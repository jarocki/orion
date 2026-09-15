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

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
