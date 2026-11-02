#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_desktop_wiring.sh — XFCE desktop wiring regressions (Trixie / XFCE 4.20)
#
# Locks two fixes found on the trixie-dev1 hardware boot:
#   - wallpaper: set on every backdrop (monitor-name-agnostic), not monitor0 only
#     (DEC-PHASE12-004)
#   - genmon panel widgets: per-plugin .rc Command= present + widgets emit <txt>
#     markup so they render instead of the "(genmon)" placeholder (DEC-PHASE12-005)
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

WP="$REPO_ROOT/scripts/set-wallpaper.sh"
AUTOSTART="$REPO_ROOT/iso/config/includes.chroot/etc/xdg/autostart/orionx-wallpaper.desktop"
HOOK="$REPO_ROOT/iso/config/hooks/normal/0100-create-user.hook.chroot"
WIDGETS="$REPO_ROOT/scripts/control_center/widgets"

section "Wallpaper: monitor-name-agnostic (DEC-PHASE12-004)"
if [[ -x "$WP" ]]; then pass "set-wallpaper.sh present + executable"; else fail "set-wallpaper.sh present+exec" "missing/not +x"; fi
if grep -q "^Exec=/opt/orionx/scripts/set-wallpaper.sh" "$AUTOSTART"; then
    pass "autostart invokes set-wallpaper.sh"
else
    fail "autostart invokes set-wallpaper.sh" "orionx-wallpaper.desktop Exec not updated"
fi
# Must enumerate existing backdrops (xfconf-query -l), not hardcode monitor0 only.
if grep -qF 'xfconf-query -c "$CH" -l' "$WP" && grep -q "backdrop/screen0/monitor" "$WP"; then
    pass "set-wallpaper enumerates existing backdrop props (handles any connector name)"
else
    fail "set-wallpaper enumerates backdrops" "still relies on a hardcoded monitor path"
fi
if sh -n "$WP" 2>/dev/null; then pass "set-wallpaper.sh is valid POSIX sh"; else fail "set-wallpaper.sh valid sh" "syntax error"; fi
# Rev 2 (race fix): must WAIT for xfdesktop to register backdrops, log to a file,
# and make a second pass — the rev-1 fire-and-forget lost the startup race.
if grep -q '_i" -lt 30' "$WP" && grep -q "set-wallpaper.log" "$WP" && grep -qi "second pass" "$WP"; then
    pass "set-wallpaper waits for xfdesktop, logs, and second-passes (race-proof)"
else
    fail "set-wallpaper race-proof" "missing wait loop / log / second pass"
fi
# Belt-and-suspenders: XFCE 4.20's compiled-in default backdrop (xfce-x.svg) is
# replaced with the Phoenix image at build time, so the default IS Phoenix.
BRAND="$REPO_ROOT/iso/config/hooks/live/0800-orionx-branding.hook.chroot"
if grep -q "backgrounds/xfce/xfce-x.svg" "$BRAND" && grep -q "base64" "$BRAND"; then
    pass "0800 hook replaces XFCE default backdrop xfce-x.svg with Phoenix (embedded SVG)"
else
    fail "0800 hook replaces default backdrop" "xfce-x.svg override missing from branding hook"
fi

section "genmon: per-plugin Command= + widgets emit <txt> (DEC-PHASE12-005)"
# The 0100 hook must write genmon-<id>.rc with a Command= for each widget id.
if grep -q "genmon-\$1.rc" "$HOOK" && grep -q "^Command=python3" "$HOOK"; then
    pass "0100 hook writes genmon-<id>.rc with Command= (the file genmon actually reads)"
else
    fail "0100 hook writes genmon .rc Command=" "genmon reads Command from genmon-<id>.rc, not the panel XML"
fi
for w in net-status mesh-status scans-count clients-count; do
    if grep -q "genmon_rc.*$w\|/$w.py" "$HOOK"; then pass "genmon rc wired for $w"; else fail "genmon rc wired for $w" "no rc entry"; fi
done
# Every widget must wrap output in <txt>…</txt> or genmon shows the placeholder.
for w in net-status mesh-status scans-count clients-count; do
    outs=$(python3 "$WIDGETS/$w.py" 2>/dev/null)
    if printf '%s' "$outs" | grep -q "<txt>.*</txt>"; then
        pass "$w emits genmon <txt> markup"
    else
        fail "$w emits <txt> markup" "output was: $outs"
    fi
