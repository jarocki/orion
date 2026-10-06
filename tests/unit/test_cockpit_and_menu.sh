#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_cockpit_and_menu.sh — Orion menu group (DEC-PHASE12-006), Orion Cockpit
# (DEC-PHASE12-007) and the deck theming pass (DEC-PHASE12-008).
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

CH="$REPO_ROOT/iso/config/includes.chroot"
HOOK="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
PKGS="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
CK="$REPO_ROOT/scripts/cockpit"
APP="$REPO_ROOT/scripts/control_center/app.py"

section "Orion application menu (DEC-PHASE12-006)"
D="$CH/usr/share/desktop-directories/orionx.directory"
if [[ -f "$D" ]] && grep -q "^Name=Orion$" "$D" && grep -q "pixmaps/orionx.png" "$D"; then
    pass "orionx.directory defines the 'Orion' group with the Phoenix icon"
else
    fail "orionx.directory" "missing, wrong Name, or no icon"
fi
M="$CH/etc/xdg/menus/applications-merged/orionx.menu"
if [[ -f "$M" ]] && grep -q "<Name>Xfce</Name>" "$M" && grep -q "<Category>X-Orion</Category>" "$M"; then
    pass "applications-merged/orionx.menu merges into XFCE root and includes X-Orion"
else
    fail "orionx.menu" "missing, wrong root <Name> (must be Xfce), or no X-Orion include"
fi
if [[ -f "$CH/usr/share/pixmaps/orionx.png" ]] && file "$CH/usr/share/pixmaps/orionx.png" | grep -q "128 x 128"; then
    pass "Phoenix menu/app icon staged (128x128)"
else
    fail "orionx.png icon" "missing or not 128x128"
fi
# Every Orion .desktop — hook-written and static — must carry X-Orion.
if grep -n "Categories=" "$HOOK" "$CH"/usr/share/applications/orionx-*.desktop | grep -qv "X-Orion"; then
    fail "all Orion .desktop entries tagged X-Orion" "$(grep -n 'Categories=' "$HOOK" "$CH"/usr/share/applications/orionx-*.desktop | grep -v X-Orion | head -3)"
else
    pass "all Orion .desktop entries tagged Categories=X-Orion"
fi
if grep -q "orionx-cockpit.desktop" "$HOOK" && grep -q "Name=Orion Cockpit" "$HOOK"; then
    pass "Orion Cockpit .desktop entry written by the 0700 hook"
else
    fail "cockpit .desktop" "missing from 0700 hook"
fi
if grep -qE '\["orionx-cockpit"\]="/opt/orionx/scripts/cockpit/orionx-cockpit"' "$HOOK"; then
    pass "SCRIPT_MAP symlinks orionx-cockpit into PATH"
else
    fail "SCRIPT_MAP orionx-cockpit" "missing"
fi

section "Orion Cockpit (DEC-PHASE12-007)"
for f in cockpit_lib.py orionx-cockpit; do
    [[ -f "$CK/$f" ]] && pass "$f present" || fail "$f present" "missing"
done
[[ -x "$CK/orionx-cockpit" ]] && pass "orionx-cockpit executable" || fail "orionx-cockpit executable" "not +x"
if python3 -m py_compile "$CK/cockpit_lib.py" "$CK/orionx-cockpit" 2>/dev/null; then pass "cockpit compiles"; else fail "cockpit compiles" "py_compile error"; fi
if grep -q "^python3-gi-cairo$" "$PKGS"; then
    pass "python3-gi-cairo in package list (Cairo draw handler prerequisite)"
else
    fail "python3-gi-cairo" "missing — DrawingArea 'draw' gets no cairo.Context without it"
