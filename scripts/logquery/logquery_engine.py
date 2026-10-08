"""logquery_engine — one SQL dialect, two engines, stdlib by default.

@decision DEC-PHASE12-027
@title SQLite (stdlib) is the default query engine; DuckDB is an opt-in accelerator
@status accepted
@rationale Upstream hard-requires DuckDB: `import duckdb` or die, plus
  `read_json_auto()`, `any_value()`, `date_trunc()`, `split_part()`,
  `regexp_matches()` and `::int` casts throughout. Porting that requirement as
  written would mean an incident-response tool on this deck cannot run a report
  until someone installs a package.

  DuckDB is not in Debian main, so keeping it as a hard dependency means either
  a vendored wheel per architecture in the ISO (tens of megabytes, a
  maintenance burden, and a pinned SHA to chase) or a pip install at the moment
  an operator least wants one. Measured against what the reports actually do —
  GROUP BY, COUNT DISTINCT, MIN/MAX and ORDER BY over at most the tens of
  thousands of records one incident produces — SQLite does the whole job, and
  it is already in the Python standard library, so it costs nothing and cannot
  be missing.

  DuckDB is kept as an explicit opt-in (`--engine duckdb`) because it is
  genuinely faster on large captures and some operators will want to hand it a
  million rows. It is installed, if wanted, through the optional-installer
  pattern (DEC-PHASE11-011) at
  /opt/orionx/optional/install-duckdb.sh, exactly like Ghidra. When it is
  absent and asked for, the operator gets one sentence naming the installer,
  not an ImportError traceback.

  `--engine auto` is deliberately NOT provided. An engine that silently
  changes under the operator depending on what happens to be installed is the
  dual-authority bug this project forbids: two engines could disagree on a
  report and nothing in the output would say which one ran. The engine is
  always named in the run banner.

@decision DEC-PHASE12-027
@title Report SQL is written once, in the subset both engines share
@status accepted
@rationale Maintaining a SQLite dialect and a DuckDB dialect of the same
  report would be two authorities over one question. Instead the ingest layer
  precomputes what the dialects disagree about — ts is a sortable ISO string so
  no CAST is needed, ip_int is materialized so CIDR math needs no split_part,
  day/hour are materialized so no date_trunc is needed, and kev is 0/1 so no
  boolean cast is needed — and the one construct left, regexp matching, is
  registered as the same `re_match(pattern, text)` function on both engines.
"""
from __future__ import annotations

import ipaddress
import re
import sqlite3

from logquery_intel import ENRICHMENT_FIELDS
from logquery_sources import RECORD_FIELDS

ENGINES = ("sqlite", "duckdb")
DEFAULT_ENGINE = "sqlite"

# Columns materialized beyond the record + enrichment fields, so that report
# SQL needs no engine-specific function to reach them.
DERIVED_FIELDS = ("ip_int", "day", "hour")

TABLE_COLUMNS = tuple(RECORD_FIELDS) + tuple(ENRICHMENT_FIELDS) + DERIVED_FIELDS

_TEXT_FIELDS = {"ts", "ip", "method", "path", "query", "userAgent", "referer",
                "asOrganization", "country", "reason", "proto", "origin",
                "tool", "tool_conf", "category", "product", "prevalence",
                "cve", "research_org", "spoof", "day"}
_INT_FIELDS = {"status", "bytes", "asn", "tier", "port", "kev",
               "kev_ransomware", "ip_int", "hour"}


class EngineUnavailable(Exception):
    """A requested engine is not installed. Carries the installer hint."""

    def __init__(self, message: str, hint: str = ""):
        super().__init__(message)
        self.hint = hint


def re_match(pattern, text) -> int:
    """Case-insensitive regex test, registered identically on both engines."""
    if pattern is None or text is None:
        return 0
    try:
        return 1 if re.search(str(pattern), str(text), re.I) else 0
    except re.error:
        return 0


def _typed_re_match(pattern: str, text: str) -> int:
    """Type-annotated wrapper: DuckDB infers a UDF's signature from hints."""
    return re_match(pattern, text)


def ip_to_int(ip) -> int | None:
    """IPv4 address as an integer, for CIDR and range math inside SQL."""
    if not ip:
        return None
    try:
        addr = ipaddress.ip_address(str(ip))
    except ValueError:
        return None
    return int(addr) if addr.version == 4 else None


