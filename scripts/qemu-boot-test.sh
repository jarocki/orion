#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — QEMU Boot Test Harness
#
# Boots the Orion-X hybrid ISO under BIOS (SeaBIOS) and/or UEFI (OVMF) modes
# in QEMU, captures serial console output, and verifies that the system reaches
# a known-good boot milestone (multi-user.target or login prompt).
#
# @decision DEC-PHASE7-017
# @title Single bash harness scripts/qemu-boot-test.sh, not Python or Make-only
# @status accepted
# @rationale Matches existing project pattern (test-mesh.sh, test-matrix.sh,
#   test-security-hardening.sh, test-e2e-scenario.sh are all bash). Make alone
#   cannot express per-mode PASS/FAIL/SKIP, serial-log capture, OVMF resolution
#   order, KVM detection, and trap-based QEMU process cleanup. Python would
#   import a new state authority for what is fundamentally a
#   `qemu-system-x86_64 + grep + tee` orchestration.
#
# @decision DEC-PHASE7-018
# @title Boot the SAME hybrid ISO twice with different QEMU firmware (no UEFI-specific build)
# @status accepted
# @rationale iso/auto/config configures `--bootloader 'syslinux,grub-efi'`
#   producing a hybrid ISO that supports both BIOS (isolinux) and UEFI (grub-efi)
#   boot. The harness invokes qemu-system-x86_64 twice on the same ISO: once
#   with default SeaBIOS for legacy boot, once with -drive if=pflash,...,file=OVMF_CODE.fd
#   for UEFI. Producing two ISOs would diverge from the actual shipping artifact.
#
# @decision DEC-PHASE7-019
# @title OVMF resolution order with explicit SKIP on missing firmware (never silent PASS)
# @status accepted
# @rationale UEFI boot requires OVMF firmware (distribution-packaged). The
#   harness searches: 1) explicit --ovmf flag, 2) Debian/Ubuntu path, 3) Fedora/RHEL
#   path. If none found, emit SKIP record with exact paths searched and exit non-zero.
#   Silent UEFI-skip would hide a regression that breaks the goal contract.
#
# @decision DEC-PHASE7-020
# @title Serial-file capture with single-constant boot-success marker matcher
# @status accepted
# @rationale QEMU -nographic -serial file:<log> captures boot stream. Marker
#   pattern lives ONCE as BOOT_SUCCESS_MARKERS bash array at top of script.
#   Modes share the same matcher — no per-mode duplication, avoiding dual-authority
#   drift where BIOS and UEFI silently diverge on what 'booted' means.
#
# @decision DEC-PHASE7-021
# @title KVM-when-available, TCG-fallback, 300s default timeout
# @status accepted
# @rationale Checks [ -r /dev/kvm ] at runtime: if accessible use -enable-kvm
#   -cpu host (~30s boot); otherwise fall back to -accel tcg -cpu max (~120-270s
#   boot). Default --timeout 300 covers slowest realistic TCG path on any
#   ubuntu-latest SKU. PASS granted when marker appears within --timeout;
#   performance is informational only per DEC-PHASE7-004.
#
# @decision DEC-PHASE7-022
# @title Pre-declared W7-4 attach contract: --post-boot-script + --keep-running
# @status accepted
# @rationale W7-4 (mesh + Matrix + AppArmor runtime verification) needs to drive
#   commands inside the booted VM. W7-3 exposes two extension points so W7-4 can
#   attach without modifying this harness: (1) --post-boot-script runs a host-side
#   script after marker detection with run-id and serial-log path as args,
#   (2) --keep-running holds QEMU alive after marker detection so an external
#   driver can attach. See docs/qemu-boot-test.md for the W7-4 contract.
#
# Usage:
#   bash scripts/qemu-boot-test.sh [options]
#
# Options:
#   --mode bios|uefi|both   Boot mode(s) to test (default: both)
#   --iso <path>            Path to ISO image (default: output/orionx-phoenix-edition-v2.0.0-rc1.iso)
#   --ovmf <path>           Override OVMF_CODE.fd path for UEFI mode
#   --timeout <sec>         Boot timeout per mode in seconds (default: 300)
#   --post-boot-script <p>  W7-4 attach point: host-side script run after boot marker
#                           detected; receives RUN_ID and SERIAL_LOG as arguments
#   --keep-running          W7-4 attach point: keep QEMU alive after marker detection
#   --dry-run               Validate prerequisites (ISO, QEMU, OVMF) without booting
#   --help                  Show this help message
#
# Examples:
#   bash scripts/qemu-boot-test.sh --mode both
#   bash scripts/qemu-boot-test.sh --mode bios --iso output/myiso.iso --timeout 90
#   bash scripts/qemu-boot-test.sh --mode uefi --dry-run
#   ISO=/path/to/my.iso bash scripts/qemu-boot-test.sh --mode both
#
# IMPORTANT: NO set -e — cleanup must run on any failure path (matches DEC-PHASE7-009
# pattern from test-e2e-scenario.sh). All failures route through mode_fail() which
# increments FAIL counter. Trap on EXIT handles QEMU process cleanup.