done
# DEC-PHASE12-010: scans/clients are REAL counts now, never the "?" placeholder.
for w in scans-count clients-count; do
    first=$(python3 "$WIDGETS/$w.py" 2>/dev/null | head -1)
    if printf '%s' "$first" | grep -qE "<txt>[◎◉] [0-9]+</txt>"; then
        pass "$w emits a real integer count (got: $first)"
    else
        fail "$w emits a real integer count" "got: $first"
    fi
done
# scans-count must count only scan/IDS events, from the bus, and tolerate garbage.
if python3 - "$WIDGETS" <<'PY'
import sys, tempfile, json, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("sc", sys.argv[1] + "/scans-count.py")
sc = importlib.util.module_from_spec(spec); spec.loader.exec_module(sc)
p = Path(tempfile.mktemp())
rows = [
  {"category": "ids", "source": "suricata"},   # counts (both)
  {"category": "scan", "source": "x"},         # counts (category)
  {"category": "service", "source": "health"}, # NOT a scan
  {"category": "posture", "source": "posture"},# NOT a scan
  {"category": "x", "source": "nucleotide"},   # counts (source)
]
p.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n\n")
assert sc.count_scans(p) == 3, sc.count_scans(p)
assert sc.count_scans(Path("/nonexistent/bus")) == 0
p.unlink()
spec2 = importlib.util.spec_from_file_location("cc", sys.argv[1] + "/clients-count.py")
cc = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(cc)
neigh = ("192.168.4.1 dev enp2s0 lladdr aa:bb:cc:dd:ee:01 REACHABLE\n"
         "192.168.4.77 dev enp2s0 lladdr aa:bb:cc:dd:ee:02 STALE\n"
         "192.168.4.99 dev enp2s0  FAILED\n"
         "192.168.4.50 dev enp2s0 lladdr aa:bb:cc:dd:ee:03 INCOMPLETE\n")
