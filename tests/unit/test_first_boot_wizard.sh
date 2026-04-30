#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W6-6: First-Boot Setup Wizard
#
# Verifies:
#   1.  Script exists and is executable
#   2.  Has proper shebang (#!/usr/bin/env bash)
#   3.  Has set -euo pipefail (strict mode)
#   4.  Has shellcheck shell=bash directive
#   5.  Has @decision DEC-SEC-003 annotation
#   6.  --help prints usage and exits 0
#   7.  --non-interactive in dry-run creates flag file
#   8.  Flag file prevents re-run (idempotent)
#   9.  --hostname accepts value
#  10.  --skip-ssh flag accepted
#  11.  systemd unit file exists
#  12.  systemd unit has ConditionPathExists
#  13.  ShellCheck passes
#
# Production sequence: On first boot of an Orion-X node, systemd runs the
# wizard as a oneshot service (non-interactive). It sets hostname, generates
# credentials, writes a completion flag, and disables itself. Subsequent
# boots skip because ConditionPathExists=!/var/lib/orionx/.first-boot-done.
# In CI/test, we use ORIONX_FIRST_BOOT_DRY_RUN=1 to avoid real system calls.
#
# Usage: bash tests/unit/test_first_boot_wizard.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WIZARD_SCRIPT="$REPO_ROOT/scripts/security/first-boot-wizard.sh"
SYSTEMD_UNIT="$REPO_ROOT/systemd/orionx-first-boot.service"

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

section() {
    echo ""
    echo "--- $1 ---"
}

echo "=== W6-6: First-Boot Setup Wizard Tests ==="

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$WIZARD_SCRIPT" ]]; then
    pass "first-boot-wizard.sh exists"
else
    fail "first-boot-wizard.sh exists" "Not found at $WIZARD_SCRIPT"
    echo "FATAL: Script not found. Cannot continue."
    exit 1
fi

if [[ -x "$WIZARD_SCRIPT" ]]; then
    pass "first-boot-wizard.sh is executable"
else
    fail "first-boot-wizard.sh is executable" "chmod +x $WIZARD_SCRIPT"
fi

# ===========================================================================
# Shell modernization markers
# ===========================================================================
section "Shell Modernization"

if head -1 "$WIZARD_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is #!/usr/bin/env bash"
fi

if grep -q '# shellcheck shell=bash' "$WIZARD_SCRIPT"; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Has shellcheck shell=bash directive"
fi

if grep -q 'set -euo pipefail' "$WIZARD_SCRIPT"; then
    pass "Has set -euo pipefail (strict mode)"
else
    fail "Has set -euo pipefail (strict mode)"
fi

# ===========================================================================
# Decision annotation
# ===========================================================================
section "Decision Annotation"

if grep -q '@decision DEC-SEC-003' "$WIZARD_SCRIPT"; then
    pass "Has @decision DEC-SEC-003 annotation"
else
    fail "Has @decision DEC-SEC-003 annotation"
fi

if grep -q '@rationale' "$WIZARD_SCRIPT"; then
    pass "Has @rationale in decision block"
else
    fail "Has @rationale in decision block"
fi

# ===========================================================================
# --help flag
# ===========================================================================
section "CLI: --help"

set +e
help_output=$(bash "$WIZARD_SCRIPT" --help 2>&1)
help_rc=$?
set -e

if [[ $help_rc -eq 0 ]]; then
    pass "--help exits 0"
else
    fail "--help exits 0" "exit code: $help_rc"
fi

if echo "$help_output" | grep -qi 'usage'; then
    pass "--help prints usage text"
else
    fail "--help prints usage text" "Output: $help_output"
fi

if echo "$help_output" | grep -q '\-\-non-interactive'; then
    pass "--help mentions --non-interactive"
else
    fail "--help mentions --non-interactive"
fi

if echo "$help_output" | grep -q '\-\-hostname'; then
    pass "--help mentions --hostname"
else
    fail "--help mentions --hostname"
fi

if echo "$help_output" | grep -q '\-\-skip-ssh'; then
    pass "--help mentions --skip-ssh"
else
    fail "--help mentions --skip-ssh"
fi

# ===========================================================================
# --non-interactive in dry-run mode
# ===========================================================================
section "Non-Interactive Dry-Run"

# Create a temporary directory to hold the flag file
DRY_RUN_DIR=$(mktemp -d)
FLAG_FILE="$DRY_RUN_DIR/.first-boot-done"

# Run wizard in dry-run + non-interactive mode
set +e
wizard_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$FLAG_FILE" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
wizard_rc=$?
set -e

if [[ $wizard_rc -eq 0 ]]; then
    pass "Non-interactive dry-run exits 0"
else
    fail "Non-interactive dry-run exits 0" "exit code: $wizard_rc, output: $wizard_output"
fi

if [[ -f "$FLAG_FILE" ]]; then
    pass "Dry-run creates flag file"
else
    fail "Dry-run creates flag file" "Expected at $FLAG_FILE"
fi

# Check that summary is printed
if echo "$wizard_output" | grep -qi 'summary\|complete\|setup'; then
    pass "Dry-run prints summary"
else
    fail "Dry-run prints summary" "Output: $wizard_output"
fi

