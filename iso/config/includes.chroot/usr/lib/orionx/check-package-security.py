#!/usr/bin/env python3
"""Fail closed when an Orion-X image contains unpatched PHP runtime packages.

Accept either live-build's filesystem.packages or the final dpkg status file.
The Debian version comparison is delegated to dpkg, not a lexical comparison.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


PHP_FLOOR = "8.4.27-1~deb13u1"  # DSA-6574-1, CVE-2026-109618/109619
VERSIONED_PHP = re.compile(r"^(?:php|libphp|libapache2-mod-php)(\d+\.\d+)(?:-|:|$)")


def installed_packages(path: Path, fmt: str) -> dict[str, str]:
    content = path.read_text(encoding="utf-8")
    if not content.strip():
        raise ValueError("package inventory is empty")
    packages: dict[str, str] = {}
    if fmt == "packages":
        for line in content.splitlines():
            fields = line.split()
            if len(fields) != 2:
                raise ValueError(f"malformed filesystem.packages entry: {line!r}")
            name, version = fields
            if name in packages and packages[name] != version:
                raise ValueError(f"conflicting versions of {name}")
            packages[name] = version
    else:
        for paragraph in content.split("\n\n"):
            fields = {}
            for line in paragraph.splitlines():
                if line.startswith((" ", "\t")):
                    continue
                if ": " in line:
                    key, value = line.split(": ", 1)
                    fields[key] = value
            if fields.get("Status") != "install ok installed":
                continue
            name, version = fields.get("Package"), fields.get("Version")
            if not name or not version:
                raise ValueError("installed dpkg entry lacks Package or Version")
            if name in packages and packages[name] != version:
                raise ValueError(f"conflicting versions of {name}")
            packages[name] = version
    return packages


def check(packages: dict[str, str]) -> None:
    found_versioned = False
    generic_php = False
    for name, version in packages.items():
        match = VERSIONED_PHP.match(name)
        if match:
            found_versioned = True
            if match.group(1) != "8.4":
                raise ValueError(f"unsupported PHP runtime package: {name} {version}")
            result = subprocess.run(
                ["dpkg", "--compare-versions", version, "ge", PHP_FLOOR],
                check=False,
            )
            if result.returncode != 0:
                raise ValueError(f"{name} {version} is below Debian security floor {PHP_FLOOR}")
        elif name == "php" or name.startswith("php-") or name == "libapache2-mod-php":
            generic_php = True
    if generic_php and not found_versioned:
        raise ValueError("unversioned PHP packages present without a checked PHP runtime")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--packages", type=Path, help="ISO /live/filesystem.packages")
    group.add_argument("--dpkg-status", type=Path, help="final /var/lib/dpkg/status")
    args = parser.parse_args()
    path = args.packages or args.dpkg_status
    try:
        check(installed_packages(path, "packages" if args.packages else "status"))
    except (OSError, ValueError) as exc:
        print(f"ERROR: PHP package security gate: {exc}", file=sys.stderr)
        return 1
    print(f"PHP package security gate PASS (floor {PHP_FLOOR}; absence is safe)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
