#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_music.sh — generative techno bed + DJ deck (DEC-PHASE12-044)
#
# The deck's speaker is a safety surface: R.A.I.N. turns intrusions into
# audible cues, so anything else that makes noise is a candidate for masking
# an alert. These tests therefore spend most of their effort on one claim —
# "a cue firing silences the music" — and prove it by driving real state
# transitions through the real guard and MEASURING THE RENDERED PCM, not by
# grepping for the word "duck".
#
# Everything here runs with no sound card. The engine's offline render path is
# the same code the streaming player uses, block for block, so a measurement
# taken on a WAV is a measurement of what the speaker would have produced.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

MUSIC_DIR="$REPO_ROOT/scripts/music"
SYNTH="$MUSIC_DIR/orionx_synth.py"
CLI="$MUSIC_DIR/orionx-music"
DJ="$MUSIC_DIR/orionx-dj"
CHROOT="$REPO_ROOT/iso/config/includes.chroot"
HOOK="$REPO_ROOT/iso/config/hooks/live/0702-orionx-music.hook.chroot"

# Isolated scratch + HOME, so no test ever reads or writes the operator's
# real ~/.config/orionx/music.json.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/orionx-music-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME"

section "Structure"
if [[ -f "$SYNTH" ]]; then pass "orionx_synth.py present"; else fail "orionx_synth.py present" "missing"; exit 1; fi
if [[ -f "$CLI" ]]; then pass "orionx-music present"; else fail "orionx-music present" "missing"; exit 1; fi
if [[ -f "$DJ" ]]; then pass "orionx-dj present"; else fail "orionx-dj present" "missing"; exit 1; fi
if [[ -x "$CLI" ]]; then pass "orionx-music executable"; else fail "orionx-music executable"; fi
if [[ -x "$DJ" ]]; then pass "orionx-dj executable"; else fail "orionx-dj executable"; fi
if head -1 "$CLI" | grep -q python3; then pass "orionx-music python3 shebang"; else fail "orionx-music python3 shebang"; fi
if head -1 "$DJ" | grep -q python3; then pass "orionx-dj python3 shebang"; else fail "orionx-dj python3 shebang"; fi
for f in "$SYNTH" "$CLI" "$DJ" "$HOOK"; do
  if grep -q '@decision DEC-PHASE12-044' "$f"; then pass "$(basename "$f") carries decision annotation"
  else fail "$(basename "$f") carries decision annotation"; fi
done

section "No shipped audio assets, no new dependency"
# The whole point of generating the music is that nothing is shipped and
# nothing is installed. Both claims are checkable.
if [[ -z "$(find "$MUSIC_DIR" -type f \( -name '*.wav' -o -name '*.mp3' -o -name '*.ogg' -o -name '*.flac' \) 2>/dev/null)" ]]; then
  pass "scripts/music/ ships no audio files"
else fail "scripts/music/ ships no audio files" "$(find "$MUSIC_DIR" -type f -name '*.wav' -o -name '*.mp3')"; fi
if python3 - "$SYNTH" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        mods.update(a.name.split(".")[0] for a in node.names)
    elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
        mods.add(node.module.split(".")[0])
allowed = {"__future__", "json", "math", "os", "random", "struct", "time", "wave",
           "array", "dataclasses", "pathlib", "typing", "shutil", "subprocess",
           "threading", "shlex", "importlib",
           # rain_lib is Orion-X's own, and importing it rather than copying
           # its severity table is the point (one authority per fact).
           "rain_lib"}
extra = mods - allowed
print("  imports:", " ".join(sorted(mods)))
if extra:
    print("  BAD  non-stdlib / unexpected imports:", extra)
    sys.exit(1)
sys.exit(0)
PY
then pass "engine imports only the Python standard library (no numpy, no new apt package)"
else fail "engine imports only the Python standard library"; fi

section "Defaults: music is off"
if python3 - "$SYNTH" "$WORK" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
m = SourceFileLoader("s", sys.argv[1]).load_module()
work = Path(sys.argv[2])
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

check(m.DeckState().enabled is False, "a fresh DeckState is disabled")
check(m.default_config()["enabled"] is False, "the shipped default config is disabled")
check(m.load_config(work / "nope.json").enabled is False, "a MISSING config file yields disabled")
(work / "corrupt.json").write_text("{not json at all")
check(m.load_config(work / "corrupt.json").enabled is False, "a CORRUPT config file yields disabled")
(work / "empty.json").write_text("{}")
check(m.load_config(work / "empty.json").enabled is False, "an EMPTY config object yields disabled")
# A disabled engine must produce literal silence even with the volume at max.
guard = m.AlertGuard(event_log=work/"e", gate=work/"g", tone_dir=work/"t", rain_lib=None)
guard.poll()
st = m.DeckState(enabled=False, volume=1.0).clamp()
eng = m.SynthEngine(st, guard)
pcm = eng.render_seconds(1.0)
check(m.peak(pcm) == 0, f"a disabled engine renders digital silence (peak={m.peak(pcm)})")
st.enabled = True
check(m.peak(eng.render_seconds(1.0)) > 1000, "the same engine makes sound once enabled")
sys.exit(0 if ok else 1)
PY
then pass "off-by-default assertions"; else fail "off-by-default assertions" "see output above"; fi

if grep -qE 'orionx-(music|dj)' "$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"; then
  fail "no systemd unit can start the music" "0615 references the music subsystem"
else pass "no systemd unit can start the music (absent from the 0615 authority)"; fi
if [[ -z "$(find "$CHROOT" -path '*xdg/autostart*' -name '*music*' -o -path '*xdg/autostart*' -name '*dj*' 2>/dev/null)" ]]; then
  pass "no XDG autostart entry can start the music"
else fail "no XDG autostart entry can start the music"; fi
if [[ -z "$(find "$CHROOT/usr/share/orionx/systemd" -name '*music*' -o -name '*orionx-dj*' 2>/dev/null)" ]]; then
  pass "no music unit file is even staged"
else fail "no music unit file is even staged"; fi

section "Ducking: a R.A.I.N. cue silences the music (safety-critical)"
# Every assertion below is a REAL STATE TRANSITION: an event is appended to a
# real bus file, the real AlertGuard polls it, and the resulting PCM is
# measured. Nothing here inspects source text.
if python3 - "$SYNTH" "$WORK" "$REPO_ROOT" <<'PY'
import json, sys, time, wave
from importlib.machinery import SourceFileLoader
from pathlib import Path

