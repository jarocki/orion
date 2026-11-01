#!/bin/sh
# Orion-X Phoenix Edition — plymouth-quit-wait failure diagnostics.
#
# Run by orionx-plymouth-diag.service (OnFailure= of plymouth-quit-wait.service,
# DEC-PHASE13-028, #141). Records the plymouth / getty / DRM / console-tty
# state so the serial log of a failed QEMU boot explains itself.
#
# Delivery is the point. In the failing boots nothing user space writes to the
# console tty appears afterwards (no login prompt from agetty, no output from
# the first version of this unit, which used StandardOutput=tty and blocked
# acquiring /dev/console), while kernel messages keep arriving. So every line
# goes to /dev/kmsg — the kernel console path, which the audit lines prove
# reaches the serial log — and, best effort and bounded, to /dev/console as
# well. Each probe is independent and time-limited: one hanging or missing
# tool must not hide the rest, and nothing here exits non-zero.
#
# Run 41272254094 (the first failure this unit caught) showed the deadlock is
# in systemd's pre-exec TTY setup: a child that never execed — ps names such a
# child "(timeout)" / "(agetty)" — holding the /dev/console lock, another
# waiting on it (wchan locks_lock_inode_wait), plymouthd idle. The fix is
# DEC-PHASE13-030 (orionx-plymouth-quit.service). What this script adds since:
# the kernel stack, wchan and syscall of every console holder and of every
# pre-exec child, and /proc/locks, so a recurrence names the blocking call.
p="ORIONX-PLYMOUTH-DIAG"

say() {
    # One line to the kernel log (<6> = info); kmsg takes at most ~1000 bytes.
    printf '<6>%s: %s\n' "$p" "$(printf '%s' "$1" | cut -c1-900)" > /dev/kmsg 2>/dev/null
    printf '%s: %s\n' "$p" "$1" >> /tmp/orionx-plymouth-diag.log 2>/dev/null
}

# Run a probe with a time limit and relay every output line through say().
probe() {
    label="$1"; shift
    timeout 15 "$@" 2>&1 | while IFS= read -r line; do say "$label: $line"; done
}

# Where is a process stuck: kernel stack, wait channel, current syscall.
# Reading /proc/PID/stack of a sleeping task is safe and needs only root.
where() {
    pid="$1"; label="$2"
    [ -d "/proc/$pid" ] || return 0
    say "$label state: $(awk '/^State:/ {print $2, $3}' "/proc/$pid/status" 2>/dev/null) wchan: $(cat "/proc/$pid/wchan" 2>/dev/null) syscall: $(cut -c1-60 "/proc/$pid/syscall" 2>/dev/null)"
    [ -r "/proc/$pid/stack" ] && probe "$label stack" cat "/proc/$pid/stack"
}

up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo '?')"
say "begin (uptime ${up}s)"

set -- plymouth-start.service plymouth-quit.service plymouth-quit-wait.service \
       orionx-plymouth-quit.service orionx-first-boot.service \
       serial-getty@ttyS0.service getty@tty1.service
probe status systemctl --no-pager --no-legend status "$@"

jargs=""
for u in "$@"; do jargs="$jargs -u $u"; done
# shellcheck disable=SC2086  # jargs is a flag list built above; splitting is the point
probe journal sh -c "journalctl -b --no-pager -o short-monotonic $jargs 2>&1 | tail -n 60"

# plymouth, getty, and every child systemd forked but that has not execed yet:
# such a child shows its future command in parentheses, "(agetty)".
probe proc sh -c "ps -eo pid,ppid,stat,wchan:24,etimes,args 2>/dev/null | awk '/plymouth|agetty|first-boot|^ *[0-9]+ +[0-9]+ +[A-Za-z<>+]+ +[^ ]+ +[0-9]+ +\\(/ && !/awk/'"

for pid in $(pidof plymouthd 2>/dev/null); do
    where "$pid" "plymouthd[$pid]"
done

# Who holds the console and the serial line (an fd on either), and where each
# holder is blocked. A holder that has not execed yet is systemd's pre-exec
# child for a unit with StandardInput=tty (the deadlock of DEC-PHASE13-030).
seen=""
for fdlink in /proc/[0-9]*/fd/*; do
    target="$(readlink "$fdlink" 2>/dev/null)" || continue
    case "$target" in
        /dev/console|/dev/ttyS0|/dev/tty0|/dev/tty1)
            pid="${fdlink#/proc/}"; pid="${pid%%/*}"
            say "holder: pid $pid ($(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-60)) fd ${fdlink##*/} -> $target"
            case " $seen " in *" $pid "*) ;; *) seen="$seen $pid"; where "$pid" "holder[$pid]" ;; esac ;;
    esac
done

# Pre-exec children that hold none of the nodes above (e.g. blocked earlier,
# acquiring the terminal) still show up by their "(name)" comm.
for st in /proc/[0-9]*/stat; do
    pid="${st#/proc/}"; pid="${pid%%/*}"
    case " $seen " in *" $pid "*) continue ;; esac
    comm="$(sed -n 's/^[0-9]* (\(.*\)) .*/\1/p' "$st" 2>/dev/null)"
    case "$comm" in
        "("*")") where "$pid" "pre-exec[$pid] $comm" ;;
    esac
done

# File locks: the /dev/console BSD lock systemd takes around every TTY reset
# (lock_dev_console) shows here with its holder's pid.
probe locks cat /proc/locks

# Serial line state: tx/rx counters and modem lines (DCD/CTS) tell flow-control
# and carrier stories; termios tells whether the line is -clocal or ixon.
probe "serial driver" cat /proc/tty/driver/serial
probe "ttyS0 termios" stty -a -F /dev/ttyS0
probe "console termios" stty -a -F /dev/console
probe consoles cat /proc/consoles
probe "active console" cat /sys/class/tty/console/active

for node in /dev/dri/* /dev/fb*; do
    [ -e "$node" ] && say "node: $node"
done
for n in /sys/class/graphics/fb*/name; do
    [ -r "$n" ] && say "fb: $n=$(cat "$n")"
done

say "end"

# Best effort copy to the console itself, bounded: if this hangs, the kmsg
# copy above has already landed and that is itself a finding.
timeout 5 sh -c 'cat /tmp/orionx-plymouth-diag.log > /dev/console' 2>/dev/null
exit 0
