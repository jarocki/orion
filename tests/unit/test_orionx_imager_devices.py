"""
tests/unit/test_orionx_imager_devices.py — unit tests for orionx-imager macOS device enumeration.

@decision DEC-PHASE11-IMAGER-001
@title Enumerate all disks, filter on RemovableMedia/Ejectable per-disk
@status active
@rationale `diskutil list external` excludes built-in card readers even when a
  removable SD card is inserted (macOS classifies the reader as internal/physical).
  Per-disk RemovableMedia check picks up the card via `diskutil info -plist <disk>`.
  Fixes issue #77 — user reported SD card at /dev/disk4 invisible to orionx-imager
  2026-07-21.  This test suite is the primary verification for the macOS-only fix
  because real hardware testing requires a PCIe card reader + SD card not available
  in CI (tracked as #78 in reverse).

Covers DEC-PHASE11-IMAGER-001: _list_devices_macos() must enumerate ALL disks
(not just `diskutil list external`) and filter per-disk on RemovableMedia/Ejectable
so that SD cards in PCIe-attached built-in readers are visible (issue #77).

# @mock-exempt: subprocess.check_output calls diskutil, a macOS-only OS binary
# that is unavailable in Linux CI and requires physical hardware (PCIe card reader +
# SD card) for real invocation. Mocking is the only way to exercise the per-disk
# RemovableMedia filtering logic in a repeatable, cross-platform unit test.
# The external boundary here is the macOS diskutil process, not an internal module.

All subprocess calls are mocked via unittest.mock.patch so these tests run on any
platform without real hardware.

Production sequence verified by this test:
  1. list_usb_devices() dispatches to _list_devices_macos() on Darwin
  2. _list_devices_macos() calls `diskutil list -plist` (NO "external" arg)
  3. For each disk in AllDisksAndPartitions it calls `diskutil info -plist <disk_id>`
  4. Disk is admitted iff (RemovableMedia OR Ejectable) AND WritableMedia AND not system disk
"""

from __future__ import annotations

import os
import plistlib
import subprocess as sp
import sys
import unittest
from unittest.mock import patch

# ---------------------------------------------------------------------------
# Make the library importable from any working directory
# ---------------------------------------------------------------------------
_LIB_DIR = os.path.join(
    os.path.dirname(__file__),
    "..",
    "..",
    "scripts",
    "orionx-imager",
    "lib",
)
sys.path.insert(0, os.path.abspath(_LIB_DIR))

import devices  # noqa: E402  (import after sys.path manipulation)


# ---------------------------------------------------------------------------
# Plist fixture helpers
# ---------------------------------------------------------------------------

def _make_list_plist(disk_ids: list[str]) -> bytes:
    """Return bytes for `diskutil list -plist` with the given top-level disk ids."""
    return plistlib.dumps({
        "AllDisksAndPartitions": [
            {"DeviceIdentifier": d, "Size": 32_000_000_000}
            for d in disk_ids
        ]
    })


def _make_info_plist(
    *,
    removable: bool = False,
    ejectable: bool = False,
    writable: bool = True,
    media_name: str = "",
    device_model: str = "Generic",
) -> bytes:
    """Return bytes for `diskutil info -plist <disk>` with the given flags."""
    return plistlib.dumps({
        "RemovableMedia": removable,
        "Ejectable": ejectable,
        "WritableMedia": writable,
        "MediaName": media_name,
        "DeviceModel": device_model,
    })


# ---------------------------------------------------------------------------
# Disk fixture catalogue (6 representative disks)
# ---------------------------------------------------------------------------

# disk0 — internal NVMe boot disk (system disk; must be refused)
DISK0 = "disk0"

# disk1 — internal SSD (not removable, not ejectable)
DISK1 = "disk1"
INFO_DISK1 = _make_info_plist(removable=False, ejectable=False, writable=True, device_model="APPLE SSD AP0512")

# disk2 — USB thumb drive (removable, writable)
DISK2 = "disk2"
INFO_DISK2 = _make_info_plist(removable=True, ejectable=True, writable=True, media_name="SanDisk Ultra")

