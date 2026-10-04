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

# The default asset. set-wallpaper.sh is the authority for WHICH wallpaper the
# deck uses (DEC-PHASE12-004), so resolving the asset is its job and not its
# caller's -- toggle-theme.sh deliberately invokes this with no argument.
# Installed path wins; the repo-relative path is the development fallback so
# the script is runnable, and testable, from a checkout.
_WP_DEFAULT="/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png"
if [ ! -f "$_WP_DEFAULT" ]; then
    _WP_DEV="$(dirname "$0")/../theme/wallpapers/orionx-phoenix-wallpaper.png"
    [ -f "$_WP_DEV" ] && _WP_DEFAULT="$_WP_DEV"
fi
WP="${1:-$_WP_DEFAULT}"
CH="xfce4-desktop"
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/orionx/set-wallpaper.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

log "start WP=$WP DISPLAY=${DISPLAY:-unset}"

# @decision DEC-PHASE12-042 (amends DEC-PHASE12-004)
# These two aborts used to `exit 0`. That made the script indistinguishable, to
# any caller, from a successful run -- and it has a caller: toggle-theme.sh
# reports "wallpaper applied" on a zero exit. A missing PNG therefore produced
# a cheerful success message and no wallpaper, which is RESILIENCE rule 3 in
# the same script the rule was written about. They exit 1 now and name the
# remedy. The XDG autostart that also calls this ignores exit status, so
# nothing regresses there; the difference is only that failure is now legible.
if [ ! -f "$WP" ]; then
    log "ABORT: wallpaper file missing: $WP"
    echo "set-wallpaper: $WP not found." >&2
    echo "  fix: reinstall /opt/orionx/theme/wallpapers/ (staged from theme/wallpapers/)." >&2
    exit 1
fi
if ! command -v xfconf-query >/dev/null 2>&1; then
    log "ABORT: xfconf-query not found"
    echo "set-wallpaper: xfconf-query not installed." >&2
    echo "  fix: apt-get install xfconf (see iso/config/package-lists/orionx.list.chroot)." >&2
    exit 1
fi

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

# 4) CHECK (DEC-PHASE12-042). Everything above is "Do". This is the only part
#    that establishes whether the wallpaper is actually set: count the backdrop
#    properties that now READ BACK as our PNG. Zero means the run failed, no
#    matter how many xfconf-query calls returned 0 along the way -- a write to
#    a property xfdesktop has not registered succeeds and then evaporates.
_ok=0
_bad=0
for _p in $(_props); do
    if [ "$(xfconf-query -c "$CH" -p "$_p" 2>/dev/null)" = "$WP" ]; then
        _ok=$((_ok + 1))
    else
        _bad=$((_bad + 1))
        log "VERIFY FAIL $_p"
    fi
done
log "verified: $_ok backdrop(s) set, $_bad not"
if [ "$_ok" -eq 0 ]; then
    log "done: FAILED (no backdrop property reads back as $WP)"
    echo "set-wallpaper: no XFCE backdrop accepted the wallpaper." >&2
    echo "  what still works: the compiled-in default backdrop is already the" >&2
    echo "  Phoenix image (0800-orionx-branding replaces xfce-x.svg), so the" >&2
    echo "  desktop is branded even when this fails." >&2
    echo "  diagnose: xfconf-query -c $CH -l | grep backdrop ; cat $LOG" >&2
    exit 1
fi
log "done: OK ($_ok backdrop(s))"
exit 0
