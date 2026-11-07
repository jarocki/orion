"""logquery_sources — where forensic records come from, and how they normalize.

@decision DEC-PHASE12-027
@title Four first-class logquery sources, with local files as the default
@status accepted
@rationale The upstream tool (jarocki-edge scripts/logquery.py) fetches sealed
  objects from one place: Cloudflare R2, via boto3 with the endpoint hardcoded
  to `{account}.r2.cloudflarestorage.com`. Its only non-R2 intake is
  `--use/--input`, which re-ingests NDJSON the tool itself previously wrote.
  There is no generic S3 endpoint and no HTTP intake at all (verified: the
  module imports no urllib/requests/http.client). So the upstream shape is
  "R2, plus a cache of its own output".

  That shape is wrong for Orion-X. An operator opens this deck at an incident,
  in front of someone else's machine, holding /var/log off a mounted disk. The
  common case has no cloud account, no credentials and possibly no network.
  Making the local path a re-ingest convenience for a cloud fetcher would make
  the common case the degraded one.

  So `local` is the default source and needs nothing: no credentials, no
  boto3, no key, no network. It reads three formats an incident actually
  produces — NDJSON/JSON (including the R.A.I.N. bus at
  /run/orionx/events.jsonl), Apache/nginx access logs, and the kernel's
  nftables drop lines — sniffed per line, so a directory of mixed evidence
  works. r2, s3 and api are peers, not the privileged path, and each one's
  dependency is optional and named when it is missing.

@decision DEC-PHASE12-027
@title The nftables drop-line grammar has one parser, and it lives in scanwatch
@status accepted
@rationale scripts/rain/orionx-scanwatch already owns the [ORIONX-DROP] line
  format (DEC-PHASE12-022). Writing a second regex here would create two
  authorities over one grammar that silently diverge the next time
  /etc/nftables.conf changes its log prefix. This module loads scanwatch and
  calls its parse_drop_line. If scanwatch cannot be loaded, drop-log parsing
  is reported as unavailable — it is never reimplemented locally.
"""
from __future__ import annotations

import ipaddress
import json
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path

SOURCES = ("local", "r2", "s3", "api")

# Where r2/s3 credentials are looked for when --env is not given. Under
# ~/.config/orionx/ beside the threat-posture file, not in the repo: no code
# path here ever writes credentials, and none should ever find them in a
# working tree.
DEFAULT_ENV_FILE = "~/.config/orionx/logquery/credentials.env"

# Sources that need credentials. `local` is deliberately absent: the default
# path must work with nothing configured.
CREDENTIALLED_SOURCES = ("r2", "s3", "api")

# The canonical record. Every parser normalizes onto these keys so one set of
# reports, one correlation pass and one SQL schema serve all four sources.
#
# signature/sid/technique/detector/tool arrived with #127: they are what a bus
# event's `detail` carries and an access log never does. `tool` is the
# producer's attribution (#128 makes postured/scanwatch set detail.tool); the
# enrichment pass keeps it when set and fills it from the User-Agent only when
# it is empty, so there is one `tool` column with one precedence rule.
RECORD_FIELDS = (
    "ts", "ip", "method", "path", "query", "status", "bytes",
    "userAgent", "referer", "asn", "asOrganization", "country",
    "reason", "tier", "proto", "port", "origin",
    "signature", "sid", "technique", "detector", "tool",
)

# @decision DEC-PHASE13-039
# @title A bus event's detail is flattened onto the record, sidecars included
# @status accepted
# @rationale parse_json_line mapped only a bus line's top-level keys, so a
#   Suricata, Zeek or scanwatch event became {ts, reason, path=message} with no
#   ip, port or signature, and every report that keys on ip (all of them, plus
#   correlate) saw nothing of it — the owner's "logquery does not operate on
#   nmap, IDS and zeek alerts" (#127). The producers already publish the
#   structure: postured's _alert_detail (engine, src_ip, dest_ip, proto, sid,
#   signature, dest_port, technique) and scanwatch's build_detail (src_ip,
#   latest_dport, protocols, detector, ports_seen). This module now lifts
#   those keys onto the canonical record with one priority list per field
#   (dest_port before latest_dport, signature before Zeek's note, detector
#   before engine), fills only fields the top level left empty, and derives
#   tier from the bus severity rank (rain_lib.SEVERITIES) so the tier-gated
#   reports (threats, timeline alerts) see an IDS critical the way they see a
#   firewall drop. When the broker spilled an oversized detail to
#   /run/orionx/details/<id>.json (rain_lib._write_sidecar), the inline copy
#   is visibly truncated; the reader here follows `_full` only when the path
#   resolves inside rain_lib.DETAIL_DIR and is named for the event's own id,
#   because the bus line is evidence that may have been copied off another
#   machine and must not be allowed to point this tool at an arbitrary file.
#   No reader of that sidecar existed before; the location is taken from
#   rain_lib so there is still one authority over where sidecars live. The
#   flattening is counted and narrated under -v, and an unreadable sidecar is
#   a note the operator sees, never a silent fallback to the truncated copy.

