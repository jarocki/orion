#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W7-6 failure-resilience files
#
# Validates all W7-6 deliverables structurally — no chroot, QEMU, or root
# access needed. Asserts: file existence, permissions, shebang, strict mode,
# @decision annotation, channel discipline (no systemctl/qemu/docker-compose),
# all 8 unit file names referenced, per-unit assertion emission, and CI
# workflow wiring.
#
# @decision DEC-PHASE7-W7-6-UNIT-TEST-001
# @title Structural unit tests for W7-6 failure-resilience deliverables
# @status accepted
# @rationale test-w7-6-failure-resilience.sh is a host-side static analysis
#   tool that reads systemd unit files directly. Structural tests here catch
#   regressions (missing unit reference, forbidden systemctl call, missing
#   @decision annotation, broken channel discipline) without requiring a full
#   ISO build + QEMU boot cycle. The compound-interaction check verifies that
#   the integration test references all 8 expected unit files AND that the CI
#   workflow wires the test as an active gate (no continue-on-error).
#
# Production sequence verified by the compound-interaction test:
#   1. CI checkout + qemu-test.yml triggers on push/PR to develop
#   2. The W7-6 step runs test-w7-6-failure-resilience.sh with no continue-on-error
#   3. test-w7-6-failure-resilience.sh reads systemd/*.service + systemd/*.timer
#   4. For each unit, get_directive() parses Type= / Restart= / timer fields
#   5. Per-type contract assertions emit [W7-6 PASS] or [W7-6 FAIL] per unit
#   6. Exit 0 iff all assertions pass; CI step fails (blocks merge) on any FAIL
#
# Usage: bash tests/unit/test_failure_resilience_unit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# File paths under test
# ---------------------------------------------------------------------------
INTEGRATION_TEST="${REPO_ROOT}/tests/integration/test-w7-6-failure-resilience.sh"
CI_WORKFLOW="${REPO_ROOT}/.github/workflows/qemu-test.yml"

# ---------------------------------------------------------------------------
# Test counters — use ((VAR+=1)) to avoid set -e firing on zero-result
# arithmetic in bash 5+
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

# Color output when running in a terminal
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" NC=""
fi

pass() { ((PASS+=1)); echo "${GREEN}  PASS${NC}: $1"; }
fail() {
    ((FAIL+=1))
    echo "${RED}  FAIL${NC}: $1"
    [[ -n "${2:-}" ]] && echo "        $2"
}
skip() { ((SKIP+=1)); echo "${YELLOW}  SKIP${NC}: $1 — $2"; }
section() { echo ""; echo "--- $1 ---"; }

echo "=== W7-6: Failure-Resilience Config Inspection — Structural Unit Tests ==="

# ===========================================================================
# 1. Integration test: existence, permissions, shebang, strict mode
# ===========================================================================
section "test-w7-6-failure-resilience.sh: existence and permissions"

if [[ -f "${INTEGRATION_TEST}" ]]; then
    pass "integration test exists at canonical path"
else
    fail "integration test exists at canonical path" "Not found: ${INTEGRATION_TEST}"
    echo "FATAL: integration test not found — cannot continue."
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
fi

if [[ -x "${INTEGRATION_TEST}" ]]; then
    pass "integration test is executable"
else
    fail "integration test is executable" "Run: chmod +x ${INTEGRATION_TEST}"
fi

INTEGRATION_CONTENT="$(< "${INTEGRATION_TEST}")"
INTEGRATION_FIRST_LINE="$(head -n1 "${INTEGRATION_TEST}")"

section "test-w7-6-failure-resilience.sh: shebang and strict mode"

if [[ "${INTEGRATION_FIRST_LINE}" == "#!/usr/bin/env bash" || "${INTEGRATION_FIRST_LINE}" == "#!/bin/bash" ]]; then
    pass "shebang is ${INTEGRATION_FIRST_LINE}"
else
    fail "shebang is bash" "Got: ${INTEGRATION_FIRST_LINE}"
fi

if [[ "${INTEGRATION_CONTENT}" == *"set -euo pipefail"* ]]; then
    pass "has set -euo pipefail (strict mode)"
