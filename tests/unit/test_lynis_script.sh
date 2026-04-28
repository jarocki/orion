#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W6-5: Modernize run-lynis.sh, retire run-lynis-v2.sh
#
# Verifies:
#   1. Script exists and is executable
#   2. Has #!/usr/bin/env bash shebang
#   3. Has set -euo pipefail strict mode
#   4. Has shellcheck shell=bash directive
#   5. Has @decision DEC-SEC-005 annotation
#   6. --help prints usage and exits 0
#   7. --threshold accepts numeric argument
#   8. --json flag accepted
#   9. --quick flag accepted
#  10. run-lynis-v2.sh no longer exists
#  11. ShellCheck passes
#  12. Makefile has lynis target
#
# Production sequence: A CI pipeline runs `run-lynis.sh --threshold 75 --json`
# to get a machine-readable security audit summary. If the hardening index
# falls below 75, the script exits non-zero, failing the CI gate. In manual
# usage, an operator runs `run-lynis.sh --quick` for a fast check. These tests
# verify CLI argument parsing, help output, and structural correctness without
# requiring Lynis to be installed.
#
# Usage: bash tests/unit/test_lynis_script.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LYNIS_SCRIPT="$REPO_ROOT/scripts/run-lynis.sh"
LYNIS_V2_SCRIPT="$REPO_ROOT/scripts/run-lynis-v2.sh"
MAKEFILE="$REPO_ROOT/Makefile"

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

echo "=== W6-5: run-lynis.sh Modernization Tests ==="

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$LYNIS_SCRIPT" ]]; then
    pass "run-lynis.sh exists"
else
    fail "run-lynis.sh exists" "Not found at $LYNIS_SCRIPT"
    echo "FATAL: Script not found. Cannot continue."
    exit 1
fi

if [[ -x "$LYNIS_SCRIPT" ]]; then
    pass "run-lynis.sh is executable"
else
    fail "run-lynis.sh is executable" "chmod +x $LYNIS_SCRIPT"
fi

# ===========================================================================
# run-lynis-v2.sh retirement
# ===========================================================================
section "V2 Script Retirement"

if [[ ! -f "$LYNIS_V2_SCRIPT" ]]; then
    pass "run-lynis-v2.sh no longer exists"
else
    fail "run-lynis-v2.sh no longer exists" "Still present at $LYNIS_V2_SCRIPT"
fi

# ===========================================================================
# Shell modernization markers
# ===========================================================================
section "Shell Modernization"

if head -1 "$LYNIS_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is #!/usr/bin/env bash" "Got: $(head -1 "$LYNIS_SCRIPT" 2>/dev/null)"
fi

if grep -q '# shellcheck shell=bash' "$LYNIS_SCRIPT" 2>/dev/null; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Has shellcheck shell=bash directive" "Missing directive"
fi

if grep -q 'set -euo pipefail' "$LYNIS_SCRIPT" 2>/dev/null; then
    pass "Has set -euo pipefail"
else
    fail "Has set -euo pipefail" "Missing strict mode"
fi

if ! grep -q 'v1\.5\.5' "$LYNIS_SCRIPT" 2>/dev/null; then
    pass "No v1.5.5 references remain"
else
    fail "No v1.5.5 references remain" "Found v1.5.5 in script"
fi

if grep -q 'v2\.0\.0' "$LYNIS_SCRIPT" 2>/dev/null; then
    pass "Contains v2.0.0 version"
else
    fail "Contains v2.0.0 version" "Missing v2.0.0 reference"
fi

# ===========================================================================
# Decision annotation
# ===========================================================================
section "Decision Annotation"

if grep -q '@decision DEC-SEC-005' "$LYNIS_SCRIPT" 2>/dev/null; then
    pass "Contains @decision DEC-SEC-005 annotation"
else
    fail "Contains @decision DEC-SEC-005 annotation" "Missing annotation"
fi

if grep -q '@status accepted' "$LYNIS_SCRIPT" 2>/dev/null; then
    pass "Decision annotation has @status accepted"
else
    fail "Decision annotation has @status accepted" "Missing @status"
fi

if grep -q '@rationale' "$LYNIS_SCRIPT" 2>/dev/null; then
    pass "Decision annotation has @rationale"
else
    fail "Decision annotation has @rationale" "Missing @rationale"
fi

# ===========================================================================
# CLI: --help
# ===========================================================================
section "CLI: --help"

set +e
output=$(bash "$LYNIS_SCRIPT" --help 2>&1)
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

if echo "$output" | grep -q -- '--profile'; then
    pass "'--help' documents --profile"
else
    fail "'--help' documents --profile" "Missing --profile in help"
fi

if echo "$output" | grep -q -- '--output-dir'; then
    pass "'--help' documents --output-dir"
else
    fail "'--help' documents --output-dir" "Missing --output-dir in help"
fi

if echo "$output" | grep -q -- '--quick'; then
    pass "'--help' documents --quick"
else
    fail "'--help' documents --quick" "Missing --quick in help"
fi

if echo "$output" | grep -q -- '--threshold'; then
    pass "'--help' documents --threshold"
else
    fail "'--help' documents --threshold" "Missing --threshold in help"
fi

if echo "$output" | grep -q -- '--json'; then
    pass "'--help' documents --json"
else
    fail "'--help' documents --json" "Missing --json in help"
fi

# Also test -h
set +e
output_h=$(bash "$LYNIS_SCRIPT" -h 2>&1)
rc_h=$?
set -e
if [[ $rc_h -eq 0 ]] && echo "$output_h" | grep -q 'Usage:'; then
    pass "'-h' works as alias for --help"
else
    fail "'-h' works as alias for --help" "rc=$rc_h"
