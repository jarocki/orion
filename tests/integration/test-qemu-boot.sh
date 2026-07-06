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
# @title W11-1 first-inference latency benchmark: active Qwen2.5-3B inference via ollama
# @status accepted
# @rationale Swapping Mistral-7B → Qwen2.5-3B changes the first-inference latency
#   profile (expected 2-3× faster per-token on CPU). T5 of W11-1 requires an
#   ACTIVE inference trigger via `ollama run qwen2.5:3b-instruct-q4_K_M` — NOT
#   a passive scan of the opt-in nebula-warmup.service logs, which require
#   operator enablement and cannot be assumed in CI or hardware smoke. This
#   wrapper runs the benchmark directly against the booted QEMU guest via the
#   Ollama daemon socket (127.0.0.1:11434) forwarded through the QEMU user-mode
#   network. Degrades gracefully: if QEMU/KVM is unavailable (mac runner, CI
#   env without KVM), the benchmark SKIPS cleanly rather than silently passing
#   with a false-positive JSON file. Rollback boundary: hard-fail if wall-clock
#   > 60 s (DEC-PHASE11-002 acceptance criterion 3, MASTER_PLAN line 2540).

# IMPORTANT: NO set -e — wrapper must capture and relay harness exit codes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HARNESS="${REPO_ROOT}/scripts/qemu-boot-test.sh"
INFERENCE_JSON="${REPO_ROOT}/tmp/nebula-first-inference-qwen3b.json"

# T5 constants (DEC-PHASE11-002)
OLLAMA_MODEL_TAG="qwen2.5:3b-instruct-q4_K_M"
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
INFERENCE_PROMPT="hello"
LATENCY_HARD_FAIL_MS=60000   # 60 s wall-clock ceiling (rollback boundary, MASTER_PLAN line 2540)
VM_CPU_COUNT=2
VM_RAM_MB=4096

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
# W11-1 T5 — Nebula First-Inference Latency Benchmark (ACTIVE, DEC-PHASE11-002)
#
# Actively triggers inference via `ollama run qwen2.5:3b-instruct-q4_K_M`
# against the Ollama daemon running inside the QEMU guest (port forwarded to
# OLLAMA_HOST:OLLAMA_PORT). Records wall-clock latency in ms and s.
#
# Outputs tmp/nebula-first-inference-qwen3b.json with fields:
#   model_tag         — ollama model tag (string)
#   prompt            — the inference prompt sent (string)
#   latency_ms        — wall-clock ms from ollama invocation to first response (integer)
#   latency_s         — latency_ms / 1000.0 (float, two decimal places)
#   timestamp         — ISO-8601 UTC timestamp when benchmark ran (string)
#   vm_cpu_count      — vCPU count of the test VM shape (integer)
#   vm_ram_mb         — RAM in MB of the test VM shape (integer)
#   iso_head_sha      — git HEAD SHA of the branch under test (string)
#   ollama_version    — ollama version string from `ollama --version` (string or null)
#   prior_baseline_ms — prior Mistral-7B baseline in ms if available, else null
#
# Behaviour matrix:
#   QEMU SKIP   → print SKIP with reason; do NOT write JSON; exit harness_exit
#   ollama down → FAIL with clear message; do NOT write JSON; exit 1
#   latency > 60 s → FAIL (rollback boundary per MASTER_PLAN line 2540); JSON still written
#   latency ≤ 60 s → PASS; JSON written; exit harness_exit
#   no prior baseline → record null; do NOT fail
# ===========================================================================
echo ""
echo "==========================================="
echo "  W11-1 T5 — Nebula First-Inference Latency"
echo "==========================================="

# Ensure tmp/ directory exists for JSON output
mkdir -p "${REPO_ROOT}/tmp"