# detail.<key> -> record field, applied only to a bus event's detail dict.
# Keys are tried in order per field; the first present, non-empty one wins.
_DETAIL_MAP = (
    ("ip", ("src_ip",)),
    ("port", ("dest_port", "latest_dport")),
    ("proto", ("proto", "protocols")),
    ("signature", ("signature", "note")),
    ("sid", ("sid",)),
    ("technique", ("technique",)),
    ("detector", ("detector", "engine")),
    ("tool", ("tool",)),
)

# A sidecar larger than this is refused unread. The broker never writes one
# above rain_lib.MAX_REQUEST_BYTES (128 KiB); the margin is for a hand-edited
# file, not for a bigger payload.
SIDECAR_MAX_BYTES = 1024 * 1024

# Field aliases seen in the wild / in the sealed edge archive.
_ALIASES = {
    "user_agent": "userAgent", "ua": "userAgent", "http_user_agent": "userAgent",
    "user-agent": "userAgent", "referrer": "referer", "http_referer": "referer",
    "client_ip": "ip", "clientIP": "ip", "src": "ip", "remote_addr": "ip",
    "src_ip": "ip", "source": "ip",
    "timestamp": "ts", "time": "ts", "@timestamp": "ts", "iso": "ts",
    "uri": "path", "url": "path", "request_path": "path",
    "status_code": "status", "sc_status": "status",
    "as_organization": "asOrganization", "asOrg": "asOrganization",
    "org": "asOrganization", "dport": "port", "dpt": "port",
}

# Apache/nginx combined and common log formats.
_CLF_RE = re.compile(
    r'^(?P<ip>\S+)\s+\S+\s+(?P<user>\S+)\s+\[(?P<time>[^\]]+)\]\s+'
    r'"(?P<method>[A-Z]+)\s+(?P<target>\S*)\s*(?P<proto>[^"]*)"\s+'
    r'(?P<status>\d{3})\s+(?P<bytes>\S+)'
    r'(?:\s+"(?P<referer>[^"]*)"\s+"(?P<ua>[^"]*)")?'
)
_CLF_TIME = "%d/%b/%Y:%H:%M:%S %z"

_DUR_RE = re.compile(r"^(\d+)\s*([hdwm])$", re.I)


class SourceError(Exception):
    """A source could not be read. Carries an operator-actionable hint."""

    def __init__(self, message: str, hint: str = ""):
        super().__init__(message)
        self.hint = hint


# ---------------------------------------------------------------------------
# R.A.I.N. siblings — loaded from scripts/rain/ (or the installed path), never
# reimplemented here. Each one is a single authority this module defers to.
# ---------------------------------------------------------------------------
def _load_rain_module(filename: str, modname: str):
    here = Path(__file__).resolve()
    candidates = [
        here.parent.parent / "rain" / filename,
        Path("/opt/orionx/scripts/rain") / filename,
    ]
    for candidate in candidates:
        if candidate.is_file():
            try:
                return SourceFileLoader(modname, str(candidate)).load_module()
            except (OSError, SyntaxError, ImportError):
                return None
    return None


_RAIN_LIB = _load_rain_module("rain_lib.py", "orionx_rain_lib")

# Where the broker spills oversized detail (rain_lib._write_sidecar) and the
# severity rank bus tiers derive from. Both come from rain_lib when it loads;
# the fallbacks mirror its values so a copy of this module can still read a
# spool off-deck, and are the only place they are repeated.
DETAIL_DIR = Path(getattr(_RAIN_LIB, "DETAIL_DIR", "/run/orionx/details"))
BUS_SEVERITIES = tuple(getattr(_RAIN_LIB, "SEVERITIES",
                               ("info", "notice", "warning", "critical")))


# ---------------------------------------------------------------------------
# time windows
# ---------------------------------------------------------------------------
def parse_window(last: str | None, since: str | None,
                 now: datetime | None = None) -> datetime | None:
    """Turn --last/--since into an aware UTC start instant, or None for 'all'."""
    now = now or datetime.now(timezone.utc)
    if last:
        m = _DUR_RE.match(last.strip())
        if not m:
            raise SourceError(f"bad --last value: {last}",
                              "use forms like 24h, 7d, 4w, 3m")
        n, unit = int(m.group(1)), m.group(2).lower()
        delta = {"h": timedelta(hours=n), "d": timedelta(days=n),
                 "w": timedelta(weeks=n), "m": timedelta(days=30 * n)}[unit]
        return now - delta
    if since:
        try:
            dt = datetime.fromisoformat(since)
        except ValueError as exc:
            raise SourceError(f"bad --since value: {since}",
                              "use YYYY-MM-DD or an ISO timestamp") from exc
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    return None


