#!/usr/bin/env python3
"""orionx_synth — generative techno for the Orion-X deck, and the safety gate
that keeps it from ever masking a R.A.I.N. alert.

@decision DEC-PHASE12-044
@title Generative techno bed + graphical DJ deck, gated by the R.A.I.N. bus
@status accepted
@rationale An operator asked for an optional music track in the spirit of
  Pivotglass's procedural soundtrack (scripts/pivotglass/.../core/music.py).
  Three things follow from where it has to live:

  1. GENERATIVE, NOT SHIPPED. Pivotglass renders an original score with nothing
     but the Python standard library and hands the WAV to an already-installed
     player. Same here: no audio asset is shipped, so there is no licensing
     question, no megabytes added to a 2.9 GiB image that is already past
     GitHub's asset cap, and the music can respond to deck state. The ISO cost
     is the source text and nothing else; no new apt package is pulled in
     (pulseaudio-utils/alsa-utils are already installed for R.A.I.N., and
     python3-gi/gir1.2-gtk-3.0 for the Control Center).

  2. R.A.I.N. OUTRANKS IT, ALWAYS. R.A.I.N. is Real-time Audible Intrusion
     Notification: on this deck the speaker is a safety surface, not a feature.
     Stadium techno over a `critical` cue is worse than no music at all. So the
     music is not merely "polite"; it is structurally subordinate. Playback is
     multiplied by AlertGuard.music_gain(), which is 0.0 whenever a cue is in
     flight AND 0.0 whenever the guard itself cannot prove it is watching.
     The engine has no path to sound that does not pass through that gate.

  3. STREAMED, NOT FILE-LOOPED. Pivotglass renders a whole movement to a WAV
     and hands it to `aplay`. Once that process owns the file there is no way
     to turn it down for 900 ms, which is exactly what ducking needs. Orion-X
     therefore synthesizes into small blocks and streams raw PCM to the
     player's stdin, so the duck lands inside one block (~46 ms) and every
     deck knob applies to the next block instead of needing a restart.

  Synthesis is a "sampler whose samples are synthesized at boot": each voice
  (kick, hats, clap, acid bass, stab) is rendered once into a small int buffer
  when a tone control moves, and the real-time path is integer adds plus one
  scalar gain pass. Measured: 108x realtime, 0.92% of one core on the dev
  host, with every voice sounding on every frame (far above the real duty
  cycle). That is what makes a pure-stdlib, numpy-free, dependency-free
  real-time synth honest on a cyberdeck rather than aspirational.

  Music defaults to OFF and there is no unit that starts it (see
  0702-orionx-music.hook.chroot: no systemd unit is installed at all). It is an
  operator action, every time.
"""

from __future__ import annotations

import json
import math
import os
import random
import struct
import time
import wave
from array import array
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

SAMPLE_RATE = 22_050
BLOCK_FRAMES = 1024                 # ~46 ms at 22.05 kHz: the duck's worst-case latency

# --- Paths ------------------------------------------------------------------
# The R.A.I.N. bus. rain_lib.EVENT_LOG is the authority; this mirrors it only
# as a fallback for when rain_lib cannot be imported at all.
EVENT_LOG = Path("/run/orionx/events.jsonl")
TONE_DIR = Path("/usr/share/orionx/rain")

# The duck gate. ANY process may ask the music to get out of the way by writing
# a duration in seconds here; the guard consumes it and ducks for that long.
# This is the hook R.A.I.N.'s play_cue() should write (see the WIRING note in
# docs and the report) so the duck LEADS the cue instead of chasing it.
DUCK_GATE = Path("/run/orionx/music-duck")

CONFIG_FILE = Path.home() / ".config" / "orionx" / "music.json"

# ---------------------------------------------------------------------------
# THE FLOOR IS A CONSTANT, NOT A SETTING.
#
# There is deliberately no config key, slider or CLI flag that raises this.
# "Duck to 20%" is a mixing decision; on a deck whose speaker is an intrusion
# alarm it is a safety decision, and safety decisions do not get a knob. A cue
# plays into silence.
# ---------------------------------------------------------------------------
DUCK_FLOOR = 0.0

DUCK_ATTACK_SECONDS = 0.012     # how fast the music gets out of the way
DUCK_RELEASE_SECONDS = 1.1      # slow return, so it does not pump between cues
DUCK_TAIL_SECONDS = 0.6         # hold past the end of the cue's own audio
DUCK_FALLBACK_SECONDS = 2.0     # if a cue WAV cannot be measured
DUCK_VOICE_SECONDS = 2.2        # extra hold when R.A.I.N.'s espeak voice is on
# R.A.I.N. gained spoken narration in DEC-PHASE12-046: a model-authored sentence
# played AFTER the tone, of a length nothing here can predict. A measured WAV
# length is therefore no longer the whole truth about how long the speaker is
# busy. Until play_cue()/the narrator writes the duck gate itself (see
# request_duck() and the WIRING note), a generous blanket hold is the only
# honest option: over-ducking costs music, under-ducking costs the alert.
DUCK_SPEECH_SECONDS = 15.0

GUARD_STALE_SECONDS = 2.0       # a guard that has not polled this recently is dead


# --- Deck state -------------------------------------------------------------
PATTERNS = ("driver", "rolling", "dub", "acid")


@dataclass
class DeckState:
    """Everything the DJ deck can change. Plain data, so it is testable and so
    the deck, the CLI and the config file all describe the same thing once."""

    enabled: bool = False       # OFF BY DEFAULT — nothing starts this but an operator
    bpm: float = 128.0          # 90 .. 160
    cutoff: float = 0.55        # 0..1 -> 180 Hz .. 9 kHz lowpass on the tonal voices
    resonance: float = 0.45     # 0..1 -> filter Q (the "acid" knob)
    density: float = 0.50       # 0..1 -> how many optional 16ths fire
    intensity: float = 0.50     # 0..1 -> voice count, accents, stabs
    volume: float = 0.55        # 0..1 master
    pattern: str = "driver"
    seed: int = 1312
    follow_posture: bool = False  # let the threat tier drive intensity

    def clamp(self) -> DeckState:
        """Coerce into range. A corrupt config must never produce a loud deck."""
        self.enabled = bool(self.enabled)
        self.bpm = _clamp(_number(self.bpm, 128.0), 90.0, 160.0)
        self.cutoff = _clamp(_number(self.cutoff, 0.55), 0.0, 1.0)
        self.resonance = _clamp(_number(self.resonance, 0.45), 0.0, 1.0)
        self.density = _clamp(_number(self.density, 0.50), 0.0, 1.0)
        self.intensity = _clamp(_number(self.intensity, 0.50), 0.0, 1.0)
        self.volume = _clamp(_number(self.volume, 0.55), 0.0, 1.0)
        self.pattern = self.pattern if self.pattern in PATTERNS else "driver"
        try:
            self.seed = int(self.seed) & 0x7FFFFFFF
        except (TypeError, ValueError):
            self.seed = 1312
        self.follow_posture = bool(self.follow_posture)
        return self

    def tone_key(self) -> tuple[Any, ...]:
        """Identity of the synthesized voice bank. Only these change the bank;
        bpm/density/intensity/volume are free, so most knobs never re-render."""
        return (round(self.cutoff, 3), round(self.resonance, 3), self.seed)


