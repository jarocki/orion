# shellcheck shell=bash
# release-promises.sh — section 37 of test-iso-content-presence.sh: what the
# README and the rc5-rc9 CHANGELOG promise, asserted against the squashfs.
#
# @decision DEC-PHASE12-119
# @title The ISO gate asserts every promise against the image, and missing
#   evidence is a FAIL
# @status accepted
# @rationale QA round 1 found the content-presence gate asserted none of the
#   rc5-rc9 promises (F-04: gnome-keyring, the mesh-status timer, the
#   threshold file, Synapse's venv, the Workbench, orionx-tune, deck_vitals,
#   tuning_lib, Neon, the green theme: 0 matches each) and 16 README tools
#   (P1-4: vol, tcpdump, binwalk, strings, scanwatch, espeak/paplay, zeek,
#   godseye, nucleotide, pivotglass, rain, music: 0 matches each). Every check
#   here reads $SQF only. Symlinks are resolved INSIDE the squashfs root
#   (an absolute link like /usr/bin/zeek -> /opt/zeek/bin/zeek would
#   otherwise be tested against the host). Sourced, so it can be unit-tested
#   against a synthetic tree (tests/unit/test_release_promises.sh) without an
#   ISO. Requires the caller's pass/fail functions and $SQF.

# sqf_resolve <path-in-image>: print the in-image path a link chain ends at,
# or nothing if it dangles or loops (10 hops).
sqf_resolve() {
    local p="$1" hops=0 t
    while [[ -L "$SQF$p" ]]; do
        hops=$((hops + 1)); [[ $hops -gt 10 ]] && return 1
        t="$(readlink "$SQF$p")"
        case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    done
    [[ -e "$SQF$p" ]] || return 1
    printf '%s\n' "$p"
}

# dpkg_state <package>: the Status: line value from the image's dpkg db, or empty.
dpkg_state() {
    awk -v pkg="$1" '
        /^Package: / { cur = $2 }
        /^Status: / && cur == pkg { sub(/^Status: /, ""); print; exit }
    ' "$SQF/var/lib/dpkg/status" 2>/dev/null
}

_rp_exec() {  # <id> <label> <in-image path>: path resolves to an executable regular file
    local id="$1" label="$2" path="$3" r
    if r="$(sqf_resolve "$path")" && [[ -f "$SQF$r" && -x "$SQF$r" ]]; then
        pass "$id: $label ($path${r:+ -> $r})"
    else
        fail "$id: $label" "$path is missing, dangling, or not executable in the squashfs"
    fi
}
_rp_file() {  # <id> <label> <in-image path>: non-empty regular file
    local id="$1" label="$2" path="$3"
    if [[ -s "$SQF$path" ]]; then pass "$id: $label ($path)"
    else fail "$id: $label" "$path is missing or empty in the squashfs"; fi
}
_rp_installed() {  # <id> <package>
    local st; st="$(dpkg_state "$2")"
    if [[ "$st" == "install ok installed" ]]; then pass "$1: dpkg: $2 installed"
    else fail "$1: dpkg: $2 installed" "Status: ${st:-<not in var/lib/dpkg/status>}"; fi
}
_rp_absent_pkg() {  # <id> <package>
    local st; st="$(dpkg_state "$2")"
    if [[ "$st" != "install ok installed" ]]; then pass "$1: dpkg: $2 NOT installed (README says it is not shipped)"
    else fail "$1: dpkg: $2 NOT installed" "README says $2 is not on the image, but dpkg has it installed"; fi
}

