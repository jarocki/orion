#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Mesh Health Check Daemon
#
# Invoked by a systemd timer every 60 seconds (oneshot). Each invocation:
#   1. Verifies the wg0 interface exists; attempts restore if missing.
#   2. Verifies that peer DISCOVERY is actually wired up, and says so once
#      per boot if it is not.
#   3. Classifies every WireGuard peer (handshake freshness + ping), then
#      applies a BOUNDED repair plan and VERIFIES that it worked.
#   4. Logs a summary and publishes terminal states to the R.A.I.N. bus.
#
# Failure counters, the heal budget and escalation markers persist across
# invocations via files in MESH_HEALTH_COUNTER_DIR (/run/orionx-mesh by
# default, a tmpfs — so the budget resets on reboot, which is correct).
# A successful handshake clears all three for that peer.
#
# Dependencies: mesh-lib.sh, ip, wg, ping, orionx-event (optional)
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
# @title Soft heal via wg set before aggressive interface restart
# @status accepted
# @rationale Using `wg set $IFACE peer $PUBKEY endpoint $ENDPOINT`
#   re-triggers the WireGuard handshake without tearing down the interface.
#   This avoids the 2-minute handshake lockout and packet loss that occurs
#   during a full interface down/up cycle. Aggressive heal is reserved for
#   the case where EVERY peer is stale, which is the only evidence that the
#   fault is the interface rather than one peer.
#
# @decision DEC-PHASE12-041
# @title Mesh healing is bounded, verified, non-destructive, and audible
# @status accepted
# @rationale Three defects, measured on rc4, all in these ~40 lines:
#
#   1. UNBOUNDED REPAIR (RESILIENCE rule 4). The timer fires every 60s,
#      MESH_AGGRESSIVE_THRESHOLD=2 and a peer is stale after 180s, so ONE
#      powered-off peer drove an "aggressive heal" every ~2 minutes,
#      forever. health_clear_all_counters() reset the budget after each
#      heal, so it could never escalate and never stop. Same shape as the
#      orionx-postured suricata loop (DEC-PHASE12-034), with a larger blast
#      radius: the repair breaks working connectivity for every HEALTHY
#      peer in order to chase one peer that is simply switched off.
#
#      Now: the per-peer failure counter and the mesh-wide heal budget are
#      SEPARATE. Only a confirmed handshake clears the budget. After
#      MESH_MAX_AGGRESSIVE_HEALS the subsystem escalates ONCE and stops.
#
#   2. A DEAD AUTHORITY THAT COULD NEVER HAVE WORKED (rule 7). The heal ran
#      `wg-quick down wg0 && wg-quick up wg0`. Nothing in Orion-X ever
#      writes /etc/wireguard/wg0.conf — `orionx-mesh join` builds the
#      interface with `ip link add type wireguard` + `wg set`
#      (mesh_interface_up, DEC-MESH-005), and setup-wireguard.sh writes
#      /etc/wireguard/orionx.conf for an unrelated client VPN. wg-quick
#      parses $CONFIG_FILE before it does anything, for BOTH `up` and
#      `down`, so both invocations died with "`/etc/wireguard/wg0.conf'
#      does not exist". The `2>/dev/null || true` on the down and the
#      caller's `|| rc=$?` on the up swallowed every trace. The heal was a
#      silent no-op that reported rc=2 ("aggressive heal triggered") —
#      rule 3, exactly.
#
#      Now: the interface is bounced with `ip link set wg0 down/up`, which
#      is the same authority that created it, and which PRESERVES peers and
#      keys. A teardown would have destroyed every peer's configuration to
#      fix one peer, and only discovery could have restored it.
#
#   3. SILENT (rule 8). The only surface was `mesh_log WARN` into the
#      journal. Nothing reached the R.A.I.N. bus, so the operator could not
#      learn that the mesh had given up. Terminal states now publish via
#      mesh_emit, in a STATUS category, so they are audible without moving
#      THREAT PRESSURE (rule 5).
#
#   The loop is now complete: health_plan_action() is a pure function from
#   observation to intent (Plan), health_check_peer() applies it (Do),
#   health_verify_handshake() re-reads `wg show` to find out whether a
#   handshake actually happened (Check), the budget bounds the attempts and
#   escalates once (Repair), and a real handshake resets the budget (Loop).

