#!/bin/bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition — In-Guest Performance Measurement (W7-5)
#
# Runs inside the booted guest to measure three performance metrics:
#   1. boot_time_seconds  — systemd-analyze total startup time
#   2. idle_ram_bytes     — RAM consumed at rest (MemTotal - MemAvailable, in bytes)
#
# (iso_size_bytes is measured host-side; see tests/integration/test-w7-5-performance.sh)
#
# Results are emitted as ORIONX_PERF_* sentinel lines to /dev/ttyS0 so that
# the host-side integration test (via scripts/qemu-boot-test.sh --post-boot-script)
# can parse them without SSH, QEMU monitor sockets, or qemu-guest-agent.
#
# Channel: /dev/ttyS0 (serial console — always available under QEMU -serial)
#
# Sentinel format:
#   ORIONX_PERF_BEGIN
#   ORIONX_PERF: <metric>=<integer>
#   ORIONX_PERF_END: overall=PASS|FAIL
#
# Independence invariant: this script MUST NOT probe wg0, apparmor, synapse,
# matrix, or mesh-discover state. Boot time, ISO size, and idle RAM are
# measurable regardless of first-boot-wizard or wg0/mesh completion.
# Violating this invariant re-introduces the W7-4-B cascade trap (issue #39).
#
# Per-assertion timeout: each measurement is wrapped in `timeout 10` so the
# entire script completes in ≤30s even when systemd-analyze or /proc/meminfo
# is unexpectedly slow.
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

SERIAL_DEV="/dev/ttyS0"

# Thresholds (bytes / seconds)
BOOT_TIME_THRESHOLD=90
IDLE_RAM_THRESHOLD=1073741824   # 1 GiB in bytes

# ---------------------------------------------------------------------------
# Sentinel emitter — writes to serial console and stdout
# ---------------------------------------------------------------------------
emit() {
    local line="$1"
    # Write to serial; tolerate errors (ttyS0 may not be writable in all envs)
    echo "${line}" | tee -a "${SERIAL_DEV}" >/dev/null 2>&1 || true
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
# Measurement: boot_time_seconds
#
# Primary method: `systemd-analyze time` prints a line like:
#   Startup finished in 5.123s (kernel) + 12.456s (userspace) = 17.579s
# We extract the total after '='.
#
# Fallback: `systemctl show -p ActiveEnterTimestampMonotonic multi-user.target`
# returns microseconds since boot; divide by 1,000,000 for seconds.
# This is less precise (truncated to integer) but always available.
# ---------------------------------------------------------------------------
measure_boot_time() {
    local seconds=""

    # Primary: systemd-analyze time
    local analyze_output
    analyze_output="$(timeout 10 systemd-analyze time 2>/dev/null || true)"
    if [[ -n "${analyze_output}" ]]; then
        # Match "= 17.579s" or "= 1min 5.432s" — extract the total after '='
        local total_part
        total_part="$(echo "${analyze_output}" | grep -oE '= [0-9]+min [0-9]+\.[0-9]+s|= [0-9]+\.[0-9]+s' | tail -1 || true)"
        if [[ -n "${total_part}" ]]; then
            if echo "${total_part}" | grep -qE '[0-9]+min'; then
                # Format: "= Xmin Y.Zs"
                local mins secs
                mins="$(echo "${total_part}" | grep -oE '[0-9]+min' | grep -oE '[0-9]+')"
                secs="$(echo "${total_part}" | grep -oE '[0-9]+\.[0-9]+s' | grep -oE '[0-9]+\.[0-9]+')"
                # Use awk for float arithmetic — bash cannot handle floats
                seconds="$(awk "BEGIN { printf \"%.0f\", ${mins} * 60 + ${secs} }")"
            else
                # Format: "= X.Ys"
                local raw_secs
                raw_secs="$(echo "${total_part}" | grep -oE '[0-9]+\.[0-9]+')"
                seconds="$(awk "BEGIN { printf \"%.0f\", ${raw_secs} }")"
            fi
        fi
    fi

    # Fallback: ActiveEnterTimestampMonotonic (microseconds)
    if [[ -z "${seconds}" ]]; then
        local mono_us
        mono_us="$(timeout 10 systemctl show -p ActiveEnterTimestampMonotonic multi-user.target 2>/dev/null \
            | grep -oE '[0-9]+' | head -1 || true)"
        if [[ -n "${mono_us}" && "${mono_us}" -gt 0 ]] 2>/dev/null; then
            seconds="$(( mono_us / 1000000 ))"
        fi
    fi

    # If both methods fail, emit a sentinel value that triggers FAIL
    if [[ -z "${seconds}" ]]; then
        seconds="9999"
    fi

    emit "ORIONX_PERF: boot_time_seconds=${seconds}"

    if [[ "${seconds}" -lt "${BOOT_TIME_THRESHOLD}" ]] 2>/dev/null; then
        : # PASS — accumulator stays PASS
    else
        mark_fail
    fi
}

# ---------------------------------------------------------------------------
# Measurement: idle_ram_bytes
#
# /proc/meminfo reports MemTotal and MemAvailable in kibibytes.
# "Idle RAM consumption" = MemTotal - MemAvailable (RAM used by the OS at rest).
# Multiply by 1024 to convert kB → bytes.
#
# MemAvailable is preferred over MemFree+Buffers+Cached because it is the
# kernel's own estimate of how much memory can actually be reclaimed for new
# allocations without swapping — the canonical "idle available" signal since
# Linux 3.14.
# ---------------------------------------------------------------------------
measure_idle_ram() {
    local mem_total_kb mem_avail_kb used_bytes
    mem_total_kb="$(timeout 10 grep -E '^MemTotal:' /proc/meminfo 2>/dev/null \
        | grep -oE '[0-9]+' | head -1 || echo "0")"
    mem_avail_kb="$(timeout 10 grep -E '^MemAvailable:' /proc/meminfo 2>/dev/null \
        | grep -oE '[0-9]+' | head -1 || echo "0")"

    if [[ "${mem_total_kb}" -eq 0 ]] 2>/dev/null; then
        # /proc/meminfo unreadable — emit sentinel that triggers FAIL
        emit "ORIONX_PERF: idle_ram_bytes=9999999999"
        mark_fail
        return
    fi

    used_bytes=$(( (mem_total_kb - mem_avail_kb) * 1024 ))
    emit "ORIONX_PERF: idle_ram_bytes=${used_bytes}"

    if [[ "${used_bytes}" -lt "${IDLE_RAM_THRESHOLD}" ]] 2>/dev/null; then
        : # PASS
    else
        mark_fail
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
emit "ORIONX_PERF_BEGIN"

measure_boot_time
measure_idle_ram

emit "ORIONX_PERF_END: overall=${OVERALL}"

# Exit 0 always — this is a probe, not a boot gate. The host-side parser owns
# the PASS/FAIL verdict for the test suite. Never kill the boot sequence.
exit 0
