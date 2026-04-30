#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for Orion-X Phase 3 mesh CLI skeleton (orionx-mesh).
#
# Tests verify:
# - CLI script exists and is executable
# - ShellCheck passes on all mesh scripts
# - Help output matches expected format
# - Subcommand routing works correctly
# - Root check is present (tested via grep, not by running as root)
# - Status command shows "Mesh: inactive" when no mesh is active
# - Unknown commands produce error + usage and exit non-zero
# - Global flags are parsed (--help, --verbose, --config)
# - mesh-lib.sh stub exists and is ShellCheck clean
#
# Production sequence: An incident responder boots Orion-X, opens a terminal,
# and runs `orionx-mesh status` to check if a mesh is active, then
# `orionx-mesh join` to create or join one. These tests exercise that
# real-world sequence.
#
# Usage: bash tests/unit/test_mesh_cli.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CLI_SCRIPT="$REPO_ROOT/scripts/mesh/orionx-mesh"
MESH_LIB="$REPO_ROOT/scripts/mesh/mesh-lib.sh"

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
    ((PASS+=1))
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    ((FAIL+=1))
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

skip() {
    ((SKIP+=1))
    echo "${YELLOW}  SKIP${NC}: $1 — $2"
}

run_cli() {
    # Run CLI with root check bypassed for testing
    ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" "$@" 2>&1
}


section() {
    echo ""
    echo "--- $1 ---"
}

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$CLI_SCRIPT" ]]; then
    pass "CLI script exists"
else
    fail "CLI script exists" "Not found at $CLI_SCRIPT"
fi

if [[ -x "$CLI_SCRIPT" ]]; then
    pass "CLI script is executable"
else
    fail "CLI script is executable" "chmod +x $CLI_SCRIPT"
fi

if head -1 "$CLI_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "CLI script has bash shebang"
else
    fail "CLI script has bash shebang" "Expected #!/usr/bin/env bash"
fi

if [[ -f "$MESH_LIB" ]]; then
    pass "mesh-lib.sh exists"
else
    fail "mesh-lib.sh exists" "Not found at $MESH_LIB"
fi

if grep -q 'set -euo pipefail' "$CLI_SCRIPT" 2>/dev/null; then
    pass "CLI has strict mode (set -euo pipefail)"
else
    fail "CLI has strict mode" "Missing 'set -euo pipefail'"
fi

if grep -q '# shellcheck shell=bash' "$CLI_SCRIPT" 2>/dev/null; then
    pass "CLI has shellcheck directive"
else
    fail "CLI has shellcheck directive" "Missing '# shellcheck shell=bash'"
fi

if grep -q '@decision DEC-MESH-004' "$CLI_SCRIPT" 2>/dev/null; then
    pass "CLI has @decision DEC-MESH-004"
else
    fail "CLI has @decision DEC-MESH-004" "Missing annotation"
fi

if grep -q 'mesh-lib.sh' "$CLI_SCRIPT" 2>/dev/null; then
    pass "CLI sources mesh-lib.sh"
else
    fail "CLI sources mesh-lib.sh" "No reference to mesh-lib.sh"
fi

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck &>/dev/null; then
    if shellcheck "$CLI_SCRIPT" 2>&1; then
        pass "ShellCheck passes on orionx-mesh"
    else
        fail "ShellCheck passes on orionx-mesh" "See errors above"
    fi

    if shellcheck "$MESH_LIB" 2>&1; then
        pass "ShellCheck passes on mesh-lib.sh"
    else
        fail "ShellCheck passes on mesh-lib.sh" "See errors above"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# Help / Usage output
# ===========================================================================
section "Help Output"

output=$(run_cli help)
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "'help' exits 0"
else
    fail "'help' exits 0" "Exit code: $rc"
fi

if echo "$output" | grep -q 'Usage: orionx-mesh'; then
    pass "'help' shows usage"
else
    fail "'help' shows usage" "Missing 'Usage: orionx-mesh'"
fi

output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" --help 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && echo "$output" | grep -q 'Usage: orionx-mesh'; then
    pass "'--help' flag works"
else
    fail "'--help' flag works" "rc=$rc output=$output"
fi

output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" -h 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && echo "$output" | grep -q 'Usage: orionx-mesh'; then
    pass "'-h' flag works"
else
    fail "'-h' flag works" "rc=$rc output=$output"
fi

output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && echo "$output" | grep -q 'Usage: orionx-mesh'; then
    pass "No args shows usage"
else
    fail "No args shows usage" "rc=$rc"
fi

output=$(run_cli help)
if echo "$output" | grep -q 'v2.0.0'; then
    pass "Help shows version"
else
    fail "Help shows version" "Missing v2.0.0"
fi

for cmd in join status peers leave help; do
    if echo "$output" | grep -q "$cmd"; then
        pass "Help lists '$cmd' command"
    else
        fail "Help lists '$cmd' command" "Missing from help output"
    fi
done

for opt in '--config' '--verbose' '--help'; do
    if echo "$output" | grep -q -- "$opt"; then
        pass "Help lists '$opt' option"
    else
        fail "Help lists '$opt' option" "Missing from help output"
    fi
done

if echo "$output" | grep -q 'Examples:'; then
    pass "Help has examples section"
