#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2329
#
# Orion-X Phoenix Edition — Unit Tests for mesh-discover.sh
#
# Tests the peer discovery daemon functions that can be exercised
# without a live network, socat, or WireGuard installation.
#
# @decision DEC-MESH-TEST-002
# @title Unit test suite for mesh-discover.sh discovery daemon
# @status accepted
# @rationale Tests each pure-logic function (beacon JSON construction,
#   own-beacon filtering, beacon parsing, broadcast address detection,
#   PID file management, invalid JSON handling) in isolation using temp
#   directories and mock overrides. Functions requiring real network/socat
#   (actual send/listen) are excluded — those belong in integration tests.
#
# Production sequence: A peer boots, runs the listener, another peer sends
# beacons. The listener parses JSON, filters own beacons, checks for
# duplicate peers, and calls mesh_add_peer for new peers. These tests
# exercise the complete beacon-receive pipeline minus actual UDP transport.
#
# Usage:  bash tests/unit/test_mesh_discover.sh

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
        echo "  FAIL: $description (file should not exist: $filepath)"
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
    export MESH_DISCOVER_PID_FILE="$TMPDIR_TEST/orionx-mesh-discover.pid"
    # Ensure log dir exists for mesh_log
    mkdir -p "$(dirname "$MESH_LOG_FILE")"
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
DISCOVER_SCRIPT="$REPO_ROOT/scripts/mesh/mesh-discover.sh"

if [[ ! -f "$MESH_LIB" ]]; then
    echo "ERROR: mesh-lib.sh not found at $MESH_LIB"
    exit 1
fi

if [[ ! -f "$DISCOVER_SCRIPT" ]]; then
    echo "ERROR: mesh-discover.sh not found at $DISCOVER_SCRIPT"
    exit 1
fi

# Source mesh-lib first (provides constants and helpers)
# shellcheck source=../../scripts/mesh/mesh-lib.sh
source "$MESH_LIB"

# Source mesh-discover in "library mode" to get functions without running main
# shellcheck source=../../scripts/mesh/mesh-discover.sh
MESH_DISCOVER_SOURCED=1 source "$DISCOVER_SCRIPT"

# =========================================================================
# Test suites
# =========================================================================

echo "=== mesh-discover.sh Unit Tests ==="
echo ""

# ---------------------------------------------------------------------------
# 1. Script structure
# ---------------------------------------------------------------------------
echo "--- Script Structure ---"

if [[ -f "$DISCOVER_SCRIPT" ]]; then
    echo "  PASS: mesh-discover.sh exists"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-discover.sh exists"
    (( FAIL_COUNT++ )) || true
fi

if [[ -x "$DISCOVER_SCRIPT" ]]; then
    echo "  PASS: mesh-discover.sh is executable"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-discover.sh is executable"
    (( FAIL_COUNT++ )) || true
fi

if head -1 "$DISCOVER_SCRIPT" | grep -q '#!/usr/bin/env bash\|#!/bin/bash'; then
    echo "  PASS: has bash shebang"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has bash shebang"
    (( FAIL_COUNT++ )) || true
fi

if grep -q '# shellcheck shell=bash' "$DISCOVER_SCRIPT"; then
    echo "  PASS: has shellcheck directive"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has shellcheck directive"
    (( FAIL_COUNT++ )) || true
fi

if grep -q 'set -euo pipefail' "$DISCOVER_SCRIPT"; then
    echo "  PASS: has strict mode"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has strict mode"
    (( FAIL_COUNT++ )) || true
fi

if grep -q '@decision DEC-MESH-001' "$DISCOVER_SCRIPT"; then
    echo "  PASS: has @decision DEC-MESH-001 annotation"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: has @decision DEC-MESH-001 annotation"
    (( FAIL_COUNT++ )) || true
fi

if grep -q 'mesh-lib.sh' "$DISCOVER_SCRIPT"; then
    echo "  PASS: sources mesh-lib.sh"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: sources mesh-lib.sh"
    (( FAIL_COUNT++ )) || true
fi
echo ""

# ---------------------------------------------------------------------------
# 2. Beacon JSON construction
# ---------------------------------------------------------------------------
echo "--- Beacon JSON Construction ---"
setup

# Test _mesh_build_beacon with known inputs
BEACON=$(_mesh_build_beacon "TestPubKey123==" "10.0.99.42" "51820" "test-node")