assert cc.count_clients(neigh) == 2, cc.count_clients(neigh)
assert cc.count_clients("") == 0
print("ok")
PY
then pass "widget counting logic (scan filter, garbage-tolerant, neigh states)"; else fail "widget counting logic" "assertion failed"; fi
# No emoji (U+1Fxxx) — the panel font has no emoji glyphs; they rendered as tofu
# boxes on the trixie-dev2 boot. Widgets must use BMP geometric glyphs instead.
if grep -qiE "U0001F" "$WIDGETS"/*.py 2>/dev/null; then
    fail "widgets use no emoji (panel font lacks emoji glyphs)" "U+1Fxxx escape still present"
else
    pass "widgets use panel-font-safe glyphs (no emoji tofu)"
fi

# ===========================================================================
# Cyberdeck theming (DEC-PHASE12-042)
#
# Operator directive: "Make sure the theme changes... well, change the themes
# (terminals, transparency, background image, etc.)."
#
# These assert EFFECTS, not strings in a file: the scripts are RUN against a
# scratch HOME with a stub xfconf-query, and the assertion is on what they did
# and what they reported. The specific regression being locked is the one named
# in docs/RESILIENCE.md rule 3 — toggle-theme.sh claiming success it had not
# confirmed — so the headline test is that a write which does NOT stick is
# reported as a failure and turns the exit code non-zero.
# ===========================================================================
TOGGLE="$REPO_ROOT/scripts/toggle-theme.sh"
TERM_DIR="$REPO_ROOT/theme/terminal"
HOOK0800="$REPO_ROOT/iso/config/hooks/live/0800-orionx-branding.hook.chroot"
THEMES="$REPO_ROOT/iso/config/includes.chroot/usr/share/themes"
SCRATCH="$REPO_ROOT/tmp/test_desktop_wiring_$$"
mkdir -p "$SCRATCH/bin"

# A stub xfconf-query with a real backing store, so "did the write stick?" is a
# question the test can actually answer. STUB_REFUSE names one property whose
# writes are silently dropped — the exact shape of the xfconf registration race.
cat > "$SCRATCH/bin/xfconf-query" <<'STUB'
#!/bin/bash
# Backing store is "channel<prop>|value" lines, one per property. '|' is the
# separator because a literal tab is not portable through BSD vs GNU sed.
db="${STUB_DB:-/dev/null}"
ch=""; prop=""; val=""; list=0
while [ $# -gt 0 ]; do
  case "$1" in
    -c) ch="$2"; shift 2;; -p) prop="$2"; shift 2;; -s) val="$2"; shift 2;;
    -l) list=1; shift;; -n) shift;; -t) shift 2;; *) shift;;
  esac
done
if [ "$list" = 1 ] && [ -z "$prop" ]; then
  awk -F'|' -v c="$ch" 'index($1,c)==1 {print substr($1, length(c)+1)}' "$db" 2>/dev/null
  exit 0
fi
key="$ch$prop"
if [ -n "$val" ]; then
  [ "$prop" = "${STUB_REFUSE:-}" ] && exit 0
  grep -v "^$key|" "$db" > "$db.tmp" 2>/dev/null; mv "$db.tmp" "$db" 2>/dev/null
  printf '%s|%s\n' "$key" "$val" >> "$db"
  exit 0
fi
line=$(grep "^$key|" "$db" 2>/dev/null | head -1)
[ -n "$line" ] || exit 1
printf '%s\n' "${line#*|}"
STUB
chmod +x "$SCRATCH/bin/xfconf-query"
cat > "$SCRATCH/bin/xfdesktop" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$SCRATCH/bin/xfdesktop"

_toggle() {  # $1 = scratch home subdir, rest = args; env via caller
    HOME="$SCRATCH/$1" PATH="$SCRATCH/bin:$PATH" bash "$TOGGLE" "${@:2}"
}

section "Terminal palette is one data asset (DEC-PHASE12-042)"
if [[ -f "$TERM_DIR/dark.terminalrc" && -f "$TERM_DIR/green.terminalrc" ]]; then
    pass "theme/terminal/{dark,green}.terminalrc present"
else
    fail "theme/terminal profiles present" "the single palette authority is missing"
fi
# FontName=Hack 12 is pinned by DEC-PHASE11-031 AND by test-iso-content-presence
# 23b-j, which reads the /etc/skel copy of the dark profile.
for v in dark green; do
    if grep -qxF 'FontName=Hack 12' "$TERM_DIR/$v.terminalrc" 2>/dev/null; then
        pass "$v.terminalrc pins FontName=Hack 12 (DEC-PHASE11-031)"
    else
        fail "$v.terminalrc pins FontName=Hack 12" "Iosevka regression / 23b-j would break"
    fi
    if grep -qxF 'BackgroundMode=TERMINAL_BACKGROUND_TRANSPARENT' "$TERM_DIR/$v.terminalrc" 2>/dev/null; then
        pass "$v.terminalrc enables terminal transparency"
    else
        fail "$v.terminalrc enables transparency" "BackgroundMode key missing — terminal is an opaque box"
    fi
done
# The two profiles must actually differ, or the toggle is cosmetic noise.
if ! cmp -s "$TERM_DIR/dark.terminalrc" "$TERM_DIR/green.terminalrc" \
   && [[ "$(grep '^ColorBackground=' "$TERM_DIR/dark.terminalrc")" != "$(grep '^ColorBackground=' "$TERM_DIR/green.terminalrc")" ]]; then
    pass "dark and green terminal profiles differ (different ColorBackground)"
else
    fail "terminal profiles differ" "both variants are the same file — the toggle would be invisible"
fi
# The palette must exist in ONE place. 0100 used to inline it and toggle-theme
# used to inline two more copies; the copies had drifted (RESILIENCE rule 7).
if ! grep -q '^ColorPalette=' "$HOOK" && grep -q 'theme/terminal/dark.terminalrc' "$HOOK"; then
    pass "0100 hook copies the terminal asset instead of inlining a palette (rule 7)"
else
    fail "0100 hook still inlines a terminal palette" "two authorities for the terminal colours"
fi
if ! grep -q 'ColorPalette=' "$TOGGLE"; then
    pass "toggle-theme.sh carries no inline palette (rule 7)"
else
    fail "toggle-theme.sh still inlines a palette" "it drifted from the /etc/skel seed last time"
fi
# 0100 must verify its own write, not assume it (rule 3). This one is a
# STRUCTURAL assertion and says so: the hook writes to absolute /etc/skel paths
# inside a chroot, so there is no honest way to run its verification block here.
# What it pins is the thing a careless edit would lose — the non-empty key list
# and the fail-loud exit. An earlier version grepped only for the comparison
# expression and stayed green when the key list was emptied (mutation D9).
if grep -qF "for _k in 'FontName=Hack 12' 'BackgroundMode=TERMINAL_BACKGROUND_TRANSPARENT'; do" "$HOOK" \
   && grep -qF 'ERROR: seeded terminalrc lacks' "$HOOK"; then
    pass "0100 hook verifies both seeded terminalrc keys and exits 1 if either is missing"
else
    fail "0100 hook verifies seeded terminalrc" \
         "the key list or the fail-loud exit is gone — a failed copy would ship silently"
fi

section "Compositor + window decorations"
if grep -q '"use_compositing" type="bool" value="true"' "$HOOK"; then
    pass "0100 seeds xfwm4 use_compositing=true (terminal transparency needs a compositor)"
else
    fail "0100 seeds use_compositing" "BackgroundMode=TRANSPARENT is inert with no compositor"
fi
if grep -q '"frame_opacity"' "$HOOK"; then
    pass "0100 seeds xfwm4 frame_opacity (window frames are translucent)"
else
    fail "0100 seeds frame_opacity" "no window transparency"
fi
if [[ -f "$THEMES/Orion-X-Cyberdeck-Green/xfwm4/themerc" ]]; then
    pass "Orion-X-Cyberdeck-Green xfwm4 theme staged (the visible half of the toggle)"
else
    fail "Orion-X-Cyberdeck-Green staged" "the green theme has no window decorations to switch to"
fi
# Both themerc files must define the same keys; a missing key silently falls
# back to xfwm4 defaults and the two themes stop being comparable.
_k1="$(grep -oE '^[a-z_]+=' "$THEMES/Orion-X-Cyberdeck/xfwm4/themerc" 2>/dev/null | sort)"
_k2="$(grep -oE '^[a-z_]+=' "$THEMES/Orion-X-Cyberdeck-Green/xfwm4/themerc" 2>/dev/null | sort)"
if [[ -n "$_k1" && "$_k1" == "$_k2" ]]; then
    pass "both xfwm4 themercs define an identical key set"
else
    fail "xfwm4 themerc key sets match" "one theme omits keys the other sets"
fi
# The 0800 pixmap seeding must cover EVERY Orion-X theme, not one hardcoded name
# — a theme with no .xpm renders no titlebar at all (hardware 2026-09-09).
if grep -q 'for _XFWM_THEME in /usr/share/themes/Orion-X-\*/xfwm4' "$HOOK0800"; then
    pass "0800 seeds xfwm4 pixmaps for every Orion-X-* theme (not just Cyberdeck)"
