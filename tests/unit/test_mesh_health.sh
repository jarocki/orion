#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2329,SC2034
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
    if [[ -f "$filepath" ]] && grep -q -- "$pattern" "$filepath"; then
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

    # sleep: recorded, never actually slept. health_verify_handshake polls
    # MESH_HEAL_VERIFY_TRIES times; a real sleep would add 15s per heal.
    sleep() {
        echo "sleep $*" >> "$MOCK_CALLS_FILE"
        return 0
    }

    # orionx-event stub: records every published event so tests can assert
    # the BUS, not the journal. mesh_emit resolves MESH_EVENT_CLI at call
    # time, so assigning it here (after sourcing) is enough.
    EVENTS_FILE="$TMPDIR_TEST/events.log"
    true > "$EVENTS_FILE"
    MESH_EVENT_CLI="$TMPDIR_TEST/orionx-event"
    cat > "$MESH_EVENT_CLI" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${EVENTS_FILE:?}"
exit "${EVENT_CLI_RC:-0}"
STUBEOF
    chmod +x "$MESH_EVENT_CLI"
    export EVENTS_FILE
    export EVENT_CLI_RC=0

    # Discovery listener PID file. By default it points at THIS shell, which
    # is alive, so the default fixture is a fully-wired mesh.
    MESH_DISCOVER_PID_FILE="$TMPDIR_TEST/orionx-mesh-discover.pid"
    echo "$$" > "$MESH_DISCOVER_PID_FILE"

    # Pretend unit directory: by default FULLY wired (beacon installed).
    MESH_UNIT_DIR="$TMPDIR_TEST/units"
    mkdir -p "$MESH_UNIT_DIR"
    : > "$MESH_UNIT_DIR/orionx-mesh-beacon.service"

    # Reset tunables every test so one test cannot leak into the next.
    MESH_HANDSHAKE_STALE_SECS=180
    MESH_AGGRESSIVE_THRESHOLD=2
    MESH_MAX_AGGRESSIVE_HEALS=2
    MESH_HEAL_VERIFY_TRIES=3
    MESH_HEAL_VERIFY_WAIT=5
    HEALTH_LAST_HEAL_VERIFIED="unverified"

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

# DEC-PHASE12-041: restore goes through mesh_interface_up (ip link add /
# wg set) — the SAME authority that created the interface in `orionx-mesh
# join`. It used to call `wg-quick up wg0`, which could never succeed:
# nothing in Orion-X ever writes /etc/wireguard/wg0.conf, and wg-quick
# parses that file before it does anything.
_mock_ip_link_show_rc=1
mesh_state_write "wg0" "10.0.99.7" "join" "SomePubKey=="

rc=0
health_check_interface 2>/dev/null || rc=$?

assert_file_contains "restore creates the wireguard interface itself" \
    "$MOCK_CALLS_FILE" "ip link add dev wg0 type wireguard"
assert_file_contains "restore re-applies the stored VPN address" \
    "$MOCK_CALLS_FILE" "ip addr add 10.0.99.7/24"

# The dead authority must not come back.
if grep -q "wg-quick" "$MOCK_CALLS_FILE"; then
    echo "  FAIL: restore still calls wg-quick (no wg0.conf exists; it cannot work)"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: restore does not call wg-quick (dead authority removed)"
    (( PASS_COUNT++ )) || true
fi

# Verify log mentions missing interface
assert_file_contains "log mentions missing interface" "$MESH_LOG_FILE" "missing"

teardown
echo ""

# ---------------------------------------------------------------------------
# 4. Interface check — restore fails returns error
# ---------------------------------------------------------------------------
echo "--- Interface Check: Restore Failure ---"
setup

# No mesh state => no VPN address to rebuild with. The old code answered
# this by shelling out to wg-quick and logging an ERROR nobody reads; it
# must now fail AND tell the operator, on the bus, what to run.
_mock_ip_link_show_rc=1
# (no mesh_state_write: this deck has not joined a mesh)

rc=0
health_check_interface 2>/dev/null || rc=$?

assert_eq "interface check returns 1 when it cannot restore" "1" "$rc"
assert_file_contains "unrestorable interface reaches the R.A.I.N. bus" \
    "$EVENTS_FILE" "--severity critical"
assert_file_contains "escalation names the remedy" \
    "$EVENTS_FILE" "orionx-mesh join"