set -uo pipefail

# =========================================================================
# Boot-success markers — single authority (DEC-PHASE7-020)
# First match in the serial log wins. Both BIOS and UEFI modes use this
# identical array. Do NOT add per-mode alternatives below.
# =========================================================================
BOOT_SUCCESS_MARKERS=(
    "Reached target Multi-User System"
    "Reached target multi-user.target"
    "orionx login:"
    "debian login:"
)

# =========================================================================
# OVMF search paths — resolution order (DEC-PHASE7-019)
# 1. Explicit --ovmf flag (set at arg-parse time, takes precedence)
# 2. Debian/Ubuntu: apt install ovmf
# 3. Fedora/RHEL:   dnf install edk2-ovmf
# =========================================================================
OVMF_SEARCH_PATHS=(
    "/usr/share/OVMF/OVMF_CODE.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE.fd"
)
OVMF_VARS_SEARCH_PATHS=(
    "/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_VARS.fd"
)

# =========================================================================
# Defaults (overridable via flags)
# =========================================================================
DEFAULT_ISO="output/orionx-phoenix-edition-v2.0.0-rc1.iso"
DEFAULT_MODE="both"
DEFAULT_TIMEOUT=300
HARNESS_VERSION="1.0.0"

# =========================================================================
# Script-level state
# =========================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Arguments (populated by parse_args)
ARG_MODE=""
ARG_ISO=""
ARG_OVMF_OVERRIDE=""
ARG_TIMEOUT=""
ARG_POST_BOOT_SCRIPT=""
ARG_KEEP_RUNNING=0
ARG_DRY_RUN=0

# Resolved values (populated after parse_args)
MODE=""
ISO_PATH=""
OVMF_PATH=""
TIMEOUT=0
RUN_ID=""
ARTIFACTS_DIR=""

# Per-mode result tracking
BIOS_STATUS="NOT_RUN"
BIOS_BOOT_SECONDS=0
UEFI_STATUS="NOT_RUN"
UEFI_BOOT_SECONDS=0

# Active QEMU PID for cleanup
QEMU_PID=0

# Colors (only when stdout is a terminal)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BOLD=""
    NC=""
fi

# =========================================================================
# Logging helpers
# =========================================================================

