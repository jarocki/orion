#!/usr/bin/env bash
# shellcheck shell=bash
#
# W7-5: Host-side integration test — performance benchmark
#
# Invokes the QEMU boot harness with a post-boot helper that waits for the
# ORIONX_PERF_* sentinels emitted by the in-guest /usr/lib/orionx/perf-measure.sh
# service via /dev/ttyS0. Parses the serial log and asserts all three
# performance metrics are within thresholds.
#
# Metrics checked:
#   boot_time_seconds  < 90          (in-guest, via systemd-analyze)
#   iso_size_bytes     < 4294967296  (host-side, via du -b)
#   idle_ram_bytes     < 1073741824  (in-guest, via /proc/meminfo)
#
# @decision DEC-PHASE7-W7-5-001
# @title In-guest performance measurement via serial-console sentinels (W7-5)
# @status accepted
# @rationale The host harness already captures the serial log for boot-success
#   detection (DEC-PHASE7-020). Attaching via --post-boot-script reuses the
#   same channel without modifying the frozen harness. SSH/monitor sockets
#   are explicitly rejected per DEC-PHASE7-035. iso_size_bytes is measured
#   host-side (the ISO file is on the host filesystem, not inside the guest).
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
#   bash tests/integration/test-w7-5-performance.sh [--mode bios|uefi|both]
#   ISO=/path/to/orionx.iso bash tests/integration/test-w7-5-performance.sh
#
# Environment:
#   ISO           Override ISO path (default: harness default)
#   QEMU_TIMEOUT  Override QEMU boot timeout in seconds (default: 900)
#   PERF_WAIT     Seconds to wait for ORIONX_PERF_END after boot (default: 90)

# IMPORTANT: NO set -e — we must always reach the result-parsing section
# even if the harness exits non-zero. Individual errors are tracked via
# FAIL counter.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

QEMU_TIMEOUT="${QEMU_TIMEOUT:-900}"
PERF_WAIT="${PERF_WAIT:-90}"

# Thresholds
BOOT_TIME_THRESHOLD=90
ISO_SIZE_THRESHOLD=4294967296      # 4 GiB
IDLE_RAM_THRESHOLD=1073741824      # 1 GiB

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
# Host-side ISO size check (independent of QEMU boot)
#
# The ISO is a static build artifact on the host filesystem. Measure it now
# before launching QEMU so the result is always emitted regardless of QEMU
# boot outcome. Emit in ORIONX_PERF sentinel format for log uniformity.
# ---------------------------------------------------------------------------
log_info "=== Host-side ISO size measurement ==="
ISO_PATH=""
if [[ -n "${ISO:-}" ]]; then
    ISO_PATH="${ISO}"
else
    # Default: find newest *.iso under output/
    ISO_PATH="$(find "${REPO_ROOT}/output" -name "*.iso" -newer "${REPO_ROOT}/iso" 2>/dev/null \
        | head -1 || true)"
    if [[ -z "${ISO_PATH}" ]]; then
        ISO_PATH="$(find "${REPO_ROOT}/output" -name "*.iso" 2>/dev/null | head -1 || true)"
    fi
fi

ISO_SIZE_BYTES=0
if [[ -n "${ISO_PATH}" && -f "${ISO_PATH}" ]]; then
    ISO_SIZE_BYTES="$(du -b "${ISO_PATH}" 2>/dev/null | awk '{print $1}' || echo "0")"
    log_info "ISO: ${ISO_PATH}"
    log_info "ORIONX_PERF: iso_size_bytes=${ISO_SIZE_BYTES}"
    if [[ "${ISO_SIZE_BYTES}" -lt "${ISO_SIZE_THRESHOLD}" ]] 2>/dev/null; then
        pass "iso_size_bytes=${ISO_SIZE_BYTES} < ${ISO_SIZE_THRESHOLD} (4 GiB) [PASS]"
    else
        fail "iso_size_bytes=${ISO_SIZE_BYTES} >= ${ISO_SIZE_THRESHOLD} (4 GiB) threshold" \
             "ISO file: ${ISO_PATH}"
    fi
else
    fail "ISO file not found under ${REPO_ROOT}/output/" \
         "Build the ISO first or set ISO=/path/to/file.iso"
fi

