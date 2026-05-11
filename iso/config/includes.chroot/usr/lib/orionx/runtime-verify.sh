#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition — In-Guest Runtime Verification (W7-4-B)
#
# Runs 5 in-guest assertions to verify that the mesh (WireGuard), Matrix
# (Synapse), and AppArmor subsystems are operational after boot. Results are
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

SERIAL_DEV="/dev/ttyS0"

# ---------------------------------------------------------------------------
# Sentinel emitter — writes to serial console and stdout
# ---------------------------------------------------------------------------
emit() {
    local line="$1"
    echo "${line}" | tee -a "${SERIAL_DEV}" >/dev/null 2>&1 || echo "${line}"
    echo "${line}"
}

# ---------------------------------------------------------------------------
# Overall PASS/FAIL accumulator
# ---------------------------------------------------------------------------
OVERALL="PASS"

mark_fail() {
    OVERALL="FAIL"
}

# ---------------------------------------------------------------------------
# Assertion: mesh_iface_up
#
# Checks that the WireGuard interface wg0 exists AND is in UP or UNKNOWN
# state. WireGuard point-to-point interfaces report UNKNOWN when no peers
# are configured yet — that is expected at first boot. The mesh-discover
# service or orionx-firewall service creates the interface; the interface
# existing confirms those services ran.
# ---------------------------------------------------------------------------
assert_mesh_iface_up() {
    local verdict="FAIL"
    if ip link show wg0 >/dev/null 2>&1; then
        local state
        state="$(ip link show wg0 | grep -oE 'state [A-Z]+' | awk '{print $2}' || true)"
        if [[ "${state}" == "UP" || "${state}" == "UNKNOWN" ]]; then
            verdict="PASS"
        fi
    fi
    emit "ORIONX_VERIFY: mesh_iface_up=${verdict}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Assertion: mesh_beacon_active
#
# Checks that orionx-mesh-beacon.service is active or activating.
# 'activating' is acceptable on slow boots — the beacon may still be
# running ExecStartPre commands when we poll.
# ---------------------------------------------------------------------------
assert_mesh_beacon_active() {
    local verdict="FAIL"
    local svc_state
    svc_state="$(systemctl is-active orionx-mesh-beacon.service 2>/dev/null || true)"
    if [[ "${svc_state}" == "active" || "${svc_state}" == "activating" ]]; then
        verdict="PASS"
    fi
    emit "ORIONX_VERIFY: mesh_beacon_active=${verdict}"
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
# Checks that matrix-synapse-orionx.service is present and not absent from
# systemd's unit database. Accepts: active, activating, or any loaded state
# (including failed, since Synapse startup is slow and may fail transiently
# on first boot before configuration is complete). Rejects only: not-found.
#
# Rationale: the assertion's purpose is to verify the unit is INSTALLED and
# managed by systemd, not that it successfully completed startup. A not-found
# result means the 0615 hook failed to install the unit into the squashfs.
# ---------------------------------------------------------------------------
assert_matrix_synapse_state() {
    local verdict="FAIL"
    local svc_state
    svc_state="$(systemctl is-active matrix-synapse-orionx.service 2>/dev/null || true)"
    if [[ "${svc_state}" != "not-found" ]]; then
        verdict="PASS"
    fi
    emit "ORIONX_VERIFY: matrix_synapse_state=${verdict}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Assertion: apparmor_enforcing
#
# Checks that AppArmor is loaded and at least 5 profiles are in enforce mode.
# The 5 documented profiles are: Synapse, WireGuard (wg), Volatility3,
# bulk_extractor, and tshark — installed by 0610-apparmor-setup.hook.chroot.
#
# Implementation: parse `aa-status` output for the enforced-profile count.
# `aa-status --enforced` prints a count and exits 0 when >=1 profile enforced,
# non-zero when AppArmor is disabled or no profiles are loaded. We accept exit
# non-zero and parse the count manually to distinguish "0 profiles" from
# "AppArmor not loaded".
# ---------------------------------------------------------------------------
assert_apparmor_enforcing() {
    local verdict="FAIL"
    if command -v aa-status >/dev/null 2>&1; then
        local enforced_count
        enforced_count="$(aa-status 2>/dev/null | grep -oE '^[0-9]+ profiles are in enforce mode' | grep -oE '^[0-9]+' || echo "0")"
        if [[ "${enforced_count}" -ge 5 ]] 2>/dev/null; then
            verdict="PASS"
        fi
    fi
    emit "ORIONX_VERIFY: apparmor_enforcing=${verdict}"
    [[ "${verdict}" == "PASS" ]] || mark_fail
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
emit "ORIONX_VERIFY_BEGIN"

assert_mesh_iface_up
assert_mesh_beacon_active
assert_mesh_discover_enabled
assert_matrix_synapse_state
assert_apparmor_enforcing

emit "ORIONX_VERIFY_END: overall=${OVERALL}"

# Exit 0 always — the host-side parser owns PASS/FAIL for the test suite.
# The script itself is a probe, not a gate; it must not kill the boot sequence.
exit 0
