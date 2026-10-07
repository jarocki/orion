#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2329
#
# Orion-X Phoenix Edition — Unit Tests for mesh-join.sh & mesh-leave.sh
#
# Tests join and leave logic without root privileges or live WireGuard.
# Uses function overrides (test doubles) to intercept WireGuard calls
# and record invocations for assertion.
#
# @decision DEC-MESH-TEST-002
# @title Unit test suite for mesh join/leave logic
# @status accepted
# @rationale Tests the join/leave orchestration logic (idempotency checks,
#   config-mode vs discovery-mode branching, state file management, cleanup)
#   using mock overrides for WireGuard operations. Real WireGuard integration
#   tests belong in Docker-based integration tests, not unit tests.
#
# Production sequence: Responder runs `orionx-mesh join`, which sources
# mesh-join.sh and calls mesh_join. If a config is provided, it enters
# pre-planned mode; otherwise discovery mode. Later, `orionx-mesh leave`
# sources mesh-leave.sh and calls mesh_leave, which tears everything down.
# Tests exercise both paths plus the idempotency guard and error cases.
#
# Usage:  bash tests/unit/test_mesh_join.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Test framework (matches test_mesh_lib.sh conventions)
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
    export MESH_DISCOVER_PORT="55555"

    # Create log directory so mesh_log can write
    mkdir -p "$(dirname "$MESH_LOG_FILE")"

    # Reset call tracking files
    MOCK_CALLS_FILE="$TMPDIR_TEST/mock_calls.log"
    > "$MOCK_CALLS_FILE"

    MOCK_DISCOVER_PID_FILE="$TMPDIR_TEST/discover.pid"

    # --- Mock overrides ---
    # These replace WireGuard-dependent functions with test doubles
    # that record calls for later assertion.

    mesh_genkeys() {
        echo "mock_genkeys" >> "$MOCK_CALLS_FILE"
        # Create a fake private key so mesh_get_pubkey works
        echo "fake-private-key" > "$MESH_PRIVATE_KEY"
        echo "MockPublicKeyABC123=="
    }

    mesh_get_pubkey() {
        echo "MockPublicKeyABC123=="
    }

    # DEC-PHASE12-097: join drives units through MESH_SYSTEMCTL; record calls.
    export MESH_FORCE_SYSTEMD=1
    export SYSTEMCTL_CALLS="$TMPDIR_TEST/systemctl.calls"
    : > "$SYSTEMCTL_CALLS"
    cat > "$TMPDIR_TEST/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$SYSTEMCTL_CALLS"
[[ "$1" == "is-active" ]] && echo active
exit 0
STUBEOF
    chmod +x "$TMPDIR_TEST/systemctl"
    export MESH_SYSTEMCTL="$TMPDIR_TEST/systemctl"
    export MESH_HEALTH_COUNTER_DIR="$TMPDIR_TEST/run"
    mkdir -p "$MESH_HEALTH_COUNTER_DIR"

    mesh_get_vpn_ip() {
        echo "mock_get_vpn_ip" >> "$MOCK_CALLS_FILE"
        echo "10.0.99.42"
    }

    mesh_interface_up() {
        echo "mock_interface_up $*" >> "$MOCK_CALLS_FILE"
    }

    mesh_interface_down() {
        echo "mock_interface_down" >> "$MOCK_CALLS_FILE"
    }

    mesh_add_peer() {
        echo "mock_add_peer $*" >> "$MOCK_CALLS_FILE"
    }

    # Mock mesh_is_active: default to inactive (return 1)
    # Tests override this as needed.
    _mock_is_active=1
    mesh_is_active() {
        return $_mock_is_active
    }
}

teardown() {
    rm -rf "$TMPDIR_TEST"
    # Reset mock state
    _mock_is_active=1
}

# ---------------------------------------------------------------------------
# Source libraries under test
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MESH_LIB="$REPO_ROOT/scripts/mesh/mesh-lib.sh"
JOIN_SCRIPT="$REPO_ROOT/scripts/mesh/mesh-join.sh"
LEAVE_SCRIPT="$REPO_ROOT/scripts/mesh/mesh-leave.sh"

