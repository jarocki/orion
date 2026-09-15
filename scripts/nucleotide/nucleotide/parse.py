"""Walk a directory of Nuclei templates and extract URL paths + literal chunks."""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Iterator

import yaml

PLACEHOLDER_RE = re.compile(r"\{\{[^}]*\}\}")
SKIP_DIRS = {".git", ".github", "node_modules", ".venv", "__pycache__"}


def iter_template_files(root: Path) -> Iterator[Path]:
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]
        for fn in filenames:
            if fn.endswith((".yaml", ".yml")):
                yield Path(dirpath) / fn


def parse_template(path: Path) -> dict | None:
    try:
        with path.open("rb") as f:
            doc = yaml.safe_load(f)
    except (yaml.YAMLError, OSError, UnicodeDecodeError):
        return None
    if not isinstance(doc, dict) or "id" not in doc or "info" not in doc:
        return None
    return doc


def _path_from_raw(raw: str) -> str | None:
    """Pull the request-target out of the first line of a raw HTTP request.

    Only accepts targets that look like a real request-target: an origin-form
    path (`/...`), an absolute-form URL, or `*` (OPTIONS *). This filters out
    templates with malformed request lines whose `parts[1]` would otherwise
    be misread as a path (e.g., a literal `HTTP/1.1`).
    """
    first = raw.lstrip().splitlines()[0] if raw.strip() else ""
    parts = first.split()
    if len(parts) < 2 or not parts[0].isupper():
        return None
    target = parts[1]
    if target == "*" or target.startswith(("/", "http://", "https://")):
        return target
    return None


def normalize_paths(template: dict) -> list[str]:
    paths: list[str] = []
    for key in ("http", "requests"):
        block = template.get(key)
        if not isinstance(block, list):
            continue
        for req in block:
            if not isinstance(req, dict):
                continue
            for p in req.get("path") or []:
                if isinstance(p, str):
                    paths.append(p)
            for raw in req.get("raw") or []:
                if isinstance(raw, str):
                    p = _path_from_raw(raw)
                    if p:
                        paths.append(p)
    return paths


def extract_literal_chunks(path: str) -> list[str]:
    """Strip Nuclei placeholder expressions and return the literal substrings."""
    return [c for c in PLACEHOLDER_RE.split(path) if c]


# Cap the number of materialized paths per template so a template with a
# huge payload list doesn't blow up the chunk set. Templates like
# generic-linux-lfi ship 30+ path variants, xss-fuzz ships 29+ ~500-char
# XSS payloads -- we take the first N unique values.
_MAX_PAYLOAD_MATERIALIZATION = 40


def extract_payloads(template: dict) -> dict[str, list[str]]:
    """Return `{payload_name: [values...]}` for every http/requests block.

    Payload values that reference an external helper file (given as a string
    path instead of an inline list) are skipped -- we only have the YAML in
    hand, not the referenced helpers directory. Non-string list entries are
    coerced to `str()`.
    """
    result: dict[str, list[str]] = {}
    for key in ("http", "requests"):
        block = template.get(key)
        if not isinstance(block, list):
            continue
        for req in block:
            if not isinstance(req, dict):
                continue
            p = req.get("payloads")
            if not isinstance(p, dict):
                continue
            for name, vals in p.items():
                if not isinstance(name, str):
                    continue
                if not isinstance(vals, list):
                    # References like `payloads: {paths: helpers/foo.txt}`
                    # can't be materialized without the helper file.
                    continue
                strings = [
                    str(v) for v in vals if isinstance(v, (str, int, float))
                ]
                if strings:
                    result.setdefault(name, []).extend(strings)
    return result


def materialize_paths(
    paths: list[str],
    payloads: dict[str, list[str]],
    *,
    cap: int = _MAX_PAYLOAD_MATERIALIZATION,
) -> list[str]:
    """Expand `{{X}}` placeholders using known payload values.

    Runs one substitution round per payload variable (not a full cartesian
    product) to bound output size. The output list contains both the
    original paths and every materialization; duplicates are dropped.
    """
    seen: set[str] = set()
    out: list[str] = []
    for p in paths:
        if p not in seen:
            seen.add(p)
            out.append(p)
    for name, values in payloads.items():
        token = "{{" + name + "}}"
        pending: list[str] = []
        for existing in out:
            if token not in existing:
                continue
            for v in values:
                materialized = existing.replace(token, v)
                if materialized in seen:
                    continue
                seen.add(materialized)
                pending.append(materialized)
                if len(seen) >= cap + len(paths):
                    break
            if len(seen) >= cap + len(paths):
                break
        out.extend(pending)
        if len(seen) >= cap + len(paths):
            break
    return out
