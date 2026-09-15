"""Actor fingerprint pipeline: events + lookup -> portable YAML artifact.

The input is a **pre-grouped** batch of observations (the operator has
already decided "these events belong to actor X"). This module never
sessionizes or streams -- it's a pure function of a list of dicts.

The output is a single actor fingerprint dict (serializable to YAML) that
captures:

  - Which templates the actor's traffic matched (and how many times each)
  - What tool likely produced the traffic (Nuclei vs. other tool consuming
    the same YAMLs vs. custom-Nuclei-shaped tool)
  - The Nuclei CLI options that would have to have been set to produce
    the observed pattern (-tags, -severity, -H, -random-agent,
    -interactsh-server, -rate-limit, -bulk-size, -scan-strategy, ...)
  - The template subset the actor favors, and any novel "Nuclei-shaped"
    probes that didn't match a known template
  - A `structural_hash` derived from the (tool, options, template subset)
    tuple, so two independently generated fingerprints of the same actor
    behavior collapse to the same hash and can be compared directly

The dict is intentionally serialization-ready (only str/int/float/list/
dict, no tuples, no dataclass magic) so callers can `yaml.dump` it
verbatim without adapters.
"""

from __future__ import annotations

import datetime
import hashlib
import io
import json
import re
from collections import Counter
from typing import Any, Iterable

from .quality import MEDIUM, at_least, match_quality
from .runtime import (
    NUCLEI_DEFAULT_OAST_HOSTS,
    is_default_oast_host,
    is_nuclei_default_ua,
    is_nuclei_random_agent_ua,
    tag_intersection,
)


# ---- Event parsing ----------------------------------------------------


def parse_events_jsonl(path_or_text: str) -> list[dict[str, Any]]:
    """Read a JSONL file (or a JSONL string) into a list of event dicts.

    Empty lines are skipped. Lines that fail to parse raise ValueError with
    the line number -- callers can catch and surface the diagnostic.
    """
    if "\n" in path_or_text or path_or_text.strip().startswith("{"):
        source = io.StringIO(path_or_text)
    else:
        source = open(path_or_text, "r")
    events: list[dict[str, Any]] = []
    try:
        for lineno, line in enumerate(source, 1):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as e:
                raise ValueError(f"line {lineno}: {e}") from e
            if not isinstance(ev, dict):
                raise ValueError(f"line {lineno}: expected an object, got {type(ev).__name__}")
            events.append(ev)
    finally:
        if hasattr(source, "close") and not isinstance(source, io.StringIO):
            source.close()
    return events


# ---- Per-event template classification --------------------------------


def classify_event(
    event: dict[str, Any],
    lookup: dict[str, Any],
    *,
    min_quality: str = MEDIUM,
) -> dict[str, Any]:
    """Match a single observation event against the template lookup.

    `min_quality` is the floor a hit must reach, *as matched in this URI*,
    to count as trustworthy (default MEDIUM). A snippet's build-time grade
    is downgraded to WEAK for a hit where the snippet lands mid-token in
    the URI (see `quality.match_quality`).

    Returns a dict with:
      - `matched_templates`: list of template ids whose URI snippet appears
        in the event's URI
      - `trustworthy_templates`: the subset whose hit meets `min_quality`
      - `oast_hosts`: set of hostnames of OAST callback URLs seen in the
        event (drawn from headers, body, and cookies if present)
      - `runtime_signals`: dict of runtime-fingerprint findings, each a
        boolean or an inferred value (looks_like_default_nuclei_ua,
        looks_like_random_agent_ua, oast_host_is_default, ...)
    """
    uri = str(event.get("uri") or event.get("url") or "")
    matched: list[str] = []
    strong_matched: list[str] = []
    snippet_index: dict[str, str] = lookup.get("snippet_index") or {}
    quality_map: dict[str, str] = lookup.get("snippet_quality") or {}
    templates: dict[str, dict] = lookup.get("templates") or {}
    for snippet, tid in sorted(snippet_index.items(), key=lambda kv: -len(kv[0])):
        if snippet and snippet in uri:
            matched.append(tid)
            graded = quality_map.get(snippet) or (
                templates.get(tid, {}).get("snippet_quality")
            ) or "weak"
            # The grade must survive where the snippet lands in *this* URI:
            # `6100` is anchored in its template but not inside a hex string.
            quality = match_quality(snippet, graded, uri)
            if at_least(quality, min_quality):
                strong_matched.append(tid)

    ua = str(event.get("ua") or event.get("user_agent") or "")
    oast_hosts: set[str] = set()

    def _harvest(text: str) -> None:
        for m in re.finditer(r"https?://([^\s\"'/<>&]+)", text):
            host = m.group(1).lower()
            # Common heuristic: any host that ends with a known OAST TLD
            # OR that appears in the request body but is *not* the target
            # host itself is treated as a callback candidate.
            if is_default_oast_host(host) or host in event.get("oast_hosts", []):
                oast_hosts.add(host)

    body = event.get("body") or ""
    if isinstance(body, str):
        _harvest(body)
    for hv in (event.get("headers") or {}).values():
        if isinstance(hv, str):
            _harvest(hv)

    # Explicit oast_hosts field on the event (operator-provided) always
    # wins -- they may know from PCAP that certain hosts got DNS-resolved
    # right after a probe.
    for h in event.get("oast_hosts") or []:
        if isinstance(h, str):
            oast_hosts.add(h.lower())

    return {
        "matched_templates": matched,
        "trustworthy_templates": strong_matched,
        "oast_hosts": sorted(oast_hosts),
        "runtime_signals": {
            "ua_matches_nuclei_default": is_nuclei_default_ua(ua),
            "ua_in_nuclei_random_pool": is_nuclei_random_agent_ua(ua),
            "oast_host_is_default": all(
                is_default_oast_host(h) for h in oast_hosts
            ) if oast_hosts else None,
        },
    }


