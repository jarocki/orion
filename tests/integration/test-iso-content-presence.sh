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

ISO_PATH="${1:-$REPO_ROOT/output/orionx-phoenix-edition-v2.0.0-rc1.iso}"
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

echo "  Mounting squashfs (extracting selected paths)..."
# Extract only the paths we need to keep this fast
unsquashfs -d "$WORK/sqfs" "$WORK/squashfs.img" \
    "/opt/orionx" \
    "/usr/share/doc/orionx" \
    "/usr/bin/orionx-mesh" \
    "/usr/bin/setup-matrix.sh" \
    "/usr/bin/setup-wireguard.sh" \
    "/usr/bin/artifact-analyzer.py" \
    "/usr/bin/storyboard-gen.py" \
    "/usr/bin/toggle-theme.sh" \
    "/usr/bin/run-lynis.sh" \
    "/usr/bin/download-samples.sh" \
    "/usr/share/applications" \
    2>/dev/null || true  # unsquashfs exits non-zero if some paths absent; we assert individually

echo "  Extraction complete."

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
# 8. File count sanity check
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