def _number(value: Any, fallback: float) -> float:
    try:
        f = float(value)
    except (TypeError, ValueError):
        return fallback
    return fallback if math.isnan(f) or math.isinf(f) else f


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def default_config() -> dict[str, Any]:
    return asdict(DeckState())


def load_config(path: Path | None = None) -> DeckState:
    """Load music.json over the defaults. Tolerant of missing/corrupt files."""
    path = CONFIG_FILE if path is None else path
    data: dict[str, Any] = {}
    try:
        with path.open(encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict):
            data = loaded
    except (OSError, ValueError):
        pass
    state = DeckState()
    for key in asdict(state):
        if key in data:
            setattr(state, key, data[key])
    return state.clamp()


def save_config(state: DeckState, path: Path | None = None) -> bool:
    path = CONFIG_FILE if path is None else path
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".json.tmp")
        with tmp.open("w", encoding="utf-8") as fh:
            json.dump(asdict(state), fh, indent=2, sort_keys=True)
        tmp.replace(path)
        return True
    except OSError:
        return False


# ---------------------------------------------------------------------------
# Ducking
# ---------------------------------------------------------------------------
class DuckController:
    """A monotonic-clock gain envelope that takes the music to DUCK_FLOOR.

    Deliberately monotonic-only: the bus carries wall-clock `ts` and the gate
    file could carry anything, so nothing outside this class is allowed to
    supply an absolute deadline. A caller says "duck for N seconds"; the window
    is measured from the moment this object observes it. A wall-clock jump
    therefore cannot end a duck early, which is the direction that matters.
    """

    def __init__(self) -> None:
        self._start: float | None = None   # when the current duck began
        self._hold_until: float = 0.0      # end of the full-floor hold

    def duck(self, now: float, seconds: float) -> None:
        """Request silence for `seconds` from now. Extends an active duck."""
        seconds = max(0.0, _number(seconds, DUCK_FALLBACK_SECONDS))
        end = now + seconds
        if self._start is None or now > self._hold_until + DUCK_RELEASE_SECONDS:
            self._start = now          # fresh duck: ramp down from here
        self._hold_until = max(self._hold_until, end)

    def release(self) -> None:
        self._start = None
        self._hold_until = 0.0

    def active(self, now: float) -> bool:
        """True while the music is at all attenuated (including the release)."""
        return self.gain_at(now) < 1.0

    def holding(self, now: float) -> bool:
        """True from the instant the duck begins until the release starts.

        Distinct from `active()`, which stays true through the slow ramp back.
        The player uses this to decide when to hand the sound card back: it has
        to let go at the FIRST sample of the duck (not when the 12 ms ramp has
        finished, a whole audio block later) and reclaim it as soon as the
        release begins.
        """
        start = self._start
        return start is not None and start <= now < self._hold_until

    def gain_at(self, now: float) -> float:
        """Multiplier in [DUCK_FLOOR, 1.0]. 1.0 only when fully recovered."""
        start = self._start
        if start is None or now >= self._hold_until + DUCK_RELEASE_SECONDS:
            return 1.0
        if now < start:
            return 1.0
        if now < start + DUCK_ATTACK_SECONDS:
            # Linear dive to the floor. Fast enough that a cue's first
            # transient is never competing with a kick drum.
            frac = (now - start) / DUCK_ATTACK_SECONDS
            return 1.0 - frac * (1.0 - DUCK_FLOOR)
        if now < self._hold_until:
            return DUCK_FLOOR
        frac = (now - self._hold_until) / DUCK_RELEASE_SECONDS
        return DUCK_FLOOR + frac * (1.0 - DUCK_FLOOR)


def cue_duration(severity: str, tone_dir: Path = TONE_DIR) -> float:
    """How long R.A.I.N.'s WAV cue for this severity actually plays.

    Measured from the file, not guessed: the cues differ by 4x in length
    (info.wav 5.8 KB vs critical.wav 27 KB) and a fixed guess would either
    un-duck during a critical cue or hold silence for seconds after an info.
    """
    try:
        with wave.open(str(tone_dir / f"{severity}.wav"), "rb") as wav:
            rate = wav.getframerate() or SAMPLE_RATE
            return wav.getnframes() / float(rate)
    except (OSError, wave.Error, ZeroDivisionError):
        return DUCK_FALLBACK_SECONDS


