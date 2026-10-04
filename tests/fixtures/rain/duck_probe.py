"""Does play_cue() arm the duck gate BEFORE it makes a sound?

Ordering is the whole point of DEC-PHASE12-044's lead-duck: a gate armed
after the tone has already started is a gate that does nothing. So this
does not check that the gate ends up armed -- it checks what the gate
held at the instant the first audio command was issued.
"""
import json
import pathlib
import sys
import wave

sys.path.insert(0, "scripts/rain")
import rain_lib  # noqa: E402

TMP = pathlib.Path(sys.argv[1])
TMP.mkdir(parents=True, exist_ok=True)
gate = TMP / "music-duck"
rain_lib.MUSIC_DUCK_GATE = gate

tone_dir = TMP / "tones"
tone_dir.mkdir(exist_ok=True)
# A 2.0s tone at 22050Hz, so the measured airtime is a number we know.
tone = tone_dir / "critical.wav"
with wave.open(str(tone), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(22050)
    w.writeframes(b"\x00\x00" * 44100)
rain_lib.TONE_DIR = tone_dir

seen = []


def fake_run(cmd):
    seen.append((cmd[0], gate.read_text().strip() if gate.exists() else None))
    return True


rain_lib._run = fake_run
rain_lib.shutil.which = lambda n: "/usr/bin/" + n

out = {}

# --- the tone path -------------------------------------------------------
gate.write_text("")
cfg = dict(rain_lib.default_config(), voice=False, volume=0.8)
rain_lib.play_cue("critical", cfg)
out["audio_calls"] = [c for c, _ in seen]
out["gate_at_first_audio"] = seen[0][1] if seen else None
out["tone_duck"] = float(gate.read_text().strip())

# --- voice extends the hold ---------------------------------------------
seen.clear()
gate.write_text("")
rain_lib.play_cue("critical", dict(cfg, voice=True))
out["voice_duck"] = float(gate.read_text().strip())
out["gate_at_first_audio_voice"] = seen[0][1] if seen else None

# --- no tone file at all, voice on: espeak still makes noise, so the
#     gate must STILL be armed before it (the bug the one-liner's
#     placement was chosen to avoid).
seen.clear()
gate.write_text("")
rain_lib.TONE_DIR = TMP / "nonexistent"
rain_lib.play_cue("critical", dict(cfg, voice=True))
out["notone_audio_calls"] = [c for c, _ in seen]
out["notone_gate_at_first_audio"] = seen[0][1] if seen else None
rain_lib.TONE_DIR = tone_dir

# --- duck_music must never raise, whatever the gate is ------------------
errors = []
for bad in (TMP / "no" / "such" / "dir" / "gate", pathlib.Path("/proc/1/mem")):
    rain_lib.MUSIC_DUCK_GATE = bad
    try:
        rain_lib.duck_music(3.0)
    except Exception as exc:                            # noqa: BLE001
        errors.append(f"{bad}: {exc!r}")
rain_lib.MUSIC_DUCK_GATE = gate
for junk in (None, "abc", float("nan"), -5.0):
    try:
        rain_lib.duck_music(junk)
    except Exception as exc:                            # noqa: BLE001
        errors.append(f"{junk!r}: {exc!r}")
out["raises"] = errors

# --- the write must be truncating, not appending ------------------------
gate.write_text("99.000\n" + "x" * 400)
rain_lib.duck_music(1.5)
raw = gate.read_text()
# Reported as value + byte count because $(...) strips trailing newlines,
# so a shell comparison cannot see the difference between a clean 6-byte
# write and one with 400 bytes of stale junk after it.
out["after_overwrite"] = raw.strip()
out["after_overwrite_bytes"] = len(raw)

print(json.dumps(out))
