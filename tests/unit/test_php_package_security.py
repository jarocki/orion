"""Regression tests for the PHP/Trixie release floor."""

import importlib.util
import shutil
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "iso/config/includes.chroot/usr/lib/orionx/check-package-security.py"
SPEC = importlib.util.spec_from_file_location("php_package_security", CHECKER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_inventory_absent_php_is_safe(tmp_path):
    inventory = tmp_path / "filesystem.packages"
    inventory.write_text("bash 5.2.15-2\n")
    MODULE.check(MODULE.installed_packages(inventory, "packages"))


@pytest.mark.skipif(shutil.which("dpkg") is None, reason="Debian dpkg is required")
@pytest.mark.parametrize(
    "version,passes",
    [
        ("8.4.26-1~deb13u1", False),
        ("8.4.27-1~deb13u1", True),
        ("8.4.28-1~deb13u1", True),
    ],
)
def test_php_floor(version, passes):
    packages = {"php8.4-cli": version, "libapache2-mod-php8.4": version}
    if passes:
        MODULE.check(packages)
    else:
        with pytest.raises(ValueError, match="below Debian security floor"):
            MODULE.check(packages)


def test_other_php_runtime_rejected():
    with pytest.raises(ValueError, match="unsupported PHP runtime"):
        MODULE.check({"php8.3-cli": "8.3.0-1"})


@pytest.mark.skipif(shutil.which("dpkg") is None, reason="Debian dpkg is required")
def test_multiarch_php_runtime_is_checked():
    with pytest.raises(ValueError, match="below Debian security floor"):
        MODULE.check({"php8.4:amd64": "8.4.26-1~deb13u1"})


@pytest.mark.parametrize("contents", ["", "php8.4-cli\n", "php8.4-cli 8.4.27 extra\n"])
def test_invalid_inventory_fails_closed(tmp_path, contents):
    inventory = tmp_path / "filesystem.packages"
    inventory.write_text(contents)
    with pytest.raises(ValueError):
        MODULE.installed_packages(inventory, "packages")


def test_dpkg_status_parses_only_installed(tmp_path):
    status = tmp_path / "status"
    status.write_text(
        "Package: php8.4-cli\nStatus: install ok installed\n"
        "Version: 8.4.27-1~deb13u1\n\n"
        "Package: php8.4-fpm\nStatus: deinstall ok config-files\n"
        "Version: 8.4.26-1~deb13u1\n"
    )
    assert MODULE.installed_packages(status, "status") == {
        "php8.4-cli": "8.4.27-1~deb13u1"
    }


def test_missing_inventory_fails_closed(tmp_path):
    with pytest.raises(OSError):
        MODULE.installed_packages(tmp_path / "missing", "packages")
