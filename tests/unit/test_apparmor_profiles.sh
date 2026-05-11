#!/usr/bin/env bash
# shellcheck shell=bash
#
# Test suite for AppArmor profiles and boot integration (W6-4)
#
# Validates that all AppArmor profile files exist, contain required
# directives, and that the live-build hook properly enables AppArmor.
# Structural validation only — no chroot or AppArmor runtime needed.
#
# @decision DEC-SEC-002
# @title Structural unit tests for AppArmor profiles
# @status accepted
# @rationale AppArmor profiles ship as static files in the ISO.
#   We validate them structurally: correct includes, expected allow/deny
#   rules, decision annotations, and ShellCheck-clean hook script.
#   This catches regressions without requiring a full ISO build cycle.
#
# Usage: bash tests/unit/test_apparmor_profiles.sh

set -euo pipefail

# --- Test framework (consistent with test_firewall_config.sh) ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Resolve project root (this script lives in tests/unit/)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass() {
    (( TESTS_PASSED++ )) || true
    (( TESTS_RUN++ )) || true
    echo "  PASS: $1"
}

fail() {
    (( TESTS_FAILED++ )) || true
    (( TESTS_RUN++ )) || true
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

assert_file_exists() {
    local file="$1"
    local desc="${2:-$file exists}"
    if [[ -f "$PROJECT_ROOT/$file" ]]; then
        pass "$desc"
    else
        fail "$desc" "File not found: $file"
    fi
}

assert_file_executable() {
    local file="$1"
    local desc="${2:-$file is executable}"
    if [[ -x "$PROJECT_ROOT/$file" ]]; then
        pass "$desc"
    else
        fail "$desc" "File not executable: $file"
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local desc="${3:-$file contains '$pattern'}"
    if grep -qE "$pattern" "$PROJECT_ROOT/$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc" "Pattern not found in $file: $pattern"
    fi
}

# ============================================================
# Profile paths
# ============================================================
PROFILES_DIR="iso/config/includes.chroot/etc/apparmor.d"
SYNAPSE_PROFILE="$PROFILES_DIR/usr.bin.synapse"
WIREGUARD_PROFILE="$PROFILES_DIR/usr.sbin.wg"
VOLATILITY_PROFILE="$PROFILES_DIR/usr.bin.volatility3"
BULKEXT_PROFILE="$PROFILES_DIR/usr.bin.bulk_extractor"
TSHARK_PROFILE="$PROFILES_DIR/usr.bin.tshark"
HOOK_FILE="iso/config/hooks/live/0610-apparmor-setup.hook.chroot"
PACKAGE_LIST="iso/package-lists/orionx.list.chroot"

# ============================================================
# Test Group 1: Profile files exist
# ============================================================
echo "=== Test Group 1: Profile File Existence ==="

assert_file_exists "$SYNAPSE_PROFILE" "Synapse profile exists"
assert_file_exists "$WIREGUARD_PROFILE" "WireGuard profile exists"
assert_file_exists "$VOLATILITY_PROFILE" "Volatility3 profile exists"
assert_file_exists "$BULKEXT_PROFILE" "bulk_extractor profile exists"
assert_file_exists "$TSHARK_PROFILE" "tshark profile exists"

# ============================================================
# Test Group 2: All profiles include tunables/global
# ============================================================
echo ""
echo "=== Test Group 2: tunables/global Include ==="

assert_file_contains "$SYNAPSE_PROFILE" "#include <tunables/global>" \
    "Synapse profile includes tunables/global"
assert_file_contains "$WIREGUARD_PROFILE" "#include <tunables/global>" \
    "WireGuard profile includes tunables/global"
assert_file_contains "$VOLATILITY_PROFILE" "#include <tunables/global>" \
    "Volatility3 profile includes tunables/global"
assert_file_contains "$BULKEXT_PROFILE" "#include <tunables/global>" \
    "bulk_extractor profile includes tunables/global"
assert_file_contains "$TSHARK_PROFILE" "#include <tunables/global>" \
    "tshark profile includes tunables/global"

# ============================================================
# Test Group 3: Synapse profile rules
# ============================================================
echo ""
echo "=== Test Group 3: Synapse Profile Rules ==="

assert_file_contains "$SYNAPSE_PROFILE" "/etc/matrix-synapse/.*r," \
    "Synapse profile allows /etc/matrix-synapse read"
assert_file_contains "$SYNAPSE_PROFILE" "deny /home/.*rw," \
    "Synapse profile denies /home"
assert_file_contains "$SYNAPSE_PROFILE" "network inet tcp," \
    "Synapse profile allows inet tcp"
assert_file_contains "$SYNAPSE_PROFILE" "/var/lib/matrix-synapse/.*rw," \
    "Synapse profile allows /var/lib/matrix-synapse rw"
assert_file_contains "$SYNAPSE_PROFILE" "/var/log/matrix-synapse/.*rw," \
    "Synapse profile allows /var/log/matrix-synapse rw"

# ============================================================
# Test Group 4: WireGuard profile rules
# ============================================================
echo ""
echo "=== Test Group 4: WireGuard Profile Rules ==="

assert_file_contains "$WIREGUARD_PROFILE" "capability net_admin," \
    "WireGuard profile has capability net_admin"
assert_file_contains "$WIREGUARD_PROFILE" "capability net_raw," \
    "WireGuard profile has capability net_raw"
assert_file_contains "$WIREGUARD_PROFILE" "/etc/wireguard/.*rw," \
    "WireGuard profile allows /etc/wireguard rw"
assert_file_contains "$WIREGUARD_PROFILE" "deny /home/.*rw," \
    "WireGuard profile denies /home"

# ============================================================
# Test Group 5: Volatility3 profile rules
# ============================================================
echo ""
echo "=== Test Group 5: Volatility3 Profile Rules ==="

assert_file_contains "$VOLATILITY_PROFILE" "deny network," \
    "Volatility3 profile denies network"
assert_file_contains "$VOLATILITY_PROFILE" "/opt/orionx/data/.*r," \
    "Volatility3 profile allows /opt/orionx/data read"
assert_file_contains "$VOLATILITY_PROFILE" "/home/orionx/Analysis/.*rw," \
    "Volatility3 profile allows /home/orionx/Analysis rw"

# ============================================================
# Test Group 6: bulk_extractor profile rules
# ============================================================
echo ""
echo "=== Test Group 6: bulk_extractor Profile Rules ==="

assert_file_contains "$BULKEXT_PROFILE" "deny network," \
    "bulk_extractor profile denies network"
assert_file_contains "$BULKEXT_PROFILE" "/opt/orionx/data/.*r," \
    "bulk_extractor profile allows /opt/orionx/data read"
assert_file_contains "$BULKEXT_PROFILE" "/home/orionx/Analysis/.*rw," \
    "bulk_extractor profile allows /home/orionx/Analysis rw"

# ============================================================
# Test Group 7: tshark profile rules
# ============================================================
echo ""
echo "=== Test Group 7: tshark Profile Rules ==="

assert_file_contains "$TSHARK_PROFILE" "network packet raw," \
    "tshark profile allows network packet raw"
assert_file_contains "$TSHARK_PROFILE" "capability net_raw," \
    "tshark profile has capability net_raw"
assert_file_contains "$TSHARK_PROFILE" "capability net_admin," \
    "tshark profile has capability net_admin"
assert_file_contains "$TSHARK_PROFILE" "/opt/orionx/data/.*r," \
    "tshark profile allows /opt/orionx/data read"
assert_file_contains "$TSHARK_PROFILE" "deny /home/.*w," \
    "tshark profile denies /home write"

# ============================================================
# Test Group 8: Package list includes AppArmor packages
# ============================================================
echo ""
echo "=== Test Group 8: Package List ==="

assert_file_contains "$PACKAGE_LIST" "^apparmor$" \
    "Package list includes apparmor"
assert_file_contains "$PACKAGE_LIST" "^apparmor-utils$" \
    "Package list includes apparmor-utils"
assert_file_contains "$PACKAGE_LIST" "^apparmor-profiles$" \
    "Package list includes apparmor-profiles"
assert_file_contains "$PACKAGE_LIST" "^apparmor-profiles-extra$" \
    "Package list includes apparmor-profiles-extra"

# ============================================================
# Test Group 9: Live-build hook
# ============================================================
echo ""
echo "=== Test Group 9: Live-Build Hook ==="

assert_file_exists "$HOOK_FILE" "AppArmor setup hook exists"
assert_file_executable "$HOOK_FILE" "AppArmor setup hook is executable"
assert_file_contains "$HOOK_FILE" "systemctl enable apparmor" \
    "Hook enables apparmor service"
assert_file_contains "$HOOK_FILE" "apparmor=1" \
    "Hook adds apparmor=1 boot parameter"
assert_file_contains "$HOOK_FILE" "security=apparmor" \
    "Hook adds security=apparmor boot parameter"
assert_file_contains "$HOOK_FILE" "set -euo pipefail" \
    "Hook has strict mode"
assert_file_contains "$HOOK_FILE" "#!/usr/bin/env bash" \
    "Hook has correct shebang"

# ============================================================
# Test Group 10: @decision DEC-SEC-002 annotations
# ============================================================
echo ""
echo "=== Test Group 10: Decision Annotations ==="

assert_file_contains "$SYNAPSE_PROFILE" "@decision DEC-SEC-002" \
    "Synapse profile has @decision DEC-SEC-002"
assert_file_contains "$HOOK_FILE" "@decision DEC-SEC-002" \
    "Hook has @decision DEC-SEC-002"

# ============================================================
# Test Group 11: ShellCheck on hook
# ============================================================
echo ""
echo "=== Test Group 11: ShellCheck ==="

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$PROJECT_ROOT/$HOOK_FILE" 2>&1; then
        pass "ShellCheck passes on hook"
    else
        fail "ShellCheck passes on hook" "ShellCheck reported issues"
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
echo "============================================"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
