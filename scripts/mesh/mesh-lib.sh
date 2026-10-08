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
# PID file for the discovery listener. Defined HERE and nowhere else: both
# mesh-discover.sh (which writes it) and mesh-health.sh (which reads it to
# find out whether the listener is actually alive) need the same answer.
# /run/orionx-mesh is the mesh units' RuntimeDirectory (DEC-PHASE12-041), so
# the confined units can write here under ProtectSystem=strict without being
# handed all of /run.
MESH_RUNTIME_DIR="${MESH_RUNTIME_DIR:-/run/orionx-mesh}"
MESH_DISCOVER_PID_FILE="${MESH_DISCOVER_PID_FILE:-$MESH_RUNTIME_DIR/orionx-mesh-discover.pid}"
# Heal counters, budget and escalation markers (mesh-health.sh). Defined here,
# not in mesh-health.sh, because `orionx-mesh leave` must clear the SAME
# directory (DEC-PHASE12-097: leave used to rm /var/run/orionx-mesh-health-*,
# a path nothing writes, so a spent heal budget survived leave+rejoin).
MESH_HEALTH_COUNTER_DIR="${MESH_HEALTH_COUNTER_DIR:-$MESH_RUNTIME_DIR}"
# Per-sender beacon rate limiter state (DEC-PHASE12-096).
MESH_RATE_DIR="${MESH_RATE_DIR:-$MESH_RUNTIME_DIR/beacon-rate}"
MESH_BEACON_MIN_INTERVAL="${MESH_BEACON_MIN_INTERVAL:-5}"
MESH_PRIVATE_KEY="${MESH_PRIVATE_KEY:-/etc/wireguard/mesh-private.key}"
MESH_PSK_FILE="${MESH_PSK_FILE:-/etc/wireguard/mesh-psk}"

# @decision DEC-PHASE12-097
# @title One list of mesh runtime units: join starts it, leave stops it
# @status accepted
# @rationale leave stopped the listener and the beacon/health timers, and
#   join started nothing — so after leave+join the deck sent no beacon, ran
#   no health check and processed no inbound beacon until reboot, and a deck
#   that joined after boot never got the listener at all (its
#   ConditionPathExists=/sys/class/net/wg0 was false at boot and nothing
#   retried it). Instead join forked `mesh-discover.sh listen &` as a child of
#   the Cockpit's terminal, unconfined and killed by SIGHUP when the window
#   closed. Both commands now read these two lists, so they cannot drift.
#   MESH_UNITS_ALWAYS run in either join mode; MESH_UNITS_DISCOVERY only in
#   discovery mode (a pre-planned --config join must not broadcast).
MESH_UNITS_ALWAYS="${MESH_UNITS_ALWAYS:-orionx-mesh-health.timer orionx-mesh-status.timer}"
MESH_UNITS_DISCOVERY="${MESH_UNITS_DISCOVERY:-orionx-mesh-discover.service orionx-mesh-discover.timer}"
# Oneshots the timers trigger; leave stops them too in case one is mid-run.
MESH_UNITS_ONESHOT="${MESH_UNITS_ONESHOT:-orionx-mesh-beacon.service orionx-mesh-health.service}"
MESH_SYSTEMCTL="${MESH_SYSTEMCTL:-systemctl}"
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
        # `|| true`: under ProtectSystem=strict an unwritable log (EROFS) must
        # not abort the caller's own failure report under set -e (system P3-3).
        { echo "$formatted" >> "$MESH_LOG_FILE"; } 2>/dev/null || true
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

    # B2 handoff: every step is checked. Callers run this inside $(...), where
    # set -e is NOT inherited, so a failed write used to fall through to
    # "Generated new WireGuard keypair" and then "Private key not found".
    local key_dir
    key_dir="$(dirname "$MESH_PRIVATE_KEY")"
    if ! mkdir -p "$key_dir" 2>/dev/null; then
        mesh_log ERROR "Cannot create $key_dir — no WireGuard key generated (run as root: sudo orionx-mesh join)"
        return 1
    fi

    if ! (umask 077; wg genkey > "$MESH_PRIVATE_KEY") 2>/dev/null || [[ ! -s "$MESH_PRIVATE_KEY" ]]; then
        rm -f "$MESH_PRIVATE_KEY" 2>/dev/null || true
        mesh_log ERROR "Could not write the WireGuard private key to $MESH_PRIVATE_KEY"
        return 1
    fi
    chmod 0600 "$MESH_PRIVATE_KEY"   # born 0600 under umask 077; chmod is belt

    local pub
    if ! pub="$(mesh_get_pubkey)" || [[ -z "$pub" ]]; then
        mesh_log ERROR "Generated $MESH_PRIVATE_KEY but could not derive its public key (wg pubkey failed)"
        return 1
    fi
    mesh_log INFO "Generated new WireGuard keypair"
    echo "$pub"
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

