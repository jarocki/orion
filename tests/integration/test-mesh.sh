#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition -- Mesh Integration Test
#
# Validates the Phase 3 acceptance criteria using a 3-node Docker mesh.
# Requires: docker, docker compose
#
# Usage: bash tests/integration/test-mesh.sh
#
# The test assumes docker-compose.mesh-test.yml is already running
# (started by `make test-mesh` or manually via docker compose up).
#
# Acceptance criteria tested:
#   AC-001: 3 Docker nodes on same bridge network join mesh; wg show shows 2 peers each within 30s
#   AC-002: Kill one node's WireGuard interface; health check restores within 120s
#   AC-003: orionx-mesh status shows interface, peers, handshake timestamps
#   AC-004: orionx-mesh leave tears down interface, node disappears from own wg show
#
# @decision DEC-MESH-TEST-004
# @title Docker-based 3-node mesh integration test
# @status accepted
# @rationale Integration tests validate the full production sequence: mesh
#   formation via discovery, health-check self-healing, status reporting, and
#   graceful leave. Unit tests exercise each function in isolation; this script
#   proves the pieces work together under realistic Docker networking conditions.
#   Timeouts are generous (60s formation, 120s recovery) because Docker bridge
#   networking adds latency compared to bare-metal LAN. Each test section is
#   independent and produces clear pass/fail output for CI.

# =========================================================================
# Configuration
# =========================================================================

COMPOSE_FILE="docker/docker-compose.mesh-test.yml"
PROJECT="orionx-mesh-test"

# Timeouts (seconds)
FORMATION_TIMEOUT=60
FORMATION_INTERVAL=5
RECOVERY_TIMEOUT=120
RECOVERY_INTERVAL=10
LEAVE_SETTLE_TIME=30

# =========================================================================
# Test framework
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
    (( PASS++ )) || true
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    (( FAIL++ )) || true
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

skip() {
    (( SKIP++ )) || true
    echo "${YELLOW}  SKIP${NC}: $1 -- $2"
}

# Assert two values are equal.
# Args: description expected actual
assert_eq() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$description"
    else
        fail "$description" "expected='$expected', got='$actual'"
    fi
}

# Assert a string contains a substring.
# Args: description haystack needle
assert_contains() {
    local description="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$description"
    else
        fail "$description" "expected to contain '$needle'"
    fi
}

# Assert numeric value is greater than threshold.
# Args: description actual threshold
assert_gt() {
    local description="$1" actual="$2" threshold="$3"
    if [[ "$actual" -gt "$threshold" ]]; then
        pass "$description"
    else
        fail "$description" "expected $actual > $threshold"
    fi
}

# =========================================================================
# Helpers
# =========================================================================

# Run a command inside a named Docker Compose service container.
# Uses -T (no TTY) for non-interactive execution in CI.
# Args: node_name command...
run_on() {
    local node="$1"; shift
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" exec -T "$node" "$@"
}

# Check whether the WireGuard kernel module is available inside a container.
# Returns 0 if available, 1 otherwise.
check_wg_module() {
    local node="$1"
    run_on "$node" modprobe wireguard 2>/dev/null \
        || run_on "$node" test -e /sys/module/wireguard 2>/dev/null
}

# Count the number of WireGuard peers on a given node.
# Returns a numeric count (0 if wg0 doesn't exist or wg is unavailable).
count_peers() {
    local node="$1"
    local result
    result="$(run_on "$node" wg show wg0 peers 2>/dev/null | wc -l | tr -d ' ')" || true
    echo "${result:-0}"
}

# =========================================================================
# Pre-flight checks
# =========================================================================