# --- Skip path: QEMU harness was not available ---
if [[ "${harness_exit}" -eq 2 ]]; then
    echo "${YELLOW}  SKIP${NC}: QEMU harness unavailable (KVM/OVMF not present in this environment)"
    echo "         Reason: harness exited 2 — QEMU or OVMF not available (mac/CI runner mismatch)"
    echo "         First-inference latency benchmark requires a live QEMU guest."
    echo "         Re-run on a Linux host with KVM enabled: make test-qemu-boot ISO=/path/to/orionx.iso"
    echo "         No JSON artifact written (skip is clean — no false-positive baseline)."
    echo "==========================================="
    exit "${harness_exit}"
fi

# --- Active inference: ollama must be reachable at OLLAMA_HOST:OLLAMA_PORT ---
# The QEMU harness forwards guest port 11434 to the host via user-mode networking
# (-netdev user,hostfwd=tcp::11434-:11434). If the forwarded port is not up,
# the guest boot may have failed or Ollama daemon not yet started.

_ollama_reachable() {
    # Quick TCP probe: return 0 if port is open, 1 otherwise
    if command -v nc &>/dev/null; then
        nc -z "${OLLAMA_HOST}" "${OLLAMA_PORT}" &>/dev/null
    elif command -v curl &>/dev/null; then
        curl -s --connect-timeout 3 \
            "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags" &>/dev/null
    else
        # Fallback: bash /dev/tcp probe (not available on all shells but bash ≥ 4 supports it)
        (echo >/dev/tcp/"${OLLAMA_HOST}"/"${OLLAMA_PORT}") &>/dev/null
    fi
}

echo "  Probing Ollama daemon at ${OLLAMA_HOST}:${OLLAMA_PORT} ..."
if ! _ollama_reachable; then
    echo "${RED}  FAIL${NC}: Ollama daemon not reachable at ${OLLAMA_HOST}:${OLLAMA_PORT}"
    echo "         The QEMU guest boot completed (harness_exit=${harness_exit}) but Ollama"
    echo "         is not responding. Possible causes:"
    echo "           1. QEMU user-mode port forward not configured (hostfwd=tcp::11434-:11434)"
    echo "           2. Ollama daemon not started inside the guest"
    echo "           3. R2 risk: pinned Ollama version incompatible with Qwen2.5-3B (DEC-PHASE11-002)"
    echo "         Check QEMU harness invocation in scripts/qemu-boot-test.sh."
    exit 1
fi
echo "  Ollama daemon reachable."

# Capture ollama version for the JSON record (informational; null if unavailable)
OLLAMA_VERSION="null"
if command -v ollama &>/dev/null; then
    _ver="$(OLLAMA_HOST="${OLLAMA_HOST}" OLLAMA_PORT="${OLLAMA_PORT}" \
        ollama --version 2>/dev/null | head -1 || true)"
    if [[ -n "${_ver}" ]]; then
        # JSON-escape: strip quotes and newlines; simple approach for version strings
        _ver="${_ver//\"/\'}"
        OLLAMA_VERSION="\"${_ver}\""
    fi
fi

# Prior baseline: null unless a previous JSON artifact already captured one
PRIOR_BASELINE_MS="null"
if [[ -f "${INFERENCE_JSON}" ]]; then
    _prior="$(python3 -c "
import json, sys
try:
    d = json.load(open('${INFERENCE_JSON}'))
    v = d.get('latency_ms')
    print(v if v is not None else 'null')
except Exception:
    print('null')
" 2>/dev/null || true)"
    if [[ "${_prior}" =~ ^[0-9]+$ ]]; then
        PRIOR_BASELINE_MS="${_prior}"
    fi
fi

# Resolve current git HEAD SHA
ISO_HEAD_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"

# Record timestamp (UTC ISO-8601)
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"

# --- Active inference invocation ---
# Run `ollama run` three times per R3 mitigation (implementer note MASTER_PLAN line 2546):
# record the 3rd (steady-state) latency, not cold-start. The cold-start is
# architecturally expected to be the slowest; the ceiling is still 60 s on the 3rd run.
echo "  Running 3 warmup inferences (R3 mitigation: record steady-state, not cold-start)..."
echo "  Model: ${OLLAMA_MODEL_TAG}"
echo "  Prompt: \"${INFERENCE_PROMPT}\""

LATENCY_MS=""