m = SourceFileLoader("s", sys.argv[1]).load_module()
work = Path(sys.argv[2]) / "duck"; work.mkdir(parents=True, exist_ok=True)
repo = Path(sys.argv[3])
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

def last_nonzero(pcm):
    for i in range(len(pcm) - 1, -1, -1):
        if pcm[i] != 0:
            return i
    return -1

# The duck is a ~12 ms ramp, not a razor cut, because an instantaneous mute
# clicks — and a click arriving at the same instant as an intrusion cue is
# exactly the wrong noise. The claim under test is therefore not "the next
# sample is zero" but "everything past the first audio block is zero": the
# music is gone before R.A.I.N.'s cue has played 46 ms of its own first tone.
DUCK_LIMIT = m.BLOCK_FRAMES + 4
def ducked(pcm, label):
    last = last_nonzero(pcm)
    check(last <= DUCK_LIMIT,
          f"{label} (last non-zero sample at {last}, limit {DUCK_LIMIT} = one block)")

rain = SourceFileLoader("rl", str(repo / "scripts/rain/rain_lib.py")).load_module()
cues = repo / "iso/config/includes.chroot/usr/share/orionx/rain"

class Rig:
    """A whole music subsystem on a clock we control."""
    def __init__(self, rain_cfg=None, rain_lib=rain, tone_dir=cues, tag="r"):
        self.t = 1_000_000.0
        self.bus = work / f"events-{tag}.jsonl"
        self.gate = work / f"gate-{tag}"
        self.bus.write_text("")
        if rain_lib is not None and rain_cfg is not None:
            rain_lib = _FakeRain(rain_lib, rain_cfg)
        self.guard = m.AlertGuard(event_log=self.bus, gate=self.gate,
                                  tone_dir=tone_dir, rain_lib=rain_lib,
                                  clock=lambda: self.t)
        self.guard.poll(self.t)
        self.state = m.DeckState(enabled=True, volume=1.0, density=0.9,
                                 intensity=0.9).clamp()
        self.engine = m.SynthEngine(self.state, self.guard)
        self.engine.ensure_bank()
        self.block(0.5)                      # let the groove get going
    def emit(self, severity, category="scan"):
        with self.bus.open("a") as fh:
            fh.write(json.dumps({"ts": time.time(), "severity": severity,
                                 "source": "test", "category": category,
                                 "message": "synthetic"}) + "\n")
    def advance(self, seconds):
        self.t += seconds
        self.guard.poll(self.t)
    def block(self, seconds=0.1):
        """Render `seconds` of audio, advancing the clock as the player does."""
        out = m.array("h") if hasattr(m, "array") else None
        import array as _a
        out = _a.array("h")
        frames = int(seconds * self.engine.sr)
        while len(out) < frames:
            self.guard.poll(self.t)
            out.extend(self.engine.render_block())
            self.t += m.BLOCK_FRAMES / self.engine.sr
        del out[frames:]
        return out

class _FakeRain:
    """rain_lib with a chosen config — the operator's live rain.json."""
    def __init__(self, real, cfg):
        self._real, self._cfg = real, cfg
        self.SEVERITIES = real.SEVERITIES
    def load_config(self): return dict(self._cfg)
    def severity_rank(self, s): return self._real.severity_rank(s)
    def normalize_severity(self, s): return self._real.normalize_severity(s)

# --- 1. the floor is silence, not a mix level -------------------------------
check(m.DUCK_FLOOR == 0.0, f"DUCK_FLOOR is exact silence ({m.DUCK_FLOOR})")

# --- 1b. holding() marks the duck from its FIRST sample ---------------------
# The player hands the sound card back while holding() is true. That predicate
# has to go true at the instant the duck begins, not when the 12 ms gain ramp
# finishes — a whole audio block later — because the whole point of yielding
# is that R.A.I.N.'s own aplay must not meet a busy device.
d = m.DuckController()
check(d.holding(100.0) is False, "holding() is false before any duck")
d.duck(100.0, 2.0)
check(d.holding(100.0) is True, "holding() is true at the duck's very first sample")
check(d.gain_at(100.0) == 1.0,
      "...at an instant when the gain ramp has deliberately not moved yet")
check(d.gain_at(100.0 + m.DUCK_ATTACK_SECONDS) == m.DUCK_FLOOR,
      f"the ramp reaches the floor in {1000 * m.DUCK_ATTACK_SECONDS:.0f} ms")
check(d.holding(101.9) is True, "holding() stays true for the whole hold")
check(d.holding(102.1) is False, "and ends when the release ramp begins")
check(d.gain_at(102.1) > m.DUCK_FLOOR, "which is when the music starts coming back")
check(d.gain_at(102.0 + m.DUCK_RELEASE_SECONDS + 0.01) == 1.0, "and fully recovers")

# --- 2. a critical event on the bus silences the music ----------------------
r = Rig(rain_cfg={"enabled": True, "min_severity": "warning", "voice": False, "speech": False})
before = r.block(0.3)
check(m.rms(before) > 200, f"music is audible before the alert (rms={m.rms(before):.0f})")
r.emit("critical")
during = r.block(0.3)
ducked(during, "a CRITICAL event takes the music to digital silence")
check(r.guard.cues_seen() == 1, "the guard counted exactly one cue")

# --- 3. the duck lasts as long as the cue, then the music returns -----------
crit_len = m.cue_duration("critical", cues)
info_len = m.cue_duration("info", cues)
check(abs(crit_len - 0.620) < 0.01 and abs(info_len - 0.130) < 0.01,
      f"cue lengths are MEASURED from the WAVs, not guessed "
      f"(info {info_len:.3f}s, critical {crit_len:.3f}s — a 4.8x spread)")
mid = r.block(0.2)
check(m.peak(mid) == 0, "still silent while critical.wav is still playing")
r.advance(crit_len + m.DUCK_TAIL_SECONDS + m.DUCK_RELEASE_SECONDS + 0.2)
after = r.block(0.4)
check(m.rms(after) > 200, f"music returns after the cue finishes (rms={m.rms(after):.0f})")