# ---------------------------------------------------------------------------
# Write the post-boot helper script to a temp path
#
# The harness invokes this script with: bash <helper> <RUN_ID> <SERIAL_LOG>
# The helper's job: wait up to PERF_WAIT seconds for ORIONX_PERF_END
# to appear in the serial log, then exit 0. The actual sentinel parsing
# is done by this parent script after the harness returns.
# ---------------------------------------------------------------------------
POST_BOOT_HELPER="${REPO_ROOT}/tmp/w7-5-post-boot-helper.sh"
mkdir -p "${REPO_ROOT}/tmp"

cat > "${POST_BOOT_HELPER}" <<'HELPER_EOF'
#!/usr/bin/env bash
# W7-5 post-boot helper — invoked by qemu-boot-test.sh after boot marker
# detected. Waits for ORIONX_PERF_END sentinel in the serial log.
# Args: $1=RUN_ID $2=SERIAL_LOG
set -uo pipefail

RUN_ID="${1:-unknown}"
SERIAL_LOG="${2:-}"
PERF_WAIT="${PERF_WAIT:-90}"

echo "[w7-5-helper] run_id=${RUN_ID} serial_log=${SERIAL_LOG}"

if [[ -z "${SERIAL_LOG}" || ! -f "${SERIAL_LOG}" ]]; then
    echo "[w7-5-helper] SERIAL_LOG not found: ${SERIAL_LOG}" >&2
    exit 1
fi

echo "[w7-5-helper] Waiting up to ${PERF_WAIT}s for ORIONX_PERF_END..."
elapsed=0
while [[ ${elapsed} -lt ${PERF_WAIT} ]]; do
    if grep -qF "ORIONX_PERF_END:" "${SERIAL_LOG}" 2>/dev/null; then
        echo "[w7-5-helper] ORIONX_PERF_END detected at ${elapsed}s"
        exit 0
    fi
    sleep 2
    ((elapsed+=2))
done

echo "[w7-5-helper] TIMEOUT: ORIONX_PERF_END not found after ${PERF_WAIT}s" >&2
exit 1
HELPER_EOF

chmod +x "${POST_BOOT_HELPER}"
log_info "Post-boot helper written to: ${POST_BOOT_HELPER}"

# ---------------------------------------------------------------------------
# Run the QEMU boot harness
# ---------------------------------------------------------------------------
log_info "=== Launching QEMU harness for W7-5 performance measurement ==="
log_info "  args: --timeout ${QEMU_TIMEOUT} --post-boot-script ${POST_BOOT_HELPER} ${HARNESS_EXTRA_ARGS[*]}"

ARTIFACTS_BASE="${REPO_ROOT}/tmp/qemu-artifacts"
HARNESS_EXIT=0
bash "${REPO_ROOT}/scripts/qemu-boot-test.sh" \
    --timeout "${QEMU_TIMEOUT}" \
    --post-boot-script "${POST_BOOT_HELPER}" \
    "${HARNESS_EXTRA_ARGS[@]}" || HARNESS_EXIT=$?

log_info "QEMU harness exited with code: ${HARNESS_EXIT}"

# ---------------------------------------------------------------------------
# Locate the serial log(s) from this run
# ---------------------------------------------------------------------------
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
# Parse performance sentinel block from each serial log
# ---------------------------------------------------------------------------
PERF_OVERALL_PASS=0
PERF_OVERALL_FAIL=0

