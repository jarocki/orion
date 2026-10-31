"""Regression tests for the Debian security floors gate (DEC-PHASE13-027).

The version-ordering tests need Debian's dpkg and are skipped elsewhere; run
them in the headless Debian image when the host is not Debian.
"""

import importlib.util
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "iso/config/includes.chroot/usr/lib/orionx/check-package-security.py"
SPEC = importlib.util.spec_from_file_location("package_security", CHECKER)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

needs_dpkg = pytest.mark.skipif(shutil.which("dpkg") is None, reason="Debian dpkg is required")


def floor(label: str) -> "MODULE.Floor":
    return next(f for f in MODULE.FLOORS if f.label == label)


# --- the table itself ------------------------------------------------------

def test_floor_table_is_well_formed():
    labels = [f.label for f in MODULE.FLOORS]
    assert len(labels) == len(set(labels)), "duplicate floor labels"
    for f in MODULE.FLOORS:
        re.compile(f.names)                      # every regex compiles
        assert f.names.startswith("^") and f.names.endswith("$"), f"{f.label}: anchor the name regex"
        assert re.match(r"^(\d+:)?[0-9][A-Za-z0-9.+~:-]*$", f.version), f"{f.label}: odd version"
        assert f.reference.strip(), f"{f.label}: reference required"


def test_named_vulnerabilities_have_floors():
    assert floor("PHP 8.4 runtime").version == "8.4.27-1~deb13u1"
    assert "PHP2Shell" in floor("PHP 8.4 runtime").reference
    assert floor("Brotli decoder").version == "1.1.0-2+deb13u1"
    assert "Node2Shell" in floor("Brotli decoder").reference
    assert floor("Zeek (OBS security:zeek)").version == "9.0.1-0"


def test_changelog_cites_every_enforced_advisory():
    """Docs derive from code: a floor the release notes do not explain is a bug."""
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    for f in MODULE.FLOORS:
        ids = re.findall(r"DSA-\d{4}-\d|GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}", f.reference)
        assert ids, f"{f.label}: reference names no DSA/GHSA id"
        for ident in ids:
            assert ident in changelog, f"CHANGELOG.md does not cite {ident} ({f.label})"


def test_name_patterns_match_shipped_binaries_not_neighbours():
    cases = {
        "Brotli decoder": (["libbrotli1", "python3-brotli", "brotli"], ["lua-lpeg", "libbrotlicommon"]),
        "Linux kernel": (["linux-image-amd64", "linux-image-6.12.113+deb13-amd64"], ["linux-base", "linux-libc-dev"]),
        "Firefox ESR": (["firefox-esr", "firefox-esr-l10n-de"], ["firefox", "thunderbird"]),
        "OpenSSL": (["openssl", "libssl3t64", "openssl-provider-legacy"], ["libssl-doc", "python3-openssl"]),
        "curl": (["curl", "libcurl4t64", "libcurl3t64-gnutls"], ["python3-pycurl", "curlftpfs"]),
        "Wireshark": (["wireshark", "wireshark-common", "tshark", "libwireshark18t64"], ["wireshark2", "pyshark"]),
        "BIND 9 tools": (["bind9-dnsutils", "bind9-host", "dnsutils"], ["libbind9-dev"]),
        "Unbound": (["libunbound8", "unbound", "unbound-anchor"], ["python3-unbound"]),
        "Zeek (OBS security:zeek)": (["zeek-core", "zeek", "zeek-lts"], ["zeek-btest-data", "zeek-zkg"]),
        "Node.js": (["nodejs", "libnode115"], ["node-shell-quote", "nodejs-legacy"]),
        "PHP 8.4 runtime": (["php8.4-cli", "libapache2-mod-php8.4", "php8.4"], ["php8.3-cli", "php-common"]),
    }
    for label, (yes, no) in cases.items():
        pat = re.compile(floor(label).names)
        for n in yes:
            assert pat.match(n), f"{label} should match {n}"
        for n in no:
            assert not pat.match(n), f"{label} must not match {n}"
    # lib* prefixes are open-ended on purpose: soname bumps must not silently leave the floor
    assert re.compile(floor("Wireshark").names).match("libwireshark19")


# --- absence and inventories -----------------------------------------------

