"""
Nebula AI — Model Warm-up (1-token inference).

Invoked by nebula-warmup.service (Type=oneshot, NOT autoenabled — operator
opts in via the Control Center or ``systemctl enable nebula-warmup.service``).

Issues a single 1-token inference against the loaded model so the GGUF is
paged into RAM before the first real operator request arrives.  This trades
boot time for first-response latency — a UX trade-off left to the operator.

Exit codes:
    0 — warm-up inference completed successfully
    1 — warm-up failed (ollama not reachable, no model loaded, inference error)

@decision DEC-PHASE10-010
@title nebula-warmup: opt-in 1-token inference; NOT autoenabled at boot
@status accepted
@rationale Loading 4.4 GB into RAM unconditionally adds ~10-30 s boot time and
  ~4.5 GB RAM consumption for every boot, even when the operator never uses
  Nebula in that session.  Lazy-start (socket activation) is the default; this
  unit is the explicit opt-in for operators who prefer low first-response latency
  over boot speed.  References: DEC-PHASE10-010.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import json
import logging
import sys
import urllib.error
import urllib.request
from typing import Optional

from .helpers.paths import OLLAMA_BASE_URL, WARMUP_LOG

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [nebula-warmup] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
    stream=sys.stderr,
)
logger = logging.getLogger("nebula.warmup")

# 1-token prompt — minimal inference to page the model weights into RAM.
_WARMUP_PROMPT = "Hello"
_WARMUP_TIMEOUT = 300  # 5 minutes; first load of 4.4 GB can be slow on CPU


def _get_first_model() -> Optional[str]:
    """Return the name of the first model registered with ollama, or None."""
    try:
        req = urllib.request.Request(f"{OLLAMA_BASE_URL}/api/tags", method="GET")
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        models = data.get("models", [])
        if models:
            return str(models[0].get("name", ""))
    except (urllib.error.URLError, OSError, ValueError, KeyError):
        pass
    return None


def run_warmup() -> bool:
    """Issue a 1-token inference to warm the model into RAM.

    Returns True on success, False on any failure.
    """
    model_name = _get_first_model()
    if model_name is None:
        logger.error(
            "No models found in ollama — cannot warm up.  "
            "Ensure nebula-runtime.service is running and the model is registered."
        )
        return False

    logger.info("Warming up model: %s (1-token inference)", model_name)

    payload = json.dumps(
        {
            "model": model_name,
            "prompt": _WARMUP_PROMPT,
            "stream": False,
            "options": {"num_predict": 1},
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        f"{OLLAMA_BASE_URL}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=_WARMUP_TIMEOUT) as resp:
            body = resp.read().decode("utf-8")
        result = json.loads(body)
        logger.info(
            "Warm-up complete: model=%s done=%s total_duration=%s ns",
            model_name,
            result.get("done"),
            result.get("total_duration"),
        )
        return bool(result.get("done", False))
    except urllib.error.URLError as exc:
        logger.error("Warm-up failed — ollama not reachable: %s", exc)
    except (OSError, ValueError) as exc:
        logger.error("Warm-up failed — unexpected error: %s", exc)
    return False


def main(argv: Optional[list[str]] = None) -> int:
    """CLI entrypoint.  Returns 0 on success, 1 on failure."""
    logger.info("nebula warmup starting (log: %s)", WARMUP_LOG)
    success = run_warmup()
    if success:
        logger.info("nebula warmup PASSED")
        return 0
    logger.error("nebula warmup FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