set -euo pipefail

# --- Resolve script directory for reliable sourcing ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Source mesh library (provides constants, logging, WG helpers) ---
# shellcheck source=mesh-lib.sh disable=SC1091
source "$SCRIPT_DIR/mesh-lib.sh"

# State directory for counters, heal budget and escalation markers. This is
# the mesh units' RuntimeDirectory (RuntimeDirectoryPreserve=yes, so it
# survives a oneshot exit — without that the heal budget would reset every
# 60 seconds and the bound would not be a bound).
# MESH_HEALTH_COUNTER_DIR is defined in mesh-lib.sh (sourced above), so that
# `orionx-mesh leave` clears the same directory this script writes.

# Handshake staleness threshold in seconds (3 minutes).
MESH_HANDSHAKE_STALE_SECS="${MESH_HANDSHAKE_STALE_SECS:-180}"

# Aggressive heal threshold: consecutive failed checks before an interface
# bounce is even CONSIDERED for a peer.
MESH_AGGRESSIVE_THRESHOLD="${MESH_AGGRESSIVE_THRESHOLD:-2}"

# Hard ceiling on interface bounces per outage episode, mesh-wide. Only a
# confirmed handshake resets it. This is the bound the old code did not have.
MESH_MAX_AGGRESSIVE_HEALS="${MESH_MAX_AGGRESSIVE_HEALS:-2}"

# Bounded verification of a heal: did a handshake ACTUALLY happen?
MESH_HEAL_VERIFY_TRIES="${MESH_HEAL_VERIFY_TRIES:-3}"
MESH_HEAL_VERIFY_WAIT="${MESH_HEAL_VERIFY_WAIT:-5}"

# Where installed unit files live. Overridable so the discovery-wiring check
# is testable without systemd.
MESH_UNIT_DIR="${MESH_UNIT_DIR:-/lib/systemd/system}"

