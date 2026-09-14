#!/bin/sh
# set-wallpaper.sh — apply the Orion-X Phoenix wallpaper to every XFCE backdrop.
#
# @decision DEC-PHASE12-004
# @title Monitor-name-agnostic wallpaper setter (XFCE 4.20 / Trixie regression)
# @status accepted
# @rationale The old autostart hardcoded /backdrop/screen0/monitor0/... . XFCE
#   4.16 (bullseye) tolerated that, but XFCE 4.20 (trixie) names each backdrop by
#   its connector — e.g. /backdrop/screen0/monitoreDP-1/workspace0/last-image —
#   so setting "monitor0" landed on a path xfdesktop never reads and the panel
#   kept the default Debian wallpaper (observed on the trixie-dev1 hardware boot).
#   This script instead OVERWRITES every backdrop last-image property that
#   actually exists (whatever the connector is named), and only if none exist yet
#   (autostart raced xfdesktop) falls back to creating them for the connected
#   monitors. Idempotent; safe to run every session.
#
# Usage: set-wallpaper.sh [wallpaper-path]

WP="${1:-/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png}"
CH="xfce4-desktop"

[ -f "$WP" ] || exit 0
command -v xfconf-query >/dev/null 2>&1 || exit 0

# image-style 5 = "Zoomed" (fill the screen, keep aspect) — 16:9 wallpaper on a
# 16:9 panel shows without distortion.
_set_one() {
    # $1 = a .../last-image property path
    xfconf-query -c "$CH" -p "$1" -s "$WP" 2>/dev/null \
        || xfconf-query -c "$CH" -p "$1" -n -t string -s "$WP" 2>/dev/null
    _style=$(printf '%s' "$1" | sed 's:/last-image$:/image-style:')
    xfconf-query -c "$CH" -p "$_style" -s 5 2>/dev/null \
        || xfconf-query -c "$CH" -p "$_style" -n -t int -s 5 2>/dev/null
}

# 1) Overwrite every existing backdrop image property (covers the real monitor
#    xfdesktop already registered, under whatever connector name).
_found=0
for _p in $(xfconf-query -c "$CH" -l 2>/dev/null \
              | grep -E '/backdrop/screen0/monitor[^/]+/(workspace[0-9]+/)?last-image$'); do
    _set_one "$_p"
    _found=1
done

# 2) Nothing registered yet (autostart raced xfdesktop): create for each
#    connected monitor, plus a bare monitor0 fallback, both path shapes.
if [ "$_found" -eq 0 ]; then
    _mons=$(xrandr 2>/dev/null | awk '/ connected/{print $1}')
    [ -n "$_mons" ] || _mons="0"
    for _m in $_mons 0; do
        _set_one "/backdrop/screen0/monitor$_m/workspace0/last-image"
        _set_one "/backdrop/screen0/monitor$_m/last-image"
    done
fi

# Nudge xfdesktop to repaint (harmless if it already applied the change live).
xfdesktop --reload 2>/dev/null || true
exit 0
