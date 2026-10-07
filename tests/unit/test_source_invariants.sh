#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_source_invariants.sh — the source-tree checks that used to live in the
# ISO gate's sections 29-33 (DEC-PHASE12-119, release-tests F-06).
#
# They are properties of the SOURCE (annotations, git mode bits, build-script
# text, package-list lines), so they belong in a unit suite; the ISO gate now
# asserts the shipped outcome of each fix instead. 31c was wrong: it required
# "debian:bullseye" in build-iso.sh and passed only because of a stale comment;
# it now requires the trixie build container.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $1 — ${2:-}"; }
has() { grep -q -- "$2" "$REPO_ROOT/$1" 2>/dev/null; }
hasE() { grep -qE -- "$2" "$REPO_ROOT/$1" 2>/dev/null; }
check() { if "$@"; then return 0; else return 1; fi; }

echo "[29] sample honesty, annotations, Plymouth initramfs check (P2-002, P3-001, P3-002)"
has scripts/download-samples.sh 'mini_sample_SYNTHETIC\.raw' && pass "29a: _SYNTHETIC sample name" || fail "29a" "download-samples.sh"
has scripts/download-samples.sh 'SYNTHETIC PLACEHOLDER' && pass "29b: placeholder README text" || fail "29b" "download-samples.sh"
has scripts/toggle-theme.sh 'DEC-PHASE11-014' && pass "29c: toggle-theme.sh cites DEC-PHASE11-014" || fail "29c" "annotation"
has iso/config/hooks/live/0800-orionx-branding.hook.chroot 'lsinitramfs' && pass "29d: 0800 verifies the theme with lsinitramfs" || fail "29d" "no lsinitramfs"
has iso/config/hooks/live/0800-orionx-branding.hook.chroot 'DEC-PHASE11-018' && pass "29e: 0800 cites DEC-PHASE11-018" || fail "29e" "annotation"

echo "[30] orionx-imager #77"
D=scripts/orionx-imager/lib/devices.py
hasE "$D" '"diskutil", "list", "-plist"\]|"diskutil", "list", "-plist",$' && pass "30a: diskutil list -plist without 'external'" || fail "30a" "$D"
has "$D" '"diskutil", "list", "-plist", "external"' && fail "30b" "'external' still present" || pass "30b: old 'external' call absent"
has "$D" 'DEC-PHASE11-IMAGER-001' && has "$D" RemovableMedia && has "$D" Ejectable && pass "30c-e: annotation + RemovableMedia/Ejectable filters" || fail "30c-e" "$D"

echo "[31] macOS wrap + version derivation"
B=scripts/build-iso.sh
hasE "$B" '"Darwin"' && pass "31a: Darwin detection" || fail "31a" "$B"
has "$B" ORIONX_BUILD_IN_DOCKER && pass "31b: recursion guard" || fail "31b" "$B"
has "$B" 'debian:trixie-slim' && pass "31c: build container is debian:trixie-slim (was a stale bullseye check)" || fail "31c" "no debian:trixie-slim"
has "$B" 'ORIONX_VERSION:-v2.0.0-rc9' && fail "31d" "stale default" || pass "31d: no stale v2.0.0-rc9 default"
has "$B" 'git describe --tags' && pass "31e: git-derived version" || fail "31e" "$B"
has "$B" DEC-PHASE11-MACOS-BUILD-001 && has "$B" DEC-PHASE11-VERSION-DEFAULT-001 && pass "31f-g: annotations" || fail "31f-g" "$B"
hasE Makefile 'uname.*!=.*Linux' && fail "31h" "Makefile still blocks non-Linux" || pass "31h: Makefile does not block non-Linux"

echo "[32] W11-13 source side"
has "$B" "--exclude='security/'" && fail "32a" "security/ still excluded" || pass "32a: security/ not excluded from staging"
[[ "$(grep -cE -- '-e ORIONX_GIT_SHA|-e ORIONX_GIT_TITLE|-e ORIONX_PHASE_11_SLICES' "$REPO_ROOT/$B")" -ge 3 ]] && pass "32d: git metadata plumbed into docker run" || fail "32d" "$B"
[[ "$(grep -cE 'FATAL:.*(matrix-commander|capa)' "$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot")" -ge 2 ]] && pass "32e: 0500 hard-fails capa + matrix-commander" || fail "32e" "0500"
[[ "$(grep -cE '^(git|python3-pip|firefox-esr)$' "$REPO_ROOT/iso/config/package-lists/orionx.list.chroot")" -ge 3 ]] && pass "32f: git/python3-pip/firefox-esr listed" || fail "32f" "package list"
for f in scripts/security/first-boot-wizard.sh "$B" iso/config/hooks/live/0500-install-external-tools.hook.chroot; do
    bash -n "$REPO_ROOT/$f" 2>/dev/null && pass "32j: bash -n $f" || fail "32j: bash -n $f" "syntax"