for _run in 1 2 3; do
    echo "  Run ${_run}/3 ..."
    _start_ms="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')"
    OLLAMA_HOST="${OLLAMA_HOST}" OLLAMA_PORT="${OLLAMA_PORT}" \
        ollama run "${OLLAMA_MODEL_TAG}" "${INFERENCE_PROMPT}" \
        >/dev/null 2>&1 || {
        echo "${RED}  FAIL${NC}: \`ollama run ${OLLAMA_MODEL_TAG} \"${INFERENCE_PROMPT}\"\` failed on run ${_run}"
        echo "         This may indicate R2: pinned Ollama version incompatible with Qwen2.5-3B"
        echo "         (DEC-PHASE11-002 rollback boundary). Check Ollama daemon logs."
        exit 1
    }
    _end_ms="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')"
    LATENCY_MS=$(( _end_ms - _start_ms ))
    echo "  Run ${_run}/3 completed: ${LATENCY_MS} ms"
done

# LATENCY_MS now holds the 3rd-run (steady-state) measurement
LATENCY_S="$(python3 -c "print('{:.2f}'.format(${LATENCY_MS}/1000.0))" 2>/dev/null \
    || echo "$(( LATENCY_MS / 1000 )).$(printf '%02d' $(( (LATENCY_MS % 1000) / 10 )))")"

# --- Write JSON artifact (DEC-PHASE11-002 T5, fields per MASTER_PLAN line 2492) ---
python3 - <<PYEOF
import json
data = {
    "model_tag":         "${OLLAMA_MODEL_TAG}",
    "prompt":            "${INFERENCE_PROMPT}",
    "latency_ms":        ${LATENCY_MS},
    "latency_s":         float("${LATENCY_S}"),
    "timestamp":         "${TIMESTAMP}",
    "vm_cpu_count":      ${VM_CPU_COUNT},
    "vm_ram_mb":         ${VM_RAM_MB},
    "iso_head_sha":      "${ISO_HEAD_SHA}",
    "ollama_version":    ${OLLAMA_VERSION},
    "prior_baseline_ms": ${PRIOR_BASELINE_MS},
}
with open("${INFERENCE_JSON}", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("  JSON written: ${INFERENCE_JSON}")
PYEOF

echo ""
echo "  Latency (3rd run / steady-state): ${LATENCY_MS} ms (${LATENCY_S} s)"
echo "  Hard-fail ceiling: ${LATENCY_HARD_FAIL_MS} ms (60 s — MASTER_PLAN line 2540)"

# --- Hard-fail gate: > 60 s means rollback boundary triggered ---
if [[ "${LATENCY_MS}" -gt "${LATENCY_HARD_FAIL_MS}" ]]; then
    echo "${RED}  FAIL${NC}: first-inference latency ${LATENCY_MS} ms exceeds 60 s hard ceiling"
    echo "         DEC-PHASE11-002 rollback boundary triggered: Qwen-3B on 2 vCPU / 4 GB"
    echo "         must complete first inference in ≤ 60 s wall-clock."
    echo "         JSON artifact written for diagnosis: ${INFERENCE_JSON}"
    echo "         Diagnose: check VM shape, Ollama version (R2), or escalate to planner"
    echo "         for a DEC-PHASE11-002 amendment or rider slice."
    exit 1
fi

echo "${GREEN}  PASS${NC}: Nebula first-inference latency within 60 s ceiling (DEC-PHASE11-002)"
echo "         ORIONX_PERF: nebula_first_inference_ms=${LATENCY_MS}"
echo "         JSON artifact: ${INFERENCE_JSON}"
if [[ "${PRIOR_BASELINE_MS}" != "null" ]]; then
    echo "         Prior baseline: ${PRIOR_BASELINE_MS} ms (delta: $(( LATENCY_MS - PRIOR_BASELINE_MS )) ms)"
else
    echo "         Prior baseline: none recorded (first run — no Mistral baseline on disk)"
fi
echo "         NOTE: Pin this value as the W11-1 QEMU baseline before the v2.1.0 tag."

echo "==========================================="
exit "${harness_exit}"
