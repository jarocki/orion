#!/usr/bin/env python3
"""
Orion-X XFCE panel widget — scans count (xfce4-genmon-plugin format).

Live count of scan/IDS events observed THIS SESSION on the Orion-X event bus
(/run/orionx/events.jsonl — the single event authority R.A.I.N. and the Cockpit
also read). The bus lives on tmpfs, so "this session" is the natural window and
needs no clock (the Control Center import allowlist has no `time`).

Counted: events whose category is ids/scan/recon/probe, or whose source is
suricata/zeek/nucleotide — i.e. whatever the Tier-1 detection layer publishes.
Until the W10-5 detection daemon ships, the count reflects whatever emits onto
the bus (Control Center posture/health events do NOT count). Output "◎ 0" on a
quiet deck, never "?": a real zero is information, a placeholder is not.

@decision DEC-PHASE12-010
@title Panel scan/client widgets read real data (event bus / neighbour table)
@status accepted
@rationale The "?" placeholders (DEC-PHASE10-005) shipped for two releases and
  read as broken on hardware. Both widgets now draw from data the deck already
  has: scans from the event bus, clients from the ARP/neighbour table. No new
  daemon, no privileges, allowlist-safe (json/pathlib/subprocess only).

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

EVENT_LOG = Path("/run/orionx/events.jsonl")
_SCAN_CATEGORIES = {"ids", "scan", "recon", "probe"}
_SCAN_SOURCES = {"suricata", "zeek", "nucleotide"}


def count_scans(path: Path = EVENT_LOG) -> int:
    """Number of scan/IDS events on the bus. Missing/unreadable bus -> 0."""
    n = 0
    try:
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(ev, dict):
                    continue
                cat = str(ev.get("category", "")).lower()
                src = str(ev.get("source", "")).lower()
                if cat in _SCAN_CATEGORIES or src in _SCAN_SOURCES:
                    n += 1
    except OSError:
        return 0
    return n


def main() -> None:
    # ◎ (U+25CE) renders in the panel font (DEC-PHASE12-005). genmon renders
    # only <txt>…</txt>; <tool> adds a hover tooltip.
    n = count_scans()
    print(f"<txt>◎ {n}</txt>")
    print(f"<tool>{n} scan/IDS event(s) this session on the Orion-X event bus</tool>")


if __name__ == "__main__":
    main()
    sys.exit(0)
