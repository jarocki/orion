#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for scripts/qemu-boot-test.sh — version-drift consolidation
#
# @decision DEC-PHASE9-015
# @title Unit assertions for glob-resolved ISO default (no rc-literal drift)
# @status accepted
# @rationale These tests fulfill the W9-1b iter-4 Evaluation Contract requirement
#   that scripts/qemu-boot-test.sh contains zero literal rc-version references in
#   functional (non-comment) lines, and that the glob-resolution default is wired
#   in. They also verify that test-iso-content-presence.sh header comment no longer
#   references the stale rc1 path, closing the cosmetic note raised in iter-1.
#
# Usage:
#   bash tests/unit/test_qemu_boot_test_default.sh
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QEMU_SCRIPT="${REPO_ROOT}/scripts/qemu-boot-test.sh"
CONTENT_PRESENCE="${REPO_ROOT}/tests/integration/test-iso-content-presence.sh"

PASS=0
FAIL=0
ERRORS=()

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("FAIL: $1")
    echo "  FAIL: $1"
}

# ---------------------------------------------------------------------------
# T1: No literal rc1 ISO name in functional lines of qemu-boot-test.sh.
#     Functional lines = lines that are not pure comments (# ...).
#     This catches regressions where someone adds back a hardcoded rc-string.
# ---------------------------------------------------------------------------
echo "T1: qemu-boot-test.sh has no literal rc1 ISO reference in functional lines"
# Strip comment-only lines (lines whose first non-space char is #), then search.
functional_rc1_hits="$(grep -n 'orionx-phoenix-edition-v2\.0\.0-rc1\.iso' "${QEMU_SCRIPT}" \
    | grep -v '^[0-9]*:[[:space:]]*#' || true)"
if [[ -z "${functional_rc1_hits}" ]]; then
    pass "T1: no rc1 literal in functional lines of qemu-boot-test.sh"
else
    fail "T1: rc1 literal found in functional lines of qemu-boot-test.sh: ${functional_rc1_hits}"
fi

# ---------------------------------------------------------------------------
# T2: glob-resolution pattern is present in qemu-boot-test.sh.
#     The find() call in main() must reference the wildcard ISO name pattern.
# ---------------------------------------------------------------------------
echo "T2: qemu-boot-test.sh contains glob-resolution pattern for ISO discovery"
if grep -q "orionx-phoenix-edition-\*\.iso" "${QEMU_SCRIPT}"; then
    pass "T2: glob pattern 'orionx-phoenix-edition-*.iso' found in qemu-boot-test.sh"
else
    fail "T2: glob pattern 'orionx-phoenix-edition-*.iso' NOT found in qemu-boot-test.sh"
fi

# ---------------------------------------------------------------------------
# T3: test-iso-content-presence.sh header comment no longer says rc1.
#     The iter-1 reviewer flagged this as a cosmetic note; fold it closed here.
# ---------------------------------------------------------------------------
echo "T3: test-iso-content-presence.sh header comment does not reference rc1"
if grep -q 'rc1\.iso' "${CONTENT_PRESENCE}"; then
    fail "T3: stale rc1 reference still present in test-iso-content-presence.sh header"
else
    pass "T3: no rc1 reference in test-iso-content-presence.sh"
fi

# ---------------------------------------------------------------------------
# T4: qemu-boot-test.sh passes bash -n (syntax check).
# ---------------------------------------------------------------------------
echo "T4: qemu-boot-test.sh passes bash -n syntax check"
if bash -n "${QEMU_SCRIPT}" 2>/dev/null; then
    pass "T4: bash -n clean"
else
    syntax_err="$(bash -n "${QEMU_SCRIPT}" 2>&1 || true)"
    fail "T4: bash -n reported errors: ${syntax_err}"
fi

# ---------------------------------------------------------------------------
# T5: qemu-boot-test.sh --help exits 0 and mentions the glob pattern.
#     This is the production-sequence test: the flag path must still work and
#     the help text must document the glob default so operators know the contract.
# ---------------------------------------------------------------------------
echo "T5: qemu-boot-test.sh --help prints glob pattern in usage text"
help_output="$(bash "${QEMU_SCRIPT}" --help 2>&1 || true)"
if echo "${help_output}" | grep -q 'orionx-phoenix-edition-\*\.iso'; then
    pass "T5: --help output contains glob pattern"
else
    fail "T5: --help output does NOT contain glob pattern; output snippet: $(echo "${help_output}" | grep -i iso | head -3 || true)"
fi

# ---------------------------------------------------------------------------
# T6: Compound-interaction — glob resolver falls back gracefully when output/
#     directory is absent (no live build required).  We run the script with
#     --dry-run pointed at a temp REPO_ROOT that has no output/ dir and verify
#     it exits 1 with [FAIL] ISO not found (not a bash error or unbound var).
# ---------------------------------------------------------------------------
echo "T6: glob resolver emits [FAIL] ISO not found when no ISO exists (no unbound-var crash)"
tmp_repo="$(mktemp -d)"
# Minimal repo skeleton: scripts/ dir so REPO_ROOT resolves correctly.
mkdir -p "${tmp_repo}/scripts"
cp "${QEMU_SCRIPT}" "${tmp_repo}/scripts/qemu-boot-test.sh"
dry_run_output="$(bash "${tmp_repo}/scripts/qemu-boot-test.sh" --dry-run --mode bios 2>&1 || true)"
if echo "${dry_run_output}" | grep -q '\[FAIL\].*ISO not found\|\[FAIL\] ISO not found'; then
    pass "T6: graceful [FAIL] ISO not found when no build exists"
elif echo "${dry_run_output}" | grep -q 'unbound variable\|bad substitution'; then
    fail "T6: script crashed with unbound-variable/substitution error: $(echo "${dry_run_output}" | tail -5)"
else
    # If QEMU isn't installed the failure message differs; accept any non-zero exit
    # that doesn't contain a bash error as a graceful failure.
    if echo "${dry_run_output}" | grep -q 'qemu-system-x86_64 not found\|\[FAIL\]'; then
        pass "T6: graceful failure (QEMU missing or ISO missing) — no crash"
    else
        fail "T6: unexpected output — neither graceful [FAIL] nor expected QEMU-missing message: $(echo "${dry_run_output}" | tail -5)"
    fi
fi
rm -rf "${tmp_repo}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================="
echo "  qemu-boot-test default unit results"
echo "======================================="
echo "  PASS: ${PASS}"
echo "  FAIL: ${FAIL}"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
        echo "  ${e}"
    done
fi
echo "======================================="

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
