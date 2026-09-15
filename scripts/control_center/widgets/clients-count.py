#!/usr/bin/env python3
"""
Orion-X XFCE panel widget — clients count (xfce4-genmon-plugin format).

Live count of network clients observed around the deck: entries in the IPv4
neighbour (ARP) table that have resolved to a hardware address and are not in a
FAILED/INCOMPLETE state — the hosts that have actually exchanged traffic with us.
Non-privileged (`ip -4 neigh show`), no daemon required.

Output "◉ 0" when nothing has spoken to us, never "?": a real zero is
information, a placeholder is not.

@decision DEC-PHASE12-010
@title Panel scan/client widgets read real data (event bus / neighbour table)
@status accepted
@rationale See scans-count.py. `ip neigh` is the cheapest truthful "who is on
  this segment" signal available without a sniffer; the W10-5 detection daemon
  can later publish a richer count onto the event bus and this widget can move
  to it without changing the panel surface.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import subprocess
import sys

_DEAD_STATES = ("FAILED", "INCOMPLETE")


def count_clients(neigh_output: str) -> int:
    """Count neighbour entries with a lladdr and a live state."""
    n = 0
    for line in neigh_output.splitlines():
        if "lladdr" not in line:
            continue
        if any(state in line for state in _DEAD_STATES):
            continue
        n += 1
    return n


def _read_neigh() -> str:
    try:
        out = subprocess.run(
            ["ip", "-4", "neigh", "show"],
            capture_output=True, text=True, timeout=3,
        )
        return out.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def main() -> None:
    # ◉ (U+25C9) renders in the panel font (DEC-PHASE12-005).
    n = count_clients(_read_neigh())
    print(f"<txt>◉ {n}</txt>")
    print(f"<tool>{n} LAN client(s) seen in the neighbour table</tool>")


if __name__ == "__main__":
    main()
    sys.exit(0)
