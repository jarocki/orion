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

@decision DEC-PHASE12-039
@title Self-status never counts as a scan, whatever source emits it
@status accepted
@rationale This widget is a threat-shaped integer sitting permanently in the
  operator's panel, and it had the same hole DEC-PHASE12-034 closed in the
  Cockpit's pressure() gauge: no self-status exclusion. Two concrete gaps.

  1. The docstring above claims "posture/health events do NOT count". That was
     true only of the Control Center's own emitters. It was never enforced —
     there was no exclusion set at all, only the two positive arms below — so
     any self-diagnosis filed under a counted category was counted. The deck
     reporting "I have no IDS rules" read to the operator as "N scans seen."

  2. The source arm was unconditional: ANY event from suricata/zeek/nucleotide
     counted regardless of category. So the first `--source zeek --category
     health` event ("zeek ingest down") would have become a scan with no
     category able to stop it. iso/.../optional/install-zeek.sh already picks
     category `tooling` specifically to dodge this widget, which shows the
     hazard was known at one call site and undefended here.

  Both are closed by one rule: a self-status category is never a scan, and the
  exclusion is applied BEFORE either positive arm, so it cannot be routed
  around by source. The policy itself is owned by cockpit_lib.py; this file
  carries a copy only because the Control Center import allowlist is
  json/pathlib/subprocess and cannot reach it. test_control_center.sh asserts
  the two sets are identical, so the copy cannot silently drift.

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

# MIRROR of rain_lib.STATUS_CATEGORIES (scripts/rain/rain_lib.py), which is
# the single authority since DEC-PHASE12-040. cockpit_lib derives from the
# same place; this is a copy only because the Control Center widget import
# allowlist is json/pathlib/subprocess. The invariant test in
# tests/unit/test_control_center.sh fails if they diverge — edit the
# authority, not this line.
_SELF_STATUS_CATEGORIES = {"health", "posture", "service", "tooling", "heal",
                           "capture", "intel", "general"}


def is_scan_event(category: str, source: str) -> bool:
    """True if this event is an external detection, not the deck's own status.

    The self-status gate runs FIRST and applies to both arms: a health event
    from a detector source is still a health event. Pure, so the suite can
    prove the behaviour instead of grepping for the constant.
    """
    cat = str(category or "").lower()
    src = str(source or "").lower()
    if cat in _SELF_STATUS_CATEGORIES:
        return False
    return cat in _SCAN_CATEGORIES or src in _SCAN_SOURCES


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
                if is_scan_event(ev.get("category", ""), ev.get("source", "")):
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
