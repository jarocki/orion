#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE7-002
# @title ISO build pipeline modernization for Phase 7 integration testing
# @status accepted
# @rationale W7-1 introduced --dry-run mode for path-resolution validation on
#   non-Linux hosts, standardized the version string to v2.0.0-rc4 (Phase 9
#   rc4 release), fixed the directory reference from legacy uppercase ISO/ to
#   lowercase iso/ (the actual live-build tree), and moved the logfile from a
#   repo-root litter path to tmp/ per Sacred Practice 3. A single version
#   constant (VERSION) is the sole authority — never duplicated. The script
#   fails loudly if iso/ is absent; there is no silent fallback to ISO/.
#   DEC-PHASE7-002 covers this entire modernization commit.
#
# Usage:
#   bash scripts/build-iso.sh [--dry-run] [--version <ver>]
#
#   --dry-run    Validate prerequisites and paths; do NOT invoke live-build.
#                Exits 0 on success or non-zero on validation failure.
#                Required for non-Linux hosts and CI path-resolution checks.
#
#   --version    Override VERSION (default: v2.0.0-rc4). Must start with 'v'.
#
# Output:
#   output/orionx-phoenix-edition-<VERSION>.iso (full build only)
#   tmp/build-iso.log  (always)
#
# Prerequisites (full build, Linux only):
#   live-build debootstrap squashfs-tools xorriso isolinux
#
# Rollback: revert this single commit to restore prior state.

set -euo pipefail

# ---------------------------------------------------------------------------
# Version authority — single constant, never duplicated.
# Downstream consumers (iso/auto/config, iso-volume label) read ORIONX_VERSION
# from the environment when this script exports it.
# ---------------------------------------------------------------------------
VERSION="${ORIONX_VERSION:-v2.0.0-rc4}"

# ---------------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ISO_DIR="$REPO_ROOT/iso"
OUTPUT_DIR="$REPO_ROOT/output"
TMP_DIR="$REPO_ROOT/tmp"
LOGFILE="$TMP_DIR/build-iso.log"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --version)
                if [[ -z "${2:-}" ]]; then
                    echo "ERROR: --version requires an argument" >&2
                    exit 1
                fi
                VERSION="$2"
                # Enforce v-prefix: version strings must start with 'v'.
                # This guards against accidental semver-only values (e.g. 2.0.0)
                # that would produce unversioned ISO labels and break downstream
                # consumers that expect the canonical 'vMAJOR.MINOR.PATCH-...' form.
                if [[ "$VERSION" != v* ]]; then
                    echo "ERROR: --version value must start with 'v' (got: '$VERSION')" >&2
                    echo "       Example: --version v2.0.0-rc4" >&2
                    exit 1
                fi
                shift 2
                ;;
            --help|-h)
                grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
mkdir -p "$TMP_DIR"
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# ---------------------------------------------------------------------------
# Prerequisite check
#
# On a non-Linux host --dry-run still validates the package list is defined;
# it does NOT attempt dpkg calls (those would fail on macOS).
# ---------------------------------------------------------------------------
REQUIRED_PACKAGES=(live-build debootstrap squashfs-tools xorriso isolinux)

check_prerequisites() {
    log "Checking prerequisites..."

    # Hard stop: iso/ must exist (lowercase). No silent fallback to ISO/.
    if [[ ! -d "$ISO_DIR" ]]; then
        log "ERROR: iso/ directory not found at $ISO_DIR"
        log "       Ensure the repository is complete and 'iso/' (lowercase) is present."
        log "       Do NOT use legacy uppercase 'ISO/' — it is not supported."
        exit 1
    fi
    log "  iso/ directory found: $ISO_DIR"

    if "$DRY_RUN"; then
        log "  [dry-run] Skipping live-build package check on non-Linux or dry-run mode."
        log "  [dry-run] Required packages: ${REQUIRED_PACKAGES[*]}"
        return 0
    fi

    # Full build: verify Debian package manager and packages are present.
    if ! command -v dpkg &>/dev/null; then
        log "ERROR: dpkg not found. ISO build requires a Debian/Ubuntu Linux host."
        log "       On macOS: use 'make iso-build' inside a Docker container."
        exit 1
    fi

    local missing=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERROR: Missing required packages: ${missing[*]}"
        log "       Install with: sudo apt-get install -y ${missing[*]}"
        exit 1
    fi

    log "Prerequisites check passed."
}

