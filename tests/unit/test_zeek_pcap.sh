#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_zeek_pcap.sh — Zeek ingest + on-demand PCAP capture (DEC-PHASE12-028)
#
# Two capabilities that were both missing for the same reason: the deck could
# ANALYSE network evidence but could neither produce it nor consume what Zeek
# produced. Zeek's build-time install is soft-fail (0500 hook), so whether a
# given ISO has it was decided by whether a repo answered — and the shipped
# 2026-09-27 image has no /opt/zeek at all. Nothing detected that.
#
# So the behaviours under test are mostly about NOT BEING SILENT:
#   - Zeek absent, present, appearing later, or with unreadable logs: each is
#     a distinct, announced state, never a quiet one.
#   - A capture that cannot be bounded is refused, out loud, with numbers.
#   - One scan reported by three detectors is still one story.
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
CAP="$REPO_ROOT/scripts/awareness/orionx-capture"
CHROOT="$REPO_ROOT/iso/config/includes.chroot"
INSTALLER="$CHROOT/opt/orionx/optional/install-zeek.sh"
UNIT="$CHROOT/usr/share/orionx/systemd/orionx-capture@.service"
FIXTURES="$REPO_ROOT/tests/fixtures/zeek"

# Never /tmp — tmp/ in the repo root, cleaned on exit.
WORK="$(mktemp -d "$REPO_ROOT/tmp/zeekpcap-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

section "Structure"
for f in "$CAP" "$INSTALLER"; do
  if [[ -f "$f" ]]; then pass "$(basename "$f") present"; else fail "$(basename "$f") present" "missing"; exit 1; fi
  if [[ -x "$f" ]]; then pass "$(basename "$f") executable"; else fail "$(basename "$f") executable"; fi
done
if [[ -f "$UNIT" ]]; then pass "orionx-capture@.service staged"; else fail "orionx-capture@.service staged" "missing $UNIT"; fi
for f in "$CAP" "$INSTALLER" "$UNIT"; do
  if grep -q '@decision DEC-PHASE12-028' "$f"; then pass "$(basename "$f") carries the decision annotation"; else fail "$(basename "$f") decision annotation"; fi
done
if grep -q '@decision DEC-PHASE12-028' "$PD"; then pass "orionx-postured carries the decision annotation"; else fail "orionx-postured decision annotation"; fi
if head -1 "$CAP" | grep -q python3; then pass "orionx-capture python3 shebang"; else fail "orionx-capture python3 shebang"; fi
for f in conn.log weird.log notice.log; do
  if [[ -s "$FIXTURES/$f" ]]; then pass "fixture $f present"; else fail "fixture $f present" "missing"; fi
done

section "Installer: idempotent, fingerprint-pinned, rolls back"
# The real script is EXECUTED here, not grepped: ORIONX_INSTALLER_LIB and
# ORIONX_ZEEK_PREFIX exist so these paths run for real on a build host.
export ORIONX_INSTALLER_LIB="$CHROOT/opt/orionx/optional/lib/orionx-installer-common.sh"
FAKE_PREFIX="$WORK/zeekroot"
out="$(ORIONX_ZEEK_PREFIX="$FAKE_PREFIX" "$INSTALLER" --check 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then pass "--check exits 1 when Zeek is absent"; else fail "--check exits 1 when absent" "rc=$rc"; fi
if echo "$out" | grep -q 'NOT installed'; then pass "--check says plainly that Zeek is absent"; else fail "--check says absent" "$out"; fi

mkdir -p "$FAKE_PREFIX/bin"
printf '#!/bin/sh\necho "zeek version 9.0.0-0"\n' > "$FAKE_PREFIX/bin/zeek"
chmod +x "$FAKE_PREFIX/bin/zeek"
out="$(ORIONX_ZEEK_PREFIX="$FAKE_PREFIX" "$INSTALLER" --check 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then pass "--check exits 0 when Zeek is present"; else fail "--check exits 0 when present" "rc=$rc $out"; fi

# Idempotence: a re-run on a provisioned deck touches nothing and exits 0 —
# with no root and no network, which is what proves it short-circuited before
# the preflight rather than merely surviving it.
out="$(ORIONX_ZEEK_PREFIX="$FAKE_PREFIX" "$INSTALLER" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then pass "re-run on an installed deck exits 0 (idempotent)"; else fail "idempotent re-run" "rc=$rc $out"; fi
if echo "$out" | grep -q 'Nothing to do'; then pass "idempotent re-run says it did nothing"; else fail "idempotent re-run reports no-op" "$out"; fi
if ! echo "$out" | grep -q 'apt-get'; then pass "idempotent re-run never reaches apt"; else fail "idempotent re-run reached apt" "$out"; fi
out="$(ORIONX_ZEEK_PREFIX="$FAKE_PREFIX" "$INSTALLER" --wat 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then pass "unknown argument is refused (exit 2)"; else fail "unknown argument refused" "rc=$rc"; fi

# A half-unpacked install must NOT be reported as installed: apt success is
# not installation success. A present-but-nonexecuting binary is the case.
printf 'not a binary\n' > "$FAKE_PREFIX/bin/zeek"; chmod +x "$FAKE_PREFIX/bin/zeek"
ORIONX_ZEEK_PREFIX="$FAKE_PREFIX" "$INSTALLER" --check >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 ]]; then pass "a binary that does not run is NOT reported as installed"; else fail "broken binary detected" "rc=$rc"; fi

# The trust anchor is a pinned fingerprint, and the pin must be a real one.
PIN="$(grep -oE 'ZEEK_REPO_KEY_FPR="[0-9A-F]{40}"' "$INSTALLER" | head -1 | grep -oE '[0-9A-F]{40}')"
if [[ -n "$PIN" ]]; then pass "signing key fingerprint is pinned ($PIN)"; else fail "fingerprint pinned" "no 40-hex pin found"; fi
if grep -q 'FINGERPRINT MISMATCH' "$INSTALLER"; then pass "mismatch is an explicit, named refusal"; else fail "mismatch refusal"; fi
if grep -q 'signed-by=' "$INSTALLER"; then pass "keyring is scoped to this repo with signed-by="; else fail "signed-by= scoping"; fi
# The refusal must happen BEFORE anything is written, or a tampered key still
# leaves a trusted source list behind.
if awk '/FINGERPRINT MISMATCH/{m=NR} /install -m 0644 .* "\$ZEEK_KEYRING"/{k=NR} END{exit !(m && k && m<k)}' "$INSTALLER"; then
  pass "fingerprint is verified BEFORE the keyring is written"; else fail "verify-before-write ordering"; fi
if grep -q 'rm -f "\$ZEEK_SOURCE_LIST" "\$ZEEK_KEYRING"' "$INSTALLER"; then pass "apt failure rolls back the source list (no dangling repo)"; else fail "rollback on apt failure"; fi

section "Runtime detection: Zeek absent, present, and appearing later"
if python3 - "$PD" "$WORK" "$FIXTURES" <<'PY'
import sys, os, shutil
from pathlib import Path
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("pd", sys.argv[1]).load_module()
work, fixtures = Path(sys.argv[2]), Path(sys.argv[3])
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

nowhere = [work / "no-zeek-bin"]
empty_dirs = [work / "no-zeek-logs"]

