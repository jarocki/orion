#!/usr/bin/env python3
"""
Orion-X XFCE panel widget — mesh status (xfce4-genmon-plugin format).

Reads the root-written snapshot /run/orionx/mesh-status.json through
helpers/mesh_data (DEC-PHASE12-067) and prints that verdict:
  "◆ 3 peers"        — mesh joined, 3 peers with a live handshake
  "◆ stale (95 s)"   — the snapshot stopped updating; the count is not trusted
  "— (no snapshot)"  — orionx-mesh-status.timer is not writing one
  "—"                — mesh not joined

No sudo: genmon has no tty, and the rc8/rc9 panel showed "—" while wg0 was
up because `sudo orionx-mesh status` failed silently every 5 s.

@decision DEC-PHASE12-067
@title One mesh verdict, from the root-written snapshot, for every surface
@status accepted
@rationale See helpers/mesh_data.py.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See control_center/helpers/subprocess_runner.py for full rationale.
"""
from __future__ import annotations

import os
import sys
import time

# realpath: genmon may call us through a symlink (same rule as the launcher).
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__)))))
from control_center.helpers import mesh_data as M  # noqa: E402


def render(snap_path=M.SNAPSHOT, now: float | None = None) -> str:
    """The genmon markup for this snapshot. Pure apart from reading the file."""
    now = time.time() if now is None else now
    s = M.mesh_summary(M.load_snapshot(snap_path, now=now), now,
                       wg_up=M.sysfs_bytes() is not None)
    return f"<txt>{s['short']}</txt>\n<tool>{s['text']}</tool>"


def main() -> None:
    print(render())


if __name__ == "__main__":
    main()
    sys.exit(0)
