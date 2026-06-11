"""
Thin ollama API client — stdlib only, no third-party dependencies.

W10-1 requires only status checks (is ollama running? what model is loaded?).
Full inference calls land in W10-2 (chat.py). This module provides the minimal
surface needed by:
  - scripts/nebula/status.py  (CLI `nebula status`)
  - scripts/control_center/sections/nebula.py  (Control Center live status row)

@decision DEC-PHASE10-008
@title runtime_client: stdlib-only thin wrapper around ollama REST API
@status accepted
@rationale W10-1 must not introduce third-party deps (even ollama-python is
  optional at this slice — the --version and status paths must work without it).
  urllib.request covers the simple GET /api/tags and GET /api/version calls
  needed here. W10-2 may add ollama-python for streaming; this module remains
  the non-optional fallback for status checks. References: DEC-PHASE10-008,
  DEC-006 (localhost-only — BASE_URL is 127.0.0.1 only).
"""
from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any

from .paths import OLLAMA_BASE_URL

logger = logging.getLogger(__name__)

# Connection timeout for all ollama API calls (seconds).
# ollama may take a moment to respond when it is starting up under socket
# activation; 5 s is generous without blocking the Control Center status poll.
_TIMEOUT: int = 5


def _get(path: str) -> dict[str, Any]:
    """Perform a GET request to the ollama API and return parsed JSON.

    Raises:
        urllib.error.URLError: if the connection is refused (daemon not running).
        urllib.error.HTTPError: on non-2xx HTTP status from ollama.
        json.JSONDecodeError: if the response body is not valid JSON.
    """
    url = f"{OLLAMA_BASE_URL}{path}"
    req = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(req, timeout=_TIMEOUT) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)  # type: ignore[no-any-return]


def get_version() -> str | None:
    """Return the ollama server version string, or None if the daemon is down.

    Example return: "0.3.12"
    Returns None on any connection or HTTP error (daemon not running).
    """
    try:
        data = _get("/api/version")
        return str(data.get("version", "unknown"))
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return None


def list_models() -> list[dict[str, Any]]:
    """Return the list of models known to ollama (GET /api/tags).

    Returns an empty list if the daemon is down or no models are loaded.
    Each entry is the raw dict from the ollama API response (name, size, etc.).
    """
    try:
        data = _get("/api/tags")
        return data.get("models", [])  # type: ignore[return-value]
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError):
        return []


def is_running() -> bool:
    """Return True if the ollama daemon is reachable on localhost:11434."""
    return get_version() is not None


def get_loaded_model_name() -> str | None:
    """Return the name of the first model ollama knows about, or None.

    This does NOT verify the model is loaded into RAM — it only checks
    what ollama has registered. Use for status display, not inference gating.
    """
    models = list_models()
    if models:
        return str(models[0].get("name", "unknown"))
    return None