# --- absent ---------------------------------------------------------------
z = m.detect_zeek(nowhere, empty_dirs, use_path=False)
ck(z["installed"] is False, "Zeek binary absent is detected as absent")
ck(z["usable"] is False, "absent Zeek is not usable")
ck(z["log_state"] == "absent", f"log state 'absent' -> {z['log_state']}")
sev, msg = m.zeek_state_message(z)
ck("NOT installed" in msg, "absence is stated plainly, not implied")
ck("install-zeek.sh" in msg, "absence message names the remedy")
ck("no rebuild or restart" in msg.lower() or "next cycle" in msg,
   "absence message says no rebuild is needed")
ck(sev in ("notice", "warning"), f"absence is announced, never silent ({sev})")

# --- installed but no logs ------------------------------------------------
binroot = work / "zbin"; (binroot / "bin").mkdir(parents=True, exist_ok=True)
fakebin = binroot / "bin" / "zeek"
fakebin.write_text("#!/bin/sh\necho zeek\n"); os.chmod(fakebin, 0o755)
logdir = work / "zlogs"; logdir.mkdir(parents=True, exist_ok=True)
z = m.detect_zeek([fakebin], [logdir], use_path=False)
ck(z["installed"] is True, "installed Zeek binary is found")
ck(z["log_state"] == "empty", f"empty log dir -> 'empty' ({z['log_state']})")
ck(z["usable"] is False, "installed but logless Zeek is not usable")
sev, msg = m.zeek_state_message(z)
ck("nothing to ingest" in msg.lower(), "empty-logs message says there is nothing to ingest")
ck("orionx-capture" in msg or "zeek -i" in msg, "empty-logs message says how to give it traffic")

# --- logs appear LATER: the no-rebuild promise ----------------------------
for name in ("conn.log", "weird.log", "notice.log"):
    shutil.copy(fixtures / name, logdir / name)
z2 = m.detect_zeek([fakebin], [logdir], use_path=False)
ck(z2["usable"] is True, "Zeek becomes usable once logs appear — no restart, no rebuild")
ck(set(z2["logs"]) == {"conn.log", "weird.log", "notice.log"},
   f"all three signal logs discovered -> {sorted(z2['logs'])}")
sev, msg = m.zeek_state_message(z2)
ck("ACTIVE" in msg, "the transition to active is announced")

# --- unreadable: the dangerous one ----------------------------------------
locked = work / "zlocked"; locked.mkdir(parents=True, exist_ok=True)
(locked / "notice.log").write_text("x")
os.chmod(locked, 0o000)
try:
    z3 = m.detect_zeek([fakebin], [locked], use_path=False)
    if os.geteuid() == 0:
        ck(True, "unreadable-dir check skipped (running as root; chmod 000 is not a barrier)")
    else:
        ck(z3["log_state"] == "unreadable", f"unreadable log dir is its own state -> {z3['log_state']}")
        ck(z3["usable"] is False, "unreadable logs are not treated as usable")
        sev, msg = m.zeek_state_message(z3)
        ck(sev == "warning", f"unreadable logs are a WARNING, not a shrug ({sev})")
        ck("silent non-detection" in msg, "unreadable message names the failure mode explicitly")
        ck("chmod" in msg, "unreadable message names the fix")
finally:
    os.chmod(locked, 0o755)

# --- a directory that exists but is not first wins only if it has logs ----
first, second = work / "zfirst", work / "zsecond"
first.mkdir(exist_ok=True); second.mkdir(exist_ok=True)
shutil.copy(fixtures / "conn.log", second / "conn.log")
z4 = m.detect_zeek([fakebin], [first, second], use_path=False)
ck(z4["log_dir"] == str(second), "search falls through an empty dir to one with logs")

# An explicit candidate list must be authoritative: a Zeek elsewhere on PATH
# must not silently satisfy --zeek-bin. (This host really does have one.)
ck(m.find_zeek_binary([work / "nope"], use_path=False) is None,
   "explicit --zeek-bin candidates are authoritative; PATH is not consulted")
sys.exit(0 if ok else 1)
PY
then pass "runtime detection assertions"; else fail "runtime detection assertions" "see output above"; fi

section "Zeek log parsing (real zeek -r output)"
if python3 - "$PD" "$FIXTURES" <<'PY'
import sys, json
from pathlib import Path
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("pd", sys.argv[1]).load_module()
fx = Path(sys.argv[2])
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# conn.log and weird.log here are REAL Zeek 8.1.1 output, not hand-typed.
fields = m.zeek_fields_from_file(fx / "conn.log")
ck(fields is not None and fields[:3] == ["ts", "uid", "id.orig_h"],
   f"#fields header parsed from real conn.log -> {None if not fields else fields[:3]}")
rows = [m.zeek_record(l, fields) for l in (fx / "conn.log").read_text().splitlines()]
rows = [r for r in rows if r]
ck(len(rows) == 64, f"all 64 real conn records parsed ({len(rows)})")
ck(rows[0]["id.orig_h"] == "10.0.0.9", "conn record fields land in the right columns")
ck(rows[0]["service"] is None, "Zeek's unset marker '-' becomes None, not the string '-'")
ck(all(not r.get("ts", "").startswith("#") for r in rows if isinstance(r.get("ts"), str)),
   "header/comment lines never leak in as records")

wfields = m.zeek_fields_from_file(fx / "weird.log")
wrows = [r for r in (m.zeek_record(l, wfields) for l in (fx / "weird.log").read_text().splitlines()) if r]
ck(len(wrows) == 4, f"real weird.log parsed ({len(wrows)} records)")
ck(wrows[0]["name"] == "bad_TCP_checksum", "weird record carries its anomaly name")

nfields = m.zeek_fields_from_file(fx / "notice.log")
notices = [m.parse_zeek_notice(m.zeek_record(l, nfields))
           for l in (fx / "notice.log").read_text().splitlines()]
notices = [n for n in notices if n]
ck(len(notices) == 5, f"5 notices parsed ({len(notices)})")
by_note = {n["note"]: n for n in notices}
ck(m.zeek_notice_severity(by_note["SSH::Password_Guessing"]) == "critical",
   "SSH brute force is critical")
ck(m.zeek_attack_technique("SSH::Password_Guessing") == ("T1110", "Brute Force"),
   "SSH brute force maps to T1110")
ck(m.zeek_notice_severity(by_note["Local::Custom_Policy_Hit"]) == "notice",
   "an UNKNOWN notice type is published at notice, never dropped")
ck(m.zeek_attack_technique("Local::Custom_Policy_Hit") == ("", ""),
   "an unmapped notice yields no ATT&CK id rather than a guessed one")
# Zeek's own escalation is honoured: this fixture carries ACTION_ALARM.
ck("ACTION_ALARM" in by_note["SSL::Weak_Key"]["actions"], "fixture carries ACTION_ALARM")

# --- JSON-format Zeek logs must work too ---------------------------------
jline = json.dumps({"ts": 1.0, "note": "Intel::Intel", "msg": "hit on 1.2.3.4",
                    "src": "10.0.0.5", "dst": "10.0.0.1", "p": 443,
                    "actions": ["Notice::ACTION_LOG"]})
jn = m.parse_zeek_notice(m.zeek_record(jline, None))
ck(jn is not None and jn["note"] == "Intel::Intel",
   "JSON-format Zeek logs parse (LogAscii::use_json decks are not silently zero)")
ck(m.zeek_notice_severity(jn) == "critical", "Intel hit is critical")

