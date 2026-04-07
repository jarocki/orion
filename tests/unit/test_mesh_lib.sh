#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2329
#
# Orion-X Phoenix Edition — Unit Tests for mesh-lib.sh
#
# Tests the shared mesh networking library functions that can be
# exercised without root privileges or a live WireGuard install.
#
# @decision DEC-MESH-TEST-001
# @title Unit test suite for mesh-lib.sh shared library
# @status accepted
# @rationale Tests each pure-logic function (logging, VPN IP allocation,
#   config parsing, state roundtrip) in isolation using temp directories
#   and mock overrides. Functions requiring root or real WireGuard (genkeys,
#   interface_up/down, add/remove_peer, ensure_psk) are excluded — those
#   belong in integration tests with Docker.
#
# Usage:  bash tests/unit/test_mesh_lib.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Test framework
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

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------
setup() {
    TMPDIR_TEST="$(mktemp -d)"
    # Override paths so tests don't touch system directories
    export MESH_STATE_FILE="$TMPDIR_TEST/orionx-mesh.state"
    export MESH_PRIVATE_KEY="$TMPDIR_TEST/mesh-private.key"
    export MESH_PSK_FILE="$TMPDIR_TEST/mesh-psk"
    export MESH_LOG_FILE="$TMPDIR_TEST/mesh.log"
    export MESH_CONFIG_FILE="$TMPDIR_TEST/mesh-peers.conf"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# Source the library under test
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MESH_LIB="$REPO_ROOT/scripts/mesh/mesh-lib.sh"

if [[ ! -f "$MESH_LIB" ]]; then
    echo "ERROR: mesh-lib.sh not found at $MESH_LIB"
    exit 1
fi

# shellcheck source=../../scripts/mesh/mesh-lib.sh
source "$MESH_LIB"

# =========================================================================
# Test suites
# =========================================================================

echo "=== mesh-lib.sh Unit Tests ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Constants are defined and non-empty
# ---------------------------------------------------------------------------
echo "--- Constants ---"
assert_ne "MESH_IFACE is non-empty" "" "${MESH_IFACE:-}"
assert_ne "MESH_SUBNET is non-empty" "" "${MESH_SUBNET:-}"
assert_ne "MESH_VPN_PREFIX is non-empty" "" "${MESH_VPN_PREFIX:-}"
assert_ne "MESH_WG_PORT is non-empty" "" "${MESH_WG_PORT:-}"
assert_ne "MESH_DISCOVER_PORT is non-empty" "" "${MESH_DISCOVER_PORT:-}"
assert_ne "MESH_STATE_FILE is non-empty" "" "${MESH_STATE_FILE:-}"
assert_ne "MESH_PRIVATE_KEY is non-empty" "" "${MESH_PRIVATE_KEY:-}"
assert_ne "MESH_PSK_FILE is non-empty" "" "${MESH_PSK_FILE:-}"
assert_ne "MESH_LOG_FILE is non-empty" "" "${MESH_LOG_FILE:-}"
assert_ne "MESH_HEALTH_INTERVAL is non-empty" "" "${MESH_HEALTH_INTERVAL:-}"
assert_ne "MESH_DISCOVER_INTERVAL is non-empty" "" "${MESH_DISCOVER_INTERVAL:-}"

assert_eq "MESH_IFACE is wg0" "wg0" "$MESH_IFACE"
assert_eq "MESH_SUBNET is 10.0.99.0/24" "10.0.99.0/24" "$MESH_SUBNET"
assert_eq "MESH_VPN_PREFIX is 10.0.99" "10.0.99" "$MESH_VPN_PREFIX"
assert_eq "MESH_WG_PORT is 51820" "51820" "$MESH_WG_PORT"
assert_eq "MESH_DISCOVER_PORT is 55555" "55555" "$MESH_DISCOVER_PORT"
assert_eq "MESH_HEALTH_INTERVAL is 60" "60" "$MESH_HEALTH_INTERVAL"
assert_eq "MESH_DISCOVER_INTERVAL is 10" "10" "$MESH_DISCOVER_INTERVAL"
echo ""

# ---------------------------------------------------------------------------
# 2. mesh_log output format
# ---------------------------------------------------------------------------
echo "--- mesh_log ---"
setup

mesh_log INFO "test message one" 2>/dev/null
mesh_log WARN "test warning" 2>/dev/null
mesh_log ERROR "test error" 2>/dev/null

# Check messages were written to the log file
assert_file_exists "log file was created" "$MESH_LOG_FILE"

LOG_CONTENT="$(cat "$MESH_LOG_FILE")"

# Verify format: [YYYY-MM-DD HH:MM:SS] [LEVEL] message
assert_match "INFO log has timestamp format" \
    '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] \[INFO\] test message one$' \
    "$(echo "$LOG_CONTENT" | head -n1)"

assert_match "WARN log has correct level" \
    '\[WARN\] test warning' \
    "$(echo "$LOG_CONTENT" | sed -n '2p')"

assert_match "ERROR log has correct level" \
    '\[ERROR\] test error' \
    "$(echo "$LOG_CONTENT" | sed -n '3p')"

# Test fallback: if log dir doesn't exist, log goes to stderr only
# (no file written). Verify stderr contains the message.
export MESH_LOG_FILE="/nonexistent/dir/mesh.log"
STDERR_OUTPUT="$(mesh_log INFO "fallback test" 2>&1)"
assert_match "fallback logs to stderr when log dir missing" \
    '\[INFO\] fallback test' \
    "$STDERR_OUTPUT"
# Verify the nonexistent log file was NOT created
if [[ -f "/nonexistent/dir/mesh.log" ]]; then
    echo "  FAIL: log file should not be created when dir missing"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: no log file created when dir missing"
    (( PASS_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 3. mesh_get_vpn_ip logic
# ---------------------------------------------------------------------------
echo "--- mesh_get_vpn_ip ---"
setup

# Override _mesh_detect_lan_ip to return a known value
_mesh_detect_lan_ip() { echo "192.168.1.42"; }

VPN_IP="$(mesh_get_vpn_ip)"
assert_eq "VPN IP derives last octet from LAN IP" "10.0.99.42" "$VPN_IP"

# Test with different LAN IP
_mesh_detect_lan_ip() { echo "192.168.1.1"; }
VPN_IP2="$(mesh_get_vpn_ip)"
assert_eq "VPN IP for .1 LAN" "10.0.99.1" "$VPN_IP2"

# Test with .255 edge case
_mesh_detect_lan_ip() { echo "192.168.1.255"; }
VPN_IP3="$(mesh_get_vpn_ip)"
assert_eq "VPN IP for .255 LAN" "10.0.99.255" "$VPN_IP3"

# Test collision: write a state file claiming .42 is taken, try again with .42 LAN
_mesh_detect_lan_ip() { echo "192.168.1.42"; }
echo '42' > "$TMPDIR_TEST/claimed_ips"
export MESH_CLAIMED_IPS="$TMPDIR_TEST/claimed_ips"
VPN_IP4="$(mesh_get_vpn_ip)"
assert_eq "VPN IP increments on collision" "10.0.99.43" "$VPN_IP4"

# Test collision wrap: claim 254 and 255, start from 254
_mesh_detect_lan_ip() { echo "192.168.1.254"; }
printf '254\n255\n' > "$TMPDIR_TEST/claimed_ips"
VPN_IP5="$(mesh_get_vpn_ip)"
# Should wrap around and find a free one (1..253)
assert_match "VPN IP wraps on high-range collision" \
    '^10\.0\.99\.[0-9]+$' "$VPN_IP5"
assert_ne "VPN IP is not .254 after wrap" "10.0.99.254" "$VPN_IP5"

teardown
echo ""

# ---------------------------------------------------------------------------
# 4. mesh_parse_config
# ---------------------------------------------------------------------------
echo "--- mesh_parse_config ---"
setup

cat > "$MESH_CONFIG_FILE" << 'CONFEOF'
# Orion-X mesh peer list
# hostname pubkey vpn_ip endpoint_ip wg_port
node-alpha ABC123PubKeyAlpha== 10.0.99.1 192.168.1.10 51820
node-beta  DEF456PubKeyBeta== 10.0.99.2 192.168.1.20 51820

# Another comment
node-gamma GHI789PubKeyGamma== 10.0.99.3 192.168.1.30 51821
CONFEOF

PARSED="$(mesh_parse_config "$MESH_CONFIG_FILE")"
LINE_COUNT="$(echo "$PARSED" | wc -l | tr -d ' ')"
assert_eq "parse_config returns 3 peer lines" "3" "$LINE_COUNT"

FIRST_LINE="$(echo "$PARSED" | head -n1)"
assert_match "first peer has hostname node-alpha" '^node-alpha ' "$FIRST_LINE"
assert_match "first peer has pubkey" 'ABC123PubKeyAlpha==' "$FIRST_LINE"

THIRD_LINE="$(echo "$PARSED" | tail -n1)"
assert_match "third peer has port 51821" '51821$' "$THIRD_LINE"

# Test with empty config (comments only)
cat > "$MESH_CONFIG_FILE" << 'CONFEOF'
# Only comments here
# No peers
CONFEOF

PARSED_EMPTY="$(mesh_parse_config "$MESH_CONFIG_FILE")"
assert_eq "parse_config returns empty for comment-only file" "" "$PARSED_EMPTY"

# Test missing config file (log warning goes to stderr, stdout should be empty)
PARSED_MISSING="$(mesh_parse_config "/nonexistent/config.conf" 2>/dev/null)" || true
assert_eq "parse_config returns empty for missing file" "" "${PARSED_MISSING:-}"

teardown
echo ""

# ---------------------------------------------------------------------------
# 5. mesh_state_write + mesh_state_read roundtrip
# ---------------------------------------------------------------------------
echo "--- mesh_state_write / mesh_state_read ---"
setup

mesh_state_write "wg0" "10.0.99.42" "pre-planned" "TestPubKeyABC=="
assert_file_exists "state file was created" "$MESH_STATE_FILE"

STATE_CONTENT="$(cat "$MESH_STATE_FILE")"
assert_match "state contains interface" '"interface"' "$STATE_CONTENT"
assert_match "state contains vpn_ip" '"vpn_ip"' "$STATE_CONTENT"
assert_match "state contains mode" '"mode"' "$STATE_CONTENT"
assert_match "state contains pubkey" '"pubkey"' "$STATE_CONTENT"
assert_match "state contains start_time" '"start_time"' "$STATE_CONTENT"

# Read back
IFACE_READ="$(mesh_state_read interface)"
assert_eq "state roundtrip: interface" "wg0" "$IFACE_READ"

VPN_IP_READ="$(mesh_state_read vpn_ip)"
assert_eq "state roundtrip: vpn_ip" "10.0.99.42" "$VPN_IP_READ"

MODE_READ="$(mesh_state_read mode)"
assert_eq "state roundtrip: mode" "pre-planned" "$MODE_READ"

PUBKEY_READ="$(mesh_state_read pubkey)"
assert_eq "state roundtrip: pubkey" "TestPubKeyABC==" "$PUBKEY_READ"

# start_time should be a Unix timestamp
START_TIME_READ="$(mesh_state_read start_time)"
assert_match "state roundtrip: start_time is numeric" '^[0-9]+$' "$START_TIME_READ"

teardown
echo ""

# ---------------------------------------------------------------------------
# 6. mesh_is_active (without real WireGuard)
# ---------------------------------------------------------------------------
echo "--- mesh_is_active ---"
setup

# No state file — should be inactive
if mesh_is_active; then
    echo "  FAIL: mesh_is_active should return 1 when no state file"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: mesh_is_active returns 1 when no state file"
    (( PASS_COUNT++ )) || true
fi

# Create state file but wg0 won't exist — should still be inactive
mesh_state_write "wg0" "10.0.99.42" "pre-planned" "TestPubKeyABC=="
if mesh_is_active; then
    echo "  FAIL: mesh_is_active should return 1 when wg0 interface is down"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: mesh_is_active returns 1 when wg0 interface is down"
    (( PASS_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 7. mesh_get_psk_path
# ---------------------------------------------------------------------------
echo "--- mesh_get_psk_path ---"
setup

PSK_PATH="$(mesh_get_psk_path)"
assert_eq "PSK path matches MESH_PSK_FILE" "$MESH_PSK_FILE" "$PSK_PATH"

teardown
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