def normalize_ts(value) -> str:
    """Coerce any recognizable timestamp to a sortable ISO-8601 UTC string.

    Records are sorted, windowed and grouped by day as text, so every parser
    must agree on one spelling. Unparseable input returns "" rather than
    guessing a time — a fabricated timestamp would corrupt the recurrence
    signal that the correlation depends on.
    """
    if value in (None, ""):
        return ""
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(float(value), timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%S+00:00")
        except (OSError, ValueError, OverflowError):
            return ""
    text = str(value).strip()
    for candidate in (text.replace("Z", "+00:00"), text[:19]):
        try:
            dt = datetime.fromisoformat(candidate)
        except ValueError:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    try:
        dt = datetime.strptime(text, _CLF_TIME)
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    except ValueError:
        return ""


def blank_record() -> dict:
    return {field: None for field in RECORD_FIELDS}


def _coerce_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# per-format parsers (pure)
# ---------------------------------------------------------------------------
def new_parse_stats() -> dict:
    """Counters parse_json_line fills when given one; narrated under -v."""
    return {"bus_events": 0, "detail_flattened": 0, "sidecar_read": 0,
            "sidecar_unreadable": 0, "detail_truncated": 0}


def read_detail_sidecar(detail: dict, event_id, detail_dir: Path | None = None):
    """Return the full detail behind a `_full` reference, or None with a reason.

    Follows the broker's own contract (rain_lib._write_sidecar): a JSON object
    at <DETAIL_DIR>/<event id>.json. Anything else — a path outside that
    directory, a name that is not this event's id, a symlink that resolves
    elsewhere, a non-object, an oversized file — is refused, because the bus
    line is evidence and may have been written anywhere.
    """
    ref = detail.get("_full")
    if not isinstance(ref, str) or not ref:
        return None, "no sidecar reference"
    if not isinstance(event_id, str) or not event_id:
        return None, "event carries no id"
    base = (detail_dir if detail_dir is not None else DETAIL_DIR)
    try:
        base = Path(base).resolve()
        path = Path(ref).resolve(strict=True)
    except (OSError, RuntimeError):
        return None, f"sidecar missing: {ref}"
    if path.parent != base or path.name != f"{event_id}.json":
        return None, f"sidecar reference refused (outside {base}): {ref}"
    try:
        if path.stat().st_size > SIDECAR_MAX_BYTES:
            return None, f"sidecar too large: {ref}"
        full = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return None, f"sidecar unreadable: {ref}"
    if not isinstance(full, dict):
        return None, f"sidecar is not a JSON object: {ref}"
    return full, ""


def _flatten_detail(rec: dict, raw: dict, stats: dict | None) -> None:
    """Lift a bus event's detail onto the record's canonical fields.

    Only fields the top level left empty are filled, so a producer that one
    day puts `ip` at the top level is not overridden by its own detail.
    """
    detail = raw.get("detail")
    if not isinstance(detail, dict) or not detail:
        return
    if "_full" in detail:
        full, why = read_detail_sidecar(detail, raw.get("id"))
        if full is not None:
            merged = dict(detail)
            merged.update(full)
            detail = merged
            if stats is not None:
                stats["sidecar_read"] += 1
        elif stats is not None:
            stats["sidecar_unreadable"] += 1
            stats.setdefault("sidecar_notes", []).append(why)
    if detail.get("_truncated") and stats is not None:
        stats["detail_truncated"] += 1
    touched = False
    for field, keys in _DETAIL_MAP:
        if rec.get(field) not in (None, ""):
            continue
        for key in keys:
            value = detail.get(key)
            if value not in (None, ""):
                rec[field] = value
                touched = True
                break
    # The producer's confidence travels with its tool (DEC-PHASE13-040); it is
    # an enrichment column, so it rides on the record outside RECORD_FIELDS
    # and enrich_record keeps it when the tool was not fingerprinted there.
    if rec.get("tool") == detail.get("tool") and detail.get("tool_conf"):
        rec["tool_conf"] = str(detail["tool_conf"])
    if touched and stats is not None:
        stats["detail_flattened"] += 1


def bus_tier(severity) -> int | None:
    """Bus severity -> the coarse tier the reports gate on (info 0 .. critical 3).

    The rank is rain_lib's; a firewall drop is tier 2 and a bus 'warning' is
    the same rung, so the two kinds of evidence sort together.
    """
    try:
        return BUS_SEVERITIES.index(str(severity).lower())
    except ValueError:
        return None


def parse_json_line(line: str, stats: dict | None = None) -> dict | None:
    """Parse one NDJSON record, mapping known aliases onto the canonical keys.

    Also accepts a R.A.I.N. bus line (/run/orionx/events.jsonl), whose
    'source'/'category'/'message' shape puts the address, port, signature
    and detector inside `detail` — flattened here (DEC-PHASE13-039). `stats`,
    when given, is a new_parse_stats() dict that counts what was flattened.
    """
    text = line.strip()
    if not text or text[0] != "{":
        return None
    try:
        raw = json.loads(text)
    except ValueError:
        return None
    if not isinstance(raw, dict):
        return None

    rec = blank_record()
    bus_event = "severity" in raw and "message" in raw
    for key, value in raw.items():
        # A bus event's "source" is a component name, not an address, and
        # its "detail" is structure, flattened below rather than copied.
        if bus_event and key in ("source", "detail"):
            continue
        field = _ALIASES.get(key, key)
        if field in RECORD_FIELDS:
            rec[field] = value
    if bus_event:
        if stats is not None:
            stats["bus_events"] += 1
        rec["reason"] = raw.get("category") or "bus_event"
        rec["path"] = rec["path"] or str(raw.get("message", ""))[:200]
        _flatten_detail(rec, raw, stats)
        if rec["tier"] is None:
            rec["tier"] = bus_tier(raw.get("severity"))
    rec["ts"] = normalize_ts(rec["ts"])
    rec["status"] = _coerce_int(rec["status"])
    rec["asn"] = _coerce_int(rec["asn"])
    rec["port"] = _coerce_int(rec["port"])
    rec["tier"] = _coerce_int(rec["tier"])
    rec["bytes"] = _coerce_int(rec["bytes"])
    rec["sid"] = _coerce_int(rec["sid"])
    for field in ("signature", "technique", "detector", "tool", "proto"):
        if rec[field] is not None:
            rec[field] = str(rec[field])
    return rec


def parse_clf_line(line: str) -> dict | None:
    """Parse one Apache/nginx common or combined access-log line."""
    m = _CLF_RE.match(line.strip())
    if not m:
        return None
    target = m.group("target") or ""
    path, _, query = target.partition("?")
    rec = blank_record()
    rec.update(
        ts=normalize_ts(m.group("time")),
        ip=m.group("ip"),
        method=m.group("method"),
        path=path or "/",
        query=query or "",
        status=_coerce_int(m.group("status")),
        bytes=_coerce_int(m.group("bytes")),
        referer=(m.group("referer") or "") if m.group("referer") != "-" else "",
        userAgent=(m.group("ua") or "") if m.group("ua") != "-" else "",
        proto="http",
    )
    # An access log carries no tier; derive the coarse one the reports use so
    # 'reason' means the same thing across sources.
    rec["reason"] = "error" if (rec["status"] or 0) >= 400 else "normal"
    rec["tier"] = 1 if (rec["status"] or 0) >= 400 else 0
    return rec


def _load_scanwatch():
    """Load scripts/rain/orionx-scanwatch as the single drop-line authority."""
    return _load_rain_module("orionx-scanwatch", "orionx_scanwatch")


_SCANWATCH = _load_scanwatch()
DROPLOG_AVAILABLE = _SCANWATCH is not None and hasattr(_SCANWATCH, "parse_drop_line")

# A syslog/journal line prefixes the kernel record with a date. Pull that out
# so a historical drop still carries a timestamp; the record body itself is
# parsed only by scanwatch.
_SYSLOG_TS = re.compile(r"^([A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s")
_ISO_TS = re.compile(r"^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}\S*)\s")


def parse_droplog_line(line: str, year: int | None = None) -> dict | None:
    """Parse one nftables [ORIONX-DROP] line via the scanwatch parser."""
    if not DROPLOG_AVAILABLE:
        return None
    parsed = _SCANWATCH.parse_drop_line(line)
    if parsed is None:
        return None
    ts = ""
    iso = _ISO_TS.match(line)
    syslog = _SYSLOG_TS.match(line)
    if iso:
        ts = normalize_ts(iso.group(1))
    elif syslog:
        # Syslog's "Sep 24 13:37:02" carries no year; take it from the caller
        # (the file's mtime year, normally) rather than inventing one.
        stamp = syslog.group(1)
        yr = year or datetime.now(timezone.utc).year
        try:
            dt = datetime.strptime(f"{yr} {stamp}", "%Y %b %d %H:%M:%S")
            ts = normalize_ts(dt.replace(tzinfo=timezone.utc).isoformat())
        except ValueError:
            ts = ""
    rec = blank_record()
    rec.update(
        ts=ts, ip=parsed["src"], port=parsed["port"], proto=parsed["proto"],
        reason="firewall_drop", tier=2, path=f"port:{parsed['port']}",
        method="DROP", status=None,
    )
    return rec


def parse_line(line: str, stats: dict | None = None) -> dict | None:
    """Sniff one line of evidence and normalize it, or return None.

    Order matters: JSON is unambiguous, a drop line is a kernel record that
    can also appear inside a JSON-free syslog file, and CLF is last because
    its regex is the loosest. `stats` is handed to the JSON parser only; it is
    the one that flattens bus detail.
    """
    if not line.strip():
        return None
    rec = parse_json_line(line, stats)
    if rec is not None:
        return rec
    for parser in (parse_droplog_line, parse_clf_line):
        rec = parser(line)
        if rec is not None:
            return rec
    return None


# ---------------------------------------------------------------------------
# local source
# ---------------------------------------------------------------------------
_SKIP_SUFFIXES = (".gz", ".xz", ".zst", ".bz2", ".pcap", ".pcapng")


def iter_local_paths(target: Path) -> list[Path]:
    """Expand a file or directory into the evidence files to read, sorted."""
    if target.is_file():
        return [target]
    if target.is_dir():
        found = [p for p in sorted(target.rglob("*"))
                 if p.is_file() and p.suffix.lower() not in _SKIP_SUFFIXES]
        if not found:
            raise SourceError(f"no readable files under {target}",
                              "point --path at a log file or a directory of them")
        return found
    raise SourceError(f"no such file or directory: {target}",
                      "local is the default source; --path takes a file, a "
                      "directory, or - for stdin")


def _human_size(size: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if size < 1024 or unit == "GiB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} GiB"


# How often a long read reports that it is still alive. Every line costs one
# modulo; a 100k-line beat is about once a second on the reference deck.
PROGRESS_EVERY_LINES = 100_000


def _read_stream(stream, origin: str, records: list[dict], progress=None):
    """Parse one text stream into records. Returns (parsed, skipped, stats).

    stats is the new_parse_stats() dict the bus-detail flattening filled; it
    is narrated under -v here so the flattening is a visible step, not an
    invisible side effect of parsing.
    """
    parsed = skipped = 0
    stats = new_parse_stats()
    for lineno, line in enumerate(stream, 1):
        rec = parse_line(line, stats)
        if rec is None:
            skipped += 1
        else:
            rec["origin"] = origin
            records.append(rec)
            parsed += 1
        if progress and lineno % PROGRESS_EVERY_LINES == 0:
            progress(f"{origin}: {lineno:,} line(s) read, "
                     f"{parsed:,} record(s) so far")
    if progress and stats["bus_events"]:
        progress(f"{origin}: flatten bus detail — {stats['detail_flattened']} of "
                 f"{stats['bus_events']} bus event(s) carried detail "
                 f"(ip/port/signature/sid/technique/detector/tool lifted onto "
                 f"the record), {stats['sidecar_read']} completed from a "
                 f"sidecar, {stats['sidecar_unreadable']} sidecar(s) unreadable, "
                 f"{stats['detail_truncated']} truncated by the broker")
    return parsed, skipped, stats


def _sidecar_notes(origin: str, stats: dict, notes: list[str]) -> None:
    """An unreadable sidecar is an observation the operator must see."""
    if stats.get("sidecar_unreadable"):
        notes.append(f"{origin}: {stats['sidecar_unreadable']} detail sidecar(s) "
                     f"unreadable — those records carry the truncated inline "
                     f"detail only (first: {stats.get('sidecar_notes', ['?'])[0]})")
    if stats.get("detail_truncated"):
        notes.append(f"{origin}: {stats['detail_truncated']} event(s) were "
                     f"truncated by the broker with no sidecar (_truncated)")


def read_local(target, stdin=None, progress=None) -> tuple[list[dict], list[str]]:
    """Read local evidence. Needs no credentials, no network, no key.

    Returns (records, notes). Notes are operator-facing observations, not
    errors: files that yielded nothing are named rather than silently skipped.
    progress, when given, is called with a line of narration as each file
    starts, every PROGRESS_EVERY_LINES lines, and as each file finishes — the
    -v trace, so a long read is never indistinguishable from a hang.
    """
    notes: list[str] = []
    records: list[dict] = []
    if str(target) == "-":
        stream = stdin if stdin is not None else sys.stdin
        if progress:
            progress("reading stdin until end of input")
        started = time.monotonic()
        parsed, skipped, stats = _read_stream(stream, "-", records, progress)
        if progress:
            progress(f"stdin: done in {time.monotonic() - started:.1f}s")
        notes.append(f"stdin: {parsed} record(s), {skipped} unparsed line(s)")
        _sidecar_notes("stdin", stats, notes)
        return records, notes

    paths = iter_local_paths(Path(target))
    if progress:
        total = sum(p.stat().st_size for p in paths if p.exists())
        progress(f"{target}: {len(paths)} file(s) to read, {_human_size(total)}")
    for index, path in enumerate(paths, 1):
        if progress:
            try:
                size = _human_size(path.stat().st_size)
            except OSError:
                size = "size unknown"
            progress(f"[{index}/{len(paths)}] {path} ({size})")
        started = time.monotonic()
        try:
            with open(path, "r", errors="replace") as handle:
                parsed, skipped, stats = _read_stream(handle, str(path), records,
                                                      progress)
        except OSError as exc:
            notes.append(f"{path}: unreadable ({exc.strerror})")
            continue
        if progress:
            progress(f"[{index}/{len(paths)}] {parsed:,} record(s), "
                     f"{skipped:,} unparsed line(s) in "
                     f"{time.monotonic() - started:.1f}s")
        if parsed == 0:
            notes.append(f"{path}: no recognizable records ({skipped} line(s))")
        else:
            notes.append(f"{path}: {parsed} record(s)")
        _sidecar_notes(str(path), stats, notes)
    return records, notes


# ---------------------------------------------------------------------------
# object-store sources (r2, s3) — boto3 is optional and named when absent
# ---------------------------------------------------------------------------
def load_env_file(path: Path) -> dict:
    """Read KEY=value lines from a credentials file, warning on loose modes.

    Values are returned to the caller and never logged by this module.
    """
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("export "):
            stripped = stripped[7:]
        key, sep, value = stripped.partition("=")
        if not sep:
            continue
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            out[key] = value
    return out


def credentials_for(source: str, env_file: Path | None, environ=None) -> dict:
    """Resolve the credentials one object-store source needs.

    Raises SourceError naming only the missing VARIABLE NAMES — never a value.
    """
    environ = os.environ if environ is None else environ
    env = dict(load_env_file(env_file)) if env_file else {}

    def pick(*names):
        for name in names:
            value = env.get(name) or environ.get(name)
            if value:
                return value
        return None

    if source == "r2":
        creds = {
            "account_id": pick("R2_ACCOUNT_ID", "R2_S3_ACCOUNT_ID"),
            "access_key": pick("R2_ACCESS_KEY_ID", "R2_S3_ACCESS_KEY_ID"),
            "secret_key": pick("R2_SECRET_ACCESS_KEY", "R2_S3_SECRET_ACCESS_KEY"),
            "bucket": pick("R2_BUCKET", "R2_S3_BUCKET"),
        }
        required = ("account_id", "access_key", "secret_key", "bucket")
        names = {"account_id": "R2_ACCOUNT_ID", "access_key": "R2_ACCESS_KEY_ID",
                 "secret_key": "R2_SECRET_ACCESS_KEY", "bucket": "R2_BUCKET"}
    else:
        creds = {
            "endpoint": pick("S3_ENDPOINT_URL", "AWS_ENDPOINT_URL"),
            "access_key": pick("AWS_ACCESS_KEY_ID", "S3_ACCESS_KEY_ID"),
            "secret_key": pick("AWS_SECRET_ACCESS_KEY", "S3_SECRET_ACCESS_KEY"),
            "bucket": pick("S3_BUCKET"),
            "region": pick("AWS_DEFAULT_REGION", "S3_REGION") or "us-east-1",
        }
        required = ("access_key", "secret_key", "bucket")
        names = {"access_key": "AWS_ACCESS_KEY_ID",
                 "secret_key": "AWS_SECRET_ACCESS_KEY", "bucket": "S3_BUCKET"}

    missing = [names[k] for k in required if not creds.get(k)]
    if missing:
        where = str(env_file) if env_file else DEFAULT_ENV_FILE
        raise SourceError(
            f"{source}: missing credential(s): {', '.join(missing)}",
            f"put them in {where} (chmod 600), pass --env, or export them. "
            "Local evidence needs none of this: --path <file>.")
    return creds


def day_prefixes(start: datetime | None, base: str,
                 now: datetime | None = None) -> list[str]:
    """Expand a window into the day-partitioned key prefixes to list."""
    if start is None:
        return [f"{base}/"]
    now = now or datetime.now(timezone.utc)
    out, day, end = [], start.date(), now.date()
    while day <= end:
        out.append(f"{base}/{day.year:04d}/{day.month:02d}/{day.day:02d}/")
        day += timedelta(days=1)
    return out


def _require_boto3():
    try:
        import boto3  # noqa: F401
        from botocore.config import Config  # noqa: F401
    except ImportError as exc:
        raise SourceError(
            "object-store sources need python3-boto3, which is not installed",
            "install it (sudo apt-get install python3-boto3), or work from "
            "local evidence: --source local --path <file>") from exc
    import boto3
    from botocore.config import Config
    return boto3, Config


def read_object_store(source: str, creds: dict, prefixes: list[str],
                      unseal=None, limit: int | None = None,
                      endpoint: str | None = None,
                      progress=None) -> tuple[list[dict], list[str]]:
    """List and read sealed/plain objects from R2 or a generic S3 endpoint.

    progress narrates the listing and every 25th fetch for -v. It is given
    bucket, prefix and counts only — never a key's contents or an error body.
    """
    boto3, Config = _require_boto3()
    if source == "r2":
        url = f"https://{creds['account_id']}.r2.cloudflarestorage.com"
        region = "auto"
    else:
        url = endpoint or creds.get("endpoint")
        region = creds.get("region", "us-east-1")
    client = boto3.client(
        "s3", endpoint_url=url, region_name=region,
        aws_access_key_id=creds["access_key"],
        aws_secret_access_key=creds["secret_key"],
        config=Config(retries={"max_attempts": 5, "mode": "standard"}))
    bucket = creds["bucket"]

    keys: list[str] = []
    paginator = client.get_paginator("list_objects_v2")
    for prefix in prefixes:
        if progress:
            progress(f"{source}: listing {bucket}/{prefix}")
        try:
            for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
                for obj in page.get("Contents", []):
                    keys.append(obj["Key"])
                    if limit and len(keys) >= limit:
                        break
                if limit and len(keys) >= limit:
                    break
        except Exception as exc:  # botocore raises a wide family
            raise SourceError(f"{source}: could not list {bucket}/{prefix}: {exc}",
                              "check the credentials file and the bucket scope") from exc
        if limit and len(keys) >= limit:
            break

    if progress:
        progress(f"{source}: {len(keys)} object(s) to fetch")
    records, notes = [], []
    bad = 0
    for index, key in enumerate(keys, 1):
        if progress and (index % 25 == 0 or index == len(keys)):
            progress(f"{source}: fetched {index}/{len(keys)} object(s), "
                     f"{len(records)} record(s) so far")
        try:
            body = client.get_object(Bucket=bucket, Key=key)["Body"].read()
            payload = json.loads(body)
            if unseal is not None and isinstance(payload, dict) and "ciphertext" in payload:
                payload = unseal(payload)
            for rec in _records_from_payload(payload, origin=f"{source}:{key}"):
                records.append(rec)
        except Exception:
            # Never echo the object body or the exception detail: a decrypt
            # failure message can carry key/ciphertext fragments.
            bad += 1
    notes.append(f"{source}: {len(keys)} object(s), {len(records)} record(s)"
                 + (f", {bad} unreadable" if bad else ""))
    return records, notes


# ---------------------------------------------------------------------------
# remote API source — stdlib urllib, no third-party dependency
# ---------------------------------------------------------------------------
def read_api(url: str, token: str | None = None, timeout: int = 30,
             opener=None, progress=None) -> tuple[list[dict], list[str]]:
    """Pull records from a remote HTTP endpoint returning NDJSON or JSON.

    Deliberately stdlib-only: an IR tool that cannot reach its own evidence
    because a pip package is missing has failed at the moment it matters.
    """
    import urllib.error
    import urllib.request

    if not url.lower().startswith(("http://", "https://")):
        raise SourceError(f"api: refusing non-HTTP url: {url}",
                          "--api-url takes an http:// or https:// endpoint")
    request = urllib.request.Request(url, headers={"Accept": "application/x-ndjson, application/json"})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    if progress:
        # The URL is operator-supplied and already on their command line; the
        # token is never part of it.
        progress(f"api: GET {url} (timeout {timeout}s)")
    try:
        opener = opener or urllib.request.urlopen
        with opener(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        # Report the status, never the response body — it may echo the token.
        raise SourceError(f"api: {url} returned HTTP {exc.code}",
                          "check the endpoint and the token file") from exc
    except (urllib.error.URLError, OSError) as exc:
        raise SourceError(f"api: could not reach {url}",
                          f"{type(exc).__name__} — check connectivity and "
                          "the Shields Up posture") from exc
    if progress:
        progress(f"api: received {_human_size(len(body))}")
    return _records_from_text(body, origin=f"api:{url}")


def _records_from_text(body: str, origin: str) -> tuple[list[dict], list[str]]:
    text = body.strip()
    records: list[dict] = []
    if text.startswith("["):
        try:
            payload = json.loads(text)
        except ValueError as exc:
            raise SourceError(f"{origin}: response is not valid JSON") from exc
        records = list(_records_from_payload(payload, origin))
    else:
        for line in text.splitlines():
            rec = parse_line(line)
            if rec is not None:
                rec["origin"] = origin
                records.append(rec)
    return records, [f"{origin}: {len(records)} record(s)"]


def _records_from_payload(payload, origin: str):
    items = payload if isinstance(payload, list) else [payload]
    for item in items:
        if not isinstance(item, dict):
            continue
        rec = parse_json_line(json.dumps(item))
        if rec is not None:
            rec["origin"] = origin
            yield rec


# ---------------------------------------------------------------------------
# window + focus filtering (applied uniformly, whatever the source)
# ---------------------------------------------------------------------------
def apply_window(records: list[dict], start: datetime | None) -> list[dict]:
    """Drop records older than the window. Records with no timestamp are kept.

    Keeping untimed records is deliberate: silently discarding evidence
    because a log line had no parseable clock is exactly the quiet data loss
    this tool exists to avoid. They are counted in the run banner instead.
    """
    if start is None:
        return list(records)
    cutoff = start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")
    return [r for r in records if not r.get("ts") or r["ts"] >= cutoff]


# ---------------------------------------------------------------------------
# --focus : narrow any report to an indicator, in Python rather than SQL.
#
# Upstream builds a SQL WHERE clause by string-concatenating the operator's
# --focus tokens. That is a SQL-injection shape in a tool that also accepts
# --sql, and it means focus works only for the SQL reports. Filtering the
# record list instead is safe by construction and applies uniformly to the
# Python correlation reports too.
# ---------------------------------------------------------------------------
def focus_predicate(focus: str | None):
    """Compile --focus into (predicate, description, skipped_tokens)."""
    if not focus:
        return (lambda rec: True), "", []

    preds, described, skipped = [], [], []
    for token in (t.strip() for t in focus.split(",") if t.strip()):
        low = token.lower()
        try:
            if low.startswith("asn:") or (low.startswith("as") and low[2:].isdigit()):
                number = int(low.split(":", 1)[1] if ":" in low else low[2:])
                preds.append(lambda r, n=number: r.get("asn") == n)
                described.append(f"ASN {number}")
            elif low.startswith(("cc:", "country:")):
                code = token.split(":", 1)[1].upper()
                preds.append(lambda r, c=code: (r.get("country") or "").upper() == c)
                described.append(f"country {code}")
            elif low.startswith("path:"):
                value = token.split(":", 1)[1]
                if value.endswith("*"):
                    preds.append(lambda r, p=value[:-1]: (r.get("path") or "").startswith(p))
                else:
                    preds.append(lambda r, p=value: r.get("path") == p)
                described.append(f"path {value}")
            elif low.startswith("port:"):
                number = int(token.split(":", 1)[1])
                preds.append(lambda r, p=number: r.get("port") == p)
                described.append(f"port {number}")
            elif token.startswith("/"):
                preds.append(lambda r, p=token: r.get("path") == p)
                described.append(f"path {token}")
            elif "/" in token:
                net = ipaddress.ip_network(token, strict=False)
                preds.append(lambda r, n=net: _ip_in_network(r.get("ip"), n))
                described.append(f"network {token}")
            elif "-" in token and token.count(".") >= 3:
                low_s, high_s = (s.strip() for s in token.split("-", 1))
                lo = int(ipaddress.ip_address(low_s))
                hi = int(ipaddress.ip_address(high_s))
                preds.append(lambda r, a=lo, b=hi: _ip_between(r.get("ip"), a, b))
                described.append(f"range {token}")
            else:
                addr = str(ipaddress.ip_address(token))
                preds.append(lambda r, a=addr: r.get("ip") == a)
                described.append(f"address {addr}")
        except ValueError:
            if len(token) == 2 and token.isalpha():
                preds.append(lambda r, c=token.upper(): (r.get("country") or "").upper() == c)
                described.append(f"country {token.upper()}")
            else:
                skipped.append(token)

    if not preds:
        return (lambda rec: True), "", skipped
    return (lambda rec: any(p(rec) for p in preds)), "; ".join(described), skipped


def _ip_in_network(ip, network) -> bool:
    try:
        return ipaddress.ip_address(str(ip)) in network
    except ValueError:
        return False


def _ip_between(ip, low: int, high: int) -> bool:
    try:
        addr = ipaddress.ip_address(str(ip))
    except ValueError:
        return False
    return addr.version == 4 and low <= int(addr) <= high
