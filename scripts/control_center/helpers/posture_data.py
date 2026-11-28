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
# The REQUEST file: user-writable, read by orionx-postured and the status strip.
REQUEST_FILE = cockpit_lib.POSTURE_FILE
# DEC-PHASE13-073: manual sensor start/stop, read by orionx-postured beside
# the request file. One `name=on|off` per line; absent = follow the tier.
SENSORS_FILE = REQUEST_FILE.parent / "sensors"
SENSOR_NAMES = ("suricata", "zeek")
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


def load_request(path: Path = REQUEST_FILE) -> str:
    """The tier the operator last requested ('0' when unset or unreadable)."""
    try:
        val = Path(path).read_text(encoding="utf-8").strip()
        return val if val in TIER_LABEL else "0"
    except OSError:
        return "0"


def request_tier(tier: str, path: Path = REQUEST_FILE) -> tuple[bool, str]:
    """THE writer of the threat-posture request file (#95, DEC-PHASE13-048).

    Moved here from the Awareness tab when the control moved to the Cockpit
    settings drawer, so the write is one function a GTK-free test can call.
    Returns settings_io's (ok, error text); a refused tier writes nothing.
    """
    if tier not in TIER_LABEL:
        return False, f"{path}: unknown tier {tier!r} (one of {', '.join(TIER_LABEL)})"
    from . import settings_io  # noqa: PLC0415  (imports tuning_lib; keep verdict() import-light)
    # DEC-PHASE13-073: a deliberate tier change puts both sensors back under
    # the tier. Cleared first, so the daemon never applies the new tier with
    # an override that belonged to the old one for longer than one poll.
    sensors = Path(path).parent / SENSORS_FILE.name
    try:
        sensors.unlink()
    except FileNotFoundError:
        pass
    except OSError as exc:
        return False, f"{sensors}: {exc.strerror or exc}"
    return settings_io.atomic_write_text(Path(path), tier + "\n")


def load_sensor_overrides(path: Path = SENSORS_FILE) -> dict[str, bool]:
    """The operator's manual sensor state, parsed the way orionx-postured parses it."""
    out: dict[str, bool] = {}
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError:
        return out
    for line in text.splitlines():
        name, sep, val = line.strip().partition("=")
        if sep and name.strip() in SENSOR_NAMES and val.strip().lower() in ("on", "off"):
            out[name.strip()] = val.strip().lower() == "on"
    return out


def request_sensor(name: str, state: bool | None, path: Path = SENSORS_FILE) -> tuple[bool, str]:
    """THE writer of the sensors file: start (True), stop (False) or follow the tier (None)."""
    if name not in SENSOR_NAMES:
        return False, f"{path}: unknown sensor {name!r} (one of {', '.join(SENSOR_NAMES)})"
    from . import settings_io  # noqa: PLC0415
    cur = load_sensor_overrides(path)
    if state is None:
        cur.pop(name, None)
    else:
        cur[name] = bool(state)
    if not cur:
        try:
            Path(path).unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            return False, f"{path}: {exc.strerror or exc}"
        return True, ""
    text = "".join(f"{n}={'on' if cur[n] else 'off'}\n" for n in SENSOR_NAMES if n in cur)
    return settings_io.atomic_write_text(Path(path), text)


def sensor_view(name: str, status: dict[str, Any], now: float, overrides: dict[str, bool] | None = None) -> dict[str, Any]:
    """Status word, colour key, detail line and the buttons for one sensor tile.

    {'word','level','line','start','stop','follow'}: level is ok|info|warn|error;
    start/stop/follow say which buttons are offered.
    """
    label = "Suricata" if name == "suricata" else "Zeek"
    try:
        fresh = bool(status) and now - float(status.get("ts", 0) or 0) <= STALE_AFTER
    except (TypeError, ValueError):
        fresh = False
    s = ((status.get("sensors") or {}).get(name) or {}) if fresh else {}
    manual = name in (overrides or {})
    tier = TIER_LABEL.get(str(status.get("tier")), "the tier") if fresh else "the tier"
    if not fresh or not s:
        return {"word": "UNKNOWN", "level": "warn", "start": True, "stop": True, "follow": manual, "label": label,
                "line": "orionx-postured is not reporting — journalctl -u orionx-postured"}
    active, wanted = bool(s.get("active")), bool(s.get("wanted"))
    ifaces = ", ".join(s.get("capture_ifaces") or []) or "no interface"
    who = "started by you" if manual and wanted else "stopped by you" if manual else f"by {tier}"
    if active:
        word, level, line = "RUNNING", "ok", f"on {ifaces} · {who}"
    elif wanted:
        why = ("no network interface is up — it starts when one is"
               if not s.get("capture_ifaces") else "starting, or failed — see LIVE events")
        word, level, line = ("WAITING" if not s.get("capture_ifaces") else "DOWN"), "error", f"{who}; {why}"
    else:
        word, level, line = "STOPPED", ("warn" if manual else "info"), who
    if manual:
        line += " · Follow tier returns it to " + tier
    return {"word": word, "level": level, "line": line, "label": label,
            "start": not wanted, "stop": wanted, "follow": manual}
