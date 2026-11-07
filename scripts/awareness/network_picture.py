#!/usr/bin/env python3
"""network_picture — what THIS deck has passively observed on the segment it sits on.

One reader, two surfaces (DEC-PHASE12-049 pattern, as deck_vitals.py): the
Cockpit NETWORK panel draws the headline from collect(); the Workbench
"This network" page renders the whole dict from /api/network.json. Neither
surface reads `ip neigh`, a Zeek log or the OUI table itself, so the two
cannot disagree about what was seen.

Inputs, all already on the image (issue #93):
  * `ip neigh`                — the ARP/NDP table (who has exchanged frames with us)
  * Zeek conn/dns/dhcp/ssdp   — found through zeek_logs.py, the same discovery
                                orionx-postured uses, never a second path list
  * ieee-data OUI database    — /usr/share/ieee-data (a dependency of aircrack-ng)

Parsers are PURE (text in, dict out) and provable against fixtures with no
root, no network and no display. collect() wraps them with thin readers and
NEVER raises. Reads only: nothing here transmits a frame or changes the system.
Active work (#94: gateway identity, posture-gated probes) hangs off the
extension point at the bottom of this file and is NOT part of the picture.

# @decision DEC-PHASE13-046
# @title The network picture is labelled "observed by this deck", windowed, never geolocated, and degrades by naming the missing log
# @status accepted
# @rationale A passive sensor on one segment sees a sample, not the network. The
#   honest wording is a contract every surface must keep, so it is fixed here
#   and tested (tests/unit/test_network_picture.sh), not left to each page:
#     1. Every count carries its window and the label OBSERVED_LABEL
#        ("observed by this deck"). No surface ever claims to count the hosts
#        that are ON the segment: this deck cannot know what it did not hear.
#     2. No geolocation anywhere. Addresses are classified local / internet by
#        RFC 1918 / ULA / link-local membership and nothing else; there is no
#        country, city or coordinate field, and the page says so.
#     3. Zeek is optional and may be absent, unreadable or late (DEC-PHASE12-028).
#        Without it the picture falls back to `ip neigh` + OUI and every row
#        that needed a Zeek log is reported as state "unknown" naming that log,
#        never silently as zero. A row that had its log and saw nothing is
#        "absent": absence of evidence is a finding, missing evidence is not.
#     4. OUI vendor is a registry lookup, and a randomised (locally
#        administered) address has no vendor; the row says which. IoT is a
#        HEURISTIC from vendor hints and mDNS service names and is labelled so.
#     5. The engine is bounded (DEC-PHASE12-034 contract): log reads are
#        tail-capped per file, filtered to the window, cut by a time budget,
#        and host lists are capped. When a cap bites, the dict says so and the
#        counts are declared a lower bound rather than presented as complete.
"""
from __future__ import annotations

import argparse
import csv
import ipaddress
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deck_vitals  # noqa: E402  (DEC-PHASE12-049: the deck's own addresses, one authority)
import zeek_logs  # noqa: E402  (shared with orionx-postured: one list of Zeek log directories)

SCHEMA = 1
DECISION = "DEC-PHASE13-046"
OBSERVED_LABEL = "observed by this deck"

WINDOW_SECONDS = 900.0           # the Cockpit's window; the page defaults to the same
WINDOW_MIN = 60.0
WINDOW_MAX = 86400.0
BUDGET_SECONDS = 1.5             # log parsing stops here; the Cockpit polls every 5 s
MAX_HOSTS = 256
MAX_ARP_ROWS = 256
MAX_SIGHTING_HOSTS = 12
MAX_SAMPLES = 6

ZEEK_LOGS = ("conn.log", "dns.log", "dhcp.log", "ssdp.log")
# Per-log tail caps. conn.log is the big one; on a busy segment 1 MiB is a few
# thousand records, which is more than a 15-minute window on a home or SOHO
# network and enough to say "lower bound" honestly on a larger one.
TAIL_BYTES = {"conn.log": 1 << 20, "dns.log": 512 << 10,
              "dhcp.log": 256 << 10, "ssdp.log": 256 << 10}

OUI_SOURCES = (
    "/usr/share/ieee-data/oui.txt",          # ieee-data (Debian), MA-L registry
    "/usr/share/ieee-data/oui.csv",
    "/usr/share/nmap/nmap-mac-prefixes",     # nmap's copy, if ieee-data is ever dropped
)
INSTALL_ZEEK = "sudo /opt/orionx/optional/install-zeek.sh"

NETBIOS_UDP = frozenset({137, 138})
NETBIOS_TCP = frozenset({139, 445})
LLMNR_PORT = 5355
MDNS_PORT = 5353
LDAP_TCP = frozenset({389, 636})
SSDP_PORT = 1900
DHCP_UDP = frozenset({67, 68})