# --- blindness is said out loud ------------------------------------------
cl = by_note["CaptureLoss::Too_Much_Loss"]
ck(cl["note"] in m.ZEEK_BLINDNESS_NOTES, "capture loss is classed as a SENSOR problem")
msg = m.format_zeek_message(cl, m.zeek_attack_technique(cl["note"]))
ck("SENSOR PROBLEM" in msg and "NOT A QUIET NETWORK" in msg,
   "capture-loss message distinguishes 'did not see' from 'nothing happened'")

# --- malformed input is a skip, never a crash ----------------------------
ck(m.zeek_record("", nfields) is None, "empty line ignored")
ck(m.zeek_record("#close\t2026-01-01", nfields) is None, "trailing #close ignored")
ck(m.zeek_record('{"truncated":', None) is None, "truncated JSON during rotation is a skip")
ck(m.zeek_record("a\tb", None) is None, "TSV line with no known header is a skip, not a guess")
ck(m.parse_zeek_notice(None) is None, "None record handled")
ck(m.parse_zeek_notice({"msg": "no note field"}) is None, "record with no note is not a notice")
short = m.zeek_record("1.0\tCuid", nfields)
ck(short is not None and short["note"] is None, "a short/truncated row pads rather than misaligning")

# --- weird.log aggregation: a firehose must not become a bus flood -------
agg = m.WeirdAggregator(window=60.0, burst=25, reannounce=600.0)
fired = [agg.observe("bad_TCP_checksum", "10.0.0.9", 1000.0 + i * 0.1) for i in range(24)]
ck(not any(fired), "24 weird events below the burst threshold stay off the bus")
one = agg.observe("bad_TCP_checksum", "10.0.0.9", 1002.5)
ck(one is not None and one["count"] == 25, f"the 25th fires one aggregated event ({one})")
more = [agg.observe("bad_TCP_checksum", "10.0.0.9", 1003.0 + i * 0.1) for i in range(200)]
ck(not any(more), "200 further weirds are throttled to zero extra events")
ck("25x bad_TCP_checksum" in m.format_weird_message(one), "aggregated message states the count")
agg2 = m.WeirdAggregator(max_keys=50)
for i in range(500):
    agg2.observe(f"weird_{i}", f"10.1.{i // 256}.{i % 256}", 1000.0 + i)
ck(agg2.tracked() == 50, f"weird table is bounded under a flood ({agg2.tracked()})")
sys.exit(0 if ok else 1)
PY
then pass "Zeek log parsing assertions"; else fail "Zeek log parsing assertions" "see output above"; fi

