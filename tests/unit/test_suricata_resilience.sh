#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_suricata_resilience.sh — Suricata actually captures (DEC-PHASE12-038)
#
# The deck shipped an IDS that could not start. Suricata 7.0.10 exited 1 on
# every attempt because Debian's unit hardcodes
#   -c /etc/suricata/suricata.yaml
# and Debian's suricata.yaml hardcodes
#   af-packet: - interface: eth0
# on a deck whose NIC is not called eth0:
#   Error: af-packet: eth0: failed to find interface: No such device
#
# DEC-PHASE12-034 bounded the resulting restart storm. This covers the cause.
#
# RESILIENCE.md rule 1 governs this file: assert EFFECTS, not implementations.
# The config is therefore validated by running `suricata -T` against it in a
# debian:trixie-slim container with the real package installed, not by
# grepping it for strings. Grep would have passed on every broken config this
# work replaced.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf "  ${YELLOW}SKIP${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

MOD="$REPO_ROOT/scripts/awareness/suricata_capture.py"
PD="$REPO_ROOT/scripts/awareness/orionx-postured"
CHROOT="$REPO_ROOT/iso/config/includes.chroot"
TOPCFG="$CHROOT/etc/suricata/orionx.yaml"
BASECFG="$CHROOT/var/lib/suricata/orionx-interfaces.yaml"
DROPIN="$CHROOT/etc/systemd/system/suricata.service.d/orionx-capture.conf"
TMP="$REPO_ROOT/tmp/suricata-resilience.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

section "Structure"
if [[ -f "$MOD" ]]; then pass "suricata_capture module present"; else fail "suricata_capture module present" "missing"; exit 1; fi
if grep -q '@decision DEC-PHASE12-038' "$MOD"; then pass "module carries the decision annotation"; else fail "module carries the decision annotation"; fi
if [[ -f "$TOPCFG" ]]; then pass "Orion-X suricata config staged"; else fail "Orion-X suricata config staged" "missing $TOPCFG"; fi
if [[ -f "$BASECFG" ]]; then pass "generated-interface baseline staged"; else fail "generated-interface baseline staged" "missing $BASECFG"; fi
if [[ -f "$DROPIN" ]]; then pass "capture drop-in staged"; else fail "capture drop-in staged" "missing $DROPIN"; fi
# The image must not inherit Debian's eth0 default by accident: the unit has
# to be pointed at Orion-X's config, or none of this is reachable at runtime.
if grep -q 'ExecStart=/usr/bin/suricata .*-c /etc/suricata/orionx.yaml' "$DROPIN"; then
  pass "drop-in points ExecStart at the Orion-X config"
else fail "drop-in points ExecStart at the Orion-X config"; fi
if grep -qE '^ExecStart=$' "$DROPIN"; then pass "drop-in resets ExecStart before setting it (systemd appends otherwise)"; else fail "drop-in resets ExecStart first" "systemd will run BOTH commands"; fi
# One authority for restarts. systemd's own Restart=on-failure fighting
# orionx-postured's bounded recovery is what produced the observed storm.
if grep -qE '^Restart=no$' "$DROPIN"; then pass "systemd restart disabled; postured is the single restart authority"; else fail "Restart=no missing" "two components will restart one service"; fi

section "Interface selection from kernel counters"
if python3 - "$MOD" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

def feed(hb, series, t0=1000.0, step=5.0):
    """series: list of {iface: rx} snapshots."""
    t = t0
    for counts in series:
        hb.observe(counts, t); t += step
    return t - step

# A dead interface with a huge LIFETIME counter must never read as live.
# This is the whole reason the threshold is a delta and not a non-zero test:
# rx_packets never decreases, so "has packets" on the raw counter marks an
# unplugged NIC live forever.
hb = m.InterfaceHeartbeat(window=30.0, min_packets=5, quiet_demote=300.0)
now = feed(hb, [{"eth0": 1000 + i*10, "wlan0": 9_000_000} for i in range(8)])
ck(hb.live(now) == {"eth0"}, f"busy iface live, dead-but-huge-counter iface not -> {sorted(hb.live(now))}")
ck(hb.selected(now) == ("eth0",), f"selection follows the measurement -> {hb.selected(now)}")