def test_inventory_without_floored_packages_is_safe(tmp_path):
    inventory = tmp_path / "filesystem.packages"
    inventory.write_text("bash 5.2.15-2\n")
    checked = MODULE.check(MODULE.installed_packages(inventory, "packages"))
    assert checked and all(n == 0 for n in checked.values())


def test_other_php_runtime_rejected():
    with pytest.raises(ValueError, match="unsupported PHP runtime"):
        MODULE.check({"php8.3-cli": "8.3.0-1"})


def test_generic_php_without_runtime_rejected():
    with pytest.raises(ValueError, match="unversioned PHP packages"):
        MODULE.check({"php-common": "2:96+deb13u1"})


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
    assert MODULE.installed_packages(status, "status") == {"php8.4-cli": "8.4.27-1~deb13u1"}


def test_missing_inventory_fails_closed(tmp_path):
    with pytest.raises(OSError):
        MODULE.installed_packages(tmp_path / "missing", "packages")


def test_status_with_no_installed_packages_fails_closed(tmp_path):
    status = tmp_path / "status"
    status.write_text("Package: php8.4-cli\nStatus: deinstall ok config-files\nVersion: 8.4.26-1~deb13u1\n")
    with pytest.raises(ValueError, match="no installed packages"):
        MODULE.installed_packages(status, "status")


def test_list_prints_every_floor():
    out = subprocess.run([sys.executable, str(CHECKER), "--list"], check=True, capture_output=True, text=True).stdout
    assert out.count("\n") == len(MODULE.FLOORS)
    assert "DSA-6582-1" in out and "Node2Shell" in out


# --- version ordering, by dpkg ---------------------------------------------

@needs_dpkg
@pytest.mark.parametrize(
    "version,passes",
    [("8.4.26-1~deb13u1", False), ("8.4.27-1~deb13u1", True), ("8.4.28-1~deb13u1", True)],
)
def test_php_floor(version, passes):
    packages = {"php8.4-cli": version, "libapache2-mod-php8.4": version}
    if passes:
        MODULE.check(packages)
    else:
        with pytest.raises(ValueError, match="below Debian security floor"):
            MODULE.check(packages)


@needs_dpkg
@pytest.mark.parametrize(
    "name,version,passes",
    [
        ("libbrotli1:amd64", "1.1.0-2", False),               # the v3.0.x images
        ("libbrotli1:amd64", "1.1.0-2+deb13u1", True),        # DSA-6582-1
        ("python3-brotli", "1.1.0-2+deb13u1", True),
        ("zeek-core", "9.0.0-0", False),                      # v3.1.0 release ISO
        ("zeek-core", "9.0.1-0", True),
        ("firefox-esr", "153.5.1esr-1~deb13u1", False),       # v3.1.0 release ISO
        ("firefox-esr", "153.6.0esr-1~deb13u1", True),
        ("linux-image-amd64", "6.12.111-1", False),
        ("linux-image-6.12.113+deb13-amd64", "6.12.113-1", True),
        ("bind9-dnsutils", "1:9.20.29-1~deb13u1", False),     # epoch handled by dpkg
        ("bind9-dnsutils", "1:9.20.30-1~deb13u1", True),
    ],
)
def test_floors_by_dpkg(name, version, passes):
    packages = {name: version, "bash": "5.2.15-2"}
    if passes:
        checked = MODULE.check(packages)
        assert sum(checked.values()) == 1
    else:
        with pytest.raises(ValueError, match="below Debian security floor"):
            MODULE.check(packages)


@needs_dpkg
def test_all_violations_are_reported_together():
    with pytest.raises(ValueError) as excinfo:
        MODULE.check({"libbrotli1:amd64": "1.1.0-2", "zeek-core": "9.0.0-0"})
    msg = str(excinfo.value)
    assert "libbrotli1" in msg and "zeek-core" in msg and "DSA-6582-1" in msg


@needs_dpkg
def test_multiarch_php_runtime_is_checked():
    with pytest.raises(ValueError, match="below Debian security floor"):
        MODULE.check({"php8.4:amd64": "8.4.26-1~deb13u1"})


def test_missing_dpkg_fails_closed(monkeypatch):
    def no_dpkg(*args, **kwargs):
        raise FileNotFoundError("dpkg")
    monkeypatch.setattr(MODULE.subprocess, "run", no_dpkg)
    with pytest.raises(OSError):
        MODULE.check({"libbrotli1": "1.1.0-2+deb13u1"})