# ---- CLI-option inference ---------------------------------------------


def infer_severity_filter(
    hit_template_ids: Iterable[str],
    corpus: dict[str, Any],
) -> list[str] | None:
    """Return the sorted set of severities present in the hits.

    None means "everything the corpus offers" -- indistinguishable from an
    unfiltered scan.
    """
    templates = corpus.get("templates") or {}
    hit_sevs: set[str] = set()
    for tid in hit_template_ids:
        t = templates.get(tid) or {}
        sev = t.get("severity")
        if isinstance(sev, str) and sev:
            hit_sevs.add(sev.lower())
    corpus_sevs = {
        (t.get("severity") or "").lower()
        for t in templates.values()
        if t.get("severity")
    }
    if hit_sevs == corpus_sevs:
        return None
    return sorted(hit_sevs)


def infer_tags_filter(
    hit_template_ids: Iterable[str],
    corpus: dict[str, Any],
) -> list[str] | None:
    """Return the tag intersection across all hit templates, or None."""
    templates = corpus.get("templates") or {}
    tag_lists: list[list[str]] = []
    for tid in hit_template_ids:
        t = templates.get(tid) or {}
        tags = t.get("tags") or []
        if isinstance(tags, list):
            tag_lists.append([str(x) for x in tags])
    if not tag_lists:
        return None
    common = tag_intersection(tag_lists)
    return common if common else None


def infer_custom_headers(events: list[dict[str, Any]]) -> list[dict[str, str]]:
    """Return headers whose *key* appears on every event and whose *value shape*
    is consistent -- either identical across events, or a recognizable
    template shape (uuid, hex, alphanum with fixed length)."""
    if not events:
        return []
    per_event_headers = [
        {k: str(v) for k, v in (ev.get("headers") or {}).items()} for ev in events
    ]
    common_keys: set[str] | None = None
    for h in per_event_headers:
        keys = set(h.keys())
        common_keys = keys if common_keys is None else (common_keys & keys)
    common_keys = common_keys or set()

    # Skip infrastructure headers that any HTTP client would set.
    boring = {
        "host", "content-length", "accept-encoding", "connection",
        "content-type", "accept",
    }

    out: list[dict[str, str]] = []
    for key in sorted(common_keys):
        if key.lower() in boring:
            continue
        values = [h[key] for h in per_event_headers]
        if len(set(values)) == 1:
            out.append({"name": key, "value": values[0], "shape": "literal"})
            continue
        shape = _classify_value_shape(values)
        if shape:
            out.append({"name": key, "value": _shape_template(shape), "shape": shape})
    return out


_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_HEX_RE = re.compile(r"^[0-9a-f]+$")
_ALNUM_RE = re.compile(r"^[A-Za-z0-9]+$")


def _classify_value_shape(values: list[str]) -> str | None:
    """Detect a common template shape (uuid, hex-N, alnum-N) across `values`.

    Returns a short shape descriptor when all values match, else None.
    """
    if not values:
        return None
    if all(_UUID_RE.match(v) for v in values):
        return "uuid"
    if all(_HEX_RE.match(v) and len(v) == len(values[0]) for v in values):
        return f"hex-{len(values[0])}"
    if all(_ALNUM_RE.match(v) and len(v) == len(values[0]) for v in values):
        return f"alnum-{len(values[0])}"
    return None


