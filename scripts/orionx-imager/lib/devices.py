"""
lib/devices.py — USB device enumeration for orionx-imager.

Single-authority for listing removable block devices on macOS and Linux.
Uses only stdlib: subprocess, json, plistlib, platform.

macOS path: diskutil list -plist (parsed via plistlib).
Linux path:  lsblk -Jo NAME,TYPE,SIZE,MODEL,VENDOR,RM,MOUNTPOINT (parsed via json).

@decision DEC-PHASE11-015
@title    Orion-X imager — USB enumeration + system-disk refuse-list (Layer A)
@status   accepted
@rationale
    usb_device_enumeration_authority: platform-specific stdlib subprocesses are the
    single canonical enumeration path. No /dev globbing shortcuts.  macOS uses
    diskutil (plistlib); Linux uses lsblk -J. Both filter to removable media only.
    Refuse-list (not allow-list) lets operators image real USB sticks that appear at
    arbitrary /dev paths while hard-blocking known system disks.
"""

from __future__ import annotations

import json
import platform
import plistlib
import subprocess
from typing import Optional


# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

# Each device dict shape:
# {
#   "path":      str,   e.g. "/dev/disk4" or "/dev/sdb"
#   "size":      str,   human-readable, e.g. "32.0 GB"
#   "size_bytes":int,   best-effort; 0 if unknown
#   "model":     str,
#   "vendor":    str,
#   "removable": bool,
#   "mounted":   bool,
# }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def list_usb_devices() -> list[dict]:
    """Return list of removable block devices on the current host.

    Filters to removable media only; excludes system disks detected by
    ``is_system_disk()``.  Returns an empty list rather than raising if
    no USB devices are attached.

    Raises RuntimeError for unsupported platforms.
    """
    system = platform.system()
    if system == "Darwin":
        return _list_devices_macos()
    elif system == "Linux":
        return _list_devices_linux()
    else:
        raise RuntimeError(f"Unsupported platform: {system!r}. Only macOS and Linux are supported in Layer A.")


def is_system_disk(path: str) -> bool:
    """Return True if *path* is a known system / boot disk.

    macOS: /dev/disk0 is always the internal boot volume container on both
    Apple Silicon and Intel hardware.

    Linux: /dev/sda is refused if it is mounted at / OR is the root source
    (detected via ``findmnt --target / --output SOURCE``).  If findmnt is
    unavailable, /dev/sda is refused unconditionally (fail-safe).
    """
    system = platform.system()
    if system == "Darwin":
        return path == "/dev/disk0"
    elif system == "Linux":
        return _is_linux_system_disk(path)
    return False


def refuse_write(path: str) -> Optional[str]:
    """Return a human-readable refusal reason if *path* must not be written.

    Returns None if the device is safe to write.
    Callers should treat a non-None return as a hard error unless the operator
    has explicitly provided ``--i-really-know-what-im-doing``.
    """
    if is_system_disk(path):
        system = platform.system()
        if system == "Darwin":
            return (
                f"{path} is the internal system disk (/dev/disk0 on macOS). "
                "Writing to the system disk would brick your machine. Refused."
            )
        else:
            return (
                f"{path} appears to be the system/root disk on Linux. "
                "Writing to the system disk would brick your machine. Refused."
            )
    return None


# ---------------------------------------------------------------------------
# macOS implementation
# ---------------------------------------------------------------------------

