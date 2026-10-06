#!/bin/bash
#
# Orion-X Phoenix Edition — desktop theme toggle
#
# Switch the running XFCE session between the DARK (Phoenix amber) and GREEN
# (phosphor) cyberdeck themes — and prove that each change took effect.
#
# Usage:
#   toggle-theme.sh              toggle to the other theme
#   toggle-theme.sh --set dark   force a theme
#   toggle-theme.sh --set green
#   toggle-theme.sh --status     report desired vs actual; change nothing
#   toggle-theme.sh --plan dark  print the desired state as data; change nothing
#
# Exit status: 0 only if every action this run attempted was verified to have
# landed. Non-zero means at least one did not, and the summary names which and
# what to do about it.
#
# @decision DEC-PHASE12-058
# @title A theme is wallpaper + GTK accent + window frames + terminal + prompt, and the toggle changes all five
# @status accepted
# @rationale rc6 on the reference deck (2026-10-06): "Toggle Theme does NOTHING
#   except the window frame and the prompt colour; the wallpaper is not
#   changing AT ALL." Three causes, all in this script's plan: (1) it
#   re-asserted the SAME Phoenix wallpaper for both themes; (2) it set the SAME
#   GTK theme for both (DEC-PHASE11-010's single-theme rule), so every
#   selection, progress bar and suggested button stayed orange; (3) the terminal
#   palette WAS written, but xfce4-terminal 1.1.4 does not watch terminalrc
#   (verified: the binary imports no file monitor), so every already-open
#   window kept the old colours and nothing said so where the operator could
#   see it. Now: dark = Phoenix wallpaper + Orion-X-Cyberdeck; green = Neon
#   wallpaper + Orion-X-Cyberdeck-Green (a recolour of the same Adwaita-dark
#   base, DEC-PHASE11-010 kept for the base). --status checks the backdrop too.
#   The Cockpit button opens a NEW terminal afterwards, born with the new
#   palette, showing this script's status report.
#
# ---------------------------------------------------------------------------
# @decision DEC-PHASE12-042
# @title toggle-theme.sh plans, applies, re-reads, and reports honestly
# @status accepted
# @rationale This script is named three separate times in docs/RESILIENCE.md.
#   Rule 3: it logged "XFCE wallpaper updated" on the line after the `||`
#   failure branch, so it reported success in exactly the case where it had
#   failed. Rule 7: it wrote the backdrop to a hardcoded monitor0 path that
#   XFCE 4.20 never uses, duplicating — and contradicting — set-wallpaper.sh.
#   DEC-PHASE12-035 fixed the wallpaper half by delegating to set-wallpaper.sh.
#   This revision fixes the rest, and the rest was most of it:
#
#   1. It did not actually change the theme. The only desktop-visible effects
#      were a terminal rc file and a PS1 colour. GTK theme, window decorations,
#      and compositing were untouched, which is why the reference deck reported
#      "Toggle Theme stopped doing anything" — from the operator's seat it
#      never did very much.
#   2. Its two inline terminalrc heredocs were an eleven-key subset of the
#      37-key /etc/skel seed and reverted the DEC-PHASE11-031 readable
#      foreground. Toggling degraded the terminal. The palette is now a data
#      asset (theme/terminal/*.terminalrc → /opt/orionx/theme/terminal/),
#      written by exactly one authority and copied by this script.
#   3. Nothing was ever read back. Every action now re-reads the state it
#      wrote — `xfconf-query` prints what it stored, and `cmp` proves a file
#      copy — and the run's exit status is the conjunction of those checks.
#   4. Desired state is data, not control flow: theme_plan() is a pure
#      function from a theme name to a list of channel|property|type|value
#      rows. It is unit-testable without an X server, which is the property
#      docs/RESILIENCE.md asks every subsystem for.
#   5. Retries are bounded. xfconf has a genuine registration race (see
#      set-wallpaper.sh, DEC-PHASE12-004), so a write may need a moment — but
#      three attempts, then one clear failure line naming the remedy, then
#      stop. Rule 4.
#
#   AUTHORITIES THIS SCRIPT DOES NOT OWN AND MUST NOT DUPLICATE:
#     - the wallpaper            → scripts/set-wallpaper.sh (DEC-PHASE12-004/035)
#     - the terminal palette     → theme/terminal/*.terminalrc (DEC-PHASE12-042)
#     - the seeded home dir      → hooks/normal/0100-create-user.hook.chroot
#                                  (DEC-PHASE11-014)
#   If you are about to add a second way to set one of those here, don't.
# ---------------------------------------------------------------------------