fi
grep -q "DEC-PHASE12-007" "$CK/cockpit_lib.py" && pass "DEC-PHASE12-007 annotation" || fail "DEC-PHASE12-007 annotation" "missing"
# Same bus as R.A.I.N. — single event authority.
grep -q 'import deck_vitals as V' "$CK/orionx-cockpit" && pass "cockpit reads deck vitals from the shared module (DEC-PHASE12-049)" || fail "deck_vitals import" "missing"
grep -q 'def _deck_panel' "$CK/orionx-cockpit" && pass "cockpit draws a DECK band (hostname, addresses, gateway, CPU/MEM/DISK)" || fail "DECK band" "missing"
grep -q '/run/orionx/events.jsonl' "$CK/cockpit_lib.py" && pass "cockpit consumes the R.A.I.N. event bus (single authority)" || fail "cockpit event bus path" "not /run/orionx/events.jsonl"
# Pure logic must be provable with no display/gi.
if python3 - "$CK" <<'PY'
import sys, tempfile, json
from pathlib import Path
sys.path.insert(0, sys.argv[1]); import cockpit_lib as L
now=1000.0
assert abs(L.pressure([{"ts":now,"severity":"critical"}],now)-40)<1e-6
assert abs(L.pressure([{"ts":now-60,"severity":"critical"}],now)-20)<1e-6
assert L.pressure([{"ts":now,"severity":"critical"}]*10,now)==100.0
assert L.pressure_color(10)==L.GREEN and L.pressure_color(40)==L.AMBER and L.pressure_color(80)==L.RED
# DEC-PHASE12-034 / DEC-PHASE12-039: self-diagnosis is not threat.
# The shipped defect was THREAT PRESSURE reading "ELEVATED" on an idle deck
# because orionx-postured's own health warnings were weighted as threat. The
# fix had no test; this is it, stated as the commit stated the measurement:
# twelve health warnings contribute 0.0, two real scan warnings contribute 40.
health=[{"ts":now,"severity":"warning","category":"health"}]*12
assert L.pressure(health,now)==0.0, L.pressure(health,now)
scans=[{"ts":now,"severity":"warning","category":"scan"}]*2
assert abs(L.pressure(scans,now)-40.0)<1e-6, L.pressure(scans,now)
# Every excluded category, at the heaviest severity, must still be 0.
for _c in L.SELF_STATUS_CATEGORIES:
    assert L.pressure([{"ts":now,"severity":"critical","category":_c}],now)==0.0, _c
# The exclusion must not swallow genuine detections sharing a severity.
assert abs(L.pressure([{"ts":now,"severity":"critical","category":"ids"}],now)-40.0)<1e-6
# A missing category must still count — defaulting to "excluded" would make
# the gauge silently blind to any emitter that forgets the field.
assert abs(L.pressure([{"ts":now,"severity":"critical"}],now)-40.0)<1e-6
# Drift invariant against rain_lib, the single authority (DEC-PHASE12-040).
# Asserting a hardcoded set here would mean editing this test every time the
# vocabulary grows, which is how a mirror drifts in the first place.
import importlib.machinery as _im
_rlmod = _im.SourceFileLoader("rain_lib", "scripts/rain/rain_lib.py").load_module()
assert set(L.SELF_STATUS_CATEGORIES)==set(_rlmod.STATUS_CATEGORIES), (
    "cockpit_lib.SELF_STATUS_CATEGORIES has drifted from rain_lib.STATUS_CATEGORIES: "
    f"{set(L.SELF_STATUS_CATEGORIES) ^ set(_rlmod.STATUS_CATEGORIES)}")
assert L.parse_event('{"severity":"WARNING","ts":1}')["severity"]=="warning" and L.parse_event("x") is None
pts=L.sparkline_points([0,50,100],0,0,200,100); assert pts[0]==(0,100) and pts[-1][1]==0
r=L.RateTracker(5); r.push(0,0,0.0); r.push(2048,1024,2.0); assert (r.rx_rate,r.tx_rate)==(1024.0,512.0)
p=Path(tempfile.mktemp()); p.write_text('{"ts":1,"severity":"info","source":"s","category":"c","message":"a"}\n')
t=L.EventTail(p,backfill=5); t.poll(); assert len(t.events)==1
# Real bus rotation = the tmpfs file is recreated (NEW inode); model that, not an in-place rewrite.
p.unlink(); p.write_text('{"ts":2,"severity":"critical","source":"s","category":"c","message":"rot"}\n'); n=t.poll(); assert n and n[0]["message"]=="rot", n; p.unlink()
print("ok")
PY
then pass "cockpit_lib logic (pressure decay/clamp/bands, parse, sparkline, rates, tail+rotation)"; else fail "cockpit_lib logic" "assertion failed"; fi

section "Deck theming (DEC-PHASE12-008)"
grep -q "DEC-PHASE12-008" "$APP" && pass "DEC-PHASE12-008 annotation in app.py" || fail "DEC-PHASE12-008 annotation" "missing"
grep -q "@keyframes orionx-pulse" "$APP" && pass "CC CSS has the pulsing ember tagline animation" || fail "CSS keyframes" "missing"
grep -q "button.orionx-cockpit" "$APP" && pass "CC CSS styles the Cockpit launcher button" || fail "CSS cockpit button" "missing"
grep -q '"orionx-cockpit"' "$APP" && pass "CC header launches orionx-cockpit" || fail "CC cockpit launcher" "app.py does not launch orionx-cockpit"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
