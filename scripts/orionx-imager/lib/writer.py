"""
lib/writer.py — block-device writer for orionx-imager (macOS + Linux).

Single authority for the write path. The actual raw-device copy runs in the
elevated helper lib/raw_write.py (run via sudo), which streams EXACT byte
progress back on stdout — see DEC-PHASE11-038. stdlib only.

Elevation model (Layer A): the tool runs unprivileged; the copy is performed by
`sudo [-S] python3 raw_write.py <iso> <target>`. The optional password (from the
GUI dialog) is fed to `sudo -S` via stdin; without it, plain sudo prompts on the
terminal. Layer B may add pkexec (Linux) and SMJobBless (macOS).

@decision DEC-PHASE11-015
@title    Orion-X imager — raw-device writer + safety refuse-list (Layer A)
@status   accepted
@rationale
    Raw sector-aligned copy in a stdlib helper (macOS uses /dev/rdiskN for
    speed, exactly as dd did). Safety: WriteRefused is raised before any
    subprocess when devices.refuse_write(target) returns a reason.

@decision DEC-PHASE11-038
@title    Honest write progress via a self-reporting elevated helper
@status   accepted
@rationale
    The old path shelled out to `sudo dd` and drove the bar by sending SIGINFO
    to the dd process — but the Popen child is *sudo*, which does not forward
    SIGINFO to the root dd child on macOS, so the bar sat at 0% then jumped to
    100%. raw_write.py copies in 4 MiB chunks and prints the cumulative bytes
    written after each chunk, so progress is exact and identical on both OSes.
"""

from __future__ import annotations

import os
import pathlib
import platform
import subprocess
from typing import Callable, Optional


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class WriteRefused(RuntimeError):
    """Raised when a write is refused by the safety refuse-list."""


class WriteError(RuntimeError):
    """Raised when the dd write subprocess fails."""


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

ProgressCallback = Optional[Callable[[int, int], None]]
# progress_cb(bytes_written_estimate: int, total_bytes: int)


def _sudo(args: list[str], password: Optional[str]) -> list[str]:
    """Return an argv prefixed with sudo. When a *password* is supplied use
    ``sudo -S`` (reads the password from stdin — see DEC-PHASE11-032), so the
    GUI can collect it in a dialog instead of the controlling terminal. When
    *password* is None, plain ``sudo`` is used (CLI/terminal path prompts as
    before)."""
    return ["sudo", "-S", *args] if password is not None else ["sudo", *args]


def unmount_target(path: str, password: Optional[str] = None) -> None:
    """Unmount all partitions on *path* before writing.

    macOS: ``diskutil unmountDisk <path>`` (no elevation needed)
    Linux: attempts ``umount`` on the device and common partition suffixes.

    Does NOT raise on failure — unmounting is best-effort; if a partition
    is busy, dd will fail with a clearer error anyway.
    """
    system = platform.system()
    if system == "Darwin":
        _run_silent(["diskutil", "unmountDisk", path])
    elif system == "Linux":
        # Try to unmount each numbered partition (e.g. /dev/sdb1, /dev/sdb2)
        for suffix in ("", "1", "2", "3", "4"):
            candidate = path + suffix
            if os.path.exists(candidate):
                _run_silent(_sudo(["umount", candidate], password), password=password)


def write_iso(
    iso_path: pathlib.Path,
    target: str,
    progress_cb: ProgressCallback = None,
    dry_run: bool = False,
    password: Optional[str] = None,
) -> None:
    """Write *iso_path* to *target* block device via dd.

    Safety checks run before any I/O:
    - Calls ``devices.refuse_write(target)`` and raises WriteRefused if refused.
    - Verifies iso_path exists and is a file.

    The write itself is done by the elevated helper raw_write.py (see
    _run_copy): unmount first (diskutil on macOS, umount on Linux), then a
    sector-aligned raw copy (macOS uses /dev/rdiskN for speed).

    In dry_run mode, prints the intended command without executing it.

    Progress: the helper reports the exact cumulative bytes written after every
    4 MiB chunk; _run_copy forwards each to progress_cb(bytes_written, total).
    Honest and identical on both platforms (DEC-PHASE11-038).

    Raises:
        WriteRefused: if the target is on the refuse list.
        WriteError:   if the raw write exits non-zero.
        FileNotFoundError: if iso_path does not exist.
    """
    # Import here to avoid circular import at module load time.
    from lib import devices  # type: ignore[import]

    # --- Safety checks ---
    refusal = devices.refuse_write(target)
    if refusal:
        raise WriteRefused(refusal)

    if not iso_path.exists():
        raise FileNotFoundError(f"ISO not found: {iso_path}")
    if not iso_path.is_file():
        raise ValueError(f"Not a regular file: {iso_path}")

    total_bytes = iso_path.stat().st_size
    system = platform.system()

    if system == "Darwin":
        _write_macos(iso_path, target, total_bytes, progress_cb, dry_run, password)
    elif system == "Linux":
        _write_linux(iso_path, target, total_bytes, progress_cb, dry_run, password)
    else:
        raise RuntimeError(f"Unsupported platform: {system!r}. Only macOS and Linux are supported in Layer A.")


