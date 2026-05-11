#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W7-4-B runtime verification files
#
# Validates all W7-4-B deliverables structurally — no chroot, QEMU, or root
# access needed. Asserts: file existence, permissions, shebang, strict mode,
# @decision annotation, expected assertion names, service unit structure,
# integration test structure, and CI workflow wiring.
#
# @decision DEC-PHASE7-W7-4-B-UNIT-TEST-001
# @title Structural unit tests for W7-4-B runtime verification deliverables
# @status accepted
# @rationale runtime-verify.sh runs inside a live-build squashfs as root
#   during boot — not directly testable on macOS dev machines or in pre-build
#   CI. Structural validation catches regressions (missing assertion, broken
#   sentinel format, wrong TTY path, missing @decision) without requiring a
#   full ISO build + QEMU boot cycle. The compound-interaction check verifies
#   that the service unit, the installation path, and the enable symlink are
#   all coherent with each other.
#
# Production sequence:
#   1. live-build copies includes.chroot/lib/systemd/system/ → /lib/systemd/system/
#      (Option B: direct install, bypasses frozen 0615 hook)
#   2. live-build copies includes.chroot/etc/systemd/system/multi-user.target.wants/
#      symlink → /etc/systemd/system/multi-user.target.wants/ (enable on boot)
#   3. live-build copies includes.chroot/usr/lib/orionx/runtime-verify.sh
#      → /usr/lib/orionx/runtime-verify.sh (executable probe)
#   4. ISO boots in QEMU; systemd starts orionx-runtime-verify.service after
#      multi-user.target
#   5. Service runs runtime-verify.sh; sentinels appear on /dev/ttyS0
#   6. Host-side post-boot script (invoked by --post-boot-script) reads
#      serial log and returns PASS/FAIL to test-w7-4-b-runtime-verify.sh
#
# Usage: bash tests/unit/test_runtime_verify_unit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# File paths under test
# ---------------------------------------------------------------------------
VERIFY_SCRIPT="${REPO_ROOT}/iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh"
SERVICE_STAGING="${REPO_ROOT}/iso/config/includes.chroot/usr/share/orionx/systemd/orionx-runtime-verify.service"
SERVICE_INSTALLED="${REPO_ROOT}/iso/config/includes.chroot/lib/systemd/system/orionx-runtime-verify.service"
SERVICE_SYMLINK="${REPO_ROOT}/iso/config/includes.chroot/etc/systemd/system/multi-user.target.wants/orionx-runtime-verify.service"
INTEGRATION_TEST="${REPO_ROOT}/tests/integration/test-w7-4-b-runtime-verify.sh"
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

echo "=== W7-4-B: Runtime Verification — Structural Unit Tests ==="

# ===========================================================================
# 1. runtime-verify.sh: existence, permissions, shebang, strict mode
# ===========================================================================
section "runtime-verify.sh: existence and permissions"

if [[ -f "${VERIFY_SCRIPT}" ]]; then
    pass "runtime-verify.sh exists at canonical path"
else
    fail "runtime-verify.sh exists at canonical path" "Not found: ${VERIFY_SCRIPT}"
    echo "FATAL: runtime-verify.sh not found — cannot continue."
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
fi

if [[ -x "${VERIFY_SCRIPT}" ]]; then
    pass "runtime-verify.sh is executable"
else
    fail "runtime-verify.sh is executable" "Run: chmod +x ${VERIFY_SCRIPT}"
fi

VERIFY_CONTENT="$(cat "${VERIFY_SCRIPT}")"
VERIFY_FIRST_LINE="$(head -n1 "${VERIFY_SCRIPT}")"

section "runtime-verify.sh: shebang and strict mode"

if [[ "${VERIFY_FIRST_LINE}" == "#!/bin/bash" ]]; then
    pass "shebang is #!/bin/bash"
else
    fail "shebang is #!/bin/bash" "Got: ${VERIFY_FIRST_LINE}"
