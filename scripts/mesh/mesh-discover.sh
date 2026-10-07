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
#   handle — internal: process ONE datagram (spawned by socat per beacon)
#
# The beacon is a JSON payload broadcast on MESH_DISCOVER_PORT (55555)
# containing the node's WireGuard public key, VPN IP and WG port (no hostname, DEC-PHASE12-099).
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

# PID file for the listener process. The default lives in mesh-lib.sh, which
# is the single authority for the path (mesh-health.sh reads the same file to
# verify the listener is alive). Still overridable for testing.

# =========================================================================
# JSON helpers — use jq if available, fall back to sed/grep
# =========================================================================

# Build a beacon JSON string from the given parameters.
#
# DEC-PHASE12-099: the beacon no longer carries the hostname. It is plaintext
# broadcast on a LAN the deck is assumed NOT to trust (security F14); the
# hostname named the responder's deck to anyone listening and no receiver
# ever used it for anything but a log line. A 4th argument is accepted and
# ignored so older callers keep working.
_mesh_build_beacon() {
    local pubkey="$1"
    local vpn_ip="$2"
    local wg_port="$3"

    printf '{"pubkey":"%s","vpn_ip":"%s","wg_port":%s}' \
        "$pubkey" "$vpn_ip" "$wg_port"
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
    local pubkey vpn_ip wg_port
    pubkey="$(_mesh_parse_field "$beacon" "pubkey")"
    vpn_ip="$(_mesh_parse_field "$beacon" "vpn_ip")"
    wg_port="$(_mesh_parse_field "$beacon" "wg_port")"

    # Validate required fields
    if [[ -z "$pubkey" || -z "$vpn_ip" || -z "$wg_port" ]]; then
        mesh_log WARN "Received malformed beacon from $sender_ip (missing fields)"
        return 0
    fi

    # Filter own beacons
    if _mesh_is_own_beacon "$pubkey" "$our_pubkey"; then
        return 0
    fi

    # Dedup: a known peer is never touched (DEC-PHASE12-096: a beacon must not
    # be able to change an existing peer's allowed-ips or endpoint).
    if wg show "$MESH_IFACE" peers 2>/dev/null | grep -qxF -- "$pubkey"; then
        return 0
    fi

    # New peer — mesh_add_peer is the validation gate (DEC-PHASE12-096) and
    # logs the reason when it rejects. A rejection is not an error for the
    # listener: one bad beacon must never stop discovery.
    mesh_log INFO "Discovered peer candidate ($vpn_ip) at $sender_ip"
    mesh_add_peer "$pubkey" "$vpn_ip" "$sender_ip" "$wg_port" || true
}

# =========================================================================
# Per-datagram handler (run by socat's SYSTEM: child, one process per beacon)
# =========================================================================
#
# @decision DEC-PHASE12-095
# @title The listener hands each datagram to a handler that socat itself
#   spawns, so the sender's address is real and one bad beacon cannot kill it
# @status accepted
# @rationale The old listener was `socat ... STDOUT | while read`. socat
#   exports SOCAT_PEERADDR only into the environment of a process it
#   EXEC/SYSTEMs; the `while` loop was its sibling in a pipeline, so the
#   sender was always the literal "unknown" and every peer was added with
#   `endpoint unknown:51820` — a DNS lookup a hostile LAN answers, or a `wg`
#   error that, under `set -euo pipefail` inside the pipeline subshell, ended
#   the loop and with it discovery (shell P1-1, security F2). Verified on
#   trixie's socat (2026-10-07, debian:trixie-slim): with
#   `-u UDP-RECVFROM:<port>,reuseaddr,fork SYSTEM:<cmd>` each datagram gets
#   its own child with SOCAT_PEERADDR/SOCAT_PEERPORT set and the datagram on
#   stdin. So the handler below is that child: it reads ONE line, takes the
#   sender from SOCAT_PEERADDR, rate-limits per sender, serialises `wg set`
#   with flock, and always exits 0. A crash or rejection costs one datagram,
#   never the listener.
mesh_beacon_handle() {
    local sender_ip="${SOCAT_PEERADDR:-}"
    local line=""
    IFS= read -r -t 5 -n 2048 line || true
    [[ -n "$line" ]] || return 0

    if ! mesh_valid_ipv4 "$sender_ip"; then
        mesh_log WARN "Dropped beacon: sender address '${sender_ip:-<none>}' is not an IPv4 address"
        return 0
    fi

    # Per-sender rate limit: at most one beacon per MESH_BEACON_MIN_INTERVAL
    # seconds from one address (beacons are sent every 10 s). Excess is
    # dropped silently so a flood cannot also flood the log.
    local now stamp last=0
    now="$(date +%s)"
    mkdir -p "$MESH_RATE_DIR" 2>/dev/null || true
    stamp="$MESH_RATE_DIR/$sender_ip"
    [[ -f "$stamp" ]] && last="$(cat "$stamp" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if (( now - last < MESH_BEACON_MIN_INTERVAL )); then
        return 0
    fi
    echo "$now" > "$stamp" 2>/dev/null || true

    local our_pubkey
    our_pubkey="$(mesh_get_pubkey 2>/dev/null)" || {
        mesh_log WARN "Dropped beacon from $sender_ip: this deck has no mesh key (not joined)"
        return 0
    }

    # Serialise peer-table changes across concurrent handlers.
    if command -v flock >/dev/null 2>&1 && mkdir -p "$MESH_RUNTIME_DIR" 2>/dev/null; then
        (
            flock -w 10 9 || { mesh_log WARN "Dropped beacon from $sender_ip: peer-table lock busy"; exit 0; }
            _mesh_process_beacon "$line" "$sender_ip" "$our_pubkey"
        ) 9>"$MESH_RUNTIME_DIR/discover.lock" || true
    else
        _mesh_process_beacon "$line" "$sender_ip" "$our_pubkey" || true
    fi
    return 0
}