done

echo "[33] iso/auto/config execute bit (#82)"
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    M="$(git -C "$REPO_ROOT" ls-files -s iso/auto/config | awk '{print $1}')"
    [[ "$M" == 100755 ]] && pass "33a: tracked mode 100755" || fail "33a" "mode '$M'"
else
    skip "33a: tracked mode" "not a git checkout"
fi
[[ -x "$REPO_ROOT/iso/auto/config" ]] && pass "33b: working-tree copy executable" || fail "33b" "not executable"

echo "[hooks-applied static checks, moved from the ISO log gate (F-15d)]"
HOOK_0700="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
# ---------------------------------------------------------------------------
# rc4 broken-basics: assert .desktop entries use xfce4-terminal, not lxterminal
# These checks are static (no build log needed) — they validate the hook file
# content directly. They do NOT require a built ISO.
# ---------------------------------------------------------------------------
echo "--- rc4 static checks: .desktop Exec strings in 0700 hook ---"
echo ""

HOOK_0700="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
if [[ -f "$HOOK_0700" ]]; then
    # Must have xfce4-terminal in Exec lines
    if grep -q "xfce4-terminal" "$HOOK_0700"; then
        pass "rc4: 0700 hook uses xfce4-terminal in .desktop Exec lines"
    else
        fail "rc4: 0700 hook uses xfce4-terminal in .desktop Exec lines"
    fi
    # Must have zero FUNCTIONAL lxterminal references.
    # Filter comments first so @decision documentation that mentions lxterminal
    # (explaining that xfce4-terminal replaced it) does not trigger a false fail.
    # Matches the approach in tests/unit/test_orionx_setup_hook_unit.sh.
    LXTERM_COUNT="$(grep -v '^\s*#' "$HOOK_0700" | grep -c "lxterminal" || true)"
    if [[ "$LXTERM_COUNT" -eq 0 ]]; then
        pass "rc4: 0700 hook has zero functional lxterminal references"
    else
        fail "rc4: 0700 hook has zero functional lxterminal references" \
             "Found $LXTERM_COUNT functional reference(s) — switch all Exec lines to xfce4-terminal"
    fi
    # Must have the one-click mesh launcher
    if grep -q "orionx-start-mesh.desktop" "$HOOK_0700"; then
        pass "rc4: 0700 hook creates orionx-start-mesh.desktop one-click launcher"
    else
        fail "rc4: 0700 hook creates orionx-start-mesh.desktop one-click launcher"
    fi
else
    skip "rc4: 0700 hook static checks" "hook file not found: $HOOK_0700"
fi

# nm-applet autostart: network-manager-gnome ships /etc/xdg/autostart/nm-applet.desktop
# In the source tree (includes.chroot), this file should NOT be present (the
# package itself installs it at build time). Verify the package is in the list.
PKG_LIST="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
if [[ -f "$PKG_LIST" ]]; then
    if grep -q "^network-manager-gnome$" "$PKG_LIST"; then
        pass "rc4: network-manager-gnome in package list (ships nm-applet autostart)"
    else
        fail "rc4: network-manager-gnome in package list (ships nm-applet autostart)"
    fi
    if grep -q "^network-manager$" "$PKG_LIST"; then
        pass "rc4: network-manager in package list"
    else
        fail "rc4: network-manager in package list"
    fi
    if grep -q "^wpasupplicant$" "$PKG_LIST"; then
        pass "rc4: wpasupplicant in package list"
    else
        fail "rc4: wpasupplicant in package list"
    fi
    if grep -q "^iw$" "$PKG_LIST"; then
        pass "rc4: iw in package list"
    else
        fail "rc4: iw in package list"
    fi
else
    skip "rc4: package list checks" "package list not found: $PKG_LIST"
fi

echo ""

