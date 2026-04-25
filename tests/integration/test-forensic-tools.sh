#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition — Forensic Toolkit Validation
#
# Validates each forensic tool from the package manifest responds
# to --version or --help. Missing tools are reported as SKIP.
#
# Usage: bash tests/integration/test-forensic-tools.sh
#
# @decision DEC-FORENSIC-TOOLS-001
# @title Graceful skip for missing tools in non-ISO environments
# @status accepted
# @rationale Docker dev containers and CI don't have all forensic
#   tools installed. SKIP is acceptable; FAIL means the tool exists
#   but is broken. Exit 0 when no FAILs. Parallel arrays used instead
#   of associative arrays for bash 3.2 compatibility (macOS default).

# =========================================================================
# Tool registry — parallel arrays (name and command at same index)
# =========================================================================

# --- System tools (expected on most environments) ---
SYSTEM_NAMES=(  python3             curl             jq             socat      )
SYSTEM_CMDS=(   "python3 --version" "curl --version" "jq --version" "socat -V" )

# --- Core forensic tools (from the package manifest) ---
FORENSIC_NAMES=(
    binwalk  bulk_extractor  dc3dd      foremost   hashcat   hexedit
    hydra    john            nmap       nikto      clamscan  lynis
    tcpdump  tshark          testdisk   sleuthkit
)
FORENSIC_CMDS=(
    "binwalk --help"        "bulk_extractor -h"   "dc3dd --help"
    "foremost -V"           "hashcat --version"   "hexedit --help"
    "hydra -h"              "john --help"         "nmap --version"
    "nikto -Version"        "clamscan --version"  "lynis --version"
    "tcpdump --version"     "tshark --version"    "testdisk --version"
    "tsk_recover --version"
)

# --- External tools (may not be in PATH) ---
EXTERNAL_NAMES=( volatility3    zeek             ghidra                  autopsy            )
EXTERNAL_CMDS=(  "vol --help"   "zeek --version" "analyzeHeadless --help" "autopsy --version" )

# =========================================================================
# Test framework (matches project conventions from test-mesh.sh)
# =========================================================================

PASS=0
FAIL=0
SKIP=0

# Colors (if terminal supports them)
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

# =========================================================================
# Tool checker
# =========================================================================

check_tool() {
    local name="$1"
    local cmd="$2"

    # Extract binary name (first word of command)
    local binary
    binary=$(echo "$cmd" | awk '{print $1}')

    if ! command -v "$binary" &>/dev/null; then
        echo "${YELLOW}  SKIP${NC}: $name (not installed)"
        ((SKIP++)) || true
        return
    fi

    # Run the version/help command, capture exit code
    if eval "$cmd" &>/dev/null; then
        echo "${GREEN}  PASS${NC}: $name"
        ((PASS++)) || true
    else
        # Some tools exit non-zero on --help but still produce output.
        # Accept the result if the output references the tool name, the
        # binary name, a version string, or usage/help text.
        local output
        output=$(eval "$cmd" 2>&1 || true)
        if echo "$output" | grep -qi "$name\|$binary\|version\|usage\|help"; then
            echo "${GREEN}  PASS${NC}: $name (non-zero exit but valid output)"
            ((PASS++)) || true
        else
            echo "${RED}  FAIL${NC}: $name (exists but failed to respond)"
            ((FAIL++)) || true
        fi
    fi
}

# =========================================================================
# Main
# =========================================================================

echo "==========================================="
echo "  Orion-X Forensic Toolkit Validation"
echo "==========================================="

# --- System Tools ---
echo ""
echo "--- System Tools ---"
for (( i=0; i<${#SYSTEM_NAMES[@]}; i++ )); do
    check_tool "${SYSTEM_NAMES[$i]}" "${SYSTEM_CMDS[$i]}"
done

# --- Forensic Tools ---
echo ""
echo "--- Forensic Tools ---"
for (( i=0; i<${#FORENSIC_NAMES[@]}; i++ )); do
    check_tool "${FORENSIC_NAMES[$i]}" "${FORENSIC_CMDS[$i]}"
done

# --- External Tools ---
echo ""
echo "--- External Tools ---"
for (( i=0; i<${#EXTERNAL_NAMES[@]}; i++ )); do
    check_tool "${EXTERNAL_NAMES[$i]}" "${EXTERNAL_CMDS[$i]}"
done

# Summary
echo ""
echo "==========================================="
echo "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

[[ "$FAIL" -eq 0 ]] || exit 1
