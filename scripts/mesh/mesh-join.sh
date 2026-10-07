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

# MESH_DISCOVER_PID_FILE comes from mesh-lib.sh (sourced first by orionx-mesh),
# the single authority for the path. The old re-default here to
# /var/run/orionx-mesh-discover.pid was a dead second authority (shell P3-7).

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

    # --- 3. Report the team PSK posture (never invented here: DEC-PHASE12-098) ---
    mesh_psk_status

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
    fi

    # --- 7. Write state file ---
    # Before the units start: the beacon and the listener read the mode from it.
    mesh_state_write "$MESH_IFACE" "$vpn_ip" "$mode" "$pubkey"

    # --- 7b. Start the mesh runtime units (DEC-PHASE12-097) ---
    local units_note=""
    units_note="$(_mesh_join_start_units "$mode")" || true
    # DEC-PHASE12-059: the Cockpit learns about it now, not at the next timer tick,
    # and the bus records it (the Mesh tab's History reads these).
    mesh_snapshot_write 2>/dev/null || true
    mesh_emit info service "joined the mesh as $vpn_ip on $MESH_IFACE ($mode mode)" 2>/dev/null || true

    # --- 8. Print success message ---
    echo "Mesh joined successfully."
    echo "  Interface: $MESH_IFACE"
    echo "  VPN IP:    $vpn_ip"
    echo "  Mode:      $mode"
    echo "  Pubkey:    ${pubkey:0:8}..."
    [[ -n "$units_note" ]] && echo "$units_note"
    mesh_reboot_line

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
        # A rejected line (DEC-PHASE12-096 validation) is logged and skipped;
        # it must not abort the join under set -e.
        if mesh_add_peer "$pubkey" "$vpn_ip" "$endpoint" "$port"; then
            (( peer_count++ )) || true
        fi
    done <<< "$parsed"

    mesh_log INFO "Pre-planned mode: added $peer_count peers from config"
}


# Start the mesh runtime units for this join mode (DEC-PHASE12-097).
# Prints one operator-facing line when something did not come up; the join
# itself (keys, wg0, state) has already succeeded and is not undone.
#
# discovery mode: health + status timers, the inbound listener unit and the
#                 beacon timer. config mode: health + status timers only — a
#                 pre-planned join on a hostile LAN must not broadcast.
# Without systemd (containers, CI) the listener is started detached with
# setsid so it at least survives the terminal that ran join.
_mesh_join_start_units() {
    local mode="$1"
    local -a units
    read -r -a units <<< "$MESH_UNITS_ALWAYS"
    if [[ "$mode" == "discovery" ]]; then
        local -a disc
        read -r -a disc <<< "$MESH_UNITS_DISCOVERY"
        units+=("${disc[@]}")
    fi

    if mesh_systemd_available; then
        local failed=0
        mesh_units_start "${units[@]}" || failed=1
        if [[ "$mode" == "discovery" ]]; then
            local state
            state="$("$MESH_SYSTEMCTL" is-active orionx-mesh-discover.service 2>/dev/null || true)"
            if [[ "$state" != "active" ]]; then
                echo "  WARNING:   discovery listener is NOT running (orionx-mesh-discover.service: ${state:-unknown}). New peers will not be found. Check: systemctl status orionx-mesh-discover.service"
                return 1
            fi
            # First beacon now rather than at the next timer tick.
            "$MESH_SYSTEMCTL" start orionx-mesh-beacon.service 2>/dev/null || true
        fi
        if (( failed )); then
            echo "  WARNING:   some mesh units did not start (see the log above); health checks or the Cockpit snapshot may be stale."
            return 1
        fi
        return 0
    fi

    # No systemd: degrade to a detached listener, said out loud.
    if [[ "$mode" == "discovery" ]]; then
        local discover_script="$_MESH_JOIN_DIR/mesh-discover.sh"
        if [[ -x "$discover_script" ]]; then
            if command -v setsid >/dev/null 2>&1; then
                setsid "$discover_script" listen </dev/null >/dev/null 2>&1 &
            else
                nohup "$discover_script" listen </dev/null >/dev/null 2>&1 &
            fi
            "$discover_script" send 2>/dev/null || true
            echo "  NOTE:      systemd is not running here; the discovery listener was started detached (PID file: $MESH_DISCOVER_PID_FILE)."
        else
            echo "  WARNING:   systemd is not running and $discover_script is missing — no discovery listener."
            return 1
        fi
    fi
    return 0
}
