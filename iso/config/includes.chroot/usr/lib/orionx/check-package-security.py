#!/usr/bin/env python3
"""Fail closed when an Orion-X image ships a package below a Debian security floor.

Accept either live-build's filesystem.packages or the final dpkg status file.
The Debian version comparison is delegated to dpkg, not a lexical comparison.

@decision DEC-PHASE13-027
@title One floor table for every security promise the release notes make
@status accepted
@rationale v3.0.1 added this gate for one advisory (DSA-6574-1, the PHP2Shell
  runtime bugs). By v3.1.1 the release notes had to promise more: the Brotli
  decoder bug behind Node2Shell (CVE-2026-111497) lives in libbrotli1, which
  curl and Firefox link; Zeek 9.0.1 closed ten analyser advisories the same
  week; firefox-esr took 145 CVEs two days after v3.1.0 was cut. A promise
  the gate does not check is a claim, not a fact (CLAUDE.md: docs are claims,
  not proof). So the floors are a table in this one file, read by the build
  hook (0890), build-iso.sh, the content-presence gate, the signed-staging
  script and CI. Each entry names the advisory it enforces, and
  tests/unit/test_package_security.py asserts that CHANGELOG.md cites every
  one of them, so the notes cannot name a fix the image does not carry and
  the gate cannot enforce a floor the notes do not explain.
  Absence stays safe: a floor applies only to packages that are present. The
  image does not ship PHP or Node.js, and the gate says so rather than
  failing on what is not there. Comparison stays with dpkg: a Debian host or
  container is the only place this runs for real, and a Python re-
  implementation would be a second authority on version order.
"""

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Floor:
    label: str          # what the operator reads
    names: str          # regex over the binary package name, arch suffix removed
    version: str        # minimum Debian version that carries the fix
    reference: str      # the advisory this floor enforces (cited in CHANGELOG.md)


# Floors are Debian 13 (trixie) versions unless the reference says otherwise.
# Add a row when the release notes promise a fix; never lower a row.
FLOORS: tuple[Floor, ...] = (
    Floor("PHP 8.4 runtime", r"^(?:php|libphp|libapache2-mod-php)8\.4(?:-.*)?$",
          "8.4.27-1~deb13u1", "DSA-6574-1 (PHP2Shell, CVE-2026-109618, CVE-2026-109619)"),
    Floor("Brotli decoder", r"^(?:libbrotli1|libbrotli-dev|python3-brotli|brotli)$",
          "1.1.0-2+deb13u1", "DSA-6582-1 (Node2Shell, CVE-2026-111497)"),
    Floor("Node.js", r"^(?:nodejs|nodejs-doc|libnode\d+|libnode-dev)$",
          "20.19.2+dfsg-1+deb13u3", "DSA-6517-1"),
    Floor("Linux kernel", r"^linux-image-.*$",
          "6.12.113-1", "DSA-6568-1"),
    Floor("Firefox ESR", r"^firefox-esr(?:-l10n-.*)?$",
          "153.6.0esr-1~deb13u1", "DSA-6590-1"),
    Floor("OpenSSL", r"^(?:openssl|openssl-provider-legacy|libssl3t64|libssl-dev)$",
          "3.5.7-1~deb13u3", "DSA-6531-1"),
    Floor("curl", r"^(?:curl|libcurl[34]t64(?:-gnutls|-nss)?|libcurl4-(?:gnutls|nss|openssl)-dev)$",
          "8.14.1-2+deb13u7", "DSA-6558-1"),
    Floor("Expat", r"^(?:expat|libexpat1|libexpat1-dev)$",
          "2.9.0-1~deb13u1", "DSA-6566-1"),
    Floor("xz / liblzma", r"^(?:xz-utils|liblzma5|liblzma-dev|xzdec)$",
          "5.8.1-1+deb13u2", "DSA-6549-1"),
    Floor("Wireshark", r"^(?:wireshark(?:-.*)?|tshark|libwireshark.*|libwiretap.*|libwsutil.*)$",
          "4.4.19-0+deb13u1", "DSA-6541-1"),
    Floor("BIND 9 tools", r"^(?:bind9(?:-.*)?|dnsutils)$",
          "1:9.20.30-1~deb13u1", "DSA-6576-1"),
    Floor("Unbound", r"^(?:unbound(?:-.*)?|libunbound\d+)$",
          "1.26.2-0+deb13u1", "DSA-6581-1"),
    Floor("Zeek (OBS security:zeek)", r"^zeek(?:-core|-lts|-\d.*|-core-dev)?$",
          "9.0.1-0", "Zeek 9.0.1 (2026-10-26; GHSA-85jg-jxjg-3rvh and nine more)"),
)