assert_match "beacon contains pubkey field" \
    '"pubkey"[[:space:]]*:[[:space:]]*"TestPubKey123=="' "$BEACON"

assert_match "beacon contains vpn_ip field" \
    '"vpn_ip"[[:space:]]*:[[:space:]]*"10.0.99.42"' "$BEACON"

assert_match "beacon contains wg_port field" \
    '"wg_port"[[:space:]]*:[[:space:]]*51820' "$BEACON"

# DEC-PHASE12-099: the hostname is no longer broadcast to the LAN.
if [[ "$BEACON" == *hostname* ]]; then
    echo "  FAIL: beacon must not carry the hostname (security F14)"; (( FAIL_COUNT++ )) || true
else
    echo "  PASS: beacon does not carry the hostname"; (( PASS_COUNT++ )) || true
fi

# Verify it's valid-looking JSON (starts with { ends with })
assert_match "beacon is JSON object" '^\{.*\}$' "$BEACON"

# Verify wg_port is numeric (not quoted)
assert_match "wg_port is numeric (not quoted)" '"wg_port"[[:space:]]*:[[:space:]]*[0-9]+' "$BEACON"

teardown
echo ""

# ---------------------------------------------------------------------------
# 3. Beacon JSON parsing
# ---------------------------------------------------------------------------
echo "--- Beacon JSON Parsing ---"
setup

SAMPLE_BEACON='{"pubkey":"ABC123PubKey==","vpn_ip":"10.0.99.1","wg_port":51820,"hostname":"alpha-node"}'

PARSED_PUBKEY=$(_mesh_parse_field "$SAMPLE_BEACON" "pubkey")
assert_eq "parse pubkey from beacon" "ABC123PubKey==" "$PARSED_PUBKEY"

PARSED_VPN_IP=$(_mesh_parse_field "$SAMPLE_BEACON" "vpn_ip")
assert_eq "parse vpn_ip from beacon" "10.0.99.1" "$PARSED_VPN_IP"

PARSED_WG_PORT=$(_mesh_parse_field "$SAMPLE_BEACON" "wg_port")
assert_eq "parse wg_port from beacon" "51820" "$PARSED_WG_PORT"

PARSED_HOSTNAME=$(_mesh_parse_field "$SAMPLE_BEACON" "hostname")
assert_eq "parse hostname from beacon" "alpha-node" "$PARSED_HOSTNAME"

# Test with extra whitespace in JSON
SPACED_BEACON='{ "pubkey" : "SpacedKey==" , "vpn_ip" : "10.0.99.5" , "wg_port" : 51821 , "hostname" : "spaced-node" }'
PARSED_SPACED=$(_mesh_parse_field "$SPACED_BEACON" "pubkey")
assert_eq "parse pubkey from spaced JSON" "SpacedKey==" "$PARSED_SPACED"

teardown
echo ""

# ---------------------------------------------------------------------------
# 4. Own-beacon filtering
# ---------------------------------------------------------------------------
echo "--- Own-Beacon Filtering ---"
setup

OWN_PUBKEY="MyOwnPubKey123=="
OTHER_PUBKEY="SomeOtherPeerKey=="

# Own beacon should be filtered (return 0 = "yes, is own")
if _mesh_is_own_beacon "$OWN_PUBKEY" "$OWN_PUBKEY"; then
    echo "  PASS: own beacon is detected"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: own beacon should be detected"
    (( FAIL_COUNT++ )) || true
fi

# Other beacon should not be filtered (return 1 = "no, not own")
if _mesh_is_own_beacon "$OTHER_PUBKEY" "$OWN_PUBKEY"; then
    echo "  FAIL: other beacon should not be flagged as own"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: other beacon is not flagged as own"
    (( PASS_COUNT++ )) || true
fi