section "One scan is one story (no triple-reporting)"
if python3 - "$PD" <<'PY'
import sys, json
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("pd", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# Precedence is declared once and derived everywhere.
ck(m.SCAN_REPORTER_PRECEDENCE == ("firewall", "suricata", "zeek"),
   f"precedence is firewall > suricata > zeek -> {m.SCAN_REPORTER_PRECEDENCE}")
ck(m.upstream_scan_reporters("firewall") == (),
   "scanwatch defers to nobody (it needs no rules and no network)")
ck(m.upstream_scan_reporters("suricata") == ("firewall",),
   "suricata defers to scanwatch only")
ck(m.upstream_scan_reporters("zeek") == ("firewall", "suricata"),
   "zeek defers to BOTH — this is the third-report guard")
ck(m.upstream_scan_reporters("nucleotide") == (),
   "an unknown reporter defers to nobody (fails OPEN: a missed detection is worse than a duplicate)")

now = 5000.0
key = b"scan-dedup-test-key-32-bytes-long!"
m.rain_lib.read_bus_key = lambda: (key, None)
def signed_event(event):
    event["auth"] = m.rain_lib.sign_event(event, key)
    return json.dumps(event)
# 1. scanwatch reports a sweep from 10.0.0.9 on the bus.
scan = {"ts": now - 5, "severity": "critical", "source": "firewall",
        "category": "scan",
        "message": "port scan from 10.0.0.9 — 60 ports in 14s (tcp), most recent dport 445"}
bus = [signed_event(scan.copy())]
srcs = m.scan_sources_from_bus(bus, now, sources=("firewall",))
ck(srcs == {"10.0.0.9"}, f"scanwatch's report is read off the bus -> {srcs}")
ck(m.scan_sources_from_bus([json.dumps(scan)], now, sources=("firewall",)) == set(),
   "forged unsigned scanwatch report cannot suppress an IDS alert")
tampered = json.loads(bus[0])
tampered["message"] = "port scan from 10.0.0.10"
ck(m.scan_sources_from_bus([json.dumps(tampered)], now, sources=("firewall",)) == set(),
   "a changed source in a signed line cannot suppress an IDS alert")

# 2. Suricata sees the same sweep. It must NOT re-report it.
sur = {"classtype": "attempted-recon", "signature": "ET SCAN Nmap", "src_ip": "10.0.0.9"}
ck(m.should_suppress(sur, srcs) is True, "suricata scan alert for that source is suppressed (report #2 prevented)")

# 3. Zeek sees it too. It must not re-report it either.
ledger = m.ScanLedger()
ledger.merge_bus("firewall", srcs, now)
ck(m.should_suppress_scan("zeek", "10.0.0.9", ledger, now) == "firewall",
   "zeek defers to scanwatch and NAMES the owner (report #3 prevented)")

# The case where scanwatch is silent but Suricata fired: zeek still defers.
ledger2 = m.ScanLedger()
ledger2.record("suricata", "10.0.0.77", now)
ck(m.should_suppress_scan("zeek", "10.0.0.77", ledger2, now) == "suricata",
   "zeek defers to suricata when scanwatch did not see it")
ck(m.should_suppress_scan("suricata", "10.0.0.77", ledger2, now) is None,
   "suricata does NOT suppress itself")

# A source nobody has reported is published by whoever saw it.
ck(m.should_suppress_scan("zeek", "10.0.0.250", ledger, now) is None,
   "an unreported source is NOT suppressed — zeek publishes it")
ck(m.should_suppress_scan("zeek", "", ledger, now) is None,
   "an empty source address never suppresses anything")

# Suppression must EXPIRE, or one old scan silences a detector forever.
ck(m.should_suppress_scan("zeek", "10.0.0.9", ledger, now + m.SCAN_DEDUP_WINDOW + 1) is None,
   f"suppression expires after the {m.SCAN_DEDUP_WINDOW:.0f}s window")

# Only SCAN notices dedup. A brute-force from a host that also scanned must
# still be reported — suppressing it would lose a different attack.
ck(m.is_zeek_scan_notice("Scan::Port_Scan") is True, "Scan::Port_Scan is a scan notice")
ck(m.is_zeek_scan_notice("Scan::Address_Scan") is True, "Scan::Address_Scan is a scan notice")
ck(m.is_zeek_scan_notice("Local::Scan_Something") is False, "only the Scan:: namespace dedups")
ck(m.is_zeek_scan_notice("SSH::Password_Guessing") is False,
   "a brute force from an already-reported scanner is still reported")
ck(m.is_zeek_scan_notice(None) is False, "a missing note is not a scan notice")

# Bounded, like every other table in the daemon.
big = m.ScanLedger(max_keys=100)
for i in range(500):
    big.record("zeek", f"10.2.{i // 256}.{i % 256}", now)
ck(big.tracked() == 100, f"scan ledger is bounded under a spoofed-source flood ({big.tracked()})")

# The bus reader must ignore other traffic on the shared bus.
noise = [json.dumps({"ts": now, "source": "health", "category": "service", "message": "from 10.9.9.9"}),
         json.dumps({"ts": now, "source": "firewall", "category": "posture", "message": "from 10.9.9.8"}),
         "not json at all", "", "{}"]
ck(m.scan_sources_from_bus(noise, now, sources=("firewall",)) == set(),
   "non-scan bus traffic never suppresses a detection")
stale = [signed_event({"ts": now - 10000, "source": "firewall", "category": "scan",
                       "message": "port scan from 10.0.0.9"})]
ck(m.scan_sources_from_bus(stale, now, sources=("firewall",)) == set(),
   "a stale bus entry outside the window does not suppress")
sys.exit(0 if ok else 1)
PY
then pass "scan de-duplication assertions"; else fail "scan de-duplication assertions" "see output above"; fi

section "PCAP capture: bounded by construction"
if python3 - "$CAP" "$WORK" <<'PY'
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("cap", sys.argv[1]).load_module()
work = Path(sys.argv[2])
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# A real sysfs-shaped tree: enumeration reads the kernel's own layout.
sysfs = work / "sysclassnet"
for name, flags, state, mac in (("eth0", "0x1003", "up", "aa:bb:cc:dd:ee:ff"),
                                ("wlan0", "0x1002", "down", "11:22:33:44:55:66"),
                                ("lo", "0x9", "unknown", "")):
    d = sysfs / name; d.mkdir(parents=True, exist_ok=True)
    (d / "flags").write_text(flags); (d / "operstate").write_text(state)
    (d / "type").write_text("1"); (d / "address").write_text(mac)

ifaces = m.enumerate_interfaces(sysfs)
ck(m.interface_names(ifaces) == ["eth0", "lo", "wlan0"],
   f"interfaces enumerated from sysfs -> {m.interface_names(ifaces)}")
ck(m.find_interface("eth0", ifaces)["up"] is True, "IFF_UP decoded from the hex flags")
ck(m.find_interface("wlan0", ifaces)["up"] is False, "a DOWN interface is reported DOWN")
ck(m.find_interface("lo", ifaces)["loopback"] is True, "loopback is identified")
ck(m.enumerate_interfaces(work / "nope") == [],
   "an unreadable sysfs yields [] rather than raising")

BIG = 10_000_000  # plenty of free space

# --- the happy path states its bounds -------------------------------------
p = m.plan_capture("eth0", ifaces, free_mb=BIG, out_dir=work / "pcap")
ck(p["ok"] is True, "a bounded capture on a real interface is allowed")
ck(p["budget_mb"] == m.DEFAULT_FILE_MB * m.DEFAULT_FILES,
   f"budget is files x size = {p['budget_mb']} MB")
argv = " ".join(p["argv"])
ck("-b filesize:65536" in argv, f"ring file size passed to dumpcap in kB -> {argv}")
ck("-b files:8" in argv, "ring file COUNT passed to dumpcap (this is the disk cap)")
ck("-a duration:900" in argv, "duration passed as an AUTOSTOP (-a), not a rotation (-b)")
ck("-n" in p["argv"], "name resolution disabled: a capture must not generate traffic")
for token in ("512 MB", "900s", "ring 8 x 64 MB"):
    ck(token in p["message"], f"the announced bound states {token!r}")

# --- unbounded requests are REFUSED, not reinterpreted --------------------
r = m.plan_capture("eth0", ifaces, duration=0, free_mb=BIG)
ck(r["ok"] is False and r["reason"] == m.R_UNBOUNDED_TIME,
   f"--duration 0 is refused, not treated as unlimited -> {r['reason']}")
ck("no time bound" in r["message"], "the time refusal explains itself")
r = m.plan_capture("eth0", ifaces, files=0, free_mb=BIG)
ck(r["ok"] is False and r["reason"] == m.R_UNBOUNDED_SIZE,
   f"--files 0 (infinite ring) is refused -> {r['reason']}")
r = m.plan_capture("eth0", ifaces, file_mb=0, free_mb=BIG)
ck(r["ok"] is False and r["reason"] == m.R_UNBOUNDED_SIZE, "--max-file-mb 0 is refused")
r = m.plan_capture("eth0", ifaces, duration=-1, free_mb=BIG)
ck(r["ok"] is False and r["reason"] == m.R_UNBOUNDED_TIME, "a negative duration is refused")

# --- the hard ceiling cannot be argued with -------------------------------
r = m.plan_capture("eth0", ifaces, file_mb=1024, files=8, free_mb=BIG)
ck(r["ok"] is False and r["reason"] == m.R_OVER_CEILING,
   f"8192 MB exceeds the {m.HARD_CEILING_MB} MB per-capture ceiling")
ck(str(m.HARD_CEILING_MB) in r["message"], "the ceiling refusal states the ceiling")
r = m.plan_capture("eth0", ifaces, file_mb=512, files=8, free_mb=BIG)
ck(r["ok"] is True, f"exactly at the ceiling ({m.HARD_CEILING_MB} MB) is allowed")

# --- disk headroom --------------------------------------------------------
r = m.plan_capture("eth0", ifaces, free_mb=100)
ck(r["ok"] is False and r["reason"] == m.R_NO_SPACE,
   "a capture larger than free space is refused before it starts")
ck("100 MB free" in r["message"] and "512 MB" in r["message"],
   "the space refusal states BOTH numbers")
ck(m.plan_capture("eth0", ifaces, free_mb=512)["ok"] is False,
   "free space equal to the budget is still refused (headroom factor)")
ck(m.plan_capture("eth0", ifaces, free_mb=512 * m.FREE_SPACE_FACTOR)["ok"] is True,
   "free space meeting the headroom factor is allowed")

# --- a bogus interface is refused CLEANLY and helpfully -------------------
r = m.plan_capture("wlan99", ifaces, free_mb=BIG)
ck(r["ok"] is False and r["reason"] == m.R_UNKNOWN_IFACE,
   f"a bogus interface is refused -> {r['reason']}")
ck("wlan99" in r["message"], "the refusal names what was asked for")
for name in ("eth0", "wlan0", "lo"):
    ck(name in r["message"], f"the refusal lists {name} as an available interface")
ck(r["argv"] == [], "a refused capture produces no command to run")
r = m.plan_capture("eth0", [], free_mb=BIG)
ck(r["ok"] is False and r["reason"] == m.R_UNKNOWN_IFACE,
   "an empty interface list is a broken deck, not a quiet network")

# --- dumpcap absent is a loud refusal, not a fallback ---------------------
r = m.plan_capture("eth0", ifaces, free_mb=BIG, have_dumpcap=False)
ck(r["ok"] is False and r["reason"] == m.R_NO_DUMPCAP, "no dumpcap -> refused")
ck("wireshark-common" in r["message"], "the dumpcap refusal names the package that provides it")

# --- warnings do not block, but are never dropped -------------------------
r = m.plan_capture("eth0", ifaces, free_mb=BIG, ram_backed=True, out_dir="/var/lib/x")
ck(r["ok"] is True, "a RAM-backed target does not block the capture")
ck(any("MEMORY" in w for w in r["warnings"]),
   "a RAM-backed target IS warned about in capitals (it costs memory, not disk)")
r = m.plan_capture("wlan0", ifaces, free_mb=BIG)
ck(r["ok"] is True and any("DOWN" in w for w in r["warnings"]),
   "capturing on a DOWN interface is allowed but warned about")
r = m.plan_capture("lo", ifaces, free_mb=BIG)
ck(any("loopback" in w for w in r["warnings"]),
   "capturing on loopback warns that it is not network traffic")

# --- RAM-backed detection uses longest-prefix, not first match ------------
mounts = "overlay / overlay rw 0 0\n/dev/sda1 /mnt/evidence ext4 rw 0 0\ntmpfs /run tmpfs rw 0 0\n"
ck(m.fs_type_for("/var/lib/orionx/capture", m.parse_mounts(mounts)) == "overlay",
   "the live overlay is detected for a path under /")
ck(m.fs_type_for("/mnt/evidence/case1", m.parse_mounts(mounts)) == "ext4",
   "a deeper mountpoint wins over / (longest prefix, not first match)")
ck(m.is_ram_backed("/mnt/evidence/case1", mounts) is False,
   "persistent storage is not reported as RAM-backed")
ck(m.is_ram_backed("/var/lib/orionx/capture", mounts) is True,
   "the live overlay IS reported as RAM-backed")
ck(m.is_ram_backed("/anything", "") is False, "unparseable mounts fail safe (no false warning)")
sys.exit(0 if ok else 1)
PY
then pass "capture bounding assertions"; else fail "capture bounding assertions" "see output above"; fi

section "Capture end-to-end (real dumpcap stub, real rotation)"
# A stub dumpcap that actually writes ring files, so the state file, the bus
# events and the rotation bound are exercised for real rather than asserted.
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/dumpcap" <<'STUBEOF'
#!/usr/bin/env bash
# Minimal dumpcap stand-in: honours -w and -b files:N by writing that many
# ring files, then exits 0 as dumpcap does when an autostop is reached.
out=""; files=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w) out="$2"; shift 2 ;;
    -b) [[ "$2" == files:* ]] && files="${2#files:}"; shift 2 ;;
    -i|-a|-s|-f) shift 2 ;;
    *) shift ;;
  esac