else
    fail "0800 seeds pixmaps for all Orion-X themes" "the green variant would ship borderless"
fi

section "toggle-theme.sh: plan / do / check / report (RESILIENCE rules 1,3,4)"
# PLAN is pure: it must change nothing, including $HOME.
mkdir -p "$SCRATCH/pure"
_plan_dark="$(_toggle pure --plan dark 2>/dev/null)"
_plan_green="$(_toggle pure --plan green 2>/dev/null)"
if [[ -z "$(ls -A "$SCRATCH/pure" 2>/dev/null)" ]]; then
    pass "--plan writes nothing (pure function of the theme name)"
else
    fail "--plan is pure" "it created files in HOME: $(ls -A "$SCRATCH/pure" | tr '\n' ' ')"
fi
if [[ -n "$_plan_dark" && -n "$_plan_green" && "$_plan_dark" != "$_plan_green" ]]; then
    pass "--plan dark and --plan green describe different desired states"
else
    fail "--plan differs per theme" "the plan is identical, so the toggle cannot change anything"
fi
# The difference must be exactly what a theme IS (DEC-PHASE12-058): the xfwm4
# theme, the two opacities, the GTK theme, the wallpaper asset and the terminal
# asset — six rows, twelve diff lines. Not more (icon theme and compositing are
# shared), not fewer (rc6 shipped with the wallpaper and GTK theme identical,
# which is why "Toggle Theme did nothing" on the reference deck).
_plan_diff="$(diff <(printf '%s\n' "$_plan_dark") <(printf '%s\n' "$_plan_green") | grep -c '^[<>]')"
if [[ "$_plan_diff" -eq 12 ]]; then
    pass "--plan differs on exactly 6 rows (xfwm4 theme, 2 opacities, GTK theme, wallpaper, terminalrc)"
