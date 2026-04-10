#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Mesh Peer Discovery Daemon
#
# Handles UDP broadcast-based peer discovery for the WireGuard mesh.
# Supports three modes:
#   send   — broadcast a single beacon (for systemd timer)
#   listen — long-running listener (for systemd service)
#   stop   — kill the listener process
#
# The beacon is a JSON payload broadcast on MESH_DISCOVER_PORT (55555)
# containing the node's WireGuard public key, VPN IP, WG port, and hostname.
# Listeners parse incoming beacons, filter own beacons, deduplicate against
# existing WireGuard peers, and call mesh_add_peer for new discoveries.
#
# Dependencies: socat, jq (optional, sed fallback), mesh-lib.sh
#
# Usage:
#   mesh-discover.sh send     # Send one beacon
#   mesh-discover.sh listen   # Start listener (foreground)
#   mesh-discover.sh stop     # Stop listener
#
# @decision DEC-MESH-001
# @title UDP broadcast + shared config for dual-mode peer discovery
# @status accepted
# @rationale Avahi/mDNS is overkill for LAN-only mesh discovery. UDP
#   broadcast is zero-dependency (socat + optional jq), works on Docker
#   bridge networks, and is trivially debuggable with tcpdump. The shared
#   config file (mesh-peers.conf) supports pre-planned operations where
#   peer lists are known in advance. Both modes coexist: broadcast for
#   ad-hoc discovery, config file for deterministic deployments.

set -euo pipefail

# --- Resolve script directory for reliable sourcing ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Source mesh library (provides constants, logging, WG helpers) ---
# shellcheck source=mesh-lib.sh disable=SC1091
source "$SCRIPT_DIR/mesh-lib.sh"

# PID file for the listener process (overridable for testing)
MESH_DISCOVER_PID_FILE="${MESH_DISCOVER_PID_FILE:-/var/run/orionx-mesh-discover.pid}"

# =========================================================================
# JSON helpers — use jq if available, fall back to sed/grep
# =========================================================================

# Build a beacon JSON string from the given parameters.
_mesh_build_beacon() {
    local pubkey="$1"
    local vpn_ip="$2"
    local wg_port="$3"
    local hostname="$4"

    printf '{"pubkey":"%s","vpn_ip":"%s","wg_port":%s,"hostname":"%s"}' \
        "$pubkey" "$vpn_ip" "$wg_port" "$hostname"
}

# Parse a field value from a JSON string.
# Uses jq when available; falls back to sed for minimal-dependency environments.
_mesh_parse_field() {
    local json="$1"
    local field="$2"

    if [[ -z "$json" ]]; then
        echo ""
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        echo "$json" | jq -r ".${field} // empty" 2>/dev/null || echo ""
    else
        # Sed fallback: handles both "field":"value" and "field": value (numeric)
        local value
        # Try quoted value first
        value="$(echo "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
        if [[ -z "$value" ]]; then
            # Try numeric value (unquoted)
            value="$(echo "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p")"
        fi
        echo "$value"
    fi
}

# =========================================================================
# Beacon filtering and deduplication
# =========================================================================

# Check if a beacon's pubkey matches our own. Returns 0 if own, 1 if foreign.
_mesh_is_own_beacon() {
    local beacon_pubkey="$1"
    local our_pubkey="$2"

    if [[ -z "$beacon_pubkey" ]]; then
        return 1
    fi

    [[ "$beacon_pubkey" == "$our_pubkey" ]]
}

# =========================================================================
# Broadcast address detection
# =========================================================================

# Extract broadcast address from ip command output.
# Input: output of `ip -o -4 addr show` (one or more lines).
# Returns the broadcast address of the first non-loopback interface.
_mesh_get_broadcast_addr_from_output() {
    local output="$1"
    echo "$output" | grep -oE 'brd [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}'
}

# Detect the subnet broadcast address for beacon sending.
# Tries `ip -o -4 addr show` (Linux), falls back to 255.255.255.255.
_mesh_get_broadcast_addr() {
    local bcast=""

    if command -v ip >/dev/null 2>&1; then
        local ip_output
        ip_output="$(ip -o -4 addr show 2>/dev/null | grep -v ' lo ' || true)"
        if [[ -n "$ip_output" ]]; then
            bcast="$(_mesh_get_broadcast_addr_from_output "$ip_output")"
        fi
    fi

    # Fallback: global broadcast
    if [[ -z "$bcast" ]]; then
        bcast="255.255.255.255"
    fi

    echo "$bcast"
}

# =========================================================================
# PID file management
# =========================================================================

# Write the listener PID to the PID file.
_mesh_write_pid() {
    local pid="$1"
    local pid_dir
    pid_dir="$(dirname "$MESH_DISCOVER_PID_FILE")"
    mkdir -p "$pid_dir"
    echo "$pid" > "$MESH_DISCOVER_PID_FILE"
}

# Read the stored listener PID. Returns empty string if no PID file.
_mesh_read_pid() {
    if [[ -f "$MESH_DISCOVER_PID_FILE" ]]; then
        cat "$MESH_DISCOVER_PID_FILE"
    else
        echo ""
    fi
}

# Remove the PID file.
_mesh_cleanup_pid() {
    rm -f "$MESH_DISCOVER_PID_FILE"
}

# =========================================================================
# Beacon processing (core pipeline)
# =========================================================================