# Sighting classes, what evidence each needs and why an operator cares.
# `needs` lists the logs that can show it; the first that is present decides
# present/absent, and when none is present the row is "unknown" naming them.
SIGHTINGS: dict[str, dict[str, Any]] = {
    "wpad": {"label": "WPAD", "needs": ("dns.log",),
             "why": "a client asking for wpad.* will take proxy settings from whoever answers"},
    "netbios": {"label": "NetBIOS / SMB", "needs": ("conn.log", "dns.log"),
                "why": "legacy Windows name service and file sharing (137-139, 445)"},
    "llmnr": {"label": "LLMNR", "needs": ("dns.log", "conn.log"),
              "why": "link-local name resolution (5355): spoofable, a classic credential-capture vector"},
    "mdns": {"label": "mDNS / Bonjour", "needs": ("dns.log", "conn.log"),
             "why": "multicast service discovery (5353): devices announcing what they are"},
    "ldap": {"label": "LDAP", "needs": ("conn.log",),
             "why": "directory traffic (389/636): a domain is in use here"},
    "dhcp": {"label": "DHCP", "needs": ("dhcp.log", "conn.log"),
             "why": "who hands out addresses, and to whom"},
    "ssdp": {"label": "SSDP / UPnP", "needs": ("ssdp.log", "conn.log"),
             "why": "UPnP discovery (1900): media devices, routers and IoT announcing themselves"},
    "iot": {"label": "IoT (heuristic)", "needs": ("dns.log",),
            "why": "vendor OUI hints and mDNS service names; a hint, not an identification"},
}

# Vendor substrings (lower-case) that usually mean a consumer IoT device.
# Deliberately short and conservative: a false "IoT" label misleads more than
# a missed one, and the row is labelled heuristic either way.
IOT_VENDOR_HINTS = (
    "espressif", "tuya", "sonoff", "itead", "shelly", "allterco", "wyze",
    "ring llc", "nest labs", "ecobee", "arlo", "signify", "philips lighting",
    "sonos", "roku", "belkin", "tp-link", "hikvision", "dahua", "axis communications",
    "xiaomi", "amazon technologies", "eero",
)
IOT_MDNS_SERVICES = frozenset({
    "_googlecast._tcp", "_hap._tcp", "_homekit._tcp", "_airplay._tcp", "_raop._tcp",
    "_spotify-connect._tcp", "_sonos._tcp", "_hue._tcp", "_matter._tcp", "_matterc._udp",
    "_amzn-wplay._tcp", "_ipp._tcp", "_printer._tcp", "_pdl-datastream._tcp",
    "_axis-video._tcp", "_androidtvremote2._tcp", "_esphomelib._tcp", "_shelly._tcp",
    "_miio._udp", "_wled._tcp", "_dyson_mqtt._tcp",
})

_NEIGH_DEAD = ("FAILED", "INCOMPLETE")
_NEIGH_STATES = ("PERMANENT", "NOARP", "REACHABLE", "STALE", "DELAY", "PROBE", "FAILED", "INCOMPLETE", "NONE")


# ---------------------------------------------------------------- pure helpers

def clamp_window(value: Any, default: float = WINDOW_SECONDS) -> float:
    try:
        return max(WINDOW_MIN, min(WINDOW_MAX, float(value)))
    except (TypeError, ValueError):
        return default


def fmt_window(seconds: float) -> str:
    s = int(round(seconds))
    if s % 3600 == 0:
        h = s // 3600
        return f"{h} h"
    if s % 60 == 0:
        return f"{s // 60} min"
    return f"{s} s"


def classify_ip(addr: str | None) -> str:
    """'local' | 'internet' | 'multicast' | 'invalid'. RFC 1918 / ULA / link-local /
    loopback / unspecified are local; multicast and broadcast stay on the segment
    and are their own class so host counting can skip them. No geolocation."""
    if not addr:
        return "invalid"
    try:
        ip = ipaddress.ip_address(str(addr).strip())
    except ValueError:
        return "invalid"
    if ip.is_unspecified:
        return "invalid"        # 0.0.0.0 / :: (a DHCP DISCOVER's source) names no host
    if ip.is_multicast:
        return "multicast"
    if ip.version == 4 and (ip == ipaddress.IPv4Address("255.255.255.255") or int(ip) & 0xFF == 0xFF):
        return "multicast"      # directed/limited broadcast: segment-local, not a host
    if ip.is_private or ip.is_link_local or ip.is_loopback or ip.is_reserved:
        return "local"
    return "internet"


def _ip_sort_key(addr: str) -> tuple:
    try:
        ip = ipaddress.ip_address(addr)
        return (ip.version, int(ip))
    except ValueError:
        return (9, 0)


def normalise_mac(mac: str | None) -> str | None:
    if not mac:
        return None
    hexs = "".join(c for c in str(mac) if c.isalnum()).upper()
    if len(hexs) != 12 or any(c not in "0123456789ABCDEF" for c in hexs):
        return None
    return ":".join(hexs[i:i + 2] for i in range(0, 12, 2))


def is_random_mac(mac: str | None) -> bool:
    """Locally administered bit set: a randomised (phone/laptop privacy) address.
    The registry has nothing to say about it, and the row must say that."""
    m = normalise_mac(mac)
    if not m:
        return False
    return int(m[1], 16) & 0x2 == 0x2


def parse_ip_neigh(text: str) -> list[dict[str, Any]]:
    """`ip neigh show` -> [{ip, dev, mac, state, router, live}]. Pure.

    live = has a hardware address and is not FAILED/INCOMPLETE: the entries
    that have actually exchanged frames with this deck (same rule as the
    panel's clients-count widget, DEC-PHASE12-010).
    """
    out: list[dict[str, Any]] = []
    for line in (text or "").splitlines():
        parts = line.split()
        if not parts or classify_ip(parts[0]) == "invalid":
            continue
        row: dict[str, Any] = {"ip": parts[0], "dev": None, "mac": None, "state": None,
                               "router": "router" in parts, "live": False}
        i = 1
        while i < len(parts):
            tok = parts[i]
            if tok == "dev" and i + 1 < len(parts):
                row["dev"] = parts[i + 1]
                i += 2
                continue
            if tok == "lladdr" and i + 1 < len(parts):
                row["mac"] = normalise_mac(parts[i + 1])
                i += 2
                continue
            if tok in _NEIGH_STATES:
                row["state"] = tok
            i += 1
        row["live"] = bool(row["mac"]) and row["state"] not in _NEIGH_DEAD
        out.append(row)
    return out