# Set by health_aggressive_heal: "yes" | "no" | "unverified".
# Never assume a heal worked — read this.
HEALTH_LAST_HEAL_VERIFIED="unverified"

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
#
# Restore goes through mesh_interface_up — the SAME authority that created
# the interface in `orionx-mesh join`. It used to call `wg-quick up wg0`,
# which can never succeed because no wg0.conf is ever written (see
# DEC-PHASE12-041 note 2).
health_check_interface() {
    if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
        return 0
    fi

    mesh_log WARN "Interface $MESH_IFACE missing — attempting restore"

    local vpn_ip=""
    vpn_ip="$(mesh_state_read vpn_ip 2>/dev/null)" || vpn_ip=""

    if [[ -z "$vpn_ip" ]]; then
        mesh_log ERROR "Cannot restore $MESH_IFACE: no VPN IP in $MESH_STATE_FILE — this deck has not joined a mesh"
        mesh_emit critical health \
            "Mesh interface $MESH_IFACE is gone and cannot be restored: no mesh state at $MESH_STATE_FILE, so this deck has no VPN address to rebuild it with. Mesh connectivity is DOWN; local tools and the IDS are unaffected. Remedy: orionx-mesh join. Check: orionx-mesh status; ip link show $MESH_IFACE; cat $MESH_STATE_FILE" \
            "{\"reason\":\"iface-missing-no-state\",\"iface\":\"$MESH_IFACE\"}" || true
        return 1
    fi

    if mesh_interface_up "$vpn_ip"; then
        # Check, do not assume (rule 3): mesh_interface_up returns 0 for
        # "already exists" too, so re-read reality.
        if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
            mesh_log INFO "Interface $MESH_IFACE restored at $vpn_ip"
            return 0
        fi
    fi

    mesh_log ERROR "Failed to restore interface $MESH_IFACE"
    mesh_emit critical health \
        "Mesh interface $MESH_IFACE could not be recreated at $vpn_ip. Mesh connectivity is DOWN; peers cannot reach this deck. Remedy: orionx-mesh leave && orionx-mesh join. Check: ip link show $MESH_IFACE; wg show; journalctl -u orionx-mesh-health -n 50; modprobe wireguard" \
        "{\"reason\":\"iface-restore-failed\",\"iface\":\"$MESH_IFACE\",\"vpn_ip\":\"$vpn_ip\"}" || true
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

# Read a peer's latest-handshake epoch straight from the kernel.
# Echoes "0" when the peer is unknown or wg is unavailable.
health_peer_handshake_epoch() {
    local pubkey="$1"
    local dump epoch
    dump="$(wg show "$MESH_IFACE" dump 2>/dev/null | tail -n +2)" || dump=""
    [[ -z "$dump" ]] && { echo "0"; return 0; }
    epoch="$(awk -F'\t' -v k="$pubkey" '$1 == k { print $5; exit }' <<< "$dump")"
    echo "${epoch:-0}"
}

# CHECK stage: did a handshake actually happen? Bounded poll, never a loop.
# Returns 0 when the peer's handshake became fresh, 1 otherwise.
health_verify_handshake() {
    local pubkey="$1"
    local try=0 epoch now

    while (( try < MESH_HEAL_VERIFY_TRIES )); do
        (( try++ )) || true
        sleep "$MESH_HEAL_VERIFY_WAIT"
        epoch="$(health_peer_handshake_epoch "$pubkey")"
        now="$(date +%s)"
        if [[ "$(health_is_handshake_stale "$epoch" "$now")" == "fresh" ]]; then
            return 0
        fi
    done
    return 1
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
# Persistent state: failure counters, heal budget, escalation markers
#
# Three DIFFERENT facts, three different files, one authority each (rule 7):
#   orionx-mesh-health-<key>      consecutive failed checks for one peer
#   orionx-mesh-heal-budget       interface bounces spent this episode (mesh-wide)
#   orionx-mesh-escalated-<key>   this peer has been reported; stay silent
#
# The old code kept only the first and wiped it after every heal, which is
# why the repair could never terminate.
# =========================================================================

_health_counter_file() { echo "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-health-$1"; }
_health_budget_file()  { echo "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-heal-budget"; }
_health_escal_file()   { echo "$MESH_HEALTH_COUNTER_DIR/orionx-mesh-escalated-$1"; }

# Increment the failure counter for a peer (persisted in temp file).
health_increment_counter() {
    local short_key="$1"
    local counter_file current
    counter_file="$(_health_counter_file "$short_key")"
    current="$(health_read_counter "$short_key")"
    mkdir -p "$MESH_HEALTH_COUNTER_DIR"
    echo $(( current + 1 )) > "$counter_file"
}

# Read the failure counter for a peer. Returns 0 if no counter file exists.
health_read_counter() {
    local counter_file
    counter_file="$(_health_counter_file "$1")"
    if [[ -f "$counter_file" ]]; then
        cat "$counter_file"
    else
        echo "0"
    fi
}

# Clear the failure counter for a single peer.
health_clear_counter() {
    rm -f "$(_health_counter_file "$1")"
}

# Clear all per-peer FAILURE counters. Used after an interface bounce,
# which invalidates every peer's consecutive-failure tally.
#
# This deliberately does NOT touch the heal budget or the escalation
# markers. Wiping those here is the original unbounded-retry defect.
health_clear_all_counters() {
    rm -f "$MESH_HEALTH_COUNTER_DIR"/orionx-mesh-health-*
}

# --- mesh-wide interface-bounce budget ---------------------------------

health_read_budget() {
    local f
    f="$(_health_budget_file)"
    if [[ -f "$f" ]]; then cat "$f"; else echo "0"; fi
}

health_consume_budget() {
    local f current
    f="$(_health_budget_file)"
    current="$(health_read_budget)"
    mkdir -p "$MESH_HEALTH_COUNTER_DIR"
    echo $(( current + 1 )) > "$f"
}

health_clear_budget() {
    rm -f "$(_health_budget_file)"
}

# --- per-peer escalation marker ----------------------------------------

health_mark_escalated() {
    mkdir -p "$MESH_HEALTH_COUNTER_DIR"
    : > "$(_health_escal_file "$1")"
}

health_has_escalated() {
    [[ -f "$(_health_escal_file "$1")" ]]
}

health_clear_escalated() {
    rm -f "$(_health_escal_file "$1")"
}

# Everything a confirmed handshake invalidates. This is the Loop stage: a
# real handshake — not a command we ran — is what resets the budget.
health_clear_peer_state() {
    local short_key="$1"
    health_clear_counter "$short_key"
    health_clear_escalated "$short_key"
    health_clear_budget
}

# Check if a peer has reached the aggressive heal threshold.
health_should_aggressive_heal() {
    local count
    count="$(health_read_counter "$1")"
    (( count >= MESH_AGGRESSIVE_THRESHOLD ))
}

# =========================================================================
# PLAN — a pure function from observation to intent
#
# No side effects, no I/O, fully testable (RESILIENCE "Plan": desired state
# as data, separate from the code that applies it).
#
# Args:  staleness(fresh|stale) ping(ok|fail) fail_count healthy_others
#        budget_used escalated(0|1)
# Echoes exactly one of:
#   none           peer is healthy
#   hold           already escalated; stay silent until a handshake happens
#   soft           refresh the endpoint and wait
#   aggressive     bounce the interface (bounded)
#   escalate-peer  one peer down while the mesh works — report once, stop
#   escalate-mesh  bounce budget exhausted — report once, stop
# =========================================================================
health_plan_action() {
    local staleness="$1" ping_result="$2" fail_count="$3"
    local healthy_others="$4" budget_used="$5" escalated="$6"

    if [[ "$staleness" == "fresh" ]]; then
        echo "none"; return 0
    fi
    if [[ "$escalated" == "1" ]]; then
        echo "hold"; return 0
    fi
    if [[ "$ping_result" == "ok" ]]; then
        # Reachable over the tunnel despite a stale handshake: an endpoint
        # refresh is the whole repair. Never escalate from here.
        echo "soft"; return 0
    fi
    if (( fail_count < MESH_AGGRESSIVE_THRESHOLD )); then
        echo "soft"; return 0
    fi
    if (( healthy_others > 0 )); then
        # The interface demonstrably works — other peers are handshaking on
        # it. Bouncing it would break them to chase a peer that is almost
        # certainly powered off. Report the peer instead.
        echo "escalate-peer"; return 0
    fi
    if (( budget_used >= MESH_MAX_AGGRESSIVE_HEALS )); then
        echo "escalate-mesh"; return 0
    fi
    echo "aggressive"
}

# =========================================================================
# Aggressive heal — bounce the link, keep the peers, verify the effect
# =========================================================================

# Restart the WireGuard interface without destroying its configuration.
#
# `ip link set wg0 down/up` drops and rebinds the UDP socket and forces new
# handshakes while preserving the private key, the address and every peer.
# The previous `wg-quick down && wg-quick up` would have destroyed all of
# that — and in fact did nothing at all, because no wg0.conf exists.
#
# Always returns 0. Whether it WORKED is reported in
# HEALTH_LAST_HEAL_VERIFIED, because a function that returns 0 for "I ran
# the command" is how toggle-theme.sh lied (rule 3).
health_aggressive_heal() {
    local short_key="$1"
    local pubkey="${2:-}"

    HEALTH_LAST_HEAL_VERIFIED="unverified"

    mesh_log WARN "Aggressive heal: bouncing $MESH_IFACE link (peers and keys preserved) for unresponsive peer $short_key"
    ip link set "$MESH_IFACE" down || true
    ip link set "$MESH_IFACE" up || true

    # A bounce invalidates every peer's consecutive-failure tally — but NOT
    # the budget that bounds how many bounces we are allowed.
    health_clear_all_counters

    if [[ -z "$pubkey" ]]; then
        mesh_log WARN "Aggressive heal for $short_key not verified: no public key supplied"
        return 0
    fi

    if health_verify_handshake "$pubkey"; then
        HEALTH_LAST_HEAL_VERIFIED="yes"
        mesh_log INFO "Aggressive heal verified: peer $short_key completed a handshake"
        health_clear_peer_state "$short_key"
    else
        HEALTH_LAST_HEAL_VERIFIED="no"
        mesh_log WARN "Aggressive heal did NOT restore peer $short_key — no handshake within $(( MESH_HEAL_VERIFY_TRIES * MESH_HEAL_VERIFY_WAIT ))s"
    fi
    return 0
}

# =========================================================================
# Discovery wiring — degrade loudly about a build defect we cannot fix here
# =========================================================================

# History: orionx-mesh-discover.timer sets Unit=orionx-mesh-beacon.service, and
# until DEC-PHASE12-041 orionx-mesh-beacon.service was absent from UNIT_FILES in
# 0615-install-systemd-units.hook.chroot, so the timer fired at a unit that
# does not exist; and because the timer names the beacon explicitly,
# orionx-mesh-discover.service (the listener) is never triggered either.
# Both halves of peer discovery are dead.
#
# This check cannot repair that — the fix is in the build hook. What it can
# do is make sure the operator is TOLD, exactly once per boot, instead of
# wondering why no peer ever appears (rule 8).
#
# DEC-PHASE12-097: since join starts the listener unit, a dead listener is a
# RUNTIME condition with a runtime remedy, not a build defect — so each cause
# now carries its own remedy, and a pre-planned (--config) join, which by
# design runs no listener and sends no beacon, is not reported at all.
health_check_discovery() {
    local marker="$MESH_HEALTH_COUNTER_DIR/orionx-mesh-discovery-announced"
    local -a broken=()
    local -a remedy=()

    if [[ "$(mesh_state_read mode 2>/dev/null || true)" == "config" ]]; then
        return 0
    fi

    if [[ ! -f "$MESH_UNIT_DIR/orionx-mesh-beacon.service" ]]; then
        broken+=("orionx-mesh-beacon.service is not installed, so orionx-mesh-discover.timer activates a unit that does not exist and this deck never announces itself")
        remedy+=("this is a build defect: add orionx-mesh-beacon.service to UNIT_FILES in 0615-install-systemd-units.hook.chroot and rebuild")
    fi
    # Assert the EFFECT — a live listener process — not systemd's opinion of
    # the unit. `systemctl is-active` would also drag a D-Bus connection to
    # PID 1 into a unit we are confining with ProtectSystem=strict.
    local pid=""
    if [[ -f "$MESH_DISCOVER_PID_FILE" ]]; then
        pid="$(cat "$MESH_DISCOVER_PID_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        broken+=("no live discovery listener (nothing alive at $MESH_DISCOVER_PID_FILE), so beacons from other decks are ignored")
        remedy+=("sudo systemctl start orionx-mesh-discover.service (or leave and rejoin the mesh)")
    fi

    if (( ${#broken[@]} == 0 )); then
        rm -f "$marker"
        return 0
    fi

    # Bounded: say it once per boot, not once per minute.
    if [[ -f "$marker" ]]; then
        return 1
    fi
    mkdir -p "$MESH_HEALTH_COUNTER_DIR"
    : > "$marker"

    mesh_emit warning health \
        "Mesh peer discovery is NOT running: ${broken[*]}. Already-configured peers still work and health checking is unaffected, but no NEW peer will ever be found or informed. Remedy: ${remedy[*]}. Check: systemctl list-timers orionx-mesh-discover.timer; systemctl status orionx-mesh-discover.service; ls $MESH_UNIT_DIR/orionx-mesh-*" \
        '{"reason":"discovery-not-wired"}' || true
    return 1
}

# =========================================================================
# Per-peer health check — DO
# =========================================================================

# Check a single peer's health and apply the planned action.
#
# Args: pubkey endpoint allowed_ips latest_handshake now_epoch [healthy_others]
# Returns:
#   0  healthy (or reachable after a soft heal)
#   1  stale, still within the repair budget
#   2  interface bounce triggered
#   3  terminal: escalated once, or holding silent after escalation
health_check_peer() {
    local pubkey="$1"
    local endpoint="$2"
    local allowed_ips="$3"
    local latest_handshake="$4"
    local now_epoch="$5"
    local healthy_others="${6:-0}"

    local short_key vpn_ip staleness
    short_key="$(health_short_key "$pubkey")"
    vpn_ip="$(health_extract_vpn_ip "$allowed_ips")"
    staleness="$(health_is_handshake_stale "$latest_handshake" "$now_epoch")"

    # --- LOOP: a real handshake is the only thing that resets the budget ---
    if [[ "$staleness" == "fresh" ]]; then
        if health_has_escalated "$short_key"; then
            mesh_log INFO "Peer $short_key recovered — handshake is fresh again"
            mesh_emit notice health \
                "Mesh peer $short_key ($vpn_ip) is back: a WireGuard handshake completed, so healing has resumed for it." \
                "{\"reason\":\"peer-recovered\",\"peer\":\"$short_key\",\"vpn_ip\":\"$vpn_ip\"}" || true
        fi
        health_clear_peer_state "$short_key"
        return 0
    fi

    # --- Already reported. Silence beats a loop (rule 4). ---
    if health_has_escalated "$short_key"; then
        return 3
    fi

    # Stale handshake — attempt soft heal
    health_soft_heal "$pubkey" "$endpoint"

    # Ping check
    local ping_result="fail"
    if ping -c 3 -W 2 "$vpn_ip" >/dev/null 2>&1; then
        ping_result="ok"
    fi

    if [[ "$ping_result" == "ok" ]]; then
        # Ping succeeds despite stale handshake — peer is reachable
        return 0
    fi

    # Ping failed AND handshake is stale — increment failure counter
    health_increment_counter "$short_key"

    local fail_count budget_used escalated action
    fail_count="$(health_read_counter "$short_key")"
    budget_used="$(health_read_budget)"
    # Always 0 here: the escalated case returned 3 above, before the soft
    # heal. The planner still models it so "hold" is testable in isolation.
    escalated=0
    action="$(health_plan_action "$staleness" "$ping_result" "$fail_count" \
        "$healthy_others" "$budget_used" "$escalated")"

    case "$action" in
        soft)
            return 1
            ;;
        aggressive)
            # Spend the budget BEFORE the attempt. A heal that crashes
            # half-way must still count, or the bound is not a bound.
            health_consume_budget
            health_aggressive_heal "$short_key" "$pubkey"
            if [[ "$HEALTH_LAST_HEAL_VERIFIED" == "yes" ]]; then
                return 0
            fi
            return 2
            ;;
        escalate-peer)
            health_mark_escalated "$short_key"
            mesh_log WARN "Peer $short_key unreachable; $healthy_others other peer(s) healthy — not bouncing the interface"
            mesh_emit warning health \
                "Mesh peer $short_key ($vpn_ip) has not handshaken for over ${MESH_HANDSHAKE_STALE_SECS}s and does not answer ping, after $fail_count checks. It is almost certainly powered off or off-network. The mesh interface is NOT being restarted, because $healthy_others other peer(s) are handshaking on it — restarting it would break them to chase this one. Everything else on the mesh still works. No further repair will be attempted for this peer until it handshakes again. Check: wg show $MESH_IFACE latest-handshakes; ping -c3 $vpn_ip; orionx-mesh peers; journalctl -u orionx-mesh-health -n 50" \
                "{\"reason\":\"peer-down-mesh-healthy\",\"peer\":\"$short_key\",\"vpn_ip\":\"$vpn_ip\",\"endpoint\":\"$endpoint\",\"failed_checks\":$fail_count,\"healthy_peers\":$healthy_others}" || true
            return 3
            ;;
        escalate-mesh)
            health_mark_escalated "$short_key"
            mesh_log ERROR "Mesh heal budget exhausted ($budget_used/$MESH_MAX_AGGRESSIVE_HEALS) — giving up on $short_key"
            mesh_emit critical health \
                "Mesh healing has GIVEN UP. No peer is handshaking on $MESH_IFACE and $budget_used interface restart(s) — the configured maximum of $MESH_MAX_AGGRESSIVE_HEALS — did not produce a single handshake. Mesh connectivity is DOWN; the IDS, capture and local tooling are unaffected. Not retrying: further restarts would only hide this message. Check: wg show $MESH_IFACE; ip -s link show $MESH_IFACE; orionx-mesh status; ping -c3 $vpn_ip; journalctl -u orionx-mesh-health -n 100" \
                "{\"reason\":\"mesh-gave-up\",\"peer\":\"$short_key\",\"vpn_ip\":\"$vpn_ip\",\"heals_spent\":$budget_used,\"max_heals\":$MESH_MAX_AGGRESSIVE_HEALS}" || true
            return 3
            ;;
        hold)
            return 3
            ;;
        *)
            mesh_log ERROR "health_plan_action returned unknown action '$action' — treating as no-op"
            return 1
            ;;
    esac
}

