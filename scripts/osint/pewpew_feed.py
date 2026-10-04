#!/usr/bin/env python3
"""pewpew_feed — turn the Orion-X event bus into a map feed, truthfully.

@decision DEC-PHASE12-043
@title Local OSINT surface: launcher page, vendored CyberChef, local pew-pew map
@status accepted
@rationale IPew is a demo: it *invents* attacks and places them at country
  centroids chosen by a statistical model. On an incident-response deck that
  is not a flourish, it is a defect — an operator who reads an invented
  position acts on it. This module is the opposite contract. Every source on
  the map came from /run/orionx/events.jsonl, and a source only carries a
  position when a geolocation database actually answered for it. There is no
  fallback coordinate anywhere in this file, by design; see locate().

  Geolocation is deliberately absent from the base ISO (../GEOIP.txt). The
  feed therefore says, as data, that it is unlocated and why — rather than
  letting the page guess. Rule 8 of docs/RESILIENCE.md: degrade loudly and
  name the remedy.

This module is pure: it parses text and returns dicts. No I/O except the
optional MaxMind-format reader handed to it. That is what makes it testable,
and tests/unit/test_osint_surface.sh mutation-tests the one invariant that
matters.
"""

from __future__ import annotations

import ipaddress
import json
import re
import time
from typing import Any

# --- Bus -------------------------------------------------------------------
# Single authority: rain_lib.EVENT_LOG. Repeated here as a literal rather than
# imported because this module must stay importable on a build host where
# /run/orionx does not exist and rain_lib's own constants are irrelevant.
EVENT_LOG = "/run/orionx/events.jsonl"

# Where install-geoip.sh puts the databases, and the only places looked at.
GEOIP_DIR = "/var/lib/orionx/geoip"
GEOIP_COUNTRY_DB = GEOIP_DIR + "/dbip-country-lite.mmdb"
GEOIP_ASN_DB = GEOIP_DIR + "/dbip-asn-lite.mmdb"

# The remedy string the UI shows wherever geolocation is missing. One authority
# for the sentence, so the page, the feed and the --help text cannot drift.
GEOIP_REMEDY = "sudo /opt/orionx/optional/install-geoip.sh"

# Severity ordering must match rain_lib.SEVERITIES exactly.
SEVERITIES = ("info", "notice", "warning", "critical")
_SEV_RANK = {s: i for i, s in enumerate(SEVERITIES)}

# How far back the map looks, and how many sources/tracers it will render.
DEFAULT_WINDOW_SECONDS = 900.0
MAX_SOURCES = 64
MAX_TRACERS = 300

# Keys in an event's `detail` that may legitimately hold a source address.
# scanwatch writes src_ip (scripts/rain/orionx-scanwatch:build_detail);
# postured's Suricata and Zeek paths write src or src_ip depending on the
# alert shape. All three are read; nothing else is guessed at.
SRC_KEYS = ("src_ip", "src", "source_ip", "srcip")


# ===========================================================================
# PURE: address classification
# ===========================================================================

# Scopes are facts about the address itself, derivable with no database and
# no network. This is the layer of truth that survives having no GeoIP.
SCOPES = ("loopback", "private", "cgnat", "link-local", "multicast",
          "reserved", "public")

