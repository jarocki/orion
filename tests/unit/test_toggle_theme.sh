#!/usr/bin/env bash
# toggle-theme.sh (DEC-PHASE12-058): a theme is wallpaper + GTK accent + frames +
# terminal + prompt, and the two themes differ in each. Pure plan, assets, wiring.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
T="$ROOT/scripts/toggle-theme.sh"; TH="$ROOT/iso/config/includes.chroot/usr/share/themes"
TMPH="$(mktemp -d "$ROOT/tmp/theme-test.XXXXXX")"; trap 'rm -rf "$TMPH"' EXIT
bash -n "$T" && pass "toggle-theme.sh parses" || fail "parse" "bash -n failed"
shellcheck -S warning "$T" >/dev/null 2>&1 && pass "shellcheck clean" || fail "shellcheck" "$(shellcheck -S warning "$T" 2>&1 | head -5)"
PD="$(HOME="$TMPH" bash "$T" --plan dark 2>&1)"; PG="$(HOME="$TMPH" bash "$T" --plan green 2>&1)"
grep -q '^xsettings|/Net/ThemeName|string|Orion-X-Cyberdeck$' <<<"$PD" && grep -q '^xsettings|/Net/ThemeName|string|Orion-X-Cyberdeck-Green$' <<<"$PG" && pass "GTK theme differs per theme (dark base, green variant)" || fail "ThemeName plan" "$PD // $PG"
grep -q '^xfwm4|/general/theme|string|Orion-X-Cyberdeck$' <<<"$PD" && grep -q '^xfwm4|/general/theme|string|Orion-X-Cyberdeck-Green$' <<<"$PG" && pass "window-frame theme differs per theme" || fail "xfwm plan" "$PD // $PG"
WD="$(grep '^asset|wallpaper|' <<<"$PD" | cut -d'|' -f4)"; WG="$(grep '^asset|wallpaper|' <<<"$PG" | cut -d'|' -f4)"
[[ -n "$WD" && -n "$WG" && "$WD" != "$WG" ]] && pass "wallpaper differs per theme ($(basename "$WD") / $(basename "$WG"))" || fail "wallpaper plan" "dark=$WD green=$WG"
for w in "$WD" "$WG"; do f="$ROOT/theme/wallpapers/$(basename "$w")"; [[ -f "$f" ]] && pass "wallpaper asset ships: $(basename "$w")" || fail "wallpaper asset" "$f missing"; done
TD="$(grep '^asset|terminalrc|' <<<"$PD" | cut -d'|' -f4)"; TG="$(grep '^asset|terminalrc|' <<<"$PG" | cut -d'|' -f4)"
[[ -f "$ROOT/theme/terminal/$(basename "$TD")" && -f "$ROOT/theme/terminal/$(basename "$TG")" ]] && pass "terminal palette assets ship for both themes" || fail "terminalrc assets" "$TD / $TG"
diff -q <(grep -E '^Color(Foreground|Background|Palette)=' "$ROOT/theme/terminal/dark.terminalrc") <(grep -E '^Color(Foreground|Background|Palette)=' "$ROOT/theme/terminal/green.terminalrc") >/dev/null && fail "terminal palettes differ" "identical colour keys" || pass "terminal palettes differ (foreground, background, palette)"
grep -q '^ColorUseTheme=FALSE' "$ROOT/theme/terminal/green.terminalrc" && grep -q '^BackgroundMode=TERMINAL_BACKGROUND_TRANSPARENT' "$ROOT/theme/terminal/green.terminalrc" && pass "terminal uses its own colours and transparency" || fail "terminal keys" "ColorUseTheme/BackgroundMode"
for f in gtk-3.0/gtk.css gtk-3.0/gtk-dark.css gtk-2.0/gtkrc index.theme xfwm4/themerc; do [[ -f "$TH/Orion-X-Cyberdeck-Green/$f" ]] && pass "green theme file: $f" || fail "green theme file" "$f missing"; done
grep -q 'resource:///org/gtk/libgtk/theme/Adwaita/gtk-dark.css' "$TH/Orion-X-Cyberdeck-Green/gtk-3.0/gtk.css" && pass "green GTK is the same Adwaita-dark base (DEC-PHASE11-010 kept)" || fail "green base" "no Adwaita import"
grep -q '#0CFA54' "$TH/Orion-X-Cyberdeck-Green/gtk-3.0/gtk.css" && grep -q 'active_text_color=#0CFA54' "$TH/Orion-X-Cyberdeck-Green/xfwm4/themerc" && pass "green GTK accent matches the green window frames (#0CFA54)" || fail "accent match" "GTK and xfwm4 disagree"
grep -qi '#FF5722' "$TH/Orion-X-Cyberdeck-Green/gtk-3.0/gtk.css" "$TH/Orion-X-Cyberdeck-Green/gtk-2.0/gtkrc" && fail "no Phoenix orange left in the green variant" "found" || pass "no Phoenix orange left in the green variant"
grep -q '^GtkTheme=Orion-X-Cyberdeck-Green' "$TH/Orion-X-Cyberdeck-Green/index.theme" && pass "green index.theme names its GtkTheme" || fail "index.theme" "GtkTheme missing"
grep -q 'apply_wallpaper "\$theme"' "$T" && grep -q '"\$SET_WALLPAPER" "\$wp"' "$T" && pass "the toggle passes the theme's wallpaper to set-wallpaper.sh" || fail "wallpaper wiring" "set-wallpaper called without the theme image"
grep -q 'WP="\${1:-\$_WP_DEFAULT}"' "$ROOT/scripts/set-wallpaper.sh" && pass "set-wallpaper.sh accepts the image as \$1" || fail "set-wallpaper arg" "no positional image"
grep -q "n_bad backdrop(s) do not show" "$T" && pass "--status verifies every backdrop shows the theme wallpaper" || fail "status wallpaper" "missing"
grep -q "toggle-theme.sh; exec xfce4-terminal --title 'Orion-X theme' --hold -e 'toggle-theme.sh --status'" "$ROOT/scripts/control_center/sections/ir.py" && pass "Cockpit button opens a NEW terminal with the report after toggling" || fail "cockpit button" "still detached with no window"
grep -q "DEC-PHASE12-058" "$T" && pass "decision annotated" || fail "DEC-PHASE12-058" "missing"
echo "==========================================="; echo "Results: $PASS passed, $FAIL failed"; echo "==========================================="
[[ $FAIL -eq 0 ]]