else
    fail "--plan diff is $_plan_diff changed lines, expected 12" \
         "a theme is six things (DEC-PHASE12-058); check theme_plan and theme_assets"
fi
# Both GTK themes must be the SAME Adwaita-dark base (DEC-PHASE11-010 kept): the
# green one is a recolour, never a second base theme.
_green_css="$REPO_ROOT/iso/config/includes.chroot/usr/share/themes/Orion-X-Cyberdeck-Green/gtk-3.0/gtk.css"
if [[ -f "$_green_css" ]] && grep -q 'resource:///org/gtk/libgtk/theme/Adwaita/gtk-dark.css' "$_green_css"; then
    pass "the green GTK theme is a recolour of the same Adwaita-dark base"
else
    fail "green GTK theme base" "Orion-X-Cyberdeck-Green/gtk-3.0/gtk.css missing or not importing the Adwaita-dark base"
fi

# DO + CHECK, everything succeeding.
mkdir -p "$SCRATCH/ok"; : > "$SCRATCH/ok/db"; touch "$SCRATCH/ok/.bashrc"
_out_ok="$(STUB_DB="$SCRATCH/ok/db" DISPLAY=:99 _toggle ok --set green 2>&1)"; _rc_ok=$?
if [[ "$_rc_ok" -eq 0 ]] && printf '%s' "$_out_ok" | grep -q '0 failed'; then
    pass "toggle --set green exits 0 and reports 0 failed when every write sticks"
else
    fail "toggle --set green succeeds cleanly" "rc=$_rc_ok; output: $(printf '%s' "$_out_ok" | tail -3 | tr '\n' ' ')"
fi
# Effect, not claim: the window-manager theme really changed in the store.
if [[ "$(grep '^xfwm4/general/theme|' "$SCRATCH/ok/db" | cut -d'|' -f2)" == "Orion-X-Cyberdeck-Green" ]]; then
    pass "xfwm4 /general/theme actually holds Orion-X-Cyberdeck-Green after the toggle"
else
    fail "xfwm4 theme changed" "store holds: $(grep '^xfwm4/general/theme|' "$SCRATCH/ok/db" || echo '<nothing>')"
fi
if [[ "$(grep '^xfwm4/general/use_compositing|' "$SCRATCH/ok/db" | cut -d'|' -f2)" == "true" ]]; then
    pass "compositing is turned on by the toggle (terminal transparency needs it)"
else
    fail "toggle enables compositing" "use_compositing not true in the store"
fi
if cmp -s "$TERM_DIR/green.terminalrc" "$SCRATCH/ok/.config/xfce4/terminal/terminalrc"; then
    pass "terminal profile on disk is byte-identical to the green asset"
else
    fail "terminal profile applied" "\$HOME/.config/xfce4/terminal/terminalrc does not match the asset"
fi
# Toggling again must flip back — a toggle that only goes one way is a setter.
_out_back="$(STUB_DB="$SCRATCH/ok/db" DISPLAY=:99 _toggle ok 2>&1)"
if [[ "$(cat "$SCRATCH/ok/.orionx_theme")" == "dark" ]] \
   && [[ "$(grep '^xfwm4/general/theme|' "$SCRATCH/ok/db" | cut -d'|' -f2)" == "Orion-X-Cyberdeck" ]]; then
    pass "a second toggle flips back to dark, in the store as well as the state file"
else
    fail "toggle flips back" "state=$(cat "$SCRATCH/ok/.orionx_theme" 2>/dev/null) theme=$(grep '^xfwm4/general/theme|' "$SCRATCH/ok/db" | cut -d'|' -f2)"
fi

