#!/usr/bin/env python3
"""
lib/raw_write.py — root raw-device writer with HONEST progress (orionx-imager).

Runs under sudo (it needs root to write a block device). Copies <iso> to
<target> in sector-aligned chunks and prints the cumulative bytes written to
stdout after every chunk, so the GUI/CLI can show real, moving progress.

Why this exists (DEC-PHASE11-038): the previous path shelled out to
`sudo dd ...` and tried to drive the progress bar by sending SIGINFO to the dd
process. But the Popen child is *sudo*, not dd, and sudo does not forward
SIGINFO to the root dd child on macOS — so dd never emitted progress and the bar
sat at 0% until the write finished, then jumped to 100% (dishonest). Doing the
copy here, in the elevated process itself, reports exact byte counts with no
signal dependency and works identically on macOS and Linux. stdlib only.

Usage:  raw_write.py <iso_path> <target_device>
Output: one integer (cumulative bytes written) per line as it progresses,
        then a final line 'DONE'. Nonzero exit + stderr on failure.
"""
from __future__ import annotations

import os
import platform
import sys

CHUNK = 4 * 1024 * 1024  # 4 MiB — a multiple of 512, matches dd bs=4m
SECTOR = 512


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("usage: raw_write.py <iso_path> <target_device>\n")
        return 2

    iso_path, target = sys.argv[1], sys.argv[2]

    # macOS: the raw disk node (/dev/rdiskN) is far faster than the buffered
    # block node, exactly as `dd` used it.
    if platform.system() == "Darwin":
        target = target.replace("/dev/disk", "/dev/rdisk")

    if not os.path.isfile(iso_path):
        sys.stderr.write(f"ISO not found: {iso_path}\n")
        return 2

    total = os.path.getsize(iso_path)
    written = 0

    try:
        src = os.open(iso_path, os.O_RDONLY)
    except OSError as exc:
        sys.stderr.write(f"cannot open ISO: {exc}\n")
        return 1
    try:
        dst = os.open(target, os.O_WRONLY)
    except OSError as exc:
        os.close(src)
        sys.stderr.write(f"cannot open target {target}: {exc}\n")
        return 1

    try:
        while True:
            buf = os.read(src, CHUNK)
            if not buf:
                break
            # Raw block devices require sector-multiple writes; pad the final
            # short read up to the next 512-byte boundary with zeros. (The
            # device is larger than the image, so the trailing zeros are inert.)
            rem = len(buf) % SECTOR
            if rem != 0:
                buf += b"\x00" * (SECTOR - rem)
            # os.write may write fewer bytes than requested — loop until drained.
            off = 0
            n = len(buf)
            while off < n:
                off += os.write(dst, buf[off:])
            written += n
            # Report progress, clamped to the true image size (padding excluded).
            sys.stdout.write(f"{min(written, total)}\n")
            sys.stdout.flush()
        os.fsync(dst)
    except OSError as exc:
        sys.stderr.write(f"write failed at {written} bytes: {exc}\n")
        return 1
    finally:
        os.close(src)
        os.close(dst)

    sys.stdout.write("DONE\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
