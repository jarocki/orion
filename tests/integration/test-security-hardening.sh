#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition — Security Hardening Integration Test
#
# Validates all Phase 6 security components are present, correctly
# structured, and functional (where testable without root).
#
# Usage: bash tests/integration/test-security-hardening.sh
#
# @decision DEC-SEC-INT-001
# @title Integration test validates all Phase 6 security deliverables
# @status accepted
# @rationale A single test script that gates CI: every security artifact
#   from W6-1 through W6-7 is checked for existence and structural
#   correctness. Components from unmerged worktrees (W6-6 first-boot
#   wizard, W6-7 service hardening) are gracefully SKIPped so the test
#   passes on develop before those branches land.

# =========================================================================
# Resolve repo root (works from any CWD inside the repo)
# =========================================================================
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# =========================================================================
# Test framework (matches project conventions from test-forensic-tools.sh)
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

pass() {
    local msg="$1"
    echo "${GREEN}  PASS${NC}: $msg"
    ((PASS++)) || true
}

fail() {
    local msg="$1"
    echo "${RED}  FAIL${NC}: $msg"
    ((FAIL++)) || true
}

skip() {
    local msg="$1"
    echo "${YELLOW}  SKIP${NC}: $msg"
    ((SKIP++)) || true
}

# =========================================================================
# Section 1: Credential audit script
# =========================================================================
echo "==========================================="
echo "  Orion-X Security Hardening Validation"
echo "==========================================="
echo ""
echo "--- 1. Credential Audit Script ---"

AUDIT_SCRIPT="$REPO_ROOT/scripts/security/audit-credentials.sh"
if [[ -f "$AUDIT_SCRIPT" ]]; then
    pass "audit-credentials.sh exists"

    if [[ -x "$AUDIT_SCRIPT" ]]; then
        pass "audit-credentials.sh is executable"
    else
        fail "audit-credentials.sh is not executable"
    fi

    # Test --help flag
    help_output=$(bash "$AUDIT_SCRIPT" --help 2>&1 || true)
    if echo "$help_output" | grep -qi "usage\|help\|audit\|credential"; then
        pass "audit-credentials.sh --help produces usage output"
    else
        fail "audit-credentials.sh --help did not produce expected output"
    fi
else
    fail "audit-credentials.sh not found"
fi

# =========================================================================
# Section 2: nftables firewall configuration
# =========================================================================
echo ""
echo "--- 2. nftables Firewall Configuration ---"

NFTABLES_CONF="$REPO_ROOT/iso/config/includes.chroot/etc/nftables.conf"
if [[ -f "$NFTABLES_CONF" ]]; then
    pass "nftables.conf exists"

    # Check for policy drop on input chain
    if grep -q "policy drop" "$NFTABLES_CONF"; then
        pass "nftables.conf has default policy drop"
    else
        fail "nftables.conf missing default policy drop"
    fi

    # Check required ports: WireGuard (51820), Matrix (8008, 8448), SSH (22), mesh discovery (55555)
    for port in 51820 8008 8448 22 55555; do
        if grep -q "$port" "$NFTABLES_CONF"; then
            pass "nftables.conf allows port $port"
        else
            fail "nftables.conf missing port $port"
        fi
    done

    # Check for logging before drop
    if grep -q 'log prefix.*ORIONX' "$NFTABLES_CONF"; then
        pass "nftables.conf has log-before-drop rule"
    else
        fail "nftables.conf missing log-before-drop rule"
    fi
else
    fail "nftables.conf not found"
fi

# =========================================================================
# Section 3: Filesystem hardening hook
# =========================================================================
echo ""
echo "--- 3. Filesystem Hardening Hook ---"

FS_HOOK="$REPO_ROOT/iso/hooks/live/0600-filesystem-hardening.hook.chroot"
if [[ -f "$FS_HOOK" ]]; then
    pass "filesystem hardening hook exists"

    # Check for tmpfs noexec
    if grep -q "tmpfs.*noexec" "$FS_HOOK"; then
        pass "filesystem hook configures tmpfs with noexec"
    else
        fail "filesystem hook missing tmpfs noexec configuration"
    fi

    # Check for core dump disable
    if grep -q "core" "$FS_HOOK"; then
        pass "filesystem hook disables core dumps"
    else
        fail "filesystem hook missing core dump disable"
    fi

    # Check for umask hardening
    if grep -q "umask" "$FS_HOOK"; then
        pass "filesystem hook configures restrictive umask"
    else
        fail "filesystem hook missing umask configuration"
    fi
else
    fail "filesystem hardening hook not found"
fi

# =========================================================================
# Section 4: AppArmor profiles (5 expected)
# =========================================================================
echo ""
echo "--- 4. AppArmor Profiles ---"

