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
#   desktop_ready      — whether the desktop's own processes were all running
#                        when RAM was read (DEC-PHASE13-069)
#   ram_settled        — whether used RAM had stopped growing when it was read
#   idle_ram_bytes     — MemTotal - MemAvailable once both of the above hold
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
# Bounded: the waits are for the desktop session (ORIONX_PROBE_SESSION_WAIT,
# 300 s), for its processes (ORIONX_PROBE_READY_WAIT, 300 s) and for RAM to
# stop growing (ORIONX_PROBE_STABLE_WAIT, 180 s); every systemctl query has a
# 10 s timeout.
#
# @decision DEC-PHASE13-069
# @title Idle RAM is read once the desktop has finished starting and RAM has stopped growing
# @status accepted
# @rationale The fixed 20 s settle after xfce4-session appeared read RAM at a
#   moment set by the runner's speed. On 2026-11-27 the same code measured
#   731 MB (#216: sampled ~64 s after the session started; the panel's plugin
#   processes, wrapper-2.0, not yet running; nm-applet 32 MB, xfdesktop 34 MB)
#   and 1,084 / 1,145 MB (#215 / #217: ~105 / ~218 s after; two wrapper-2.0
#   at ~100-110 MB each, nm-applet 117-153 MB, xfdesktop 123-131 MB). Those
#   three account for the ~350 MB AnonPages difference (424 vs 768-800 MB).
#   The low readings were of a half-started desktop, so the earlier passes
#   were false. The probe now waits for the processes an idle desktop runs
#   (DESKTOP_PROCS) and then for two readings STABLE_STEP apart to agree
#   within STABLE_KB, and reports both conditions; the host test refuses to
#   judge a reading taken without them. With an honest reading the budget
#   was raised to 1.25 GiB (owner decision, 2026-11-27; host test holds it;
#   bringing it back under 1 GiB is #218).
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
# What an idle Orion-X desktop runs once its autostart is done: the panel,
# its out-of-process plugins, the desktop (wallpaper, icons) and the network
# applet. A reading before all of them run is of a half-started desktop.
DESKTOP_PROCS="${ORIONX_PROBE_DESKTOP_PROCS:-xfce4-panel wrapper-2.0 xfdesktop nm-applet}"
READY_WAIT="${ORIONX_PROBE_READY_WAIT:-300}"
STABLE_WAIT="${ORIONX_PROBE_STABLE_WAIT:-180}"
STABLE_STEP="${ORIONX_PROBE_STABLE_STEP:-15}"
STABLE_KB="${ORIONX_PROBE_STABLE_KB:-16384}"
MEMINFO="${ORIONX_PROBE_MEMINFO:-/proc/meminfo}"

# Used RAM in kB (MemTotal - MemAvailable), or nothing when unreadable.
used_kb() {
    awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t != "" && a != "") print t - a}' "${MEMINFO}" 2>/dev/null || true
}

# The DESKTOP_PROCS not yet running for user $1 (empty when all are).
missing_procs() {
    local p out=()
    for p in ${DESKTOP_PROCS}; do pgrep -u "$1" -x "$p" >/dev/null 2>&1 || out+=("$p"); done
    printf '%s' "${out[*]-}"
}

emit "ORIONX_PERF_BEGIN"
emit "ORIONX_PERF: virt=$(systemd-detect-virt 2>/dev/null || echo none)"
emit "ORIONX_PERF: multi_user_seconds=$(active_since_boot multi-user.target)"

# systemd-analyze cannot answer from here: this unit is part of the boot
# transaction, so it always reports "Bootup is not yet finished".
USER_NAME="$(probe_user)"
if wait_desktop "${USER_NAME}" "${SESSION_WAIT}"; then
    uid="$(id -u "${USER_NAME}" 2>/dev/null || echo 0)"
    emit "ORIONX_PERF: boot_time_seconds=$(active_since_boot "user@${uid}.service")"

    start=${SECONDS}
    missing="$(missing_procs "${USER_NAME}")"
    while [[ -n "${missing}" ]] && (( SECONDS - start < READY_WAIT )); do
        sleep "${ORIONX_PROBE_POLL:-5}"
        missing="$(missing_procs "${USER_NAME}")"
    done
    if [[ -z "${missing}" ]]; then
        emit "ORIONX_PERF: desktop_ready=yes (${DESKTOP_PROCS} running after $(( SECONDS - start ))s)"
    else
        emit "ORIONX_PERF: desktop_ready=no (not running after ${READY_WAIT}s: ${missing})"
    fi

    # Two readings STABLE_STEP apart within STABLE_KB: RAM has stopped growing.
    start=${SECONDS}; settled=""
    prev="$(used_kb)"
    while [[ "${prev}" =~ ^[0-9]+$ ]] && (( SECONDS - start < STABLE_WAIT )); do
        sleep "${STABLE_STEP}"
        cur="$(used_kb)"
        [[ "${cur}" =~ ^[0-9]+$ ]] || break
        delta=$(( cur > prev ? cur - prev : prev - cur ))
        if (( delta <= STABLE_KB )); then settled=yes; break; fi
        prev="${cur}"
    done
    if [[ -n "${settled}" ]]; then
        emit "ORIONX_PERF: ram_settled=yes (changed ${delta} kB in ${STABLE_STEP}s, after $(( SECONDS - start ))s)"
    else
        emit "ORIONX_PERF: ram_settled=no (still changing more than ${STABLE_KB} kB per ${STABLE_STEP}s after ${STABLE_WAIT}s)"
    fi
else
    emit "ORIONX_PERF: boot_time_seconds=none (no desktop session for ${USER_NAME} after ${SESSION_WAIT}s)"
    emit "ORIONX_PERF: desktop_ready=no (no desktop session)"
fi

mem_total_kb="$(awk '/^MemTotal:/ {print $2}' "${MEMINFO}" 2>/dev/null || true)"
mem_avail_kb="$(awk '/^MemAvailable:/ {print $2}' "${MEMINFO}" 2>/dev/null || true)"
if [[ "${mem_total_kb}" =~ ^[0-9]+$ && "${mem_avail_kb}" =~ ^[0-9]+$ ]]; then
    emit "ORIONX_PERF: idle_ram_bytes=$(( (mem_total_kb - mem_avail_kb) * 1024 ))"
    # Where it went (informational; the host judges only idle_ram_bytes). On
    # a live system "used" includes the RAM-backed overlay (Shmem), so the
    # total alone cannot say whether a service or the image's writes grew.
    emit "ORIONX_PERF: mem_detail_kb=$(awk '/^(MemTotal|MemAvailable|MemFree|Cached|Shmem|AnonPages|Slab|SUnreclaim|KernelStack|PageTables|SwapTotal|SwapFree):/ {printf "%s%s=%s", sep, $1, $2; sep=" "}' "${MEMINFO}" | tr -d ':')"
    emit "ORIONX_PERF: top_rss_kb=$(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -12 | awk '{printf "%s%s:%s", sep, $2, $1; sep=" "}')"
    emit "ORIONX_PERF: tmpfs_used_kb=$(df -k -t tmpfs -t overlay --output=target,used 2>/dev/null | awk 'NR>1 && $2>1024 {printf "%s%s:%s", sep, $1, $2; sep=" "}')"
else
    emit "ORIONX_PERF: idle_ram_bytes=none (/proc/meminfo unreadable)"
fi

emit "ORIONX_PERF_END: overall=REPORTED"
exit 0
