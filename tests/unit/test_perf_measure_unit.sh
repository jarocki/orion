#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W7-5 performance measurement files
#
# Validates all W7-5 deliverables structurally — no chroot, QEMU, or root
# access needed. Asserts: file existence, permissions, shebang, strict mode,
# @decision annotation, sentinel format, per-assertion timeout pattern,
# service unit structure, integration test structure, CI workflow wiring,
# and the critical independence invariant (no first-boot/wg0/mesh/Matrix/
# AppArmor dependencies in perf-measure.sh).
#
# @decision DEC-PHASE7-W7-5-UNIT-TEST-001
# @title Structural unit tests for W7-5 performance measurement deliverables
# @status accepted
# @rationale perf-measure.sh runs inside a live-build squashfs as root during
#   boot — not directly testable on macOS dev machines or in pre-build CI.
#   Structural validation catches regressions (missing sentinel, broken format,
#   wrong TTY path, missing @decision, forbidden dependency) without requiring
#   a full ISO build + QEMU boot cycle. The independence-invariant check
#   mechanically enforces that W7-5 cannot inherit the W7-4-B cascade trap
#   (issue #39): if perf-measure.sh ever acquires a reference to wg0,
#   apparmor, synapse, matrix, or mesh-discover, this test fails loudly.
#   The compound-interaction check verifies that the service unit, the
#   installation path, and the enable symlink are all coherent with each other.
#
# Production sequence:
#   1. live-build copies includes.chroot/lib/systemd/system/ → /lib/systemd/system/
#      (Option B: direct install, bypasses frozen 0615 hook)
#   2. live-build copies includes.chroot/etc/systemd/system/multi-user.target.wants/
#      symlink → /etc/systemd/system/multi-user.target.wants/ (enable on boot)
#   3. live-build copies includes.chroot/usr/lib/orionx/perf-measure.sh
#      → /usr/lib/orionx/perf-measure.sh (executable probe)
#   4. ISO boots in QEMU; systemd starts orionx-perf-measure.service after
#      multi-user.target
#   5. Service runs perf-measure.sh; sentinels appear on /dev/ttyS0
#   6. Host-side post-boot script (invoked by --post-boot-script) reads
#      serial log and returns PASS/FAIL to test-w7-5-performance.sh
#
# Usage: bash tests/unit/test_perf_measure_unit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# File paths under test
# ---------------------------------------------------------------------------
PERF_SCRIPT="${REPO_ROOT}/iso/config/includes.chroot/usr/lib/orionx/perf-measure.sh"
SERVICE_STAGING="${REPO_ROOT}/iso/config/includes.chroot/usr/share/orionx/systemd/orionx-perf-measure.service"
SERVICE_INSTALLED="${REPO_ROOT}/iso/config/includes.chroot/lib/systemd/system/orionx-perf-measure.service"
SERVICE_SYMLINK="${REPO_ROOT}/iso/config/includes.chroot/etc/systemd/system/multi-user.target.wants/orionx-perf-measure.service"
INTEGRATION_TEST="${REPO_ROOT}/tests/integration/test-w7-5-performance.sh"
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

echo "=== W7-5: Performance Measurement — Structural Unit Tests ==="

# ===========================================================================
# 1. perf-measure.sh: existence, permissions, shebang, strict mode
# ===========================================================================
section "perf-measure.sh: existence and permissions"

if [[ -f "${PERF_SCRIPT}" ]]; then
    pass "perf-measure.sh exists at canonical path"
else
    fail "perf-measure.sh exists at canonical path" "Not found: ${PERF_SCRIPT}"
    echo "FATAL: perf-measure.sh not found — cannot continue."
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
fi

if [[ -x "${PERF_SCRIPT}" ]]; then
    pass "perf-measure.sh is executable"
else
    fail "perf-measure.sh is executable" "Run: chmod +x ${PERF_SCRIPT}"
fi

PERF_CONTENT="$(cat "${PERF_SCRIPT}")"
PERF_FIRST_LINE="$(head -n1 "${PERF_SCRIPT}")"

section "perf-measure.sh: shebang and strict mode"

if [[ "${PERF_FIRST_LINE}" == "#!/bin/bash" ]]; then
    pass "shebang is #!/bin/bash"
else
    fail "shebang is #!/bin/bash" "Got: ${PERF_FIRST_LINE}"
fi

if [[ "${PERF_CONTENT}" == *"set -euo pipefail"* ]]; then
    pass "has set -euo pipefail"
