#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2015  # `test && pass || fail`: pass() always returns 0
# ---------------------------------------------------------------------------
# test_decision_log.sh — the Decision Log is derived from the inline blocks
#
# Inline `@decision` blocks are the authority for every decision from Phase 12
# onward (DEC-PHASE13-045, #97). This suite is the gate that keeps the derived
# surface honest:
#   1. `decision_log.py --check` passes on the tree: every DEC-PHASE12+ id has
#      exactly one full block (or one marked @canonical), no id is referenced
#      without a block or a hand-written row, no row and block for one id.
#   2. The generated region of MASTER_PLAN.md equals `--since PHASE12` output
#      byte for byte, so `make decision-log` has been run after the last block
#      change.
#   3. `--check` really fails: a scratch tree with a duplicate id and a
#      malformed block exits non-zero and names both file:line sites.
#
# Usage: bash tests/unit/test_decision_log.sh
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }
export PYTHONDONTWRITEBYTECODE=1

TOOL="$REPO_ROOT/scripts/decisions/decision_log.py"
PLAN="$REPO_ROOT/MASTER_PLAN.md"
mkdir -p "$REPO_ROOT/tmp"
WORK="$(mktemp -d "$REPO_ROOT/tmp/decision-log.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

section "1. --check passes on the tree"
OUT="$(python3 "$TOOL" --root "$REPO_ROOT" --check 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && pass "decision_log.py --check exit 0" || fail "decision_log.py --check" "rc=$RC: $OUT"
[[ "$OUT" == *"decision_log: OK ("* ]] && pass "check reports OK with counts: ${OUT##*OK }" || fail "check summary" "$OUT"

section "2. MASTER_PLAN's generated region equals --since PHASE12 (byte for byte)"
python3 "$TOOL" --root "$REPO_ROOT" --since PHASE12 > "$WORK/expected.md"; RC=$?
[[ $RC -eq 0 && -s "$WORK/expected.md" ]] && pass "--since PHASE12 emits a table" || fail "--since PHASE12" "rc=$RC"
awk '/^<!-- decision-log:generated start /{f=1; next} /^<!-- decision-log:generated end -->$/{f=0} f' "$PLAN" > "$WORK/actual.md"
grep -q '^<!-- decision-log:generated start (scripts/decisions/decision_log.py --since PHASE12; do not hand-edit) -->$' "$PLAN" \
    && pass "start marker present with the regeneration command" || fail "start marker" "missing or reworded"
grep -q '^<!-- decision-log:generated end -->$' "$PLAN" && pass "end marker present" || fail "end marker" "missing"
if cmp -s "$WORK/expected.md" "$WORK/actual.md"; then
    pass "generated region is current ($(grep -c '^| DEC-' "$WORK/actual.md") rows)"
else
    fail "generated region" "differs from the generator; run 'make decision-log' and commit MASTER_PLAN.md"
    diff "$WORK/actual.md" "$WORK/expected.md" | head -20
fi
head -1 "$WORK/actual.md" | grep -q '^| ID | Date | Decision | Rationale |$' && pass "region carries its own table header" || fail "region header" "$(head -1 "$WORK/actual.md")"
grep -q '^| DEC-PHASE13-045 | ' "$WORK/actual.md" && pass "DEC-PHASE13-045 (this mechanism) is a generated row" || fail "DEC-PHASE13-045 row" "missing"
grep -q '^| DEC-PHASE13-000 | ' "$PLAN" && pass "DEC-PHASE13-000 stays as a hand-written row" || fail "DEC-PHASE13-000" "missing"
! grep -q '^| DEC-PHASE13-000 | ' "$WORK/actual.md" && pass "DEC-PHASE13-000 is not inside the generated region" || fail "DEC-PHASE13-000" "inside generated region"
grep -c '^| DEC-PHASE12-' "$WORK/actual.md" | awk '{exit !($1 >= 100)}' && pass "Phase 12 has 100+ generated rows" || fail "Phase 12 rows" "$(grep -c '^| DEC-PHASE12-' "$WORK/actual.md")"

