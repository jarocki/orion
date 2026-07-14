#!/usr/bin/env bash
# shellcheck shell=bash
#
# Integration test: verify Orion-X application content is present in the ISO.
#
# @decision DEC-PHASE8-006
# @title Host-side squashfs extraction test for ISO application content
# @status accepted
# @rationale Issue #43 root cause: the ISO was built without staging Orion-X
#   application content. This test is the active gate that proves the fix
#   works end-to-end: it extracts the squashfs from the built ISO and asserts
#   that every canonical path from stage_application_content() and
#   0700-orionx-setup.hook.chroot is present in the filesystem image.
#   Running after ISO build (in CI) and before QEMU boot tests ensures the
#   content gap is caught at build time, not discovered at boot time.
#   Tools required: xorriso + unsquashfs (squashfs-tools). Both are already
#   installed in the CI debian:bullseye ISO-build step.
#
# Usage:
#   bash tests/integration/test-iso-content-presence.sh [path/to/orionx.iso]
#
# Default ISO path: output/orionx-phoenix-edition-v2.0.0-rc9.iso (positional arg $1 overrides)
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed or prerequisites missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISO_PATH="${1:-$REPO_ROOT/output/orionx-phoenix-edition-v2.0.0-rc9.iso}"
WORK=""

# ---------------------------------------------------------------------------
# Test counters
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    NC=""
fi