class AlertGuard:
    """The single authority for 'may the music be heard right now, and how loud'.

    It is both the ducking trigger and the liveness interlock. Two obligations:

      WATCH   — poll the R.A.I.N. event bus and the duck gate, and duck for any
                event that R.A.I.N. will turn into an audible cue.
      PROVE   — report whether it is in fact watching. The engine multiplies
                every sample by music_gain(), which returns 0.0 when this guard
                has not polled within GUARD_STALE_SECONDS. Music cannot outlive
                its own watchdog: if the polling thread dies, wedges, or was
                never started, the deck goes silent rather than deaf.

    Rule 8 of docs/RESILIENCE.md: degraded states are enumerated in
    degradations(), each naming the consequence and the exact remedy.
    """

    # Sentinel: rain_lib="auto" means "find it"; rain_lib=None means
    # "there genuinely isn't one", which is a state the tests must be able to
    # construct deliberately rather than by hoping the import fails.
    AUTO = "auto"

    def __init__(self, event_log: Path | None = None, gate: Path | None = None,
                 tone_dir: Path | None = None, rain_lib: Any = AUTO,
                 clock: Any = time.monotonic) -> None:
        self.event_log = EVENT_LOG if event_log is None else Path(event_log)
        self.gate = DUCK_GATE if gate is None else Path(gate)
        self.tone_dir = TONE_DIR if tone_dir is None else Path(tone_dir)
        self.clock = clock
        self.duck = DuckController()

        self._rain = _import_rain_lib() if rain_lib == self.AUTO else rain_lib
        self._rain_cfg: dict[str, Any] = {}
        self._rain_cfg_at = -1e9
        self._offset = 0
        self._inode: tuple[int, int] | None = None
        self._gate_stamp: tuple[int, int] | None = None
        self._last_poll: float | None = None
        self._bus_error: str = ""
        self._cue_count = 0
        self._primed = False

    # -- liveness ----------------------------------------------------------
    def started(self) -> bool:
        return self._last_poll is not None

    def is_healthy(self, now: float | None = None) -> bool:
        """Has this guard proved, recently, that it is still watching?"""
        if self._last_poll is None:
            return False
        now = self.clock() if now is None else now
        return (now - self._last_poll) <= GUARD_STALE_SECONDS

    def music_gain(self, now: float | None = None) -> float:
        """The only path from the synth to a loudspeaker.

        0.0 if a cue is in flight. 0.0 if this guard is not demonstrably alive.
        Fail-closed in both directions: the failure mode of a safety interlock
        has to be silence, never 'probably fine'.
        """
        now = self.clock() if now is None else now
        if not self.is_healthy(now):
            return 0.0
        return self.duck.gain_at(now)

    def cues_seen(self) -> int:
        return self._cue_count

    # -- watching ----------------------------------------------------------
    def poll(self, now: float | None = None) -> int:
        """One watch cycle. Returns how many ducks it triggered. Never raises.

        Check in FIRST: a poll that raised halfway through still proves the
        thread is alive, and marking liveness only on the happy path would mute
        the deck every time /run/orionx is briefly unreadable.
        """
        now = self.clock() if now is None else now
        self._last_poll = now
        ducks = 0
        try:
            ducks += self._poll_gate(now)
        except OSError:
            pass
        try:
            ducks += self._poll_bus(now)
        except OSError as exc:
            self._bus_error = str(exc)
        return ducks

    def _poll_gate(self, now: float) -> int:
        """Consume the duck gate. Its content is a duration in seconds.

        The gate is pre-created 0666 by tmpfiles.d so any uid can arm it, and
        is therefore DISARMED BY TRUNCATION rather than by unlink — deleting it
        would take the file's permissions with it and leave the next non-root
        process unable to recreate it under a 0755 /run/orionx.

        An empty gate means "not armed", which is the state tmpfiles.d leaves
        it in at boot. Unparseable content means "armed, duration unknown" and
        ducks for the fallback: a corrupt gate must not be read as silence.
        """
        try:
            st = self.gate.stat()
        except OSError:
            self._gate_stamp = None
            return 0
        stamp = (st.st_mtime_ns, st.st_size)
        if stamp == self._gate_stamp:
            return 0                      # already consumed this write
        self._gate_stamp = stamp
        try:
            raw = self.gate.read_text(encoding="utf-8").strip()
        except OSError:
            raw = ""
        if not raw:
            return 0                      # pre-created but not armed
        seconds = _number(raw, DUCK_FALLBACK_SECONDS)
        if seconds <= 0.0:
            return 0
        self.duck.duck(now, min(seconds, 60.0))
        self._cue_count += 1
        try:
            with self.gate.open("r+", encoding="utf-8") as fh:
                fh.truncate(0)            # disarm, keep the file and its mode
            self._gate_stamp = (self.gate.stat().st_mtime_ns, 0)
        except OSError:
            pass                          # not ours to write; the stamp still guards
        return 1

    def _poll_bus(self, now: float) -> int:
        """Tail the R.A.I.N. bus and duck for anything that will become a cue."""
        try:
            st = self.event_log.stat()
        except FileNotFoundError:
            # No bus yet is normal on a fresh boot and is not a degradation:
            # if the spool does not exist, R.A.I.N. has nothing to play either.
            self._inode = None
            self._offset = 0
            return 0
        ident = (st.st_dev, st.st_ino)
        if ident != self._inode:
            self._inode = ident
            # First sight of this spool: skip the backlog. Ducking for an hour
            # of history the operator already heard would be absurd.
            self._offset = st.st_size if not self._primed else 0
            self._primed = True
            return 0
        if st.st_size < self._offset:
            self._offset = 0              # truncated under us
        if st.st_size == self._offset:
            return 0

        with self.event_log.open("rb") as fh:
            fh.seek(self._offset)
            chunk = fh.read(st.st_size - self._offset)
        # Only consume whole lines; a partial append is re-read next poll.
        cut = chunk.rfind(b"\n")
        if cut < 0:
            return 0
        self._offset += cut + 1
        self._bus_error = ""

        ducks = 0
        longest = 0.0
        for line in chunk[:cut].split(b"\n"):
            if not line.strip():
                continue
            severity = self._severity_of(line)
            if severity is None or not self._will_play_cue(severity, now):
                continue
            longest = max(longest, self._duck_seconds(severity, now))
            ducks += 1
        if ducks:
            self.duck.duck(now, longest)
            self._cue_count += ducks
        return ducks

    @staticmethod
    def _severity_of(line: bytes) -> str | None:
        try:
            event = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            return None
        if not isinstance(event, dict):
            return None
        sev = event.get("severity")
        return str(sev) if sev is not None else None

    def _rain_config(self, now: float) -> dict[str, Any]:
        """R.A.I.N.'s live config, re-read at most every 2s (it is user-editable)."""
        if self._rain is None:
            return {}
        if now - self._rain_cfg_at < 2.0:
            return self._rain_cfg
        self._rain_cfg_at = now
        try:
            self._rain_cfg = dict(self._rain.load_config())
        except Exception:                                   # noqa: BLE001
            self._rain_cfg = {}
        return self._rain_cfg

    def _will_play_cue(self, severity: str, now: float) -> bool:
        """Will R.A.I.N. make a sound for this event?

        rain_lib owns the severity model and the threshold; we ask it rather
        than copying its table (rule 7: one authority per fact). If we cannot
        ask — rain_lib missing, config unreadable — we assume YES. Ducking for
        an event that turns out to be silent costs a second of music. Not
        ducking for one that turns out to be audible is the failure this whole
        module exists to prevent.
        """
        rain = self._rain
        if rain is None:
            return True
        cfg = self._rain_config(now)
        if not cfg:
            return True
        if not cfg.get("enabled", True):
            return False
        try:
            return rain.severity_rank(severity) >= rain.severity_rank(cfg.get("min_severity", "warning"))
        except Exception:                                   # noqa: BLE001
            return True

    def _duck_seconds(self, severity: str, now: float) -> float:
        sev = severity
        if self._rain is not None:
            try:
                sev = self._rain.normalize_severity(severity)
            except Exception:                               # noqa: BLE001
                sev = severity
        cfg = self._rain_config(now)
        total = cue_duration(sev, self.tone_dir) + DUCK_TAIL_SECONDS
        if cfg.get("voice"):
            total += DUCK_VOICE_SECONDS
        if cfg.get("speech"):
            total += DUCK_SPEECH_SECONDS
        return total

    # -- rule 8 ------------------------------------------------------------
    def degradations(self) -> list[dict[str, str]]:
        """Every way this guard is currently less than it claims to be."""
        out: list[dict[str, str]] = []
        if self._rain is None:
            out.append({
                "what": "rain_lib.py could not be imported",
                "consequence": "the alert threshold is unknown, so the music "
                               "ducks for EVERY bus event, including info",
                "remedy": "ls -l /opt/orionx/scripts/rain/rain_lib.py",
            })
        if not self.is_healthy():
            out.append({
                "what": "the alert guard has not polled within "
                        f"{GUARD_STALE_SECONDS:.0f}s",
                "consequence": "music is forced to silence — it is not allowed "
                               "to play while nothing is watching for alerts",
                "remedy": "restart the deck: orionx-dj   (or: orionx-music play)",
            })
        if self._bus_error:
            out.append({
                "what": f"the R.A.I.N. bus could not be read ({self._bus_error})",
                "consequence": "cues may fire without the music getting out of the way",
                "remedy": f"ls -l {self.event_log}; systemctl status orionx-rain",
            })
        if not self.tone_dir.is_dir():
            out.append({
                "what": f"{self.tone_dir} is missing",
                "consequence": "cue length cannot be measured; ducks fall back "
                               f"to a flat {DUCK_FALLBACK_SECONDS:.0f}s",
                "remedy": f"ls -l {self.tone_dir}",
            })
        return out