done
base="${out%.pcapng}"
for ((i=1; i<=files; i++)); do printf 'PCAPSTUB%03d' "$i" > "${base}_0000${i}.pcapng"; done
exit 0
STUBEOF
chmod +x "$STUB/dumpcap"
export PATH="$STUB:$PATH"
CAPDIR="$WORK/pcaps"; STATED="$WORK/capstate"; mkdir -p "$STATED"
SYSFS="$WORK/sysclassnet"
CAPARGS=(--sysfs "$SYSFS" --dir "$CAPDIR" --state-dir "$STATED")

out="$("$CAP" list "${CAPARGS[@]}" 2>&1)"
if echo "$out" | grep -q 'eth0'; then pass "list shows a capturable interface"; else fail "list shows interfaces" "$out"; fi
if echo "$out" | grep -q 'dumpcap: .*dumpcap'; then pass "list reports dumpcap availability"; else fail "list reports dumpcap" "$out"; fi

out="$("$CAP" plan wlan99 "${CAPARGS[@]}" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then pass "CLI: a bogus interface exits non-zero"; else fail "bogus interface exit" "rc=$rc"; fi
if echo "$out" | grep -q 'REFUSED (unknown-interface)'; then pass "CLI: bogus interface refused cleanly by name"; else fail "bogus interface refusal" "$out"; fi

out="$("$CAP" run eth0 "${CAPARGS[@]}" --duration 5 --files 3 --max-file-mb 1 --dry-run 2>&1)"
if echo "$out" | grep -q 'ring 3 x 1 MB'; then pass "dry-run announces the exact bound"; else fail "dry-run bound" "$out"; fi
if echo "$out" | grep -q 'notice.*capture/capture'; then pass "dry-run emits a bus event for the start"; else fail "dry-run start event" "$out"; fi

out="$("$CAP" run eth0 "${CAPARGS[@]}" --duration 5 --files 3 --max-file-mb 1 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then pass "a real bounded capture completes"; else fail "capture completes" "rc=$rc $out"; fi
ringcount="$(find "$CAPDIR/eth0" -name 'eth0_*.pcapng' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$ringcount" == "3" ]]; then pass "rotation produced exactly the 3 ring files requested"; else fail "ring rotation" "got $ringcount files"; fi
if [[ ! -f "$STATED/eth0.json" ]]; then pass "state file is removed when the capture ends"; else fail "state cleanup" "$STATED/eth0.json still present"; fi

# State DURING a capture must describe the bound, for the Cockpit.
python3 - "$CAP" "$STATED" >/dev/null <<'PY'
import sys, time
from pathlib import Path
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("cap", sys.argv[1]).load_module()
d = Path(sys.argv[2])
m.write_json(d / "eth0.json", {"iface": "eth0", "started": time.time(),
                               "budget_mb": 512, "duration": 900,
                               "out_path": "/x/eth0.pcapng"})
m.write_json(d / "eth0.request.json", {"iface": "eth0"})
PY
act="$(python3 -c "
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('cap', '$CAP').load_module()
print(len(m.active_captures(m.Path('$STATED'))))")"
if [[ "$act" == "1" ]]; then pass "active_captures ignores the .request.json sidecar"; else fail "active capture listing" "got $act"; fi
out="$("$CAP" status "${CAPARGS[@]}" 2>&1)"
if echo "$out" | grep -q 'cap 512 MB'; then pass "status reports the bound a running capture is under"; else fail "status reports bound" "$out"; fi
rm -f "$STATED"/eth0*.json

section "Loud degradation"
if python3 - "$PD" "$CAP" "$WORK" <<'PY'
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("pd", sys.argv[1]).load_module()
c = SourceFileLoader("cap", sys.argv[2]).load_module()
work = Path(sys.argv[3])
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# EVERY Zeek state produces a message. None is silent.
states = [
    {"installed": False, "binary": "", "log_state": "absent", "log_dir": "",
     "logs": [], "considered": ["/opt/zeek/logs/current"], "usable": False},
    {"installed": True, "binary": "/opt/zeek/bin/zeek", "log_state": "empty",
     "log_dir": "/var/log/zeek", "logs": [], "considered": [], "usable": False},
    {"installed": True, "binary": "/opt/zeek/bin/zeek", "log_state": "unreadable",
     "log_dir": "/var/log/zeek", "logs": [], "considered": [], "usable": False},
    {"installed": True, "binary": "/opt/zeek/bin/zeek", "log_state": "ok",
     "log_dir": "/var/log/zeek", "logs": ["conn.log"], "considered": [], "usable": True},
    {"installed": True, "binary": "/opt/zeek/bin/zeek", "log_state": "absent",
     "log_dir": "", "logs": [], "considered": ["/opt/zeek/logs/current"], "usable": False},
]
for st in states:
    sev, msg = m.zeek_state_message(st)
    ck(sev in ("info", "notice", "warning", "critical") and len(msg) > 40,
       f"state {st['log_state']}/installed={st['installed']} produces a real message ({sev})")

# Zeek attached but seeing NOTHING is reported as a sensor problem.
ck(m.zeek_blind(0, 1000.0, 1000.0 + m.ZEEK_LIVENESS_SECONDS + 1) is True,
   "zero conn records after the liveness window IS reported")
ck(m.zeek_blind(0, 1000.0, 1000.0 + 5) is False,
   "zero conn records early is not yet a complaint (no false alarm on startup)")
