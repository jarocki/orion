#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — QEMU Boot Integration Test Wrapper
#
# Thin wrapper around scripts/qemu-boot-test.sh that produces PASS/FAIL/SKIP
# framing consistent with the project's integration test convention
# (test-mesh.sh, test-matrix.sh, test-security-hardening.sh, test-e2e-scenario.sh).
#
# This wrapper is intentionally minimal: scripts/qemu-boot-test.sh is the
# single authority for QEMU invocation, OVMF resolution, boot-mode dispatch,
# and PASS/FAIL/SKIP semantics. This file only adapts exit codes into the
# project's structured summary output and is the entry point for
# `make test-qemu-boot`.
#
# W11-1 addition: after the harness completes, this wrapper scans the serial
# log artifacts for the Nebula first-inference latency sentinel:
#
#   ORIONX_PERF: nebula_first_inference_ms=<integer>
#
# This sentinel is emitted by nebula-warmup.service when the operator has
# enabled it (opt-in per DEC-PHASE10-010). If the sentinel is absent (warmup
# not enabled, or QEMU skipped), the latency check is recorded as INFORMATIONAL
# — it does not fail the test. The recorded value establishes the Qwen2.5-3B
# first-inference baseline (DEC-PHASE11-002; Mistral-7B latency baseline
# superseded by this measurement).
#
# Usage:
#   bash tests/integration/test-qemu-boot.sh
#   ISO=/path/to/my.iso bash tests/integration/test-qemu-boot.sh
#   make test-qemu-boot
#   make test-qemu-boot ISO=/path/to/my.iso
#
# Exit codes (mirrors project convention):
#   0  — all modes PASS
#   1  — one or more modes FAIL
#   2  — modes SKIP (harness exit 2); propagated as non-zero so CI sees it
#
# @decision DEC-PHASE7-017
# @title Single bash harness scripts/qemu-boot-test.sh, not Python or Make-only
# @status accepted
# @rationale This wrapper exists only to provide a consistent
#   tests/integration/test-qemu-boot.sh entry point matching project
#   conventions. All actual boot logic lives in scripts/qemu-boot-test.sh.
#
# @decision DEC-PHASE11-002
# @title W11-1 first-inference latency benchmark: Qwen2.5-3B baseline recorded here
# @status accepted
# @rationale Swapping Mistral-7B → Qwen2.5-3B changes the first-inference latency
#   profile (expected 2-3× faster per-token on CPU). The ORIONX_PERF sentinel
#   emitted by nebula-warmup.service when opted in is the single authority for
#   the measured value. This wrapper records it post-harness from serial log
#   artifacts so the baseline is captured without requiring a separate benchmark
#   run. INFORMATIONAL-only: warmup is opt-in (DEC-PHASE10-010); absent sentinel
#   means the operator has not enabled warmup, not a build failure.

# IMPORTANT: NO set -e — wrapper must capture and relay harness exit codes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HARNESS="${REPO_ROOT}/scripts/qemu-boot-test.sh"
ARTIFACTS_BASE="${REPO_ROOT}/tmp/qemu-artifacts"

# Colors
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

echo "==========================================="
echo "  Orion-X QEMU Boot Integration Test"
echo "==========================================="

# Validate wrapper preconditions
if [[ ! -f "${HARNESS}" ]]; then
    echo "${RED}  FAIL${NC}: harness not found: ${HARNESS}"
    exit 1
fi

# Build harness args; propagate ISO env var if set
HARNESS_ARGS=(--mode both)
if [[ -n "${ISO:-}" ]]; then
    HARNESS_ARGS+=(--iso "${ISO}")
fi

# Run the harness; capture exit code without set -e terminating the wrapper
harness_exit=0
bash "${HARNESS}" "${HARNESS_ARGS[@]}" || harness_exit=$?

echo ""
echo "==========================================="
echo "  QEMU Boot Integration Test — Summary"
echo "==========================================="

case "${harness_exit}" in
    0)
        echo "${GREEN}  PASS${NC}: QEMU boot harness completed — BIOS and UEFI both PASS"
        ;;
    2)
        echo "${YELLOW}  SKIP${NC}: QEMU boot harness reported SKIP for one or more modes"
        echo "         Check harness output above for OVMF/KVM availability details."
        ;;
    *)
        echo "${RED}  FAIL${NC}: QEMU boot harness exited ${harness_exit} — one or more modes FAILED"
        echo "         Check serial logs under tmp/qemu-artifacts/ for debugging."
        ;;