set -uo pipefail

# Resolve through symlinks: 0700-orionx-setup.hook.chroot installs this as
# /usr/bin/toggle-theme.sh -> /opt/orionx/scripts/toggle-theme.sh, and a plain
# dirname of $0 there yields /usr/bin. The installed asset paths below are
# absolute and win anyway, but a sibling lookup that silently resolves to /theme
# is the kind of latent trap that only shows up on the deck.
_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
    _link="$(readlink "$_self")"
    case "$_link" in
        /*) _self="$_link" ;;
        *)  _self="$(dirname "$_self")/$_link" ;;
    esac
done
SELF_DIR="$(cd "$(dirname "$_self")" && pwd)"

# Asset roots. /opt/orionx is the installed layout; the repo-relative paths are
# the development fallback so the script is runnable (and testable) from a
# checkout. Installed path wins — there is one authority, this just finds it.
THEME_ROOT="/opt/orionx/theme"
[ -d "$THEME_ROOT/terminal" ] || THEME_ROOT="$SELF_DIR/../theme"
SET_WALLPAPER="/opt/orionx/scripts/set-wallpaper.sh"
[ -x "$SET_WALLPAPER" ] || SET_WALLPAPER="$SELF_DIR/set-wallpaper.sh"

STATE_FILE="$HOME/.orionx_theme"
# Bounded retry budget (RESILIENCE rule 4). Overridable so the test suite can
# exercise the give-up path without paying the real backoff; the DEFAULT is the
# contract, and tests assert on the default too.
XFCONF_TRIES="${ORIONX_XFCONF_TRIES:-3}"

# Log where we can actually write, and not one moment before we write. The old
# unconditional /var/log/orionx + `tee -a` printed a permission error for every
# line when the operator ran this from the desktop menu as a normal user; and
# creating the log directory at startup made --plan and --status leave traces,
# which disqualified them as the "ask without touching" commands they exist to
# be. Resolved on first use instead.
LOGFILE=""
_log_init() {
    [ -z "$LOGFILE" ] || return 0
    if [ -w /var/log/orionx ] 2>/dev/null || mkdir -p /var/log/orionx 2>/dev/null; then
        LOGFILE="/var/log/orionx/theme_toggle.log"
    else
        LOGFILE="${XDG_CACHE_HOME:-$HOME/.cache}/orionx/theme_toggle.log"
        mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null
    fi
    touch "$LOGFILE" 2>/dev/null || LOGFILE=/dev/null
}

OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILURES=()

log()  { _log_init; printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"; }
ok()   { OK_COUNT=$((OK_COUNT + 1));   log "  OK      $*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); log "  SKIP    $*"; }
# Every failure carries its own remedy (RESILIENCE rule 8).
bad()  {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILURES+=("$1 — fix: $2")
    log "  FAILED  $1"
    log "          fix: $2"
}

# ---------------------------------------------------------------------------
# PLAN — pure. Theme name in, desired state out, nothing touched.
#
# Rows are channel|property|type|value. IconThemeName is identical in both
# themes and listed so every run REASSERTS it. ThemeName now differs
# (DEC-PHASE12-058): Orion-X-Cyberdeck-Green is a recolour of the same
# Adwaita-dark base, so DEC-PHASE11-010's single-base rule still holds.
#
# What genuinely differs between the two themes:
#   - the xfwm4 window-decoration theme (visible: titlebar colour and border)
#   - the compositor opacity (visible: how much shows through)
#   - the terminal palette asset (visible: the terminal)
#   - the PS1 accent colour
#   - the GTK theme accent (DEC-PHASE12-058)
#   - the wallpaper (DEC-PHASE12-058; see theme_wallpaper below)
# ---------------------------------------------------------------------------
theme_plan() {
    local theme="$1" wm_theme gtk_theme frame_op inactive_op
    case "$theme" in
        green)
            wm_theme="Orion-X-Cyberdeck-Green"; gtk_theme="Orion-X-Cyberdeck-Green"; frame_op=78; inactive_op=88 ;;
        dark)
            wm_theme="Orion-X-Cyberdeck";       gtk_theme="Orion-X-Cyberdeck";       frame_op=88; inactive_op=92 ;;
        *)
            echo "theme_plan: unknown theme '$theme'" >&2; return 2 ;;
    esac
    cat <<PLAN
xfwm4|/general/theme|string|$wm_theme
xfwm4|/general/use_compositing|bool|true
xfwm4|/general/frame_opacity|int|$frame_op
xfwm4|/general/inactive_opacity|int|$inactive_op
xsettings|/Net/ThemeName|string|$gtk_theme
xsettings|/Net/IconThemeName|string|Orion-X-Icons
PLAN
}

# PS1 accent is a plan output too, kept separate because it is not xfconf.
theme_ps1_color() {
    case "$1" in
        green) printf '\\[\\033[01;32m\\]' ;;
        *)     printf '\\[\\033[38;5;214m\\]' ;;
    esac
}

theme_terminal_asset() { printf '%s/terminal/%s.terminalrc' "$THEME_ROOT" "$1"; }
# The wallpaper is part of the theme (DEC-PHASE12-058): Phoenix (amber) for
# dark, the cyan Neon phoenix for green. Both ship in /opt/orionx/theme/wallpapers.
theme_wallpaper() {
    case "$1" in
        green) printf '%s/wallpapers/orionx-wp-neon.png' "$THEME_ROOT" ;;
        *)     printf '%s/wallpapers/orionx-phoenix-wallpaper.png' "$THEME_ROOT" ;;
    esac
}
# Everything a theme consists of, as data (for --plan and the tests).
theme_assets() {
    printf 'asset|wallpaper|file|%s\n' "$(theme_wallpaper "$1")"
    printf 'asset|terminalrc|file|%s\n' "$(theme_terminal_asset "$1")"
}

# ---------------------------------------------------------------------------
# Is there a session to talk to? An honest SKIP beats a fabricated PASS and
# beats a failure the operator cannot act on.
# ---------------------------------------------------------------------------
have_session() {
    command -v xfconf-query >/dev/null 2>&1 || return 1
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# DO + CHECK for one xfconf row. Bounded retries, then give up and say so.
#
# The retry is not optimism: xfconf properties are registered by the component
# that owns them, so a write issued before xfwm4 has registered /general/* can
# land in a channel that is then overwritten at registration. set-wallpaper.sh
# documents the same race for xfdesktop backdrops. Three one-second attempts
# cover session start; beyond that something is actually wrong.
# ---------------------------------------------------------------------------
xfconf_set_verified() {
    local ch="$1" prop="$2" type="$3" want="$4" got="" i=0
    while [ "$i" -lt "$XFCONF_TRIES" ]; do
        i=$((i + 1))
        xfconf-query -c "$ch" -p "$prop" -s "$want" >/dev/null 2>&1 \
            || xfconf-query -c "$ch" -p "$prop" -n -t "$type" -s "$want" >/dev/null 2>&1
        got="$(xfconf-query -c "$ch" -p "$prop" 2>/dev/null)"
        if [ "$got" = "$want" ]; then
            ok "$ch $prop = $want (verified, attempt $i)"
            return 0
        fi
        [ "$i" -lt "$XFCONF_TRIES" ] && sleep 1
    done
    bad "$ch $prop is '${got:-<unset>}', wanted '$want'" \
        "run from the desktop session, then: xfconf-query -c $ch -p $prop -n -t $type -s $want"
    return 1
}

xfconf_read() { xfconf-query -c "$1" -p "$2" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Terminal palette: copy the asset, then prove the copy is byte-identical.
# ---------------------------------------------------------------------------
apply_terminal_profile() {
    local theme="$1" src dst
    src="$(theme_terminal_asset "$theme")"
    dst="$HOME/.config/xfce4/terminal/terminalrc"
    if [ ! -f "$src" ]; then
        bad "terminal profile asset missing: $src" \
            "reinstall /opt/orionx/theme/terminal/ (staged from theme/terminal/ by build-iso.sh)"
        return 1
    fi
    mkdir -p "$(dirname "$dst")" 2>/dev/null
    if ! cp "$src" "$dst" 2>/dev/null; then
        bad "could not write $dst" "check ownership: chown -R \$USER $HOME/.config/xfce4"
        return 1
    fi
    if cmp -s "$src" "$dst"; then
        ok "terminal profile = $theme ($dst matches $src byte for byte)"
        return 0
    fi
    bad "$dst does not match $src after copy" "check free space and permissions on $HOME"
    return 1
}

# ---------------------------------------------------------------------------
# PS1: rewrite the accent, then grep the file back to confirm it is there.
# ---------------------------------------------------------------------------
apply_ps1() {
    local theme="$1" color line
    if [ ! -f "$HOME/.bashrc" ]; then
        skip "PS1 (no $HOME/.bashrc)"
        return 0
    fi
    color="$(theme_ps1_color "$theme")"
    line="PS1='${color}[Orion-X]\\[\\033[00m\\] \\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\\$ '"
    sed -i '/# Orion-X Phoenix Edition PS1/d' "$HOME/.bashrc" 2>/dev/null
    sed -i '/^PS1=/d' "$HOME/.bashrc" 2>/dev/null
    {
        echo "# Orion-X Phoenix Edition PS1"
        echo "$line"
    } >> "$HOME/.bashrc" 2>/dev/null
    if grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null; then
        ok "PS1 accent = $theme (verified in $HOME/.bashrc)"
        return 0
    fi
    bad "PS1 line not found in $HOME/.bashrc after write" \
        "check that $HOME/.bashrc is writable"
    return 1
}

# ---------------------------------------------------------------------------
# Wallpaper: delegate. set-wallpaper.sh is the authority (DEC-PHASE12-004/035).
# Report exactly what it did — never the old unconditional success line.
# ---------------------------------------------------------------------------
apply_wallpaper() {
    local theme="$1" wp
    wp="$(theme_wallpaper "$theme")"
    if [ ! -f "$wp" ]; then
        bad "wallpaper asset missing: $wp" "reinstall /opt/orionx/theme/wallpapers/ (staged from theme/wallpapers/)"
        return 1
    fi
    if [ ! -x "$SET_WALLPAPER" ]; then
        bad "set-wallpaper.sh not found (looked in /opt/orionx/scripts and $SELF_DIR)" \
            "reinstall /opt/orionx/scripts/set-wallpaper.sh"
        return 1
    fi
    if ! have_session; then
        skip "wallpaper (no X session; set-wallpaper.sh needs one)"
        return 0
    fi
    if "$SET_WALLPAPER" "$wp"; then
        ok "wallpaper = $(basename "$wp") (set-wallpaper.sh verified every backdrop; ~/.cache/orionx/set-wallpaper.log)"
        return 0
    fi
    bad "set-wallpaper.sh exited non-zero" \
        "read ~/.cache/orionx/set-wallpaper.log, then run $SET_WALLPAPER by hand"
    return 1
}

apply_state_file() {
    local theme="$1"
    if ! printf '%s\n' "$theme" > "$STATE_FILE" 2>/dev/null; then
        bad "could not write $STATE_FILE" "check that $HOME is writable"
        return 1
    fi
    if [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$theme" ]; then
        ok "recorded theme = $theme ($STATE_FILE)"
        return 0
    fi
    bad "$STATE_FILE does not read back as '$theme'" "check that $HOME is writable"
    return 1
}

current_theme() {
    local t="dark"
    [ -f "$STATE_FILE" ] && t="$(cat "$STATE_FILE" 2>/dev/null)"
    case "$t" in green|dark) printf '%s' "$t" ;; *) printf 'dark' ;; esac
}

other_theme() { [ "$1" = "dark" ] && printf 'green' || printf 'dark'; }

# ---------------------------------------------------------------------------
# --status: re-read reality against the recorded theme. Writes nothing.
# ---------------------------------------------------------------------------
do_status() {
    local theme ch prop want got src dst
    theme="$(current_theme)"
    log "Status for recorded theme: $theme"
    if have_session; then
        while IFS='|' read -r ch prop _ want; do
            [ -n "$ch" ] || continue
            got="$(xfconf_read "$ch" "$prop")"
            if [ "$got" = "$want" ]; then
                ok "$ch $prop = $want"
            else
                bad "$ch $prop is '${got:-<unset>}', wanted '$want'" \
                    "run: $0 --set $theme"
            fi
        done < <(theme_plan "$theme")
    else
        skip "xfconf checks (no X session — run this from the desktop)"
    fi
    src="$(theme_terminal_asset "$theme")"
    dst="$HOME/.config/xfce4/terminal/terminalrc"
    if [ -f "$src" ] && cmp -s "$src" "$dst" 2>/dev/null; then
        ok "terminal profile matches $src"
    else
        bad "terminal profile $dst does not match $src" "run: $0 --set $theme"
    fi
    # Wallpaper (DEC-PHASE12-058): every backdrop xfdesktop registered must show the theme's image.
    local wp props p n_ok n_bad
    wp="$(theme_wallpaper "$theme")"
    if have_session; then
        props="$(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E '/backdrop/screen0/monitor[^/]+/(workspace[0-9]+/)?last-image$')"
        n_ok=0; n_bad=0
        for p in $props; do
            if [ "$(xfconf_read xfce4-desktop "$p")" = "$wp" ]; then n_ok=$((n_ok + 1)); else n_bad=$((n_bad + 1)); fi
        done
        if [ -z "$props" ]; then
            bad "no xfdesktop backdrop properties registered" "is xfdesktop running? xfconf-query -c xfce4-desktop -l | grep backdrop"
        elif [ "$n_bad" -eq 0 ]; then
            ok "wallpaper = $(basename "$wp") on $n_ok backdrop(s)"
        else
            bad "$n_bad backdrop(s) do not show $(basename "$wp")" "run: $SET_WALLPAPER $wp"
        fi
    else
        skip "wallpaper check (no X session)"
    fi
    summarise "status"
}

summarise() {
    local what="$1"
    log "----"
    log "$what: $OK_COUNT verified, $FAIL_COUNT failed, $SKIP_COUNT skipped"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        log "The following did NOT take effect:"
        local f
        for f in "${FAILURES[@]}"; do log "  - $f"; done
        echo ""
        echo "Theme $what INCOMPLETE: $FAIL_COUNT item(s) did not take effect (see above)."
        return 1
    fi
    echo ""
    echo "Theme $what complete: $OK_COUNT item(s) verified, $SKIP_COUNT skipped."
    return 0
}

do_apply() {
    local theme="$1" ch prop type want
    log "Applying theme: $theme"

    if have_session; then
        while IFS='|' read -r ch prop type want; do
            [ -n "$ch" ] || continue
            xfconf_set_verified "$ch" "$prop" "$type" "$want"
        done < <(theme_plan "$theme")
    else
        skip "xfconf writes (no X session; window theme and compositing unchanged)"
        log "          fix: run $0 from the XFCE desktop session"
    fi

    apply_terminal_profile "$theme"
    apply_ps1 "$theme"
    apply_wallpaper "$theme"
    apply_state_file "$theme"

    echo ""
    echo "Already-open terminals keep their old palette: xfce4-terminal 1.1 reads"
    echo "terminalrc only when a window is created (it has no file monitor). New"
    echo "windows get $theme; the Cockpit's button opens one for you."
    summarise "switch to $theme"
}

# ---------------------------------------------------------------------------
main() {
    case "${1:-}" in
        --status)
            do_status ;;
        --plan)
            theme_plan "${2:-$(current_theme)}" && theme_assets "${2:-$(current_theme)}" ;;
        --set)
            case "${2:-}" in
                dark|green) do_apply "$2" ;;
                *) echo "usage: $0 --set {dark|green}" >&2; exit 2 ;;
            esac ;;
        -h|--help)
            sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
        "")
            do_apply "$(other_theme "$(current_theme)")" ;;
        *)
            echo "usage: $0 [--set dark|green] [--status] [--plan [theme]]" >&2
            exit 2 ;;
    esac
}

main "$@"