pass() {
    ((PASS+=1))
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    ((FAIL+=1))
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

section() {
    echo ""
    echo "--- $1 ---"
}

# shellcheck disable=SC2329  # cleanup is invoked indirectly via trap EXIT
cleanup() {
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

echo "=== W8-content-staging: ISO Content Presence Integration Test ==="
echo "    ISO: $ISO_PATH"

# ===========================================================================
# 0. Prerequisites
# ===========================================================================
section "Prerequisites"

if [[ ! -f "$ISO_PATH" ]]; then
    echo "${RED}FATAL${NC}: ISO not found at $ISO_PATH"
    echo "       Build the ISO first: bash scripts/build-iso.sh"
    echo "       Or pass the ISO path as an argument: $0 /path/to/orionx.iso"
    exit 1
fi
echo "  ISO found: $ISO_PATH ($(du -sh "$ISO_PATH" | cut -f1))"

for tool in xorriso unsquashfs; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "${RED}FATAL${NC}: Required tool not found: $tool"
        echo "       Install with: sudo apt-get install -y xorriso squashfs-tools"
        exit 1
    fi
done
echo "  Tools available: xorriso, unsquashfs"

# ===========================================================================
# 1. Extract squashfs from ISO
# ===========================================================================
section "Extracting squashfs from ISO"

WORK="$(mktemp -d)"
echo "  Working directory: $WORK"

echo "  Extracting /live/filesystem.squashfs from ISO..."
xorriso -osirrox on -indev "$ISO_PATH" \
    -extract /live/filesystem.squashfs "$WORK/squashfs.img" \
    2>/dev/null

if [[ ! -f "$WORK/squashfs.img" ]]; then
    echo "${RED}FATAL${NC}: squashfs extraction failed — $WORK/squashfs.img not created"
    exit 1
fi
echo "  squashfs.img extracted: $(du -sh "$WORK/squashfs.img" | cut -f1)"

echo "  Extracting full squashfs filesystem..."
# @decision DEC-PHASE9-012
# @title Full squashfs extraction replaces selective path extraction
# @status accepted
# @rationale W9-1b iter-2: the previous selective extraction listed only a handful of
#   paths at build time. As rc4 added new assertions (dpkg/status for package checks,
#   /etc/lightdm for autologin config) without adding those paths to the extraction
#   list, the fallback per-assertion re-extractions (unsquashfs into an already-existing
#   destination) silently produced incomplete trees because unsquashfs refuses to
#   extract into a pre-existing directory without --force. Result: every new assertion
#   beyond the original list produced a spurious FAIL even though the packages and files
#   ARE present in the squashfs (proven by nm-applet.desktop PASS in CI run 26554366937).
#   Full extraction eliminates the entire class of "path not in extract list" bugs.
#   GitHub Actions ubuntu-latest runners have ~20 GB free; a 2-3 GB uncompressed
#   squashfs adds ~25s of extraction time, which is acceptable for test correctness.
#   Every future assertion automatically works without a matching extraction list entry.
unsquashfs -d "$WORK/sqfs" "$WORK/squashfs.img" \
    2>/dev/null || true  # unsquashfs may exit non-zero on minor warnings; we assert individually

echo "  Full extraction complete."

SQF="$WORK/sqfs"

# ===========================================================================
# 2. Application scripts
# ===========================================================================
section "Application scripts: /opt/orionx/scripts/"

if [[ -d "$SQF/opt/orionx/scripts" ]]; then
    pass "/opt/orionx/scripts/ directory present"
else
    fail "/opt/orionx/scripts/ directory present" "stage_application_content did not stage scripts/"
fi

for script in \
    "setup-matrix.sh" \
    "setup-wireguard.sh" \
    "artifact-analyzer.py" \
    "storyboard-gen.py" \
    "toggle-theme.sh" \
    "run-lynis.sh" \
    "download-samples.sh"; do
    if [[ -f "$SQF/opt/orionx/scripts/$script" ]]; then
        pass "/opt/orionx/scripts/$script present"
    else
        fail "/opt/orionx/scripts/$script present" \
             "Script missing from staged ISO filesystem"
    fi
done

# Mesh CLI lives in the mesh/ subdirectory
if [[ -f "$SQF/opt/orionx/scripts/mesh/orionx-mesh" ]]; then
    pass "/opt/orionx/scripts/mesh/orionx-mesh present"
else
    fail "/opt/orionx/scripts/mesh/orionx-mesh present" \
         "Mesh CLI missing from staged ISO filesystem"
fi

# ===========================================================================
# 3. Theme directory (wallpapers dir must exist and be non-empty)
# ===========================================================================
section "Theme: /opt/orionx/theme/"

if [[ -d "$SQF/opt/orionx/theme" ]]; then
    pass "/opt/orionx/theme/ directory present"
else
    fail "/opt/orionx/theme/ directory present" "stage_application_content did not stage theme/"
fi

# Assert the wallpapers dir exists and contains at least one entry (.gitkeep,
# README.txt, or future wallpaper assets all satisfy this).  The specific
# placeholder file varies depending on whether the wallpapers dir was empty at
# rsync time, so we check presence + non-emptiness rather than a specific name.
if [[ -d "$SQF/opt/orionx/theme/wallpapers" ]] && \
   [[ -n "$(ls -A "$SQF/opt/orionx/theme/wallpapers" 2>/dev/null)" ]]; then
    pass "/opt/orionx/theme/wallpapers/ exists and is non-empty (placeholder or assets)"
else
    fail "/opt/orionx/theme/wallpapers/ missing or empty" \
         "Wallpapers dir absent or empty — stage_application_content did not stage theme/wallpapers/"
fi

# ===========================================================================
# 4. Sample data
# ===========================================================================
section "Sample data: /opt/orionx/data/"

if [[ -d "$SQF/opt/orionx/data/samples" ]]; then
    pass "/opt/orionx/data/samples/ directory present"
else
    fail "/opt/orionx/data/samples/ directory present" "stage_application_content did not stage data/"
fi

# ===========================================================================
# 5. Documentation
# ===========================================================================
section "Documentation: /usr/share/doc/orionx/"

if [[ -d "$SQF/usr/share/doc/orionx" ]]; then
    pass "/usr/share/doc/orionx/ directory present"
else
    fail "/usr/share/doc/orionx/ directory present" "stage_application_content did not stage docs/"
fi

if [[ -f "$SQF/usr/share/doc/orionx/User_Guide.md" ]]; then
    pass "/usr/share/doc/orionx/User_Guide.md present"
else
    fail "/usr/share/doc/orionx/User_Guide.md present" \
         "User Guide missing from staged ISO docs"
fi

# ===========================================================================
# 6. PATH symlinks (created by 0700-orionx-setup.hook.chroot)
# ===========================================================================
section "PATH symlinks: /usr/bin/ (created by 0700 hook)"

for symlink in \
    "orionx-mesh" \
    "setup-matrix.sh" \
    "setup-wireguard.sh" \
    "artifact-analyzer.py" \
    "storyboard-gen.py" \
    "toggle-theme.sh" \
    "run-lynis.sh" \
    "download-samples.sh"; do
    if [[ -L "$SQF/usr/bin/$symlink" ]]; then
        pass "/usr/bin/$symlink symlink present"
    elif [[ -f "$SQF/usr/bin/$symlink" ]]; then
        # Accept a regular file too (some build toolchains dereference symlinks)
        pass "/usr/bin/$symlink present (as regular file)"
    else
        fail "/usr/bin/$symlink symlink present" \
             "PATH symlink missing — 0700-orionx-setup.hook.chroot did not run or failed"
    fi
done

# ===========================================================================
# 7. XDG desktop entries (created by 0700-orionx-setup.hook.chroot)
# ===========================================================================
section "XDG desktop entries: /usr/share/applications/"

if [[ -d "$SQF/usr/share/applications" ]]; then
    pass "/usr/share/applications/ directory present"
else
    fail "/usr/share/applications/ directory present" \
         "0700-orionx-setup.hook.chroot did not create applications dir"
fi

if [[ -f "$SQF/usr/share/applications/orionx-mesh.desktop" ]]; then
    pass "/usr/share/applications/orionx-mesh.desktop present"
else
    fail "/usr/share/applications/orionx-mesh.desktop present" \
         "orionx-mesh XDG entry missing"
fi

# ===========================================================================
# 8. rc4 broken-basics: GUI networking packages in chroot package set
#    These assertions verify that NM/nm-applet/wpasupplicant/iw/firmware
#    packages were installed into the squashfs by the live-build package step.
#    We check for the dpkg status database or installed binary/lib paths.
# ===========================================================================
section "rc4: GUI networking packages (NM, nm-applet, wpasupplicant, iw, firmware)"

DPKG_STATUS="$SQF/var/lib/dpkg/status"

for pkg in network-manager network-manager-gnome wpasupplicant iw \
           firmware-iwlwifi firmware-realtek firmware-atheros firmware-misc-nonfree; do
    if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: $pkg$" "$DPKG_STATUS" 2>/dev/null; then
        pass "package installed in chroot: $pkg"
    elif [[ -f "$SQF/usr/sbin/NetworkManager" && "$pkg" == "network-manager" ]]; then
        pass "package installed in chroot: $pkg (binary present)"
    elif [[ -f "$SQF/usr/bin/nm-applet" && "$pkg" == "network-manager-gnome" ]]; then
        pass "package installed in chroot: $pkg (binary present)"
    elif [[ -f "$SQF/usr/sbin/wpa_supplicant" && "$pkg" == "wpasupplicant" ]]; then
        pass "package installed in chroot: $pkg (binary present)"
    elif [[ -f "$SQF/usr/sbin/iw" && "$pkg" == "iw" ]]; then
        pass "package installed in chroot: $pkg (binary present)"
    else
        fail "package installed in chroot: $pkg" \
             "Check orionx.list.chroot includes $pkg and non-free archive area is enabled"
    fi
done

# nm-applet autostart desktop file (shipped by network-manager-gnome)
if [[ -f "$SQF/etc/xdg/autostart/nm-applet.desktop" ]]; then
    pass "/etc/xdg/autostart/nm-applet.desktop present (nm-applet autostarts in XFCE)"
else
    fail "/etc/xdg/autostart/nm-applet.desktop present" \
         "network-manager-gnome should ship this file; XFCE uses it to autostart nm-applet"
fi

# ===========================================================================
# 9. rc4 broken-basics: LightDM autologin config present
# ===========================================================================
section "rc4: LightDM autologin configuration"

AUTOLOGIN_CONF="$SQF/etc/lightdm/lightdm.conf.d/10-orionx-autologin.conf"
if [[ -f "$AUTOLOGIN_CONF" ]]; then
    pass "/etc/lightdm/lightdm.conf.d/10-orionx-autologin.conf present"
    if grep -q "autologin-user=orionx" "$AUTOLOGIN_CONF" 2>/dev/null; then
        pass "autologin-user=orionx set in LightDM config"
    else
        fail "autologin-user=orionx set in LightDM config" \
             "Check 10-orionx-autologin.conf contains autologin-user=orionx"
    fi
    if grep -q "autologin-user-timeout=0" "$AUTOLOGIN_CONF" 2>/dev/null; then
        pass "autologin-user-timeout=0 set in LightDM config"
    else
        fail "autologin-user-timeout=0 set in LightDM config" \
             "Check 10-orionx-autologin.conf contains autologin-user-timeout=0"
    fi
else
    fail "/etc/lightdm/lightdm.conf.d/10-orionx-autologin.conf present" \
         "Autologin config missing — includes.chroot/etc/lightdm/ not staged"
fi

# ===========================================================================
# 10. rc4 broken-basics: Phoenix wallpaper staged + xfconf backdrop config
# ===========================================================================
section "rc4: Phoenix wallpaper staged and xfconf backdrop configured"

# Wallpaper asset (staged by stage_application_content from theme/wallpapers/)
if [[ -f "$SQF/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png" ]]; then
    pass "/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png staged"
else
    fail "/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png staged" \
         "Phoenix wallpaper asset missing — check theme/wallpapers/ in repo and stage_application_content"
fi

# xfconf desktop XML set by 0100-create-user.hook.chroot in /home/orionx
XFCONF_XML="$SQF/home/orionx/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
if [[ -f "$XFCONF_XML" ]]; then
    pass "/home/orionx/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml present"
    if grep -q "orionx-phoenix-wallpaper.png" "$XFCONF_XML" 2>/dev/null; then
        pass "xfce4-desktop.xml references orionx-phoenix-wallpaper.png as backdrop"
    else
        fail "xfce4-desktop.xml references orionx-phoenix-wallpaper.png as backdrop" \
             "Check 0100-create-user.hook.chroot xfconf XML block"
    fi
else
    fail "/home/orionx xfce4-desktop.xml present" \
         "XFCE backdrop config missing — 0100-create-user.hook.chroot did not create it"
fi

# ===========================================================================
# 11. rc4 broken-basics: zero lxterminal in .desktop Exec lines
# ===========================================================================
# @decision DEC-PHASE9-014
# @title Neutralise set-e + pipefail silent-exit on zero-match grep in count pipelines
# @status accepted
# @rationale grep exits 1 when it finds no matches. In a `set -euo pipefail`
#   script, a command substitution of the form $(grep ... | wc -l | tr -d ' ')
#   inherits the grep non-zero exit via pipefail, killing the script silently
#   *before* the count variable is ever tested. Zero matches is the DESIRED rc4
#   state for lxterminal — the fix is `|| true` at the end of the pipeline, not
#   disabling pipefail globally. Applied to any grep-count pipeline where a
#   no-match outcome is a legitimate, assertable state. DEC-PHASE9-014.
section "rc4: no lxterminal in .desktop Exec lines"

if [[ -d "$SQF/usr/share/applications" ]]; then
    # || true: grep returns 1 when no matches; in `set -euo pipefail` that kills
    # the script silently before the count is even checked. Zero matches is the
    # desired rc4 state for lxterminal — we WANT the no-match path. DEC-PHASE9-014.
    LXTERMINAL_REFS=$(grep -rl "lxterminal" "$SQF/usr/share/applications/" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [[ "$LXTERMINAL_REFS" -eq 0 ]]; then
        pass "zero .desktop files in /usr/share/applications/ reference lxterminal"
    else
        fail "zero .desktop files in /usr/share/applications/ reference lxterminal" \
             "Found $LXTERMINAL_REFS .desktop file(s) still using lxterminal — fix 0700 hook"
    fi
    # Positive check: orionx .desktop files use xfce4-terminal
    # || true: same pipefail guard — zero xfce4-terminal refs is a fail-case
    # assertion, but we must let the variable populate before we can test it. DEC-PHASE9-014.
    XFCE_TERM_REFS=$(grep -rl "xfce4-terminal" "$SQF/usr/share/applications/" 2>/dev/null | wc -l | tr -d ' ' || true)
    if [[ "$XFCE_TERM_REFS" -gt 0 ]]; then
        pass "orionx .desktop files use xfce4-terminal ($XFCE_TERM_REFS file(s))"
    else
        fail "orionx .desktop files use xfce4-terminal" \
             "No xfce4-terminal Exec lines found in /usr/share/applications/"
    fi
else
    fail "/usr/share/applications/ present for lxterminal check" \
         "applications dir missing from squashfs"
fi

# ===========================================================================
# 12. W9-2a: pcap-analyzer.py staged + symlinked; fail2ban installed
#
# @decision DEC-PHASE9-017: pcap-analyzer.py is the modernized STA PCAP tool
#   staged via the existing scripts/ rsync path (stage_application_content).
# @decision DEC-PHASE9-018: fail2ban replaces gecko/bin/start-denyhosts.sh;
#   enabled by its own package postinst (no custom unit needed).
# ===========================================================================
section "W9-2a: pcap-analyzer.py staged, symlinked; fail2ban installed"

# (a) /opt/orionx/scripts/pcap-analyzer.py staged in chroot
if [[ -f "$SQF/opt/orionx/scripts/pcap-analyzer.py" ]]; then
    pass "/opt/orionx/scripts/pcap-analyzer.py staged in chroot (DEC-PHASE9-017)"
else
    fail "/opt/orionx/scripts/pcap-analyzer.py staged in chroot" \
         "stage_application_content rsyncs scripts/ — ensure pcap-analyzer.py exists in repo scripts/"
fi

# Check executable bit on the staged copy
if [[ -f "$SQF/opt/orionx/scripts/pcap-analyzer.py" ]] && \
   [[ -x "$SQF/opt/orionx/scripts/pcap-analyzer.py" ]]; then
    pass "/opt/orionx/scripts/pcap-analyzer.py is executable in chroot"
else
    fail "/opt/orionx/scripts/pcap-analyzer.py is executable in chroot" \
         "0700 hook sets chmod 755 on all scripts/ files — check hook execution"
fi

# (b) /usr/bin/pcap-analyzer.py symlink present (created by 0700 hook)
if [[ -L "$SQF/usr/bin/pcap-analyzer.py" ]]; then
    pass "/usr/bin/pcap-analyzer.py symlink present in chroot (0700 hook)"
elif [[ -f "$SQF/usr/bin/pcap-analyzer.py" ]]; then
    pass "/usr/bin/pcap-analyzer.py present in chroot (as regular file)"
else
    fail "/usr/bin/pcap-analyzer.py symlink present in chroot" \
         "0700-orionx-setup.hook.chroot SCRIPT_MAP must include pcap-analyzer.py"
fi

# (c) fail2ban installed in chroot (dpkg status or binary fallback)
# || true: grep returns 1 on no-match; under pipefail that kills the script
# before the if-branch is reached. Same guard pattern as section 8. DEC-PHASE9-014.
if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: fail2ban$" "$DPKG_STATUS" 2>/dev/null; then
    pass "package installed in chroot: fail2ban (dpkg status)"
elif [[ -f "$SQF/usr/bin/fail2ban-client" ]]; then
    pass "package installed in chroot: fail2ban (binary present: fail2ban-client)"
elif [[ -f "$SQF/usr/sbin/fail2ban-server" ]]; then
    pass "package installed in chroot: fail2ban (binary present: fail2ban-server)"
else
    fail "package installed in chroot: fail2ban" \
         "fail2ban not found in dpkg/status or as binary — check orionx.list.chroot includes fail2ban"
fi

# ===========================================================================
# 13. File count sanity check (renumbered from 12)
# ===========================================================================
section "File count sanity"

STAGED_COUNT="$(find "$SQF/opt/orionx" "$SQF/usr/share/doc/orionx" -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "  Staged file count: $STAGED_COUNT"
if [[ "$STAGED_COUNT" -gt 20 ]]; then
    pass "staged file count > 20 ($STAGED_COUNT files — application layer is substantive)"
else
    fail "staged file count > 20" \
         "Only $STAGED_COUNT files found — staging likely incomplete"
fi

# ===========================================================================
# 14. W9-2: Orion-X Control Center — GTK app + GTK/genmon packages staged
#
# @decision DEC-PHASE10-005
# @title Control Center ships ahead of Phase 10 Nebula AI; placeholder
#        sections define the plug-in surfaces for W10-1 through W10-6.
# @status accepted
# @rationale stage_application_content rsyncs scripts/ → /opt/orionx/scripts/
#   so the control_center/ module lands in the ISO automatically. The 0700
#   hook creates the /usr/bin/orionx-control-center symlink and copies the
#   .desktop launcher. Package presence is asserted via dpkg/status (same
#   pattern as section 8). DEC-PHASE9-014 pipefail guard applied to any
#   grep-count pipeline.
# ===========================================================================
section "14. W9-2: Control Center — GTK app + GTK/genmon packages staged"

# (a) Entry script staged and executable
if [[ -f "$SQF/opt/orionx/scripts/control_center/orionx-control-center" ]]; then
    pass "/opt/orionx/scripts/control_center/orionx-control-center staged"
else
    fail "/opt/orionx/scripts/control_center/orionx-control-center staged" \
         "stage_application_content must rsync scripts/control_center/ into the ISO"
fi

if [[ -x "$SQF/opt/orionx/scripts/control_center/orionx-control-center" ]]; then
    pass "/opt/orionx/scripts/control_center/orionx-control-center is executable"
else
    fail "/opt/orionx/scripts/control_center/orionx-control-center is executable" \
         "0700 hook sets chmod 755 on scripts/ files — check hook execution"
fi

# (b) Python module present (app.py + at least one section file)
if [[ -f "$SQF/opt/orionx/scripts/control_center/app.py" ]]; then
    pass "/opt/orionx/scripts/control_center/app.py staged"
else
    fail "/opt/orionx/scripts/control_center/app.py staged" \
         "control_center/ Python package must be staged via stage_application_content"
fi

if [[ -f "$SQF/opt/orionx/scripts/control_center/sections/nebula.py" ]]; then
    pass "/opt/orionx/scripts/control_center/sections/nebula.py staged"
else
    fail "/opt/orionx/scripts/control_center/sections/nebula.py staged" \
         "control_center/sections/ not fully staged — check rsync in stage_application_content"
fi

# (c) /usr/bin/orionx-control-center symlink present (created by 0700 hook)
if [[ -L "$SQF/usr/bin/orionx-control-center" ]]; then
    pass "/usr/bin/orionx-control-center symlink present (0700 hook)"
elif [[ -f "$SQF/usr/bin/orionx-control-center" ]]; then
    pass "/usr/bin/orionx-control-center present (as regular file, 0700 hook)"
else
    fail "/usr/bin/orionx-control-center symlink present" \
         "0700-orionx-setup.hook.chroot SCRIPT_MAP must include orionx-control-center"
fi

# (d) .desktop launcher present
if [[ -f "$SQF/usr/share/applications/orionx-control-center.desktop" ]]; then
    pass "/usr/share/applications/orionx-control-center.desktop present"
else
    fail "/usr/share/applications/orionx-control-center.desktop present" \
         "0700 hook must create /usr/share/applications/orionx-control-center.desktop"
fi

# (e) .desktop Exec line must point to /usr/bin/orionx-control-center
#     (DEC-PHASE9-006 invariant: no lxterminal, direct GTK executable)
CONTROL_DESKTOP="$SQF/usr/share/applications/orionx-control-center.desktop"
if [[ -f "$CONTROL_DESKTOP" ]]; then
    if grep -qE "^Exec=/usr/bin/orionx-control-center" "$CONTROL_DESKTOP" 2>/dev/null; then
        pass ".desktop Exec line is Exec=/usr/bin/orionx-control-center (DEC-PHASE9-006)"
    else
        fail ".desktop Exec line is Exec=/usr/bin/orionx-control-center" \
             "Check orionx-control-center.desktop Exec line — must be direct GTK exec (no lxterminal)"
    fi
    # DEC-PHASE9-006: no lxterminal in the Exec line
    # || true: DEC-PHASE9-014 — grep exits 1 on no-match; under pipefail this kills
    # the script before the count is tested. Zero matches is the desired state.
    LXTERM_IN_DESKTOP="$(grep -c "lxterminal" "$CONTROL_DESKTOP" 2>/dev/null || true)"
    if [[ "$LXTERM_IN_DESKTOP" -eq 0 ]]; then
        pass ".desktop has zero lxterminal references (DEC-PHASE9-006 invariant)"
    else
        fail ".desktop has zero lxterminal references" \
             "Found $LXTERM_IN_DESKTOP lxterminal reference(s) — violates DEC-PHASE9-006"
    fi
fi

# (f) GTK / GI / genmon packages installed in chroot dpkg
#     Same dpkg/status + binary-fallback pattern as section 8. DEC-PHASE9-014
#     pipefail guard not needed here because we use grep -q (no pipe).
for gtk_pkg in python3-gi gir1.2-gtk-3.0 gir1.2-glib-2.0 xfce4-genmon-plugin; do
    if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: ${gtk_pkg}$" "$DPKG_STATUS" 2>/dev/null; then
        pass "package installed in chroot: $gtk_pkg (dpkg status, DEC-PHASE10-005)"
    else
        fail "package installed in chroot: $gtk_pkg" \
             "Check orionx.list.chroot includes $gtk_pkg (W9-2 GTK dependency)"
    fi
done

# ===========================================================================
# 15. W10-1 — Nebula runtime: model + manifest + ollama + units staged
#
# @decision DEC-PHASE10-007
# @title ollama .deb staging: fail-LOUD on fetch/verify failure (build-time gate)
# @status accepted
# @rationale ollama is installed via 0500-install-external-tools.hook.chroot during
#   the chroot build phase. Absent = nebula-runtime.service never starts = red badge.
#
# @decision DEC-PHASE10-008
# @title stage_nebula_model: HF download + SHA-256 verify + MANIFEST generation
# @status accepted
# @rationale stage_nebula_model() downloads the bundled model GGUF (W11-1:
#   Qwen2.5-3B-Instruct Q4_K_M per DEC-PHASE11-002, swapped from Mistral-7B),
#   verifies SHA-256 against nebula-model-manifest.json, and writes
#   MANIFEST.sha256 into the chroot /opt/orionx/nebula/models/. This section
#   asserts that the full staged artifact set is present in the squashfs.
#
# @decision DEC-PHASE10-009
# @title nebula-integrity-check: boot-time SHA-256 gate; must be autoenabled
# @status accepted
# @rationale nebula-integrity-check.service is the only Nebula unit in
#   multi-user.target.wants/ — it is the boot gate that blocks nebula-runtime
#   on mismatch. It has WantedBy=multi-user.target.
#
# @decision DEC-PHASE10-010
# @title lazy-start: nebula-runtime.socket + nebula-runtime.service opt-in;
#   nebula-warmup.service opt-in only; only integrity-check in multi-user.target.wants
# @status accepted
# @rationale nebula-runtime.socket (WantedBy=sockets.target) provides lazy-start.
#   nebula-runtime.service and nebula-warmup.service are NOT in multi-user.target.wants/
#   (keeps boot fast and RAM budget preserved for non-AI workflows).
#
# @decision DEC-PHASE10-011
# @title AppArmor profile usr.bin.ollama confinement
# @status accepted
# @rationale /etc/apparmor.d/usr.bin.ollama is staged via includes.chroot and
#   activated by 0610-apparmor-setup.hook.chroot. It confines the ollama daemon
#   to /opt/orionx/nebula/models and localhost networking only.
# ===========================================================================
section "15. Phase 11 W11-1 — Nebula runtime: model + manifest + ollama + units staged"

# (a) Model file present and large (> 1.5 GB sanity check — the Qwen2.5-3B Q4_K_M GGUF is ~1.9 GB)
# Filename is single source of truth from nebula-model-manifest.json model_filename field.
# W11-1 swaps Mistral-7B (~4.4 GB) → Qwen2.5-3B-Instruct Q4_K_M (~1.9 GB, DEC-PHASE11-002).
# Warn threshold relaxed from 4 GB to 3 GB per DEC-PHASE10-012 for this smaller model.
NEBULA_MODEL="$SQF/opt/orionx/nebula/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf"
if [[ -f "$NEBULA_MODEL" ]]; then
    pass "/opt/orionx/nebula/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf present (DEC-PHASE10-008, DEC-PHASE11-002)"
    # Sanity-check: model must be > 1 500 000 000 bytes (the Qwen2.5-3B Q4_K_M GGUF is ~1.9 GB)
    # || true: stat exits non-zero if field extraction fails; we assert separately.
    MODEL_SIZE="$(stat -c '%s' "$NEBULA_MODEL" 2>/dev/null || stat -f '%z' "$NEBULA_MODEL" 2>/dev/null || true)"
    if [[ -z "$MODEL_SIZE" ]]; then
        fail "model file size unknown" \
             "MODEL_SIZE could not be determined — model may be absent (DEC-PHASE10-008)"
    elif [[ "$MODEL_SIZE" -le 1500000000 ]]; then
        fail "model file size > 1.5 GB (floor)" \
             "Got: $MODEL_SIZE bytes — model may be a stub or download incomplete (DEC-PHASE10-008)"
    elif [[ "$MODEL_SIZE" -ge 3000000000 ]]; then
        fail "model file size < 3.0 GB (ceiling, Mistral-regression guard)" \
             "Got: $MODEL_SIZE bytes — exceeds Qwen-3B plausible ceiling; possible accidental Mistral-7B regression (DEC-PHASE11-002)"
    else
        pass "model file size in Qwen-3B range 1.5 GB < size < 3.0 GB ($MODEL_SIZE bytes)"
    fi
else
    fail "/opt/orionx/nebula/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf present" \
         "stage_nebula_model() in build-iso.sh must download+stage the GGUF (DEC-PHASE10-008, DEC-PHASE11-002)"
fi

# (b) MANIFEST.sha256 present (written by stage_nebula_model after SHA-256 verify)
NEBULA_MANIFEST="$SQF/opt/orionx/nebula/models/MANIFEST.sha256"
if [[ -f "$NEBULA_MANIFEST" ]]; then
    pass "/opt/orionx/nebula/models/MANIFEST.sha256 present (DEC-PHASE10-008 integrity chain)"
else
    fail "/opt/orionx/nebula/models/MANIFEST.sha256 present" \
         "stage_nebula_model() must write MANIFEST.sha256 — integrity boot gate depends on it"
fi

# (c) nebula dispatcher present and executable
NEBULA_DISPATCHER="$SQF/opt/orionx/scripts/nebula/nebula"
if [[ -f "$NEBULA_DISPATCHER" ]]; then
    pass "/opt/orionx/scripts/nebula/nebula staged"
else
    fail "/opt/orionx/scripts/nebula/nebula staged" \
         "scripts/nebula/ must be rsynced by stage_application_content (DEC-PHASE10-008)"
fi
if [[ -x "$NEBULA_DISPATCHER" ]]; then
    pass "/opt/orionx/scripts/nebula/nebula is executable"
else
    fail "/opt/orionx/scripts/nebula/nebula is executable" \
         "0700 hook sets chmod 755 on all scripts/ files — check hook execution"
fi

# (d) integrity.py staged (invoked by nebula-integrity-check.service at boot)
if [[ -f "$SQF/opt/orionx/scripts/nebula/integrity.py" ]]; then
    pass "/opt/orionx/scripts/nebula/integrity.py staged (DEC-PHASE10-009)"
else
    fail "/opt/orionx/scripts/nebula/integrity.py staged" \
         "scripts/nebula/integrity.py must be rsynced — it is the boot integrity check"
fi

# (e) /usr/bin/nebula symlink present (created by 0700-orionx-setup.hook.chroot)
if [[ -L "$SQF/usr/bin/nebula" ]]; then
    pass "/usr/bin/nebula symlink present (0700 hook — DEC-PHASE10-008)"
elif [[ -f "$SQF/usr/bin/nebula" ]]; then
    pass "/usr/bin/nebula present (as regular file — 0700 hook)"
else
    fail "/usr/bin/nebula symlink present" \
         "0700-orionx-setup.hook.chroot SCRIPT_MAP must include [\"nebula\"]=\"/opt/orionx/scripts/nebula/nebula\""
fi

# (f) ollama binary present at /usr/local/bin/ollama
#
# @decision DEC-PHASE10-007
# @title ollama installed via .tar.zst extraction to /usr/local/ (not dpkg)
# @status accepted (updated iter-8)
# @rationale ollama has never shipped a .deb in its canonical distribution;
#   iter-7 switched from a hypothetical .deb path to .tar.zst extraction
#   (0500-install-external-tools.hook.chroot). The tarball extracts the
#   ollama binary to /usr/local/bin/ollama. It is NOT registered in dpkg,
#   so dpkg/status will never contain "^Package: ollama$". The dpkg assertion
#   inherited from the W9-1 pattern was incorrect for this distribution method.
#   Binary-presence at /usr/local/bin/ollama is the correct and authoritative
#   check. zstd must be dpkg-installed for the tarball decompression to succeed
#   (asserted separately below). DEC-PHASE10-007 iter-8.
if [[ -x "$SQF/usr/local/bin/ollama" ]]; then
    pass "ollama binary present at /usr/local/bin/ollama (extracted from .tar.zst — DEC-PHASE10-007)"
else
    fail "ollama binary present at /usr/local/bin/ollama" \
         "Expected 0500-install-external-tools.hook.chroot to extract ollama .tar.zst to /usr/local/bin/ (DEC-PHASE10-007)"
fi

# zstd must be dpkg-installed — it is required to decompress the ollama .tar.zst
# in the chroot hook. Without it the tar -I zstd extraction silently fails.
# DEC-PHASE10-007: zstd is the decompressor; its presence in dpkg proves it
# was installed before the hook ran.
if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: zstd$" "$DPKG_STATUS" 2>/dev/null; then
    pass "package installed in chroot: zstd (required for ollama .tar.zst extraction — DEC-PHASE10-007)"
else
    fail "package installed in chroot: zstd" \
         "zstd not found in dpkg/status — check orionx.list.chroot includes zstd (DEC-PHASE10-007)"
fi

# (g) 4 systemd unit files installed at /lib/systemd/system/
for nebula_unit in \
    "nebula-integrity-check.service" \
    "nebula-runtime.service" \
    "nebula-runtime.socket" \
    "nebula-warmup.service"; do
    if [[ -f "$SQF/lib/systemd/system/$nebula_unit" ]]; then
        pass "/lib/systemd/system/$nebula_unit installed (0615 hook — DEC-PHASE10-009/010)"
    else
        fail "/lib/systemd/system/$nebula_unit installed" \
             "0615-install-systemd-units.hook.chroot must copy this unit (DEC-PHASE7-SYSTEMD-INSTALL-001)"
    fi
done

# (h) ONLY nebula-integrity-check.service in multi-user.target.wants/
#     (the other 3 are lazy-start or opt-in — DEC-PHASE10-010)
MULTI_USER_WANTS="$SQF/etc/systemd/system/multi-user.target.wants"
if [[ -L "$MULTI_USER_WANTS/nebula-integrity-check.service" ]] || \
   [[ -f "$MULTI_USER_WANTS/nebula-integrity-check.service" ]]; then
    pass "nebula-integrity-check.service in multi-user.target.wants/ (boot gate enabled — DEC-PHASE10-009)"
else
    fail "nebula-integrity-check.service in multi-user.target.wants/" \
         "systemctl enable nebula-integrity-check.service must run in 0615 hook"
fi

# nebula-runtime.service must NOT be in multi-user.target.wants/ (socket activates it)
# || true: DEC-PHASE9-014 — ls exits non-zero on absent file; the no-match is the correct state.
if [[ ! -e "$MULTI_USER_WANTS/nebula-runtime.service" ]]; then
    pass "nebula-runtime.service NOT in multi-user.target.wants/ (socket lazy-start — DEC-PHASE10-010)"
else
    fail "nebula-runtime.service NOT in multi-user.target.wants/" \
         "Service should be activated by socket only — direct autoenable bypasses lazy-start (DEC-PHASE10-010)"
fi

# nebula-warmup.service must NOT be in multi-user.target.wants/ (opt-in only)
if [[ ! -e "$MULTI_USER_WANTS/nebula-warmup.service" ]]; then
    pass "nebula-warmup.service NOT in multi-user.target.wants/ (opt-in — DEC-PHASE10-010)"
else
    fail "nebula-warmup.service NOT in multi-user.target.wants/" \
         "Warmup is deliberately opt-in; autoenable would run at every boot (DEC-PHASE10-010)"
fi

# nebula-runtime.socket NOT in multi-user.target.wants/ (it goes to sockets.target.wants/)
if [[ ! -e "$MULTI_USER_WANTS/nebula-runtime.socket" ]]; then
    pass "nebula-runtime.socket NOT in multi-user.target.wants/ (WantedBy=sockets.target — DEC-PHASE10-010)"
else
    fail "nebula-runtime.socket NOT in multi-user.target.wants/" \
         "Socket unit belongs in sockets.target.wants/, not multi-user.target.wants/"
fi

# (i) AppArmor profile usr.bin.ollama present (DEC-PHASE10-011)
if [[ -f "$SQF/etc/apparmor.d/usr.bin.ollama" ]]; then
    pass "/etc/apparmor.d/usr.bin.ollama AppArmor profile present (DEC-PHASE10-011)"
else
    fail "/etc/apparmor.d/usr.bin.ollama AppArmor profile present" \
         "AppArmor profile missing — includes.chroot/etc/apparmor.d/usr.bin.ollama not staged (DEC-PHASE10-011)"
fi

# ===========================================================================
# 16. W11-2 debloat post-conditions + bootloader single-authority + W9-2 import
# ===========================================================================
# @decision DEC-PHASE11-012
# @title Section 16: W11-2 debloat assertions, GENERATED marker, W9-2 import
# @status accepted
# @rationale W11-2 lands three coupled fixes (issue #63, #64, #65, #66):
#   (a) 14 packages debloated from base ISO per DEC-PHASE11-003 + DEC-PHASE11-006;
#   (b) Ghidra bulk staging removed from base (deferred to W11-8 optional installer);
#   (c) bootloader cmdline single-authority: both cfgs carry GENERATED marker and
#       correct identity tokens (orionx-operator / orionx per DEC-PHASE11-012);
#   (d) W9-2 Python module present and importable inside the built squashfs.
#   These assertions run against the CI-built ISO squashfs so build-time bugs
#   are caught before hardware boot (the class of issue that made rc7-rc9 silently
#   ship dead-authority bootloader configs).
section "16. W11-2: debloat post-conditions + GENERATED bootloader + W9-2 import"

# ---------------------------------------------------------------------------
# 16a. Dropped packages absent from dpkg -l in the extracted squashfs
# ---------------------------------------------------------------------------
# We use dpkg --get-selections (available in the squashfs dpkg database) parsed
# via grep against the dpkg status file, which is cheaper than running dpkg -l.
# The dpkg status file is at $SQF/var/lib/dpkg/status.
DPKG_STATUS="$SQF/var/lib/dpkg/status"
DROPPED_PACKAGES=(hashcat john hydra proxychains chntpw steghide encfs openvpn build-essential gcc make libssl-dev python3-dev vim)

echo "  [16a] Verifying 14 dropped packages absent from squashfs dpkg database"
if [[ -f "$DPKG_STATUS" ]]; then
    for pkg in "${DROPPED_PACKAGES[@]}"; do
        # grep for "Package: <pkg>" followed shortly by "Status: install ok installed"
        # A simple approach: check if the package appears as installed in the status file.
        if grep -q "^Package: ${pkg}$" "$DPKG_STATUS"; then
            fail "16a: $pkg absent from squashfs dpkg database (W11-2 debloat)" \
                 "Package '$pkg' found in dpkg status — debloat did not remove it from the ISO"
        else
            pass "16a: $pkg absent from squashfs dpkg database (W11-2 debloat)"
        fi
    done
else
    fail "16a: dpkg status file available for package checks" \
         "$DPKG_STATUS not found — cannot verify package absence; squashfs extraction may be incomplete"
fi

# ---------------------------------------------------------------------------
# 16b. Ghidra references absent from the extracted 0500 hook
# ---------------------------------------------------------------------------
echo "  [16b] Verifying Ghidra bulk staging removed from 0500 hook"
# The 0500 hook is a live/ hook (runs at build time, not boot time), so it won't be
# in the squashfs at all. Instead we assert against the source hook in the worktree.
HOOK_0500_SRC="$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot"
if [[ -f "$HOOK_0500_SRC" ]]; then
    if grep -qE '(NationalSecurityAgency/ghidra|unzip.*ghidra|GHIDRA_VERSION|GHIDRA_DATE|/opt/ghidra[^.])' "$HOOK_0500_SRC" 2>/dev/null; then
        GHIDRA_HITS=$(grep -cE '(NationalSecurityAgency/ghidra|unzip.*ghidra|GHIDRA_VERSION|GHIDRA_DATE|/opt/ghidra[^.])' "$HOOK_0500_SRC" 2>/dev/null)
    else
        GHIDRA_HITS=0
    fi
    if [[ "$GHIDRA_HITS" -eq 0 ]]; then
        pass "16b: Ghidra bulk staging absent from 0500 hook source (DEC-PHASE11-004)"
    else
        fail "16b: Ghidra bulk staging absent from 0500 hook source" \
             "Found $GHIDRA_HITS Ghidra reference(s) in $HOOK_0500_SRC — debloat incomplete"
    fi
else
    fail "16b: 0500 hook source file accessible for Ghidra check" \
         "Cannot find $HOOK_0500_SRC"
fi

# ---------------------------------------------------------------------------
# 16c. GENERATED marker on line 1 of both bootloader cfgs in the binary tree
# ---------------------------------------------------------------------------
echo "  [16c] Verifying GENERATED marker in bootloader cfgs (proves generator ran)"
# We check against the source cfgs in the worktree (includes.binary/).
# In a real CI run these would also be extracted from the ISO binary partition.
ISOLINUX_SRC="$REPO_ROOT/iso/config/includes.binary/isolinux/isolinux.cfg"
GRUB_SRC="$REPO_ROOT/iso/config/includes.binary/boot/grub/grub.cfg"

GENERATED_MARKER="GENERATED — do not edit — regenerate via scripts/build-iso.sh"

if [[ -f "$ISOLINUX_SRC" ]]; then
    ISOLINUX_L1="$(head -1 "$ISOLINUX_SRC")"
    if echo "$ISOLINUX_L1" | grep -qF "$GENERATED_MARKER"; then
        pass "16c: GENERATED marker on line 1 of isolinux.cfg (DEC-PHASE11-012)"
    else
        fail "16c: GENERATED marker on line 1 of isolinux.cfg" \
             "Line 1 is: $ISOLINUX_L1"
    fi
else
    fail "16c: isolinux.cfg accessible for marker check" "Not found: $ISOLINUX_SRC"
fi

if [[ -f "$GRUB_SRC" ]]; then
    GRUB_L1="$(head -1 "$GRUB_SRC")"
    if echo "$GRUB_L1" | grep -qF "$GENERATED_MARKER"; then
        pass "16c: GENERATED marker on line 1 of grub.cfg (DEC-PHASE11-012)"
    else
        fail "16c: GENERATED marker on line 1 of grub.cfg" \
             "Line 1 is: $GRUB_L1"
    fi
else
    fail "16c: grub.cfg accessible for marker check" "Not found: $GRUB_SRC"
fi

# ---------------------------------------------------------------------------
# 16d. Identity tokens present in both bootloader cfgs
# ---------------------------------------------------------------------------
echo "  [16d] Verifying identity tokens in both bootloader cfgs (issue #65 guard)"
# This assertion would have caught the rc7-rc9 silent no-op: the static cfgs had
# the wrong identity because they were hand-edited without going through the
# generator. Now that the generator is the authority, this assertion catches
# any future divergence between the generated cfgs and the intended identity.

USERNAME_TOKEN="live-config.username=orionx-operator"
HOSTNAME_TOKEN="live-config.hostname=orionx"

if [[ -f "$ISOLINUX_SRC" ]]; then
    if grep -q "$USERNAME_TOKEN" "$ISOLINUX_SRC"; then
        pass "16d: $USERNAME_TOKEN present in isolinux.cfg"
    else
        fail "16d: $USERNAME_TOKEN present in isolinux.cfg" \
             "Identity token missing — generator may not have run or wrong identity (DEC-PHASE11-012)"
    fi
    if grep -q "$HOSTNAME_TOKEN" "$ISOLINUX_SRC"; then
        pass "16d: $HOSTNAME_TOKEN present in isolinux.cfg"
    else
        fail "16d: $HOSTNAME_TOKEN present in isolinux.cfg" \
             "Hostname token missing — generator may not have run or wrong identity (DEC-PHASE11-012)"
    fi
fi

if [[ -f "$GRUB_SRC" ]]; then
    if grep -q "$USERNAME_TOKEN" "$GRUB_SRC"; then
        pass "16d: $USERNAME_TOKEN present in grub.cfg"
    else
        fail "16d: $USERNAME_TOKEN present in grub.cfg" \
             "Identity token missing — generator may not have run or wrong identity (DEC-PHASE11-012)"
    fi
    if grep -q "$HOSTNAME_TOKEN" "$GRUB_SRC"; then
        pass "16d: $HOSTNAME_TOKEN present in grub.cfg"
    else
        fail "16d: $HOSTNAME_TOKEN present in grub.cfg" \
             "Hostname token missing — generator may not have run or wrong identity (DEC-PHASE11-012)"
    fi
fi

# ---------------------------------------------------------------------------
# 16e. W9-2 wrapper + Python module present at expected squashfs paths
# ---------------------------------------------------------------------------
echo "  [16e] Verifying W9-2 wrapper + control_center module present in squashfs"
# stage_application_content() rsyncs scripts/ → /opt/orionx/scripts/ inside the squashfs.
# 0700-orionx-setup.hook.chroot symlinks /usr/bin/orionx-control-center → the staged wrapper.

CC_WRAPPER="$SQF/usr/bin/orionx-control-center"
CC_MODULE_DIR="$SQF/opt/orionx/scripts/control_center"
CC_INIT="$CC_MODULE_DIR/__init__.py"
CC_APP="$CC_MODULE_DIR/app.py"

if [[ -L "$CC_WRAPPER" ]]; then
    CC_WRAPPER_TARGET="$(readlink "$CC_WRAPPER" 2>/dev/null || :)"
    if [[ "$CC_WRAPPER_TARGET" == "/opt/orionx/scripts/control_center/orionx-control-center" ]]; then
        pass "16e: /usr/bin/orionx-control-center symlink present in squashfs (issue #66)"
    else
        fail "16e: /usr/bin/orionx-control-center symlink target correct" \
             "Got target: $CC_WRAPPER_TARGET"
    fi
else
    fail "16e: /usr/bin/orionx-control-center symlink present in squashfs" \
         "Symlink not found at $CC_WRAPPER — 0700-orionx-setup.hook.chroot did not create it (issue #66)"
fi

if [[ -d "$CC_MODULE_DIR" ]]; then
    pass "16e: /opt/orionx/scripts/control_center/ directory present in squashfs"
else
    fail "16e: /opt/orionx/scripts/control_center/ directory present in squashfs" \
         "Module directory missing — stage_application_content() may not have staged scripts/ (issue #66)"
fi

if [[ -f "$CC_INIT" ]]; then
    pass "16e: control_center/__init__.py present in squashfs"
else
    fail "16e: control_center/__init__.py present in squashfs" \
         "$CC_INIT not found — module package incomplete (issue #66)"
fi

if [[ -f "$CC_APP" ]]; then
    pass "16e: control_center/app.py present in squashfs"
else
    fail "16e: control_center/app.py present in squashfs" \
         "$CC_APP not found — module package incomplete (issue #66)"
fi

# ---------------------------------------------------------------------------
# 16f. W11-2d structural check: def run_app symbol + wrapper import wire
# ---------------------------------------------------------------------------
# W11-2c used PYTHONPATH+python3 -c to import control_center.app at test time.
# On Ubuntu 24.04 GHA runners python3-gi (a C-extension gobject-introspection
# binding) is not available via pip and the system package installs into the
# wrong prefix relative to the runner's python3, causing the import to fail
# with "No module named gi" even though the source file is intact.
#
# W11-2d replaces the runtime import with two grep structural checks that
# carry the same acceptance signal for issue #66 wire cohesion without
# requiring C-extension availability on the host runner:
#
#   1. grep -qE "^def run_app\b" app.py  — symbol is defined in the module
#   2. grep -qE "from control_center\.app import run_app" wrapper — wire is present
#
# The actual module-import at runtime is exercised by the first-boot service on
# hardware and in the QEMU T6 integration test (DEC-PHASE11-012).
echo "  [16f] W11-2d structural: def run_app in app.py + wrapper imports run_app"

CC_SCRIPTS_PARENT="$SQF/opt/orionx/scripts"
if [[ -d "$CC_SCRIPTS_PARENT" ]]; then
    APP_PY="$CC_SCRIPTS_PARENT/control_center/app.py"
    WRAPPER="$CC_SCRIPTS_PARENT/control_center/orionx-control-center"

    # Structural check 1: run_app symbol defined in app.py
    if [[ -f "$APP_PY" ]] && grep -qE "^def run_app\b" "$APP_PY"; then
        pass "16f: control_center.app.run_app symbol defined in squashfs (issue #66 module completeness)"
    else
        fail "16f: control_center.app.run_app symbol defined in squashfs" \
             "run_app function not found in $APP_PY (issue #66 — module tree incomplete)"
    fi

    # Structural check 2: wrapper imports run_app from control_center.app
    if [[ -f "$WRAPPER" ]] && grep -qE "from control_center\.app import run_app" "$WRAPPER"; then
        pass "16f: wrapper imports run_app from control_center.app (issue #66 wire cohesion)"
    else
        fail "16f: wrapper imports run_app from control_center.app" \
             "Import statement not found in $WRAPPER (issue #66 — wire missing)"
    fi
else
    fail "16f: /opt/orionx/scripts/ present in squashfs" \
         "Cannot find $CC_SCRIPTS_PARENT"
fi

# ===========================================================================
# 17. W11-9a: Boot chain branding — Plymouth + GRUB + isolinux + LightDM
# ===========================================================================
#
# @decision DEC-PHASE11-010
# @title W11-9a content-presence section 23a: boot chain branding assets
# @status accepted
# @rationale W11-9a stages Plymouth orionx-phoenix theme, GRUB orionx theme,
#   isolinux splash asset, and LightDM greeter config. This section (labelled
#   section 23a per plan numbering) asserts all 9 sub-conditions required by
#   the W11-9a Evaluation Contract item 9. Assertions are keyed as 23a-a
#   through 23a-i matching the plan text (T7 assertions in MASTER_PLAN).
#
# Section label note: sections 17-22 are reserved for W11-3 through W11-8
# work items between W11-2 (section 16) and W11-9a (here, section 23/17).
# The section number in echo output uses 23a to match the plan numbering;
# the comment label 17 reflects insertion order in this file.

section "17. W11-9a: Boot chain branding assets (section 23a)"

# ---------------------------------------------------------------------------
# 23a-a: Plymouth theme directory and .plymouth metadata present in squashfs
# ---------------------------------------------------------------------------
PLYMOUTH_THEME_DIR="$SQF/usr/share/plymouth/themes/orionx-phoenix"

if [[ -d "$PLYMOUTH_THEME_DIR" ]]; then
    pass "23a-a: /usr/share/plymouth/themes/orionx-phoenix/ present in squashfs"
else
    fail "23a-a: /usr/share/plymouth/themes/orionx-phoenix/ present in squashfs" \
         "Plymouth theme directory missing — check includes.chroot staging"
fi

# 23a-a(ii): .plymouth metadata file
if [[ -f "$PLYMOUTH_THEME_DIR/orionx-phoenix.plymouth" ]]; then
    pass "23a-a: orionx-phoenix.plymouth metadata file present"
else
    fail "23a-a: orionx-phoenix.plymouth metadata file present" \
         "Missing: $PLYMOUTH_THEME_DIR/orionx-phoenix.plymouth"
fi

# ---------------------------------------------------------------------------
# 23a-b: Plymouth script file present
# ---------------------------------------------------------------------------
if [[ -f "$PLYMOUTH_THEME_DIR/orionx-phoenix.script" ]]; then
    pass "23a-b: orionx-phoenix.script present in squashfs"
else
    fail "23a-b: orionx-phoenix.script present in squashfs" \
         "Missing: $PLYMOUTH_THEME_DIR/orionx-phoenix.script"
fi

# ---------------------------------------------------------------------------
# 23a-c: At least one PNG asset present under Plymouth theme dir
# ---------------------------------------------------------------------------
PLYMOUTH_PNG_COUNT=0
if [[ -d "$PLYMOUTH_THEME_DIR" ]]; then
    PLYMOUTH_PNG_COUNT=$(find "$PLYMOUTH_THEME_DIR" -name "*.png" -type f 2>/dev/null | wc -l)
fi

if [[ "$PLYMOUTH_PNG_COUNT" -ge 1 ]]; then
    pass "23a-c: at least one PNG asset present under Plymouth theme dir (found: $PLYMOUTH_PNG_COUNT)"
else
    fail "23a-c: at least one PNG asset present under Plymouth theme dir" \
         "No *.png files found under $PLYMOUTH_THEME_DIR"
fi

# ---------------------------------------------------------------------------
# 23a-d: /etc/plymouth/plymouthd.conf contains Theme=orionx-phoenix
# ---------------------------------------------------------------------------
PLYMOUTHD_CONF="$SQF/etc/plymouth/plymouthd.conf"

if [[ -f "$PLYMOUTHD_CONF" ]] && grep -q "Theme=orionx-phoenix" "$PLYMOUTHD_CONF"; then
    pass "23a-d: /etc/plymouth/plymouthd.conf contains Theme=orionx-phoenix"
else
    fail "23a-d: /etc/plymouth/plymouthd.conf contains Theme=orionx-phoenix" \
         "File missing or Theme= line absent: $PLYMOUTHD_CONF"
fi

# ---------------------------------------------------------------------------
# 23a-e: GRUB theme.txt present in squashfs
# ---------------------------------------------------------------------------
GRUB_THEME_DIR="$SQF/usr/share/grub/themes/orionx"
GRUB_THEME_TXT="$GRUB_THEME_DIR/theme.txt"

if [[ -f "$GRUB_THEME_TXT" ]]; then
    pass "23a-e: /usr/share/grub/themes/orionx/theme.txt present in squashfs"
else
    fail "23a-e: /usr/share/grub/themes/orionx/theme.txt present in squashfs" \
         "Missing: $GRUB_THEME_TXT"
fi

# ---------------------------------------------------------------------------
# 23a-f: At least one image asset present under GRUB theme dir
# ---------------------------------------------------------------------------
GRUB_PNG_COUNT=0
if [[ -d "$GRUB_THEME_DIR" ]]; then
    GRUB_PNG_COUNT=$(find "$GRUB_THEME_DIR" -name "*.png" -type f 2>/dev/null | wc -l)
fi

if [[ "$GRUB_PNG_COUNT" -ge 1 ]]; then
    pass "23a-f: at least one PNG asset present under GRUB theme dir (found: $GRUB_PNG_COUNT)"
else
    fail "23a-f: at least one PNG asset present under GRUB theme dir" \
         "No *.png files found under $GRUB_THEME_DIR"
fi

# ---------------------------------------------------------------------------
# 23a-g: LightDM greeter orionx asset directory present in squashfs
# ---------------------------------------------------------------------------
LIGHTDM_GREETER_DIR="$SQF/usr/share/lightdm-gtk-greeter/orionx"

if [[ -d "$LIGHTDM_GREETER_DIR" ]]; then
    pass "23a-g: /usr/share/lightdm-gtk-greeter/orionx/ present in squashfs"
else
    fail "23a-g: /usr/share/lightdm-gtk-greeter/orionx/ present in squashfs" \
         "LightDM greeter asset directory missing — check includes.chroot staging"
fi

# ---------------------------------------------------------------------------
# 23a-h: /etc/lightdm/lightdm-gtk-greeter.conf present and contains wallpaper
# ---------------------------------------------------------------------------
LIGHTDM_GREETER_CONF="$SQF/etc/lightdm/lightdm-gtk-greeter.conf"
EXPECTED_BG="/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png"

if [[ -f "$LIGHTDM_GREETER_CONF" ]] && \
   grep -q "background=${EXPECTED_BG}" "$LIGHTDM_GREETER_CONF"; then
    pass "23a-h: /etc/lightdm/lightdm-gtk-greeter.conf present and background=W9-1 wallpaper"
else
    fail "23a-h: /etc/lightdm/lightdm-gtk-greeter.conf present and background=W9-1 wallpaper" \
         "File missing or background line absent: $LIGHTDM_GREETER_CONF (expected background=${EXPECTED_BG})"
fi

# ---------------------------------------------------------------------------
# 23a-i: 0800-orionx-branding.hook.chroot present in source tree (build-time check)
# ---------------------------------------------------------------------------
# Hooks run at chroot build time and are not copied into the squashfs root.
# This assertion checks the source-tree location, not the squashfs extraction.
HOOK_SOURCE="$REPO_ROOT/iso/config/hooks/live/0800-orionx-branding.hook.chroot"

if [[ -f "$HOOK_SOURCE" ]]; then
    pass "23a-i: 0800-orionx-branding.hook.chroot present in source tree (iso/config/hooks/live/)"
else
    fail "23a-i: 0800-orionx-branding.hook.chroot present in source tree" \
         "Missing: $HOOK_SOURCE"
fi

# Also verify the hook contains the critical activation command
if [[ -f "$HOOK_SOURCE" ]] && \
   grep -q "plymouth-set-default-theme -R orionx-phoenix" "$HOOK_SOURCE"; then
    pass "23a-i(ii): hook contains plymouth-set-default-theme -R orionx-phoenix"
else
    fail "23a-i(ii): hook contains plymouth-set-default-theme -R orionx-phoenix" \
         "Activation command absent from $HOOK_SOURCE"
fi

# Verify hook carries @decision annotation referencing DEC-PHASE11-010
if [[ -f "$HOOK_SOURCE" ]] && grep -q "DEC-PHASE11-010" "$HOOK_SOURCE"; then
    pass "23a-i(iii): hook carries @decision DEC-PHASE11-010 annotation"
else
    fail "23a-i(iii): hook carries @decision DEC-PHASE11-010 annotation" \
         "@decision DEC-PHASE11-010 not found in $HOOK_SOURCE"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL ))
echo "Results: $PASS passed, $FAIL failed (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    echo "${RED}FAIL${NC}: Content presence verification failed — $FAIL assertion(s) failed"
    exit 1
fi
echo "${GREEN}PASS${NC}: Content presence verified — all $PASS assertions passed"
exit 0