assert_file_contains "escalation uses a STATUS category, not a threat one" \
    "$EVENTS_FILE" "--category health"

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

# DEC-PHASE12-041: the heal bounces the LINK. `ip link set wg0 down/up`
# drops and rebinds the socket and forces new handshakes while preserving
# the private key, the address and every peer. `wg-quick down && up` would
# have destroyed all of it — and in practice did nothing at all.
assert_file_contains "link bounced down" "$MOCK_CALLS_FILE" "ip link set wg0 down"
assert_file_contains "link bounced up" "$MOCK_CALLS_FILE" "ip link set wg0 up"

if grep -q "wg-quick" "$MOCK_CALLS_FILE"; then
    echo "  FAIL: aggressive heal still calls wg-quick"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: aggressive heal does not call wg-quick"
    (( PASS_COUNT++ )) || true
fi

if grep -q "ip link delete" "$MOCK_CALLS_FILE"; then
    echo "  FAIL: aggressive heal destroys the interface (peers would be lost)"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: aggressive heal preserves peers (no interface delete)"
    (( PASS_COUNT++ )) || true
fi

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

# Verify the aggressive heal actually bounced the link
assert_file_contains "aggressive heal bounced link down" "$MOCK_CALLS_FILE" "ip link set wg0 down"
assert_file_contains "aggressive heal bounced link up" "$MOCK_CALLS_FILE" "ip link set wg0 up"
assert_eq "the heal is reported as UNVERIFIED (no handshake followed)" \
    "no" "$HEALTH_LAST_HEAL_VERIFIED"
assert_eq "the mesh-wide heal budget was spent" "1" "$(health_read_budget)"

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
# 28. PLAN — health_plan_action is pure and covers the whole decision table
#
# @decision DEC-PHASE12-041
# RESILIENCE "Plan": desired behaviour as data, separate from the code that
# applies it. If this table is wrong, every test below is wrong too — so it
# is asserted directly, with no mocks and no filesystem.
# ---------------------------------------------------------------------------
echo "--- Plan: decision table ---"
setup

#                      staleness ping  fails others budget escalated
assert_eq "fresh handshake needs no action" "none" \
    "$(health_plan_action fresh fail 9 0 9 0)"
assert_eq "already escalated holds silent" "hold" \
    "$(health_plan_action stale fail 9 0 9 1)"
assert_eq "stale but pingable is a soft heal only" "soft" \
    "$(health_plan_action stale ok 9 0 0 0)"
assert_eq "below the failure threshold is a soft heal" "soft" \
    "$(health_plan_action stale fail 1 0 0 0)"
assert_eq "at threshold with healthy peers reports the PEER, never bounces" "escalate-peer" \
    "$(health_plan_action stale fail 2 1 0 0)"
assert_eq "at threshold with no healthy peers bounces the interface" "aggressive" \
    "$(health_plan_action stale fail 2 0 0 0)"
assert_eq "second bounce is still inside the budget" "aggressive" \
    "$(health_plan_action stale fail 5 0 1 0)"
assert_eq "budget exhausted escalates and stops" "escalate-mesh" \
    "$(health_plan_action stale fail 5 0 2 0)"
assert_eq "over-spent budget still escalates (never wraps back to healing)" "escalate-mesh" \
    "$(health_plan_action stale fail 99 0 99 0)"

teardown
echo ""

# ---------------------------------------------------------------------------
# 29. The original defect: ONE powered-off peer must not bounce the interface
#     for the healthy ones, and must not do it forever.
#
# Measured on rc4: timer every 60s, threshold 2, stale after 180s ->
# `wg-quick down wg0 && wg-quick up wg0` every ~2 minutes, indefinitely,
# because health_clear_all_counters() reset the budget after every heal.
# ---------------------------------------------------------------------------
echo "--- Regression: one dead peer, two healthy ones, 20 timer firings ---"
setup

NOW="$(date +%s)"
RECENT=$((NOW - 30))
OLD=$((NOW - 600))

_mock_wg_dump_output="GoodPeer1XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.10:51820	10.0.99.10/32	${RECENT}	1	1	off
GoodPeer2XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.11:51820	10.0.99.11/32	${RECENT}	1	1	off
DeadPeer3XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.12:51820	10.0.99.12/32	${OLD}	1	1	off"
_mock_ping_rc=1