def _import_rain_lib() -> Any:
    """Import rain_lib from wherever it lives, without copying any of it.

    Tried in order: already importable; the installed path on the deck; the
    repo layout next to this file. Returns None rather than raising — the
    caller treats None as 'assume every event is audible'.
    """
    try:
        import rain_lib                                     # type: ignore
        return rain_lib
    except ImportError:
        pass
    here = Path(__file__).resolve().parent
    for candidate in (Path("/opt/orionx/scripts/rain/rain_lib.py"),
                      here.parent / "rain" / "rain_lib.py"):
        try:
            if not candidate.is_file():
                continue
            from importlib.util import module_from_spec, spec_from_file_location
            spec = spec_from_file_location("orionx_rain_lib", candidate)
            if spec is None or spec.loader is None:
                continue
            module = module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        except Exception:                                   # noqa: BLE001
            continue
    return None


def request_duck(seconds: float = DUCK_FALLBACK_SECONDS, gate: Path | None = None) -> bool:
    """Ask any running Orion-X music engine to get out of the way.

    This is the whole interface. R.A.I.N.'s play_cue() should call it (or write
    the file itself — two lines, no import) immediately BEFORE it starts a cue,
    so the duck leads the sound instead of chasing it down the bus.
    """
    gate = DUCK_GATE if gate is None else Path(gate)
    data = f"{max(0.0, float(seconds)):.3f}\n".encode()
    try:
        gate.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(gate), os.O_WRONLY | os.O_CREAT, 0o666)
        try:
            # Write BEFORE truncating, so a reader polling at exactly the wrong
            # moment sees stale-or-garbage (which ducks) and never sees an empty
            # file (which does not). The unsafe direction is the one to avoid.
            os.lseek(fd, 0, os.SEEK_SET)
            written = os.write(fd, data)
            os.ftruncate(fd, written)
        finally:
            os.close(fd)
        try:
            os.chmod(gate, 0o666)       # any uid may duck the music
        except OSError:
            pass                        # pre-created by tmpfiles.d; already 0666
        return True
    except (OSError, TypeError, ValueError):
        return False


# ---------------------------------------------------------------------------
# Voice synthesis
#
# Every voice is rendered ONCE into a small integer buffer whenever a tone
# control moves, and the real-time path then only adds those buffers together.
# That is what keeps a pure-stdlib synth inside a fraction of a core: the
# expensive maths (oscillators, the resonant filter, envelopes) happens at
# human rate, not at 22 050 Hz.
# ---------------------------------------------------------------------------
_SCALE = (0, 3, 5, 7, 10)          # minor pentatonic — the acid-techno default
_ROOT_HZ = 55.0                    # A1
_BASS_NOTES = 10                   # two octaves of the scale
_STAB_NOTES = 3
_PEAK = 9000                       # per-voice peak before the master gain


def _rng(*parts: Any) -> random.Random:
    """Deterministic RNG. Same deck state always renders the same bank."""
    return random.Random("|".join(str(p) for p in parts))


def _cutoff_hz(cutoff: float) -> float:
    """Knob 0..1 -> 180 Hz .. 9 kHz, exponentially (how hearing works)."""
    return 180.0 * (9000.0 / 180.0) ** _clamp(cutoff, 0.0, 1.0)


def _svf_lowpass(samples: list[float], cutoff_hz: float, q: float,
                 sr: int = SAMPLE_RATE) -> list[float]:
    """Chamberlin state-variable lowpass — the resonant sweep the deck exposes."""
    f = 2.0 * math.sin(math.pi * min(cutoff_hz, sr * 0.45) / sr)
    damp = min(1.0 / max(q, 0.5), 2.0 - f)      # clamped for stability
    low = band = 0.0
    out: list[float] = []
    for x in samples:
        notch = x - damp * band
        low += f * band
        high = notch - low
        band += f * high
        out.append(low)
    return out


def _saw(phase: float) -> float:
    return 2.0 * (phase - math.floor(phase + 0.5))


def _to_buffer(samples: list[float], peak: int = _PEAK) -> array:
    """Normalize to a fixed peak and freeze as int16-range integers."""
    high = max((abs(s) for s in samples), default=0.0)
    if high <= 1e-9:
        return array("i", [0]) * len(samples)
    scale = peak / high
    return array("i", [int(s * scale) for s in samples])


def _kick(sr: int = SAMPLE_RATE) -> array:
    n = int(0.26 * sr)
    out: list[float] = []
    phase = 0.0
    for i in range(n):
        t = i / sr
        freq = 48.0 + 110.0 * math.exp(-t / 0.022)       # the classic pitch drop
        phase += 2.0 * math.pi * freq / sr
        body = math.sin(phase) * math.exp(-t / 0.115)
        click = math.exp(-t / 0.0018) * 0.5
        out.append(math.tanh((body + click) * 1.7))
    return _to_buffer(out, int(_PEAK * 1.25))


def _hat(seed: int, decay: float, seconds: float, sr: int = SAMPLE_RATE) -> array:
    """Inharmonic partial cluster — a metallic hat with no shipped sample."""
    rng = _rng("hat", seed, decay)
    ratios = [7.3, 11.7, 14.1, 17.13, 23.71, 31.37]
    phases = [rng.random() * 6.283 for _ in ratios]
    base = 940.0
    n = int(seconds * sr)
    out: list[float] = []
    for i in range(n):
        t = i / sr
        s = sum(math.sin(2.0 * math.pi * base * r * t + p)
                for r, p in zip(ratios, phases)) / len(ratios)
        out.append(s * math.exp(-t / decay))
    return _to_buffer(out, int(_PEAK * 0.45))