# ---------------------------------------------------------------- OUI registry

def parse_oui_txt(lines) -> dict[str, str]:
    """ieee-data oui.txt: the `XXXXXX     (base 16)\\t\\tVendor` lines. Pure."""
    table: dict[str, str] = {}
    for line in lines:
        if "(base 16)" not in line:
            continue
        prefix, _, rest = line.partition("(base 16)")
        prefix = prefix.strip().upper()
        vendor = rest.strip()
        if len(prefix) == 6 and vendor:
            table[prefix] = vendor
    return table


def parse_oui_csv(lines) -> dict[str, str]:
    """ieee-data oui.csv: Registry,Assignment,Organization Name,Organization Address."""
    table: dict[str, str] = {}
    for row in csv.reader(lines):
        if len(row) < 3 or row[0].strip().lower() == "registry":
            continue
        prefix = row[1].strip().upper()
        if len(prefix) == 6 and row[2].strip():
            table[prefix] = row[2].strip()
    return table


def parse_nmap_prefixes(lines) -> dict[str, str]:
    """nmap-mac-prefixes: `000000 Xerox` per line, `#` comments."""
    table: dict[str, str] = {}
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        prefix, _, vendor = s.partition(" ")
        prefix = prefix.upper()
        if len(prefix) == 6 and vendor.strip():
            table[prefix] = vendor.strip()
    return table


_OUI_PARSERS = {".txt": parse_oui_txt, ".csv": parse_oui_csv}
_OUI_CACHE: dict[str, Any] = {}


def load_oui(paths=None) -> tuple[dict[str, str], dict[str, Any]]:
    """First readable registry wins; parsed once per (path, mtime) and cached in
    the process, because a 35 000-line parse per Cockpit poll would be silly on
    a Bay Trail Atom. Never raises: (table, info) with info.reason when empty."""
    env = os.environ.get("ORIONX_OUI_PATH")
    candidates = tuple(paths) if paths is not None else (
        tuple(p for p in env.split(os.pathsep) if p) if env else OUI_SOURCES)
    for p in candidates:
        path = Path(p)
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        key = str(path)
        if _OUI_CACHE.get("key") == key and _OUI_CACHE.get("mtime") == mtime:
            return _OUI_CACHE["table"], _OUI_CACHE["info"]
        parser = _OUI_PARSERS.get(path.suffix.lower(), parse_nmap_prefixes)
        t0 = time.monotonic()
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                table = parser(fh)
        except OSError as exc:
            continue_reason = f"{path}: {exc}"
            _OUI_CACHE.setdefault("skipped", []).append(continue_reason)
            continue
        info = {"source": key, "entries": len(table), "reason": "",
                "load_ms": round((time.monotonic() - t0) * 1000.0, 1)}
        if not table:
            info["reason"] = f"{key} parsed to zero entries"
            continue
        _OUI_CACHE.update({"key": key, "mtime": mtime, "table": table, "info": info})
        return table, info
    return {}, {"source": None, "entries": 0, "load_ms": 0.0,
                "reason": "no OUI registry readable (looked for " + ", ".join(candidates) + ")"}


def oui_vendor(mac: str | None, table: dict[str, str]) -> str | None:
    m = normalise_mac(mac)
    if not m or not table:
        return None
    return table.get(m.replace(":", "")[:6])


# ---------------------------------------------------------------- Zeek readers

def _rec_ts(rec: dict | None) -> float | None:
    try:
        return float(rec.get("ts")) if rec else None
    except (TypeError, ValueError):
        return None


def _rec_port(rec: dict, key: str) -> int | None:
    try:
        return int(rec.get(key))
    except (TypeError, ValueError):
        return None


