#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W1-2: Modernize setup-matrix.sh
#
# Verifies:
#   1. Script exists and is executable
#   2. Has #!/usr/bin/env bash shebang
#   3. Has set -euo pipefail
#   4. Has shellcheck shell=bash directive
#   5. Has @decision DEC-MATRIX-SETUP-001 annotation
#   6. --help prints usage and exits 0
#   7. Missing --mode prints error and exits non-zero
#   8. --mode server without --server-name uses default "orionx.local"
#   9. Accepts all CLI arguments without error
#  10. ShellCheck passes
#  11. No v1.5.5 references remain
#  12. Contains cross-reference to orionx-mesh
#
# Production sequence: An operator provisions a new Orion-X node for team
# collaboration by running `setup-matrix.sh --mode server --server-name ...`
# in a Dockerfile or automated deployment. These tests verify the CLI
# argument pathway works without interactive prompts, which is the primary
# use case in automated/Docker environments.
#
# Usage: bash tests/unit/test_matrix_setup.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MATRIX_SCRIPT="$REPO_ROOT/scripts/setup-matrix.sh"

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

# Helper: run the script with ORIONX_MATRIX_DRY_RUN to prevent actual system changes
run_matrix() {
    ORIONX_MATRIX_DRY_RUN=1 bash "$MATRIX_SCRIPT" "$@" 2>&1
}

run_matrix_rc() {
    ORIONX_MATRIX_DRY_RUN=1 bash "$MATRIX_SCRIPT" "$@" 2>&1
    return $?
}

echo "=== W1-2: setup-matrix.sh Modernization Tests ==="

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$MATRIX_SCRIPT" ]]; then
    pass "setup-matrix.sh exists"
else
    fail "setup-matrix.sh exists" "Not found at $MATRIX_SCRIPT"
fi

if [[ -x "$MATRIX_SCRIPT" ]]; then
    pass "setup-matrix.sh is executable"
else
    fail "setup-matrix.sh is executable" "chmod +x $MATRIX_SCRIPT"
fi

# ===========================================================================
# Shell modernization markers
# ===========================================================================
section "Shell Modernization"

if head -1 "$MATRIX_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is #!/usr/bin/env bash" "Got: $(head -1 "$MATRIX_SCRIPT" 2>/dev/null)"
fi

if grep -q '# shellcheck shell=bash' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Has shellcheck shell=bash directive" "Missing directive"
fi

if grep -q 'set -euo pipefail' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Has set -euo pipefail"
else
    fail "Has set -euo pipefail" "Missing strict mode"
fi

if ! grep -q 'v1\.5\.5' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "No v1.5.5 references remain"
else
    fail "No v1.5.5 references remain" "Found v1.5.5 in script"
fi

# ===========================================================================
# Decision annotation
# ===========================================================================
section "Decision Annotation"

if grep -q '@decision DEC-MATRIX-SETUP-001' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Contains @decision DEC-MATRIX-SETUP-001 annotation"
else
    fail "Contains @decision DEC-MATRIX-SETUP-001 annotation" "Missing annotation"
fi

# ===========================================================================
# Cross-reference to mesh
# ===========================================================================
section "Cross-references"

if grep -q 'orionx-mesh' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Contains reference to orionx-mesh"
else
    fail "Contains reference to orionx-mesh" "Missing mesh cross-reference"
fi

# ===========================================================================
# CLI argument parsing: --help
# ===========================================================================
section "CLI: --help"

set +e
output=$(run_matrix --help)
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
    fail "'--help' shows Usage:" "Output: $output"
fi

if echo "$output" | grep -q -- '--mode'; then
    pass "'--help' documents --mode"
else
    fail "'--help' documents --mode" "Output: $output"
fi

# Also test -h
set +e
output_h=$(run_matrix -h)
rc_h=$?
set -e
if [[ $rc_h -eq 0 ]] && echo "$output_h" | grep -q 'Usage:'; then
    pass "'-h' works as alias for --help"
else
    fail "'-h' works as alias for --help" "rc=$rc_h"
fi

