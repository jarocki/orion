"""Parse Nuclei payloads: raw HTTP requests, cookies, OAST injection points.

The fingerprint module pulls from this to capture *what the template actually
asks the client to send* (header ordering, cookies, the literal context around
each OAST callback marker), as opposed to just hashing whole blobs.
"""

from __future__ import annotations

import re
from typing import Any

# Built-in Nuclei interactsh placeholders, plus the looser `oast-*` family some
# templates use. We deliberately do NOT match generic `{{...}}` here -- that
# lives in parse.PLACEHOLDER_RE and is used for path normalization, not OAST.
OAST_TOKEN_RE = re.compile(
    r"\{\{\s*(interactsh-[A-Za-z0-9_-]+|interactsh|oast(?:-[A-Za-z0-9_-]+)?)\s*\}\}"
)
COOKIE_HEADER_RE = re.compile(r"^cookie$", re.IGNORECASE)
# Nuclei templating placeholders (used to strip `{{Hostname}}`, `{{BaseURL}}`,
# `{{interactsh-url}}`, etc.) when computing literal anchors from a value.
PLACEHOLDER_RE = re.compile(r"\{\{[^}]*\}\}")
# RFC 6265 cookie-name token grammar (per RFC 7230 token): tchar+.
COOKIE_NAME_TOKEN_RE = re.compile(r"^[!#$%&'*+\-.0-9A-Z^_`a-z|~]+$")


def parse_raw_request(raw: str) -> dict[str, Any]:
    """Parse a Nuclei raw HTTP request block into method/target/headers/body.

    Header order (including duplicate names) is preserved exactly as written.
    Returns an empty dict if the first line doesn't look like a request line.
    """
    text = raw.lstrip("\n")
    lines = text.splitlines()
    if not lines:
        return {}
    parts = lines[0].split()
    if len(parts) < 2 or not parts[0].isupper():
        return {}
    headers: list[tuple[str, str]] = []
    body_lines: list[str] = []
    in_body = False
    for line in lines[1:]:
        if not in_body:
            if line == "":
                in_body = True
                continue
            if ":" in line:
                k, v = line.split(":", 1)
                headers.append((k.strip(), v.lstrip()))
        else:
            body_lines.append(line)
    return {
        "method": parts[0],
        "target": parts[1],
        "headers": headers,
        "body": "\n".join(body_lines),
    }


def parse_cookie_header(value: str) -> list[tuple[str, str]]:
    """Split a Cookie header value into [(name, value), ...].

    Cookies without `=` are kept as (name, "") so that bare flags survive.
    If any segment fails RFC 6265 cookie-name validation (which catches the
    "Shellshock in Cookie" case where the value is actually a bash payload
    full of `;` and `=` characters), the whole header is treated as a single
    opaque payload and returned as a single-element list with name="" and
    the original value preserved -- callers can fingerprint the bytes
    without inventing nonsense cookie names like `() { ignored` or `}`.
    """
    raw_parts = [p.strip() for p in value.split(";")]
    raw_parts = [p for p in raw_parts if p]
    parsed: list[tuple[str, str]] = []
    for part in raw_parts:
        if "=" in part:
            n, v = part.split("=", 1)
            parsed.append((n.strip(), v.strip()))
        else:
            parsed.append((part, ""))
    if not parsed:
        return []
    if all(COOKIE_NAME_TOKEN_RE.match(n) for n, _ in parsed if n):
        return parsed
    return [("", value.strip())]


def find_oast_injections(
    text: str,
    location: str,
    *,
    context: int = 24,
) -> list[dict[str, str]]:
    """Locate OAST callback placeholders in `text` with `context` bytes of surrounding literal.

    Returns a list of dicts with `location`, `placeholder`, `before`, `after`.
    The before/after slices are the immediate *literal* context: they're
    clamped to the boundary of the surrounding literal chunk so that
    back-to-back placeholders (`{{X}}sep{{X}}sep{{X}}...`, common in
    parameter-fuzzing templates) don't bleed the neighbouring placeholder's
    text into the anchor. Anchors like `ctsh-url}}/&href=http://` are what
    that used to produce -- worse than useless for IDS matching.
    """
    out: list[dict[str, str]] = []
    for m in OAST_TOKEN_RE.finditer(text):
        s, e = m.span()
        # Left boundary: end of the previous `}}`, or start of text.
        prev_close = text.rfind("}}", 0, s)
        left_boundary = 0 if prev_close == -1 else prev_close + 2
        # Right boundary: start of the next `{{`, or end of text.
        next_open = text.find("{{", e)
        right_boundary = len(text) if next_open == -1 else next_open
        out.append(
            {
                "location": location,
                "placeholder": m.group(0),
                "before": text[max(left_boundary, s - context) : s],
                "after": text[e : min(right_boundary, e + context)],
            }
        )
    return out


def literal_chunks(value: str) -> list[str]:
    """Return the literal substrings of `value` with Nuclei `{{...}}` placeholders stripped.

    Empty chunks are dropped. Whitespace is preserved.
    """
    return [c for c in PLACEHOLDER_RE.split(value) if c]


def longest_literal(value: str, min_len: int = 6) -> str | None:
    """Return the longest literal substring of `value` (placeholders stripped) at least `min_len` long, else None."""
    chunks = [c.strip() for c in literal_chunks(value)]
    chunks = [c for c in chunks if c]
    if not chunks:
        return None
    longest = max(chunks, key=len)
    return longest if len(longest) >= min_len else None