log_info()  { echo "${CYAN}[INFO]${NC}  $*"; }
log_pass()  { echo "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo "${RED}[FAIL]${NC}  $*"; }
log_skip()  { echo "${YELLOW}[SKIP]${NC}  $*"; }
log_warn()  { echo "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo "${RED}[ERROR]${NC} $*" >&2; }

# =========================================================================
# Usage
# =========================================================================

usage() {
    cat <<'USAGE'
Usage:
  bash scripts/qemu-boot-test.sh [options]

Options:
  --mode bios|uefi|both   Boot mode(s) to test (default: both)
  --iso <path>            Path to ISO image (default: output/orionx-phoenix-edition-v2.0.0-rc1.iso)
  --ovmf <path>           Override OVMF_CODE.fd path for UEFI mode
  --timeout <sec>         Boot timeout per mode in seconds (default: 300)
  --post-boot-script <p>  W7-4 attach point: host-side script run after boot marker
                          detected; receives RUN_ID and SERIAL_LOG as arguments
  --keep-running          W7-4 attach point: keep QEMU alive after marker detection
  --dry-run               Validate prerequisites (ISO, QEMU, OVMF) without booting
  --help                  Show this help message

Examples:
  bash scripts/qemu-boot-test.sh --mode both
  bash scripts/qemu-boot-test.sh --mode bios --iso output/myiso.iso --timeout 90
  bash scripts/qemu-boot-test.sh --mode uefi --dry-run
  ISO=/path/to/my.iso bash scripts/qemu-boot-test.sh --mode both

Environment override: ISO=<path> bash scripts/qemu-boot-test.sh --mode both
USAGE
}

# =========================================================================
# Argument parsing
# =========================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                ARG_MODE="${2:?--mode requires a value}"
                shift 2
                ;;
            --iso)
                ARG_ISO="${2:?--iso requires a value}"
                shift 2
                ;;
            --ovmf)
                ARG_OVMF_OVERRIDE="${2:?--ovmf requires a value}"
                shift 2
                ;;
            --timeout)
                ARG_TIMEOUT="${2:?--timeout requires a value}"
                shift 2
                ;;
            --post-boot-script)
                ARG_POST_BOOT_SCRIPT="${2:?--post-boot-script requires a value}"
                shift 2
                ;;
            --keep-running)
                ARG_KEEP_RUNNING=1
                shift
                ;;
            --dry-run)
                ARG_DRY_RUN=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# =========================================================================
# OVMF resolution — single authority (DEC-PHASE7-019)
# Sets global OVMF_PATH. Returns 0 if resolved, 1 if not found.
# =========================================================================

resolve_ovmf() {
    # Priority 1: explicit --ovmf override
    if [[ -n "${ARG_OVMF_OVERRIDE}" ]]; then
        if [[ -f "${ARG_OVMF_OVERRIDE}" ]]; then
            OVMF_PATH="${ARG_OVMF_OVERRIDE}"
            log_info "OVMF resolved via --ovmf flag: ${OVMF_PATH}"
            return 0
        else
            log_error "Explicit --ovmf path not found: ${ARG_OVMF_OVERRIDE}"
            return 1
        fi
    fi

    # Priority 2-3: search standard paths
    local searched=()
    for candidate in "${OVMF_SEARCH_PATHS[@]}"; do
        searched+=("$candidate")
        if [[ -f "$candidate" ]]; then
            OVMF_PATH="$candidate"
            log_info "OVMF resolved via search: ${OVMF_PATH}"
            return 0
        fi
    done

    # Not found — emit actionable SKIP record
    log_skip "OVMF firmware not found. Searched:"
    for p in "${searched[@]}"; do
        log_skip "  - ${p}"
    done
    log_skip "Install with: sudo apt-get install ovmf  (Debian/Ubuntu)"
    log_skip "              sudo dnf install edk2-ovmf  (Fedora/RHEL)"
    OVMF_PATH=""
    return 1
}

# Find OVMF_VARS.fd companion file (writable template for UEFI variable store)
find_ovmf_vars() {
    local code_dir
    code_dir="$(dirname "${OVMF_PATH}")"

    # First try same directory as OVMF_CODE.fd
    local candidate="${code_dir}/OVMF_VARS.fd"
    if [[ -f "$candidate" ]]; then
        echo "$candidate"
        return 0
    fi

    # Then try search paths
    for vars_path in "${OVMF_VARS_SEARCH_PATHS[@]}"; do
        if [[ -f "$vars_path" ]]; then
            echo "$vars_path"
            return 0
        fi
    done

    echo ""
    return 1
}

# =========================================================================
# KVM detection (DEC-PHASE7-021)
# Sets QEMU_ACCEL_ARGS array based on /dev/kvm accessibility.
# =========================================================================

detect_kvm() {
    if [[ -r /dev/kvm ]]; then
        log_info "KVM acceleration available (/dev/kvm readable)"
        QEMU_ACCEL_ARGS=(-enable-kvm -cpu host)
        HOST_KVM=true
    else
        log_warn "KVM not available (/dev/kvm unreadable). Using TCG fallback. Boot may take 120-270s."
        QEMU_ACCEL_ARGS=(-accel tcg -cpu max)
        HOST_KVM=false
    fi
}

# Global set by detect_kvm
HOST_KVM=false
QEMU_ACCEL_ARGS=()

