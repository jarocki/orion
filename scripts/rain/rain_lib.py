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

import hashlib
import hmac
import json
import os
import shutil
import stat
import subprocess
import time
import uuid
import wave
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

# ---------------------------------------------------------------------------
# Category vocabulary (DEC-PHASE12-040)
#
# `category` used to be a free-form string: emit_event() did
# `str(category)[:64] or "general"` and the CLI had no `choices=`, while
# `--severity` right beside it was constrained. That one asymmetry is the root
# cause of a whole class of defect, because a *consumer* then decides what each
# category means and emitters never see that policy:
#
#   - pressure() excludes self-status categories from THREAT PRESSURE.
#   - scans-count.py counts detection categories.
#
# So every new emitter was a coin flip, and the coin kept landing wrong:
# postured published "my IDS has no rules" as `ids`, which drove the threat
# gauge to ELEVATED on an idle deck — the louder the deck said it was blind,
# the more the gauge said it was under attack. orionx-capture publishes
# `capture`, the healing engine `heal`, logquery `intel`; none is excluded, so
# a failed capture or a stale feed reads as hostile.
#
# THREAT is something happening TO the deck. STATUS is the deck describing
# ITSELF. The split is declared here, once, where emitters and consumers both
# see it. Rule 5 of docs/RESILIENCE.md: self-diagnosis is not a threat.
# ---------------------------------------------------------------------------

# Categories that describe a threat to the deck. These drive THREAT PRESSURE
# and the panel scan counter.
THREAT_CATEGORIES = ("ids", "scan", "recon", "probe", "alert", "forensics",
                     "deception", "malware", "mesh-intrusion")

# Categories describing the deck's own condition. Visible in the stream, still
# audible via R.A.I.N., deliberately NOT counted as threat.
STATUS_CATEGORIES = ("health", "posture", "service", "tooling", "heal",
                     "capture", "intel", "general")

CATEGORIES = THREAT_CATEGORIES + STATUS_CATEGORIES


def is_threat_category(category: str) -> bool:
    """True if this category represents a threat rather than self-status.

    Unknown categories count as threat, deliberately: a detector someone adds
    without updating this list should be noticed rather than silently ignored.
    Failing open here loses signal; failing closed would lose detections.
    """
    return str(category) not in STATUS_CATEGORIES


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
        # DEC-PHASE12-046: spoken, model-authored narration AFTER the tone.
        # Off by default — speech is intelligible to everyone in the room and a
        # tone is not, so narrating alert contents aloud is opt-in.
        # Toggle: orionx-rain --speech on|off   State: orionx-rain --speech-status
        "speech": False,
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
    cfg["speech"] = bool(cfg.get("speech", False))   # DEC-PHASE12-046
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
# ---------------------------------------------------------------------------
# Structured detail (DEC-PHASE12-029)
#
# The bus carried only a flat message string, so the Cockpit could say "port
# scan from 192.168.4.77" and nothing more — an operator could not see the
# signature that fired, the rule that triggered, or the matching content. Any
# drill-down needs that detail to exist on the bus in the first place.
#
# It must not arrive at the cost of the bus's integrity. Single-line appends to
# an O_APPEND fd are atomic only below PIPE_BUF (4096 on Linux), and there are
# now many concurrent emitters (scanwatch, postured, healing, nucleotide, the
# Control Center...). A fat detail payload would push a line over that limit
# and let two emitters interleave, corrupting the record precisely when it
# matters most. So detail is budgeted, and anything that does not fit spills to
# a sidecar file the event points at rather than being silently dropped.
# ---------------------------------------------------------------------------

DETAIL_DIR = Path("/run/orionx/details")

# Total serialized line budget. PIPE_BUF is 4096; leave generous headroom for
# the envelope and for multi-byte UTF-8 expanding past len() in characters.
LINE_BUDGET = 3072
_DETAIL_VALUE_MAX = 512


def _shrink_detail(detail: dict[str, Any], envelope_len: int) -> tuple[dict[str, Any], dict[str, Any]]:
    """Split detail into (inline, overflow) so the line stays under budget.

    Sheds in a deliberate order: oversized individual values first (a 40 KB
    packet hexdump is the usual culprit), then whole keys, longest first.
    Whatever is shed goes to the sidecar — never quietly discarded.
    """
    inline: dict[str, Any] = {}
    overflow: dict[str, Any] = {}
    for k, v in detail.items():
        if isinstance(v, str) and len(v) > _DETAIL_VALUE_MAX:
            overflow[k] = v
            inline[k] = v[:_DETAIL_VALUE_MAX - 1] + "\u2026"
        else:
            inline[k] = v
    # Still too big? Drop whole keys, longest serialization first.
    while inline and envelope_len + len(json.dumps(inline, ensure_ascii=False)) > LINE_BUDGET:
        worst = max(inline, key=lambda k: len(json.dumps({k: inline[k]}, ensure_ascii=False)))
        overflow.setdefault(worst, inline[worst])
        del inline[worst]
    return inline, overflow


