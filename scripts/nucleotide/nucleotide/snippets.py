"""Compute the shortest substring of a template's URL that is unique across the corpus."""

from __future__ import annotations

from collections import defaultdict
from typing import Mapping

from .quality import edge_anchored as _is_anchored, is_generic_token


def compute_unique_snippets(
    corpus: Mapping[str, list[str]],
    *,
    min_len: int = 4,
    max_len: int = 80,
    prefer_anchored: bool = True,
    skip_generic: bool = True,
) -> tuple[dict[str, str], list[str]]:
    """Find each template's shortest *trustworthy* URL substring unique across the corpus.

    `corpus` maps template_id -> list of literal URL chunks (placeholders already stripped).
    Returns (snippets, unresolved) where:
      - `snippets[tid]` is the chosen substring,
      - `unresolved` lists template ids that share all their substrings with another
        template (or have no chunks long enough to qualify).

    Selection strategy (when `prefer_anchored`):
      At each growing length, a template resolves only on a substring that is
      BOTH unique AND anchored to a path boundary. Only if the template can
      never be resolved with an anchored snippet (checked in a second pass)
      does it fall back to the shortest unique *unanchored* substring. This
      prevents picking `s/ak` (a mid-token fragment of `akismet`) when a
      slightly longer `/akismet/` is available and far more trustworthy.

      When `skip_generic`, the anchored pass also refuses short candidates
      that `quality.is_generic_token` rejects (bare numbers, common English
      words), so `landray-eis-ws-infoleak` resolves on `WS/Basic` rather
      than on `Basic`, which matches `/Basic/Command/` in JNDI payloads.
    """
    candidates = {tid: [c for c in chunks if c] for tid, chunks in corpus.items()}
    resolved: dict[str, str] = {}
    unresolved = {tid for tid, ch in candidates.items() if ch}
    no_chunks = [tid for tid, ch in candidates.items() if not ch]

    def _pass(require_anchored: bool) -> None:
        pending = set(unresolved)
        for length in range(min_len, max_len + 1):
            if not pending:
                break
            owners: dict[str, set[str]] = defaultdict(set)
            for tid, chunks in candidates.items():
                seen: set[str] = set()
                for c in chunks:
                    if len(c) < length:
                        continue
                    for i in range(len(c) - length + 1):
                        seen.add(c[i : i + length])
                for s in seen:
                    owners[s].add(tid)

            for tid in list(pending):
                chosen: str | None = None
                for c in candidates[tid]:
                    if len(c) < length:
                        continue
                    for i in range(len(c) - length + 1):
                        s = c[i : i + length]
                        if len(owners.get(s, ())) != 1:
                            continue
                        if require_anchored and not _is_anchored(c, i, length):
                            continue
                        if require_anchored and skip_generic and is_generic_token(s):
                            continue
                        chosen = s
                        break
                    if chosen is not None:
                        break
                if chosen is not None:
                    resolved[tid] = chosen
                    pending.discard(tid)
                    unresolved.discard(tid)

    if prefer_anchored:
        _pass(require_anchored=True)
    # Fallback: templates with no anchored-unique substring take the shortest
    # unique substring of any kind (recorded, but they'll grade as weak).
    _pass(require_anchored=False)

    return resolved, sorted(unresolved | set(no_chunks))