esac

# ===========================================================================
# W11-1 Nebula First-Inference Latency Benchmark (INFORMATIONAL)
#
# Scan the most recent QEMU serial log artifacts for the Nebula warmup
# sentinel emitted by nebula-warmup.service:
#
#   ORIONX_PERF: nebula_first_inference_ms=<integer>
#
# This establishes the Qwen2.5-3B-Instruct Q4_K_M first-inference baseline
# on the QEMU vCPU profile (DEC-PHASE11-002). The check is INFORMATIONAL:
#   - FOUND   → print the measured latency; PASS (baseline recorded)
#   - ABSENT  → warmup is opt-in (DEC-PHASE10-010); print INFO, do not fail
#   - SKIP    → harness was skipped (harness_exit=2); latency not measurable
#
# The sentinel format mirrors ORIONX_PERF used by the W7-5 perf suite so
# log parsers can extract it uniformly.
# ===========================================================================
echo ""
echo "==========================================="
echo "  W11-1 Nebula First-Inference Latency"
echo "==========================================="

if [[ "${harness_exit}" -eq 2 ]]; then
    echo "${YELLOW}  INFO${NC}: QEMU harness SKIPped — first-inference latency not measurable"
    echo "         Enable QEMU (KVM + OVMF) to capture Qwen2.5-3B warmup latency."
else
    # Find the most recent run directory under tmp/qemu-artifacts/
    LATEST_RUN=""
    if [[ -d "${ARTIFACTS_BASE}" ]]; then
        # Sort by name; run IDs are timestamped so newest is last lexicographically
        LATEST_RUN="$(find "${ARTIFACTS_BASE}" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
            | sort | tail -1 | xargs basename 2>/dev/null || true)"
    fi

    LATENCY_MS=""
    LATENCY_SOURCE=""

    if [[ -n "${LATEST_RUN}" ]]; then
        RUN_DIR="${ARTIFACTS_BASE}/${LATEST_RUN}"
        # Check both BIOS and UEFI serial logs; prefer bios (default mode)
        for serial_log in \
            "${RUN_DIR}/serial-bios.log" \
            "${RUN_DIR}/serial-uefi.log" \
            "${RUN_DIR}/serial.log"; do
            if [[ -f "${serial_log}" ]]; then
                # Extract the last occurrence of the sentinel (warmup may emit once per boot)
                sentinel_line="$(grep -F "ORIONX_PERF: nebula_first_inference_ms=" \
                    "${serial_log}" 2>/dev/null | tail -1 || true)"
                if [[ -n "${sentinel_line}" ]]; then
                    # Parse value: ORIONX_PERF: nebula_first_inference_ms=<int>
                    LATENCY_MS="${sentinel_line##*nebula_first_inference_ms=}"
                    LATENCY_MS="${LATENCY_MS%%[^0-9]*}"
                    LATENCY_SOURCE="$(basename "${serial_log}")"
                    break
                fi
            fi
        done
    fi

    if [[ -n "${LATENCY_MS}" ]]; then
        echo "${GREEN}  PASS${NC}: Nebula first-inference latency recorded (DEC-PHASE11-002 baseline)"
        echo "         ORIONX_PERF: nebula_first_inference_ms=${LATENCY_MS}"
        echo "         Source: ${LATENCY_SOURCE} (model: Qwen2.5-3B-Instruct Q4_K_M)"
        echo "         NOTE: Pin this value as the W11-1 QEMU baseline in MASTER_PLAN.md"
        echo "               before the v2.1.0 tag. Expected 2-3x faster than Mistral-7B."
    else
        echo "${YELLOW}  INFO${NC}: nebula_first_inference_ms sentinel not found in serial logs"
        echo "         nebula-warmup.service is opt-in (DEC-PHASE10-010); sentinel is only"
        echo "         emitted when the operator enables warmup via Control Center."
        echo "         To capture the latency baseline, enable nebula-warmup.service and"
        echo "         re-run: make test-qemu-boot ISO=/path/to/orionx.iso"
        if [[ -n "${LATEST_RUN}" ]]; then
            echo "         Searched: ${ARTIFACTS_BASE}/${LATEST_RUN}/serial-{bios,uefi}.log"
        else
            echo "         No run artifacts found under ${ARTIFACTS_BASE}/"
        fi
    fi
fi

echo "==========================================="
exit "${harness_exit}"
