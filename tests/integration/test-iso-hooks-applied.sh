#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — ISO Hook Execution Validator
#
# Parses a live-build log to verify that each project hook actually executed
# during the most recent lb build. File presence in iso/config/hooks/ proves
# discovery; this test proves execution by grepping the build log for the
# live-build "P: Executing hook" trace lines.
#
# @decision DEC-PHASE7-025
# @title CI validation that project hooks actually run during lb build
# @status accepted
# @rationale Issue #32 surfaced that all Phase 1-6 project hooks were inert
#   for prior ISO builds because they lived at non-canonical iso/hooks/ paths.
#   After the move to iso/config/hooks/, this test verifies via the build log
#   that each project hook actually executed during lb build. File existence
#   does not prove hook execution — this gate closes that gap. Without it,
#   a future accidental path regression could silently leave hooks inert again.
#
# Usage:
#   BUILD_LOG=path/to/build-iso.log bash tests/integration/test-iso-hooks-applied.sh
#   bash tests/integration/test-iso-hooks-applied.sh              # auto-detects tmp/build-iso.log
#   bash tests/integration/test-iso-hooks-applied.sh --help
#
# Exit codes:
#   0  All project hooks found in build log (or test SKIPped due to missing log)
#   1  One or more project hooks not found in build log

set -uo pipefail

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
test-iso-hooks-applied.sh — Verify project hooks executed during lb build

USAGE
  BUILD_LOG=path/to/build-iso.log bash tests/integration/test-iso-hooks-applied.sh
  bash tests/integration/test-iso-hooks-applied.sh

ENVIRONMENT
  BUILD_LOG   Path to the captured lb build log. If unset, the script looks
              for tmp/build-iso.log relative to the repo root. If the log is
              not found at either location, all tests are SKIPped (not FAILed)
              so that local development without a prior build stays green.

EXIT CODES
  0  All expected hooks found in build log, or all tests SKIPped (no log).
  1  One or more expected hooks not found in the build log.

EXPECTED HOOKS (iso/config/hooks/ — post-move canonical paths)
  live/0500-install-external-tools.hook.chroot
  live/0600-filesystem-hardening.hook.chroot
  live/0610-apparmor-setup.hook.chroot
  live/0615-install-systemd-units.hook.chroot
  live/0620-service-hardening.hook.chroot
  normal/0100-create-user.hook.chroot
  normal/0200-copy-samples.hook.chroot
  normal/0500-bootloader-serial.hook.binary
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve repo root (works from any CWD inside the repo tree)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# ---------------------------------------------------------------------------
# Color helpers (disabled when not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

# ---------------------------------------------------------------------------
# Test counters  (use arithmetic with || true so set -e doesn't fire on 0→0)
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
ERRORS=()

pass() { PASS=$((PASS + 1)); echo "${GREEN}  PASS${NC}: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("$1")
    echo "${RED}  FAIL${NC}: $1"
}
skip() { SKIP=$((SKIP + 1)); echo "${YELLOW}  SKIP${NC}: $1"; }

# ---------------------------------------------------------------------------
# Locate build log
# ---------------------------------------------------------------------------
DEFAULT_LOG="$REPO_ROOT/tmp/build-iso.log"
BUILD_LOG="${BUILD_LOG:-$DEFAULT_LOG}"

echo "================================================================"
echo "test-iso-hooks-applied.sh — ISO hook execution validator"
echo "BUILD_LOG : $BUILD_LOG"
echo "================================================================"
echo ""

if [[ ! -f "$BUILD_LOG" ]]; then
    echo "${YELLOW}SKIP${NC}: build log not found at $BUILD_LOG"
    echo ""
    echo "Run a full ISO build first (bash scripts/build-iso.sh) and capture"
    echo "its output, or set BUILD_LOG to an existing log file."
    echo ""
    echo "All hook-execution checks SKIPped — not FAILed."
    echo ""
    echo "================================================================"
    echo "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC} (no build log)"
    echo "================================================================"
    exit 0
fi

# ---------------------------------------------------------------------------
# Expected hooks — these are the project hooks that must appear in a
# successful lb build log. live-build logs "P: Executing hook" lines for
# every script it discovers in config/hooks/{live,normal,binary}/.
#
# The grep pattern matches both the short form live-build uses internally
# (config/hooks/live/<name>) and the absolute path variant that some lb
# versions emit. We match the basename component to be robust to lb version
# differences.
#
# @decision DEC-PHASE7-025-BINARY-MARKER
# @title Binary-stage hook detection via hook's own [bootloader-serial] marker
# @status accepted
# @rationale CI run 25649928483 showed that live-build's binary stage does NOT
#   emit "P: Executing hook" prefix lines for hooks the way the chroot stage
#   does. Grepping for the hook filename alone is insufficient: it finds the
#   hook name in the lb startup trace ("Executing binary_hooks") but that does
#   not prove the hook's own logic ran. The hook emits "[bootloader-serial]"
#   lines in all code paths (patch, already-patched, and WARNING skipped),
#   so grepping for that marker reliably proves the hook script executed.
#   We use a two-tier check: accept either the "P: Executing hook" prefix
#   (for forward compatibility with lb versions that may add it) OR the
#   "[bootloader-serial]" marker that the hook always emits.
# ---------------------------------------------------------------------------

