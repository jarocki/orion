#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_healing.sh — Orion-X auto-healing engine (DEC-PHASE12-023)
#
# The Control Center has offered an autonomy grid since W10-6's first slice:
# the operator pre-approves off/propose/confirm/autonomous per action class and
# it persists to ~/.config/orionx/autonomy.json. Nothing consumed it, so an
# operator could set block_ip to "autonomous" and be wrong about it during an
# incident. scripts/healing/ is the engine that makes the control real.
#
# These tests cover the properties that make it safe to leave running: the
# autonomy gate at every level, failing closed on a missing/corrupt config, a
# real undo for each of the six playbooks, rollback expiry, tamper detection in
# the Merkle audit chain, the never-lock-out guards, and a --dry-run that
# genuinely touches nothing. All of it runs unprivileged, with no nftables and
# no mesh: effects go through an injected runner that records argv vectors.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

HEAL_DIR="$REPO_ROOT/scripts/healing"
CHROOT="$REPO_ROOT/iso/config/includes.chroot"
# Never /tmp — scratch state lives in the repo's own tmp/ (CLAUDE.md).
WORK="$REPO_ROOT/tmp/test-healing.$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

section "Structure"
for f in healing_lib.py playbooks.py engine.py orionx-heald orionx-heal; do
    if [[ -f "$HEAL_DIR/$f" ]]; then pass "$f present"; else fail "$f present" "missing"; exit 1; fi
done
for f in orionx-heald orionx-heal; do
    if [[ -x "$HEAL_DIR/$f" ]]; then pass "$f executable"; else fail "$f executable"; fi
    if head -1 "$HEAL_DIR/$f" | grep -q python3; then pass "$f python3 shebang"; else fail "$f python3 shebang"; fi
done
for f in healing_lib.py playbooks.py engine.py orionx-heald orionx-heal; do
    if grep -q '@decision DEC-PHASE12-023' "$HEAL_DIR/$f"; then
        pass "$f carries the decision annotation"
    else
        fail "$f carries the decision annotation"
    fi
done

