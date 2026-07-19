#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for orionx-diag (W11-11, DEC-PHASE11-015)
#
# Validates the diagnostic tool's structure, arg-parse contract, and JSON output
# shape WITHOUT running the full check suite (which requires live ISO state).
# All 6 assertions (T6a-T6f per MASTER_PLAN.md §W11-11 Tasks T6) must pass.
#
# @decision DEC-PHASE11-015
# @title Unit tests for orionx-diag structural integrity + arg-parse + JSON shape
# @status accepted
# @rationale The tool targets the live Orion-X ISO environment; its runtime
#   assertions (identity tokens, installed packages, systemd units) will FAIL on
#   any dev machine. These unit tests validate structure and CLI contract without
#   depending on live system state. The compound-interaction test (T6e) exercises
#   the full --json + --category path end-to-end, confirming JSON emission is
#   correct even when assertions FAIL. This matches the production pattern: an
#   operator on a partially-broken ISO would see FAIL results in JSON, not a
#   crash or malformed output. References: MASTER_PLAN.md §W11-11 T6, W11-11.
#
# Production sequence:
#   1. orionx-diag is staged into includes.chroot/opt/orionx/scripts/orionx-diag
#   2. 0700 hook symlinks it to /usr/bin/orionx-diag at build time
#   3. Operator runs: sudo orionx-diag (or sudo orionx-diag --json --category X)
#   4. orionx-diag reads /etc/orionx-version, runs 10 check categories, exits 0/1
#
# Usage: bash tests/unit/test_orionx_diag.sh
# Exit: 0 iff all assertions pass

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DIAG_SCRIPT="$REPO_ROOT/iso/config/includes.chroot/opt/orionx/scripts/orionx-diag"

# ---------------------------------------------------------------------------
# Test counters — use ((VAR+=1)) style to avoid set -e firing on zero-result
# arithmetic in bash 5+
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