if [[ ! -f "$MESH_LIB" ]]; then
    echo "ERROR: mesh-lib.sh not found at $MESH_LIB"
    exit 1
fi

# Source the library first (provides constants, mesh_log, state funcs)
# shellcheck source=../../scripts/mesh/mesh-lib.sh
source "$MESH_LIB"

# =========================================================================
# Test suites
# =========================================================================

echo "=== mesh-join.sh / mesh-leave.sh Unit Tests ==="
echo ""

# ---------------------------------------------------------------------------
# 0. File structure
# ---------------------------------------------------------------------------
echo "--- File Structure ---"

assert_file_exists "mesh-join.sh exists" "$JOIN_SCRIPT"
assert_file_exists "mesh-leave.sh exists" "$LEAVE_SCRIPT"

# Check shellcheck directive
if head -1 "$JOIN_SCRIPT" | grep -q '# shellcheck shell=bash'; then
    echo "  PASS: mesh-join.sh has shellcheck directive"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-join.sh missing shellcheck directive"
    (( FAIL_COUNT++ )) || true
fi

if head -1 "$LEAVE_SCRIPT" | grep -q '# shellcheck shell=bash'; then
    echo "  PASS: mesh-leave.sh has shellcheck directive"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-leave.sh missing shellcheck directive"
    (( FAIL_COUNT++ )) || true
fi

# Check set -euo pipefail
if grep -q 'set -euo pipefail' "$JOIN_SCRIPT"; then
    echo "  PASS: mesh-join.sh has strict mode"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-join.sh missing strict mode"
    (( FAIL_COUNT++ )) || true
fi

if grep -q 'set -euo pipefail' "$LEAVE_SCRIPT"; then
    echo "  PASS: mesh-leave.sh has strict mode"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-leave.sh missing strict mode"
    (( FAIL_COUNT++ )) || true
fi

# Check functions are defined (so they can be sourced and called)
if grep -q '^mesh_join()' "$JOIN_SCRIPT"; then
    echo "  PASS: mesh-join.sh defines mesh_join function"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-join.sh missing mesh_join function"
    (( FAIL_COUNT++ )) || true
fi

if grep -q '^mesh_leave()' "$LEAVE_SCRIPT"; then
    echo "  PASS: mesh-leave.sh defines mesh_leave function"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: mesh-leave.sh missing mesh_leave function"
    (( FAIL_COUNT++ )) || true
fi

echo ""

# Source the scripts under test (after mocks are established in setup)
# We source them here to get the function definitions, then override
# WG-dependent functions in each test's setup.
# shellcheck source=../../scripts/mesh/mesh-join.sh
source "$JOIN_SCRIPT"
# shellcheck source=../../scripts/mesh/mesh-leave.sh
source "$LEAVE_SCRIPT"

# ---------------------------------------------------------------------------
# 1. Join: idempotency — already active
# ---------------------------------------------------------------------------
echo "--- Join: Idempotency ---"
setup

_mock_is_active=0  # mesh_is_active returns 0 (active)

OUTPUT=$(mesh_join "" 2>&1)
rc=$?

assert_eq "join exits 0 when already active" "0" "$rc"
assert_match "join prints 'Already in mesh' message" "Already in mesh" "$OUTPUT"