else
    fail "has set -euo pipefail" "strict mode directive missing"
fi

# ===========================================================================
# 2. @decision annotation
# ===========================================================================
section "test-w7-6-failure-resilience.sh: @decision annotation"

if [[ "${INTEGRATION_CONTENT}" == *"@decision DEC-PHASE7-W7-6-001"* ]]; then
    pass "has @decision DEC-PHASE7-W7-6-001"
else
    fail "has @decision DEC-PHASE7-W7-6-001" "@decision annotation missing or wrong ID"
fi

if [[ "${INTEGRATION_CONTENT}" == *"@status accepted"* ]]; then
    pass "has @status accepted"
else
    fail "has @status accepted" "@status annotation missing"
fi

if [[ "${INTEGRATION_CONTENT}" == *"@title"* ]]; then
    pass "has @title annotation"
else
    fail "has @title annotation" "@title line missing"
fi

if [[ "${INTEGRATION_CONTENT}" == *"@rationale"* ]]; then
    pass "has @rationale annotation"
else
    fail "has @rationale annotation" "@rationale line missing"
fi

# ===========================================================================
# 3. All 8 unit files referenced by name
# ===========================================================================
section "test-w7-6-failure-resilience.sh: all 8 unit files referenced"

EXPECTED_UNITS=(
    "matrix-synapse-orionx.service"
    "orionx-mesh-discover.service"
    "orionx-mesh-beacon.service"
    "orionx-mesh-health.service"
    "orionx-firewall.service"
    "orionx-first-boot.service"
    "orionx-mesh-discover.timer"
    "orionx-mesh-health.timer"
)

for unit in "${EXPECTED_UNITS[@]}"; do
    if [[ "${INTEGRATION_CONTENT}" == *"${unit}"* ]]; then
        pass "references unit: ${unit}"
    else
        fail "references unit: ${unit}" "Unit name not found in integration test"
    fi
done

# ===========================================================================
# 4. Channel discipline: must NOT call systemctl or systemd runtime tools
# ===========================================================================
section "test-w7-6-failure-resilience.sh: channel discipline (host-side static only)"

# Strip comment lines before checking for forbidden patterns
INTEGRATION_CODE_ONLY="$(grep -vE '^\s*#' "${INTEGRATION_TEST}" || true)"

if echo "${INTEGRATION_CODE_ONLY}" | grep -qE '\bsystemctl\b'; then
    fail "must NOT call systemctl (host-side static check only)" \
         "Found 'systemctl' in functional code — violates Option D channel discipline"
else
    pass "does not call systemctl (host-side static check — no systemd runtime)"
fi

if echo "${INTEGRATION_CODE_ONLY}" | grep -qE '\bsystemd-analyze\b'; then
    fail "must NOT call systemd-analyze (host-side static check only)" \
         "Found 'systemd-analyze' in functional code — violates Option D channel discipline"
else
    pass "does not call systemd-analyze (host-side static check)"
fi

if echo "${INTEGRATION_CODE_ONLY}" | grep -qE 'qemu-boot-test\.sh'; then
    fail "must NOT invoke qemu-boot-test.sh (channel discipline)" \
         "W7-6 is host-side static inspection; must not trigger QEMU boot"
else
    pass "does not invoke qemu-boot-test.sh (no active stimulation)"
fi

if echo "${INTEGRATION_CODE_ONLY}" | grep -qE 'docker-compose'; then
    fail "must NOT invoke docker-compose (channel discipline)" \
         "W7-6 rejects Option C (Docker); per Phase 4 SKIP #21/#22 anti-pattern"
else
    pass "does not invoke docker-compose (Option C rejected)"
fi

# ===========================================================================
# 5. Per-unit assertion emission: test emits [W7-6 PASS] / [W7-6 FAIL] markers
# ===========================================================================
section "test-w7-6-failure-resilience.sh: per-unit assertion emission"

if [[ "${INTEGRATION_CONTENT}" == *"[W7-6 PASS]"* ]]; then
    pass "emits [W7-6 PASS] assertion markers"
else
    fail "emits [W7-6 PASS] assertion markers" "Per-unit PASS marker missing"
fi