# ===========================================================================
# CLI argument parsing: missing --mode
# ===========================================================================
section "CLI: Missing --mode"

set +e
output=$(run_matrix 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "No args exits non-zero"
else
    fail "No args exits non-zero" "Exit code: $rc (expected non-zero)"
fi

if echo "$output" | grep -qi 'mode.*required\|--mode\|usage'; then
    pass "No args shows error about missing --mode"
else
    fail "No args shows error about missing --mode" "Output: $output"
fi

# ===========================================================================
# CLI argument parsing: --mode server defaults
# ===========================================================================
section "CLI: --mode server defaults"

# In dry-run mode, server setup should accept defaults and exit cleanly
# We pass all required server args to avoid interactive prompts
set +e
output=$(run_matrix --mode server --admin-user testadmin --admin-pass testpass123)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--mode server' with args exits 0 in dry-run"
else
    fail "'--mode server' with args exits 0 in dry-run" "Exit code: $rc, Output: $output"
fi

# Verify default server-name is used when not provided
if echo "$output" | grep -q 'orionx.local'; then
    pass "Default server-name is orionx.local"
else
    fail "Default server-name is orionx.local" "Output: $output"
fi

# ===========================================================================
# CLI argument parsing: --mode server with custom server-name
# ===========================================================================
section "CLI: --mode server custom args"

set +e
output=$(run_matrix --mode server --server-name myserver.example --admin-user admin1 --admin-pass secret)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--mode server --server-name myserver.example' exits 0 in dry-run"
else
    fail "'--mode server --server-name myserver.example' exits 0 in dry-run" "Exit code: $rc"
fi

if echo "$output" | grep -q 'myserver.example'; then
    pass "Custom server-name 'myserver.example' is used"
else
    fail "Custom server-name 'myserver.example' is used" "Output: $output"
fi

# ===========================================================================
# CLI argument parsing: --mode client with all args
# ===========================================================================
section "CLI: --mode client args"

set +e
output=$(run_matrix --mode client --homeserver-url https://matrix.example.org --user-id '@test:example.org' --password secretpass)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--mode client' with all args exits 0 in dry-run"
else
    fail "'--mode client' with all args exits 0 in dry-run" "Exit code: $rc, Output: $output"
fi

# ===========================================================================
# CLI argument parsing: invalid mode
# ===========================================================================
section "CLI: Invalid mode"

set +e
output=$(run_matrix --mode invalid 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "'--mode invalid' exits non-zero"
else
    fail "'--mode invalid' exits non-zero" "Exit code: $rc"
fi

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$MATRIX_SCRIPT" 2>&1; then
        pass "ShellCheck passes on setup-matrix.sh"
    else
        fail "ShellCheck passes on setup-matrix.sh" "See errors above"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# Production sequence: automated deployment
# ===========================================================================
section "Production Sequence"

# Automated deployment: help → server setup → client setup
# This simulates a Docker build where the script is called non-interactively
set +e
r1=$(run_matrix --help); rc1=$?
r2=$(run_matrix --mode server --server-name deploy.local --admin-user deployer --admin-pass deploy123); rc2=$?
r3=$(run_matrix --mode client --homeserver-url https://deploy.local:8448 --user-id '@responder:deploy.local' --password resp123); rc3=$?
set -e

if [[ $rc1 -eq 0 ]] && echo "$r1" | grep -q 'Usage:' \
   && [[ $rc2 -eq 0 ]] \
   && [[ $rc3 -eq 0 ]]; then
    pass "Automated deployment: help→server→client (all dry-run)"
else
    fail "Automated deployment sequence" "rc1=$rc1 rc2=$rc2 rc3=$rc3"
fi

# Failure recovery: no mode → error → retry with mode
set +e
r1=$(run_matrix 2>&1); rc1=$?
r2=$(run_matrix --mode server --admin-user admin --admin-pass pass); rc2=$?
set -e
if [[ $rc1 -ne 0 ]] && [[ $rc2 -eq 0 ]]; then
    pass "Failure recovery: no-mode-error → retry with --mode succeeds"
else
    fail "Failure recovery" "rc1=$rc1 rc2=$rc2"
fi

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