# THE RULE-3 REGRESSION. A write that does not stick must be reported as a
# failure and must make the exit code non-zero. The old script logged
# "XFCE wallpaper updated" on the line after its own failure branch.
mkdir -p "$SCRATCH/refuse"; : > "$SCRATCH/refuse/db"; touch "$SCRATCH/refuse/.bashrc"
_out_bad="$(STUB_DB="$SCRATCH/refuse/db" STUB_REFUSE=/general/theme DISPLAY=:99 \
            ORIONX_XFCONF_TRIES=2 _toggle refuse --set green 2>&1)"; _rc_bad=$?
if [[ "$_rc_bad" -ne 0 ]]; then
    pass "toggle exits NON-ZERO when an xfconf write does not take effect (rule 3)"
else
    fail "toggle exits non-zero on unapplied write" "it exited 0 — this is the exact bug RESILIENCE rule 3 names"
fi
if printf '%s' "$_out_bad" | grep -q 'FAILED  xfwm4 /general/theme'; then
    pass "toggle names the property that did not take effect"
else
    fail "toggle names the failed property" "output did not identify /general/theme"
fi
if printf '%s' "$_out_bad" | grep -q 'fix: '; then
    pass "toggle prints a remedy for the failure (rule 8)"
else
    fail "toggle prints a remedy" "a degraded state with no named fix"
fi
# Bounded retries (rule 4): the default budget is 3, and it must be a bounded
# loop, not a forever-retry like orionx-postured's suricata loop.
if grep -q 'ORIONX_XFCONF_TRIES:-3' "$TOGGLE" && grep -q 'while \[ "\$i" -lt "\$XFCONF_TRIES" \]' "$TOGGLE"; then
    pass "xfconf retries are bounded at 3 by default (rule 4)"
else
    fail "xfconf retries are bounded" "unbounded retry is how the event bus got flooded"
fi
# --status re-reads reality and must disagree with a store that was tampered with.
printf 'xfwm4/general/theme|Something-Else\n' > "$SCRATCH/ok/db"
_out_st="$(STUB_DB="$SCRATCH/ok/db" DISPLAY=:99 _toggle ok --status 2>&1)"; _rc_st=$?
if [[ "$_rc_st" -ne 0 ]] && printf '%s' "$_out_st" | grep -q "wanted 'Orion-X-Cyberdeck'"; then
    pass "--status re-reads reality and reports drift instead of the recorded intent"
else
    fail "--status detects drift" "rc=$_rc_st — status trusted the state file instead of the session"
fi
# No second wallpaper authority (rule 7): the backdrop belongs to set-wallpaper.sh.
# Comments in toggle-theme.sh explain WHY it must not; code must not.
# WRITES are the dual authority; --status READS the backdrops to verify the
# theme's wallpaper landed (DEC-PHASE12-058), which is rule 3, not rule 7.
if ! grep -v '^[[:space:]]*#' "$TOGGLE" | grep 'backdrop' | grep -qE 'xfconf_set_verified|xfconf-query[^|]* -s |xfconf-query[^|]* -n '; then
    pass "toggle-theme.sh never WRITES a backdrop property (set-wallpaper.sh is the authority; reading to verify is allowed)"
else
    fail "toggle-theme.sh writes backdrop properties" "that is the DEC-PHASE12-035 dual authority coming back"
fi

section "set-wallpaper.sh reports what actually happened (DEC-PHASE12-042)"
# It used to `exit 0` on a missing PNG, which made toggle-theme print
# "wallpaper applied" for a wallpaper it had not applied.
if ! HOME="$SCRATCH/ok" PATH="$SCRATCH/bin:$PATH" bash "$WP" "$SCRATCH/definitely-not-here.png" >/dev/null 2>&1; then
    pass "set-wallpaper.sh exits non-zero when the wallpaper file is missing"
else
    fail "set-wallpaper.sh fails loudly on a missing PNG" "exit 0 made the caller report success"
