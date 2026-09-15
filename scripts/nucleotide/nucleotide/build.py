"""Orchestrate fetch + parse + snippet computation + fingerprint extraction."""

from __future__ import annotations

import datetime
import subprocess
from collections import Counter
from pathlib import Path
from typing import Any

from .quality import snippet_quality
from .fingerprint import extract_fingerprints
from .parse import (
    extract_literal_chunks,
    extract_payloads,
    iter_template_files,
    materialize_paths,
    normalize_paths,
    parse_template,
)
from .signatures import build_signatures
from .snippets import compute_unique_snippets


def build_lookup(
    templates_dir: Path,
    *,
    source_url: str | None = None,
    min_snippet_len: int = 4,
) -> dict[str, Any]:
    templates_dir = Path(templates_dir)
    templates: dict[str, dict[str, Any]] = {}
    corpus: dict[str, list[str]] = {}

    for f in iter_template_files(templates_dir):
        doc = parse_template(f)
        if not doc:
            continue
        rel = f.relative_to(templates_dir).as_posix()
        base_id = str(doc["id"])
        tid = base_id if base_id not in templates else f"{base_id}@{rel}"
        info = doc.get("info") or {}
        paths = normalize_paths(doc)
        # Expand `path: [{{BaseURL}}{{X}}]` + `payloads: {X: [...]}` into
        # concrete detection paths, then chunk. Templates whose real URL
        # surface lives in `payloads:` (laravel-env, generic-linux-lfi,
        # xss-fuzz, etc.) would otherwise emit no URI signature at all.
        payloads = extract_payloads(doc)
        materialized = materialize_paths(paths, payloads)
        chunks: list[str] = []
        for p in materialized:
            chunks.extend(extract_literal_chunks(p))
        templates[tid] = {
            "id": base_id,
            "name": info.get("name"),
            "severity": info.get("severity"),
            "tags": _split_tags(info.get("tags")),
            "file": rel,
            "paths": paths,
            "materialized_paths": materialized if payloads else [],
            "payload_names": sorted(payloads),
            "chunks": sorted({c for c in chunks if len(c) >= min_snippet_len}),
            "fingerprints": extract_fingerprints(doc),
        }
        corpus[tid] = chunks

    http_corpus = {tid: chunks for tid, chunks in corpus.items() if chunks}
    snippets, unresolved = compute_unique_snippets(http_corpus, min_len=min_snippet_len)

    # Grade every resolved snippet by attribution trustworthiness (length +
    # anchoring). A 4-byte fragment sliced from the middle of a longer
    # literal is "unique" but not trustworthy; recording the tier lets
    # `lookup` and actor inference gate on it instead of trusting blindly.
    snippet_quality_map: dict[str, str] = {}
    for tid, snip in snippets.items():
        q = snippet_quality(snip, http_corpus.get(tid, []))
        templates[tid]["url_snippet"] = snip
        templates[tid]["snippet_quality"] = q
        snippet_quality_map[snip] = q
    for tid in templates:
        templates[tid].setdefault("url_snippet", snippets.get(tid))
        templates[tid].setdefault("snippet_quality", None)

    snippet_index = {snip: tid for tid, snip in snippets.items()}
    no_url_count = sum(1 for chunks in corpus.values() if not chunks)
    quality_counts = Counter(snippet_quality_map.values())

    result = {
        "metadata": {
            "generated_utc": datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z",
            "source": source_url,
            "commit": _git_head(templates_dir),
            "template_count": len(templates),
            "http_template_count": len(http_corpus),
            "resolved_snippets": len(snippets),
            "unresolved_count": len(unresolved),
            "no_url_template_count": no_url_count,
            "min_snippet_len": min_snippet_len,
            "snippet_quality_counts": dict(quality_counts),
        },
        "templates": templates,
        "snippet_index": snippet_index,
        "snippet_quality": snippet_quality_map,
        "unresolved": unresolved,
    }
    result["signatures"] = build_signatures(result)
    return result


def _split_tags(tags: Any) -> list[str]:
    if isinstance(tags, list):
        return [str(t) for t in tags]
    if isinstance(tags, str):
        return [t.strip() for t in tags.split(",") if t.strip()]
    return []


def _git_head(d: Path) -> str | None:
    try:
        r = subprocess.run(
            ["git", "-C", str(d), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
        return r.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
