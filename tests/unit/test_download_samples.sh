#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W5-6: Modernize download-samples.sh
#
# Verifies:
#   1. Script exists and is executable
#   2. Has #!/usr/bin/env bash shebang
#   3. Has set -euo pipefail
#   4. Has shellcheck shell=bash directive
#   5. Has @decision DEC-FORENSIC-003 annotation
#   6. --help prints usage and exits 0
#   7. --offline mode creates sample files in target directory
#   8. Missing --samples-dir uses default data/samples
#   9. ShellCheck passes
#  10. No v1.5.5 references remain
#  11. Version is v2.0.0
#
# Production sequence: An operator in an air-gapped environment runs
# `download-samples.sh --offline --samples-dir /evidence/samples` to
# generate synthetic forensic data locally. In online environments,
# the default behavior downloads real samples. These tests verify both
# the offline CLI pathway and structural correctness without requiring
# network access.
#
# Usage: bash tests/unit/test_download_samples.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DOWNLOAD_SCRIPT="$REPO_ROOT/scripts/download-samples.sh"

# Test counters
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

pass() {
    ((PASS++))
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    ((FAIL++))
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

skip() {
    ((SKIP++))
    echo "${YELLOW}  SKIP${NC}: $1 — $2"
}

section() {
    echo ""
    echo "--- $1 ---"
}

# Temp directory for offline tests — cleaned up on exit
TMPDIR_TEST=""
cleanup() {
    if [[ -n "$TMPDIR_TEST" && -d "$TMPDIR_TEST" ]]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

echo "=== W5-6: download-samples.sh Modernization Tests ==="

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$DOWNLOAD_SCRIPT" ]]; then
    pass "download-samples.sh exists"
else
    fail "download-samples.sh exists" "Not found at $DOWNLOAD_SCRIPT"
    echo "FATAL: Script not found. Cannot continue."
    exit 1
fi

if [[ -x "$DOWNLOAD_SCRIPT" ]]; then
    pass "download-samples.sh is executable"
else
    fail "download-samples.sh is executable" "chmod +x $DOWNLOAD_SCRIPT"
fi

# ===========================================================================
# Shell modernization markers
# ===========================================================================
section "Shell Modernization"

if head -1 "$DOWNLOAD_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is #!/usr/bin/env bash" "Got: $(head -1 "$DOWNLOAD_SCRIPT" 2>/dev/null)"
fi

if grep -q '# shellcheck shell=bash' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Has shellcheck shell=bash directive" "Missing directive"
fi

if grep -q 'set -euo pipefail' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "Has set -euo pipefail"
else
    fail "Has set -euo pipefail" "Missing strict mode"
fi

if ! grep -q 'v1\.5\.5' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "No v1.5.5 references remain"
else
    fail "No v1.5.5 references remain" "Found v1.5.5 in script"
fi

if grep -q 'v2\.0\.0' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "Contains v2.0.0 version"
else
    fail "Contains v2.0.0 version" "Missing v2.0.0 reference"
fi

# ===========================================================================
# Decision annotation
# ===========================================================================
section "Decision Annotation"

if grep -q '@decision DEC-FORENSIC-003' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "Contains @decision DEC-FORENSIC-003 annotation"
else
    fail "Contains @decision DEC-FORENSIC-003 annotation" "Missing annotation"
fi

if grep -q '@status accepted' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "Decision annotation has @status accepted"
else
    fail "Decision annotation has @status accepted" "Missing @status"
fi

if grep -q '@rationale' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "Decision annotation has @rationale"
else
    fail "Decision annotation has @rationale" "Missing @rationale"
fi

# ===========================================================================
# CLI: --help
# ===========================================================================
section "CLI: --help"

set +e
output=$(bash "$DOWNLOAD_SCRIPT" --help 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--help' exits 0"
else
    fail "'--help' exits 0" "Exit code: $rc"
fi

if echo "$output" | grep -q 'Usage:'; then
    pass "'--help' shows Usage:"
else
    fail "'--help' shows Usage:" "Output did not contain Usage:"
fi

if echo "$output" | grep -q -- '--samples-dir'; then
    pass "'--help' documents --samples-dir"
else
    fail "'--help' documents --samples-dir" "Missing --samples-dir in help"
fi

if echo "$output" | grep -q -- '--offline'; then
    pass "'--help' documents --offline"
else
    fail "'--help' documents --offline" "Missing --offline in help"
fi

if echo "$output" | grep -q -- '--validate-urls'; then
    pass "'--help' documents --validate-urls"
else
    fail "'--help' documents --validate-urls" "Missing --validate-urls in help"
fi

if echo "$output" | grep -q -- '--checksums'; then
    pass "'--help' documents --checksums"
else
    fail "'--help' documents --checksums" "Missing --checksums in help"
fi

# Also test -h
set +e
output_h=$(bash "$DOWNLOAD_SCRIPT" -h 2>&1)
rc_h=$?
set -e
if [[ $rc_h -eq 0 ]] && echo "$output_h" | grep -q 'Usage:'; then
    pass "'-h' works as alias for --help"
else
    fail "'-h' works as alias for --help" "rc=$rc_h"
fi

# ===========================================================================
# CLI: --offline mode creates sample files
# ===========================================================================
section "CLI: --offline mode"

TMPDIR_TEST=$(mktemp -d)
set +e
output=$(bash "$DOWNLOAD_SCRIPT" --offline --samples-dir "$TMPDIR_TEST/samples" 2>&1)
rc=$?
set -e

if [[ $rc -eq 0 ]]; then
    pass "'--offline --samples-dir <tmp>' exits 0"
else
    fail "'--offline --samples-dir <tmp>' exits 0" "Exit code: $rc, Output: $output"
fi

# Check that offline mode created the expected subdirectories
if [[ -d "$TMPDIR_TEST/samples/pcaps" ]]; then
    pass "--offline creates pcaps/ subdirectory"
else
    fail "--offline creates pcaps/ subdirectory" "Dir not found"
fi

if [[ -d "$TMPDIR_TEST/samples/memory" ]]; then
    pass "--offline creates memory/ subdirectory"
else
    fail "--offline creates memory/ subdirectory" "Dir not found"
fi

if [[ -d "$TMPDIR_TEST/samples/firmware" ]]; then
    pass "--offline creates firmware/ subdirectory"
else
    fail "--offline creates firmware/ subdirectory" "Dir not found"
fi

if [[ -d "$TMPDIR_TEST/samples/logs" ]]; then
    pass "--offline creates logs/ subdirectory"
else
    fail "--offline creates logs/ subdirectory" "Dir not found"
fi

# Check that actual files were created (not just directories)
pcap_count=$(find "$TMPDIR_TEST/samples/pcaps" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$pcap_count" -gt 0 ]]; then
    pass "--offline creates pcap sample file(s) ($pcap_count files)"
else
    fail "--offline creates pcap sample file(s)" "No files in pcaps/"
fi

memory_count=$(find "$TMPDIR_TEST/samples/memory" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$memory_count" -gt 0 ]]; then
    pass "--offline creates memory sample file(s) ($memory_count files)"
else
    fail "--offline creates memory sample file(s)" "No files in memory/"
fi

firmware_count=$(find "$TMPDIR_TEST/samples/firmware" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$firmware_count" -gt 0 ]]; then
    pass "--offline creates firmware sample file(s) ($firmware_count files)"
else
    fail "--offline creates firmware sample file(s)" "No files in firmware/"
fi

logs_count=$(find "$TMPDIR_TEST/samples/logs" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$logs_count" -gt 0 ]]; then
    pass "--offline creates log sample file(s) ($logs_count files)"
else
    fail "--offline creates log sample file(s)" "No files in logs/"
fi

# ===========================================================================
# CLI: default --samples-dir
# ===========================================================================
section "CLI: Default --samples-dir"

# The script should default to data/samples when --samples-dir is not given.
# We test by parsing --help output or grep the source for the default.
if grep -q 'data/samples' "$DOWNLOAD_SCRIPT" 2>/dev/null; then
    pass "Script references default data/samples directory"
else
    fail "Script references default data/samples directory" "Default not found in source"
fi

# ===========================================================================
# CLI: unknown argument
# ===========================================================================
section "CLI: Unknown argument"

set +e
output=$(bash "$DOWNLOAD_SCRIPT" --nonexistent-flag 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "'--nonexistent-flag' exits non-zero"
else
    fail "'--nonexistent-flag' exits non-zero" "Exit code: $rc (expected non-zero)"
fi

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    set +e
    sc_output=$(shellcheck "$DOWNLOAD_SCRIPT" 2>&1)
    sc_rc=$?
    set -e
    if [[ $sc_rc -eq 0 ]]; then
        pass "ShellCheck passes on download-samples.sh"
    else
        fail "ShellCheck passes on download-samples.sh" "$sc_output"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# SHA256SUMS file exists
# ===========================================================================
section "SHA256SUMS"

SHA256SUMS_FILE="$REPO_ROOT/data/samples/SHA256SUMS"
if [[ -f "$SHA256SUMS_FILE" ]]; then
    pass "data/samples/SHA256SUMS file exists"
else
    fail "data/samples/SHA256SUMS file exists" "Not found at $SHA256SUMS_FILE"
fi

# Verify SHA256SUMS has content (at least one line with a hash)
if [[ -f "$SHA256SUMS_FILE" ]] && grep -qE '^[0-9a-f]{64}  ' "$SHA256SUMS_FILE" 2>/dev/null; then
    pass "SHA256SUMS contains valid hash entries"
else
    fail "SHA256SUMS contains valid hash entries" "File empty or invalid format"
fi

# ===========================================================================
# Production sequence: air-gapped deployment
# ===========================================================================
section "Production Sequence: Air-Gapped Deployment"

# Simulates an air-gapped operator who:
#   1. Checks help for available options
#   2. Runs offline mode into a custom directory
#   3. Verifies the generated files exist
TMPDIR_PROD=$(mktemp -d)
set +e
r1=$(bash "$DOWNLOAD_SCRIPT" --help 2>&1); rc1=$?
r2=$(bash "$DOWNLOAD_SCRIPT" --offline --samples-dir "$TMPDIR_PROD/evidence" 2>&1); rc2=$?
set -e

# Count total files created
total_files=$(find "$TMPDIR_PROD/evidence" -type f 2>/dev/null | wc -l | tr -d ' ')

if [[ $rc1 -eq 0 ]] && echo "$r1" | grep -q 'Usage:' \
   && [[ $rc2 -eq 0 ]] \
   && [[ "$total_files" -gt 0 ]]; then
    pass "Air-gapped deployment: help + offline ($total_files files created)"
else
    fail "Air-gapped deployment sequence" "rc1=$rc1 rc2=$rc2 files=$total_files"
fi

rm -rf "$TMPDIR_PROD"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
echo "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
