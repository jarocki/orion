"""
lib/writer.py — Platform-specific USB writer for orionx-imager.

Single-authority for block-device write logic (dd) on macOS and Linux.
Uses only stdlib: subprocess, os, platform, signal, threading, pathlib.

Elevation model (Layer A): tool runs unprivileged; write_iso() detects
EACCES and re-execs the dd subprocess via sudo. Layer B may add pkexec
(Linux) and SMJobBless (macOS).

@decision DEC-PHASE11-015
@title    Orion-X imager — platform dd writer + safety refuse-list (Layer A)
@status   accepted
@rationale
    dd is the universal low-level block writer on Unix; no third-party deps.
    macOS uses bs=4m (lowercase) and /dev/rdiskN (raw disk) for speed.
    Linux uses bs=4M oflag=direct,sync for cache bypass + write ordering.
    Safety: WriteRefused exception raised before any subprocess if
    devices.refuse_write(target) returns a reason. Elevation via sudo only
    (Layer A); pkexec / notarized helper deferred to Layer B.
"""

from __future__ import annotations

import os
import pathlib
import platform
import signal
import subprocess
import threading
import time
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

    macOS:
      - Converts /dev/diskN to /dev/rdiskN for raw (faster) access.
      - Uses ``bs=4m`` (macOS dd uses lowercase).
      - Unmounts the disk first via diskutil.

    Linux:
      - Uses ``bs=4M oflag=direct,sync`` for cache bypass + write ordering.
      - Unmounts partitions first.

    In dry_run mode, prints the intended command without executing it.

    Progress (Layer A):
      - macOS: sends SIGINFO to dd every 2 s and captures stderr.
      - Linux: polls /sys/block/<dev>/stat (column 6 = sectors written).
      Both strategies update progress_cb when available.

    Raises:
        WriteRefused: if the target is on the refuse list.
        WriteError:   if dd exits non-zero.
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

def _write_macos(
    iso_path: pathlib.Path,
    target: str,
    total_bytes: int,
    progress_cb: ProgressCallback,
    dry_run: bool,
    password: Optional[str] = None,
) -> None:
    """Write ISO to target on macOS."""
    # Use raw disk device for speed
    raw_target = target.replace("/dev/disk", "/dev/rdisk")
    cmd = _sudo(
        [
            "dd",
            f"if={iso_path}",
            f"of={raw_target}",
            "bs=4m",
        ],
        password,
    )

    if dry_run:
        _print_dry_run(cmd, iso_path, target, total_bytes)
        return

    unmount_target(target, password)
    _run_dd_macos(cmd, total_bytes, progress_cb, password)
    _sync()


def _run_dd_macos(
    cmd: list[str],
    total_bytes: int,
    progress_cb: ProgressCallback,
    password: Optional[str] = None,
) -> None:
    """Run dd on macOS, periodically sending SIGINFO to get progress."""
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if password is not None else None,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    _feed_sudo_password(proc, password)

    stop_event = threading.Event()

    def _siginfo_sender() -> None:
        """Send SIGINFO to dd every 2 s to trigger progress output on macOS."""
        while not stop_event.wait(2.0):
            try:
                proc.send_signal(signal.SIGINFO)
            except (ProcessLookupError, OSError):
                break

    if progress_cb:
        sender = threading.Thread(target=_siginfo_sender, daemon=True)
        sender.start()

    stderr_lines: list[str] = []
    try:
        # Read stderr line by line; dd prints progress on SIGINFO to stderr
        assert proc.stderr is not None
        for raw_line in proc.stderr:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if line:
                stderr_lines.append(line)
                if progress_cb:
                    bytes_written = _parse_dd_progress_macos(line)
                    if bytes_written is not None:
                        progress_cb(bytes_written, total_bytes)
    finally:
        stop_event.set()

    ret = proc.wait()
    if ret != 0:
        stderr_tail = "\n".join(stderr_lines[-5:])
        raise WriteError(f"dd exited with code {ret}:\n{stderr_tail}")


def _parse_dd_progress_macos(line: str) -> Optional[int]:
    """Parse dd SIGINFO stderr line on macOS to extract bytes transferred.

    macOS dd SIGINFO output looks like:
      ``1073741824 bytes (1073741824 bytes) transferred in 10.123456 secs (...)``
    Returns bytes transferred as int, or None if line doesn't match.
    """
    import re
    m = re.match(r"^\s*(\d+)\s+bytes\s+transferred", line)
    if m:
        return int(m.group(1))
    return None


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
    """Write ISO to target on Linux."""
    cmd = _sudo(
        [
            "dd",
            f"if={iso_path}",
            f"of={target}",
            "bs=4M",
            "oflag=direct,sync",
            "status=progress",
        ],
        password,
    )

    if dry_run:
        _print_dry_run(cmd, iso_path, target, total_bytes)
        return

    unmount_target(target, password)
    _run_dd_linux(cmd, target, total_bytes, progress_cb, password)
    _sync()


def _run_dd_linux(
    cmd: list[str],
    target: str,
    total_bytes: int,
    progress_cb: ProgressCallback,
    password: Optional[str] = None,
) -> None:
    """Run dd on Linux with status=progress; also poll /sys/block/<dev>/stat."""
    dev_name = os.path.basename(target)  # e.g. "sdb"
    stat_path = f"/sys/block/{dev_name}/stat"

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE if password is not None else None,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    _feed_sudo_password(proc, password)

    stop_event = threading.Event()

    def _stat_poller() -> None:
        """Poll /sys/block/<dev>/stat column 6 (sectors written) every second."""
        while not stop_event.wait(1.0):
            try:
                with open(stat_path) as fh:
                    cols = fh.read().split()
                if len(cols) >= 6 and progress_cb:
                    sectors = int(cols[5])
                    progress_cb(sectors * 512, total_bytes)
            except (OSError, ValueError):
                pass

    if progress_cb and os.path.exists(stat_path):
        poller = threading.Thread(target=_stat_poller, daemon=True)
        poller.start()

    stderr_lines: list[str] = []
    try:
        assert proc.stderr is not None
        for raw_line in proc.stderr:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if line:
                stderr_lines.append(line)
    finally:
        stop_event.set()

    ret = proc.wait()
    if ret != 0:
        stderr_tail = "\n".join(stderr_lines[-5:])
        raise WriteError(f"dd exited with code {ret}:\n{stderr_tail}")


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
