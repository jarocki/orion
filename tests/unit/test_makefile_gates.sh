#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_makefile_gates.sh — the unit gates must not lie (DEC-PHASE12-110)
#
# Behavioural: copies the real Makefile into a scratch tree with canned
# suites and runs the real targets. Asserts that
#   - a failing pytest test makes `make test-unit` exit non-zero (P1-2, F-01);
#   - every bash suite runs even after an earlier one fails, all failures are
#     listed, and the Python suite still runs (P2-6, F-16);
#   - an all-green tree exits 0;
#   - `make clean` keeps output/*.iso unless CLEAN_ISOS=1 (P2-8);
#   - `make lint-python` leaves no __pycache__ behind (F-23).
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }
export PYTHONDONTWRITEBYTECODE=1

SCRATCH="$REPO_ROOT/tmp/test_makefile_gates_$$"
trap 'rm -rf "$SCRATCH"' EXIT

mk_tree() {  # $1 = dir; builds a tree whose suites are given by the caller
    rm -rf "$1"; mkdir -p "$1/tests/unit" "$1/scripts"
    cp "$REPO_ROOT/Makefile" "$1/Makefile"
}
python_has_pytest() { python3 -c 'import pytest' >/dev/null 2>&1; }

section "test-unit: failures anywhere make the gate fail, and nothing is skipped"
T="$SCRATCH/red"; mk_tree "$T"
printf '#!/usr/bin/env bash\necho a-ran; exit 1\n' > "$T/tests/unit/test_a_fail.sh"
printf '#!/usr/bin/env bash\ntouch "%s/b-ran"; exit 0\n' "$T" > "$T/tests/unit/test_b_pass.sh"
printf '#!/usr/bin/env bash\necho c-ran; exit 1\n' > "$T/tests/unit/test_c_fail.sh"
printf 'def test_red():\n    assert 1 == 2\n' > "$T/tests/unit/test_red.py"
OUT="$(make -C "$T" --no-print-directory test-unit 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && pass "make test-unit exits non-zero (rc=$RC)" || fail "make test-unit exit" "rc=0 with failing suites"
[[ -f "$T/b-ran" ]] && pass "a suite after a failing one still ran" || fail "bash loop" "stopped at first failure"
[[ "$OUT" == *"FAIL tests/unit/test_a_fail.sh"* && "$OUT" == *"FAIL tests/unit/test_c_fail.sh"* ]] \
    && pass "both failing bash suites are listed" || fail "failure list" "$OUT"
if python_has_pytest; then
    [[ "$OUT" == *"1 failed"* ]] && pass "Python suite ran after bash failures and reported its failure" \
        || fail "pytest ran" "no '1 failed' in output"
    [[ "$OUT" != *"No Python unit tests found yet"* ]] && pass "no soft-fail 'not found' message" || fail "soft-fail text" "still present"
else
    fail "pytest available" "python3 -m pytest is required for this gate"
fi

section "test-unit-python alone: a failing test is a failure"
OUT="$(make -C "$T" --no-print-directory test-unit-python 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && pass "make test-unit-python exits non-zero on a failing test" || fail "pytest gate" "rc=0"

section "test-unit: an all-green tree passes"
G="$SCRATCH/green"; mk_tree "$G"
printf '#!/usr/bin/env bash\nexit 0\n' > "$G/tests/unit/test_ok.sh"
printf 'def test_green():\n    assert True\n' > "$G/tests/unit/test_green.py"
OUT="$(make -C "$G" --no-print-directory test-unit 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && pass "green tree exits 0" || fail "green tree" "rc=$RC: $OUT"

section "clean keeps ISOs unless CLEAN_ISOS=1"
C="$SCRATCH/clean"; mk_tree "$C"
mkdir -p "$C/output" "$C/iso/cache" "$C/iso/build" "$C/scripts/__pycache__"
echo iso > "$C/output/orionx-phoenix-edition-v9.iso"
make -C "$C" --no-print-directory clean >/dev/null 2>&1
[[ -f "$C/output/orionx-phoenix-edition-v9.iso" ]] && pass "make clean keeps output/*.iso" || fail "make clean" "deleted the ISO"
[[ ! -d "$C/iso/cache" && ! -d "$C/iso/build" && ! -d "$C/scripts/__pycache__" ]] \
    && pass "make clean still removes iso/cache, iso/build, __pycache__" || fail "make clean" "build state left"
make -C "$C" --no-print-directory clean CLEAN_ISOS=1 >/dev/null 2>&1
[[ ! -e "$C/output" ]] && pass "CLEAN_ISOS=1 removes output/" || fail "CLEAN_ISOS=1" "output/ survived"

section "lint-python leaves no bytecode in the source tree"
L="$SCRATCH/lint"; mk_tree "$L"
printf 'print("ok")\n' > "$L/scripts/ok.py"
make -C "$L" --no-print-directory lint-python >/dev/null 2>&1
[[ ! -d "$L/scripts/__pycache__" ]] && pass "no scripts/__pycache__ after lint-python" || fail "lint bytecode" "__pycache__ created"
printf 'def broken(:\n' > "$L/scripts/bad.py"
make -C "$L" --no-print-directory lint-python >/dev/null 2>&1 && fail "syntax gate" "bad.py passed" || pass "a syntax error fails lint-python"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