# --- 4. the duck is faster than one audio block -----------------------------
r2 = Rig(rain_cfg={"enabled": True, "min_severity": "warning", "voice": False, "speech": False}, tag="fast")
r2.emit("warning")
r2.guard.poll(r2.t)
one = r2.engine.render_block()
r2.t += m.BLOCK_FRAMES / r2.engine.sr
two = r2.engine.render_block()
check(m.peak(two) == 0,
      f"one audio block ({1000.0 * m.BLOCK_FRAMES / r2.engine.sr:.0f} ms) after the event, "
      f"every sample is zero (peak={m.peak(two)})")
check(m.peak(one) < m.peak(before),
      "and the block containing the ramp is already quieter than normal play")

# --- 5. severity threshold is R.A.I.N.'s, not a second copy of it -----------
r3 = Rig(rain_cfg={"enabled": True, "min_severity": "warning", "voice": False, "speech": False}, tag="below")
r3.emit("info")
quiet_event = r3.block(0.3)
check(m.rms(quiet_event) > 200,
      "an INFO event below R.A.I.N.'s threshold does NOT duck (no cue will play)")
r3.emit("critical")
ducked(r3.block(0.3), "a CRITICAL event above the threshold does duck")

r4 = Rig(rain_cfg={"enabled": True, "min_severity": "info", "voice": False, "speech": False}, tag="lowthresh")
r4.emit("info")
ducked(r4.block(0.3),
       "the SAME info event ducks when the operator lowered min_severity to info")

# --- 6. R.A.I.N. switched off means no cue, so no duck ----------------------
r5 = Rig(rain_cfg={"enabled": False, "min_severity": "info", "voice": False, "speech": False}, tag="off")
r5.emit("critical")
check(m.rms(r5.block(0.3)) > 200, "with R.A.I.N. disabled, nothing ducks the music")

# --- 7. fail closed: if we cannot ask R.A.I.N., assume every event is audible
r6 = Rig(rain_lib=None, tag="norain")
r6.emit("info")
ducked(r6.block(0.3),
       "with rain_lib unavailable, even an INFO event ducks (fail closed)")
check(any("rain_lib" in d["what"] for d in r6.guard.degradations()),
      "and that degradation is reported, with a remedy")

# --- 8. spoken narration (DEC-PHASE12-046) extends the hold -----------------
base = Rig(rain_cfg={"enabled": True, "min_severity": "warning", "voice": False, "speech": False}, tag="nospeech")
spk  = Rig(rain_cfg={"enabled": True, "min_severity": "warning", "voice": False, "speech": True}, tag="speech")
d_base = base.guard._duck_seconds("critical", base.t)
d_spk = spk.guard._duck_seconds("critical", spk.t)
check(d_spk > d_base + 10.0,
      f"speech on holds the duck far longer ({d_base:.1f}s -> {d_spk:.1f}s)")

# --- 9. the duck gate: anything can ask for the room ------------------------
r7 = Rig(rain_cfg={"enabled": True, "min_severity": "critical", "voice": False, "speech": False}, tag="gate")
check(m.rms(r7.block(0.3)) > 200, "audible before the gate is armed")
check(m.request_duck(2.0, gate=r7.gate), "request_duck() armed the gate")
ducked(r7.block(0.3), "arming the duck gate silences the music")
# Disarmed by truncation, never unlink: the file must survive so a non-root
# process can still arm it under a 0755 /run/orionx.
check(r7.gate.exists(), "the gate file still exists after being consumed")
check(r7.gate.read_text().strip() == "", "the gate was disarmed by truncation")
r7.advance(2.0 + m.DUCK_RELEASE_SECONDS + 0.2)
check(m.rms(r7.block(0.4)) > 200, "music returns when the gate's duration expires")

# An empty gate (what tmpfiles.d leaves at boot) must NOT duck.
r8 = Rig(rain_cfg={"enabled": True, "min_severity": "critical", "voice": False, "speech": False}, tag="emptygate")
r8.gate.write_text("")
check(m.rms(r8.block(0.3)) > 200, "an EMPTY gate (boot state) does not duck")
# A corrupt gate must duck: a garbled gate is not permission to play.
r8.gate.write_text("whatever\x00garbage")
ducked(r8.block(0.3), "a CORRUPT gate ducks anyway (fail closed)")

# --- 10. music may not outlive its own watchdog -----------------------------
r9 = Rig(rain_cfg={"enabled": True, "min_severity": "warning", "voice": False, "speech": False}, tag="stale")
check(m.rms(r9.block(0.3)) > 200, "audible while the guard is polling")
# Assert the POLICY as an absolute bound, then drive an absolute transition.
# The original version advanced the clock by GUARD_STALE_SECONDS + 1, so
# widening the constant to 1e9 moved the test with the bug and the mutation
# survived. A watchdog's timeout is a number to pin down, not to read back.
check(m.GUARD_STALE_SECONDS <= 5.0,
      f"the watchdog timeout is a bounded number ({m.GUARD_STALE_SECONDS}s <= 5s)")
r9.t += 6.0                                  # clock moves, guard does NOT poll
check(r9.guard.is_healthy(r9.t) is False, "a guard that stopped polling reports unhealthy")
import array as _arr
silent = _arr.array("h")
while len(silent) < int(0.3 * r9.engine.sr):
    silent.extend(r9.engine.render_block())   # deliberately no poll()
    r9.t += m.BLOCK_FRAMES / r9.engine.sr
check(m.peak(silent) == 0,
      f"a stale guard forces silence — music cannot play unwatched (peak={m.peak(silent)})")
fresh = m.AlertGuard(event_log=work/"nx", gate=work/"nx2", tone_dir=cues, rain_lib=rain)
check(fresh.music_gain() == 0.0, "a guard that has NEVER polled permits nothing")

# --- 11. the groove does not restart after a duck ---------------------------
r10 = Rig(rain_cfg={"enabled": True, "min_severity": "warning", "voice": False, "speech": False}, tag="phase")
step_before = r10.engine._step
r10.emit("critical")
r10.block(0.5)
check(r10.engine._step > step_before,
      "the step clock keeps running while ducked, so the music resumes in time")
sys.exit(0 if ok else 1)
PY
then pass "ducking assertions (real bus events, measured PCM)"; else fail "ducking assertions" "see output above"; fi

section "No audio device degrades loudly, and names the remedy"
if python3 - "$SYNTH" "$WORK" <<'PY'
import os, sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
m = SourceFileLoader("s", sys.argv[1]).load_module()
work = Path(sys.argv[2]); ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