# RFC1918 (and IPv6 ULA) are spelled out rather than taken from
# ipaddress.is_private, which is deliberately broader: Python counts the
# RFC5737 documentation ranges (192.0.2.0/24, 198.51.100.0/24,
# 203.0.113.0/24), 6to4 relay space and several other special-purpose blocks
# as "private" too. Telling an operator that 203.0.113.45 is "coming from
# inside the house" would be wrong in a way that changes what they do next.
# Documentation and other special-purpose space lands in `reserved`, which is
# its own, true, and quite interesting answer.
_PRIVATE = tuple(ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"))
_CGNAT = tuple(ipaddress.ip_network(n) for n in ("100.64.0.0/10",))


def _in(addr, nets) -> bool:
    return any(addr.version == n.version and addr in n for n in nets)


def classify_ip(raw: str) -> dict[str, Any]:
    """Classify an address string. Never raises; never guesses a location."""
    text = str(raw).strip()
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return {"ip": text, "valid": False, "scope": "invalid",
                "version": None, "geolocatable": False}

    if addr.is_loopback:
        scope = "loopback"
    elif addr.is_link_local:
        scope = "link-local"
    elif addr.is_multicast:
        scope = "multicast"
    elif _in(addr, _CGNAT):
        scope = "cgnat"
    elif _in(addr, _PRIVATE):
        scope = "private"
    elif addr.is_global:
        scope = "public"
    else:
        # Documentation ranges, benchmark space, 0.0.0.0, reserved blocks.
        scope = "reserved"

    # Only a globally routable address can meaningfully have a geolocation.
    # Saying a 192.168.x.x host is "in Ireland" is the same lie as inventing
    # coordinates, so it is ruled out here rather than at render time.
    return {"ip": str(addr), "valid": True, "scope": scope,
            "version": addr.version, "geolocatable": scope == "public"}


# ===========================================================================
# PURE: location — the one invariant this whole feature rests on
# ===========================================================================

def _unlocated(reason: str) -> dict[str, Any]:
    """The only shape an unlocated source may take.

    There is exactly one rule in this module and it is here: when the answer
    to "where is this address" is not known, the result carries
    "located": False and NO coordinate keys at all. Not 0,0. Not a country
    centroid. Not the middle of the ocean. Nothing a renderer could mistake
    for a position.

    tests/unit/test_osint_surface.sh mutates this function and asserts the
    suite goes red. If you are reading this because that test failed: the
    test is right.
    """
    return {"located": False, "reason": reason, "remedy": GEOIP_REMEDY}


def locate(ip: str, reader: Any = None, asn_reader: Any = None) -> dict[str, Any]:
    """Look an address up in an open MaxMind-format reader, or report why not.

    `reader` is anything with a .country(ip) returning a mapping shaped like
    maxminddb's output. It is passed in rather than opened here so the pure
    layer stays pure and the test can hand in a fake.
    """
    info = classify_ip(ip)
    if not info["valid"]:
        return _unlocated("not-an-ip-address")
    if not info["geolocatable"]:
        # A private/loopback/CGNAT address has no public location to find.
        # That is a complete answer, not a degraded one — hence no remedy.
        out = _unlocated("address-is-" + info["scope"])
        out.pop("remedy", None)
        return out
    if reader is None:
        return _unlocated("no-geoip-database")

    try:
        record = reader.country(info["ip"])
    except Exception:                                    # noqa: BLE001
        # A corrupt or truncated database must not take the map down, and
        # must not silently look like "this IP is unlocated".
        return _unlocated("geoip-lookup-failed")

    country = None
    name = None
    if isinstance(record, dict):
        node = record.get("country") or record.get("registered_country") or {}
        if isinstance(node, dict):
            country = node.get("iso_code")
            names = node.get("names")
            if isinstance(names, dict):
                name = names.get("en")

    if not country:
        # The database answered, and its answer was "I do not know". That is
        # still unlocated. DB-IP Lite has real gaps; pretending otherwise is
        # the same defect as having no database at all.
        return _unlocated("not-in-geoip-database")

    out: dict[str, Any] = {
        "located": True,
        "country": str(country),
        "country_name": str(name) if name else str(country),
        "source": "geoip-country-database",
    }
    if asn_reader is not None:
        try:
            asn_rec = asn_reader.asn(info["ip"])
        except Exception:                                # noqa: BLE001
            asn_rec = None
        if isinstance(asn_rec, dict):
            num = asn_rec.get("autonomous_system_number")
            org = asn_rec.get("autonomous_system_organization")
            if num:
                out["asn"] = "AS%s" % num
            if org:
                out["as_org"] = str(org)
    return out


# ===========================================================================
# PURE: bus parsing
# ===========================================================================

def extract_source_ip(event: dict[str, Any]) -> str | None:
    """Pull a source address out of an event's structured detail.

    Only `detail` is read. The message string is deliberately NOT regexed for
    something that looks like an IP: a message is prose written for a human,
    and "blocked 203.0.113.9 reaching 10.0.0.1" would hand the map whichever
    address the regex happened to hit first. Structured detail or nothing.
    """
    detail = event.get("detail")
    if not isinstance(detail, dict):
        return None
    for key in SRC_KEYS:
        value = detail.get(key)
        if isinstance(value, str) and value.strip():
            info = classify_ip(value)
            if info["valid"]:
                return info["ip"]
    return None


def parse_event(line: str) -> dict[str, Any] | None:
    """Parse one JSONL bus line. Returns None for anything unusable."""
    text = line.strip()
    if not text:
        return None
    try:
        event = json.loads(text)
    except (ValueError, TypeError):
        return None
    if not isinstance(event, dict):
        return None
    ts = event.get("ts")
    if not isinstance(ts, (int, float)):
        return None
    sev = str(event.get("severity", "notice")).lower().strip()
    return {
        "ts": float(ts),
        "severity": sev if sev in _SEV_RANK else "notice",
        "source": str(event.get("source", "unknown")),
        "category": str(event.get("category", "general")),
        "message": str(event.get("message", "")),
        "detail": event.get("detail") if isinstance(event.get("detail"), dict) else {},
        "src_ip": extract_source_ip(event),
    }


def _detail_ports(detail: dict[str, Any]) -> int:
    value = detail.get("distinct_ports")
    return int(value) if isinstance(value, int) and value > 0 else 0


def _detail_protocols(detail: dict[str, Any]) -> list[str]:
    """Protocols from a detail blob, whichever separator the emitter used.

    scanwatch writes "/".join(sorted(protos)) — "tcp/udp" — not a list and
    not comma-separated (scripts/rain/orionx-scanwatch:ScanTracker.observe).
    Splitting on commas alone produced the single protocol "tcp/udp", which
    rendered as one meaningless label. Both separators are accepted, and a
    list is accepted too, because a future emitter is as likely to send one.
    """
    value = detail.get("protocols")
    if isinstance(value, str):
        parts = re.split(r"[,/]", value)
        return [p for p in (x.strip().lower() for x in parts) if p]
    if isinstance(value, (list, tuple)):
        return [str(p).strip().lower() for p in value if str(p).strip()]
    return []


# ===========================================================================
# PURE: the feed
# ===========================================================================

def build_feed(lines, now: float | None = None,
               window: float = DEFAULT_WINDOW_SECONDS,
               reader: Any = None, asn_reader: Any = None,
               geoip_state: dict[str, Any] | None = None) -> dict[str, Any]:
    """Build the whole map feed from an iterable of raw bus lines.

    The returned dict is the complete contract with orionx-pewpew.html. Its
    two load-bearing properties:

      * every `sources[*]` entry came from a real event, and
      * a source carries coordinates or a country ONLY inside its `location`
        object and ONLY when `location.located` is true.

    Events that carry no source address are not dropped — they are counted in
    `unattributed` and listed in `recent_unattributed`, because "17 Suricata
    alerts the map cannot attribute to an address" is information the
    operator needs, and silently showing 0 tracers for them is the exact
    failure this file exists to avoid.
    """
    now = time.time() if now is None else float(now)
    cutoff = now - float(window)

    sources: dict[str, dict[str, Any]] = {}
    tracers: list[dict[str, Any]] = []
    unattributed: list[dict[str, Any]] = []
    parsed = malformed = 0
    dropped_sources: set[str] = set()

    for line in lines:
        event = parse_event(line)
        if event is None:
            if str(line).strip():
                malformed += 1
            continue
        parsed += 1
        if event["ts"] < cutoff:
            continue

        ip = event["src_ip"]
        if ip is None:
            unattributed.append({
                "ts": event["ts"], "severity": event["severity"],
                "category": event["category"], "source": event["source"],
                "message": event["message"][:160],
            })
            continue

        entry = sources.get(ip)
        if entry is None:
            if len(sources) >= MAX_SOURCES:
                # Bounded, like ScanTracker: a spoofed-source flood must not
                # grow this dict without limit. Dropped sources are counted
                # so the page can say so instead of quietly showing 64 and
                # letting the operator believe that is all of them.
                dropped_sources.add(ip)
                continue
            entry = sources[ip] = {
                "ip": ip,
                "events": 0,
                "first_seen": event["ts"],
                "last_seen": event["ts"],
                "max_severity": event["severity"],
                "distinct_ports": 0,
                "protocols": [],
                "detectors": [],
                "categories": [],
                "kinds": [],
            }
            entry.update({k: v for k, v in classify_ip(ip).items() if k != "ip"})
            entry["location"] = locate(ip, reader=reader, asn_reader=asn_reader)

        entry["events"] += 1
        entry["first_seen"] = min(entry["first_seen"], event["ts"])
        entry["last_seen"] = max(entry["last_seen"], event["ts"])
        if _SEV_RANK[event["severity"]] > _SEV_RANK[entry["max_severity"]]:
            entry["max_severity"] = event["severity"]

        detail = event["detail"]
        entry["distinct_ports"] = max(entry["distinct_ports"], _detail_ports(detail))
        for proto in _detail_protocols(detail):
            if proto not in entry["protocols"]:
                entry["protocols"].append(proto)
        for key, field in (("detector", "detectors"), ("scan_kind", "kinds")):
            value = detail.get(key)
            if isinstance(value, str) and value and value not in entry[field]:
                entry[field].append(value)
        if event["source"] and event["source"] not in entry["detectors"]:
            entry["detectors"].append(event["source"])
        if event["category"] not in entry["categories"]:
            entry["categories"].append(event["category"])

        tracers.append({
            "ts": event["ts"], "ip": ip, "severity": event["severity"],
            "category": event["category"],
            "port": detail.get("latest_dport"),
        })

    tracers.sort(key=lambda t: t["ts"])
    ordered = sorted(sources.values(),
                     key=lambda s: (-_SEV_RANK[s["max_severity"]], -s["events"], s["ip"]))
    located = sum(1 for s in ordered if s["location"]["located"])

    state = dict(geoip_state or {"available": False, "reason": "not-checked"})
    return {
        "schema": 1,
        "generated": now,
        "window_seconds": float(window),
        "sources": ordered,
        "tracers": tracers[-MAX_TRACERS:],
        "unattributed": len(unattributed),
        "recent_unattributed": unattributed[-20:],
        "counts": {
            "events_parsed": parsed,
            "malformed_lines": malformed,
            "sources": len(ordered),
            "located": located,
            "unlocated": len(ordered) - located,
            "sources_dropped": len(dropped_sources),
            "sources_capped": bool(dropped_sources),
            "max_sources": MAX_SOURCES,
        },
        "geoip": state,
        # Echoed so the page never hardcodes the sentence twice.
        "geoip_remedy": GEOIP_REMEDY,
    }