def to_row(rec: dict) -> tuple:
    """Flatten one enriched record into the table's column order."""
    row = []
    for column in TABLE_COLUMNS:
        if column == "ip_int":
            row.append(ip_to_int(rec.get("ip")))
            continue
        if column == "day":
            row.append((rec.get("ts") or "")[:10] or None)
            continue
        if column == "hour":
            hour = (rec.get("ts") or "")[11:13]
            row.append(int(hour) if hour.isdigit() else None)
            continue
        value = rec.get(column)
        if column in _INT_FIELDS:
            if isinstance(value, bool):
                value = int(value)
            elif not isinstance(value, int):
                try:
                    value = int(value) if value not in (None, "") else None
                except (TypeError, ValueError):
                    value = None
        elif column in _TEXT_FIELDS and value is not None:
            value = str(value)
        row.append(value)
    return tuple(row)


class Engine:
    """A loaded corpus that answers SQL over table `r`."""

    def __init__(self, name: str, connection, columns, regex_available=True,
                 regex_note: str = ""):
        self.name = name
        self._conn = connection
        self.columns = columns
        # Whether re_match() could be registered. Reports that need it check
        # this and refuse, rather than running a query that would silently
        # return a wrong answer.
        self.regex_available = regex_available
        self.regex_note = regex_note

    def query(self, sql: str) -> tuple[list[str], list[tuple]]:
        raise NotImplementedError

    def close(self):
        try:
            self._conn.close()
        except Exception:
            pass


class SqliteEngine(Engine):
    def __init__(self, records):
        conn = sqlite3.connect(":memory:")
        conn.create_function("re_match", 2, re_match)
        decls = []
        for column in TABLE_COLUMNS:
            kind = "INTEGER" if column in _INT_FIELDS else "TEXT"
            decls.append(f'"{column}" {kind}')
        conn.execute(f"CREATE TABLE r ({', '.join(decls)})")
        placeholders = ", ".join("?" * len(TABLE_COLUMNS))
        conn.executemany(f"INSERT INTO r VALUES ({placeholders})",
                         (to_row(rec) for rec in records))
        conn.commit()
        super().__init__("sqlite", conn, TABLE_COLUMNS)

    def query(self, sql: str):
        cursor = self._conn.execute(sql)
        columns = [d[0] for d in (cursor.description or [])]
        return columns, cursor.fetchall()


class DuckdbEngine(Engine):
    def __init__(self, records):
        try:
            import duckdb
        except ImportError as exc:
            raise EngineUnavailable(
                "the duckdb engine was requested but duckdb is not installed",
                "install it with: sudo /opt/orionx/optional/install-duckdb.sh\n"
                "  or just drop the flag — the default sqlite engine is in the "
                "Python standard library and runs every report here.") from exc
        conn = duckdb.connect()
        decls = []
        for column in TABLE_COLUMNS:
            kind = "BIGINT" if column in _INT_FIELDS else "VARCHAR"
            decls.append(f'"{column}" {kind}')
        conn.execute(f"CREATE TABLE r ({', '.join(decls)})")

        # DuckDB's Python scalar UDFs go through its numpy/pyarrow bridge, so
        # `import duckdb` succeeding does NOT mean create_function will. That
        # was measured, not assumed: on a duckdb 1.5.5 install without numpy,
        # registration raises InvalidInputException("'numpy' is required").
        # The failure is recorded and surfaced rather than swallowed — a
        # report that quietly drops its WHERE clause is the exact silent
        # degradation this tool exists to prevent.
        regex_available, regex_note = True, ""
        try:
            conn.create_function("re_match", _typed_re_match)
        except Exception as exc:
            regex_available = False
            regex_note = (f"duckdb could not register the re_match function "
                          f"({type(exc).__name__}). DuckDB's Python UDFs need "
                          f"numpy; install it, or use the default sqlite "
                          f"engine, which has no such requirement.")

        placeholders = ", ".join("?" * len(TABLE_COLUMNS))
        rows = [to_row(rec) for rec in records]
        if rows:
            conn.executemany(f"INSERT INTO r VALUES ({placeholders})", rows)
        super().__init__("duckdb", conn, TABLE_COLUMNS,
                         regex_available=regex_available, regex_note=regex_note)

    def query(self, sql: str):
        relation = self._conn.sql(sql)
        columns = [d[0] for d in relation.description]
        return columns, relation.fetchall()


def duckdb_available() -> bool:
    try:
        import duckdb  # noqa: F401
    except ImportError:
        return False
    return True


def make_engine(name: str, records: list[dict]) -> Engine:
    """Build the named engine over the corpus. Never falls back silently."""
    if name == "sqlite":
        return SqliteEngine(records)
    if name == "duckdb":
        return DuckdbEngine(records)
    raise EngineUnavailable(f"unknown engine: {name}",
                            f"choose one of: {', '.join(ENGINES)}")


