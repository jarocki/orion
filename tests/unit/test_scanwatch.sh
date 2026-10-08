#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_scanwatch.sh — orionx-scanwatch port-scan detection (DEC-PHASE12-022)
#
# The Cockpit's network panel reads byte counters, so a scan looked like a
# throughput bump with no explanation. nftables already logs every dropped
# packet (DEC-SEC-001); this daemon turns that into R.A.I.N. events. These
# tests cover parsing, the detection windows, the false-positive guards, the
# memory bound, and the build wiring.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

SW="$REPO_ROOT/scripts/rain/orionx-scanwatch"
CHROOT="$REPO_ROOT/iso/config/includes.chroot"

section "Structure"
if [[ -f "$SW" ]]; then pass "orionx-scanwatch present"; else fail "orionx-scanwatch present" "missing"; exit 1; fi
if [[ -x "$SW" ]]; then pass "orionx-scanwatch executable"; else fail "orionx-scanwatch executable"; fi
if head -1 "$SW" | grep -q python3; then pass "python3 shebang"; else fail "python3 shebang"; fi
if grep -q '@decision DEC-PHASE12-022' "$SW"; then pass "carries decision annotation"; else fail "carries decision annotation"; fi

section "Detection logic"
if python3 - "$SW" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sw", sys.argv[1]).load_module()
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

real = ("Sep 24 13:37:02 orionx kernel: [ORIONX-DROP] IN=eth0 OUT= MAC=52:54:00:12:34:56 "
        "SRC=192.168.4.77 DST=192.168.4.42 LEN=44 PROTO=TCP SPT=54321 DPT=443 SYN URGP=0")
r = m.parse_drop_line(real)
check(r == {"src": "192.168.4.77", "port": 443, "proto": "tcp"}, f"parses a real drop line -> {r}")
check(m.parse_drop_line("kernel: usb 1-1: new high-speed USB device") is None, "ignores unrelated kernel lines")
check(m.parse_drop_line("[ORIONX-DROP] SRC=10.0.0.5 PROTO=ICMP TYPE=8") is None, "ignores drops with no DPT (ICMP)")
check(m.parse_drop_line("[ORIONX-DROP] SRC=10.0.0.5 DPT=99999 PROTO=TCP") is None, "rejects out-of-range port")

# An nmap sweep at the observed field rate (~4.3 ports/sec) must alert.
t = m.ScanTracker()
alerts = [a for a in (t.observe(1000.0 + i/4.3, "192.168.4.77", 20+i, "tcp") for i in range(60)) if a]
check(len(alerts) >= 1, f"nmap-rate sweep alerts ({len(alerts)} event(s))")
check(any(a["severity"] == "warning" for a in alerts), "first alert is warning")
check(any(a["severity"] == "critical" for a in alerts), "escalates to critical as the sweep widens")

# A handful of stray blocked packets is not a scan.
t2 = m.ScanTracker()
check(not any(t2.observe(2000.0+i, "10.0.0.5", 80+i, "tcp") for i in range(5)), "5 stray drops do not alert")

# One host hammering ONE port is a brute-force, not a port scan; must not fire.
t3 = m.ScanTracker()
check(not any(t3.observe(2500.0+i*0.1, "10.0.0.7", 22, "tcp") for i in range(200)), "single-port flood does not alert as a scan")

# Timing-evasive scan: below the fast window, caught by the wide one.
fast = m.ScanTracker()
check(not any(fast.observe(3000.0+i*30, "10.0.0.6", 100+i, "tcp") for i in range(40)), "slow scan evades the fast window")
slow = m.ScanTracker(window=m.SLOW_WINDOW_SECONDS, warn=m.SLOW_PORTS_WARNING,
                     crit=m.SLOW_PORTS_CRITICAL, reannounce=m.SLOW_REANNOUNCE_SECONDS,
                     label="slow port scan")
sa = [a for a in (slow.observe(3000.0+i*30, "10.0.0.6", 100+i, "tcp") for i in range(40)) if a]
check(len(sa) >= 1, f"wide window catches the slow scan ({len(sa)} event(s))")
check("slow port scan" in m.format_message(sa[0]), "slow scan is labelled distinctly")

# A spoofed-source flood must not grow memory without bound.
t4 = m.ScanTracker(max_sources=100)
for i in range(500):
    t4.observe(4000.0+i*0.01, f"10.1.{i//256}.{i%256}", 80, "tcp")
check(t4.tracked_sources() == 100, f"source table is bounded ({t4.tracked_sources()})")

# Throttle: an ongoing scan is not re-announced every packet.
t5 = m.ScanTracker()
many = [a for a in (t5.observe(5000.0 + i*0.01, "10.0.0.8", 1000+i, "tcp") for i in range(400)) if a]
check(len(many) <= 3, f"ongoing scan is throttled ({len(many)} events for 400 packets)")
sys.exit(0 if ok else 1)
PY
then pass "detection logic assertions"; else fail "detection logic assertions" "see output above"; fi

section "End-to-end via --stdin"
E2E="$(printf '[ORIONX-DROP] SRC=192.168.4.77 DST=192.168.4.42 PROTO=TCP DPT=%s SYN\n' $(seq 1 60) | python3 "$SW" --stdin --dry-run 2>&1)"
if echo "$E2E" | grep -q 'port scan from 192.168.4.77'; then pass "stdin pipeline emits a scan alert"; else fail "stdin pipeline emits a scan alert" "$E2E"; fi
if echo "$E2E" | grep -q 'critical'; then pass "full 60-port sweep reaches critical"; else fail "full 60-port sweep reaches critical" "$E2E"; fi

section "Bus + build wiring"
if grep -q '"orionx-event"' "$SW"; then pass "publishes via the orionx-event CLI (same as nucleotide)"; else fail "publishes via orionx-event CLI"; fi
if grep -q '"scan"' "$SW"; then pass "uses the existing 'scan' bus category"; else fail "uses 'scan' category"; fi
UNIT="$CHROOT/usr/share/orionx/systemd/orionx-scanwatch.service"
if [[ -f "$UNIT" ]]; then pass "systemd unit staged"; else fail "systemd unit staged" "missing $UNIT"; fi
H615="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"
if grep -q 'orionx-scanwatch.service' "$H615"; then pass "unit listed in 0615 hook"; else fail "unit listed in 0615 hook"; fi
if [[ "$(grep -c 'orionx-scanwatch.service' "$H615")" -ge 2 ]]; then pass "unit both staged and autostarted"; else fail "unit both staged and autostarted" "needs UNIT_FILES + AUTOSTART_UNITS"; fi
if grep -q 'orionx-scanwatch' "$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"; then pass "PATH symlink registered in 0700 hook"; else fail "PATH symlink registered in 0700 hook"; fi
if grep -q 'ORIONX-DROP' "$CHROOT/etc/nftables.conf"; then pass "firewall still logs drops with the expected prefix"; else fail "firewall drop-log prefix missing" "detector has no input"; fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
