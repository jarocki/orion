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

# IMPORTANT: NO set -e — wrapper must capture and relay harness exit codes
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HARNESS="${REPO_ROOT}/scripts/qemu-boot-test.sh"

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

echo "==========================================="
exit "${harness_exit}"