# 1. No player binary anywhere.
saved = os.environ.get("PATH", "")
os.environ["PATH"] = str(work / "empty-path")
os.environ.pop("ORIONX_MUSIC_PLAYER", None)
report = m.audio_report()
os.environ["PATH"] = saved
check(report["available"] is False, "no paplay/aplay -> audio_report says unavailable")
check(bool(report["what"]) and bool(report["consequence"]) and bool(report["remedy"]),
      "the report names WHAT, the CONSEQUENCE and the REMEDY (rule 8)")
check("apt-get install" in report["remedy"], f"remedy is a runnable command: {report['remedy']!r}")
check("R.A.I.N." in report["consequence"],
      "and it says the part that matters: no player means the INTRUSION CUES are silent too")

# 2. A player binary that exists but dies immediately (= no sound card).
guard = m.AlertGuard(event_log=work/"nd1", gate=work/"nd2", rain_lib=None)
guard.poll()
state = m.DeckState(enabled=True).clamp()
engine = m.SynthEngine(state, guard)
engine.ensure_bank()
player = m.MusicPlayer(engine, argv=[sys.executable, "-c", "raise SystemExit(1)"])
result = player.start()
player.stop()
check(result.ok is False, "a player that exits immediately is NOT reported as playing")
check("exited immediately" in result.what, f"it says what happened: {result.what!r}")
check("aplay -l" in result.remedy, f"and how to diagnose it: {result.remedy!r}")
check("cues are almost certainly silent" in result.consequence,
      "and that R.A.I.N. is probably broken too, which is the real headline")

# 3. The engine never claims to be playing when it is not.
check(player.running() is False, "the player reports itself stopped")
check(player.device_held() is False, "and holds no audio device")
sys.exit(0 if ok else 1)
PY
then pass "degradation assertions"; else fail "degradation assertions" "see output above"; fi

STATUS_OUT="$(PATH="$WORK/empty-path:/usr/bin:/bin" ORIONX_MUSIC_PLAYER='' python3 "$CLI" status 2>&1)"; STATUS_RC=$?
if [[ $STATUS_RC -ne 0 ]]; then pass "orionx-music status exits non-zero when degraded"; else fail "orionx-music status exits non-zero when degraded" "rc=$STATUS_RC"; fi
if echo "$STATUS_OUT" | grep -q 'remedy'; then pass "orionx-music status prints a remedy"; else fail "orionx-music status prints a remedy" "$STATUS_OUT"; fi
if echo "$STATUS_OUT" | grep -q 'DEGRADED'; then pass "orionx-music status announces DEGRADED loudly"; else fail "orionx-music status announces DEGRADED loudly" "$STATUS_OUT"; fi

mkdir -p "$WORK/nogi"
printf 'raise ImportError("gi blocked by test_music.sh")\n' > "$WORK/nogi/gi.py"
DJ_OUT="$(PYTHONPATH="$WORK/nogi" python3 "$DJ" 2>&1)"; DJ_RC=$?
if [[ $DJ_RC -eq 1 ]]; then pass "orionx-dj exits 1 when GTK is missing"; else fail "orionx-dj exits 1 when GTK is missing" "rc=$DJ_RC"; fi
if echo "$DJ_OUT" | grep -q 'remedy.*python3-gi'; then pass "orionx-dj names the GTK remedy"; else fail "orionx-dj names the GTK remedy" "$DJ_OUT"; fi
if echo "$DJ_OUT" | grep -q 'orionx-music play'; then pass "orionx-dj names the headless fallback"; else fail "orionx-dj names the headless fallback" "$DJ_OUT"; fi