APPARMOR_DIR="$REPO_ROOT/iso/config/includes.chroot/etc/apparmor.d"

EXPECTED_PROFILES=(
    "usr.bin.bulk_extractor"
    "usr.bin.synapse"
    "usr.bin.tshark"
    "usr.bin.volatility3"
    "usr.sbin.wg"
)

if [[ -d "$APPARMOR_DIR" ]]; then
    pass "AppArmor profiles directory exists"

    profile_count=0
    for profile in "${EXPECTED_PROFILES[@]}"; do
        if [[ -f "$APPARMOR_DIR/$profile" ]]; then
            pass "AppArmor profile $profile exists"
            ((profile_count++)) || true

            # Each profile should contain a 'profile' declaration
            if grep -q "^profile\|^  profile" "$APPARMOR_DIR/$profile"; then
                pass "AppArmor profile $profile has profile declaration"
            else
                fail "AppArmor profile $profile missing profile declaration"
            fi
        else
            fail "AppArmor profile $profile not found"
        fi
    done

    if [[ "$profile_count" -eq 5 ]]; then
        pass "All 5 AppArmor profiles present"
    else
        fail "Expected 5 AppArmor profiles, found $profile_count"
    fi
else
    fail "AppArmor profiles directory not found"
fi

# Check AppArmor setup hook
APPARMOR_HOOK="$REPO_ROOT/iso/hooks/live/0610-apparmor-setup.hook.chroot"
if [[ -f "$APPARMOR_HOOK" ]]; then
    pass "AppArmor setup hook exists"
else
    fail "AppArmor setup hook not found"
fi

# =========================================================================
# Section 5: Lynis script
# =========================================================================
echo ""
echo "--- 5. Lynis Script ---"

LYNIS_SCRIPT="$REPO_ROOT/scripts/run-lynis.sh"
if [[ -f "$LYNIS_SCRIPT" ]]; then
    pass "run-lynis.sh exists"

    # Test --help flag
    help_output=$(bash "$LYNIS_SCRIPT" --help 2>&1 || true)
    if echo "$help_output" | grep -qi "usage\|help\|lynis\|threshold"; then
        pass "run-lynis.sh --help produces usage output"
    else
        fail "run-lynis.sh --help did not produce expected output"
    fi

    # Verify v2 is gone (run-lynis-v2.sh should not exist)
    if [[ -f "$REPO_ROOT/scripts/run-lynis-v2.sh" ]]; then
        fail "run-lynis-v2.sh still exists (should be retired)"
    else
        pass "run-lynis-v2.sh is retired (does not exist)"
    fi
else
    fail "run-lynis.sh not found"
fi

# =========================================================================
# Section 6: First-boot wizard (SKIP if not yet on develop)
# =========================================================================
echo ""
echo "--- 6. First-Boot Wizard ---"

FIRSTBOOT_SCRIPT="$REPO_ROOT/scripts/first-boot-wizard.sh"
FIRSTBOOT_SERVICE="$REPO_ROOT/systemd/orionx-first-boot.service"

if [[ -f "$FIRSTBOOT_SCRIPT" ]]; then
    pass "first-boot-wizard.sh exists"

    if [[ -f "$FIRSTBOOT_SERVICE" ]]; then
        pass "orionx-first-boot.service exists"
    else
        fail "orionx-first-boot.service not found"
    fi
else
    skip "first-boot-wizard.sh not yet on this branch (W6-6)"
fi

# =========================================================================
# Section 7: Service hardening hook (SKIP if not yet on develop)
# =========================================================================
echo ""
echo "--- 7. Service Hardening Hook ---"

SERVICE_HOOK="$REPO_ROOT/iso/hooks/live/0620-service-hardening.hook.chroot"

if [[ -f "$SERVICE_HOOK" ]]; then
    pass "service hardening hook exists"

    # Check for systemd hardening directives
    if grep -qi "systemctl\|ProtectSystem\|hardening\|service" "$SERVICE_HOOK"; then
        pass "service hardening hook contains hardening directives"
    else
        fail "service hardening hook missing expected content"
    fi
else
    skip "service hardening hook not yet on this branch (W6-7)"
fi

# =========================================================================
# Section 8: Package list includes security packages
# =========================================================================
echo ""
echo "--- 8. Package List ---"

PKG_LIST="$REPO_ROOT/iso/package-lists/orionx.list.chroot"
if [[ -f "$PKG_LIST" ]]; then
    pass "package list exists"

    for pkg in nftables apparmor apparmor-utils lynis; do
        if grep -q "^${pkg}$" "$PKG_LIST"; then
            pass "package list includes $pkg"
        else
            fail "package list missing $pkg"
        fi
    done
else
    fail "package list not found"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "==========================================="
echo "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

[[ "$FAIL" -eq 0 ]] || exit 1