ck(m.zeek_blind(1, 1000.0, 1000.0 + 99999) is False,
   "a deck that has seen traffic is never called blind")
ck(m.zeek_blind(0, 0.0, 99999.0) is False,
   "an ingest that never started cannot be blind")

# The ingest itself degrades quietly-but-not-silently: no logs, no crash.
zi = m.ZeekIngest(log_dirs=[work / "definitely-not-here"], use_path=False)
ck(zi.sync() is False, "sync() with no Zeek returns False rather than raising")
ck(zi.running is False, "ingest does not claim to be running when it is not")
st = zi.status()
ck(st["ingesting"] is False and st["conn_records"] == 0,
   "status reports honest zeros rather than absent keys")
zi.stop()
ck(zi.running is False, "stopping a non-running ingest is safe")

# Capture state for the Cockpit degrades to [] on an unreadable dir.
ck(m.capture_status(work / "no-such-capture-dir") == [],
   "capture status on a missing state dir is [] rather than an exception")
ck(c.current_tier_label(work / "no-posture-status.json") == "unknown",
   "orionx-capture reports an unknown posture rather than inventing a tier")
sys.exit(0 if ok else 1)
PY
then pass "loud degradation assertions"; else fail "loud degradation assertions" "see output above"; fi

section "Single authority + build wiring"
if grep -q '"orionx-event"' "$CAP"; then pass "capture publishes via the orionx-event CLI (one writer convention)"; else fail "capture uses orionx-event CLI"; fi
if grep -q 'source="zeek"' "$PD"; then pass "Zeek events are attributed to zeek on the bus"; else fail "zeek bus source"; fi
if ! grep -qE 'pip install|import requests|import yaml' "$PD" "$CAP"; then pass "stdlib only (no new runtime dependency)"; else fail "stdlib only" "external dependency found"; fi
# The posture authority must not be forked. orionx-capture may READ the status
# file; it must never write it or decide a tier.
if grep -q 'posture-status.json' "$CAP"; then pass "capture reads the posture status file"; else fail "capture reads posture status"; fi
if ! grep -qE 'threat-posture|write.*posture-status|parse_tier' "$CAP"; then pass "capture never writes posture — orionx-postured stays the single authority"; else fail "capture must not own posture" "found a posture write/parse in orionx-capture"; fi
if grep -q 'zeek_ingest' "$PD"; then pass "Zeek ingest is declared in the tier plan (visible in --print-plan)"; else fail "zeek_ingest in tier_plan"; fi
if python3 -c "
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('pd', '$PD').load_module()
sys.exit(0 if all(m.tier_plan(t, True)['zeek_ingest'] for t in ('0','1','2')) else 1)"; then
  pass "Zeek ingest is on at EVERY tier (passive, like scanwatch)"; else fail "zeek ingest at every tier"; fi
if python3 -c "
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('pd', '$PD').load_module()
sys.exit(0 if m.plan_actions(m.tier_plan('1', True), m.tier_plan('1', True)) == [] else 1)"; then
  pass "re-asserting a tier is still a no-op (zeek did not break idempotence)"; else fail "tier idempotence"; fi

# The template unit: hardened, not autostarted, not tier-coupled.
if grep -qE '^ExecStart=.*orionx-capture run %I' "$UNIT"; then pass "unit ExecStart is the in-unit entry point"; else fail "unit ExecStart"; fi
if grep -qE '^AmbientCapabilities=CAP_NET_RAW$' "$UNIT"; then pass "unit grants CAP_NET_RAW and nothing more"; else fail "unit CAP_NET_RAW"; fi
if grep -qE '^CapabilityBoundingSet=CAP_NET_RAW$' "$UNIT"; then pass "capability bounding set is the same single capability"; else fail "unit CapabilityBoundingSet"; fi
# Directive lines only: the unit's rationale comment mentions CAP_NET_ADMIN
# precisely to say it is NOT granted, and an earlier version of this check
# matched that comment and reported the unit over-privileged. Grep what
# systemd reads, not what the file says about itself.
if ! grep -vE '^\s*#' "$UNIT" | grep -q 'CAP_NET_ADMIN'; then pass "unit does NOT take CAP_NET_ADMIN (capture listens, it does not reconfigure)"; else fail "unit over-privileged" "CAP_NET_ADMIN granted"; fi
if grep -qE '^ProtectSystem=strict$' "$UNIT"; then pass "unit runs with ProtectSystem=strict"; else fail "unit ProtectSystem=strict"; fi
if grep -qE '^ProtectHome=yes$' "$UNIT"; then pass "unit cannot read the operator's home"; else fail "unit ProtectHome"; fi
if grep -qE '^NoNewPrivileges=yes$' "$UNIT"; then pass "unit sets NoNewPrivileges"; else fail "unit NoNewPrivileges"; fi
if grep -qE '^RestrictAddressFamilies=.*AF_PACKET' "$UNIT"; then pass "unit allows AF_PACKET (the capture socket)"; else fail "unit AF_PACKET"; fi
if ! grep -qE '^RestrictAddressFamilies=.*AF_INET' "$UNIT"; then pass "unit opens no IP sockets — it listens, it does not connect"; else fail "unit should not need AF_INET"; fi
if grep -qE '^Restart=no$' "$UNIT"; then pass "unit does NOT restart (a restarting capture is an unbounded capture)"; else fail "unit Restart=no" "an auto-restart defeats the duration bound"; fi
if ! grep -q '^\[Install\]' "$UNIT"; then pass "template unit has no [Install] (cannot and must not be enabled at boot)"; else fail "template must not be autostart-enabled"; fi

# --- Central build wiring (0615 / 0700) ----------------------------------
# These two hooks are integrated centrally, so this slice does not edit them.
# The assertions still run and still print: a capability that is built but not
# wired is exactly the failure this whole slice exists to fix. They are
# counted as PENDING rather than FAILED so the suite's exit code reflects the
# code this slice owns, and they flip to PASS the moment the wiring lands.
PENDING=0
pending() { PENDING=$((PENDING+1)); printf "  ${RED}WIRING PENDING${NC}: %s — %s\n" "$1" "$2"; }
H615="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"
H700="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
if grep -q 'orionx-capture@.service' "$H615"; then pass "capture unit staged in the 0615 hook"; else pending "0615 UNIT_FILES entry" "add \"orionx-capture@.service\" to UNIT_FILES (NOT to AUTOSTART_UNITS)"; fi
if ! awk '/^AUTOSTART_UNITS=\(/{a=1} a&&/orionx-capture@/{found=1} /^\)/{a=0} END{exit !found}' "$H615"; then
  pass "capture unit is NOT in AUTOSTART_UNITS (enable on a template fails, and capture is an operator action)"
else fail "capture must not be autostarted" "remove it from AUTOSTART_UNITS"; fi
if grep -q 'orionx-capture' "$H700"; then pass "orionx-capture symlinked into PATH by the 0700 hook"; else pending "0700 SCRIPT_MAP entry" "add [\"orionx-capture\"]=\"/opt/orionx/scripts/awareness/orionx-capture\""; fi
if grep -q '/opt/zeek/bin/zeek' "$H700"; then pass "zeek PATH symlink already registered in 0700 (skipped safely when absent)"; else fail "0700 zeek symlink"; fi
if grep -q 'install-zeek.sh' "$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"; then pass "package list points at the real install authority"; else fail "package list zeek comment" "still points somewhere else"; fi

