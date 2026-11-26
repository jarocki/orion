#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition — In-Guest Runtime Verification (W7-4-B)
#
# Runs in-guest assertions over the mesh (WireGuard, opt-in), Matrix
# (Synapse), AppArmor, the Zeek install path and the graphical session
# (graphical.target, the autologin desktop, no screen locker). Results are
# emitted as ORIONX_VERIFY_* sentinel lines to /dev/ttyS0 so that the
# host-side QEMU harness (scripts/qemu-boot-test.sh --post-boot-script)
# can parse them without SSH, QEMU monitor sockets, or qemu-guest-agent.
#
# Channel: /dev/ttyS0 (serial console — always available under QEMU -serial)
# Authority: This script is the single authority for in-guest runtime
#   verification state. The host-side test wrapper
#   (tests/integration/test-w7-4-b-runtime-verify.sh) is the parsing
#   authority and must not duplicate assertion logic.
#
# Sentinel format (one per line to /dev/ttyS0):
#   ORIONX_VERIFY_BEGIN
#   ORIONX_VERIFY: <name>=PASS|FAIL
#   ORIONX_VERIFY_END: overall=PASS|FAIL
#
# Idempotent: safe to re-run; each invocation emits a fresh sentinel block.
#
# @decision DEC-PHASE7-035
# @title In-guest verification via serial-console sentinels, not SSH/sockets
# @status accepted
# @rationale SSH requires network-up, credentials, and an open port — all
#   fragile at the point of first-boot verification. QEMU monitor sockets
#   add host-side complexity and a listening surface. qemu-guest-agent
#   requires the agent binary installed, started, and the virtio channel
#   configured. Serial console (/dev/ttyS0) is always present under QEMU
#   -serial (or -serial file:<log>), requires no guest-side network, no
#   credentials, and no extra packages. The host harness already captures
#   the serial log for boot-success detection (DEC-PHASE7-020); reusing
#   the same channel for verification sentinels avoids a second side-channel.
#   This decision supersedes any SSH/socket-based verification approach.

# emit, probe_user, wait_desktop: the shared probe helpers (DEC-PHASE13-067).
# shellcheck source=/dev/null
. "${ORIONX_PROBE_LIB:-/usr/lib/orionx/probe-lib.sh}"

# ---------------------------------------------------------------------------
# Overall PASS/FAIL accumulator
# ---------------------------------------------------------------------------
OVERALL="PASS"

mark_fail() {
    OVERALL="FAIL"
}

# ---------------------------------------------------------------------------
# Mesh assertions: the mesh is opt-in. A stock deck has no wg0 until the
# operator joins one, and the mesh units are written for that: each carries
# ConditionPathExists=/sys/class/net/wg0 and is skipped, not failed. The
# earlier checks demanded wg0 and an active beacon on every image, so the
# first boot that delivered them (v3.1.6, 2026-11-26) reported FAIL for a
# correctly built deck. Without wg0 the checks now prove the units stood down
# cleanly; with wg0 they prove the mesh is up.
# ---------------------------------------------------------------------------
mesh_joined() { [[ -e "${ORIONX_PROBE_SYSFS_NET:-/sys/class/net}/wg0" ]]; }