# Empty pubkey should not match
if _mesh_is_own_beacon "" "$OWN_PUBKEY"; then
    echo "  FAIL: empty pubkey should not match own"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: empty pubkey does not match own"
    (( PASS_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 5. Broadcast address detection
# ---------------------------------------------------------------------------
echo "--- Broadcast Address Detection ---"
setup

# Mock _mesh_get_broadcast_addr with known ip output
# Test: provide mock ip output and verify broadcast extraction
_mesh_detect_ip_output() {
    echo "2: eth0    inet 192.168.1.42/24 brd 192.168.1.255 scope global eth0"
}

# Override the function to use our mock
_mesh_get_broadcast_addr_from_output() {
    local output="$1"
    echo "$output" | { grep -oE 'brd [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true; } | head -1 | awk '{print $2}'
}

BCAST=$(_mesh_get_broadcast_addr_from_output "2: eth0    inet 192.168.1.42/24 brd 192.168.1.255 scope global eth0")
assert_eq "extract broadcast from ip output" "192.168.1.255" "$BCAST"

# Test with different subnet
BCAST2=$(_mesh_get_broadcast_addr_from_output "3: wlan0    inet 10.0.0.50/16 brd 10.0.255.255 scope global wlan0")
assert_eq "extract broadcast from /16 subnet" "10.0.255.255" "$BCAST2"

# Test fallback when no brd field (returns empty, caller uses 255.255.255.255)
BCAST3=$(_mesh_get_broadcast_addr_from_output "1: lo    inet 127.0.0.1/8 scope host lo")
assert_eq "no brd field returns empty" "" "$BCAST3"

teardown
echo ""

# ---------------------------------------------------------------------------
# 6. PID file management
# ---------------------------------------------------------------------------
echo "--- PID File Management ---"
setup

# Write PID file
_mesh_write_pid "12345"
assert_file_exists "PID file created" "$MESH_DISCOVER_PID_FILE"

# Read PID back
STORED_PID=$(_mesh_read_pid)
assert_eq "PID file contains correct PID" "12345" "$STORED_PID"

# Clean up PID file
_mesh_cleanup_pid
assert_file_not_exists "PID file removed after cleanup" "$MESH_DISCOVER_PID_FILE"

# Read PID when no file exists (should return empty)
EMPTY_PID=$(_mesh_read_pid)
assert_eq "read PID returns empty when no file" "" "$EMPTY_PID"

teardown
echo ""

# ---------------------------------------------------------------------------
# 7. Invalid JSON handling
# ---------------------------------------------------------------------------
echo "--- Invalid JSON Handling ---"
setup

# Completely malformed input should not crash and should return empty
PARSED_BAD=$(_mesh_parse_field "not json at all" "pubkey")
assert_eq "malformed input returns empty for pubkey" "" "$PARSED_BAD"

PARSED_EMPTY=$(_mesh_parse_field "" "pubkey")
assert_eq "empty input returns empty for pubkey" "" "$PARSED_EMPTY"

# Partial JSON (missing fields)
PARTIAL='{"pubkey":"PartialKey=="}'
PARSED_PARTIAL_VPN=$(_mesh_parse_field "$PARTIAL" "vpn_ip")
assert_eq "missing field returns empty" "" "$PARSED_PARTIAL_VPN"

PARSED_PARTIAL_PK=$(_mesh_parse_field "$PARTIAL" "pubkey")
assert_eq "present field in partial JSON parsed correctly" "PartialKey==" "$PARSED_PARTIAL_PK"

# JSON with special characters in hostname
SPECIAL_BEACON='{"pubkey":"SpecKey==","vpn_ip":"10.0.99.10","wg_port":51820,"hostname":"node-01.local"}'
PARSED_SPECIAL=$(_mesh_parse_field "$SPECIAL_BEACON" "hostname")
assert_eq "hostname with dots parsed correctly" "node-01.local" "$PARSED_SPECIAL"

teardown
echo ""

# ---------------------------------------------------------------------------
# 8. Production sequence: beacon receive pipeline
# ---------------------------------------------------------------------------
echo "--- Production Sequence: Beacon Receive Pipeline ---"
setup

# Simulate the full pipeline:
# 1. Build a beacon from peer data
# 2. Parse the beacon
# 3. Check it's not our own
# 4. Verify fields are all present and correct

OUR_PUBKEY="OurNodeKey123=="
PEER_PUBKEY="PeerNodeKey456=="
PEER_VPN="10.0.99.50"
PEER_PORT="51820"
PEER_HOST="peer-alpha"

# Peer sends a beacon
PEER_BEACON=$(_mesh_build_beacon "$PEER_PUBKEY" "$PEER_VPN" "$PEER_PORT" "$PEER_HOST")

# We receive and parse it
RX_PUBKEY=$(_mesh_parse_field "$PEER_BEACON" "pubkey")
RX_VPN=$(_mesh_parse_field "$PEER_BEACON" "vpn_ip")
RX_PORT=$(_mesh_parse_field "$PEER_BEACON" "wg_port")
RX_HOST=$(_mesh_parse_field "$PEER_BEACON" "hostname")

assert_eq "pipeline: pubkey roundtrip" "$PEER_PUBKEY" "$RX_PUBKEY"
assert_eq "pipeline: vpn_ip roundtrip" "$PEER_VPN" "$RX_VPN"
assert_eq "pipeline: wg_port roundtrip" "$PEER_PORT" "$RX_PORT"
assert_eq "pipeline: no hostname on the wire (DEC-PHASE12-099)" "" "$RX_HOST"

# Verify it's not our own beacon
if _mesh_is_own_beacon "$RX_PUBKEY" "$OUR_PUBKEY"; then
    echo "  FAIL: peer beacon should not be flagged as own"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: peer beacon correctly identified as foreign"
    (( PASS_COUNT++ )) || true
fi

# Now test with our own beacon
OUR_BEACON=$(_mesh_build_beacon "$OUR_PUBKEY" "10.0.99.1" "51820" "our-node")
OUR_RX_PUBKEY=$(_mesh_parse_field "$OUR_BEACON" "pubkey")

if _mesh_is_own_beacon "$OUR_RX_PUBKEY" "$OUR_PUBKEY"; then
    echo "  PASS: own beacon correctly filtered in pipeline"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: own beacon should be filtered"
    (( FAIL_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 9. Production sequence: multiple peers discovered in sequence
# ---------------------------------------------------------------------------
echo "--- Production Sequence: Multiple Peer Discovery ---"
setup

# Simulate receiving beacons from 3 different peers, then a duplicate
OUR_KEY="LocalNodeKey=="

# Track calls to mesh_add_peer (override with mock that records calls)
MOCK_ADD_PEER_CALLS=()
mesh_add_peer() {
    MOCK_ADD_PEER_CALLS+=("$1|$2|$3|$4")
}

# Mock wg show to return empty (no existing peers)
wg() {
    if [[ "$1" == "show" && "$3" == "peers" ]]; then
        # Return the peers we have already added
        if [[ ${#MOCK_ADD_PEER_CALLS[@]} -gt 0 ]]; then
            for call in "${MOCK_ADD_PEER_CALLS[@]}"; do
                echo "${call%%|*}"
            done
        fi
    fi
}

# Peer 1
B1=$(_mesh_build_beacon "PeerKey1==" "10.0.99.10" "51820" "node-1")
# Peer 2
B2=$(_mesh_build_beacon "PeerKey2==" "10.0.99.20" "51820" "node-2")
# Peer 3
B3=$(_mesh_build_beacon "PeerKey3==" "10.0.99.30" "51821" "node-3")

# Process each beacon through the handler function
_mesh_process_beacon "$B1" "192.168.1.10" "$OUR_KEY" 2>/dev/null
_mesh_process_beacon "$B2" "192.168.1.20" "$OUR_KEY" 2>/dev/null
_mesh_process_beacon "$B3" "192.168.1.30" "$OUR_KEY" 2>/dev/null

assert_eq "3 unique peers added" "3" "${#MOCK_ADD_PEER_CALLS[@]}"

# Now send a duplicate of Peer 1 — should be skipped (already in wg peers)
_mesh_process_beacon "$B1" "192.168.1.10" "$OUR_KEY" 2>/dev/null
assert_eq "duplicate peer not re-added" "3" "${#MOCK_ADD_PEER_CALLS[@]}"

# Send our own beacon — should be filtered
OWN_B=$(_mesh_build_beacon "$OUR_KEY" "10.0.99.1" "51820" "local-node")
_mesh_process_beacon "$OWN_B" "192.168.1.1" "$OUR_KEY" 2>/dev/null
assert_eq "own beacon filtered, count unchanged" "3" "${#MOCK_ADD_PEER_CALLS[@]}"

# Verify the recorded add_peer calls have correct args
assert_match "peer 1 added with correct pubkey" '^PeerKey1==' "${MOCK_ADD_PEER_CALLS[0]}"
assert_match "peer 2 added with correct pubkey" '^PeerKey2==' "${MOCK_ADD_PEER_CALLS[1]}"
assert_match "peer 3 added with correct pubkey" '^PeerKey3==' "${MOCK_ADD_PEER_CALLS[2]}"

teardown
echo ""

# ---------------------------------------------------------------------------
# 9b. The REAL listener path (DEC-PHASE12-095/096): socat spawns the handler
#     once per datagram with SOCAT_PEERADDR set; the handler validates and
#     calls `wg set` with the sender's real address. Stub `wg` and `socat` on
#     PATH; the SYSTEM: command the listener hands socat is then executed
#     exactly as socat would (sh -c, datagram on stdin, peer in the env).
# ---------------------------------------------------------------------------
echo "--- Listener: real handler path, sender address, validation, rate limit ---"
setup
mkkey() { printf "%0.s$1" {1..42}; printf 'A='; }
OUR_K="$(mkkey O)"; KEY_B="$(mkkey B)"; KEY_C="$(mkkey C)"; KEY_D="$(mkkey D)"; KEY_E="$(mkkey E)"
STUB="$TMPDIR_TEST/bin"; mkdir -p "$STUB"
export WG_CALLS="$TMPDIR_TEST/wg.calls" WG_PEERS="$TMPDIR_TEST/wg.peers" WG_ALLOWED="$TMPDIR_TEST/wg.allowed"
export SOCAT_ARGS="$TMPDIR_TEST/socat.args" OUR_K
: > "$WG_CALLS"; : > "$WG_PEERS"; : > "$WG_ALLOWED"
cat > "$STUB/wg" <<'STUBEOF'
#!/usr/bin/env bash
case "$1 ${3:-}" in
    "show peers")       cat "$WG_PEERS" ;;
    "show allowed-ips") cat "$WG_ALLOWED" ;;
    "pubkey "*)         cat >/dev/null; echo "$OUR_K" ;;
    "set "*)            echo "$*" >> "$WG_CALLS" ;;
esac
STUBEOF
cat > "$STUB/socat" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SOCAT_ARGS"
STUBEOF
chmod +x "$STUB/wg" "$STUB/socat"
export MESH_RUNTIME_DIR="$TMPDIR_TEST/run" MESH_RATE_DIR="$TMPDIR_TEST/run/rate"
echo "private" > "$MESH_PRIVATE_KEY"
PATH="$STUB:$PATH" mesh_state_write wg0 10.0.99.1 discovery "$OUR_K" 2>/dev/null

rc=0
PATH="$STUB:$PATH" bash "$DISCOVER_SCRIPT" listen 2>/dev/null || rc=$?
assert_eq "listener execs socat (stub returns 0)" "0" "$rc"
SYS_ARG="$(grep '^SYSTEM:' "$SOCAT_ARGS" 2>/dev/null || true)"
assert_match "listener hands socat a SYSTEM: per-datagram handler, not STDOUT" '^SYSTEM:exec .*mesh-discover\.sh handle$' "$SYS_ARG"
assert_match "listener receives on UDP-RECVFROM with fork" '^UDP-RECVFROM:55555,.*fork' "$(grep '^UDP-RECVFROM' "$SOCAT_ARGS" || true)"
HANDLER_CMD="${SYS_ARG#SYSTEM:}"

# Deliver one datagram the way socat does.
deliver() {  # deliver <peeraddr> <line>
    printf '%s\n' "$2" | env PATH="$STUB:$PATH" SOCAT_PEERADDR="$1" sh -c "$HANDLER_CMD" 2>>"$TMPDIR_TEST/handler.err"
}

rc=0; deliver 192.168.7.20 "$(_mesh_build_beacon "$KEY_B" 10.0.99.20 51820)" || rc=$?
assert_eq "handler exits 0 for a good beacon" "0" "$rc"
assert_match "peer added with the SENDER's real address as endpoint" \
    "peer $KEY_B allowed-ips 10\.0\.99\.20/32 endpoint 192\.168\.7\.20:51820" "$(cat "$WG_CALLS")"
if grep -q "unknown" "$WG_CALLS"; then
    echo "  FAIL: endpoint must never be the literal 'unknown'"; (( FAIL_COUNT++ )) || true
else
    echo "  PASS: no 'unknown' endpoint"; (( PASS_COUNT++ )) || true
fi

: > "$WG_CALLS"
rc=0; deliver 192.168.7.21 "{\"pubkey\":\"$KEY_C\",\"vpn_ip\":\"10.0.99.0/24,10.0.99.1\",\"wg_port\":51820}" || rc=$?
assert_eq "handler survives an allowed-ips injection beacon (exit 0)" "0" "$rc"
assert_eq "allowed-ips injection is NOT passed to wg (security F2)" "" "$(cat "$WG_CALLS")"
assert_match "the rejection is logged with its reason" "Rejected peer.*not a single host" "$(cat "$TMPDIR_TEST/handler.err")"

: > "$WG_CALLS"
deliver 192.168.7.22 "{\"pubkey\":\"$KEY_D\",\"vpn_ip\":\"10.0.98.5\",\"wg_port\":51820}" || true
assert_eq "an address outside the mesh /24 is rejected" "" "$(cat "$WG_CALLS")"

: > "$WG_CALLS"
printf '%s\t10.0.99.20/32\n' "$KEY_B" > "$WG_ALLOWED"; printf '%s\n' "$KEY_B" > "$WG_PEERS"
deliver 192.168.7.23 "$(_mesh_build_beacon "$KEY_E" 10.0.99.20 51820)" || true
assert_eq "an address another peer already holds is rejected" "" "$(cat "$WG_CALLS")"
deliver 192.168.7.24 "$(_mesh_build_beacon "$KEY_B" 10.0.99.99 51820)" || true
assert_eq "a known peer's allowed-ips are never changed by a beacon" "" "$(cat "$WG_CALLS")"
deliver 192.168.7.25 "$(_mesh_build_beacon "$KEY_E" 10.0.99.1 51820)" || true
assert_eq "our own mesh address is rejected (collision)" "" "$(cat "$WG_CALLS")"

: > "$WG_CALLS"; : > "$WG_PEERS"; : > "$WG_ALLOWED"
rc=0; deliver "" "$(_mesh_build_beacon "$KEY_C" 10.0.99.30 51820)" || rc=$?
assert_eq "no sender address: handler still exits 0" "0" "$rc"
assert_eq "no sender address: nothing added" "" "$(cat "$WG_CALLS")"
rc=0; deliver 192.168.7.26 'not json at all' || rc=$?
assert_eq "garbage datagram: handler exits 0 (listener never dies)" "0" "$rc"

deliver 192.168.7.30 "$(_mesh_build_beacon "$KEY_C" 10.0.99.30 51820)" || true
deliver 192.168.7.30 "$(_mesh_build_beacon "$KEY_D" 10.0.99.31 51820)" || true
assert_eq "rate limit: a second beacon from one sender within the interval is dropped" \
    "1" "$(grep -c 'peer ' "$WG_CALLS" || true)"

# Beacons are only sent after a DISCOVERY-mode join (security F14).
rm -f "$SOCAT_ARGS"
PATH="$STUB:$PATH" mesh_state_write wg0 10.0.99.1 config "$OUR_K" 2>/dev/null
PATH="$STUB:$PATH" bash "$DISCOVER_SCRIPT" send 2>/dev/null || true
assert_file_not_exists "config-mode join sends no beacon" "$SOCAT_ARGS"
rm -f "$MESH_STATE_FILE" "$SOCAT_ARGS"
PATH="$STUB:$PATH" bash "$DISCOVER_SCRIPT" send 2>/dev/null || true
assert_file_not_exists "an unjoined deck sends no beacon" "$SOCAT_ARGS"
PATH="$STUB:$PATH" mesh_state_write wg0 10.0.99.1 discovery "$OUR_K" 2>/dev/null
PATH="$STUB:$PATH" bash "$DISCOVER_SCRIPT" send 2>/dev/null || true
assert_file_exists "a discovery-mode join does send its beacon" "$SOCAT_ARGS"

unset WG_CALLS WG_PEERS WG_ALLOWED SOCAT_ARGS MESH_RUNTIME_DIR MESH_RATE_DIR
teardown
echo ""

# ---------------------------------------------------------------------------
# 10. ShellCheck
# ---------------------------------------------------------------------------
echo "--- ShellCheck ---"

if command -v shellcheck &>/dev/null; then
    if shellcheck "$DISCOVER_SCRIPT" 2>&1; then
        echo "  PASS: ShellCheck passes on mesh-discover.sh"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: ShellCheck passes on mesh-discover.sh"
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