def _clap(seed: int, sr: int = SAMPLE_RATE) -> array:
    """Three deterministic noise bursts plus a tail — a 909-shaped clap."""
    rng = _rng("clap", seed)
    n = int(0.24 * sr)
    noise = [rng.uniform(-1.0, 1.0) for _ in range(n)]
    shaped = _svf_lowpass(noise, 2600.0, 1.6, sr)
    out: list[float] = []
    bursts = (0.0, 0.009, 0.019)
    for i in range(n):
        t = i / sr
        env = 0.0
        for offset in bursts:
            if t >= offset:
                env = max(env, math.exp(-(t - offset) / 0.0075))
        env = max(env, 0.45 * math.exp(-t / 0.085))       # the room tail
        out.append(shaped[i] * env)
    return _to_buffer(out, int(_PEAK * 0.7))


def _bass(freq: float, cutoff_hz: float, q: float, seconds: float = 0.17,
          sr: int = SAMPLE_RATE) -> array:
    """Saw through the resonant lowpass with a per-note filter envelope."""
    n = int(seconds * sr)
    raw: list[float] = []
    phase = 0.0
    for i in range(n):
        phase += freq / sr
        raw.append(_saw(phase) * 0.6 + _saw(phase * 0.5) * 0.4)
    # Sweep the filter down across the note: static cutoff sounds like a pad,
    # an envelope sounds like a 303.
    filtered = _svf_lowpass(raw, cutoff_hz, q, sr)
    bright = _svf_lowpass(raw, min(cutoff_hz * 2.6, sr * 0.44), q, sr)
    out: list[float] = []
    for i in range(n):
        t = i / sr
        blend = math.exp(-t / 0.055)
        amp = min(1.0, t / 0.004) * math.exp(-t / 0.10)
        out.append(math.tanh((filtered[i] * (1 - blend) + bright[i] * blend) * amp * 1.4))
    return _to_buffer(out, int(_PEAK * 0.85))


def _stab(freq: float, cutoff_hz: float, q: float, sr: int = SAMPLE_RATE) -> array:
    """A detuned minor chord — the one harmonic event in the pattern."""
    n = int(0.38 * sr)
    voices = (1.0, 1.003, 2.0 ** (3 / 12), 2.0 ** (7 / 12) * 0.997)
    raw: list[float] = []
    phases = [0.0] * len(voices)
    for _ in range(n):
        s = 0.0
        for v, ratio in enumerate(voices):
            phases[v] += freq * ratio / sr
            s += _saw(phases[v])
        raw.append(s / len(voices))
    filtered = _svf_lowpass(raw, cutoff_hz, q, sr)
    out: list[float] = []
    for i in range(n):
        t = i / sr
        amp = min(1.0, t / 0.006) * math.exp(-t / 0.13)
        out.append(filtered[i] * amp)
    return _to_buffer(out, int(_PEAK * 0.5))