else
    fail "Help has examples section" "Missing 'Examples:'"
fi

# ===========================================================================
# Subcommand routing
# ===========================================================================
section "Subcommand Routing"

output=$(run_cli status)
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "'status' exits 0"
else
    fail "'status' exits 0" "Exit code: $rc"
fi

if echo "$output" | grep -qi 'inactive'; then
    pass "'status' shows inactive"
else
    fail "'status' shows inactive" "Output: $output"
fi

# join now attempts real WireGuard setup; without WG it fails gracefully
set +e
output=$(run_cli join)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "'join' fails gracefully without WireGuard"
else
    fail "'join' fails gracefully without WireGuard" "Exit code was 0 (expected non-zero)"
fi

if echo "$output" | grep -qi 'error\|permission denied'; then
    pass "'join' shows error message"
else
    fail "'join' shows error message" "Output: $output"
fi

output=$(run_cli leave)
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "'leave' exits 0 (stub)"
else
    fail "'leave' exits 0 (stub)" "Exit code: $rc"
fi

if echo "$output" | grep -qi 'not in a mesh'; then
    pass "'leave' shows not-in-mesh message"
else
    fail "'leave' shows not-in-mesh message" "Output: $output"
fi

# peers with no active mesh should exit non-zero
set +e
output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" peers 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "'peers' exits non-zero when no mesh"
else
    fail "'peers' exits non-zero when no mesh" "Exit code was 0"
fi

if echo "$output" | grep -qi 'not in a mesh\|not active'; then
    pass "'peers' shows 'not in a mesh' message"
else
    fail "'peers' shows 'not in a mesh' message" "Output: $output"
fi

# Unknown command
set +e
output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" unknown-cmd 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "Unknown command exits non-zero"
else
    fail "Unknown command exits non-zero" "Exit code was 0"
fi

if echo "$output" | grep -qi 'unknown\|unknown-cmd'; then
    pass "Unknown command shows error"
else
    fail "Unknown command shows error" "Output: $output"
fi

if echo "$output" | grep -q 'Usage:'; then
    pass "Unknown command shows usage"
else
    fail "Unknown command shows usage" "Missing Usage: in output"
fi

# ===========================================================================
# Global flags
# ===========================================================================
section "Global Flags"

output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" --verbose status 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "'--verbose status' accepted"
else
    fail "'--verbose status' accepted" "Exit: $rc Output: $output"
fi

output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" -v status 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "'-v status' accepted"
else
    fail "'-v status' accepted" "Exit: $rc Output: $output"
fi

output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" --config /tmp/test.conf status 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "'--config <file> status' accepted"
else
    fail "'--config <file> status' accepted" "Exit: $rc Output: $output"
fi

output=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" --help status 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && echo "$output" | grep -q 'Usage:'; then
    pass "'--help status' shows help instead of running status"
else
    fail "'--help status' shows help" "Exit: $rc Output: $output"
fi

# ===========================================================================
# Root check (structural)
# ===========================================================================
section "Root Check"

if grep -q 'EUID' "$CLI_SCRIPT" 2>/dev/null || grep -q 'id -u' "$CLI_SCRIPT" 2>/dev/null; then
    pass "Root check present (EUID or id -u)"
else
    fail "Root check present" "Missing EUID/id -u check"
fi

if grep -q 'ORIONX_SKIP_ROOT_CHECK' "$CLI_SCRIPT" 2>/dev/null; then
    pass "Test bypass env var present"
else
    fail "Test bypass env var present" "Missing ORIONX_SKIP_ROOT_CHECK"
fi

# ===========================================================================
# Production sequence: responder workflow
# ===========================================================================
section "Production Sequence"

# Full workflow: status → help → join → status
# join now attempts real WireGuard setup and fails without it (non-zero exit)
r1=$(run_cli status); rc1=$?
r2=$(run_cli help); rc2=$?
set +e
_r3=$(run_cli join); rc3=$?
set -e
r4=$(run_cli status); rc4=$?

if [[ $rc1 -eq 0 ]] && echo "$r1" | grep -qi 'inactive' \
   && [[ $rc2 -eq 0 ]] && echo "$r2" | grep -q 'join' \
   && [[ $rc3 -ne 0 ]]  \
   && [[ $rc4 -eq 0 ]] && echo "$r4" | grep -qi 'inactive'; then
    pass "Responder workflow: status→help→join(fail-no-WG)→status"
else
    fail "Responder workflow" "rc1=$rc1 rc2=$rc2 rc3=$rc3 rc4=$rc4"
fi

# Typo recovery: bad cmd → help displayed → correct cmd (join fails without WG but routes correctly)
set +e
r1=$(ORIONX_SKIP_ROOT_CHECK=1 bash "$CLI_SCRIPT" joinn 2>&1); rc1=$?
r2=$(run_cli join); rc2=$?
set -e
if [[ $rc1 -ne 0 ]] && echo "$r1" | grep -q 'Usage:' \
   && [[ $rc2 -ne 0 ]]; then
    pass "Typo recovery: bad cmd→usage→correct cmd(routes to join)"
else
    fail "Typo recovery" "rc1=$rc1 rc2=$rc2"
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
