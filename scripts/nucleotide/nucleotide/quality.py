"""Score how trustworthy a URL snippet is as a template attribution key.

Motivation
----------
`compute_unique_snippets` finds the *shortest* substring unique to one
template across the corpus. "Shortest + unique" is not the same as
"trustworthy": on a 13k-template corpus the shortest unique substring is
often a 4-byte fragment torn out of the middle of a longer literal --
``e64/`` sliced from ``base64/``, ``//19`` from ``http://192.168...``,
``edis`` from ``redis``. Those fragments re-appear constantly in
unrelated adversarial traffic (Base64 Log4Shell payloads, JNDI callbacks
to RFC-1918 hosts), producing confident-looking but bogus attributions
that then poison actor/tool inference downstream.

A snippet's trustworthiness has two independent axes:

* **length** -- longer substrings collide by chance far less often.
* **anchoring** -- a substring aligned to a path boundary (``/``, start,
  end, or a query/param delimiter) names a real path component; a
  substring floating in the middle of a word is a coincidence waiting to
  happen.

`snippet_quality` combines the two into a coarse, explainable tier so
callers can keep short snippets but treat them with appropriate
suspicion, rather than silently trusting or silently dropping them.
"""

from __future__ import annotations

import re
from functools import lru_cache
from pathlib import Path

# Boundary characters that make a snippet edge "meaningful" -- i.e. the
# snippet starts/ends at a real delimiter rather than mid-token.
_BOUNDARY = "/?=&.:;,%+ "

# Quality tiers, ordered weakest -> strongest. Exposed as plain strings so
# they survive JSON round-trips in lookup.json without an enum dependency.
WEAK = "weak"        # short and unanchored -- coincidental-match risk
MEDIUM = "medium"    # anchored-but-short, or long-but-unanchored
STRONG = "strong"    # long and anchored -- safe for silent attribution

_ORDER = {WEAK: 0, MEDIUM: 1, STRONG: 2}


def at_least(quality: str, floor: str) -> bool:
    """True if `quality` is at or above `floor` in the tier ordering."""
    return _ORDER.get(quality, 0) >= _ORDER.get(floor, 0)


_SEGMENT = re.compile(r"[A-Za-z0-9]+")
_HEX2 = re.compile(r"[0-9a-fA-F]{2}")
_HEX_ONLY = re.compile(r"[0-9a-fA-F]+")


@lru_cache(maxsize=1)
def common_words() -> frozenset[str]:
    """Lower-case English words with Zipf frequency >= 3.0.

    Loaded from ``nucleotide/data/common-words.txt`` (generated from the
    wordfreq package; see the header of that file for provenance). Used to
    stop a short anchored snippet that is an ordinary word -- ``Basic``,
    ``login``, ``status`` -- from earning MEDIUM on anchoring alone.
    """
    path = Path(__file__).with_name("data") / "common-words.txt"
    words = set()
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                words.add(line)
    return frozenset(words)


def is_generic_token(snippet: str, *, strong_len: int = 8) -> bool:
    """True if a short snippet is too generic to attribute on anchoring alone.

    Applies only below `strong_len`. The snippet is split into alphanumeric
    segments (boundary and punctuation characters are dropped). A segment
    is *generic* if it is hex-only -- digits and a-f, e.g. ``6100``,
    ``3d50``, ``ffff`` -- or if it is a common English word (``Basic``,
    ``login``, ``status``; see `common_words`). The snippet is generic when
    it has no segment that is neither.

    Both rules were motivated by measured false positives on the Log4Shell
    capture (``Basic`` from ``/WS/Basic/Basic.asmx``, ``6100`` from an
    ``OR 6100=6100`` SQLi template); see docs/v2.0.0-analysis/ANALYSIS.md.
    """
    if len(snippet) >= strong_len:
        return False
    words = common_words()
    for seg in _SEGMENT.findall(snippet):
        if _HEX_ONLY.fullmatch(seg):
            continue
        if seg.isalpha() and seg.lower() in words:
            continue
        return False
    return True