fi
# And it must verify the backdrop READS BACK as the wallpaper, not merely that
# xfconf-query returned 0 — a write to an unregistered property does both.
mkdir -p "$SCRATCH/wp"
_WPPNG="$REPO_ROOT/theme/wallpapers/orionx-phoenix-wallpaper.png"
printf 'xfce4-desktop/backdrop/screen0/monitoreDP-1/workspace0/last-image|/old.png\n' > "$SCRATCH/wp/db"
if HOME="$SCRATCH/wp" PATH="$SCRATCH/bin:$PATH" STUB_DB="$SCRATCH/wp/db" \
   bash "$WP" "$_WPPNG" >/dev/null 2>&1 \
   && grep -q "last-image|$_WPPNG" "$SCRATCH/wp/db"; then
    pass "set-wallpaper.sh sets the real connector-named backdrop and exits 0"
else
    fail "set-wallpaper.sh applies to the real backdrop" "db: $(cat "$SCRATCH/wp/db" 2>/dev/null)"
fi
printf 'xfce4-desktop/backdrop/screen0/monitoreDP-1/workspace0/last-image|/old.png\n' > "$SCRATCH/wp/db"
if ! HOME="$SCRATCH/wp" PATH="$SCRATCH/bin:$PATH" STUB_DB="$SCRATCH/wp/db" \
     STUB_REFUSE=/backdrop/screen0/monitoreDP-1/workspace0/last-image \
     bash "$WP" "$_WPPNG" >/dev/null 2>&1; then
    pass "set-wallpaper.sh exits non-zero when no backdrop reads back as the wallpaper (rule 3)"
else
    fail "set-wallpaper.sh verifies the backdrop readback" \
         "writes that evaporate were being reported as success"
fi

# ---------------------------------------------------------------------------
# DEC-PHASE13-034 (#149): the Desktop launchers are marked trusted per session.
# Executed against a stub gio with a real backing store, so the assertion is on
# what was written (attribute = SHA-256 of the file), not on the source text.
# ---------------------------------------------------------------------------
section "Desktop launchers trusted for XFCE 4.20 (DEC-PHASE13-034, #149)"
TL="$REPO_ROOT/scripts/orionx-trust-launchers.sh"
TL_AUTOSTART="$REPO_ROOT/iso/config/includes.chroot/etc/xdg/autostart/orionx-trust-launchers.desktop"
TL_HOOK="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
TLS="$SCRATCH/trust"; mkdir -p "$TLS/bin" "$TLS/Desktop"
if [[ -x "$TL" ]]; then pass "orionx-trust-launchers.sh present + executable"; else fail "orionx-trust-launchers.sh present+exec" "missing/not +x"; fi
grep -q '@decision DEC-PHASE13-034' "$TL" && pass "script carries DEC-PHASE13-034" || fail "script decision annotation"
if [[ -f "$TL_AUTOSTART" ]]; then pass "autostart entry staged"; else fail "autostart entry staged" "missing $TL_AUTOSTART"; fi
grep -qE '^Exec=/opt/orionx/scripts/orionx-trust-launchers.sh$' "$TL_AUTOSTART" && pass "autostart runs the staged script" || fail "autostart Exec"
grep -qE '^OnlyShowIn=XFCE;?$' "$TL_AUTOSTART" && pass "autostart is XFCE-only" || fail "autostart OnlyShowIn"
grep -qE '^NoDisplay=true$' "$TL_AUTOSTART" && pass "autostart entry is hidden from menus" || fail "autostart NoDisplay"
grep -qF '["orionx-trust-launchers"]="/opt/orionx/scripts/orionx-trust-launchers.sh"' "$TL_HOOK" && pass "0700 puts orionx-trust-launchers on PATH (--check by hand)" || fail "0700 SCRIPT_MAP entry"
# stub gio with a backing store: info -a ATTR FILE / set -t string FILE ATTR VALUE
cat > "$TLS/bin/gio" <<'STUB'
#!/usr/bin/env bash
db="${STUB_DB:?}"; touch "$db"
case "$1" in
  info) attr="$3"; f="$4"; v="$(grep -F "$f|$attr|" "$db" | tail -1 | cut -d'|' -f3-)"; [[ -n "$v" ]] && printf '  %s: %s\n' "$attr" "$v"; echo "info" >> "$db.calls" ;;
  set)  f="$4"; attr="$5"; v="$6"; echo "$f|$attr|$v" >> "$db"; echo "set $f" >> "$db.calls" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TLS/bin/gio"