# =========================================================================
# Peer validation — the single gate every peer passes before `wg set`
# =========================================================================
#
# @decision DEC-PHASE12-096
# @title Every peer is validated before it reaches `wg set`; a beacon can add
#   a peer but never move an address
# @status accepted
# @rationale Beacons are unauthenticated UDP from the LAN. vpn_ip went into
#   `allowed-ips "${vpn_ip}/32"` verbatim, so a beacon carrying
#   "10.0.99.0/24,10.0.99.1" produced allowed-ips 10.0.99.0/24,10.0.99.1/32
#   and — because WireGuard allowed-ips are unique across peers — moved the
#   whole mesh /24 onto the rogue key (security F2). The gate lives here, in
#   mesh_add_peer, so the discovery path and the --config path share it:
#     pubkey   44-char base64 of a 32-byte key (the only shape wg emits)
#     vpn_ip   ONE dotted-quad host inside MESH_VPN_PREFIX.0/24, .1-.254,
#              never our own address, never an address another peer holds
#     endpoint an IPv4 literal (no name lookup: "unknown" used to go to DNS,
#              which a hostile LAN's DHCP server answers)
#     port     1-65535
#   A pubkey that is already a peer is left untouched (no allowed-ips change).
#   Rejections are logged with the reason and return 3; callers treat that as
#   "dropped", not as a fatal error.

mesh_valid_pubkey() {
    [[ "${1:-}" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw480]=$ ]]
}

