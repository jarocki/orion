#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Mesh Health Check Daemon
#
# Invoked by a systemd timer every 60 seconds (oneshot). Each invocation:
#   1. Verifies the wg0 interface exists; attempts restore if missing.
#   2. Iterates over all WireGuard peers, checking handshake freshness
#      and ping reachability.
#   3. Applies tiered healing: soft heal (wg set endpoint) first,
#      aggressive heal (interface restart) after 2+ consecutive failures.
#   4. Logs a summary of peer health.
#
# Failure counters persist across invocations via temp files in
# MESH_HEALTH_COUNTER_DIR (/var/run/ by default). A successful handshake
# clears the failure counter for that peer.
#
# Dependencies: mesh-lib.sh, ip, wg, wg-quick, ping
#
# Usage:
#   mesh-health.sh          # Run health check (systemd oneshot)
#   MESH_HEALTH_SOURCED=1 source mesh-health.sh   # Library mode for tests
#
# @decision DEC-MESH-002
# @title Systemd timer-driven health check with tiered healing
# @status accepted
# @rationale A systemd timer (OnUnitActiveSec=60s) invokes the health
#   check as a oneshot service. This avoids a long-running daemon process
#   and leverages systemd for scheduling, logging (journal), and restart
#   policy. The timer approach is simpler than a sleep-loop daemon and
#   gives operators standard systemctl commands for management.
#
# @decision DEC-MESH-005
# @title Soft heal via wg set before aggressive wg-quick restart
# @status accepted
# @rationale Using `wg set $IFACE peer $PUBKEY endpoint $ENDPOINT`
#   re-triggers the WireGuard handshake without tearing down the interface.
#   This avoids the 2-minute handshake lockout and packet loss that occurs
#   during a full wg-quick down/up cycle. Aggressive heal (interface restart)
#   is reserved for peers that fail 2+ consecutive health checks, indicating
#   a deeper connectivity issue that a simple endpoint refresh cannot fix.

set -euo pipefail

# --- Resolve script directory for reliable sourcing ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Source mesh library (provides constants, logging, WG helpers) ---
# shellcheck source=mesh-lib.sh disable=SC1091
source "$SCRIPT_DIR/mesh-lib.sh"

# Failure counter directory (overridable for testing).
MESH_HEALTH_COUNTER_DIR="${MESH_HEALTH_COUNTER_DIR:-/var/run}"

# Handshake staleness threshold in seconds (3 minutes).
MESH_HANDSHAKE_STALE_SECS="${MESH_HANDSHAKE_STALE_SECS:-180}"

# Aggressive heal threshold: consecutive failed checks before interface restart.
MESH_AGGRESSIVE_THRESHOLD="${MESH_AGGRESSIVE_THRESHOLD:-2}"

# =========================================================================
# Helper functions
# =========================================================================

# Extract shortened key (first 8 chars) for logging and counter files.
health_short_key() {
    local pubkey="$1"
    echo "${pubkey:0:8}"
}

# Extract VPN IP from allowed-ips field (e.g., "10.0.99.10/32" → "10.0.99.10").
health_extract_vpn_ip() {
    local allowed_ips="$1"
    # Take the first CIDR block and strip the mask
    local first_cidr
    first_cidr="${allowed_ips%%,*}"
    echo "${first_cidr%%/*}"
}

# =========================================================================
# Interface check
# =========================================================================

# Verify the mesh interface exists; attempt restore if missing.
health_check_interface() {
    if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
        return 0
    fi

    mesh_log WARN "Interface $MESH_IFACE missing — attempting restore"

    if wg-quick up "$MESH_IFACE" 2>/dev/null; then
        mesh_log INFO "Interface $MESH_IFACE restored via wg-quick"
        return 0
    fi

    mesh_log ERROR "Failed to restore interface $MESH_IFACE"
    return 1
}

# =========================================================================
# Handshake staleness
# =========================================================================

# Determine if a handshake timestamp is stale. Returns "stale" or "fresh".
health_is_handshake_stale() {
    local handshake_epoch="$1"
    local now_epoch="$2"

    # Zero means never connected
    if [[ "$handshake_epoch" == "0" ]]; then
        echo "stale"
        return 0
    fi

    local age=$(( now_epoch - handshake_epoch ))
    if (( age > MESH_HANDSHAKE_STALE_SECS )); then
        echo "stale"
    else
        echo "fresh"
    fi
}

# =========================================================================
# Soft heal
# =========================================================================

# Re-trigger handshake by resetting the endpoint for a peer.
health_soft_heal() {
    local pubkey="$1"
    local endpoint="$2"
    local short_key
    short_key="$(health_short_key "$pubkey")"

    mesh_log INFO "Soft heal: refreshing endpoint for peer $short_key"
    wg set "$MESH_IFACE" peer "$pubkey" endpoint "$endpoint"
}

# =========================================================================
# Failure counters
# =========================================================================

