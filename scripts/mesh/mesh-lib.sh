# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Mesh Networking Shared Library
#
# Sourced by all mesh scripts (orionx-mesh join|status|peers|leave,
# discovery daemon, health-check timer). Provides logging, WireGuard
# helpers, config parsing, PSK management, and state management.
#
# Usage:  source /path/to/mesh-lib.sh
#         (Do NOT execute directly — this is a library.)
#
# @decision DEC-MESH-004
# @title Single bash CLI with case-based subcommands and shared library
# @status accepted
# @rationale Consistent with existing Orion-X codebase (setup-vpn.sh,
#   build-iso.sh). A single sourced library avoids duplication across
#   the mesh join/status/peers/leave/discovery/health scripts. All mesh
#   scripts source this file for constants, logging, and WireGuard ops.
#
# @decision DEC-MESH-005
# @title Direct wg/ip commands for runtime, wg-quick for bootstrap only
# @status accepted
# @rationale Using `wg set` and `ip link/addr` for runtime peer changes
#   avoids the 2-minute WireGuard handshake lockout that occurs when
#   tearing down and recreating the interface via wg-quick. wg-quick is
#   only used during initial bootstrap (orionx-mesh join). This "soft
#   healing" approach was validated by research (see research-log.md).

# =========================================================================
# Constants — override via environment for testing
# =========================================================================

MESH_IFACE="${MESH_IFACE:-wg0}"
MESH_SUBNET="${MESH_SUBNET:-10.0.99.0/24}"
MESH_VPN_PREFIX="${MESH_VPN_PREFIX:-10.0.99}"
MESH_WG_PORT="${MESH_WG_PORT:-51820}"
MESH_DISCOVER_PORT="${MESH_DISCOVER_PORT:-55555}"
MESH_STATE_FILE="${MESH_STATE_FILE:-/var/run/orionx-mesh.state}"
MESH_PRIVATE_KEY="${MESH_PRIVATE_KEY:-/etc/wireguard/mesh-private.key}"
MESH_PSK_FILE="${MESH_PSK_FILE:-/etc/wireguard/mesh-psk}"
MESH_LOG_FILE="${MESH_LOG_FILE:-/var/log/orionx/mesh.log}"
MESH_HEALTH_INTERVAL="${MESH_HEALTH_INTERVAL:-60}"
MESH_DISCOVER_INTERVAL="${MESH_DISCOVER_INTERVAL:-10}"

# File used to track claimed VPN IPs (one octet per line) for collision avoidance
MESH_CLAIMED_IPS="${MESH_CLAIMED_IPS:-}"

# =========================================================================
# Logging
# =========================================================================

# Log to MESH_LOG_FILE and stderr with timestamp and level.
# stderr is used (not stdout) so that functions can return values
# via stdout without log messages corrupting the output.
# Falls back to stderr-only if log directory does not exist.
mesh_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local formatted="[${timestamp}] [${level}] ${message}"

    local log_dir
    log_dir="$(dirname "$MESH_LOG_FILE")"

    if [[ -d "$log_dir" ]]; then
        echo "$formatted" >> "$MESH_LOG_FILE"
    fi
    # Always echo to stderr for terminal visibility
    echo "$formatted" >&2
}

# =========================================================================
# WireGuard key management
# =========================================================================

# Generate WireGuard keypair. Stores private key at MESH_PRIVATE_KEY
# (mode 0600). Returns public key on stdout. Idempotent: skips if
# private key already exists.
mesh_genkeys() {
    if [[ -f "$MESH_PRIVATE_KEY" ]]; then
        mesh_log INFO "Private key already exists at $MESH_PRIVATE_KEY, skipping generation"
        mesh_get_pubkey
        return 0
    fi

    local key_dir
    key_dir="$(dirname "$MESH_PRIVATE_KEY")"
    mkdir -p "$key_dir"

    wg genkey > "$MESH_PRIVATE_KEY"
    chmod 0600 "$MESH_PRIVATE_KEY"

    mesh_log INFO "Generated new WireGuard keypair"
    mesh_get_pubkey
}

# Read public key derived from the private key file.
mesh_get_pubkey() {
    if [[ ! -f "$MESH_PRIVATE_KEY" ]]; then
        mesh_log ERROR "Private key not found at $MESH_PRIVATE_KEY"
        return 1
    fi
    wg pubkey < "$MESH_PRIVATE_KEY"
}

# =========================================================================
# VPN IP allocation
# =========================================================================

# Detect the primary LAN IP address. Separated into its own function
# so tests can override it.
_mesh_detect_lan_ip() {
    # Try ip route first (Linux), fall back to hostname (macOS/BSD)
    if command -v ip >/dev/null 2>&1; then
        ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}'
    else
        # macOS fallback: use ipconfig or hostname
        local iface
        iface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
        if [[ -n "$iface" ]]; then
            ipconfig getifaddr "$iface" 2>/dev/null
        fi
    fi
}

