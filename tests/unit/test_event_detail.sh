#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_event_detail.sh — structured event detail + Cockpit drill-down
# (DEC-PHASE12-029)
#
# The bus carried only a flat message string, so the Cockpit could say "port
# scan from 192.168.4.77" and nothing more. Drill-down needs the evidence to
# exist on the bus first.
#
# The constraint that shapes everything here: appends to the O_APPEND bus are
# atomic only below PIPE_BUF (4096 on Linux), and there are many concurrent
# emitters. A fat detail payload would let two of them interleave and corrupt
# the record exactly when it matters most. So the tests below care as much
# about what detail must NOT do as what it must.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

section "Bus schema: detail is bounded and never corrupts the log"
if python3 - "$REPO_ROOT" <<'PY'
import sys, json, tempfile, pathlib
from importlib.machinery import SourceFileLoader
root = pathlib.Path(sys.argv[1])
ok = True
def ck(c, label):
    global ok
    print(("  ok   " if c else "  BAD  ") + label); ok = ok and bool(c)

rl = SourceFileLoader("rain_lib", str(root/"scripts/rain/rain_lib.py")).load_module()
td = pathlib.Path(tempfile.mkdtemp(dir=str(root/"tmp")))
rl.EVENT_LOG = td/"events.jsonl"; rl.DETAIL_DIR = td/"details"

# Backward compatibility is non-negotiable: every existing emitter calls the
# 4-arg form and every existing consumer reads these six keys.
rl.emit_event("notice", "cli", "general", "Hello World")
e = json.loads(rl.EVENT_LOG.read_text().splitlines()[0])
ck(sorted(e) == ["category","iso","message","severity","source","ts"],
   f"no-detail event keeps the original six keys -> {sorted(e)}")

rl.emit_event("critical","firewall","scan","port scan",
              detail={"src_ip":"192.168.4.77","signature":"ET SCAN Nmap","sid":2009582})
e2 = json.loads(rl.EVENT_LOG.read_text().splitlines()[1])
ck(e2["detail"]["src_ip"] == "192.168.4.77", "small detail rides inline")
ck(bool(e2.get("id")), "detail-bearing event gets an id for sidecar correlation")

# The load-bearing test: a huge payload must not break line atomicity.
big = "de:ad:be:ef " * 8000
rl.emit_event("critical","zeek","alert","suspicious payload",
              detail={"src_ip":"10.0.0.9","packet_hex":big,"signature":"X"})
line = rl.EVENT_LOG.read_text().splitlines()[2]
size = len(line.encode()) + 1
ck(size < 4096, f"96KB payload still yields an atomically-appendable line ({size} bytes)")
e3 = json.loads(line)
ck("_full" in e3["detail"], "oversized detail spills to a sidecar reference")
full = json.loads(pathlib.Path(e3["detail"]["_full"]).read_text())
ck(len(full["packet_hex"]) == len(big), "sidecar preserves the payload in full")
ck(e3["detail"]["packet_hex"].endswith("…"),
   "inline value is visibly truncated, not silently cut")
ck(e3["detail"]["src_ip"] == "10.0.0.9", "small fields survive alongside a spilled one")

# Many oversized keys at once must still fit.
rl.emit_event("critical","zeek","alert","many blobs",
              detail={f"blob{i}": "x"*9000 for i in range(12)})
line4 = rl.EVENT_LOG.read_text().splitlines()[3]
ck(len(line4.encode())+1 < 4096, f"twelve oversized keys still fit ({len(line4.encode())+1} bytes)")

# A non-dict detail must not explode.
try:
    rl.emit_event("notice","cli","general","bad detail", detail="not-a-dict")
    ck(True, "non-dict detail is ignored rather than raising")
except Exception as exc:
    ck(False, f"non-dict detail raised {exc!r}")
sys.exit(0 if ok else 1)
PY
then pass "bus schema assertions"; else fail "bus schema assertions" "see above"; fi

section "orionx-event --detail"
if python3 - "$REPO_ROOT" <<'PY'
import sys, json, tempfile, pathlib
from importlib.machinery import SourceFileLoader
root = pathlib.Path(sys.argv[1]); ok = True
def ck(c, label):
    global ok
    print(("  ok   " if c else "  BAD  ") + label); ok = ok and bool(c)
rl = SourceFileLoader("rain_lib", str(root/"scripts/rain/rain_lib.py")).load_module()
td = pathlib.Path(tempfile.mkdtemp(dir=str(root/"tmp")))
rl.EVENT_LOG = td/"events.jsonl"; rl.DETAIL_DIR = td/"details"
sys.modules["rain_lib"] = rl
cli = SourceFileLoader("orionx_event", str(root/"scripts/rain/orionx-event")).load_module()

ck(cli.main(["--severity","critical","--source","firewall","--category","scan",
             "--detail",'{"src_ip":"1.2.3.4","signature":"S"}',"scan"]) == 0,
   "valid --detail accepted")
e = json.loads(rl.EVENT_LOG.read_text().splitlines()[0])
ck(e["detail"]["src_ip"] == "1.2.3.4", "detail round-trips through the CLI")
ck(cli.main(["--detail","{not json","x"]) == 2, "malformed JSON rejected with exit 2")
ck(cli.main(["--detail",'["a"]',"x"]) == 2, "JSON array rejected (must be an object)")
ck(cli.main(["plain"]) == 0, "omitting --detail still works")
ck("detail" not in json.loads(rl.EVENT_LOG.read_text().splitlines()[1]),
   "event without --detail carries no detail key")
sys.exit(0 if ok else 1)
PY
then pass "CLI assertions"; else fail "CLI assertions" "see above"; fi

