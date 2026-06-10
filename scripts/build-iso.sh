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
# Stage Nebula AI model into iso/config/includes.chroot/
#
# @decision DEC-PHASE10-008
# @title Nebula model staging: HuggingFace download + SHA-256 verify + rsync into chroot
# @status accepted
# @rationale W10-1 bundles Mistral-7B-Instruct-v0.3 Q4_K_M (4.4 GB, Apache-2.0) directly
#   into the ISO so the system works fully offline on first boot (DEC-006 LOCAL-ONLY).
#   The model is NOT committed to git (4.4 GB would bloat every clone 10x); instead
#   this function downloads it from HuggingFace at build time, verifies SHA-256 against
#   the pinned manifest, and rsyncs into includes.chroot so live-build picks it up.
#   ORIONX_MODEL_LOCAL env var provides an air-gap-builder escape hatch: when set,
#   the file is copied from the local path instead of downloading from HF.
#   This is a SIBLING to stage_application_content() with disjoint subtree ownership:
#   - stage_application_content owns /opt/orionx/{scripts,theme,data,docs}
#   - stage_nebula_model owns /opt/orionx/nebula/models/
#   The two functions MUST NOT cross into each other's subtrees.
#   References: DEC-PHASE10-002 (model selection), DEC-PHASE10-008 (staging path).
# ---------------------------------------------------------------------------
stage_nebula_model() {
    log "Staging Nebula AI model into iso/config/includes.chroot/..."

    local manifest="$ISO_DIR/config/nebula-model-manifest.json"
    if [[ ! -f "$manifest" ]]; then
        log "ERROR: nebula-model-manifest.json not found at $manifest"
        log "       This file is the single authority for the bundled model URL + SHA-256."
        exit 1
    fi

    # Parse manifest fields using python3 (available in the build env).
    # We use python3 rather than jq to avoid a jq dependency gate on the build host.
    local model_filename model_url_primary model_url_fallback model_sha256 model_size_bytes
    model_filename="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['model_filename'])" "$manifest")"
    model_url_primary="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['model_url_primary'])" "$manifest")"
    model_url_fallback="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['model_url_fallback'])" "$manifest")"
    model_sha256="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['model_sha256'])" "$manifest")"
    model_size_bytes="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['model_size_bytes'])" "$manifest")"

    local models_dir="$ISO_DIR/config/includes.chroot/opt/orionx/nebula/models"
    mkdir -p "$models_dir"

    local dest_file="$models_dir/$model_filename"

    # ---------------------------------------------------------------------------
    # Air-gap builder path: ORIONX_MODEL_LOCAL overrides the HF download.
    # When set, the local file is SHA-256 verified (if the manifest has a pinned
    # hash) then copied into the chroot. If model_sha256 is the sentinel
    # TBD-VERIFY-AT-DOWNLOAD, the hash is computed from the local file and
    # used directly (trust-on-first-use; operator should pin after first build).
    # ---------------------------------------------------------------------------
    if [[ -n "${ORIONX_MODEL_LOCAL:-}" ]]; then
        if [[ ! -f "$ORIONX_MODEL_LOCAL" ]]; then
            log "ERROR: ORIONX_MODEL_LOCAL is set but file not found: $ORIONX_MODEL_LOCAL"
            exit 1
        fi
        log "  [air-gap] ORIONX_MODEL_LOCAL=$ORIONX_MODEL_LOCAL — skipping HF download."

        if [[ "$model_sha256" == "TBD-VERIFY-AT-DOWNLOAD" ]]; then
            log "  [air-gap] manifest SHA-256 is TBD; computing from local file..."
            local computed_sha
            computed_sha="$(sha256sum "$ORIONX_MODEL_LOCAL" | awk '{print $1}')"
            log "  [air-gap] computed SHA-256: $computed_sha"
            log "  [air-gap] WARN: Pin model_sha256 in $manifest after verifying this hash."
        else
            log "  [air-gap] Verifying SHA-256 of local file against manifest..."
            local computed_sha
            computed_sha="$(sha256sum "$ORIONX_MODEL_LOCAL" | awk '{print $1}')"
            if [[ "$computed_sha" != "$model_sha256" ]]; then
                log "ERROR: SHA-256 mismatch for $ORIONX_MODEL_LOCAL"
                log "       Expected: $model_sha256"
                log "       Got:      $computed_sha"
                log "       Update the manifest or supply the correct file (DEC-PHASE10-008)."
                exit 1
            fi
            log "  [air-gap] SHA-256 verified: $computed_sha"
        fi

        log "  [air-gap] Copying $ORIONX_MODEL_LOCAL -> $dest_file"
        cp "$ORIONX_MODEL_LOCAL" "$dest_file"

    # ---------------------------------------------------------------------------
    # Network download path: curl with retry, primary URL then fallback.
    # SHA-256 is verified after download. On mismatch the build FAILS LOUDLY.
    # ---------------------------------------------------------------------------
    else
        local tmp_model="$TMP_DIR/${model_filename}.download.$$"
        log "  Downloading model from HuggingFace (primary URL)..."
        log "  URL: $model_url_primary"
        log "  Expected size: approximately $(( model_size_bytes / 1024 / 1024 )) MB"

        local download_ok=false
        # Primary URL: 3 attempts with curl (--retry 3 handles transient failures)
        if curl --fail --location --retry 3 --retry-delay 5 \
                --progress-bar \
                -o "$tmp_model" \
                "$model_url_primary"; then
            download_ok=true
        else
            log "  WARN: Primary URL failed; trying fallback URL..."
            log "  URL: $model_url_fallback"
            if curl --fail --location --retry 3 --retry-delay 5 \
                    --progress-bar \
                    -o "$tmp_model" \
                    "$model_url_fallback"; then
                download_ok=true
            fi
        fi

        if ! "$download_ok"; then
            log "ERROR: Model download failed from both primary and fallback URLs."
            log "       Primary:  $model_url_primary"
            log "       Fallback: $model_url_fallback"
            log "       Set ORIONX_MODEL_LOCAL=/path/to/$(basename "$model_filename") for air-gap builds."
            rm -f "$tmp_model"
            exit 1
        fi

        # SHA-256 verification gate (DEC-PHASE10-008 + DEC-PHASE10-009 chain)
        log "  Verifying SHA-256..."
        local computed_sha
        computed_sha="$(sha256sum "$tmp_model" | awk '{print $1}')"

        if [[ "$model_sha256" == "TBD-VERIFY-AT-DOWNLOAD" ]]; then
            log "  WARN: manifest SHA-256 is TBD-VERIFY-AT-DOWNLOAD (trust-on-first-use)."
            log "  Computed SHA-256: $computed_sha"
            log "  ACTION REQUIRED: Pin this hash as model_sha256 in $manifest"
            log "                   before the next build (DEC-PHASE10-008 lockdown step)."
        else
            if [[ "$computed_sha" != "$model_sha256" ]]; then
                log "ERROR: SHA-256 mismatch — possible corruption or tampered download!"
                log "       Expected: $model_sha256"
                log "       Got:      $computed_sha"
                log "       Refusing to stage an integrity-unverified model (DEC-PHASE10-009)."
                rm -f "$tmp_model"
                exit 1
            fi
            log "  SHA-256 verified: $computed_sha"
        fi

        log "  Moving model to staging directory..."
        mv "$tmp_model" "$dest_file"
    fi

    # ---------------------------------------------------------------------------
    # Generate MANIFEST.sha256 in the models dir.
    # Format: sha256sum compatible (sha256sum -c readable).
    # This is the file integrity.py reads at boot time.
    # Chain: nebula-model-manifest.json (source) ->
    #        stage_nebula_model download+verify (build) ->
    #        MANIFEST.sha256 (staging) ->
    #        integrity.py verify (boot) ->
    #        nebula-runtime.service gate (DEC-PHASE10-009)
    # ---------------------------------------------------------------------------
    log "  Generating MANIFEST.sha256..."
    (cd "$models_dir" && sha256sum "$model_filename" > MANIFEST.sha256)
    log "  MANIFEST.sha256: $(cat "$models_dir/MANIFEST.sha256")"

    log "Nebula model staged: $dest_file ($(du -sh "$dest_file" | cut -f1))"
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
#
# @decision DEC-PHASE9-011
# @title Explicit lb build exit-code capture + fail-loud ISO presence gate
# @status accepted
# @rationale W9-1b (#48): CI run 26492487114 showed build-iso.sh exiting 0
#   even though lb build did not produce an ISO (firmware-* packages failed
#   to resolve; live-build may exit 0 on some package-install failures).
#   Fix: capture lb build's exit code explicitly (not relying solely on
#   set -e propagation through the subshell), log a fatal error, and exit 1
#   immediately if lb_exit != 0. Then perform a belt-and-suspenders check
#   on the expected built_iso path. Finally, after the copy to OUTPUT_DIR,
#   verify the final output ISO glob resolves (the path CI upload-artifact
#   looks for). This function is the single authority for build exit code
#   (iso_build_exit_code_authority). No other caller should mask or ignore
#   these exit codes. References: issue #48, DEC-PHASE9-010, W9-1b.
# ---------------------------------------------------------------------------
build_iso() {
    log "Running lb build (this may take 30-90 minutes on first run)..."

    # Capture lb build's exit code explicitly.  We do NOT use '|| true' or
    # swallow the code through set -e subshell propagation alone — we check
    # it ourselves so the error message is actionable.
    local lb_exit=0
    (cd "$ISO_DIR" && lb build) || lb_exit=$?
    if [[ $lb_exit -ne 0 ]]; then
        log "ERROR: lb build exited with code $lb_exit — no ISO was produced."
        log "       Check the live-build log above for package resolution errors."
        log "       Common cause: non-free firmware packages not resolvable."
        log "       Ensure iso/config/archives/debian-nonfree.list.chroot exists."
        exit 1
    fi

    local built_iso="$ISO_DIR/live-image-amd64.hybrid.iso"
    if [[ ! -f "$built_iso" ]]; then
        log "ERROR: lb build exited 0 but ISO not found at $built_iso"
        log "       lb build may have silently failed. Check the live-build log."
        exit 1
    fi

    local iso_name="orionx-phoenix-edition-${VERSION}.iso"
    cp "$built_iso" "$OUTPUT_DIR/$iso_name"

    (cd "$OUTPUT_DIR" && sha256sum "$iso_name" > "${iso_name}.sha256")

    # Belt-and-suspenders: verify the final output ISO exists before declaring
    # success.  This is the gate that CI's upload-artifact step also checks.
    if [[ ! -f "$OUTPUT_DIR/$iso_name" ]]; then
        log "ERROR: ISO copy to output/ failed — $OUTPUT_DIR/$iso_name not found."
        exit 1
    fi

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
stage_nebula_model              # DEC-PHASE10-008: stage Mistral-7B + integrity chain
configure_live_build
build_iso

# ---------------------------------------------------------------------------
# ISO size sanity check (DEC-PHASE10-012)
# WARN (not fail) when ISO > 7 GB — additive to the existing build gate in
# build_iso(). The existing fail threshold in build_iso() is NOT modified.
# 7 GB is the WARN threshold reflecting the ~6 GB target (DEC-PHASE10-003)
# with headroom for model + toolchain growth. A value over 7 GB requires
# explicit investigation before the next RC cut.
# ---------------------------------------------------------------------------
iso_name="orionx-phoenix-edition-${VERSION}.iso"
if [[ -f "$OUTPUT_DIR/$iso_name" ]]; then
    iso_size_bytes="$(stat --format="%s" "$OUTPUT_DIR/$iso_name" 2>/dev/null || stat -f "%z" "$OUTPUT_DIR/$iso_name" 2>/dev/null || echo 0)"
    iso_size_gb="$(echo "scale=2; $iso_size_bytes / 1073741824" | bc 2>/dev/null || echo "unknown")"
    log "ISO size: ${iso_size_gb} GB (${iso_size_bytes} bytes)"
    # 7 GB in bytes = 7 * 1024^3 = 7516192768
    if [[ "$iso_size_bytes" -gt 7516192768 ]]; then
        log "WARN: ISO size ${iso_size_gb} GB exceeds 7 GB threshold (DEC-PHASE10-012)."
        log "      This is a WARNING, not a build failure. Investigate before next RC cut."
        log "      Target: ~6 GB (DEC-PHASE10-003). Current: ${iso_size_gb} GB."
    else
        log "ISO size ${iso_size_gb} GB is within the 7 GB warn threshold (DEC-PHASE10-012 OK)."
    fi
fi

cleanup

log "========================================================"
log "Orion-X Phoenix Edition ${VERSION} build complete!"
log "ISO : $OUTPUT_DIR/orionx-phoenix-edition-${VERSION}.iso"
log "========================================================"