# ---------------------------------------------------------------------------
# Stage Orion-X application content into iso/config/includes.chroot/
#
# @decision DEC-PHASE8-004
# @title Stage v2.0.0 application content from repo root into includes.chroot
# @status accepted
# @rationale Issue #43 identified that booted ISOs were missing the entire
#   Orion-X application layer. The root cause was no rsync step between
#   repo-root source dirs and the live-build staging area. This function is
#   the single authority for content staging: it copies scripts/, theme/,
#   data/, and docs/ into includes.chroot so live-build picks them up during
#   the chroot phase. The v2.0.0 source (repo root) is the authoritative
#   content; archive/ is reference-only and is never staged. The
#   wallpapers/ directory carries the Orion-X Phoenix branded wallpaper
#   (orionx-phoenix-wallpaper.png) staged in Phase 8. A defensive README.txt
#   is created only if the directory ends up empty after rsync (e.g. theme/
#   source was missing). Staged content is .gitignored to keep
#   the worktree clean — the repo root is the single source of truth.
#
# @decision DEC-PHASE8-005
# @title Defensive rsync guards for missing source dirs in stage_application_content
# @status accepted
# @rationale CI run 25953342666 failed because theme/ was not tracked by git
#   (git does not track empty dirs), so rsync exited 23 under set -euo pipefail,
#   killing build-iso.sh before lb build ran. Fix: (a) commit theme/wallpapers/.gitkeep
#   so the directory exists post-checkout, and (b) guard every rsync with an
#   existence check so a missing source dir emits a WARN and skips rather than
#   crashing. Option A (explicit if-guard) was chosen over --ignore-missing-args
#   because it is explicit, logs the warning, and does not depend on rsync >= 3.0.
#   Applied to all 4 rsync calls for symmetry — any missing source dir warns,
#   never crashes.
# ---------------------------------------------------------------------------
stage_application_content() {
    log "Staging Orion-X application content into iso/config/includes.chroot/..."
    local stage_dir="$ISO_DIR/config/includes.chroot"

    # Early diagnostic: report any missing source dirs up front so the log
    # is actionable without hunting through per-dir WARN lines.
    local missing_sources=()
    for src in scripts theme data docs; do
        [[ -d "$REPO_ROOT/$src" ]] || missing_sources+=("$src")
    done
    if [[ ${#missing_sources[@]} -gt 0 ]]; then
        log "  WARN: missing source dirs (staging will skip): ${missing_sources[*]}"
    fi

    # Application scripts -> /opt/orionx/scripts/
    mkdir -p "$stage_dir/opt/orionx/scripts"
    if [[ -d "$REPO_ROOT/scripts" ]]; then
        rsync -a --delete \
            --exclude='__pycache__' --exclude='*.pyc' \
            --exclude='build-iso.sh' --exclude='qemu-boot-test.sh' \
            --exclude='release/' --exclude='security/' \
            "$REPO_ROOT/scripts/" "$stage_dir/opt/orionx/scripts/"
    else
        log "  WARN: scripts/ source missing; skipping scripts staging"
    fi

    # Theme -> /opt/orionx/theme/  (wallpapers dir has phoenix wallpaper; README is defensive fallback)
    mkdir -p "$stage_dir/opt/orionx/theme/wallpapers"
    if [[ -d "$REPO_ROOT/theme" ]]; then
        rsync -a --delete "$REPO_ROOT/theme/" "$stage_dir/opt/orionx/theme/"
    else
        log "  WARN: theme/ source missing; skipping theme staging"
    fi
    if [[ ! "$(ls -A "$stage_dir/opt/orionx/theme/wallpapers" 2>/dev/null)" ]]; then
        cat > "$stage_dir/opt/orionx/theme/wallpapers/README.txt" <<'WALLPAPER_EOF'
Orion-X Phoenix Edition Wallpapers
This directory is intended for branded desktop wallpapers.
At v2.0.0-rc4, the phoenix wallpaper asset is staged from theme/wallpapers/.
Default Debian wallpapers are used at runtime.
WALLPAPER_EOF
    fi

    # Sample data -> /opt/orionx/data/
    mkdir -p "$stage_dir/opt/orionx/data"
    if [[ -d "$REPO_ROOT/data" ]]; then
        rsync -a --delete "$REPO_ROOT/data/" "$stage_dir/opt/orionx/data/"
    else
        log "  WARN: data/ source missing; skipping data staging"
    fi

    # Documentation -> /usr/share/doc/orionx/
    mkdir -p "$stage_dir/usr/share/doc/orionx"
    if [[ -d "$REPO_ROOT/docs" ]]; then
        rsync -a --delete "$REPO_ROOT/docs/" "$stage_dir/usr/share/doc/orionx/"
    else
        log "  WARN: docs/ source missing; skipping docs staging"
    fi

    # Also stage CHANGELOG.md + README.md at /usr/share/doc/orionx/ for visibility
    cp "$REPO_ROOT/CHANGELOG.md" "$stage_dir/usr/share/doc/orionx/CHANGELOG.md" 2>/dev/null || true
    cp "$REPO_ROOT/README.md" "$stage_dir/usr/share/doc/orionx/README.md" 2>/dev/null || true

    log "Application content staged: $(find "$stage_dir/opt/orionx" "$stage_dir/usr/share/doc/orionx" -type f 2>/dev/null | wc -l) files"
}

# ---------------------------------------------------------------------------
# Prepare build environment
# ---------------------------------------------------------------------------
prepare_build_env() {
    log "Preparing build environment..."
    mkdir -p "$OUTPUT_DIR"

    if [[ -d "$ISO_DIR/build" ]]; then
        log "Cleaning previous build artifacts..."
        (cd "$ISO_DIR" && lb clean --purge)
    fi

    log "Build environment ready."
}

# ---------------------------------------------------------------------------
# Configure live-build
#
# iso/auto/config is invoked by lb config automatically when present.
# We export VERSION so iso/auto/config can pick it up via $ORIONX_VERSION.
# ---------------------------------------------------------------------------
configure_live_build() {
    log "Configuring live-build (iso/auto/config drives lb config)..."
    export ORIONX_VERSION="$VERSION"
    (cd "$ISO_DIR" && lb config)
    log "Live-build configured."
}

# ---------------------------------------------------------------------------
# Build ISO
# ---------------------------------------------------------------------------
build_iso() {
    log "Running lb build (this may take 30-90 minutes on first run)..."
    (cd "$ISO_DIR" && lb build)

    local built_iso="$ISO_DIR/live-image-amd64.hybrid.iso"
    if [[ ! -f "$built_iso" ]]; then
        log "ERROR: lb build completed but ISO not found at $built_iso"
        exit 1
    fi

    local iso_name="orionx-phoenix-edition-${VERSION}.iso"
    cp "$built_iso" "$OUTPUT_DIR/$iso_name"

    (cd "$OUTPUT_DIR" && sha256sum "$iso_name" > "${iso_name}.sha256")

    log "ISO created: $OUTPUT_DIR/$iso_name"
    log "SHA-256:     $(cat "$OUTPUT_DIR/${iso_name}.sha256")"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    log "Build complete. Build artifacts remain in iso/build/ for inspection."
    log "Run 'lb clean --purge' inside iso/ to reclaim space."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
parse_args "$@"

log "========================================================"
log "Orion-X Phoenix Edition ${VERSION} ISO build"
log "  iso_dir   : $ISO_DIR"
log "  output    : $OUTPUT_DIR"
log "  dry_run   : $DRY_RUN"
log "  logfile   : $LOGFILE"
log "========================================================"

check_prerequisites

if "$DRY_RUN"; then
    log "[dry-run] All path and prerequisite checks passed."
    log "[dry-run] Full build requires: Linux host with live-build installed."
    log "[dry-run] Run without --dry-run on a Linux host to produce the ISO."
    exit 0
fi

prepare_build_env
stage_application_content       # DEC-PHASE8-004: stage v2.0.0 app content (fix #43)
configure_live_build
build_iso
cleanup

log "========================================================"
log "Orion-X Phoenix Edition ${VERSION} build complete!"
log "ISO : $OUTPUT_DIR/orionx-phoenix-edition-${VERSION}.iso"
log "========================================================"