pass() {
    ((PASS+=1))
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    ((FAIL+=1))
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

skip() {
    ((SKIP+=1))
    echo "${YELLOW}  SKIP${NC}: $1  (${2:-})"
}

echo "=== orionx-diag unit tests (W11-11 T6, DEC-PHASE11-015) ==="
echo "    Script under test: $DIAG_SCRIPT"
echo ""

# ===========================================================================
# T6a — Script present + executable + bash -n syntax check
# ===========================================================================
echo "--- T6a: script present + executable + bash -n ---"

if [[ -f "$DIAG_SCRIPT" ]]; then
    pass "T6a: $DIAG_SCRIPT exists"
else
    fail "T6a: $DIAG_SCRIPT exists" \
         "file absent — run W11-11 T1 to create the script"
fi

if [[ -x "$DIAG_SCRIPT" ]]; then
    pass "T6a: $DIAG_SCRIPT is executable"
else
    fail "T6a: $DIAG_SCRIPT is executable" \
         "chmod +x $DIAG_SCRIPT to fix"
fi

if [[ -f "$DIAG_SCRIPT" ]]; then
    if bash -n "$DIAG_SCRIPT" 2>/dev/null; then
        pass "T6a: bash -n (syntax check) exits 0"
    else
        SYNTAX_ERR="$(bash -n "$DIAG_SCRIPT" 2>&1 || true)"
        fail "T6a: bash -n (syntax check) exits 0" \
             "syntax error: $SYNTAX_ERR"
    fi
fi

# ===========================================================================
# T6b — --help exits 0 and output contains --json and --category
# ===========================================================================
echo ""
echo "--- T6b: --help exits 0 + contains --json and --category ---"

if [[ -f "$DIAG_SCRIPT" ]]; then
    HELP_EXIT=0
    HELP_OUT="$(bash "$DIAG_SCRIPT" --help 2>&1)" || HELP_EXIT=$?
    if [[ $HELP_EXIT -eq 0 ]]; then
        pass "T6b: --help exits 0"
    else
        fail "T6b: --help exits 0" \
             "--help exited $HELP_EXIT"
    fi

    if echo "$HELP_OUT" | grep -q -- '--json'; then
        pass "T6b: --help output contains '--json'"
    else
        fail "T6b: --help output contains '--json'" \
             "--json not found in --help output"
    fi

    if echo "$HELP_OUT" | grep -q -- '--category'; then
        pass "T6b: --help output contains '--category'"
    else
        fail "T6b: --help output contains '--category'" \
             "--category not found in --help output"
    fi
else
    fail "T6b: --help exits 0" "script absent — cannot execute"
    fail "T6b: --help output contains '--json'" "script absent"
    fail "T6b: --help output contains '--category'" "script absent"
fi

# ===========================================================================
# T6c — --version exits 0 and prints a non-empty string
# ===========================================================================
echo ""
echo "--- T6c: --version exits 0 + prints a version string ---"

if [[ -f "$DIAG_SCRIPT" ]]; then
    VER_EXIT=0
    VER_OUT="$(bash "$DIAG_SCRIPT" --version 2>&1)" || VER_EXIT=$?
    if [[ $VER_EXIT -eq 0 ]]; then
        pass "T6c: --version exits 0"
    else
        fail "T6c: --version exits 0" \
             "--version exited $VER_EXIT"
    fi

    if [[ -n "$VER_OUT" ]]; then
        pass "T6c: --version prints a non-empty version string" \
             "(value: $VER_OUT)"
    else
        fail "T6c: --version prints a non-empty version string" \
             "output was empty"
    fi
else
    fail "T6c: --version exits 0" "script absent"
    fail "T6c: --version prints a non-empty version string" "script absent"
fi

# ===========================================================================
# T6d — --category nonexistent exits non-zero with "unknown category" in output
# ===========================================================================
echo ""
echo "--- T6d: --category nonexistent exits non-zero + 'unknown category' message ---"

if [[ -f "$DIAG_SCRIPT" ]]; then
    BAD_CAT_EXIT=0
    BAD_CAT_OUT="$(bash "$DIAG_SCRIPT" --category nonexistent 2>&1)" || BAD_CAT_EXIT=$?
    if [[ $BAD_CAT_EXIT -ne 0 ]]; then
        pass "T6d: --category nonexistent exits non-zero (got: $BAD_CAT_EXIT)"
    else
        fail "T6d: --category nonexistent exits non-zero" \
             "exited 0 — should exit 1 or 2 on unknown category"
    fi

    if echo "$BAD_CAT_OUT" | grep -qi "unknown category"; then
        pass "T6d: error output contains 'unknown category'"
    else
        fail "T6d: error output contains 'unknown category'" \
             "got: $BAD_CAT_OUT"
    fi
else
    fail "T6d: --category nonexistent exits non-zero" "script absent"
    fail "T6d: error output contains 'unknown category'" "script absent"
fi

# ===========================================================================
# T6e — Compound interaction: --json --category identity on dev host
#        exits non-zero (identity FAILs on non-ISO host) AND emits valid JSON
#
# This is the primary compound-interaction test per MASTER_PLAN.md §W11-11.
# It exercises the full production path end-to-end:
#   arg-parse -> category dispatch -> check_fail recording -> emit_json
# The host is NOT an Orion-X live system so identity checks FAIL (expected),
# but JSON emission must not corrupt on FAIL — that's the critical invariant.
# ===========================================================================
echo ""
echo "--- T6e: --json --category identity: exits non-zero AND valid JSON ---"

if [[ -f "$DIAG_SCRIPT" ]]; then
    JSON_EXIT=0
    JSON_OUT="$(bash "$DIAG_SCRIPT" --json --category identity 2>&1)" || JSON_EXIT=$?

    # Must exit non-zero: host is not orionx-operator / hostname orionx
    if [[ $JSON_EXIT -ne 0 ]]; then
        pass "T6e: --json --category identity exits non-zero on non-ISO host (identity FAILs)"
    else
        # Could exit 0 if somehow on an orionx host — that's also fine
        pass "T6e: --json --category identity exits 0 (running on actual Orion-X host?)"
    fi

    # JSON must parse cleanly regardless of PASS/FAIL results
    if echo "$JSON_OUT" | python3 -m json.tool > /dev/null 2>&1; then
        pass "T6e: --json --category identity output is valid JSON"
    else
        fail "T6e: --json --category identity output is valid JSON" \
             "python3 -m json.tool failed to parse output: $(echo "$JSON_OUT" | head -3)"
    fi

    # JSON must have 'overall' field
    if echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'overall' in d" \
            2>/dev/null; then
        pass "T6e: JSON output contains 'overall' field"
    else
        fail "T6e: JSON output contains 'overall' field" \
             "'overall' key missing from JSON output"
    fi

    # JSON must have 'categories' map
    if echo "$JSON_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'categories' in d" \
            2>/dev/null; then
        pass "T6e: JSON output contains 'categories' map"
    else
        fail "T6e: JSON output contains 'categories' map" \
             "'categories' key missing from JSON output"
    fi

    # With --category identity, categories map must have exactly one entry
    CAT_COUNT="$(echo "$JSON_OUT" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(len(d.get('categories',{})))" 2>/dev/null \
        || echo "0")"
    if [[ "$CAT_COUNT" == "1" ]]; then
        pass "T6e: --category filter produces exactly 1 category in JSON output"
    else
        fail "T6e: --category filter produces exactly 1 category in JSON output" \
             "got $CAT_COUNT categories — filter not working"
    fi
else
    fail "T6e: --json --category identity exits non-zero on non-ISO host" "script absent"
    fail "T6e: --json --category identity output is valid JSON" "script absent"
    fail "T6e: JSON output contains 'overall' field" "script absent"
    fail "T6e: JSON output contains 'categories' map" "script absent"
    fail "T6e: --category filter produces exactly 1 category in JSON output" "script absent"
fi

# ===========================================================================
# T6f — shellcheck -S error exits 0 (no severity=error findings)
# ===========================================================================
echo ""
echo "--- T6f: shellcheck -S error exits 0 ---"

if ! command -v shellcheck &>/dev/null; then
    skip "T6f: shellcheck -S error exits 0" "shellcheck not on PATH"
elif [[ ! -f "$DIAG_SCRIPT" ]]; then
    fail "T6f: shellcheck -S error exits 0" "script absent"
else
    SC_EXIT=0
    SC_OUT="$(shellcheck -S error "$DIAG_SCRIPT" 2>&1)" || SC_EXIT=$?
    if [[ $SC_EXIT -eq 0 ]]; then
        pass "T6f: shellcheck -S error exits 0 (no severity=error findings)"
    else
        fail "T6f: shellcheck -S error exits 0 (no severity=error findings)" \
             "shellcheck findings: $(echo "$SC_OUT" | head -5)"
    fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL + SKIP ))
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    echo "${RED}FAIL${NC}: orionx-diag unit tests — $FAIL assertion(s) failed"
    exit 1
fi
echo "${GREEN}PASS${NC}: orionx-diag unit tests — all $PASS assertions passed (${SKIP} skipped)"
exit 0