for _i in $(seq 1 20); do
    health_check_all_peers 2>/dev/null
done

BOUNCES="$(grep -c "ip link set wg0 down" "$MOCK_CALLS_FILE" || true)"
assert_eq "20 timer firings produced ZERO interface bounces" "0" "$BOUNCES"

if grep -q "wg-quick" "$MOCK_CALLS_FILE"; then
    echo "  FAIL: wg-quick is still being invoked"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: wg-quick never invoked"
    (( PASS_COUNT++ )) || true
fi

CRITS="$(grep -c "severity warning" "$EVENTS_FILE" || true)"
assert_eq "the dead peer is reported exactly ONCE, not 20 times" "1" "$CRITS"
assert_file_contains "the report names the peer" "$EVENTS_FILE" "DeadPeer"
assert_file_contains "the report says the mesh is still working" "$EVENTS_FILE" "other peer"
assert_file_contains "the report names a diagnosis command" "$EVENTS_FILE" "latest-handshakes"

teardown
echo ""

# ---------------------------------------------------------------------------
# 30. Bounded repair: when EVERY peer is stale the interface is bounced,
#     but only MESH_MAX_AGGRESSIVE_HEALS times — then it escalates and stops.
# ---------------------------------------------------------------------------
echo "--- Repair is bounded: whole mesh down, 20 timer firings ---"
setup

MESH_MAX_AGGRESSIVE_HEALS=2
NOW="$(date +%s)"
OLD=$((NOW - 600))

_mock_wg_dump_output="LonePeerXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX==	(none)	192.168.1.20:51820	10.0.99.20/32	${OLD}	1	1	off"
_mock_ping_rc=1

for _i in $(seq 1 20); do
    health_check_all_peers 2>/dev/null
done

BOUNCES="$(grep -c "ip link set wg0 down" "$MOCK_CALLS_FILE" || true)"
assert_eq "interface bounced exactly MESH_MAX_AGGRESSIVE_HEALS times" "2" "$BOUNCES"
assert_eq "budget records both bounces and is not reset by them" "2" "$(health_read_budget)"

CRITS="$(grep -c "severity critical" "$EVENTS_FILE" || true)"
assert_eq "gave up with exactly one critical event" "1" "$CRITS"
assert_file_contains "critical says it is not retrying" "$EVENTS_FILE" "Not retrying"
assert_file_contains "critical names what still works" "$EVENTS_FILE" "unaffected"
assert_file_contains "critical is self-status, not a threat" "$EVENTS_FILE" "category health"

teardown
echo ""

# ---------------------------------------------------------------------------
# 31. LOOP: only a real handshake resets the budget.
# ---------------------------------------------------------------------------
echo "--- Loop: a confirmed handshake resets the budget ---"
setup

PUBKEY="BudgetPeerXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
SHORT_KEY="${PUBKEY:0:8}"
NOW="$(date +%s)"
RECENT=$((NOW - 10))

health_consume_budget
health_consume_budget
health_mark_escalated "$SHORT_KEY"
assert_eq "budget is spent before the handshake" "2" "$(health_read_budget)"

health_check_peer "$PUBKEY" "1.2.3.4:51820" "10.0.99.30/32" "$RECENT" "$NOW" 0 2>/dev/null

assert_eq "a fresh handshake clears the heal budget" "0" "$(health_read_budget)"
if health_has_escalated "$SHORT_KEY"; then
    echo "  FAIL: escalation marker survived a confirmed handshake"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: escalation marker cleared by a confirmed handshake"
    (( PASS_COUNT++ )) || true
fi
assert_file_contains "recovery is announced on the bus" "$EVENTS_FILE" "is back"

teardown
echo ""

# ---------------------------------------------------------------------------
# 32. Silence after escalation — no soft heal, no event, no work.
# ---------------------------------------------------------------------------
echo "--- Silence after escalation ---"
setup

PUBKEY="QuietPeerXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
SHORT_KEY="${PUBKEY:0:8}"
NOW="$(date +%s)"
OLD=$((NOW - 600))
health_mark_escalated "$SHORT_KEY"
_mock_ping_rc=1

rc=0
health_check_peer "$PUBKEY" "1.2.3.4:51820" "10.0.99.40/32" "$OLD" "$NOW" 0 2>/dev/null || rc=$?

