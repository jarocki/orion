#!/usr/bin/env bash
# shellcheck shell=bash
#
# Test suite for nftables firewall configuration (W6-2)
#
# Validates that all firewall infrastructure files exist, are well-formed,
# and meet the security requirements for Orion-X Phoenix Edition.
#
# Usage: bash tests/unit/test_firewall_config.sh
#

set -euo pipefail

# --- Test framework ---
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

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local desc="${3:-$file contains \"$pattern\"}"
    if grep -qE "$pattern" "$PROJECT_ROOT/$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc" "Pattern not found in $file: $pattern"
    fi
}

# ============================================================
# Test Group 1: nftables.conf file existence and structure
# ============================================================
echo "=== Test Group 1: nftables.conf Existence ==="

NFTABLES_CONF="iso/config/includes.chroot/etc/nftables.conf"

assert_file_exists "$NFTABLES_CONF" "nftables.conf exists"

# ============================================================
# Test Group 2: nftables.conf content — ruleset structure
# ============================================================
echo ""
echo "=== Test Group 2: nftables.conf Ruleset Structure ==="

assert_file_contains "$NFTABLES_CONF" "flush ruleset" \
    "nftables.conf contains flush ruleset"

assert_file_contains "$NFTABLES_CONF" "table inet orionx_firewall" \
    "nftables.conf defines inet orionx_firewall table"

assert_file_contains "$NFTABLES_CONF" "chain input" \
    "nftables.conf defines input chain"

assert_file_contains "$NFTABLES_CONF" "chain forward" \
    "nftables.conf defines forward chain"

assert_file_contains "$NFTABLES_CONF" "chain output" \
    "nftables.conf defines output chain"

# ============================================================
# Test Group 3: nftables.conf — input chain policies and rules
# ============================================================
echo ""
echo "=== Test Group 3: Input Chain Policies and Rules ==="

assert_file_contains "$NFTABLES_CONF" "policy drop" \
    "Input chain has policy drop"

assert_file_contains "$NFTABLES_CONF" "ct state established,related accept" \
    "nftables.conf allows established/related connections"

assert_file_contains "$NFTABLES_CONF" 'iif "lo" accept' \
    "nftables.conf allows loopback"

assert_file_contains "$NFTABLES_CONF" "ip protocol icmp accept" \
    "nftables.conf allows ICMP"

assert_file_contains "$NFTABLES_CONF" "ip6 nexthdr icmpv6 accept" \
    "nftables.conf allows ICMPv6"

assert_file_contains "$NFTABLES_CONF" "udp dport 51820 accept" \
    "nftables.conf allows WireGuard port 51820"

assert_file_contains "$NFTABLES_CONF" "udp dport 55555 accept" \
    "nftables.conf allows mesh discovery port 55555"

assert_file_contains "$NFTABLES_CONF" "tcp dport.*8008.*8448" \
    "nftables.conf allows Matrix ports 8008 and 8448"

assert_file_contains "$NFTABLES_CONF" "tcp dport 22 accept" \
    "nftables.conf allows SSH port 22"

assert_file_contains "$NFTABLES_CONF" 'log prefix "\[ORIONX-DROP\]' \
    "nftables.conf contains log prefix [ORIONX-DROP]"

# ============================================================
# Test Group 4: Forward and output chain policies
# ============================================================
echo ""
echo "=== Test Group 4: Forward and Output Chain Policies ==="

# Forward chain must have policy drop
# We need to check that the forward chain specifically has policy drop
# The input chain also has policy drop, so we check contextually
if grep -A2 "chain forward" "$PROJECT_ROOT/$NFTABLES_CONF" 2>/dev/null | grep -q "policy drop"; then
    pass "Forward chain has policy drop"
else
    fail "Forward chain has policy drop" \
        "Forward chain does not contain 'policy drop'"
fi

# Output chain must have policy accept
if grep -A2 "chain output" "$PROJECT_ROOT/$NFTABLES_CONF" 2>/dev/null | grep -q "policy accept"; then
    pass "Output chain has policy accept"
else
    fail "Output chain has policy accept" \
        "Output chain does not contain 'policy accept'"
fi

# ============================================================
# Test Group 5: systemd unit file
# ============================================================
echo ""
echo "=== Test Group 5: systemd Unit File ==="

SYSTEMD_UNIT="systemd/orionx-firewall.service"

assert_file_exists "$SYSTEMD_UNIT" "orionx-firewall.service exists"

assert_file_contains "$SYSTEMD_UNIT" "ExecStart=/usr/sbin/nft -f /etc/nftables.conf" \
    "systemd unit has correct ExecStart"

assert_file_contains "$SYSTEMD_UNIT" "ExecReload=/usr/sbin/nft -f /etc/nftables.conf" \
    "systemd unit has ExecReload"

assert_file_contains "$SYSTEMD_UNIT" "ExecStop=/usr/sbin/nft flush ruleset" \
    "systemd unit has ExecStop to flush ruleset"

assert_file_contains "$SYSTEMD_UNIT" "Type=oneshot" \
    "systemd unit is Type=oneshot"

assert_file_contains "$SYSTEMD_UNIT" "RemainAfterExit=yes" \
    "systemd unit has RemainAfterExit=yes"

assert_file_contains "$SYSTEMD_UNIT" "Before=network-pre.target" \
    "systemd unit runs Before=network-pre.target"

assert_file_contains "$SYSTEMD_UNIT" "WantedBy=multi-user.target" \
    "systemd unit has WantedBy=multi-user.target"

# ============================================================
# Test Group 6: @decision DEC-SEC-001 annotations
# ============================================================
echo ""
echo "=== Test Group 6: Decision Annotations ==="

assert_file_contains "$NFTABLES_CONF" "@decision DEC-SEC-001" \
    "nftables.conf has @decision DEC-SEC-001 annotation"

assert_file_contains "$SYSTEMD_UNIT" "@decision DEC-SEC-001" \
    "systemd unit has @decision DEC-SEC-001 annotation"

# ============================================================
# Test Group 7: Package list includes nftables
# ============================================================
echo ""
echo "=== Test Group 7: Package List ==="

PACKAGE_LIST="iso/package-lists/orionx.list.chroot"

assert_file_contains "$PACKAGE_LIST" "^nftables$" \
    "nftables is in package list"

# ============================================================
# Test Group 8: nftables.conf syntax check (if nft available)
# ============================================================
echo ""
echo "=== Test Group 8: Syntax Validation ==="

if ! command -v nft >/dev/null 2>&1; then
    echo "  SKIP: nft not available — syntax check skipped"
elif [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "  SKIP: nft -c -f requires root (non-root CI runner) — syntax check skipped"
else
    if nft -c -f "$PROJECT_ROOT/$NFTABLES_CONF" 2>/dev/null; then
        pass "nftables.conf passes syntax check (nft -c -f)"
    else
        fail "nftables.conf passes syntax check (nft -c -f)" \
            "nft reported syntax errors"
    fi
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