else
    fail "has set -euo pipefail" "strict mode directive missing"
fi

# ===========================================================================
# 2. perf-measure.sh: @decision annotation
# ===========================================================================
section "perf-measure.sh: @decision annotation"

if [[ "${PERF_CONTENT}" == *"@decision DEC-PHASE7-W7-5-001"* ]]; then
    pass "has @decision DEC-PHASE7-W7-5-001"
else
    fail "has @decision DEC-PHASE7-W7-5-001" "@decision annotation missing or wrong ID"
fi

if [[ "${PERF_CONTENT}" == *"@status accepted"* ]]; then
    pass "has @status accepted"
else
    fail "has @status accepted" "@status annotation missing"
fi

# ===========================================================================
# 3. perf-measure.sh: sentinel format correctness
# ===========================================================================
section "perf-measure.sh: sentinel format"

if [[ "${PERF_CONTENT}" == *"ORIONX_PERF_BEGIN"* ]]; then
    pass "emits ORIONX_PERF_BEGIN sentinel"
else
    fail "emits ORIONX_PERF_BEGIN sentinel"
fi

if [[ "${PERF_CONTENT}" == *"ORIONX_PERF: boot_time_seconds="* ]]; then
    pass "emits ORIONX_PERF: boot_time_seconds= sentinel"
else
    fail "emits ORIONX_PERF: boot_time_seconds= sentinel" "metric name or format mismatch"
fi

if [[ "${PERF_CONTENT}" == *"ORIONX_PERF: idle_ram_bytes="* ]]; then
    pass "emits ORIONX_PERF: idle_ram_bytes= sentinel"
else
    fail "emits ORIONX_PERF: idle_ram_bytes= sentinel" "metric name or format mismatch"
fi

if [[ "${PERF_CONTENT}" == *"ORIONX_PERF_END: overall="* ]]; then
    pass "emits ORIONX_PERF_END: overall= sentinel"
else
    fail "emits ORIONX_PERF_END: overall= sentinel" "format must be 'ORIONX_PERF_END: overall=PASS|FAIL'"
fi

# Serial device reference
if [[ "${PERF_CONTENT}" == *"/dev/ttyS0"* ]]; then
    pass "references /dev/ttyS0 as serial channel"
else
    fail "references /dev/ttyS0 as serial channel" "sentinel output target missing"
fi

# ===========================================================================
# 4. perf-measure.sh: per-assertion timeout wraps (W7-4-B lesson)
# ===========================================================================
section "perf-measure.sh: per-assertion timeout pattern"

if [[ "${PERF_CONTENT}" == *"timeout 10"* ]]; then
    pass "uses 'timeout 10' per-assertion wrap (prevents hang)"
else
    fail "uses 'timeout 10' per-assertion wrap" \
         "each measurement must be wrapped in 'timeout 10' per W7-4-B lesson"
fi

# ===========================================================================
# 5. perf-measure.sh: exits 0 (probe, not gate)
# ===========================================================================
section "perf-measure.sh: exits 0 (probe semantics)"

if [[ "${PERF_CONTENT}" == *"exit 0"* ]]; then
    pass "script contains 'exit 0' (probe must not kill boot sequence)"
else
    fail "script contains 'exit 0'" "script must always exit 0 — it is a probe, not a boot gate"
fi

# ===========================================================================
# 6. perf-measure.sh: INDEPENDENCE INVARIANT
#    Must have ZERO references to wg0, apparmor, synapse, matrix, mesh-discover.
#    Violation re-introduces the W7-4-B cascade trap (issue #39).
# ===========================================================================
section "perf-measure.sh: independence invariant (no first-boot/mesh/Matrix/AppArmor dependencies)"

FORBIDDEN_PATTERNS=("wg0" "apparmor" "synapse" "matrix" "mesh-discover" "mesh_discover" "mesh_beacon")

# Strip comment lines (lines whose first non-whitespace character is '#')
# before checking for forbidden patterns. Comments may legitimately name these
# terms to document what the script must NOT do; only functional code is checked.
PERF_CODE_ONLY="$(grep -vE '^\s*#' "${PERF_SCRIPT}" || true)"

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if echo "${PERF_CODE_ONLY}" | grep -qiE "${pattern}"; then
        fail "independence invariant: '${pattern}' found in perf-measure.sh (non-comment code)" \
             "perf-measure.sh MUST NOT probe first-boot/wg0/mesh/Matrix/AppArmor state (W7-4-B cascade trap)"
    else
        pass "independence invariant: '${pattern}' not in perf-measure.sh functional code"
    fi
