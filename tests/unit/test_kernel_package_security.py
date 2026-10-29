"""CVE-2026-98432: image package and boot-payload release regressions."""

import importlib.util
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "iso/config/includes.chroot/usr/lib/orionx/check-package-security.py"
SPEC = importlib.util.spec_from_file_location("kernel_package_security", CHECKER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
NAME = "linux-image-6.12.113+deb13-amd64"
FLOOR = "6.12.113-1"


@pytest.mark.parametrize("version", [FLOOR, "6.12.113-1+deb13u1", "6.12.114-1"])
def test_fixed_kernel_versions(version):
    assert MODULE.check({NAME: version}, require_kernel=True) == ["6.12.113+deb13-amd64"]


@pytest.mark.parametrize("name,version", [
    ("linux-image-6.12.112+deb13-amd64", "6.12.112-1"),
    (NAME, "6.12.113-1~deb13u0"),
    (NAME + ":amd64", "6.12.112-1"),
    ("linux-image-6.18.1-amd64", "6.18.1-1"),
    (NAME, "7.0.0-1"),
    ("linux-image-6.12.113+deb13-arm64", FLOOR),
])
def test_unsafe_or_unsupported_kernel(name, version):
    with pytest.raises(ValueError):
        MODULE.check({name: version}, require_kernel=True)


@pytest.mark.parametrize("packages", [
    {"bash": "5.2"},
    {"linux-image-amd64": FLOOR},
    {"linux-headers-6.12.113+deb13-amd64": FLOOR},
    {"linux-libc-dev": FLOOR},
    {NAME + "-dbg": FLOOR},
])
def test_real_kernel_is_mandatory(packages):
    with pytest.raises(ValueError, match="no checked versioned"):
        MODULE.check(packages, require_kernel=True)


def test_old_image_alongside_fixed_image_is_rejected():
    with pytest.raises(ValueError, match="below Debian kernel security floor"):
        MODULE.check({NAME: FLOOR, "linux-image-6.12.112+deb13-amd64": "6.12.112-1"}, True)


def test_unsigned_and_multiarch_map_to_packaged_payload():
    assert MODULE.check({NAME + "-unsigned:amd64": FLOOR}, True) == ["6.12.113+deb13-amd64"]


@pytest.mark.parametrize("selection", ["hold", "install", "deinstall"])
@pytest.mark.parametrize("package,version", [
    (NAME, "6.12.112-1"), ("php8.4-cli", "8.4.26-1~deb13u1"),
])
def test_installed_state_cannot_hide_behind_selection(tmp_path, selection, package, version):
    status = tmp_path / "status"
    status.write_text("Package: bash\nStatus: install ok installed\nVersion: 5.2\n\n"
                      f"Package: {package}\nStatus: {selection} ok installed\nVersion: {version}\n")
    with pytest.raises(ValueError, match="below Debian"):
        MODULE.check(MODULE.installed_packages(status, "status"))


def test_uninstalled_kernel_cannot_satisfy_requirement(tmp_path):
    status = tmp_path / "status"
    status.write_text("Package: bash\nStatus: install ok installed\nVersion: 5.2\n\n"
                      f"Package: {NAME}\nStatus: deinstall ok config-files\nVersion: {FLOOR}\n")
    with pytest.raises(ValueError, match="no checked versioned"):
        MODULE.check(MODULE.installed_packages(status, "status"), True)


def test_boot_payload_match_and_stale_payload(tmp_path, monkeypatch):
    # Stub only the archive transport; exercise real subprocess, hashing and exit handling.
    tool = tmp_path / "unsquashfs"
    tool.write_text("#!/bin/sh\n[ \"$3\" = boot/vmlinuz-6.12.113+deb13-amd64 ] || exit 1\ncat \"$2\"\n")
    tool.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    archive = tmp_path / "squashfs"
    archive.write_bytes(b"fixed kernel bytes")
    boot = tmp_path / "vmlinuz"
    boot.write_bytes(b"fixed kernel bytes")
    MODULE.check_kernel_payload(["6.12.113+deb13-amd64"], archive, boot)
    boot.write_bytes(b"stale kernel bytes")
    with pytest.raises(ValueError, match="does not match"):
        MODULE.check_kernel_payload(["6.12.113+deb13-amd64"], archive, boot)
    boot.write_bytes(b"fixed kernel bytes")
    with pytest.raises(ValueError, match="does not match"):
        MODULE.check_kernel_payload(["6.12.114+deb13-amd64"], archive, boot)
    boot.write_bytes(b"")
    with pytest.raises(ValueError, match="empty"):
        MODULE.check_kernel_payload(["6.12.113+deb13-amd64"], archive, boot)


def test_cli_requires_both_payload_arguments(tmp_path):
    inventory = tmp_path / "filesystem.packages"
    inventory.write_text(f"{NAME} {FLOOR}\n")
    result = subprocess.run([sys.executable, str(CHECKER), "--packages", str(inventory),
                             "--boot-kernel", str(tmp_path / "vmlinuz")], capture_output=True, check=False)
    assert result.returncode != 0
    assert b"must be supplied together" in result.stderr


def test_debug_package_does_not_block_a_checked_image():
    MODULE.check({NAME: FLOOR, NAME + "-dbg": FLOOR}, True)

def test_fixed_metapackage_cannot_hide_stale_image():
    with pytest.raises(ValueError, match="below Debian kernel security floor"):
        MODULE.check({"linux-image-amd64": FLOOR,
                      "linux-image-6.12.112+deb13-amd64": "6.12.112-1"}, True)


def test_real_squashfs_boot_payload(tmp_path):
    import shutil
    if not shutil.which("mksquashfs") or not shutil.which("unsquashfs"):
        pytest.skip("squashfs-tools required for real image fixture")
    root = tmp_path / "root"
    (root / "boot").mkdir(parents=True)
    payload = root / "boot/vmlinuz-6.12.113+deb13-amd64"
    payload.write_bytes(b"fixed kernel fixture\0" * 100)
    archive = tmp_path / "filesystem.squashfs"
    subprocess.run(["mksquashfs", str(root), str(archive), "-noappend", "-processors", "1"],
                   check=True, capture_output=True)
    boot = tmp_path / "vmlinuz"
    boot.write_bytes(payload.read_bytes())
    MODULE.check_kernel_payload(["6.12.113+deb13-amd64"], archive, boot)
    boot.write_bytes(b"stale boot image")
    with pytest.raises(ValueError, match="does not match"):
        MODULE.check_kernel_payload(["6.12.113+deb13-amd64"], archive, boot)
    boot.unlink()
    with pytest.raises(OSError):
        MODULE.check_kernel_payload(["6.12.113+deb13-amd64"], archive, boot)


@pytest.mark.parametrize("state", ["fixed", "stale-payload", "held-stale-package"])
def test_signed_staging_security_boundary_without_signing(tmp_path, state):
    """A real tiny ISO exercises the gate even when signing is unavailable."""
    import shutil
    if not all(shutil.which(tool) for tool in ("mksquashfs", "unsquashfs", "xorriso")):
        pytest.skip("ISO/squashfs tools required")
    root = tmp_path / "root"
    (root / "boot").mkdir(parents=True)
    (root / "var/lib/dpkg").mkdir(parents=True)
    payload = b"fixed kernel fixture\0" * 100
    (root / "boot/vmlinuz-6.12.113+deb13-amd64").write_bytes(payload)
    version = "6.12.112-1" if state == "held-stale-package" else FLOOR
    (root / "var/lib/dpkg/status").write_text(
        f"Package: {NAME}\nStatus: hold ok installed\nVersion: {version}\n")
    live = tmp_path / "image/live"
    live.mkdir(parents=True)
    (live / "filesystem.packages").write_text(f"{NAME} {FLOOR}\n")
    (live / "vmlinuz").write_bytes(b"stale" if state == "stale-payload" else payload)
    subprocess.run(["mksquashfs", str(root), str(live / "filesystem.squashfs"),
                    "-noappend", "-processors", "1"], check=True, capture_output=True)
    iso = tmp_path / "fixture.iso"
    subprocess.run(["xorriso", "-as", "mkisofs", "-quiet", "-o", str(iso), str(live.parent)],
                   check=True, capture_output=True)
    # A deliberately unavailable signing key: test only the preceding security boundary.
    env = os.environ.copy()
    env["GNUPGHOME"] = str(tmp_path / "empty-gpg")
    result = subprocess.run(["bash", str(ROOT / "scripts/release/stage-split-release.sh"),
                             str(iso), "v2.2.0-rc9", "--out", str(tmp_path / "release"),
                             "--key", "0000000000000000000000000000000000000000"],
                            env=env, capture_output=True, text=True, check=False)
    output = result.stdout + result.stderr
    assert result.returncode != 0
    if state == "fixed":
        assert output.count("Package security gate PASS") == 2
        assert "sign" in output.lower()
    elif state == "stale-payload":
        assert "does not match a checked packaged kernel" in output
    else:
        assert "below Debian kernel security floor" in output