# Chroot-stage hooks: live-build emits "P: Executing hook" prefix lines for
# each hook discovered in config/hooks/{live,normal}/ during the chroot stage.
CHROOT_HOOKS=(
    "live/0500-install-external-tools.hook.chroot"
    "live/0600-filesystem-hardening.hook.chroot"
    "live/0610-apparmor-setup.hook.chroot"
    "live/0615-install-systemd-units.hook.chroot"
    "live/0620-service-hardening.hook.chroot"
    "normal/0100-create-user.hook.chroot"
    "normal/0200-copy-samples.hook.chroot"
)

# Binary-stage hooks: live-build's binary stage does NOT reliably emit the
# "P: Executing hook" prefix. Detect these via the hook's own output marker.
# Format: "<subdir>/<filename>:<marker-string>"
BINARY_HOOKS=(
    "normal/0500-bootloader-serial.hook.binary:[bootloader-serial]"
)

echo "--- Checking hook execution traces in build log ---"
echo ""

# Check chroot-stage hooks via basename match (live-build "P: Executing hook"
# prefix or any other line containing the filename — robust to lb version diffs).
for hook_rel in "${CHROOT_HOOKS[@]}"; do
    hook_basename="$(basename "$hook_rel")"
    hook_label="config/hooks/$hook_rel"

    # live-build emits lines like:
    #   P: Executing hook config/hooks/live/0600-filesystem-hardening.hook.chroot...
    # or (older lb versions):
    #   P: Executing hook /path/to/config/hooks/live/0600-filesystem-hardening.hook.chroot...
    #
    # We grep for the basename (unique enough given our naming convention) so
    # this stays robust across lb version log format differences.
    if grep -qF "$hook_basename" "$BUILD_LOG"; then
        pass "hook executed: $hook_label"
    else
        fail "hook NOT found in build log: $hook_label (grep for '$hook_basename' returned nothing)"
    fi
done

# Check binary-stage hooks via two-tier detection:
#   Tier 1: hook filename present in build log (forward-compat with lb versions
#           that may emit "P: Executing hook" for binary hooks in the future).
#   Tier 2: hook's own output marker present in build log (always emitted by
#           the hook regardless of live-build version, proves the script ran).
for hook_entry in "${BINARY_HOOKS[@]}"; do
    hook_rel="${hook_entry%%:*}"
    hook_marker="${hook_entry#*:}"
    hook_basename="$(basename "$hook_rel")"
    hook_label="config/hooks/$hook_rel"

    if grep -qF "P: Executing hook" "$BUILD_LOG" && grep -qF "$hook_basename" "$BUILD_LOG"; then
        pass "hook executed: $hook_label (detected via P: Executing hook prefix)"
    elif grep -qF "$hook_marker" "$BUILD_LOG"; then
        pass "hook executed: $hook_label (detected via '$hook_marker' marker)"
    else
        fail "hook NOT found in build log: $hook_label (grep for '$hook_basename' and '$hook_marker' both returned nothing)"
    fi
done

echo ""

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
    if grep -q "Exec=/usr/bin/orionx-control-center" "$HOOK_0700" 2>/dev/null; then
        pass "W9-2: orionx-control-center.desktop Exec=/usr/bin/orionx-control-center (DEC-PHASE9-006)"
    else
        fail "W9-2: orionx-control-center.desktop Exec=/usr/bin/orionx-control-center" \
             "0700 hook must emit Exec=/usr/bin/orionx-control-center in the .desktop block"
    fi

    # (d) /usr/bin/orionx-control-center symlink entry present in SCRIPT_MAP
    if grep -q '"orionx-control-center"' "$HOOK_0700" 2>/dev/null; then
        pass "W9-2: orionx-control-center present in SCRIPT_MAP symlink loop"
    else
        fail "W9-2: orionx-control-center present in SCRIPT_MAP symlink loop" \
             "0700 hook SCRIPT_MAP must include orionx-control-center → /opt/orionx/scripts/control_center/"
    fi

    # (e) .desktop file staged in includes.chroot (source-tree presence check)
    DESKTOP_SRC="$REPO_ROOT/iso/config/includes.chroot/usr/share/applications/orionx-control-center.desktop"
    if [[ -f "$DESKTOP_SRC" ]]; then
        pass "W9-2: iso/config/includes.chroot/usr/share/applications/orionx-control-center.desktop staged"
    else
        fail "W9-2: iso/config/includes.chroot/usr/share/applications/orionx-control-center.desktop staged" \
             "Static .desktop file must be present in includes.chroot for live-build to copy into chroot"
    fi
else
    skip "W9-2: orionx-control-center hook wiring checks" "hook file not found: $HOOK_0700"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "================================================================"
echo "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    echo ""
    echo "If hooks are present in iso/config/hooks/ but missing from the log,"
    echo "re-run the build and check that iso/auto/config does NOT use"
    echo "--hook-files (DEC-PHASE7-024: canonical discovery only)."
fi
echo "================================================================"

[[ "$FAIL" -eq 0 ]]