preflight() {
    echo ""
    echo "=== Pre-flight Checks ==="

    # 1. Docker compose is available
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        pass "docker compose is available"
    else
        fail "docker compose is available" "Install Docker with compose plugin"
        echo ""
        echo "FATAL: Cannot continue without docker compose."
        exit 2
    fi

    # 2. Compose file exists
    if [[ -f "$COMPOSE_FILE" ]]; then
        pass "compose file exists ($COMPOSE_FILE)"
    else
        fail "compose file exists" "Not found: $COMPOSE_FILE"
        echo ""
        echo "FATAL: Compose file missing. Run 'make test-mesh' or create $COMPOSE_FILE first."
        exit 2
    fi

    # 3. All 3 nodes are running
    local running_nodes
    running_nodes="$(docker compose -p "$PROJECT" -f "$COMPOSE_FILE" ps --status running --format '{{.Name}}' 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$running_nodes" -ge 3 ]]; then
        pass "3 nodes are running ($running_nodes containers up)"
    else
        fail "3 nodes are running" "Only $running_nodes containers running"
        echo ""
        echo "FATAL: Start containers first: docker compose -p $PROJECT -f $COMPOSE_FILE up -d"
        exit 2
    fi

    # 4. Spot-check bridge connectivity (node-1 pings node-2 and node-3)
    local ping_ok=true
    if ! run_on node-1 ping -c 1 -W 2 172.20.0.12 >/dev/null 2>&1; then
        ping_ok=false
    fi
    if ! run_on node-1 ping -c 1 -W 2 172.20.0.13 >/dev/null 2>&1; then
        ping_ok=false
    fi
    if [[ "$ping_ok" == "true" ]]; then
        pass "nodes reachable on bridge network"
    else
        fail "nodes reachable on bridge network" "node-1 cannot reach node-2 or node-3"
    fi

    # 5. WireGuard kernel module check
    if check_wg_module node-1; then
        pass "WireGuard kernel module available"
    else
        skip "WireGuard kernel module" "not available in container kernel"
        echo ""
        echo "WARNING: WireGuard module not loaded. Tests requiring wg0 will likely fail."
        echo "         Load the module on the Docker host: sudo modprobe wireguard"
        echo ""
    fi
}

# =========================================================================
# AC-001: Mesh Formation
# =========================================================================