def _shape_template(shape: str) -> str:
    """Render a shape as a template placeholder for the fingerprint output."""
    return "{" + shape + "}"


def infer_random_agent(events: list[dict[str, Any]]) -> bool:
    """Return True if the observed UA set looks like -random-agent output.

    Signal: multiple distinct UAs AND >= 80% of them come from the
    known Nuclei random-agent pool. A single UA is never -random-agent.
    """
    uas = [str(ev.get("ua") or ev.get("user_agent") or "") for ev in events]
    uas = [u for u in uas if u]
    distinct = set(uas)
    if len(distinct) < 2:
        return False
    from_pool = sum(1 for u in distinct if is_nuclei_random_agent_ua(u))
    return from_pool / len(distinct) >= 0.8


def infer_interactsh_server(events: list[dict[str, Any]]) -> dict[str, Any]:
    """Return `{"host": <host>, "is_default": bool}` or None."""
    hosts: Counter[str] = Counter()
    for ev in events:
        clf = classify_event(ev, {})  # only cares about OAST harvesting
        for h in clf["oast_hosts"]:
            # Reduce sub.subdomain.oast.online -> oast.online for grouping
            parts = h.split(".")
            for i in range(len(parts) - 1):
                candidate = ".".join(parts[i:])
                if candidate in NUCLEI_DEFAULT_OAST_HOSTS:
                    hosts[candidate] += 1
                    break
            else:
                hosts[h] += 1
    if not hosts:
        return None
    top, _ = hosts.most_common(1)[0]
    return {"host": top, "is_default": top in NUCLEI_DEFAULT_OAST_HOSTS}


def infer_rate_limit(events: list[dict[str, Any]]) -> float | None:
    """Return the peak requests-per-second observed, or None if no timestamps.

    Uses a 1-second sliding window over parsed `ts` values.
    """
    times: list[float] = []
    for ev in events:
        ts = ev.get("ts")
        if not ts:
            continue
        try:
            t = datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
        except ValueError:
            continue
        times.append(t.timestamp())
    if len(times) < 2:
        return None
    times.sort()
    peak = 0
    left = 0
    for right in range(len(times)):
        while times[right] - times[left] > 1.0:
            left += 1
        peak = max(peak, right - left + 1)
    return float(peak)


def infer_bulk_size(events: list[dict[str, Any]]) -> int | None:
    """Return the peak concurrent open connections, if the operator has
    provided per-event `conn_active_at_start` counters. Otherwise None.
    """
    counters = [ev.get("conn_active_at_start") for ev in events]
    valid = [c for c in counters if isinstance(c, int)]
    return max(valid) if valid else None


def infer_scan_strategy(events: list[dict[str, Any]]) -> str | None:
    """Distinguish template-spray from host-spray from the ordering.

    Template-spray: `template_A` hits many hosts before `template_B` starts.
    Host-spray:     `host_X` sees many templates before `host_Y` starts.
    """
    ordered = []
    for ev in events:
        tid_list = ev.get("matched_templates")
        # If classification hasn't happened yet, skip; caller runs
        # classify_event first.
        if not isinstance(tid_list, list) or not tid_list:
            continue
        target = ev.get("target") or ev.get("host") or ev.get("dst_ip")
        if not target:
            continue
        # Attribute one probe to the first matched template; ties broken
        # by SHA(tid) for determinism.
        ordered.append((tid_list[0], str(target)))
    if len(ordered) < 10:
        return None
    # Count "run-length" of same-template blocks vs same-target blocks.
    template_runs = _runlength([t for t, _ in ordered])
    target_runs = _runlength([h for _, h in ordered])
    template_avg = sum(template_runs) / len(template_runs)
    target_avg = sum(target_runs) / len(target_runs)
    if template_avg > target_avg * 1.5:
        return "template-spray"
    if target_avg > template_avg * 1.5:
        return "host-spray"
    return "mixed"


_DIGITS = re.compile(r"[0-9]+")
_HEXRUN = re.compile(r"[0-9a-fA-F]{8,}")
_B64RUN = re.compile(r"[A-Za-z0-9+/=]{16,}")
_IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")


