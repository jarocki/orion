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
RECORD_FIELDS = (
    "ts", "ip", "method", "path", "query", "status", "bytes",
    "userAgent", "referer", "asn", "asOrganization", "country",
    "reason", "tier", "proto", "port", "origin",
)

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
def parse_json_line(line: str) -> dict | None:
    """Parse one NDJSON record, mapping known aliases onto the canonical keys.

    Also accepts a R.A.I.N. bus line (/run/orionx/events.jsonl), whose
    'source'/'category'/'message' shape has no ip or path.
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
        # A bus event's "source" is a component name, not an address.
        if bus_event and key == "source":
            continue
        field = _ALIASES.get(key, key)
        if field in RECORD_FIELDS:
            rec[field] = value
    if bus_event:
        rec["reason"] = raw.get("category") or "bus_event"
        rec["path"] = rec["path"] or str(raw.get("message", ""))[:200]
    rec["ts"] = normalize_ts(rec["ts"])
    rec["status"] = _coerce_int(rec["status"])
    rec["asn"] = _coerce_int(rec["asn"])
    rec["port"] = _coerce_int(rec["port"])
    rec["tier"] = _coerce_int(rec["tier"])
    rec["bytes"] = _coerce_int(rec["bytes"])
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
    here = Path(__file__).resolve()
    candidates = [
        here.parent.parent / "rain" / "orionx-scanwatch",
        Path("/opt/orionx/scripts/rain/orionx-scanwatch"),
    ]
    for candidate in candidates:
        if candidate.is_file():
            try:
                return SourceFileLoader("orionx_scanwatch", str(candidate)).load_module()
            except (OSError, SyntaxError, ImportError):
                return None
    return None


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


def parse_line(line: str) -> dict | None:
    """Sniff one line of evidence and normalize it, or return None.

    Order matters: JSON is unambiguous, a drop line is a kernel record that
    can also appear inside a JSON-free syslog file, and CLF is last because
    its regex is the loosest.
    """
    if not line.strip():
        return None
    for parser in (parse_json_line, parse_droplog_line, parse_clf_line):
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


def read_local(target, stdin=None) -> tuple[list[dict], list[str]]:
    """Read local evidence. Needs no credentials, no network, no key.

    Returns (records, notes). Notes are operator-facing observations, not
    errors: files that yielded nothing are named rather than silently skipped.
    """
    notes: list[str] = []
    records: list[dict] = []
    if str(target) == "-":
        stream = stdin if stdin is not None else sys.stdin
        parsed = skipped = 0
        for line in stream:
            rec = parse_line(line)
            if rec is None:
                skipped += 1
                continue
            rec["origin"] = "-"
            records.append(rec)
            parsed += 1
        notes.append(f"stdin: {parsed} record(s), {skipped} unparsed line(s)")
        return records, notes

    for path in iter_local_paths(Path(target)):
        parsed = skipped = 0
        try:
            with open(path, "r", errors="replace") as handle:
                for line in handle:
                    rec = parse_line(line)
                    if rec is None:
                        skipped += 1
                        continue
                    rec["origin"] = str(path)
                    records.append(rec)
                    parsed += 1
        except OSError as exc:
            notes.append(f"{path}: unreadable ({exc.strerror})")
            continue
        if parsed == 0:
            notes.append(f"{path}: no recognizable records ({skipped} line(s))")
        else:
            notes.append(f"{path}: {parsed} record(s)")
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
                      endpoint: str | None = None) -> tuple[list[dict], list[str]]:
    """List and read sealed/plain objects from R2 or a generic S3 endpoint."""
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

    records, notes = [], []
    bad = 0
    for key in keys:
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
             opener=None) -> tuple[list[dict], list[str]]:
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