# .gitignore excludes iso/config/includes.chroot/opt/orionx/ wholesale, but
# every sibling installer is force-added and tracked. An untracked installer
# is one that silently never ships — the same shape of bug as the soft-fail
# this slice exists to recover from, so it is asserted rather than assumed.
if git -C "$REPO_ROOT" ls-files --error-unmatch "$INSTALLER" >/dev/null 2>&1; then
  pass "install-zeek.sh is tracked by git (like its siblings)"
else
  pending "install-zeek.sh is UNTRACKED" "run: git add -f iso/config/includes.chroot/opt/orionx/optional/install-zeek.sh — the whole optional/ tree is gitignored and every sibling installer is force-added; without this the installer never ships"
fi

if command -v ruff >/dev/null 2>&1; then
  if ruff check --select E4,E7,E9,F "$PD" "$CAP" >/dev/null 2>&1; then pass "ruff check --select E4,E7,E9,F clean"; else fail "ruff check --select E4,E7,E9,F clean" "$(ruff check --select E4,E7,E9,F "$PD" "$CAP" 2>&1 | tail -3)"; fi
fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$INSTALLER" >/dev/null 2>&1; then pass "installer shellcheck clean"; else fail "installer shellcheck" "$(shellcheck -S warning "$INSTALLER" 2>&1 | tail -5)"; fi
fi
if bash -n "$INSTALLER"; then pass "installer parses (bash -n)"; else fail "installer bash -n"; fi

section "Managed sensor: orionx-zeek@.service + orionx.zeek policy + archive prune (#150, DEC-PHASE13-033)"
ZUNIT="$CHROOT/usr/share/orionx/systemd/orionx-zeek@.service"
ZPOLICY="$CHROOT/usr/share/orionx/zeek/orionx.zeek"
ZPRUNE="$REPO_ROOT/scripts/awareness/orionx-zeek-prune"
HOOK615="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"
if [[ -f "$ZUNIT" ]]; then pass "orionx-zeek@.service staged"; else fail "orionx-zeek@.service staged" "missing $ZUNIT"; fi
if [[ -f "$ZPOLICY" ]]; then pass "orionx.zeek site policy staged"; else fail "orionx.zeek staged" "missing $ZPOLICY"; fi
if [[ -x "$ZPRUNE" ]]; then pass "orionx-zeek-prune staged and executable"; else fail "orionx-zeek-prune executable" "missing or not +x"; fi
grep -q '@decision DEC-PHASE13-033' "$ZUNIT" && pass "unit carries DEC-PHASE13-033" || fail "unit decision annotation"
grep -qE '^ExecStart=/opt/zeek/bin/zeek -C -i %I /usr/share/orionx/zeek/orionx.zeek$' "$ZUNIT" \
    && pass "unit runs zeek -C -i %I with the Orion-X policy (not the stock 'local')" || fail "unit ExecStart" "$(grep '^ExecStart' "$ZUNIT")"
grep -vE '^\s*#' "$ZUNIT" | grep -qE '(^| )local( |$)' && fail "unit loads the stock 'local' policy (phones out: detect-MHR, reverse DNS)" || pass "unit never loads the stock 'local' policy"
grep -qE '^LogsDirectory=zeek/%i$' "$ZUNIT" && pass "each instance gets /var/log/zeek/<iface>/ (LogsDirectory=zeek/%i)" || fail "unit LogsDirectory"
grep -qE '^WorkingDirectory=/var/log/zeek/%i$' "$ZUNIT" && pass "Zeek writes its logs in the instance directory" || fail "unit WorkingDirectory"
grep -qE '^ConditionPathExists=/opt/zeek/bin/zeek$' "$ZUNIT" && pass "a start without the binary is a clean no-op (soft-fail build)" || fail "unit ConditionPathExists binary"
grep -qE '^ConditionPathExists=/sys/class/net/%i$' "$ZUNIT" && pass "a start on a missing interface is a clean no-op" || fail "unit ConditionPathExists iface"
grep -qE '^AmbientCapabilities=CAP_NET_RAW$' "$ZUNIT" && grep -qE '^CapabilityBoundingSet=CAP_NET_RAW$' "$ZUNIT" \
    && pass "exactly CAP_NET_RAW, like orionx-capture@" || fail "unit capabilities"
grep -vE '^\s*#' "$ZUNIT" | grep -q 'CAP_NET_ADMIN' && fail "unit over-privileged" "CAP_NET_ADMIN" || pass "no CAP_NET_ADMIN"
grep -qE '^RestrictAddressFamilies=AF_PACKET AF_NETLINK AF_UNIX$' "$ZUNIT" && pass "no AF_INET/AF_INET6: the sensor cannot connect anywhere" || fail "unit address families"
grep -qE '^ProtectSystem=strict$' "$ZUNIT" && pass "ProtectSystem=strict" || fail "unit ProtectSystem"
grep -qE '^MemoryMax=[0-9]+M$' "$ZUNIT" && pass "memory ceiling set for the 2 GB deck" || fail "unit MemoryMax"
grep -qE '^StartLimitBurst=[0-9]+$' "$ZUNIT" && grep -qE '^Restart=on-failure$' "$ZUNIT" && pass "restart is bounded by a start limit" || fail "unit restart bound"
grep -qE '^\[Install\]' "$ZUNIT" && fail "template has an [Install] section" || pass "no [Install] section (started per interface by postured, never enabled)"
# policy
for bad in 'frameworks/files/detect-MHR' 'extend-email/hostnames' 'protocols/ssh/geo-data'; do
    if grep -vE '^\s*#' "$ZPOLICY" | grep -q "$bad"; then fail "policy loads $bad (phones out / needs a DB the image lacks)"; else pass "policy does not load $bad"; fi
done
for good in 'protocols/conn/known-services' 'protocols/http/detect-sql-injection' 'protocols/ssh/detect-bruteforcing' 'frameworks/files/hash-all-files' 'misc/capture-loss'; do
    grep -qE "^@load(-sigs)? $good" "$ZPOLICY" && pass "policy loads $good" || fail "policy loads $good"
