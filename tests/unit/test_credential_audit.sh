#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W6-1: Credential Audit Script
#
# Verifies:
#   1. Script exists and is executable
#   2. Has proper shebang (#!/usr/bin/env bash)
#   3. Has set -euo pipefail (strict mode)
#   4. Has shellcheck shell=bash directive
#   5. --help prints usage and exits 0
#   6. Runs against project and finds 0 findings (exits 0)
#   7. Correctly excludes test files
#   8. Correctly excludes template placeholders (ORIONX_*)
#   9. ShellCheck passes on the audit script
#
# Production sequence: A CI pipeline or developer runs the credential
# audit as part of security gating before merge. The script scans
# scripts/, iso/, and docker/ directories for hardcoded credentials.
# A clean project should always exit 0 with zero findings.
#
# Usage: bash tests/unit/test_credential_audit.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

AUDIT_SCRIPT="$REPO_ROOT/scripts/security/audit-credentials.sh"

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

echo "=== W6-1: Credential Audit Script Tests ==="

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$AUDIT_SCRIPT" ]]; then
    pass "audit-credentials.sh exists"
else
    fail "audit-credentials.sh exists" "Not found at $AUDIT_SCRIPT"
    echo "FATAL: Script not found. Cannot continue."
    exit 1
fi

if [[ -x "$AUDIT_SCRIPT" ]]; then
    pass "audit-credentials.sh is executable"
else
    fail "audit-credentials.sh is executable" "chmod +x $AUDIT_SCRIPT"
fi

# ===========================================================================
# Shell modernization markers
# ===========================================================================
section "Shell Modernization"

if head -1 "$AUDIT_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is #!/usr/bin/env bash" "Got: $(head -1 "$AUDIT_SCRIPT" 2>/dev/null)"
fi

if grep -q '# shellcheck shell=bash' "$AUDIT_SCRIPT" 2>/dev/null; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Has shellcheck shell=bash directive" "Missing directive"
fi

if grep -q 'set -euo pipefail' "$AUDIT_SCRIPT" 2>/dev/null; then
    pass "Has set -euo pipefail"
else
    fail "Has set -euo pipefail" "Missing strict mode"
fi

# ===========================================================================
# Decision annotation
# ===========================================================================
section "Decision Annotation"

if grep -q '@decision DEC-SEC-AUDIT-001' "$AUDIT_SCRIPT" 2>/dev/null; then
    pass "Contains @decision DEC-SEC-AUDIT-001 annotation"
else
    fail "Contains @decision DEC-SEC-AUDIT-001 annotation" "Missing annotation"
fi

if grep -q '@status accepted' "$AUDIT_SCRIPT" 2>/dev/null; then
    pass "Decision annotation has @status accepted"
else
    fail "Decision annotation has @status accepted" "Missing @status"
fi

if grep -q '@rationale' "$AUDIT_SCRIPT" 2>/dev/null; then
    pass "Decision annotation has @rationale"
else
    fail "Decision annotation has @rationale" "Missing @rationale"
fi

# ===========================================================================
# CLI: --help
# ===========================================================================
section "CLI: --help"

set +e
output=$(bash "$AUDIT_SCRIPT" --help 2>&1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--help' exits 0"
else
    fail "'--help' exits 0" "Exit code: $rc"
fi

if echo "$output" | grep -qi 'usage'; then
    pass "'--help' shows usage information"
else
    fail "'--help' shows usage information" "Output did not contain usage"
fi

# ===========================================================================
# Run against project: expect clean exit (0 findings)
# ===========================================================================
section "Full Project Scan"

set +e
scan_output=$(bash "$AUDIT_SCRIPT" 2>&1)
scan_rc=$?
set -e

if [[ $scan_rc -eq 0 ]]; then
    pass "Audit exits 0 on clean project (no hardcoded credentials)"
else
    fail "Audit exits 0 on clean project" "Exit code: $scan_rc, Output: $scan_output"
fi

if echo "$scan_output" | grep -q 'Credential Audit'; then
    pass "Output includes audit header"
else
    fail "Output includes audit header" "Missing header in output"
fi

if echo "$scan_output" | grep -q '0 findings'; then
    pass "Reports 0 findings"
else
    fail "Reports 0 findings" "Output: $scan_output"
fi

# ===========================================================================
# Exclusion: test files are not flagged
# ===========================================================================
section "Exclusions: Test Files"

# The audit script should exclude the tests/ directory.
# Verify by checking that no test file paths appear as FINDING lines.
if echo "$scan_output" | grep -q 'FINDING.*tests/'; then
    fail "Test files are excluded from findings" "Found a FINDING referencing tests/"
else
    pass "Test files are excluded from findings"
fi

# ===========================================================================
# Exclusion: template placeholders (ORIONX_*)
# ===========================================================================
section "Exclusions: Template Placeholders"

# docker/matrix/homeserver.yaml has ORIONX_REGISTRATION_SECRET etc.
# These are template placeholders, not hardcoded credentials.
if echo "$scan_output" | grep -q 'FINDING.*homeserver.yaml'; then
    fail "Template placeholders (ORIONX_*) are excluded" "Found FINDING for homeserver.yaml"
else
    pass "Template placeholders (ORIONX_*) are excluded"
fi

# docker-compose.matrix-test.yml has labeled test secrets — should not be flagged
if echo "$scan_output" | grep -q 'FINDING.*docker-compose.matrix-test.yml'; then
    fail "Labeled docker test secrets are excluded" "Found FINDING for docker-compose.matrix-test.yml"
else
    pass "Labeled docker test secrets are excluded"
fi

# ===========================================================================
# Exclusion: the audit script itself
# ===========================================================================
section "Exclusions: Self-Exclusion"

if echo "$scan_output" | grep -q 'FINDING.*audit-credentials.sh'; then
    fail "Audit script excludes itself from findings" "Found FINDING for audit-credentials.sh"
else
    pass "Audit script excludes itself from findings"
fi

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    set +e
    sc_output=$(shellcheck "$AUDIT_SCRIPT" 2>&1)
    sc_rc=$?
    set -e
    if [[ $sc_rc -eq 0 ]]; then
        pass "ShellCheck passes on audit-credentials.sh"
    else
        fail "ShellCheck passes on audit-credentials.sh" "$sc_output"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# Production sequence: CI security gate
# ===========================================================================
section "Production Sequence: CI Security Gate"

# Simulates a CI pipeline that:
#   1. Checks help for available options
#   2. Runs the full audit
#   3. Verifies clean exit
set +e
r1=$(bash "$AUDIT_SCRIPT" --help 2>&1); rc1=$?
r2=$(bash "$AUDIT_SCRIPT" 2>&1); rc2=$?
set -e

if [[ $rc1 -eq 0 ]] && echo "$r1" | grep -qi 'usage' \
   && [[ $rc2 -eq 0 ]] \
   && echo "$r2" | grep -q '0 findings'; then
    pass "CI security gate: help + full scan passes cleanly"
else
    fail "CI security gate sequence" "rc1=$rc1 rc2=$rc2"
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