def read_log_tail(path, max_bytes: int, now: float, window: float,
                  deadline: float | None = None) -> tuple[list[dict], dict[str, Any]]:
    """Records of `path` with ts inside [now - window, now], from at most the
    last `max_bytes` of the file. Bounded on purpose (DEC-PHASE12-034): the
    header is read for the column names, then one seek and one read.

    info says what the cap did: tail_truncated (the file was longer than the
    cap), coverage_seconds (how much of the window the tail actually spans)
    and budget_exhausted (the deadline stopped the parse early). Each is a
    reason for the picture to call its counts a lower bound.
    """
    path = Path(path)
    info: dict[str, Any] = {"path": str(path), "bytes_read": 0, "lines": 0, "in_window": 0,
                            "tail_truncated": False, "coverage_seconds": None,
                            "budget_exhausted": False, "error": ""}
    fields = zeek_logs.zeek_fields_from_file(path)
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            start = max(0, size - max_bytes)
            fh.seek(start)
            data = fh.read()
    except OSError as exc:
        info["error"] = str(exc)
        return [], info
    info["bytes_read"] = len(data)
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if start > 0:
        info["tail_truncated"] = True
        if lines:
            lines = lines[1:]           # the first line is a fragment
    since = now - window
    out: list[dict] = []
    oldest: float | None = None
    for n, line in enumerate(lines):
        if deadline is not None and n % 256 == 0 and time.monotonic() > deadline:
            info["budget_exhausted"] = True
            break
        if not line or line[0] == "#":
            continue
        info["lines"] += 1
        # Cheap pre-filter: for TSV the timestamp is the first column.
        if line[0] != "{":
            head = line.split("\t", 1)[0]
            try:
                ts = float(head)
            except ValueError:
                continue
            if oldest is None or ts < oldest:
                oldest = ts
            if ts < since or ts > now + 60.0:
                continue
        rec = zeek_logs.zeek_record(line, fields)
        if not rec:
            continue
        ts = _rec_ts(rec)
        if ts is None:
            continue
        if oldest is None or ts < oldest:
            oldest = ts
        if ts < since or ts > now + 60.0:
            continue
        out.append(rec)
    if oldest is not None:
        info["coverage_seconds"] = round(max(0.0, min(window, now - oldest)), 1)
    info["in_window"] = len(out)
    return out, info


def zeek_sources(log_dirs=None) -> dict[str, Any]:
    """Which Zeek directories hold which of our four logs, via the daemon's
    own discovery. ORIONX_ZEEK_LOG_DIR (os.pathsep-separated) overrides the
    candidate list, for tests and for an operator reading an offline run."""
    env = os.environ.get("ORIONX_ZEEK_LOG_DIR")
    if log_dirs is None and env:
        log_dirs = tuple(Path(p) for p in env.split(os.pathsep) if p)
    dirs = tuple(log_dirs) if log_dirs is not None else zeek_logs.ZEEK_LOG_DIRS
    return zeek_logs.assess_zeek_logs(dirs, logs=ZEEK_LOGS)


def zeek_reason(assessment: dict[str, Any]) -> str:
    state = assessment.get("state")
    if state == "ok":
        missing = [name for name in ZEEK_LOGS if name not in (assessment.get("logs") or [])]
        if not missing:
            return ""
        return "Zeek logs found in %s; not present there: %s" % (assessment.get("dir"), ", ".join(missing))
    if state == "unreadable":
        return ("Zeek log directory %s exists but this user cannot read it; the picture is "
                "neighbour-table only until it can (sudo usermod -aG adm, or read as root)"
                % assessment.get("dir"))
    if state == "empty":
        return ("Zeek log directory %s holds no conn/dns/dhcp/ssdp log yet; Zeek may be "
                "starting, or capturing an idle interface" % assessment.get("dir"))
    return ("Zeek is not installed or has not run on this deck (no log directory among %s); "
            "install with %s or raise the posture to Tier 1 to start the managed sensor"
            % (", ".join(assessment.get("considered") or []), INSTALL_ZEEK))


# ---------------------------------------------------------------- pure analysis

def _bytes_of(rec: dict) -> int:
    total = 0
    for a, b in (("orig_ip_bytes", "orig_bytes"), ("resp_ip_bytes", "resp_bytes")):
        v = rec.get(a) if rec.get(a) is not None else rec.get(b)
        try:
            total += int(v)
        except (TypeError, ValueError):
            pass
    return total


def _pkts_of(rec: dict) -> int:
    total = 0
    for k in ("orig_pkts", "resp_pkts"):
        try:
            total += int(rec.get(k))
        except (TypeError, ValueError):
            pass
    return total


def local_internet_split(conn: list[dict]) -> dict[str, Any]:
    """RFC 1918 classification of Zeek conn records: a connection with either
    end on the internet is 'internet'; everything else (private, link-local,
    multicast, broadcast) stayed on the segment. Pure."""
    acc = {"local": {"conns": 0, "bytes": 0, "pkts": 0},
           "internet": {"conns": 0, "bytes": 0, "pkts": 0}}
    for rec in conn:
        o, r = classify_ip(rec.get("id.orig_h")), classify_ip(rec.get("id.resp_h"))
        if o == "invalid" and r == "invalid":
            continue
        cls = "internet" if "internet" in (o, r) else "local"
        acc[cls]["conns"] += 1
        acc[cls]["bytes"] += _bytes_of(rec)
        acc[cls]["pkts"] += _pkts_of(rec)
    tb = acc["local"]["bytes"] + acc["internet"]["bytes"]
    tc = acc["local"]["conns"] + acc["internet"]["conns"]
    basis, denom = ("bytes", tb) if tb > 0 else ("conns", tc)
    local_pct = internet_pct = None
    if denom > 0:
        local_pct = round(100.0 * acc["local"][basis] / denom, 1)
        internet_pct = round(100.0 - local_pct, 1)
    return {"available": tc > 0, "basis": basis, "local": acc["local"], "internet": acc["internet"],
            "local_pct": local_pct, "internet_pct": internet_pct, "conns": tc,
            "reason": "" if tc > 0 else "no conn.log records inside the window"}


def _sighting(state: str, count: int = 0, hosts=(), sources=(), needs=(), detail: str = "",
              samples=(), last_ts: float | None = None, **extra) -> dict[str, Any]:
    hosts = sorted(set(h for h in hosts if h), key=_ip_sort_key)
    d = {"state": state, "count": int(count), "hosts": hosts[:MAX_SIGHTING_HOSTS],
         "hosts_truncated": len(hosts) > MAX_SIGHTING_HOSTS, "sources": list(sources),
         "needs": list(needs), "detail": detail, "samples": sorted(set(samples))[:MAX_SAMPLES],
         "last_ts": last_ts}
    d.update(extra)
    return d