# disk3 — PCIe SD card reader with SD card (ejectable=True, removable=True)
DISK3 = "disk3"
INFO_DISK3 = _make_info_plist(removable=True, ejectable=True, writable=True, media_name="SD Card")

# disk4 — read-only optical disc (ejectable but not writable)
DISK4 = "disk4"
INFO_DISK4 = _make_info_plist(removable=True, ejectable=True, writable=False, media_name="CDROM")

# disk5 — read-write RAM disk / dmg mount (ejectable=True, writable=True)
#   Per DEC-PHASE11-IMAGER-001 rationale: a writable+ejectable virtual disk
#   is admitted (we let the caller decide — the safety gate is is_system_disk).
DISK5 = "disk5"
INFO_DISK5 = _make_info_plist(removable=False, ejectable=True, writable=True, media_name="DiskImages")

ALL_DISK_IDS = [DISK0, DISK1, DISK2, DISK3, DISK4, DISK5]
LIST_PLIST = _make_list_plist(ALL_DISK_IDS)

INFO_MAP: dict[str, bytes] = {
    # disk0 would never reach info call (filtered by is_system_disk first)
    DISK1: INFO_DISK1,
    DISK2: INFO_DISK2,
    DISK3: INFO_DISK3,
    DISK4: INFO_DISK4,
    DISK5: INFO_DISK5,
}


def _side_effect_check_output(cmd: list[str], **kwargs) -> bytes:
    """Route mocked subprocess.check_output calls to the right plist fixture."""
    if cmd[:3] == ["diskutil", "list", "-plist"]:
        # The new code calls ["diskutil", "list", "-plist"] with no extra arg
        assert len(cmd) == 3, f"Expected 3-element list cmd, got: {cmd}"
        return LIST_PLIST
    if cmd[:3] == ["diskutil", "info", "-plist"]:
        disk_id = cmd[3]
        return INFO_MAP[disk_id]
    raise ValueError(f"Unexpected subprocess call: {cmd}")


# ---------------------------------------------------------------------------
# Core enumeration tests
# ---------------------------------------------------------------------------