for serial_log in "${SERIAL_LOGS[@]}"; do
    log_info "=== Parsing ORIONX_PERF sentinels from: ${serial_log} ==="

    # Check BEGIN marker present
    if ! grep -qF "ORIONX_PERF_BEGIN" "${serial_log}" 2>/dev/null; then
        fail "ORIONX_PERF_BEGIN not found in ${serial_log}" \
             "orionx-perf-measure.service may not have run"
        ((PERF_OVERALL_FAIL+=1))
        continue
    fi
    pass "ORIONX_PERF_BEGIN present in $(basename "${serial_log}")"

    # Check END marker present
    if ! grep -qF "ORIONX_PERF_END:" "${serial_log}" 2>/dev/null; then
        fail "ORIONX_PERF_END: not found in ${serial_log}" \
             "perf-measure.sh may have been interrupted or timed out"
        ((PERF_OVERALL_FAIL+=1))
        continue
    fi
    pass "ORIONX_PERF_END: present in $(basename "${serial_log}")"

    # Parse boot_time_seconds
    boot_line="$(grep "ORIONX_PERF: boot_time_seconds=" "${serial_log}" 2>/dev/null | tail -1 || true)"
    if [[ -z "${boot_line}" ]]; then
        fail "boot_time_seconds sentinel missing from $(basename "${serial_log}")"
    else
        boot_val="$(echo "${boot_line}" | grep -oE '[0-9]+$' || echo "")"
        if [[ -z "${boot_val}" ]]; then
            fail "boot_time_seconds value unparseable: ${boot_line}"
        elif [[ "${boot_val}" -lt "${BOOT_TIME_THRESHOLD}" ]] 2>/dev/null; then
            pass "boot_time_seconds=${boot_val} < ${BOOT_TIME_THRESHOLD}s [PASS]"
        else
            fail "boot_time_seconds=${boot_val} >= ${BOOT_TIME_THRESHOLD}s threshold" \
                 "line: ${boot_line}"
        fi
    fi

    # Parse idle_ram_bytes
    ram_line="$(grep "ORIONX_PERF: idle_ram_bytes=" "${serial_log}" 2>/dev/null | tail -1 || true)"
    if [[ -z "${ram_line}" ]]; then
        fail "idle_ram_bytes sentinel missing from $(basename "${serial_log}")"
    else
        ram_val="$(echo "${ram_line}" | grep -oE '[0-9]+$' || echo "")"
        if [[ -z "${ram_val}" ]]; then
            fail "idle_ram_bytes value unparseable: ${ram_line}"
        elif [[ "${ram_val}" -lt "${IDLE_RAM_THRESHOLD}" ]] 2>/dev/null; then
            pass "idle_ram_bytes=${ram_val} < ${IDLE_RAM_THRESHOLD} (1 GiB) [PASS]"
        else
            fail "idle_ram_bytes=${ram_val} >= ${IDLE_RAM_THRESHOLD} (1 GiB) threshold" \
                 "line: ${ram_line}"
        fi
    fi

    # Parse overall verdict from END line
    end_line="$(grep "ORIONX_PERF_END:" "${serial_log}" 2>/dev/null | tail -1 || true)"
    if echo "${end_line}" | grep -qiF "overall=PASS"; then
        pass "overall sentinel: PASS in $(basename "${serial_log}")"
        ((PERF_OVERALL_PASS+=1))
    else
        fail "overall sentinel: not PASS in $(basename "${serial_log}")" \
             "end line: ${end_line}"
        ((PERF_OVERALL_FAIL+=1))
    fi

    # Dump full sentinel block for diagnostics
    echo ""
    echo "--- Perf sentinel block from $(basename "${serial_log}") ---"
    grep "ORIONX_PERF" "${serial_log}" 2>/dev/null || echo "(none found)"
    echo "--- End perf sentinel block ---"
    echo ""
done

# ---------------------------------------------------------------------------
# Assert at least one serial log showed overall=PASS
# ---------------------------------------------------------------------------
if [[ "${PERF_OVERALL_PASS}" -gt 0 && "${PERF_OVERALL_FAIL}" -eq 0 ]]; then
    pass "All serial logs show ORIONX_PERF_END: overall=PASS"
elif [[ "${PERF_OVERALL_FAIL}" -gt 0 ]]; then
    fail "One or more serial logs show performance failures" \
         "overall_pass=${PERF_OVERALL_PASS} overall_fail=${PERF_OVERALL_FAIL}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL ))
echo "W7-5 Performance Benchmark Test Results"
echo "  PASS: ${PASS}  FAIL: ${FAIL}  TOTAL: ${TOTAL}"
echo "  QEMU harness exit: ${HARNESS_EXIT}"
echo "  Thresholds: boot<${BOOT_TIME_THRESHOLD}s  iso<${ISO_SIZE_THRESHOLD}B  ram<${IDLE_RAM_THRESHOLD}B"
echo "==========================================="

if [[ ${FAIL} -gt 0 || ${HARNESS_EXIT} -ne 0 ]]; then
    exit 1
fi
exit 0