fi

if [[ "${VERIFY_CONTENT}" == *"set -euo pipefail"* ]]; then
    pass "has set -euo pipefail"
else
    fail "has set -euo pipefail" "strict mode directive missing"
fi

# ===========================================================================
# 2. runtime-verify.sh: @decision annotation
# ===========================================================================
section "runtime-verify.sh: @decision annotation"

if [[ "${VERIFY_CONTENT}" == *"@decision DEC-PHASE7-035"* ]]; then
    pass "has @decision DEC-PHASE7-035"
else
    fail "has @decision DEC-PHASE7-035" "@decision annotation missing or wrong ID"
fi

if [[ "${VERIFY_CONTENT}" == *"@status accepted"* ]]; then
    pass "has @status accepted"
else
    fail "has @status accepted" "@status annotation missing"
fi

# ===========================================================================
# 3. runtime-verify.sh: all 5 assertion names referenced
# ===========================================================================
section "runtime-verify.sh: assertion names present"

EXPECTED_ASSERTIONS=(
    "mesh_iface_up"
    "mesh_beacon_active"
    "mesh_discover_enabled"
    "matrix_synapse_state"
    "apparmor_enforcing"
)

for name in "${EXPECTED_ASSERTIONS[@]}"; do
    if [[ "${VERIFY_CONTENT}" == *"${name}"* ]]; then
        pass "assertion referenced: ${name}"
    else
        fail "assertion referenced: ${name}" "Name not found in runtime-verify.sh"
    fi
done

# ===========================================================================
# 4. runtime-verify.sh: sentinel format correctness
# ===========================================================================
section "runtime-verify.sh: sentinel format"

if [[ "${VERIFY_CONTENT}" == *"ORIONX_VERIFY_BEGIN"* ]]; then
    pass "emits ORIONX_VERIFY_BEGIN sentinel"
else
    fail "emits ORIONX_VERIFY_BEGIN sentinel"
fi

if [[ "${VERIFY_CONTENT}" == *"ORIONX_VERIFY_END: overall="* ]]; then
    pass "emits ORIONX_VERIFY_END: overall= sentinel"
else
    fail "emits ORIONX_VERIFY_END: overall= sentinel" "format must be 'ORIONX_VERIFY_END: overall=PASS|FAIL'"
fi

if [[ "${VERIFY_CONTENT}" == *"ORIONX_VERIFY: "* ]]; then
    pass "emits ORIONX_VERIFY: <name>=<verdict> sentinels"
else
    fail "emits ORIONX_VERIFY: <name>=<verdict> sentinels"
fi

# Serial device reference
if [[ "${VERIFY_CONTENT}" == *"/dev/ttyS0"* ]]; then
    pass "references /dev/ttyS0 as serial channel"
else
    fail "references /dev/ttyS0 as serial channel" "sentinel output target missing"
fi

# ===========================================================================
# 5. runtime-verify.sh: exits 0 (probe, not gate)
# ===========================================================================
section "runtime-verify.sh: exits 0 (probe semantics)"

if [[ "${VERIFY_CONTENT}" == *"exit 0"* ]]; then
    pass "script contains 'exit 0' (probe must not kill boot sequence)"
else
    fail "script contains 'exit 0'" "script must always exit 0 — it is a probe, not a boot gate"
fi

# ===========================================================================
# 6. Service unit (staging): existence and key directives
# ===========================================================================
section "orionx-runtime-verify.service (staging): existence"

if [[ -f "${SERVICE_STAGING}" ]]; then
    pass "service unit exists in staging path (usr/share/orionx/systemd/)"
else
    fail "service unit exists in staging path" "Not found: ${SERVICE_STAGING}"
fi

SERVICE_CONTENT="$(cat "${SERVICE_STAGING}")"

section "orionx-runtime-verify.service: key directives"

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