fi

# ===========================================================================
# CLI: --threshold accepts numeric argument
# ===========================================================================
section "CLI: --threshold argument"

# --threshold should be accepted as a valid flag (script will skip if lynis
# is not installed, but should not fail on argument parsing)
set +e
output=$(bash "$LYNIS_SCRIPT" --threshold 80 2>&1)
rc=$?
set -e
# With no Lynis installed, the script should exit 0 gracefully (skip mode)
# The key test: it should NOT fail due to bad argument parsing
if [[ $rc -eq 0 ]]; then
    pass "'--threshold 80' accepted (exits 0, lynis not installed = skip)"
else
    # If Lynis IS installed, any non-zero exit could be a real audit failure,
    # not a parsing failure. Check for parsing-related error messages.
    if echo "$output" | grep -qi 'unknown option\|invalid\|unrecognized'; then
        fail "'--threshold 80' accepted" "Argument parsing error: $output"
    else
        pass "'--threshold 80' accepted (non-zero exit likely from audit, not parsing)"
    fi
fi

# ===========================================================================
# CLI: --json flag accepted
# ===========================================================================
section "CLI: --json flag"

set +e
output=$(bash "$LYNIS_SCRIPT" --json 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--json' accepted (exits 0, lynis not installed = skip)"
else
    if echo "$output" | grep -qi 'unknown option\|invalid\|unrecognized'; then
        fail "'--json' accepted" "Argument parsing error: $output"
    else
        pass "'--json' accepted (non-zero exit likely from audit, not parsing)"
    fi
fi

# ===========================================================================
# CLI: --quick flag accepted
# ===========================================================================
section "CLI: --quick flag"

set +e
output=$(bash "$LYNIS_SCRIPT" --quick 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--quick' accepted (exits 0, lynis not installed = skip)"
else
    if echo "$output" | grep -qi 'unknown option\|invalid\|unrecognized'; then
        fail "'--quick' accepted" "Argument parsing error: $output"
    else
        pass "'--quick' accepted (non-zero exit likely from audit, not parsing)"
    fi
fi

# ===========================================================================
# CLI: unknown argument rejected
# ===========================================================================
section "CLI: Unknown argument"

set +e
output=$(bash "$LYNIS_SCRIPT" --nonexistent-flag 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "'--nonexistent-flag' exits non-zero"
else
    fail "'--nonexistent-flag' exits non-zero" "Exit code: $rc (expected non-zero)"
fi

# ===========================================================================
# CLI: combined flags accepted
# ===========================================================================
section "CLI: Combined flags"

set +e
output=$(bash "$LYNIS_SCRIPT" --quick --threshold 60 --json 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--quick --threshold 60 --json' accepted together"
else
    if echo "$output" | grep -qi 'unknown option\|invalid\|unrecognized'; then
        fail "'--quick --threshold 60 --json' accepted together" "Parsing error: $output"
    else
        pass "'--quick --threshold 60 --json' accepted (non-zero from audit, not parsing)"
    fi
fi

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    set +e
    sc_output=$(shellcheck "$LYNIS_SCRIPT" 2>&1)
    sc_rc=$?
    set -e
    if [[ $sc_rc -eq 0 ]]; then
        pass "ShellCheck passes on run-lynis.sh"
    else
        fail "ShellCheck passes on run-lynis.sh" "$sc_output"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# Makefile lynis target
# ===========================================================================
section "Makefile Integration"

if [[ -f "$MAKEFILE" ]]; then
    if grep -q '^lynis:' "$MAKEFILE" 2>/dev/null; then
        pass "Makefile has lynis target"
    else
        fail "Makefile has lynis target" "No 'lynis:' target found in Makefile"
    fi

    if grep -q '\.PHONY.*lynis' "$MAKEFILE" 2>/dev/null; then
        pass "lynis target is declared .PHONY"
    else
        fail "lynis target is declared .PHONY" "Missing .PHONY declaration"
    fi

    if grep -q 'run-lynis.sh' "$MAKEFILE" 2>/dev/null; then
        pass "Makefile lynis target references run-lynis.sh"
    else
        fail "Makefile lynis target references run-lynis.sh" "Missing script reference"
    fi

    if grep -q -- '--threshold' "$MAKEFILE" 2>/dev/null; then
        pass "Makefile lynis target uses --threshold flag"
    else
        fail "Makefile lynis target uses --threshold flag" "Missing --threshold in Makefile"
    fi
else
    fail "Makefile exists" "Not found at $MAKEFILE"
fi

# ===========================================================================
# Production sequence: CI pipeline gate
# ===========================================================================
section "Production Sequence: CI Pipeline Gate"

# Simulates a CI pipeline that:
#   1. Checks help to verify the script interface
#   2. Runs with --threshold and --json for machine-readable output
#   3. Expects graceful skip when Lynis is not installed
set +e
r1=$(bash "$LYNIS_SCRIPT" --help 2>&1); rc1=$?
r2=$(bash "$LYNIS_SCRIPT" --threshold 75 --json 2>&1); rc2=$?
set -e

if [[ $rc1 -eq 0 ]] && echo "$r1" | grep -q 'Usage:' \
   && [[ $rc2 -eq 0 ]]; then
    pass "CI pipeline: help + threshold+json (graceful skip without Lynis)"
else
    # If lynis IS installed, rc2 may be non-zero from audit; still valid
    if [[ $rc1 -eq 0 ]] && echo "$r1" | grep -q 'Usage:'; then
        pass "CI pipeline: help works, audit ran (lynis may be installed)"
    else
        fail "CI pipeline sequence" "rc1=$rc1 rc2=$rc2"
    fi
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