def _query_label(rec: dict) -> str:
    return str(rec.get("query") or "").rstrip(".").lower()


def _mdns_service(query: str) -> str | None:
    q = query.rstrip(".").lower()
    if not q.endswith(".local"):
        return None
    labels = q.split(".")
    for i, lab in enumerate(labels):
        if lab.startswith("_") and i + 1 < len(labels) and labels[i + 1] in ("_tcp", "_udp"):
            return ".".join(labels[i:i + 2])
    return None


def protocol_sightings(conn: list[dict], dns: list[dict], dhcp: list[dict], ssdp: list[dict],
                       have: dict[str, bool]) -> dict[str, dict[str, Any]]:
    """Every sighting class, each present / absent / unknown. Pure.

    `have` says which logs were readable (not merely non-empty): a log that was
    read and showed nothing yields 'absent'; a log that could not be read
    yields 'unknown' for the rows that needed it.
    """
    out: dict[str, dict[str, Any]] = {}

    def latest(recs) -> float | None:
        ts = [t for t in (_rec_ts(r) for r in recs) if t is not None]
        return max(ts) if ts else None

    # --- from conn.log: port-based classes ---
    by_class: dict[str, list[dict]] = {k: [] for k in ("netbios", "llmnr", "mdns", "ldap", "ssdp", "dhcp")}
    for rec in conn:
        proto = str(rec.get("proto") or "").lower()
        p = _rec_port(rec, "id.resp_p")
        if p is None:
            continue
        if proto == "udp":
            if p in NETBIOS_UDP:
                by_class["netbios"].append(rec)
            elif p == LLMNR_PORT:
                by_class["llmnr"].append(rec)
            elif p == MDNS_PORT:
                by_class["mdns"].append(rec)
            elif p == SSDP_PORT:
                by_class["ssdp"].append(rec)
            elif p in DHCP_UDP:
                by_class["dhcp"].append(rec)
        elif proto == "tcp":
            if p in NETBIOS_TCP:
                by_class["netbios"].append(rec)
            elif p in LDAP_TCP:
                by_class["ldap"].append(rec)

    # --- from dns.log: the same name services, with the names asked for ---
    dns_by_port: dict[str, list[dict]] = {"netbios": [], "llmnr": [], "mdns": []}
    wpad: list[dict] = []
    for rec in dns:
        p = _rec_port(rec, "id.resp_p")
        q = _query_label(rec)
        if q == "wpad" or q.startswith("wpad."):
            wpad.append(rec)
        if p == 137:
            dns_by_port["netbios"].append(rec)
        elif p == LLMNR_PORT:
            dns_by_port["llmnr"].append(rec)
        elif p == MDNS_PORT:
            dns_by_port["mdns"].append(rec)

    def merged(key: str) -> dict[str, Any]:
        spec = SIGHTINGS[key]
        recs_conn = by_class.get(key, [])
        recs_dns = dns_by_port.get(key, [])
        srcs = [n for n, ok in (("conn.log", have.get("conn.log")), ("dns.log", have.get("dns.log")))
                if ok and n in spec["needs"]]
        if not srcs:
            return _sighting("unknown", needs=spec["needs"], detail="needs Zeek " + " or ".join(spec["needs"]))
        recs = recs_conn + recs_dns
        hosts = [r.get("id.orig_h") for r in recs]
        samples = [_query_label(r) for r in recs_dns if _query_label(r)]
        established = sum(1 for r in recs_conn if str(r.get("conn_state") or "") in ("SF", "S1", "S2", "S3", "RSTO", "RSTR"))
        detail = spec["why"]
        if recs_conn and key in ("ldap", "netbios"):
            detail += f"; {established} of {len(recs_conn)} connections completed a handshake"
        return _sighting("present" if recs else "absent", len(recs), hosts, srcs, spec["needs"],
                         detail, samples, latest(recs), established=established)

    for key in ("netbios", "llmnr", "mdns", "ldap"):
        out[key] = merged(key)

    # WPAD: dns.log only.
    if have.get("dns.log"):
        out["wpad"] = _sighting("present" if wpad else "absent", len(wpad),
                                [r.get("id.orig_h") for r in wpad], ["dns.log"], SIGHTINGS["wpad"]["needs"],
                                SIGHTINGS["wpad"]["why"], [_query_label(r) for r in wpad], latest(wpad))
    else:
        out["wpad"] = _sighting("unknown", needs=SIGHTINGS["wpad"]["needs"], detail="needs Zeek dns.log")

    # DHCP: dhcp.log first (it names servers and leases); conn.log 67/68 as the fallback.
    if have.get("dhcp.log"):
        hosts = [r.get("client_addr") or r.get("mac") for r in dhcp]
        servers = sorted({str(r.get("server_addr")) for r in dhcp if r.get("server_addr")})
        names = [str(r.get("host_name")) for r in dhcp if r.get("host_name")]
        out["dhcp"] = _sighting("present" if dhcp else "absent", len(dhcp), hosts, ["dhcp.log"],
                                SIGHTINGS["dhcp"]["needs"], SIGHTINGS["dhcp"]["why"], names, latest(dhcp),
                                servers=servers)
    elif have.get("conn.log"):
        recs = by_class["dhcp"]
        out["dhcp"] = _sighting("present" if recs else "absent", len(recs), [r.get("id.orig_h") for r in recs],
                                ["conn.log"], SIGHTINGS["dhcp"]["needs"],
                                SIGHTINGS["dhcp"]["why"] + " (ports 67/68 only; dhcp.log would name the server)",
                                (), latest(recs), servers=[])
    else:
        out["dhcp"] = _sighting("unknown", needs=SIGHTINGS["dhcp"]["needs"], detail="needs Zeek dhcp.log or conn.log")

    # SSDP: ssdp.log if a policy writes one, else conn.log 1900.
    if have.get("ssdp.log"):
        samples = [str(r.get("server") or r.get("user_agent") or r.get("uri") or "") for r in ssdp]
        out["ssdp"] = _sighting("present" if ssdp else "absent", len(ssdp), [r.get("id.orig_h") for r in ssdp],
                                ["ssdp.log"], SIGHTINGS["ssdp"]["needs"], SIGHTINGS["ssdp"]["why"],
                                [s for s in samples if s], latest(ssdp))
    elif have.get("conn.log"):
        recs = by_class["ssdp"]
        out["ssdp"] = _sighting("present" if recs else "absent", len(recs), [r.get("id.orig_h") for r in recs],
                                ["conn.log"], SIGHTINGS["ssdp"]["needs"],
                                SIGHTINGS["ssdp"]["why"] + " (port 1900 only; no ssdp.log on this deck)",
                                (), latest(recs))
    else:
        out["ssdp"] = _sighting("unknown", needs=SIGHTINGS["ssdp"]["needs"], detail="needs Zeek ssdp.log or conn.log")
    return out