# ---------------------------------------------------------------------------
# preset reports — one text per report, valid on both engines
# ---------------------------------------------------------------------------
SQL_REPORTS = {
    "summary": """
SELECT coalesce(nullif(reason,''),'(none)') AS reason,
       coalesce(max(tier),0) AS max_tier,
       count(*) AS events, count(DISTINCT ip) AS uniq_sources,
       min(ts) AS first_seen, max(ts) AS last_seen
FROM r GROUP BY reason ORDER BY events DESC""",

    "sources": """
SELECT ip, max(asOrganization) AS org, max(country) AS country,
       count(*) AS hits, count(DISTINCT path) AS paths,
       count(DISTINCT day) AS active_days, max(tier) AS max_tier,
       min(ts) AS first_seen, max(ts) AS last_seen
FROM r WHERE ip IS NOT NULL GROUP BY ip ORDER BY hits DESC LIMIT 40""",

    "paths": """
SELECT coalesce(path,'(none)') AS path, count(*) AS hits,
       count(DISTINCT ip) AS uniq_sources, max(status) AS status,
       max(tier) AS max_tier
FROM r GROUP BY path ORDER BY hits DESC LIMIT 40""",

    "asn": """
SELECT asn, max(asOrganization) AS org, count(*) AS hits,
       count(DISTINCT ip) AS uniq_sources, max(tier) AS max_tier
FROM r WHERE asn IS NOT NULL GROUP BY asn ORDER BY hits DESC LIMIT 30""",

    "countries": """
SELECT coalesce(country,'(unknown)') AS country, count(*) AS hits,
       count(DISTINCT ip) AS uniq_sources
FROM r GROUP BY country ORDER BY hits DESC LIMIT 30""",

    "agents": """
SELECT substr(coalesce(nullif(userAgent,''),'(none)'),1,80) AS ua,
       count(*) AS hits, count(DISTINCT ip) AS uniq_sources
FROM r GROUP BY 1 ORDER BY hits DESC LIMIT 30""",

    "timeline": """
SELECT substr(ts,1,13) AS hour_bucket, count(*) AS hits,
       count(DISTINCT ip) AS uniq_sources,
       sum(CASE WHEN tier >= 2 THEN 1 ELSE 0 END) AS alerts
FROM r WHERE ts <> '' AND ts IS NOT NULL GROUP BY 1 ORDER BY 1""",

    "errors": """
SELECT status, coalesce(path,'(none)') AS path, count(*) AS hits,
       count(DISTINCT ip) AS uniq_sources
FROM r WHERE status >= 400 GROUP BY status, path
ORDER BY hits DESC LIMIT 40""",

    "existence": """
SELECT ip, max(asOrganization) AS org,
       sum(CASE WHEN status >= 400 THEN 1 ELSE 0 END) AS not_found,
       sum(CASE WHEN status < 400 THEN 1 ELSE 0 END) AS served,
       count(DISTINCT path) AS paths,
       round(100.0 * sum(CASE WHEN status >= 400 THEN 1 ELSE 0 END) / count(*)) AS pct_missing
FROM r WHERE ip IS NOT NULL AND status IS NOT NULL
GROUP BY ip HAVING count(*) >= 3
ORDER BY pct_missing DESC, not_found DESC LIMIT 40""",

    "uarotation": """
SELECT ip, max(asOrganization) AS org, count(*) AS hits,
       count(DISTINCT userAgent) AS distinct_uas,
       sum(CASE WHEN userAgent IS NULL OR userAgent = '' THEN 1 ELSE 0 END) AS null_ua,
       CASE WHEN count(DISTINCT userAgent) >= 3 THEN 'rotating (evasion?)'
            WHEN sum(CASE WHEN userAgent IS NULL OR userAgent = '' THEN 1 ELSE 0 END) = count(*) THEN 'always-null'
            WHEN sum(CASE WHEN userAgent IS NULL OR userAgent = '' THEN 1 ELSE 0 END) > 0 THEN 'some-null'
            ELSE 'stable' END AS pattern
FROM r WHERE ip IS NOT NULL GROUP BY ip HAVING count(*) >= 2
ORDER BY distinct_uas DESC, null_ua DESC LIMIT 40""",

    "bots": """
SELECT substr(coalesce(nullif(userAgent,''),'(none)'),1,60) AS ua,
       count(*) AS hits, count(DISTINCT ip) AS uniq_sources,
       max(asOrganization) AS org
FROM r
WHERE re_match('bot|crawl|spider|curl|wget|python|scan|libwww|go-http', coalesce(userAgent,'')) = 1
   OR userAgent IS NULL OR userAgent = ''
GROUP BY 1 ORDER BY hits DESC LIMIT 30""",

    "requests": """
SELECT ts, coalesce(method,'-') AS method, coalesce(path,'-') AS path,
       status, ip, nullif(tool,'') AS tool,
       substr(coalesce(userAgent,'-'),1,45) AS ua,
       coalesce(nullif(referer,''),'-') AS referer,
       coalesce(origin,'-') AS origin
FROM r ORDER BY ts LIMIT 1000""",

    "ports": """
SELECT ip, count(DISTINCT port) AS distinct_ports, count(*) AS drops,
       max(proto) AS proto, min(ts) AS first_seen, max(ts) AS last_seen
FROM r WHERE reason = 'firewall_drop' AND port IS NOT NULL
GROUP BY ip ORDER BY distinct_ports DESC LIMIT 40""",

    # --- enrichment-aware. These columns are empty without a fetched intel
    # --- catalog, and the run banner always states the intel's state and age,
    # --- so an empty column is never mistakable for "nothing found".
    "threats": """
SELECT ts, coalesce(reason,'-') AS reason, ip,
       coalesce(nullif(asOrganization,''),'-') AS org,
       coalesce(country,'-') AS country, coalesce(path,'-') AS path,
       nullif(tool,'') AS tool, nullif(category,'') AS category,
       nullif(cve,'') AS cve,
       CASE WHEN kev_ransomware = 1 THEN 'KEV+RANSOMWARE'
            WHEN kev = 1 THEN 'KEV' ELSE '' END AS exploited,
       nullif(spoof,'') AS flags
FROM r WHERE tier >= 2 OR kev = 1 OR tool <> ''
ORDER BY ts DESC LIMIT 60""",

    "scanners": """
SELECT coalesce(nullif(tool,''),'(unidentified)') AS tool,
       max(nullif(category,'')) AS category, count(*) AS hits,
       count(DISTINCT ip) AS uniq_sources, count(DISTINCT path) AS paths
FROM r WHERE tier >= 1 OR tool <> ''
GROUP BY tool ORDER BY hits DESC LIMIT 30""",

    "campaigns": """
SELECT coalesce(nullif(tool,''),'(unidentified)') AS tool,
       coalesce(nullif(asOrganization,''),'(unknown)') AS org,
       count(DISTINCT ip) AS uniq_sources, count(*) AS hits,
       count(DISTINCT path) AS paths, max(kev) AS any_kev,
       min(ts) AS first_seen, max(ts) AS last_seen
FROM r WHERE tier >= 1 OR tool <> ''
GROUP BY tool, asOrganization HAVING count(*) > 1
ORDER BY hits DESC LIMIT 40""",
}

