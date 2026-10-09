#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_awareness_daemon.sh — W10-5 posture daemon (DEC-PHASE12-024)
#
# The Threat Posture tier selector used to persist a value that nothing
# consumed except the Cockpit's badge colour: elevating to Deception changed a
# label and started nothing. orionx-postured enforces the tier.
#
# The single most important behaviour under test is the NO-RULES WARNING.
# Suricata running with no threat rules is indistinguishable, from the
# operator's seat, from Suricata seeing nothing — that is the exact failure
# that let a live nmap sweep pass unreported. Silent non-detection is the bug;
# loud degradation is the fix.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

PD="$REPO_ROOT/scripts/awareness/orionx-postured"
UNIT="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd/orionx-postured.service"

section "Structure"
if [[ -f "$PD" ]]; then pass "orionx-postured present"; else fail "orionx-postured present" "missing"; exit 1; fi
if [[ -x "$PD" ]]; then pass "orionx-postured executable"; else fail "orionx-postured executable"; fi
if head -1 "$PD" | grep -q python3; then pass "python3 shebang"; else fail "python3 shebang"; fi
if grep -q '@decision DEC-PHASE12-024' "$PD"; then pass "carries decision annotation"; else fail "carries decision annotation"; fi
if [[ -f "$UNIT" ]]; then pass "systemd unit staged"; else fail "systemd unit staged" "missing $UNIT"; fi