# ---------------------------------------------------------------------------
# rc5 W9-2 static checks: orionx-control-center .desktop + symlink in 0700 hook
#
# @decision DEC-PHASE10-005
# @title Control Center ships ahead of Phase 10 Nebula AI; hook wiring
#        is asserted here as a static gate that does not require a built ISO.
# @status accepted
# @rationale The 0700 hook is the single authority for /usr/bin symlinks
#   (0700_hook_path_symlinks_authority) and .desktop launchers
#   (0700_hook_desktop_launcher_authority). These checks confirm both wires
#   are present in the hook source so a future refactor cannot silently
#   remove them. DEC-PHASE9-006 invariant: no lxterminal in any Exec line
#   of the orionx-control-center .desktop (GTK app, no terminal wrapper).
#   Comment-filtering matches the approach in the rc4 static checks above:
#   `grep -v '^\s*#' | grep -c lxterminal` so @decision documentation that
#   mentions lxterminal does not false-positive.
# ---------------------------------------------------------------------------
echo "--- rc5 W9-2 static checks: orionx-control-center hook wiring ---"
echo ""

if [[ -f "$HOOK_0700" ]]; then
    # (a) .desktop launcher present: /usr/share/applications/orionx-control-center.desktop
    if grep -q "orionx-control-center.desktop" "$HOOK_0700"; then
        pass "W9-2: 0700 hook creates /usr/share/applications/orionx-control-center.desktop"
    else
        fail "W9-2: 0700 hook creates /usr/share/applications/orionx-control-center.desktop"
    fi

    # (b) .desktop Exec line is NOT lxterminal (DEC-PHASE9-006 invariant).
    #     Filter comment lines first to avoid false-positives from @decision
    #     documentation that mentions lxterminal for historical context.
    LXTERM_CONTROL="$(grep -v '^\s*#' "$HOOK_0700" | grep -c "lxterminal" || true)"
    if [[ "$LXTERM_CONTROL" -eq 0 ]]; then
        pass "W9-2: orionx-control-center .desktop does NOT use lxterminal (DEC-PHASE9-006)"
    else
        fail "W9-2: orionx-control-center .desktop does NOT use lxterminal" \
             "Found $LXTERM_CONTROL functional lxterminal reference(s) — DEC-PHASE9-006 violated"
    fi

    # (c) Exec line for orionx-control-center.desktop uses absolute path
    # DEC-PHASE12-053: the entry opens the Orion Cockpit on a tab (still a direct GTK binary).
    if grep -q "Exec=/usr/bin/orionx-cockpit --tab network" "$HOOK_0700" 2>/dev/null; then
        pass "W9-2: orionx-control-center.desktop Exec opens the Cockpit tabs directly (DEC-PHASE12-053, DEC-PHASE9-006)"
    else
        fail "W9-2: orionx-control-center.desktop Exec=/usr/bin/orionx-cockpit --tab network" \
             "0700 hook must emit the Cockpit-tab Exec in the .desktop block (the tabs live in the Cockpit now)"
    fi

    # (d) /usr/bin/orionx-control-center symlink entry present in SCRIPT_MAP
    if grep -q '"orionx-control-center"' "$HOOK_0700" 2>/dev/null; then
        pass "W9-2: orionx-control-center present in SCRIPT_MAP symlink loop"
    else
        fail "W9-2: orionx-control-center present in SCRIPT_MAP symlink loop" \
             "0700 hook SCRIPT_MAP must include orionx-control-center → /opt/orionx/scripts/control_center/"
    fi

    # (e) .desktop file staged in includes.chroot (source-tree presence check)
    # DEC-PHASE12-053: the 0700 hook is the ONLY writer of this file. rc7 shipped a
    # stale entry because a static copy here was edited while the hook's heredoc
    # overwrote it at build time. A static copy must NOT exist.
    DESKTOP_SRC="$REPO_ROOT/iso/config/includes.chroot/usr/share/applications/orionx-control-center.desktop"
    if [[ ! -f "$DESKTOP_SRC" ]]; then
        pass "W9-2: no static orionx-control-center.desktop beside the 0700 heredoc (one writer)"
    else
        fail "W9-2: no static orionx-control-center.desktop beside the 0700 heredoc" \
             "a static copy exists and the hook overwrites it at build time — delete it (DEC-PHASE12-053)"
    fi
else
    skip "W9-2: orionx-control-center hook wiring checks" "hook file not found: $HOOK_0700"
fi

echo ""


echo; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
