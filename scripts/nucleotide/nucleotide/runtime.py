"""Nuclei runtime constants used for tool-and-CLI-option inference.

Every value in this module is *observable in traffic* -- we don't do any
binary analysis or dynamic instrumentation. If Nuclei sets a distinctive
User-Agent, tries a specific header injection order, or points OAST
callbacks at a specific host, we record it here so that the actor
fingerprinter can compare observed traffic to what stock Nuclei would
produce and infer:
  - the tool (nuclei vs a different tool consuming the same YAMLs)
  - the CLI options (-rate-limit, -H, -random-agent, -interactsh-server,
    -scan-strategy, etc.)

Sources:
- Nuclei's built-in User-Agent list lives in nuclei-templates.git and is
  the pool `-random-agent` samples from at runtime; we vendor a
  representative subset here.
- The default OAST callback hosts are the ones ProjectDiscovery operates
  publicly for `interactsh-client`; see the interactsh README.
- The Go net/http JA3 hash range is what a stock Go client produces (any
  Go binary using net/http converges on the same ClientHello absent
  transport customization). We keep this loose (a `matches_go_net_http`
  predicate) rather than pinning to a single hash because Go's TLS
  ClientHello has evolved across releases and the operator will care
  about "is this a Go client" more than "is this specifically Go 1.21".
"""

from __future__ import annotations

import re
from typing import Iterable

# Default User-Agent Nuclei emits when no `-H` / `-user-agent` /
# `-random-agent` is set. Format is stable across the 3.x line.
NUCLEI_DEFAULT_UA_RE = re.compile(r"^Nuclei\s*-\s*Open-source\s*project", re.I)
NUCLEI_DEFAULT_UA_EXAMPLE = "Nuclei - Open-source project (github.com/projectdiscovery/nuclei)"

# A representative slice of Nuclei's `-random-agent` UA pool. If an actor's
# observed UAs all fall inside this set (and the actor uses more than one
# UA), the fingerprinter concludes `-random-agent: true`. The full pool is
# larger; a 90%+ overlap is enough evidence given other corroborating
# signals.
NUCLEI_RANDOM_UA_POOL = frozenset(
    {
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36 Edge/16.16299",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.169 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.132 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.75 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/100.0.4896.75 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; WOW64; rv:56.0) Gecko/20100101 Firefox/56.0",
        "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:56.0) Gecko/20100101 Firefox/56.0",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.5 Safari/605.1.15",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Safari/605.1.15",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/74.0.3729.169 Safari/537.36",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 12_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Linux; Android 8.0.0; SM-G960F Build/R16NW) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/62.0.3202.84 Mobile Safari/537.36",
        "curl/7.68.0",
    }
)

# The publicly-operated interactsh callback hosts. When an actor's observed
# OAST callback URLs all resolve to one of these, the fingerprinter records
# that as the default `-interactsh-server`; a callback host outside this
# set is high-signal evidence of a custom `-interactsh-server`.
NUCLEI_DEFAULT_OAST_HOSTS = frozenset(
    {
        "oast.pro",
        "oast.online",
        "oast.site",
        "oast.live",
        "oast.fun",
        "oast.me",
    }
)


def is_nuclei_default_ua(ua: str) -> bool:
    """Return True if `ua` looks like Nuclei's stock default User-Agent."""
    return bool(ua and NUCLEI_DEFAULT_UA_RE.match(ua))


def is_nuclei_random_agent_ua(ua: str) -> bool:
    """Return True if `ua` is drawn from Nuclei's built-in `-random-agent` pool."""
    return ua in NUCLEI_RANDOM_UA_POOL


def is_default_oast_host(host: str) -> bool:
    """Return True if `host` (or a subdomain of it) is a default interactsh host."""
    if not host:
        return False
    host = host.lower().strip()
    for default in NUCLEI_DEFAULT_OAST_HOSTS:
        if host == default or host.endswith("." + default):
            return True
    return False


def looks_like_go_net_http(ja3: str | None, ja4: str | None) -> bool:
    """Rough matcher for a Go net/http-issued ClientHello.

    Go's `crypto/tls` ClientHello is distinctive but not stable across Go
    versions; the operator supplies whichever JA3/JA4 they've collected
    from known-Nuclei traffic. We keep this a placeholder that always
    returns False today -- the operator can pass a `--go-http-ja3` fleet
    to the fingerprinter to seed it. This deliberately doesn't hard-code
    a single JA3 value because Go's TLS stack has shifted between 1.20
    and 1.23 in ways that change JA3.

    Returns False when the caller has no reference set to compare against.
    """
    # Intentional: we don't ship a canned Go JA3 list. See docstring.
    return False


# --- Nuclei tag inventory helpers ---
# When the fingerprinter has a corpus of templates and a set of hit
# templates, we ask: what tag intersection describes all of them? That's
# an educated guess for `-tags <t1,t2,...>`. Also useful is the set
# difference: tags common to the corpus but MISSING from the hits could
# indicate `-exclude-tags`.


def tag_intersection(template_tags: Iterable[Iterable[str]]) -> list[str]:
    """Return the sorted set of tags present in *every* input tag list."""
    common: set[str] | None = None
    for tags in template_tags:
        s = set(tags)
        common = s if common is None else (common & s)
    return sorted(common or [])


def tag_union(template_tags: Iterable[Iterable[str]]) -> list[str]:
    """Return the sorted set of tags present in *any* input tag list."""
    all_tags: set[str] = set()
    for tags in template_tags:
        all_tags.update(tags)
    return sorted(all_tags)