# Increment the failure counter for a peer (persisted in temp file).
health_increment_counter() {
    local short_key="$1"
    local counter_file="$MESH_HEALTH_COUNTER_DIR/orionx-mesh-health-$short_key"
    local current
    current="$(health_read_counter "$short_key")"
    echo $(( current + 1 )) > "$counter_file"
}

# Read the failure counter for a peer. Returns 0 if no counter file exists.
health_read_counter() {
    local short_key="$1"
    local counter_file="$MESH_HEALTH_COUNTER_DIR/orionx-mesh-health-$short_key"
    if [[ -f "$counter_file" ]]; then
        cat "$counter_file"
    else
        echo "0"
    fi
}

# Clear the failure counter for a single peer.
health_clear_counter() {
    local short_key="$1"
    local counter_file="$MESH_HEALTH_COUNTER_DIR/orionx-mesh-health-$short_key"
    rm -f "$counter_file"
}

# Clear all failure counters (used after aggressive heal / interface restart).
health_clear_all_counters() {
    rm -f "$MESH_HEALTH_COUNTER_DIR"/orionx-mesh-health-*
}

# Check if a peer has reached the aggressive heal threshold.
health_should_aggressive_heal() {
    local short_key="$1"
    local count
    count="$(health_read_counter "$short_key")"
    (( count >= MESH_AGGRESSIVE_THRESHOLD ))
}

# =========================================================================
# Aggressive heal
# =========================================================================

# Restart the WireGuard interface — last resort for unresponsive peers.
health_aggressive_heal() {
    local short_key="$1"

    mesh_log WARN "Aggressive heal: interface restart for unresponsive peer $short_key"
    wg-quick down "$MESH_IFACE" 2>/dev/null || true
    wg-quick up "$MESH_IFACE"

    # Interface restart affects all peers — reset ALL counters
    health_clear_all_counters
}

# =========================================================================
# Per-peer health check
# =========================================================================

# Check a single peer's health: handshake freshness, ping, healing.
# Returns 0 for healthy, 1 for stale, 2 for aggressive heal triggered.
health_check_peer() {
    local pubkey="$1"
    local endpoint="$2"
    local allowed_ips="$3"
    local latest_handshake="$4"
    local now_epoch="$5"

    local short_key
    short_key="$(health_short_key "$pubkey")"
    local vpn_ip
    vpn_ip="$(health_extract_vpn_ip "$allowed_ips")"
    local staleness
    staleness="$(health_is_handshake_stale "$latest_handshake" "$now_epoch")"

    # Fresh handshake — peer is healthy, clear any failure counter
    if [[ "$staleness" == "fresh" ]]; then
        health_clear_counter "$short_key"
        return 0
    fi

    # Stale handshake — attempt soft heal
    health_soft_heal "$pubkey" "$endpoint"

    # Ping check
    if ping -c 3 -W 2 "$vpn_ip" >/dev/null 2>&1; then
        # Ping succeeds despite stale handshake — peer is reachable
        return 0
    fi

    # Ping failed AND handshake is stale — increment failure counter
    health_increment_counter "$short_key"

    # Check aggressive heal threshold
    if health_should_aggressive_heal "$short_key"; then
        health_aggressive_heal "$short_key"
        return 2
    fi

    return 1
}

# =========================================================================
# All-peers health check
# =========================================================================

# Iterate over all peers and run health checks. Logs summary.
health_check_all_peers() {
    local now_epoch
    now_epoch="$(date +%s)"

    local total=0
    local healthy=0
    local stale=0

    # wg show dump format (tab-separated, after header line):
    # pubkey  preshared-key  endpoint  allowed-ips  latest-handshake  transfer-rx  transfer-tx  persistent-keepalive
    local dump_output
    dump_output="$(wg show "$MESH_IFACE" dump 2>/dev/null | tail -n +2)" || true

    if [[ -z "$dump_output" ]]; then
        mesh_log INFO "Health check: 0 peers, 0 healthy, 0 stale"
        return 0
    fi

    while IFS=$'\t' read -r pubkey _psk endpoint allowed_ips latest_handshake _rx _tx _keepalive; do
        (( total++ )) || true

        local rc=0
        health_check_peer "$pubkey" "$endpoint" "$allowed_ips" "$latest_handshake" "$now_epoch" || rc=$?

        if [[ "$rc" -eq 0 ]]; then
            (( healthy++ )) || true
        elif [[ "$rc" -eq 2 ]]; then
            # Aggressive heal triggered — exit early, next invocation re-checks
            mesh_log INFO "Health check: $total peers checked, aggressive heal triggered — exiting"
            return 0
        else
            (( stale++ )) || true
        fi
    done <<< "$dump_output"

    mesh_log INFO "Health check: $total peers, $healthy healthy, $stale stale"
    return 0
}

# =========================================================================
# Main
# =========================================================================

# Guard: when sourced for testing, skip main execution.
if [[ "${MESH_HEALTH_SOURCED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi

main() {
    # Step 1: Check interface
    if ! health_check_interface; then
        exit 1
    fi

    # Step 2+3: Check all peers and report
    health_check_all_peers
}

main "$@"
