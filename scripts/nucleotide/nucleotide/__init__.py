"""nucleotide -- reverse-engineer threat-actor tool + CLI choices from
observed Nuclei traffic, and emit portable detection rules + actor
fingerprint artifacts.

Public API (stable):
  build_lookup                 -- fetch/parse a Nuclei templates tree and
                                  build the URL-snippet lookup + signatures
  compute_unique_snippets      -- underlying shortest-unique-substring solver
  fingerprint                  -- events + lookup -> actor fingerprint dict
  parse_events_jsonl           -- read a JSONL event file
  to_yaml                      -- serialize a fingerprint dict to YAML text
  TIERS, TIER_URL, TIER_HEADER,
  TIER_BODY, TIER_TLS,
  TIER_RESPONSE                -- observability tier constants

See docs/user-guide.md for the full walkthrough.
"""

__version__ = "2.0.0"

from .actor import fingerprint, parse_events_jsonl, to_yaml
from .build import build_lookup
from .signatures import (
    TIER_BODY,
    TIER_HEADER,
    TIER_RESPONSE,
    TIER_TLS,
    TIER_URL,
    TIERS,
)
from .snippets import compute_unique_snippets

__all__ = [
    "__version__",
    "build_lookup",
    "compute_unique_snippets",
    "fingerprint",
    "parse_events_jsonl",
    "to_yaml",
    "TIERS",
    "TIER_URL",
    "TIER_HEADER",
    "TIER_BODY",
    "TIER_TLS",
    "TIER_RESPONSE",
]