# =========================================================================
# ISO SHA256 (best-effort; does not fail preflight if slow)
# =========================================================================

compute_iso_sha256() {
    local iso_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$iso_path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$iso_path" | awk '{print $1}'
    else
        echo "unavailable"
    fi
}

# =========================================================================
# Preflight checks
# =========================================================================

preflight() {
    log_info "Running preflight checks..."
    local failed=0

    # qemu-system-x86_64 availability
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log_fail "qemu-system-x86_64 not found in PATH"
        log_fail "  Install with: sudo apt-get install qemu-system-x86"
        log_fail "              or: brew install qemu"
        failed=1
    else
        local qemu_ver
        qemu_ver="$(qemu-system-x86_64 --version 2>&1 | head -1)"
        log_info "QEMU: ${qemu_ver}"
    fi

    # ISO existence
    if [[ ! -f "${ISO_PATH}" ]]; then
        log_fail "ISO not found: ${ISO_PATH}"
        log_fail "  Build with: make iso-build"
        log_fail "  Or specify: --iso <path>"
        failed=1
    else
        local iso_size
        iso_size="$(du -sh "${ISO_PATH}" 2>/dev/null | awk '{print $1}')"
        log_info "ISO: ${ISO_PATH} (${iso_size})"
    fi

    # UEFI firmware check (only when uefi or both mode)
    if [[ "${MODE}" == "uefi" || "${MODE}" == "both" ]]; then
        if ! resolve_ovmf; then
            if [[ "${MODE}" == "uefi" ]]; then
                # uefi-only mode with no OVMF is a hard blocker
                log_fail "UEFI mode requested but OVMF firmware unavailable"
                failed=1
            else
                # both mode — UEFI will be SKIPped, BIOS still runs
                log_warn "UEFI will be SKIPPED (OVMF unavailable). BIOS mode will proceed."
            fi
        fi
    fi

    # post-boot-script validation
    if [[ -n "${ARG_POST_BOOT_SCRIPT}" && ! -f "${ARG_POST_BOOT_SCRIPT}" ]]; then
        log_fail "Post-boot script not found: ${ARG_POST_BOOT_SCRIPT}"
        failed=1
    fi

    if [[ $failed -ne 0 ]]; then
        log_error "Preflight failed. Resolve the issues above before running."
        return 1
    fi

    log_info "Preflight checks passed."
    return 0
}

# =========================================================================
# QEMU process cleanup — called from EXIT trap and after each mode
# =========================================================================

kill_qemu() {
    local pid="${1:-${QEMU_PID}}"
    if [[ "${pid}" -le 0 ]]; then
        return 0
    fi

    if kill -0 "${pid}" 2>/dev/null; then
        log_info "Terminating QEMU PID ${pid} (SIGTERM)..."
        kill -TERM "${pid}" 2>/dev/null || true
        local waited=0
        while kill -0 "${pid}" 2>/dev/null && [[ $waited -lt 10 ]]; do
            sleep 1
            (( waited++ )) || true
        done
        if kill -0 "${pid}" 2>/dev/null; then
            log_warn "QEMU PID ${pid} did not exit after 10s SIGTERM — sending SIGKILL"
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    fi

    QEMU_PID=0
}

# shellcheck disable=SC2329,SC2317  # false positive — reached indirectly via: trap cleanup EXIT
cleanup() {
    # Ensure QEMU is dead on any exit path
    if [[ "${QEMU_PID}" -gt 0 ]]; then
        kill_qemu "${QEMU_PID}"
    fi
}

trap cleanup EXIT

# =========================================================================
# Serial log watcher — polls log for any BOOT_SUCCESS_MARKERS entry
# Outputs the matched marker to stdout and exits 0 when found.
# Exits 1 if deadline passes without a match.
# =========================================================================

watch_serial_log() {
    local log_file="$1"
    local deadline="$2"   # epoch seconds

    while [[ "$(date +%s)" -lt "${deadline}" ]]; do
        if [[ -f "${log_file}" ]]; then
            for marker in "${BOOT_SUCCESS_MARKERS[@]}"; do
                if grep -qF "${marker}" "${log_file}" 2>/dev/null; then
                    echo "${marker}"
                    return 0
                fi
            done
        fi
        sleep 2
    done

    return 1
}