assert_release_promises() {
    [[ -n "${SQF:-}" && -d "$SQF" ]] || { fail "37: squashfs root" "SQF unset or not a directory"; return 0; }

    # --- rc5-rc9 deck fixes (CHANGELOG rc9 "verified on the deck") -----------
    _rp_installed 37a gnome-keyring
    local tl="/etc/systemd/system/timers.target.wants/orionx-mesh-status.timer" r
    if [[ -L "$SQF$tl" ]] && r="$(sqf_resolve "$tl")"; then pass "37b: orionx-mesh-status.timer enabled ($tl -> $r)"
    else fail "37b: orionx-mesh-status.timer enabled" "$tl missing or dangling"; fi
    _rp_file 37c "Suricata threshold file where postured may write" /var/lib/suricata/orionx-threshold.config
    if grep -qx 'threshold-file: /var/lib/suricata/orionx-threshold.config' "$SQF/etc/suricata/orionx.yaml" 2>/dev/null; then
        pass "37c: orionx.yaml points threshold-file at /var/lib/suricata/orionx-threshold.config"
    else
        fail "37c: orionx.yaml threshold-file path" "no 'threshold-file: /var/lib/suricata/orionx-threshold.config' line in /etc/suricata/orionx.yaml"
    fi

    # Synapse (lead ruling, round 1): the package unit is the authority; the
    # repo's own matrix-synapse-orionx.service is retired. Synapse is an
    # optional install, so only assert what the image ships.
    local u
    if [[ -e "$SQF/usr/share/orionx/systemd/matrix-synapse-orionx.service" || -e "$SQF/etc/systemd/system/matrix-synapse-orionx.service" || -e "$SQF/usr/lib/systemd/system/matrix-synapse-orionx.service" ]]; then
        fail "37d: matrix-synapse-orionx.service absent" "a second Synapse unit authority ships; the package unit + drop-in is the authority"
    else
        pass "37d: matrix-synapse-orionx.service absent (package unit is the authority)"
    fi
    local dropins=0 badexec=""
    for u in "$SQF"/etc/systemd/system/matrix-synapse.service.d/*.conf; do
        [[ -f "$u" ]] || continue
        dropins=$((dropins + 1))
        while IFS= read -r line; do
            [[ "$line" == "ExecStart=" ]] && continue
            [[ "$line" == ExecStart=/opt/venvs/matrix-synapse/bin/python* ]] || badexec="$badexec ${u##*/}:${line}"
        done < <(grep -E '^ExecStart=' "$u")
    done
    if [[ -z "$badexec" ]]; then pass "37d: every matrix-synapse.service.d ExecStart uses /opt/venvs/matrix-synapse/bin/python ($dropins drop-in(s))"
    else fail "37d: Synapse drop-in ExecStart uses the venv python" "$badexec"; fi

    if grep -qx 'Exec=/usr/bin/orionx-cockpit --tab network' "$SQF/usr/share/applications/orionx-control-center.desktop" 2>/dev/null; then
        pass "37e: Control Center menu entry opens the Cockpit network tab"
    else fail "37e: orionx-control-center.desktop Exec=/usr/bin/orionx-cockpit --tab network" "Exec line missing or different"; fi
    if grep -qx 'Name=Orion Workbench' "$SQF/usr/share/applications/orionx-osint.desktop" 2>/dev/null; then
        pass "37f: orionx-osint.desktop is the Orion Workbench"
    else fail "37f: orionx-osint.desktop Name=Orion Workbench" "Name line missing or different"; fi
    if [[ "$(sqf_resolve /usr/bin/orionx-tune)" == /opt/orionx/scripts/awareness/orionx-tune && -x "$SQF/opt/orionx/scripts/awareness/orionx-tune" ]]; then
        pass "37g: /usr/bin/orionx-tune -> /opt/orionx/scripts/awareness/orionx-tune (executable)"
    else fail "37g: orionx-tune on PATH" "/usr/bin/orionx-tune does not resolve to the awareness script"; fi
    _rp_file 37h "deck_vitals.py" /opt/orionx/scripts/awareness/deck_vitals.py
    _rp_file 37h "tuning_lib.py" /opt/orionx/scripts/awareness/tuning_lib.py
    _rp_file 37i "Neon wallpaper" /opt/orionx/theme/wallpapers/orionx-wp-neon.png
    if [[ -d "$SQF/usr/share/themes/Orion-X-Cyberdeck-Green" ]] && [[ -n "$(ls -A "$SQF/usr/share/themes/Orion-X-Cyberdeck-Green" 2>/dev/null)" ]]; then
        pass "37j: green GTK theme Orion-X-Cyberdeck-Green ships (non-empty)"
    else fail "37j: Orion-X-Cyberdeck-Green theme" "missing or empty"; fi

    # --- README "What's on the ISO" tools (P1-4) ------------------------------
    _rp_exec 37k "capa (venv) on PATH" /usr/bin/capa
    _rp_exec 37l "matrix-commander (venv) on PATH" /usr/local/bin/matrix-commander
    local vt; vt="$(sqf_resolve /usr/local/bin/vol || true)"
    if [[ "$vt" == /opt/orionx/venv/forensics/* && -x "$SQF$vt" ]]; then
        pass "37m: /usr/local/bin/vol resolves into the forensics venv ($vt)"
    else fail "37m: /usr/local/bin/vol resolves into /opt/orionx/venv/forensics" "resolves to '${vt:-<nothing>}' (DEC-PHASE12-116)"; fi
    local volpkg
    volpkg="$(find "$SQF/opt/orionx/venv/forensics/lib" -maxdepth 4 -path '*/site-packages/volatility3/__init__.py' 2>/dev/null | head -1)"
    if [[ $EUID -eq 0 ]] && command -v chroot >/dev/null 2>&1 && [[ -x "$SQF/opt/orionx/venv/forensics/bin/python" ]]; then
        if chroot "$SQF" /opt/orionx/venv/forensics/bin/python -c 'import volatility3' >/dev/null 2>&1; then
            pass "37m: forensics venv python imports volatility3 (run in the image via chroot)"
        else fail "37m: forensics venv python imports volatility3" "chroot import failed"; fi
    elif [[ -n "$volpkg" ]] && grep -q '^home = /usr/bin' "$SQF/opt/orionx/venv/forensics/pyvenv.cfg" 2>/dev/null; then
        pass "37m: volatility3 package in the forensics venv site-packages, venv bound to /usr/bin python (not root: import not executed)"
    else fail "37m: forensics venv can import volatility3" "no volatility3 package in the venv, or pyvenv.cfg not bound to /usr/bin"; fi
    _rp_exec 37n "tcpdump" /usr/bin/tcpdump
    _rp_exec 37n "binwalk" /usr/bin/binwalk
    _rp_exec 37n "strings (binutils)" /usr/bin/strings
    _rp_exec 37n "espeak-ng (R.A.I.N. fallback voice)" /usr/bin/espeak-ng
    _rp_exec 37n "paplay (R.A.I.N. audio)" /usr/bin/paplay
    _rp_exec 37o "zeek (OBS zeek-core)" /usr/bin/zeek
    _rp_exec 37p "orionx-scanwatch" /usr/bin/orionx-scanwatch
    _rp_file 37q "GODSEYE app" /opt/orionx/osint/godseye/app/index.html
    _rp_file 37q "CesiumJS licence (DEC-PHASE12-124)" /opt/orionx/osint/godseye/LICENSE.cesium
    _rp_file 37r "nucleotide prebuilt lookup.json" /opt/orionx/nucleotide/lookup.json
    if grep -qE '^templates_commit=[0-9a-f]{7,40}$' "$SQF/opt/orionx/nucleotide/BUILD_INFO" 2>/dev/null; then
        pass "37r: nucleotide BUILD_INFO records the templates commit"
    else fail "37r: nucleotide BUILD_INFO templates_commit" "missing or 'unknown'"; fi
    _rp_exec 37s "Pivotglass (ap)" /usr/bin/ap
    _rp_exec 37t "R.A.I.N. (orionx-rain)" /usr/bin/orionx-rain
    _rp_file 37t "R.A.I.N. autostart" /etc/xdg/autostart/orionx-rain.desktop
    _rp_exec 37u "DJ Deck (orionx-music)" /usr/bin/orionx-music
    local lk
    for lk in forensics pivotglass re comms; do
        _rp_file 37v "pip lock $lk.txt ships (record of what was installed)" "/usr/share/orionx/pip/$lk.txt"
    done

    # --- README "not on the image" claims ------------------------------------
    _rp_absent_pkg 37w radare2
    _rp_absent_pkg 37w bulk-extractor
    _rp_absent_pkg 37w nikto
    _rp_absent_pkg 37w light-locker
    local b
    for b in /usr/bin/radare2 /usr/bin/r2 /usr/bin/bulk_extractor /usr/bin/nikto /usr/bin/light-locker; do
        if [[ -e "$SQF$b" || -L "$SQF$b" ]]; then fail "37w: $b absent" "present in the image although the README says it is not shipped"
        else pass "37w: $b absent"; fi
    done
}
