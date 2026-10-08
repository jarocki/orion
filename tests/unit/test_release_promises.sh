#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_release_promises.sh — the ISO gate's section 37 and self-check
# (DEC-PHASE12-119). Behavioural: runs the real assert_release_promises
# against synthetic squashfs trees (complete, then with items removed or
# wrong), and the real --self-check against mutated copies of the gate.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
T_PASS=0; T_FAIL=0
tpass() { T_PASS=$((T_PASS+1)); echo "  PASS: $1"; }
tfail() { T_FAIL=$((T_FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
LIB="$REPO_ROOT/tests/integration/lib/release-promises.sh"
GATE="$REPO_ROOT/tests/integration/test-iso-content-presence.sh"
S="$REPO_ROOT/tmp/test_release_promises_$$"; trap 'rm -rf "$S"' EXIT

mk_image() {  # complete synthetic image at $1
    local R="$1"; rm -rf "$R"; mkdir -p "$R"
    x() { mkdir -p "$R$(dirname "$1")"; printf '#!/bin/sh\n' > "$R$1"; chmod +x "$R$1"; }
    f() { mkdir -p "$R$(dirname "$1")"; printf '%s\n' "${2:-data}" > "$R$1"; }
    l() { mkdir -p "$R$(dirname "$1")"; ln -s "$2" "$R$1"; }
    mkdir -p "$R/var/lib/dpkg"
    { for p in gnome-keyring git python3-pip firefox-esr; do printf 'Package: %s\nStatus: install ok installed\n\n' "$p"; done
      printf 'Package: light-locker\nStatus: deinstall ok config-files\n\n'; } > "$R/var/lib/dpkg/status"
    f /usr/lib/systemd/system/orionx-mesh-status.timer
    l /etc/systemd/system/timers.target.wants/orionx-mesh-status.timer /usr/lib/systemd/system/orionx-mesh-status.timer
    f /var/lib/suricata/orionx-threshold.config
    f /etc/suricata/orionx.yaml 'threshold-file: /var/lib/suricata/orionx-threshold.config'
    f /etc/systemd/system/matrix-synapse.service.d/orionx.conf $'[Service]\nExecStart=\nExecStart=/opt/venvs/matrix-synapse/bin/python -m synapse.app.homeserver'
    f /usr/share/applications/orionx-control-center.desktop 'Exec=/usr/bin/orionx-cockpit --tab network'
    f /usr/share/applications/orionx-osint.desktop 'Name=Orion Workbench'
    x /opt/orionx/scripts/awareness/orionx-tune; l /usr/bin/orionx-tune /opt/orionx/scripts/awareness/orionx-tune
    f /opt/orionx/scripts/awareness/deck_vitals.py; f /opt/orionx/scripts/awareness/tuning_lib.py
    f /opt/orionx/theme/wallpapers/orionx-wp-neon.png
    f /usr/share/themes/Orion-X-Cyberdeck-Green/index.theme
    x /opt/orionx/venv/re/bin/capa; l /usr/bin/capa /opt/orionx/venv/re/bin/capa
    x /opt/orionx/venv/comms/bin/matrix-commander; l /usr/local/bin/matrix-commander /opt/orionx/venv/comms/bin/matrix-commander
    x /opt/orionx/venv/forensics/bin/vol; l /usr/local/bin/vol /opt/orionx/venv/forensics/bin/vol
    f /opt/orionx/venv/forensics/pyvenv.cfg 'home = /usr/bin'
    f /opt/orionx/venv/forensics/lib/python3.13/site-packages/volatility3/__init__.py
    x /usr/bin/tcpdump; x /usr/bin/binwalk; x /usr/bin/x86_64-linux-gnu-strings; l /usr/bin/strings x86_64-linux-gnu-strings
    x /usr/bin/espeak-ng; x /usr/bin/pacat; l /usr/bin/paplay pacat
    x /opt/zeek/bin/zeek; l /usr/bin/zeek /opt/zeek/bin/zeek
    x /opt/orionx/scripts/rain/orionx-scanwatch; l /usr/bin/orionx-scanwatch /opt/orionx/scripts/rain/orionx-scanwatch
    f /opt/orionx/osint/godseye/app/index.html; f /opt/orionx/osint/godseye/LICENSE.cesium
    f /opt/orionx/nucleotide/lookup.json '{"a":1}'; f /opt/orionx/nucleotide/BUILD_INFO 'templates_commit=4907f7865cd95540bee7ba9c8919273edcefe4df'
    x /opt/orionx/scripts/pivotglass/ap; l /usr/bin/ap /opt/orionx/scripts/pivotglass/ap
    x /opt/orionx/scripts/rain/orionx-rain; l /usr/bin/orionx-rain /opt/orionx/scripts/rain/orionx-rain
    f /etc/xdg/autostart/orionx-rain.desktop
    x /opt/orionx/scripts/music/orionx-music; l /usr/bin/orionx-music /opt/orionx/scripts/music/orionx-music
    for k in forensics pivotglass re comms; do f "/usr/share/orionx/pip/$k.txt"; done
}
run_lib() {  # $1 = image root; prints the gate's PASS/FAIL lines; sets RP_FAIL
    ( PASS=0; FAIL=0; SQF="$1"
      pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
      fail() { FAIL=$((FAIL+1)); echo "FAIL: $1 :: ${2:-}"; }
      # shellcheck disable=SC1090
      . "$LIB"; assert_release_promises; echo "COUNTS $PASS $FAIL" )
}

echo "[section 37 against a complete image]"
mk_image "$S/good"
OUT="$(run_lib "$S/good")"
read -r _ P F <<<"$(grep '^COUNTS' <<<"$OUT")"
[[ "$F" == 0 && "$P" -ge 45 ]] && tpass "complete image: $P checks pass, 0 fail" || tfail "complete image" "$(grep '^FAIL' <<<"$OUT")"

expect_fail() {  # <label> <check id prefix> <mutation command...>
    local label="$1" id="$2"; shift 2
    mk_image "$S/m"; ( cd "$S/m" && "$@" )
    local out; out="$(run_lib "$S/m")"
    grep -q "^FAIL: $id" <<<"$out" && tpass "$label -> FAIL $id" || tfail "$label" "no FAIL $id: $(grep '^FAIL' <<<"$out" | head -2)"
}
expect_fail "gnome-keyring removed by a trim" 37a sed -i.bak 's/^Package: gnome-keyring$/Package: gone/' var/lib/dpkg/status
expect_fail "mesh-status timer not enabled" 37b rm etc/systemd/system/timers.target.wants/orionx-mesh-status.timer
expect_fail "threshold-file back under /etc" 37c sh -c 'echo "threshold-file: /etc/suricata/orionx-threshold.config" > etc/suricata/orionx.yaml'
expect_fail "retired matrix-synapse-orionx.service ships" 37d sh -c 'mkdir -p usr/share/orionx/systemd && touch usr/share/orionx/systemd/matrix-synapse-orionx.service'
expect_fail "Synapse drop-in runs system python" 37d sh -c 'printf "ExecStart=\nExecStart=/usr/bin/python3 -m synapse.app.homeserver\n" > etc/systemd/system/matrix-synapse.service.d/orionx.conf'
expect_fail "Workbench renamed back" 37f sh -c 'echo "Name=OSINT" > usr/share/applications/orionx-osint.desktop'
expect_fail "orionx-tune link dangles" 37g rm opt/orionx/scripts/awareness/orionx-tune
expect_fail "vol back in system Python" 37m sh -c 'rm usr/local/bin/vol && printf "#!/bin/sh\n" > usr/local/bin/vol && chmod +x usr/local/bin/vol'
expect_fail "venv without volatility3" 37m rm -r opt/orionx/venv/forensics/lib
expect_fail "tcpdump trimmed" 37n rm usr/bin/tcpdump
expect_fail "strings link dangles (binutils purged)" 37n rm usr/bin/x86_64-linux-gnu-strings
expect_fail "zeek soft-failed" 37o rm -r opt/zeek
expect_fail "nucleotide lookup empty" 37r sh -c ': > opt/orionx/nucleotide/lookup.json'
expect_fail "Cesium licence missing" 37q rm opt/orionx/osint/godseye/LICENSE.cesium
expect_fail "radare2 shipped after all" 37w sh -c 'printf "Package: radare2\nStatus: install ok installed\n\n" >> var/lib/dpkg/status'
expect_fail "light-locker binary back" 37w sh -c 'printf "#!/bin/sh\n" > usr/bin/light-locker'

echo "[symlinks resolve inside the image, never on the host]"
mk_image "$S/h"; rm -r "$S/h/opt/zeek"; ln -sfn /bin/sh "$S/h/usr/bin/zeek"   # /bin/sh exists on the HOST
grep -q "^FAIL: 37o" <<<"$(run_lib "$S/h")" && tpass "a link to a host-only path fails (no false PASS from the host)" || tfail "host leak" "absolute link resolved on the host"

echo "[gate self-check: unique section numbers; every section reads the image]"
bash "$GATE" --self-check >/dev/null 2>&1 && tpass "the gate passes its own self-check" || tfail "self-check" "$(bash "$GATE" --self-check 2>&1)"
cp "$GATE" "$S/dup.sh"; mkdir -p "$S/lib"; cp "$LIB" "$S/lib/"
printf '\nsection "36. a duplicate number"\necho "$SQF"\n' >> "$S/dup.sh"
bash "$S/dup.sh" --self-check >/dev/null 2>&1 && tfail "duplicate section" "accepted" || tpass "a duplicate section number fails the self-check"
cp "$GATE" "$S/src.sh"
printf '\nsection "38. source only"\ngrep -q x "$REPO_ROOT/README.md"\n' >> "$S/src.sh"
bash "$S/src.sh" --self-check >/dev/null 2>&1 && tfail "source-only section" "accepted" || tpass "a section that never reads the image fails the self-check"
grep -q 'ORIONX_RELEASE_GATE:-0}" == "1" && $SKIP -gt 0' "$GATE" && tpass "ORIONX_RELEASE_GATE=1 turns any SKIP into a failing exit" || tfail "release gate" "no SKIP rule"
grep -nE 'pass "[^"]*(skipped|informational only)' "$GATE" >/dev/null && tfail "PASS on missing evidence" "$(grep -nE 'pass "[^"]*(skipped|informational only)' "$GATE" | head -3)" \
    || tpass "no check records PASS for a skipped or 'informational' branch (F-05)"

# The content-presence suite must source this library BEFORE the first section
# that calls its helpers (v3.0.0 gate: sourced at section 37, used at 32).
_cp="$REPO_ROOT/tests/integration/test-iso-content-presence.sh"
_src_ln="$(grep -nE '^\. "\$SCRIPT_DIR/lib/release-promises.sh"' "$_cp" | head -1 | cut -d: -f1)"
_use_ln="$(grep -nE 'sqf_resolve|dpkg_state|assert_release_promises' "$_cp" | grep -vE '^[0-9]+:\s*#' | grep -v 'release-promises.sh' | head -1 | cut -d: -f1)"
if [[ -n "$_src_ln" && -n "$_use_ln" && "$_src_ln" -lt "$_use_ln" ]]; then pass "content-presence sources the helper library (line $_src_ln) before its first use (line $_use_ln)"; else fail "helper library sourced before use" "source=$_src_ln first use=$_use_ln"; fi
echo; echo "Results: $T_PASS passed, $T_FAIL failed"
[[ $T_FAIL -eq 0 ]]