assert_eq "an escalated peer returns the terminal code" "3" "$rc"
if grep -q "wg set" "$MOCK_CALLS_FILE"; then
    echo "  FAIL: escalated peer was still soft-healed"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: escalated peer is left alone (no soft heal)"
    (( PASS_COUNT++ )) || true
fi
assert_eq "no further events published" "0" "$(wc -l < "$EVENTS_FILE" | tr -d ' ')"

teardown
echo ""
# ---------------------------------------------------------------------------
# 33. CHECK — a heal reports what actually happened, not what it attempted
#
# RESILIENCE rule 3. The old health_aggressive_heal ran two commands that
# could not work and returned "aggressive heal triggered" regardless.
# ---------------------------------------------------------------------------
echo "--- Check: heal verification reads reality back ---"
setup

PUBKEY="VerifyPeerXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
SHORT_KEY="${PUBKEY:0:8}"
NOW="$(date +%s)"
FRESH=$((NOW - 5))

# After the bounce, the kernel reports a fresh handshake for this peer.
_mock_wg_dump_output="${PUBKEY}	(none)	192.168.1.50:51820	10.0.99.50/32	${FRESH}	1	1	off"
health_increment_counter "$SHORT_KEY"
health_consume_budget

health_aggressive_heal "$SHORT_KEY" "$PUBKEY" 2>/dev/null

assert_eq "a heal followed by a real handshake is reported verified" \
    "yes" "$HEALTH_LAST_HEAL_VERIFIED"
assert_eq "a verified heal resets the budget" "0" "$(health_read_budget)"

teardown
echo ""

echo "--- Check: an ineffective heal is NOT reported as success ---"
setup

PUBKEY="StillDeadXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=="
SHORT_KEY="${PUBKEY:0:8}"
NOW="$(date +%s)"
OLD=$((NOW - 600))

_mock_wg_dump_output="${PUBKEY}	(none)	192.168.1.51:51820	10.0.99.51/32	${OLD}	1	1	off"
health_consume_budget

health_aggressive_heal "$SHORT_KEY" "$PUBKEY" 2>/dev/null

assert_eq "no handshake means the heal is reported as failed" \
    "no" "$HEALTH_LAST_HEAL_VERIFIED"
assert_eq "an unverified heal does NOT refund the budget" "1" "$(health_read_budget)"
assert_file_contains "verification is bounded, not a loop" "$MOCK_CALLS_FILE" "sleep 5"
SLEEPS="$(grep -c "^sleep " "$MOCK_CALLS_FILE" || true)"
assert_eq "verification polls exactly MESH_HEAL_VERIFY_TRIES times" "3" "$SLEEPS"

teardown
echo ""

# ---------------------------------------------------------------------------
# 34. The bus: mesh self-healing may never be published as a THREAT
#
# DEC-PHASE12-040 / RESILIENCE rule 5. A powered-off peer moving THREAT
# PRESSURE is the orionx-postured gauge defect all over again.
# ---------------------------------------------------------------------------
echo "--- Bus: category vocabulary is enforced, not documented ---"
setup

rc=0
mesh_emit warning health "a status message" 2>/dev/null || rc=$?
assert_eq "'health' is accepted" "0" "$rc"

rc=0
mesh_emit warning service "a status message" 2>/dev/null || rc=$?
assert_eq "'service' is accepted" "0" "$rc"

for _bad in ids intrusion scan malware general; do
    rc=0
    mesh_emit warning "$_bad" "should never be published" 2>/dev/null || rc=$?
    assert_eq "'$_bad' is refused (would count as a threat)" "2" "$rc"
done

EMITTED="$(grep -c "should never be published" "$EVENTS_FILE" || true)"
assert_eq "refused categories reach the bus zero times" "0" "$EMITTED"

teardown
echo ""

echo "--- Bus: an unpublished event is never reported as published ---"
setup

MESH_EVENT_CLI="$TMPDIR_TEST/definitely-not-installed"
rc=0
mesh_emit critical health "nobody will hear this" 2>/dev/null || rc=$?
assert_eq "a missing orionx-event is reported as a failure" "1" "$rc"
assert_file_contains "and says so in the log" "$MESH_LOG_FILE" "NOT published"

setup
export EVENT_CLI_RC=7
rc=0
mesh_emit critical health "the CLI will reject this" 2>/dev/null || rc=$?
assert_eq "a non-zero orionx-event exit is reported as a failure" "1" "$rc"
assert_file_contains "and says so in the log" "$MESH_LOG_FILE" "NOT published"
export EVENT_CLI_RC=0

