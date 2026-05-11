#!/usr/bin/env bash
# shellcheck shell=bash
#
# W7-4-B: Host-side integration test — in-guest runtime verification
#
# Invokes the QEMU boot harness with a post-boot helper that waits for the
# ORIONX_VERIFY_* sentinels emitted by the in-guest
# /usr/lib/orionx/runtime-verify.sh service via /dev/ttyS0. Parses the
# serial log and PASS/FAILs based on the sentinel block.
#
# @decision DEC-PHASE7-035
# @title In-guest verification via serial-console sentinels, not SSH/sockets
# @status accepted
# @rationale The host harness already captures the serial log for boot-success
#   detection (DEC-PHASE7-020). Attaching via --post-boot-script reuses the
#   same channel without modifying the frozen harness. SSH/monitor sockets
#   are explicitly rejected per DEC-PHASE7-035.
#
# Contract with scripts/qemu-boot-test.sh (DEC-PHASE7-022):
#   --post-boot-script <script> receives two positional args when invoked:
#     $1 = RUN_ID    (e.g. 20260511-120000)
#     $2 = SERIAL_LOG (absolute path to the serial console log)
#   The harness treats a non-zero exit from post-boot-script as a warning,
#   not a boot failure. This test script handles its own PASS/FAIL accounting
#   and exits appropriately after the harness returns.
#
# Usage:
#   bash tests/integration/test-w7-4-b-runtime-verify.sh [--mode bios|uefi|both]
#   ISO=/path/to/orionx.iso bash tests/integration/test-w7-4-b-runtime-verify.sh
#
# Environment:
#   ISO          Override ISO path (default: harness default)
#   QEMU_TIMEOUT Override QEMU boot timeout in seconds (default: 900)
#   VERIFY_WAIT  Seconds to wait for ORIONX_VERIFY_END after boot (default: 120)

# IMPORTANT: NO set -e — we must always reach the result-parsing section
# even if the harness exits non-zero. Individual errors are tracked via
# FAIL counter.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QEMU_TIMEOUT="${QEMU_TIMEOUT:-900}"
VERIFY_WAIT="${VERIFY_WAIT:-120}"

# ---------------------------------------------------------------------------
# Color helpers (only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'
    NC=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" CYAN="" NC=""
fi

log_info()  { echo "${CYAN}[INFO]${NC}  $*"; }
log_pass()  { echo "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo "${RED}[FAIL]${NC}  $*"; }
log_warn()  { echo "${YELLOW}[WARN]${NC}  $*"; }

PASS=0
FAIL=0

pass() { ((PASS+=1)); log_pass "$1"; }
fail() { ((FAIL+=1)); log_fail "$1${2:+ — }${2:-}"; }

# ---------------------------------------------------------------------------
# Parse CLI args forwarded to the harness
# ---------------------------------------------------------------------------
HARNESS_EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) HARNESS_EXTRA_ARGS+=("--mode" "${2:?--mode requires a value}"); shift 2 ;;
        --iso)  HARNESS_EXTRA_ARGS+=("--iso"  "${2:?--iso requires a value}");  shift 2 ;;
        --ovmf) HARNESS_EXTRA_ARGS+=("--ovmf" "${2:?--ovmf requires a value}"); shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--mode bios|uefi|both] [--iso <path>] [--ovmf <path>]"
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Default mode: bios-only (faster for CI; full BIOS+UEFI is the qemu-boot job)
if [[ "${#HARNESS_EXTRA_ARGS[@]}" -eq 0 ]]; then
    HARNESS_EXTRA_ARGS=("--mode" "bios")
fi

# Pass ISO env var through to harness if set
if [[ -n "${ISO:-}" ]]; then
    HARNESS_EXTRA_ARGS+=("--iso" "${ISO}")
fi

# ---------------------------------------------------------------------------
# Write the post-boot helper script to a temp path
#
# The harness invokes this script with: bash <helper> <RUN_ID> <SERIAL_LOG>
# The helper's job: wait up to VERIFY_WAIT seconds for ORIONX_VERIFY_END
# to appear in the serial log, then exit 0. The actual sentinel parsing
# is done by this parent script after the harness returns.
# ---------------------------------------------------------------------------
POST_BOOT_HELPER="${REPO_ROOT}/tmp/w7-4-b-post-boot-helper.sh"
mkdir -p "${REPO_ROOT}/tmp"

