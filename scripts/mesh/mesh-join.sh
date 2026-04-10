# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Mesh Join Logic
#
# Implements the `orionx-mesh join [--config <file>]` command.
# Sources mesh-lib.sh for all WireGuard operations and state management.
#
# Two modes:
#   - Discovery mode (default): Broadcasts on LAN to find peers automatically.
#   - Config mode (--config <file>): Reads a static peer list from a config file.
#
# Usage: source mesh-join.sh; mesh_join "$config_file"
#   (Do NOT execute directly — this is sourced by orionx-mesh.)
#
# @decision DEC-MESH-006
# @title Join orchestration with dual-mode peer setup
# @status accepted
# @rationale The join function is the primary entry point for mesh participation.
#   Pre-planned mode (--config) provides deterministic peer setup for known
#   environments; discovery mode enables ad-hoc LAN mesh formation for field
#   deployments. Both share the same key/PSK/interface bootstrap, diverging
#   only at peer registration. Discovery process is delegated to mesh-discover.sh
#   (W-003) — join merely starts it.

set -euo pipefail

# Resolve script directory for sibling script references.
# When sourced, BASH_SOURCE[0] points to this file.
_MESH_JOIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PID file for the discovery listener process
MESH_DISCOVER_PID_FILE="${MESH_DISCOVER_PID_FILE:-/var/run/orionx-mesh-discover.pid}"

# =========================================================================
# mesh_join — Main join function
# =========================================================================

# Join or create a WireGuard mesh network.
#
# Args:
#   $1 — Config file path (empty string for discovery mode)
#
# Returns 0 on success, non-zero on failure.
mesh_join() {
    local config_file="${1:-}"

    # --- 1. Idempotency check ---
    if mesh_is_active; then
        local current_vpn_ip current_mode
        current_vpn_ip="$(mesh_state_read vpn_ip 2>/dev/null || echo "unknown")"
        current_mode="$(mesh_state_read mode 2>/dev/null || echo "unknown")"
        echo "Already in mesh."
        echo "  Interface: $MESH_IFACE"
        echo "  VPN IP:    $current_vpn_ip"
        echo "  Mode:      $current_mode"
        return 0
    fi

    mesh_log INFO "Joining mesh network..."

    # --- 2. Generate WireGuard keys (idempotent) ---
    local pubkey
    pubkey="$(mesh_genkeys)"
    mesh_log INFO "Public key: ${pubkey:0:8}..."

    # --- 3. Generate/ensure PSK (idempotent) ---
    mesh_ensure_psk

    # --- 4. Allocate VPN IP ---
    local vpn_ip
    vpn_ip="$(mesh_get_vpn_ip)"
    mesh_log INFO "Allocated VPN IP: $vpn_ip"

    # --- 5. Create WireGuard interface ---
    mesh_interface_up "$vpn_ip"

    # --- 6. Mode-dependent peer setup ---
    local mode="discovery"

    if [[ -n "$config_file" ]]; then
        # Pre-planned mode: read peers from config file
        mode="config"
        _mesh_join_config_mode "$config_file"
    else
        # Discovery mode: start LAN peer discovery
        _mesh_join_discovery_mode
    fi

    # --- 7. Write state file ---
    mesh_state_write "$MESH_IFACE" "$vpn_ip" "$mode" "$pubkey"

    # --- 8. Print success message ---
    echo "Mesh joined successfully."
    echo "  Interface: $MESH_IFACE"
    echo "  VPN IP:    $vpn_ip"
    echo "  Mode:      $mode"
    echo "  Pubkey:    ${pubkey:0:8}..."

    return 0
}

# =========================================================================
# Internal helpers
# =========================================================================

# Set up peers from a pre-planned config file.
# Parses the config and adds each peer to the WireGuard interface.
_mesh_join_config_mode() {
    local config_file="$1"
    local peer_count=0

    mesh_log INFO "Pre-planned mode: loading config from $config_file"

    local parsed
    parsed="$(mesh_parse_config "$config_file")"

    if [[ -z "$parsed" ]]; then
        mesh_log WARN "Config file is empty or contains only comments"
        mesh_log INFO "Pre-planned mode: added 0 peers from config"
        return 0
    fi

    while IFS=' ' read -r _hostname pubkey vpn_ip endpoint port; do
        # Skip if we didn't get all fields
        if [[ -z "${port:-}" ]]; then
            mesh_log WARN "Skipping malformed config line: $_hostname"
            continue
        fi
        mesh_add_peer "$pubkey" "$vpn_ip" "$endpoint" "$port"
        (( peer_count++ )) || true
    done <<< "$parsed"

    mesh_log INFO "Pre-planned mode: added $peer_count peers from config"
}

# Start LAN peer discovery (broadcasts to find other mesh nodes).
# Delegates to mesh-discover.sh if it exists.
_mesh_join_discovery_mode() {
    local discover_script="$_MESH_JOIN_DIR/mesh-discover.sh"

    mesh_log INFO "Discovery mode: looking for peers on LAN"

    if [[ -x "$discover_script" ]]; then
        # Start discovery listener in background
        mesh_log INFO "Starting discovery listener..."
        "$discover_script" listen &
        local listener_pid=$!

        # Store PID for cleanup by mesh_leave
        local pid_dir
        pid_dir="$(dirname "$MESH_DISCOVER_PID_FILE")"
        if [[ -d "$pid_dir" ]] || mkdir -p "$pid_dir" 2>/dev/null; then
            echo "$listener_pid" > "$MESH_DISCOVER_PID_FILE"
        fi

        # Send initial beacon
        "$discover_script" send 2>/dev/null || true

        mesh_log INFO "Discovery mode: broadcasting on LAN (listener PID: $listener_pid)"
    else
        mesh_log WARN "Discovery script not found at $discover_script"
        mesh_log INFO "Discovery mode: broadcasting on LAN (no discover script yet)"
    fi
}