section "3. --check fails loudly on a bad tree (duplicate id, malformed block, dangling reference)"
T="$WORK/bad"; mkdir -p "$T/scripts/a" "$T/scripts/b"
cat > "$T/MASTER_PLAN.md" <<'EOF'
## Decision Log

<!-- decision-log:generated start (scripts/decisions/decision_log.py --since PHASE12; do not hand-edit) -->
<!-- decision-log:generated end -->

## Risk Register
EOF
cat > "$T/scripts/a/one.py" <<'EOF'
# @decision DEC-PHASE12-900
# @title First
# @status accepted
# @rationale One.
x = 1  # see DEC-PHASE12-902
EOF
cat > "$T/scripts/b/two.sh" <<'EOF'
# @decision DEC-PHASE12-900
# @title Second, same id, no @canonical on either
# @status accepted
# @rationale Two.
# @decision DEC-PHASE12-901
# @title Missing status and rationale
EOF
OUT="$(python3 "$TOOL" --root "$T" --check 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && pass "bad tree exits non-zero (rc=$RC)" || fail "bad tree rc" "rc=0"
[[ "$OUT" == *"DEC-PHASE12-900 has 2 full blocks"*"scripts/a/one.py:1"*"scripts/b/two.sh:1"* ]] \
    && pass "duplicate id names both sites" || fail "duplicate report" "$OUT"
[[ "$OUT" == *"scripts/b/two.sh:5: DEC-PHASE12-901 block is missing @status, @rationale"* ]] \
    && pass "malformed block names file:line and the missing tags" || fail "malformed report" "$OUT"
[[ "$OUT" == *"DEC-PHASE12-902 is referenced"*"no @decision block"* ]] \
    && pass "dangling reference is reported" || fail "dangling report" "$OUT"
OUT="$(python3 "$TOOL" --root "$T" --write 2>&1)"; RC=$?
[[ $RC -ne 0 && "$OUT" == *"refusing to write"* ]] && pass "--write refuses on a failing check" || fail "--write guard" "rc=$RC: $OUT"

section "4. @canonical resolves a duplicate, and --write is idempotent"
cat > "$T/scripts/b/two.sh" <<'EOF'
# @decision DEC-PHASE12-900
# @canonical
# @title Second, same id, no @canonical on either
# @status accepted
# @rationale Two.
# @decision DEC-PHASE12-901
# @title Missing status and rationale
# @status accepted
# @rationale Fixed.
EOF
printf '# @decision DEC-PHASE12-900\n# @title First\n# @status accepted\n# @rationale One.\nx = 1\n' > "$T/scripts/a/one.py"
OUT="$(python3 "$TOOL" --root "$T" --check 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && pass "fixed tree passes --check" || fail "fixed tree" "$OUT"
python3 "$TOOL" --root "$T" --write >/dev/null 2>&1
grep -q '^| DEC-PHASE12-900 | [0-9-]* | \[MISC\] Second, same id, no @canonical on either | Two. |$' "$T/MASTER_PLAN.md" \
    && pass "the @canonical block's title is the row" || fail "canonical row" "$(grep DEC-PHASE12-900 "$T/MASTER_PLAN.md")"
OUT="$(python3 "$TOOL" --root "$T" --write 2>&1)"
[[ "$OUT" == *"already current"* ]] && pass "second --write is a no-op" || fail "idempotent write" "$OUT"

section "A shallow clone refuses to emit rows (blame would misdate every row)"
S="$WORK/shallow"; mkdir -p "$S/src"
git -C "$S/src" init -q && git -C "$S/src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one \
    && git -C "$S/src" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
git clone -q --depth 1 "file://$S/src" "$S/clone" 2>/dev/null
OUT="$(python3 "$TOOL" --root "$S/clone" --since PHASE12 2>&1)"; RC=$?
[[ $RC -eq 2 && "$OUT" == *"shallow clone"* ]] && pass "rows refused in a shallow clone (exit 2, says why)" \
    || fail "shallow guard" "rc=$RC $OUT"
OUT="$(python3 "$TOOL" --root "$S/clone" --check 2>&1)"; RC=$?
[[ "$OUT" != *"shallow clone"* ]] && pass "--check still runs in a shallow clone (it emits no dates)" \
    || fail "shallow --check" "$OUT"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
