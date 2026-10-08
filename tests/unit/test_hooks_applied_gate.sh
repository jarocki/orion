#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_hooks_applied_gate.sh — tests/integration/test-iso-hooks-applied.sh
# (DEC-PHASE12-120). Behavioural: runs the real gate against canned build logs
# and a scratch hook directory (ORIONX_HOOK_ROOT).
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
GATE="$REPO_ROOT/tests/integration/test-iso-hooks-applied.sh"
S="$REPO_ROOT/tmp/test_hooks_gate_$$"; trap 'rm -rf "$S"' EXIT
mkdir -p "$S/hooks/live" "$S/hooks/normal"
for h in live/0500-a.hook.chroot live/0900-trim.hook.chroot normal/0100-create-user.hook.chroot normal/0500-x.hook.binary; do
    printf '#!/bin/sh\n' > "$S/hooks/$h"; chmod +x "$S/hooks/$h"
done
ln -s /nonexistent/0020-stale.hook.chroot "$S/hooks/normal/0020-stale.hook.chroot"   # dangling: never runs
printf '#!/bin/sh\n' > "$S/hooks/live/README.hook.chroot.txt"
good() {
    echo "W: Skipping bootstrap, already done"
    for h in live/0500-a.hook.chroot live/0900-trim.hook.chroot normal/0100-create-user.hook.chroot normal/0500-x.hook.binary; do
        echo "P: Executing hook config/hooks/$h..."
    done
}
run() { ORIONX_HOOK_ROOT="$S/hooks" BUILD_LOG="$1" bash "$GATE" > "$S/out" 2>&1; echo $?; }

good > "$S/good.log"
[[ "$(run "$S/good.log")" == 0 ]] && pass "complete log passes" || fail "complete log" "$(tail -5 "$S/out")"
grep -q "4 hooks expected" "$S/out" && pass "expected set derived from the directory (4; dangling link ignored)" || fail "derived set" "$(grep expected "$S/out")"
good | grep -v 0900-trim > "$S/miss.log"
[[ "$(run "$S/miss.log")" == 1 ]] && grep -q "NOT executed: config/hooks/live/0900-trim" "$S/out" && pass "a hook missing from the log fails, named" || fail "missing hook" "$(tail -5 "$S/out")"
{ good; echo "P: Executing hook config/hooks/live/0500-a.hook.chroot..."; } > "$S/dup.log"
[[ "$(run "$S/dup.log")" == 1 ]] && pass "a hook executed twice in one log fails" || fail "duplicate" "accepted"
{ good; echo "W: Skipping chroot_hooks, already done"; } > "$S/stale.log"
[[ "$(run "$S/stale.log")" == 1 ]] && pass "stale chroot_hooks reuse fails (build-iso.sh check_no_stale_skips)" || fail "stale" "accepted"
{ good; echo "SOFT-FAIL: zeek NOT installed"; } > "$S/soft.log"
[[ "$(run "$S/soft.log")" == 1 ]] && pass "a SOFT-FAIL line fails the gate" || fail "soft-fail" "accepted"
[[ "$(run "$S/absent.log")" == 1 ]] && pass "no build log is a FAIL, not an exit-0 SKIP" || fail "no log" "$(tail -3 "$S/out")"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
