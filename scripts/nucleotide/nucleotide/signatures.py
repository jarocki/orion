"""Generate YARA and Snort/Suricata signatures from extracted Nuclei fingerprints.

The strings we emit come straight from the fingerprint dict that
`extract_fingerprints` produced: distinctive literal URL chunks, User-Agent
values, custom header names+values (with `{{...}}` placeholders stripped to
their literal substrings), cookie names, the literal context around any OAST
callback marker, and response-side anchors pulled from the template's
`matchers:` blocks. Generic "this header looks routine" values like
`Content-Type: application/json` are filtered out; payload-looking values
(Struts OGNL, Log4j JNDI, etc.) are kept verbatim. Severity is mapped to
the appropriate Snort `classtype`. SIDs are deterministic per (tid, salt)
*and* de-conflicted globally so a build never produces two rules with the
same SID.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any, Iterable

from .payload import longest_literal

_YARA_NAME_RE = re.compile(r"[^A-Za-z0-9_]")

# Header NAMES we never emit a signature for. These two are infrastructure-
# provided (Host gets rewritten per target, Content-Length is recomputed).
# Anything else -- including Content-Type, Accept, Cookie, User-Agent -- is
# allowed through and judged on the value's distinctiveness.
_INFRA_HEADERS = frozenset({"host", "content-length", "connection"})
# Handled by dedicated extractors (user_agents, cookies) so we don't double-emit.
_DEDICATED_HEADERS = frozenset({"user-agent", "cookie"})

# Values we'll skip as "looks like a routine HTTP header value":
# short, only ASCII tokens/punctuation, no obvious payload markers.
_BORING_VALUE_RE = re.compile(r"^[\w/+=,;.\- :*]{1,48}$")
# Substrings that flag a value as a payload regardless of length.
_PAYLOAD_MARKERS = ("${", "%{", "<%", "() {", "/*!", "../", "..\\", "<script")

# Severity -> Snort classtype mapping. Defaults to web-application-activity
# for `info`, `unknown`, or anything we don't recognize.
_SEVERITY_CLASSTYPE = {
    "critical": "web-application-attack",
    "high": "web-application-attack",
    "medium": "web-application-violation",
    "low": "attempted-recon",
    "info": "web-application-activity",
    "informational": "web-application-activity",
    "unknown": "web-application-activity",
}

# Per-rule string length thresholds. Tunable from build_signatures().
_DEFAULT_URI_MIN = 6
_DEFAULT_HEADER_MIN = 8
_DEFAULT_RESPONSE_WORD_MIN = 6


def _classtype_for(severity: Any) -> str:
    if not severity:
        return _SEVERITY_CLASSTYPE["unknown"]
    return _SEVERITY_CLASSTYPE.get(str(severity).lower(), "web-application-activity")


def _yara_name(tid: str) -> str:
    name = _YARA_NAME_RE.sub("_", tid)
    if not name or not (name[0].isalpha() or name[0] == "_"):
        name = "_" + name
    return f"nuclei_{name}"


def _yara_escape(s: str) -> str:
    # YARA double-quoted strings honor: \" \\ \t \n \r \x##
    out: list[str] = []
    for ch in s:
        o = ord(ch)
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
        elif o < 0x20 or o > 0x7E:
            # Encode any non-printable byte explicitly. For multi-byte UTF-8
            # we hex-encode each byte separately so the rule matches the wire
            # bytes, not a Python string abstraction.
            for b in ch.encode("utf-8"):
                out.append(f"\\x{b:02x}")
        else:
            out.append(ch)
    return "".join(out)


def _snort_escape(s: str) -> str:
    """Encode a string as a Snort `content:` payload.

    Printable ASCII goes through verbatim, with the four content-grammar
    reserved chars (`"`, `;`, `\\`, `|`) lifted into a `|hex|` block alongside
    every non-ASCII / control byte. Multi-byte UTF-8 is preserved byte-wise.
    """
    out: list[str] = []
    hex_run: list[str] = []

    def flush_hex() -> None:
        if hex_run:
            out.append("|" + " ".join(hex_run) + "|")
            hex_run.clear()

    for ch in s:
        b = ch.encode("utf-8")
        if len(b) == 1 and 0x20 <= b[0] <= 0x7E and ch not in ('"', ";", "\\", "|"):
            flush_hex()
            out.append(ch)
        else:
            for byte in b:
                hex_run.append(f"{byte:02X}")
    flush_hex()
    return "".join(out)


def _stable_sid(tid: str, salt: int = 0) -> int:
    """Deterministically pick a SID in the 1_000_000..1_899_999 range."""
    h = hashlib.sha256(f"{tid}:{salt}".encode()).digest()
    return 1_000_000 + int.from_bytes(h[:4], "big") % 900_000


def _value_is_payload_like(value: str) -> bool:
    """Distinguish a payload-bearing header value from a routine one.

    A value is "payload-like" if it contains a known injection marker, is long
    (>48 chars), or contains non-ASCII bytes -- anything but a short routine
    HTTP header value.
    """
    if not value:
        return False
    if any(m in value for m in _PAYLOAD_MARKERS):
        return True
    if len(value) > 48:
        return True
    if any(ord(c) > 0x7E or ord(c) < 0x20 for c in value):
        return True
    return not _BORING_VALUE_RE.match(value)


def _interesting_headers(
    header_order: Iterable[Any],
    *,
    min_anchor_len: int = _DEFAULT_HEADER_MIN,
) -> list[tuple[str, str]]:
    """Return `[(name, anchor_value), ...]` where `anchor_value` is what to
    actually put in the IDS rule.

    `user-agent` and `cookie` are normally handled by dedicated extractors,
    but when their values are payload-like (Shellshock weaponizes both, for
    example) we let them through as additional header anchors. Header values
    that still carry `{{...}}` placeholders are reduced to their longest
    literal substring -- a value like
    `Authorization: Bearer {{interactsh-url}}` becomes anchor `Bearer ` if
    that meets the minimum length, otherwise the header is dropped.
    """
    out: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for kv in header_order or []:
        if not isinstance(kv, (list, tuple)) or len(kv) != 2:
            continue
        k, v = kv
        if not isinstance(k, str) or not isinstance(v, str):
            continue
        kl = k.lower()
        if kl in _INFRA_HEADERS:
            continue
        if not v.strip():
            continue
        if "{{" in v:
            anchor = longest_literal(v, min_len=min_anchor_len)
            if not anchor:
                continue
        else:
            if not _value_is_payload_like(v):
                continue
            anchor = v
            if len(anchor) < min_anchor_len:
                continue
        if kl in _DEDICATED_HEADERS and not _value_is_payload_like(anchor):
            continue
        pair = (k, anchor)
        if pair in seen:
            continue
        seen.add(pair)
        out.append(pair)
    return out


# Locations whose response anchors are HTTP-side and thus safe to emit as
# `alert http` Snort rules. DNS/SSL anchors stay YARA-only (a DNS-flavoured
# Snort rule needs a different grammar and we don't synthesize one).
_HTTP_RESPONSE_LOCATION_PREFIXES = ("http", "requests", "network", "tcp", "code")


def _http_response_words(fp: dict[str, Any]) -> list[str]:
    sites = fp.get("response_word_sites") or []
    if not sites:
        # Pre-location older builds: fall back to all words.
        return list(fp.get("response_words") or [])
    out: list[str] = []
    for s in sites:
        if not isinstance(s, dict):
            continue
        loc = str(s.get("location") or "")
        prefix = loc.split("[", 1)[0]
        if prefix in _HTTP_RESPONSE_LOCATION_PREFIXES:
            w = s.get("word")
            if isinstance(w, str):
                out.append(w)
    return out


_DEFAULT_URI_ANCHOR_CAP = 6


def _uri_anchors(
    t: dict[str, Any],
    *,
    min_len: int = _DEFAULT_URI_MIN,
    cap: int = _DEFAULT_URI_ANCHOR_CAP,
) -> list[str]:
    """Pick up to `cap` distinctive URI-side anchor strings for this template.

    Prefers the longest literal chunks from `template["chunks"]` (e.g. the full
    `/wp-content/plugins/akismet/readme.txt` literal) over the shorter
    `url_snippet` which the lookup table uses for fast uniqueness queries.
    Falls back to the snippet when no chunk is long enough.

    Templates with a broad payload list (`generic-linux-lfi`,
    `laravel-env`, `xss-fuzz`) can materialize to many concrete path
    variants; the cap controls how many of those emit as separate rules.
    Chunks that are pure substrings of an already-selected longer chunk
    are dropped -- keeping `/etc/passwd` when we already have
    `/../../../etc/passwd` is redundant.
    """
    seen: set[str] = set()
    candidates: list[str] = []
    for c in sorted(
        (c for c in (t.get("chunks") or []) if isinstance(c, str)),
        key=len,
        reverse=True,
    ):
        if len(c) < min_len or c in seen:
            continue
        # Drop substrings of already-kept anchors.
        if any(c in existing for existing in candidates):
            continue
        seen.add(c)
        candidates.append(c)
        if len(candidates) >= cap:
            break
    if candidates:
        return candidates
    snip = t.get("url_snippet")
    if isinstance(snip, str) and snip:
        return [snip]
    return []


def yara_rule_for(tid: str, t: dict[str, Any]) -> str | None:
    """Build a single YARA rule for one template, or None if no signal is usable."""
    fp = t.get("fingerprints") or {}
    strings: list[tuple[str, str]] = []
    used_values: set[str] = set()

    def add(prefix: str, value: str) -> None:
        if not value or value in used_values:
            return
        used_values.add(value)
        strings.append((f"${prefix}_{len(strings)}", value))

    for anchor in _uri_anchors(t):
        add("path", anchor)

    for ua in fp.get("user_agents") or []:
        if isinstance(ua, str) and ua.strip():
            add("ua", f"User-Agent: {ua}")

    for k, v in _interesting_headers(fp.get("header_order")):
        add("hdr", f"{k}: {v}")

    for ck in fp.get("cookie_names") or []:
        if isinstance(ck, str) and ck.strip() and len(ck) >= 3:
            # Skip the synthetic "" name parse_cookie_header emits when the
            # Cookie value isn't really a cookie list (e.g. Shellshock).
            add("ck", f"{ck}=")

    for o in fp.get("oast_injections") or []:
        if not isinstance(o, dict):
            continue
        before = (o.get("before") or "").rstrip()
        after = (o.get("after") or "").lstrip()
        if len(before) >= 4 and "{{" not in before:
            add("oast_pre", before)
        if len(after) >= 4 and "{{" not in after:
            add("oast_post", after)

    for w in fp.get("response_words") or []:
        if isinstance(w, str) and len(w) >= _DEFAULT_RESPONSE_WORD_MIN:
            add("resp", w)

    for q in fp.get("dns_names") or []:
        if isinstance(q, str) and "{{" not in q and len(q) >= 6:
            add("dns", q)

    if not strings:
        return None

    lines: list[str] = []
    lines.append(f"rule {_yara_name(tid)}")
    lines.append("{")
    lines.append("    meta:")
    lines.append(f'        nuclei_id = "{_yara_escape(tid)}"')
    if t.get("severity"):
        lines.append(f'        severity = "{_yara_escape(str(t["severity"]))}"')
    if t.get("name"):
        lines.append(f'        nuclei_name = "{_yara_escape(str(t["name"]))}"')
    lines.append("    strings:")
    for label, value in strings:
        lines.append(f'        {label} = "{_yara_escape(value)}"')
    lines.append("    condition:")
    lines.append("        any of them")
    lines.append("}")
    return "\n".join(lines) + "\n"


# Observability tiers. Every emitted Snort rule is tagged with the tier that
# a consumer of that data source could actually match. See docs/tiers.md
# (and the README's "Signature tiers" section) for the deployment-vantage
# framing.
#
#   T1  URL-log only              -- access logs, CDN logs, DNS logs, TCP flow only
#   T2  Header-visible            -- WAF, SSL-intercepting proxy, mod_security
#   T3  Body/cleartext PCAP       -- decrypted or plaintext PCAP with request body
#   T4  TLS-opaque PCAP           -- network sensor with no SSL keys (JA3/JA4)
#   T5  Response-only             -- outbound proxy log, honeypot response cache
TIER_URL = "T1"
TIER_HEADER = "T2"
TIER_BODY = "T3"
TIER_TLS = "T4"
TIER_RESPONSE = "T5"
TIERS = (TIER_URL, TIER_HEADER, TIER_BODY, TIER_TLS, TIER_RESPONSE)


def _emit_snort(
    rules: list[dict[str, str]],
    *,
    tid: str,
    salt: int,
    classtype: str,
    content: str,
    buffer: str | None,
    flow: str,
    suffix: str,
    tier: str,
    nocase: bool = False,
) -> int:
    """Append one Snort rule (tagged with its observability tier) and return the next salt."""
    sid = _stable_sid(tid, salt)
    msg = f"[{tier}] Nuclei {tid} ({suffix})".replace('"', "'")
    opts = [
        f'msg:"{msg}"',
        f"flow:{flow}",
        f'content:"{content}"',
    ]
    if buffer:
        opts.append(buffer)
    if nocase:
        opts.append("nocase")
    opts.append(f"sid:{sid}")
    opts.append("rev:1")
    opts.append(f"classtype:{classtype}")
    opts.append(f'metadata:tier {tier}')
    rules.append(
        {
            "tier": tier,
            "rule": "alert http any any -> any any ("
            + "; ".join(opts)
            + ";)",
        }
    )
    return salt + 1


def _oast_tier(location: str) -> str:
    """Classify an OAST injection by where in the request it lives."""
    if "body" in location or "network" in location:
        return TIER_BODY
    if "header:" in location:
        return TIER_HEADER
    # target / path / anything else URL-shaped
    return TIER_URL


def snort_rules_for(tid: str, t: dict[str, Any]) -> list[dict[str, str]]:
    """Emit a list of `{tier, rule}` dicts for one template.

    Rules use classic Snort 2 syntax (`content:"..."; http_uri;`) which both
    Snort 3 and Suricata understand. Every rule is tagged with its
    observability tier so downstream code can split the bundle by what
    each vantage point can actually see. SIDs are deterministic per
    (tid, salt); `build_signatures` resolves global collisions afterwards.
    """
    fp = t.get("fingerprints") or {}
    classtype = _classtype_for(t.get("severity"))
    rules: list[dict[str, str]] = []
    salt = 0

    for anchor in _uri_anchors(t):
        salt = _emit_snort(
            rules,
            tid=tid,
            salt=salt,
            classtype=classtype,
            content=_snort_escape(anchor),
            buffer="http_uri",
            flow="established,to_server",
            suffix=f"URI {anchor[:32]}",
            tier=TIER_URL,
            nocase=True,
        )

    for ua in fp.get("user_agents") or []:
        if isinstance(ua, str) and ua.strip():
            salt = _emit_snort(
                rules,
                tid=tid,
                salt=salt,
                classtype=classtype,
                content=_snort_escape(ua),
                buffer="http_user_agent",
                flow="established,to_server",
                suffix="User-Agent",
                tier=TIER_HEADER,
            )

    for k, v in _interesting_headers(fp.get("header_order")):
        salt = _emit_snort(
            rules,
            tid=tid,
            salt=salt,
            classtype=classtype,
            content=_snort_escape(f"{k}: {v}"),
            buffer="http_header",
            flow="established,to_server",
            suffix=f"header {k}",
            tier=TIER_HEADER,
        )

    for ck in fp.get("cookie_names") or []:
        if isinstance(ck, str) and ck.strip() and len(ck) >= 3:
            salt = _emit_snort(
                rules,
                tid=tid,
                salt=salt,
                classtype=classtype,
                content=_snort_escape(f"{ck}="),
                buffer="http_cookie",
                flow="established,to_server",
                suffix=f"cookie {ck}",
                tier=TIER_HEADER,
            )

    for o in fp.get("oast_injections") or []:
        if not isinstance(o, dict):
            continue
        before = (o.get("before") or "").rstrip()
        after = (o.get("after") or "").lstrip()
        loc = o.get("location") or ""
        oast_tier = _oast_tier(loc)
        buffer = "http_client_body" if oast_tier == TIER_BODY else (
            "http_uri" if oast_tier == TIER_URL else "http_header"
        )
        if len(before) >= 6 and "{{" not in before:
            salt = _emit_snort(
                rules,
                tid=tid,
                salt=salt,
                classtype=classtype,
                content=_snort_escape(before),
                buffer=buffer,
                flow="established,to_server",
                suffix=f"OAST pre @ {loc}",
                tier=oast_tier,
            )
        if len(after) >= 6 and "{{" not in after:
            salt = _emit_snort(
                rules,
                tid=tid,
                salt=salt,
                classtype=classtype,
                content=_snort_escape(after),
                buffer=buffer,
                flow="established,to_server",
                suffix=f"OAST post @ {loc}",
                tier=oast_tier,
            )

    # Response-side anchors -- Tier 5. Only emit for response words pulled
    # from HTTP/TCP/network probes; DNS/SSL words like "NXDOMAIN" don't
    # translate to an `alert http` rule.
    for w in _http_response_words(fp):
        if isinstance(w, str) and len(w) >= _DEFAULT_RESPONSE_WORD_MIN:
            salt = _emit_snort(
                rules,
                tid=tid,
                salt=salt,
                classtype=classtype,
                content=_snort_escape(w),
                buffer=None,
                flow="established,to_client",
                suffix="response word",
                tier=TIER_RESPONSE,
            )

    # TLS-opaque tier: JA3/JA4 fingerprints if the template specifies a
    # ClientHello. Emit as Suricata's `tls.ja3.hash` / `ja4.hash` rules.
    ja3 = fp.get("ja3")
    if isinstance(ja3, str) and ja3:
        sid = _stable_sid(tid, salt)
        salt += 1
        msg = f"[{TIER_TLS}] Nuclei {tid} (JA3)".replace('"', "'")
        rule = (
            f'alert tls any any -> any any '
            f'(msg:"{msg}"; ja3.hash; content:"{ja3}"; '
            f'sid:{sid}; rev:1; classtype:{classtype}; '
            f'metadata:tier {TIER_TLS};)'
        )
        rules.append({"tier": TIER_TLS, "rule": rule})
    ja4 = fp.get("ja4")
    if isinstance(ja4, str) and ja4:
        sid = _stable_sid(tid, salt)
        salt += 1
        msg = f"[{TIER_TLS}] Nuclei {tid} (JA4)".replace('"', "'")
        rule = (
            f'alert tls any any -> any any '
            f'(msg:"{msg}"; ja4.hash; content:"{ja4}"; '
            f'sid:{sid}; rev:1; classtype:{classtype}; '
            f'metadata:tier {TIER_TLS};)'
        )
        rules.append({"tier": TIER_TLS, "rule": rule})

    return rules


def _deconflict_sids(
    snort_rules: dict[str, list[dict[str, str]]],
) -> dict[str, list[dict[str, str]]]:
    """Walk the global rule set and re-roll any SID that collides with one already used.

    Two templates' rules can hash to the same SID; this loop salts again
    until each rule has a unique SID across the whole bundle. Deterministic
    given the same (tid, rule-position) inputs.
    """
    sid_re = re.compile(r"sid:(\d+);")
    seen: set[int] = set()
    out: dict[str, list[dict[str, str]]] = {}
    for tid in sorted(snort_rules):
        rebuilt: list[dict[str, str]] = []
        for idx, entry in enumerate(snort_rules[tid]):
            rule = entry["rule"]
            m = sid_re.search(rule)
            if not m:
                rebuilt.append(entry)
                continue
            sid = int(m.group(1))
            salt = idx
            while sid in seen:
                salt += 1000
                sid = _stable_sid(tid, salt)
            seen.add(sid)
            rebuilt.append(
                {
                    "tier": entry["tier"],
                    "rule": sid_re.sub(f"sid:{sid};", rule, count=1),
                }
            )
        out[tid] = rebuilt
    return out


def build_signatures(lookup: dict[str, Any]) -> dict[str, Any]:
    """Compute YARA + Snort + Sigma rule sets for every template in a built lookup."""
    from .sigma import build_sigma

    yara_rules: dict[str, str] = {}
    snort_rules: dict[str, list[dict[str, str]]] = {}
    for tid, t in (lookup.get("templates") or {}).items():
        y = yara_rule_for(tid, t)
        if y:
            yara_rules[tid] = y
        s = snort_rules_for(tid, t)
        if s:
            snort_rules[tid] = s
    snort_rules = _deconflict_sids(snort_rules)
    sigma_rules = build_sigma(lookup)
    return {"yara": yara_rules, "snort": snort_rules, "sigma": sigma_rules}


def render_yara(signatures: dict[str, Any]) -> str:
    """Concatenate every YARA rule in the bundle into a single file-ready string."""
    rules = (signatures or {}).get("yara") or {}
    return "\n".join(rules[tid] for tid in sorted(rules))


def render_snort(
    signatures: dict[str, Any],
    *,
    tier: str | None = None,
) -> str:
    """Flatten every Snort rule in the bundle into a newline-terminated string.

    Passing `tier=` returns only the rules for that observability tier
    (`"T1"`..`"T5"`); default returns all tiers.
    """
    rules = (signatures or {}).get("snort") or {}
    out: list[str] = []
    for tid in sorted(rules):
        for entry in rules[tid]:
            if tier is not None and entry.get("tier") != tier:
                continue
            out.append(entry["rule"])
    return "\n".join(out) + ("\n" if out else "")


def render_snort_by_tier(signatures: dict[str, Any]) -> dict[str, str]:
    """Return `{tier: rendered_rules_text}` for every tier that has rules."""
    return {t: render_snort(signatures, tier=t) for t in TIERS}