def _list_devices_macos() -> list[dict]:
    """Enumerate removable disks on macOS via diskutil list -plist."""
    try:
        raw = subprocess.check_output(
            ["diskutil", "list", "-plist", "external"],
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise RuntimeError(f"diskutil failed: {exc}") from exc

    try:
        plist = plistlib.loads(raw)
    except Exception as exc:
        raise RuntimeError(f"Failed to parse diskutil plist output: {exc}") from exc

    devices: list[dict] = []
    for disk_path in plist.get("AllDisksAndPartitions", []):
        path = "/dev/" + disk_path.get("DeviceIdentifier", "")
        if not path or path == "/dev/":
            continue
        # Skip if system disk
        if is_system_disk(path):
            continue
        size_bytes = disk_path.get("Size", 0)
        devices.append({
            "path": path,
            "size": _fmt_bytes(size_bytes),
            "size_bytes": size_bytes,
            "model": _macos_disk_model(disk_path.get("DeviceIdentifier", "")),
            "vendor": "",
            "removable": True,
            "mounted": _macos_is_mounted(disk_path),
        })
    return sorted(devices, key=lambda d: d["path"])


def _macos_disk_model(disk_id: str) -> str:
    """Try to get human-friendly model string from diskutil info."""
    try:
        raw = subprocess.check_output(
            ["diskutil", "info", "-plist", disk_id],
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
        info = plistlib.loads(raw)
        media_name = info.get("MediaName", "")
        device_model = info.get("DeviceModel", "")
        return media_name or device_model or "?"
    except Exception:
        return "?"


def _macos_is_mounted(disk_entry: dict) -> bool:
    """Return True if the disk or any partition has a mount point."""
    if disk_entry.get("MountPoint"):
        return True
    for part in disk_entry.get("Partitions", []):
        if part.get("MountPoint"):
            return True
    return False


# ---------------------------------------------------------------------------
# Linux implementation
# ---------------------------------------------------------------------------

def _list_devices_linux() -> list[dict]:
    """Enumerate removable disks on Linux via lsblk -J."""
    try:
        raw = subprocess.check_output(
            ["lsblk", "-Jo", "NAME,TYPE,SIZE,MODEL,VENDOR,RM,MOUNTPOINT"],
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise RuntimeError(f"lsblk failed: {exc}") from exc

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Failed to parse lsblk JSON output: {exc}") from exc

    devices: list[dict] = []
    for dev in data.get("blockdevices", []):
        if dev.get("type") != "disk":
            continue
        # RM can be "1" (string) or 1 (int) or True depending on lsblk version
        rm = dev.get("rm", "0")
        if str(rm) not in ("1", "true", "True"):
            continue
        path = f"/dev/{dev['name']}"
        # Skip system disks
        if is_system_disk(path):
            continue
        size_bytes = _parse_lsblk_size(dev.get("size", "0"))
        mounted = bool(dev.get("mountpoint"))
        # Also check children for mountpoints
        if not mounted:
            for child in dev.get("children", []):
                if child.get("mountpoint"):
                    mounted = True
                    break
        devices.append({
            "path": path,
            "size": dev.get("size", "?"),
            "size_bytes": size_bytes,
            "model": (dev.get("model") or "?").strip(),
            "vendor": (dev.get("vendor") or "").strip(),
            "removable": True,
            "mounted": mounted,
        })
    return sorted(devices, key=lambda d: d["path"])


def _is_linux_system_disk(path: str) -> bool:
    """Return True if *path* is the Linux root device."""
    # Always refuse /dev/sda as a safety default; additionally check findmnt.
    # The explicit check against findmnt catches cases where /dev/sda is NOT
    # root (unlikely but possible on servers with NVMe) and /dev/nvme0n1 IS.
    try:
        result = subprocess.run(
            ["findmnt", "--target", "/", "--output", "SOURCE", "--noheadings"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            root_source = result.stdout.strip()
            # root_source may be "/dev/sda1"; check if path is a prefix
            if root_source.startswith(path):
                return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        # findmnt unavailable: fall through to conservative /dev/sda check
        pass

    # Conservative fallback: refuse /dev/sda on Linux
    return path == "/dev/sda"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fmt_bytes(n: int) -> str:
    """Format byte count as human-readable string."""
    if n == 0:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n //= 1024  # type: ignore[assignment]
    return f"{n:.1f} PB"


def _parse_lsblk_size(s: str) -> int:
    """Best-effort parse of lsblk size string (e.g. '32G', '500M') to bytes."""
    s = s.strip()
    if not s or s == "?":
        return 0
    multipliers = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
    suffix = s[-1].upper()
    if suffix in multipliers:
        try:
            return int(float(s[:-1]) * multipliers[suffix])
        except ValueError:
            return 0
    try:
        return int(s)
    except ValueError:
        return 0