def iot_heuristics(arp_rows: list[dict], dns: list[dict], have_dns: bool,
                   have_oui: bool) -> dict[str, Any]:
    """Vendor-hint and mDNS-service hints, labelled heuristic. Pure."""
    hits: list[dict[str, Any]] = []
    for row in arp_rows:
        vendor = (row.get("vendor") or "").lower()
        hint = next((h for h in IOT_VENDOR_HINTS if h in vendor), None)
        if hint:
            hits.append({"ip": row.get("ip"), "mac": row.get("mac"), "why": f"vendor OUI: {row.get('vendor')}"})
    services: dict[str, set] = {}
    for rec in dns:
        svc = _mdns_service(_query_label(rec))
        if svc and svc in IOT_MDNS_SERVICES:
            services.setdefault(svc, set()).add(str(rec.get("id.orig_h")))
    for svc, hosts in sorted(services.items()):
        for h in sorted(hosts, key=_ip_sort_key):
            hits.append({"ip": h, "mac": None, "why": f"mDNS service {svc}"})
    sources = [s for s, ok in (("oui", have_oui), ("dns.log", have_dns)) if ok]
    if not sources:
        state = "unknown"
        detail = "needs the OUI registry or Zeek dns.log"
    else:
        state = "present" if hits else "absent"
        detail = SIGHTINGS["iot"]["why"]
        if not have_dns:
            detail += "; mDNS part needs Zeek dns.log"
        if not have_oui:
            detail += "; vendor part needs the ieee-data OUI registry"
    out = _sighting(state, len(hits), [h["ip"] for h in hits], sources, SIGHTINGS["iot"]["needs"], detail,
                    [h["why"] for h in hits], None, heuristic=True)
    out["hits"] = hits[:MAX_SIGHTING_HOSTS]
    return out


def host_census(neigh: list[dict], conn: list[dict], self_ips: set[str]) -> dict[str, Any]:
    """Distinct hosts: live neighbour entries keyed by MAC (a v4 and a v6
    neighbour with one MAC is one host) plus local unicast addresses seen in
    conn.log that the neighbour table does not already explain. Pure, capped."""
    hosts: dict[str, dict[str, Any]] = {}
    ip_to_key: dict[str, str] = {}
    for row in neigh:
        if not row.get("live") or row["ip"] in self_ips:
            continue
        key = row["mac"]
        h = hosts.setdefault(key, {"key": key, "mac": key, "ips": set(), "sources": set()})
        h["ips"].add(row["ip"])
        h["sources"].add("ip neigh")
        ip_to_key[row["ip"]] = key
    truncated = False
    for rec in conn:
        for side in ("id.orig_h", "id.resp_h"):
            ip = rec.get(side)
            if not ip or ip in self_ips or classify_ip(ip) != "local":
                continue
            key = ip_to_key.get(ip, ip)
            if key not in hosts:
                if len(hosts) >= MAX_HOSTS:
                    truncated = True
                    continue
                hosts[key] = {"key": key, "mac": key if ":" in key and len(key) == 17 else None,
                              "ips": set(), "sources": set()}
            hosts[key]["ips"].add(ip)
            hosts[key]["sources"].add("conn.log")
    n_neigh = sum(1 for h in hosts.values() if "ip neigh" in h["sources"])
    n_zeek_only = sum(1 for h in hosts.values() if h["sources"] == {"conn.log"})
    return {"count": len(hosts), "from_neigh": n_neigh, "zeek_only": n_zeek_only,
            "truncated": truncated, "cap": MAX_HOSTS}


# ---------------------------------------------------------------- thin readers