def _write_sidecar(event_id: str, payload: dict[str, Any]) -> str | None:
    """Persist the full detail next to the bus. Returns a path, or None."""
    try:
        DETAIL_DIR.mkdir(parents=True, exist_ok=True)
        path = DETAIL_DIR / f"{event_id}.json"
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, path)          # atomic; a reader never sees a partial file
        return str(path)
    except OSError:
        return None


# --- Attestation: which bus lines a ROOT producer wrote --------------------
#
# @decision DEC-PHASE12-084
# @title Root producers sign their bus events; the healing daemon acts only on signed ones
# @status accepted
# @rationale QA round 1 (security F7). /run/orionx/events.jsonl is 0666 by
#   design: the Cockpit, the operator's `orionx-event` and every sensor write
#   it, and R.A.I.N. must hear all of them. But the `source` field is
#   self-asserted, and orionx-heald (root, CAP_NET_ADMIN/CAP_KILL) maps
#   source/category to block_ip, kill_process, isolate_node... Any local uid
#   could append {"source":"health","category":"compromise"} and, with
#   autonomy raised, isolate the deck.
#   Trust model, kept to one bus: a 32-byte key lives in a root-only file
#   (BUS_KEY, 0600 root, created by orionx-heald or any root emitter, never
#   by anyone else: a file not owned by root or with group/other bits is
#   REFUSED). emit_event() adds "auth" = HMAC-SHA256(key, canonical event)
#   when, and only when, it can read that key - i.e. when the writer is root
#   (postured, scanwatch, heald, `sudo orionx-event`). The engine verifies the
#   HMAC, a freshness window and a replay set before it will park or execute
#   anything; an unsigned, forged, stale or replayed event can at most become
#   a labelled SUGGESTION the operator may act on by hand. The bus stays the
#   single channel for see/hear/act; nothing else changes for its readers.
#   What this does not solve: a root producer faithfully reporting attacker-
#   controlled content (Suricata alerting on a spoofed source address can
#   still drive block_ip at that address). That is inherent to any IPS; the
#   never-lock-out guards, the default autonomy "off" and the rollback TTL
#   are the mitigations, and the User Guide must say so.
BUS_KEY = Path(os.environ.get("ORIONX_BUS_KEY", "/var/lib/orionx/bus.key"))
AUTH_FIELD = "auth"
_KEY_BYTES = 32
_key_cache: dict[str, bytes] = {}


def _canonical_event(event: dict[str, Any]) -> bytes:
    body = {k: v for k, v in event.items() if k != AUTH_FIELD}
    return json.dumps(body, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, default=str).encode("utf-8")