class TestListDevicesMacOS(unittest.TestCase):
    """Tests for _list_devices_macos() — the macOS enumeration internals."""

    def _run(self) -> list[dict]:
        """Invoke _list_devices_macos() with all subprocess calls mocked."""
        with patch("devices.subprocess.check_output", side_effect=_side_effect_check_output):
            return devices._list_devices_macos()

    # ------------------------------------------------------------------
    # DEC-PHASE11-IMAGER-001: no "external" argument to diskutil list
    # ------------------------------------------------------------------

    def test_diskutil_list_called_without_external_arg(self) -> None:
        """diskutil list must be called as ['diskutil', 'list', '-plist'] with no extra arg."""
        with patch("devices.subprocess.check_output", side_effect=_side_effect_check_output) as mock_co:
            devices._list_devices_macos()
        list_calls = [c for c in mock_co.call_args_list if c.args[0][:2] == ["diskutil", "list"]]
        self.assertEqual(len(list_calls), 1)
        actual_cmd = list_calls[0].args[0]
        self.assertEqual(actual_cmd, ["diskutil", "list", "-plist"],
                         "The 'external' argument must not be passed to diskutil list")

    # ------------------------------------------------------------------
    # Boot disk exclusion
    # ------------------------------------------------------------------

    def test_boot_disk_excluded(self) -> None:
        """disk0 (system disk) must never appear in results."""
        result = self._run()
        paths = [d["path"] for d in result]
        self.assertNotIn("/dev/disk0", paths, "/dev/disk0 is the system disk and must be excluded")

    # ------------------------------------------------------------------
    # Internal non-removable SSD must be excluded
    # ------------------------------------------------------------------

    def test_internal_ssd_excluded(self) -> None:
        """disk1 (internal non-removable SSD) must not appear in results."""
        result = self._run()
        paths = [d["path"] for d in result]
        self.assertNotIn("/dev/disk1", paths, "Internal non-removable SSD must be filtered out")

    # ------------------------------------------------------------------
    # USB thumb drive must be included
    # ------------------------------------------------------------------

    def test_usb_thumb_drive_included(self) -> None:
        """disk2 (USB thumb drive, RemovableMedia=True) must appear in results."""
        result = self._run()
        paths = [d["path"] for d in result]
        self.assertIn("/dev/disk2", paths, "USB thumb drive must be included in enumeration")

    # ------------------------------------------------------------------
    # PCIe SD card reader — the issue #77 target — must be included
    # ------------------------------------------------------------------

    def test_pcie_sd_card_included(self) -> None:
        """disk3 (PCIe SD reader with SD card, RemovableMedia=True) must appear in results.

        This is the exact failure mode reported in issue #77: a PCIe-attached
        built-in reader is 'internal/physical' to diskutil, so 'diskutil list
        external' returned nothing.  After DEC-PHASE11-IMAGER-001 the per-disk
        RemovableMedia check surfaces the SD card regardless of reader bus type.
        """
        result = self._run()
        paths = [d["path"] for d in result]
        self.assertIn("/dev/disk3", paths,
                      "SD card in PCIe reader (RemovableMedia=True) must be visible after issue #77 fix")

    # ------------------------------------------------------------------
    # Read-only optical disc must be excluded (WritableMedia=False)
    # ------------------------------------------------------------------

    def test_readonly_optical_excluded(self) -> None:
        """disk4 (read-only optical disc, WritableMedia=False) must not appear."""
        result = self._run()
        paths = [d["path"] for d in result]
        self.assertNotIn("/dev/disk4", paths, "Read-only media (WritableMedia=False) must be excluded")

    # ------------------------------------------------------------------
    # Writable+ejectable virtual disk (dmg mount) — admitted
    # ------------------------------------------------------------------

    def test_writable_virtual_disk_admitted(self) -> None:
        """disk5 (writable dmg mount, Ejectable=True, WritableMedia=True) is admitted.

        Per DEC-PHASE11-IMAGER-001: the per-disk filter admits anything that is
        (RemovableMedia OR Ejectable) AND WritableMedia.  A mounted writable
        disk image satisfies Ejectable=True + WritableMedia=True, so it passes
        the filter.  The caller (the imager UI) presents it to the operator who
        can choose to skip it.  Excluding writable virtual disks here would
        silently hide legitimate test targets on developer machines.
        """
        result = self._run()
        paths = [d["path"] for d in result]
        self.assertIn("/dev/disk5", paths,
                      "Writable ejectable virtual disk (dmg mount) should be admitted — caller decides")

    # ------------------------------------------------------------------
    # Result shape
    # ------------------------------------------------------------------

    def test_result_sorted_by_path(self) -> None:
        """Results must be sorted by path ascending."""
        result = self._run()
        paths = [d["path"] for d in result]
        self.assertEqual(paths, sorted(paths))

    def test_result_has_required_keys(self) -> None:
        """Each device dict must contain the canonical keys."""
        result = self._run()
        required = {"path", "size", "size_bytes", "model", "vendor", "removable", "mounted"}
        for dev in result:
            self.assertTrue(required.issubset(dev.keys()),
                            f"Device dict missing keys: {required - dev.keys()}")

    def test_removable_flag_is_true(self) -> None:
        """All returned devices must have removable=True."""
        result = self._run()
        for dev in result:
            self.assertTrue(dev["removable"], f"{dev['path']} has removable=False")

    # ------------------------------------------------------------------
    # Compound-interaction: production sequence end-to-end
    # ------------------------------------------------------------------

    def test_production_sequence_end_to_end(self) -> None:
        """Exercise the real production call chain crossing all internal boundaries.

        Simulates what happens when the operator inserts an SD card into a
        built-in PCIe reader (issue #77):

          list_usb_devices()               [public API]
            -> _list_devices_macos()       [platform dispatch]
               -> diskutil list -plist     [step 1: enumerate all disks]
               -> is_system_disk()         [step 2: filter system disk]
               -> _macos_disk_is_removable() [step 3: per-disk flags via diskutil info]
               -> _macos_disk_model()      [step 4: fetch human name]
               -> _macos_is_mounted()      [step 5: check mount status]

        Verifies that the SD card (disk3) appears and the boot disk (disk0)
        does not, using mocked plist bytes that mirror the real macOS plist
        structure returned by diskutil.
        """
        with patch("devices.platform.system", return_value="Darwin"), \
             patch("devices.subprocess.check_output", side_effect=_side_effect_check_output):
            result = devices.list_usb_devices()

        paths = [d["path"] for d in result]

        # Boot disk must never be offered to the operator
        self.assertNotIn("/dev/disk0", paths)

        # SD card in PCIe reader must be visible (core fix for issue #77)
        self.assertIn("/dev/disk3", paths)

        # USB drive must remain visible (regression guard)
        self.assertIn("/dev/disk2", paths)

        # Internal non-removable SSD must stay hidden
        self.assertNotIn("/dev/disk1", paths)