cat > "${POST_BOOT_HELPER}" <<'HELPER_EOF'
#!/usr/bin/env bash
# W7-4-B post-boot helper — invoked by qemu-boot-test.sh after boot marker
# detected. Waits for ORIONX_VERIFY_END sentinel in the serial log.
# Args: $1=RUN_ID $2=SERIAL_LOG
set -uo pipefail

RUN_ID="${1:-unknown}"
SERIAL_LOG="${2:-}"
VERIFY_WAIT="${VERIFY_WAIT:-120}"

echo "[w7-4-b-helper] run_id=${RUN_ID} serial_log=${SERIAL_LOG}"

if [[ -z "${SERIAL_LOG}" || ! -f "${SERIAL_LOG}" ]]; then
    echo "[w7-4-b-helper] SERIAL_LOG not found: ${SERIAL_LOG}" >&2
    exit 1
fi

echo "[w7-4-b-helper] Waiting up to ${VERIFY_WAIT}s for ORIONX_VERIFY_END..."
elapsed=0
while [[ ${elapsed} -lt ${VERIFY_WAIT} ]]; do
    if grep -qF "ORIONX_VERIFY_END:" "${SERIAL_LOG}" 2>/dev/null; then
        echo "[w7-4-b-helper] ORIONX_VERIFY_END detected at ${elapsed}s"
        exit 0
    fi
    sleep 2
    ((elapsed+=2))
done

echo "[w7-4-b-helper] TIMEOUT: ORIONX_VERIFY_END not found after ${VERIFY_WAIT}s" >&2
exit 1
HELPER_EOF

chmod +x "${POST_BOOT_HELPER}"
log_info "Post-boot helper written to: ${POST_BOOT_HELPER}"

# ---------------------------------------------------------------------------
# Determine serial log path
#
# The harness writes serial logs to:
#   tmp/qemu-artifacts/<run-id>/serial-<mode>.log
# We discover the path after harness exit by finding the most recently
# modified serial log under tmp/qemu-artifacts/.
# ---------------------------------------------------------------------------
ARTIFACTS_BASE="${REPO_ROOT}/tmp/qemu-artifacts"

# ---------------------------------------------------------------------------
# Run the QEMU boot harness
# ---------------------------------------------------------------------------
log_info "Launching QEMU harness..."
log_info "  args: --timeout ${QEMU_TIMEOUT} --post-boot-script ${POST_BOOT_HELPER} ${HARNESS_EXTRA_ARGS[*]}"

HARNESS_EXIT=0
bash "${REPO_ROOT}/scripts/qemu-boot-test.sh" \
    --timeout "${QEMU_TIMEOUT}" \
    --post-boot-script "${POST_BOOT_HELPER}" \
    "${HARNESS_EXTRA_ARGS[@]}" || HARNESS_EXIT=$?

log_info "QEMU harness exited with code: ${HARNESS_EXIT}"

# ---------------------------------------------------------------------------
# Locate the serial log(s) from this run
# ---------------------------------------------------------------------------
# The harness may have run bios, uefi, or both. Find all serial logs newer
# than 15 minutes (covers the run we just executed) under qemu-artifacts.
SERIAL_LOGS=()
if [[ -d "${ARTIFACTS_BASE}" ]]; then
    while IFS= read -r -d '' f; do
        SERIAL_LOGS+=("$f")
    done < <(find "${ARTIFACTS_BASE}" -name "serial-*.log" -newer "${POST_BOOT_HELPER}" -print0 2>/dev/null || true)
fi

if [[ "${#SERIAL_LOGS[@]}" -eq 0 ]]; then
    fail "No serial log found under ${ARTIFACTS_BASE} from this run"
    log_warn "QEMU harness exit code was: ${HARNESS_EXIT}"
    echo ""
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
fi

log_info "Found ${#SERIAL_LOGS[@]} serial log(s): ${SERIAL_LOGS[*]}"