mesh_valid_ipv4() {
    local ip="${1:-}" o
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        [[ "$o" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
        (( o <= 255 )) || return 1
    done
}

# One host inside the mesh /24, not the network or broadcast address.
mesh_valid_mesh_ip() {
    local ip="${1:-}" last
    mesh_valid_ipv4 "$ip" || return 1
    [[ "${ip%.*}" == "$MESH_VPN_PREFIX" ]] || return 1
    last="${ip##*.}"
    (( last >= 1 && last <= 254 ))
}

mesh_valid_port() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

# Print the reason a peer is unacceptable, or nothing (and return 0) if it is.
mesh_peer_reject_reason() {
    local pubkey="$1" vpn_ip="$2" endpoint="$3" port="$4"
    mesh_valid_pubkey "$pubkey" || { echo "pubkey is not a WireGuard public key"; return 1; }
    mesh_valid_mesh_ip "$vpn_ip" || { echo "vpn_ip '$vpn_ip' is not a single host in ${MESH_VPN_PREFIX}.0/24"; return 1; }
    mesh_valid_ipv4 "$endpoint" || { echo "endpoint '$endpoint' is not an IPv4 address"; return 1; }
    mesh_valid_port "$port" || { echo "port '$port' is not 1-65535"; return 1; }
    local own
    own="$(mesh_state_read vpn_ip 2>/dev/null || true)"
    if [[ -n "$own" && "$vpn_ip" == "$own" ]]; then
        echo "vpn_ip $vpn_ip is THIS deck's mesh address (address collision: two decks derived the same last octet; one must leave and rejoin from a LAN address with a different last octet)"
        return 1
    fi
    local holder
    holder="$(wg show "$MESH_IFACE" allowed-ips 2>/dev/null \
              | awk -v ip="${vpn_ip}/32" -v me="$pubkey" '$1 != me { for (i = 2; i <= NF; i++) if ($i == ip) { print $1; exit } }')"
    if [[ -n "$holder" ]]; then
        echo "vpn_ip $vpn_ip is already held by peer ${holder:0:10}…"
        return 1
    fi
    return 0
}

# Add a peer to the mesh interface.
# Idempotent: skips if peer already exists (its allowed-ips are never changed).
# Returns 3 when the peer is rejected by the validation gate above.
mesh_add_peer() {
    local pubkey="$1"
    local vpn_ip="$2"
    local endpoint="$3"
    local port="$4"
    local psk_file="${5:-$MESH_PSK_FILE}"

    # Check if peer already exists — never rewrite a known peer's allowed-ips.
    if mesh_valid_pubkey "$pubkey" && wg show "$MESH_IFACE" peers 2>/dev/null | grep -qxF -- "$pubkey"; then
        mesh_log INFO "Peer ${pubkey:0:10}… already exists, skipping"
        return 0
    fi

    local reason
    if ! reason="$(mesh_peer_reject_reason "$pubkey" "$vpn_ip" "$endpoint" "$port")"; then
        mesh_log WARN "Rejected peer from ${endpoint:-?}: $reason"
        return 3
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

# @decision DEC-PHASE12-098
# @title The team PSK is optional, off by default, and only ever arrives out
#   of band
# @status accepted
# @rationale mesh_ensure_psk used to mint a fresh random PSK on every deck
#   that lacked one — which on a live USB is every deck, every boot. Two stock
#   decks therefore always held DIFFERENT pre-shared keys and could never
#   complete a handshake (security F17): the mesh's only peer-authentication
#   control was also the reason the mesh never worked. A PSK is only useful
#   when every deck holds the SAME one, which needs a channel the LAN cannot
#   see. So: join never invents a PSK; if MESH_PSK_FILE exists it is used for
#   every peer, otherwise peers are keyed by public key alone (WireGuard's
#   normal mode). The out-of-band exchange is:
#     deck A:      sudo orionx-mesh psk generate /media/USB/team.psk
#     every deck:  sudo orionx-mesh psk install /media/USB/team.psk
#   and then `orionx-mesh join`. All decks in a mesh must agree: a deck with a
#   PSK cannot handshake with one without it.

# Report the PSK posture. Never creates a PSK.
mesh_psk_status() {
    if [[ -f "$MESH_PSK_FILE" ]]; then
        mesh_log INFO "Team PSK in use ($MESH_PSK_FILE) — every peer must hold the same PSK"
    else
        mesh_log INFO "No team PSK installed — peers authenticate by public key only (optional: orionx-mesh psk install <file>)"
    fi
}

# Write a new PSK to a file the operator carries to the other decks.
mesh_psk_generate() {
    local out="${1:-}"
    [[ -n "$out" ]] || { mesh_log ERROR "usage: orionx-mesh psk generate <file>"; return 1; }
    [[ ! -e "$out" ]] || { mesh_log ERROR "$out already exists — refusing to overwrite a team PSK"; return 1; }
    (umask 077; wg genpsk > "$out") || { mesh_log ERROR "could not write $out"; return 1; }
    echo "Team PSK written to $out (mode 0600). Install it on EVERY deck with: sudo orionx-mesh psk install $out"
}

# Install a PSK file (validated: one base64 32-byte key) as MESH_PSK_FILE.
mesh_psk_install() {
    local src="${1:-}" key
    [[ -n "$src" && -f "$src" ]] || { mesh_log ERROR "usage: orionx-mesh psk install <file> (file not found: ${src:-<none>})"; return 1; }
    key="$(head -c 100 "$src" | tr -d '[:space:]')"
    if ! mesh_valid_pubkey "$key"; then
        mesh_log ERROR "$src does not contain a WireGuard key (expected 44 base64 characters from 'wg genpsk')"
        return 1
    fi
    mkdir -p "$(dirname "$MESH_PSK_FILE")"
    if ! { (umask 077; printf '%s\n' "$key" > "${MESH_PSK_FILE}.tmp.$$") && mv -f "${MESH_PSK_FILE}.tmp.$$" "$MESH_PSK_FILE"; }; then
        rm -f "${MESH_PSK_FILE}.tmp.$$"
        mesh_log ERROR "could not install $MESH_PSK_FILE"
        return 1
    fi
    chmod 0600 "$MESH_PSK_FILE"   # born 0600 under umask 077; chmod is belt
    echo "Team PSK installed at $MESH_PSK_FILE. Peers added from now on use it; already-added peers do not (leave and rejoin)."
}

mesh_psk_remove() {
    rm -f "$MESH_PSK_FILE"
    echo "Team PSK removed. Peers added from now on authenticate by public key only."
}

# =========================================================================
# Mesh runtime units (DEC-PHASE12-097)
# =========================================================================

# True when PID 1 is systemd and we can drive units. MESH_FORCE_SYSTEMD=1 lets
# tests substitute MESH_SYSTEMCTL with a stub.
mesh_systemd_available() {
    [[ "${MESH_FORCE_SYSTEMD:-0}" == "1" ]] && return 0
    command -v "$MESH_SYSTEMCTL" >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

# Start each unit; print the ones that did not start. Returns non-zero if any failed.
mesh_units_start() {
    local u rc=0
    for u in "$@"; do
        if "$MESH_SYSTEMCTL" start "$u" 2>/dev/null; then
            mesh_log INFO "started $u"
        else
            mesh_log WARN "could not start $u (systemctl status $u)"
            rc=1
        fi
    done
    return "$rc"
}

# Stop each unit (best effort: a unit that is already stopped is fine).
mesh_units_stop() {
    local u
    for u in "$@"; do
        "$MESH_SYSTEMCTL" stop "$u" 2>/dev/null || true
    done
}

# "survives reboot" line for join/leave (UX-27, RESILIENCE honesty rule 4).
# The persistence check is tuning_lib.persistence_present() — the single
# authority — so the mesh never has its own idea of what persistence is.
# Even WITH persistence nothing re-joins at boot: wg0 is created only by join.
_MESH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MESH_AWARENESS_DIR="${MESH_AWARENESS_DIR:-$_MESH_LIB_DIR/../awareness}"
mesh_reboot_line() {
    local out present where
    out="$(PYTHONDONTWRITEBYTECODE=1 python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import tuning_lib as t; p, w = t.persistence_present(); print(("1" if p else "0") + "\t" + w)' "$MESH_AWARENESS_DIR" 2>/dev/null)" || out=""
    if [[ -z "$out" ]]; then
        echo "survives reboot: UNKNOWN (the persistence check could not run). Assume NO: run 'sudo orionx-mesh join' again after a reboot."
        return 0
    fi
    present="${out%%$'\t'*}"; where="${out#*$'\t'}"
    if [[ "$present" == "1" ]]; then
        echo "survives reboot: PARTLY — keys persist (persistence at $where), but the mesh interface does not come back by itself: run 'sudo orionx-mesh join' after each boot."
    else
        echo "survives reboot: NO — $where. Keys, address and peers are lost at reboot; run 'sudo orionx-mesh join' again after booting."
    fi
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

    # Atomic: the beacon and status timers read this every 10 s, and a reader
    # must never see a half-written file (shell.md P3-6). mktemp in the SAME
    # directory so the mv is a rename, never a copy.
    local tmp
    tmp="$(mktemp "${MESH_STATE_FILE}.XXXXXX")" || { mesh_log ERROR "could not create a temp file next to $MESH_STATE_FILE"; return 1; }
    cat > "$tmp" << STATEEOF
{
  "interface": "${interface}",
  "vpn_ip": "${vpn_ip}",
  "mode": "${mode}",
  "start_time": "${start_time}",
  "pubkey": "${pubkey}"
}
STATEEOF
    chmod 0644 "$tmp"
    mv -f "$tmp" "$MESH_STATE_FILE"

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

# =========================================================================
# R.A.I.N. event bus
# =========================================================================
#
# @decision DEC-PHASE12-041
# @title Mesh self-healing publishes to the R.A.I.N. bus as self-STATUS, never
#   as a threat, and never claims a publication it did not confirm
# @status accepted
# @rationale Before this, every mesh healing decision went only to
#   mesh_log WARN -> the journal. The operator learned nothing: the deck could
#   retry an interface heal every two minutes for hours and the only surface
#   that said so was `journalctl -u orionx-mesh-health`. RESILIENCE rule 8
#   (degrade loudly, name the remedy) requires the bus.
#
#   The category is constrained on purpose. rain_lib.STATUS_CATEGORIES are
#   excluded from THREAT PRESSURE; everything else counts as a threat
#   (DEC-PHASE12-040, and rule 5: "self-diagnosis is not a threat"). A mesh
#   peer that is switched off is self-status, so this helper REFUSES any
#   category outside the self-status set rather than letting a future edit
#   drive the gauge with the deck's own health. That is the orionx-postured
#   suricata-loop defect (DEC-PHASE12-034) encoded as a guard instead of a
#   comment.
#
#   Publication is confirmed, not assumed (rule 3): if orionx-event is absent
#   or exits non-zero, this returns non-zero and says so. A caller that logs
#   "published" on the strength of having called this is reintroducing the
#   toggle-theme.sh bug.

# The CLI that publishes onto the bus. Overridable for tests.
MESH_EVENT_CLI="${MESH_EVENT_CLI:-orionx-event}"

# Categories this subsystem is allowed to emit. Both are in
# rain_lib.STATUS_CATEGORIES, so neither moves THREAT PRESSURE.
MESH_EVENT_CATEGORIES="${MESH_EVENT_CATEGORIES:-health service}"

# Publish one event. Args: severity category message [detail-json]
# Returns 0 only when the event was actually written to the bus.
mesh_emit() {
    local severity="$1"
    local category="$2"
    local message="$3"
    local detail="${4:-}"

    local allowed=1 known
    for known in $MESH_EVENT_CATEGORIES; do
        [[ "$category" == "$known" ]] && allowed=0 && break
    done
    if (( allowed != 0 )); then
        mesh_log ERROR "mesh_emit refused category '$category' — mesh self-healing is self-status; use one of: $MESH_EVENT_CATEGORIES (DEC-PHASE12-040)"
        return 2
    fi

    if ! command -v "$MESH_EVENT_CLI" >/dev/null 2>&1; then
        mesh_log WARN "orionx-event not found — event NOT published to the R.A.I.N. bus: [$severity/$category] $message"
        return 1
    fi

    local -a cmd=("$MESH_EVENT_CLI" --severity "$severity" --source mesh --category "$category")
    [[ -n "$detail" ]] && cmd+=(--detail "$detail")
    cmd+=("$message")

    if "${cmd[@]}" >/dev/null 2>&1; then
        mesh_log INFO "published [$severity/$category] $message"
        return 0
    fi

    mesh_log ERROR "orionx-event exited non-zero — event NOT published: [$severity/$category] $message"
    return 1
}

# --- Status snapshot (DEC-PHASE12-059) ---------------------------------------
# Root-only inputs (`wg show dump`, the state file) -> a world-readable JSON the
# Cockpit reads with no privilege. Written by orionx-mesh-status.timer every
# 10 s while wg0 exists, and by join/leave the moment the state changes.
MESH_SNAPSHOT_FILE="${MESH_SNAPSHOT_FILE:-/run/orionx/mesh-status.json}"

mesh_snapshot_write() {
    local now active iface vpn_ip mode start pub peers first tmp
    local pubkey _psk endpoint allowed hs tx rx _ka node
    now="$(date +%s)"
    mkdir -p "$(dirname "$MESH_SNAPSHOT_FILE")" 2>/dev/null || true
    active=false; iface=""; vpn_ip=""; mode=""; start=0; pub=""
    if mesh_is_active; then
        active=true
        iface="$(mesh_state_read interface 2>/dev/null || true)"
        vpn_ip="$(mesh_state_read vpn_ip 2>/dev/null || true)"
        mode="$(mesh_state_read mode 2>/dev/null || true)"
        start="$(mesh_state_read start_time 2>/dev/null || echo 0)"
        pub="$(mesh_state_read pubkey 2>/dev/null || true)"
    fi
    [[ "$start" =~ ^[0-9]+$ ]] || start=0
    peers="["; first=1
    while IFS=$'\t' read -r pubkey _psk endpoint allowed hs tx rx _ka; do
        [[ -n "$pubkey" ]] || continue
        node="${allowed%%,*}"; node="${node%%/*}"
        [[ "$allowed" == "(none)" ]] && node=""
        [[ "$endpoint" == "(none)" ]] && endpoint=""
        [[ "$hs" =~ ^[0-9]+$ ]] || hs=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        (( first )) || peers+=","
        first=0
        peers+="$(printf '{"pubkey_short":"%s","node":"%s","endpoint":"%s","handshake":%s,"rx":%s,"tx":%s}' \
                  "${pubkey:0:10}" "$node" "$endpoint" "$hs" "$rx" "$tx")"
    done < <(wg show "${iface:-$MESH_IFACE}" dump 2>/dev/null | tail -n +2)
    peers+="]"
    # Unique temp name: the timer and join/leave can write concurrently, and a
    # fixed ".tmp" let one writer rename the other's half-written file.
    tmp="$(mktemp "${MESH_SNAPSHOT_FILE}.XXXXXX" 2>/dev/null)" || tmp=""
    if [[ -n "$tmp" ]] && printf '{"ts":%s,"active":%s,"interface":"%s","vpn_ip":"%s","mode":"%s","start_time":%s,"pubkey_short":"%s","peers":%s}\n' \
            "$now" "$active" "${iface:-$MESH_IFACE}" "$vpn_ip" "$mode" "$start" "${pub:0:10}" "$peers" > "$tmp" 2>/dev/null \
       && chmod 0644 "$tmp" 2>/dev/null && mv -f "$tmp" "$MESH_SNAPSHOT_FILE" 2>/dev/null; then
        return 0
    fi
    [[ -n "$tmp" ]] && rm -f "$tmp"
    mesh_log WARN "could not write $MESH_SNAPSHOT_FILE — the Cockpit's Mesh tab will say 'no snapshot'"
    return 1
}