# Verify no WG operations were called
if [[ -s "$MOCK_CALLS_FILE" ]]; then
    echo "  FAIL: join should not call WG functions when already active"
    echo "        calls: $(cat "$MOCK_CALLS_FILE")"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: no WG functions called when already active"
    (( PASS_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 2. Join: discovery mode (no config)
# ---------------------------------------------------------------------------
echo "--- Join: Discovery Mode ---"
setup

_mock_is_active=1  # not active

OUTPUT=$(mesh_join "" 2>&1)
rc=$?

assert_eq "join discovery mode exits 0" "0" "$rc"

# Verify key generation was called
assert_file_contains "genkeys was called" "$MOCK_CALLS_FILE" "mock_genkeys"
assert_file_not_exists "join never invents a team PSK (DEC-PHASE12-098)" "$MESH_PSK_FILE"
assert_file_contains "get_vpn_ip was called" "$MOCK_CALLS_FILE" "mock_get_vpn_ip"
assert_file_contains "interface_up was called" "$MOCK_CALLS_FILE" "mock_interface_up"

# Verify state file was written
assert_file_exists "state file created" "$MESH_STATE_FILE"

# Read back state
IFACE_READ="$(mesh_state_read interface)"
assert_eq "state: interface is wg0" "wg0" "$IFACE_READ"

VPN_IP_READ="$(mesh_state_read vpn_ip)"
assert_eq "state: vpn_ip is 10.0.99.42" "10.0.99.42" "$VPN_IP_READ"

MODE_READ="$(mesh_state_read mode)"
assert_eq "state: mode is discovery" "discovery" "$MODE_READ"

PUBKEY_READ="$(mesh_state_read pubkey)"
assert_match "state: pubkey recorded" "MockPublicKeyABC123==" "$PUBKEY_READ"

# Verify success message includes key info
assert_match "output shows Interface" "Interface.*wg0" "$OUTPUT"
assert_match "output shows VPN IP" "VPN IP.*10\.0\.99\.42" "$OUTPUT"
assert_match "output shows Mode discovery" "Mode.*discovery" "$OUTPUT"

teardown
echo ""

# ---------------------------------------------------------------------------
# 3. Join: pre-planned config mode
# ---------------------------------------------------------------------------
echo "--- Join: Config Mode ---"
setup

_mock_is_active=1  # not active

# Create a test config file
CONFIG_FILE="$TMPDIR_TEST/peers.conf"
cat > "$CONFIG_FILE" << 'CONFEOF'
# Test mesh config
node-alpha ABC123PubKeyAlpha== 10.0.99.1 192.168.1.10 51820
node-beta  DEF456PubKeyBeta== 10.0.99.2 192.168.1.20 51820
node-gamma GHI789PubKeyGamma== 10.0.99.3 192.168.1.30 51821
CONFEOF

OUTPUT=$(mesh_join "$CONFIG_FILE" 2>&1)
rc=$?

assert_eq "join config mode exits 0" "0" "$rc"

# Verify mesh_add_peer was called for each peer
PEER_CALLS=$(grep -c "mock_add_peer" "$MOCK_CALLS_FILE" || true)
assert_eq "add_peer called 3 times" "3" "$PEER_CALLS"

# Verify specific peer data was passed
assert_file_contains "peer alpha added" "$MOCK_CALLS_FILE" "ABC123PubKeyAlpha=="
assert_file_contains "peer beta added" "$MOCK_CALLS_FILE" "DEF456PubKeyBeta=="
assert_file_contains "peer gamma added" "$MOCK_CALLS_FILE" "GHI789PubKeyGamma=="

# Verify state records config mode
MODE_READ="$(mesh_state_read mode)"
assert_eq "state: mode is config" "config" "$MODE_READ"

# Verify success message
assert_match "output shows Mode config" "Mode.*config" "$OUTPUT"

teardown
echo ""

# ---------------------------------------------------------------------------
# 4. Join: config mode with empty config
# ---------------------------------------------------------------------------
echo "--- Join: Config Mode (empty config) ---"
setup

_mock_is_active=1

CONFIG_FILE="$TMPDIR_TEST/empty.conf"
cat > "$CONFIG_FILE" << 'CONFEOF'
# Only comments
# No peers
CONFEOF

OUTPUT=$(mesh_join "$CONFIG_FILE" 2>&1)
rc=$?

assert_eq "join with empty config exits 0" "0" "$rc"

# No peers should be added
PEER_CALLS=$(grep -c "mock_add_peer" "$MOCK_CALLS_FILE" || true)
assert_eq "add_peer called 0 times for empty config" "0" "$PEER_CALLS"

# Mode should still be config
MODE_READ="$(mesh_state_read mode)"
assert_eq "state: mode is config even with empty config" "config" "$MODE_READ"

teardown
echo ""

# ---------------------------------------------------------------------------
# 5. Leave: clean teardown
# ---------------------------------------------------------------------------
echo "--- Leave: Clean Teardown ---"
setup

# Simulate active mesh: create state file
mesh_state_write "wg0" "10.0.99.42" "discovery" "MockPublicKeyABC123=="
_mock_is_active=0  # active

OUTPUT=$(mesh_leave 2>&1)
rc=$?

assert_eq "leave exits 0" "0" "$rc"

# Verify interface_down was called
assert_file_contains "interface_down was called" "$MOCK_CALLS_FILE" "mock_interface_down"

# Verify state file was removed
assert_file_not_exists "state file removed" "$MESH_STATE_FILE"

# Verify output message
assert_match "leave prints confirmation" "Left the mesh" "$OUTPUT"

teardown
echo ""

# ---------------------------------------------------------------------------
# 6. Leave: not active
# ---------------------------------------------------------------------------
echo "--- Leave: Not Active ---"
setup

_mock_is_active=1  # not active

OUTPUT=$(mesh_leave 2>&1)
rc=$?

assert_eq "leave exits 0 when not active" "0" "$rc"
assert_match "leave prints 'Not in a mesh' message" "Not in a mesh" "$OUTPUT"

# Verify no teardown operations
if grep -q "mock_interface_down" "$MOCK_CALLS_FILE" 2>/dev/null; then
    echo "  FAIL: leave should not call interface_down when not active"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: no interface_down called when not active"
    (( PASS_COUNT++ )) || true
fi

teardown
echo ""

# ---------------------------------------------------------------------------
# 7. Leave: cleans up PID file
# ---------------------------------------------------------------------------
echo "--- Leave: PID File Cleanup ---"
setup

mesh_state_write "wg0" "10.0.99.42" "discovery" "MockPublicKeyABC123=="
_mock_is_active=0

# Create a fake PID file with a non-existent PID
MESH_DISCOVER_PID_FILE="$TMPDIR_TEST/discover.pid"
export MESH_DISCOVER_PID_FILE
echo "99999999" > "$MESH_DISCOVER_PID_FILE"

OUTPUT=$(mesh_leave 2>&1)
rc=$?

assert_eq "leave exits 0 with stale PID" "0" "$rc"
assert_file_not_exists "PID file removed" "$MESH_DISCOVER_PID_FILE"

teardown
echo ""

# ---------------------------------------------------------------------------
# 8. Production sequence: join → leave → join again
# ---------------------------------------------------------------------------
echo "--- Production Sequence: Join-Leave-Join ---"
setup

_mock_is_active=1  # start inactive

# First join
OUTPUT1=$(mesh_join "" 2>&1)
rc1=$?
assert_eq "first join exits 0" "0" "$rc1"
assert_file_exists "state file exists after join" "$MESH_STATE_FILE"

# Simulate that mesh is now active
_mock_is_active=0

# Leave
OUTPUT2=$(mesh_leave 2>&1)
rc2=$?
assert_eq "leave exits 0" "0" "$rc2"
assert_file_not_exists "state file gone after leave" "$MESH_STATE_FILE"

# Now inactive again
_mock_is_active=1

# Clear mock calls for clean tracking
> "$MOCK_CALLS_FILE"

# Second join
OUTPUT3=$(mesh_join "" 2>&1)
rc3=$?
assert_eq "second join exits 0" "0" "$rc3"
assert_file_exists "state file exists after re-join" "$MESH_STATE_FILE"

# Verify full cycle completed
assert_file_contains "genkeys called on re-join" "$MOCK_CALLS_FILE" "mock_genkeys"
assert_file_contains "interface_up called on re-join" "$MOCK_CALLS_FILE" "mock_interface_up"

teardown
echo ""

# ---------------------------------------------------------------------------
# 9. Join: interface_up receives correct VPN IP
# ---------------------------------------------------------------------------
echo "--- Join: Interface Setup ---"
setup

_mock_is_active=1

mesh_join "" 2>/dev/null
rc=$?

assert_eq "join exits 0" "0" "$rc"

# Verify interface_up was called with the VPN IP
assert_file_contains "interface_up called with VPN IP" "$MOCK_CALLS_FILE" "mock_interface_up 10.0.99.42"

teardown
echo ""

# ---------------------------------------------------------------------------
# 10. DEC-PHASE12-097: join STARTS every runtime unit leave STOPS, via
#     systemctl — never a listener forked into the operator's terminal.
# ---------------------------------------------------------------------------
echo "--- Join/Leave: the same mesh units, started and stopped ---"
setup
_mock_is_active=1
OUTPUT="$(mesh_join "" 2>/dev/null)"
assert_match "join says whether it survives reboot, from tuning_lib (UX-27)" "survives reboot: (NO|PARTLY)" "$OUTPUT"
STARTED="$(awk '$1=="start"{print $2}' "$SYSTEMCTL_CALLS" | sort -u)"
for u in orionx-mesh-discover.service orionx-mesh-discover.timer orionx-mesh-health.timer orionx-mesh-status.timer; do
    if grep -qxF "$u" <<< "$STARTED"; then echo "  PASS: discovery join starts $u"; (( PASS_COUNT++ )) || true; else echo "  FAIL: discovery join starts $u"; (( FAIL_COUNT++ )) || true; fi
done
assert_file_not_exists "join does not fork a listener PID file of its own" "$MESH_DISCOVER_PID_FILE"

# leave stops at least everything join started
_mock_is_active=0
: > "$SYSTEMCTL_CALLS"
LOUT="$(mesh_leave 2>/dev/null)"
assert_match "leave states its reboot behaviour (UX-27)" "survives reboot:" "$LOUT"
STOPPED="$(awk '$1=="stop"{print $2}' "$SYSTEMCTL_CALLS" | sort -u)"
MISSING=""
while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    grep -qxF "$u" <<< "$STOPPED" || MISSING+=" $u"
done <<< "$STARTED"
assert_eq "every unit join started is stopped by leave" "" "$MISSING"
teardown

setup
_mock_is_active=1
CONF="$TMPDIR_TEST/peers.conf"
printf 'alpha %s 10.0.99.7 192.168.1.7 51820\n' "$(printf 'K%.0s' {1..42})A=" > "$CONF"
mesh_join "$CONF" >/dev/null 2>&1
CSTARTED="$(awk '$1=="start"{print $2}' "$SYSTEMCTL_CALLS" | sort -u)"
assert_match "config join starts the health timer" "orionx-mesh-health.timer" "$CSTARTED"
if grep -q "orionx-mesh-discover" <<< "$CSTARTED"; then
    echo "  FAIL: a pre-planned (--config) join must not start the listener or beacon"; (( FAIL_COUNT++ )) || true
else
    echo "  PASS: a pre-planned (--config) join starts no listener and no beacon"; (( PASS_COUNT++ )) || true
fi
teardown

# A listener that does not come up is SAID, not hidden.
setup
_mock_is_active=1
cat > "$TMPDIR_TEST/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
echo "$*" >> "$SYSTEMCTL_CALLS"
[[ "$1" == "is-active" ]] && echo failed
exit 0
STUBEOF
OUTPUT="$(mesh_join "" 2>/dev/null)"
assert_match "a dead listener after join is reported to the operator" "discovery listener is NOT running" "$OUTPUT"
teardown
echo ""

# ---------------------------------------------------------------------------
# 11. shell P2-3: leave clears the heal state in the directory mesh-health
#     actually writes, so leave+rejoin really resets a spent budget.
# ---------------------------------------------------------------------------
echo "--- Leave: heal budget and escalation markers are cleared ---"
setup
mesh_state_write "wg0" "10.0.99.42" "discovery" "MockPublicKeyABC123==" 2>/dev/null
_mock_is_active=0
: > "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-heal-budget"
: > "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-escalated-abc123"
: > "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-health-abc123"
mesh_leave >/dev/null 2>&1
assert_file_not_exists "heal budget cleared" "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-heal-budget"
assert_file_not_exists "escalation marker cleared" "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-escalated-abc123"
assert_file_not_exists "per-peer counter cleared" "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-health-abc123"
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