section "Device yield: a cue gets the sound card back, not just the volume"
# On a box with only alsa-utils, a held PCM device makes R.A.I.N.'s own aplay
# fail with EBUSY. Silencing the stream is not enough — the player process has
# to let go. Proven here against a REAL child process.
if python3 - "$SYNTH" "$WORK" <<'PY'
import sys, time
from importlib.machinery import SourceFileLoader
from pathlib import Path
m = SourceFileLoader("s", sys.argv[1]).load_module()
work = Path(sys.argv[2]) / "yield"; work.mkdir(parents=True, exist_ok=True)
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)
def wait_for(fn, timeout=6.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if fn():
            return True
        time.sleep(0.05)
    return False

gate = work / "gate"
guard = m.AlertGuard(event_log=work / "bus", gate=gate, rain_lib=None)
state = m.DeckState(enabled=True, volume=0.5).clamp()
engine = m.SynthEngine(state, guard)
engine.ensure_bank()
# A stand-in for paplay: a real process that really consumes the PCM stream.
player = m.MusicPlayer(engine, argv=[sys.executable, "-c",
                                     "import sys\nwhile sys.stdin.buffer.read(4096): pass"])
try:
    check(player.start().ok, "the streaming player started")
    check(wait_for(player.device_held), "it holds the audio device while playing")
    m.request_duck(1.0, gate=gate)
    check(wait_for(lambda: not player.device_held(), 3.0),
          "a duck TERMINATES the player — R.A.I.N. gets the sound card back")
    check(wait_for(player.device_held, 8.0),
          "and the music reclaims the device once the cue is over")
finally:
    player.stop()
check(player.device_held() is False, "stopping the deck releases the device")
sys.exit(0 if ok else 1)
PY
then pass "device-yield assertions"; else fail "device-yield assertions" "see output above"; fi

section "DJ deck: the controls really change the synthesis"
# The deck is constructed for real and its real GTK signal handlers are fired,
# against a stub `gi` that records values instead of drawing them. So this
# tests the actual wiring — fader -> handler -> DeckState -> rendered PCM —
# rather than asserting that the source contains the word "bpm".
mkdir -p "$WORK/stubgi/gi"
cat > "$WORK/stubgi/gi/__init__.py" <<'PY'
def require_version(*_a, **_k):
    return None
PY
cat > "$WORK/stubgi/gi/repository.py" <<'PY'
"""Just enough GTK3 to build a window headlessly and press its buttons."""


class _Widget:
    def __init__(self, *_a, **_k):
        self._value = 0.0
        self._text = ""
        self._label = ""
        self._active = False
        self._handlers = {}

    def connect(self, signal, cb, *extra):
        self._handlers.setdefault(signal, []).append((cb, extra))
        return len(self._handlers[signal])

    def emit(self, signal, *_a):
        for cb, extra in list(self._handlers.get(signal, [])):
            cb(self, *extra)

    def set_value(self, v):
        self._value = float(v)

    def get_value(self):
        return self._value

    def set_active(self, v):
        self._active = bool(v)
        self.emit("toggled")

    def get_active(self):
        return self._active

    def set_text(self, t):
        self._text = str(t)

    def get_text(self):
        return self._text

    def set_label(self, t):
        self._label = str(t)

    def get_label(self):
        return self._label

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        return lambda *_a, **_k: None


class _Auto:
    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        value = _Auto()
        setattr(self, name, value)
        return value

    def __call__(self, *a, **k):
        return _Widget(*a, **k)


Gtk = _Auto()
Gtk.Window = _Widget
GLib = _Auto()
Pango = _Auto()
PY
if PYTHONPATH="$WORK/stubgi" python3 - "$DJ" "$SYNTH" "$WORK" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

dj_path, synth_path, work = sys.argv[1], sys.argv[2], Path(sys.argv[3]) / "deck"
work.mkdir(parents=True, exist_ok=True)
# Import the engine the way orionx-dj itself does, so the deck and these
# assertions share ONE module object. Loading it twice would give the test a
# private copy of every module-level constant and quietly stop testing the
# thing the deck actually uses.
sys.path.insert(0, str(Path(synth_path).parent))
import orionx_synth as m
dj = SourceFileLoader("dj", dj_path).load_module()
assert dj.synth is m, "the deck and the test must share one engine module"

ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

deck = dj.DJDeck()
# Pin the deck's guard to scratch paths so a real alert on the build host
# cannot perturb the measurements.
guard = m.AlertGuard(event_log=work / "bus", gate=work / "gate", rain_lib=None)
guard.poll()
deck.guard = guard
deck.engine.guard = guard

check(sorted(deck._scales) == sorted(m.CONTROL_KEYS),
      f"the deck builds one fader per declared control: {sorted(deck._scales)}")
check(len(m.CONTROLS) == 6, f"six faders, not a DAW ({len(m.CONTROLS)})")

def render(seconds=2.0):
    """Render from the deck's LIVE state, the way the player thread would."""
    engine = m.SynthEngine(deck.state, guard)
    engine.ensure_bank()
    out = engine.render_seconds(seconds)
    return out, engine

def move(key, value):
    """Drive the real GTK handler, exactly as a mouse drag would."""
    scale = deck._scales[key]
    scale.set_value(value)
    scale.emit("value-changed")

deck.state.enabled = True

# -- every control must move the audio, measurably --------------------------
for control in m.CONTROLS:
    move(control.key, control.low)
    low_pcm, _ = render(2.0)
    move(control.key, control.high)
    high_pcm, _ = render(2.0)
    check(low_pcm.tobytes() != high_pcm.tobytes(),
          f"{control.label}: moving the fader changes the rendered audio")
    move(control.key, float(getattr(m.DeckState(), control.key)))

# -- and move it in the direction the label promises ------------------------
move("volume", 0.9)
loud, _ = render(2.0)
move("volume", 0.2)
quiet, _ = render(2.0)
ratio = m.rms(quiet) / max(m.rms(loud), 1e-9)
check(0.1 < ratio < 0.45,
      f"VOLUME scales the level roughly linearly (0.2/0.9 -> rms ratio {ratio:.2f})")
move("volume", 0.55)

move("cutoff", 0.15)
dark, _ = render(2.0)
move("cutoff", 0.95)
bright, _ = render(2.0)
check(m.brightness(bright) > m.brightness(dark) * 1.5,
      f"FILTER opens the lowpass (brightness {m.brightness(dark):.0f} -> "
      f"{m.brightness(bright):.0f})")

move("bpm", 96.0)
_, slow_engine = render(2.0)
slow_steps, slow_len = slow_engine._step, slow_engine.step_frames()
move("bpm", 156.0)
_, fast_engine = render(2.0)
check(fast_engine._step > slow_steps,
      f"TEMPO changes how many 16ths fit in 2s ({slow_steps} -> "
      f"{fast_engine._step}; expected ~{int(2*96/60*4)} -> ~{int(2*156/60*4)})")
check(abs(slow_len - (60.0 / 96.0 / 4.0) * m.SAMPLE_RATE) < 1.0,
      f"and the step length matches the tempo arithmetic exactly "
      f"({slow_len:.1f} frames at 96 bpm)")
check(abs(fast_engine.step_frames() - (60.0 / 156.0 / 4.0) * m.SAMPLE_RATE) < 1.0,
      "at 156 bpm too")

# Density and intensity are monotone by construction: raising them can only
# add onsets, never reroll the bar. Check that over many bars, not just one.
move("density", 0.0)
low_d = sum(m.bar_onset_count(deck.state, b) for b in range(16))
move("density", 1.0)
high_d = sum(m.bar_onset_count(deck.state, b) for b in range(16))
check(high_d > low_d, f"DENSITY adds hits ({low_d} -> {high_d} onsets over 16 bars)")
prev, monotone = -1, True
for value in (0.0, 0.2, 0.4, 0.6, 0.8, 1.0):
    move("density", value)
    total = sum(m.bar_onset_count(deck.state, b) for b in range(16))
    monotone = monotone and total >= prev
    prev = total
check(monotone, "and it is monotone — turning it up never removes a hit")

move("intensity", 0.0)
low_i = sum(m.bar_onset_count(deck.state, b) for b in range(16))
move("intensity", 1.0)
high_i = sum(m.bar_onset_count(deck.state, b) for b in range(16))
check(high_i > low_i, f"INTENSITY adds hits ({low_i} -> {high_i} onsets over 16 bars)")

# A total onset count is too coarse: each knob drives SEVERAL voices, so
# breaking one of them still leaves the total rising. Mutation testing caught
# exactly that (density stopped driving hats, intensity stopped driving open
# hats, and both aggregate assertions stayed green). Count per voice.
def voice_counts(bars=16):
    counts = {}
    for bar in range(bars):
        for onset in m.plan_bar(deck.state, bar):
            key = "bass" if onset.voice.startswith("bass") else (
                  "stab" if onset.voice.startswith("stab") else onset.voice)
            counts[key] = counts.get(key, 0) + 1
    return counts

move("density", 0.0); move("intensity", 0.5)
d_low = voice_counts()
move("density", 1.0)
d_high = voice_counts()
check(d_high.get("chat", 0) > d_low.get("chat", 0),
      f"DENSITY drives the closed hats specifically "
      f"({d_low.get('chat', 0)} -> {d_high.get('chat', 0)})")
check(d_high.get("bass", 0) > d_low.get("bass", 0),
      f"DENSITY drives the bassline specifically "
      f"({d_low.get('bass', 0)} -> {d_high.get('bass', 0)})")
check(d_high.get("kick", 0) > d_low.get("kick", 0),
      f"DENSITY adds ghost kicks at the top of its range "
      f"({d_low.get('kick', 0)} -> {d_high.get('kick', 0)})")

move("density", 0.5); move("intensity", 0.0)
i_low = voice_counts()
move("intensity", 1.0)
i_high = voice_counts()
check(i_high.get("ohat", 0) > i_low.get("ohat", 0),
      f"INTENSITY drives the open hats specifically "
      f"({i_low.get('ohat', 0)} -> {i_high.get('ohat', 0)})")
check(i_high.get("clap", 0) > i_low.get("clap", 0),
      f"INTENSITY drives the claps specifically "
      f"({i_low.get('clap', 0)} -> {i_high.get('clap', 0)})")
check(i_high.get("stab", 0) > i_low.get("stab", 0),
      f"INTENSITY drives the stabs specifically "
      f"({i_low.get('stab', 0)} -> {i_high.get('stab', 0)})")
move("density", 0.5); move("intensity", 0.5)

# -- a knob moved MID-PLAY must reach the running engine --------------------
# Every check above rebuilt the engine from scratch, so it could not tell a
# live parameter from one that only applies on restart. A fader on a DJ deck
# is useless if you have to stop the music to hear it.
live = m.SynthEngine(deck.state, guard)
move("cutoff", 0.15)
live.ensure_bank()
dark_key = live._bank_key
dark_block = live.render_seconds(0.5)
move("cutoff", 0.95)
check(live.ensure_bank() is True,
      "turning FILTER re-synthesizes the voice bank of an ALREADY-RUNNING engine")
check(live._bank_key != dark_key, "and the bank identity actually changed")
bright_block = live.render_seconds(0.5)
check(m.brightness(bright_block) > m.brightness(dark_block) * 1.5,
      f"and the running engine gets brighter without a restart "
      f"({m.brightness(dark_block):.0f} -> {m.brightness(bright_block):.0f})")
move("resonance", 0.1); live.ensure_bank(); res_key = live._bank_key
move("resonance", 0.9)
check(live.ensure_bank() is True and live._bank_key != res_key,
      "RESONANCE likewise re-synthesizes a running engine")
# ...and a knob that does NOT change the timbre must not pay for a rebuild.
move("density", 0.3); live.ensure_bank()
move("density", 0.9)
check(live.ensure_bank() is False,
      "but DENSITY does not — pattern knobs are free, no re-synthesis")
move("cutoff", 0.55); move("resonance", 0.45); move("density", 0.5)

# -- patterns are distinct --------------------------------------------------
rendered = {}
for name in m.PATTERNS:
    deck.state.pattern = name
    rendered[name] = render(2.0)[0].tobytes()
check(len(set(rendered.values())) == len(m.PATTERNS),
      f"all {len(m.PATTERNS)} patterns render differently")
deck.state.pattern = "driver"

# -- the deck's own safety surface ------------------------------------------
deck._tick()
check("OPEN" in deck.gate_lamp.get_text(), "the ALERT GATE lamp reads OPEN while clear")
m.request_duck(2.0, gate=work / "gate")
guard.poll()
deck._tick()
check("HELD" in deck.gate_lamp.get_text(),
      f"and flips to HELD the moment a cue takes the room ({deck.gate_lamp.get_text()!r})")

# -- stopping the deck turns the music off, and persists that ---------------
deck._stop()
check(deck.state.enabled is False, "pressing STOP disables the music")
check(m.load_config().enabled is False, "and that is what gets persisted to disk")

# -- optional: threat posture drives intensity, never volume ----------------
check(m.posture_intensity(work / "no-such-posture.json") is None,
      "an absent posture file yields no opinion")
# Assert the SHAPE of the posture mapping, not its literal values — reading
# POSTURE_INTENSITY back to check POSTURE_INTENSITY proves nothing, and a
# mutation that flattened tier 3 back down to tier 0 survived that version.
tiers = sorted(m.POSTURE_INTENSITY)
levels = [m.POSTURE_INTENSITY[t] for t in tiers]
check(all(b >= a for a, b in zip(levels, levels[1:])),
      f"posture -> intensity never decreases as the threat rises: {levels}")
check(levels[-1] >= levels[0] + 0.3,
      f"and the top tier is meaningfully busier than the bottom "
      f"({levels[0]} -> {levels[-1]})")
for tier, expected in zip(tiers, levels):
    (work / "posture.json").write_text('{"tier": %d}' % tier)
    got = m.posture_intensity(work / "posture.json")
    if got != expected:
        check(False, f"tier {tier} reads back as {got}, not {expected}")
        break
else:
    check(True, f"every tier {tiers} reads back from a real posture file")
(work / "posture.json").write_text('{"tier": 3}')
m.POSTURE_STATUS = work / "posture.json"
deck.state.follow_posture = True
deck.state.intensity, deck.state.volume = 0.1, 0.4
deck._tick()
check(abs(deck.state.intensity - m.POSTURE_INTENSITY[3]) < 1e-9,
      f"with follow-posture on, a tier-3 threat drives INTENSITY to "
      f"{deck.state.intensity}")
check(deck.state.volume == 0.4,
      "and leaves VOLUME alone — a rising threat makes the bed busier, never "
      "louder, because loudness is the resource R.A.I.N. needs")
deck.state.follow_posture = False
sys.exit(0 if ok else 1)
PY
then pass "DJ deck control assertions"; else fail "DJ deck control assertions" "see output above"; fi

section "CLI"
if python3 "$CLI" --help >/dev/null 2>&1; then pass "orionx-music --help works"; else fail "orionx-music --help works"; fi
RENDER_OUT="$(python3 "$CLI" render "$WORK/cli.wav" --seconds 2 --bpm 140 --pattern acid 2>&1)"
if [[ -f "$WORK/cli.wav" ]]; then pass "orionx-music render writes a WAV with no audio device"; else fail "orionx-music render writes a WAV" "$RENDER_OUT"; fi
if echo "$RENDER_OUT" | grep -q 'bpm=140 pattern=acid'; then pass "render honours the knob flags"; else fail "render honours the knob flags" "$RENDER_OUT"; fi
if python3 -c "
import sys, wave
w = wave.open(sys.argv[1], 'rb')
assert w.getnchannels() == 1 and w.getsampwidth() == 2, 'not mono 16-bit'
assert abs(w.getnframes()/w.getframerate() - 2.0) < 0.05, 'wrong length'
" "$WORK/cli.wav"; then pass "the rendered WAV is mono 16-bit and the requested length"; else fail "the rendered WAV is well-formed"; fi
# A duck fired mid-render must leave an audibly quieter file.
python3 "$CLI" render "$WORK/clean.wav" --seconds 6 >/dev/null 2>&1
python3 "$CLI" render "$WORK/ducked.wav" --seconds 6 --duck-at 1.0 --duck-for 3.0 >/dev/null 2>&1
if python3 - "$SYNTH" "$WORK/clean.wav" "$WORK/ducked.wav" <<'PY'
import sys, wave
from array import array
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("s", sys.argv[1]).load_module()
def load(p):
    with wave.open(p, "rb") as w:
        a = array("h"); a.frombytes(w.readframes(w.getnframes())); return a
clean, ducked = load(sys.argv[2]), load(sys.argv[3])
# Silent window: 1.0s .. 4.0s of the ducked render.
sr = m.SAMPLE_RATE
win = ducked[int(1.2 * sr):int(3.8 * sr)]
ref = clean[int(1.2 * sr):int(3.8 * sr)]
print(f"  clean window rms={m.rms(ref):.0f}  ducked window rms={m.rms(win):.0f}")
ok = m.rms(ref) > 200 and m.peak(win) == 0
print(("  ok   " if ok else "  BAD  ") + "the duck window is digitally silent in the rendered file")
sys.exit(0 if ok else 1)
PY
then pass "orionx-music render --duck-at produces a provably silent window"; else fail "orionx-music render --duck-at produces a silent window"; fi
DUCK_OUT="$(python3 "$CLI" duck --seconds 1.5 --gate "$WORK/clidguck" 2>&1)"
if [[ "$(cat "$WORK/clidguck" 2>/dev/null | tr -d '[:space:]')" == "1.500" ]]; then pass "orionx-music duck arms the gate with the requested duration"; else fail "orionx-music duck arms the gate" "$DUCK_OUT / $(cat "$WORK/clidguck" 2>/dev/null)"; fi
SET_OUT="$(python3 "$CLI" set bpm=999 volume=5 pattern=nonsense 2>&1)"
if echo "$SET_OUT" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
assert cfg['bpm'] == 160.0, cfg['bpm']
assert cfg['volume'] == 1.0, cfg['volume']
assert cfg['pattern'] == 'driver', cfg['pattern']
assert cfg['enabled'] is False, 'set must not enable the music'
"; then pass "orionx-music set clamps out-of-range input and never enables the music"; else fail "orionx-music set clamps input" "$SET_OUT"; fi

section "Build wiring"
if [[ -f "$HOOK" ]]; then pass "0702-orionx-music hook present"; else fail "0702-orionx-music hook present" "missing"; fi
if [[ -x "$HOOK" ]]; then pass "hook is executable"; else fail "hook is executable"; fi
if bash -n "$HOOK" 2>/dev/null; then pass "hook parses"; else fail "hook parses"; fi
if grep -q 'set -euo pipefail' "$HOOK"; then pass "hook fails loudly (set -euo pipefail)"; else fail "hook fails loudly"; fi
for name in orionx-music orionx-dj; do
  if grep -q "\[\"$name\"\]=" "$HOOK"; then pass "hook symlinks $name onto PATH"; else fail "hook symlinks $name onto PATH"; fi
done
# The hook must CHECK, not assume (rule 2): it imports the engine in the chroot.
if grep -q 'import orionx_synth' "$HOOK"; then pass "hook imports the engine inside the chroot (build-time check)"; else fail "hook imports the engine inside the chroot"; fi
if grep -q "DUCK_FLOOR == 0.0" "$HOOK"; then pass "hook fails the BUILD if the duck floor is not silence"; else fail "hook fails the build if the duck floor is not silence"; fi
if grep -q "enabled is False" "$HOOK"; then pass "hook fails the BUILD if music stops defaulting to off"; else fail "hook fails the build if music stops defaulting to off"; fi
if grep -q 'rain_lib' "$HOOK"; then pass "hook verifies the R.A.I.N. coupling the safety gate needs"; else fail "hook verifies the R.A.I.N. coupling"; fi
if grep -qE 'paplay|aplay' "$HOOK"; then pass "hook verifies a raw-PCM player exists"; else fail "hook verifies a raw-PCM player exists"; fi
if grep -q 'xdg/autostart' "$HOOK"; then pass "hook refuses to build if anything can autostart the music"; else fail "hook refuses to build if anything can autostart the music"; fi

DESKTOP="$CHROOT/usr/share/applications/orionx-dj.desktop"
if [[ -f "$DESKTOP" ]]; then pass "DJ Deck menu entry staged"; else fail "DJ Deck menu entry staged" "missing $DESKTOP"; fi
if grep -q '^Exec=/usr/bin/orionx-dj$' "$DESKTOP"; then pass "menu entry execs the PATH symlink the hook creates"; else fail "menu entry execs the PATH symlink"; fi
if grep -q 'Categories=X-Orion;' "$DESKTOP"; then pass "menu entry lands in the Orion menu"; else fail "menu entry lands in the Orion menu"; fi
if grep -qi 'R.A.I.N' "$DESKTOP"; then pass "menu entry tells the operator the music yields to alerts"; else fail "menu entry mentions R.A.I.N."; fi

TMPF="$CHROOT/usr/lib/tmpfiles.d/orionx-music.conf"
if [[ -f "$TMPF" ]]; then pass "duck-gate tmpfiles drop-in staged"; else fail "duck-gate tmpfiles drop-in staged" "missing $TMPF"; fi
if grep -qE '^f /run/orionx/music-duck 0666' "$TMPF"; then pass "gate is pre-created 0666 so any uid can duck the music"; else fail "gate is pre-created 0666"; fi
if grep -q 'DEC-PHASE11-022' "$TMPF"; then pass "drop-in explains why it is separate from orionx.conf"; else fail "drop-in explains why it is separate"; fi
if grep -q 'music-duck' "$CHROOT/usr/lib/tmpfiles.d/orionx.conf"; then fail "the shared tmpfiles authority was not edited" "orionx.conf now mentions music-duck"; else pass "the shared tmpfiles authority (orionx.conf) was left alone"; fi
if python3 -c "
import sys
sys.path.insert(0, '$MUSIC_DIR')
import orionx_synth as s
raise SystemExit(0 if str(s.DUCK_GATE) == '/run/orionx/music-duck' else 1)
"; then pass "the engine and tmpfiles.d agree on the gate path"; else fail "the engine and tmpfiles.d agree on the gate path"; fi

PKGS="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
for pkg in pulseaudio-utils alsa-utils python3-gi gir1.2-gtk-3.0; do
  if grep -qE "^${pkg}\$" "$PKGS"; then pass "$pkg already in the image (no new dependency for music)"; else fail "$pkg present in the package list"; fi
done
if grep -qiE "^(sox|ffmpeg|python3-sounddevice|python3-pyaudio|supercollider|csound|pd)\$" "$PKGS"; then
  fail "no heavy audio dependency was added" "a synthesis package appeared in the package list"
else pass "no heavy audio dependency was added for the music"; fi

# ===========================================================================
# The lead-duck: rain_lib.play_cue() arms the gate BEFORE it makes a sound.
#
# The bus watcher in orionx_synth already ducks reactively, so every assertion
# above this point stays green with the lead-duck completely dead -- verified
# by mutation (neutering duck_music() left all 136 assertions passing). This
# section is the only thing standing between that hook and silent rot.
#
# Ordering is the whole claim. A gate armed AFTER the tone starts is a gate
# that does nothing, so the probe records what the gate held at the instant
# the first audio command was issued, not merely that it ended up armed.
# ===========================================================================
section "Lead-duck — play_cue arms the gate before the first sound"

DUCK_TMP="$(mktemp -d)"
trap 'rm -rf "$DUCK_TMP"' EXIT
DUCK_JSON="$(cd "$REPO_ROOT" && python3 tests/fixtures/rain/duck_probe.py "$DUCK_TMP" 2>"$DUCK_TMP/err")" || true

if [[ -z "$DUCK_JSON" ]]; then
  fail "duck probe runs" "$(cat "$DUCK_TMP/err")"
else
  pass "duck probe runs"
  dq() { printf '%s' "$DUCK_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

  # A 2.0s tone + 0.6s tail = 2.600. Measured from the WAV, not guessed.
  if [[ "$(dq '["gate_at_first_audio"]')" == "2.600" ]]; then
    pass "gate already held 2.600s when the tone command was issued"
  else
    fail "gate armed before the tone" "gate read '$(dq '["gate_at_first_audio"]')' at first audio call, want 2.600"
  fi

  # The duration must come from the file, so a longer cue ducks longer.
  if [[ "$(dq '["tone_duck"]')" == "2.6" ]]; then
    pass "duck length is measured from the cue WAV, not a constant"
  else
    fail "duck length is measured" "got $(dq '["tone_duck"]'), want 2.6 for a 2.0s tone"
  fi

  # cfg['voice'] adds an espeak phrase after the tone: 2.6 + 2.5 = 5.1.
  if [[ "$(dq '["voice_duck"]')" == "5.1" ]] && [[ "$(dq '["gate_at_first_audio_voice"]')" == "5.100" ]]; then
    pass "the espeak voice cue extends the hold, and does so before the tone"
  else
    fail "voice extends the hold" "duck=$(dq '["voice_duck"]') at-first-audio=$(dq '["gate_at_first_audio_voice"]'), want 5.1 / 5.100"
  fi

  # With no tone file, espeak is the FIRST sound. The gate must already be
  # armed -- this is why duck_music() sits above `if tone.is_file():`.
  if [[ "$(dq '["notone_audio_calls"]')" == "['espeak-ng']" ]] \
     && [[ "$(dq '["notone_gate_at_first_audio"]')" == "4.000" ]]; then
    pass "with no tone file, the gate is armed before espeak — the only sound"
  else
    fail "gate armed before espeak when the tone file is missing" \
         "calls=$(dq '["notone_audio_calls"]') gate=$(dq '["notone_gate_at_first_audio"]')"
  fi

  # R.A.I.N. must never fail because an accessory's gate is unwritable.
  if [[ "$(dq '["raises"]')" == "[]" ]]; then
    pass "duck_music never raises — bad path, /proc, None, NaN, negative"
  else
    fail "duck_music never raises" "$(dq '["raises"]')"
  fi

  # ftruncate, not append: a stale longer value must not survive. The byte
  # count is the real assertion -- the gate was pre-loaded with "99.000" plus
  # 400 bytes of junk, and an append-only write would leave all of it there.
  if [[ "$(dq '["after_overwrite"]')" == "1.500" ]] \
     && [[ "$(dq '["after_overwrite_bytes"]')" == "6" ]]; then
    pass "the gate write truncates — no stale duration survives a shorter duck"
  else
    fail "the gate write truncates" \
         "gate holds '$(dq '["after_overwrite"]')' in $(dq '["after_overwrite_bytes"]') bytes, want '1.500' in 6"
  fi
fi

# The narrator (DEC-PHASE12-046) runs on a worker thread, so its line length
# is not predictable from the event. It must arm the gate itself.
if grep -q 'rain_lib.duck_music' "$REPO_ROOT/scripts/rain/rain_speech.py"; then
  pass "the narrator arms the gate before speaking"
else
  fail "the narrator arms the gate before speaking" \
       "rain_speech.py does not call duck_music; spoken narration would play over the music"
fi

# Ducking is a safety decision, so it must not be reachable from play_cue's
# own error handling -- a cue that cannot measure its WAV still ducks.
if (cd "$REPO_ROOT" && python3 -c "
import inspect, sys
sys.path.insert(0, 'scripts/rain')
import rain_lib
src = inspect.getsource(rain_lib.play_cue)
body = src.split(chr(10))
duck = next(i for i, l in enumerate(body) if 'duck_music' in l)
sound = next(i for i, l in enumerate(body) if 'is_file()' in l)
raise SystemExit(0 if duck < sound else 1)
"); then
  pass "duck_music() precedes every playback branch in play_cue's source"
else
  fail "duck_music() precedes every playback branch" "a sound path was found above the duck"
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
