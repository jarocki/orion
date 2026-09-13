#!/usr/bin/env python3
"""rain_lib — shared library for R.A.I.N. (Real-time Audible Intrusion Notification).

R.A.I.N. gives the operator's "3am self" an EARS-not-eyes channel: detection and
auto-healing events are turned into distinct, severity-mapped audio cues so an
intrusion is heard without watching the screen (issue #88).

This module is the single authority for three things every R.A.I.N. piece shares:

  1. THE EVENT BUS — an append-only JSONL spool at /run/orionx/events.jsonl.
     It is the integration point the whole detection stack plugs into: the
     Control Center health monitor + threat-posture changes emit here now; the
     W10-5 Suricata detection daemon, auto-healing engine (W10-6), and the
     roadmap sensors (nucleotide #89, pivotglass #90, go-roast #91, selfedge #92)
     all emit here later. One writer convention, one reader (orionx-rain).

  2. SEVERITY MODEL — info < notice < warning < critical, with a stable rank so
     the daemon and the Control Center agree on ordering and thresholds.

  3. CONFIG — ~/.config/orionx/rain.json, the user-writable authority the Control
     Center Awareness panel writes and the daemon reads live.

@decision DEC-PHASE11-045
@title R.A.I.N. event bus + audible alert daemon (roadmap #88)
@status accepted
@rationale The roadmap tools (#88-92) and the W10-5 detection daemon all need a
  common place to publish events; RAIN needs a common place to consume them.
  Rather than couple RAIN to any one detector, define /run/orionx/events.jsonl as
  the single event authority (JSONL on tmpfs — ephemeral by design on a live
  forensic appliance) and make RAIN its first consumer. Emitters call the
  `orionx-event` CLI (or emit_event() in-process); the daemon tails the spool and
  maps severity -> a bundled WAV cue, throttled so an event storm cannot become
  an audio storm. Audio degrades gracefully (paplay -> aplay -> silent) so a box
  with no sound device never errors.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

# --- Event bus (single authority) -------------------------------------------
# tmpfs path created 0755 by tmpfiles.d (DEC-PHASE11-022); the spool file itself
# is created world-writable (0666) so both root detectors and the desktop user
# can append on this single-operator appliance. Ephemeral across reboots — RAIN
# is a live-alert channel, not a forensic log (those go to /var/log/orionx).
EVENT_LOG = Path("/run/orionx/events.jsonl")

# --- Severity model ---------------------------------------------------------
SEVERITIES = ("info", "notice", "warning", "critical")
_RANK = {name: i for i, name in enumerate(SEVERITIES)}


def severity_rank(sev: str) -> int:
    """Rank of a severity (higher = more urgent); unknown -> -1."""
    return _RANK.get(str(sev).lower().strip(), -1)


def normalize_severity(sev: str) -> str:
    """Coerce arbitrary input to a known severity, defaulting to 'notice'."""
    s = str(sev).lower().strip()
    return s if s in _RANK else "notice"


# --- Config (user authority) ------------------------------------------------
CONFIG_FILE = Path.home() / ".config" / "orionx" / "rain.json"

# Where the build stages the severity tones (see includes.chroot).
TONE_DIR = Path("/usr/share/orionx/rain")

# Short phrases for the optional espeak-ng voice channel (off by default).
VOICE_PHRASES = {
    "info": "Notice.",
    "notice": "Heads up.",
    "warning": "Warning. Suspicious activity.",
    "critical": "Critical. Intrusion detected.",
}

# Per-severity minimum seconds between cues, so an event storm is not an audio
# storm. Higher severities are allowed to repeat sooner.
COOLDOWN_SECONDS = {
    "info": 30.0,
    "notice": 15.0,
    "warning": 8.0,
    "critical": 3.0,
}

# Never play two cues closer together than this, regardless of severity.
GLOBAL_MIN_GAP_SECONDS = 1.5


def default_config() -> dict[str, Any]:
    """The shipped defaults: on, but only warning+ is audible by default."""
    return {
        "enabled": True,
        "min_severity": "warning",
        "volume": 0.8,          # 0.0 - 1.0
        "voice": False,         # espeak-ng voice cue in addition to the tone
    }


def load_config() -> dict[str, Any]:
    """Load rain.json merged over defaults; tolerant of a missing/corrupt file."""
    cfg = default_config()
    try:
        with CONFIG_FILE.open(encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            cfg.update({k: data[k] for k in cfg if k in data})
    except (OSError, ValueError):
        pass
    # Clamp / sanitize. A corrupt/unknown min_severity falls back to the shipped
    # default ("warning"), NOT normalize_severity's "notice" — never make a broken
    # config quietly noisier than the default.
    ms = str(cfg.get("min_severity", "warning")).lower().strip()
    cfg["min_severity"] = ms if ms in _RANK else "warning"
    try:
        cfg["volume"] = max(0.0, min(1.0, float(cfg.get("volume", 0.8))))
    except (TypeError, ValueError):
        cfg["volume"] = 0.8
    cfg["enabled"] = bool(cfg.get("enabled", True))
    cfg["voice"] = bool(cfg.get("voice", False))
    return cfg


def save_config(cfg: dict[str, Any]) -> bool:
    """Persist rain.json (creating ~/.config/orionx). Returns success."""
    try:
        CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = CONFIG_FILE.with_suffix(".json.tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2, sort_keys=True)
        tmp.replace(CONFIG_FILE)
        return True
    except OSError:
        return False


# --- Emission ---------------------------------------------------------------
def emit_event(severity: str, source: str, category: str, message: str) -> bool:
    """Append one event to the bus. Safe to call from anywhere; never raises.

    Emitters that cannot import this module (e.g. the Control Center, which is
    held to a strict import allowlist) shell out to the `orionx-event` CLI, which
    is a thin wrapper over this function.
    """
    event = {
        "ts": time.time(),
        "iso": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
        "severity": normalize_severity(severity),
        "source": str(source)[:64] or "unknown",
        "category": str(category)[:64] or "general",
        "message": str(message)[:512],
    }
    line = json.dumps(event, ensure_ascii=False) + "\n"
    try:
        # O_APPEND makes concurrent single-line appends atomic (< PIPE_BUF),
        # so multiple emitters never interleave a line.
        fd = os.open(str(EVENT_LOG), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o666)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
        return True
    except OSError:
        return False


# --- Audio playback ---------------------------------------------------------
def _tone_path(severity: str) -> Path:
    return TONE_DIR / f"{normalize_severity(severity)}.wav"


def play_cue(severity: str, cfg: dict[str, Any] | None = None) -> bool:
    """Play the cue for a severity. Degrades gracefully; never raises.

    Order: pulseaudio (paplay, honours --volume) -> alsa (aplay). If neither is
    present, or there is no audio device, we simply return False — a headless or
    muted box must not error. When cfg['voice'] is set, an espeak-ng phrase is
    spoken in addition to the tone.
    """
    cfg = cfg or default_config()
    sev = normalize_severity(severity)
    tone = _tone_path(sev)
    played = False

    if tone.is_file():
        vol = max(0.0, min(1.0, float(cfg.get("volume", 0.8))))
        if shutil.which("paplay"):
            # paplay --volume is 0..65536 (0x10000 == 100%).
            pa_vol = str(int(vol * 65536))
            played = _run(["paplay", f"--volume={pa_vol}", str(tone)])
        if not played and shutil.which("aplay"):
            # aplay has no software volume; relies on the mixer level.
            played = _run(["aplay", "-q", str(tone)])

    if cfg.get("voice") and shutil.which("espeak-ng"):
        phrase = VOICE_PHRASES.get(sev, "Alert.")
        amp = str(int(max(0.0, min(1.0, float(cfg.get("volume", 0.8)))) * 200))
        _run(["espeak-ng", "-a", amp, phrase])

    return played


def _run(cmd: list[str]) -> bool:
    """Run an audio command, swallowing failure (no device, missing bin, etc.)."""
    try:
        subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=10,
        )
        return True
    except (OSError, subprocess.SubprocessError):
        return False