def anchored_in(snippet: str, text: str) -> bool:
    """True if some occurrence of `snippet` in `text` sits on boundaries at both edges."""
    return _edges_anchored(snippet, text)


def match_quality(snippet: str, graded: str, text: str, *, long_unanchored_len: int = 12) -> str:
    """Grade of a snippet *as matched in a specific URI*.

    A snippet earns its build-time grade from anchoring in its own
    template. That anchoring must also hold where it lands in the traffic,
    or the match is a mid-token coincidence regardless of grade: ``6100``
    is anchored in ``+OR+6100%3d6100`` but not in ``...f9b86100000000...``.

    Snippets at or above `long_unanchored_len` keep their grade unanchored,
    for the same reason long unanchored snippets earn MEDIUM at build time.
    """
    if not snippet or len(snippet) >= long_unanchored_len:
        return graded
    if graded == WEAK:
        return WEAK
    return graded if _edges_anchored(snippet, text) else WEAK


def edge_anchored(chunk: str, i: int, length: int) -> bool:
    """True if chunk[i:i+length] sits on boundary characters at both edges.

    A ``%`` counts as a left boundary only when the two characters that
    follow it are *not* a hex pair: in ``%3dASC`` the ``3d`` belongs to the
    percent-encoding, so ``3dASC`` is not a real path token.
    """
    left_ok = i == 0 or (
        chunk[i - 1] in _BOUNDARY
        and not (chunk[i - 1] == "%" and _HEX2.match(chunk, i))
    )
    j = i + length
    right_ok = j == len(chunk) or chunk[j] in _BOUNDARY
    return left_ok and right_ok


def _edges_anchored(snippet: str, chunk: str) -> bool:
    """True if some occurrence of `snippet` in `chunk` is anchored on both edges.

    A snippet that is only ever a mid-token fragment is not anchored.
    """
    L = len(snippet)
    start = 0
    while True:
        i = chunk.find(snippet, start)
        if i < 0:
            return False
        if edge_anchored(chunk, i, L):
            return True
        start = i + 1


def snippet_quality(
    snippet: str,
    parent_chunks: list[str],
    *,
    strong_len: int = 8,
    long_unanchored_len: int = 12,
) -> str:
    """Grade a snippet's attribution trustworthiness.

    `parent_chunks` are the literal URL chunks the snippet was drawn from
    (the template's own chunk list). Anchoring is judged against them.

    **Anchoring is the primary axis.** Empirically (Log4Shell 2021 + galah
    2024 corpora), anchoring alone separates the coincidental fragments
    (``e64/`` from ``base64/``, ``//19`` from ``http://192...``, ``edis``
    from ``redis``, all *unanchored*) from legitimate short path tokens
    (``saml`` in ``/saml/login``, ``mgmt`` in ``/mgmt/tm/util/bash``, both
    *anchored*). Length is a secondary, weaker signal.

    Rules (first match wins):
      * anchored AND length >= strong_len              -> STRONG
      * anchored AND not a generic token (see
        `is_generic_token`: no letters, or a common word) -> MEDIUM
      * unanchored AND length >= long_unanchored_len   -> MEDIUM
      * otherwise                                      -> WEAK

    The one place a long *unanchored* snippet still earns MEDIUM is when
    it is long enough (>= long_unanchored_len) that coincidental collision
    is implausible even without boundary alignment -- e.g. a Base64 XSS
    marker or an OGNL payload substring.
    """
    if not snippet:
        return WEAK
    anchored = any(_edges_anchored(snippet, c) for c in parent_chunks if snippet in c)
    n = len(snippet)
    if anchored and n >= strong_len:
        return STRONG
    if anchored and not is_generic_token(snippet, strong_len=strong_len):
        return MEDIUM
    if n >= long_unanchored_len:
        return MEDIUM
    return WEAK