teardown
echo ""

# ---------------------------------------------------------------------------
# 35. Discovery wiring — degrade loudly about the 0615 gap (defect 3)
#
# orionx-mesh-discover.timer has Unit=orionx-mesh-beacon.service, but that
# unit is absent from UNIT_FILES in 0615, so the timer fires at nothing and
# the listener is never triggered either. mesh-health cannot repair a build
# hook; it can refuse to let the operator find out by accident.
# ---------------------------------------------------------------------------
echo "--- Discovery wiring: silent when wired, loud once when not ---"
setup

rc=0
health_check_discovery 2>/dev/null || rc=$?
assert_eq "fully wired discovery produces no complaint" "0" "$rc"
assert_eq "and publishes nothing" "0" "$(wc -l < "$EVENTS_FILE" | tr -d ' ')"

teardown
setup

# The shipped state: beacon unit was never installed.
rm -f "$MESH_UNIT_DIR/orionx-mesh-beacon.service"

rc=0
health_check_discovery 2>/dev/null || rc=$?
assert_eq "a dangling timer target is reported" "1" "$rc"
assert_file_contains "names the missing unit" "$EVENTS_FILE" "orionx-mesh-beacon.service"
assert_file_contains "names the consequence" "$EVENTS_FILE" "no NEW peer"
assert_file_contains "names what still works" "$EVENTS_FILE" "still work"
assert_file_contains "names the exact remedy" "$EVENTS_FILE" "UNIT_FILES"
assert_file_contains "is self-status, not a threat" "$EVENTS_FILE" "category health"

# Bounded: 60 further timer firings must not add 60 more events.
for _i in $(seq 1 60); do
    health_check_discovery 2>/dev/null || true
done
ANNOUNCE="$(grep -c "orionx-mesh-beacon.service" "$EVENTS_FILE" || true)"
assert_eq "announced exactly once per boot, not once per minute" "1" "$ANNOUNCE"

teardown
echo ""

echo "--- Discovery wiring: a stopped listener is reported too ---"
setup

# A PID file left behind by a listener that died (the live-overlay /run is a
# tmpfs, so a stale PID file is exactly what a crashed listener leaves).
echo "999999" > "$MESH_DISCOVER_PID_FILE"
rc=0
health_check_discovery 2>/dev/null || rc=$?
assert_eq "a dead listener behind a stale PID file is reported" "1" "$rc"
assert_file_contains "names the missing listener" "$EVENTS_FILE" "discovery listener"

teardown
echo ""

echo "--- Discovery wiring: a missing PID file is reported ---"
setup
rm -f "$MESH_DISCOVER_PID_FILE"
rc=0
health_check_discovery 2>/dev/null || rc=$?
assert_eq "no PID file at all is reported" "1" "$rc"
assert_file_contains "names the path the operator should look at" \
    "$EVENTS_FILE" "orionx-mesh-discover.pid"

teardown
echo ""

# ---------------------------------------------------------------------------
# 36. The dead wg-quick authority must not come back (rule 7)
# ---------------------------------------------------------------------------
echo "--- Dead authority: wg-quick is gone from the healing path ---"

# Any line that is not a comment and mentions wg-quick is a regression.
WGQ_CODE="$(grep -n 'wg-quick' "$HEALTH_SCRIPT" | grep -vE ':[[:space:]]*#' || true)"
if [[ -n "$WGQ_CODE" ]]; then
    echo "  FAIL: mesh-health.sh has executable wg-quick references again:"
    echo "$WGQ_CODE"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: no executable wg-quick reference in mesh-health.sh"
    (( PASS_COUNT++ )) || true
fi

# And the restore path must use the interface authority instead.
if grep -q 'mesh_interface_up' "$HEALTH_SCRIPT"; then
    echo "  PASS: interface restore uses mesh_interface_up (single authority)"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: interface restore no longer uses mesh_interface_up"
    (( FAIL_COUNT++ )) || true
fi

if grep -q 'DEC-PHASE12-041' "$HEALTH_SCRIPT"; then
    echo "  PASS: has @decision DEC-PHASE12-041 annotation"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: missing @decision DEC-PHASE12-041 annotation"
    (( FAIL_COUNT++ )) || true
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