# =========================================================================
# Send / Listen / Stop commands
# =========================================================================

# Send a single UDP beacon broadcast.
mesh_beacon_send() {
    # Read our identity from state/keys
    local pubkey vpn_ip wg_port broadcast_addr

    pubkey="$(mesh_get_pubkey)" || {
        # W11-14f offline-safe: no keys = node not set up for mesh; a boot-time
        # beacon is normal here, not an error. Skip so the timer does not fail-loop.
        mesh_log INFO "Mesh not configured (no public key); skipping beacon"
        return 0
    }

    vpn_ip="$(mesh_state_read vpn_ip 2>/dev/null)" || {
        # W11-14f offline-safe: no VPN IP = mesh not joined (normal on a
        # standalone/offline boot). Skip cleanly; prevents the 10s beacon loop.
        mesh_log INFO "Mesh not joined (no VPN IP); skipping beacon"
        return 0
    }

    if [[ -z "$vpn_ip" ]]; then
        mesh_log INFO "Mesh not joined (VPN IP empty); skipping beacon"
        return 0
    fi

    # DEC-PHASE12-097/099: only a DISCOVERY-mode join announces itself. A
    # pre-planned (--config) join on a hostile LAN must stay silent, even
    # though orionx-mesh-discover.timer is enabled at boot.
    local mode
    mode="$(mesh_state_read mode 2>/dev/null || true)"
    if [[ "$mode" != "discovery" ]]; then
        mesh_log INFO "Mesh joined in '${mode:-unknown}' mode; beacons are sent only in discovery mode"
        return 0
    fi

    wg_port="${MESH_WG_PORT}"
    broadcast_addr="$(_mesh_get_broadcast_addr)"

    local beacon
    beacon="$(_mesh_build_beacon "$pubkey" "$vpn_ip" "$wg_port")"

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

    mesh_get_pubkey >/dev/null || {
        mesh_log ERROR "Cannot start listener: no public key available"
        return 1
    }

    # A pre-planned (--config) join runs no listener (DEC-PHASE12-097). Exit
    # 0 so Restart=on-failure does not loop.
    local mode
    mode="$(mesh_state_read mode 2>/dev/null || true)"
    if [[ "$mode" == "config" ]]; then
        mesh_log INFO "Mesh joined in config mode; the discovery listener does not run"
        return 0
    fi

    # The handler is THIS script (`handle` mode), spawned by socat once per
    # datagram with SOCAT_PEERADDR set (DEC-PHASE12-095). socat's SYSTEM:
    # address is parsed by socat, so the path must not contain its
    # separators.
    local self
    self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    if [[ "$self" == *[,:!\'\"\ ]* ]]; then
        mesh_log ERROR "Cannot start listener: handler path '$self' contains a character socat treats as an address separator"
        return 1
    fi

    # The PID file names the process that actually listens: exec replaces
    # this shell with socat under the same PID, so mesh-health's kill -0 and
    # `mesh-discover.sh stop` see the real listener.
    _mesh_write_pid "$$"
    mesh_log INFO "Starting beacon listener on port $MESH_DISCOVER_PORT (PID $$)"
    exec socat -u "UDP-RECVFROM:${MESH_DISCOVER_PORT},broadcast,reuseaddr,fork" \
        "SYSTEM:exec $self handle"
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
        handle)
            # Internal: one datagram on stdin, sender in SOCAT_PEERADDR.
            mesh_beacon_handle
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
