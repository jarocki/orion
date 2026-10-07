#!/usr/bin/env bash
# test_bus_reader.sh — the one event-bus reader, rain_lib.BusTail (DEC-PHASE12-083).
#
# QA round 1, python P1-4 / P1-6: orionx-rain died when the bus file was
# deleted, and every reader dropped a line it read before the newline arrived.
# Everything here EXECUTES the real code: the class, the orionx-rain daemon
# loop (in-process, audio stubbed) and the orionx-heald daemon (subprocess).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/bus-reader.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

echo "[rain_lib.BusTail: partial lines, deletion, rotation, truncation]"
if python3 - "$ROOT/scripts/rain" "$TMP/a" <<'PY'
import sys, os, json, pathlib
sys.path.insert(0, sys.argv[1]); import rain_lib as rl
d = pathlib.Path(sys.argv[2]); d.mkdir()
bus = d / "events.jsonl"
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
def ev(n): return json.dumps({"severity": "critical", "source": "t", "category": "ids", "message": f"m{n}"})
t = rl.BusTail(bus, at_end=True)
ck(t.poll() == [], "absent bus: [] and no exception")
bus.write_text(ev(0) + "\n")                       # appeared after we started: read in full
ck([e["message"] for e in t.poll_events()] == ["m0"], "a bus that appears later is read from its top")
with bus.open("a") as fh: fh.write(ev(1)[:20]); fh.flush()
ck(t.poll() == [], "half-written line is held, not parsed")
with bus.open("a") as fh: fh.write(ev(1)[20:] + "\n")
ck([e["message"] for e in t.poll_events()] == ["m1"], "the completed line is delivered (P1-6)")
bus.unlink()
ck(t.poll() == [] and t.poll() == [], "bus deleted: polling keeps working (P1-4)")
bus.write_text(ev(2) + "\n")
ck([e["message"] for e in t.poll_events()] == ["m2"], "recreated bus is followed from its top")
with bus.open("a") as fh: fh.write(ev(3) + "\n")
os.rename(bus, d / "old.jsonl")
with (d / "old.jsonl").open("a") as fh: fh.write(ev(4) + "\n")
bus.write_text(ev(5) + "\n")
ck([e["message"] for e in t.poll_events()] == ["m3", "m4", "m5"], "rotation: old file drained, new one read")
bus.write_text("")
ck(t.poll() == [], "truncated bus seen as a shrink (a shrink is only detectable while it is smaller)")
with bus.open("a") as fh: fh.write(ev(6) + "\n")
ck([e["message"] for e in t.poll_events()] == ["m6"], "truncation in place: read from the top")
pre = d / "pre.jsonl"; pre.write_text(ev(7) + "\n")
t2 = rl.BusTail(pre, at_end=True); t2.poll()
with pre.open("a") as fh: fh.write(ev(8) + "\n")
ck([e["message"] for e in t2.poll_events()] == ["m8"], "an existing bus is joined at EOF (no history replay)")
t2.rewind()
ck([e["message"] for e in t2.poll_events()] == ["m7", "m8"], "rewind() reads from the start (one-shot modes)")
PY
then pass "BusTail semantics"; else fail "BusTail semantics" "see output above"; fi

echo "[orionx-rain daemon: survives deletion, hears a line written in two parts]"
cat > "$TMP/rain_harness.py" <<'PYEOF'
import json, sys, threading, time
from importlib.machinery import SourceFileLoader
from pathlib import Path
root, work = Path(sys.argv[1]), Path(sys.argv[2]); work.mkdir()
rl = SourceFileLoader("rain_lib", str(root / "scripts/rain/rain_lib.py")).load_module()
sys.modules["rain_lib"] = rl
rl.EVENT_LOG = work / "events.jsonl"; rl.CONFIG_FILE = work / "rain.json"
rl.CONFIG_FILE.write_text(json.dumps({"enabled": True, "min_severity": "warning", "speech": False}))
rl.GLOBAL_MIN_GAP_SECONDS = 0.0
rl.COOLDOWN_SECONDS = {}
cues = []
rl.play_cue = lambda sev, cfg=None: (cues.append(sev), True)[1]
rain = SourceFileLoader("orionx_rain", str(root / "scripts/rain/orionx-rain")).load_module()
rain._POLL = 0.05
rain.rain_lib.COOLDOWN_SECONDS = {"critical": 0.0, "warning": 0.0}
res = {}
def line(n): return json.dumps({"severity": "critical", "source": "t", "category": "ids", "message": f"m{n}"}) + "\n"
def wait_cues(n, limit=3.0):
    end = time.monotonic() + limit
    while time.monotonic() < end and len(cues) < n: time.sleep(0.02)
    return len(cues)