assert_mesh_iface_up() {
    local verdict="FAIL" note=""
    if ! mesh_joined; then
        verdict="PASS"; note=" (no wg0: mesh not joined, opt-in)"
    elif ip link show wg0 >/dev/null 2>&1; then
        local state
        state="$(ip link show wg0 | grep -oE 'state [A-Z]+' | awk '{print $2}' || true)"
        # A point-to-point WireGuard link with no peers reports UNKNOWN.
        if [[ "${state}" == "UP" || "${state}" == "UNKNOWN" ]]; then
            verdict="PASS"
        fi
    fi
    emit "ORIONX_VERIFY: mesh_iface_up=${verdict}${note}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

assert_mesh_beacon_active() {
    local verdict="FAIL" svc_state
    svc_state="$(systemctl is-active orionx-mesh-beacon.service 2>/dev/null || true)"
    if ! mesh_joined; then
        # Skipped by its condition reads inactive; only a failure is wrong.
        [[ "${svc_state}" != "failed" ]] && verdict="PASS"
    elif [[ "${svc_state}" == "active" || "${svc_state}" == "activating" ]]; then
        verdict="PASS"
    fi
    emit "ORIONX_VERIFY: mesh_beacon_active=${verdict} (${svc_state:-unknown})"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Assertion: mesh_discover_enabled
#
# Checks that orionx-mesh-discover.timer is enabled at boot. The timer is
# the autostart authority for periodic mesh discovery per W7-4-A hook
# (DEC-PHASE7-SYSTEMD-INSTALL-001). 'enabled' means the
# /etc/systemd/system/multi-user.target.wants/ symlink exists.
# ---------------------------------------------------------------------------
assert_mesh_discover_enabled() {
    local verdict="FAIL"
    local enabled_state
    enabled_state="$(systemctl is-enabled orionx-mesh-discover.timer 2>/dev/null || true)"
    if [[ "${enabled_state}" == "enabled" ]]; then
        verdict="PASS"
    fi
    emit "ORIONX_VERIFY: mesh_discover_enabled=${verdict}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Assertion: matrix_synapse_state
#
# Checks that matrix-synapse.service is not in a broken state.
# DEC-PHASE12-102: the package unit is the ONE Synapse unit (the Cockpit and
# setup-matrix.sh name the same one); matrix-synapse-orionx.service is gone.
# Accepts: not-found, inactive, active, activating — every state except one.
# Rejects only: failed.
#
# Rationale: Matrix is OPT-IN. W11-14f (offline boot) removed the unit from the
# set the 0615 hook installs; an operator adds it with
# `setup-matrix.sh --mode server`, which pulls Synapse over the network. On a
# stock image the unit is therefore "not-found" BY DESIGN, and that is a PASS.
# The only thing worth failing on is a unit that was installed and then failed
# to start. (Beta audit A.6: the previous not-found=FAIL rule made W7-4-B red
# on every correctly-built image.)
# ---------------------------------------------------------------------------
assert_matrix_synapse_state() {
    # "failed" is the only rejected state — see the block comment above.
    local verdict="PASS"
    local svc_state
    svc_state="$(systemctl is-active matrix-synapse.service 2>/dev/null || true)"
    if [[ "${svc_state}" == "failed" ]]; then
        verdict="FAIL"
    fi
    emit "ORIONX_VERIFY: matrix_synapse_state=${verdict} (${svc_state:-unknown})"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Assertion: apparmor_enforcing
#
# DEC-PHASE12-103: checks BY NAME that the profiles Orion-X advertises are in
# enforce mode (ollama, nebula-mcp, wireguard, tshark), in the kernel's own
# list. A count of ">= 5 enforced" passed with any five stock profiles while
# ollama ran unconfined (system P2-7). Synapse has no profile (DEC-PHASE12-102).
#
# Implementation: parse `aa-status` output for the enforced-profile count.
# `aa-status --enforced` prints a count and exits 0 when >=1 profile enforced,
# non-zero when AppArmor is disabled or no profiles are loaded. We accept exit
# non-zero and parse the count manually to distinguish "0 profiles" from
# "AppArmor not loaded".
# ---------------------------------------------------------------------------
assert_apparmor_enforcing() {
    local verdict="PASS" name missing=""
    local list="${ORIONX_AA_KERNEL_PROFILES:-/sys/kernel/security/apparmor/profiles}"
    for name in ollama nebula-mcp wireguard tshark; do
        grep -qxF "${name} (enforce)" "$list" 2>/dev/null || missing+=" ${name}"
    done
    [[ -z "$missing" ]] || verdict="FAIL"
    emit "ORIONX_VERIFY: apparmor_enforcing=${verdict}${missing:+ (not enforced:${missing})}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Session assertions (#78): the gate used to stop at the serial login prompt,
# which appears before LightDM does anything. Defects in the graphical
# session (the rc5 screen locker, #76; an autologin that never opens) passed
# it and were found on hardware. These read the session itself.
# ---------------------------------------------------------------------------
SESSION_WAIT="${ORIONX_PROBE_SESSION_WAIT:-300}"
LOCKERS="light-locker xfce4-screensaver xscreensaver"

assert_graphical_target() {
    local verdict="FAIL" state
    state="$(systemctl is-active graphical.target 2>/dev/null || true)"
    [[ "${state}" == "active" ]] && verdict="PASS"
    emit "ORIONX_VERIFY: graphical_target=${verdict} (${state:-unknown})"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

assert_desktop_session() {
    local verdict="FAIL" user note
    user="$(probe_user)"
    note="no xfce4-session for ${user} after ${SESSION_WAIT}s"
    if wait_desktop "${user}" "${SESSION_WAIT}"; then
        verdict="PASS"; note="xfce4-session running for ${user}"
    fi
    emit "ORIONX_VERIFY: desktop_session=${verdict} (${note})"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

assert_no_screen_locker() {
    # Read after the session is up: a locker starts from the session's
    # autostart. A package that is merely installed fails too, because a
    # Recommends: can bring it back and it then starts on the next login.
    local verdict="PASS" found="" pkg
    for pkg in ${LOCKERS}; do
        if pgrep -x "${pkg}" >/dev/null 2>&1; then found+=" ${pkg}(running)"; fi
        if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q 'install ok installed'; then
            found+=" ${pkg}(installed)"
        fi
    done
    [[ -z "${found}" ]] || verdict="FAIL"
    emit "ORIONX_VERIFY: no_screen_locker=${verdict}${found:+ (found:${found})}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
emit "ORIONX_VERIFY_BEGIN"

# ---------------------------------------------------------------------------
# Assertion: zeek_unit_staged (DEC-PHASE13-033, #150)
#
# The QEMU deck boots at Tier 0, where no Zeek instance runs, so this proves
# the install path rather than the sensor: the template is loadable by
# systemd (0615 installed it) and the policy and prune script it names exist.
# A Tier-1 boot with traffic is the Pavilion's job (v3.2.0 boot test).
# ---------------------------------------------------------------------------
assert_zeek_unit_staged() {
    local verdict="FAIL"
    if systemctl cat 'orionx-zeek@.service' >/dev/null 2>&1 \
       && [[ -f /usr/share/orionx/zeek/orionx.zeek ]] \
       && [[ -x /opt/orionx/scripts/awareness/orionx-zeek-prune ]]; then
        verdict="PASS"
    fi
    emit "ORIONX_VERIFY: zeek_unit_staged=${verdict}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

assert_mesh_iface_up
assert_mesh_beacon_active
assert_mesh_discover_enabled
assert_matrix_synapse_state
assert_apparmor_enforcing
assert_zeek_unit_staged
assert_graphical_target
assert_desktop_session
assert_no_screen_locker

emit "ORIONX_VERIFY_END: overall=${OVERALL}"

# Exit 0 always — the host-side parser owns PASS/FAIL for the test suite.
# The script itself is a probe, not a gate; it must not kill the boot sequence.
exit 0
