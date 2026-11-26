#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition — In-Guest Performance Measurement (W7-5)
#
# Runs inside the booted guest and reports, without judging (the host-side
# test owns every threshold, DEC-PHASE13-067):
#   virt               — systemd-detect-virt (qemu = TCG emulation, kvm, none)
#   multi_user_seconds — when the boot transaction reached multi-user.target
#   boot_time_seconds  — when the operator's desktop session started (the
#                        autologin user's user@UID.service), the boot an
#                        operator experiences
#   idle_ram_bytes     — MemTotal - MemAvailable once the desktop has settled
#
# (iso_size_bytes is measured host-side; see tests/integration/test-w7-5-performance.sh)
#
# Sentinels go to stdout, which the unit delivers to /dev/ttyS0:
#   ORIONX_PERF_BEGIN
#   ORIONX_PERF: <metric>=<value>
#   ORIONX_PERF_END: overall=REPORTED
#
# Independence invariant: this script MUST NOT probe wg0, apparmor, synapse,
# matrix, or mesh-discover state. Boot time, ISO size, and idle RAM are
# measurable regardless of first-boot-wizard or wg0/mesh completion.
# Violating this invariant re-introduces the W7-4-B cascade trap (issue #39).
#
# Bounded: the only wait is for the desktop session (ORIONX_PROBE_SESSION_WAIT,
# 300 s) plus a settle delay; every systemctl query has a 10 s timeout.
#
# @decision DEC-PHASE7-W7-5-001
# @title In-guest performance measurement via serial-console sentinels (W7-5)
# @status accepted
# @rationale Boot time, idle RAM, and ISO size are the three acceptance
#   criteria for Phase 7's performance goal. boot_time_seconds uses
#   systemd-analyze (canonical source — it measures kernel+userspace time
#   from the kernel's own timestamps, not host wall-clock, so QEMU firmware
#   overhead is excluded). idle_ram_bytes uses /proc/meminfo MemAvailable
#   (kernel-reported available RAM, the correct "idle RAM consumption"
#   signal — MemTotal minus MemAvailable = RAM consumed by the OS at rest).
#   iso_size_bytes is measured host-side (the ISO file is on the host
#   filesystem, not visible inside the guest). Serial console reuse follows
#   DEC-PHASE7-035 — same channel, same host harness, no new side-channels.
#   Per-assertion timeout wraps prevent any single stall from hanging the
#   overall measurement block past the service's WatchdogSec or the host's
#   QEMU timeout.
#   Amended 2026-11-26 by DEC-PHASE13-067: systemd-analyze never answered
#   from inside the boot transaction, so boot time is now the desktop
#   session's start (user@UID.service), with multi-user.target reported
#   alongside; the thresholds moved to the host-side test alone.

# emit, probe_user, wait_desktop, active_since_boot (DEC-PHASE13-067).
# shellcheck source=/dev/null
. "${ORIONX_PROBE_LIB:-/usr/lib/orionx/probe-lib.sh}"

SESSION_WAIT="${ORIONX_PROBE_SESSION_WAIT:-300}"
SETTLE="${ORIONX_PROBE_SETTLE:-20}"     # let the desktop's autostart finish before reading RAM

emit "ORIONX_PERF_BEGIN"
emit "ORIONX_PERF: virt=$(systemd-detect-virt 2>/dev/null || echo none)"
emit "ORIONX_PERF: multi_user_seconds=$(active_since_boot multi-user.target)"

# systemd-analyze cannot answer from here: this unit is part of the boot
# transaction, so it always reports "Bootup is not yet finished".
USER_NAME="$(probe_user)"
if wait_desktop "${USER_NAME}" "${SESSION_WAIT}"; then
    uid="$(id -u "${USER_NAME}" 2>/dev/null || echo 0)"
    emit "ORIONX_PERF: boot_time_seconds=$(active_since_boot "user@${uid}.service")"
    sleep "${SETTLE}"
else
    emit "ORIONX_PERF: boot_time_seconds=none (no desktop session for ${USER_NAME} after ${SESSION_WAIT}s)"
fi

MEMINFO="${ORIONX_PROBE_MEMINFO:-/proc/meminfo}"
mem_total_kb="$(awk '/^MemTotal:/ {print $2}' "${MEMINFO}" 2>/dev/null || true)"
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' "${MEMINFO}" 2>/dev/null || true)"
if [[ "${mem_total_kb}" =~ ^[0-9]+$ && "${mem_avail_kb}" =~ ^[0-9]+$ ]]; then
    emit "ORIONX_PERF: idle_ram_bytes=$(( (mem_total_kb - mem_avail_kb) * 1024 ))"
else
    emit "ORIONX_PERF: idle_ram_bytes=none (/proc/meminfo unreadable)"
fi

emit "ORIONX_PERF_END: overall=REPORTED"
exit 0