# ---------------------------------------------------------------------------
# Robustness: diskutil info failure mid-enumeration
# ---------------------------------------------------------------------------

class TestMacosDiskIsRemovable(unittest.TestCase):
    """Tests for _macos_disk_is_removable() edge cases."""

    def test_returns_false_on_subprocess_failure(self) -> None:
        """If diskutil info crashes mid-enumeration, skip the disk (return False)."""
        with patch("devices.subprocess.check_output", side_effect=sp.CalledProcessError(1, "diskutil")):
            result = devices._macos_disk_is_removable("disk99")
        self.assertFalse(result, "A diskutil info failure must return False (skip disk, don't crash)")

    def test_removable_true_writable_true(self) -> None:
        """RemovableMedia=True + WritableMedia=True → admitted."""
        plist_bytes = _make_info_plist(removable=True, ejectable=False, writable=True)
        with patch("devices.subprocess.check_output", return_value=plist_bytes):
            self.assertTrue(devices._macos_disk_is_removable("disk2"))

    def test_ejectable_true_writable_true(self) -> None:
        """Ejectable=True + WritableMedia=True → admitted (PCIe card reader path)."""
        plist_bytes = _make_info_plist(removable=False, ejectable=True, writable=True)
        with patch("devices.subprocess.check_output", return_value=plist_bytes):
            self.assertTrue(devices._macos_disk_is_removable("disk3"))

    def test_removable_true_writable_false(self) -> None:
        """Ejectable=True but WritableMedia=False → rejected (read-only media)."""
        plist_bytes = _make_info_plist(removable=True, ejectable=True, writable=False)
        with patch("devices.subprocess.check_output", return_value=plist_bytes):
            self.assertFalse(devices._macos_disk_is_removable("disk4"))

    def test_neither_removable_nor_ejectable(self) -> None:
        """RemovableMedia=False + Ejectable=False → rejected regardless of writable."""
        plist_bytes = _make_info_plist(removable=False, ejectable=False, writable=True)
        with patch("devices.subprocess.check_output", return_value=plist_bytes):
            self.assertFalse(devices._macos_disk_is_removable("disk1"))


# ---------------------------------------------------------------------------
# Linux path is unaffected (regression guard)
# ---------------------------------------------------------------------------

class TestListDevicesLinuxUnaffected(unittest.TestCase):
    """Verify that the Linux enumeration path still works after macOS changes."""

    def test_linux_path_still_uses_lsblk(self) -> None:
        """_list_devices_linux() must still call lsblk (not diskutil)."""
        lsblk_output = b'{"blockdevices": [{"name": "sdb", "type": "disk", "size": "32G", "model": "SanDisk", "vendor": "SanDisk", "rm": "1", "mountpoint": null}]}'
        with patch("devices.subprocess.check_output", return_value=lsblk_output) as mock_co, \
             patch("devices.platform.system", return_value="Linux"), \
             patch("devices._is_linux_system_disk", return_value=False):
            result = devices.list_usb_devices()
        # Verify lsblk was called
        calls = mock_co.call_args_list
        self.assertTrue(any("lsblk" in str(c) for c in calls), "lsblk must be called on Linux")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["path"], "/dev/sdb")


if __name__ == "__main__":
    unittest.main()