def shape_of_path(uri: str, *, max_len: int = 64) -> str:
    """Collapse the variable parts of a URI into a reusable shape.

    IPv4 addresses -> ``A``, hex runs of 8+ -> ``H``, base64-like runs of
    16+ -> ``B``, remaining digit runs -> ``N``; truncated to `max_len`.
    Two sprayers using the same payload template produce the same shape;
    two using different templates do not.
    """
    s = _IPV4.sub("A", uri)
    s = _HEXRUN.sub("H", s)
    s = _B64RUN.sub("B", s)
    s = _DIGITS.sub("N", s)
    return s[:max_len]


def infer_path_shapes(events: list[dict[str, Any]], *, limit: int = 8) -> list[str]:
    """Sorted set of distinct URI shapes (capped at `limit`) across the batch."""
    shapes = {shape_of_path(str(e.get("uri") or e.get("url") or "")) for e in events}
    return sorted(shapes)[:limit]


def shape_of_ua(ua: str) -> str:
    """User-Agent with version numbers collapsed: ``curl/7.58.0`` -> ``curl/N.N.N``."""
    return _DIGITS.sub("N", ua)[:80]


def infer_ua_shapes(events: list[dict[str, Any]], *, limit: int = 8) -> list[str]:
    """Sorted set of distinct User-Agent shapes (capped at `limit`) across the batch."""
    shapes = {shape_of_ua(str(e.get("ua") or e.get("user_agent") or "")) for e in events}
    return sorted(shapes)[:limit]


def _runlength(seq: list[str]) -> list[int]:
    if not seq:
        return []
    runs: list[int] = []
    cur = seq[0]
    n = 1
    for x in seq[1:]:
        if x == cur:
            n += 1
        else:
            runs.append(n)
            cur = x
            n = 1
    runs.append(n)
    return runs


# ---- Assembly ----------------------------------------------------------


def _confidence(supporting: int, contradicting: int) -> float:
    """Simple monotonic confidence: baseline 0.5, +0.1 per supporting signal,
    -0.1 per contradicting signal, clamped to [0.0, 1.0]. Explainable and
    deferrable to any smarter scheme later."""
    return max(0.0, min(1.0, 0.5 + 0.1 * supporting - 0.1 * contradicting))


def _structural_hash(fields: dict[str, Any]) -> str:
    """Deterministic hash over the (tool, options, template subset) tuple.

    Two independent runs on the same actor's observations produce the same
    hash; this is the pivot for `compare` and `match`.
    """
    canon = json.dumps(fields, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canon.encode()).hexdigest()[:32]