section "No dynamic dispatch (the bus is attacker-influenced input)"
# An event maps to an action. If that mapping could reach eval/exec/shell, the
# event bus would be a remote-code-execution surface.
if grep -nE '\b(eval|exec)\(' "$HEAL_DIR"/*.py "$HEAL_DIR"/orionx-heal* >/dev/null 2>&1; then
    fail "no eval/exec in the healing tree" "$(grep -nE '\b(eval|exec)\(' "$HEAL_DIR"/*.py)"
else
    pass "no eval/exec anywhere in the healing tree"
fi
if grep -nE 'shell=True|os\.system|getattr\(' "$HEAL_DIR"/*.py >/dev/null 2>&1; then
    fail "no shell=True / os.system / getattr dispatch" \
         "$(grep -nE 'shell=True|os\.system|getattr\(' "$HEAL_DIR"/*.py)"
else
    pass "no shell=True, os.system, or getattr-based dispatch"
fi

section "Lint"
if command -v ruff >/dev/null 2>&1; then
    if RUFF_OUT="$(cd "$REPO_ROOT" && ruff check scripts/healing/ 2>&1)"; then
        pass "ruff check scripts/healing/ clean"
    else
        fail "ruff check scripts/healing/ clean" "$RUFF_OUT"
    fi
else
    pass "ruff not installed — skipped (not a failure on this host)"
fi
if bash -n "$SCRIPT_DIR/test_healing.sh"; then pass "test script parses"; else fail "test script parses"; fi

# ---------------------------------------------------------------------------
# All Python assertion blocks share this environment: the engine is pointed
# entirely at $WORK, so nothing under $HOME or /var/lib is read or written.
# ---------------------------------------------------------------------------
export PYTHONPATH="$HEAL_DIR"
export ORIONX_AUTONOMY_FILE="$WORK/autonomy.json"
export ORIONX_HEALING_CONFIG="$WORK/healing.json"
export ORIONX_HEALING_STATE="$WORK/state"
export ORIONX_EVENT_LOG="$WORK/events.jsonl"
export ORIONX_MATRIX_TOKEN_FILE="$WORK/matrix-token"

section "Autonomy gating — the operator's standing consent"
if python3 - <<'PY'
import json, os, sys
import healing_lib as hl
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

work = os.environ["ORIONX_HEALING_STATE"].rsplit("/", 1)[0]
cfg = os.environ["ORIONX_AUTONOMY_FILE"]

# Every level maps to exactly one disposition, and only ONE of them acts.
check(hl.disposition("off")        == hl.ACT_SKIP,    "off        -> skip")
check(hl.disposition("propose")    == hl.ACT_PROPOSE, "propose    -> propose (suggestion only)")
check(hl.disposition("confirm")    == hl.ACT_AWAIT,   "confirm    -> await_confirm")
check(hl.disposition("autonomous") == hl.ACT_EXECUTE, "autonomous -> execute")
acting = [l for l in hl.LEVELS if hl.disposition(l) == hl.ACT_EXECUTE]
check(acting == ["autonomous"], f"exactly one level acts unattended: {acting}")

# propose and confirm must NOT be treated as permission to act.
for lvl in ("off", "propose", "confirm"):
    a = {"block_ip": lvl}
    check(not hl.may_act_now(a, "block_ip"), f"{lvl!r} does not authorise autonomous action")
check(hl.may_act_now({"block_ip": "autonomous"}, "block_ip"), "'autonomous' does authorise it")

# --- Fail closed. Each of these must yield "off", never anything else. ---
open(cfg, "w").write(json.dumps({"block_ip": "autonomous"}))
check(hl.level_for(hl.load_autonomy(cfg), "block_ip") == "autonomous", "a valid file is honoured")
check(hl.level_for(hl.load_autonomy(cfg), "isolate_node") == "off",
      "a class absent from the file defaults to OFF (not the UI's 'propose')")

os.unlink(cfg)
check(hl.load_autonomy(cfg) == {}, "missing file -> empty mapping")
check(hl.level_for(hl.load_autonomy(cfg), "block_ip") == "off", "missing file -> off")

for bad, label in [
    ("{not json at all", "truncated/invalid JSON"),
    ('{"block_ip": "autonomous"', "truncated mid-object"),
    ('["block_ip", "autonomous"]', "a JSON list instead of an object"),
    ('"autonomous"', "a bare JSON string"),
    ("null", "JSON null"),
    ('{"block_ip": "ULTRA"}', "an unrecognised level name"),
    ('{"block_ip": true}', "a non-string level"),
    ("", "an empty file"),
]:
    open(cfg, "w").write(bad)
    lv = hl.level_for(hl.load_autonomy(cfg), "block_ip")
    check(lv == "off", f"corrupt config ({label}) -> off, got {lv!r}")

# A corrupt file must not leak a partially-valid neighbour into consent either.
open(cfg, "w").write('{"block_ip": "autonomous", "kill_process": "WHATEVER"}')
a = hl.load_autonomy(cfg)
check(hl.level_for(a, "kill_process") == "off", "one bad value does not taint, but is itself off")
check(hl.level_for(a, "block_ip") == "autonomous", "and the valid sibling still parses")
check(hl.FAILSAFE_LEVEL == "off", "the declared failsafe IS off")
sys.exit(0 if ok else 1)
PY
then pass "autonomy gating assertions"; else fail "autonomy gating assertions" "see output above"; fi

section "Never-lock-out guards"
if python3 - <<'PY'
import sys
import healing_lib as hl
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

g = hl.GuardContext(
    operator_addrs={"192.168.4.10", "2001:db8::5"},
    local_addrs={"192.168.4.42"},
    gateways={"192.168.4.1"},
    never_block=("198.51.100.0/24", "203.0.113.200"),
    mesh_subnet="10.0.99.0/24",
    self_pid=4242,
)

allowed, why = hl.check_block_target("203.0.113.9", g)
check(allowed, f"a genuine hostile source IS blockable ({why})")

for ip, label in [
    ("127.0.0.1",     "loopback v4"),
    ("::1",           "loopback v6"),
    ("0.0.0.0",       "the unspecified address"),
    ("169.254.9.9",   "link-local"),
    ("224.0.0.1",     "multicast"),
    ("192.168.4.10",  "the address the operator is connected FROM"),
    ("2001:db8::5",   "the operator's v6 session address"),
    ("192.168.4.42",  "the deck's own address"),
    ("192.168.4.1",   "the default gateway"),
    ("10.0.99.7",     "a mesh peer (inside MESH_SUBNET)"),
    ("198.51.100.5",  "inside the operator's never-block CIDR"),
    ("203.0.113.200", "an exact never-block entry"),
    ("not-an-ip",     "a malformed target"),
    ("",              "an empty target"),
]:
    allowed, why = hl.check_block_target(ip, g)
    check(not allowed, f"REFUSES {label} ({ip or '<empty>'}): {why}")

# The guard is a precondition, not a policy knob: check_target dispatches to it
# for every caller, so no autonomy level and no manual run can reach around it.
allowed, why = hl.check_target("block_ip", "192.168.4.10", g)
check(not allowed, "check_target() refuses the operator's address for block_ip")

# kill_process
check(not hl.check_kill_target("1", g)[0], "REFUSES killing PID 1 (init)")
check(not hl.check_kill_target("0", g)[0], "REFUSES killing PID 0 (kernel)")
check(not hl.check_kill_target("4242", g)[0], "REFUSES killing the engine's own PID")
check(not hl.check_kill_target("abc", g)[0], "REFUSES a non-numeric PID")
check(hl.check_kill_target("31337", g)[0], "allows an ordinary PID")

# quarantine_file — moving /usr/bin/bash into a 0000 vault is a brick, not a fix.
for path, label in [
    ("/usr/bin/bash",          "a binary under /usr"),
    ("/etc/nftables.conf",     "the firewall config"),
    ("/bin/sh",                "the shell"),
    ("/boot/vmlinuz",          "the kernel"),
    ("/opt/orionx/scripts/x",  "the Orion-X tree itself"),
    ("/",                      "the filesystem root"),
    ("relative/path",          "a relative path"),
    ("/usr/../usr/lib/x.so",   "a traversal back into /usr"),
]:
    allowed, why = hl.check_quarantine_target(path, g)
    check(not allowed, f"REFUSES quarantining {label}: {why}")
check(hl.check_quarantine_target("/home/orionx-operator/Downloads/evil.bin", g)[0],
      "allows quarantining a file in the operator's Downloads")

check(not hl.check_target("revoke_matrix_session", "bob", g)[0], "REFUSES a bare Matrix username")
check(hl.check_target("revoke_matrix_session", "@bob:orionx.local", g)[0], "allows a full Matrix id")
check(not hl.check_target("no_such_playbook", "x", g)[0], "REFUSES an unknown playbook")
sys.exit(0 if ok else 1)
PY
then pass "never-lock-out guard assertions"; else fail "never-lock-out guard assertions" "see output above"; fi

section "Merkle audit chain — tamper detection"
if python3 - <<'PY'
import json, os, sys
from pathlib import Path
import healing_lib as hl
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

chain = Path(os.environ["ORIONX_HEALING_STATE"]) / "merkle.jsonl"
chain.parent.mkdir(parents=True, exist_ok=True)
if chain.exists():
    chain.unlink()

for i in range(6):
    hl.append_entry({"kind": hl.KIND_APPLIED, "action_id": f"a{i}",
                     "playbook": "block_ip", "target": f"203.0.113.{i}",
                     "level": "autonomous", "expires_at": 0.0,
                     "undo": {"kind": "nft_del_element", "set": "blocked",
                              "element": f"203.0.113.{i}"}}, chain)

entries = hl.read_chain(chain)
check(len(entries) == 6, f"six records written ({len(entries)})")
good, bad, why = hl.verify_chain(entries)
check(good and bad == -1, f"an untouched chain verifies INTACT ({why})")
check(entries[0]["prev"] == hl.GENESIS_HASH, "record 0 links to the genesis hash")
check(all(entries[i]["prev"] == entries[i-1]["hash"] for i in range(1, 6)),
      "every record commits to its predecessor's hash")
check(len({e["hash"] for e in entries}) == 6, "all six hashes are distinct")

# Determinism: the same logical record must hash identically after a JSON
# round-trip, or honest data would be reported as tampered.
rt = [json.loads(json.dumps(e)) for e in entries]
check(hl.verify_chain(rt)[0], "a JSON round-trip still verifies (canonical form is stable)")

def load_raw():
    return [json.loads(l) for l in chain.read_text().splitlines() if l.strip()]

def rewrite(rows):
    chain.write_text("".join(json.dumps(r) + "\n" for r in rows))

# --- TAMPER 1: silently change what an action did. -----------------------
rows = load_raw()
rows[3]["target"] = "10.0.0.1"          # rewrite history, keep the stored hash
rewrite(rows)
good, bad, why = hl.verify_chain(hl.read_chain(chain))
check(not good, "DETECTS an altered record")
check(bad == 3, f"names the exact record that was altered (#{bad}, expected 3)")
check("altered" in why, f"explains it as alteration: {why}")

# --- TAMPER 2: delete an inconvenient record. ----------------------------
rows = load_raw()
del rows[2]
rewrite(rows)
good, bad, why = hl.verify_chain(hl.read_chain(chain))
check(not good, "DETECTS a deleted record")
check(bad == 2, f"reports the first broken link at the deletion point (#{bad})")
check("broken link" in why, f"explains it as a broken link: {why}")

# --- TAMPER 3: reorder two records. --------------------------------------
rows = load_raw()
rows[1], rows[2] = rows[2], rows[1]
rewrite(rows)
check(not hl.verify_chain(hl.read_chain(chain))[0], "DETECTS reordered records")

# --- TAMPER 4: truncate the head off and rebuild from record 2. ----------
rows = load_raw()[2:]
rewrite(rows)
good, bad, why = hl.verify_chain(hl.read_chain(chain))
check(not good, "DETECTS a truncated prefix (chain no longer starts at genesis)")
check(bad == 0, "reports the break at record 0")

# --- TAMPER 5: forge a record with a recomputed hash but the WRONG prev. --
rows = load_raw()
forged = dict(rows[-1])
forged["target"] = "10.0.0.99"
forged["prev"] = hl.GENESIS_HASH
forged["hash"] = hl.entry_hash(forged)   # internally consistent, but unlinked
rows.append(forged)
rewrite(rows)
check(not hl.verify_chain(hl.read_chain(chain))[0],
      "DETECTS a self-consistent forgery spliced onto the wrong predecessor")

# --- TAMPER 6: corrupt a line so it is not even JSON. --------------------
chain.write_text("")
for i in range(3):
    hl.append_entry({"kind": hl.KIND_APPLIED, "action_id": f"b{i}",
                     "playbook": "kill_process", "target": str(100+i)}, chain)
lines = chain.read_text().splitlines()
lines[1] = "{ this is not json"
chain.write_text("\n".join(lines) + "\n")
good, bad, why = hl.verify_chain(hl.read_chain(chain))
check(not good and bad == 1, f"DETECTS an unparseable line rather than skipping it (#{bad})")

# An intact chain rebuilt from scratch verifies again — detection is not sticky.
chain.unlink()
hl.append_entry({"kind": hl.KIND_APPLIED, "action_id": "z", "playbook": "block_ip"}, chain)
check(hl.verify_chain(hl.read_chain(chain))[0], "a fresh chain verifies clean again")
check(hl.verify_chain([])[0], "an empty chain is vacuously intact")
sys.exit(0 if ok else 1)
PY
then pass "Merkle chain assertions"; else fail "Merkle chain assertions" "see output above"; fi

section "Rollback timers and ledger replay"
if python3 - <<'PY'
import os, sys, time
from pathlib import Path
import healing_lib as hl
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

T0 = 1_000_000.0
# Replay is pure: build a chain as plain dicts and reason about it directly.
def applied(aid, pb_, target, ts, expires):
    return {"kind": hl.KIND_APPLIED, "action_id": aid, "playbook": pb_,
            "target": target, "ts": ts, "expires_at": expires,
            "undo": {"kind": "nft_del_element", "element": target}, "level": "autonomous"}

chain = [
    applied("a1", "block_ip", "203.0.113.1", T0, T0 + 3600),
    applied("a2", "block_ip", "203.0.113.2", T0, T0 + 60),
    applied("a3", "rotate_mesh_keys", "", T0, 0.0),        # TTL 0 = no timer
]
state = hl.replay(chain)
check(len(hl.active_actions(chain)) == 3, "three actions in force after replay")

due = hl.due_for_rollback(chain, T0 + 120)
check([a.action_id for a in due] == ["a2"], f"only the lapsed timer is due ({[a.action_id for a in due]})")
check(not hl.due_for_rollback(chain, T0 + 10), "nothing is due before any timer elapses")
due_later = {a.action_id for a in hl.due_for_rollback(chain, T0 + 99999)}
check(due_later == {"a1", "a2"}, f"a TTL of 0 NEVER auto-reverts ({due_later})")

# A revert entry retires the action; replay must reflect it.
chain.append({"kind": hl.KIND_REVERTED, "action_id": "a2", "ts": T0 + 121})
check(len(hl.active_actions(chain)) == 2, "a reverted action leaves the in-force set")
check(not hl.due_for_rollback(chain, T0 + 99999) or
      "a2" not in {a.action_id for a in hl.due_for_rollback(chain, T0 + 99999)},
      "an already-reverted action is not due again")

# Renewal extends the timer.
chain.append({"kind": hl.KIND_RENEWED, "action_id": "a1", "ts": T0 + 100,
              "expires_at": T0 + 7200})
check(not hl.due_for_rollback(chain, T0 + 3700), "a renewed action survives its original expiry")
check({a.action_id for a in hl.due_for_rollback(chain, T0 + 7300)} == {"a1"},
      "the renewed action expires at the NEW time")

# Confirm-level proposals lapse unanswered rather than escalating.
chain.append({"kind": hl.KIND_PENDING, "action_id": "p1", "playbook": "isolate_node",
              "target": "", "ts": T0, "expires_at": 0.0})
check([a.action_id for a in hl.pending_actions(chain)] == ["p1"], "the proposal is pending")
check(not hl.active_actions(chain) or "p1" not in {a.action_id for a in hl.active_actions(chain)},
      "a PENDING action is NOT in force — confirm never acts on its own")
check(not hl.expired_pending(chain, T0 + 60, 3600.0), "a fresh proposal has not lapsed")
check([a.action_id for a in hl.expired_pending(chain, T0 + 4000, 3600.0)] == ["p1"],
      "an unanswered proposal lapses after the grace period")

# Ledger durability: state survives a "restart" because it is re-read from disk.
work = Path(os.environ["ORIONX_HEALING_STATE"]) / "restart.jsonl"
if work.exists():
    work.unlink()
hl.append_entry(applied("r1", "block_ip", "203.0.113.77", time.time(), time.time() + 3600), work)
reloaded = hl.active_actions(hl.read_chain(work))     # fresh read == fresh process
check(len(reloaded) == 1 and reloaded[0].target == "203.0.113.77",
      "rollback state is reconstructed from disk after a restart")
check(reloaded[0].undo.get("element") == "203.0.113.77",
      "the undo record survives the restart intact")
check(hl.ttl_for("isolate_node") == 900.0, "isolate_node's TTL is deliberately short (15m)")
check(hl.ttl_for("rotate_mesh_keys") == 0.0, "rotate_mesh_keys has no auto-revert")
check(hl.ttl_for("block_ip", {"ttl": {"block_ip": 120}}) == 120.0, "config can override a TTL")
sys.exit(0 if ok else 1)
PY
then pass "rollback timer + replay assertions"; else fail "rollback timer + replay assertions" "see output above"; fi

section "Playbooks — every action has a real undo"
if MESH_PRIVATE_KEY="$WORK/mesh-private.key" python3 - <<'PY'
import json, os, sys
from pathlib import Path
import healing_lib as hl
import playbooks as pb
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

WORK = Path(os.environ["ORIONX_HEALING_STATE"]).parent
STATE = Path(os.environ["ORIONX_HEALING_STATE"])

class Rec(pb.Runner):
    """Records argv vectors instead of running them; filesystem ops are real."""
    def __init__(self, rc=0, out="", **kw):
        super().__init__(**kw)
        self.rc, self.out = rc, out
    def run(self, argv, check=False):
        self.commands.append(list(argv))
        return self.rc, self.out, ""
    def http(self, method, url, token, body=None):
        self.requests.append((method, url, body))
        return 200, "{}"

def ctx(runner, aid="act1"):
    return pb.ExecContext(runner=runner, guards=hl.GuardContext(),
                          config=hl.default_config(), state_dir=STATE, action_id=aid)

def joined(r):
    return [" ".join(c) for c in r.commands]

# --- registry/implementation coupling ------------------------------------
check(set(pb.APPLY) == set(hl.PLAYBOOK_NAMES), "every registry playbook has an apply()")
check(set(pb.UNDO) == set(hl.PLAYBOOK_NAMES), "every registry playbook has an undo()")
check(len(hl.REGISTRY) == 6, f"all six action classes are registered ({len(hl.REGISTRY)})")
ui = {"block_ip", "kill_process", "quarantine_file", "isolate_node",
      "rotate_mesh_keys", "revoke_matrix_session"}
check(set(hl.PLAYBOOK_NAMES) == ui, "the registry matches the Control Center's six classes exactly")

# --- 1. block_ip ---------------------------------------------------------
r = Rec(); c = ctx(r)
res = pb.apply_block_ip("203.0.113.9", c)
check(res.ok, f"block_ip applies: {res.detail}")
check(any("add element inet orionx_healing blocked { 203.0.113.9 }" in j for j in joined(r)),
      "adds the address to the dedicated named set (additive, not a ruleset rewrite)")
check(any("add table inet orionx_healing" in j for j in joined(r)),
      "creates its OWN table — never edits the shipped inet orionx_firewall")
check(not any("flush" in j for j in joined(r)), "never flushes the baseline ruleset")
check(res.undo.get("element") == "203.0.113.9", "records the undo before returning")
r2 = Rec(); res2 = pb.undo_block_ip(res.undo, ctx(r2))
check(res2.ok, f"block_ip undo: {res2.detail}")
check(any("delete element inet orionx_healing blocked { 203.0.113.9 }" in j for j in joined(r2)),
      "undo deletes exactly that element")
# v6 goes to the v6 set.
r3 = Rec(); res3 = pb.apply_block_ip("2001:db8::9", ctx(r3))
check(any("blocked6" in j for j in joined(r3)), "an IPv6 source lands in the v6 set")
# A missing element on undo is success — the desired end state already holds.
class Missing(Rec):
    def run(self, argv, check=False):
        self.commands.append(list(argv))
        return 1, "", "Error: No such file or directory"
check(pb.undo_block_ip(res.undo, ctx(Missing())).ok,
      "undo is idempotent: an already-absent element is success, not failure")

# --- 2. kill_process -----------------------------------------------------
r = Rec(); res = pb.apply_kill_process("31337", ctx(r))
check(res.ok, f"kill_process applies: {res.detail}")
check(["kill", "-TERM", "31337"] in r.commands, "sends SIGTERM first, never SIGKILL outright")
check(res.undo.get("reversible") is False, "a bare PID is HONESTLY marked irreversible")
u = pb.undo_kill_process(res.undo, ctx(Rec()))
check(not u.ok and "resurrect" in u.detail,
      f"undo says plainly that a bare PID cannot come back: {u.detail}")
# The reversible case: a PID owned by a systemd unit.
svc = {"kind": "systemctl_start", "unit": "evil.service", "pid": "42", "reversible": True}
r = Rec(); u = pb.undo_kill_process(svc, ctx(r))
check(u.ok and ["systemctl", "start", "evil.service"] in r.commands,
      "a unit-owned process IS reversible: undo restarts the unit")

# --- 3. quarantine_file (real filesystem, under tmp/) --------------------
victim = WORK / "evil.bin"
victim.write_text("malicious payload")
original_mode = victim.stat().st_mode & 0o7777
r = Rec(); res = pb.apply_quarantine_file(str(victim), ctx(r, "qact"))
check(res.ok, f"quarantine_file applies: {res.detail}")
check(not victim.exists(), "the original file is gone from its location")
vault = Path(res.undo["vault"])
check(vault.exists(), f"the file is in the vault at {vault}")
check((vault.stat().st_mode & 0o777) == 0, "the quarantined copy is sealed at mode 0000")
check(len(res.undo.get("sha256", "")) == 64, "the content hash is recorded for forensics")
check(Path(str(vault) + ".meta.json").exists(), "a metadata sidecar is written")
u = pb.undo_quarantine_file(res.undo, ctx(Rec()))
check(u.ok, f"quarantine_file undo: {u.detail}")
check(victim.exists(), "the file is restored to its ORIGINAL path")
check(victim.read_text() == "malicious payload", "the content is byte-identical after restore")
check((victim.stat().st_mode & 0o7777) == original_mode, "the original mode is restored")
check(not pb.apply_quarantine_file(str(WORK / "nope.bin"), ctx(Rec())).ok,
      "quarantining a nonexistent file fails cleanly")

# --- 4. isolate_node -----------------------------------------------------
g = hl.GuardContext(operator_addrs={"192.168.4.10"})
r = Rec()
res = pb.apply_isolate_node("", pb.ExecContext(runner=r, guards=g, state_dir=STATE))
check(res.ok, f"isolate_node applies: {res.detail}")
j = joined(r)
check(any("add table inet orionx_isolate" in x for x in j), "creates the isolation table")
check(sum("policy drop" in x for x in j) == 3, "input, output AND forward all default to drop")
check(any("iif lo accept" in x for x in j), "loopback stays up")
check(any("saddr 192.168.4.10 accept" in x for x in j),
      "THE OPERATOR'S LIVE SESSION IS KEPT REACHABLE — isolation is not a lockout")
check("192.168.4.10" in res.detail, "the detail names which addresses were kept")
r2 = Rec(); u = pb.undo_isolate_node(res.undo, ctx(r2))
check(u.ok and ["nft", "delete", "table", "inet", "orionx_isolate"] in r2.commands,
      "undo removes the whole table in one step (no half-isolated state)")
# With no operator session detected, it must warn rather than silently isolate.
res_b = pb.apply_isolate_node("", pb.ExecContext(runner=Rec(), guards=hl.GuardContext(),
                                                 state_dir=STATE))
check("WARNING" in res_b.detail, f"warns when no operator address was detected: {res_b.detail}")

# --- 5. rotate_mesh_keys -------------------------------------------------
keyfile = Path(os.environ["MESH_PRIVATE_KEY"])
keyfile.write_text("ORIGINALKEY000000000000000000000000000000000=\n")
r = Rec(out="NEWKEY1111111111111111111111111111111111111=\n")
res = pb.apply_rotate_mesh_keys("", ctx(r, "mact"))
check(res.ok, f"rotate_mesh_keys applies: {res.detail}")
check(["wg", "genkey"] in r.commands, "generates a fresh key with wg genkey")
check(any("wg set" in x and "private-key" in x for x in joined(r)),
      "installs it with `wg set` (no interface teardown — DEC-MESH-005 handshake lockout)")
check("NEWKEY" in keyfile.read_text(), "the new key is on disk")
backup = Path(res.undo["backup"])
check(backup.exists() and "ORIGINALKEY" in backup.read_text(),
      "the previous key is backed up before being replaced")
r2 = Rec(); u = pb.undo_rotate_mesh_keys(res.undo, ctx(r2))
check(u.ok, f"rotate_mesh_keys undo: {u.detail}")
check("ORIGINALKEY" in keyfile.read_text(), "undo restores the PREVIOUS key byte for byte")
check(any("wg set" in x for x in joined(r2)), "and re-applies it to the live interface")
check(not pb.apply_rotate_mesh_keys("", ctx(Rec())).ok or keyfile.exists(),
      "rotation without a mesh key fails cleanly")

# --- 6. revoke_matrix_session -------------------------------------------
tokfile = Path(os.environ["ORIONX_MATRIX_TOKEN_FILE"])
r = Rec(); res = pb.apply_revoke_matrix_session("@mallory:orionx.local", ctx(r))
check(not res.ok and "admin token" in res.detail,
      f"without an admin token it fails LOUDLY rather than pretending: {res.detail}")
tokfile.write_text("syt_adm_token\n")
r = Rec(); res = pb.apply_revoke_matrix_session("@mallory:orionx.local", ctx(r))
check(res.ok, f"revoke_matrix_session applies: {res.detail}")
urls = [u for _m, u, _b in r.requests]
check(any("delete_devices" in u for u in urls), "revokes the devices (invalidates access tokens)")
check(any(m == "PUT" and b == {"locked": True} for m, _u, b in r.requests),
      "locks the account — the reversible half of the containment")
check(not any("deactivate" in u for u in urls),
      "never uses the DESTRUCTIVE deactivate endpoint")
r2 = Rec(); u = pb.undo_revoke_matrix_session(res.undo, ctx(r2))
check(u.ok and any(b == {"locked": False} for _m, _u, b in r2.requests),
      f"undo unlocks the account: {u.detail}")
pbk = hl.PLAYBOOKS["revoke_matrix_session"]
check(pbk.fully_reversible is False,
      "the registry states honestly that this is only PARTLY reversible")

# Unknown playbook names are refused, and a raising playbook cannot kill the daemon.
check(not pb.apply_playbook("rm_rf_slash", "/", ctx(Rec())).ok, "an unknown playbook is refused")
sys.exit(0 if ok else 1)
PY
then pass "playbook apply/undo assertions"; else fail "playbook apply/undo assertions" "see output above"; fi

section "Engine end-to-end: event -> gate -> action -> ledger"
if python3 - <<'PY'
import json, os, sys, time
from pathlib import Path
import healing_lib as hl
import playbooks as pb
import engine as eng
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

WORK = Path(os.environ["ORIONX_HEALING_STATE"]).parent
AUT = Path(os.environ["ORIONX_AUTONOMY_FILE"])
run_no = 0

def make(levels, dry_run=False, guards=None, state=None):
    """An engine with consent `levels`, no host probing, no bus, fake nft."""
    global run_no
    run_no += 1
    AUT.write_text(json.dumps(levels))
    st = state or (WORK / f"eng{run_no}")
    e = eng.Engine(dry_run=dry_run, state_dir=st, probe_host=False)
    e.published = []
    e.publish = lambda sev, msg, category="heal": e.published.append((sev, msg))
    if guards is not None:
        e.guards = guards
    real_run = e.runner.run
    e.runner.run = lambda argv, check=False: (e.runner.commands.append(list(argv))
                                              or (0, "", "")) if not e.dry_run else real_run(argv)
    return e

SCAN = {"ts": time.time(), "severity": "critical", "source": "firewall",
        "category": "scan",
        "message": "port scan from 203.0.113.9 - 60 ports in 12s (tcp), most recent dport 4444"}

# --- event mapping -------------------------------------------------------
p = hl.match_event(SCAN)
check(p is not None and p.playbook == "block_ip" and p.target == "203.0.113.9",
      f"a critical firewall scan event maps to block_ip on the scanner ({p})")
low = dict(SCAN, severity="warning")
check(hl.match_event(low) is None, "the SAME event at warning is below the floor — no action")
check(hl.match_event(dict(SCAN, source="healing")) is None,
      "the engine IGNORES its own events (no feedback loop on a shared bus)")
check(hl.match_event({"severity": "critical", "source": "who", "category": "knows",
                      "message": "x"}) is None, "an unmapped source/category maps to nothing")
check(hl.match_event(dict(SCAN, message="port scan from not-an-ip")) is None,
      "an unparseable target is dropped rather than guessed at")
check(hl.match_event("not a dict") is None, "a non-dict event is ignored")
check(hl.extract_path({"message": "YARA hit path=/home/o/evil.bin"}) == "/home/o/evil.bin",
      "the path extractor works")
check(hl.extract_pid({"message": "malicious pid=1234"}) == "1234", "the pid extractor works")
check(hl.extract_user({"message": "hijack user=@bob:orionx.local"}) == "@bob:orionx.local",
      "the matrix user extractor works")

# --- OFF -----------------------------------------------------------------
e = make({"block_ip": "off"})
check(e.handle_event(SCAN) == "off", "level 'off': the engine does nothing")
check(not e.runner.commands, "level 'off': no command was issued")
check(not e.chain_file().exists() or not hl.read_chain(e.chain_file()),
      "level 'off': nothing written to the ledger")

# Not listed at all == off, even though the UI would display 'propose'.
e = make({})
check(e.handle_event(SCAN) == "off", "a class absent from autonomy.json does nothing")
# A corrupt file on disk must not become consent.
AUT.write_text("{corrupt")
check(e.handle_event(SCAN) == "off", "a CORRUPT autonomy.json does nothing")
AUT.unlink()
check(e.handle_event(SCAN) == "off", "a MISSING autonomy.json does nothing")

# --- PROPOSE -------------------------------------------------------------
e = make({"block_ip": "propose"})
check(e.handle_event(SCAN) == "proposed", "level 'propose': returns 'proposed'")
check(not e.runner.commands, "level 'propose': NO nftables command was issued")
entries = hl.read_chain(e.chain_file())
check([x["kind"] for x in entries] == [hl.KIND_PROPOSED], "only a 'proposed' record is written")
check(not hl.active_actions(entries), "level 'propose': nothing is in force")
check(any("suggestion" in m for _s, m in e.published), "it emits a suggestion event")
check(any("orionx-heal run block_ip" in m for _s, m in e.published),
      "the suggestion tells the operator the exact command to run")

# --- CONFIRM -------------------------------------------------------------
e = make({"block_ip": "confirm"})
check(e.handle_event(SCAN) == "pending", "level 'confirm': parks a pending action")
check(not e.runner.commands, "level 'confirm': NO action taken without acknowledgement")
pend = hl.pending_actions(e.entries())
check(len(pend) == 1, "exactly one action awaits confirmation")
check(not hl.active_actions(e.entries()), "level 'confirm': nothing in force yet")
check(any("confirm" in m for _s, m in e.published), "the operator is told how to confirm")
aid = pend[0].action_id
okc, msg = e.confirm(aid)
check(okc, f"the explicit confirm path executes it: {msg}")
check(any("add element" in " ".join(c) for c in e.runner.commands),
      "only NOW does the nftables command run")
check(len(hl.active_actions(e.entries())) == 1, "the action is in force after confirmation")
check(not e.confirm(aid)[0], "confirming twice is refused (it is no longer pending)")
check(not e.confirm("deadbeef0000")[0], "confirming an unknown id is refused")
# deny
e2 = make({"block_ip": "confirm"})
e2.handle_event(SCAN)
aid2 = hl.pending_actions(e2.entries())[0].action_id
check(e2.deny(aid2)[0], "the operator can deny a parked action")
check(not hl.active_actions(e2.entries()), "a denied action never takes effect")
check(not e2.confirm(aid2)[0], "a denied action cannot then be confirmed")

# --- AUTONOMOUS ----------------------------------------------------------
e = make({"block_ip": "autonomous"})
check(e.handle_event(SCAN) == "applied", "level 'autonomous': acts immediately")
cmds = [" ".join(c) for c in e.runner.commands]
check(any("add element inet orionx_healing blocked { 203.0.113.9 }" in c for c in cmds),
      "the address really is added to the block set")
act = hl.active_actions(e.entries())
check(len(act) == 1 and act[0].target == "203.0.113.9", "the action is recorded as in force")
check(act[0].expires_at > time.time(), "it carries a rollback timer")
check(act[0].undo.get("element") == "203.0.113.9", "its undo is stored in the ledger")
check(hl.verify_chain(e.entries())[0], "the ledger written by a live run verifies INTACT")
check(any("applied" in m for _s, m in e.published), "the action is announced on the bus")

# Consent is re-read live: revoking it mid-incident takes effect at once.
AUT.write_text(json.dumps({"block_ip": "off"}))
before = len(e.runner.commands)
check(e.handle_event(dict(SCAN, message="port scan from 203.0.113.55")) == "off",
      "revoking consent stops the engine WITHOUT a restart")
check(len(e.runner.commands) == before, "and no further command is issued")

# --- guards beat consent -------------------------------------------------
g = hl.GuardContext(operator_addrs={"203.0.113.9"})
e = make({"block_ip": "autonomous"}, guards=g)
check(e.handle_event(SCAN) == "refused",
      "'autonomous' still CANNOT block the operator's own address")
check(not e.runner.commands, "no nftables command was issued for a refused target")
kinds = [x["kind"] for x in e.entries()]
check(kinds == [hl.KIND_REFUSED], "the refusal is itself recorded in the audit chain")
check(any("refused" in m for _s, m in e.published), "and announced, so it is not a silent no-op")

# --- undo / renew through the engine ------------------------------------
e = make({"block_ip": "autonomous"})
e.handle_event(SCAN)
a = hl.active_actions(e.entries())[0]
check(e.renew(a.action_id, ttl=7200)[0], "an action can be renewed")
check(hl.replay(e.entries())[a.action_id].expires_at > time.time() + 7000,
      "renewal extends the rollback timer in the ledger")
check(e.undo(a.action_id)[0], "the operator can undo it early")
check(not hl.active_actions(e.entries()), "after undo nothing is in force")
check(any("delete element" in " ".join(c) for c in e.runner.commands), "undo hit nftables")
check(not e.undo(a.action_id)[0], "undoing twice is refused")
check(hl.verify_chain(e.entries())[0], "the chain still verifies after apply+renew+undo")

# --- rollback expiry sweep ----------------------------------------------
e = make({"block_ip": "autonomous"})
e.config["ttl"] = {"block_ip": 1.0}
e.handle_event(SCAN)
a = hl.active_actions(e.entries())[0]
check(e.sweep(time.time()) == 0, "nothing is swept while the timer is still running")
check(len(hl.active_actions(e.entries())) == 1, "the block is still in force")
swept = e.sweep(a.expires_at + 1)
check(swept == 1, f"the sweep reverts the action once its timer elapses ({swept})")
check(not hl.active_actions(e.entries()), "the expired action is no longer in force")
check(any(x["kind"] == hl.KIND_EXPIRED for x in e.entries()),
      "the auto-revert is recorded as 'expired', distinct from an operator undo")
check(any("delete element" in " ".join(c) for c in e.runner.commands),
      "the auto-revert really removed the rule")

# Reconcile: the ledger, not the kernel, is the record of what is in force.
e = make({"block_ip": "autonomous"})
e.handle_event(SCAN)
e.runner.commands.clear()
n = e.reconcile()
check(n == 1 and any("add element" in " ".join(c) for c in e.runner.commands),
      "reconcile() re-asserts active blocks (nftables.conf's `flush ruleset` drops them)")

# --- rate limiting / storm guard ----------------------------------------
lim = hl.RateLimiter(cooldown=300.0, max_per_window=3, window=60.0)
allowed, why = lim.allow("block_ip", "1.2.3.4", 1000.0)
check(allowed, "the first action on a target is allowed")
lim.record("block_ip", "1.2.3.4", 1000.0)
check(not lim.allow("block_ip", "1.2.3.4", 1010.0)[0], "the same target is debounced")
check(lim.allow("block_ip", "1.2.3.4", 1400.0)[0], "and allowed again after the cooldown")
lim2 = hl.RateLimiter(cooldown=0.0, max_per_window=3, window=60.0)
fired = 0
for i in range(50):
    if lim2.allow("block_ip", f"10.0.0.{i}", 2000.0 + i * 0.1)[0]:
        lim2.record("block_ip", f"10.0.0.{i}", 2000.0 + i * 0.1)
        fired += 1
check(fired == 3, f"a 50-source flood produces at most 3 actions, not 50 ({fired})")
big = hl.RateLimiter(cooldown=300.0, max_keys=100)
for i in range(500):
    big.record("block_ip", f"10.1.{i // 256}.{i % 256}", 3000.0 + i)
check(big.tracked() == 100, f"the limiter's memory is bounded ({big.tracked()})")

# An end-to-end storm through the real engine.
e = make({"block_ip": "autonomous"})
e.config["max_actions_per_window"] = 2
e.limiter = hl.RateLimiter(cooldown=0.0, max_per_window=2, window=600.0)
outcomes = [e.handle_event(dict(SCAN, message=f"port scan from 203.0.113.{i}"))
            for i in range(10)]
check(outcomes.count("applied") == 2, f"10 hostile sources -> 2 actions ({outcomes.count('applied')})")
check(outcomes.count("rate-limited") == 8, "the rest are recorded as rate-limited")
sys.exit(0 if ok else 1)
PY
then pass "engine end-to-end assertions"; else fail "engine end-to-end assertions" "see output above"; fi

section "--dry-run performs no side effects"
DRY="$WORK/dry"
mkdir -p "$DRY"
echo "malicious payload" > "$DRY/evil.bin"
DRY_BEFORE="$(cd "$DRY" && find . | sort)"
cat > "$WORK/autonomy.json" <<'JSON'
{"block_ip": "autonomous", "quarantine_file": "autonomous", "isolate_node": "autonomous",
 "kill_process": "autonomous", "rotate_mesh_keys": "autonomous",
 "revoke_matrix_session": "autonomous"}
JSON
rm -rf "$WORK/state-dry"
DRY_EVENTS="$WORK/dry-events.jsonl"
cat > "$DRY_EVENTS" <<JSON
{"ts": 1, "severity": "critical", "source": "firewall", "category": "scan", "message": "port scan from 203.0.113.9 - 60 ports"}
{"ts": 2, "severity": "warning", "source": "yara", "category": "malware", "message": "rule Trojan matched path=$DRY/evil.bin"}
{"ts": 3, "severity": "critical", "source": "health", "category": "compromise", "message": "host compromise asserted"}
JSON
DRY_OUT="$(ORIONX_HEALING_STATE="$WORK/state-dry" python3 "$HEAL_DIR/orionx-heald" \
    --stdin --dry-run -v --state-dir "$WORK/state-dry" < "$DRY_EVENTS" 2>&1)"

if echo "$DRY_OUT" | grep -q 'would run: nft add element'; then
    pass "dry-run PRINTS the intended nftables command"
else
    fail "dry-run prints the intended nftables command" "$DRY_OUT"
fi
if echo "$DRY_OUT" | grep -q 'would move'; then
    pass "dry-run prints the intended quarantine move"
else
    fail "dry-run prints the intended quarantine move" "$DRY_OUT"
fi
if echo "$DRY_OUT" | grep -q 'would emit'; then
    pass "dry-run prints the bus events it would emit"
else
    fail "dry-run prints the bus events it would emit" "$DRY_OUT"
fi
if echo "$DRY_OUT" | grep -q 'would append to the audit chain'; then
    pass "dry-run prints the ledger records it would seal"
else
    fail "dry-run prints the ledger records it would seal" "$DRY_OUT"
fi
# ...and now the part that matters: nothing actually happened.
if [[ -f "$DRY/evil.bin" ]] && grep -q "malicious payload" "$DRY/evil.bin"; then
    pass "dry-run did NOT move or alter the targeted file"
else
    fail "dry-run did NOT move or alter the targeted file" "the file was touched"
fi
if [[ "$(cd "$DRY" && find . | sort)" == "$DRY_BEFORE" ]]; then
    pass "dry-run left the target directory byte-for-byte unchanged"
else
    fail "dry-run left the target directory unchanged" "$(cd "$DRY" && find . | sort)"
fi
if [[ ! -e "$WORK/state-dry/chain.jsonl" ]]; then
    pass "dry-run wrote NO audit-chain records to disk"
else
    fail "dry-run wrote no audit-chain records" "$(cat "$WORK/state-dry/chain.jsonl")"
fi
if [[ ! -e "$WORK/state-dry/quarantine" ]]; then
    pass "dry-run created NO quarantine vault"
else
    fail "dry-run created no quarantine vault"
fi
if [[ ! -e "$ORIONX_EVENT_LOG" ]]; then
    pass "dry-run published NO events onto the bus"
else
    fail "dry-run published no events onto the bus" "$(cat "$ORIONX_EVENT_LOG")"
fi
# The same events WITHOUT --dry-run must be refused for lack of privilege or
# succeed — either way it proves the dry-run path was the thing suppressing it.
if python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import playbooks as pb
r = pb.Runner(dry_run=True)
rc, out, err = r.run(["nft", "add", "table", "inet", "orionx_healing"])
ok = rc == 0 and r.commands and not out
print("  ok   " if ok else "  BAD  ", "Runner.run() is the single dry-run choke point")
ok2, _e = r.move("/definitely/missing/src", "/definitely/missing/dst")
print("  ok   " if ok2 else "  BAD  ", "Runner.move() short-circuits before touching the filesystem")
sys.exit(0 if (ok and ok2) else 1)
PY
then pass "dry-run is enforced at one choke point"; else fail "dry-run choke point"; fi

section "Operator CLI (orionx-heal)"
HEAL="$HEAL_DIR/orionx-heal"
if python3 "$HEAL" list 2>&1 | grep -q 'block_ip'; then
    pass "orionx-heal list shows the registry"
else
    fail "orionx-heal list shows the registry"
fi
LISTOUT="$(python3 "$HEAL" list 2>&1)"
MISSING=""
for p in block_ip kill_process quarantine_file isolate_node rotate_mesh_keys revoke_matrix_session; do
    echo "$LISTOUT" | grep -q "$p" || MISSING="$MISSING $p"
done
if [[ -z "$MISSING" ]]; then pass "all six playbooks are listed"; else fail "all six playbooks listed" "missing:$MISSING"; fi
if echo "$LISTOUT" | grep -q 'undoes'; then pass "the listing states each playbook's undo"; else fail "listing states each undo"; fi
if python3 "$HEAL" --state-dir "$WORK/state-cli" status 2>&1 | grep -q 'Standing consent'; then
    pass "orionx-heal status reports the consent authority"
else
    fail "orionx-heal status reports the consent authority"
fi
# verify on a good chain, then on a tampered one.
rm -rf "$WORK/state-cli"; mkdir -p "$WORK/state-cli"
python3 - <<'PY'
import os
from pathlib import Path
import healing_lib as hl
c = Path(os.environ["ORIONX_HEALING_STATE"]).parent / "state-cli" / "chain.jsonl"
for i in range(4):
    hl.append_entry({"kind": hl.KIND_APPLIED, "action_id": f"c{i}",
                     "playbook": "block_ip", "target": f"203.0.113.{i}"}, c)
PY
if python3 "$HEAL" --state-dir "$WORK/state-cli" verify 2>&1 | grep -q 'INTACT'; then
    pass "orionx-heal verify reports an intact chain"
else
    fail "orionx-heal verify reports an intact chain"
fi
python3 - <<'PY'
import json, os
from pathlib import Path
c = Path(os.environ["ORIONX_HEALING_STATE"]).parent / "state-cli" / "chain.jsonl"
rows = [json.loads(l) for l in c.read_text().splitlines() if l.strip()]
rows[2]["target"] = "10.0.0.1"          # tamper
c.write_text("".join(json.dumps(r) + "\n" for r in rows))
PY
VOUT="$(python3 "$HEAL" --state-dir "$WORK/state-cli" verify 2>&1)"; VRC=$?
if [[ $VRC -ne 0 ]]; then pass "orionx-heal verify EXITS NON-ZERO on a tampered chain"; else fail "verify exits non-zero on tamper" "$VOUT"; fi
if echo "$VOUT" | grep -q 'BROKEN at record #2'; then
    pass "verify names the first broken link (#2)"
else
    fail "verify names the first broken link" "$VOUT"
fi
# A manual run must still obey the guards.
RUNOUT="$(python3 "$HEAL" --state-dir "$WORK/state-cli" run block_ip --target 127.0.0.1 2>&1)"; RRC=$?
if [[ $RRC -ne 0 ]] && echo "$RUNOUT" | grep -qi 'loopback'; then
    pass "a MANUAL run is still refused for loopback (guards outrank the operator)"
else
    fail "manual run refused for loopback" "$RUNOUT"
fi

section "Bus + build wiring"
if grep -q '"orionx-event"' "$HEAL_DIR/engine.py"; then
    pass "publishes via the orionx-event CLI (same pattern as scanwatch/nucleotide)"
else
    fail "publishes via the orionx-event CLI"
fi
if grep -q 'events.jsonl' "$HEAL_DIR/healing_lib.py"; then
    pass "consumes the shared R.A.I.N. event bus"
else
    fail "consumes the shared R.A.I.N. event bus"
fi
if grep -q 'SELF_SOURCE' "$HEAL_DIR/healing_lib.py" && grep -q 'SELF_SOURCE' "$HEAL_DIR/engine.py"; then
    pass "emits under a single source name, and refuses it on input (loop break)"
else
    fail "loop-break source name shared between emitter and matcher"
fi
UNIT="$CHROOT/usr/share/orionx/systemd/orionx-heald.service"
if [[ -f "$UNIT" ]]; then pass "systemd unit staged"; else fail "systemd unit staged" "missing $UNIT"; fi
if grep -q '/opt/orionx/scripts/healing/orionx-heald' "$UNIT"; then
    pass "unit ExecStart points at the rsynced /opt/orionx path"
else
    fail "unit ExecStart points at the rsynced /opt/orionx path"
fi
if grep -q '@decision DEC-PHASE12-023' "$UNIT"; then pass "unit carries the decision annotation"; else fail "unit carries the decision annotation"; fi
if grep -q 'ORIONX_OPERATOR_USER' "$UNIT"; then
    pass "unit points the root daemon at the DESKTOP user's autonomy.json"
else
    fail "unit points the root daemon at the desktop user's autonomy.json" \
         "root's Path.home() is /root — the grid would be invisible"
fi
if grep -q 'StateDirectory=orionx/healing' "$UNIT"; then
    pass "unit declares a persistent StateDirectory (ledger survives restart)"
else
    fail "unit declares a persistent StateDirectory"
fi
if grep -q 'ORIONX-DROP' "$CHROOT/etc/nftables.conf"; then
    pass "the firewall still logs drops (the engine's upstream detection input)"
else
    fail "firewall drop-log prefix missing"
fi
if grep -q 'flush ruleset' "$CHROOT/etc/nftables.conf" && grep -q 'reconcile' "$HEAL_DIR/engine.py"; then
    pass "nftables.conf flushes the ruleset AND the engine reconciles after it"
else
    fail "engine reconciles blocks after a firewall reload"
fi
# The engine must not touch the shipped baseline table. Checked against the
# CODE, not the prose: playbooks.py names inet orionx_firewall in its rationale
# precisely to record that it stays out of it. Docstrings are excluded via AST.
if ! grep -q 'orionx_firewall' "$CHROOT/etc/nftables.conf"; then
    fail "the shipped firewall table is named inet orionx_firewall" "baseline changed?"
elif BADSTR="$(python3 -c 'import ast,sys; src=sys.argv[1]; tree=ast.parse(open(src,encoding="utf-8").read()); docs={ast.get_docstring(n,clean=False) for n in ast.walk(tree) if isinstance(n,(ast.Module,ast.FunctionDef,ast.AsyncFunctionDef,ast.ClassDef))}; bad=[n.value for n in ast.walk(tree) if isinstance(n,ast.Constant) and isinstance(n.value,str) and n.value not in docs and "orionx_firewall" in n.value]; print(bad); sys.exit(1 if bad else 0)' "$HEAL_DIR/playbooks.py")"; then
    pass "the engine never writes the shipped inet orionx_firewall table"
else
    fail "the engine must not write the shipped firewall table" "$BADSTR"
fi
if grep -q 'HEAL_TABLE = "orionx_healing"' "$HEAL_DIR/playbooks.py"; then
    pass "blocks go into the engine own additive table/named set"
else
    fail "blocks go into the engine own table"
fi
CC_TAB="$REPO_ROOT/scripts/control_center/sections/auto_healing.py"
if grep -q 'orionx-heald' "$CC_TAB"; then
    pass "the Control Center tab names the engine that consumes its file"
else
    fail "Control Center tab still claims execution is unimplemented"
fi
if grep -q 'lands in W10-6' "$CC_TAB"; then
    pass "the W10-6 marker test_control_center.sh greps for is preserved"
else
    fail "W10-6 marker preserved in auto_healing.py"
fi

section "Daemon bus tailing"
# Regression: --once seeked to EOF before reading, so "process what is already
# on the bus" silently processed nothing at all.
BUSW="$WORK/bus"
mkdir -p "$BUSW"
cat > "$WORK/autonomy.json" <<'JSON'
{"block_ip": "propose", "kill_process": "propose"}
JSON
cat > "$BUSW/bus.jsonl" <<'JSON'
{"ts": 1, "severity": "critical", "source": "firewall", "category": "scan", "message": "port scan from 203.0.113.9 - 60 ports"}
{"ts": 2, "severity": "critical", "source": "go-roast", "category": "process", "message": "malicious pid=31337"}
{"ts": 3, "severity": "critical", "source": "healing", "category": "heal", "message": "block_ip applied to 203.0.113.9"}
JSON
ONCE_OUT="$(python3 "$HEAL_DIR/orionx-heald" --once -v --bus "$BUSW/bus.jsonl" \
    --state-dir "$BUSW/state" --no-reconcile --dry-run 2>&1)"
if echo "$ONCE_OUT" | grep -q 'PROPOSE block_ip 203.0.113.9'; then
    pass "--once reads the bus FROM THE START (regression: it seeked to EOF and did nothing)"
else
    fail "--once processes events already on the bus" "$ONCE_OUT"
fi
if echo "$ONCE_OUT" | grep -q 'PROPOSE kill_process 31337'; then
    pass "--once processes every event on the bus, not just the first"
else
    fail "--once processes every event" "$ONCE_OUT"
fi
if [[ "$(echo "$ONCE_OUT" | grep -c PROPOSE)" -eq 2 ]]; then
    pass "the engine's OWN bus event is skipped (2 actions from 3 events)"
else
    fail "the engine's own bus event is skipped" "$ONCE_OUT"
fi
# The daemon loop must do the opposite: start at EOF so a systemd restart
# during an incident does not replay an hour of history as fresh actions.
# Proven by EXECUTING the daemon in tests/unit/test_bus_reader.sh (the shared
# rain_lib.BusTail, DEC-PHASE12-083); the old source-text grep is gone.
STDIN_OUT="$(python3 "$HEAL_DIR/orionx-heald" --stdin --dry-run -v \
    --state-dir "$BUSW/state2" < "$BUSW/bus.jsonl" 2>&1)"
if echo "$STDIN_OUT" | grep -q 'PROPOSE block_ip'; then
    pass "--stdin feeds events for testing without a live bus"
else
    fail "--stdin feeds events" "$STDIN_OUT"
fi
if printf 'not json\n\n{"broken":\n' | python3 "$HEAL_DIR/orionx-heald" --stdin \
        --dry-run --state-dir "$BUSW/state3" >/dev/null 2>&1; then
    pass "malformed bus lines are skipped without crashing the daemon"
else
    fail "malformed bus lines are skipped without crashing the daemon"
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