if [[ "${SERVICE_CONTENT}" == *"ExecStart=/usr/lib/orionx/runtime-verify.sh"* ]]; then
    pass "service ExecStart points to /usr/lib/orionx/runtime-verify.sh"
else
    fail "service ExecStart points to /usr/lib/orionx/runtime-verify.sh"
fi

if [[ "${SERVICE_CONTENT}" == *"RemainAfterExit=yes"* ]]; then
    pass "service has RemainAfterExit=yes"
else
    fail "service has RemainAfterExit=yes"
fi

# ===========================================================================
# 7. Compound-interaction: Option B installation coherence
#    - unit present in lib/systemd/system/ (operative install, bypasses 0615)
#    - symlink present in etc/systemd/system/multi-user.target.wants/
#    - symlink target is the /lib/systemd/system/ path
# ===========================================================================
section "Compound-interaction: Option B installation coherence"

if [[ -f "${SERVICE_INSTALLED}" ]]; then
    pass "unit installed at lib/systemd/system/orionx-runtime-verify.service"
else
    fail "unit installed at lib/systemd/system/orionx-runtime-verify.service" \
         "Expected: ${SERVICE_INSTALLED}"
fi

if [[ -L "${SERVICE_SYMLINK}" ]]; then
    pass "enable symlink exists in multi-user.target.wants/"
    SYMLINK_TARGET="$(readlink "${SERVICE_SYMLINK}")"
    if [[ "${SYMLINK_TARGET}" == "/lib/systemd/system/orionx-runtime-verify.service" ]]; then
        pass "symlink target is /lib/systemd/system/orionx-runtime-verify.service"
    else
        fail "symlink target is /lib/systemd/system/orionx-runtime-verify.service" \
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
# 8. Integration test: existence, permissions, contract references
# ===========================================================================
section "Integration test: test-w7-4-b-runtime-verify.sh"

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

if [[ "${INTEGRATION_CONTENT}" == *"ORIONX_VERIFY_END"* ]]; then
    pass "integration test references ORIONX_VERIFY_END sentinel"
else
    fail "integration test references ORIONX_VERIFY_END sentinel"
fi

if [[ "${INTEGRATION_CONTENT}" == *"--post-boot-script"* ]]; then
    pass "integration test uses --post-boot-script attach point"
else
    fail "integration test uses --post-boot-script attach point"
fi

# Must NOT use SSH, QEMU monitor, or guest-agent (per DEC-PHASE7-035)
if echo "${INTEGRATION_CONTENT}" | grep -qE '\bssh\b|\bqemu-monitor\b|\bqemu-guest-agent\b'; then
    fail "integration test must NOT use SSH/monitor/guest-agent" \
         "Found forbidden channel reference (DEC-PHASE7-035)"
else
    pass "integration test does not use SSH/monitor/guest-agent (DEC-PHASE7-035 compliant)"
fi

# ===========================================================================
# 9. CI workflow: W7-4-B step present in qemu-test.yml
# ===========================================================================
section "CI workflow: qemu-test.yml"

if [[ -f "${CI_WORKFLOW}" ]]; then
    pass "qemu-test.yml exists"
    CI_CONTENT="$(cat "${CI_WORKFLOW}")"

    if [[ "${CI_CONTENT}" == *"test-w7-4-b-runtime-verify"* ]]; then
        pass "qemu-test.yml references test-w7-4-b-runtime-verify"
    else
        fail "qemu-test.yml references test-w7-4-b-runtime-verify" \
             "W7-4-B CI step not wired in .github/workflows/qemu-test.yml"
    fi
else
    fail "qemu-test.yml exists" "Not found: ${CI_WORKFLOW}"
fi

# ===========================================================================
# 10. ShellCheck (skip gracefully when not installed)
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "${VERIFY_SCRIPT}"; then
        pass "runtime-verify.sh: ShellCheck passes clean"
    else
        fail "runtime-verify.sh: ShellCheck passes clean"
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