done

# ===========================================================================
# 7. Service unit (staging): existence and key directives
# ===========================================================================
section "orionx-perf-measure.service (staging): existence"

if [[ -f "${SERVICE_STAGING}" ]]; then
    pass "service unit exists in staging path (usr/share/orionx/systemd/)"
else
    fail "service unit exists in staging path" "Not found: ${SERVICE_STAGING}"
fi

SERVICE_CONTENT="$(cat "${SERVICE_STAGING}")"

section "orionx-perf-measure.service: key directives"

if [[ "${SERVICE_CONTENT}" == *"Type=oneshot"* ]]; then
    pass "service has Type=oneshot"
else
    fail "service has Type=oneshot" "Wrong or missing Type= directive"
fi

if [[ "${SERVICE_CONTENT}" == *"After=multi-user.target"* ]]; then
    pass "service has After=multi-user.target"
else
    fail "service has After=multi-user.target"
fi

if [[ "${SERVICE_CONTENT}" == *"TTYPath=/dev/ttyS0"* ]]; then
    pass "service has TTYPath=/dev/ttyS0"
else
    fail "service has TTYPath=/dev/ttyS0"
fi

if [[ "${SERVICE_CONTENT}" == *"WantedBy=multi-user.target"* ]]; then
    pass "service has WantedBy=multi-user.target"
else
    fail "service has WantedBy=multi-user.target"
fi

if [[ "${SERVICE_CONTENT}" == *"ExecStart=/usr/lib/orionx/perf-measure.sh"* ]]; then
    pass "service ExecStart points to /usr/lib/orionx/perf-measure.sh"
else
    fail "service ExecStart points to /usr/lib/orionx/perf-measure.sh"
fi

if [[ "${SERVICE_CONTENT}" == *"RemainAfterExit=yes"* ]]; then
    pass "service has RemainAfterExit=yes"
else
    fail "service has RemainAfterExit=yes"
fi

# Service must NOT have After= dependencies on mesh/Matrix/AppArmor services
section "orionx-perf-measure.service: no forbidden After= dependencies"

FORBIDDEN_AFTER_PATTERNS=("orionx-mesh" "matrix-synapse" "orionx-first-boot" "orionx-runtime-verify")
for pattern in "${FORBIDDEN_AFTER_PATTERNS[@]}"; do
    if echo "${SERVICE_CONTENT}" | grep -qiE "After=.*${pattern}|Requires=.*${pattern}"; then
        fail "service must NOT have After=/Requires= dependency on '${pattern}'" \
             "W7-5 perf service must be independent of first-boot/mesh/Matrix services"
    else
        pass "service does not depend on '${pattern}' (independence invariant)"
    fi
done

# ===========================================================================
# 8. Compound-interaction: Option B installation coherence
#    - unit present in lib/systemd/system/ (operative install, bypasses 0615)
#    - symlink present in etc/systemd/system/multi-user.target.wants/
#    - symlink target is the /lib/systemd/system/ path
#    - staging and installed unit files are identical (no drift)
# ===========================================================================
section "Compound-interaction: Option B installation coherence"

if [[ -f "${SERVICE_INSTALLED}" ]]; then
    pass "unit installed at lib/systemd/system/orionx-perf-measure.service"
else
    fail "unit installed at lib/systemd/system/orionx-perf-measure.service" \
         "Expected: ${SERVICE_INSTALLED}"
fi

if [[ -L "${SERVICE_SYMLINK}" ]]; then
    pass "enable symlink exists in multi-user.target.wants/"
    SYMLINK_TARGET="$(readlink "${SERVICE_SYMLINK}")"
    if [[ "${SYMLINK_TARGET}" == "/lib/systemd/system/orionx-perf-measure.service" ]]; then
        pass "symlink target is /lib/systemd/system/orionx-perf-measure.service"
    else
        fail "symlink target is /lib/systemd/system/orionx-perf-measure.service" \
             "Got: ${SYMLINK_TARGET}"
    fi
else
    fail "enable symlink exists in multi-user.target.wants/" \
         "Expected: ${SERVICE_SYMLINK}"
fi

# Verify staging and installed unit are identical (no drift between copies)
if [[ -f "${SERVICE_STAGING}" && -f "${SERVICE_INSTALLED}" ]]; then
    if diff -q "${SERVICE_STAGING}" "${SERVICE_INSTALLED}" >/dev/null 2>&1; then
        pass "staging and installed unit files are identical (no drift)"
    else
        fail "staging and installed unit files are identical (no drift)" \
             "diff: $(diff "${SERVICE_STAGING}" "${SERVICE_INSTALLED}" | head -5)"
    fi