# Process a received beacon: parse, filter, dedup, and add peer.
# Args: json_beacon sender_ip our_pubkey
_mesh_process_beacon() {
    local beacon="$1"
    local sender_ip="$2"
    local our_pubkey="$3"

    # Parse beacon fields
    local pubkey vpn_ip wg_port hostname
    pubkey="$(_mesh_parse_field "$beacon" "pubkey")"
    vpn_ip="$(_mesh_parse_field "$beacon" "vpn_ip")"
    wg_port="$(_mesh_parse_field "$beacon" "wg_port")"
    hostname="$(_mesh_parse_field "$beacon" "hostname")"

    # Validate required fields
    if [[ -z "$pubkey" || -z "$vpn_ip" || -z "$wg_port" ]]; then
        mesh_log WARN "Received malformed beacon from $sender_ip (missing fields)"
        return 0
    fi

    # Filter own beacons
    if _mesh_is_own_beacon "$pubkey" "$our_pubkey"; then
        return 0
    fi

    # Dedup: check if peer already known to WireGuard
    if wg show "$MESH_IFACE" peers 2>/dev/null | grep -q "^${pubkey}$"; then
        return 0
    fi

    # New peer discovered — add to mesh
    mesh_log INFO "Discovered peer: ${hostname:-unknown} ($vpn_ip) at $sender_ip"
    mesh_add_peer "$pubkey" "$vpn_ip" "$sender_ip" "$wg_port"
}

# =========================================================================
# Send / Listen / Stop commands
# =========================================================================

# Send a single UDP beacon broadcast.
mesh_beacon_send() {
    # Read our identity from state/keys
    local pubkey vpn_ip wg_port hostname_val broadcast_addr

    pubkey="$(mesh_get_pubkey)" || {
        mesh_log ERROR "Cannot send beacon: no public key available"
        return 1
    }

    vpn_ip="$(mesh_state_read vpn_ip 2>/dev/null)" || {
        mesh_log ERROR "Cannot send beacon: no VPN IP in state file"
        return 1
    }

    if [[ -z "$vpn_ip" ]]; then
        mesh_log ERROR "Cannot send beacon: VPN IP is empty"
        return 1
    fi

    wg_port="${MESH_WG_PORT}"
    hostname_val="$(hostname -s 2>/dev/null || echo "unknown")"
    broadcast_addr="$(_mesh_get_broadcast_addr)"

    local beacon
    beacon="$(_mesh_build_beacon "$pubkey" "$vpn_ip" "$wg_port" "$hostname_val")"

    mesh_log INFO "Sending beacon to ${broadcast_addr}:${MESH_DISCOVER_PORT}"

    if ! command -v socat >/dev/null 2>&1; then
        mesh_log ERROR "socat is required for beacon sending but not found"
        return 1
    fi

    echo "$beacon" | socat - "UDP-DATAGRAM:${broadcast_addr}:${MESH_DISCOVER_PORT},broadcast"
}

# Start the beacon listener (long-running, foreground).
mesh_beacon_listen() {
    if ! command -v socat >/dev/null 2>&1; then
        mesh_log ERROR "socat is required for beacon listening but not found"
        return 1
    fi

    local our_pubkey
    our_pubkey="$(mesh_get_pubkey)" || {
        mesh_log ERROR "Cannot start listener: no public key available"
        return 1
    }

    # Write our PID for stop command
    _mesh_write_pid "$$"

    mesh_log INFO "Starting beacon listener on port $MESH_DISCOVER_PORT (PID $$)"

    # Set up cleanup trap
    trap '_mesh_cleanup_pid; mesh_log INFO "Listener stopped"' EXIT INT TERM

    # Listen for UDP broadcasts. socat fork mode provides SOCAT_PEERADDR.
    # We use a while-read loop on STDOUT for simpler process management.
    socat -u "UDP-RECVFROM:${MESH_DISCOVER_PORT},broadcast,reuseaddr,fork" STDOUT | \
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            # In fork mode, SOCAT_PEERADDR may not propagate to the pipe.
            # Extract sender from the beacon itself or use a placeholder.
            local sender_ip="${SOCAT_PEERADDR:-unknown}"
            _mesh_process_beacon "$line" "$sender_ip" "$our_pubkey"
        fi
    done
}

# Stop the running listener by PID file.
mesh_beacon_stop() {
    local pid
    pid="$(_mesh_read_pid)"

    if [[ -z "$pid" ]]; then
        mesh_log WARN "No listener PID file found"
        return 0
    fi

    if kill -0 "$pid" 2>/dev/null; then
        mesh_log INFO "Stopping listener (PID $pid)"
        kill "$pid"
        _mesh_cleanup_pid
        mesh_log INFO "Listener stopped"
    else
        mesh_log WARN "Listener process $pid not running, cleaning up PID file"
        _mesh_cleanup_pid
    fi
}

# =========================================================================
# Main — mode dispatch
# =========================================================================

# Guard: when sourced for testing, skip main execution.
if [[ "${MESH_DISCOVER_SOURCED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi

main() {
    local mode="${1:-}"

    case "$mode" in
        send)
            mesh_beacon_send
            ;;
        listen)
            mesh_beacon_listen
            ;;
        stop)
            mesh_beacon_stop
            ;;
        *)
            echo "Usage: mesh-discover.sh {send|listen|stop}" >&2
            exit 1
            ;;
    esac
}

main "$@"