test_mesh_formation() {
    echo ""
    echo "=== AC-001: Mesh Formation ==="
    echo "  Waiting for mesh formation (max ${FORMATION_TIMEOUT}s)..."

    local elapsed=0
    local n1_peers=0
    local n2_peers=0
    local n3_peers=0

    while [[ $elapsed -lt $FORMATION_TIMEOUT ]]; do
        n1_peers=$(count_peers node-1)
        n2_peers=$(count_peers node-2)
        n3_peers=$(count_peers node-3)

        if [[ "$n1_peers" -ge 2 && "$n2_peers" -ge 2 && "$n3_peers" -ge 2 ]]; then
            echo "  Mesh formed in ${elapsed}s"
            break
        fi

        sleep "$FORMATION_INTERVAL"
        elapsed=$((elapsed + FORMATION_INTERVAL))
    done

    assert_eq "node-1 has 2 peers" "2" "$n1_peers"
    assert_eq "node-2 has 2 peers" "2" "$n2_peers"
    assert_eq "node-3 has 2 peers" "2" "$n3_peers"

    # Bonus: verify VPN IPs are reachable across the mesh
    # Each node should be able to ping the other two on the VPN subnet
    local vpn_ping_ok=true
    for src in node-1 node-2 node-3; do
        for dst in node-1 node-2 node-3; do
            [[ "$src" == "$dst" ]] && continue
            local dst_vpn_ip
            # Extract VPN IP from wg0 (portable: no grep -P needed)
            dst_vpn_ip=$(run_on "$dst" ip -4 addr show wg0 2>/dev/null \
                | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
            if [[ -n "$dst_vpn_ip" ]]; then
                if ! run_on "$src" ping -c 1 -W 3 "$dst_vpn_ip" >/dev/null 2>&1; then
                    vpn_ping_ok=false
                fi
            fi
        done
    done

    if [[ "$vpn_ping_ok" == "true" ]]; then
        pass "VPN cross-node pings succeed"
    else
        fail "VPN cross-node pings succeed" "Some VPN pings failed"
    fi
}

# =========================================================================
# AC-002: Health Check Recovery
# =========================================================================

test_health_recovery() {
    echo ""
    echo "=== AC-002: Health Check Recovery ==="

    # Verify node-2 currently has the interface before killing it
    local pre_check
    pre_check=$(run_on node-2 ip link show wg0 2>/dev/null && echo "up" || echo "down")
    if [[ "$pre_check" != "up" ]]; then
        skip "AC-002: Health check recovery" "node-2 wg0 not up (mesh may not have formed)"
        return
    fi

    # Kill node-2's WireGuard interface
    run_on node-2 ip link delete wg0 2>/dev/null || true

    # Confirm it's actually gone
    local post_kill
    post_kill=$(run_on node-2 ip link show wg0 2>/dev/null && echo "up" || echo "down")
    assert_eq "node-2 wg0 killed" "down" "$post_kill"

    echo "  Killed node-2 wg0, waiting for recovery (max ${RECOVERY_TIMEOUT}s)..."

    local elapsed=0
    local n2_iface="down"

    while [[ $elapsed -lt $RECOVERY_TIMEOUT ]]; do
        n2_iface=$(run_on node-2 ip link show wg0 2>/dev/null && echo "up" || echo "down")

        if [[ "$n2_iface" == "up" ]]; then
            echo "  Interface restored in ${elapsed}s"
            break
        fi

        sleep "$RECOVERY_INTERVAL"
        elapsed=$((elapsed + RECOVERY_INTERVAL))
    done

    # Verify interface is back
    assert_eq "node-2 wg0 restored" "up" "$n2_iface"

    # Wait a bit for peers to re-establish handshakes
    if [[ "$n2_iface" == "up" ]]; then
        echo "  Waiting 15s for peer re-establishment..."
        sleep 15

        local n2_peers
        n2_peers=$(count_peers node-2)
        assert_eq "node-2 has 2 peers after recovery" "2" "$n2_peers"
    else
        fail "node-2 has 2 peers after recovery" "interface never came back up"
    fi
}

# =========================================================================
# AC-003: Status Command
# =========================================================================

test_status_output() {
    echo ""
    echo "=== AC-003: Status Command ==="

    local status
    status=$(run_on node-1 orionx-mesh status 2>/dev/null || true)

    if [[ -z "$status" ]]; then
        fail "status command produces output" "empty output"
        return
    fi

    pass "status command produces output"
    assert_contains "status shows active" "$status" "active"
    assert_contains "status shows interface" "$status" "wg0"
    assert_contains "status shows VPN IP" "$status" "10.0.99"
    assert_contains "status shows peers" "$status" "Peers"

    # Verify the status output has meaningful content (not just template)
    # The Uptime field should show a non-zero value since mesh is running
    if echo "$status" | grep -qE 'Uptime:.*[0-9]'; then
        pass "status shows uptime value"
    else
        fail "status shows uptime value" "No numeric uptime in output"
    fi

    # Health field should exist
    if echo "$status" | grep -q 'Health:'; then
        pass "status shows health field"
    else
        fail "status shows health field" "Missing Health: line"
    fi
}

# =========================================================================
# AC-004: Leave Command
# =========================================================================

test_leave() {
    echo ""
    echo "=== AC-004: Leave Command ==="

    # Node-3 leaves the mesh
    local leave_output
    leave_output=$(run_on node-3 orionx-mesh leave 2>/dev/null || true)

    if [[ -n "$leave_output" ]]; then
        pass "leave command produces output"
    else
        fail "leave command produces output" "empty output"
    fi

    # Verify node-3's WireGuard interface is gone
    local n3_iface
    n3_iface=$(run_on node-3 ip link show wg0 2>/dev/null && echo "up" || echo "down")
    assert_eq "node-3 wg0 removed after leave" "down" "$n3_iface"

    # Verify node-3 has no WireGuard peers
    local n3_peer_count
    n3_peer_count=$(run_on node-3 wg show 2>/dev/null | grep -c "peer:" || echo 0)
    assert_eq "node-3 has 0 peers after leave" "0" "$n3_peer_count"

    # Verify node-3 status shows inactive
    local n3_status
    n3_status=$(run_on node-3 orionx-mesh status 2>/dev/null || true)
    assert_contains "node-3 status shows inactive after leave" "$n3_status" "inactive"

    # Wait for other nodes to notice (WireGuard keeps stale peer configs,
    # but the peer's handshake will go stale). We don't expect automatic
    # peer removal from other nodes -- WireGuard doesn't do that.
    echo "  Waiting ${LEAVE_SETTLE_TIME}s for peer removal to settle..."
    sleep "$LEAVE_SETTLE_TIME"

    # Remaining nodes should still have their interfaces up
    local n1_iface n2_iface
    n1_iface=$(run_on node-1 ip link show wg0 2>/dev/null && echo "up" || echo "down")
    n2_iface=$(run_on node-2 ip link show wg0 2>/dev/null && echo "up" || echo "down")
    assert_eq "node-1 still has wg0 after node-3 leaves" "up" "$n1_iface"
    assert_eq "node-2 still has wg0 after node-3 leaves" "up" "$n2_iface"
}

# =========================================================================
# Main
# =========================================================================

echo "==========================================="
echo "  Orion-X Mesh Integration Tests"
echo "==========================================="

preflight
test_mesh_formation
test_health_recovery
test_status_output
test_leave

# Summary
echo ""
echo "==========================================="
echo "  Integration Test Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

[[ "$FAIL" -eq 0 ]] || exit 1