def _run(cmd: list[str], timeout: float = 2.0) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def summary_of(picture: dict[str, Any]) -> dict[str, Any]:
    """The headline both surfaces show, built from the picture and nothing
    else, so the Cockpit's two lines and the page's chips are the same words."""
    hosts = picture["hosts"]
    split = picture["split"]
    win = fmt_window(picture["window_seconds"])
    n = hosts["count"]
    # The neighbour table is the kernel's cache, not a windowed log: its entries
    # age by the kernel's rules, so the window is claimed only for the Zeek part.
    basis = f"ARP table + Zeek {win}" if picture["zeek"].get("conn.log") else "ARP table only"
    lower = " (at least)" if hosts.get("truncated") or picture["bounded"]["lower_bound"] else ""
    headline = f"{n} host{'s' if n != 1 else ''}{lower} · {basis} · {OBSERVED_LABEL}"
    if split.get("available"):
        split_line = (f"{split['local_pct']:.0f}% local / {split['internet_pct']:.0f}% internet "
                      f"by {split['basis']} · Zeek conn.log · {win}")
    elif picture["zeek"].get("conn.log"):
        split_line = f"no connections in Zeek conn.log in the last {win}"
    else:
        split_line = "local/internet split needs Zeek (conn.log)"
    return {"hosts": n, "hosts_basis": basis, "lower_bound": bool(lower), "window_seconds": picture["window_seconds"],
            "window": win, "label": OBSERVED_LABEL, "split_available": bool(split.get("available")),
            "local_pct": split.get("local_pct"), "internet_pct": split.get("internet_pct"),
            "headline": headline, "split_line": split_line,
            "degraded": list(picture["degraded"])}


def collect(window: float = WINDOW_SECONDS, now: float | None = None,
            run: Callable[..., str] = _run, log_dirs=None, oui_paths=None,
            budget: float = BUDGET_SECONDS) -> dict[str, Any]:
    """The whole picture, best effort, bounded. Never raises.

    Every section is independently degraded with a reason; `degraded` lists the
    rows that needed a Zeek log that was not there (the page prints them).
    """
    t_start = time.monotonic()
    deadline = t_start + max(0.1, budget)
    now = time.time() if now is None else float(now)
    window = clamp_window(window)
    reasons: list[str] = []
    out: dict[str, Any] = {"schema": SCHEMA, "decision": DECISION, "generated": now,
                           "window_seconds": window, "label": OBSERVED_LABEL,
                           "geolocation": None, "reasons": reasons}

    def _safe(fn: Callable[..., str], *args: Any) -> str:
        try:
            return fn(*args) or ""
        except Exception:  # noqa: BLE001 - an injected reader that raises is "unreadable"
            return ""

    # Self: the deck's own addresses are never counted as hosts.
    self_ips: set[str] = set()
    for it in deck_vitals.parse_ip_addr(_safe(run, ["ip", "-j", "addr"])):
        for cidr in (it.get("ipv4") or []) + (it.get("ipv6") or []):
            self_ips.add(cidr.split("/")[0])

    # Neighbour table.
    neigh_text = _safe(run, ["ip", "neigh", "show"])
    neigh = parse_ip_neigh(neigh_text)
    if not neigh_text.strip():
        reasons.append("ip neigh: no output (not Linux, or `ip` missing) — neighbour rows empty")

    # OUI registry.
    try:
        table, oui_info = load_oui(oui_paths)
    except Exception as exc:  # noqa: BLE001 - a corrupt registry must not take the picture down
        table, oui_info = {}, {"source": None, "entries": 0, "load_ms": 0.0, "reason": f"OUI load failed: {exc}"}
    if not table:
        reasons.append("oui: " + oui_info["reason"])
    out["oui"] = oui_info

    arp_rows: list[dict[str, Any]] = []
    for row in sorted(neigh, key=lambda r: _ip_sort_key(r["ip"])):
        if not row.get("mac"):
            continue
        rnd = is_random_mac(row["mac"])
        vendor = None if rnd else oui_vendor(row["mac"], table)
        arp_rows.append({"ip": row["ip"], "mac": row["mac"], "dev": row["dev"], "state": row["state"],
                         "live": row["live"], "router": row["router"], "random_mac": rnd,
                         "vendor": vendor,
                         "vendor_note": ("randomised address: no registry vendor" if rnd else
                                         "" if vendor else
                                         ("no OUI registry" if not table else "prefix not in registry"))})
    out["arp"] = {"rows": arp_rows[:MAX_ARP_ROWS], "count": len(arp_rows),
                  "truncated": len(arp_rows) > MAX_ARP_ROWS, "source": "ip neigh",
                  "live": sum(1 for r in arp_rows if r["live"])}

    # Zeek: discovery via the shared module, then bounded tail reads.
    try:
        assessment = zeek_sources(log_dirs)
    except Exception as exc:  # noqa: BLE001
        assessment = {"state": "absent", "dir": "", "logs": [], "considered": [], "sources": [],
                      "unreadable": [], "error": str(exc)}
    zeek: dict[str, Any] = {"state": assessment.get("state"), "dir": assessment.get("dir", ""),
                            "logs": list(assessment.get("logs") or []),
                            "sources": [s["dir"] for s in (assessment.get("sources") or [])],
                            "reason": zeek_reason(assessment), "coverage": {}}
    recs: dict[str, list[dict]] = {name: [] for name in ZEEK_LOGS}
    have: dict[str, bool] = {name: False for name in ZEEK_LOGS}
    lower_bound = False
    for source in assessment.get("sources") or []:
        for name in source.get("logs") or []:
            rows, info = read_log_tail(Path(source["dir"]) / name, TAIL_BYTES[name], now, window, deadline)
            zeek["coverage"][name] = info
            if info["error"]:
                reasons.append(f"zeek {name}: {info['error']}")
                continue
            have[name] = True
            recs[name].extend(rows)
            if info["budget_exhausted"]:
                lower_bound = True
                reasons.append(f"zeek {name}: time budget of {budget:.1f} s exhausted; counts are a lower bound")
            elif info["tail_truncated"] and info["coverage_seconds"] is not None and info["coverage_seconds"] < window:
                lower_bound = True
                reasons.append(f"zeek {name}: the last {TAIL_BYTES[name] >> 10} KiB cover {fmt_window(info['coverage_seconds'])} "
                               f"of the {fmt_window(window)} window; counts are a lower bound")
    for name in ZEEK_LOGS:
        zeek[name] = have[name]
    if zeek["reason"]:
        reasons.append("zeek: " + zeek["reason"])
    out["zeek"] = zeek

    out["hosts"] = host_census(neigh, recs["conn.log"], self_ips)
    out["hosts"].update({"window_seconds": window, "label": OBSERVED_LABEL,
                         "sources": ["ip neigh"] + (["conn.log"] if have["conn.log"] else []),
                         "neigh_note": "neighbour-table entries age by the kernel's cache rules, not by this "
                                       "window; only the Zeek-fed hosts are bounded to it"})
    split = local_internet_split(recs["conn.log"]) if have["conn.log"] else {
        "available": False, "basis": None, "local": None, "internet": None, "local_pct": None,
        "internet_pct": None, "conns": 0, "reason": "needs Zeek conn.log"}
    split.update({"window_seconds": window, "label": OBSERVED_LABEL})
    out["split"] = split
    sightings = protocol_sightings(recs["conn.log"], recs["dns.log"], recs["dhcp.log"], recs["ssdp.log"], have)
    sightings["iot"] = iot_heuristics(arp_rows, recs["dns.log"], have["dns.log"], bool(table))
    for key, s in sightings.items():
        s["label"] = SIGHTINGS[key]["label"]
        s["window_seconds"] = window
    out["sightings"] = sightings

    degraded = []
    if not have["conn.log"]:
        degraded.append("split")
        degraded.append("hosts.zeek")
    degraded.extend(f"sightings.{k}" for k, s in sightings.items() if s["state"] == "unknown")
    out["degraded"] = degraded
    out["bounded"] = {"budget_seconds": budget, "lower_bound": lower_bound,
                      "elapsed_ms": round((time.monotonic() - t_start) * 1000.0, 1),
                      "caps": {"hosts": MAX_HOSTS, "arp_rows": MAX_ARP_ROWS, "tail_bytes": TAIL_BYTES}}
    out["active"] = active_extensions()
    out["summary"] = summary_of(out)
    out["bounded"]["elapsed_ms"] = round((time.monotonic() - t_start) * 1000.0, 1)
    return out