# =========================================================================
# Run a single boot mode and record PASS/FAIL/SKIP
# Sets <MODE_UPPER>_STATUS and <MODE_UPPER>_BOOT_SECONDS globals.
# =========================================================================

run_mode() {
    local mode="$1"                # "bios" or "uefi"
    local iso_path="$2"
    local artifacts_dir="$3"
    local timeout_sec="$4"

    local mode_upper
    mode_upper="$(echo "$mode" | tr '[:lower:]' '[:upper:]')"

    echo ""
    echo "${BOLD}${CYAN}=== Boot mode: ${mode_upper} ===${NC}"

    local serial_log="${artifacts_dir}/serial-${mode}.log"
    local start_epoch
    start_epoch="$(date +%s)"
    local deadline=$(( start_epoch + timeout_sec ))

    # ---- UEFI: resolve OVMF (may already be done in preflight) ----
    if [[ "${mode}" == "uefi" ]]; then
        if [[ -z "${OVMF_PATH}" ]]; then
            # resolve_ovmf was not called yet (e.g. bios-only preflight path)
            resolve_ovmf || true
        fi

        if [[ -z "${OVMF_PATH}" ]]; then
            log_skip "UEFI mode: OVMF firmware unavailable (see paths above)"
            if [[ "${mode_upper}" == "UEFI" ]]; then
                UEFI_STATUS="SKIP"
            fi
            return 0
        fi
    fi

    # ---- Build QEMU argv ----
    local qemu_args=()
    qemu_args+=(
        -m 2048
        -smp 2
        "${QEMU_ACCEL_ARGS[@]}"
        -nographic
        -monitor none
        -serial "file:${serial_log}"
        -no-reboot
    )

    if [[ "${mode}" == "bios" ]]; then
        # BIOS mode: no -bios override; use QEMU's default SeaBIOS
        qemu_args+=(
            -drive "media=cdrom,file=${iso_path},readonly=on"
            -boot d
        )
    else
        # UEFI mode: pflash CODE (readonly) + per-run VARS copy (writable)
        local ovmf_vars_src
        ovmf_vars_src="$(find_ovmf_vars)"

        local ovmf_vars_run="${artifacts_dir}/OVMF_VARS.fd"
        if [[ -n "${ovmf_vars_src}" ]]; then
            cp "${ovmf_vars_src}" "${ovmf_vars_run}"
        else
            # Some packages ship only OVMF_CODE.fd; create a zeroed VARS file
            log_warn "OVMF_VARS.fd not found — creating blank variable store (64K)"
            dd if=/dev/zero of="${ovmf_vars_run}" bs=1024 count=64 2>/dev/null
        fi

        qemu_args+=(
            -drive "if=pflash,format=raw,readonly=on,file=${OVMF_PATH}"
            -drive "if=pflash,format=raw,file=${ovmf_vars_run}"
            -drive "media=cdrom,file=${iso_path},readonly=on"
            -boot d
        )
    fi

    log_info "Launching QEMU (${mode_upper} mode, timeout ${timeout_sec}s)..."
    log_info "Serial log: ${serial_log}"

    # Launch QEMU in background; serial output goes to the log file
    qemu-system-x86_64 "${qemu_args[@]}" &
    QEMU_PID=$!
    log_info "QEMU PID: ${QEMU_PID}"

    # Watch for boot-success marker in parallel (in foreground, QEMU in bg)
    local matched_marker=""
    matched_marker="$(watch_serial_log "${serial_log}" "${deadline}")" || true

    local elapsed=$(( $(date +%s) - start_epoch ))

    if [[ -n "${matched_marker}" ]]; then
        log_pass "${mode_upper} boot succeeded in ${elapsed}s — marker: '${matched_marker}'"

        # W7-4 attach contract: run post-boot script if provided (DEC-PHASE7-022)
        if [[ -n "${ARG_POST_BOOT_SCRIPT}" ]]; then
            log_info "Running post-boot script: ${ARG_POST_BOOT_SCRIPT}"
            bash "${ARG_POST_BOOT_SCRIPT}" "${RUN_ID}" "${serial_log}" || {
                log_warn "Post-boot script exited non-zero (${?}). Boot itself is still PASS."
            }
        fi

        # W7-4 attach contract: optionally keep QEMU alive (DEC-PHASE7-022)
        if [[ "${ARG_KEEP_RUNNING}" -eq 1 ]]; then
            log_info "--keep-running set: QEMU process ${QEMU_PID} left running for external attachment."
            log_info "Attach via: kill -0 ${QEMU_PID} (check alive) or interact via monitor socket."
        else
            kill_qemu "${QEMU_PID}"
        fi

        # Record status
        if [[ "${mode}" == "bios" ]]; then
            BIOS_STATUS="PASS"
            BIOS_BOOT_SECONDS="${elapsed}"
        else
            UEFI_STATUS="PASS"
            UEFI_BOOT_SECONDS="${elapsed}"
        fi
    else
        # Timeout — QEMU still running; dump last 50 lines for debugging
        log_fail "${mode_upper} boot FAILED: timeout after ${elapsed}s — no boot marker found"
        log_fail "Serial log: ${serial_log}"
        if [[ -f "${serial_log}" ]]; then
            echo ""
            echo "--- Last 50 lines of serial log ---"
            tail -50 "${serial_log}" 2>/dev/null || true
            echo "--- End of serial log tail ---"
        fi
        kill_qemu "${QEMU_PID}"

        if [[ "${mode}" == "bios" ]]; then
            BIOS_STATUS="FAIL"
            BIOS_BOOT_SECONDS="${elapsed}"
        else
            UEFI_STATUS="FAIL"
            UEFI_BOOT_SECONDS="${elapsed}"
        fi
    fi
}

