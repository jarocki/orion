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
#
#   DEC-PHASE12-097: the units stopped here are the SAME lists join starts
#   (MESH_UNITS_* in mesh-lib.sh), and the counters cleared are in
#   MESH_HEALTH_COUNTER_DIR (also mesh-lib.sh) — the directory mesh-health.sh
#   actually writes. MESH_DISCOVER_PID_FILE likewise comes from mesh-lib.sh;
#   the old re-default here to /var/run/orionx-mesh-discover.pid was dead.

set -euo pipefail

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

    # --- 2. Stop the mesh runtime units and any detached listener ---
    _mesh_leave_stop_units

    # --- 3. Tear down interface ---
    mesh_interface_down

    # --- 4. Remove state file and health state ---
    rm -f "$MESH_STATE_FILE"
    mesh_snapshot_write 2>/dev/null || true     # DEC-PHASE12-059: snapshot now says inactive
    mesh_emit info service "left the mesh ($MESH_IFACE removed)" 2>/dev/null || true
    # Per-peer counters, the mesh-wide heal budget, escalation markers and the
    # once-per-boot discovery announcement: a rejoin starts from a clean slate.
    rm -f "$MESH_HEALTH_COUNTER_DIR"/orionx-mesh-health-* \
          "$MESH_HEALTH_COUNTER_DIR"/orionx-mesh-heal-budget \
          "$MESH_HEALTH_COUNTER_DIR"/orionx-mesh-escalated-* \
          "$MESH_HEALTH_COUNTER_DIR"/orionx-mesh-discovery-announced 2>/dev/null || true
    mesh_log INFO "State file and health counters removed"

    # --- 5. Print message ---
    echo "Left the mesh. Interface $MESH_IFACE removed."
    echo "survives reboot: n/a — leaving takes effect now, and a reboot never rejoins by itself."

    return 0
}

# =========================================================================
# Internal helpers
# =========================================================================

# Stop the listener (detached fallback via PID file) and every mesh unit.
_mesh_leave_stop_units() {
    if [[ -f "$MESH_DISCOVER_PID_FILE" ]]; then
        local pid
        pid="$(cat "$MESH_DISCOVER_PID_FILE" 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            mesh_log INFO "Stopping discovery listener (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$MESH_DISCOVER_PID_FILE"
    fi

    local -a units a d o
    read -r -a a <<< "$MESH_UNITS_ALWAYS"
    read -r -a d <<< "$MESH_UNITS_DISCOVERY"
    read -r -a o <<< "$MESH_UNITS_ONESHOT"
    units=("${d[@]}" "${a[@]}" "${o[@]}")
    mesh_units_stop "${units[@]}"
}
