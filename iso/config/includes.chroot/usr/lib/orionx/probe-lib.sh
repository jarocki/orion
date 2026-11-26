#!/bin/bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — shared helpers for the in-guest CI probes
# (runtime-verify.sh, perf-measure.sh). Sourced, never run.
#
# @decision DEC-PHASE13-067
# @title The in-guest probes run after the boot transaction, wait for the desktop session, and leave the verdicts to the host
# @status accepted
# @rationale #40 and #78. Since the model moved into the image, no develop
#   QEMU run had received a single ORIONX_VERIFY or ORIONX_PERF line (run
#   44204402356: "ORIONX_VERIFY_BEGIN not found", "ORIONX_PERF_BEGIN not
#   found"). Both steps were continue-on-error, so the job stayed green. A
#   local boot of the v3.1.6 ISO with the journal forwarded to the serial line
#   (2026-11-26; excerpt on #40, issuecomment-7205153716) showed why:
#   both units are After=multi-user.target, and multi-user.target waits for
#   nebula-integrity-check, a oneshot that hashes the 1.93 GB model. Under TCG
#   that took 253 s (65.5 s -> 318.8 s); the probes started at 319.2 s, long
#   after the harness had stopped waiting (120 s / 90 s past the login
#   prompt). Their tty output was never the problem: every sentinel arrived.
#   The ordering stays (a probe that ran before the boot finished would test
#   a half-booted system); the waits are sized to it instead, and the probes
#   now also wait for what an operator sees, the autologin desktop session
#   (opened at 294.9 s on that boot, after the first-boot wizard's prompts
#   time out). The probes measure and report; the host-side test is the one
#   authority for every threshold, so a limit lives in one place. Timings
#   under TCG emulation are recorded, not judged: they measure the runner.
#
# Every sentinel is one line on stdout. The units set StandardOutput=tty with
# TTYPath=/dev/ttyS0, which delivers it to the serial log the host reads.

emit() { printf '%s\n' "$1"; }

# The account live-config autologs in (live-config.username= on the kernel
# command line; the image's default otherwise).
probe_user() {
    local arg args=() cmdline="${ORIONX_PROBE_CMDLINE:-/proc/cmdline}"
    [[ -r "$cmdline" ]] && read -ra args < "$cmdline"
    for arg in ${args[@]+"${args[@]}"}; do
        case "$arg" in live-config.username=*) printf '%s\n' "${arg#*=}"; return 0 ;; esac
    done
    printf '%s\n' orionx-operator
}

# True once the operator's desktop is up: an xfce4-session process owned by
# the autologin user.
desktop_up() { pgrep -u "$1" -x xfce4-session >/dev/null 2>&1; }

# Wait up to $2 seconds for the desktop session of user $1. Returns 0 when it
# is up, 1 at the deadline.
wait_desktop() {
    local user="$1" deadline=$(( SECONDS + $2 ))
    until desktop_up "$user"; do
        (( SECONDS < deadline )) || return 1
        sleep "${ORIONX_PROBE_POLL:-5}"
    done
}

# Seconds since boot at which a unit became active (0 when it has not).
active_since_boot() {
    local us
    us="$(timeout 10 systemctl show -p ActiveEnterTimestampMonotonic --value "$1" 2>/dev/null || true)"
    [[ "$us" =~ ^[0-9]+$ ]] || us=0
    printf '%s\n' $(( us / 1000000 ))
}