section "Producers publish evidence"
if python3 - "$REPO_ROOT" <<'PY'
import sys, pathlib
from importlib.machinery import SourceFileLoader
root = pathlib.Path(sys.argv[1]); ok = True
def ck(c, label):
    global ok
    print(("  ok   " if c else "  BAD  ") + label); ok = ok and bool(c)
sw = SourceFileLoader("sw", str(root/"scripts/rain/orionx-scanwatch")).load_module()
t = sw.ScanTracker()
alert = None
for i in range(40):
    a = t.observe(1000.0 + i/4.3, "192.168.4.77", 20+i, "tcp")
    if a: alert = a
ck(alert is not None, "scan alert produced")
d = sw.build_detail(alert)
for k in ("src_ip","distinct_ports","protocols","detector","evidence","triggering_rule"):
    ck(k in d, f"scan detail carries {k}")
ck(d["src_ip"] == "192.168.4.77", "detail names the actual source IP")
ck("ORIONX-DROP" in d["triggering_rule"], "detail names the nftables rule that produced the evidence")
ck(isinstance(d.get("ports_seen"), list) and d["ports_seen"], "detail lists the ports observed")
ck(len(d["ports_seen"]) <= 64, "port list is bounded")
sys.exit(0 if ok else 1)
PY
then pass "producer evidence assertions"; else fail "producer evidence assertions" "see above"; fi

section "Cockpit: actions readers + drill-down wiring"
if python3 - "$REPO_ROOT" <<'PY'
import sys, pathlib, json, tempfile
from importlib.machinery import SourceFileLoader
root = pathlib.Path(sys.argv[1]); ok = True
def ck(c, label):
    global ok
    print(("  ok   " if c else "  BAD  ") + label); ok = ok and bool(c)
cl = SourceFileLoader("cl", str(root/"scripts/cockpit/cockpit_lib.py")).load_module()

# parse_event must carry detail through untruncated.
ev = cl.parse_event(json.dumps({"ts":1.0,"severity":"critical","source":"firewall",
                                "category":"scan","message":"m","id":"abc",
                                "detail":{"src_ip":"10.0.0.9","signature":"S"}}))
ck(ev["detail"]["src_ip"] == "10.0.0.9", "parse_event carries structured detail")
ck(cl.parse_event(json.dumps({"ts":1.0,"message":"m"}))["detail"] == {},
   "event without detail parses to an empty dict, not None")
ck(cl.parse_event('{"detail":"not-a-dict","ts":1}')["detail"] == {},
   "non-dict detail is coerced away rather than crashing the stream")

# The distinction that matters: 'nothing pending' vs 'could not look'.
td = pathlib.Path(tempfile.mkdtemp(dir=str(root/"tmp")))
absent = cl.healing_actions(td/"nope.jsonl")
ck(absent["readable"] is True and not absent["pending"],
   "absent chain reads as genuinely no actions")
chain = td/"chain.jsonl"
chain.write_text("\n".join(json.dumps(r) for r in [
    {"action_id":"a1","playbook":"block_ip","target":"10.0.0.9","status":"pending","ts":2},
    {"action_id":"a2","playbook":"quarantine_file","target":"/tmp/x","status":"active","ts":1},
    {"action_id":"a3","playbook":"kill_process","target":"999","status":"reverted","ts":3},
])+"\n")
h = cl.healing_actions(chain)
ck([r["action_id"] for r in h["pending"]] == ["a1"], "pending actions identified")
ck([r["action_id"] for r in h["active"]] == ["a2"], "active actions identified")
ck(not any(r["action_id"]=="a3" for r in h["pending"]+h["active"]),
   "reverted actions are neither pending nor in force")
bad = chain.with_name("bad.jsonl"); bad.write_text("{not json\n")
ck(cl.healing_actions(bad)["readable"] is True, "unparseable lines are skipped, not fatal")

# The distinction this panel exists to preserve. An unreadable chain must
# report readable=False so the Cockpit renders "state unknown" — rendering an
# empty pending list would tell the operator there is nothing to approve while
# the engine is holding a block-this-host decision. Found by mutation testing:
# flipping this branch to readable=True previously passed every assertion.
import os
locked = chain.with_name("locked.jsonl"); locked.write_text("{}\n"); locked.chmod(0o000)
if os.geteuid() == 0:
    print("  ok   (skipped: running as root, chmod 000 cannot deny)")
else:
    lr = cl.healing_actions(locked)
    ck(lr["readable"] is False, "unreadable chain reports readable=False, not an empty list")
    ck(bool(lr["reason"]), "unreadable chain explains why")
    ck(lr["pending"] == [], "unreadable chain yields no fabricated pending entries")
locked.chmod(0o644)

ok_, msg = cl.approve_action("")
ck(ok_ is False and "no action" in msg, "approving nothing is refused")
ok2, msg2 = cl.approve_action("deadbeef")
ck(ok2 is False and ("not found" in msg2 or "orionx-heal" in msg2),
   "failed approval names the command to run by hand, never silently 'succeeds'")

src = (root/"scripts/cockpit/orionx-cockpit").read_text()
for frag, label in [("_drill_overlay","drill-down overlay implemented"),
                    ("_actions_panel","actions panel implemented"),
                    ("_approve_selected","approve handler implemented"),
                    ("APPROVE?","APPROVE button rendered"),
                    ("button-press-event","click handling wired"),
                    ("_approve_rect","button hit-region tracked for clicks")]:
    ck(frag in src, label)
ck(src.count("self.drill") >= 3, "drill state actually used, not just declared")
sys.exit(0 if ok else 1)
PY
then pass "cockpit assertions"; else fail "cockpit assertions" "see above"; fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