def build_voice_bank(state: DeckState, sr: int = SAMPLE_RATE) -> dict[str, array]:
    """Synthesize every voice for this tone setting. Pure: same state in,
    byte-identical bank out."""
    cutoff_hz = _cutoff_hz(state.cutoff)
    q = 0.7 + _clamp(state.resonance, 0.0, 1.0) * 7.3
    bank: dict[str, array] = {
        "kick": _kick(sr),
        "chat": _hat(state.seed, 0.013, 0.055, sr),
        "ohat": _hat(state.seed + 1, 0.060, 0.190, sr),
        "clap": _clap(state.seed, sr),
    }
    for i in range(_BASS_NOTES):
        semis = _SCALE[i % len(_SCALE)] + 12 * (i // len(_SCALE))
        bank[f"bass{i}"] = _bass(_ROOT_HZ * 2.0 ** (semis / 12.0), cutoff_hz, q, sr=sr)
    for i in range(_STAB_NOTES):
        semis = _SCALE[i % len(_SCALE)] + 24
        bank[f"stab{i}"] = _stab(_ROOT_HZ * 2.0 ** (semis / 12.0), cutoff_hz, q * 0.6, sr)
    return bank


# ---------------------------------------------------------------------------
# Pattern planner — pure, and deliberately MONOTONE in the deck's knobs.
#
# Each bar has a fixed jitter vector derived from (seed, pattern, bar) alone,
# and an optional step fires when its jitter is under the knob. Raising
# `density` can therefore only ever ADD onsets, never move them around. That
# is a musical choice (turning the knob up feels like adding, not rerolling)
# and a testability choice: "the control changes the synthesis" becomes an
# exact assertion instead of a statistical one.
# ---------------------------------------------------------------------------
STEPS_PER_BAR = 16

_GRIDS: dict[str, dict[str, tuple[int, ...]]] = {
    "driver":  {"kick": (0, 4, 8, 12),         "bass": (2, 6, 10, 14)},
    "rolling": {"kick": (0, 4, 8, 12, 14),     "bass": (0, 3, 6, 8, 11, 14)},
    "dub":     {"kick": (0, 8),                "bass": (4, 12)},
    "acid":    {"kick": (0, 4, 8, 12),         "bass": (0, 2, 3, 6, 8, 10, 11, 14)},
}

_ACCENTS = (0, 4, 8, 12)


def _jitter(seed: int, pattern: str, bar: int, lane: str) -> tuple[float, ...]:
    rng = _rng("jitter", seed, pattern, bar, lane)
    return tuple(rng.random() for _ in range(STEPS_PER_BAR))


@dataclass
class Onset:
    """One scheduled hit: which synthesized voice, how loud."""
    step: int
    voice: str
    amp: float = 1.0


def plan_bar(state: DeckState, bar: int) -> list[Onset]:
    """The score for one bar. Pure function of deck state and bar number."""
    grid = _GRIDS.get(state.pattern, _GRIDS["driver"])
    j_hat = _jitter(state.seed, state.pattern, bar, "hat")
    j_bass = _jitter(state.seed, state.pattern, bar, "bass")
    j_stab = _jitter(state.seed, state.pattern, bar, "stab")
    j_note = _jitter(state.seed, state.pattern, bar, "note")

    onsets: list[Onset] = []
    for step in range(STEPS_PER_BAR):
        accent = 1.0 if step in _ACCENTS else 0.82

        if step in grid["kick"]:
            onsets.append(Onset(step, "kick", 1.0))
        elif state.density > 0.80 and j_hat[step] < (state.density - 0.80) * 2.0:
            onsets.append(Onset(step, "kick", 0.55))      # ghost kick, high density only

        # Closed hats: every 8th always, every 16th as density rises.
        if step % 2 == 0 or j_hat[step] < state.density:
            onsets.append(Onset(step, "chat", accent * 0.9))

        # Open hat on the offbeat is an intensity feature, not a density one.
        if state.intensity >= 0.40 and step % 4 == 2:
            onsets.append(Onset(step, "ohat", 0.8))

        if state.intensity >= 0.25 and step in (4, 12):
            onsets.append(Onset(step, "clap", 0.9))

        if step in grid["bass"] or j_bass[step] < state.density * 0.6:
            note = int(j_note[step] * _BASS_NOTES) % _BASS_NOTES
            onsets.append(Onset(step, f"bass{note}", accent))

        if j_stab[step] < state.intensity * 0.22:
            note = int(j_note[step] * _STAB_NOTES) % _STAB_NOTES
            onsets.append(Onset(step, f"stab{note}", 0.7))

    return onsets


def bar_onset_count(state: DeckState, bar: int) -> int:
    return len(plan_bar(state, bar))


# ---------------------------------------------------------------------------
# The engine
# ---------------------------------------------------------------------------
MAX_POLYPHONY = 28


class SynthEngine:
    """Streams blocks of PCM. Every sample passes through guard.music_gain().

    The guard is a REQUIRED constructor argument on purpose. There is no
    default, no None branch and no 'unguarded' mode, because the one thing this
    module must not have is a code path that reaches a loudspeaker without
    asking whether R.A.I.N. wants the room.
    """

    def __init__(self, state: DeckState, guard: AlertGuard,
                 sample_rate: int = SAMPLE_RATE) -> None:
        self.state = state
        self.guard = guard
        self.sr = sample_rate
        self._bank: dict[str, array] = {}
        self._bank_key: tuple[Any, ...] | None = None
        self._bank_build_seconds = 0.0
        self._active: list[list[Any]] = []     # [buffer, position, amplitude]
        self._frame = 0
        self._step = 0                         # absolute 16th counter
        self._next_step_frame = 0.0
        self._bar_cache: tuple[int, list[Onset]] | None = None

    # -- bank --------------------------------------------------------------
    def ensure_bank(self) -> bool:
        """Re-synthesize the voices if a tone control moved. Returns True if
        it rebuilt (the caller may want to know it just spent ~100 ms)."""
        key = self.state.tone_key()
        if key == self._bank_key and self._bank:
            return False
        started = time.monotonic()
        self._bank = build_voice_bank(self.state, self.sr)
        self._bank_build_seconds = time.monotonic() - started
        self._bank_key = key
        self._active.clear()                   # old buffers are now stale
        return True

    @property
    def bank_build_seconds(self) -> float:
        return self._bank_build_seconds

    def step_frames(self) -> float:
        """Frames per 16th note at the current tempo."""
        return (60.0 / max(1.0, self.state.bpm) / 4.0) * self.sr

    # -- scheduling --------------------------------------------------------
    def _onsets_for(self, step: int) -> list[Onset]:
        bar, within = divmod(step, STEPS_PER_BAR)
        if self._bar_cache is None or self._bar_cache[0] != bar:
            self._bar_cache = (bar, plan_bar(self.state, bar))
        return [o for o in self._bar_cache[1] if o.step == within]

    def _schedule(self, block_end: int) -> None:
        """Fire every 16th whose onset lands inside this block.

        The step clock advances by the CURRENT step length each time, so moving
        the tempo slider retimes the next step rather than jumping the beat.
        """
        while self._next_step_frame < block_end:
            for onset in self._onsets_for(self._step):
                buf = self._bank.get(onset.voice)
                if buf is None or not len(buf):
                    continue
                if len(self._active) >= MAX_POLYPHONY:
                    break
                self._active.append([buf, 0, onset.amp])
            self._step += 1
            self._next_step_frame += self.step_frames()
            # A silly-low tempo must not spin here forever.
            if self.step_frames() < 1.0:
                break

    # -- rendering ---------------------------------------------------------
    def render_block(self, nframes: int = BLOCK_FRAMES) -> array:
        """Render the next `nframes` of signed 16-bit mono PCM."""
        now = self.guard.clock()
        gain_start = self.state.volume * self.guard.music_gain(now)
        gain_end = self.state.volume * self.guard.music_gain(now + nframes / self.sr)

        if not self.state.enabled:
            # Not playing: stay silent AND stay still, so enabling the deck
            # starts on a downbeat rather than halfway through a bar.
            self._active.clear()
            return array("h", bytes(2 * nframes))

        self.ensure_bank()
        self._schedule(self._frame + nframes)

        acc = [0] * nframes
        if gain_start > 0.0 or gain_end > 0.0:
            survivors: list[list[Any]] = []
            for voice in self._active:
                buf, pos, amp = voice
                take = min(nframes, len(buf) - pos)
                if take > 0:
                    if amp >= 0.999:
                        for i in range(take):
                            acc[i] += buf[pos + i]
                    else:
                        for i in range(take):
                            acc[i] += int(buf[pos + i] * amp)
                    voice[1] = pos + take
                    if voice[1] < len(buf):
                        survivors.append(voice)
            self._active = survivors
        else:
            # Fully ducked. Still advance the voices so the groove does not
            # restart when the cue ends — the music comes back where it would
            # have been, which is what makes the duck read as a duck.
            survivors = []
            for voice in self._active:
                voice[1] += nframes
                if voice[1] < len(voice[0]):
                    survivors.append(voice)
            self._active = survivors

        pcm = array("h", bytes(2 * nframes))
        gain = gain_start
        delta = (gain_end - gain_start) / nframes if nframes else 0.0
        for i in range(nframes):
            s = int(acc[i] * gain)
            gain += delta
            pcm[i] = 32767 if s > 32767 else (-32768 if s < -32768 else s)

        self._frame += nframes
        return pcm

    # -- offline -----------------------------------------------------------
    def render_seconds(self, seconds: float, nframes: int = BLOCK_FRAMES,
                       poll: bool = True) -> array:
        """Render offline, polling the guard per block exactly as the player does.

        The poll is not optional housekeeping. AlertGuard goes unhealthy after
        GUARD_STALE_SECONDS without one, and an unhealthy guard renders
        silence — so a render loop that forgot to poll would quietly produce a
        file that is audible for two seconds and digitally silent thereafter.
        Found by running the suite under load, where exactly that happened.

        `poll=False` exists only for tests that are deliberately asserting the
        stale-guard behaviour.
        """
        out = array("h")
        total = int(seconds * self.sr)
        while len(out) < total:
            if poll:
                self.guard.poll()
            out.extend(self.render_block(nframes))
        del out[total:]
        return out


def write_wav(path: Path, pcm: array, sr: int = SAMPLE_RATE) -> None:
    data = pcm
    if struct.pack("=h", 1) != struct.pack("<h", 1):     # big-endian host
        data = array("h", pcm)
        data.byteswap()
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(sr)
        out.writeframes(data.tobytes())


def rms(pcm: array) -> float:
    """Root-mean-square level of a block. The measurable 'is it loud' number."""
    if not len(pcm):
        return 0.0
    return math.sqrt(sum(s * s for s in pcm) / len(pcm))


def peak(pcm: array) -> int:
    return max((abs(s) for s in pcm), default=0)


def brightness(pcm: array) -> float:
    """Mean absolute first difference — a cheap, FFT-free proxy for how much
    high-frequency content survived the lowpass. Used to prove the cutoff
    slider is connected to the synthesis rather than to a label."""
    if len(pcm) < 2:
        return 0.0
    return sum(abs(pcm[i] - pcm[i - 1]) for i in range(1, len(pcm))) / (len(pcm) - 1)


# ---------------------------------------------------------------------------
# Audio output
#
# Streams raw PCM to a player's stdin rather than handing it a finished file,
# because a file-based player cannot be turned down mid-cue (the whole point).
#
# DEVICE YIELD. When the duck reaches the floor the player process is
# TERMINATED, not merely silenced. On a box with only alsa-utils and no
# software mixer, a held PCM device makes R.A.I.N.'s own `aplay` fail with
# EBUSY — the music would silence itself and swallow the alert at the same
# time, which is the worst possible outcome. Releasing the device costs a
# ~100 ms restart when the music returns and removes that failure entirely.
# ---------------------------------------------------------------------------
import shutil        # noqa: E402  (grouped with the audio code it belongs to)
import subprocess    # noqa: E402
import threading     # noqa: E402

WRITE_AHEAD_SECONDS = 0.10      # how far ahead of the speaker we are allowed to get
YIELD_POLL_SECONDS = 0.025

# How much successfully-written audio counts as proof that the device works,
# and how long start() will wait for that proof.
#
# This replaced a flat 600 ms "did the child survive?" grace period, which was
# a rule-3 bug of the exact kind docs/RESILIENCE.md is about: on a loaded box
# the player process could still be *starting up* at the 600 ms mark, so a
# device that did not exist was reported as playing. Surviving a timer is not
# evidence; bytes accepted by the device is. Caught by running the suite six
# ways concurrently.
# A settle window is unavoidable here and it is worth being precise about why:
# writes go into a 64 KiB pipe before they reach the player, so for roughly the
# first 1.5 s of audio a WRITE SUCCEEDING PROVES NOTHING about whether anything
# is playing it — a child that has already died still absorbs several blocks.
# start() therefore watches for a bounded period and only then reports.
#
# This is a confirmation window, not the guarantee. The guarantee is the
# streaming loop, which turns the first BrokenPipeError into a loud failure
# whenever it happens, and which both orionx-music and the DJ deck poll
# continuously. start() is allowed to be slow; it is not allowed to be wrong.
CONFIRM_BLOCKS = 3
CONFIRM_SETTLE_SECONDS = 1.0
CONFIRM_TIMEOUT_SECONDS = 6.0


def _player_argv(name: str, sr: int) -> list[str]:
    if name == "paplay":
        return [name, "--raw", "--format=s16le", f"--rate={sr}", "--channels=1",
                "--latency-msec=80", "--stream-name=Orion-X Music"]
    return [name, "-q", "-t", "raw", "-f", "S16_LE", "-r", str(sr), "-c", "1",
            "--buffer-time=120000", "-"]


def find_player(sr: int = SAMPLE_RATE) -> list[str] | None:
    """The first available streaming player. Honours $ORIONX_MUSIC_PLAYER,
    which must be a command that reads raw s16le mono PCM on stdin."""
    override = os.environ.get("ORIONX_MUSIC_PLAYER", "").strip()
    if override:
        import shlex
        return shlex.split(override)
    for name in ("paplay", "aplay"):
        if shutil.which(name):
            return _player_argv(name, sr)
    return None


def audio_report(sr: int = SAMPLE_RATE) -> dict[str, Any]:
    """What the audio path can and cannot do, and what to type about it."""
    argv = find_player(sr)
    if argv is None:
        return {
            "available": False,
            "player": None,
            "what": "no raw-PCM audio player found (looked for paplay, aplay)",
            "consequence": "the deck cannot make any sound at all — note that "
                           "this means R.A.I.N.'s intrusion cues are silent too",
            "remedy": "sudo apt-get install --no-install-recommends "
                      "pulseaudio-utils alsa-utils",
        }
    return {"available": True, "player": argv[0], "what": "", "consequence": "",
            "remedy": ""}


@dataclass
class PlayerResult:
    ok: bool
    what: str = ""
    consequence: str = ""
    remedy: str = ""
    detail: str = ""

    def message(self) -> str:
        if self.ok:
            return "ok"
        parts = [self.what]
        if self.consequence:
            parts.append(f"consequence: {self.consequence}")
        if self.remedy:
            parts.append(f"remedy: {self.remedy}")
        if self.detail:
            parts.append(f"detail: {self.detail}")
        return " | ".join(p for p in parts if p)


class MusicPlayer:
    """Runs the engine against a real audio device, in a background thread."""

    def __init__(self, engine: SynthEngine, argv: list[str] | None = None) -> None:
        self.engine = engine
        self.argv = argv if argv is not None else find_player(engine.sr)
        self._proc: subprocess.Popen[bytes] | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._result = PlayerResult(ok=False, what="not started")
        self._yielded = False
        self._blocks_written = 0
        self._lock = threading.Lock()

    # -- status ------------------------------------------------------------
    @property
    def result(self) -> PlayerResult:
        with self._lock:
            return self._result

    def _set(self, result: PlayerResult) -> None:
        with self._lock:
            self._result = result

    def running(self) -> bool:
        thread = self._thread
        return thread is not None and thread.is_alive()

    def device_held(self) -> bool:
        proc = self._proc
        return proc is not None and proc.poll() is None

    def blocks_written(self) -> int:
        """Audio blocks the device has actually accepted. The evidence."""
        with self._lock:
            return self._blocks_written

    # -- lifecycle ---------------------------------------------------------
    def start(self) -> PlayerResult:
        if self.running():
            return self.result
        if self.argv is None:
            report = audio_report(self.engine.sr)
            result = PlayerResult(False, report["what"], report["consequence"],
                                  report["remedy"])
            self._set(result)
            return result
        self.engine.guard.poll()
        self._stop.clear()
        self._set(PlayerResult(ok=True))
        with self._lock:
            self._blocks_written = 0
        self._thread = threading.Thread(target=self._run, name="orionx-music",
                                        daemon=True)
        self._thread.start()

        # Confirm rather than assume (rule 3). "Playing" means the device has
        # taken CONFIRM_BLOCKS blocks of PCM and the player is still alive —
        # not that a process existed for a while without complaining.
        started = time.monotonic()
        deadline = started + CONFIRM_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if not self.result.ok:
                return self.result                  # already failed, loudly
            if (time.monotonic() - started >= CONFIRM_SETTLE_SECONDS
                    and self.blocks_written() >= CONFIRM_BLOCKS
                    and self.device_held()):
                return self.result                  # confirmed
            if not self.running():
                break
            time.sleep(0.01)

        if self.result.ok:
            # Neither confirmed nor failed. Say exactly that; do not round it
            # up to success.
            self._set(PlayerResult(
                False,
                f"the audio player ({self.argv[0] if self.argv else '?'}) accepted "
                f"only {self.blocks_written()} of {CONFIRM_BLOCKS} audio blocks in "
                f"{CONFIRM_TIMEOUT_SECONDS:.0f}s",
                "playback could not be confirmed, so the deck is reporting "
                "nothing rather than claiming to play",
                "orionx-music status; aplay -l"))
            self.stop()
        return self.result

    def stop(self) -> None:
        self._stop.set()
        self._kill_child()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)
        self._thread = None

    def _kill_child(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except OSError:
            pass
        try:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
        except OSError:
            pass

    def _spawn(self) -> bool:
        try:
            self._proc = subprocess.Popen(          # noqa: S603
                list(self.argv or []),
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            return True
        except OSError as exc:
            self._set(PlayerResult(
                False,
                f"could not launch the audio player ({self.argv[0] if self.argv else '?'})",
                "the music deck is silent; R.A.I.N. cues are unaffected",
                "orionx-music status",
                str(exc)))
            return False

    def _child_died(self) -> None:
        proc = self._proc
        detail = ""
        if proc is not None and proc.stderr is not None:
            try:
                detail = proc.stderr.read(400).decode("utf-8", "replace").strip()
            except OSError:
                detail = ""
        name = self.argv[0] if self.argv else "?"
        self._set(PlayerResult(
            False,
            f"the audio player ({name}) exited immediately",
            "there is no usable audio device, so the deck produces nothing — "
            "and R.A.I.N.'s intrusion cues are almost certainly silent too, "
            "which is the part that matters",
            "aplay -l   # list devices; empty output means no sound card is present",
            detail))

    # -- the loop ----------------------------------------------------------
    def _run(self) -> None:
        guard = self.engine.guard
        sr = self.engine.sr
        if not self._spawn():
            return
        produced = 0
        origin = time.monotonic()
        while not self._stop.is_set():
            guard.poll()

            now = guard.clock()
            yield_device = (guard.duck.holding(now) or not guard.is_healthy(now))
            if yield_device and self.engine.state.enabled:
                # Hand the sound card back for the duration of the cue.
                if self.device_held():
                    self._kill_child()
                    self._yielded = True
                time.sleep(YIELD_POLL_SECONDS)
                continue

            if self._yielded or not self.device_held():
                if self._proc is not None and self._proc.poll() is not None:
                    self._child_died()
                    return
                if not self._spawn():
                    return
                self._yielded = False
                produced = 0
                origin = time.monotonic()

            ahead = produced / sr - (time.monotonic() - origin)
            if ahead > WRITE_AHEAD_SECONDS:
                time.sleep(min(ahead - WRITE_AHEAD_SECONDS, 0.2))
                continue

            block = self.engine.render_block()
            proc = self._proc
            if proc is None or proc.stdin is None:
                continue
            try:
                proc.stdin.write(block.tobytes())
                proc.stdin.flush()
            except (BrokenPipeError, OSError):
                self._child_died()
                return
            produced += len(block)
            with self._lock:
                self._blocks_written += 1
        self._kill_child()


# ---------------------------------------------------------------------------
# The deck's control surface, declared as data.
#
# The GTK deck builds its widgets by iterating this table, and the test suite
# drives the same table to prove each control actually moves the synthesis.
# One authority for "what knobs exist" — a slider cannot appear on the deck
# without being a real synthesis parameter, and a parameter cannot be renamed
# out from under the GUI (rule 7, docs/RESILIENCE.md).
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Control:
    key: str
    label: str
    low: float
    high: float
    step: float
    fmt: str
    tip: str
    rebuilds_bank: bool = False

    def format(self, value: float) -> str:
        return self.fmt.format(value)


CONTROLS: tuple[Control, ...] = (
    Control("bpm", "TEMPO", 90.0, 160.0, 1.0, "{:.0f} BPM",
            "Beats per minute. Retimes the next 16th rather than restarting the bar."),
    Control("cutoff", "FILTER", 0.0, 1.0, 0.01, "{:.0%}",
            "Lowpass cutoff, 180 Hz to 9 kHz. Re-synthesizes the voice bank.",
            rebuilds_bank=True),
    Control("resonance", "RESONANCE", 0.0, 1.0, 0.01, "{:.0%}",
            "Filter Q — the acid knob. Re-synthesizes the voice bank.",
            rebuilds_bank=True),
    Control("density", "DENSITY", 0.0, 1.0, 0.01, "{:.0%}",
            "How many optional 16ths fire. Raising it only ever adds hits."),
    Control("intensity", "INTENSITY", 0.0, 1.0, 0.01, "{:.0%}",
            "Open hats, claps and stabs. Can be driven by the threat posture."),
    Control("volume", "VOLUME", 0.0, 1.0, 0.01, "{:.0%}",
            "Master level. Never reaches the speaker without the alert guard's gain."),
)

CONTROL_KEYS = tuple(c.key for c in CONTROLS)


def apply_control(state: DeckState, key: str, value: float) -> DeckState:
    """Set one control on the deck state, clamped. Pure-ish: mutates and
    returns the same object so the GTK handlers stay one-liners."""
    if key not in CONTROL_KEYS:
        raise KeyError(f"unknown control: {key}")
    setattr(state, key, value)
    return state.clamp()


# --- Optional: let the deck's own threat posture drive the music ------------
POSTURE_STATUS = Path("/run/orionx/posture-status.json")

# Tier -> intensity. Deliberately NOT tier -> volume: a rising threat should
# make the bed busier and more urgent, never louder, because loudness is the
# resource R.A.I.N. needs and the music does not get to spend it.
POSTURE_INTENSITY = {0: 0.30, 1: 0.55, 2: 0.80, 3: 0.95}


def posture_intensity(path: Path | None = None) -> float | None:
    """Current threat tier mapped to an intensity, or None if unknown."""
    path = POSTURE_STATUS if path is None else Path(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    for key in ("tier", "level", "posture_tier"):
        if key in data:
            try:
                return POSTURE_INTENSITY.get(int(data[key]))
            except (TypeError, ValueError):
                return None
    return None