printf '[Desktop Entry]\nType=Application\nName=A\nExec=true\n' > "$TLS/Desktop/a.desktop"; chmod 755 "$TLS/Desktop/a.desktop"
printf '[Desktop Entry]\nType=Application\nName=B\nExec=true\n' > "$TLS/Desktop/b.desktop"; chmod 644 "$TLS/Desktop/b.desktop"
echo "notes" > "$TLS/Desktop/notes.txt"
ln -s a.desktop "$TLS/Desktop/link.desktop"
tl_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
tl_run() { STUB_DB="$TLS/db" PATH="$TLS/bin:$PATH" bash "$TL" --desktop-dir "$TLS/Desktop" "$@"; }
tl_run --check >/dev/null 2>&1; [[ $? -eq 1 ]] && pass "--check on untrusted launchers exits 1" || fail "--check exit on untrusted"
[[ ! -f "$TLS/db" || ! -s "$TLS/db" ]] && pass "--check writes nothing" || fail "--check wrote attributes" "$(cat "$TLS/db")"
TL_OUT="$(tl_run 2>&1)"; TL_RC=$?
[[ $TL_RC -eq 0 ]] && pass "apply exits 0" || fail "apply exit" "rc=$TL_RC $TL_OUT"
grep -qF "$TLS/Desktop/a.desktop|metadata::xfce-exe-checksum|$(tl_sha "$TLS/Desktop/a.desktop")" "$TLS/db" \
    && pass "a.desktop: attribute set to the file's SHA-256 (what xfce_g_file_is_trusted compares)" || fail "a.desktop attribute" "$(cat "$TLS/db")"
grep -qF "$TLS/Desktop/b.desktop|metadata::xfce-exe-checksum|$(tl_sha "$TLS/Desktop/b.desktop")" "$TLS/db" \
    && pass "b.desktop: attribute set" || fail "b.desktop attribute" "$(cat "$TLS/db")"
[[ -x "$TLS/Desktop/b.desktop" ]] && pass "a launcher without +x is made executable (Thunar classifies on it too)" || fail "b.desktop +x"
grep -q "notes.txt" "$TLS/db" && fail "non-launcher file was touched" || pass "notes.txt (not a launcher) is left alone"
grep -q "link.desktop" "$TLS/db" && fail "symlink launcher was trusted" || pass "a symlink is never trusted (not the operator's file)"
echo "$TL_OUT" | grep -q '2 marked, 1 made executable, 0 failed' && pass "summary line reports 2 marked, 1 made executable" || fail "summary" "$TL_OUT"
: > "$TLS/db.calls"
TL_OUT2="$(tl_run 2>&1)"
grep -q '^set' "$TLS/db.calls" && fail "second run rewrote attributes (not idempotent)" || pass "second run writes nothing (idempotent)"
echo "$TL_OUT2" | grep -q '2 already trusted, 0 marked' && pass "second run reports everything already trusted" || fail "second run summary" "$TL_OUT2"
tl_run --check >/dev/null 2>&1 && pass "--check after apply exits 0" || fail "--check after apply"
printf '[Desktop Entry]\nType=Application\nName=A2\nExec=true\n' > "$TLS/Desktop/a.desktop"
tl_run --check >/dev/null 2>&1; [[ $? -eq 1 ]] && pass "a changed launcher is untrusted again (content hash, not a flag)" || fail "content change not detected"
TL_DRY="$(tl_run --dry-run 2>&1)"; : > "$TLS/db.calls"
echo "$TL_DRY" | grep -q 'would set' && ! grep -q '^set' "$TLS/db.calls" && pass "--dry-run says what it would write and writes nothing" || fail "--dry-run" "$TL_DRY"
ORIONX_GIO_BIN=/nonexistent/gio bash "$TL" --desktop-dir "$TLS/Desktop" >/dev/null 2>&1 && pass "no gio: warns, exits 0 (never breaks the session)" || fail "no gio apply exit"
ORIONX_GIO_BIN=/nonexistent/gio bash "$TL" --desktop-dir "$TLS/Desktop" --check >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "no gio: --check exits 2 (cannot verify)" || fail "no gio check exit"
bash "$TL" --desktop-dir "$TLS/nope" >/dev/null 2>&1 && pass "missing Desktop directory: exits 0" || fail "missing dir exit"

rm -rf "$SCRATCH"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
