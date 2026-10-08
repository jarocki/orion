"""posture_data — what the threat-posture control may honestly say (DEC-PHASE12-070).

@decision DEC-PHASE12-070
@title Selecting a tier is a request; only orionx-postured's status confirms enforcement
@status accepted
@rationale ux.md UX-01 (P0). Clicking a tier wrote ~/.config/orionx/threat-posture
  (ignoring write failures) and toasted "✓ Threat posture set" / "Tier 2
  Deception armed — opt-in assets active". Enforcement is done later, as root,
  by orionx-postured, which may be down or running an IDS with no rules. The
  toast now says "requested" and the Awareness tab re-reads
  /run/orionx/posture-status.json until it confirms the requested tier (with
  the same NO IDS RULES / IDS DOWN / UNENFORCED wording as the Cockpit badge,
  cockpit_lib.posture_badge), or until it is clear nothing is enforcing it.
  Pure: the tab feeds it the status dict and the clock.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "cockpit"))
import cockpit_lib  # noqa: E402  (posture_badge, POSTURE_STATUS_FILE: one wording, one file)

STATUS_FILE = cockpit_lib.POSTURE_STATUS_FILE
STALE_AFTER = 30.0       # postured rewrites the file every poll (2 s)
CONFIRM_WITHIN = 15.0    # how long a request may stay unconfirmed before we say so
TIER_LABEL = {"0": "Tier 0 · Passive", "1": "Tier 1 · Active Monitoring", "2": "Tier 2 · Deception"}


def read_status(path: Path = STATUS_FILE) -> dict[str, Any]:
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def verdict(requested: str, status: dict[str, Any], requested_at: float, now: float) -> dict[str, Any]:
    """{'state': pending|enforced|degraded|not-enforced, 'level': ok|info|error, 'text': str}."""
    want = TIER_LABEL.get(requested, f"Tier {requested}")
    try:
        ts = float(status.get("ts", 0) or 0)
    except (TypeError, ValueError):
        ts = 0.0
    fresh = bool(status) and ts > 0 and now - ts <= STALE_AFTER
    waited = now - requested_at
    have = str(status.get("tier", "")) if fresh else ""
    if fresh and have == requested and ts >= requested_at - 1.0:
        label, badge = cockpit_lib.posture_badge(requested, status)
        if badge == "ok":
            extra = ""
            if requested == "2":
                extra = " — deception armed" if status.get("deception_armed") else " — deception NOT armed (check: journalctl -u orionx-postured)"
                if not status.get("deception_armed"):
                    return {"state": "degraded", "level": "error", "text": f"⚠ {want} enforced{extra}"}
            return {"state": "enforced", "level": "ok", "text": f"✓ {want} enforced by orionx-postured{extra}"}
        why = label.split("⚠", 1)[-1].strip()
        return {"state": "degraded", "level": "error",
                "text": f"⚠ {want} selected but {why} — journalctl -u orionx-postured"}
    if waited < CONFIRM_WITHIN:
        return {"state": "pending", "level": "info",
                "text": f"requested {want} — waiting for orionx-postured to confirm…"}
    if not fresh:
        why = "not running" if not status else f"not publishing (status {now - ts:.0f} s old)"
        return {"state": "not-enforced", "level": "error",
                "text": f"✗ {want} NOT enforced: orionx-postured {why} — sudo systemctl start orionx-postured"}
    return {"state": "not-enforced", "level": "error",
            "text": f"✗ {want} NOT enforced: orionx-postured still reports "
                    f"{TIER_LABEL.get(have, 'Tier ' + have)} after {waited:.0f} s — journalctl -u orionx-postured"}