done
grep -qE '^redef Log::default_rotation_interval = 1hr;' "$ZPOLICY" && pass "hourly rotation (standalone zeek never rotates by default)" || fail "policy rotation interval"
grep -qE '^redef Log::default_rotation_dir = "archive";' "$ZPOLICY" && pass "rotated logs go to ./archive" || fail "policy rotation dir"
grep -qE '^redef Log::default_rotation_postprocessor_cmd = "/opt/orionx/scripts/awareness/orionx-zeek-prune";' "$ZPOLICY" && pass "the prune runs after every rotation" || fail "policy postprocessor"
grep -qE '^redef LogAscii::use_json = F;' "$ZPOLICY" && pass "TSV logs (zeek-cut, logquery, postured all read #fields)" || fail "policy TSV"
# hook + postured wiring
grep -qF '"orionx-zeek@.service"' "$HOOK615" && pass "0615 installs the template" || fail "0615 UNIT_FILES lacks orionx-zeek@.service"
awk '/^AUTOSTART_UNITS=\(/{p=1} p{print} /^\)/{if(p) p=0}' "$HOOK615" | grep -q 'orionx-zeek@' && fail "template in AUTOSTART_UNITS (cannot enable a bare template; Tier 0 starts nothing)" || pass "template is NOT in AUTOSTART_UNITS"
grep -q 'ZEEK_UNIT_TEMPLATE = "orionx-zeek@{iface}.service"' "$PD" && pass "postured names the same template" || fail "postured template name"
grep -q '@decision DEC-PHASE13-033\|DEC-PHASE13-033' "$PD" && pass "postured cites DEC-PHASE13-033" || fail "postured decision cite"
# prune, exercised on a fixture
ZW="$(mktemp -d "${TMPDIR:-$REPO_ROOT/tmp}/zeekprune.XXXXXX")"
mkdir -p "$ZW/eth0/archive"
# mtimes RELATIVE to now (python os.utime: portable, and a fixture stamped with
# absolute dates aged past the 24 h cap the day after it was written — CI run
# 41374029808 pruned all six files by age and the byte-cap assertions failed).
for i in 1 2 3 4 5; do head -c 1000 /dev/zero > "$ZW/eth0/archive/conn-2026-11-01-0$i-00-00.log"; done
head -c 1000 /dev/zero > "$ZW/eth0/archive/weird-old.log"
python3 - "$ZW/eth0/archive" <<'PY'
import os, sys, time
d, now = sys.argv[1], time.time()
for i in range(1, 6):   # conn-…-01 oldest (5 h ago) … conn-…-05 newest (1 h ago)
    t = now - (6 - i) * 3600
    os.utime(os.path.join(d, f"conn-2026-11-01-0{i}-00-00.log"), (t, t))
t = now - 400 * 86400   # well past the 24 h age cap
os.utime(os.path.join(d, "weird-old.log"), (t, t))
PY
ln -s conn-2026-11-01-05-00-00.log "$ZW/eth0/archive/link.log"
PRUNE_OUT="$(ORIONX_ZEEK_ARCHIVE_MAX_BYTES=2500 python3 "$ZPRUNE" "$ZW/eth0/archive/conn-2026-11-01-05-00-00.log" conn 26-11-01_04.00.00 26-11-01_05.00.00 0 ascii 2>&1)"; PRUNE_RC=$?
[[ $PRUNE_RC -eq 0 ]] && pass "prune exits 0" || fail "prune exit" "rc=$PRUNE_RC: $PRUNE_OUT"
[[ ! -e "$ZW/eth0/archive/weird-old.log" ]] && pass "a file past the age cap is removed" || fail "age cap" "$PRUNE_OUT"
[[ ! -e "$ZW/eth0/archive/conn-2026-11-01-01-00-00.log" && ! -e "$ZW/eth0/archive/conn-2026-11-01-02-00-00.log" && ! -e "$ZW/eth0/archive/conn-2026-11-01-03-00-00.log" ]] \
    && pass "oldest files go first until the byte cap holds" || fail "byte cap oldest-first" "$(ls "$ZW/eth0/archive")"
[[ -e "$ZW/eth0/archive/conn-2026-11-01-04-00-00.log" && -e "$ZW/eth0/archive/conn-2026-11-01-05-00-00.log" ]] && pass "newest files survive (2000 bytes <= 2500)" || fail "newest survive" "$(ls "$ZW/eth0/archive")"
[[ -L "$ZW/eth0/archive/link.log" ]] && pass "symlinks are never touched" || fail "symlink removed"
echo "$PRUNE_OUT" | grep -q 'removed 4 file' && pass "prune reports what it removed and why on stderr" || fail "prune report" "$PRUNE_OUT"
touch "$ZW/eth0/conn.log"
REFUSE_OUT="$(python3 "$ZPRUNE" "$ZW/eth0/conn.log" 2>&1)"; REFUSE_RC=$?
[[ $REFUSE_RC -eq 0 && -e "$ZW/eth0/conn.log" ]] && echo "$REFUSE_OUT" | grep -q "refusing" && pass "a path outside an 'archive' dir is refused, nothing deleted, exit 0" || fail "prune refusal" "rc=$REFUSE_RC $REFUSE_OUT"
python3 "$ZPRUNE" >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "no arguments -> usage, exit 2" || fail "prune usage exit"
rm -rf "$ZW"

section "export: the operator gets a 0600 copy; the ring stays root's (#109, DEC-PHASE13-021)"
EXR="$WORK/export"; mkdir -p "$EXR/cap/eth0" "$EXR/state" "$EXR/out"
printf 'old' > "$EXR/cap/eth0/eth0_00001_20261025100000.pcapng"
printf 'newest' > "$EXR/cap/eth0/eth0_00002_20261025100500.pcapng"
touch -t 202610251000 "$EXR/cap/eth0/eth0_00001_20261025100000.pcapng"
touch -t 202610251005 "$EXR/cap/eth0/eth0_00002_20261025100500.pcapng"
OUT="$(python3 "$CAP" export eth0 --dir "$EXR/cap" --state-dir "$EXR/state" --to "$EXR/out" 2>&1)"; rc=$?
COPY="$EXR/out/eth0_00002_20261025100500.pcapng"
if [[ $rc -eq 0 && -f "$COPY" && "$(cat "$COPY")" == "newest" ]]; then
  pass "export copies the NEWEST ring file"
else
  fail "export copies the NEWEST ring file" "rc=$rc $OUT"
fi
MODE="$(stat -c '%a' "$COPY" 2>/dev/null || stat -f '%Lp' "$COPY")"
[[ "$MODE" == "600" ]] && pass "the copy is mode 0600" || fail "the copy is mode 0600" "mode $MODE"
echo "$OUT" | grep -q "wireshark -r $COPY" && pass "export says how to open the copy" || fail "export says how to open the copy" "$OUT"
ls "$EXR/out" | grep -q '\.part$' && fail "no partial file left behind" "$(ls -a "$EXR/out")" || pass "no partial file left behind"
python3 "$CAP" export eth1 --dir "$EXR/cap" --state-dir "$EXR/state" --to "$EXR/out" >/dev/null 2>&1
[[ $? -eq 1 ]] && pass "an interface with no capture is refused (exit 1)" || fail "no-capture export" "did not exit 1"
python3 "$CAP" export ../etc --dir "$EXR/cap" --state-dir "$EXR/state" --to "$EXR/out" >/dev/null 2>&1
[[ $? -eq 2 ]] && pass "a path-like interface name is refused (exit 2)" || fail "path-like iface" "did not exit 2"
ERR="$(env -u SUDO_USER python3 "$CAP" export eth0 --dir "$EXR/cap" --state-dir "$EXR/state" 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && echo "$ERR" | grep -q -- "--to" && pass "without sudo or --to it refuses and says why" || fail "no destination" "rc=$rc $ERR"
if python3 - "$CAP" "$EXR" <<'PY'
import sys, types
from importlib.machinery import SourceFileLoader
cap = SourceFileLoader("cap", sys.argv[1]).load_module()
root = sys.argv[2]
cap.free_mb_for = lambda _p: 0.000001
args = types.SimpleNamespace(iface="eth0", dir=root + "/cap", state_dir=root + "/state",
                             to=root + "/full", dry_run=False, json=False)
sys.exit(0 if cap.cmd_export(args) == 1 else 1)
PY
then pass "export refuses when the destination cannot hold the copy"
else fail "export refuses when the destination cannot hold the copy"
fi

printf "\n===========================================\n"
if [[ ${PENDING:-0} -gt 0 ]]; then
  printf "  ${RED}%s central wiring entr(y/ies) PENDING${NC} — see WIRING above\n" "$PENDING"
fi
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
