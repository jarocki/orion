"""tool_fingerprint — name the scanning tool, at the producer, from one pattern authority.

# @decision DEC-PHASE13-040
# @title Tool attribution is a producer-side fingerprint with a stated confidence
# @status accepted
# @rationale Only logquery named tools, and only from an HTTP User-Agent, so
#   a Suricata alert whose signature text literally says "ET SCAN Nmap"
#   reached the Cockpit, the Attack Map and the reports as an anonymous
#   alert. Three consumers each guessing would have meant three answers
#   for one scan. Instead the producers (orionx-postured for Suricata and
#   Zeek, orionx-scanwatch for the firewall drop log) call this helper once
#   and write `detail.tool` + `detail.tool_conf`; every consumer reads that
#   field and nothing else, so the deck has one answer.
#   The regexes are not duplicated here: they are loaded from
#   scripts/logquery/intel-base.json, the file logquery already fingerprints
#   User-Agents with, so a new tool is added in one place and both paths
#   learn it. A minimal mirrored list stands in only when that file is
#   absent (marked FALLBACK below; it is the subset the issue names, not an
#   authority).
#   Confidence is a three-step enum, not a probability, because nothing here
#   is measured: `high` means the tool named itself in rule text the attacker
#   does not write (a Suricata signature); `medium` means it was named in
#   text that can echo attacker-supplied bytes (a Zeek notice message);
#   `low` means a behavioural heuristic (port order and probe rate) matched
#   a known profile. The same three words are what intel-base.json and the
#   logquery `tool_conf` column already use. When no pattern matches the
#   tool stays unset — "unknown" is a true answer and a guess is not.

The helper is stdlib-only and pure: no I/O after import, no bus access.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

# ---------------------------------------------------------------------------
# Pattern authority
# ---------------------------------------------------------------------------

# scripts/rain/ -> scripts/logquery/intel-base.json. The same relative layout
# holds on the image (/opt/orionx/scripts/<dir>/), so one path serves both.
INTEL_BASE_FILE = Path(__file__).resolve().parent.parent / "logquery" / "intel-base.json"

# FALLBACK ONLY — used when intel-base.json is missing (e.g. a trimmed build
# host). It mirrors the six signatures issue #128 names and nothing more. The
# authority is the JSON file; do not extend this list, extend that file.
_FALLBACK_SIGNATURES = (
    {"ua_regex": r"(?i)\bnmap\b", "tool": "nmap", "confidence": "high"},
    {"ua_regex": r"(?i)\bmasscan\b", "tool": "masscan", "confidence": "high"},
    {"ua_regex": r"(?i)\bzgrab\b|\bzmap\b", "tool": "zmap/zgrab", "confidence": "high"},
    {"ua_regex": r"(?i)\bnuclei\b", "tool": "nuclei", "confidence": "high"},
    {"ua_regex": r"(?i)\bnikto\b", "tool": "nikto", "confidence": "high"},
    {"ua_regex": r"(?i)\bsqlmap\b", "tool": "sqlmap", "confidence": "high"},
)

# `^...` or `(?i)^...`: a User-Agent prefix, meaningless against rule text.
_ANCHORED_RE = re.compile(r"^(?:\(\?[a-zA-Z]+\))?\^")

CONFIDENCE_LEVELS = ("low", "medium", "high")
_CONF_RANK = {c: i for i, c in enumerate(CONFIDENCE_LEVELS)}


def _load_signatures(path: Path = INTEL_BASE_FILE) -> tuple[list[tuple[re.Pattern, str, str]], str]:
    """Compile the tool signatures. Returns (patterns, origin).

    Anchored User-Agent patterns (those starting with `^`, e.g. `^curl/`)
    describe the start of a UA string and say nothing about a rule's text,
    so they are left out of free-text matching.
    """
    origin = "intel-base.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        raw = data.get("signatures") or []
        if not raw:
            raise ValueError("no signatures")
    except (OSError, ValueError, AttributeError):
        raw = list(_FALLBACK_SIGNATURES)
        origin = "fallback"
    compiled: list[tuple[re.Pattern, str, str]] = []
    for sig in raw:
        try:
            rx = str(sig["ua_regex"])
            tool = str(sig["tool"])
        except (KeyError, TypeError):
            continue
        if _ANCHORED_RE.match(rx):
            continue
        conf = str(sig.get("confidence") or "medium").lower()
        if conf not in _CONF_RANK:
            conf = "medium"
        try:
            compiled.append((re.compile(rx), tool, conf))
        except re.error:
            continue
    return compiled, origin


SIGNATURES, SIGNATURES_ORIGIN = _load_signatures()


def _cap(conf: str, ceiling: str) -> str:
    return conf if _CONF_RANK[conf] <= _CONF_RANK[ceiling] else ceiling


def fingerprint_text(text: str | None, ceiling: str = "high") -> tuple[str | None, str | None]:
    """First signature whose name appears in `text`, confidence capped at `ceiling`."""
    if not text:
        return None, None
    s = str(text)
    for rx, tool, conf in SIGNATURES:
        if rx.search(s):
            return tool, _cap(conf, ceiling)
    return None, None


# ---------------------------------------------------------------------------
# Per-producer entry points
# ---------------------------------------------------------------------------

def fingerprint_suricata(signature: str | None) -> tuple[str | None, str | None]:
    """A Suricata rule's message text. Rule text is the analyst's, not the
    attacker's, so a named tool is `high`."""
    return fingerprint_text(signature, ceiling="high")