def fingerprint(
    events: list[dict[str, Any]],
    lookup: dict[str, Any],
    *,
    actor_id: str | None = None,
    min_quality: str = MEDIUM,
) -> dict[str, Any]:
    """Produce the actor fingerprint dict for a batch of events.

    `lookup` is the JSON produced by `nucleotide build`. `events` is the
    operator's pre-grouped list of observation dicts. `actor_id`, when
    absent, is derived from window + structural_hash. `min_quality` is the
    snippet-quality floor for a template hit to drive attribution.
    """
    # Classify each event once so downstream inference doesn't rescan.
    classified: list[dict[str, Any]] = []
    for ev in events:
        clf = classify_event(ev, lookup, min_quality=min_quality)
        # Enrich the event so scan-strategy inference can see matches.
        ev = {**ev, "matched_templates": clf["matched_templates"]}
        classified.append({"event": ev, "classification": clf})

    hit_ids = [
        tid
        for c in classified
        for tid in c["classification"]["matched_templates"]
    ]
    hit_counts = Counter(hit_ids)
    unique_hits = sorted(hit_counts)

    # Trustworthy hits (medium+ snippet quality) are the only ones allowed to
    # drive tool/CLI inference and the structural hash. Weak hits -- short
    # mid-token fragments -- are still *reported* under template_preference so
    # the operator sees them, but they never flip likely_tool or fabricate
    # CLI options from a coincidental substring match.
    trust_ids = [
        tid
        for c in classified
        for tid in c["classification"].get("trustworthy_templates", [])
    ]
    trust_counts = Counter(trust_ids)
    trusted_hits = sorted(trust_counts)
    weak_only_hits = sorted(set(unique_hits) - set(trusted_hits))

    # -- Tool inference --------------------------------------------------
    ua_default_hits = sum(
        1 for c in classified
        if c["classification"]["runtime_signals"]["ua_matches_nuclei_default"]
    )
    ua_random_pool_hits = sum(
        1 for c in classified
        if c["classification"]["runtime_signals"]["ua_in_nuclei_random_pool"]
    )
    oast_default_hits = sum(
        1 for c in classified
        if c["classification"]["runtime_signals"]["oast_host_is_default"] is True
    )
    oast_seen = any(c["classification"]["oast_hosts"] for c in classified)

    tool_supporting = 0
    tool_signals: list[str] = []
    if ua_default_hits > 0 or ua_random_pool_hits > 0:
        tool_supporting += 1
        if ua_default_hits > 0:
            tool_signals.append("observed User-Agent matches Nuclei stock default")
        if ua_random_pool_hits > 0:
            tool_signals.append("observed User-Agents drawn from Nuclei's built-in random-agent pool")
    if oast_default_hits > 0:
        tool_supporting += 1
        tool_signals.append("OAST callbacks resolve to a default interactsh host")
    if trusted_hits:
        tool_supporting += 1
        tool_signals.append(
            f"traffic matched {len(trusted_hits)} known Nuclei template(s) "
            f"on medium+ quality snippets"
        )

    tool_contradicting = 0
    tool_contradiction_signals: list[str] = []
    if oast_seen and oast_default_hits == 0:
        tool_contradicting += 1
        tool_contradiction_signals.append("OAST callbacks resolve to a non-default host (custom -interactsh-server)")
    # Weak-only matches are a red herring, not evidence: surface them as an
    # explicit non-signal so an operator isn't left wondering why a template
    # that "hit" didn't raise confidence.
    if weak_only_hits and not trusted_hits:
        tool_contradiction_signals.append(
            f"{len(weak_only_hits)} template hit(s) rest on weak (short, unanchored) "
            f"snippets only -- treated as coincidental, not attribution"
        )

    tool_confidence = _confidence(tool_supporting, tool_contradicting)
    likely_tool = "nuclei" if tool_confidence >= 0.6 else "unknown"

    # Non-Nuclei-tool hypothesis: known templates hit but no Nuclei runtime
    # signals -> possible different tool consuming the same YAMLs.
    nn_signals: list[str] = []
    if trusted_hits and ua_default_hits == 0 and ua_random_pool_hits == 0:
        nn_signals.append("known templates hit but no Nuclei-shaped UA observed")
    non_nuclei_confidence = _confidence(len(nn_signals), tool_supporting)

    # -- CLI-option inference --------------------------------------------
    # Severity/tags are inferred only from trustworthy template hits; a
    # coincidental fragment must not fabricate a -severity or -tags filter.
    severity_filter = infer_severity_filter(trusted_hits, lookup)
    tags_filter = infer_tags_filter(trusted_hits, lookup)
    custom_headers = infer_custom_headers([c["event"] for c in classified])
    random_agent = infer_random_agent([c["event"] for c in classified])
    interactsh = infer_interactsh_server([c["event"] for c in classified])
    rate_limit = infer_rate_limit([c["event"] for c in classified])
    bulk_size = infer_bulk_size([c["event"] for c in classified])
    scan_strategy = infer_scan_strategy([c["event"] for c in classified])

    # -- Novel probes ----------------------------------------------------
    novel_probes: list[dict[str, Any]] = []
    for c in classified:
        if c["classification"]["matched_templates"]:
            continue
        rs = c["classification"]["runtime_signals"]
        # A "nuclei-shaped" unknown probe: Nuclei-ish UA or OAST callback
        # observed even though no template matched.
        if (
            rs["ua_matches_nuclei_default"]
            or rs["ua_in_nuclei_random_pool"]
            or (rs["oast_host_is_default"] is True)
        ):
            ev = c["event"]
            uri = str(ev.get("uri") or ev.get("url") or "")
            novel_probes.append(
                {
                    "uri": uri,
                    "ua": ev.get("ua") or ev.get("user_agent"),
                    "oast_hosts": c["classification"]["oast_hosts"],
                }
            )

    # -- Window ----------------------------------------------------------
    timestamps = [
        str(ev.get("ts") or "")
        for c in classified
        for ev in [c["event"]]
        if ev.get("ts")
    ]
    window = (
        [min(timestamps), max(timestamps)]
        if timestamps
        else None
    )

    # -- Structural hash + id --------------------------------------------
    # An actor is "low signal" when nothing trustworthy pins it down: no
    # trusted template hits and no Nuclei runtime signal. Such actors must
    # NOT collapse to a single shared hash (which would let `compare` declare
    # nine distinct sprayers "identical"). We fold discriminating runtime
    # shape -- inferred rate-limit and custom-header names -- into the hash,
    # and flag the fingerprint so `compare`/`match` can refuse identity.
    low_signal = not trusted_hits and ua_default_hits == 0 and ua_random_pool_hits == 0
    ua_shapes = infer_ua_shapes([c["event"] for c in classified])
    path_shapes = infer_path_shapes([c["event"] for c in classified])
    structural_fields = {
        "likely_tool": likely_tool,
        "cli": {
            "-severity": severity_filter,
            "-tags": tags_filter,
            "-H": [{"name": h["name"], "shape": h["shape"]} for h in custom_headers],
            "-random-agent": random_agent,
            "-interactsh-server": (interactsh or {}).get("host"),
            "-scan-strategy": scan_strategy,
        },
        "template_subset": trusted_hits,
    }
    if low_signal:
        # Discriminators that would otherwise be washed out of the hash for
        # signal-poor actors. Rate-limit bucket + sorted custom-header names
        # keep genuinely different sprayers apart.
        structural_fields["low_signal_discriminators"] = {
            "rate_limit": rate_limit,
            "header_names": sorted(h["name"] for h in custom_headers),
            "scan_strategy": scan_strategy,
            "ua_shapes": ua_shapes,
            "path_shapes": path_shapes,
        }
    structural_hash = _structural_hash(structural_fields)
    if actor_id is None:
        actor_id = f"actor-{structural_hash.split(':',1)[1][:12]}"

    return {
        "actor_fingerprint": {
            "id": actor_id,
            "structural_hash": structural_hash,
            "low_signal": low_signal,
            "window": window,
            "events_analyzed": len(events),
            "tool_inference": {
                "likely_tool": likely_tool,
                "confidence": round(tool_confidence, 2),
                "signals": tool_signals,
                "contradictions": tool_contradiction_signals,
                "non_nuclei_hypothesis": {
                    "description": "known template YAMLs consumed by a different tool",
                    "confidence": round(non_nuclei_confidence, 2),
                    "signals": nn_signals,
                },
            },
            "inferred_cli_options": {
                "-severity": severity_filter,
                "-tags": tags_filter,
                "-H": custom_headers,
                "-random-agent": random_agent,
                "-interactsh-server": interactsh,
                "-rate-limit": rate_limit,
                "-bulk-size": bulk_size,
                "-scan-strategy": scan_strategy,
            },
            "template_preference": {
                "matched": trusted_hits,
                "hits_by_template": {
                    tid: n for tid, n in hit_counts.most_common() if tid in trusted_hits
                },
                "weak_only_matches": weak_only_hits,
                "novel_probes": len(novel_probes),
                "novel_probe_examples": novel_probes[:8],
            },
        }
    }


