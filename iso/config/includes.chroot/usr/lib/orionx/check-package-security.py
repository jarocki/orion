#!/usr/bin/env python3
"""Fail closed when an Orion-X image contains unpatched PHP or Linux packages.

Accept either live-build's filesystem.packages or the final dpkg status file.
The Debian version comparison is delegated to dpkg, not a lexical comparison.
"""

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

PHP_FLOOR = "8.4.27-1~deb13u1"  # DSA-6574-1, CVE-2026-109618/109619
KERNEL_FLOOR = "6.12.113-1"  # DSA-6568-1, CVE-2026-98432
KERNEL_IMAGE = re.compile(r"^linux-image-(6\.12\.[0-9]+[a-zA-Z0-9.+~-]*-amd64)(?:-unsigned)?$")
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
            status = fields.get("Status", "").split()
            # Selection (install/hold/deinstall) does not describe current state.
            if len(status) != 3 or status[2] != "installed":
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


def check(packages: dict[str, str], require_kernel: bool = False) -> list[str]:
    kernels = []
    found_versioned = False
    generic_php = False
    for name, version in packages.items():
        name = name.split(":", 1)[0]
        if re.match(r"linux-image-[0-9]", name) and not name.endswith("-dbg"):
            kernel = KERNEL_IMAGE.fullmatch(name)
            if not kernel or not re.match(r"^(?:[0-9]+:)?6\.12\.", version):
                raise ValueError(f"unsupported kernel image: {name} {version}")
            result = subprocess.run(
                ["dpkg", "--compare-versions", version, "ge", KERNEL_FLOOR],
                check=False,
            )
            if result.returncode != 0:
                raise ValueError(f"{name} {version} is below Debian kernel security floor {KERNEL_FLOOR}")
            kernels.append(kernel.group(1))
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
    if require_kernel and not kernels:
        raise ValueError("no checked versioned amd64 kernel image (metapackages/headers do not count)")
    return kernels


def stream_digest(stream) -> bytes:
    """Hash large payloads with bounded memory, including on Python 3.9 hosts."""
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.digest()


def check_kernel_payload(kernels: list[str], squashfs: Path, boot_kernel: Path) -> None:
    """Bind the ISO boot payload to a checked packaged kernel in its squashfs."""
    with boot_kernel.open("rb") as stream:
        expected = stream_digest(stream)
    if boot_kernel.stat().st_size == 0:
        raise ValueError("ISO boot kernel is empty")
    for kernel in kernels:
        # kernel is derived from the strict package-name regex, never a path.
        with subprocess.Popen(
            ["unsquashfs", "-cat", str(squashfs), f"boot/vmlinuz-{kernel}"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ) as process:
            digest = stream_digest(process.stdout)
            code = process.wait()
        if code == 0 and digest == expected:
            return
    raise ValueError("ISO /live/vmlinuz does not match a checked packaged kernel in squashfs")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--packages", type=Path, help="ISO /live/filesystem.packages")
    group.add_argument("--dpkg-status", type=Path, help="final /var/lib/dpkg/status")
    parser.add_argument("--require-kernel", action="store_true", help="require a patched Trixie amd64 kernel image")
    parser.add_argument("--squashfs", type=Path, help="shipped squashfs for boot-payload verification")
    parser.add_argument("--boot-kernel", type=Path, help="extracted ISO /live/vmlinuz")
    args = parser.parse_args()
    if bool(args.squashfs) != bool(args.boot_kernel):
        parser.error("--squashfs and --boot-kernel must be supplied together")
    path = args.packages or args.dpkg_status
    try:
        kernels = check(installed_packages(path, "packages" if args.packages else "status"),
                        require_kernel=args.require_kernel or bool(args.boot_kernel))
        if args.boot_kernel:
            check_kernel_payload(kernels, args.squashfs, args.boot_kernel)
    except (OSError, ValueError) as exc:
        print(f"ERROR: package security gate: {exc}", file=sys.stderr)
        return 1
    print(f"Package security gate PASS (PHP floor {PHP_FLOOR}; kernel floor {KERNEL_FLOOR})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