# The QUIET interface case. Under the threshold is not live, at it is.
hb2 = m.InterfaceHeartbeat(window=30.0, min_packets=5, quiet_demote=300.0)
n2 = feed(hb2, [{"eth0": 100 + i} for i in range(7)])   # +6 over 30s
ck("eth0" in hb2.live(n2), f"6 packets in the window clears a 5-packet threshold -> {hb2.rates(n2)['eth0']}")
hb3 = m.InterfaceHeartbeat(window=30.0, min_packets=5, quiet_demote=300.0)
n3 = feed(hb3, [{"eth0": 100 + (i // 3)} for i in range(7)])  # +2 over 30s
ck(hb3.live(n3) == set(), f"2 packets in the window does NOT -> {hb3.rates(n3)['eth0']}")

# Loopback is excluded by TYPE, not by the name "lo".
import tempfile, pathlib, os
with tempfile.TemporaryDirectory(dir=os.environ.get("ORIONX_TMP", "tmp")) as td:
    root = pathlib.Path(td)
    def mk(name, typ, rx):
        d = root / name / "statistics"; d.mkdir(parents=True)
        (root / name / "type").write_text(str(typ))
        (d / "rx_packets").write_text(str(rx))
    mk("lo", 772, 12345)
    mk("enp2s0", 1, 50)
    mk("lo-fake", 1, 7)        # named like loopback, type says otherwise
    mk("weird", 772, 99)       # named normally, type says loopback
    names = m.list_interfaces(root)
    ck("lo" not in names and "weird" not in names, f"loopback excluded by ARPHRD type -> {names}")
    ck("lo-fake" in names and "enp2s0" in names, f"non-loopback kept regardless of name -> {names}")
    snap = m.sample_interfaces(root)
    ck(snap.get("enp2s0") == 50, f"rx_packets read from sysfs -> {snap}")
    (root / "enp2s0" / "statistics" / "rx_packets").write_text("not-a-number")
    ck("enp2s0" not in m.sample_interfaces(root), "unreadable counter is omitted, not recorded as zero")

# APPEARS later: a USB NIC plugged in mid-incident.
hb4 = m.InterfaceHeartbeat(window=30.0, min_packets=5, quiet_demote=300.0)
t = feed(hb4, [{"eth0": 100 + i*10} for i in range(8)])
ck(hb4.selected(t) == ("eth0",), "before the USB NIC exists, only eth0")
for i in range(8):
    t += 5.0
    hb4.observe({"eth0": 180 + i*10, "usb0": 0 + i*10}, t)
ck(hb4.selected(t) == ("eth0", "usb0"), f"USB NIC appearing mid-incident joins the set -> {hb4.selected(t)}")

# DISAPPEARS: unplugged. Must leave at once -- measured in a container, one
# unopenable device fails the WHOLE engine, not just its own thread, so
# keeping it to avoid a restart would cost all capture at the next start.
for i in range(3):
    t += 5.0
    hb4.observe({"eth0": 260 + i*10}, t)
ck(hb4.selected(t) == ("eth0",), f"vanished interface leaves the set immediately -> {hb4.selected(t)}")
ck("usb0" not in hb4.present, "vanished interface is no longer a candidate")

# A counter that goes BACKWARDS (driver reload / device recreated) must not
# produce a negative or absurd delta.
hb5 = m.InterfaceHeartbeat(window=30.0, min_packets=5)
t5 = feed(hb5, [{"eth0": 1_000_000}, {"eth0": 1_000_050}, {"eth0": 3}])
ck(hb5.rates(t5)["eth0"]["packets"] >= 0, "counter reset does not yield a negative delta")
ck(hb5.live(t5) == set(), "counter reset does not fake a burst of traffic")

# Bound the interface count on a deck full of veths; keep the busiest.
hb6 = m.InterfaceHeartbeat(window=30.0, min_packets=5, max_ifaces=2)
t6 = 1000.0
for i in range(8):
    hb6.observe({f"veth{n}": 10 * i * (n + 1) for n in range(6)}, t6 + i*5)
t6 = t6 + 35
sel = hb6.selected(t6)
ck(len(sel) == 2, f"interface count is bounded -> {sel}")
ck("veth5" in sel, f"the busiest interface is kept -> {sel}")

# A pinned interface bypasses the liveness test but must still EXIST.
hb7 = m.InterfaceHeartbeat(window=30.0, min_packets=5, pinned=("span0", "ghost0"))
t7 = feed(hb7, [{"eth0": 100 + i*10, "span0": 1} for i in range(8)])
ck(hb7.selected(t7) == ("eth0", "span0"), f"silent pinned port is captured anyway -> {hb7.selected(t7)}")
ck("ghost0" not in hb7.selected(t7), "a pinned interface that does not exist is NOT configured")
sys.exit(0 if ok else 1)
PY
then pass "interface selection assertions"; else fail "interface selection assertions" "see output above"; fi

section "Anti-thrash: a flapping link must not restart the IDS"
if python3 - "$MOD" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# A link that comes and goes every 30s. Reconfiguring Suricata means
# restarting it, and a restart is a gap in coverage, so the correct number of
# restarts for a flap is ZERO. Hysteresis, not the cooldown, has to carry
# this: the cooldown only bounds the rate, it does not stop the churn.
hb = m.InterfaceHeartbeat(window=30.0, min_packets=5, quiet_demote=300.0)
brake = m.ReconfigureBrake(cooldown=120.0)
t = 1000.0
rx = {"eth0": 0, "flap0": 0}
applied = []
for cycle in range(40):           # 40 cycles x 15s = 10 minutes
    for _ in range(3):
        rx["eth0"] += 50
        if (cycle // 2) % 2 == 0:  # flap0 alive for 30s, dead for 30s
            rx["flap0"] += 50
        hb.observe(dict(rx), t); t += 5.0
    desired = hb.selected(t)
    d = brake.decide(desired, t, present=hb.present)
    if d["act"]:
        brake.note_applied(desired, t)
        applied.append((round(t - 1000.0), desired))
ck(len(applied) == 1, f"a 10-minute flap costs exactly ONE apply -> {applied}")
ck(applied and set(applied[0][1]) == {"eth0", "flap0"},
   f"the flapping interface stays in the set rather than churning -> {applied}")

# Hysteresis has a limit: an interface genuinely quiet past the hold time IS
# dropped. Otherwise a NIC unplugged an hour ago stays in the config forever
# and the next start fails on it.
hb2 = m.InterfaceHeartbeat(window=30.0, min_packets=5, quiet_demote=300.0)
t2 = 2000.0
for i in range(8):
    hb2.observe({"eth0": 100 + i*50, "idle0": 50 + i*50}, t2); t2 += 5.0
ck(set(hb2.selected(t2)) == {"eth0", "idle0"}, "both start out selected")
for i in range(40):               # idle0 stops; eth0 keeps going
    hb2.observe({"eth0": 500 + i*50, "idle0": 400}, t2); t2 += 10.0
ck(hb2.selected(t2) == ("eth0",), f"quiet past the hold time IS dropped -> {hb2.selected(t2)}")

# The cooldown is the second brake, for a set that genuinely keeps changing.
b = m.ReconfigureBrake(cooldown=120.0)
b.note_applied(("eth0",), 1000.0)
d1 = b.decide(("eth0", "eth1"), 1030.0, present={"eth0", "eth1"})
ck(d1["act"] is False and d1["reason"] == "cooldown", f"a change inside the cooldown is deferred -> {d1}")
d2 = b.decide(("eth0", "eth1"), 1121.0, present={"eth0", "eth1"})
ck(d2["act"] is True and d2["reason"] == "changed", f"and applied once the cooldown expires -> {d2}")

# ... but a VANISHED interface overrides the cooldown. Waiting it out would
# mean waiting with an engine configured against a device that is gone, and
# one bad device fails the whole engine at the next start.
b2 = m.ReconfigureBrake(cooldown=120.0)
b2.note_applied(("eth0", "usb0"), 1000.0)
d3 = b2.decide(("eth0",), 1010.0, present={"eth0"})
ck(d3["act"] is True and d3["reason"] == "interface-vanished", f"unplug beats the cooldown -> {d3}")

# Idempotence: the same set, re-offered, is never an apply, at any time.
b3 = m.ReconfigureBrake(cooldown=120.0)
b3.note_applied(("eth0",), 1000.0)
decisions = [b3.decide(("eth0",), 1000.0 + i*300.0, present={"eth0"}) for i in range(10)]
ck(not any(d["act"] for d in decisions), "re-offering an unchanged set never reconfigures")
ck(all(d["reason"] == "unchanged" for d in decisions), "and says why")
sys.exit(0 if ok else 1)
PY
then pass "anti-thrash assertions"; else fail "anti-thrash assertions" "see output above"; fi

section "Generated config: idempotent, and shaped the way the engine demands"
if python3 - "$MOD" <<'PY'
import sys, os, tempfile, pathlib
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# Byte-identical renders are what let the writer skip a restart. A timestamp
# in the file would silently defeat every idempotence check below.
a = m.render_interfaces_yaml(("eth0", "wlan0"))
b = m.render_interfaces_yaml(("wlan0", "eth0"))
ck(a == b, "render is order-independent and byte-stable")
ck(a == m.render_interfaces_yaml(("eth0", "wlan0", "eth0")), "duplicates collapse")
ck("\n# Generated" not in a.split("af-packet:")[1], "no timestamp or varying content in the body")

# Measured in a container: two af-packet entries sharing a cluster-id fail
# with "failed to set fanout mode: Invalid argument" and the engine dies.
ids = [cid for _, cid in m.allocate_cluster_ids(("a", "b", "c", "d"))]
ck(len(set(ids)) == 4, f"every interface gets a distinct cluster-id -> {ids}")

# Measured: an included file that does not open with these two lines is a
# fatal config error ("The configuration file must begin with ...").
ck(a.startswith("%YAML 1.1\n---\n"), "generated include opens with the two lines Suricata requires")

with tempfile.TemporaryDirectory(dir=os.environ.get("ORIONX_TMP", "tmp")) as td:
    path = pathlib.Path(td) / "sub" / "orionx-interfaces.yaml"
    r1 = m.write_interfaces_yaml(("eth0",), path)
    ck(r1["ok"] and r1["changed"] and path.exists(), "first write creates the include (parents too)")
    r2 = m.write_interfaces_yaml(("eth0",), path)
    ck(r2["ok"] and r2["changed"] is False, "re-writing the same set changes nothing")
    r3 = m.write_interfaces_yaml(("eth0", "eth1"), path)
    ck(r3["changed"] is True, "a different set does change it")
    # Reality can drift behind our back. The comparison is against the FILE,
    # not against what we remember writing (RESILIENCE.md rule 2).
    path.write_text("vandalised")
    r4 = m.write_interfaces_yaml(("eth0", "eth1"), path)
    ck(r4["changed"] is True and "af-packet" in path.read_text(), "a file edited behind our back is repaired")
    r5 = m.write_interfaces_yaml(("eth0",), path, dry_run=True)
    ck(r5["changed"] is True and "eth1" in path.read_text(), "dry-run writes nothing")
    bad = pathlib.Path(td) / "nope" / "x"
    bad.parent.mkdir(); bad.parent.chmod(0o500)
    r6 = m.write_interfaces_yaml(("eth0",), bad)
    ck(r6["ok"] is False and r6["error"], f"an unwritable path reports failure rather than claiming success -> {r6['error']}")
    bad.parent.chmod(0o700)

# The empty set must still render a PARSEABLE file. Measured: `suricata -T`
# against this exits 0, while a real start exits 1 with "No interface found
# in config for af-packet" -- which is exactly why nothing starts it.
empty = m.render_interfaces_yaml(())
ck(empty.startswith("%YAML 1.1\n---\n") and "af-packet:" in empty, "the no-interface baseline is still a valid document")
ck("interface: default" in empty, "the baseline carries only the settings template, not a capture device")
sys.exit(0 if ok else 1)
PY
then pass "generated config assertions"; else fail "generated config assertions" "see output above"; fi

section "Verification: proving capture, not proving a zero exit status"
if python3 - "$MOD" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# Response shapes are the ones measured from suricata 7.0.10, not invented.
LIST = '{"message": {"count": 2, "ifaces": ["eth0", "dummy0"]}, "return": "OK"}'
STAT = '{"message": {"pkts": 8, "invalid-checksums": 0, "drop": 0, "bypassed": 0}, "return": "OK"}'
ck(m.parse_iface_list(LIST) == ["eth0", "dummy0"], "iface-list parsed")
ck(m.parse_iface_stat(STAT) == {"pkts": 8, "drop": 0}, "iface-stat parsed")

# "Could not ask" and "the engine says nothing is attached" are different
# facts with different remedies, so None is never conflated with [].
ck(m.parse_iface_list(None) is None, "no answer -> None, not an empty set")
ck(m.parse_iface_list("") is None, "empty answer -> None")
ck(m.parse_iface_list("Connection refused") is None, "non-JSON answer -> None")
ck(m.parse_iface_list('{"return": "NOK", "message": "x"}') is None, "an error reply is not an interface list")
ck(m.parse_iface_stat('{"message": {}, "return": "OK"}') is None, "a reply with no counter is not a count")

class Fake:
    """Stands in for suricatasc."""
    def __init__(self, listing=LIST, stat=STAT): self.listing, self.stat = listing, stat
    def __call__(self, argv, **kw):
        cmd = argv[2]
        out = self.listing if cmd == "iface-list" else self.stat
        if out is None:
            raise OSError("socket gone")
        class R: pass
        r = R(); r.stdout = out; r.stderr = ""; r.returncode = 0
        return r

import pathlib
sock = pathlib.Path("/definitely/not/here.socket")
v = m.verify_capture(("eth0", "dummy0"), sock, runner=Fake())
ck(v["verified"] is True, f"engine attached to what we asked for -> {v['verified']}")
ck(v["total_packets"] == 16, f"packet evidence collected -> {v['total_packets']}")

# The failure this whole exercise exists to catch: the unit is "active", and
# the engine is not on the interface we asked for.
v2 = m.verify_capture(("eth0", "wlan0"), sock, runner=Fake())
ck(v2["verified"] is False, "a mismatch is reported as NOT verified")
ck(v2["missing"] == ["wlan0"], f"and names the missing interface -> {v2['missing']}")

# Unreachable engine: tri-state. Never True, and never False either -- "I
# could not ask" must not be reported as "it is wrong", nor as success.
v3 = m.verify_capture(("eth0",), sock, runner=Fake(listing=None))
ck(v3["verified"] is None, f"unreachable engine -> None, never success -> {v3['verified']}")
ck(v3["reason"], f"and says why -> {v3['reason']}")

# THE FAILURE iface-list CANNOT SEE. Measured: with two interfaces sharing a
# cluster-id the engine logs "failed to init socket for interface", then
# stays up answering iface-list with BOTH interfaces and iface-stat with
# pkts: 0, indefinitely. A verifier trusting iface-list alone calls that deck
# fully covered. The engine's own log is what closes the gap.
LOG = """[10 - Suricata-Main] 2026-10-02 04:25:06 Notice: suricata: This is Suricata version 7.0.10 RELEASE running in SYSTEM mode
[10 - Suricata-Main] 2026-10-02 04:25:06 Info: cpu: CPUs/cores online: 10
[23 - W#01-eth0] 2026-10-02 04:25:06 Error: af-packet: eth0: failed to set fanout mode: Invalid argument
[23 - W#01-eth0] 2026-10-02 04:25:06 Error: af-packet: eth0: failed to init socket for interface
"""
errs = m.socket_errors(LOG)
ck(errs.get("eth0", "").startswith("failed to set fanout"), f"a failed capture socket is read from the engine log -> {errs}")
ck(m.socket_errors("") == {}, "an empty log reports no errors")
ck(m.socket_errors("Error: detect: something unrelated") == {}, "non-capture errors are not capture errors")

# Errors from a PREVIOUS, already-fixed run must not be reported forever:
# the log is appended across restarts, and every start writes the banner.
OLD_THEN_GOOD = LOG + "[10 - Suricata-Main] 2026-10-02 05:00:00 Notice: suricata: This is Suricata version 7.0.10 RELEASE running in SYSTEM mode\n[10 - Suricata-Main] 2026-10-02 05:00:01 Info: threads: Threads created\n"
ck(m.socket_errors(OLD_THEN_GOOD) == {}, "errors before the latest start banner are not attributed to this run")

class FakeErr(Fake):
    pass
v4 = m.verify_capture(("eth0",), sock, runner=Fake(), engine_log="/definitely/absent")
ck(v4["verified"] is True and v4["configured"] is True, "with no engine log and a matching iface-list, verification holds")
import tempfile, os, pathlib as _pl
with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False,
                                 dir=os.environ.get("ORIONX_TMP", "tmp")) as fh:
    fh.write(LOG); logp = fh.name
v5 = m.verify_capture(("eth0", "dummy0"), sock, runner=Fake(), engine_log=logp)
ck(v5["verified"] is False, "a failed capture socket defeats verification even though iface-list agrees")
ck(v5["configured"] is True, "and the two facts are reported separately, not conflated")
ck(v5["capturing"] is True or v5["capturing"] is False, "capturing is reported as its own fact")
sev, msg, detail = m.socket_error_message(v5)
ck(sev == "critical", f"an up-but-blind engine is critical -> {sev}")
ck("fanout" in msg and "cluster-id" in msg, "the message names the usual cause")
os.unlink(logp)

# A zero packet count is NOT by itself a failure: a quiet network is real.
v6 = m.verify_capture(("eth0", "dummy0"), sock, runner=Fake(stat='{"message": {"pkts": 0, "drop": 0}, "return": "OK"}'), engine_log="/definitely/absent")
ck(v6["capturing"] is False, "zero packets is reported as not-yet-capturing")
ck(v6["verified"] is True, "but is not called a failure -- prolonged silence is judged over a window instead")

# `suricata -T`: measured on 7.0.10, a perfectly valid config EXITS 1 when no
# rule file matched. Gating a start on the exit code would refuse to start a
# working IDS on every deck that has not fetched ET-Open yet.
no_rules = m.classify_config_test(1, "W: detect: No rule files match the pattern /var/lib/suricata/rules/suricata.rules")
ck(no_rules["verdict"] == "no-rules", f"valid config + no rules is NOT a config failure -> {no_rules}")
good = m.classify_config_test(0, "i: suricata: Configuration provided was successfully loaded. Exiting.")
ck(good["verdict"] == "ok", "a loaded config is ok")
bad = m.classify_config_test(1, "Error: conf-yaml-loader: Failed to include configuration file /x.yaml")
ck(bad["verdict"] == "invalid" and "conf-yaml-loader" in bad["error"], f"a rejected config is invalid and quotes the error -> {bad['error']}")
bad2 = m.classify_config_test(1, "E: suricata: No interface found in config for af-packet")
ck(bad2["verdict"] == "invalid", "the empty-af-packet fatal is recognised as invalid")
sys.exit(0 if ok else 1)
PY
then pass "verification assertions"; else fail "verification assertions" "see output above"; fi

section "Degradation is loud, names the remedy, and is never a 'threat'"
if python3 - "$MOD" "$PD" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
pd = SourceFileLoader("pd", sys.argv[2]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

status = {"candidates": ["enp2s0"], "rates": {"enp2s0": 0.0}, "packets": {"enp2s0": 0},
          "window_seconds": 30.0, "min_packets": 5, "observed_seconds": 120.0}
sev, msg, detail = m.no_live_message(status, "Tier 1 · Active Monitoring")
ck("NOT started" in msg, "says what is not working")
ck("NO IDS coverage" in msg, "says the consequence")
ck("scanwatch" in msg, "says what still works, so it is not read as total blindness")
ck("ip link set" in msg and "--capture-iface" in msg, "names exact remedy commands")
ck(detail["rates"] == {"enp2s0": 0.0}, "detail carries the measured evidence for the drill-down")

for fn, args in ((m.absent_message, ("Tier 1",)),
                 (m.invalid_config_message, ({"error": "boom"},)),
                 (m.capture_mismatch_message, ({"attached": ["eth0"]}, ("wlan0",), "Tier 1")),
                 (m.capture_blind_message, ({"attached": ["eth0"]}, 600.0)),
                 (m.unverified_message, ({"reason": "no socket"}, ("eth0",)))):
    sev, msg, detail = fn(*args)
    ck(sev in ("notice", "warning", "critical"), f"{fn.__name__} severity {sev}")
    ck("scanwatch" in msg, f"{fn.__name__} says what still works")
    ck(any(k in msg for k in ("Remedy", "check ", "Check ")), f"{fn.__name__} names a remedy")
    ck(isinstance(detail, dict) and detail.get("reason"), f"{fn.__name__} carries structured detail")

# RESILIENCE.md rule 5. Self-diagnosis must not reach the threat gauge:
# pressure() excludes health/posture/service/tooling and does NOT exclude ids.
src = open(sys.argv[2]).read()
ck('"ids",\n                  no_rules_message' not in src, "the no-rules warning is no longer category ids")
ck('NO_RULES_REPEAT, "health"' in src, "the no-rules warning is category health")
ck('"nebula", "ids"' not in src, "Nebula tooling events are not category ids")
ck(src.count('publish("info", "nebula", "tooling"') == 1, "the alert annotation does not double-count as a detection")
sys.exit(0 if ok else 1)
PY
then pass "degradation assertions"; else fail "degradation assertions" "see output above"; fi

section "Posture integration: Tier 0 starts nothing, Tier 1 starts only what can work"
if python3 - "$PD" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
pd = SourceFileLoader("pd", sys.argv[1]).load_module()
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

# Tier 0 starts nothing and sends nothing -- including no capture, no
# generated config and no interface list, however busy the network is.
t0 = pd.tier_plan("0", True, live_ifaces=("eth0", "wlan0"))
ck(t0["suricata"] is False and t0["gate_file"] is False, "Tier 0 still starts nothing with live interfaces present")
ck(t0["capture_ifaces"] == (), f"Tier 0 configures no capture -> {t0['capture_ifaces']}")
ck(t0["warn_no_capture"] is False, "Tier 0 does not warn about capture it never claimed")
ck(pd.plan_actions(None, t0) == [] or all(a[0] not in ("capture", "service", "gate") for a in pd.plan_actions(None, t0)),
   f"Tier 0 plans no capture/service/gate actions -> {pd.plan_actions(None, t0)}")

# Tier 1 with a live interface: config written BEFORE the service starts.
t1 = pd.tier_plan("1", True, live_ifaces=("eth0",))
ck(t1["suricata"] is True and t1["capture_ifaces"] == ("eth0",), "Tier 1 captures the live interface")
acts = pd.plan_actions(None, t1)
kinds = [a[0] for a in acts]
ck("capture" in kinds and "service" in kinds, f"Tier 1 plans both -> {kinds}")
ck(kinds.index("capture") < kinds.index("service"),
   "the interface list is written BEFORE the engine is started (it reads config once, at start)")
ck(kinds.index("gate") < kinds.index("service"), "the DEC-PHASE11-008 gate still precedes the start")

# Tier 1 with NO live interface: do not start something that cannot work.
t1n = pd.tier_plan("1", True, live_ifaces=())
ck(t1n["suricata"] is False, "Tier 1 with no live interface does NOT start Suricata")
ck(t1n["warn_no_capture"] is True, "and raises the no-capture warning instead")
ck(t1n["gate_file"] is True, "the gate still reflects the operator's tier intent")
acts_n = pd.plan_actions(None, t1n)
ck(not any(a[0] == "service" for a in acts_n), f"no doomed start is planned -> {acts_n}")
ck(("warn", "no-capture") in acts_n, "the gap is announced")

# Re-applying an unchanged plan must be a no-op: no write, no restart.
ck(pd.plan_actions(t1, t1) == [], f"same tier + same interfaces = no actions -> {pd.plan_actions(t1, t1)}")

# A changed interface set restarts rather than stop+start: one systemd
# transaction, so the reassert loop never sees a gap and spends a recovery
# attempt on a service we are deliberately cycling.
t1b = pd.tier_plan("1", True, live_ifaces=("eth0", "usb0"))
acts_c = pd.plan_actions(t1, t1b)
ck(("service", "restart", pd.SURICATA_UNIT) in acts_c, f"a new interface restarts the engine -> {acts_c}")
ck(not any(a[:2] == ("service", "stop") for a in acts_c), "and never stop+start")
ck(("capture", "write", ("eth0", "usb0")) in acts_c, "with the new list written first")

# Back-compat: callers that know nothing about capture still get tier intent.
legacy = pd.tier_plan("1", True)
ck(legacy["suricata"] is True, "an unmeasured plan still describes the tier's intent")
ck(legacy["warn_no_capture"] is False, "and does not claim a gap it has not measured")
sys.exit(0 if ok else 1)
PY
then pass "posture integration assertions"; else fail "posture integration assertions" "see output above"; fi

section "End to end: the daemon against a fixture /sys"
SYSFS="$TMP/sys"
mkdir -p "$SYSFS"
mkfs_iface() { mkdir -p "$SYSFS/$1/statistics"; echo "$2" > "$SYSFS/$1/type"; echo "$3" > "$SYSFS/$1/statistics/rx_packets"; }
mkfs_iface lo 772 500000
mkfs_iface enp2s0 1 1000
mkfs_iface wlan0 1 9000000
echo 0 > "$TMP/posture"
E2E0="$(python3 "$PD" --once --dry-run --no-nebula --posture-file "$TMP/posture" \
        --sysfs "$SYSFS" --interfaces-yaml "$TMP/ifaces.yaml" \
        --suricata-config "$TOPCFG" --rules-dir "$TMP/rules" --canary-dir "$TMP/canary" 2>&1)"
if ! echo "$E2E0" | grep -qE 'systemctl (start|restart) suricata'; then pass "Tier 0 end to end starts no service"; else fail "Tier 0 starts nothing" "$E2E0"; fi
if ! echo "$E2E0" | grep -q 'gate create'; then pass "Tier 0 creates no lazy-start gate"; else fail "Tier 0 creates no gate" "$E2E0"; fi
if [[ ! -f "$TMP/ifaces.yaml" ]]; then pass "Tier 0 writes no interface config"; else fail "Tier 0 writes no interface config"; fi

echo 1 > "$TMP/posture"
# A single sample cannot distinguish "no traffic" from "not measured yet",
# and claiming the former one second after boot is a false alarm that costs
# the operator's trust in every later warning. Silence here is the assertion.
WARM="$(python3 "$PD" --once --dry-run --no-nebula --posture-file "$TMP/posture" \
        --sysfs "$SYSFS" --interfaces-yaml "$TMP/ifaces.yaml" \
        --suricata-config "$TOPCFG" --rules-dir "$TMP/rules" --canary-dir "$TMP/canary" 2>&1)"
if ! echo "$WARM" | grep -q 'no network interface is carrying traffic'; then pass "during warm-up the deck does not cry wolf about interfaces"; else fail "warm-up suppression" "$WARM"; fi

# Once the measurement window has genuinely elapsed, it must say so.
E2E1="$(python3 "$PD" --once --dry-run --no-nebula --posture-file "$TMP/posture" \
        --sysfs "$SYSFS" --interfaces-yaml "$TMP/ifaces.yaml" --live-window 0 \
        --suricata-config "$TOPCFG" --rules-dir "$TMP/rules" --canary-dir "$TMP/canary" 2>&1)"
if echo "$E2E1" | grep -q 'no network interface is carrying traffic'; then pass "Tier 1 with no live interface degrades loudly"; else fail "Tier 1 no-live-interface degradation" "$E2E1"; fi
if echo "$E2E1" | grep -q 'suricata/health:'; then pass "capture self-status is published as health, not ids"; else fail "capture self-status category" "$E2E1"; fi
if ! echo "$E2E1" | grep -qE 'systemctl (start|restart) suricata'; then pass "no doomed start when nothing is carrying packets"; else fail "no doomed start" "$E2E1"; fi

section "End to end: the daemon drives a real start once packets appear"
if python3 - "$PD" "$TMP" "$TOPCFG" <<'PY2'
import sys, pathlib, time
from importlib.machinery import SourceFileLoader
pd = SourceFileLoader("pd", sys.argv[1]).load_module()
tmp = pathlib.Path(sys.argv[2]); topcfg = sys.argv[3]
ok = True
def ck(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label); ok = ok and bool(cond)

sysfs = tmp / "sys2"
def mk(name, typ, rx):
    d = sysfs / name / "statistics"; d.mkdir(parents=True, exist_ok=True)
    (sysfs / name / "type").write_text(str(typ))
    (d / "rx_packets").write_text(str(rx))
mk("lo", 772, 500000); mk("enp2s0", 1, 1000)
posture = tmp / "posture2"; posture.write_text("1\n")
ifaces = tmp / "e2e-ifaces.yaml"

# Real threat rules, so the no-rules warning -- a different decision's
# concern -- is not appended to every action list and masking the capture
# actions this section is about.
rules = tmp / "e2e-rules"; rules.mkdir(exist_ok=True)
(rules / "emerging-all.rules").write_text(
    'alert tcp any any -> any 80 (msg:"x"; sid:1; rev:1;)\n' * 200)

args = pd.build_parser().parse_args([
    "--dry-run", "--no-nebula", "--posture-file", str(posture),
    "--sysfs", str(sysfs), "--interfaces-yaml", str(ifaces),
    "--suricata-config", topcfg, "--rules-dir", str(rules),
    "--canary-dir", str(tmp / "canary"), "--live-window", "10",
    "--live-packets", "5"])
d = pd.PostureDaemon(args)

# The maintainer's workstation has no suricata binary; the deck does. This
# section is about the plan -> write -> start wiring, and the "suricata is
# not installed" path is asserted on its own in the degradation section.
# What is faked here is the ENGINE's verdict, never the daemon's logic.
pd.capture.check_config = lambda *a, **k: {"verdict": "ok", "error": None,
                                           "rc": 0}

# One sample in: nothing can be known yet, and nothing must be claimed.
now = time.time()
ck(d.heartbeat.warming_up(now) is True, "a single sample is 'warming up', not 'no traffic'")
ck(d.capture_target(now) == (), "and selects nothing yet")

# Packets start flowing on enp2s0.
rxfile = sysfs / "enp2s0" / "statistics" / "rx_packets"
for i in range(1, 5):
    rxfile.write_text(str(1000 + i * 40))
    now += 3.0
    d.heartbeat_tick(now)
ck(d.heartbeat.warming_up(now) is False, "warm-up ends as soon as something is measurably live")
ck(d.capture_target(now) == ("enp2s0",), f"the live interface is selected -> {d.capture_target(now)}")

done = d.apply_tier("1")
ck(any(a.startswith("capture:write") for a in done), f"the daemon writes the interface list -> {done}")
ck("service:start:suricata.service" in done, f"and starts the engine -> {done}")

# --dry-run must not have touched the filesystem.
ck(not ifaces.exists(), "dry-run wrote no config")

# Idempotence at the daemon level: re-applying changes nothing.
again = d.apply_tier("1")
ck(again == [], f"re-applying the same tier and interfaces is a no-op -> {again}")

# A second interface appears and goes live: config rewritten, engine
# restarted once, not stopped and started.
mk("usb0", 1, 0)
for i in range(1, 6):
    (sysfs / "usb0" / "statistics" / "rx_packets").write_text(str(i * 40))
    rxfile.write_text(str(1200 + i * 40))
    now += 3.0
    d.heartbeat_tick(now)
d.brake.last_apply = 0.0        # step past the cooldown deliberately
third = d.apply_tier("1")
ck(any("usb0" in a for a in third), f"the new interface reaches the config -> {third}")
ck("service:restart:suricata.service" in third, f"one restart, not a stop+start -> {third}")

# Drop to Tier 0: everything comes down and the brake forgets, so a later
# Tier 1 is a first apply against a live engine rather than a stale diff.
down = d.apply_tier("0")
ck("service:stop:suricata.service" in down, f"Tier 0 stops the engine -> {down}")
ck(d.brake.applied is None, "and the reconfigure brake is reset")

# --- the daemon must SAY what it detects, not merely be able to detect it --
# Detecting a failure in a library function nothing calls is not detection.
# These drive the daemon's own verify path and read what reaches the bus.
import io, contextlib
pd.service_active = lambda *a, **k: True
d.state = pd.tier_plan("1", True, live_ifaces=("enp2s0",))

def bus(fn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn()
    return buf.getvalue()

pd.capture.verify_capture = lambda *a, **k: {
    "verified": False, "configured": True, "capturing": False,
    "attached": ["enp2s0"], "missing": [], "packets": {"enp2s0": 0},
    "total_packets": 0, "reason": "enp2s0: failed to init socket",
    "socket_errors": {"enp2s0": "failed to init socket for interface"}}
d._capture_announced = {}
out = bus(lambda: d.verify_capture(time.time()))
ck("failed to open a capture socket" in out, f"daemon announces an up-but-blind engine -> {out[:90]!r}")
ck("/health:" in out and "/ids:" not in out, "and as health, so it does not inflate THREAT PRESSURE")
ck("[critical]" in out, "at critical, because the deck looks covered and is not")

pd.capture.verify_capture = lambda *a, **k: {
    "verified": None, "configured": None, "capturing": None, "attached": [],
    "missing": ["enp2s0"], "packets": {}, "total_packets": 0,
    "socket_errors": {}, "reason": "suricatasc could not read iface-list"}
d._capture_announced = {}
out2 = bus(lambda: d.verify_capture(time.time()))
ck("could NOT be verified" in out2, f"an unanswerable engine is reported as unverified -> {out2[:90]!r}")
ck("[notice]" not in out2, "and never as success")

pd.capture.verify_capture = lambda *a, **k: {
    "verified": True, "configured": True, "capturing": True,
    "attached": ["enp2s0"], "missing": [], "packets": {"enp2s0": 4242},
    "total_packets": 4242, "socket_errors": {}, "reason": None}
d._capture_announced = {}
out3 = bus(lambda: d.verify_capture(time.time()))
ck("is capturing on enp2s0" in out3 and "4242" in out3, f"a confirmed capture is announced with its packet evidence -> {out3[:90]!r}")
# ...once. A working IDS that says so every cycle buries the one time it stops.
out4 = bus(lambda: d.verify_capture(time.time()))
ck(out4.strip() == "", f"and is not repeated on every cycle -> {out4!r}")

# The engine is not running at all: that is the recovery path's business,
# and verify must not claim anything about capture.
pd.service_active = lambda *a, **k: False
d._capture_announced = {}
res = d.verify_capture(time.time())
ck(res["verified"] is False and "not active" in (res["reason"] or ""), f"a stopped engine is not verified -> {res['reason']}")
sys.exit(0 if ok else 1)
PY2
then pass "daemon end-to-end assertions"; else fail "daemon end-to-end assertions" "see output above"; fi

section "Shipped config is valid -- asked of the real suricata binary"
IMG="orionx-suricata-probe:trixie"
if [[ "${ORIONX_SKIP_CONTAINER:-0}" == "1" ]]; then
  skip "suricata -T against the shipped config" "ORIONX_SKIP_CONTAINER=1"
elif ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  skip "suricata -T against the shipped config" "no container runtime; config validity is UNVERIFIED on this host"
else
  BUILD="$TMP/img"; mkdir -p "$BUILD"
  cat > "$BUILD/Dockerfile" <<'DOCKER'
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends suricata iproute2 \
 && rm -rf /var/lib/apt/lists/*
DOCKER
  if ! docker build -q -t "$IMG" "$BUILD" >/dev/null 2>&1; then
    skip "suricata -T against the shipped config" "image build failed (offline?)"
  else
    # Generated multi-interface config, produced by the real generator.
    python3 - "$MOD" "$TMP/gen.yaml" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
open(sys.argv[2], "w").write(m.render_interfaces_yaml(("eth0", "dummy0")))
PY
    RUN="docker run --rm -v $TOPCFG:/etc/suricata/orionx.yaml:ro"
    # A rules file must exist first: measured on 7.0.10, a VALID config exits
    # 1 when zero rules load, so testing -T without rules would assert the
    # wrong thing in both directions.
    SEED='mkdir -p /var/lib/suricata/rules; echo "alert tcp any any -> any 80 (msg:\"t\"; sid:1; rev:1;)" > /var/lib/suricata/rules/suricata.rules;'

    OUT="$($RUN -v "$BASECFG:/var/lib/suricata/orionx-interfaces.yaml:ro" "$IMG" \
          bash -c "$SEED suricata -T -c /etc/suricata/orionx.yaml 2>&1; echo RC=\$?" 2>&1)"
    if echo "$OUT" | grep -q 'RC=0'; then pass "shipped config + no-interface baseline loads cleanly (suricata -T)"; else fail "shipped config loads" "$OUT"; fi

    OUT2="$($RUN -v "$TMP/gen.yaml:/var/lib/suricata/orionx-interfaces.yaml:ro" "$IMG" \
           bash -c "$SEED suricata -T -c /etc/suricata/orionx.yaml 2>&1; echo RC=\$?" 2>&1)"
    if echo "$OUT2" | grep -q 'RC=0'; then pass "GENERATED two-interface config loads cleanly (suricata -T)"; else fail "generated config loads" "$OUT2"; fi

    # The bug itself: Debian's stock config on a deck with no eth0 exits 1.
    # If this ever stops failing, the fix is no longer needed and this file
    # should be revisited rather than quietly passing.
    OUT3="$(docker run --rm --net=none --privileged "$IMG" \
           bash -c "$SEED suricata --af-packet -c /etc/suricata/suricata.yaml 2>&1 | tail -3; exit \${PIPESTATUS[0]}" 2>&1)"
    if echo "$OUT3" | grep -qi 'failed to find interface\|failed to init socket'; then
      pass "reproduces the shipped defect: Debian's stock config cannot open a capture socket without eth0"
    else fail "defect reproduction" "$OUT3"; fi

    # And the engine really does attach to a generated multi-interface config
    # and really does report it back -- the verification channel, end to end.
    OUT4="$(docker run --rm --privileged \
        -v "$TOPCFG:/etc/suricata/orionx.yaml:ro" \
        -v "$TMP/gen.yaml:/var/lib/suricata/orionx-interfaces.yaml:ro" "$IMG" \
        bash -c "$SEED ip link add dummy0 type dummy; ip link set dummy0 up;
          suricata -D -c /etc/suricata/orionx.yaml --af-packet --pidfile /run/suricata.pid >/dev/null 2>&1
          for i in \$(seq 1 40); do [ -S /var/lib/suricata/orionx-command.socket ] && break; sleep 1; done
          sleep 3; suricatasc -c iface-list /var/lib/suricata/orionx-command.socket" 2>&1)"
    if echo "$OUT4" | grep -q '"eth0"' && echo "$OUT4" | grep -q '"dummy0"'; then
      pass "running engine confirms it attached to BOTH generated interfaces"
    else fail "engine attach verification" "$OUT4"; fi

    if python3 - "$MOD" "$OUT4" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
got = m.parse_iface_list(sys.argv[2])
print("  parsed:", got)
sys.exit(0 if got and set(got) == {"eth0", "dummy0"} else 1)
PY
    then pass "the parser this daemon ships reads the real engine's reply"; else fail "parser vs real engine reply" "$OUT4"; fi

    # THE FAILURE THE SOCKET CANNOT SEE, against the real engine. Two
    # interfaces sharing a cluster-id: the engine comes up, answers
    # iface-list with BOTH, reports pkts: 0 forever, and is blind. Only its
    # own log says so. If this ever stops producing an error, the detection
    # built on it is dead weight and should be revisited, not left passing.
    python3 - "$MOD" "$TMP/dup.yaml" <<'PY'
import sys, re
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sc", sys.argv[1]).load_module()
body = m.render_interfaces_yaml(("eth0", "dummy0"))
# Collapse the distinct cluster-ids the generator correctly allocates.
body = re.sub(r"cluster-id: \d+", "cluster-id: 90", body)
open(sys.argv[2], "w").write(body)
PY
    OUT5="$(docker run --rm --privileged \
        -v "$TOPCFG:/etc/suricata/orionx.yaml:ro" \
        -v "$TMP/dup.yaml:/var/lib/suricata/orionx-interfaces.yaml:ro" "$IMG" \
        bash -c "$SEED ip link add dummy0 type dummy; ip link set dummy0 up;
          suricata -D -c /etc/suricata/orionx.yaml --af-packet --pidfile /run/suricata.pid >/dev/null 2>&1
          sleep 8
          S=/var/lib/suricata/orionx-command.socket
          echo '--IFACELIST--'; suricatasc -c iface-list \$S
          echo '--LOG--'; cat /var/log/suricata/suricata.log" 2>&1)"
    if echo "$OUT5" | sed -n '/--IFACELIST--/,/--LOG--/p' | grep -q 'eth0'; then
      pass "a broken capture socket still appears in iface-list (the gap this detection exists for)"
    else
      skip "iface-list gap reproduction" "engine behaved differently: $(echo "$OUT5" | head -3)"
    fi
    if printf '%s' "$OUT5" | sed -n '/--LOG--/,$p' | python3 -c '
import sys
sys.path.insert(0, "'"$REPO_ROOT"'/scripts/awareness")
import suricata_capture as sc
errs = sc.socket_errors(sys.stdin.read())
print("  parsed socket_errors:", errs)
sys.exit(0 if errs else 1)'; then
      pass "the shipped parser detects the real engine's capture-socket failure"
    else
      fail "socket-error detection vs the real engine" "$(echo "$OUT5" | tail -5)"
    fi
  fi
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}" "$PASS" "$FAIL"
[[ $SKIP -gt 0 ]] && printf ", ${YELLOW}%s skipped${NC}" "$SKIP"
printf "\n===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
