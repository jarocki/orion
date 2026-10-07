#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_rain.sh — R.A.I.N. (Real-time Audible Intrusion Notification, #88)
#
# Covers the event bus (rain_lib), the orionx-event emitter, the orionx-rain
# daemon logic (gate + throttle), and the system wiring (tones, autostart,
# tmpfiles, PATH symlinks, packages, Control Center integration).
# @decision DEC-PHASE11-045
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

RAIN_DIR="$REPO_ROOT/scripts/rain"
CHROOT="$REPO_ROOT/iso/config/includes.chroot"

# ---------------------------------------------------------------------------
section "Structure: scripts + assets present and wired"
# ---------------------------------------------------------------------------
for f in rain_lib.py orionx-event orionx-rain; do
    if [[ -f "$RAIN_DIR/$f" ]]; then pass "$f present"; else fail "$f present" "missing"; fi
done
for f in orionx-event orionx-rain; do
    if [[ -x "$RAIN_DIR/$f" ]]; then pass "$f is executable"; else fail "$f is executable" "not +x"; fi
    if head -1 "$RAIN_DIR/$f" | grep -q "python3"; then pass "$f has python3 shebang"; else fail "$f python3 shebang"; fi
done

for sev in info notice warning critical; do
    w="$CHROOT/usr/share/orionx/rain/$sev.wav"
    if [[ -f "$w" ]]; then pass "tone $sev.wav staged"; else fail "tone $sev.wav staged" "missing"; fi
done

AUTOSTART="$CHROOT/etc/xdg/autostart/orionx-rain.desktop"
if [[ -f "$AUTOSTART" ]] && grep -q "^Exec=orionx-rain" "$AUTOSTART"; then
    pass "autostart .desktop launches orionx-rain"
else
    fail "autostart .desktop launches orionx-rain" "missing or wrong Exec"
fi

TMPFILES="$CHROOT/usr/lib/tmpfiles.d/orionx.conf"
if grep -qE "^f /run/orionx/events\.jsonl 0666" "$TMPFILES"; then
    pass "tmpfiles creates the event bus (events.jsonl 0666)"
else
    fail "tmpfiles creates the event bus" "events.jsonl entry missing"
fi

HOOK="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
for name in orionx-event orionx-rain; do
    if grep -qE "\[\"$name\"\]=\"/opt/orionx/scripts/rain/$name\"" "$HOOK"; then
        pass "SCRIPT_MAP symlinks $name into PATH"
    else
        fail "SCRIPT_MAP symlinks $name" "entry missing in 0700 hook"
    fi
done

PKGS="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
for p in pulseaudio-utils alsa-utils; do
    if grep -qE "^$p$" "$PKGS"; then pass "package $p declared (audio playback)"; else fail "package $p declared" "missing"; fi
done

if grep -q "DEC-PHASE11-045" "$RAIN_DIR/rain_lib.py"; then
    pass "DEC-PHASE11-045 annotation present in rain_lib.py"
else
    fail "DEC-PHASE11-045 annotation present" "missing"
fi

# ---------------------------------------------------------------------------
section "Control Center: Awareness emits + exposes R.A.I.N."
# ---------------------------------------------------------------------------
AW="$REPO_ROOT/scripts/control_center/sections/awareness.py"
if grep -q '"orionx-event"' "$AW"; then
    pass "awareness.py emits events via the orionx-event CLI (allowlist-safe)"
else
    fail "awareness.py emits via orionx-event" "no orionx-event Popen found"
fi
if grep -q "rain.json" "$AW" && grep -q "_build_rain_controls" "$AW"; then
    pass "awareness.py builds R.A.I.N. controls + persists rain.json"
else
    fail "awareness.py R.A.I.N. controls" "missing controls or config path"
fi
# rain.json has ONE writer: awareness.py saves through rain_lib.save_config (python P2-5)
if grep -q "rain_lib.save_config(" "$AW" && ! grep -qE "open\([^)]*rain\.json[^)]*['\"]w" "$AW"; then
    pass "awareness.py writes rain.json only through rain_lib.save_config"
else
    fail "rain.json single writer" "awareness.py writes rain.json itself"
fi

# ---------------------------------------------------------------------------
section "Logic: severity model, emit, config, gate, throttle"
# ---------------------------------------------------------------------------
if python3 - "$RAIN_DIR" <<'PY'
import sys, tempfile, os, json, time
from pathlib import Path
from importlib.machinery import SourceFileLoader
rain_dir = sys.argv[1]
sys.path.insert(0, rain_dir)
import rain_lib

# severity ordering
assert rain_lib.severity_rank("critical") > rain_lib.severity_rank("warning") \
    > rain_lib.severity_rank("notice") > rain_lib.severity_rank("info"), "severity order"
assert rain_lib.severity_rank("bogus") == -1
assert rain_lib.normalize_severity("CRITICAL ") == "critical"
assert rain_lib.normalize_severity("nope") == "notice"

# emit → valid JSON with required fields, atomic append
tmp = Path(tempfile.mktemp(suffix=".jsonl")); rain_lib.EVENT_LOG = tmp
assert rain_lib.emit_event("critical", "suricata", "ids", "scan from 10.0.0.5")
assert rain_lib.emit_event("info", "health", "service", "ok")
rows = [json.loads(l) for l in tmp.read_text().splitlines() if l.strip()]
assert len(rows) == 2, rows
for k in ("ts","iso","severity","source","category","message"):
    assert k in rows[0], f"missing field {k}"
assert rows[0]["severity"] == "critical" and rows[0]["source"] == "suricata"
tmp.unlink()

# config defaults + clamp
cfg = rain_lib.default_config()
assert cfg["enabled"] and cfg["min_severity"] == "warning"
cfgf = Path(tempfile.mktemp(suffix=".json")); rain_lib.CONFIG_FILE = cfgf
cfgf.write_text('{"volume": 5, "min_severity": "bogus", "enabled": false}')
c = rain_lib.load_config()
assert c["volume"] == 1.0, "volume clamp"          # 5 -> clamped to 1.0
assert c["min_severity"] == "warning", "bad severity -> default"
assert c["enabled"] is False
assert rain_lib.save_config({"enabled": True, "min_severity": "critical", "volume": 0.3, "voice": True})
c2 = rain_lib.load_config()
assert c2["min_severity"] == "critical" and c2["volume"] == 0.3 and c2["voice"] is True
cfgf.unlink()

# play_cue must never raise even with no audio device / missing tone
assert rain_lib.play_cue("warning", cfg) in (True, False)

# daemon gate + throttle
mod = SourceFileLoader("orx_rain", os.path.join(rain_dir, "orionx-rain")).load_module()
assert mod._parse('{"severity":"warning"}')["severity"] == "warning"
assert mod._parse("not json") is None and mod._parse("") is None
assert mod._should_play({"severity":"critical"}, {"enabled":True,"min_severity":"warning"})
assert not mod._should_play({"severity":"info"}, {"enabled":True,"min_severity":"warning"})
assert not mod._should_play({"severity":"critical"}, {"enabled":False,"min_severity":"warning"})
t = mod._Throttle(); now = 1000.0
assert t.allow("critical", now); t.record("critical", now)
assert not t.allow("critical", now+0.1)     # global min gap
assert not t.allow("critical", now+2.0)     # still in 3s cooldown
assert t.allow("critical", now+3.1)         # cooldown elapsed
print("LOGIC_OK")
PY
then
    pass "rain_lib + daemon logic (severity/emit/config/gate/throttle) all correct"
else
    fail "rain_lib + daemon logic" "python logic assertions failed (see above)"
fi

# ---------------------------------------------------------------------------
printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