# =========================================================================
# Write the run summary JSON (required by Evaluation Contract evidence)
# =========================================================================

write_summary_json() {
    local artifacts_dir="$1"
    local iso_sha256="$2"

    local summary_file="${artifacts_dir}/qemu-boot-summary.json"

    # Escape string for JSON (no external tools required)
    local ovmf_json
    if [[ -n "${OVMF_PATH}" ]]; then
        ovmf_json="\"${OVMF_PATH}\""
    else
        ovmf_json="null"
    fi

    local kvm_json
    if [[ "${HOST_KVM}" == "true" ]]; then
        kvm_json="true"
    else
        kvm_json="false"
    fi

    cat > "${summary_file}" <<JSON
{
  "harness_version": "${HARNESS_VERSION}",
  "run_id": "${RUN_ID}",
  "iso_path": "${ISO_PATH}",
  "iso_sha256": "${iso_sha256}",
  "host_kvm": ${kvm_json},
  "ovmf_path": ${ovmf_json},
  "timeout_sec": ${TIMEOUT},
  "bios": {
    "status": "${BIOS_STATUS}",
    "boot_seconds": ${BIOS_BOOT_SECONDS}
  },
  "uefi": {
    "status": "${UEFI_STATUS}",
    "boot_seconds": ${UEFI_BOOT_SECONDS}
  }
}
JSON

    log_info "Summary JSON: ${summary_file}"
}

# =========================================================================
# Main
# =========================================================================

