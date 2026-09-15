"""Render Sigma detection rules for the two tiers a SIEM actually ingests.

Sigma is the SIEM-native detection format (YAML). We emit rules for two of
the observability tiers:

  T1 -- URL / access-log detection (logsource: webserver)
  T5 -- Response-log detection (logsource: proxy)

T2-T4 stay Snort-native because SIEMs don't typically ingest raw header
values or packet-body bytes; they consume the request/response line and
parsed access-log fields.

Sigma has no hard "content escape" grammar the way Snort does -- the rule
runs against parsed log fields, so the anchor string just needs to survive
YAML quoting.
"""

from __future__ import annotations

import hashlib
from typing import Any

from .signatures import (
    TIER_RESPONSE,
    TIER_URL,
    _http_response_words,
    _interesting_headers,
    _uri_anchors,
    _DEFAULT_RESPONSE_WORD_MIN,
)

# Sigma level maps directly from Nuclei severity. Unmapped -> "medium".
_SEVERITY_LEVEL = {
    "critical": "critical",
    "high": "high",
    "medium": "medium",
    "low": "low",
    "info": "informational",
    "informational": "informational",
    "unknown": "medium",
}


def _sigma_level(severity: Any) -> str:
    if not severity:
        return "medium"
    return _SEVERITY_LEVEL.get(str(severity).lower(), "medium")


def _sigma_id(tid: str, tier: str) -> str:
    """Deterministic UUID-shaped identifier per (tid, tier).

    Sigma requires a UUID-like `id` per rule; we derive one from
    sha256(tid:tier) so successive builds are stable.
    """
    h = hashlib.sha256(f"{tid}:{tier}".encode()).hexdigest()
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def _yaml_escape(s: str) -> str:
    """Escape a string for a YAML double-quoted scalar."""
    out: list[str] = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20:
            out.append(f"\\x{ord(ch):02x}")
        else:
            out.append(ch)
    return "".join(out)


def _rule_yaml(
    *,
    tid: str,
    tier: str,
    title: str,
    description: str,
    severity: Any,
    tags: list[str] | None,
    logsource_category: str,
    selection: dict[str, list[str]],
) -> str:
    """Emit a single Sigma rule as a YAML string.

    `selection` maps field-name (with Sigma modifier like `|contains`) to a
    list of literal values -- Sigma treats a list value as OR at the field
    level. The rule's `condition` is `selection` (any field matches).
    """
    level = _sigma_level(severity)
    rule_id = _sigma_id(tid, tier)
    lines: list[str] = []
    lines.append(f"title: {title}")
    lines.append(f"id: {rule_id}")
    if description:
        lines.append(f'description: "{_yaml_escape(description)}"')
    lines.append(f'status: experimental')
    lines.append(f'author: nucleotide')
    lines.append(f'level: {level}')
    all_tags = [f'nucleotide.tier.{tier.lower()}']
    if tid:
        all_tags.append(f'nuclei.template.{tid}')
    if tags:
        for tag in tags:
            all_tags.append(f'nuclei.tag.{tag}')
    lines.append("tags:")
    for tag in all_tags:
        lines.append(f'  - "{_yaml_escape(tag)}"')
    lines.append("logsource:")
    lines.append(f"  category: {logsource_category}")
    lines.append("detection:")
    lines.append("  selection:")
    for field, values in selection.items():
        lines.append(f"    {field}:")
        for v in values:
            lines.append(f'      - "{_yaml_escape(v)}"')
    lines.append("  condition: selection")
    return "\n".join(lines) + "\n"