# ---- YAML dumper (no external dep) ------------------------------------


def to_yaml(obj: Any, *, indent: int = 0) -> str:
    """Small YAML dumper for the actor fingerprint dict.

    Handles nested dicts, lists of scalars and dicts, strings, ints,
    floats, bools, and None. No dependency on PyYAML for output -- our
    only PyYAML use is for parsing input Nuclei templates.
    """
    prefix = "  " * indent
    if obj is None:
        return "null"
    if isinstance(obj, bool):
        return "true" if obj else "false"
    if isinstance(obj, (int, float)):
        return json.dumps(obj)
    if isinstance(obj, str):
        return _yaml_scalar(obj)
    if isinstance(obj, list):
        if not obj:
            return "[]"
        lines: list[str] = []
        for item in obj:
            if isinstance(item, (dict, list)):
                lines.append(f"{prefix}-")
                lines.append(to_yaml(item, indent=indent + 1))
            else:
                lines.append(f"{prefix}- {to_yaml(item, indent=0)}")
        return "\n".join(lines)
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        lines: list[str] = []
        for key, value in obj.items():
            key_repr = _yaml_scalar(str(key), bare_ok=True)
            if isinstance(value, (dict, list)) and value not in (None, {}, []):
                lines.append(f"{prefix}{key_repr}:")
                lines.append(to_yaml(value, indent=indent + 1))
            else:
                lines.append(f"{prefix}{key_repr}: {to_yaml(value, indent=0)}")
        return "\n".join(lines)
    return _yaml_scalar(str(obj))


def _yaml_scalar(s: str, *, bare_ok: bool = False) -> str:
    """Emit a YAML scalar; quote if the string contains anything ambiguous."""
    if bare_ok and re.match(r"^[A-Za-z0-9_./ -]+$", s) and s not in ("true", "false", "null", "yes", "no"):
        return s
    escaped = s.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'
