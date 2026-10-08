"""logquery_intel — threat intel that is fetched when connected and aged when not.

@decision DEC-PHASE12-027
@title Intel is a cache with a recorded fetch time, and its age is always stated
@status accepted
@rationale The upstream tool reads intel from a build-time file
  (intel/enrichment.json) and, if it is absent, prints one warning. If it is
  present it is used with no regard for when it was written. On a deck that is
  carried to an incident that is the wrong behaviour twice over: a KEV catalog
  from four months ago will happily describe a vulnerability as "actively
  exploited" or not, with no signal that the operator is reading history.

  Silent degradation is the failure mode this project keeps getting burned by
  (DEC-PHASE11-029 shipped byte-identical ISOs; section 32 passed 15/15 on a
  broken squashfs). The rule here is therefore stronger than "warn if
  missing": every run prints the intel's state and age, and a stale cache is
  reported as stale in the banner, in --format json, and on the R.A.I.N. bus.
  There is no code path that enriches a record and stays quiet about how old
  the intel was.

@decision DEC-PHASE12-027
@title Two-part intel: curated base in the repo, volatile catalog in the cache
@status accepted
@rationale Splitting intel by how it changes keeps one authority per fact.
  Tool user-agent signatures, research-scanner identities and datacenter ASNs
  are curation: they belong in the repo, version with the code, and are
  reviewable in a diff. The CISA KEV catalog changes weekly and must never be
  committed, or the ISO would ship a snapshot that looks authoritative and
  silently rots. So the base ships, the catalog is fetched by
  orionx-freshen-intel, and only the fetched half carries a staleness clock.
  An unfreshened deck still enriches — it just says so.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
from pathlib import Path

# Where the fetched half lives. /var/lib/orionx is the established Orion-X
# state root (orionx-heald, orionx-postured, first-boot all write there).
DEFAULT_CACHE_DIR = Path("/var/lib/orionx/logquery/intel")
CACHE_DIR_ENV = "ORIONX_LOGQUERY_INTEL_DIR"

# The curated half, committed beside this module and rsynced to
# /opt/orionx/scripts/logquery/ with the rest of scripts/.
BASE_INTEL_FILE = Path(__file__).resolve().parent / "intel-base.json"

CATALOG_FILE = "kev.json"
METADATA_FILE = "fetched.json"

# Age thresholds. Chosen against how fast each half actually moves: CISA
# publishes KEV additions roughly weekly, so a cache inside a week is
# current; a month behind has missed several publication cycles and must be
# called stale rather than merely old.
FRESH_DAYS = 7.0
STALE_DAYS = 30.0

STATE_MISSING = "missing"
STATE_FRESH = "fresh"
STATE_AGING = "aging"
STATE_STALE = "stale"
STATE_UNDATED = "undated"


def cache_dir(explicit=None) -> Path:
    """Resolve the intel cache directory. The env override exists for tests."""
    if explicit:
        return Path(explicit)
    from_env = os.environ.get(CACHE_DIR_ENV)
    if from_env:
        return Path(from_env)
    return DEFAULT_CACHE_DIR


# ---------------------------------------------------------------------------
# freshness (pure — no filesystem, no clock of its own)
# ---------------------------------------------------------------------------
def intel_freshness(fetched_at: float | None, now: float,
                    fresh_days: float = FRESH_DAYS,
                    stale_days: float = STALE_DAYS) -> dict:
    """Classify a cache's age. Returns state, age in days, and whether to warn.

    `fetched_at` of None means nothing has ever been fetched (state missing).
    A fetch time in the future is treated as undated rather than fresh: a
    skewed clock must not be able to make old intel look current.
    """
    if fetched_at is None:
        return {"state": STATE_MISSING, "age_days": None, "warn": True,
                "label": "no threat intel fetched yet"}
    age_seconds = now - float(fetched_at)
    if age_seconds < -3600:
        return {"state": STATE_UNDATED, "age_days": None, "warn": True,
                "label": "intel fetch time is in the future (clock skew) — "
                         "age cannot be trusted"}
    age_days = max(age_seconds, 0.0) / 86400.0
    if age_days <= fresh_days:
        state, warn = STATE_FRESH, False
    elif age_days <= stale_days:
        state, warn = STATE_AGING, False
    else:
        state, warn = STATE_STALE, True
    return {"state": state, "age_days": age_days, "warn": warn,
            "label": f"threat intel is {age_days:.1f} day(s) old ({state})"}


def freshness_banner(freshness: dict, catalog_count: int | None = None) -> str:
    """One operator-facing line. Always printed; never suppressed on success."""
    state = freshness["state"]
    detail = ""
    if catalog_count is not None and state not in (STATE_MISSING,):
        detail = f", {catalog_count} KEV entr{'y' if catalog_count == 1 else 'ies'}"
    if state == STATE_MISSING:
        return ("intel: NONE FETCHED — enrichment runs on the curated base only. "
                "Run: sudo orionx-freshen-intel")
    if state == STATE_STALE:
        return (f"intel: STALE — last fetched {freshness['age_days']:.1f} days ago"
                f"{detail}. Treat KEV/CVE columns as history, not current. "
                "Run: sudo orionx-freshen-intel")
    if state == STATE_UNDATED:
        return f"intel: AGE UNKNOWN — {freshness['label']}{detail}"
    return (f"intel: {state} — fetched {freshness['age_days']:.1f} days ago"
            f"{detail}")


# ---------------------------------------------------------------------------
# cache I/O
# ---------------------------------------------------------------------------
def read_metadata(directory: Path) -> dict | None:
    """Read the recorded fetch metadata, or None if nothing was ever fetched."""
    path = Path(directory) / METADATA_FILE
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def write_metadata(directory: Path, source_url: str, digest: str,
                   catalog_count: int, catalog_version: str = "",
                   now: float | None = None) -> dict:
    """Record what was fetched, from where, and exactly when.

    The timestamp is the whole point: it is what makes staleness reportable
    instead of guessable. Written atomically so an interrupted freshen cannot
    leave a catalog with no clock beside it.
    """
    now = time.time() if now is None else now
    meta = {
        "fetched_at": now,
        "fetched_iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
        "source_url": source_url,
        "sha256": digest,
        "catalog_count": catalog_count,
        "catalog_version": catalog_version,
    }
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    tmp = directory / (METADATA_FILE + ".tmp")
    tmp.write_text(json.dumps(meta, indent=2) + "\n")
    tmp.replace(directory / METADATA_FILE)
    return meta


def sha256_file(path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_base_intel(path=None) -> dict:
    """Load the curated half. Absence is a packaging bug, not an operator error."""
    path = Path(path) if path else BASE_INTEL_FILE
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {"signatures": [], "research_scanners": [], "paths": {},
                "datacenter_asns": {}, "version": "unavailable"}
    return data


def load_catalog(directory: Path) -> dict:
    """Load the fetched KEV catalog as {cve_id: {"ransomware": bool, ...}}."""
    path = Path(directory) / CATALOG_FILE
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def load_intel(directory=None, base_path=None, now: float | None = None) -> dict:
    """Assemble the merged intel view plus its freshness verdict.

    The returned dict always carries a "freshness" key. Callers render it; no
    caller is able to obtain enrichment data without it.
    """
    directory = cache_dir(directory)
    now = time.time() if now is None else now
    base = load_base_intel(base_path)
    catalog = load_catalog(directory)
    meta = read_metadata(directory)
    fetched_at = None
    if meta is not None:
        value = meta.get("fetched_at")
        if isinstance(value, (int, float)):
            fetched_at = float(value)
        else:
            fetched_at = None
        if fetched_at is None:
            # A catalog with no usable clock is worse than none: report it.
            meta = dict(meta)
            meta["fetched_at"] = None
    freshness = intel_freshness(fetched_at, now)
    if meta is None and catalog:
        # Catalog on disk with no metadata beside it — refuse to call it dated.
        freshness = {"state": STATE_UNDATED, "age_days": None, "warn": True,
                     "label": "KEV catalog present but its fetch time was not "
                              "recorded — age unknown"}
    return {
        "signatures": base.get("signatures", []),
        "research_scanners": base.get("research_scanners", []),
        "paths": base.get("paths", {}),
        "datacenter_asns": base.get("datacenter_asns", {}),
        "base_version": base.get("version", "unknown"),
        "kev": catalog,
        "catalog_count": len(catalog),
        "metadata": meta,
        "freshness": freshness,
        "cache_dir": str(directory),
    }


# ---------------------------------------------------------------------------
# enrichment (pure given an intel dict)
# ---------------------------------------------------------------------------
_BROWSER = re.compile(r"Mozilla/5\.0")
_BROWSER_ENGINE = re.compile(r"(Chrome|Firefox|Safari|Edg)/")
_NOT_BROWSER = re.compile(r"bot|crawl|spider|headless|preview", re.I)


def browser_like(ua: str) -> bool:
    """True when a user-agent claims to be an interactive browser."""
    ua = ua or ""
    return bool(_BROWSER.search(ua) and _BROWSER_ENGINE.search(ua)
                and not _NOT_BROWSER.search(ua))


ENRICHMENT_FIELDS = ("tool", "tool_conf", "category", "product", "prevalence",
                     "cve", "kev", "kev_ransomware", "research_org", "spoof")


def enrich_record(rec: dict, intel: dict | None) -> dict:
    """Add the enrichment columns to one record, in place, and return it.

    kev/kev_ransomware are 0/1 integers, not booleans: the SQL layer has to
    behave the same on SQLite (which has no boolean type) and DuckDB, and one
    representation in both beats a cast in each report.
    """
    ua = rec.get("userAgent") or ""
    path = rec.get("path") or ""
    tool = tool_conf = category = product = prevalence = cve = research = ""
    kev = kev_ransomware = 0
    spoof: list[str] = []

    if intel:
        for sig in intel.get("signatures", []):
            try:
                if ua and re.search(sig["ua_regex"], ua):
                    tool = sig.get("tool", "")
                    tool_conf = sig.get("confidence", "")
                    category = sig.get("category", "")
                    break
            except (re.error, KeyError):
                continue
        for scanner in intel.get("research_scanners", []):
            try:
                if ua and re.search(scanner["ua_regex"], ua):
                    research = scanner.get("org", "")
                    break
            except (re.error, KeyError):
                continue
        meta = intel.get("paths", {}).get(path)
        if meta:
            product = meta.get("product", "")
            prevalence = meta.get("prevalence", "")
            cves = list(meta.get("related_cve", []))
            cve = ",".join(cves)
            catalog = intel.get("kev", {})
            hits = [catalog[c] for c in cves if c in catalog]
            kev = 1 if hits else 0
            kev_ransomware = 1 if any(h.get("ransomware") for h in hits) else 0
        datacenter = intel.get("datacenter_asns", {}).get(str(rec.get("asn", "")))
        if browser_like(ua):
            if datacenter:
                spoof.append(f"browser-UA/{datacenter}")
            if tool:
                spoof.append(f"UA~{tool}+browser")
        if rec.get("ip") and not ua and rec.get("method") not in (None, "DROP"):
            spoof.append("no-UA")

    rec.update(tool=tool, tool_conf=tool_conf, category=category,
               product=product, prevalence=prevalence, cve=cve, kev=kev,
               kev_ransomware=kev_ransomware, research_org=research,
               spoof=";".join(spoof))
    return rec


def enrich_all(records: list[dict], intel: dict | None) -> list[dict]:
    for rec in records:
        enrich_record(rec, intel)
    return records