# Allocate a VPN IP from the MESH_VPN_PREFIX subnet.
# Strategy: derive last octet from primary LAN IP. If collision
# detected (via MESH_CLAIMED_IPS file), increment until free.
mesh_get_vpn_ip() {
    local lan_ip
    lan_ip="$(_mesh_detect_lan_ip)"

    if [[ -z "$lan_ip" ]]; then
        mesh_log ERROR "Could not detect LAN IP for VPN allocation"
        return 1
    fi

    # Extract last octet from LAN IP
    local last_octet
    last_octet="${lan_ip##*.}"

    # Load claimed IPs if collision file exists
    local -a claimed=()
    if [[ -n "$MESH_CLAIMED_IPS" && -f "$MESH_CLAIMED_IPS" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && claimed+=("$line")
        done < "$MESH_CLAIMED_IPS"
    fi

    # Check for collision and increment
    local candidate="$last_octet"
    local attempts=0
    local max_attempts=254

    while (( attempts < max_attempts )); do
        local collision=false
        if [[ ${#claimed[@]} -gt 0 ]]; then
            for c in "${claimed[@]}"; do
                if [[ "$c" == "$candidate" ]]; then
                    collision=true
                    break
                fi
            done
        fi

        if [[ "$collision" == "false" ]]; then
            echo "${MESH_VPN_PREFIX}.${candidate}"
            return 0
        fi

        # Increment with wrap: 1-255
        candidate=$(( (candidate % 255) + 1 ))
        (( attempts++ )) || true
    done

    mesh_log ERROR "No free VPN IP available in ${MESH_SUBNET}"
    return 1
}

# =========================================================================
# WireGuard interface management
# =========================================================================

# Create wg0 interface with the given VPN IP using ip/wg commands.
# NOT wg-quick — that's only for bootstrap.
mesh_interface_up() {
    local vpn_ip="$1"
    local private_key_file="${2:-$MESH_PRIVATE_KEY}"
    local listen_port="${3:-$MESH_WG_PORT}"

    if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
        mesh_log WARN "Interface $MESH_IFACE already exists"
        return 0
    fi

    mesh_log INFO "Creating interface $MESH_IFACE with IP $vpn_ip"

    ip link add dev "$MESH_IFACE" type wireguard
    ip addr add "${vpn_ip}/24" dev "$MESH_IFACE"
    wg set "$MESH_IFACE" \
        listen-port "$listen_port" \
        private-key "$private_key_file"
    ip link set "$MESH_IFACE" up

    mesh_log INFO "Interface $MESH_IFACE is up"
}

# Tear down wg0 interface cleanly.
mesh_interface_down() {
    if ! ip link show "$MESH_IFACE" >/dev/null 2>&1; then
        mesh_log WARN "Interface $MESH_IFACE does not exist, nothing to tear down"
        return 0
    fi

    mesh_log INFO "Tearing down interface $MESH_IFACE"
    ip link set "$MESH_IFACE" down
    ip link delete dev "$MESH_IFACE"
    mesh_log INFO "Interface $MESH_IFACE removed"
}

# Add a peer to the mesh interface.
# Idempotent: skips if peer already exists with same config.
mesh_add_peer() {
    local pubkey="$1"
    local vpn_ip="$2"
    local endpoint="$3"
    local port="$4"
    local psk_file="${5:-$MESH_PSK_FILE}"

    # Check if peer already exists
    if wg show "$MESH_IFACE" peers 2>/dev/null | grep -q "^${pubkey}$"; then
        mesh_log INFO "Peer $pubkey already exists, skipping"
        return 0
    fi

    mesh_log INFO "Adding peer $pubkey (${vpn_ip}) endpoint ${endpoint}:${port}"

    local -a cmd=(wg set "$MESH_IFACE" peer "$pubkey"
        allowed-ips "${vpn_ip}/32"
        endpoint "${endpoint}:${port}")

    if [[ -f "$psk_file" ]]; then
        cmd+=(preshared-key "$psk_file")
    fi

    "${cmd[@]}"
    mesh_log INFO "Peer $pubkey added successfully"
}

# Remove a peer from the mesh interface.
mesh_remove_peer() {
    local pubkey="$1"

    if ! wg show "$MESH_IFACE" peers 2>/dev/null | grep -q "^${pubkey}$"; then
        mesh_log WARN "Peer $pubkey not found on $MESH_IFACE"
        return 0
    fi

    mesh_log INFO "Removing peer $pubkey"
    wg set "$MESH_IFACE" peer "$pubkey" remove
    mesh_log INFO "Peer $pubkey removed"
}

# =========================================================================
# Config parsing (pre-planned mode)
# =========================================================================

# Parse a mesh peer config file. Format: one peer per line,
# fields: <hostname> <pubkey> <vpn_ip> <endpoint_ip> <wg_port>
# Lines starting with # are comments. Blank lines are skipped.
# Returns parsed data on stdout suitable for iteration.
mesh_parse_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        mesh_log WARN "Config file not found: $config_file"
        return 0
    fi

    local output=""
    while IFS= read -r line; do
        # Skip comments and blank lines
        local trimmed
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        if [[ -z "$output" ]]; then
            output="$trimmed"
        else
            output="${output}
${trimmed}"
        fi
    done < "$config_file"

    echo -n "$output"
}

# =========================================================================
# PSK management
# =========================================================================

# Generate mesh-wide PSK at MESH_PSK_FILE (mode 0600) if not exists.
# Idempotent.
mesh_ensure_psk() {
    if [[ -f "$MESH_PSK_FILE" ]]; then
        mesh_log INFO "PSK already exists at $MESH_PSK_FILE, skipping"
        return 0
    fi

    local psk_dir
    psk_dir="$(dirname "$MESH_PSK_FILE")"
    mkdir -p "$psk_dir"

    wg genpsk > "$MESH_PSK_FILE"
    chmod 0600 "$MESH_PSK_FILE"
    mesh_log INFO "Generated mesh-wide PSK at $MESH_PSK_FILE"
}

# Return PSK file path.
mesh_get_psk_path() {
    echo "$MESH_PSK_FILE"
}

# =========================================================================
# State management
# =========================================================================

# Write mesh state to MESH_STATE_FILE as JSON.
# Args: interface vpn_ip mode pubkey
mesh_state_write() {
    local interface="$1"
    local vpn_ip="$2"
    local mode="$3"
    local pubkey="$4"
    local start_time
    start_time="$(date +%s)"

    local state_dir
    state_dir="$(dirname "$MESH_STATE_FILE")"
    mkdir -p "$state_dir"

    cat > "$MESH_STATE_FILE" << STATEEOF
{
  "interface": "${interface}",
  "vpn_ip": "${vpn_ip}",
  "mode": "${mode}",
  "start_time": "${start_time}",
  "pubkey": "${pubkey}"
}
STATEEOF

    mesh_log INFO "State written to $MESH_STATE_FILE"
}

# Read a field from the mesh state file.
# Arg: field name (interface, vpn_ip, mode, start_time, pubkey)
mesh_state_read() {
    local field="$1"

    if [[ ! -f "$MESH_STATE_FILE" ]]; then
        mesh_log WARN "State file not found: $MESH_STATE_FILE"
        return 1
    fi

    # Simple JSON field extraction without external dependencies.
    # Handles: "field": "value" patterns.
    local value
    value="$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$MESH_STATE_FILE")"
    echo "$value"
}

# Check if the mesh is active (state file exists AND wg0 interface is up).
# Returns 0 if active, 1 otherwise.
mesh_is_active() {
    # Check state file
    if [[ ! -f "$MESH_STATE_FILE" ]]; then
        return 1
    fi

    # Check interface — use ip link on Linux, ifconfig elsewhere
    if command -v ip >/dev/null 2>&1; then
        ip link show "$MESH_IFACE" >/dev/null 2>&1 || return 1
    else
        ifconfig "$MESH_IFACE" >/dev/null 2>&1 || return 1
    fi

    return 0
}

# =========================================================================
# Output formatting helpers
# =========================================================================

# Format seconds into human-readable duration (e.g., "1h 23m", "45s")
mesh_format_duration() {
    local seconds="${1:-0}"
    if [[ "$seconds" -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ "$seconds" -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    elif [[ "$seconds" -lt 86400 ]]; then
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    else
        echo "$((seconds / 86400))d $((seconds % 86400 / 3600))h"
    fi
}

# Format bytes into human-readable size (e.g., "1.2K", "3.4M")
mesh_format_bytes() {
    local bytes="${1:-0}"
    if [[ "$bytes" -lt 1024 ]]; then
        echo "${bytes}B"
    elif [[ "$bytes" -lt 1048576 ]]; then
        echo "$(( bytes / 1024 )).$(( (bytes % 1024) * 10 / 1024 ))K"
    elif [[ "$bytes" -lt 1073741824 ]]; then
        echo "$(( bytes / 1048576 )).$(( (bytes % 1048576) * 10 / 1048576 ))M"
    else
        echo "$(( bytes / 1073741824 )).$(( (bytes % 1073741824) * 10 / 1073741824 ))G"
    fi
}

# Format handshake timestamp as relative time (e.g., "12s ago", "never")
mesh_format_handshake() {
    local ts="${1:-0}"
    if [[ "$ts" == "0" || -z "$ts" ]]; then
        echo "never"
        return
    fi
    local now
    now=$(date +%s)
    local diff=$(( now - ts ))
    if [[ "$diff" -lt 0 ]]; then
        echo "future?"
    else
        echo "$(mesh_format_duration "$diff") ago"
    fi
}