# The only report that needs the re_match UDF. Named so the CLI can refuse it
# with a useful sentence on an engine that could not register the function,
# rather than returning a silently wrong answer.
SQL_NEEDS_REGEX = ("bots",)

# Reports whose value depends on a fetched intel catalog.
INTEL_DEPENDENT = ("threats", "scanners", "campaigns")

# Reports computed in pure Python (logquery_correlate) — always available.
PYTHON_REPORTS = ("targeted", "similarity", "cadence")

ALL_REPORTS = tuple(sorted(tuple(SQL_REPORTS) + PYTHON_REPORTS))

REPORT_HELP = {
    "summary": "The big picture: what kinds of records, how many, over what span. Start here.",
    "targeted": "Targeted vs widespread, ranked, with the reasons shown. The important one.",
    "similarity": "Give it one address; finds others behaving the same way and says why (--focus).",
    "cadence": "Per-source request rhythm; flags machine-regular spacing (a script, not a person).",
    "sources": "Busiest source addresses: hits, paths, how many separate days.",
    "requests": "Every record as its own row. Best narrowed with --focus.",
    "paths": "Most-requested paths, and how many distinct sources asked for each.",
    "ports": "Firewall drops grouped by source: who touched how many distinct blocked ports.",
    "existence": "Who asks for things that do not exist vs real pages — the blind-scanning tell.",
    "uarotation": "Per-source user-agent behaviour: rotating, always-null, or stable.",
    "asn": "Busiest networks. A datacenter ASN on a personal deck is worth a look.",
    "countries": "Where the traffic came from.",
    "agents": "The user-agent strings seen.",
    "timeline": "Records by the hour, with alert counts.",
    "errors": "Records that returned an error status — often scanning.",
    "bots": "Records that look automated rather than human.",
    "threats": "Every alert, explained: which tool, which CVE, whether it is in KEV.",
    "scanners": "Which scanning tools showed up, by name, and how much.",
    "campaigns": "Groups related alerts so one operator is one row, not forty.",
}