main() {
    parse_args "$@"

    # Resolve runtime values
    MODE="${ARG_MODE:-${DEFAULT_MODE}}"
    TIMEOUT="${ARG_TIMEOUT:-${DEFAULT_TIMEOUT}}"

    # ISO: --iso flag > ISO env var > default path
    if [[ -n "${ARG_ISO}" ]]; then
        ISO_PATH="${ARG_ISO}"
    elif [[ -n "${ISO:-}" ]]; then
        ISO_PATH="${ISO}"
    else
        ISO_PATH="${REPO_ROOT}/${DEFAULT_ISO}"
    fi

    # Validate mode
    case "${MODE}" in
        bios|uefi|both) ;;
        *)
            log_error "Invalid --mode value: '${MODE}'. Must be bios, uefi, or both."
            exit 1
            ;;
    esac

    # Generate run-id and artifact dir (DEC-PHASE7-010 / Sacred Practice 3)
    RUN_ID="$(date +%Y%m%d-%H%M%S)"
    ARTIFACTS_DIR="${REPO_ROOT}/tmp/qemu-artifacts/${RUN_ID}"
    mkdir -p "${ARTIFACTS_DIR}"

    echo ""
    echo "==========================================="
    echo "  Orion-X QEMU Boot Test Harness v${HARNESS_VERSION}"
    echo "==========================================="
    log_info "Mode:         ${MODE}"
    log_info "ISO:          ${ISO_PATH}"
    log_info "Timeout:      ${TIMEOUT}s per mode"
    log_info "Run ID:       ${RUN_ID}"
    log_info "Artifacts:    ${ARTIFACTS_DIR}"
    if [[ "${ARG_DRY_RUN}" -eq 1 ]]; then
        log_info "Dry run:      YES (no QEMU launched)"
    fi

    # Detect KVM before preflight logging
    detect_kvm

    # Preflight
    if ! preflight; then
        echo ""
        log_error "Preflight failed — aborting."
        exit 1
    fi

    # Dry run: done after preflight
    if [[ "${ARG_DRY_RUN}" -eq 1 ]]; then
        echo ""
        log_pass "Dry run complete. All prerequisites validated."
        log_info "ISO SHA256: $(compute_iso_sha256 "${ISO_PATH}")"
        if [[ -n "${OVMF_PATH}" ]]; then
            log_info "OVMF: ${OVMF_PATH}"
        fi
        exit 0
    fi

    # Compute ISO SHA256 once (used in summary JSON)
    local iso_sha256
    iso_sha256="$(compute_iso_sha256 "${ISO_PATH}")"
    log_info "ISO SHA256:   ${iso_sha256}"

    # Boot modes
    local SCENARIO_START
    SCENARIO_START="$(date +%s)"

    if [[ "${MODE}" == "bios" || "${MODE}" == "both" ]]; then
        run_mode "bios" "${ISO_PATH}" "${ARTIFACTS_DIR}" "${TIMEOUT}"
    fi

    if [[ "${MODE}" == "uefi" || "${MODE}" == "both" ]]; then
        run_mode "uefi" "${ISO_PATH}" "${ARTIFACTS_DIR}" "${TIMEOUT}"
    fi

    # Write summary JSON
    write_summary_json "${ARTIFACTS_DIR}" "${iso_sha256}"

    # Summary
    local total_elapsed=$(( $(date +%s) - SCENARIO_START ))
    echo ""
    echo "==========================================="
    echo "  QEMU Boot Test Results (run-id: ${RUN_ID})"
    echo "==========================================="

    local fail_count=0
    local skip_count=0

    if [[ "${MODE}" == "bios" || "${MODE}" == "both" ]]; then
        case "${BIOS_STATUS}" in
            PASS) log_pass "BIOS=${BIOS_STATUS} (${BIOS_BOOT_SECONDS}s)" ;;
            FAIL) log_fail "BIOS=${BIOS_STATUS} (${BIOS_BOOT_SECONDS}s)"; (( fail_count++ )) || true ;;
            SKIP) log_skip "BIOS=${BIOS_STATUS}"; (( skip_count++ )) || true ;;
            *)    log_warn "BIOS=NOT_RUN" ;;
        esac
    fi

    if [[ "${MODE}" == "uefi" || "${MODE}" == "both" ]]; then
        case "${UEFI_STATUS}" in
            PASS) log_pass "UEFI=${UEFI_STATUS} (${UEFI_BOOT_SECONDS}s)" ;;
            FAIL) log_fail "UEFI=${UEFI_STATUS} (${UEFI_BOOT_SECONDS}s)"; (( fail_count++ )) || true ;;
            SKIP) log_skip "UEFI=${UEFI_STATUS}"; (( skip_count++ )) || true ;;
            *)    log_warn "UEFI=NOT_RUN" ;;
        esac
    fi

    echo ""
    log_info "Total elapsed: ${total_elapsed}s"
    log_info "Artifacts:     ${ARTIFACTS_DIR}/"
    echo "==========================================="

    if [[ $fail_count -gt 0 ]]; then
        log_fail "Overall: FAIL (${fail_count} mode(s) failed)"
        exit 1
    elif [[ $skip_count -gt 0 && $fail_count -eq 0 ]]; then
        log_skip "Overall: SKIP (${skip_count} mode(s) skipped; none failed)"
        exit 2
    else
        log_pass "Overall: PASS"
        exit 0
    fi
}

main "$@"