def read_bus_key(path: Path | str | None = None) -> tuple[bytes | None, str | None]:
    """(key, None) if the key file is one only root (or this uid) controls, else (None, why)."""
    p = Path(path) if path is not None else BUS_KEY
    try:
        fd = os.open(str(p), os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None, f"no attestation key at {p}"
    except OSError as exc:
        return None, f"cannot read attestation key {p}: {exc.strerror}"
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid not in (0, os.geteuid()):
            return None, f"attestation key {p} refused: not a regular file owned by root"
        if st.st_mode & 0o077:
            return None, f"attestation key {p} refused: mode {oct(st.st_mode & 0o777)} is not 0600"
        raw = os.read(fd, 256).strip()
    finally:
        os.close(fd)
    try:
        key = bytes.fromhex(raw.decode("ascii"))
    except (UnicodeDecodeError, ValueError):
        return None, f"attestation key {p} refused: not hex"
    if len(key) != _KEY_BYTES:
        return None, f"attestation key {p} refused: wrong length"
    return key, None


def ensure_bus_key(path: Path | str | None = None) -> tuple[bytes | None, str | None]:
    """Create the key if absent (O_EXCL: never overwrite, never follow a link),
    then read it back through the same checks every reader applies."""
    p = Path(path) if path is not None else BUS_KEY
    try:
        fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        pass
    except OSError as exc:
        return None, f"cannot create attestation key {p}: {exc.strerror}"
    else:
        try:
            os.write(fd, os.urandom(_KEY_BYTES).hex().encode("ascii") + b"\n")
        finally:
            os.close(fd)
    return read_bus_key(p)


def _signing_key() -> bytes | None:
    """The key, if this process may sign. Cached once found; retried until then."""
    k = str(BUS_KEY)
    if k in _key_cache:
        return _key_cache[k]
    key = None
    if os.geteuid() == 0:
        key, _why = ensure_bus_key(BUS_KEY)
    if key is None:
        key, _why = read_bus_key(BUS_KEY)
    if key is not None:
        _key_cache[k] = key
    return key


def sign_event(event: dict[str, Any], key: bytes) -> str:
    return hmac.new(key, _canonical_event(event), hashlib.sha256).hexdigest()


def verify_event(event: dict[str, Any], key: bytes | None) -> bool:
    tag = event.get(AUTH_FIELD) if isinstance(event, dict) else None
    if key is None or not isinstance(tag, str):
        return False
    return hmac.compare_digest(tag, sign_event(event, key))

def emit_event(severity: str, source: str, category: str, message: str,
               detail: dict[str, Any] | None = None) -> bool:
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

    # Structured detail, budgeted so the line stays atomically appendable.
    if isinstance(detail, dict) and detail:
        event["id"] = uuid.uuid4().hex[:16]
        envelope = len(json.dumps(event, ensure_ascii=False)) + len('"detail":,') + 2
        inline, overflow = _shrink_detail(detail, envelope)
        if overflow:
            ref = _write_sidecar(event["id"], detail)
            if ref:
                inline["_full"] = ref
            else:
                # Sidecar unavailable (read-only /run, no space). Say so in the
                # record rather than presenting a truncated detail as complete.
                inline["_truncated"] = True
        if inline:
            event["detail"] = inline

    key = _signing_key()               # DEC-PHASE12-084: root producers attest
    if key is not None:
        event[AUTH_FIELD] = sign_event(event, key)
    line = json.dumps(event, ensure_ascii=False) + "\n"
    if len(line.encode("utf-8")) > LINE_BUDGET + 512:
        # Last-resort guard: never risk a non-atomic append. Drop detail and
        # keep the event, because losing the alert is worse than losing detail.
        event.pop("detail", None)
        if key is not None:
            event[AUTH_FIELD] = sign_event(event, key)
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


# --- Reading the bus ----------------------------------------------------------

#: A partial line longer than this is not a line in progress, it is garbage
#: (the writer budget is LINE_BUDGET); it is dropped so memory stays bounded.
MAX_PARTIAL_BYTES = 64 * 1024


class BusTail:
    """The ONE incremental reader of the event bus (DEC-PHASE12-083).

    @decision DEC-PHASE12-083
    @title One bus reader: survives deletion/rotation/truncation, never drops a partial line
    @status accepted
    @rationale QA round 1 (python P1-4, P1-6). orionx-rain crashed with
      FileNotFoundError when the bus file was deleted (rotation path called
      open() outside any try) and, being an autostart rather than a unit with
      Restart=, stayed dead for the session. orionx-rain, orionx-heald and the
      Cockpit each parsed whatever readline() returned: a line read before its
      newline arrived failed JSON parsing and was skipped for good, so a
      critical event could be neither heard, acted on nor seen. This class
      reads bytes, keeps the unterminated tail in a buffer and only yields
      complete lines; a missing file is a normal state (poll again); an inode
      change or a shrink reopens from the top so a fresh bus is read in full.
      Readers that start at EOF (daemons must not re-act on history) still see
      every event written after the first successful open.

    poll() never raises. Lines are returned decoded; poll_events() parses them.
    """

    def __init__(self, path: Path | str | None = None, at_end: bool = True) -> None:
        self.path = Path(path) if path is not None else EVENT_LOG
        self._at_end = at_end          # only the FIRST open may skip history
        self._fh = None
        self._ino: int | None = None
        self._buf = b""
        self.reopens = 0
        self.dropped_partial = 0

    def _open(self) -> bool:
        try:
            fh = open(self.path, "rb")
        except OSError:
            return False
        try:
            st = os.fstat(fh.fileno())
            if self._at_end:
                fh.seek(0, os.SEEK_END)
        except OSError:
            fh.close()
            return False
        self._at_end = False           # any later (re)open reads a new file in full
        self._fh, self._ino, self._buf = fh, st.st_ino, b""
        return True

    def _close(self) -> None:
        if self._fh is not None:
            try:
                self._fh.close()
            except OSError:
                pass
        self._fh, self._ino, self._buf = None, None, b""

    def rewind(self) -> None:
        """Read from the start on the next poll (one-shot modes)."""
        self._close()
        self._at_end = False

    def _drain(self, max_bytes: int) -> list[str]:
        try:
            data = self._fh.read(max_bytes)
        except OSError:
            return []
        if not data:
            return []
        data = self._buf + data
        *lines, tail = data.split(b"\n")
        if len(tail) > MAX_PARTIAL_BYTES:
            self.dropped_partial += 1
            tail = b""
        self._buf = tail
        return [ln.decode("utf-8", errors="replace") for ln in lines if ln.strip()]

    def poll(self, max_bytes: int = 1 << 20) -> list[str]:
        """Complete new lines since the last poll ([] when there are none)."""
        if self._fh is None:
            if not self._open():
                # Not there yet: whatever it holds when it appears is new.
                self._at_end = False
                return []
            return self._drain(max_bytes)
        try:
            st = os.stat(self.path)
        except OSError:
            st = None
        if st is None or st.st_ino != self._ino:
            # Deleted or replaced: finish what the old file still holds, then
            # follow the new one (or wait for it) from its top.
            out = self._drain(max_bytes)
            self._close()
            self.reopens += 1
            if st is not None and self._open():
                out += self._drain(max_bytes)
            return out
        try:
            if st.st_size < self._fh.tell():
                self._fh.seek(0)       # truncated in place: start over
                self._buf = b""
                self.reopens += 1
        except OSError:
            self._close()
            return []
        return self._drain(max_bytes)

    def poll_events(self, max_bytes: int = 1 << 20) -> list[dict[str, Any]]:
        out = []
        for line in self.poll(max_bytes):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                out.append(obj)
        return out

    def close(self) -> None:
        self._close()

# --- Audio playback ---------------------------------------------------------
def _tone_path(severity: str) -> Path:
    return TONE_DIR / f"{normalize_severity(severity)}.wav"


# --- Music ducking (DEC-PHASE12-044) ----------------------------------------
# The optional generative music deck (scripts/music/) watches this file and
# goes silent for the number of seconds written here. Writing it BEFORE the
# cue starts is what makes the duck LEAD the sound rather than chase it down
# the event bus. Deliberately a plain file write and not an import: R.A.I.N.
# must never acquire a dependency on an accessory, and a failure here must
# cost nothing but a second of music.
MUSIC_DUCK_GATE = Path("/run/orionx/music-duck")


def _cue_airtime(sev: str, cfg: dict[str, Any]) -> float:
    """How long this cue will occupy the speaker, measured where possible."""
    total = 1.5
    try:
        with wave.open(str(_tone_path(sev)), "rb") as w:
            total = w.getnframes() / float(w.getframerate() or 22050) + 0.6
    except (OSError, wave.Error, ZeroDivisionError):
        pass
    if cfg.get("voice"):
        total += 2.5
    return total


def duck_music(seconds: float) -> None:
    """Ask the music deck for the room. Never raises; failure is acceptable."""
    try:
        data = f"{max(0.0, float(seconds)):.3f}\n".encode()
        fd = os.open(str(MUSIC_DUCK_GATE), os.O_WRONLY | os.O_CREAT, 0o666)
        try:
            # Write before truncating, so a reader catching us mid-write sees
            # stale-or-garbage (which ducks) and never an empty file (which
            # does not). The unsafe direction is the one to avoid.
            os.lseek(fd, 0, os.SEEK_SET)
            written = os.write(fd, data)
            os.ftruncate(fd, written)
        finally:
            os.close(fd)
    except (OSError, TypeError, ValueError):
        pass


def play_cue(severity: str, cfg: dict[str, Any] | None = None) -> bool:
    """Play the cue for a severity. Degrades gracefully; never raises.

    Order: pulseaudio (paplay, honours --volume) -> alsa (aplay). If neither is
    present, or there is no audio device, we simply return False — a headless or
    muted box must not error. When cfg['voice'] is set, an espeak-ng phrase is
    spoken in addition to the tone.
    """
    cfg = cfg or default_config()
    sev = normalize_severity(severity)
    # Clear the room before making a sound, not after (DEC-PHASE12-044).
    duck_music(_cue_airtime(sev, cfg))
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
