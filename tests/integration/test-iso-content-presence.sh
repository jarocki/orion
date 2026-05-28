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
# Default ISO path: output/orionx-phoenix-edition-v2.0.0-rc1.iso
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed or prerequisites missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISO_PATH="${1:-$REPO_ROOT/output/orionx-phoenix-edition-v2.0.0-rc4.iso}"
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
# 12. File count sanity check (renumbered from 8)
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