fi

# ===========================================================================
# 9. Integration test: existence, permissions, contract references
# ===========================================================================
section "Integration test: test-w7-5-performance.sh"

if [[ -f "${INTEGRATION_TEST}" ]]; then
    pass "integration test exists"
else
    fail "integration test exists" "Not found: ${INTEGRATION_TEST}"
fi

if [[ -x "${INTEGRATION_TEST}" ]]; then
    pass "integration test is executable"
else
    fail "integration test is executable"
fi

INTEGRATION_CONTENT="$(cat "${INTEGRATION_TEST}")"

if [[ "${INTEGRATION_CONTENT}" == *"scripts/qemu-boot-test.sh"* ]]; then
    pass "integration test references scripts/qemu-boot-test.sh"
else
    fail "integration test references scripts/qemu-boot-test.sh"
fi

if [[ "${INTEGRATION_CONTENT}" == *"ORIONX_PERF_END"* ]]; then
    pass "integration test references ORIONX_PERF_END sentinel"
else
    fail "integration test references ORIONX_PERF_END sentinel"
fi

if [[ "${INTEGRATION_CONTENT}" == *"--post-boot-script"* ]]; then
    pass "integration test uses --post-boot-script attach point"
else
    fail "integration test uses --post-boot-script attach point"
fi

# Must reference all three metrics
for metric in "boot_time_seconds" "iso_size_bytes" "idle_ram_bytes"; do
    if [[ "${INTEGRATION_CONTENT}" == *"${metric}"* ]]; then
        pass "integration test references metric: ${metric}"
    else
        fail "integration test references metric: ${metric}" \
             "All three performance metrics must be asserted host-side"
    fi
done

# Must NOT use SSH, QEMU monitor, or guest-agent (per DEC-PHASE7-035)
if echo "${INTEGRATION_CONTENT}" | grep -qE '\bssh\b|\bqemu-monitor\b|\bqemu-guest-agent\b'; then
    fail "integration test must NOT use SSH/monitor/guest-agent" \
         "Found forbidden channel reference (DEC-PHASE7-035)"
else
    pass "integration test does not use SSH/monitor/guest-agent (DEC-PHASE7-035 compliant)"
fi

# iso_size_bytes must be measured host-side via du
if [[ "${INTEGRATION_CONTENT}" == *"du -b"* ]]; then
    pass "integration test measures iso_size_bytes host-side via du -b"
else
    fail "integration test measures iso_size_bytes host-side via du -b" \
         "ISO size is a host-side measurement — must use du -b, not in-guest"
fi

# ===========================================================================
# 10. CI workflow: W7-5 step present in qemu-test.yml
# ===========================================================================
section "CI workflow: qemu-test.yml"

if [[ -f "${CI_WORKFLOW}" ]]; then
    pass "qemu-test.yml exists"
    CI_CONTENT="$(cat "${CI_WORKFLOW}")"

    if [[ "${CI_CONTENT}" == *"test-w7-5-performance"* ]]; then
        pass "qemu-test.yml references test-w7-5-performance"
    else
        fail "qemu-test.yml references test-w7-5-performance" \
             "W7-5 CI step not wired in .github/workflows/qemu-test.yml"
    fi

    # W7-5 step must NOT have continue-on-error: true (it's the active gate)
    # We check by looking for "continue-on-error" in close proximity to "w7-5"
    # A simple heuristic: the step block containing w7-5 must not have
    # continue-on-error: true. We look for the pattern in the CI file.
    if echo "${CI_CONTENT}" | grep -A5 "test-w7-5-performance" | grep -q "continue-on-error: true"; then
        fail "W7-5 CI step must NOT have continue-on-error: true" \
             "W7-5 is the active acceptance gate — CI must fail when perf targets miss"
    else
        pass "W7-5 CI step does not have continue-on-error: true (active gate)"
    fi
else
    fail "qemu-test.yml exists" "Not found: ${CI_WORKFLOW}"
fi

# ===========================================================================
# 11. ShellCheck (skip gracefully when not installed)
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "${PERF_SCRIPT}"; then
        pass "perf-measure.sh: ShellCheck passes clean"
    else
        fail "perf-measure.sh: ShellCheck passes clean"
    fi
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