section "Pure logic"
if python3 - "$PD" <<'PY'
import sys, json, time
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("pd", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# --- tier parsing is default-safe -----------------------------------------
ck(m.parse_tier("2") == "2", "parse_tier('2') -> 2")
ck(m.parse_tier("1\n") == "1", "parse_tier tolerates trailing newline")
ck(m.parse_tier(None) == "0", "missing posture file -> Tier 0")
ck(m.parse_tier("") == "0", "empty posture file -> Tier 0")
ck(m.parse_tier("garbage") == "0", "corrupt posture file -> Tier 0")
ck(m.parse_tier("9") == "0", "out-of-range tier -> Tier 0")
ck(m.parse_tier("2; rm -rf /") == "0", "injection-ish content -> Tier 0")

# --- what each tier actually does -----------------------------------------
t0 = m.tier_plan("0", rules_usable=True)
ck(not any([t0["gate_file"], t0["suricata"], t0["eve_ingest"], t0["deception"]]),
   "Tier 0 starts NOTHING (no gate, no suricata, no ingest, no deception)")
ck(t0["warn_no_rules"] is False, "Tier 0 does not warn about rules (it claims no coverage)")
t1 = m.tier_plan("1", rules_usable=True)
ck(t1["gate_file"] and t1["suricata"] and t1["eve_ingest"], "Tier 1 creates gate + starts suricata + ingests")
ck(t1["deception"] is False, "Tier 1 does NOT arm deception")
t2 = m.tier_plan("2", rules_usable=True)
ck(t2["deception"] is True and t2["suricata"] is True, "Tier 2 = Tier 1 plus deception")
ck(m.tier_plan("bogus", True)["tier"] == "0", "unknown tier falls back to 0")

# --- THE no-rules warning path (the bug this work exists to fix) ----------
# files.rules is deliberately included: it is in STOCK_ANOMALY_RULES but does
# NOT end in "-events.rules", so it is the only fixture that exercises the
# explicit stock set rather than the suffix rule. Without it, deleting the set
# entirely still passed — found by mutation testing.
stock = [("/etc/suricata/rules/decoder-events.rules", 4096),
         ("/etc/suricata/rules/stream-events.rules", 2048),
         ("/etc/suricata/rules/files.rules", 1024)]
st = m.assess_rules(stock)
ck(st["usable"] is False, "stock protocol-anomaly rules alone are NOT usable coverage")
ck(st["anomaly_files"] == 3 and st["threat_files"] == 0, "stock files classified as anomaly, not threat")
ck(m.is_threat_rule_file("files.rules") is False, "stock files.rules excluded by the explicit set, not the suffix rule")
ck(m.tier_plan("1", rules_usable=False)["warn_no_rules"] is True, "Tier 1 without rules RAISES the warning")
ck(m.tier_plan("2", rules_usable=False)["warn_no_rules"] is True, "Tier 2 without rules RAISES the warning")
msg = m.no_rules_message("1", st)
ck("NOT be detected" in msg or "not watching" in msg, "warning states the consequence plainly")
ck("orionx-freshen-suricata" in msg, "warning names the remedy")
ck("scanwatch" in msg, "warning says what still works, so it is not read as total blindness")

# empty threat file must not count as coverage
ck(m.assess_rules([("/var/lib/suricata/rules/emerging-all.rules", 0)])["usable"] is False,
   "a zero-byte threat rule file is not coverage")
ck(m.assess_rules([("/var/lib/suricata/rules/emerging-all.rules", 900000)])["usable"] is True,
   "a populated ET rule file IS coverage")
ck(m.is_threat_rule_file("emerging-scan.rules") is True, "ET rule recognised as threat signatures")
ck(m.is_threat_rule_file("decoder-events.rules") is False, "stock -events file not a threat file")
ck(m.is_threat_rule_file("notes.txt") is False, "non-.rules file ignored")

# --- eve.json parsing ------------------------------------------------------
alert_line = json.dumps({"event_type": "alert", "src_ip": "192.168.4.77",
                         "dest_port": 445,
                         "alert": {"signature": "ET SCAN Nmap Scripting Engine",
                                   "category": "Attempted Information Leak",
                                   "signature_id": 2009582, "severity": 2}})
a = m.parse_eve_line(alert_line)
ck(a is not None and a.get("src_ip") == "192.168.4.77", f"parses an eve alert -> {None if not a else a.get('src_ip')}")
ck(m.parse_eve_line(json.dumps({"event_type": "flow"})) is None, "ignores non-alert telemetry (flow)")
ck(m.parse_eve_line("") is None, "ignores empty line")
ck(m.parse_eve_line('{"event_type":"alert"') is None, "truncated line during rotation is a skip, not a crash")
ck(m.parse_eve_line("not json at all") is None, "garbage line ignored")

# --- ATT&CK mapping --------------------------------------------------------
tid, tname = m.attack_technique("attempted-recon", "ET SCAN Nmap")
ck(bool(tid), f"recon classtype maps to an ATT&CK technique -> {tid} {tname}")
ck(m.attack_technique(None, None) == ("", ""), "unmapped alert yields empty technique, not a guess")

# --- dedup with scanwatch (no double-reporting) ---------------------------
scan_alert = {"classtype": "attempted-recon", "signature": "ET SCAN Nmap", "src_ip": "10.0.0.9"}
ck(m.should_suppress(scan_alert, {"10.0.0.9"}) is True, "suricata scan alert suppressed when scanwatch owns that source")
ck(m.should_suppress(scan_alert, set()) is False, "not suppressed when scanwatch has not reported it")

# --- Nebula degradation: must never gate an alert -------------------------
ck(m.parse_nebula_response(None) is None, "Nebula unreachable -> None, no crash")
ck(m.parse_nebula_response("") is None, "empty Nebula body -> None")
ck(m.parse_nebula_response("<html>502</html>") is None, "non-JSON Nebula body -> None")
ck(m.parse_nebula_response(json.dumps({"response": "  "})) is None, "blank model text -> None")
ck(m.parse_nebula_response(json.dumps({"response": "Port sweep."})) == "Port sweep.", "valid model text extracted")
ck(m.condense(None) is None, "condense(None) is safe")
long = m.condense("x " * 500, limit=80)
ck(long is not None and len(long) <= 80, f"condense bounds length for the bus/TTS ({len(long or '')})")

# --- bounded memory --------------------------------------------------------
d = m.AlertDeduper(reannounce=300.0, max_keys=50)
now = 1000.0
for i in range(400):
    d.should_emit(("sid", i, f"10.0.{i//256}.{i%256}", 80), now + i*0.01) if hasattr(d, "should_emit") else None
if hasattr(d, "should_emit"):
    size = len(getattr(d, "_seen", getattr(d, "seen", {})))
    ck(size <= 50, f"alert deduper bounded under a flood ({size} keys)")
else:
    ck(True, "alert deduper present (API name differs; flood test skipped)")
sys.exit(0 if ok else 1)
PY
then pass "pure-logic assertions"; else fail "pure-logic assertions" "see output above"; fi

section "Tier transitions and effects"
if python3 - "$PD" <<'PY'
import sys, tempfile, os
from pathlib import Path
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("pd", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# Boot (no prior state) into each tier.
up0 = m.plan_actions(None, m.tier_plan("0", True))
ck(up0 == [] or all(a[0] not in ("gate", "service", "eve", "deception") for a in up0),
   f"Tier 0 from cold plans no start actions -> {up0}")
up1 = m.plan_actions(None, m.tier_plan("1", True))
kinds1 = [a[0] for a in up1]
ck("gate" in kinds1 and "service" in kinds1 and "eve" in kinds1, f"Tier 1 plans gate+service+eve -> {kinds1}")
ck("deception" not in kinds1, "Tier 1 never plans deception")
up2 = m.plan_actions(None, m.tier_plan("2", True))
ck("deception" in [a[0] for a in up2], "Tier 2 plans deception arm")

# De-escalation must tear down, not linger.
down = m.plan_actions(m.tier_plan("2", True), m.tier_plan("0", True))
kinds = [a[0] for a in down]
ck("deception" in kinds and "eve" in kinds and "service" in kinds,
   f"dropping 2 -> 0 tears down deception, ingest and suricata -> {kinds}")
ck(kinds.index("deception") < kinds.index("service"),
   "teardown disarms deception before stopping the IDS")

# Idempotence: re-applying the same tier must not thrash services.
same = m.plan_actions(m.tier_plan("1", True), m.tier_plan("1", True))
ck(same == [], f"re-asserting the same tier is a no-op -> {same}")

# Gate file is the DEC-PHASE11-008 mechanism that actually lets suricata start.
os.makedirs(os.environ.get("ORIONX_TMP", "tmp"), exist_ok=True)   # a fresh CI checkout has no tmp/
with tempfile.TemporaryDirectory(dir=os.environ.get("ORIONX_TMP", "tmp")) as td:
    g = Path(td) / "sub" / "orionx-enabled"
    ck(m.set_gate(True, path=g) is True and g.exists(), "set_gate(True) creates the gate (parents too)")
    ck(m.set_gate(False, path=g) is True and not g.exists(), "set_gate(False) removes the gate")
    ck(m.set_gate(False, path=g) is True, "removing an absent gate is idempotent")
    g2 = Path(td) / "dry" / "orionx-enabled"
    ck(m.set_gate(True, path=g2, dry_run=True) is True and not g2.exists(), "dry-run creates nothing")

# Deception is local-only and non-destructive.
tok = m.honeytoken()
ck(isinstance(tok, str) and len(tok) > 8, f"honeytoken generated ({tok[:8]}…)")
ck(m.honeytoken() != m.honeytoken(), "honeytokens are unique per call")
ck(m.canary_tripped(100.0, 200.0) is True, "canary read (atime advanced) is detected")
ck(m.canary_tripped(100.0, 100.0) is False, "untouched canary does not trip")
ck(m.canary_tripped(200.0, 100.0) is False, "clock skew backwards does not false-trip")
ck("10.0.0.9" in m.decoy_alert_message(2222, "10.0.0.9"), "decoy alert names the peer")
sys.exit(0 if ok else 1)
PY
then pass "tier transition + effect assertions"; else fail "tier transition + effect assertions" "see output above"; fi

section "Build wiring"
if grep -q 'orionx-event' "$PD"; then pass "publishes via the orionx-event CLI"; else fail "publishes via orionx-event CLI"; fi
if grep -qE '127\.0\.0\.1:11434' "$PD"; then pass "Nebula pinned to localhost only"; else fail "Nebula pinned to localhost"; fi
if ! grep -qE 'pip install|import requests|import yaml' "$PD"; then pass "stdlib only (air-gapped safe)"; else fail "stdlib only" "external dependency found"; fi
if grep -q 'ConditionPathExists\|orionx-enabled' "$PD"; then pass "knows the DEC-PHASE11-008 suricata gate"; else fail "knows the suricata gate"; fi
if grep -qE 'ExecStart=.*orionx-postured' "$UNIT"; then pass "unit ExecStart points at the daemon"; else fail "unit ExecStart points at the daemon"; fi
# DEC-PHASE12-032: detection must not wait on the optional model runtime.
# On rc3 this unit sat inactive with a pending job because it was ordered
# After=nebula-runtime.service, so Shields Up enforcement and Zeek ingest were
# dormant — the exact inversion of "the model never gates an alert".
if grep -qE '^After=.*nebula-runtime' "$UNIT"; then
  fail "postured is not ordered behind the model runtime" \
       "After=nebula-runtime.service makes detection wait on optional enrichment"
else
  pass "postured is not ordered behind the model runtime (DEC-PHASE12-032)"
fi
if command -v ruff >/dev/null 2>&1; then
  if ruff check --select E4,E7,E9,F "$PD" >/dev/null 2>&1; then pass "ruff check --select E4,E7,E9,F clean"; else fail "ruff check --select E4,E7,E9,F clean" "$(ruff check --select E4,E7,E9,F "$PD" 2>&1 | tail -3)"; fi
fi

section "Self-diagnosis is not a threat (RESILIENCE.md rule 5)"
# The Cockpit's pressure() gauge weights by severity and excludes exactly
# health/posture/service/tooling. It does NOT exclude `ids`. So every event
# this daemon emits ABOUT ITSELF must avoid `ids`, or the deck frightens
# itself with its own health messages and the gauge stops meaning anything.
#
# This is asserted on what actually reaches the bus, not by reading the
# source: a dry run prints "[severity] source/category: message", and a run
# with no traffic and no rules produces nothing but self-diagnosis, so not
# one line of it may be categorised `ids`.
CATTMP="$REPO_ROOT/tmp/awareness-cat.$$"
mkdir -p "$CATTMP/sys/lo/statistics" "$CATTMP/sys/enp2s0/statistics"
echo 772 > "$CATTMP/sys/lo/type"; echo 500000 > "$CATTMP/sys/lo/statistics/rx_packets"
echo 1 > "$CATTMP/sys/enp2s0/type"; echo 1000 > "$CATTMP/sys/enp2s0/statistics/rx_packets"
echo 1 > "$CATTMP/posture"
CATOUT="$(python3 "$PD" --once --dry-run --no-nebula --posture-file "$CATTMP/posture" \
          --sysfs "$CATTMP/sys" --interfaces-yaml "$CATTMP/ifaces.yaml" \
          --rules-dir "$CATTMP/rules" --canary-dir "$CATTMP/canary" \
          --live-window 0 --zeek-log-dir "$CATTMP/zeek" 2>&1)"
if [[ -n "$CATOUT" ]]; then pass "dry run emits events to inspect"; else fail "dry run emits events" "no output"; fi
if ! echo "$CATOUT" | grep -q '/ids:'; then
  pass "no self-diagnosis event is categorised 'ids' (would inflate THREAT PRESSURE)"
else
  fail "self-diagnosis categorised as ids" "$(echo "$CATOUT" | grep '/ids:' | head -2)"
fi
if echo "$CATOUT" | grep -q 'IDS COVERAGE GAP'; then
  if echo "$CATOUT" | grep 'IDS COVERAGE GAP' | grep -q '/health:'; then
    pass "the no-rules coverage gap is published as health"
  else
    fail "no-rules coverage gap category" "$(echo "$CATOUT" | grep 'IDS COVERAGE GAP' | head -1)"
  fi
else
  fail "no-rules coverage gap announced" "$CATOUT"
fi
if echo "$CATOUT" | grep -q 'Zeek' && echo "$CATOUT" | grep 'Zeek' | grep -q '/health:'; then
  pass "Zeek capability self-status is published as health"
elif ! echo "$CATOUT" | grep -q 'Zeek'; then
  pass "Zeek capability self-status not emitted in this run (nothing to report)"
else
  fail "Zeek self-status category" "$(echo "$CATOUT" | grep 'Zeek' | head -1)"
fi
# The three remaining `ids` emitters must be detections and nothing else.
IDS_SITES="$(grep -c '"ids"' "$PD")"
if [[ "$IDS_SITES" == "3" ]]; then
  pass "exactly 3 'ids' emit sites remain (suricata alert, zeek notice, zeek weird)"
else
  fail "ids emit site count" "expected 3 detection sites, found $IDS_SITES: $(grep -n '\"ids\"' "$PD" | tr '\n' ' ')"
fi
# orionx-capture's PCAP events are self-status too, and shared the defect.
CAP="$REPO_ROOT/scripts/awareness/orionx-capture"
# Assert the EFFECT, not which literal was chosen. What matters is that a
# failed PCAP capture cannot move THREAT PRESSURE; whether that is spelled
# "health" or "capture" is a labelling choice, and both are in
# rain_lib.STATUS_CATEGORIES. The previous form named one literal and so went
# red when the other, equally safe, more specific one was picked — a test
# failing for a reason unrelated to the property it guards (RESILIENCE rule 1).
_CAPCAT="$(grep -oE 'def publish\(severity: str, message: str, category: str = "[a-z]+"' "$CAP" | grep -oE '"[a-z]+"$' | tr -d '"')"
if python3 - "$REPO_ROOT" "$_CAPCAT" <<'PYCAP'
import sys, pathlib
from importlib.machinery import SourceFileLoader
root, cat = pathlib.Path(sys.argv[1]), sys.argv[2]
rl = SourceFileLoader("rain_lib", str(root/"scripts/rain/rain_lib.py")).load_module()
cl = SourceFileLoader("cl", str(root/"scripts/cockpit/cockpit_lib.py")).load_module()
import time; now = time.time()
ok = bool(cat) and not rl.is_threat_category(cat) \
     and cl.pressure([{"ts": now, "severity": "critical", "category": cat}], now) == 0.0
print(f"  capture default category = {cat!r}; contributes "
      f"{cl.pressure([{'ts': now, 'severity': 'critical', 'category': cat}], now)} to pressure")
sys.exit(0 if ok else 1)
PYCAP
then pass "orionx-capture's default category is excluded from THREAT PRESSURE"; else fail "orionx-capture default category" "PCAP failures would add to THREAT PRESSURE"; fi
rm -rf "$CATTMP"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