# ---------------------------------------------------------------- extension point (#94)
# Everything above is PASSIVE: it reads tables and logs and transmits nothing.
# Issue #94 adds two ACTIVE things beneath this picture on the same Workbench
# page: gateway identity via SSDP/IGD (local segment, operator-initiated,
# "reported by the gateway, not measured") and blocking/filtering probes that
# reach the internet and must pass osint_server.outbound_verdict() first.
# They plug in here and ONLY here, so a reader of collect() can see at a glance
# that the passive picture never grew a transmitter by accident. Until #94
# lands this returns an empty list and the page draws nothing for it.

def active_extensions() -> list[dict[str, Any]]:
    """Operator-initiated, posture-gated sections (#94). Empty until implemented;
    the entries will carry {id, label, state, gated_by, result} and the page
    renders them under the passive picture with their own labels."""
    return []


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="network_picture",
                                 description="What this deck has passively observed on its segment (#93).")
    ap.add_argument("--window", type=float, default=WINDOW_SECONDS, help="look-back in seconds (default %(default)s)")
    ap.add_argument("--bench", type=int, default=0, metavar="N",
                    help="run collect() N times and print min/median/max ms instead of the picture")
    ap.add_argument("--summary", action="store_true", help="print the two headline lines only")
    args = ap.parse_args(argv)
    if args.bench > 0:
        times = []
        for _ in range(args.bench):
            t0 = time.monotonic()
            pic = collect(window=args.window)
            times.append((time.monotonic() - t0) * 1000.0)
        times.sort()
        print(json.dumps({"runs": args.bench, "min_ms": round(times[0], 1),
                          "median_ms": round(times[len(times) // 2], 1), "max_ms": round(times[-1], 1),
                          "budget_s": BUDGET_SECONDS, "cockpit_poll_ms": 5000,
                          "zeek_state": pic["zeek"]["state"], "oui_source": pic["oui"]["source"],
                          "oui_load_ms_first": pic["oui"].get("load_ms")}))
        return 0
    pic = collect(window=args.window)
    if args.summary:
        print(pic["summary"]["headline"])
        print(pic["summary"]["split_line"])
        return 0
    print(json.dumps(pic, indent=2, default=str))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