if [[ "${INTEGRATION_CONTENT}" == *"[W7-6 FAIL]"* ]]; then
    pass "emits [W7-6 FAIL] assertion markers"
else
    fail "emits [W7-6 FAIL] assertion markers" "Per-unit FAIL marker missing"
fi

# ===========================================================================
# 6. get_directive() helper present (core parsing mechanism)
# ===========================================================================
section "test-w7-6-failure-resilience.sh: get_directive() helper"

if [[ "${INTEGRATION_CONTENT}" == *"get_directive()"* ]]; then
    pass "defines get_directive() parsing helper"
else
    fail "defines get_directive() parsing helper" "Core parsing function missing"
fi

if [[ "${INTEGRATION_CONTENT}" == *"Restart="* ]]; then
    pass "references Restart= directive (key recovery assertion)"
else
    fail "references Restart= directive" "Restart= assertion missing from integration test"
fi

if [[ "${INTEGRATION_CONTENT}" == *"OnUnitActiveSec"* ]]; then
    pass "references OnUnitActiveSec= directive (timer cadence assertion)"
else
    fail "references OnUnitActiveSec= directive" "Timer cadence assertion missing"
fi

if [[ "${INTEGRATION_CONTENT}" == *"OnBootSec"* ]]; then
    pass "references OnBootSec= directive (timer boot assertion)"
else
    fail "references OnBootSec= directive" "Timer boot assertion missing"
fi

# ===========================================================================
# 7. Disk-full gap documented
# ===========================================================================
section "test-w7-6-failure-resilience.sh: disk-full gap documented"

if [[ "${INTEGRATION_CONTENT}" == *"Disk full"* ]]; then
    pass "documents 'Disk full' as known gap (per MASTER_PLAN.md W7-6 contract)"
else
    fail "documents 'Disk full' as known gap" \
         "MASTER_PLAN.md requires explicit disk-full gap documentation in test header"
fi

# ===========================================================================
# 8. Compound-interaction: integration test runs and exits 0 against actual units
#    This is the real production sequence check — it crosses the boundary between
#    the structural assertions above and the actual unit file content.
# ===========================================================================
section "Compound-interaction: integration test passes against frozen unit files"

if bash "${INTEGRATION_TEST}" >/dev/null 2>&1; then
    pass "integration test exits 0 against systemd/*.service + systemd/*.timer"
else
    RESULT="$(bash "${INTEGRATION_TEST}" 2>&1 || true)"
    fail "integration test exits 0 against frozen unit files" \
         "$(echo "${RESULT}" | grep "FAIL\|Results" | head -5)"
fi

# ===========================================================================
# 9. CI workflow: W7-6 step present in qemu-test.yml
# ===========================================================================
section "CI workflow: qemu-test.yml"

if [[ -f "${CI_WORKFLOW}" ]]; then
    pass "qemu-test.yml exists"
    CI_CONTENT="$(< "${CI_WORKFLOW}")"

    if [[ "${CI_CONTENT}" == *"test-w7-6-failure-resilience"* ]]; then
        pass "qemu-test.yml references test-w7-6-failure-resilience"
    else
        fail "qemu-test.yml references test-w7-6-failure-resilience" \
             "W7-6 CI step not wired in .github/workflows/qemu-test.yml"
    fi

    # W7-6 step must NOT have continue-on-error: true
    # Static config inspection has no hang risk — it is the active gate
    if echo "${CI_CONTENT}" | grep -A5 "test-w7-6-failure-resilience" \
            | grep -q "continue-on-error: true"; then
        fail "W7-6 CI step must NOT have continue-on-error: true" \
             "W7-6 is an active gate (deterministic static check — no hang risk)"
    else
        pass "W7-6 CI step does not have continue-on-error: true (active gate)"
    fi
else
    fail "qemu-test.yml exists" "Not found: ${CI_WORKFLOW}"
fi

# ===========================================================================
# 10. ShellCheck (skip gracefully when not installed)
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "${INTEGRATION_TEST}"; then
        pass "integration test: ShellCheck passes clean"
    else
        fail "integration test: ShellCheck passes clean"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL + SKIP ))
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped (total: ${TOTAL})"
echo "==========================================="

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