# PHP runtimes other than 8.4 have no floor here and are refused outright:
# Debian 13 ships only php8.4, so any other series came from somewhere else.
PHP_RUNTIME = re.compile(r"^(?:php|libphp|libapache2-mod-php)(\d+\.\d+)(?:-|$)")


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
        if not packages:
            raise ValueError("dpkg status has no installed packages")
    return packages


def base_name(name: str) -> str:
    """'libbrotli1:amd64' -> 'libbrotli1'; dpkg names never contain ':' otherwise."""
    return name.split(":", 1)[0]


def version_at_least(version: str, floor: str) -> bool:
    """Debian ordering, by dpkg. A missing dpkg is an OSError: the gate must not guess."""
    result = subprocess.run(["dpkg", "--compare-versions", version, "ge", floor], check=False)
    if result.returncode not in (0, 1):
        raise OSError(f"dpkg --compare-versions failed (rc={result.returncode})")
    return result.returncode == 0


def check(packages: dict[str, str]) -> dict[str, int]:
    """Raise ValueError on the first floor violation set; return {label: packages checked}."""
    problems: list[str] = []
    checked: dict[str, int] = {}

    # PHP: refuse runtimes Debian 13 does not ship, and unversioned php-*
    # packages that imply a runtime the inventory does not show.
    found_runtime = False
    generic_php = False
    for name in packages:
        base = base_name(name)
        match = PHP_RUNTIME.match(base)
        if match:
            found_runtime = True
            if match.group(1) != "8.4":
                problems.append(f"unsupported PHP runtime package: {name} {packages[name]}")
        elif base == "php" or base.startswith("php-") or base == "libapache2-mod-php":
            generic_php = True
    if generic_php and not found_runtime:
        problems.append("unversioned PHP packages present without a checked PHP runtime")

    for floor in FLOORS:
        pattern = re.compile(floor.names)
        count = 0
        for name, version in packages.items():
            if not pattern.match(base_name(name)):
                continue
            count += 1
            if not version_at_least(version, floor.version):
                problems.append(
                    f"{name} {version} is below Debian security floor {floor.version}"
                    f" [{floor.label}; {floor.reference}]"
                )
        checked[floor.label] = count

    if problems:
        raise ValueError("; ".join(problems))
    return checked


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--packages", type=Path, help="ISO /live/filesystem.packages")
    group.add_argument("--dpkg-status", type=Path, help="final /var/lib/dpkg/status")
    group.add_argument("--list", action="store_true", help="print the floor table and exit")
    args = parser.parse_args()
    if args.list:
        for floor in FLOORS:
            print(f"{floor.label}\t{floor.version}\t{floor.reference}\t{floor.names}")
        return 0
    path = args.packages or args.dpkg_status
    try:
        checked = check(installed_packages(path, "packages" if args.packages else "status"))
    except (OSError, ValueError) as exc:
        print(f"ERROR: package security gate: {exc}", file=sys.stderr)
        return 1
    present = {label: n for label, n in checked.items() if n}
    absent = [label for label, n in checked.items() if not n]
    print(
        f"Package security gate PASS: {len(FLOORS)} floors, "
        f"{sum(present.values())} shipped packages at or above floor "
        f"({', '.join(f'{k} x{v}' for k, v in present.items())}); "
        f"not shipped, so not exposed: {', '.join(absent) or 'none'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