def driver():
    time.sleep(0.3)
    with rl.EVENT_LOG.open("a") as fh: fh.write(line(1))
    res["first"] = wait_cues(1)
    rl.EVENT_LOG.unlink(); time.sleep(0.3)
    res["alive_after_unlink"] = "exc" not in err
    with rl.EVENT_LOG.open("a") as fh: fh.write(line(2))
    res["after_recreate"] = wait_cues(2)
    l3 = line(3)
    with rl.EVENT_LOG.open("a") as fh: fh.write(l3[:15]); fh.flush()
    time.sleep(0.4)
    with rl.EVENT_LOG.open("a") as fh: fh.write(l3[15:])
    res["after_partial"] = wait_cues(3)
    rain._running = False
rl.EVENT_LOG.write_text("")
err = {}
def target():
    try: rain.run_daemon()
    except BaseException as e: err["exc"] = repr(e)
d = threading.Thread(target=driver, daemon=True); d.start()
target()                                   # signal handlers need the main thread
d.join(5)
res["exc"] = err.get("exc"); res["cues"] = len(cues)
print(json.dumps(res))
PYEOF
OUT="$(python3 "$TMP/rain_harness.py" "$ROOT" "$TMP/rain" 2>&1 | tail -1)"
echo "    measured: $OUT"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r["alive_after_unlink"] and r["exc"] is None else 1)' "$OUT" 2>/dev/null \
  && pass "orionx-rain is still running after the bus file is deleted (P1-4)" || fail "rain survives unlink" "$OUT"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r["after_recreate"] >= 2 else 1)' "$OUT" 2>/dev/null \
  && pass "an event on the recreated bus is heard" || fail "event after recreate" "$OUT"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if r["after_partial"] >= 3 else 1)' "$OUT" 2>/dev/null \
  && pass "an event written in two parts is heard (P1-6)" || fail "partial line heard" "$OUT"

echo "[orionx-heald daemon: joins at EOF, acts on a line written in two parts]"
B="$TMP/heald"; mkdir -p "$B"
echo '{"ts":1,"severity":"critical","source":"firewall","category":"scan","message":"port scan from 203.0.113.1 - 60 ports"}' > "$B/bus.jsonl"
echo '{"block_ip": "propose"}' > "$B/autonomy.json"
ORIONX_AUTONOMY_FILE="$B/autonomy.json" ORIONX_HEALING_STATE="$B/state" ORIONX_HEALING_STATUS="$B/healing-status.json" \
  python3 "$ROOT/scripts/healing/orionx-heald" -v --dry-run --no-reconcile --bus "$B/bus.jsonl" --state-dir "$B/state" > "$B/out.txt" 2>&1 &
HP=$!
sleep 1.5
L='{"ts":2,"severity":"critical","source":"firewall","category":"scan","message":"port scan from 203.0.113.2 - 60 ports"}'
printf '%s' "${L:0:30}" >> "$B/bus.jsonl"; sleep 1.5; printf '%s\n' "${L:30}" >> "$B/bus.jsonl"; sleep 2
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
grep -q 'PROPOSE block_ip 203.0.113.2' "$B/out.txt" && pass "heald acted on the event written in two parts" || fail "heald partial line" "$(tail -5 "$B/out.txt")"
grep -q '203.0.113.1' "$B/out.txt" && fail "heald replayed history" "$(grep 203.0.113.1 "$B/out.txt" | head -2)" || pass "heald joined the bus at EOF (history not re-acted)"

echo "==========================================="; echo "Results: $PASS passed, $FAIL failed"; echo "==========================================="
[[ $FAIL -eq 0 ]]