def fingerprint_zeek(note: str | None, msg: str | None) -> tuple[str | None, str | None]:
    """A Zeek notice type plus its message. The message may quote bytes the
    remote side sent (a User-Agent, a banner), so the ceiling is `medium`."""
    return fingerprint_text(f"{note or ''} {msg or ''}".strip(), ceiling="medium")


# nmap -Pn -A against the deck's DROP policy swept 1000 ports at ~4.3
# ports/sec on the reference hardware (every probe waits out a timeout). This
# is the single home of that measured figure; orionx-scanwatch's window
# rationale cites it rather than restating it.
NMAP_DROP_POLICY_PPS = 4.3
# Band around the profile that still reads as "nmap pacing itself against a
# DROP policy": half the measured rate (a slower machine) to ~4x (-T4).
NMAP_RATE_BAND = (NMAP_DROP_POLICY_PPS * 0.5, NMAP_DROP_POLICY_PPS * 4.0)
# Fewer observed ports than this and the order carries no signal.
MIN_PORTS_FOR_ORDER = 8


def port_order(ports_in_time_order: list | None) -> str | None:
    """'sequential' | 'random' | None, from the ports as they were observed.

    Sequential means the probes walked the port space in steps of one, up or
    down (allowing an occasional retransmit or gap). Random means consecutive
    probes were almost never neighbours AND the walk changed direction about
    as often as a shuffle does — what nmap's default shuffle and masscan's
    randomisation both look like. A monotonic list with gaps (a sorted
    `ports_seen`, say) is neither, and yields None rather than a claim.
    """
    if not ports_in_time_order or len(ports_in_time_order) < MIN_PORTS_FOR_ORDER:
        return None
    try:
        ports = [int(p) for p in ports_in_time_order]
    except (TypeError, ValueError):
        return None
    pairs = list(zip(ports, ports[1:]))
    if not pairs:
        return None
    n = len(pairs)
    steps = sum(1 for a, b in pairs if 0 < abs(b - a) <= 2) / n
    ascents = sum(1 for a, b in pairs if b > a) / n
    if steps >= 0.8:
        return "sequential"
    if steps <= 0.2 and 0.3 <= ascents <= 0.7:
        return "random"
    return None


def fingerprint_scan(ports_seen: list | None, window_seconds: float | None,
                     distinct_ports: int | None,
                     rate_pps: float | None = None) -> tuple[str | None, str | None]:
    """Behavioural fingerprint for a firewall-observed port sweep.

    `ports_seen` must be in OBSERVATION order (orionx-scanwatch keeps one);
    a sorted list carries no order information and yields None. The only
    profile claimed is nmap pacing itself against a DROP policy: randomised
    order at a rate inside NMAP_RATE_BAND. It is reported `low`, because a
    scripted scanner can sit in the same band. A sequential sweep is
    tool-agnostic (nmap -r, nc, a shell loop) and stays None.
    """
    order = port_order(ports_seen)
    if order != "random":
        return None, None
    if rate_pps is None:
        try:
            if not window_seconds or float(window_seconds) <= 0 or not distinct_ports:
                return None, None
            rate_pps = float(distinct_ports) / float(window_seconds)
        except (TypeError, ValueError):
            return None, None
    lo, hi = NMAP_RATE_BAND
    if lo <= rate_pps <= hi:
        return "nmap", "low"
    return None, None


# ---------------------------------------------------------------------------
# The one call producers make
# ---------------------------------------------------------------------------

def attribute(detail: dict, ports_order: list | None = None) -> dict:
    """Set detail['tool'] and detail['tool_conf'] when a fingerprint matches.

    Never overwrites a tool already present. Dispatch is on the detail's own
    shape: `signature` (Suricata), `note` (Zeek), `distinct_ports` (scan).
    For a scan, `ports_order` is the time-ordered probe list; without it no
    order claim is made and `scan_order` is left unset. Returns `detail`.
    """
    if not isinstance(detail, dict):
        return detail
    if detail.get("tool"):
        return detail
    tool = conf = None
    if detail.get("signature") or detail.get("engine") == "suricata":
        tool, conf = fingerprint_suricata(detail.get("signature"))
    elif detail.get("note") or detail.get("engine") == "zeek":
        tool, conf = fingerprint_zeek(detail.get("note"), detail.get("msg"))
    elif "distinct_ports" in detail or "ports_seen" in detail:
        order = port_order(ports_order)
        if order:
            detail["scan_order"] = order
        tool, conf = fingerprint_scan(ports_order, detail.get("window_seconds"),
                                      detail.get("distinct_ports"))
    if tool:
        detail["tool"] = tool
        detail["tool_conf"] = conf
    return detail
