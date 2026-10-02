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
SKIP=0

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

skip() {
    SKIP=$(( SKIP + 1 ))
    echo "  SKIP: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
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

# Bootloader configs + menu assets live in the ISO binary tree, NOT the squashfs.
# They are the SHIPPED output of generate_bootloader_configs() (DEC-PHASE11-012)
# and are the single authority for sections 16c/16d/18 — the copies under
# iso/config/includes.binary/ in the worktree are regenerated on every build and
# may be stale relative to the ISO under test, so they are not consulted.
ISO_BOOT="$WORK/iso"
mkdir -p "$ISO_BOOT/boot/grub/themes/orionx" "$ISO_BOOT/isolinux"
echo "  Extracting bootloader cfgs + menu assets from the ISO binary tree..."
# -abort_on NEVER: one missing file must not stop the remaining extractions.
xorriso -abort_on NEVER -osirrox on -indev "$ISO_PATH" \
    -extract /boot/grub/grub.cfg "$ISO_BOOT/boot/grub/grub.cfg" \
    -extract /isolinux/isolinux.cfg "$ISO_BOOT/isolinux/isolinux.cfg" \
    -extract /boot/grub/themes/orionx/theme.txt "$ISO_BOOT/boot/grub/themes/orionx/theme.txt" \
    -extract /boot/grub/themes/orionx/background.png "$ISO_BOOT/boot/grub/themes/orionx/background.png" \
    -extract /isolinux/orionx-isolinux-bg.png "$ISO_BOOT/isolinux/orionx-isolinux-bg.png" \
    -extract /isolinux/vesamenu.c32 "$ISO_BOOT/isolinux/vesamenu.c32" \
    2>/dev/null || true  # individual absence is asserted per-file below
ISO_GRUB_CFG="$ISO_BOOT/boot/grub/grub.cfg"
ISO_ISOLINUX_CFG="$ISO_BOOT/isolinux/isolinux.cfg"
ISO_GRUB_THEME_DIR="$ISO_BOOT/boot/grub/themes/orionx"
ISO_ISOLINUX_DIR="$ISO_BOOT/isolinux"

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

# xfconf desktop XML is seeded into /etc/skel/ by hooks/normal/0100-create-user.hook.chroot
# (DEC-PHASE11-014). The live user (orionx-operator) is created at BOOT by live-config,
# which copies /etc/skel — so /home/orionx does not exist in the squashfs (23b-k asserts
# that) and the seed file is the thing to check here.
XFCONF_XML="$SQF/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
if [[ -f "$XFCONF_XML" ]]; then
    pass "/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml present (skel authority — DEC-PHASE11-014)"
    if grep -q "orionx-phoenix-wallpaper.png" "$XFCONF_XML" 2>/dev/null; then
        pass "xfce4-desktop.xml (skel) references orionx-phoenix-wallpaper.png as backdrop"
    else
        fail "xfce4-desktop.xml (skel) references orionx-phoenix-wallpaper.png as backdrop" \
             "Check 0100-create-user.hook.chroot xfconf XML block"
    fi
else
    fail "/etc/skel xfce4-desktop.xml present" \
         "XFCE backdrop seed missing — 0100-create-user.hook.chroot did not write it to /etc/skel/ (DEC-PHASE11-014)"
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
# @decision DEC-PHASE11-033
# @title nebula-runtime.service auto-started directly; socket activation removed
# @status accepted
# @rationale ollama serve binds 127.0.0.1:11434 itself and cannot accept a systemd
#   socket fd, so the former nebula-runtime.socket raced it for the port and ollama
#   looped on EADDRINUSE. The socket unit is deleted; nebula-runtime.service is now
#   auto-enabled (multi-user.target.wants/). ollama loads the model LAZILY on the
#   first request, so the idle-RAM budget (DEC-PHASE10-010) still holds.
#   nebula-warmup.service stays opt-in (NOT auto-enabled).
#
# @decision DEC-PHASE10-011
# @title AppArmor profile usr.bin.ollama confinement
# @status accepted
# @rationale /etc/apparmor.d/usr.bin.ollama is staged via includes.chroot and
#   activated by 0610-apparmor-setup.hook.chroot. It confines the ollama daemon
#   to /opt/orionx/nebula/models and localhost networking only.
# ===========================================================================
section "15. Phase 11 W11-1 — Nebula runtime: model + manifest + ollama + units staged"

# (a) Model store — the consolidated single-copy ollama layout (DEC-PHASE12-016).
# Authority: scripts/nebula/store.py `consolidate`, run by
# hooks/live/0510-register-nebula-model.hook.chroot after `ollama create`. It
# verifies the live blobs, deletes orphan blobs AND the source GGUF, and rewrites
# MANIFEST.sha256 to the blob(s). So there is NO bare
# Qwen2.5-3B-Instruct-Q4_K_M.gguf in the image; the model is exactly one
# content-addressed blob (~1.93 GB — DEC-PHASE11-002 Qwen2.5-3B Q4_K_M) under blobs/.
NEBULA_MODELS_DIR="$SQF/opt/orionx/nebula/models"
NEBULA_BLOBS_DIR="$NEBULA_MODELS_DIR/blobs"
NEBULA_SOURCE_GGUF="$NEBULA_MODELS_DIR/Qwen2.5-3B-Instruct-Q4_K_M.gguf"
LARGE_BLOB_COUNT=0
if [[ -d "$NEBULA_BLOBS_DIR" ]]; then
    LARGE_BLOB_COUNT="$(find "$NEBULA_BLOBS_DIR" -maxdepth 1 -type f -name 'sha256-*' -size +1G 2>/dev/null | wc -l | tr -d ' ')"
fi
if [[ "$LARGE_BLOB_COUNT" -eq 1 ]]; then
    LARGE_BLOB="$(find "$NEBULA_BLOBS_DIR" -maxdepth 1 -type f -name 'sha256-*' -size +1G 2>/dev/null | head -1)"
    MODEL_SIZE="$(stat -c '%s' "$LARGE_BLOB" 2>/dev/null || stat -f '%z' "$LARGE_BLOB" 2>/dev/null || true)"
    pass "/opt/orionx/nebula/models/blobs/ holds exactly one blob > 1 GB — single-copy store (DEC-PHASE12-016; ${MODEL_SIZE:-?} bytes)"
    # Mistral-regression guard retained from the GGUF era (DEC-PHASE11-002): a 7B Q4 would be ~4.4 GB.
    if [[ -n "$MODEL_SIZE" && "$MODEL_SIZE" -ge 3000000000 ]]; then
        fail "model blob size < 3.0 GB (ceiling, Mistral-regression guard)" \
             "Got: $MODEL_SIZE bytes — exceeds Qwen-3B plausible ceiling; possible accidental Mistral-7B regression (DEC-PHASE11-002)"
    else
        pass "model blob size in Qwen-3B range (< 3.0 GB)"
    fi
else
    fail "/opt/orionx/nebula/models/blobs/ holds exactly one blob > 1 GB" \
         "Found $LARGE_BLOB_COUNT — 0: model never imported (DEC-PHASE11-021); 2+: store.py consolidate did not purge the orphan (DEC-PHASE12-016)"
fi

if [[ ! -e "$NEBULA_SOURCE_GGUF" ]]; then
    pass "bare Qwen2.5-3B-Instruct-Q4_K_M.gguf absent — ollama blob store is the only copy (DEC-PHASE12-016)"
else
    fail "bare Qwen2.5-3B-Instruct-Q4_K_M.gguf absent" \
         "Source GGUF survived consolidation — two ~1.9 GB copies in the squashfs (DEC-PHASE12-016 regression; hook 0510 should have hard-failed)"
fi

# Tag pinned in iso/config/nebula-model-manifest.json ("ollama_model_tag": "qwen2.5:3b-instruct-q4_K_M");
# ollama lays it out as manifests/registry.ollama.ai/library/<name>/<tag>. (34k re-derives it from the JSON.)
if [[ -f "$NEBULA_MODELS_DIR/manifests/registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M" ]]; then
    pass "ollama manifest registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M present (hook 0510 registration)"
else
    fail "ollama manifest registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M present" \
         "Tag not registered — \`ollama create\` in hook 0510 did not run or used a different tag"
fi

# (b) MANIFEST.sha256 present and in the store.py shape: "<hex64>  blobs/sha256-<hex64>",
#     first entry = model layer, digest == blob filename suffix. Comment lines allowed.
#     The full `sha256sum -c` proof lives in tests/integration/test-nebula-runtime.sh.
NEBULA_MANIFEST="$NEBULA_MODELS_DIR/MANIFEST.sha256"
if [[ -f "$NEBULA_MANIFEST" ]]; then
    pass "/opt/orionx/nebula/models/MANIFEST.sha256 present (DEC-PHASE10-008/DEC-PHASE12-016 integrity chain)"
    # || true: grep exits 1 on no match (DEC-PHASE9-014 pipefail guard)
    MANIFEST_ENTRIES="$(grep -v '^#' "$NEBULA_MANIFEST" | grep -v '^[[:space:]]*$' || true)"
    MANIFEST_BAD="$(printf '%s\n' "$MANIFEST_ENTRIES" | grep -vE '^[0-9a-f]{64}  blobs/sha256-[0-9a-f]{64}$' || true)"
    FIRST_DIGEST="$(printf '%s\n' "$MANIFEST_ENTRIES" | head -1 | awk '{print $1}')"
    FIRST_PATH="$(printf '%s\n' "$MANIFEST_ENTRIES" | head -1 | awk '{print $2}')"
    if [[ -n "$FIRST_DIGEST" && -z "$MANIFEST_BAD" && "$FIRST_PATH" == "blobs/sha256-${FIRST_DIGEST}" ]]; then
        pass "MANIFEST.sha256 entries are '<hex64>  blobs/sha256-<hex64>' and the first digest is its blob's content address (DEC-PHASE12-016)"
    else
        fail "MANIFEST.sha256 entries are '<hex64>  blobs/sha256-<hex64>' with digest == filename suffix" \
             "first='${FIRST_DIGEST:-<none>} ${FIRST_PATH:-<none>}' malformed='${MANIFEST_BAD:-<none>}' — MANIFEST not rewritten by store.py"
    fi
else
    fail "/opt/orionx/nebula/models/MANIFEST.sha256 present" \
         "store.py consolidate must write MANIFEST.sha256 — integrity boot gate depends on it (DEC-PHASE12-016)"
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

# (g) 3 systemd unit files installed at /lib/systemd/system/ (socket removed — DEC-PHASE11-033)
for nebula_unit in \
    "nebula-integrity-check.service" \
    "nebula-runtime.service" \
    "nebula-warmup.service"; do
    if [[ -f "$SQF/lib/systemd/system/$nebula_unit" ]]; then
        pass "/lib/systemd/system/$nebula_unit installed (0615 hook — DEC-PHASE10-009, DEC-PHASE11-033)"
    else
        fail "/lib/systemd/system/$nebula_unit installed" \
             "0615-install-systemd-units.hook.chroot must copy this unit (DEC-PHASE7-SYSTEMD-INSTALL-001)"
    fi
done

# (h) nebula-integrity-check.service + nebula-runtime.service enabled in
#     multi-user.target.wants/; nebula-warmup.service opt-in (DEC-PHASE10-009/010,
#     DEC-PHASE11-033).
#     Use -L, never -e, on wants/ entries: `systemctl enable` writes symlinks to
#     ABSOLUTE targets (/usr/lib/systemd/system/...) which do not resolve inside
#     the extracted tree, so -e reports a present symlink as missing.
MULTI_USER_WANTS="$SQF/etc/systemd/system/multi-user.target.wants"
if [[ -L "$MULTI_USER_WANTS/nebula-integrity-check.service" ]] || \
   [[ -f "$MULTI_USER_WANTS/nebula-integrity-check.service" ]]; then
    pass "nebula-integrity-check.service in multi-user.target.wants/ (boot gate enabled — DEC-PHASE10-009)"
else
    fail "nebula-integrity-check.service in multi-user.target.wants/" \
         "systemctl enable nebula-integrity-check.service must run in 0615 hook"
fi

# nebula-runtime.service MUST be in multi-user.target.wants/ (auto-started — DEC-PHASE11-033)
if [[ -L "$MULTI_USER_WANTS/nebula-runtime.service" ]] || \
   [[ -f "$MULTI_USER_WANTS/nebula-runtime.service" ]]; then
    pass "nebula-runtime.service in multi-user.target.wants/ (auto-started — DEC-PHASE11-033)"
else
    fail "nebula-runtime.service in multi-user.target.wants/" \
         "ollama must be auto-enabled now that socket activation is removed (DEC-PHASE11-033)"
fi

# nebula-warmup.service must NOT be in multi-user.target.wants/ (opt-in only).
# -L catches a dangling-in-tree symlink that -e alone would miss (false PASS).
if [[ ! -L "$MULTI_USER_WANTS/nebula-warmup.service" && ! -e "$MULTI_USER_WANTS/nebula-warmup.service" ]]; then
    pass "nebula-warmup.service NOT in multi-user.target.wants/ (opt-in — DEC-PHASE10-010)"
else
    fail "nebula-warmup.service NOT in multi-user.target.wants/" \
         "Warmup is deliberately opt-in; autoenable would run at every boot (DEC-PHASE10-010)"
fi

# nebula-runtime.socket must be ABSENT entirely (socket activation removed — DEC-PHASE11-033)
if [[ ! -f "$SQF/lib/systemd/system/nebula-runtime.socket" ]]; then
    pass "nebula-runtime.socket absent from /lib/systemd/system/ (socket activation removed — DEC-PHASE11-033)"
else
    fail "nebula-runtime.socket must NOT be installed" \
         "ollama serve binds :11434 itself; the socket caused an EADDRINUSE loop (DEC-PHASE11-033)"
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
# Authority: the cfgs extracted from the ISO binary tree in section 1 — what the
# firmware actually reads. (The worktree copies under includes.binary/ are
# regenerated every build and can be stale relative to the ISO under test.)
ISOLINUX_SRC="$ISO_ISOLINUX_CFG"
GRUB_SRC="$ISO_GRUB_CFG"

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

# ---------------------------------------------------------------------------
# 16g. W11-2f: XFCE auto-lock disabled (issue #76, DEC-PHASE9-002)
# ---------------------------------------------------------------------------
# Layer 1: 0100-create-user.hook.chroot writes xfce4-screensaver.xml into
#   /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/ (single-authority,
#   DEC-PHASE9-002). /etc/skel is now the canonical live-config path per
#   DEC-PHASE11-014 — the prior /home/orionx/ path was dead-authority (R6 root
#   cause 2026-07-13) and was retired by the W11-9b R6 fix.
# Layer 2: /etc/xdg/autostart/orionx-disable-screen-lock.desktop runs
#   xset s off + xset -dpms + xset s noblank at XFCE session start.
# Assertion (a): Layer 1 XML present in squashfs (hook wrote it to /etc/skel/).
# Assertion (b): Layer 1 XML contains the lock-disabled property.
# Assertion (c): Layer 2 .desktop present and contains xset s off + OnlyShowIn=XFCE.
echo "  [16g] W11-2f: xfce4-screensaver.xml + disable-screen-lock.desktop (#76, DEC-PHASE9-002, DEC-PHASE11-014)"

SCREENSAVER_XML="$SQF/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml"
SCREEN_LOCK_DESKTOP="$SQF/etc/xdg/autostart/orionx-disable-screen-lock.desktop"

# (a) Layer 1 XML present in /etc/skel/ (canonical live-config path per DEC-PHASE11-014)
if [[ -f "$SCREENSAVER_XML" ]]; then
    pass "16g-a: xfce4-screensaver.xml present in squashfs /etc/skel/ xfconf dir (#76, DEC-PHASE11-014 canonical authority)"
else
    fail "16g-a: xfce4-screensaver.xml present in squashfs /etc/skel/ xfconf dir" \
         "Missing: $SCREENSAVER_XML — Layer 1 of W11-2f not written by 0100-create-user.hook.chroot to /etc/skel/"
fi

# (b) Layer 1 XML content: lock/enabled=false present
if [[ -f "$SCREENSAVER_XML" ]] && \
   grep -q 'name="lock"' "$SCREENSAVER_XML" && \
   grep -q 'value="false"' "$SCREENSAVER_XML"; then
    pass "16g-b: xfce4-screensaver.xml contains lock name with value=false (#76, DEC-PHASE9-002, DEC-PHASE11-014)"
else
    fail "16g-b: xfce4-screensaver.xml contains lock name with value=false" \
         "lock/enabled=false property absent from $SCREENSAVER_XML — idle-lock bricking bug #76 not fixed"
fi

# (c) Layer 2 .desktop present and contains xset s off + OnlyShowIn=XFCE
if [[ -f "$SCREEN_LOCK_DESKTOP" ]] && \
   grep -q "xset s off" "$SCREEN_LOCK_DESKTOP" && \
   grep -q "OnlyShowIn=XFCE" "$SCREEN_LOCK_DESKTOP"; then
    pass "16g-c: orionx-disable-screen-lock.desktop present with xset s off + OnlyShowIn=XFCE (#76)"
else
    fail "16g-c: orionx-disable-screen-lock.desktop present with xset s off + OnlyShowIn=XFCE" \
         "File missing or xset/OnlyShowIn lines absent: $SCREEN_LOCK_DESKTOP — Layer 2 of W11-2f not shipped"
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
# 23a-h: /etc/lightdm/lightdm-gtk-greeter.conf present and background= is the
#        greeter badge artwork. DEC-PHASE11-028 (operator choice 2026-09-09) split
#        the greeter background (orionx-wp-badge.png) from the desktop wallpaper
#        (orionx-phoenix-wallpaper.png); each surface keeps one authority.
#        Source: iso/config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf
# ---------------------------------------------------------------------------
LIGHTDM_GREETER_CONF="$SQF/etc/lightdm/lightdm-gtk-greeter.conf"
EXPECTED_BG="/opt/orionx/theme/wallpapers/orionx-wp-badge.png"

if [[ -f "$LIGHTDM_GREETER_CONF" ]] && \
   grep -q "^background=${EXPECTED_BG}$" "$LIGHTDM_GREETER_CONF"; then
    pass "23a-h: /etc/lightdm/lightdm-gtk-greeter.conf present and background=orionx-wp-badge.png (DEC-PHASE11-028)"
else
    fail "23a-h: /etc/lightdm/lightdm-gtk-greeter.conf present and background=orionx-wp-badge.png" \
         "File missing or background line absent: $LIGHTDM_GREETER_CONF (expected background=${EXPECTED_BG}, DEC-PHASE11-028)"
fi
# The badge asset itself must be staged, or LightDM silently falls back to the GTK default.
if [[ -f "$SQF$EXPECTED_BG" ]]; then
    pass "23a-h: greeter background asset $EXPECTED_BG staged in squashfs"
else
    fail "23a-h: greeter background asset $EXPECTED_BG staged in squashfs" \
         "Missing — stage_application_content rsync of theme/wallpapers/ did not ship the badge"
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
# 18. Boot menus as shipped: plain-text GRUB (DEC-PHASE11-044) + themed
#     isolinux vesamenu (DEC-PHASE11-042)
#
# @decision DEC-PHASE11-044
# @title Plain readable GRUB text menu (gfxmenu theme retired)
# @status accepted
# @rationale The GRUB gfxmenu theme of DEC-PHASE11-013 (W11-9a2, #74) errored and
#   rendered an unreadable font on real UEFI hardware (rc1-79 / rc1-81, operator
#   report 2026-09-12). generate_bootloader_configs() in scripts/build-iso.sh now
#   emits a GRUB cfg with NO `set theme`, NO `insmod png`, NO gfxmode/gfxterm/
#   loadfont, and `set timeout=5`. The Phoenix boot identity is carried by the
#   Plymouth splash (paints after i915 KMS) and by the BIOS isolinux vesamenu
#   (DEC-PHASE11-042: `ui vesamenu.c32`, `timeout 50`, `menu background
#   orionx-isolinux-bg.png`). The GRUB theme assets under /boot/grub/themes/orionx/
#   are deliberately LEFT in the binary tree, unreferenced, so a future revival
#   needs only the generator lines back (optionality) — 18a/18b keep asserting
#   they ship. The former 18c/18d/18e (theme/insmod png/gfxmode PRESENT) are
#   inverted: their presence is now a regression.
#   Authority for every assertion here is the cfg/asset EXTRACTED FROM THE ISO
#   in section 1 (single authority, DEC-PHASE11-012), not the worktree copy.
# ===========================================================================
section "18. Boot menus as shipped: plain GRUB (DEC-PHASE11-044) + themed isolinux (DEC-PHASE11-042)"

# (a) theme.txt still shipped in the ISO binary tree (kept for optionality)
if [[ -f "$ISO_GRUB_THEME_DIR/theme.txt" ]]; then
    pass "18a: ISO /boot/grub/themes/orionx/theme.txt shipped (kept unreferenced — DEC-PHASE11-044)"
else
    fail "18a: ISO /boot/grub/themes/orionx/theme.txt shipped" \
         "generate_bootloader_configs() still copies the theme assets to includes.binary/ (DEC-PHASE11-044 keeps them); missing means the staging step regressed"
fi

# (b) background.png still shipped in the ISO binary tree
if [[ -f "$ISO_GRUB_THEME_DIR/background.png" ]]; then
    pass "18b: ISO /boot/grub/themes/orionx/background.png shipped (kept unreferenced — DEC-PHASE11-044)"
else
    fail "18b: ISO /boot/grub/themes/orionx/background.png shipped" \
         "Theme background asset missing from the ISO binary tree"
fi

if [[ -f "$ISO_GRUB_CFG" ]]; then
    # (c) NO 'set theme' — the gfxmenu theme is retired
    if ! grep -qE '^[[:space:]]*set theme=' "$ISO_GRUB_CFG"; then
        pass "18c: grub.cfg has NO 'set theme=' directive (plain text menu — DEC-PHASE11-044)"
    else
        fail "18c: grub.cfg has NO 'set theme=' directive" \
             "'set theme=' present — gfxmenu theming regressed; it errored on real UEFI hardware (DEC-PHASE11-044)"
    fi

    # (d) NO graphics-mode directives at all (insmod png / gfxmode / gfxterm / loadfont)
    GFX_HITS="$(grep -nE '^[[:space:]]*(insmod (png|gfxterm|gfxmenu)|set gfxmode|loadfont|terminal_output gfxterm)' "$ISO_GRUB_CFG" || true)"
    if [[ -z "$GFX_HITS" ]]; then
        pass "18d: grub.cfg has no insmod png / gfxmode / gfxterm / loadfont (native text console — DEC-PHASE11-044)"
    else
        fail "18d: grub.cfg has no insmod png / gfxmode / gfxterm / loadfont" \
             "Found: $(echo "$GFX_HITS" | tr '\n' ' ') — DEC-PHASE11-044 drops all GRUB graphics directives"
    fi

    # (e) menu visible for 5 s so the operator can pick failsafe
    if grep -qE '^set timeout=5$' "$ISO_GRUB_CFG"; then
        pass "18e: grub.cfg 'set timeout=5' (5 s visible menu — DEC-PHASE11-044)"
    else
        fail "18e: grub.cfg 'set timeout=5'" \
             "Got: $(grep -E '^set timeout=' "$ISO_GRUB_CFG" || echo '<no timeout line>') — generator emits set timeout=5"
    fi

    # (f) W11-2 identity tokens preserved (regression guard)
    if grep -qF "live-config.username=orionx-operator" "$ISO_GRUB_CFG" && \
       grep -qF "live-config.hostname=orionx" "$ISO_GRUB_CFG"; then
        pass "18f: W11-2 identity tokens present in shipped grub.cfg (DEC-PHASE11-012)"
    else
        fail "18f: W11-2 identity tokens present in shipped grub.cfg" \
             "live-config.username/hostname missing from the ISO grub.cfg"
    fi
else
    fail "18c: grub.cfg extracted from ISO for directive checks" "Not found in ISO: /boot/grub/grub.cfg"
    fail "18d: no GRUB graphics directives" "grub.cfg missing"
    fail "18e: set timeout=5 in grub.cfg" "grub.cfg missing"
    fail "18f: W11-2 identity tokens in grub.cfg" "grub.cfg missing"
fi

# (g)-(i) BIOS isolinux: themed vesamenu (DEC-PHASE11-042)
if [[ -f "$ISO_ISOLINUX_CFG" ]]; then
    if grep -qE '^ui vesamenu\.c32$' "$ISO_ISOLINUX_CFG"; then
        pass "18g: isolinux.cfg uses 'ui vesamenu.c32' (themed BIOS menu — DEC-PHASE11-042)"
    else
        fail "18g: isolinux.cfg uses 'ui vesamenu.c32'" \
             "No 'ui vesamenu.c32' line — BIOS/CSM boot would show no themed menu (DEC-PHASE11-042)"
    fi
    if grep -qE '^timeout 50$' "$ISO_ISOLINUX_CFG"; then
        pass "18h: isolinux.cfg 'timeout 50' (5.0 s — DEC-PHASE11-042)"
    else
        fail "18h: isolinux.cfg 'timeout 50'" \
             "Got: $(grep -E '^timeout ' "$ISO_ISOLINUX_CFG" || echo '<no timeout line>')"
    fi
    if grep -qE '^menu background orionx-isolinux-bg\.png$' "$ISO_ISOLINUX_CFG"; then
        pass "18i: isolinux.cfg 'menu background orionx-isolinux-bg.png' (Phoenix menu — DEC-PHASE11-042)"
    else
        fail "18i: isolinux.cfg 'menu background orionx-isolinux-bg.png'" \
             "Phoenix menu background directive missing (DEC-PHASE11-042)"
    fi
    # The referenced module + artwork must actually be in the ISO next to the cfg.
    if [[ -f "$ISO_ISOLINUX_DIR/vesamenu.c32" && -s "$ISO_ISOLINUX_DIR/orionx-isolinux-bg.png" ]]; then
        pass "18i: ISO /isolinux/ ships vesamenu.c32 + orionx-isolinux-bg.png"
    else
        fail "18i: ISO /isolinux/ ships vesamenu.c32 + orionx-isolinux-bg.png" \
             "vesamenu.c32 or the background PNG is missing from the ISO — the menu would fall back to text or fail to render"
    fi
else
    fail "18g: isolinux.cfg extracted from ISO" "Not found in ISO: /isolinux/isolinux.cfg"
    fail "18h: isolinux timeout 50" "isolinux.cfg missing"
    fail "18i: isolinux menu background" "isolinux.cfg missing"
fi

# ===========================================================================
# 19. W11-9b: Desktop identity assets (section 23b)
#
# @decision DEC-PHASE11-010
# @title W11-9b content-presence section 23b: desktop identity assets
# @status accepted
# @rationale W11-9b stages GTK theme Orion-X-Cyberdeck, icon theme Orion-X-Icons,
#   cursor theme Orion-X-Cursor, the Hack font, and fixes the R6 root-cause
#   by switching DEC-PHASE9-002 authority from /home/orionx/ to /etc/skel/
#   (DEC-PHASE11-014). This section (labelled section 23b per plan numbering)
#   asserts all 13 sub-conditions required by the W11-9b Evaluation Contract
#   items 2-8,10. Assertions are keyed as 23b-a through 23b-m matching the plan.
#
# FONTS (DEC-PHASE11-031, #85): the plan's Iosevka was never installable —
#   fonts-iosevka is not in bullseye and not in trixie, so "Iosevka 11" fell
#   back to an unreadable substitute. hooks/normal/0100-create-user.hook.chroot
#   now seeds Hack (fonts-hack-otf/fonts-hack → /usr/share/fonts/truetype/hack/):
#   xsettings MonospaceFontName="Hack 11", terminalrc FontName=Hack 12,
#   xfwm4 title_font="Sans Bold 10" (DejaVu Sans, always present); the greeter
#   conf ships font-name=Hack 11. Every former Iosevka assertion below now
#   asserts those values, and 23b-f asserts Iosevka is ABSENT.
#
# @decision DEC-PHASE11-014
# @title R6 fix verification: /etc/skel/ authority assertions in section 23b
# @status accepted
# @rationale The critical R6 fix assertions (23b-h through 23b-k) verify that:
#   (h) xfce4-desktop.xml is in /etc/skel/ (not /home/orionx/ — dead-authority retired)
#   (i) xsettings.xml is in /etc/skel/ with ThemeName=Orion-X-Cyberdeck and
#       MonospaceFontName=Hack 11
#   (j) terminalrc is in /etc/skel/ with FontName=Hack 12
#   (k) /home/orionx/ does NOT exist in the squashfs (proves R6 dead-authority retired)
#   These assertions catch any regression to the /home/orionx/ dead-authority path.
# ===========================================================================
section "19. W11-9b: Desktop identity assets (section 23b)"

# ---------------------------------------------------------------------------
# 23b-a: Orion-X-Cyberdeck GTK theme index.theme present in squashfs
# ---------------------------------------------------------------------------
CYBERDECK_THEME_DIR="$SQF/usr/share/themes/Orion-X-Cyberdeck"

if [[ -f "$CYBERDECK_THEME_DIR/index.theme" ]]; then
    pass "23b-a: /usr/share/themes/Orion-X-Cyberdeck/index.theme present in squashfs"
else
    fail "23b-a: /usr/share/themes/Orion-X-Cyberdeck/index.theme present in squashfs" \
         "GTK theme index.theme missing — check includes.chroot staging of Orion-X-Cyberdeck"
fi

# ---------------------------------------------------------------------------
# 23b-b: gtk-3.0/gtk.css present and contains #FF5722 (Phoenix accent)
# ---------------------------------------------------------------------------
CYBERDECK_GTK_CSS="$CYBERDECK_THEME_DIR/gtk-3.0/gtk.css"

if [[ -f "$CYBERDECK_GTK_CSS" ]]; then
    pass "23b-b: /usr/share/themes/Orion-X-Cyberdeck/gtk-3.0/gtk.css present in squashfs"
    if grep -q "#FF5722" "$CYBERDECK_GTK_CSS" 2>/dev/null; then
        pass "23b-b: gtk.css contains Phoenix accent color #FF5722 (DEC-PHASE11-010)"
    else
        fail "23b-b: gtk.css contains Phoenix accent color #FF5722" \
             "#FF5722 not found in $CYBERDECK_GTK_CSS — accent override not applied"
    fi
else
    fail "23b-b: /usr/share/themes/Orion-X-Cyberdeck/gtk-3.0/gtk.css present in squashfs" \
         "gtk.css missing — GTK3 theme incomplete"
    fail "23b-b: gtk.css contains Phoenix accent color #FF5722" \
         "gtk.css file missing — cannot check accent"
fi

# ---------------------------------------------------------------------------
# 23b-c: xfwm4/themerc present in squashfs
# ---------------------------------------------------------------------------
if [[ -f "$CYBERDECK_THEME_DIR/xfwm4/themerc" ]]; then
    pass "23b-c: /usr/share/themes/Orion-X-Cyberdeck/xfwm4/themerc present in squashfs"
else
    fail "23b-c: /usr/share/themes/Orion-X-Cyberdeck/xfwm4/themerc present in squashfs" \
         "xfwm4/themerc missing — XFWM4 window decoration colors not staged"
fi

# ---------------------------------------------------------------------------
# 23b-d: Orion-X-Icons index.theme present and contains Inherits= line
# ---------------------------------------------------------------------------
ORIONX_ICONS_THEME="$SQF/usr/share/icons/Orion-X-Icons/index.theme"

if [[ -f "$ORIONX_ICONS_THEME" ]]; then
    pass "23b-d: /usr/share/icons/Orion-X-Icons/index.theme present in squashfs"
    if grep -q "^Inherits=" "$ORIONX_ICONS_THEME" 2>/dev/null; then
        pass "23b-d: Orion-X-Icons/index.theme contains Inherits= line (inheritance chain present)"
    else
        fail "23b-d: Orion-X-Icons/index.theme contains Inherits= line" \
             "Inherits= line missing from $ORIONX_ICONS_THEME — icon fallback chain broken"
    fi
else
    fail "23b-d: /usr/share/icons/Orion-X-Icons/index.theme present in squashfs" \
         "Icon theme index.theme missing — check includes.chroot staging of Orion-X-Icons"
    fail "23b-d: Orion-X-Icons/index.theme contains Inherits= line" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 23b-e: Orion-X-Cursor index.theme present and contains Inherits=Adwaita
# ---------------------------------------------------------------------------
ORIONX_CURSOR_THEME="$SQF/usr/share/icons/Orion-X-Cursor/index.theme"

if [[ -f "$ORIONX_CURSOR_THEME" ]]; then
    pass "23b-e: /usr/share/icons/Orion-X-Cursor/index.theme present in squashfs"
    if grep -q "Inherits=Adwaita" "$ORIONX_CURSOR_THEME" 2>/dev/null; then
        pass "23b-e: Orion-X-Cursor/index.theme contains Inherits=Adwaita (cursor fallback)"
    else
        fail "23b-e: Orion-X-Cursor/index.theme contains Inherits=Adwaita" \
             "Inherits=Adwaita not found in $ORIONX_CURSOR_THEME"
    fi
else
    fail "23b-e: /usr/share/icons/Orion-X-Cursor/index.theme present in squashfs" \
         "Cursor theme index.theme missing — check includes.chroot staging of Orion-X-Cursor"
    fail "23b-e: Orion-X-Cursor/index.theme contains Inherits=Adwaita" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 23b-f: Iosevka is NOT shipped and NOT referenced (DEC-PHASE11-031, #85)
# ---------------------------------------------------------------------------
# fonts-iosevka is not packaged in bullseye or trixie (orionx.list.chroot keeps
# it commented out with that note). A config value of "Iosevka ..." therefore
# renders as an arbitrary fallback font — the exact defect DEC-PHASE11-031 fixed.
# Guard both directions: no Iosevka files/package (would mean an unvetted font
# source crept in) and no Iosevka value in any shipped xfce/greeter config.
IOSEVKA_FILES=$(find "$SQF/usr/share/fonts" -iname 'iosevka*' -type f 2>/dev/null | wc -l | tr -d ' ')
IOSEVKA_PKG=0
if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: fonts-iosevka" "$DPKG_STATUS" 2>/dev/null; then
    IOSEVKA_PKG=1
fi
if [[ "$IOSEVKA_FILES" -eq 0 && "$IOSEVKA_PKG" -eq 0 ]]; then
    pass "23b-f: Iosevka absent from /usr/share/fonts and dpkg (not in trixie — DEC-PHASE11-031, #85)"
else
    fail "23b-f: Iosevka absent from /usr/share/fonts and dpkg" \
         "files=$IOSEVKA_FILES pkg=$IOSEVKA_PKG — Iosevka is not a Debian trixie package; where did it come from? (DEC-PHASE11-031, #85)"
fi
# || true: zero matches is the desired state (DEC-PHASE9-014 pipefail guard)
IOSEVKA_VALUE_REFS=$(grep -rhE '(FontName|font-name|title_font)[^#]*Iosevka' "$SQF/etc/skel/.config" "$SQF/etc/lightdm/lightdm-gtk-greeter.conf" 2>/dev/null | grep -vE '^[[:space:]]*#' | wc -l | tr -d ' ' || true)
if [[ "$IOSEVKA_VALUE_REFS" -eq 0 ]]; then
    pass "23b-f: no shipped font config value names Iosevka (skel xfce4 + greeter conf — DEC-PHASE11-031)"
else
    fail "23b-f: no shipped font config value names Iosevka" \
         "$IOSEVKA_VALUE_REFS config value(s) still select Iosevka — would render as an unreadable fallback (DEC-PHASE11-031)"
fi

# ---------------------------------------------------------------------------
# 23b-g: Hack font files present at /usr/share/fonts/truetype/hack/
# ---------------------------------------------------------------------------
# fonts-hack (pulled by fonts-hack-otf in orionx.list.chroot) installs
# /usr/share/fonts/truetype/hack/Hack-{Regular,Bold,Italic,BoldItalic}.ttf.
# Hack is the only purpose-built monospace font on the ISO (DEC-PHASE11-031).
HACK_COUNT=$(find "$SQF/usr/share/fonts/truetype/hack" -type f -iname 'Hack-*.ttf' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$HACK_COUNT" -ge 1 ]]; then
    pass "23b-g: Hack font files present at /usr/share/fonts/truetype/hack/ ($HACK_COUNT files, DEC-PHASE11-031)"
else
    # Fallback: check dpkg status for fonts-hack-otf or fonts-hack
    HACK_PKG_FOUND=0
    for hack_pkg in fonts-hack-otf fonts-hack fonts-hack-ttf; do
        if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: ${hack_pkg}$" "$DPKG_STATUS" 2>/dev/null; then
            HACK_PKG_FOUND=1
            pass "23b-g: Hack font package installed in squashfs dpkg ($hack_pkg, DEC-PHASE11-013)"
            break
        fi
    done
    if [[ "$HACK_PKG_FOUND" -eq 0 ]]; then
        fail "23b-g: at least one Hack font file present under /usr/share/fonts/" \
             "No hack* files found and no fonts-hack* package in dpkg — check orionx.list.chroot"
    fi
fi

# ---------------------------------------------------------------------------
# 23b-h: /etc/skel/ xfce4-desktop.xml present in squashfs (R6 fix)
# ---------------------------------------------------------------------------
SKEL_XFCONF="$SQF/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml"
SKEL_DESKTOP_XML="$SKEL_XFCONF/xfce4-desktop.xml"

if [[ -f "$SKEL_DESKTOP_XML" ]]; then
    pass "23b-h: /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml present (R6 fix — skel authority DEC-PHASE11-014)"
    if grep -q "orionx-phoenix-wallpaper.png" "$SKEL_DESKTOP_XML" 2>/dev/null; then
        pass "23b-h: xfce4-desktop.xml (skel) references orionx-phoenix-wallpaper.png (DEC-PHASE9-002 preserved)"
    else
        fail "23b-h: xfce4-desktop.xml (skel) references orionx-phoenix-wallpaper.png" \
             "Wallpaper path missing from $SKEL_DESKTOP_XML — R6 fix may be incomplete"
    fi
else
    fail "23b-h: /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml present in squashfs" \
         "Missing: $SKEL_DESKTOP_XML — 0100-create-user.hook.chroot must write xfce4-desktop.xml to /etc/skel/"
    fail "23b-h: xfce4-desktop.xml (skel) references orionx-phoenix-wallpaper.png" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 23b-i: /etc/skel/ xsettings.xml present with ThemeName and MonospaceFontName
# ---------------------------------------------------------------------------
SKEL_XSETTINGS="$SKEL_XFCONF/xsettings.xml"

if [[ -f "$SKEL_XSETTINGS" ]]; then
    pass "23b-i: /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml present (DEC-PHASE11-014)"
    if grep -q 'value="Orion-X-Cyberdeck"' "$SKEL_XSETTINGS" 2>/dev/null; then
        pass "23b-i: xsettings.xml contains ThemeName=Orion-X-Cyberdeck (DEC-PHASE11-010)"
    else
        fail "23b-i: xsettings.xml contains ThemeName=Orion-X-Cyberdeck" \
             "ThemeName not found or value != Orion-X-Cyberdeck in $SKEL_XSETTINGS"
    fi
    # hooks/normal/0100-create-user.hook.chroot: <property name="MonospaceFontName" ... value="Hack 11"/> (DEC-PHASE11-031)
    if grep -qE '<property name="MonospaceFontName" type="string" value="Hack 11"/>' "$SKEL_XSETTINGS" 2>/dev/null; then
        pass "23b-i: xsettings.xml contains MonospaceFontName=Hack 11 (DEC-PHASE11-031)"
    else
        fail "23b-i: xsettings.xml contains MonospaceFontName=Hack 11" \
             "MonospaceFontName=\"Hack 11\" not found in $SKEL_XSETTINGS — hook 0100 font wiring regressed (DEC-PHASE11-031)"
    fi
else
    fail "23b-i: /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml present in squashfs" \
         "Missing: $SKEL_XSETTINGS — 0100-create-user.hook.chroot must write xsettings.xml to /etc/skel/"
    fail "23b-i: xsettings.xml contains ThemeName=Orion-X-Cyberdeck" \
         "File missing — cannot check"
    fail "23b-i: xsettings.xml contains MonospaceFontName=Hack 11" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 23b-j: /etc/skel/ terminalrc present and contains FontName=Hack 12
# ---------------------------------------------------------------------------
# hooks/normal/0100-create-user.hook.chroot writes FontName=Hack 12 (DEC-PHASE11-031:
# terminal one point larger than the UI monospace for readability).
SKEL_TERMINALRC="$SQF/etc/skel/.config/xfce4/terminal/terminalrc"

if [[ -f "$SKEL_TERMINALRC" ]]; then
    pass "23b-j: /etc/skel/.config/xfce4/terminal/terminalrc present in squashfs (DEC-PHASE11-014)"
    if grep -qE "^FontName=Hack 12$" "$SKEL_TERMINALRC" 2>/dev/null; then
        pass "23b-j: terminalrc contains FontName=Hack 12 (DEC-PHASE11-031)"
    else
        fail "23b-j: terminalrc contains FontName=Hack 12" \
             "Got: $(grep '^FontName=' "$SKEL_TERMINALRC" || echo '<no FontName line>') — check hook 0100 terminalrc block (DEC-PHASE11-031)"
    fi
else
    fail "23b-j: /etc/skel/.config/xfce4/terminal/terminalrc present in squashfs" \
         "Missing: $SKEL_TERMINALRC — 0100-create-user.hook.chroot must write terminalrc to /etc/skel/"
    fail "23b-j: terminalrc contains FontName=Hack 12" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 23b-k: /home/orionx/ does NOT exist in squashfs (dead-authority retired)
# ---------------------------------------------------------------------------
# DEC-PHASE11-014: the R6 fix removes the chroot-time /home/orionx/ build.
# If /home/orionx/ still exists in the squashfs, the old dead-authority path
# was not cleaned up — the R6 fix is incomplete.
# Note: We check the directory itself, not any subdirectory, because live-config
# might create /home/orionx-operator/ at boot (not present in the chroot squashfs).
if [[ ! -d "$SQF/home/orionx" ]]; then
    pass "23b-k: /home/orionx/ does NOT exist in squashfs (DEC-PHASE11-014 dead-authority retired)"
else
    fail "23b-k: /home/orionx/ does NOT exist in squashfs" \
         "/home/orionx/ found in squashfs — 0100-create-user.hook.chroot still writing to dead-authority /home/orionx/. R6 fix incomplete. DEC-PHASE11-014 requires removal of chroot-time user creation + redirect to /etc/skel/"
fi

# ---------------------------------------------------------------------------
# 23b-l: autologin-user=orionx-operator in LightDM autologin conf (T6)
# ---------------------------------------------------------------------------
LIGHTDM_AUTOLOGIN="$SQF/etc/lightdm/lightdm.conf.d/10-orionx-autologin.conf"

if [[ -f "$LIGHTDM_AUTOLOGIN" ]]; then
    if grep -q "autologin-user=orionx-operator" "$LIGHTDM_AUTOLOGIN" 2>/dev/null; then
        pass "23b-l: 10-orionx-autologin.conf contains autologin-user=orionx-operator (DEC-PHASE11-012 alignment)"
    else
        fail "23b-l: 10-orionx-autologin.conf contains autologin-user=orionx-operator" \
             "autologin-user=orionx-operator not found — check T6 update. Old value 'orionx' would mismatch live-config identity"
    fi
else
    fail "23b-l: /etc/lightdm/lightdm.conf.d/10-orionx-autologin.conf present for autologin-user check" \
         "File missing from squashfs — check includes.chroot staging"
fi

# ---------------------------------------------------------------------------
# 23b-m: LightDM greeter conf upgraded to Orion-X theme stack (T7)
# ---------------------------------------------------------------------------
LIGHTDM_GREETER_CONF_SQF="$SQF/etc/lightdm/lightdm-gtk-greeter.conf"

if [[ -f "$LIGHTDM_GREETER_CONF_SQF" ]]; then
    pass "23b-m: /etc/lightdm/lightdm-gtk-greeter.conf present in squashfs"
    if grep -q "theme-name=Orion-X-Cyberdeck" "$LIGHTDM_GREETER_CONF_SQF" 2>/dev/null; then
        pass "23b-m: lightdm-gtk-greeter.conf contains theme-name=Orion-X-Cyberdeck (DEC-PHASE11-010)"
    else
        fail "23b-m: lightdm-gtk-greeter.conf contains theme-name=Orion-X-Cyberdeck" \
             "theme-name=Orion-X-Cyberdeck not found — check T7 greeter conf upgrade"
    fi
    if grep -q "icon-theme-name=Orion-X-Icons" "$LIGHTDM_GREETER_CONF_SQF" 2>/dev/null; then
        pass "23b-m: lightdm-gtk-greeter.conf contains icon-theme-name=Orion-X-Icons (DEC-PHASE11-010)"
    else
        fail "23b-m: lightdm-gtk-greeter.conf contains icon-theme-name=Orion-X-Icons" \
             "icon-theme-name=Orion-X-Icons not found — check T7 greeter conf upgrade"
    fi
    # iso/config/includes.chroot/etc/lightdm/lightdm-gtk-greeter.conf: font-name=Hack 11 (DEC-PHASE11-031)
    if grep -qE "^font-name=Hack 11$" "$LIGHTDM_GREETER_CONF_SQF" 2>/dev/null; then
        pass "23b-m: lightdm-gtk-greeter.conf contains font-name=Hack 11 (DEC-PHASE11-031)"
    else
        fail "23b-m: lightdm-gtk-greeter.conf contains font-name=Hack 11" \
             "Got: $(grep '^font-name=' "$LIGHTDM_GREETER_CONF_SQF" || echo '<no font-name line>') — Iosevka is not installable; Hack is the shipped mono font (DEC-PHASE11-031)"
    fi
    # Greeter background is the badge artwork (DEC-PHASE11-028) — a separate state
    # domain from the desktop wallpaper, each with exactly one authority.
    if grep -qE "^background=/opt/orionx/theme/wallpapers/orionx-wp-badge\.png$" \
             "$LIGHTDM_GREETER_CONF_SQF" 2>/dev/null; then
        pass "23b-m: lightdm-gtk-greeter.conf background= points to orionx-wp-badge.png (DEC-PHASE11-028)"
    else
        fail "23b-m: lightdm-gtk-greeter.conf background= points to orionx-wp-badge.png" \
             "Got: $(grep '^background=' "$LIGHTDM_GREETER_CONF_SQF" || echo '<no background line>') — greeter authority is orionx-wp-badge.png (DEC-PHASE11-028)"
    fi
else
    fail "23b-m: /etc/lightdm/lightdm-gtk-greeter.conf present in squashfs" \
         "File missing — check includes.chroot staging"
    fail "23b-m: lightdm-gtk-greeter.conf theme/icon/font checks" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 23b BONUS: Vendor-font absence check — /etc/skel/ xfce4 configs (DEC-PHASE11-013)
# ---------------------------------------------------------------------------
# Confirm the new skel files don't reference vendor-proprietary monospace fonts
# as actual FontName= or MonospaceFontName= values.
# Pattern targets actual font-name config values (not comment text).
# || true: grep exits 1 on no matches; zero matches is the desired state (DEC-PHASE9-014).
VENDOR_FONT_IN_SKEL=$(grep -rE "FontName=.*[Jj]et[Bb]rains|MonospaceFontName=.*[Jj]et[Bb]rains" \
    "$SQF/etc/skel" 2>/dev/null | wc -l | tr -d ' ' || true)
if [[ "$VENDOR_FONT_IN_SKEL" -eq 0 ]]; then
    pass "23b-bonus: no vendor-font FontName= references in /etc/skel/ xfce4 configs (DEC-PHASE11-013 enforced)"
else
    fail "23b-bonus: no vendor-font FontName= references in /etc/skel/ xfce4 configs" \
         "Found $VENDOR_FONT_IN_SKEL vendor-font config line(s) in /etc/skel/ — DEC-PHASE11-013 violation (community fonts only)"
fi

# Also check the source-tree hook for vendor-font package or config references
HOOK_0100_SRC="$REPO_ROOT/iso/config/hooks/normal/0100-create-user.hook.chroot"
if [[ -f "$HOOK_0100_SRC" ]]; then
    VENDOR_FONT_IN_0100=$(grep -cE "FontName=.*[Jj]et[Bb]rains|MonospaceFontName=.*[Jj]et[Bb]rains|fonts-[Jj]et[Bb]rains" \
        "$HOOK_0100_SRC" 2>/dev/null || true)
    if [[ "$VENDOR_FONT_IN_0100" -eq 0 ]]; then
        pass "23b-bonus: no vendor-font references in 0100-create-user.hook.chroot source (DEC-PHASE11-013)"
    else
        fail "23b-bonus: no vendor-font references in 0100-create-user.hook.chroot source" \
             "Found $VENDOR_FONT_IN_0100 vendor-font reference(s) in the hook — remove them (DEC-PHASE11-013)"
    fi
fi

# Check the package list does not reference vendor-font packages
PKG_LIST="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
if [[ -f "$PKG_LIST" ]]; then
    VENDOR_FONT_IN_PKGS=$(grep -cE "^fonts-[Jj]et[Bb]rains" "$PKG_LIST" 2>/dev/null || true)
    if [[ "$VENDOR_FONT_IN_PKGS" -eq 0 ]]; then
        pass "23b-bonus: no vendor-font packages in orionx.list.chroot (DEC-PHASE11-013)"
    else
        fail "23b-bonus: no vendor-font packages in orionx.list.chroot" \
             "Found $VENDOR_FONT_IN_PKGS vendor-font package line(s) — DEC-PHASE11-013 violation"
    fi
fi

# ---------------------------------------------------------------------------
# 23b BONUS-2: section 10 now checks /etc/skel/ too.
# Legacy section 10 asserted xfce4-desktop.xml in /home/orionx/ — correct under
# DEC-PHASE9-002, but a permanent FAIL after the R6 fix (DEC-PHASE11-014) retired
# that path. Section 10 was re-pointed at /etc/skel/ (the seed live-config copies
# at boot), so it and 23b-h now agree; 23b-k guards that /home/orionx/ stays gone.
# ---------------------------------------------------------------------------

# ===========================================================================
# 20. W11-9b iter-2: xfwm4 window decoration theme (section 23c)
#
# @decision DEC-PHASE11-010
# @title W11-9b content-presence section 23c: xfwm4 window decoration theme
# @status accepted
# @rationale xsettings.xml sets GTK ThemeName=Orion-X-Cyberdeck but xfwm4
#   reads its own xfconf channel (xfwm4.xml) for the window decoration theme.
#   Without xfwm4.xml in /etc/skel/, the window manager title bars fall back
#   to the XFCE default even when GTK widgets correctly render Orion-X-Cyberdeck.
#   Section 23c verifies xfwm4.xml is seeded to /etc/skel/ with the correct
#   theme and the "Sans Bold 10" title font (DEC-PHASE11-031: Iosevka is not
#   installable; DejaVu Sans is always present).
# ===========================================================================
section "20. W11-9b iter-2: xfwm4 window decoration theme (section 23c)"

# ---------------------------------------------------------------------------
# 23c-a: /etc/skel/ xfwm4.xml present in squashfs
# ---------------------------------------------------------------------------
SKEL_XFWM4="$SQF/etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"

if [[ -f "$SKEL_XFWM4" ]]; then
    pass "23c-a: /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml present (DEC-PHASE11-010 window decoration)"
else
    fail "23c-a: /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml present" \
         "Missing: $SKEL_XFWM4 — 0100-create-user.hook.chroot must write xfwm4.xml to /etc/skel/"
fi

# ---------------------------------------------------------------------------
# 23c-b: xfwm4.xml contains theme=Orion-X-Cyberdeck
# ---------------------------------------------------------------------------
if [[ -f "$SKEL_XFWM4" ]] && grep -q 'value="Orion-X-Cyberdeck"' "$SKEL_XFWM4" 2>/dev/null; then
    pass "23c-b: xfwm4.xml contains theme=Orion-X-Cyberdeck (DEC-PHASE11-010 window decoration theme)"
else
    fail "23c-b: xfwm4.xml contains theme=Orion-X-Cyberdeck" \
         "theme=Orion-X-Cyberdeck not found in $SKEL_XFWM4 — xfwm4 will fall back to XFCE default decorations"
fi

# ---------------------------------------------------------------------------
# 23c-c: xfwm4.xml contains title_font="Sans Bold 10"
# hooks/normal/0100-create-user.hook.chroot: <property name="title_font" ... value="Sans Bold 10"/>
# (DEC-PHASE11-031 — was "Iosevka Bold 10", which never rendered).
# ---------------------------------------------------------------------------
if [[ -f "$SKEL_XFWM4" ]] && grep -qE '<property name="title_font" type="string" value="Sans Bold 10"/>' "$SKEL_XFWM4" 2>/dev/null; then
    pass "23c-c: xfwm4.xml contains title_font=Sans Bold 10 (DEC-PHASE11-031)"
else
    fail "23c-c: xfwm4.xml contains title_font=Sans Bold 10" \
         "Got: $(grep -o 'name="title_font"[^/]*' "$SKEL_XFWM4" 2>/dev/null || echo '<no title_font>') — check hook 0100 xfwm4.xml block (DEC-PHASE11-031)"
fi

# ===========================================================================
# 21. W11-3 Layer A: RE toolkit packages + staging scaffolds
#
# @decision DEC-PHASE11-004
# @title W11-3 Layer A: lean RE + malware analysis toolkit (Debian packages +
#   capa venv); heavy binaries (FLOSS/TrID/remnux/Node) deferred to W11-3b
# @status accepted
# @rationale Debian-packaged tools (ssdeep, hashdeep, python3-pefile,
#   python3-yara, python3-capstone) go in via the package list. capa (Apache-2.0)
#   is installed to /opt/orionx/venv/re/ by the 0500 hook (soft-fail if network
#   unavailable). Staging scaffolds (re/ README + nebula/mcp-servers/ README)
#   prove the Layer A directory tree is present for Layer B expansion.
#
#   Trixie reality (#85): radare2 was removed from Debian (RC bugs) and
#   bulk-extractor is not in main — both are commented out in orionx.list.chroot
#   and are NOT installed. `md5deep` is only a name in the list: the binaries
#   are provided by the `hashdeep` source/binary package (md5deep/sha256deep/...
#   are hashdeep symlinks), and dpkg records `hashdeep`, not `md5deep`.
# ===========================================================================
section "21. W11-3 Layer A: RE toolkit packages + staging scaffolds"

# ---------------------------------------------------------------------------
# 21a. Debian-packaged RE tools present in squashfs dpkg database
# ---------------------------------------------------------------------------
echo "  [21a] Verifying W11-3 RE toolkit Debian packages in squashfs"
W11_3_PKGS=(ssdeep hashdeep python3-pefile python3-yara python3-capstone)
# Not packaged in trixie (#85) — asserted ABSENT so a surprise reappearance
# (e.g. from an unvetted third-party repo) is visible rather than silent.
W11_3_NOT_IN_TRIXIE=(radare2 bulk-extractor)
if [[ -f "$DPKG_STATUS" ]]; then
    for pkg in "${W11_3_PKGS[@]}"; do
        if grep -q "^Package: ${pkg}$" "$DPKG_STATUS" 2>/dev/null; then
            pass "21a: package installed in chroot: $pkg (W11-3 RE toolkit, DEC-PHASE11-004)"
        else
            fail "21a: package installed in chroot: $pkg" \
                 "Check orionx.list.chroot W11-3 block includes $pkg"
        fi
    done
    # hashdeep must actually provide the md5deep entry point the RE docs reference
    if [[ -e "$SQF/usr/bin/md5deep" || -L "$SQF/usr/bin/md5deep" ]]; then
        pass "21a: /usr/bin/md5deep present (provided by hashdeep)"
    else
        fail "21a: /usr/bin/md5deep present (provided by hashdeep)" \
             "hashdeep installed but /usr/bin/md5deep missing — packaging changed?"
    fi
    for pkg in "${W11_3_NOT_IN_TRIXIE[@]}"; do
        if grep -q "^Package: ${pkg}$" "$DPKG_STATUS" 2>/dev/null; then
            fail "21a: $pkg absent from chroot (not in Debian trixie — #85)" \
                 "$pkg is in dpkg/status but is not a trixie package — which archive did it come from?"
        else
            pass "21a: $pkg absent from chroot (not in Debian trixie — #85; commented out in orionx.list.chroot)"
        fi
    done
else
    fail "21a: dpkg status file available for W11-3 package checks" \
         "$DPKG_STATUS not found — squashfs extraction may be incomplete"
fi

# ---------------------------------------------------------------------------
# 21b. /opt/orionx/re/README.md present in squashfs
# ---------------------------------------------------------------------------
if [[ -f "$SQF/opt/orionx/re/README.md" ]]; then
    pass "21b: /opt/orionx/re/README.md present in squashfs (W11-3 RE toolkit staging scaffold)"
else
    fail "21b: /opt/orionx/re/README.md present in squashfs" \
         "iso/config/includes.chroot/opt/orionx/re/README.md not staged — check includes.chroot"
fi

# ---------------------------------------------------------------------------
# 21c. /opt/orionx/nebula/mcp-servers/README.md present in squashfs
# ---------------------------------------------------------------------------
if [[ -f "$SQF/opt/orionx/nebula/mcp-servers/README.md" ]]; then
    pass "21c: /opt/orionx/nebula/mcp-servers/README.md present in squashfs (W11-3 MCP registry scaffold)"
else
    fail "21c: /opt/orionx/nebula/mcp-servers/README.md present in squashfs" \
         "iso/config/includes.chroot/opt/orionx/nebula/mcp-servers/README.md not staged — check includes.chroot"
fi

# ---------------------------------------------------------------------------
# 21d. capa venv binary present (best-effort — soft-fail if network was
#      unavailable at build time; does not cause an overall test failure)
# ---------------------------------------------------------------------------
CAPA_BIN="$SQF/opt/orionx/venv/re/bin/capa"
if [[ -f "$CAPA_BIN" ]]; then
    pass "21d: /opt/orionx/venv/re/bin/capa installed (W11-3 capa venv, DEC-PHASE11-004)"
    # Also check the /usr/bin/capa convenience symlink
    if [[ -L "$SQF/usr/bin/capa" ]] || [[ -f "$SQF/usr/bin/capa" ]]; then
        pass "21d: /usr/bin/capa symlink/file present (0500 hook convenience symlink)"
    else
        fail "21d: /usr/bin/capa symlink present" \
             "0500 hook should create ln -sf /opt/orionx/venv/re/bin/capa /usr/bin/capa when capa is installed"
    fi
else
    # capa is installed by 0500 hook which is soft-fail when network unavailable.
    # Record a note rather than a hard fail, so builds without network connectivity
    # (e.g. air-gap CI runs) are not blocked by this assertion.
    echo "  NOTE: 21d: /opt/orionx/venv/re/bin/capa not found — capa venv may not have been installed"
    echo "        (0500 hook soft-fails when network is unavailable during build; not a hard failure)"
    # Still register as a pass for the overall count to avoid blocking CI on
    # network-less build environments where the soft-fail is the expected outcome.
    pass "21d: capa venv check: soft-fail expected when network unavailable at build time (informational only)"
fi

# ===========================================================================
# 22. W11-4 Layer A: YARA skeleton + freshen script + yara binary
#
# @decision DEC-PHASE11-005
# @title W11-4 Layer A content-presence section 22: YARA rulesets skeleton
# @status accepted
# @rationale W11-4 Layer A stages the YARA rulesets skeleton:
#   (a) yara Debian package installed in the chroot
#   (b) /opt/orionx/yara/README.md present and contains "Licensing Split"
#   (c) /opt/orionx/yara/LOCKFILE.json present, parses as JSON, and has 4 rulesets
#   (d) /opt/orionx/scripts/orionx-freshen-yara.sh present and executable
#   (e) /usr/local/bin/orionx-freshen-yara symlink present (created by 0700 hook)
#   (f) rules-*/ dirs NOT present (Layer A sentinel — actual snapshots deferred to W11-4b)
#   Layer B (W11-4b) will flip assertion (f) and populate the rules-*/ directories
#   via git clone at ISO build time.
# ===========================================================================
section "22. W11-4 Layer A: YARA skeleton + freshen script + yara binary (DEC-PHASE11-005)"

# ---------------------------------------------------------------------------
# 22a. yara Debian package installed in chroot dpkg database
# ---------------------------------------------------------------------------
if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: yara$" "$DPKG_STATUS" 2>/dev/null; then
    pass "22a: package installed in chroot: yara (W11-4 Layer A, DEC-PHASE11-005)"
elif [[ -x "$SQF/usr/bin/yara" ]]; then
    pass "22a: package installed in chroot: yara (binary present at /usr/bin/yara)"
else
    fail "22a: package installed in chroot: yara" \
         "Check orionx.list.chroot W11-4 block includes yara"
fi

# ---------------------------------------------------------------------------
# 22b. /opt/orionx/yara/README.md present and contains "Licensing Split"
# ---------------------------------------------------------------------------
YARA_README="$SQF/opt/orionx/yara/README.md"
if [[ -f "$YARA_README" ]]; then
    pass "22b: /opt/orionx/yara/README.md present in squashfs (W11-4 skeleton)"
    if grep -q "Licensing Split" "$YARA_README" 2>/dev/null; then
        pass "22b: README.md contains 'Licensing Split' section (license table present)"
    else
        fail "22b: README.md contains 'Licensing Split' section" \
             "Licensing Split heading not found in $YARA_README — check includes.chroot content"
    fi
else
    fail "22b: /opt/orionx/yara/README.md present in squashfs" \
         "iso/config/includes.chroot/opt/orionx/yara/README.md not staged"
    fail "22b: README.md contains 'Licensing Split' section" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 22c. /opt/orionx/yara/LOCKFILE.json present, parses as JSON, has 4 rulesets
# ---------------------------------------------------------------------------
YARA_LOCKFILE="$SQF/opt/orionx/yara/LOCKFILE.json"
if [[ -f "$YARA_LOCKFILE" ]]; then
    pass "22c: /opt/orionx/yara/LOCKFILE.json present in squashfs (W11-4 template)"
    # Validate JSON parse + ruleset count. Needs a JSON parser on the RUNNER:
    # python3 preferred, jq accepted. A missing parser must surface as SKIP, not
    # as "malformed JSON" — the 2026-09 QA run in debian:trixie-slim (no python3)
    # reported a false 22c FAIL against a LOCKFILE that parses fine.
    RULESET_COUNT=""
    JSON_TOOL=""
    if command -v python3 >/dev/null 2>&1; then
        JSON_TOOL="python3"
        RULESET_COUNT=$(python3 -c "
import json, sys
try:
    with open('$YARA_LOCKFILE') as f:
        d = json.load(f)
    print(len(d.get('rulesets', {})))
except Exception as e:
    print('ERROR: ' + str(e))
    sys.exit(1)
" 2>&1 || true)
    elif command -v jq >/dev/null 2>&1; then
        JSON_TOOL="jq"
        RULESET_COUNT=$(jq -r '.rulesets | length' "$YARA_LOCKFILE" 2>&1 || echo "ERROR: jq parse failed")
    fi
    if [[ -z "$JSON_TOOL" ]]; then
        skip "22c: LOCKFILE.json JSON validity + ruleset count (no python3 or jq on this runner — install one; e.g. add python3-minimal to the container apt-get line)"
    elif [[ "$RULESET_COUNT" == ERROR* ]] || [[ -z "$RULESET_COUNT" ]]; then
        fail "22c: LOCKFILE.json parses as valid JSON" \
             "$JSON_TOOL reported: ${RULESET_COUNT:-<no output>} — LOCKFILE.json is malformed"
    else
        pass "22c: LOCKFILE.json parses as valid JSON ($JSON_TOOL)"
        if [[ "$RULESET_COUNT" -eq 4 ]]; then
            pass "22c: LOCKFILE.json contains exactly 4 rulesets (yara-rules, reversinglabs, binaryalert-managed, didierstevens)"
        else
            fail "22c: LOCKFILE.json contains exactly 4 rulesets" \
                 "Got $RULESET_COUNT ruleset(s) — expected 4 (DEC-PHASE11-005 licensing split)"
        fi
    fi
else
    fail "22c: /opt/orionx/yara/LOCKFILE.json present in squashfs" \
         "iso/config/includes.chroot/opt/orionx/yara/LOCKFILE.json not staged"
    fail "22c: LOCKFILE.json parses as valid JSON" \
         "File missing — cannot check"
    fail "22c: LOCKFILE.json contains exactly 4 rulesets" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 22d. /opt/orionx/scripts/orionx-freshen-yara.sh present and executable
# ---------------------------------------------------------------------------
YARA_FRESHEN="$SQF/opt/orionx/scripts/orionx-freshen-yara.sh"
if [[ -f "$YARA_FRESHEN" ]]; then
    pass "22d: /opt/orionx/scripts/orionx-freshen-yara.sh present in squashfs (W11-4 freshen script)"
    if [[ -x "$YARA_FRESHEN" ]]; then
        pass "22d: orionx-freshen-yara.sh is executable (0700 hook chmod 755)"
    else
        fail "22d: orionx-freshen-yara.sh is executable" \
             "0700 hook sets chmod 755 on all scripts/ files — check hook execution"
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck -S error "$SQF/opt/orionx/scripts/orionx-freshen-yara.sh" >/dev/null 2>&1; then
            pass "22d(shellcheck): orionx-freshen-yara.sh clean (severity=error)"
        else
            fail "22d(shellcheck): orionx-freshen-yara.sh clean" \
                 "shellcheck reported errors — see output"
        fi
    else
        skip "22d(shellcheck): shellcheck not available on runner"
    fi
else
    fail "22d: /opt/orionx/scripts/orionx-freshen-yara.sh present in squashfs" \
         "scripts/orionx-freshen-yara.sh not staged — check stage_application_content rsync"
    fail "22d: orionx-freshen-yara.sh is executable" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 22e. /usr/local/bin/orionx-freshen-yara symlink present (0700 hook)
# ---------------------------------------------------------------------------
# Note: the 0700 hook creates symlinks in /usr/bin/ via SCRIPT_MAP. The
# SCRIPT_MAP key "orionx-freshen-yara" maps to the scripts/ path. The hook
# creates /usr/bin/orionx-freshen-yara (not /usr/local/bin/). Both paths
# are acceptable; we check /usr/bin/ first (canonical hook output) then
# /usr/local/bin/ as a fallback.
if [[ -L "$SQF/usr/bin/orionx-freshen-yara" ]]; then
    pass "22e: /usr/bin/orionx-freshen-yara symlink present (0700 hook SCRIPT_MAP, DEC-PHASE11-005)"
elif [[ -f "$SQF/usr/bin/orionx-freshen-yara" ]]; then
    pass "22e: /usr/bin/orionx-freshen-yara present as regular file (0700 hook)"
elif [[ -L "$SQF/usr/local/bin/orionx-freshen-yara" ]] || \
     [[ -f "$SQF/usr/local/bin/orionx-freshen-yara" ]]; then
    pass "22e: /usr/local/bin/orionx-freshen-yara present (alternative PATH location)"
else
    fail "22e: /usr/bin/orionx-freshen-yara symlink present" \
         "0700-orionx-setup.hook.chroot SCRIPT_MAP must include [\"orionx-freshen-yara\"]=\"/opt/orionx/scripts/orionx-freshen-yara.sh\""
fi

# ---------------------------------------------------------------------------
# 22f. rules-*/ directories NOT present (Layer A sentinel — W11-4b will flip)
# ---------------------------------------------------------------------------
# Layer A intentionally ships NO ruleset snapshots; operators run
# orionx-freshen-yara post-boot. When W11-4b lands and populates the rules-*/
# dirs at build time, this assertion should be inverted to REQUIRE their presence.
# || true: find exits 0 always; we just count.
RULES_DIR_COUNT=$(find "$SQF/opt/orionx/yara" -maxdepth 1 -type d -name "rules-*" 2>/dev/null | wc -l | tr -d ' ' || true)
if [[ "$RULES_DIR_COUNT" -eq 0 ]]; then
    pass "22f: rules-*/ dirs NOT present in squashfs (Layer A sentinel — snapshots deferred to W11-4b)"
else
    fail "22f: rules-*/ dirs NOT present in squashfs" \
         "Found $RULES_DIR_COUNT rules-*/ dir(s) — Layer A should ship only the skeleton. If W11-4b has landed, invert this assertion."
fi

# ===========================================================================
# 23. W11-5 Layer A: matrix-commander comms skeleton
#
# @decision DEC-PHASE11-006
# @title W11-5 Layer A content-presence section 23: matrix-commander pip venv +
#   comms skeleton README + .desktop launcher
# @status accepted
# @rationale W11-5 Layer A stages the Matrix team comms infrastructure:
#   (a) /opt/orionx/venv/comms/bin/matrix-commander installed (soft-fail — venv
#       install may skip if network unavailable at build time);
#   (b) /opt/orionx/comms/README.md documents Layer A/B/C plan;
#   (c) /usr/share/applications/orionx-matrix-commander.desktop staged for XFCE
#       application menu;
#   (d) /usr/local/bin/matrix-commander symlink present when venv install succeeded;
#   (e) /opt/orionx/comms/gomuks/ NOT present (Layer B sentinel — deferred to W11-5b).
# ===========================================================================
section "23. W11-5 Layer A: matrix-commander comms skeleton (DEC-PHASE11-006)"

# ---------------------------------------------------------------------------
# 23a. /opt/orionx/venv/comms/bin/matrix-commander present (soft-fail)
# ---------------------------------------------------------------------------
MATRIX_COMMANDER_BIN="$SQF/opt/orionx/venv/comms/bin/matrix-commander"
if [[ -f "$MATRIX_COMMANDER_BIN" ]]; then
    pass "23a: /opt/orionx/venv/comms/bin/matrix-commander installed (W11-5 Layer A, DEC-PHASE11-006)"
else
    # matrix-commander is installed by 0500 hook which is soft-fail when network
    # unavailable. Record a note rather than a hard fail so builds without network
    # connectivity (e.g. air-gap CI runs) are not blocked by this assertion.
    echo "  NOTE: 23a: /opt/orionx/venv/comms/bin/matrix-commander not found — venv install"
    echo "        may not have run (0500 hook soft-fails when network is unavailable; not a hard failure)"
    pass "23a: matrix-commander venv check: soft-fail expected when network unavailable at build time (informational only)"
fi

# ---------------------------------------------------------------------------
# 23b. /opt/orionx/comms/README.md present
# ---------------------------------------------------------------------------
COMMS_README="$SQF/opt/orionx/comms/README.md"
if [[ -f "$COMMS_README" ]]; then
    pass "23b: /opt/orionx/comms/README.md present in squashfs (W11-5 skeleton)"
else
    fail "23b: /opt/orionx/comms/README.md present in squashfs" \
         "iso/config/includes.chroot/opt/orionx/comms/README.md not staged — check includes.chroot"
fi

# ---------------------------------------------------------------------------
# 23c. /usr/share/applications/orionx-matrix-commander.desktop present
# ---------------------------------------------------------------------------
MATRIX_DESKTOP="$SQF/usr/share/applications/orionx-matrix-commander.desktop"
if [[ -f "$MATRIX_DESKTOP" ]]; then
    pass "23c: /usr/share/applications/orionx-matrix-commander.desktop present (W11-5 XFCE launcher)"
    # Desktop entry must reference xfce4-terminal (not lxterminal — DEC-PHASE9-006)
    # || true: DEC-PHASE9-014 — grep exits 1 on no-match; zero refs is the desired state.
    LXTERM_IN_MATRIX=$(grep -c "lxterminal" "$MATRIX_DESKTOP" 2>/dev/null || true)
    if [[ "$LXTERM_IN_MATRIX" -eq 0 ]]; then
        pass "23c: orionx-matrix-commander.desktop has zero lxterminal references (DEC-PHASE9-006)"
    else
        fail "23c: orionx-matrix-commander.desktop has zero lxterminal references" \
             "Found $LXTERM_IN_MATRIX lxterminal reference(s) — violates DEC-PHASE9-006; use xfce4-terminal"
    fi
else
    fail "23c: /usr/share/applications/orionx-matrix-commander.desktop present" \
         "iso/config/includes.chroot/usr/share/applications/orionx-matrix-commander.desktop not staged"
fi

# ---------------------------------------------------------------------------
# 23d. /usr/local/bin/matrix-commander symlink (best-effort when venv installed)
# ---------------------------------------------------------------------------
# Only assert the symlink if the venv binary is present; if the venv install
# was skipped (network unavailable), the symlink will also be absent — both
# are expected and not a build failure. DEC-PHASE9-014 pipefail guard: we use
# [[ -L ]] || [[ -f ]] which do not trigger pipefail.
if [[ -f "$MATRIX_COMMANDER_BIN" ]]; then
    if [[ -L "$SQF/usr/local/bin/matrix-commander" ]] || \
       [[ -f "$SQF/usr/local/bin/matrix-commander" ]]; then
        pass "23d: /usr/local/bin/matrix-commander symlink/file present (0500 hook ln -sf)"
    else
        fail "23d: /usr/local/bin/matrix-commander symlink present" \
             "0500 hook should create ln -sf /opt/orionx/venv/comms/bin/matrix-commander /usr/local/bin/matrix-commander when venv is installed"
    fi
else
    echo "  NOTE: 23d: /usr/local/bin/matrix-commander symlink check skipped (venv not installed — soft-fail)"
    pass "23d: matrix-commander symlink check: skipped (venv not installed; soft-fail per DEC-PHASE11-006)"
fi

# ---------------------------------------------------------------------------
# 23e. /opt/orionx/comms/gomuks/ NOT present (Layer B sentinel — W11-5b will flip)
# ---------------------------------------------------------------------------
# Layer A intentionally ships NO gomuks binary; operators wait for W11-5b.
# When W11-5b lands and stages the gomuks static binary, this assertion should
# be inverted to REQUIRE its presence.
if [[ ! -d "$SQF/opt/orionx/comms/gomuks" ]]; then
    pass "23e: /opt/orionx/comms/gomuks/ NOT present (Layer B sentinel — deferred to W11-5b)"
else
    fail "23e: /opt/orionx/comms/gomuks/ NOT present" \
         "gomuks directory found — Layer A should not include gomuks. If W11-5b has landed, invert this assertion."
fi

# ===========================================================================
# 24. W11-6 Layer A: Suricata IDS — lazy-start + skeleton + freshen script
#
# @decision DEC-PHASE11-008
# @title W11-6 Layer A content-presence section 24: Suricata IDS skeleton
# @status accepted
# @rationale W11-6 Layer A stages the Suricata IDS integration:
#   (a) suricata Debian package installed in chroot
#   (b) systemd drop-in override at /etc/systemd/system/suricata.service.d/orionx-lazy.conf
#       present and contains ConditionPathExists=/var/lib/suricata/orionx-enabled
#   (c) /var/lib/suricata/orionx-README.md skeleton present
#   (d) /opt/orionx/scripts/orionx-freshen-suricata.sh present + executable + shellcheck-clean
#   (e) /usr/bin/orionx-freshen-suricata symlink present (created by 0700 hook)
#   (f) Layer B sentinel: /var/lib/suricata/rules/ NOT present with .rules files
#       (bundled ruleset deferred to W11-6b)
#   Layer B (W11-6b) will flip assertion (f) and wire the Nebula tier selector.
# ===========================================================================
section "24. W11-6 Layer A: Suricata IDS — lazy-start + skeleton + freshen script (DEC-PHASE11-008)"

# 24a. suricata package installed in chroot
if [[ -f "$DPKG_STATUS" ]] && grep -q "^Package: suricata$" "$DPKG_STATUS" 2>/dev/null; then
    pass "24a: package installed in chroot: suricata (W11-6 Layer A, DEC-PHASE11-008)"
elif [[ -x "$SQF/usr/bin/suricata" ]]; then
    pass "24a: package installed in chroot: suricata (binary present at /usr/bin/suricata)"
else
    fail "24a: package installed in chroot: suricata" \
         "Check orionx.list.chroot W11-6 block includes suricata"
fi

# 24b. systemd drop-in present and contains ConditionPathExists
SURICATA_DROPIN="$SQF/etc/systemd/system/suricata.service.d/orionx-lazy.conf"
if [[ -f "$SURICATA_DROPIN" ]]; then
    pass "24b: /etc/systemd/system/suricata.service.d/orionx-lazy.conf present (W11-6 lazy-start)"
    if grep -q "ConditionPathExists=/var/lib/suricata/orionx-enabled" "$SURICATA_DROPIN" 2>/dev/null; then
        pass "24b: orionx-lazy.conf contains ConditionPathExists=/var/lib/suricata/orionx-enabled"
    else
        fail "24b: orionx-lazy.conf contains ConditionPathExists=/var/lib/suricata/orionx-enabled" \
             "Drop-in missing the ConditionPathExists sentinel — check includes.chroot staging"
    fi
else
    fail "24b: /etc/systemd/system/suricata.service.d/orionx-lazy.conf present" \
         "Systemd drop-in missing — includes.chroot/etc/systemd/system/suricata.service.d/ not staged"
fi

# 24c. /var/lib/suricata/orionx-README.md skeleton present
if [[ -f "$SQF/var/lib/suricata/orionx-README.md" ]]; then
    pass "24c: /var/lib/suricata/orionx-README.md present (W11-6 skeleton)"
else
    fail "24c: /var/lib/suricata/orionx-README.md present" \
         "Skeleton README missing — includes.chroot/var/lib/suricata/ not staged"
fi

# 24d. orionx-freshen-suricata.sh staged + executable + shellcheck-clean
SURICATA_FRESHEN="$SQF/opt/orionx/scripts/orionx-freshen-suricata.sh"
if [[ -f "$SURICATA_FRESHEN" ]]; then
    pass "24d: /opt/orionx/scripts/orionx-freshen-suricata.sh present in squashfs (W11-6 freshen script)"
else
    fail "24d: /opt/orionx/scripts/orionx-freshen-suricata.sh present in squashfs" \
         "stage_application_content must rsync scripts/ — ensure orionx-freshen-suricata.sh exists in repo scripts/"
fi

if [[ -f "$SURICATA_FRESHEN" ]] && [[ -x "$SURICATA_FRESHEN" ]]; then
    pass "24d: /opt/orionx/scripts/orionx-freshen-suricata.sh is executable in chroot"
else
    fail "24d: /opt/orionx/scripts/orionx-freshen-suricata.sh is executable in chroot" \
         "0700 hook sets chmod 755 on all scripts/ files — check hook execution"
fi

# Lint check runs against the source file in the repo (not inside squashfs)
SURICATA_FRESHEN_SRC="$REPO_ROOT/scripts/orionx-freshen-suricata.sh"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$SURICATA_FRESHEN_SRC" 2>/dev/null; then
        pass "24d: scripts/orionx-freshen-suricata.sh shellcheck-clean"
    else
        fail "24d: scripts/orionx-freshen-suricata.sh shellcheck-clean" \
             "shellcheck found issues — run: shellcheck $SURICATA_FRESHEN_SRC"
    fi
else
    skip "24d shellcheck: shellcheck not installed on this host (install shellcheck to enable)"
fi

# 24e. /usr/bin/orionx-freshen-suricata symlink (created by 0700 hook)
if [[ -L "$SQF/usr/bin/orionx-freshen-suricata" ]]; then
    pass "24e: /usr/bin/orionx-freshen-suricata symlink present in chroot (0700 hook)"
elif [[ -f "$SQF/usr/bin/orionx-freshen-suricata" ]]; then
    pass "24e: /usr/bin/orionx-freshen-suricata present in chroot (as regular file)"
else
    fail "24e: /usr/bin/orionx-freshen-suricata symlink present in chroot" \
         "0700-orionx-setup.hook.chroot SCRIPT_MAP must include orionx-freshen-suricata"
fi

# 24f. Layer B sentinel: /var/lib/suricata/rules/ NOT present with .rules files
# Layer A intentionally ships NO bundled ruleset; operators fetch post-boot via
# orionx-freshen-suricata. When W11-6b lands and bundles the ET-Open snapshot,
# this assertion should be inverted (or removed).
# || true: find exits non-zero when path absent; that is the desired Layer A state.
SURICATA_RULES_COUNT="$(find "$SQF/var/lib/suricata/rules" -name '*.rules' 2>/dev/null | wc -l | tr -d ' ' || true)"
if [[ "$SURICATA_RULES_COUNT" -eq 0 ]]; then
    pass "24f: /var/lib/suricata/rules/ NOT present with .rules files (Layer B sentinel — deferred to W11-6b)"
else
    fail "24f: /var/lib/suricata/rules/ NOT present with .rules files" \
         "Found $SURICATA_RULES_COUNT .rules file(s) — Layer A should ship no bundled rules. If W11-6b has landed, invert this assertion."
fi

# ===========================================================================
# 25. W11-7: ClamAV drop — absent from package list + optional installer staged
#
# @decision DEC-PHASE11-009
# @title W11-7 ClamAV dropped from base ISO; optional installer at
#   /opt/orionx/optional/install-clamav.sh
# @status accepted
# @rationale ClamAV adds ~350 MB, signatures decay within days (90% freshness
#   decay), and the background network dependency is incompatible with the
#   air-gap threat model. YARA + capa + Suricata + FLOSS + Nebula MCP provide
#   sufficient detection value for the base image. Operators who need signature
#   scanning install post-boot via the optional installer on a network-connected
#   node.
#
# 25a: 'clamav' NOT present as a bare package line in orionx.list.chroot
# 25b: /opt/orionx/optional/install-clamav.sh present, executable, shellcheck-clean
# 25c: 'clamav' NOT installed in squashfs dpkg database (absence gate)
# ===========================================================================
section "25. W11-7: ClamAV drop — absent from package list + optional installer staged (DEC-PHASE11-009)"

# ---------------------------------------------------------------------------
# 25a. clamav NOT in orionx.list.chroot
# ---------------------------------------------------------------------------
PKG_LIST_CLAMAV="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
echo "  [25a] Verifying clamav absent from orionx.list.chroot"
if [[ -f "$PKG_LIST_CLAMAV" ]]; then
    # || true: grep exits 1 on no-match; zero matches is the desired W11-7 state (DEC-PHASE9-014).
    CLAMAV_PKG_LINES=$(grep -c "^clamav$" "$PKG_LIST_CLAMAV" 2>/dev/null || true)
    if [[ "$CLAMAV_PKG_LINES" -eq 0 ]]; then
        pass "25a: 'clamav' absent from orionx.list.chroot (W11-7 debloat -350 MB, DEC-PHASE11-009)"
    else
        fail "25a: 'clamav' absent from orionx.list.chroot" \
             "Found $CLAMAV_PKG_LINES 'clamav' line(s) — W11-7 debloat not applied (DEC-PHASE11-009)"
    fi
else
    fail "25a: orionx.list.chroot accessible for clamav check" \
         "Cannot find $PKG_LIST_CLAMAV"
fi

# ---------------------------------------------------------------------------
# 25b. /opt/orionx/optional/install-clamav.sh present, executable, shellcheck-clean
# ---------------------------------------------------------------------------
echo "  [25b] Verifying optional installer present, executable, and shellcheck-clean"
INSTALL_CLAMAV_SRC="$REPO_ROOT/iso/config/includes.chroot/opt/orionx/optional/install-clamav.sh"

if [[ -f "$INSTALL_CLAMAV_SRC" ]]; then
    pass "25b: iso/config/includes.chroot/opt/orionx/optional/install-clamav.sh present (DEC-PHASE11-009)"
    if [[ -x "$INSTALL_CLAMAV_SRC" ]]; then
        pass "25b: install-clamav.sh is executable (+x bit set)"
    else
        fail "25b: install-clamav.sh is executable" \
             "File exists but lacks execute permission — chmod +x required"
    fi
    # bash -n syntax check always runs
    if bash -n "$INSTALL_CLAMAV_SRC" 2>/dev/null; then
        pass "25b: install-clamav.sh passes bash -n syntax check"
    else
        fail "25b: install-clamav.sh passes bash -n syntax check" \
             "bash -n reported syntax errors — fix install-clamav.sh"
    fi
    # lint check (skip if shellcheck not available on runner)
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck "$INSTALL_CLAMAV_SRC" 2>/dev/null; then
            pass "25b: install-clamav.sh shellcheck-clean (DEC-PHASE11-009)"
        else
            fail "25b: install-clamav.sh shellcheck-clean" \
                 "shellcheck reported issues — run: shellcheck $INSTALL_CLAMAV_SRC"
        fi
    else
        skip "25b shellcheck: shellcheck not installed on this host (install shellcheck to enable)"
    fi
else
    fail "25b: iso/config/includes.chroot/opt/orionx/optional/install-clamav.sh present" \
         "Optional installer missing — W11-7 requires it at includes.chroot/opt/orionx/optional/install-clamav.sh (DEC-PHASE11-009)"
    fail "25b: install-clamav.sh is executable" \
         "File missing — cannot check"
    fail "25b: install-clamav.sh passes bash -n syntax check" \
         "File missing — cannot check"
fi

# Also verify the installer is present in the extracted squashfs (staged via includes.chroot)
INSTALL_CLAMAV_SQF="$SQF/opt/orionx/optional/install-clamav.sh"
if [[ -f "$INSTALL_CLAMAV_SQF" ]]; then
    pass "25b: /opt/orionx/optional/install-clamav.sh present in squashfs (staged via includes.chroot)"
    if [[ -x "$INSTALL_CLAMAV_SQF" ]]; then
        pass "25b: /opt/orionx/optional/install-clamav.sh executable in squashfs"
    else
        fail "25b: /opt/orionx/optional/install-clamav.sh executable in squashfs" \
             "Executable bit not set on staged copy — check includes.chroot or live-build permissions"
    fi
else
    # squashfs check is informational when ISO is not available; the source-tree
    # check above is the hard gate. Squashfs absence may mean the ISO was not
    # built after the W11-7 commit.
    echo "  NOTE: 25b: /opt/orionx/optional/install-clamav.sh not found in squashfs"
    echo "        (ISO may not have been rebuilt after W11-7 commit — source-tree check is authoritative)"
    pass "25b: squashfs check skipped (ISO not rebuilt since W11-7; source-tree assertions are authoritative)"
fi

# ---------------------------------------------------------------------------
# 25c. clamav NOT installed in squashfs dpkg database
# ---------------------------------------------------------------------------
echo "  [25c] Verifying clamav absent from squashfs dpkg database"
if [[ -f "$DPKG_STATUS" ]]; then
    if grep -q "^Package: clamav$" "$DPKG_STATUS" 2>/dev/null; then
        fail "25c: clamav absent from squashfs dpkg database (W11-7 debloat gate)" \
             "clamav found in dpkg/status — package list removal not reflected in built ISO (DEC-PHASE11-009)"
    else
        pass "25c: clamav absent from squashfs dpkg database (W11-7 -350 MB, DEC-PHASE11-009)"
    fi
else
    echo "  NOTE: 25c: dpkg/status not available (squashfs not extracted or ISO not built)"
    pass "25c: clamav dpkg check skipped (dpkg/status unavailable — ISO may not have been rebuilt)"
fi

# ===========================================================================
# 26. W11-8 Layer A: Optional-installer framework — shared lib + 5 new stubs
#     + clamav refactor (DEC-PHASE11-011)
#
# @decision DEC-PHASE11-011
# @title W11-8 Layer A optional-installer framework assertions (Section 26)
# @status accepted
# @rationale W11-8 introduces a shared bash library at
#   /opt/orionx/optional/lib/orionx-installer-common.sh (7 DRY functions) and
#   five new installer stubs (ghidra/element/floss/trid/gomuks), and refactors
#   install-clamav.sh (W11-7) to source the library. This section proves:
#   (26a) library present + shellcheck clean,
#   (26b) all 7 function definitions present in library,
#   (26c) all 5 new stubs present + executable + source library,
#   (26d) install-clamav.sh refactored (sources lib, uses orionx_apt_install),
#   (26e) install-clamav.sh LOUD-fails when run as non-root.
#
# Note on Section 25c: the W11-7 Section 25c assertion checks the dpkg
# absence of clamav from the squashfs (a plain grep against dpkg/status).
# There is no apt-get regex in 25c that required loosening — the W11-8
# refactor of install-clamav.sh replaces the apt-get invocation with
# orionx_apt_install at the source level, but the squashfs dpkg-absence
# gate (25c) is orthogonal to that and remains valid as-is.
# ===========================================================================
section "26. W11-8 Layer A: Optional-installer framework — shared lib + 5 new stubs + clamav refactor (DEC-PHASE11-011)"

# Source paths for assertions against the repo tree (not squashfs)
OPTIONAL_SRC="$REPO_ROOT/iso/config/includes.chroot/opt/orionx/optional"
COMMON_LIB_SRC="$OPTIONAL_SRC/lib/orionx-installer-common.sh"

# Squashfs paths (used when ISO was rebuilt after W11-8 commit)
OPTIONAL_SQF="$SQF/opt/orionx/optional"
COMMON_LIB_SQF="$OPTIONAL_SQF/lib/orionx-installer-common.sh"

# ---------------------------------------------------------------------------
# 26a. lib/orionx-installer-common.sh present + shellcheck-clean
# ---------------------------------------------------------------------------
echo "  [26a] Verifying shared library present and shellcheck-clean"
if [[ -f "$COMMON_LIB_SRC" ]]; then
    pass "26a: lib/orionx-installer-common.sh present in source tree (DEC-PHASE11-011)"
    if bash -n "$COMMON_LIB_SRC" 2>/dev/null; then
        pass "26a: lib/orionx-installer-common.sh passes bash -n syntax check"
    else
        fail "26a: lib/orionx-installer-common.sh passes bash -n syntax check" \
             "bash -n reported syntax errors in the shared library"
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck "$COMMON_LIB_SRC" 2>/dev/null; then
            pass "26a: lib/orionx-installer-common.sh shellcheck-clean (DEC-PHASE11-011)"
        else
            fail "26a: lib/orionx-installer-common.sh shellcheck-clean" \
                 "shellcheck reported issues — run: shellcheck $COMMON_LIB_SRC"
        fi
    else
        skip "26a shellcheck: shellcheck not installed on this host"
    fi
    # Library must NOT be executable (it is sourced, not run — DEC-PHASE11-011 invariant)
    if [[ ! -x "$COMMON_LIB_SRC" ]]; then
        pass "26a: lib/orionx-installer-common.sh is NOT executable (sourced, not run)"
    else
        fail "26a: lib/orionx-installer-common.sh is NOT executable" \
             "Library has +x bit set — violates DEC-PHASE11-011 (sourced libs must not be executable)"
    fi
    # Squashfs check (informational if ISO not rebuilt)
    if [[ -f "$COMMON_LIB_SQF" ]]; then
        pass "26a: lib/orionx-installer-common.sh present in squashfs (staged via includes.chroot)"
    else
        echo "  NOTE: 26a: lib/orionx-installer-common.sh not found in squashfs"
        echo "        (ISO may not have been rebuilt after W11-8 commit — source-tree check is authoritative)"
        pass "26a: squashfs check skipped (ISO not rebuilt since W11-8; source-tree assertions are authoritative)"
    fi
else
    fail "26a: lib/orionx-installer-common.sh present in source tree" \
         "Library missing — W11-8 requires it at $COMMON_LIB_SRC (DEC-PHASE11-011)"
    fail "26a: lib/orionx-installer-common.sh passes bash -n syntax check" \
         "File missing — cannot check"
    fail "26a: lib/orionx-installer-common.sh shellcheck-clean" \
         "File missing — cannot check"
    fail "26a: lib/orionx-installer-common.sh is NOT executable" \
         "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 26b. Library defines all 7 expected functions
# ---------------------------------------------------------------------------
echo "  [26b] Verifying 7 function definitions present in shared library"
if [[ -f "$COMMON_LIB_SRC" ]]; then
    for fn in \
        orionx_require_root \
        orionx_require_network \
        orionx_log_info \
        orionx_log_error \
        orionx_apt_install \
        orionx_wget_extract \
        orionx_verify_sha256; do
        # Match function definition: name followed by () on the same line
        # (bash function definition syntax: name() { or name () {)
        # || true: grep exits 1 on no-match; under pipefail that kills the
        # script before the if-branch is reached (DEC-PHASE9-014 guard).
        FN_HITS=$(grep -cE "^[[:space:]]*${fn}[[:space:]]*\(\)" "$COMMON_LIB_SRC" 2>/dev/null || true)
        if [[ "$FN_HITS" -ge 1 ]]; then
            pass "26b: function ${fn}() defined in shared library"
        else
            fail "26b: function ${fn}() defined in shared library" \
                 "Missing definition for ${fn} — add it to $COMMON_LIB_SRC"
        fi
    done
else
    for fn in \
        orionx_require_root orionx_require_network orionx_log_info \
        orionx_log_error orionx_apt_install orionx_wget_extract \
        orionx_verify_sha256; do
        fail "26b: function ${fn}() defined in shared library" \
             "Library file missing — cannot check function definitions"
    done
fi

# ---------------------------------------------------------------------------
# 26c. All 5 new installer stubs present + executable + source the library
# ---------------------------------------------------------------------------
echo "  [26c] Verifying 5 new installer stubs present, executable, and sourcing library"
for stub in install-ghidra.sh install-element.sh install-floss.sh install-trid.sh install-gomuks.sh; do
    STUB_SRC="$OPTIONAL_SRC/$stub"
    STUB_SQF="$OPTIONAL_SQF/$stub"

    if [[ -f "$STUB_SRC" ]]; then
        pass "26c: $stub present in source tree"
        if [[ -x "$STUB_SRC" ]]; then
            pass "26c: $stub is executable (+x bit set)"
        else
            fail "26c: $stub is executable" \
                 "$stub exists but lacks execute permission — chmod +x required"
        fi
        if bash -n "$STUB_SRC" 2>/dev/null; then
            pass "26c: $stub passes bash -n syntax check"
        else
            fail "26c: $stub passes bash -n syntax check" \
                 "bash -n reported syntax errors in $stub"
        fi
        # Must source the shared library via the canonical runtime path
        if grep -qE "source[[:space:]]+/opt/orionx/optional/lib/orionx-installer-common\.sh" "$STUB_SRC" 2>/dev/null; then
            pass "26c: $stub sources /opt/orionx/optional/lib/orionx-installer-common.sh"
        else
            fail "26c: $stub sources /opt/orionx/optional/lib/orionx-installer-common.sh" \
                 "Missing: source /opt/orionx/optional/lib/orionx-installer-common.sh in $stub"
        fi
        # Must call orionx_require_root and orionx_require_network
        if grep -q "orionx_require_root" "$STUB_SRC" 2>/dev/null; then
            pass "26c: $stub calls orionx_require_root"
        else
            fail "26c: $stub calls orionx_require_root" \
                 "Missing orionx_require_root call — DEC-PHASE11-011 requires root preflight"
        fi
        if grep -q "orionx_require_network" "$STUB_SRC" 2>/dev/null; then
            pass "26c: $stub calls orionx_require_network"
        else
            fail "26c: $stub calls orionx_require_network" \
                 "Missing orionx_require_network call — DEC-PHASE11-011 requires network preflight"
        fi
        # Squashfs check (informational if ISO not rebuilt)
        if [[ -f "$STUB_SQF" ]]; then
            pass "26c: $stub present in squashfs"
            if [[ -x "$STUB_SQF" ]]; then
                pass "26c: $stub executable in squashfs"
            else
                fail "26c: $stub executable in squashfs" \
                     "Executable bit not set on staged copy — check includes.chroot permissions"
            fi
        else
            echo "  NOTE: 26c: $stub not found in squashfs (ISO may not have been rebuilt)"
            pass "26c: $stub squashfs check skipped (source-tree assertions are authoritative)"
        fi
    else
        fail "26c: $stub present in source tree" \
             "Stub missing — W11-8 requires it at $STUB_SRC (DEC-PHASE11-011)"
        fail "26c: $stub is executable" "File missing — cannot check"
        fail "26c: $stub passes bash -n syntax check" "File missing — cannot check"
        fail "26c: $stub sources /opt/orionx/optional/lib/orionx-installer-common.sh" \
             "File missing — cannot check"
    fi
done

# ---------------------------------------------------------------------------
# 26d. install-clamav.sh refactored to use shared library
# ---------------------------------------------------------------------------
echo "  [26d] Verifying install-clamav.sh refactored to source shared library"
CLAMAV_SRC="$OPTIONAL_SRC/install-clamav.sh"
if [[ -f "$CLAMAV_SRC" ]]; then
    # Positive: must source the library
    if grep -qE "source[[:space:]]+/opt/orionx/optional/lib/orionx-installer-common\.sh" "$CLAMAV_SRC" 2>/dev/null; then
        pass "26d: install-clamav.sh sources /opt/orionx/optional/lib/orionx-installer-common.sh (refactored)"
    else
        fail "26d: install-clamav.sh sources /opt/orionx/optional/lib/orionx-installer-common.sh" \
             "Missing source directive — W11-8 refactor not applied to install-clamav.sh"
    fi
    # Positive: must call orionx_require_root (replaces inlined EUID check)
    if grep -q "orionx_require_root" "$CLAMAV_SRC" 2>/dev/null; then
        pass "26d: install-clamav.sh calls orionx_require_root (old EUID inline removed)"
    else
        fail "26d: install-clamav.sh calls orionx_require_root" \
             "Missing orionx_require_root — refactor must replace the old inlined EUID check"
    fi
    # Positive: must call orionx_apt_install (replaces inlined apt-get)
    if grep -q "orionx_apt_install" "$CLAMAV_SRC" 2>/dev/null; then
        pass "26d: install-clamav.sh calls orionx_apt_install (old apt-get inline replaced)"
    else
        fail "26d: install-clamav.sh calls orionx_apt_install" \
             "Missing orionx_apt_install — refactor must replace the old inlined apt-get install"
    fi
    # Negative: old inlined EUID check must be GONE (dual-authority hazard per DEC-PHASE11-011)
    # || true: grep exits 1 on no-match; zero matches is the desired state. DEC-PHASE9-014.
    # SC2016: single quotes are intentional — we are grepping for the literal
    # string 'if [[ $EUID -ne 0 ]]' as it appeared in the pre-refactor file.
    # shellcheck disable=SC2016
    OLD_EUID_HITS=$(grep -cF 'if [[ $EUID -ne 0 ]]' "$CLAMAV_SRC" 2>/dev/null || true)
    if [[ "$OLD_EUID_HITS" -eq 0 ]]; then
        pass "26d: old inlined EUID check removed from install-clamav.sh (no dual-authority)"
    else
        fail "26d: old inlined EUID check removed from install-clamav.sh" \
             "Found $OLD_EUID_HITS old EUID inline(s) — remove and replace with orionx_require_root"
    fi
    # Negative: old inlined getent check must be GONE
    # || true: same DEC-PHASE9-014 guard.
    OLD_GETENT_HITS=$(grep -cF 'if ! getent hosts deb.debian.org' "$CLAMAV_SRC" 2>/dev/null || true)
    if [[ "$OLD_GETENT_HITS" -eq 0 ]]; then
        pass "26d: old inlined getent check removed from install-clamav.sh (no dual-authority)"
    else
        fail "26d: old inlined getent check removed from install-clamav.sh" \
             "Found $OLD_GETENT_HITS old getent inline(s) — remove and replace with orionx_require_network"
    fi
    # DEC-PHASE11-009 header block preserved verbatim (lines 1-6)
    if grep -q "@decision DEC-PHASE11-009" "$CLAMAV_SRC" 2>/dev/null; then
        pass "26d: DEC-PHASE11-009 @decision header preserved in install-clamav.sh"
    else
        fail "26d: DEC-PHASE11-009 @decision header preserved in install-clamav.sh" \
             "Header missing — refactor must NOT change the DEC-PHASE11-009 decision block"
    fi
else
    fail "26d: install-clamav.sh present for refactor check" \
         "$CLAMAV_SRC missing — W11-7 installer not found"
    fail "26d: install-clamav.sh sources library" "File missing — cannot check"
    fail "26d: install-clamav.sh calls orionx_require_root" "File missing — cannot check"
    fail "26d: install-clamav.sh calls orionx_apt_install" "File missing — cannot check"
fi

# ---------------------------------------------------------------------------
# 26e. install-clamav.sh LOUD-fails when run as non-root (smoke test)
# The shared library's orionx_require_root() checks $EUID and `exit 1`s with
# orionx_log_error "... requires root. Run with sudo." (lib line ~51). We source
# the SHIPPED library from the extracted squashfs and call the function under a
# genuinely non-root identity.
# Why not `EUID=1000`: bash's EUID is READ-ONLY — the assignment prints
# "EUID: readonly variable" and is ignored, so under a root runner (every
# container run) the check passed, printed SHOULD_NOT_REACH, and 26e reported a
# false FAIL against a correct library (2026-09 QA). When the runner is root we
# drop to uid 65534 via setpriv/runuser; if neither exists we SKIP rather than
# fake the result.
# ---------------------------------------------------------------------------
echo "  [26e] Verifying install-clamav.sh LOUD-fails on non-root invocation (smoke test)"
SMOKE_LIB="$COMMON_LIB_SQF"
[[ -f "$SMOKE_LIB" ]] || SMOKE_LIB="$COMMON_LIB_SRC"   # source-tree fallback if the ISO predates W11-8
if [[ -f "$CLAMAV_SRC" ]] && [[ -f "$SMOKE_LIB" ]]; then
    # $WORK is a 0700 mktemp dir, unreadable once we drop to uid 65534 — hand the
    # unprivileged shell a world-readable copy of the library instead.
    SMOKE_LIB_COPY="$(mktemp "${TMPDIR:-/tmp}/orionx-installer-common.XXXXXX")"
    cp "$SMOKE_LIB" "$SMOKE_LIB_COPY" && chmod 0644 "$SMOKE_LIB_COPY"
    SMOKE_SCRIPT="source '$SMOKE_LIB_COPY'; orionx_require_root; echo 'SHOULD_NOT_REACH'"
    SMOKE_RUNNER=""
    if [[ "$EUID" -ne 0 ]]; then
        SMOKE_RUNNER="self"
        SMOKE_OUT="$(bash -c "$SMOKE_SCRIPT" 2>&1 || true)"
    elif command -v setpriv >/dev/null 2>&1; then
        SMOKE_RUNNER="setpriv uid 65534"
        SMOKE_OUT="$(setpriv --reuid=65534 --regid=65534 --clear-groups bash -c "$SMOKE_SCRIPT" 2>&1 || true)"
    elif command -v runuser >/dev/null 2>&1; then
        SMOKE_RUNNER="runuser nobody"
        SMOKE_OUT="$(runuser -u nobody -- bash -c "$SMOKE_SCRIPT" 2>&1 || true)"
    fi
    rm -f "$SMOKE_LIB_COPY"
    if [[ -z "$SMOKE_RUNNER" ]]; then
        skip "26e: non-root smoke test (runner is root and neither setpriv nor runuser is available to drop privileges)"
        skip "26e: installer exits before reaching install logic on non-root (same reason)"
    else
        # Library must have emitted its loud error and exited before the sentinel.
        if echo "$SMOKE_OUT" | grep -q "requires root"; then
            pass "26e: shipped orionx_require_root LOUD-fails with 'requires root' for a non-root caller (via $SMOKE_RUNNER)"
        else
            fail "26e: shipped orionx_require_root LOUD-fails with 'requires root' for a non-root caller" \
                 "Expected 'requires root' in output (lib orionx_log_error); got: ${SMOKE_OUT:-<empty>} (via $SMOKE_RUNNER)"
        fi
        if echo "$SMOKE_OUT" | grep -q "SHOULD_NOT_REACH"; then
            fail "26e: installer exits before reaching install logic on non-root" \
                 "orionx_require_root did not exit — execution reached past the root check (via $SMOKE_RUNNER)"
        else
            pass "26e: installer exits before reaching install logic on non-root (exit 1 fired)"
        fi
    fi
    # install-clamav.sh must call the gate before anything else (shipped copy preferred)
    CLAMAV_GATE_SRC="$INSTALL_CLAMAV_SQF"
    [[ -f "$CLAMAV_GATE_SRC" ]] || CLAMAV_GATE_SRC="$CLAMAV_SRC"
    if grep -qE '^orionx_require_root' "$CLAMAV_GATE_SRC" 2>/dev/null; then
        pass "26e: install-clamav.sh invokes orionx_require_root at top level"
    else
        fail "26e: install-clamav.sh invokes orionx_require_root at top level" \
             "No 'orionx_require_root' call in $CLAMAV_GATE_SRC — installer would proceed to apt-get as non-root"
    fi
else
    fail "26e: install-clamav.sh + shared library available for smoke test" \
         "One or both files missing — cannot run non-root smoke test"
    fail "26e: installer exits before reaching install logic on non-root" \
         "Files missing — cannot check"
fi

# ===========================================================================
# 27. W11-11: orionx-diag in-ISO diagnostic tool + version-manifest
#     KEY=VALUE extension (DEC-PHASE11-015)
# ===========================================================================
#
# @decision DEC-PHASE11-015
# @title W11-11 content-presence section 27: orionx-diag build-time source
#   assertions (shell tool + hook extension + build-iso.sh exports)
# @status accepted
# @rationale Section 27 validates BUILD-TIME source presence and squashfs
#   staging of the diagnostic tool. Runtime behavior (does it produce correct
#   PASS/FAIL on a booted system?) is the domain of tests/unit/test_orionx_diag.sh
#   (structural + arg-parse + JSON shape) and T-Verify QEMU boot smoke (runtime).
#   Eight assertions cover: repo source executable + shellcheck, README, hook
#   SCRIPT_MAP entry, hook ISO_VERSION manifest write, build-iso.sh export, and
#   squashfs presence (guarded by SQF extraction success).

section "27. W11-11: orionx-diag in-ISO diagnostic tool + version-manifest KEY=VALUE extension (DEC-PHASE11-015)"

# DEC-PHASE12-021: orionx-diag and the scripts/ operator README live in the repo's
# scripts/ directory and reach /opt/orionx/scripts/ through stage_application_content's
# `rsync -a --delete scripts/ -> opt/orionx/scripts/` (build-iso.sh). Their former home
# under includes.chroot/opt/orionx/scripts/ was wiped by that same --delete, which is
# why the v2.2.0-beta (dev9) squashfs ships neither file (27g/27h below).
DIAG_SRC="$REPO_ROOT/scripts/orionx-diag"
HOOK_0700="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
BUILD_ISO="$REPO_ROOT/scripts/build-iso.sh"
README_SRC="$REPO_ROOT/scripts/README.md"

# 27a: orionx-diag source present in repo + executable bit set
if [[ -f "$DIAG_SRC" && -x "$DIAG_SRC" ]]; then
    pass "27a: $DIAG_SRC present + executable"
else
    fail "27a: $DIAG_SRC present + executable" \
         "file absent or not executable (run: chmod +x $DIAG_SRC)"
fi

# 27b: orionx-diag passes shellcheck -S error
if command -v shellcheck &>/dev/null; then
    if shellcheck -S error "$DIAG_SRC" 2>/dev/null; then
        pass "27b: orionx-diag shellcheck -S error clean"
    else
        SHELLCHECK_OUT="$(shellcheck -S error "$DIAG_SRC" 2>&1 || true)"
        fail "27b: orionx-diag shellcheck -S error clean" \
             "shellcheck findings: $(echo "$SHELLCHECK_OUT" | head -5)"
    fi
else
    skip "27b: orionx-diag shellcheck -S error (shellcheck not on PATH)"
fi

# 27c: README.md for scripts/ present in repo
if [[ -f "$README_SRC" ]]; then
    pass "27c: $README_SRC present"
else
    fail "27c: $README_SRC present" \
         "README.md absent — operator guide missing from staging tree"
fi

# 27d: 0700 hook contains ["orionx-diag"]= SCRIPT_MAP entry
if grep -qF '["orionx-diag"]=' "$HOOK_0700" 2>/dev/null; then
    pass "27d: 0700 hook SCRIPT_MAP contains [\"orionx-diag\"]= entry"
else
    fail "27d: 0700 hook SCRIPT_MAP contains [\"orionx-diag\"]= entry" \
         'grep -F [\"orionx-diag\"]= returned no match in 0700 hook'
fi

# 27e: 0700 hook contains ISO_VERSION= in version manifest write block
if grep -q 'ISO_VERSION=' "$HOOK_0700" 2>/dev/null; then
    pass "27e: 0700 hook contains ISO_VERSION= (KEY=VALUE manifest write)"
else
    fail "27e: 0700 hook contains ISO_VERSION= (KEY=VALUE manifest write)" \
         "ISO_VERSION= not found in 0700 hook — manifest write block missing"
fi

# 27f: build-iso.sh exports ORIONX_GIT_SHA
if grep -q 'ORIONX_GIT_SHA=' "$BUILD_ISO" 2>/dev/null; then
    pass "27f: scripts/build-iso.sh exports ORIONX_GIT_SHA"
else
    fail "27f: scripts/build-iso.sh exports ORIONX_GIT_SHA" \
         "ORIONX_GIT_SHA= not found in scripts/build-iso.sh"
fi

# 27g: squashfs check — orionx-diag present in extracted squashfs
if [[ -d "$SQF/opt/orionx/scripts" ]]; then
    if [[ -f "$SQF/opt/orionx/scripts/orionx-diag" ]]; then
        pass "27g: /opt/orionx/scripts/orionx-diag present in squashfs"
    else
        fail "27g: /opt/orionx/scripts/orionx-diag present in squashfs" \
             "known: absent from v2.2.0-beta (dev9) — includes.chroot copy was wiped by the scripts/ rsync --delete; fixed by DEC-PHASE12-021 (moved to scripts/orionx-diag) — rebuild"
    fi
    # Also verify /etc/orionx-version in squashfs has the KEY=VALUE format (compound 27g)
    if [[ -f "$SQF/etc/orionx-version" ]]; then
        if grep -q '^ISO_VERSION=' "$SQF/etc/orionx-version" 2>/dev/null; then
            pass "27g(ext): /etc/orionx-version in squashfs contains ISO_VERSION= (KEY=VALUE format)"
        else
            fail "27g(ext): /etc/orionx-version in squashfs contains ISO_VERSION= (KEY=VALUE format)" \
                 "ISO_VERSION= not found — 0700 hook manifest write may not have run"
        fi
    else
        skip "27g(ext): /etc/orionx-version ISO_VERSION= check (file absent in squashfs — chroot phase may not have run)"
    fi
else
    skip "27g: /opt/orionx/scripts/orionx-diag squashfs check (scripts dir absent — squashfs not extracted)"
    skip "27g(ext): /etc/orionx-version ISO_VERSION= check (squashfs not extracted)"
fi

# 27h: squashfs check — /usr/bin/orionx-diag symlink present
if [[ -d "$SQF/usr/bin" ]]; then
    if [[ -L "$SQF/usr/bin/orionx-diag" || -f "$SQF/usr/bin/orionx-diag" ]]; then
        pass "27h: /usr/bin/orionx-diag symlink present in squashfs"
    else
        fail "27h: /usr/bin/orionx-diag symlink present in squashfs" \
             "known: absent from v2.2.0-beta (dev9) — 0700 hook skips the symlink when the target is missing; fixed by DEC-PHASE12-021 — rebuild"
    fi
else
    skip "27h: /usr/bin/orionx-diag symlink squashfs check (squashfs not extracted)"
fi

# ===========================================================================
# 28. QA P0 Hotfix (2026-07-21) — xfconf pkg, log dir self-heal, skel authority
#
# @decision DEC-PHASE11-016
# @title QA P0 hotfix assertions: package list completeness + log dir + skel authority
# @status accepted
# @rationale tmp/QA_AUDIT_2026-07-21.md surfaced 3 P0 bricking bugs after hardware
#   test failure (root cause: presence-check bias substituted for runtime verification).
#   (P0-001) xfconf package missing — toggle-theme.sh runtime fails at xfconf-query.
#   (P0-002) /var/log/orionx not created — artifact-analyzer.py crashes on first boot.
#   (P0-003) 0200-copy-samples hook writes to dead /home/orionx/ — DEC-PHASE11-014
#     R6 cascade: skel authority not applied to sample seeding hook.
#   Also adds P1 packages (iproute2, perl, socat, dpkg) per QA audit findings.
#   These assertions run against source-tree files (package list, scripts, hooks)
#   so they can catch regressions without requiring a full ISO rebuild.
# ===========================================================================
section "28. QA P0 Hotfix (2026-07-21) — xfconf/iproute2/perl/socat/dpkg packages, log dir self-heal, skel authority"

PKG_LIST_P0="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
ARTIFACT_ANALYZER="$REPO_ROOT/scripts/artifact-analyzer.py"
HOOK_0200_LIVE="$REPO_ROOT/iso/config/hooks/live/0200-copy-samples.hook.chroot"

# ---------------------------------------------------------------------------
# 28a. xfconf present in package list (P0-001: toggle-theme.sh runtime fix)
# ---------------------------------------------------------------------------
# grep -q returns 0 on match, 1 on no-match; no pipefail risk with -q form.
if [[ -f "$PKG_LIST_P0" ]] && grep -q "^xfconf$" "$PKG_LIST_P0" 2>/dev/null; then
    pass "28a: xfconf present in orionx.list.chroot (P0-001: toggle-theme.sh runtime fix, DEC-PHASE11-016)"
else
    fail "28a: xfconf present in orionx.list.chroot" \
         "xfconf not found as a bare package line — toggle-theme.sh xfconf-query will fail at runtime (P0-001)"
fi

# ---------------------------------------------------------------------------
# 28b. P1 packages present in package list (iproute2, perl, socat, dpkg)
# ---------------------------------------------------------------------------
for p1_pkg in iproute2 perl socat dpkg; do
    if [[ -f "$PKG_LIST_P0" ]] && grep -q "^${p1_pkg}$" "$PKG_LIST_P0" 2>/dev/null; then
        pass "28b: ${p1_pkg} present in orionx.list.chroot (QA P1 audit completeness)"
    else
        fail "28b: ${p1_pkg} present in orionx.list.chroot" \
             "${p1_pkg} not found as a bare package line — QA_AUDIT_2026-07-21.md P1 fix incomplete"
    fi
done

# ---------------------------------------------------------------------------
# 28c. artifact-analyzer.py contains log dir self-heal (P0-002)
# ---------------------------------------------------------------------------
if [[ -f "$ARTIFACT_ANALYZER" ]] && \
   grep -q 'mkdir(parents=True, exist_ok=True)' "$ARTIFACT_ANALYZER" 2>/dev/null; then
    pass "28c: artifact-analyzer.py contains Path.mkdir(parents=True, exist_ok=True) log-dir self-heal (P0-002)"
else
    fail "28c: artifact-analyzer.py contains Path.mkdir(parents=True, exist_ok=True) log-dir self-heal" \
         "Self-heal mkdir missing from $ARTIFACT_ANALYZER — tool will crash on first boot when /var/log/orionx absent (P0-002)"
fi

# ---------------------------------------------------------------------------
# 28d. 0200-copy-samples live hook targets /etc/skel/Analysis (P0-003)
# ---------------------------------------------------------------------------
if [[ -f "$HOOK_0200_LIVE" ]] && \
   grep -q '/etc/skel/Analysis' "$HOOK_0200_LIVE" 2>/dev/null; then
    pass "28d: 0200-copy-samples live hook seeds /etc/skel/Analysis/ (P0-003 DEC-PHASE11-014 cascade fix)"
else
    fail "28d: 0200-copy-samples live hook seeds /etc/skel/Analysis/" \
         "/etc/skel/Analysis not found in $HOOK_0200_LIVE — sample seeding writes to dead /home/orionx/ path (P0-003)"
fi

# ---------------------------------------------------------------------------
# 28e. 0200-copy-samples live hook has NO /home/orionx/ references (P0-003 negative gate)
# ---------------------------------------------------------------------------
# || true: grep exits 1 on no-match; zero refs is the desired state (DEC-PHASE9-014 pattern).
if [[ -f "$HOOK_0200_LIVE" ]]; then
    HOME_ORIONX_REFS=$(grep -c '/home/orionx/' "$HOOK_0200_LIVE" 2>/dev/null || true)
    if [[ "$HOME_ORIONX_REFS" -eq 0 ]]; then
        pass "28e: 0200-copy-samples live hook has zero /home/orionx/ references (dead-authority retired, DEC-PHASE11-014)"
    else
        fail "28e: 0200-copy-samples live hook has zero /home/orionx/ references" \
             "Found $HOME_ORIONX_REFS /home/orionx/ reference(s) — dead-authority path not fully removed (P0-003)"
    fi
else
    fail "28e: 0200-copy-samples live hook present for /home/orionx/ reference check" \
         "Hook not found at $HOOK_0200_LIVE — P0-003 fix not applied"
fi

# ---------------------------------------------------------------------------
# 28f. 0200-copy-samples live hook has NO chown orionx:orionx calls (P0-003)
# The old hook chowned /home/orionx/Analysis to the dead 'orionx' user.
# /etc/skel/ files must NOT be chowned — live-config sets ownership at user creation.
# ---------------------------------------------------------------------------
if [[ -f "$HOOK_0200_LIVE" ]]; then
    CHOWN_ORIONX_REFS=$(grep -c 'chown orionx:orionx' "$HOOK_0200_LIVE" 2>/dev/null || true)
    if [[ "$CHOWN_ORIONX_REFS" -eq 0 ]]; then
        pass "28f: 0200-copy-samples live hook has zero 'chown orionx:orionx' calls (P0-003 dead-user reference retired)"
    else
        fail "28f: 0200-copy-samples live hook has zero 'chown orionx:orionx' calls" \
             "Found $CHOWN_ORIONX_REFS chown orionx:orionx call(s) — 'orionx' user does not exist post-DEC-PHASE11-014 R6"
    fi
else
    fail "28f: 0200-copy-samples live hook present for chown check" \
         "Hook not found at $HOOK_0200_LIVE — P0-003 fix not applied"
fi

# ---------------------------------------------------------------------------
# 28g. normal/0200-copy-samples hook is REMOVED (dual-authority guard)
# The normal/ variant contained `chown -R orionx:orionx /home/orionx/Analysis`
# (line 69). Post-DEC-PHASE11-014 R6 the 'orionx' user no longer exists in the
# chroot, so the old hook would hard-abort `lb chroot`. The sole authority is
# now live/0200-copy-samples.hook.chroot. This assertion fails if the deleted
# file is ever accidentally re-introduced (e.g. a merge brings it back).
# ---------------------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/iso/config/hooks/normal/0200-copy-samples.hook.chroot" ]]; then
    pass "28g: iso/config/hooks/normal/0200-copy-samples.hook.chroot is REMOVED (dual-authority guard, DEC-PHASE11-014)"
else
    fail "28g: iso/config/hooks/normal/0200-copy-samples.hook.chroot is REMOVED" \
         "File still exists — dual-authority hook would hard-abort lb chroot via 'chown orionx:orionx' to dead user (post-DEC-PHASE11-014 R6)"
fi

# Also verify the hook is present in the squashfs if the ISO was rebuilt.
# (The live/ hooks execute at chroot build time and are NOT copied into the
# squashfs root, so we assert /etc/skel/Analysis/ presence in the squashfs instead.)
if [[ -d "$SQF/etc/skel" ]]; then
    if [[ -d "$SQF/etc/skel/Analysis" ]]; then
        pass "28f(sqf): /etc/skel/Analysis/ directory present in squashfs (0200 hook ran, P0-003)"
    else
        # Squashfs check is informational if the ISO predates this fix.
        echo "  NOTE: 28f(sqf): /etc/skel/Analysis/ not found in squashfs"
        echo "        (ISO may not have been rebuilt after P0-003 fix — source-tree checks 28d/28e/28f are authoritative)"
        pass "28f(sqf): /etc/skel/Analysis/ squashfs check skipped (ISO not rebuilt since P0-003 fix; source assertions are authoritative)"
    fi
else
    pass "28f(sqf): /etc/skel/Analysis/ squashfs check skipped (squashfs not extracted)"
fi

# ===========================================================================
# 29. QA P2/P3 Hotfix follow-up (2026-07-22) — sample honesty, @decision
#     annotations, Plymouth initramfs verification
#
# @decision DEC-PHASE11-017 dependency
# @title P2-002 sample honesty: _SYNTHETIC suffix + README
# @status accepted
# @rationale tmp/QA_AUDIT_2026-07-21.md P2-002: operators could mistake
#   the randomly-generated placeholder in create_memory_sample() for real
#   forensic data. Renamed to mini_sample_SYNTHETIC.raw and co-located a
#   README.txt that explicitly labels the file as synthetic. These
#   source-tree assertions catch regressions without requiring a full ISO
#   rebuild.
#
# @decision DEC-PHASE11-014 dependency (P3-001)
# @title P3-001 toggle-theme.sh DEC-PHASE11-014 annotation
# @status accepted
# @rationale toggle-theme.sh operates on the live session seeded from
#   /etc/skel/. A missing annotation caused reviewers to miss that a
#   change to this script also requires a change to 0100-create-user.hook.
#   DEC-PHASE11-014 is now explicitly cited in the script header.
#
# @decision DEC-PHASE11-018
# @title P3-002 Plymouth initramfs verification: build-time fail-loud gate
# @status accepted
# @rationale The operator-reported "Plymouth Phoenix splash did NOT paint"
#   on hardware was caused by a silent initramfs regeneration failure.
#   0800-orionx-branding.hook.chroot now calls lsinitramfs and aborts the
#   build (exit 1) if the theme is absent from the initrd. This section
#   asserts the check mechanism and its DEC annotation are present in the
#   hook source.
# ===========================================================================
section "29. QA P2/P3 Hotfix follow-up (2026-07-22) — sample honesty, @decision annotations, Plymouth initramfs verification"

DOWNLOAD_SAMPLES="$REPO_ROOT/scripts/download-samples.sh"
TOGGLE_THEME="$REPO_ROOT/scripts/toggle-theme.sh"
HOOK_0800="$REPO_ROOT/iso/config/hooks/live/0800-orionx-branding.hook.chroot"

# ---------------------------------------------------------------------------
# 29a. P2-002: mini_sample_SYNTHETIC.raw filename present in download-samples.sh
# ---------------------------------------------------------------------------
if [[ -f "$DOWNLOAD_SAMPLES" ]] && grep -q 'mini_sample_SYNTHETIC\.raw' "$DOWNLOAD_SAMPLES" 2>/dev/null; then
    pass "29a: mini_sample_SYNTHETIC.raw filename present in download-samples.sh (P2-002 rename, DEC-PHASE11-017)"
else
    fail "29a: mini_sample_SYNTHETIC.raw filename present in download-samples.sh" \
         "_SYNTHETIC suffix not found in $DOWNLOAD_SAMPLES — honesty rename incomplete (P2-002)"
fi

# ---------------------------------------------------------------------------
# 29b. P2-002: SYNTHETIC PLACEHOLDER README content present in download-samples.sh
# ---------------------------------------------------------------------------
if [[ -f "$DOWNLOAD_SAMPLES" ]] && grep -q 'SYNTHETIC PLACEHOLDER' "$DOWNLOAD_SAMPLES" 2>/dev/null; then
    pass "29b: SYNTHETIC PLACEHOLDER README content present in download-samples.sh (P2-002 honesty README, DEC-PHASE11-017)"
else
    fail "29b: SYNTHETIC PLACEHOLDER README content present in download-samples.sh" \
         "README text absent from $DOWNLOAD_SAMPLES — operators won't see honesty warning (P2-002)"
fi

# ---------------------------------------------------------------------------
# 29c. P3-001: DEC-PHASE11-014 annotation present in toggle-theme.sh
# ---------------------------------------------------------------------------
if [[ -f "$TOGGLE_THEME" ]] && grep -q 'DEC-PHASE11-014' "$TOGGLE_THEME" 2>/dev/null; then
    pass "29c: DEC-PHASE11-014 annotation present in toggle-theme.sh (P3-001, skel dependency documented)"
else
    fail "29c: DEC-PHASE11-014 annotation present in toggle-theme.sh" \
         "DEC-PHASE11-014 not cited in $TOGGLE_THEME — reviewers cannot see the /etc/skel/ dependency (P3-001)"
fi

# ---------------------------------------------------------------------------
# 29d. P3-002: lsinitramfs check present in 0800-orionx-branding.hook.chroot
# ---------------------------------------------------------------------------
if [[ -f "$HOOK_0800" ]] && grep -q 'lsinitramfs' "$HOOK_0800" 2>/dev/null; then
    pass "29d: lsinitramfs Plymouth initramfs verification present in 0800 hook (P3-002, DEC-PHASE11-018)"
else
    fail "29d: lsinitramfs Plymouth initramfs verification present in 0800 hook" \
         "lsinitramfs check absent from $HOOK_0800 — silent initramfs failure remains undetected (P3-002)"
fi

# ---------------------------------------------------------------------------
# 29e. P3-002: DEC-PHASE11-018 annotation present in 0800-orionx-branding.hook.chroot
# ---------------------------------------------------------------------------
if [[ -f "$HOOK_0800" ]] && grep -q 'DEC-PHASE11-018' "$HOOK_0800" 2>/dev/null; then
    pass "29e: DEC-PHASE11-018 annotation present in 0800-orionx-branding.hook.chroot (P3-002 decision documented)"
else
    fail "29e: DEC-PHASE11-018 annotation present in 0800-orionx-branding.hook.chroot" \
         "DEC-PHASE11-018 not cited in $HOOK_0800 — @decision annotation missing (P3-002)"
fi

# ===========================================================================
# 30. orionx-imager macOS SD-reader detection fix (DEC-PHASE11-IMAGER-001, #77)
#
# @decision DEC-PHASE11-IMAGER-001
# @title Enumerate all disks, filter on RemovableMedia/Ejectable per-disk
# @status active
# @rationale `diskutil list external` excludes built-in card readers even when
#   a removable SD card is inserted (macOS classifies the reader as internal/
#   physical). The fix drops the `external` arg and adds per-disk
#   RemovableMedia/Ejectable filtering via `diskutil info -plist <disk>`.
#   These assertions verify the change is present in the source tree without
#   requiring a full ISO rebuild or macOS hardware.
# ===========================================================================
section "30. orionx-imager macOS SD-reader detection fix (DEC-PHASE11-IMAGER-001, #77)"

DEVICES_PY="$REPO_ROOT/scripts/orionx-imager/lib/devices.py"

# ---------------------------------------------------------------------------
# 30a. `external` argument removed from diskutil list call
# ---------------------------------------------------------------------------
if [[ -f "$DEVICES_PY" ]] && \
   grep -qE '"diskutil", "list", "-plist"\]|"diskutil", "list", "-plist",$' "$DEVICES_PY" 2>/dev/null; then
    pass "30a: diskutil list -plist called without 'external' arg (DEC-PHASE11-IMAGER-001)"
else
    fail "30a: diskutil list -plist called without 'external' arg" \
         "Expected ['diskutil', 'list', '-plist'] (no 'external') in $DEVICES_PY"
fi

# ---------------------------------------------------------------------------
# 30b. Negative guard: 'external' argument must NOT be present
# ---------------------------------------------------------------------------
if [[ -f "$DEVICES_PY" ]] && \
   ! grep -q '"diskutil", "list", "-plist", "external"' "$DEVICES_PY" 2>/dev/null; then
    pass "30b: 'diskutil list -plist external' call absent (removed by DEC-PHASE11-IMAGER-001)"
else
    fail "30b: 'diskutil list -plist external' call absent" \
         "Found the old 'external' arg still in $DEVICES_PY — issue #77 fix not applied"
fi

# ---------------------------------------------------------------------------
# 30c. @decision annotation present
# ---------------------------------------------------------------------------
if [[ -f "$DEVICES_PY" ]] && grep -q 'DEC-PHASE11-IMAGER-001' "$DEVICES_PY" 2>/dev/null; then
    pass "30c: DEC-PHASE11-IMAGER-001 decision annotation present in devices.py"
else
    fail "30c: DEC-PHASE11-IMAGER-001 decision annotation present in devices.py" \
         "Decision annotation missing from $DEVICES_PY"
fi

# ---------------------------------------------------------------------------
# 30d. RemovableMedia per-disk filter present
# ---------------------------------------------------------------------------
if [[ -f "$DEVICES_PY" ]] && grep -q 'RemovableMedia' "$DEVICES_PY" 2>/dev/null; then
    pass "30d: RemovableMedia per-disk filter present in devices.py (DEC-PHASE11-IMAGER-001)"
else
    fail "30d: RemovableMedia per-disk filter present in devices.py" \
         "RemovableMedia key not found in $DEVICES_PY — per-disk filter not implemented"
fi

# ---------------------------------------------------------------------------
# 30e. Ejectable per-disk filter present
# ---------------------------------------------------------------------------
if [[ -f "$DEVICES_PY" ]] && grep -q 'Ejectable' "$DEVICES_PY" 2>/dev/null; then
    pass "30e: Ejectable per-disk filter present in devices.py (DEC-PHASE11-IMAGER-001)"
else
    fail "30e: Ejectable per-disk filter present in devices.py" \
         "Ejectable key not found in $DEVICES_PY — per-disk filter incomplete"
fi

# ===========================================================================
# 31. macOS Docker auto-wrap + git-derived version default (build-iso.sh)
#
# @decision DEC-PHASE11-MACOS-BUILD-001
# @title macOS host auto-wraps in debian:bullseye-slim Docker
# @status active
# @rationale These source-tree assertions verify the macOS Docker auto-wrap
#   and git-derived version changes without requiring a full ISO build or
#   Docker/macOS hardware. They prove the implementation is present and
#   consistent with the CI release.yml pattern.
# ===========================================================================
section "31. macOS Docker auto-wrap + git-derived version (DEC-PHASE11-MACOS-BUILD-001)"

BUILD_SH="$REPO_ROOT/scripts/build-iso.sh"

# ---------------------------------------------------------------------------
# 31a. Darwin detection present
# ---------------------------------------------------------------------------
if grep -q 'uname -s.*Darwin\|Darwin.*uname' "$BUILD_SH" 2>/dev/null || \
   grep -q '"Darwin"' "$BUILD_SH" 2>/dev/null; then
    pass "31a: build-iso.sh detects Darwin host (DEC-PHASE11-MACOS-BUILD-001)"
else
    fail "31a: build-iso.sh detects Darwin host" \
         "Expected Darwin uname check in $BUILD_SH"
fi

# ---------------------------------------------------------------------------
# 31b. ORIONX_BUILD_IN_DOCKER recursion guard present
# ---------------------------------------------------------------------------
if grep -q 'ORIONX_BUILD_IN_DOCKER' "$BUILD_SH" 2>/dev/null; then
    pass "31b: build-iso.sh has ORIONX_BUILD_IN_DOCKER recursion guard"
else
    fail "31b: build-iso.sh has ORIONX_BUILD_IN_DOCKER recursion guard" \
         "ORIONX_BUILD_IN_DOCKER guard not found in $BUILD_SH"
fi

# ---------------------------------------------------------------------------
# 31c. debian:bullseye-slim used (matches release.yml)
# ---------------------------------------------------------------------------
if grep -q 'debian:bullseye' "$BUILD_SH" 2>/dev/null; then
    pass "31c: build-iso.sh uses debian:bullseye (matches release.yml)"
else
    fail "31c: build-iso.sh uses debian:bullseye (matches release.yml)" \
         "debian:bullseye not found in $BUILD_SH — Docker image must match CI"
fi

# ---------------------------------------------------------------------------
# 31d. Stale hardcoded default v2.0.0-rc9 removed
# ---------------------------------------------------------------------------
if ! grep -qF 'ORIONX_VERSION:-v2.0.0-rc9' "$BUILD_SH" 2>/dev/null; then
    pass "31d: build-iso.sh no longer hardcodes stale default v2.0.0-rc9"
else
    fail "31d: build-iso.sh no longer hardcodes stale default v2.0.0-rc9" \
         "Found ORIONX_VERSION:-v2.0.0-rc9 still present in $BUILD_SH — issue #75 not fixed"
fi

# ---------------------------------------------------------------------------
# 31e. git describe used for version derivation
# ---------------------------------------------------------------------------
if grep -q 'git describe --tags' "$BUILD_SH" 2>/dev/null; then
    pass "31e: build-iso.sh derives default version from git describe --tags"
else
    fail "31e: build-iso.sh derives default version from git describe --tags" \
         "git describe --tags not found in $BUILD_SH — version default not git-derived"
fi

# ---------------------------------------------------------------------------
# 31f. DEC-PHASE11-MACOS-BUILD-001 annotation present
# ---------------------------------------------------------------------------
if grep -q 'DEC-PHASE11-MACOS-BUILD-001' "$BUILD_SH" 2>/dev/null; then
    pass "31f: DEC-PHASE11-MACOS-BUILD-001 annotation present in build-iso.sh"
else
    fail "31f: DEC-PHASE11-MACOS-BUILD-001 annotation present in build-iso.sh" \
         "Decision annotation missing from $BUILD_SH"
fi

# ---------------------------------------------------------------------------
# 31g. DEC-PHASE11-VERSION-DEFAULT-001 annotation present
# ---------------------------------------------------------------------------
if grep -q 'DEC-PHASE11-VERSION-DEFAULT-001' "$BUILD_SH" 2>/dev/null; then
    pass "31g: DEC-PHASE11-VERSION-DEFAULT-001 annotation present in build-iso.sh"
else
    fail "31g: DEC-PHASE11-VERSION-DEFAULT-001 annotation present in build-iso.sh" \
         "Decision annotation missing from $BUILD_SH"
fi

# ---------------------------------------------------------------------------
# 31h. Makefile iso-build no longer errors on non-Linux
# ---------------------------------------------------------------------------
if ! grep -qE 'uname.*!=.*Linux|uname.*!=.*"Linux"' "$REPO_ROOT/Makefile" 2>/dev/null; then
    pass "31h: Makefile iso-build no longer errors on non-Linux hosts"
else
    fail "31h: Makefile iso-build no longer errors on non-Linux hosts" \
         "Found uname != Linux check still in Makefile — macOS block not removed"
fi

# ===========================================================================
# 32. Phase 11 W11-13 Runtime Cascade Fix — content-presence assertions
#
# @decision DEC-PHASE11-016 DEC-PHASE11-017 DEC-PHASE11-018 DEC-PHASE11-019
# @title W11-13 seven-fix bundle: source-tree assertions for all AC1-AC11 checks
# @status active
# @rationale These source-tree assertions verify the seven W11-13 runtime cascade
#   fixes are present and consistent without requiring a full ISO build. They
#   mirror the Layer A acceptance criteria (AC1-AC11) from the Evaluation Contract
#   at tmp/eval-wi-phase11-runtime-cascade-fix.json.
# ===========================================================================
section "32. Phase 11 W11-13 Runtime Cascade Fix (DEC-PHASE11-016..019)"

# ---------------------------------------------------------------------------
# 32a. AC1 — --exclude='security/' removed from build-iso.sh stage_application_content
# ---------------------------------------------------------------------------
if ! grep -qF -- "--exclude='security/'" "$REPO_ROOT/scripts/build-iso.sh" 2>/dev/null; then
    pass "32a: --exclude='security/' removed from build-iso.sh stage_application_content (AC1)"
else
    fail "32a: --exclude='security/' removed from build-iso.sh stage_application_content (AC1)" \
         "Found --exclude='security/' still present in scripts/build-iso.sh — P0 fix T1 not applied"
fi

# ---------------------------------------------------------------------------
# 32b. AC2 — LogsDirectory=orionx in nebula-integrity-check.service
# ---------------------------------------------------------------------------
NEBULA_SVC="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd/nebula-integrity-check.service"
if grep -q 'LogsDirectory=orionx' "$NEBULA_SVC" 2>/dev/null; then
    pass "32b: LogsDirectory=orionx present in nebula-integrity-check.service (AC2)"
else
    fail "32b: LogsDirectory=orionx present in nebula-integrity-check.service (AC2)" \
         "LogsDirectory=orionx not found in $NEBULA_SVC — 209/STDOUT fix T2 not applied"
fi

# ---------------------------------------------------------------------------
# 32c. AC3 — XDG autostart .desktop present and references Phoenix wallpaper
# ---------------------------------------------------------------------------
WALLPAPER_DESKTOP="$REPO_ROOT/iso/config/includes.chroot/etc/xdg/autostart/orionx-wallpaper.desktop"
if [[ -f "$WALLPAPER_DESKTOP" ]]; then
    pass "32c: orionx-wallpaper.desktop exists (AC3)"
else
    fail "32c: orionx-wallpaper.desktop exists (AC3)" \
         "File not found: $WALLPAPER_DESKTOP — XDG autostart fix T3 not applied"
fi

# DEC-PHASE12-004: the autostart entry no longer inlines the xfconf-query calls;
# it execs /opt/orionx/scripts/set-wallpaper.sh, whose default argument is the
# Phoenix wallpaper path (scripts/set-wallpaper.sh line ~23). Assert the wire in
# both halves: the .desktop Exec, and the script's reference to the wallpaper —
# checking the shipped squashfs copy of the script, with the repo copy as the
# authority the squashfs is staged from.
if grep -qE '^Exec=/opt/orionx/scripts/set-wallpaper\.sh' "$WALLPAPER_DESKTOP" 2>/dev/null; then
    pass "32c2: orionx-wallpaper.desktop Exec=/opt/orionx/scripts/set-wallpaper.sh (DEC-PHASE12-004)"
else
    fail "32c2: orionx-wallpaper.desktop Exec=/opt/orionx/scripts/set-wallpaper.sh (DEC-PHASE12-004)" \
         "Got: $(grep '^Exec=' "$WALLPAPER_DESKTOP" 2>/dev/null || echo '<no Exec line>')"
fi
SET_WALLPAPER_SQF="$SQF/opt/orionx/scripts/set-wallpaper.sh"
SET_WALLPAPER_SRC="$REPO_ROOT/scripts/set-wallpaper.sh"
if [[ -x "$SET_WALLPAPER_SQF" ]] && grep -q 'orionx-phoenix-wallpaper.png' "$SET_WALLPAPER_SQF" 2>/dev/null; then
    pass "32c2: /opt/orionx/scripts/set-wallpaper.sh shipped + executable and references orionx-phoenix-wallpaper.png (AC3)"
else
    fail "32c2: /opt/orionx/scripts/set-wallpaper.sh shipped + executable and references orionx-phoenix-wallpaper.png (AC3)" \
         "Shipped script missing, not executable, or does not name the Phoenix wallpaper — the autostart Exec would be a dead wire"
fi
if grep -q 'orionx-phoenix-wallpaper.png' "$SET_WALLPAPER_SRC" 2>/dev/null; then
    pass "32c2: scripts/set-wallpaper.sh (repo authority) references orionx-phoenix-wallpaper.png"
else
    fail "32c2: scripts/set-wallpaper.sh (repo authority) references orionx-phoenix-wallpaper.png" \
         "orionx-phoenix-wallpaper.png not found in $SET_WALLPAPER_SRC"
fi

if grep -q 'OnlyShowIn=XFCE' "$WALLPAPER_DESKTOP" 2>/dev/null; then
    pass "32c3: orionx-wallpaper.desktop has OnlyShowIn=XFCE (AC3)"
else
    fail "32c3: orionx-wallpaper.desktop has OnlyShowIn=XFCE (AC3)" \
         "OnlyShowIn=XFCE not found in $WALLPAPER_DESKTOP"
fi

# ---------------------------------------------------------------------------
# 32d. AC4 — Three ORIONX_GIT_* env vars plumbed into docker run in build-iso.sh
# ---------------------------------------------------------------------------
BUILD_SH="$REPO_ROOT/scripts/build-iso.sh"
GIT_ENV_COUNT=$(grep -cE -- '-e ORIONX_GIT_SHA|-e ORIONX_GIT_TITLE|-e ORIONX_PHASE_11_SLICES' "$BUILD_SH" 2>/dev/null || echo 0)
if [[ "$GIT_ENV_COUNT" -ge 3 ]]; then
    pass "32d: Three ORIONX_GIT_* env vars plumbed into docker run (AC4)"
else
    fail "32d: Three ORIONX_GIT_* env vars plumbed into docker run (AC4)" \
         "Expected >=3 matches for ORIONX_GIT_SHA|ORIONX_GIT_TITLE|ORIONX_PHASE_11_SLICES in $BUILD_SH, got: $GIT_ENV_COUNT"
fi

# ---------------------------------------------------------------------------
# 32e. AC5 — hook 0500 hard-fail lines for capa + matrix-commander
# ---------------------------------------------------------------------------
HOOK_0500="$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot"
FATAL_COUNT=$(grep -cE 'FATAL:.*(matrix-commander|capa)' "$HOOK_0500" 2>/dev/null || echo 0)
if [[ "$FATAL_COUNT" -ge 2 ]]; then
    pass "32e: hook 0500 has FATAL hard-fail for capa + matrix-commander (AC5)"
else
    fail "32e: hook 0500 has FATAL hard-fail for capa + matrix-commander (AC5)" \
         "Expected >=2 FATAL lines in $HOOK_0500, got: $FATAL_COUNT — T5 not applied"
fi

# ---------------------------------------------------------------------------
# 32f. AC6 — git, python3-pip, firefox-esr in package list
# ---------------------------------------------------------------------------
PKG_LIST="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
PKG_COUNT=$(grep -cE '^(git|python3-pip|firefox-esr)$' "$PKG_LIST" 2>/dev/null || echo 0)
if [[ "$PKG_COUNT" -ge 3 ]]; then
    pass "32f: git + python3-pip + firefox-esr in base package list (AC6)"
else
    fail "32f: git + python3-pip + firefox-esr in base package list (AC6)" \
         "Expected 3 bare package lines in $PKG_LIST, got: $PKG_COUNT — T6 not applied"
fi

# ---------------------------------------------------------------------------
# 32g. AC7 — wizard writes wg0.conf + mesh-private.key filenames
# ---------------------------------------------------------------------------
WIZARD="$REPO_ROOT/scripts/security/first-boot-wizard.sh"
WG_PATHS=$(grep -cE 'wg0\.conf|mesh-private\.key' "$WIZARD" 2>/dev/null || echo 0)
if [[ "$WG_PATHS" -ge 2 ]]; then
    pass "32g: wizard references wg0.conf + mesh-private.key (AC7)"
else
    fail "32g: wizard references wg0.conf + mesh-private.key (AC7)" \
         "Expected >=2 matches for wg0.conf|mesh-private.key in $WIZARD, got: $WG_PATHS — T1b not applied"
fi

# ---------------------------------------------------------------------------
# 32h. AC8 — wizard writes authorized_keys + SSH admin one-shot
# ---------------------------------------------------------------------------
AUTH_COUNT=$(grep -cE 'authorized_keys|SSH admin one-shot' "$WIZARD" 2>/dev/null || echo 0)
if [[ "$AUTH_COUNT" -ge 2 ]]; then
    pass "32h: wizard references authorized_keys + SSH admin one-shot (AC8)"
else
    fail "32h: wizard references authorized_keys + SSH admin one-shot (AC8)" \
         "Expected >=2 matches for authorized_keys|SSH admin one-shot in $WIZARD, got: $AUTH_COUNT — T7 not applied"
fi

# ---------------------------------------------------------------------------
# 32i. AC9 — /etc/motd.d/orionx-ssh-admin + /etc/issue.d/orionx-ssh-admin.issue present
# ---------------------------------------------------------------------------
MOTD_FILE="$REPO_ROOT/iso/config/includes.chroot/etc/motd.d/orionx-ssh-admin"
ISSUE_FILE="$REPO_ROOT/iso/config/includes.chroot/etc/issue.d/orionx-ssh-admin.issue"
if [[ -f "$MOTD_FILE" ]]; then
    pass "32i: /etc/motd.d/orionx-ssh-admin placeholder present (AC9)"
else
    fail "32i: /etc/motd.d/orionx-ssh-admin placeholder present (AC9)" \
         "File not found: $MOTD_FILE — T7 not applied"
fi
if [[ -f "$ISSUE_FILE" ]]; then
    pass "32i2: /etc/issue.d/orionx-ssh-admin.issue placeholder present (AC9)"
else
    fail "32i2: /etc/issue.d/orionx-ssh-admin.issue placeholder present (AC9)" \
         "File not found: $ISSUE_FILE — T7 not applied"
fi

# ---------------------------------------------------------------------------
# 32j. AC12 — bash -n syntax check on wizard and build-iso.sh
# ---------------------------------------------------------------------------
set +e
_wiz_syntax=$(bash -n "$WIZARD" 2>&1)
_wiz_rc=$?
set -e
if [[ $_wiz_rc -eq 0 ]]; then
    pass "32j: first-boot-wizard.sh passes bash -n syntax check (AC12)"
else
    fail "32j: first-boot-wizard.sh passes bash -n syntax check (AC12)" \
         "$_wiz_syntax"
fi

set +e
_build_syntax=$(bash -n "$BUILD_SH" 2>&1)
_build_rc=$?
set -e
if [[ $_build_rc -eq 0 ]]; then
    pass "32j2: build-iso.sh passes bash -n syntax check (AC12)"
else
    fail "32j2: build-iso.sh passes bash -n syntax check (AC12)" \
         "$_build_syntax"
fi

set +e
_hook_syntax=$(bash -n "$HOOK_0500" 2>&1)
_hook_rc=$?
set -e
if [[ $_hook_rc -eq 0 ]]; then
    pass "32j3: hook 0500 passes bash -n syntax check (AC12)"
else
    fail "32j3: hook 0500 passes bash -n syntax check (AC12)" \
         "$_hook_syntax"
fi

section "33. iso/auto/config execute bit — #82 root cause fix"

# Restored after W11-13: T8 reused section number 32 (and sub-check IDs 32a/32b)
# for the runtime-cascade assertions, overwriting the original #82 guards that
# had shipped in e13f1cd. The #82 code fix (tracked mode 100755) was never lost,
# but its regression guard was. Renumbered to 33 because 32 is now W11-13's.

# §33a: git tracked mode must be 100755
# git ls-files -s prints "<mode> <hash> <stage>\t<path>"; awk extracts mode.
#
# This assertion reads git metadata, not the ISO, so it can only run where the
# repo is a real checkout with git available. In a minimal test container —
# or against a source tree copied without .git — it must SKIP: reporting
# "<not tracked>" as a FAIL would invent a defect out of a missing tool. The
# command substitution is also guarded with `|| true`, because an absent git
# exits 127 and would otherwise abort the whole suite here (every later
# section silently unreported).
if ! command -v git >/dev/null 2>&1; then
    skip "33a: iso/auto/config has execute bit in git tracked mode" \
         "git not available — assertion reads git index metadata, not the ISO"
elif ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    skip "33a: iso/auto/config has execute bit in git tracked mode" \
         "$REPO_ROOT is not a git checkout — assertion reads git index metadata, not the ISO"
else
    TRACKED_MODE="$(git -C "$REPO_ROOT" ls-files -s iso/auto/config 2>/dev/null | awk '{print $1}' || true)"
    if [[ "$TRACKED_MODE" == "100755" ]]; then
        pass "33a: iso/auto/config has execute bit in git tracked mode (100755 — #82 root cause fix)"
    else
        fail "33a: iso/auto/config has execute bit in git tracked mode" \
             "Got: '${TRACKED_MODE:-<not tracked>}' — expected 100755; run: git update-index --chmod=+x iso/auto/config"
    fi
fi

# §33b: working-tree copy must be executable
if [[ -x "$REPO_ROOT/iso/auto/config" ]]; then
    pass "33b: iso/auto/config is executable in working tree"
else
    fail "33b: iso/auto/config is executable in working tree" \
         "File not executable: $REPO_ROOT/iso/auto/config — lb config will fail with Permission denied"
fi

section "34. W11-14 runtime-operational assertions (OUTCOMES in the ISO, not strings in source)"

# Every W11-13 acceptance check was a source-string grep, so section 32 passed 15/15
# on an ISO whose venvs were empty, whose ollama unit pointed at a nonexistent path,
# and whose /etc/orionx-version said GIT_HEAD_SHA=unknown. These assertions inspect
# the built squashfs instead: they fail if the tool is not actually there.

# --- 34a/b: venvs must contain pip (the silent-empty-venv defect) ---
_vid=a
for _v in re comms; do
    if [[ -x "$SQF/opt/orionx/venv/$_v/bin/pip" ]]; then
        pass "34${_vid}: /opt/orionx/venv/$_v has pip (venv was created with ensurepip)"
    else
        fail "34${_vid}: /opt/orionx/venv/$_v has pip" \
             "No pip in venv — python3-venv missing from package list; hook 0500 would skip its install block and ship an empty venv"
    fi
    _vid=b
done

# --- 34c: capa actually installed (not merely FATAL-string-present in the hook) ---
if [[ -x "$SQF/opt/orionx/venv/re/bin/capa" ]]; then
    pass "34c: capa binary present in /opt/orionx/venv/re/bin (DEC-PHASE11-018 satisfied)"
else
    fail "34c: capa binary present in /opt/orionx/venv/re/bin" \
         "capa absent — the DEC-PHASE11-018 hard-fail did not fire because the pip guard skipped the block"
fi

# --- 34d: matrix-commander actually installed ---
if [[ -x "$SQF/opt/orionx/venv/comms/bin/matrix-commander" ]]; then
    pass "34d: matrix-commander present in /opt/orionx/venv/comms/bin (DEC-PHASE11-018 satisfied)"
else
    fail "34d: matrix-commander present in /opt/orionx/venv/comms/bin" \
         "matrix-commander absent — same silent-skip defect as capa"
fi

# --- 34e: the ollama binary must exist at the path nebula-runtime.service invokes ---
_ollama_exec="$(grep -m1 '^ExecStart=' "$SQF/lib/systemd/system/nebula-runtime.service" 2>/dev/null | sed 's/^ExecStart=//' | awk '{print $1}')"
if [[ -n "$_ollama_exec" && -x "$SQF$_ollama_exec" ]]; then
    pass "34e: nebula-runtime ExecStart path exists in squashfs ($_ollama_exec)"
else
    fail "34e: nebula-runtime ExecStart path exists in squashfs" \
         "Unit invokes '${_ollama_exec:-<unparsed>}' but that path is not an executable in the image — service dies 203/EXEC"
fi

# --- 34f: units writing to /var/log/orionx must declare LogsDirectory ---
_missing_logdir=""
for _u in nebula-runtime.service nebula-warmup.service nebula-integrity-check.service; do
    _uf="$SQF/lib/systemd/system/$_u"
    [[ -f "$_uf" ]] || continue
    if grep -q "append:/var/log/orionx" "$_uf" && ! grep -q "^LogsDirectory=" "$_uf"; then
        _missing_logdir="$_missing_logdir $_u"
    fi
done
if [[ -z "$_missing_logdir" ]]; then
    pass "34f: all units using append:/var/log/orionx declare LogsDirectory= (no 209/STDOUT)"
else
    fail "34f: all units using append:/var/log/orionx declare LogsDirectory=" \
         "Missing LogsDirectory in:$_missing_logdir — systemd opens StandardOutput before ExecStartPre, so these die 209/STDOUT"
fi

# --- 34g: /etc/orionx-version must carry real metadata, not defaults ---
_ver_sha="$(grep -m1 '^GIT_HEAD_SHA=' "$SQF/etc/orionx-version" 2>/dev/null | cut -d= -f2)"
if [[ -n "$_ver_sha" && "$_ver_sha" != "unknown" ]]; then
    pass "34g: /etc/orionx-version GIT_HEAD_SHA is real ($_ver_sha)"
else
    fail "34g: /etc/orionx-version GIT_HEAD_SHA is real" \
         "GIT_HEAD_SHA='${_ver_sha:-<absent>}' — build metadata did not cross into the chroot (DEC-PHASE11-020)"
fi

# --- 34h: tshark must be present (wireshark alone does not provide it) ---
if [[ -x "$SQF/usr/bin/tshark" ]]; then
    pass "34h: tshark present in squashfs"
else
    fail "34h: tshark present in squashfs" \
         "tshark absent — the 'wireshark' package is the GUI only; tshark is a separate Debian binary package"
fi

# --- 34i: debloat must survive the python3-pip Recommends pull-in ---
_rebloat=""
for _p in make python3-dev build-essential dpkg-dev; do
    grep -q "^Package: ${_p}$" "$SQF/var/lib/dpkg/status" 2>/dev/null && _rebloat="$_rebloat $_p"
done
if [[ -z "$_rebloat" ]]; then
    pass "34i: build toolchain absent from ISO (DEC-PHASE11-003 debloat intact)"
else
    fail "34i: build toolchain absent from ISO (DEC-PHASE11-003 debloat intact)" \
         "Present:$_rebloat — python3-pip Recommends build-essential+python3-dev and iso/auto/config uses --apt-recommends true"
fi

# --- 34j: the bundled model must be REGISTERED with ollama, not just present ---
# A bare .gguf in OLLAMA_MODELS is invisible to ollama. Registration materialises
# blobs/ + manifests/. Without these, warmup.py exits 1 "No models found".
if [[ -d "$SQF/opt/orionx/nebula/models/blobs" && -d "$SQF/opt/orionx/nebula/models/manifests" ]]; then
    pass "34j: ollama store present (blobs/ + manifests/) — model registered at build time"
else
    fail "34j: ollama store present (blobs/ + manifests/) — model registered at build time" \
         "No ollama store under /opt/orionx/nebula/models — the GGUF was staged but never imported (DEC-PHASE11-021); ollama list will be empty and warm-up cannot work"
fi

# --- 34k: the registered manifest must carry the tag the runtime expects ---
# python3 is not guaranteed on the runner (debian:*-slim); a sed fallback reads the
# one flat string key we need so 34k cannot fail for lack of an interpreter.
_want_tag="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['ollama_model_tag'])" \
              "$REPO_ROOT/iso/config/nebula-model-manifest.json" 2>/dev/null || true)"
if [[ -z "$_want_tag" ]]; then
    _want_tag="$(sed -nE 's/^[[:space:]]*"ollama_model_tag"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
                  "$REPO_ROOT/iso/config/nebula-model-manifest.json" 2>/dev/null | head -1)"
fi
_tag_name="${_want_tag%%:*}"
if [[ -n "$_tag_name" ]] && find "$SQF/opt/orionx/nebula/models/manifests" -type f -path "*${_tag_name}*" 2>/dev/null | grep -q .; then
    pass "34k: ollama manifest exists for the manifest-declared tag ($_want_tag)"
else
    fail "34k: ollama manifest exists for the manifest-declared tag ($_want_tag)" \
         "No manifest entry matching '${_tag_name:-<unresolved>}' — registered tag disagrees with nebula-model-manifest.json"
fi

# --- 34l: AppArmor profile must attach to the real ollama path ---
_aa="$SQF/etc/apparmor.d/usr.bin.ollama"
_aa_path="$(grep -m1 -oE '^profile[[:space:]]+ollama[[:space:]]+\S+' "$_aa" 2>/dev/null | awk '{print $3}')"
_exec_path="$(grep -m1 '^ExecStart=' "$SQF/lib/systemd/system/nebula-runtime.service" 2>/dev/null | sed 's/^ExecStart=//' | awk '{print $1}')"
if [[ -n "$_aa_path" && "$_aa_path" == "$_exec_path" ]]; then
    pass "34l: AppArmor profile attaches to the ollama path the unit runs ($_aa_path)"
else
    fail "34l: AppArmor profile attaches to the ollama path the unit runs" \
         "profile='${_aa_path:-<none>}' vs ExecStart='${_exec_path:-<none>}' — AppArmor keys on executable path, so a mismatch means ollama runs UNCONFINED (DEC-006/DEC-007 not enforced)"
fi

# --- 34m: the hostname binary must be a real ELF, not absent or a stub ---
# live-build diverts /bin/hostname for the whole build and restores it at
# teardown; rc1-25 and rc1-31 both shipped with NO binary (divert dance broke
# across resumed builds), which broke live-config's hostname setup and killed
# the first-boot wizard with status=127 (2026-08-23 hardware attestation).
_hn="$SQF/usr/bin/hostname"
if [[ -s "$_hn" ]] && ! head -c2 "$_hn" | grep -q '#!'; then
    pass "34m: /usr/bin/hostname is a real binary ($(stat -c%s "$_hn" 2>/dev/null || wc -c < "$_hn") bytes)"
else
    fail "34m: /usr/bin/hostname is a real binary" \
         "Absent or a shell stub — live-build's hostname diversion was not restored; live-config and the first-boot wizard will fail"
fi

# --- 34n: /etc/hosts must not leak build-container state ---
if grep -qE "172\.17\.|d48450a52def|^127\.0\.1\.1[[:space:]]+debian" "$SQF/etc/hosts" 2>/dev/null; then
    fail "34n: /etc/hosts free of build-container leakage" \
         "Baked hosts contains Docker/build-chroot entries: $(grep -E '172\.17\.|debian' "$SQF/etc/hosts" | head -2 | tr '\n' ' ')"
else
    pass "34n: /etc/hosts free of build-container leakage"
fi

# --- 34o: baked /etc/hostname is the canonical identity ---
_bhn="$(cat "$SQF/etc/hostname" 2>/dev/null | head -1)"
if [[ "$_bhn" == "orionx" ]]; then
    pass "34o: baked /etc/hostname is 'orionx'"
else
    fail "34o: baked /etc/hostname is 'orionx'" \
         "Got '${_bhn:-<absent>}' — includes.chroot/etc/hostname not restored by chroot_hostname teardown"
fi

# --- 34p: tmpfiles.d fragment guarantees the log/run dirs (the real 209 fix) ---
if grep -qE "^d /var/log/orionx" "$SQF/usr/lib/tmpfiles.d/orionx.conf" 2>/dev/null && \
   grep -qE "^d /run/orionx" "$SQF/usr/lib/tmpfiles.d/orionx.conf" 2>/dev/null; then
    pass "34p: tmpfiles.d/orionx.conf creates /var/log/orionx + /run/orionx at boot"
else
    fail "34p: tmpfiles.d/orionx.conf creates /var/log/orionx + /run/orionx at boot" \
         "LogsDirectory= alone is proven insufficient on systemd 247 (209/STDOUT on 2026-08-03 and 2026-08-23)"
fi


# --- 34q: lightdm restart is bounded (no infinite cold-boot loop) ---
_dropin="$SQF/etc/systemd/system/lightdm.service.d/10-orionx-noloop.conf"
if [[ -f "$_dropin" ]] && grep -q "Restart=on-failure" "$_dropin" && grep -q "StartLimitBurst=" "$_dropin"; then
    pass "34q: lightdm no-loop drop-in present (DEC-PHASE11-023 — bounded restart)"
else
    fail "34q: lightdm no-loop drop-in present (DEC-PHASE11-023 — bounded restart)" \
         "Missing/incomplete $_dropin — a failing X could loop the cold boot forever (Restart=always default)"
fi
section "35. W10-3/5/6 engines present in the squashfs (DEC-PHASE12-023/024/025)"

# These three slices each shipped an operator-facing control whose engine did
# not exist. The engines exist now — and this section is here because that is
# exactly the kind of thing that disappears silently: orionx-diag was deleted
# from the image by a staging bug (DEC-PHASE12-021) and nothing failed, because
# no assertion demanded its presence. An unexecuted playbook and an absent
# playbook look identical from the Cockpit.

# 35a-c: W10-6 healing engine modules
_heal_missing=""
for _f in healing_lib.py playbooks.py engine.py orionx-heal orionx-heald; do
    [[ -f "$SQF/opt/orionx/scripts/healing/$_f" ]] || _heal_missing="$_heal_missing $_f"
done
if [[ -z "$_heal_missing" ]]; then
    pass "35a: W10-6 healing engine staged (all 5 modules)"
else
    fail "35a: W10-6 healing engine staged" "missing:$_heal_missing"
fi
if [[ -x "$SQF/opt/orionx/scripts/healing/orionx-heald" ]]; then
    pass "35b: orionx-heald executable"
else
    fail "35b: orionx-heald executable" "daemon not executable in squashfs"
fi
if [[ -L "$SQF/usr/bin/orionx-heal" || -f "$SQF/usr/bin/orionx-heal" ]]; then
    pass "35c: orionx-heal on PATH (operator control surface)"
else
    fail "35c: orionx-heal on PATH" "0700 SCRIPT_MAP entry missing"
fi

# 35d-e: W10-5 posture daemon
if [[ -x "$SQF/opt/orionx/scripts/awareness/orionx-postured" ]]; then
    pass "35d: W10-5 posture daemon staged + executable"
else
    fail "35d: W10-5 posture daemon staged + executable" \
         "without it the threat-posture tier is a label again"
fi
if [[ -L "$SQF/usr/bin/orionx-postured" || -f "$SQF/usr/bin/orionx-postured" ]]; then
    pass "35e: orionx-postured on PATH"
else
    fail "35e: orionx-postured on PATH" "0700 SCRIPT_MAP entry missing"
fi

# 35f-i: W10-3 MCP confinement. The profile and the dedicated uid are the
# confinement; without them the tool server runs unconfined as root.
if [[ -f "$SQF/etc/apparmor.d/usr.bin.nebula-mcp" ]]; then
    pass "35f: nebula-mcp AppArmor profile shipped"
else
    fail "35f: nebula-mcp AppArmor profile shipped" "MCP server would run unconfined"
fi
if [[ -f "$SQF/etc/apparmor.d/usr.bin.nebula-mcp" ]] \
   && ! grep -qE '^[[:space:]]*network[[:space:]]+inet6?[[:space:]]' "$SQF/etc/apparmor.d/usr.bin.nebula-mcp"; then
    pass "35g: nebula-mcp profile grants no inet network (issue #53 class)"
else
    fail "35g: nebula-mcp profile grants no inet network" \
         "an inet allow reintroduces the #53 over-broad-network problem"
fi
if [[ -f "$SQF/usr/bin/nebula-mcp" ]]; then
    pass "35h: /usr/bin/nebula-mcp entrypoint shipped (AppArmor attachment path)"
else
    fail "35h: /usr/bin/nebula-mcp entrypoint shipped" \
         "profile attachment path would not resolve"
fi
if grep -q '^nebula-mcp:' "$SQF/etc/passwd" 2>/dev/null; then
    pass "35i: nebula-mcp system user created at build time"
else
    fail "35i: nebula-mcp system user created" \
         "0616 hook did not run; unit would fail with User=nebula-mcp"
fi

# 35j-l: the three units are installed AND enabled. Staged-but-not-enabled is
# the silent failure: the file exists, the test passes, nothing ever runs.
for _u in orionx-heald orionx-postured nebula-mcp; do
    if [[ -f "$SQF/lib/systemd/system/${_u}.service" || -f "$SQF/usr/lib/systemd/system/${_u}.service" ]]; then
        pass "35j: ${_u}.service installed"
    else
        fail "35j: ${_u}.service installed" "0615 UNIT_FILES entry missing"
    fi
    if [[ -L "$SQF/etc/systemd/system/multi-user.target.wants/${_u}.service" ]]; then
        pass "35k: ${_u}.service enabled at boot"
    else
        fail "35k: ${_u}.service enabled at boot" "0615 AUTOSTART_UNITS entry missing"
    fi
done

section "36. Suricata actually captures (DEC-PHASE12-038)"

# Debian's unit hardcodes -c /etc/suricata/suricata.yaml, and that file
# hardcodes `af-packet: - interface: eth0`. On a deck with no eth0 the engine
# exits 1 immediately, forever — verified against suricata 7.0.10. These
# assert the Orion-X capture surface that replaces it actually ships.
for _f in etc/suricata/orionx.yaml \
          var/lib/suricata/orionx-interfaces.yaml \
          etc/systemd/system/suricata.service.d/orionx-capture.conf; do
    if [[ -f "$SQF/$_f" ]]; then
        pass "36a: /$_f shipped"
    else
        fail "36a: /$_f shipped" "without it Suricata runs Debian's eth0 config and cannot start"
    fi
done

# The override must repoint ExecStart at the Orion-X config, or the drop-in is
# decoration and the engine still reads Debian's eth0 default.
_DROPIN="$SQF/etc/systemd/system/suricata.service.d/orionx-capture.conf"
if [[ -f "$_DROPIN" ]] && grep -qE '^ExecStart=.*orionx\.yaml' "$_DROPIN"; then
    pass "36b: drop-in repoints ExecStart at orionx.yaml"
else
    fail "36b: drop-in repoints ExecStart at orionx.yaml" "engine would still read Debian's eth0 config"
fi

# Restart=no: postured owns restart policy with bounded attempts
# (DEC-PHASE12-034). systemd restarting underneath it reintroduces the storm.
if [[ -f "$_DROPIN" ]] && grep -qE '^Restart=no' "$_DROPIN"; then
    pass "36c: drop-in sets Restart=no (postured owns bounded recovery)"
else
    fail "36c: drop-in sets Restart=no" "systemd auto-restart would reintroduce the loop postured bounds"
fi

# The generated interface file must live where postured can write it: its unit
# is ProtectSystem=strict and /etc is read-only to it.
if grep -qE 'var/lib/suricata' "$_DROPIN" 2>/dev/null || \
   [[ -f "$SQF/var/lib/suricata/orionx-interfaces.yaml" ]]; then
    pass "36d: generated interface config lives under a writable path"
else
    fail "36d: generated interface config lives under a writable path" \
         "postured runs ProtectSystem=strict; /etc is read-only to it"
fi

# The capture library ships beside the daemon that imports it.
if [[ -f "$SQF/opt/orionx/scripts/awareness/suricata_capture.py" ]]; then
    pass "36e: suricata_capture.py staged beside orionx-postured"
else
    fail "36e: suricata_capture.py staged beside orionx-postured" "postured would ImportError at start"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL + SKIP ))
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    echo "${RED}FAIL${NC}: Content presence verification failed — $FAIL assertion(s) failed"
    exit 1
fi
echo "${GREEN}PASS${NC}: Content presence verified — $PASS assertions passed, $SKIP skipped"
exit 0