# ---------------------------------------------------------------------------
# Parse sentinel block from each serial log
# ---------------------------------------------------------------------------
VERIFY_OVERALL_PASS=0
VERIFY_OVERALL_FAIL=0

for serial_log in "${SERIAL_LOGS[@]}"; do
    log_info "Parsing sentinel block from: ${serial_log}"

    # Check BEGIN marker present
    if ! grep -qF "ORIONX_VERIFY_BEGIN" "${serial_log}" 2>/dev/null; then
        fail "ORIONX_VERIFY_BEGIN not found in ${serial_log}" \
             "runtime-verify.service may not have run"
        ((VERIFY_OVERALL_FAIL+=1))
        continue
    fi
    pass "ORIONX_VERIFY_BEGIN present in $(basename "${serial_log}")"

    # Check END marker present
    if ! grep -qF "ORIONX_VERIFY_END:" "${serial_log}" 2>/dev/null; then
        fail "ORIONX_VERIFY_END: not found in ${serial_log}" \
             "runtime-verify.sh may have been interrupted or timed out"
        ((VERIFY_OVERALL_FAIL+=1))
        continue
    fi
    pass "ORIONX_VERIFY_END: present in $(basename "${serial_log}")"

    # Check individual assertion sentinels
    EXPECTED_ASSERTIONS=(
        "mesh_iface_up"
        "mesh_beacon_active"
        "mesh_discover_enabled"
        "matrix_synapse_state"
        "apparmor_enforcing"
    )

    assertion_failures=()
    for name in "${EXPECTED_ASSERTIONS[@]}"; do
        line="$(grep "ORIONX_VERIFY: ${name}=" "${serial_log}" 2>/dev/null | tail -1 || true)"
        if [[ -z "${line}" ]]; then
            fail "assertion sentinel missing: ${name}" "no ORIONX_VERIFY: ${name}= line in log"
            assertion_failures+=("${name}:missing")
        elif echo "${line}" | grep -qF "=${name}=FAIL" 2>/dev/null || \
             echo "${line}" | grep -qF "ORIONX_VERIFY: ${name}=FAIL" 2>/dev/null; then
            fail "assertion FAIL: ${name}" "line: ${line}"
            assertion_failures+=("${name}:FAIL")
        else
            pass "assertion PASS: ${name}"
        fi
    done

    # Parse overall verdict from END line
    end_line="$(grep "ORIONX_VERIFY_END:" "${serial_log}" 2>/dev/null | tail -1 || true)"
    if echo "${end_line}" | grep -qF "overall=PASS"; then
        pass "overall sentinel: PASS in $(basename "${serial_log}")"
        ((VERIFY_OVERALL_PASS+=1))
    else
        fail "overall sentinel: not PASS in $(basename "${serial_log}")" \
             "end line: ${end_line}"
        ((VERIFY_OVERALL_FAIL+=1))
    fi

    # Dump full sentinel block for diagnostics
    echo ""
    echo "--- Sentinel block from $(basename "${serial_log}") ---"
    grep "ORIONX_VERIFY" "${serial_log}" 2>/dev/null || echo "(none found)"
    echo "--- End sentinel block ---"
    echo ""
done

# ---------------------------------------------------------------------------
# Assert at least one serial log showed overall=PASS
# ---------------------------------------------------------------------------
if [[ "${VERIFY_OVERALL_PASS}" -gt 0 && "${VERIFY_OVERALL_FAIL}" -eq 0 ]]; then
    pass "All serial logs show ORIONX_VERIFY_END: overall=PASS"
elif [[ "${VERIFY_OVERALL_FAIL}" -gt 0 ]]; then
    fail "One or more serial logs show verification failures" \
         "overall_pass=${VERIFY_OVERALL_PASS} overall_fail=${VERIFY_OVERALL_FAIL}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL ))
echo "W7-4-B Runtime Verification Test Results"
echo "  PASS: ${PASS}  FAIL: ${FAIL}  TOTAL: ${TOTAL}"
echo "  QEMU harness exit: ${HARNESS_EXIT}"
echo "==========================================="

if [[ ${FAIL} -gt 0 || ${HARNESS_EXIT} -ne 0 ]]; then
    exit 1
fi
exit 0
