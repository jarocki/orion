"""Extract response-side signals from Nuclei matcher blocks plus DNS / SSL probe shape.

Nuclei templates describe *what the response should contain* in their
`matchers:` blocks (literal words, regexes, status codes, DSL expressions).
Those response anchors are the bytes that come back when a probe lands --
arguably more valuable for an IDS than the outbound payload, since they
prove the host actually responded the way the template predicted.

This module walks every matcher across http/network/tcp/dns/ssl blocks
and returns a flat list of (location, part, kind, value) tuples plus a
small set of DNS query descriptors. The fingerprint module turns these
into top-level `response_words` / `response_regexes` / `dns_*` fields.
"""

from __future__ import annotations

from typing import Any, Iterable


_REQUEST_BLOCK_KEYS = ("http", "requests")
_PROBE_BLOCK_KEYS = ("network", "tcp", "dns", "ssl", "code", "headless", "javascript")


def _iter_matcher_blocks(template: dict) -> Iterable[tuple[str, dict]]:
    """Yield (location, matcher_dict) for every matcher across every probe block."""
    for key in _REQUEST_BLOCK_KEYS + _PROBE_BLOCK_KEYS:
        block = template.get(key)
        if not isinstance(block, list):
            continue
        for idx, item in enumerate(block):
            if not isinstance(item, dict):
                continue
            for m in item.get("matchers") or []:
                if isinstance(m, dict):
                    yield f"{key}[{idx}]", m


def extract_response_signals(template: dict) -> dict[str, Any]:
    """Return a dict of response-side signature material extracted from matcher blocks.

    Keys (omitted when empty):
      - `response_words`         flat list of literal words to anchor on
      - `response_word_sites`    list of {location, part, word}
      - `response_regexes`       flat list of regex strings
      - `response_regex_sites`   list of {location, part, regex}
      - `response_status_codes`  sorted list of HTTP status codes expected
      - `response_dsl`           DSL expressions (kept verbatim, useful for triage)
    """
    words: list[tuple[str, str, str]] = []
    regexes: list[tuple[str, str, str]] = []
    statuses: set[int] = set()
    dsls: list[str] = []

    for loc, m in _iter_matcher_blocks(template):
        mtype = m.get("type")
        part = str(m.get("part") or "body")
        if mtype == "word":
            for w in m.get("words") or []:
                if isinstance(w, str) and w.strip():
                    words.append((loc, part, w))
        elif mtype == "regex":
            for r in m.get("regex") or []:
                if isinstance(r, str) and r.strip():
                    regexes.append((loc, part, r))
        elif mtype == "status":
            for s in m.get("status") or []:
                if isinstance(s, int):
                    statuses.add(s)
        elif mtype == "dsl":
            for d in m.get("dsl") or []:
                if isinstance(d, str) and d.strip():
                    dsls.append(d)

    out: dict[str, Any] = {}
    if words:
        out["response_words"] = [w for _, _, w in words]
        out["response_word_sites"] = [
            {"location": loc, "part": part, "word": w} for loc, part, w in words
        ]
    if regexes:
        out["response_regexes"] = [r for _, _, r in regexes]
        out["response_regex_sites"] = [
            {"location": loc, "part": part, "regex": r}
            for loc, part, r in regexes
        ]
    if statuses:
        out["response_status_codes"] = sorted(statuses)
    if dsls:
        out["response_dsl"] = dsls
    return out


def extract_dns_queries(template: dict) -> list[dict[str, str]]:
    """Return a list of {type, name} dicts for every DNS query the template issues."""
    out: list[dict[str, str]] = []
    block = template.get("dns")
    if not isinstance(block, list):
        return out
    for d in block:
        if not isinstance(d, dict):
            continue
        name = d.get("name")
        rtype = d.get("type") or "A"
        if isinstance(name, str) and name.strip():
            out.append({"type": str(rtype), "name": name})
    return out
