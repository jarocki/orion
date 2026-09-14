#!/bin/sh
# set-wallpaper.sh — apply the Orion-X Phoenix wallpaper to every XFCE backdrop.
#
# @decision DEC-PHASE12-004 (rev 2 — wait for xfdesktop, then overwrite; log it)
# @title Monitor-name-agnostic, race-proof wallpaper setter (XFCE 4.20 / Trixie)
# @status accepted
# @rationale Rev 1 enumerated existing backdrop props and overwrote them, but on
#   the trixie-dev2 hardware boot the wallpaper still did not apply. Everything
#   was present (script +x, PNG staged, xrandr/xfconf-query/xfdesktop all in the
#   rootfs), which points at a STARTUP RACE: XDG autostart fires before xfdesktop
#   has registered the real monitor, so rev 1 found no props, set guessed names,
#   and xfdesktop then initialised its own default (the blue diamond-X). XFCE
#   4.20 names backdrops by connector (e.g. monitoreDP-1), so hardcoded monitor0
#   (the /etc/skel seed) is never the real display. Fix: WAIT (up to 30s) for
#   xfdesktop to register backdrop props under whatever name it chooses, THEN
#   overwrite them all; do a second pass to catch late-registered monitors; and
#   LOG every step to ~/.cache/orionx/set-wallpaper.log so the next boot gives
#   ground truth instead of a guess. Falls back to xrandr-detected names only if
#   xfdesktop never registers anything. Idempotent; safe every session.
#
# Usage: set-wallpaper.sh [wallpaper-path]

WP="${1:-/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png}"
CH="xfce4-desktop"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/orionx/set-wallpaper.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

log "start WP=$WP DISPLAY=${DISPLAY:-unset}"
[ -f "$WP" ] || { log "ABORT: wallpaper file missing"; exit 0; }
command -v xfconf-query >/dev/null 2>&1 || { log "ABORT: xfconf-query not found"; exit 0; }

# Every backdrop image property xfdesktop has registered (any connector name,
# with or without the workspaceN level).
_props() {
    xfconf-query -c "$CH" -l 2>/dev/null \
        | grep -E '/backdrop/screen0/monitor[^/]+/(workspace[0-9]+/)?last-image$'
}

# image-style 5 = Zoomed (fill screen, keep aspect; 16:9 art on a 16:9 panel).
_set_one() {
    xfconf-query -c "$CH" -p "$1" -s "$WP" 2>/dev/null \
        || xfconf-query -c "$CH" -p "$1" -n -t string -s "$WP" 2>/dev/null
    _style=$(printf '%s' "$1" | sed 's:/last-image$:/image-style:')
    xfconf-query -c "$CH" -p "$_style" -s 5 2>/dev/null \
        || xfconf-query -c "$CH" -p "$_style" -n -t int -s 5 2>/dev/null
    log "set $1"
}

# 1) Wait for xfdesktop to register the real monitor(s) — this is the race fix.
_i=0
_props_now=""
while [ "$_i" -lt 30 ]; do
    _props_now=$(_props)
    [ -n "$_props_now" ] && break
    sleep 1
    _i=$((_i + 1))
done
log "waited ${_i}s; backdrop props: $(printf '%s' "$_props_now" | tr '\n' ' ')"

if [ -n "$_props_now" ]; then
    for _p in $_props_now; do _set_one "$_p"; done
else
    # 2) xfdesktop never registered anything: create for connected monitors and
    #    a bare monitor0, both path shapes.
    _mons=$(xrandr 2>/dev/null | awk '/ connected/{print $1}')
    [ -n "$_mons" ] || _mons="0"
    log "fallback: no props after wait; monitors: $_mons"
    for _m in $_mons 0; do
        _set_one "/backdrop/screen0/monitor$_m/workspace0/last-image"
        _set_one "/backdrop/screen0/monitor$_m/last-image"
    done
fi

if xfdesktop --reload 2>/dev/null; then log "xfdesktop --reload ok"; else log "xfdesktop --reload unavailable"; fi

# 3) Second pass: xfdesktop can register monitors slightly after our first set
#    (late init). Re-check and overwrite anything that isn't ours yet.
sleep 3
for _p in $(_props); do
    _cur=$(xfconf-query -c "$CH" -p "$_p" 2>/dev/null)
    [ "$_cur" = "$WP" ] || { log "second-pass fix $_p (was: $_cur)"; _set_one "$_p"; }
done
log "done"
exit 0