# =========================================================================
# All-peers health check — classify first, then act
# =========================================================================

# Two passes on purpose. "How many peers are healthy?" is an input to the
# plan for every peer, and it must be computed from the SAME observation
# the actions are based on — not discovered half-way through healing.
health_check_all_peers() {
    local now_epoch
    now_epoch="$(date +%s)"

    # wg show dump format (tab-separated, after header line):
    # pubkey  preshared-key  endpoint  allowed-ips  latest-handshake  rx  tx  keepalive
    local dump_output
    dump_output="$(wg show "$MESH_IFACE" dump 2>/dev/null | tail -n +2)" || true

    if [[ -z "$dump_output" ]]; then
        mesh_log INFO "Health check: 0 peers, 0 healthy, 0 stale"
        return 0
    fi

    # --- Pass 1: classify, no side effects ---
    local -a lines=()
    local fresh_total=0
    local line pubkey _psk endpoint allowed_ips latest_handshake _rx _tx _keepalive
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lines+=("$line")
        IFS=$'\t' read -r pubkey _psk endpoint allowed_ips latest_handshake _rx _tx _keepalive <<< "$line"
        if [[ "$(health_is_handshake_stale "${latest_handshake:-0}" "$now_epoch")" == "fresh" ]]; then
            (( fresh_total++ )) || true
        fi
    done <<< "$dump_output"

    # A dump that was non-empty but held only blank lines leaves `lines`
    # empty; "${lines[@]}" under `set -u` is an unbound-variable error on
    # bash 3.2 (the dev/CI hosts). Answer it explicitly rather than crashing.
    if (( ${#lines[@]} == 0 )); then
        mesh_log INFO "Health check: 0 peers, 0 healthy, 0 stale"
        return 0
    fi

    # --- Pass 2: act ---
    local total=0 healthy=0 stale=0 escalated=0
    local this_fresh healthy_others rc
    for line in "${lines[@]}"; do
        (( total++ )) || true
        IFS=$'\t' read -r pubkey _psk endpoint allowed_ips latest_handshake _rx _tx _keepalive <<< "$line"

        this_fresh=0
        if [[ "$(health_is_handshake_stale "${latest_handshake:-0}" "$now_epoch")" == "fresh" ]]; then
            this_fresh=1
        fi
        healthy_others=$(( fresh_total - this_fresh ))

        rc=0
        health_check_peer "$pubkey" "$endpoint" "$allowed_ips" \
            "${latest_handshake:-0}" "$now_epoch" "$healthy_others" || rc=$?

        case "$rc" in
            0) (( healthy++ )) || true ;;
            2)
                # Interface bounced — every other peer's state is now stale
                # information. Stop and let the next invocation re-observe.
                mesh_log INFO "Health check: $total peers checked, interface bounced (verified=$HEALTH_LAST_HEAL_VERIFIED) — exiting"
                return 0
                ;;
            3) (( escalated++ )) || true ;;
            *) (( stale++ )) || true ;;
        esac
    done

    mesh_log INFO "Health check: $total peers, $healthy healthy, $stale stale, $escalated escalated"
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

    # Step 2: Is peer discovery actually wired up? (announces once per boot)
    health_check_discovery || true

    # Step 3: Classify all peers and apply the bounded repair plan
    health_check_all_peers
}

main "$@"
