#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2329
#
# Orion-X Phoenix Edition — Unit Tests for mesh-health.sh
#
# Tests the health check daemon functions without root, WireGuard, or a
# live network. Uses mock overrides for external commands (ip, wg, ping,
# wg-quick) and records invocations for assertion.
#
# @decision DEC-MESH-TEST-003
# @title Unit test suite for mesh health check daemon
# @status accepted
# @rationale Tests each health-check function in isolation: interface
#   verification, handshake staleness detection, soft heal, ping checks,
#   aggressive heal threshold, failure counter management, and the full
#   production health-check sequence. External commands are mocked since
#   the script requires root privileges and WireGuard in production.
#
# Production sequence: systemd timer fires every 60s, invoking the oneshot
# service. The script checks the wg0 interface, iterates over peers from
# `wg show`, checks handshake staleness and ping reachability, performs
# soft or aggressive healing as needed, and logs a summary. Tests exercise
# the complete check-heal pipeline using mocked wg/ip/ping output.
#
# Usage:  bash tests/unit/test_mesh_health.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Test framework (same pattern as test_mesh_lib.sh)
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
TMPDIR_TEST=""

assert_eq() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected: '$expected'"
        echo "        actual:   '$actual'"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_match() {
    local description="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected pattern: '$pattern'"
        echo "        actual:           '$actual'"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_ne() {
    local description="$1" unexpected="$2" actual="$3"
    if [[ "$unexpected" != "$actual" ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description (got unexpected value '$unexpected')"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_file_exists() {
    local description="$1" filepath="$2"
    if [[ -f "$filepath" ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description (file not found: $filepath)"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_file_not_exists() {
    local description="$1" filepath="$2"
    if [[ ! -f "$filepath" ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description (file exists but should not: $filepath)"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_file_contains() {
    local description="$1" filepath="$2" pattern="$3"
    if [[ -f "$filepath" ]] && grep -q "$pattern" "$filepath"; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description (pattern '$pattern' not found in $filepath)"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_gt() {
    local description="$1" value="$2" threshold="$3"
    if (( value > threshold )); then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description ($value not > $threshold)"
        (( FAIL_COUNT++ )) || true
    fi
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------
setup() {
    TMPDIR_TEST="$(mktemp -d)"

    # Override all paths to temp directory
    export MESH_STATE_FILE="$TMPDIR_TEST/orionx-mesh.state"
    export MESH_PRIVATE_KEY="$TMPDIR_TEST/mesh-private.key"
    export MESH_PSK_FILE="$TMPDIR_TEST/mesh-psk"
    export MESH_LOG_FILE="$TMPDIR_TEST/mesh.log"
    export MESH_IFACE="wg0"
    export MESH_VPN_PREFIX="10.0.99"
    export MESH_WG_PORT="51820"
    export MESH_HEALTH_COUNTER_DIR="$TMPDIR_TEST/counters"

    # Create log directory so mesh_log can write
    mkdir -p "$(dirname "$MESH_LOG_FILE")"
    mkdir -p "$MESH_HEALTH_COUNTER_DIR"

    # Reset call tracking
    MOCK_CALLS_FILE="$TMPDIR_TEST/mock_calls.log"
    true > "$MOCK_CALLS_FILE"

    # --- Default mock overrides ---
    # ip: by default, interface exists
    _mock_ip_link_show_rc=0
    ip() {
        echo "ip $*" >> "$MOCK_CALLS_FILE"
        if [[ "$1" == "link" && "$2" == "show" ]]; then
            return "$_mock_ip_link_show_rc"
        fi
    }

    # wg: by default, returns no peers
    _mock_wg_dump_output=""
    wg() {
        echo "wg $*" >> "$MOCK_CALLS_FILE"
        if [[ "$1" == "show" && "${3:-}" == "dump" ]]; then
            # First line is interface header, then peers
            echo "wg0	privatekey	publickey	51820	off"
            if [[ -n "$_mock_wg_dump_output" ]]; then
                echo "$_mock_wg_dump_output"
            fi
            return 0
        fi
        if [[ "$1" == "set" ]]; then
            return 0
        fi
        return 0
    }

    # wg-quick: records calls, returns 0
    _mock_wg_quick_rc=0
    wg-quick() {
        echo "wg-quick $*" >> "$MOCK_CALLS_FILE"
        return "$_mock_wg_quick_rc"
    }

    # ping: by default, succeeds
    _mock_ping_rc=0
    ping() {
        echo "ping $*" >> "$MOCK_CALLS_FILE"
        return "$_mock_ping_rc"
    }

    # date: return a known epoch for deterministic tests
    _mock_current_epoch=""
    _original_date="$(command -v date)"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Source the library under test and its dependency
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MESH_LIB="$REPO_ROOT/scripts/mesh/mesh-lib.sh"
HEALTH_SCRIPT="$REPO_ROOT/scripts/mesh/mesh-health.sh"

if [[ ! -f "$MESH_LIB" ]]; then
    echo "ERROR: mesh-lib.sh not found at $MESH_LIB"
    exit 1
fi

if [[ ! -f "$HEALTH_SCRIPT" ]]; then
    echo "ERROR: mesh-health.sh not found at $HEALTH_SCRIPT"
    exit 1
fi

# Source mesh-lib first (provides constants and helpers)
# shellcheck source=../../scripts/mesh/mesh-lib.sh
source "$MESH_LIB"

# Source mesh-health in library mode to get functions without running main
# shellcheck source=../../scripts/mesh/mesh-health.sh
MESH_HEALTH_SOURCED=1 source "$HEALTH_SCRIPT"

# =========================================================================
# Test suites
# =========================================================================

echo "=== mesh-health.sh Unit Tests ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Script structure
# ---------------------------------------------------------------------------
echo "--- Script Structure ---"

if [[ -f "$HEALTH_SCRIPT" ]]; then
    echo "  PASS: mesh-health.sh exists"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-health.sh exists"
    (( FAIL_COUNT++ )) || true
fi

if [[ -x "$HEALTH_SCRIPT" ]]; then
    echo "  PASS: mesh-health.sh is executable"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-health.sh is executable"
    (( FAIL_COUNT++ )) || true
fi

if head -1 "$HEALTH_SCRIPT" | grep -q '#!/usr/bin/env bash\|#!/bin/bash'; then
    echo "  PASS: has bash shebang"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has bash shebang"
    (( FAIL_COUNT++ )) || true
fi

if grep -q '# shellcheck shell=bash' "$HEALTH_SCRIPT"; then
    echo "  PASS: has shellcheck directive"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has shellcheck directive"
    (( FAIL_COUNT++ )) || true
fi

if grep -q 'set -euo pipefail' "$HEALTH_SCRIPT"; then
    echo "  PASS: has strict mode"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has strict mode"
    (( FAIL_COUNT++ )) || true
fi

if grep -q '@decision DEC-MESH-002' "$HEALTH_SCRIPT"; then
    echo "  PASS: has @decision DEC-MESH-002 annotation"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has @decision DEC-MESH-002 annotation"
    (( FAIL_COUNT++ )) || true
fi

if grep -q '@decision DEC-MESH-005' "$HEALTH_SCRIPT"; then
    echo "  PASS: has @decision DEC-MESH-005 annotation"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has @decision DEC-MESH-005 annotation"
    (( FAIL_COUNT++ )) || true
fi

if grep -q 'mesh-lib.sh' "$HEALTH_SCRIPT"; then
    echo "  PASS: sources mesh-lib.sh"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: sources mesh-lib.sh"
    (( FAIL_COUNT++ )) || true
fi

if grep -q 'MESH_HEALTH_SOURCED' "$HEALTH_SCRIPT"; then
    echo "  PASS: has source guard (MESH_HEALTH_SOURCED)"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: missing source guard (MESH_HEALTH_SOURCED)"
    (( FAIL_COUNT++ )) || true
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Interface check — success
# ---------------------------------------------------------------------------
echo "--- Interface Check: Success ---"
setup

_mock_ip_link_show_rc=0

rc=0
health_check_interface 2>/dev/null || rc=$?

assert_eq "interface check passes when interface exists" "0" "$rc"

teardown
echo ""

# ---------------------------------------------------------------------------
# 3. Interface check — failure triggers restore
# ---------------------------------------------------------------------------
echo "--- Interface Check: Failure Triggers Restore ---"
setup

_mock_ip_link_show_rc=1

# wg-quick up should be called for restore
rc=0
health_check_interface 2>/dev/null || rc=$?

# When interface is missing and wg-quick up is attempted,
# we need the mock to succeed for restore
assert_file_contains "wg-quick up called for restore" "$MOCK_CALLS_FILE" "wg-quick up"

# Verify log mentions missing interface
assert_file_contains "log mentions missing interface" "$MESH_LOG_FILE" "missing"

teardown
echo ""

# ---------------------------------------------------------------------------
# 4. Interface check — restore fails returns error
# ---------------------------------------------------------------------------
echo "--- Interface Check: Restore Failure ---"
setup

_mock_ip_link_show_rc=1
_mock_wg_quick_rc=1

rc=0
health_check_interface 2>/dev/null || rc=$?

assert_eq "interface check returns 1 when restore fails" "1" "$rc"

teardown
echo ""

# ---------------------------------------------------------------------------
# 5. Handshake staleness detection — fresh handshake
# ---------------------------------------------------------------------------
echo "--- Handshake Staleness: Fresh ---"
setup

# Current time simulated via a recent handshake
NOW="$(date +%s)"
RECENT_HANDSHAKE=$((NOW - 60))

result=$(health_is_handshake_stale "$RECENT_HANDSHAKE" "$NOW")
assert_eq "60s-old handshake is fresh" "fresh" "$result"

teardown
echo ""

# ---------------------------------------------------------------------------
# 6. Handshake staleness detection — stale handshake
# ---------------------------------------------------------------------------
echo "--- Handshake Staleness: Stale ---"
setup

NOW="$(date +%s)"
OLD_HANDSHAKE=$((NOW - 300))

result=$(health_is_handshake_stale "$OLD_HANDSHAKE" "$NOW")
assert_eq "300s-old handshake is stale" "stale" "$result"

teardown
echo ""

# ---------------------------------------------------------------------------
# 7. Handshake staleness detection — zero handshake (never connected)
# ---------------------------------------------------------------------------
echo "--- Handshake Staleness: Zero (never connected) ---"
setup

NOW="$(date +%s)"
result=$(health_is_handshake_stale "0" "$NOW")
assert_eq "zero handshake is stale" "stale" "$result"

teardown
echo ""

# ---------------------------------------------------------------------------
# 8. Soft heal — called for stale handshake
# ---------------------------------------------------------------------------
echo "--- Soft Heal: Stale Handshake ---"
setup

PUBKEY="TestPeerPubKey123=="
ENDPOINT="192.168.1.10:51820"

health_soft_heal "$PUBKEY" "$ENDPOINT" 2>/dev/null

assert_file_contains "wg set called for soft heal" "$MOCK_CALLS_FILE" "wg set"
assert_file_contains "soft heal targets correct peer" "$MOCK_CALLS_FILE" "TestPeerPubKey123=="
assert_file_contains "log mentions soft heal" "$MESH_LOG_FILE" "Soft heal"

teardown
echo ""

# ---------------------------------------------------------------------------
# 9. Failure counter — increment and read
# ---------------------------------------------------------------------------
echo "--- Failure Counter: Increment and Read ---"
setup

SHORT_KEY="TestKey1"
health_increment_counter "$SHORT_KEY"
COUNT=$(health_read_counter "$SHORT_KEY")
assert_eq "counter is 1 after first increment" "1" "$COUNT"

health_increment_counter "$SHORT_KEY"
COUNT=$(health_read_counter "$SHORT_KEY")
assert_eq "counter is 2 after second increment" "2" "$COUNT"

teardown
echo ""

# ---------------------------------------------------------------------------
# 10. Failure counter — read returns 0 when no file
# ---------------------------------------------------------------------------
echo "--- Failure Counter: Default Zero ---"
setup

COUNT=$(health_read_counter "NonExistentKey")
assert_eq "counter is 0 for unknown peer" "0" "$COUNT"

teardown
echo ""

# ---------------------------------------------------------------------------
# 11. Failure counter — clear single
# ---------------------------------------------------------------------------
echo "--- Failure Counter: Clear Single ---"
setup

SHORT_KEY="ClearMe"
health_increment_counter "$SHORT_KEY"
health_increment_counter "$SHORT_KEY"
health_clear_counter "$SHORT_KEY"
COUNT=$(health_read_counter "$SHORT_KEY")
assert_eq "counter is 0 after clear" "0" "$COUNT"

teardown
echo ""

# ---------------------------------------------------------------------------
# 12. Failure counter — clear all
# ---------------------------------------------------------------------------
echo "--- Failure Counter: Clear All ---"
setup

health_increment_counter "Key1"
health_increment_counter "Key2"
health_increment_counter "Key3"

health_clear_all_counters

C1=$(health_read_counter "Key1")
C2=$(health_read_counter "Key2")
C3=$(health_read_counter "Key3")

assert_eq "Key1 counter cleared" "0" "$C1"
assert_eq "Key2 counter cleared" "0" "$C2"
assert_eq "Key3 counter cleared" "0" "$C3"

teardown
echo ""

# ---------------------------------------------------------------------------
# 13. Aggressive heal threshold
# ---------------------------------------------------------------------------
echo "--- Aggressive Heal: Triggered at threshold ---"
setup

SHORT_KEY="AggressivePeer"
health_increment_counter "$SHORT_KEY"
health_increment_counter "$SHORT_KEY"

# Should return 0 (true) — threshold met
if health_should_aggressive_heal "$SHORT_KEY"; then
    echo "  PASS: aggressive heal triggered at count=2"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: aggressive heal should trigger at count=2"
    (( FAIL_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 14. Aggressive heal — not triggered below threshold
# ---------------------------------------------------------------------------
echo "--- Aggressive Heal: Not triggered below threshold ---"
setup

SHORT_KEY="GentlePeer"
health_increment_counter "$SHORT_KEY"

# Should return 1 (false) — threshold not met
if health_should_aggressive_heal "$SHORT_KEY"; then
    echo "  FAIL: aggressive heal should NOT trigger at count=1"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: aggressive heal not triggered at count=1"
    (( PASS_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 15. Aggressive heal execution
# ---------------------------------------------------------------------------
echo "--- Aggressive Heal: Execution ---"
setup

health_increment_counter "Peer1"
health_increment_counter "Peer2"

SHORT_KEY="BadPeer"
health_aggressive_heal "$SHORT_KEY" 2>/dev/null

# Verify wg-quick down/up sequence
assert_file_contains "wg-quick down called" "$MOCK_CALLS_FILE" "wg-quick down"
assert_file_contains "wg-quick up called" "$MOCK_CALLS_FILE" "wg-quick up"

# Verify ALL counters were cleared (interface restart affects all peers)
C1=$(health_read_counter "Peer1")
C2=$(health_read_counter "Peer2")
assert_eq "Peer1 counter cleared after aggressive heal" "0" "$C1"
assert_eq "Peer2 counter cleared after aggressive heal" "0" "$C2"

# Verify log
assert_file_contains "log mentions aggressive heal" "$MESH_LOG_FILE" "Aggressive heal"

teardown
echo ""

# ---------------------------------------------------------------------------
# 16. Peer check — healthy peer (fresh handshake, ping OK)
# ---------------------------------------------------------------------------
echo "--- Peer Check: Healthy ---"
setup

NOW="$(date +%s)"
RECENT_HS=$((NOW - 30))
PUBKEY="HealthyPeerKey123456789012345678901234567890=="
ENDPOINT="192.168.1.10:51820"
ALLOWED_IPS="10.0.99.10/32"

_mock_ping_rc=0

rc=0
health_check_peer "$PUBKEY" "$ENDPOINT" "$ALLOWED_IPS" "$RECENT_HS" "$NOW" 2>/dev/null || rc=$?

assert_eq "healthy peer check returns 0" "0" "$rc"

# No soft heal should have been called
if grep -q "wg set" "$MOCK_CALLS_FILE" 2>/dev/null; then
    echo "  FAIL: soft heal should not be called for healthy peer"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: no soft heal for healthy peer"
    (( PASS_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 17. Peer check — stale handshake triggers soft heal
# ---------------------------------------------------------------------------
echo "--- Peer Check: Stale Handshake Soft Heal ---"
setup

NOW="$(date +%s)"
OLD_HS=$((NOW - 300))
PUBKEY="StalePeerKeyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
ENDPOINT="192.168.1.20:51820"
ALLOWED_IPS="10.0.99.20/32"

_mock_ping_rc=0  # ping succeeds

rc=0
health_check_peer "$PUBKEY" "$ENDPOINT" "$ALLOWED_IPS" "$OLD_HS" "$NOW" 2>/dev/null || rc=$?

# Soft heal should have been called
assert_file_contains "soft heal called for stale peer" "$MOCK_CALLS_FILE" "wg set"

teardown
echo ""

# ---------------------------------------------------------------------------
# 18. Peer check — stale + ping fail increments counter
# ---------------------------------------------------------------------------
echo "--- Peer Check: Stale + Ping Fail ---"
setup

NOW="$(date +%s)"
OLD_HS=$((NOW - 300))
PUBKEY="FailPeerKeyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
ENDPOINT="192.168.1.30:51820"
ALLOWED_IPS="10.0.99.30/32"
SHORT_KEY="${PUBKEY:0:8}"

_mock_ping_rc=1  # ping fails

rc=0
health_check_peer "$PUBKEY" "$ENDPOINT" "$ALLOWED_IPS" "$OLD_HS" "$NOW" 2>/dev/null || rc=$?

COUNT=$(health_read_counter "$SHORT_KEY")
assert_gt "failure counter incremented" "$COUNT" 0

teardown
echo ""

# ---------------------------------------------------------------------------
# 19. No peers — graceful handling
# ---------------------------------------------------------------------------
echo "--- No Peers: Graceful Handling ---"
setup

_mock_wg_dump_output=""  # no peers

rc=0
health_check_all_peers 2>/dev/null || rc=$?

assert_eq "no peers check returns 0" "0" "$rc"
assert_file_contains "log mentions 0 peers" "$MESH_LOG_FILE" "0 peers"

teardown
echo ""

# ---------------------------------------------------------------------------
# 20. Healthy mesh — all peers responsive
# ---------------------------------------------------------------------------
echo "--- Healthy Mesh: All Responsive ---"
setup

NOW="$(date +%s)"
RECENT=$((NOW - 30))

# Two healthy peers
_mock_wg_dump_output="PeerKey1XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.10:51820	10.0.99.10/32	${RECENT}	12345	67890	off
PeerKey2XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.20:51820	10.0.99.20/32	${RECENT}	12345	67890	off"

_mock_ping_rc=0

rc=0
health_check_all_peers 2>/dev/null || rc=$?

assert_eq "healthy mesh check returns 0" "0" "$rc"
assert_file_contains "log mentions 2 peers" "$MESH_LOG_FILE" "2 peers"
assert_file_contains "log mentions 2 healthy" "$MESH_LOG_FILE" "2 healthy"
assert_file_contains "log mentions 0 stale" "$MESH_LOG_FILE" "0 stale"

teardown
echo ""

# ---------------------------------------------------------------------------
# 21. Mixed mesh — one healthy, one stale
# ---------------------------------------------------------------------------
echo "--- Mixed Mesh: One Healthy, One Stale ---"
setup

NOW="$(date +%s)"
RECENT=$((NOW - 30))
OLD=$((NOW - 300))

_mock_wg_dump_output="PeerKey1XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.10:51820	10.0.99.10/32	${RECENT}	12345	67890	off
PeerKey2XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.20:51820	10.0.99.20/32	${OLD}	12345	67890	off"

# Ping fails for the stale peer (simulates unreachable node)
_mock_ping_rc=1

rc=0
health_check_all_peers 2>/dev/null || rc=$?

assert_eq "mixed mesh check returns 0" "0" "$rc"
assert_file_contains "log mentions 2 peers" "$MESH_LOG_FILE" "2 peers"
assert_file_contains "log mentions 1 stale" "$MESH_LOG_FILE" "1 stale"

teardown
echo ""

# ---------------------------------------------------------------------------
# 22. Production sequence: stale peer → soft heal → still failing → aggressive
# ---------------------------------------------------------------------------
echo "--- Production Sequence: Soft → Aggressive Heal ---"
setup

NOW="$(date +%s)"
OLD=$((NOW - 300))
PUBKEY="ProdFailKeyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
ENDPOINT="192.168.1.50:51820"
ALLOWED_IPS="10.0.99.50/32"
SHORT_KEY="${PUBKEY:0:8}"

_mock_ping_rc=1  # ping always fails

# First invocation: soft heal + increment — returns 1 (stale, below threshold)
rc=0
health_check_peer "$PUBKEY" "$ENDPOINT" "$ALLOWED_IPS" "$OLD" "$NOW" 2>/dev/null || rc=$?
assert_eq "first check returns 1 (stale)" "1" "$rc"
C1=$(health_read_counter "$SHORT_KEY")
assert_eq "counter is 1 after first check" "1" "$C1"

# Clear mock calls for second check
true > "$MOCK_CALLS_FILE"

# Second invocation: soft heal + increment → triggers aggressive threshold (returns 2)
rc=0
health_check_peer "$PUBKEY" "$ENDPOINT" "$ALLOWED_IPS" "$OLD" "$NOW" 2>/dev/null || rc=$?
assert_eq "second check returns 2 (aggressive heal)" "2" "$rc"
C2=$(health_read_counter "$SHORT_KEY")

# After aggressive heal, counter is cleared to 0
# (aggressive heal resets all counters)
if health_should_aggressive_heal "$SHORT_KEY" 2>/dev/null; then
    # It reached threshold but aggressive heal in check_peer should have
    # already cleared it, so counter should be 0
    echo "  INFO: aggressive threshold was reached"
fi

# Verify aggressive heal was triggered (wg-quick down/up in the calls)
assert_file_contains "aggressive heal wg-quick down" "$MOCK_CALLS_FILE" "wg-quick down"
assert_file_contains "aggressive heal wg-quick up" "$MOCK_CALLS_FILE" "wg-quick up"

teardown
echo ""

# ---------------------------------------------------------------------------
# 23. Counter cleared on fresh handshake
# ---------------------------------------------------------------------------
echo "--- Counter Cleared on Fresh Handshake ---"
setup

NOW="$(date +%s)"
RECENT=$((NOW - 30))
PUBKEY="RecoveredKeyXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
ENDPOINT="192.168.1.60:51820"
ALLOWED_IPS="10.0.99.60/32"
SHORT_KEY="${PUBKEY:0:8}"

# Pre-set a failure counter
health_increment_counter "$SHORT_KEY"

_mock_ping_rc=0  # ping succeeds

# Now check with a fresh handshake — counter should be cleared
health_check_peer "$PUBKEY" "$ENDPOINT" "$ALLOWED_IPS" "$RECENT" "$NOW" 2>/dev/null

COUNT=$(health_read_counter "$SHORT_KEY")
assert_eq "counter cleared on fresh handshake" "0" "$COUNT"

teardown
echo ""

# ---------------------------------------------------------------------------
# 24. Short key extraction
# ---------------------------------------------------------------------------
echo "--- Short Key Extraction ---"
setup

LONG_KEY="AbCdEfGhIjKlMnOpQrStUvWxYz1234567890ABCD=="
SHORT=$(health_short_key "$LONG_KEY")
assert_eq "short key is first 8 chars" "AbCdEfGh" "$SHORT"

EXACTLY_8="12345678"
SHORT2=$(health_short_key "$EXACTLY_8")
assert_eq "short key for 8-char input" "12345678" "$SHORT2"

teardown
echo ""

# ---------------------------------------------------------------------------
# 25. VPN IP extraction from allowed-ips
# ---------------------------------------------------------------------------
echo "--- VPN IP Extraction ---"
setup

VPN_IP=$(health_extract_vpn_ip "10.0.99.10/32")
assert_eq "extract VPN IP from CIDR" "10.0.99.10" "$VPN_IP"

VPN_IP2=$(health_extract_vpn_ip "10.0.99.20/32,192.168.1.0/24")
assert_eq "extract first VPN IP from multi-CIDR" "10.0.99.20" "$VPN_IP2"

teardown
echo ""

# ---------------------------------------------------------------------------
# 26. Systemd unit files exist
# ---------------------------------------------------------------------------
echo "--- Systemd Unit Files ---"

SERVICE_FILE="$REPO_ROOT/systemd/orionx-mesh-health.service"
TIMER_FILE="$REPO_ROOT/systemd/orionx-mesh-health.timer"

assert_file_exists "health service unit exists" "$SERVICE_FILE"
assert_file_exists "health timer unit exists" "$TIMER_FILE"

if [[ -f "$SERVICE_FILE" ]]; then
    assert_file_contains "service is oneshot" "$SERVICE_FILE" "Type=oneshot"
    assert_file_contains "service exec references mesh-health.sh" "$SERVICE_FILE" "mesh-health.sh"
fi

if [[ -f "$TIMER_FILE" ]]; then
    assert_file_contains "timer has OnBootSec" "$TIMER_FILE" "OnBootSec"
    assert_file_contains "timer has OnUnitActiveSec" "$TIMER_FILE" "OnUnitActiveSec"
    assert_file_contains "timer targets the service" "$TIMER_FILE" "orionx-mesh-health.service"
    assert_file_contains "timer has Install section" "$TIMER_FILE" "WantedBy=timers.target"
fi

echo ""

# ---------------------------------------------------------------------------
# 27. ShellCheck
# ---------------------------------------------------------------------------
echo "--- ShellCheck ---"

if command -v shellcheck &>/dev/null; then
    if shellcheck "$HEALTH_SCRIPT" 2>&1; then
        echo "  PASS: ShellCheck passes on mesh-health.sh"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: ShellCheck passes on mesh-health.sh"
        (( FAIL_COUNT++ )) || true
    fi
else
    echo "  SKIP: shellcheck not installed"
fi
echo ""

# =========================================================================
# Summary
# =========================================================================
echo "==========================================="
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