# ---------------------------------------------------------------------------
# macOS write path
# ---------------------------------------------------------------------------

# Absolute path to the elevated raw-device writer helper (DEC-PHASE11-038).
_HELPER = str(pathlib.Path(__file__).resolve().parent / "raw_write.py")


def _write_macos(
    iso_path: pathlib.Path,
    target: str,
    total_bytes: int,
    progress_cb: ProgressCallback,
    dry_run: bool,
    password: Optional[str] = None,
) -> None:
    """Write ISO to target on macOS via the raw_write helper (exact progress)."""
    cmd = _sudo(["python3", _HELPER, str(iso_path), target], password)

    if dry_run:
        _print_dry_run(cmd, iso_path, target, total_bytes)
        return

    unmount_target(target, password)
    _run_copy(cmd, total_bytes, progress_cb, password)
    _sync()


def _run_copy(
    cmd: list[str],
    total_bytes: int,
    progress_cb: ProgressCallback,
    password: Optional[str] = None,
) -> None:
    """Run the elevated raw_write helper and stream its EXACT byte-progress.

    The helper prints the cumulative bytes written (one integer per line) as the
    copy proceeds, then a final 'DONE'. This replaces the old dd + SIGINFO path,
    whose signal never reached the root dd child through sudo on macOS
    (DEC-PHASE11-038). Progress is therefore honest and identical on both
    platforms. sudo's password prompt and any error text go to stderr.
    """
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if password is not None else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    _feed_sudo_password(proc, password)

    assert proc.stdout is not None
    for raw_line in proc.stdout:
        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line or line == "DONE":
            continue
        if progress_cb is not None and line.isdigit():
            progress_cb(int(line), total_bytes)

    ret = proc.wait()
    if ret != 0:
        err = ""
        if proc.stderr is not None:
            err = proc.stderr.read().decode("utf-8", errors="replace")
        raise WriteError(f"raw write exited with code {ret}:\n{err.strip()[-800:]}")


# ---------------------------------------------------------------------------
# Linux write path
# ---------------------------------------------------------------------------

def _write_linux(
    iso_path: pathlib.Path,
    target: str,
    total_bytes: int,
    progress_cb: ProgressCallback,
    dry_run: bool,
    password: Optional[str] = None,
) -> None:
    """Write ISO to target on Linux via the raw_write helper (exact progress)."""
    cmd = _sudo(["python3", _HELPER, str(iso_path), target], password)

    if dry_run:
        _print_dry_run(cmd, iso_path, target, total_bytes)
        return

    unmount_target(target, password)
    _run_copy(cmd, total_bytes, progress_cb, password)
    _sync()


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

def _sync() -> None:
    """Flush all pending writes to disk."""
    try:
        subprocess.run(["sync"], check=True, timeout=60)
    except subprocess.CalledProcessError as exc:
        raise WriteError(f"sync failed: {exc}") from exc


def _feed_sudo_password(proc: "subprocess.Popen", password: Optional[str]) -> None:
    """Write *password* to a ``sudo -S`` subprocess's stdin, then close it.

    sudo -S reads exactly one line (the password) from stdin; dd then runs with
    if=<file> so it ignores the remaining stdin. Best-effort: a wrong password
    makes sudo fail and dd exit non-zero, surfaced later as WriteError.
    """
    if password is None or proc.stdin is None:
        return
    try:
        proc.stdin.write((password + "\n").encode("utf-8"))
        proc.stdin.flush()
        proc.stdin.close()
    except (BrokenPipeError, OSError):
        pass


def _run_silent(cmd: list[str], password: Optional[str] = None) -> None:
    """Run a command, ignoring errors (best-effort operations like unmount).

    When *password* is given, feed it to stdin (for ``sudo -S umount``).
    """
    try:
        subprocess.run(
            cmd,
            input=(password + "\n").encode("utf-8") if password is not None else None,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except Exception:
        pass


def _print_dry_run(cmd: list[str], iso_path: pathlib.Path, target: str, total_bytes: int) -> None:
    """Print the dry-run plan without executing anything."""
    size_gb = total_bytes / 1e9
    print(
        f"\n[DRY RUN] NOT executing. Would run:\n"
        f"  {' '.join(cmd)}\n\n"
        f"  ISO:    {iso_path}  ({size_gb:.2f} GB)\n"
        f"  Target: {target}\n"
        f"\nNo data written. Remove --dry-run to perform the actual write.\n",
        flush=True,
    )
