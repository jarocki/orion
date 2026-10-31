#!/bin/sh
# Orion-X Phoenix Edition — plymouth-quit-wait failure diagnostics.
#
# Run by orionx-plymouth-diag.service (OnFailure= of plymouth-quit-wait.service,
# DEC-PHASE13-028, #141). Writes the plymouth / getty / DRM / serial-console
# state to stdout, which the unit points at /dev/console. Every line carries
# the ORIONX-PLYMOUTH-DIAG prefix; qemu-boot-test.sh prints the block when a
# boot mode fails. Each probe is independent: one failing must not hide the
# rest, so nothing here exits non-zero on a missing tool or file.
p="ORIONX-PLYMOUTH-DIAG"
up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo '?')"
echo "$p: begin (uptime ${up}s)"

set -- plymouth-start.service plymouth-quit.service plymouth-quit-wait.service \
       orionx-first-boot.service serial-getty@ttyS0.service getty@tty1.service
systemctl --no-pager --no-legend status "$@" 2>&1 | sed "s/^/$p: status: /"

jargs=""
for u in "$@"; do jargs="$jargs -u $u"; done
# shellcheck disable=SC2086  # jargs is a flag list built above; splitting is the point
journalctl -b --no-pager -o short-monotonic $jargs 2>&1 | tail -n 60 | sed "s/^/$p: journal: /"

ps -eo pid,ppid,stat,wchan:24,etimes,args 2>/dev/null | awk '/plymouth|agetty/ && !/awk/' | sed "s/^/$p: proc: /"

for pid in $(pidof plymouthd 2>/dev/null); do
    [ -r "/proc/$pid/stack" ] && sed "s/^/$p: plymouthd[$pid] stack: /" "/proc/$pid/stack"
    for fd in /proc/"$pid"/fd/*; do
        [ -e "$fd" ] || continue
        target="$(readlink "$fd" 2>/dev/null)" || continue
        case "$target" in
            *tty*|*dri*|*fb*|*console*) echo "$p: plymouthd[$pid] fd: ${fd##*/} -> $target" ;;
        esac
    done
done

for node in /dev/dri/* /dev/fb*; do
    [ -e "$node" ] && echo "$p: node: $node"
done
for n in /sys/class/graphics/fb*/name; do
    [ -r "$n" ] && echo "$p: fb: $n=$(cat "$n")"
done
sed "s/^/$p: consoles: /" /proc/consoles 2>/dev/null
stty -a -F /dev/ttyS0 2>&1 | sed "s/^/$p: ttyS0: /"

echo "$p: end"
exit 0
