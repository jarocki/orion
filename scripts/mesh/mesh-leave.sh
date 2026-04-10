# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Mesh Leave Logic
#
# Implements the `orionx-mesh leave` command.
# Tears down the WireGuard mesh interface, stops discovery/health daemons,
# and removes state files.
#
# Usage: source mesh-leave.sh; mesh_leave
#   (Do NOT execute directly — this is sourced by orionx-mesh.)
#
# @decision DEC-MESH-007
# @title Defensive leave with multi-source cleanup
# @status accepted
# @rationale Leave must handle partial states gracefully — the interface
#   may be up without discovery running, or the PID file may reference a
#   dead process. Each cleanup step is independently guarded with || true
#   so a failure in one step does not prevent subsequent cleanup. Systemd
#   units are stopped unconditionally (2>/dev/null) since they may or may
#   not exist depending on the deployment mode.

set -euo pipefail

# PID file for the discovery listener process
MESH_DISCOVER_PID_FILE="${MESH_DISCOVER_PID_FILE:-/var/run/orionx-mesh-discover.pid}"

# =========================================================================
# mesh_leave — Main leave function
# =========================================================================

# Leave the WireGuard mesh network.
# Stops all mesh-related processes, tears down the interface,
# and removes state files.
#
# Returns 0 always (idempotent — safe to call when not in mesh).
mesh_leave() {

    # --- 1. Check if active ---
    if ! mesh_is_active; then
        echo "Not in a mesh."
        return 0
    fi

    mesh_log INFO "Leaving mesh network..."

    # --- 2. Stop discovery listener ---
    _mesh_leave_stop_discovery

    # --- 3. Stop health check ---
    _mesh_leave_stop_health

    # --- 4. Tear down interface ---
    mesh_interface_down

    # --- 5. Remove state file ---
    rm -f "$MESH_STATE_FILE"
    mesh_log INFO "State file removed"

    # --- 6. Print message ---
    echo "Left the mesh. Interface $MESH_IFACE removed."

    return 0
}

# =========================================================================
# Internal helpers
# =========================================================================

# Stop the discovery listener process.
# Checks PID file first, then tries systemd units.
_mesh_leave_stop_discovery() {
    # Kill via PID file if it exists
    if [[ -f "$MESH_DISCOVER_PID_FILE" ]]; then
        local pid
        pid="$(cat "$MESH_DISCOVER_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            mesh_log INFO "Stopping discovery listener (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$MESH_DISCOVER_PID_FILE"
    fi

    # Also stop systemd units if they exist (covers systemd deployments)
    # shellcheck disable=SC2086
    systemctl stop orionx-mesh-discover.service orionx-mesh-discover.timer orionx-mesh-beacon.service 2>/dev/null || true
}

# Stop the health check timer/service.
_mesh_leave_stop_health() {
    systemctl stop orionx-mesh-health.timer orionx-mesh-health.service 2>/dev/null || true
}