# ===========================================================================
# Idempotent: flag file prevents re-run
# ===========================================================================
section "Idempotency"

# Flag file should already exist from previous test
set +e
rerun_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$FLAG_FILE" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
rerun_rc=$?
set -e

if [[ $rerun_rc -eq 0 ]]; then
    pass "Re-run with existing flag exits 0"
else
    fail "Re-run with existing flag exits 0" "exit code: $rerun_rc"
fi

if echo "$rerun_output" | grep -qi 'already\|skip\|complet'; then
    pass "Re-run detects existing flag file"
else
    fail "Re-run detects existing flag file" "Output: $rerun_output"
fi

# Clean up first run's flag for subsequent tests
rm -f "$FLAG_FILE"

# ===========================================================================
# --hostname flag
# ===========================================================================
section "CLI: --hostname"

set +e
hostname_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$DRY_RUN_DIR/.first-boot-hostname-test" \
    bash "$WIZARD_SCRIPT" --non-interactive --hostname test-node-42 2>&1)
hostname_rc=$?
set -e

if [[ $hostname_rc -eq 0 ]]; then
    pass "--hostname flag accepted"
else
    fail "--hostname flag accepted" "exit code: $hostname_rc"
fi

if echo "$hostname_output" | grep -q 'test-node-42'; then
    pass "--hostname value appears in output"
else
    fail "--hostname value appears in output" "Output: $hostname_output"
fi

# ===========================================================================
# --skip-ssh flag
# ===========================================================================
section "CLI: --skip-ssh"

rm -f "$DRY_RUN_DIR/.first-boot-ssh-test"

set +e
ssh_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$DRY_RUN_DIR/.first-boot-ssh-test" \
    bash "$WIZARD_SCRIPT" --non-interactive --skip-ssh 2>&1)
ssh_rc=$?
set -e

if [[ $ssh_rc -eq 0 ]]; then
    pass "--skip-ssh flag accepted"
else
    fail "--skip-ssh flag accepted" "exit code: $ssh_rc"
fi

if echo "$ssh_output" | grep -qi 'ssh.*disable\|disable.*ssh\|ssh.*skip'; then
    pass "--skip-ssh referenced in output"
else
    fail "--skip-ssh referenced in output" "Output: $ssh_output"
fi

# ===========================================================================
# systemd unit file
# ===========================================================================
section "systemd Unit File"

if [[ -f "$SYSTEMD_UNIT" ]]; then
    pass "orionx-first-boot.service exists"
else
    fail "orionx-first-boot.service exists" "Not found at $SYSTEMD_UNIT"
fi

if grep -q 'ConditionPathExists=!/var/lib/orionx/.first-boot-done' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit has ConditionPathExists guard"
else
    fail "systemd unit has ConditionPathExists guard"
fi

if grep -q 'Type=oneshot' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit is Type=oneshot"
else
    fail "systemd unit is Type=oneshot"
fi

if grep -q 'multi-user.target' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit targets multi-user.target"
else
    fail "systemd unit targets multi-user.target"
fi

if grep -q 'first-boot-wizard.sh' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit references wizard script"
else
    fail "systemd unit references wizard script"
fi

if grep -q '@decision DEC-SEC-003' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit has @decision DEC-SEC-003 annotation"
else
    fail "systemd unit has @decision DEC-SEC-003 annotation"
fi

# ===========================================================================
# Production sequence: first-boot on a fresh node
# ===========================================================================
section "Production Sequence: First Boot"

# Simulates the full first-boot sequence:
#   1. No flag file exists (fresh node)
#   2. systemd invokes wizard with --non-interactive
#   3. Wizard creates flag file and prints summary
#   4. Second boot: systemd ConditionPathExists prevents re-run
#   5. Manual re-run also detects flag and skips

PROD_DIR=$(mktemp -d)
PROD_FLAG="$PROD_DIR/.first-boot-done"

# Step 1+2+3: First boot
set +e
_boot1_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$PROD_FLAG" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
boot1_rc=$?
set -e

if [[ $boot1_rc -eq 0 ]] && [[ -f "$PROD_FLAG" ]]; then
    pass "First boot: wizard runs and creates flag"
else
    fail "First boot: wizard runs and creates flag" "rc=$boot1_rc, flag exists=$(test -f "$PROD_FLAG" && echo yes || echo no)"
fi

# Step 4+5: Second boot (flag exists)
set +e
boot2_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$PROD_FLAG" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
boot2_rc=$?
set -e

if [[ $boot2_rc -eq 0 ]] && echo "$boot2_output" | grep -qi 'already\|skip\|complet'; then
    pass "Second boot: wizard detects flag and skips"
else
    fail "Second boot: wizard detects flag and skips" "rc=$boot2_rc, output: $boot2_output"
fi

# Cleanup
rm -rf "$PROD_DIR" "$DRY_RUN_DIR"

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    set +e
    sc_output=$(shellcheck "$WIZARD_SCRIPT" 2>&1)
    sc_rc=$?
    set -e
    if [[ $sc_rc -eq 0 ]]; then
        pass "ShellCheck passes on first-boot-wizard.sh"
    else
        fail "ShellCheck passes on first-boot-wizard.sh" "$sc_output"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
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