def sigma_rules_for(tid: str, t: dict[str, Any]) -> list[dict[str, str]]:
    """Emit a list of `{tier, rule}` Sigma rule dicts for one template.

    Two rule shapes today:
      - T1 URL-log rule when the template has URI anchors, custom
        Cookie names, or DNS query names. Matches on `cs-uri-stem`,
        `cs-uri-query`, `c-cookie`, or DNS query name depending on the
        anchor kind.
      - T5 response-log rule when the template has HTTP response words.
        Matches on `sc-substatus`, `sc-substatus-desc`, or an equivalent
        response-body field. Real SIEM deployments use whatever the log
        pipeline names its response fields; we default to the W3C
        extended-log field set.
    """
    fp = t.get("fingerprints") or {}
    severity = t.get("severity")
    name = t.get("name") or tid
    tags = t.get("tags") or []
    rules: list[dict[str, str]] = []

    # ---- T1: URL / access-log tier ----
    uri_anchors = _uri_anchors(t)
    dns_names = [
        n for n in (fp.get("dns_names") or [])
        if isinstance(n, str) and "{{" not in n and len(n) >= 6
    ]
    cookie_names = [
        c for c in (fp.get("cookie_names") or [])
        if isinstance(c, str) and c.strip() and len(c) >= 3
    ]
    header_anchors = _interesting_headers(fp.get("header_order"))
    user_agents = [
        ua for ua in (fp.get("user_agents") or [])
        if isinstance(ua, str) and ua.strip()
    ]

    t1_selection: dict[str, list[str]] = {}
    if uri_anchors:
        t1_selection["cs-uri-stem|contains"] = uri_anchors
    if user_agents:
        t1_selection["cs(User-Agent)|contains"] = user_agents
    if header_anchors:
        # Sigma access logs typically expose specific header fields; we use
        # a generic `cs-header|contains` that matches on the raw header line.
        t1_selection["cs-header|contains"] = [
            f"{k}: {v}" for k, v in header_anchors
        ]
    if cookie_names:
        t1_selection["c-cookie|contains"] = [f"{c}=" for c in cookie_names]
    if dns_names:
        t1_selection["dns-query-name|contains"] = dns_names

    if t1_selection:
        rules.append(
            {
                "tier": TIER_URL,
                "rule": _rule_yaml(
                    tid=tid,
                    tier=TIER_URL,
                    title=f"Nuclei {tid} request-side (T1)",
                    description=f"Detects the request-side surface of the Nuclei template '{name}'.",
                    severity=severity,
                    tags=tags,
                    logsource_category="webserver",
                    selection=t1_selection,
                ),
            }
        )

    # ---- T5: response-log tier ----
    response_words = [
        w for w in _http_response_words(fp)
        if isinstance(w, str) and len(w) >= _DEFAULT_RESPONSE_WORD_MIN
    ]
    if response_words:
        rules.append(
            {
                "tier": TIER_RESPONSE,
                "rule": _rule_yaml(
                    tid=tid,
                    tier=TIER_RESPONSE,
                    title=f"Nuclei {tid} response-side (T5)",
                    description=f"Detects a *successful* Nuclei '{name}' probe by matching the template's declared response anchors.",
                    severity=severity,
                    tags=tags,
                    logsource_category="proxy",
                    selection={
                        "sc-response-body|contains": response_words,
                    },
                ),
            }
        )

    return rules


def build_sigma(lookup: dict[str, Any]) -> dict[str, list[dict[str, str]]]:
    """Compute the Sigma rule bundle for every template in a built lookup."""
    out: dict[str, list[dict[str, str]]] = {}
    for tid, t in (lookup.get("templates") or {}).items():
        rules = sigma_rules_for(tid, t)
        if rules:
            out[tid] = rules
    return out


def render_sigma(
    signatures: dict[str, Any],
    *,
    tier: str | None = None,
) -> str:
    """Concatenate every Sigma rule in the bundle into a single YAML stream.

    Sigma rule collections are conventionally emitted as `---`-delimited
    multi-document YAML. `tier=` filters to a single tier when set.
    """
    rules = (signatures or {}).get("sigma") or {}
    docs: list[str] = []
    for tid in sorted(rules):
        for entry in rules[tid]:
            if tier is not None and entry.get("tier") != tier:
                continue
            docs.append(entry["rule"])
    if not docs:
        return ""
    return "\n---\n".join(doc.rstrip() + "\n" for doc in docs)


def render_sigma_by_tier(signatures: dict[str, Any]) -> dict[str, str]:
    """Return `{tier: rendered_yaml}` for T1 and T5 (the tiers with Sigma rules)."""
    return {
        TIER_URL: render_sigma(signatures, tier=TIER_URL),
        TIER_RESPONSE: render_sigma(signatures, tier=TIER_RESPONSE),
    }
