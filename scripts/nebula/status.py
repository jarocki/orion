"""
Nebula AI — Runtime Status Reporter.

Produces a JSON status snapshot consumed by:
  - ``nebula status`` CLI subcommand
  - scripts/control_center/sections/nebula.py (live status row in the UI)

Output format (JSON to stdout)::

    {
        "ollama_running": true | false,
        "ollama_version": "0.3.12" | null,
        "integrity_state": "OK" | "FAIL" | "UNKNOWN",
        "integrity_detail": "<human-readable>",
        "model_name": "qwen2.5:3b-instruct-q4_K_M" | null,
        "model_size_bytes": 1940000000 | null,
        "manifest_present": true | false,
        "status_summary": "Runtime: ready, model: Qwen2.5-3B-Instruct-Q4_K_M (~1.9 GB, integrity OK)"
                        | "Runtime: down"
                        | "Runtime: integrity-failed"
    }

Exit codes:
    0 — status retrieved (even if runtime is down — the JSON is the answer)
    1 — unexpected error reading status

@decision DEC-PHASE10-005
@title status.py: single authority for machine-readable Nebula runtime status
@status accepted
@rationale The Control Center (scripts/control_center/sections/nebula.py) must
  not contain duplicated status logic.  All runtime introspection lives here;
  the Control Center calls ``nebula status --json`` (or imports this module) and
  renders whatever it receives.  References: DEC-PHASE10-005, DEC-PHASE10-009.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import json
import logging
import sys
from pathlib import Path
from typing import Any, Optional

from .helpers.paths import (
    INTEGRITY_STATUS_FILE,
    MANIFEST_FILE,
    MODELS_DIR,
)
from .helpers.runtime_client import get_version, is_running, list_models

logger = logging.getLogger("nebula.status")


def _read_integrity_status(status_file: Path = INTEGRITY_STATUS_FILE) -> dict[str, str]:
    """Parse the key=value integrity status file written by integrity.py.

    Returns a dict with keys NEBULA_INTEGRITY, NEBULA_INTEGRITY_DETAIL,
    NEBULA_INTEGRITY_TS (all strings).  Returns UNKNOWN state on any read error.
    """
    if not status_file.exists():
        return {
            "NEBULA_INTEGRITY": "UNKNOWN",
            "NEBULA_INTEGRITY_DETAIL": "status file not found (integrity check may not have run yet)",
            "NEBULA_INTEGRITY_TS": "",
        }
    result: dict[str, str] = {}
    try:
        for line in status_file.read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, _, val = line.partition("=")
                result[key.strip()] = val.strip()
    except OSError as exc:
        logger.warning("Cannot read integrity status file %s: %s", status_file, exc)
        return {
            "NEBULA_INTEGRITY": "UNKNOWN",
            "NEBULA_INTEGRITY_DETAIL": f"read error: {exc}",
            "NEBULA_INTEGRITY_TS": "",
        }
    # Fill any missing keys with defaults
    result.setdefault("NEBULA_INTEGRITY", "UNKNOWN")
    result.setdefault("NEBULA_INTEGRITY_DETAIL", "")
    result.setdefault("NEBULA_INTEGRITY_TS", "")
    return result


def _model_size_from_manifest(manifest_file: Path = MANIFEST_FILE) -> Optional[int]:
    """Read the model size from MANIFEST.sha256 via stat on the actual file.

    Returns the size in bytes or None if the model file cannot be found.
    """
    if not manifest_file.exists():
        return None
    try:
        for line in manifest_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("  ", 1)
            if len(parts) == 2:
                filename = parts[1].strip()
                model_path = MODELS_DIR / filename
                if model_path.exists():
                    return model_path.stat().st_size
    except OSError:
        pass
    return None


def collect_status() -> dict[str, Any]:
    """Collect and return the full Nebula runtime status as a dict."""
    running = is_running()
    version = get_version() if running else None
    models = list_models() if running else []

    model_name: Optional[str] = None
    if models:
        model_name = str(models[0].get("name", "unknown"))

    integrity = _read_integrity_status()
    integrity_state = integrity.get("NEBULA_INTEGRITY", "UNKNOWN")
    integrity_detail = integrity.get("NEBULA_INTEGRITY_DETAIL", "")

    manifest_present = MANIFEST_FILE.exists()
    model_size = _model_size_from_manifest()
    model_size_gb = f"{model_size / 1024 / 1024 / 1024:.1f} GB" if model_size else None

    # Compose a human-readable summary line (the Control Center renders this)
    if not running:
        summary = "Runtime: down"
    elif integrity_state == "FAIL":
        summary = "Runtime: integrity-failed"
    else:
        name_part = model_name or "unknown-model"
        size_part = f", {model_size_gb}" if model_size_gb else ""
        integrity_badge = "integrity OK" if integrity_state == "OK" else f"integrity {integrity_state}"
        summary = f"Runtime: ready, model: {name_part}{size_part}, {integrity_badge}"

    return {
        "ollama_running": running,
        "ollama_version": version,
        "integrity_state": integrity_state,
        "integrity_detail": integrity_detail,
        "model_name": model_name,
        "model_size_bytes": model_size,
        "manifest_present": manifest_present,
        "status_summary": summary,
    }


def main(argv: Optional[list[str]] = None) -> int:
    """CLI entrypoint — prints JSON status to stdout and exits 0."""
    try:
        data = collect_status()
        print(json.dumps(data, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        logger.error("Unexpected error collecting Nebula status: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
