#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE7-002
# @title ISO build pipeline modernization for Phase 7 integration testing
# @status accepted
# @rationale W7-1 introduced --dry-run mode for path-resolution validation on
#   non-Linux hosts, made the version a single derived value (git describe,
#   or ORIONX_VERSION / --version; DEC-PHASE11-VERSION-DEFAULT-001), fixed the directory reference from legacy uppercase ISO/ to
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
#   --version    Override VERSION (default: `git describe --tags --always --dirty`,
#                else dev-unknown). Must start with 'v'. A release-looking version
#                (vX.Y.Z[-rcN|-betaN|-alphaN]) needs its CHANGELOG.md section
#                (DEC-PHASE12-114).
#
# Output:
#   output/orionx-phoenix-edition-<VERSION>.iso (full build only)
#   tmp/build-iso.log  (always)
#   tmp/lb-build-<VERSION>.log  (full build: lb build output, checked for
#                                stale stage skips, DEC-PHASE12-113)
#
# Prerequisites (full build, Linux only):
#   live-build debootstrap squashfs-tools xorriso isolinux
#
# Rollback: revert this single commit to restore prior state.

set -euo pipefail

# ===========================================================================
# Library functions (pure, no side effects at definition time).
#
# Everything above the ORIONX_BUILD_ISO_LIB_ONLY guard below may be SOURCED:
# the macOS wrapper's container step sources this file to publish the ISO,
# and tests/unit/test_build_iso.sh sources it to exercise these functions
# against canned inputs. Keep them free of global state and of `log` (which
# is defined later and writes the build log).
# ===========================================================================

# The ISO filename is derived in exactly one place.
iso_filename() { printf 'orionx-phoenix-edition-%s.iso' "$1"; }

_sha256_check() {  # run in the directory holding the sidecar: _sha256_check <sidecar>
    # No --quiet: macOS's sha256sum lacks it. Exit status is the verdict.
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1" >/dev/null
    else shasum -a 256 -c "$1" >/dev/null; fi
}

# ---------------------------------------------------------------------------
# @decision DEC-PHASE12-111
# @title Publish only the ISO this build produced, by exact name, only on success
# @status accepted
# @rationale The macOS wrapper copied /build/output/*.iso back to the host
#   whatever happened. The volume's output/ is never cleared, so the rc9 run
#   re-copied rc6, rc8 and a September dev9 ISO; and a FAILED build still
#   copied, so a stale same-named ISO from an earlier attempt could overwrite
#   the host's copy (packages-build P2-1). Now the wrapper removes this
#   version's ISO + sidecar from the volume before building, and afterwards
#   publishes exactly `iso_filename VERSION` + its .sha256, only when the
#   build exited 0, after verifying the sidecar in the volume AND again on
#   the host side. Any mismatch is a failure, never a warning.
# ---------------------------------------------------------------------------
publish_built_iso() {  # <src_dir> <dst_dir> <version> <build_rc>
    local src="$1" dst="$2" version="$3" rc="$4" name
    name="$(iso_filename "$version")"
    if [[ "$rc" != "0" ]]; then
        echo "[publish] build exited $rc: NOT publishing anything to $dst" >&2
        return "$rc"
    fi
    if [[ ! -f "$src/$name" || ! -f "$src/$name.sha256" ]]; then
        echo "[publish] ERROR: build exited 0 but $src/$name (+ .sha256) is missing" >&2
        return 1
    fi
    if ! (cd "$src" && _sha256_check "$name.sha256"); then
        echo "[publish] ERROR: $src/$name does not match its own .sha256" >&2
        return 1
    fi
    cp -f "$src/$name" "$src/$name.sha256" "$dst/" || {
        echo "[publish] ERROR: copy of $name to $dst failed" >&2; return 1; }
    if ! (cd "$dst" && _sha256_check "$name.sha256"); then
        echo "[publish] ERROR: copied $dst/$name fails its .sha256" >&2
        return 1
    fi
    echo "[publish] Published to host: $dst/$name (SHA-256 verified)"
}

# ---------------------------------------------------------------------------
# @decision DEC-PHASE12-113
# @title Detect stale "already done" stage skips in the lb build output and fail
# @status accepted
# @rationale The DEC-PHASE11-029 clean guard PREVENTS stale skips only when it
#   recognises the leftover state; nothing DETECTED them (shell P2-6). rc1-55
#   shipped a byte-identical ISO because lb printed "Skipping chroot_hooks,
#   already done" and reused the old chroot, and "0 hook-skips" has been a
#   manual post-build check ever since. live-build prints
#   `Skipping <stage>, already done` (functions/stagefile.sh). After lb build
#   every such line must name a bootstrap* stage (the bootstrap cache is kept
#   on purpose); anything else fails the build before an ISO is published.
# ---------------------------------------------------------------------------
check_no_stale_skips() {  # <lb build output log>
    local log_file="$1" stale
    if [[ ! -f "$log_file" ]]; then
        echo "ERROR: lb build log $log_file not found; cannot prove the build was fresh" >&2
        return 1
    fi
    stale="$(grep -oE 'Skipping [A-Za-z0-9_.-]+, already done' "$log_file" \
             | grep -vE '^Skipping bootstrap[A-Za-z0-9_.-]*, already done$' || true)"
    if [[ -n "$stale" ]]; then
        echo "ERROR: lb build reused stale stages (the ISO would not contain this tree):" >&2
        printf '         %s\n' "$stale" | sort -u >&2
        echo "       Run with ORIONX_FULL_CLEAN=1, or lb clean inside the volume (DEC-PHASE12-113)." >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# @decision DEC-PHASE12-114
# @title A release-looking version needs its CHANGELOG section before it builds
# @status accepted
# @rationale The v2.2.0-beta shipped as v2.2.0-trixie-dev9, and QA found that a
#   v3.0.0 tag on the rc9 bits would bake the wrong identity and publish an
#   empty body (release-tests F-03, F-20). A version that LOOKS like a release
#   (vMAJOR.MINOR.PATCH, optionally -rcN/-betaN/-alphaN, nothing else) is
#   refused unless CHANGELOG.md has a non-empty `## [<version>]` section, as
#   parsed by scripts/release/extract-release-notes.sh (the one parser; the
#   release workflow uses the same script for the release body). git-describe
#   versions (v2.2.0-rc9-3-gabc, -dirty), dev-unknown and other suffixed
#   versions are development builds and are not checked.
# ---------------------------------------------------------------------------
is_release_version() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta|alpha)[0-9]*)?$ ]]; }

require_release_changelog() {  # <version> <repo_root>
    local version="$1" root="$2" notes
    is_release_version "$version" || return 0
    if [[ ! -f "$root/CHANGELOG.md" || ! -f "$root/scripts/release/extract-release-notes.sh" ]]; then
        echo "ERROR: $version is a release version but $root has no CHANGELOG.md or" >&2
        echo "       scripts/release/extract-release-notes.sh to prove its notes exist (DEC-PHASE12-114)." >&2
        return 1
    fi
    if ! notes="$(cd "$root" && CHANGELOG_PATH=CHANGELOG.md bash scripts/release/extract-release-notes.sh "$version" 2>&1)"; then
        echo "ERROR: refusing to build release version $version: CHANGELOG.md has no" >&2
        echo "       '## [$version]' section with content (DEC-PHASE12-114)." >&2
        echo "       Write the section first, or build a development version." >&2
        echo "       extract-release-notes.sh said: $notes" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# @decision DEC-PHASE12-112
# @title live-build patches live in one place, and --allow-remove-essential is
#   scoped to live-build's own temporary-package removal
# @status accepted
# @rationale Two patches to the build container's live-build were applied only
#   by the macOS wrapper, so CI (release.yml, qemu-test.yml) built without
#   them. One of them added --allow-remove-essential to the APT_OPTIONS
#   DEFAULT (and the wrapper passed it in APT_OPTIONS too), which armed it for
#   EVERY apt call live-build makes, including chroot_install-packages: a
#   package-list change that made apt want to drop an essential package would
#   have been obeyed silently (packages-build P2-2). The removal it exists for
#   is Remove_packages (functions/packages.sh), where binary_grub-efi purges
#   the grub-efi-amd64-signed/grub-common it installed temporarily. The flag
#   is now inserted into that one apt-get command and nowhere else. Both
#   patches are verified after sed; a live-build whose text no longer matches
#   fails the build instead of silently building unpatched.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2120  # the optional dir is passed by tests/unit/test_build_iso.sh (T41); the build uses the default
patch_live_build() {  # [functions_dir]
    local fdir="${1:-/usr/share/live/build/functions}"
    # -i.orig + rm: the one in-place form GNU and BSD sed both accept (tests run on macOS).
    _sedi() { sed -i.orig "$1" "$2" && rm -f "$2.orig"; }
    # cache.sh: Restore_package_cache hardlinks (cp -fl) across the chroot
    # tmpfs boundary -> EXDEV. Force a plain copy.
    _sedi 's|cp -fl|cp -f|g' "$fdir/cache.sh"
    if grep -q 'cp -fl' "$fdir/cache.sh"; then
        echo "ERROR: could not patch cp -fl out of $fdir/cache.sh" >&2; return 1
    fi
    # packages.sh: Remove_packages only.
    if ! grep -q 'apt-get remove --auto-remove --purge --allow-remove-essential' "$fdir/packages.sh"; then
        # shellcheck disable=SC2016  # ${APT_OPTIONS} is literal live-build text
        _sedi 's|apt-get remove --auto-remove --purge \${APT_OPTIONS}|apt-get remove --auto-remove --purge --allow-remove-essential ${APT_OPTIONS}|' "$fdir/packages.sh"
    fi
    # shellcheck disable=SC2016  # literal text
    if ! grep -q 'apt-get remove --auto-remove --purge --allow-remove-essential \${APT_OPTIONS}' "$fdir/packages.sh"; then
        echo "ERROR: Remove_packages in $fdir/packages.sh no longer matches; --allow-remove-essential not applied" >&2
        return 1
    fi
    if grep -q -- '--allow-remove-essential' "$fdir/configuration.sh" 2>/dev/null; then
        echo "ERROR: $fdir/configuration.sh carries --allow-remove-essential in the APT_OPTIONS default" >&2
        return 1
    fi
    return 0
}

if [[ "${ORIONX_BUILD_ISO_LIB_ONLY:-}" == "1" ]]; then
    # shellcheck disable=SC2317  # reachable when sourced
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# @decision DEC-PHASE11-MACOS-BUILD-001
# @title macOS host auto-wraps in debian:trixie-slim Docker
# @status active
# @rationale live-build is Debian-native (dpkg, debootstrap, chroot). macOS
#   hosts cannot run it natively. Prior UX required the user to know the
#   docker run incantation; now the script detects Darwin and auto-re-execs
#   itself inside the same debian:trixie-slim container that release.yml
#   uses. Preserves reproducibility with CI and eliminates the "you must be
#   on Linux" wall. The ORIONX_BUILD_IN_DOCKER guard prevents infinite
#   recursion when the script is re-invoked inside the container.
#   Package list mirrors release.yml step "Build ISO in debian:bullseye container".
#   --dry-run bypasses Docker delegation so path-validation works on macOS
#   without Docker (same behaviour as pre-DEC-PHASE11-MACOS-BUILD-001).
# ---------------------------------------------------------------------------
_IS_DRY_RUN_ARG=false
for _arg in "$@"; do
    [[ "$_arg" == "--dry-run" ]] && _IS_DRY_RUN_ARG=true && break
done

if [[ "$(uname -s)" == "Darwin" ]] && [[ "$_IS_DRY_RUN_ARG" == "false" ]]; then
    if [[ -z "${ORIONX_BUILD_IN_DOCKER:-}" ]]; then
        # -------------------------------------------------------------------
        # @decision DEC-PHASE12-014
        # @title Delegation guards: validate args, verify the repo, refuse a busy volume
        # @status accepted
        # @rationale The trixie-dev5 build died at lb chroot_hooks with
        #   "mount: chroot/live-build/config: special device config does not
        #   exist" — /build/iso/config had VANISHED from the shared volume
        #   mid-build. Cause: tests/unit/test_build_iso.sh T9 runs
        #   `bash scripts/build-iso.sh --bogus` from a FAKE repo (scripts/ with
        #   one file). Without --dry-run, this block delegated to Docker, mounted
        #   the fake repo as /host-src, and `rsync -a --delete` replaced the
        #   volume's whole tree (iso/config, iso/auto, docs, theme…) under the
        #   running build; the unknown-flag error only fired afterwards, INSIDE
        #   the container. On an idle volume the next real build silently
        #   re-synced everything, which is why this never surfaced before.
        #   Three independent guards, all BEFORE any docker command:
        #     1. args are validated on the host — only --dry-run, --version V,
        #        --help/-h may proceed; anything else exits 1 here;
        #     2. the source tree must be the real repo (iso/auto/config +
        #        iso/config/package-lists present), or we refuse to delegate;
        #     3. if a container already uses the orionx-lb-work volume, refuse —
        #        two concurrent builds would corrupt each other.
        # -------------------------------------------------------------------
        _argv=("$@")
        _i=0
        _host_version_arg=""
        while [[ $_i -lt ${#_argv[@]} ]]; do
            case "${_argv[$_i]}" in
                --dry-run) ;;
                --version)
                    _i=$((_i + 1))
                    if [[ $_i -ge ${#_argv[@]} || "${_argv[$_i]}" != v* ]]; then
                        echo "ERROR: --version requires a value starting with 'v' (got: '${_argv[$_i]:-}')" >&2
                        exit 1
                    fi
                    _host_version_arg="${_argv[$_i]}"
                    ;;
                --help|-h)
                    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
                    exit 0
                    ;;
                *)
                    echo "ERROR: Unknown argument: ${_argv[$_i]}" >&2
                    echo "       Usage: bash scripts/build-iso.sh [--dry-run] [--version <ver>]" >&2
                    echo "       (refusing to delegate to Docker with invalid arguments — DEC-PHASE12-014)" >&2
                    exit 1
                    ;;
            esac
            _i=$((_i + 1))
        done
        unset _argv _i

        REPO_ROOT_MACOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

        # Guard 2 (DEC-PHASE12-014): only the REAL repo may be rsync --delete'd
        # over the shared build volume. A fake/partial tree would wipe it.
        # Runs BEFORE the Docker probes (release-tests F-16): it is cheaper, it
        # needs no daemon, and a fake tree must be refused even when Docker is down.
        if [[ ! -f "$REPO_ROOT_MACOS/iso/auto/config" || ! -d "$REPO_ROOT_MACOS/iso/config/package-lists" ]]; then
            echo "ERROR: $REPO_ROOT_MACOS does not look like the Orion-X repo (missing iso/auto/config" >&2
            echo "       or iso/config/package-lists). Refusing to delegate: syncing this tree into the" >&2
            echo "       shared build volume would destroy it (DEC-PHASE12-014)." >&2
            exit 1
        fi
        if ! command -v docker >/dev/null 2>&1; then
            echo "ERROR: macOS host detected but 'docker' command not found." >&2
            echo "       Install Docker Desktop and start it, then re-run." >&2
            echo "       (build-iso.sh auto-delegates to debian:trixie-slim on macOS.)" >&2
            exit 1
        fi
        if ! docker info >/dev/null 2>&1; then
            echo "ERROR: Docker daemon not reachable. Start Docker Desktop and re-run." >&2
            exit 1
        fi
        # Guard 3 (DEC-PHASE12-014): one build per volume at a time.
        if [[ -n "$(docker ps -q --filter volume=orionx-lb-work 2>/dev/null)" ]]; then
            echo "ERROR: a container is already using the orionx-lb-work build volume:" >&2
            docker ps --filter volume=orionx-lb-work --format '       {{.ID}}  {{.Image}}  {{.Status}}' >&2
            echo "       Refusing to start a second build on the same volume (DEC-PHASE12-014)." >&2
            exit 1
        fi
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] macOS host detected — delegating to debian:trixie-slim container"

        # -------------------------------------------------------------------
        # @decision DEC-PHASE11-MACOS-BUILD-002 (supersedes DEC-PHASE11-MACOS-BUILD-001)
        # @title Whole-build-in-one-volume strategy for the macOS Docker wrap
        # @status active
        # @rationale The prior bind-mount-into-iso approach (v1) hit a full
        #   spectrum of mount-vs-live-build conflicts: EXDEV on cp -fl between
        #   two volumes, EBUSY on `rm chroot` in bootstrap_cache restore, EBUSY
        #   on `mv chroot chroot.tmp` in binary_chroot. Every live-build stage
        #   that treats `chroot` as a directory-it-owns fails when that path is
        #   a mount point. The only stable solution is to put the entire
        #   live-build workdir on a normal filesystem (a single Docker volume,
        #   no bind mounts within it). Source is rsynced into the volume at
        #   container startup; output ISO is copied back to the host at exit.
        #   Bootstrap+chroot state persists in the volume across runs, so
        #   iteration is still fast.
        # -------------------------------------------------------------------
        # Derive version on host — the rsync excludes .git, so `git describe`
        # inside the container returns nothing. We compute it here and pass via
        # env so ORIONX_VERSION inside the container reflects real repo state.
        if [[ -n "$_host_version_arg" ]]; then
            HOST_VERSION="$_host_version_arg"   # --version wins, as it does inside
        elif [[ -z "${ORIONX_VERSION:-}" ]]; then
            if command -v git >/dev/null 2>&1 && \
               git -C "$REPO_ROOT_MACOS" rev-parse --git-dir >/dev/null 2>&1; then
                _HOST_GIT_VERSION="$(git -C "$REPO_ROOT_MACOS" describe --tags --always --dirty 2>/dev/null || echo "")"
                HOST_VERSION="${_HOST_GIT_VERSION:-dev-unknown}"
            else
                HOST_VERSION="dev-unknown"
            fi
        else
            HOST_VERSION="${ORIONX_VERSION}"
        fi
        # DEC-PHASE12-114: refuse a release identity without release notes on
        # the host, before a 35-minute container build.
        require_release_changelog "$HOST_VERSION" "$REPO_ROOT_MACOS" || exit 1
        mkdir -p "$REPO_ROOT_MACOS/output"

        # Delete stale untracked live-build config outputs so `lb config` re-
        # generates them from our env-supplied APT_OPTIONS on the next run.
        # These 5 files are auto-generated by lb config, not source-of-truth.
        for _stale in common binary chroot bootstrap source; do
            _stale_path="$REPO_ROOT_MACOS/iso/config/$_stale"
            if [[ -f "$_stale_path" ]] && ! git -C "$REPO_ROOT_MACOS" ls-files --error-unmatch "iso/config/$_stale" >/dev/null 2>&1; then
                rm -f "$_stale_path"
            fi
        done
        unset _stale _stale_path

        # Snapshot builds pin an old snapshot whose security Release is past its
        # short Valid-Until; tell apt (live-build's chroot + binary stages, via
        # APT_OPTIONS) to tolerate that. Empty for normal deb.debian.org builds.
        APT_VALID_UNTIL=""
        [ -n "${ORIONX_MIRROR:-}" ] && APT_VALID_UNTIL=" -o Acquire::Check-Valid-Until=false"

        exec docker run --rm --privileged --platform linux/amd64 \
             -v "${REPO_ROOT_MACOS}:/host-src:ro" \
             -v "${REPO_ROOT_MACOS}/output:/host-output" \
             -v orionx-lb-work:/build \
             -w /build \
             -e ORIONX_BUILD_IN_DOCKER=1 \
             -e ORIONX_VERSION="${HOST_VERSION}" \
             -e ORIONX_ISO_VERSION="${ORIONX_ISO_VERSION:-}" \
             -e ORIONX_MODEL_LOCAL="${ORIONX_MODEL_LOCAL:-}" \
             -e ORIONX_MIRROR="${ORIONX_MIRROR:-}" \
             -e ORIONX_SECURITY_MIRROR="${ORIONX_SECURITY_MIRROR:-}" \
             -e ORIONX_GIT_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" \
             -e ORIONX_GIT_TITLE="$(git log -1 --format=%s 2>/dev/null || echo unknown)" \
             -e ORIONX_PHASE_11_SLICES="${ORIONX_PHASE_11_SLICES:-W11-1,W11-2,W11-2b,W11-2c,W11-2d,W11-2e,W11-2f,W11-3,W11-4,W11-5,W11-6,W11-7,W11-8,W11-9a,W11-9a2,W11-9b,W11-11,W11-12,W11-13}" \
             -e APT_OPTIONS="--yes -o Acquire::Retries=5${APT_VALID_UNTIL}" \
             -e APTITUDE_OPTIONS="--assume-yes -o Acquire::Retries=5${APT_VALID_UNTIL}" \
             debian:trixie-slim \
             bash -c '
                 set -e
                 # When a mirror override is set (e.g. snapshot.debian.org to dodge a
                 # broken live security index), repoint the build container apt too
                 # so the host toolchain (gnupg etc.) resolves consistently.
                 # (DEC-PHASE12-001: base is trixie; suite codenames updated.)
                 if [ -n "$ORIONX_MIRROR" ]; then
                     {
                       echo "deb $ORIONX_MIRROR trixie main contrib non-free non-free-firmware"
                       echo "deb ${ORIONX_SECURITY_MIRROR:-$ORIONX_MIRROR} trixie-security main contrib non-free non-free-firmware"
                       echo "deb $ORIONX_MIRROR trixie-updates main contrib non-free non-free-firmware"
                     } > /etc/apt/sources.list
                     # snapshot.debian.org serves original security Release files
                     # whose Valid-Until has since passed; tolerate for this build.
                     echo "Acquire::Check-Valid-Until \"false\";" > /etc/apt/apt.conf.d/99snapshot-valid-until
                 fi
                 # Retries: snapshot.debian.org occasionally drops a connection
                 # mid-fetch (observed on the rc1-85 build: libksba8 "Remote end
                 # closed connection"). Without retries one dropped packet fails
                 # the whole toolchain install before lb build even starts.
                 # (DEC-PHASE11-046)
                 apt-get update -q -o Acquire::Retries=5
                 apt-get install -y -q --no-install-recommends \
                     -o Acquire::Retries=5 \
                     live-build debootstrap xorriso isolinux \
                     ca-certificates wget gnupg python3 \
                     squashfs-tools rsync cpio

                 # live-build patches (cp -fl, Remove_packages) are applied by the
                 # inner build-iso.sh itself: patch_live_build, DEC-PHASE12-112.

                 # Self-heal a stranded binary/ from a prior failed binary_iso
                 # run. binary_iso does `mv binary chroot` (into the chroot) so
                 # it can invoke xorriso from inside the chroot; if xorriso
                 # fails, the mv-back-out step never runs and binary/ is
                 # stranded at chroot/binary. Restore it here so the retry
                 # sees the expected layout.
                 if [ -d /build/iso/chroot/binary ] && [ ! -d /build/iso/binary ]; then
                     mv /build/iso/chroot/binary /build/iso/binary
                     rm -f /build/iso/chroot/binary.sh
                 fi

                 # Sync source into the build volume. Exclude live-build persistent
                 # workdirs (they live in the volume across runs), git internals
                 # (not needed for build), and irrelevant/bulky host-only paths.
                 rsync -a --delete \
                       --exclude=/iso/chroot --exclude=/iso/cache \
                       --exclude=/iso/.build --exclude=/iso/binary \
                       --exclude=/iso/build  --exclude=/iso/live-image-\* \
                       --exclude=/output     --exclude=/.git \
                       --exclude=/.worktrees --exclude=/tmp \
                       --exclude=/.claude    --exclude=/.venv \
                       --exclude=/node_modules \
                       /host-src/ /build/

                 mkdir -p /build/output

                 # DEC-PHASE12-111: the ISO for this version must come from THIS run.
                 ORIONX_BUILD_ISO_LIB_ONLY=1 . /build/scripts/build-iso.sh
                 _iso="$(iso_filename "$ORIONX_VERSION")"
                 rm -f "/build/output/$_iso" "/build/output/$_iso.sha256"

                 # Run the build (do NOT exec — we need to publish the output after).
                 set +e
                 bash /build/scripts/build-iso.sh "$@"
                 rc=$?
                 set -e

                 # Publish exactly that ISO + sidecar, only on success, verified.
                 publish_built_iso /build/output /host-output "$ORIONX_VERSION" "$rc" || exit $?
                 exit $rc
             ' -- "$@"
    fi
fi
unset _IS_DRY_RUN_ARG _arg

# ---------------------------------------------------------------------------
# @decision DEC-PHASE11-VERSION-DEFAULT-001
# @title Post-tag develop builds default to descriptive git-derived version string
# @status active
# @rationale Hardcoded `v2.0.0-rc9` default confused post-tag builds —
#   ISO filenames did not reflect actual source. Now derives from
#   `git describe --tags --always --dirty` if inside a git repo, falls
#   back to `dev-unknown` otherwise. ORIONX_VERSION env override still
#   wins (used by release.yml tag-triggered builds). The --version CLI
#   flag (enforces v-prefix) overrides the derived value for manual builds.
# ---------------------------------------------------------------------------
if [[ -z "${ORIONX_VERSION:-}" ]]; then
    _SCRIPT_DIR_TMP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _REPO_ROOT_TMP="$(dirname "$_SCRIPT_DIR_TMP")"
    if command -v git >/dev/null 2>&1 && \
       git -C "$_REPO_ROOT_TMP" rev-parse --git-dir >/dev/null 2>&1; then
        _GIT_VERSION="$(git -C "$_REPO_ROOT_TMP" describe --tags --always --dirty 2>/dev/null || echo "")"
        VERSION="${_GIT_VERSION:-dev-unknown}"
    else
        VERSION="dev-unknown"
    fi
    unset _SCRIPT_DIR_TMP _REPO_ROOT_TMP _GIT_VERSION
else
    VERSION="${ORIONX_VERSION}"
fi

# ---------------------------------------------------------------------------
# W11-11 (DEC-PHASE11-015): Build metadata exports for /etc/orionx-version
# KEY=VALUE manifest. The 0700 hook reads these from the chroot environment at
# build time and writes them into /etc/orionx-version for orionx-diag + MOTD.
# Fallback to 'unknown' when git is unavailable (e.g. CI Docker without .git).
# PHASE_11_SLICES is hardcoded here — build-iso.sh is the authoritative seat
# for the slice list (orionx-diag trusts the manifest, never hardcodes slices).
# ---------------------------------------------------------------------------
# NOTE (DEC-PHASE11-020): respect an inherited value before deriving from git.
# Under the macOS Docker wrap the inner copy of this script runs in a container
# whose /build tree EXCLUDES /.git (see the wrapper's rsync), so `git rev-parse`
# there always fails and would clobber the correct value the wrapper passed in
# via `docker run -e`. Derive only when the caller supplied nothing.
export ORIONX_GIT_SHA
ORIONX_GIT_SHA="${ORIONX_GIT_SHA:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
export ORIONX_GIT_TITLE
ORIONX_GIT_TITLE="${ORIONX_GIT_TITLE:-$(git log -1 --format=%s 2>/dev/null || echo unknown)}"
export ORIONX_PHASE_11_SLICES="W11-1,W11-2,W11-2b,W11-2c,W11-2d,W11-2e,W11-2f,W11-3,W11-4,W11-5,W11-6,W11-7,W11-8,W11-9a,W11-9a2,W11-9b,W11-11,W11-12,W11-13"

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
                    echo "       Example: --version v2.0.0-rc9" >&2
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
# @rationale W11-1 swaps the bundled model to Qwen2.5-3B-Instruct Q4_K_M (~1.9 GB, Apache-2.0)
#   per DEC-PHASE11-002 (Mistral-7B-Instruct-v0.3 Q4_K_M retired). The model is bundled
#   directly into the ISO so the system works fully offline on first boot (DEC-006 LOCAL-ONLY).
#   The model is NOT committed to git (~1.9 GB would still bloat every clone); instead
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
    # Network download path: wget with retry, primary URL then fallback.
    # curl is NOT installed in the debian:trixie-slim build container used by
    # qemu-test.yml (only wget is pre-installed).  wget equivalents:
    #   curl --fail --location --retry 3 --retry-delay 5 -o dest url
    #   → wget -O dest --tries=3 --waitretry=5 --timeout=120 --no-verbose url
    # SHA-256 is verified after download. On mismatch the build FAILS LOUDLY.
    # ---------------------------------------------------------------------------
    else
        local tmp_model="$TMP_DIR/${model_filename}.download.$$"
        log "  Downloading model from HuggingFace (primary URL)..."
        log "  URL: $model_url_primary"
        log "  Expected size: approximately $(( model_size_bytes / 1024 / 1024 )) MB"

        local download_ok=false
        # Primary URL: 3 attempts with wget (--tries=3 handles transient failures)
        if wget -O "$tmp_model" \
                --tries=3 --waitretry=5 --timeout=120 \
                --no-verbose \
                "$model_url_primary"; then
            download_ok=true
        else
            log "  WARN: Primary URL failed; trying fallback URL..."
            log "  URL: $model_url_fallback"
            if wget -O "$tmp_model" \
                    --tries=3 --waitretry=5 --timeout=120 \
                    --no-verbose \
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
# ---------------------------------------------------------------------------
# W11-14: stage build metadata as a FILE for the 0700 chroot hook.
#
# @decision DEC-PHASE11-020
# @title Build metadata crosses into the chroot via a staged file, not the environment
# @status accepted
# @rationale W11-13 T4 exported ORIONX_GIT_SHA/TITLE/PHASE_11_SLICES and plumbed
#   them through `docker run -e`, on the assumption that hook 0700 could read them
#   "from the chroot environment at build time". It cannot: live-build chroot hooks
#   do not inherit the invoking shell's environment. Proven on the 2026-08-07 build —
#   every field fell back to its default:
#       ISO_VERSION=v2.0.0-rc8   GIT_HEAD_SHA=unknown
#       GIT_HEAD_TITLE=unknown   PHASE_11_SLICES=unknown
#   ...while the ISO itself was v2.1.0-rc1-25-gdb03cb9. Content-presence 32d passed
#   because it only asserted the three `-e ORIONX_GIT_*` strings exist in this
#   script, never that the values arrive.
#   A file crosses the chroot boundary; an environment variable does not. This
#   preserves DEC-PHASE11-015 single-writer discipline: hook 0700 remains the ONLY
#   writer of /etc/orionx-version. This fragment is a build-time INPUT, consumed
#   and deleted by that hook — not a second manifest.
# ---------------------------------------------------------------------------
stage_build_env() {
    log "Staging build metadata for the chroot hooks (DEC-PHASE11-020)..."
    local stage_dir="$ISO_DIR/config/includes.chroot/etc"
    local manifest="$ISO_DIR/config/nebula-model-manifest.json"
    mkdir -p "$stage_dir"

    # Model identity is owned by nebula-model-manifest.json (DEC-PHASE11-002).
    # Hook 0510 needs the ollama tag + filename but cannot read the manifest: it
    # is build configuration and is never staged into the chroot. Forward the two
    # fields it needs rather than letting the hook hardcode a second copy.
    local ollama_tag model_filename
    ollama_tag="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['ollama_model_tag'])" "$manifest")"
    model_filename="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['model_filename'])" "$manifest")"

    # Values MUST be shell-quoted: this file is sourced by hooks 0510 and 0700, and
    # ORIONX_GIT_TITLE is an arbitrary git commit subject. An unquoted subject
    # containing parentheses — e.g. a merge commit "Merge x into develop (DEC-...)"
    # — is a shell syntax error that kills the sourcing hook. Observed 2026-08-19:
    #   /etc/orionx-build-env: line 6: syntax error near unexpected token `('
    # _shq wraps a value in single quotes and escapes any embedded single quote,
    # which is safe for every byte a commit subject can contain.
    _shq() { printf "'%s'" "$(printf '%s' "${1-}" | sed "s/'/'\\\\''/g")"; }

    cat > "$stage_dir/orionx-build-env" <<BUILDENV
# Generated by scripts/build-iso.sh. Read by hook 0510 (nebula model registration);
# consumed and REMOVED by hook 0700. Hook order matters: 0510 runs before 0700.
# Values are single-quoted: this file is SOURCED, and the git subject is free text.
# Do not edit or commit.
ORIONX_VERSION=$(_shq "${VERSION}")
ORIONX_GIT_SHA=$(_shq "${ORIONX_GIT_SHA:-unknown}")
ORIONX_GIT_TITLE=$(_shq "${ORIONX_GIT_TITLE:-unknown}")
ORIONX_PHASE_11_SLICES=$(_shq "${ORIONX_PHASE_11_SLICES:-unknown}")
ORIONX_OLLAMA_MODEL_TAG=$(_shq "${ollama_tag}")
ORIONX_MODEL_FILENAME=$(_shq "${model_filename}")
BUILDENV
    chmod 644 "$stage_dir/orionx-build-env"
    log "  build env staged: ORIONX_VERSION=${VERSION} GIT_SHA=${ORIONX_GIT_SHA:-unknown} TAG=${ollama_tag}"
}

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
            --exclude='release/' \
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
At v2.0.0-rc9, the phoenix wallpaper asset is staged from theme/wallpapers/.
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
# Generate bootloader configs from the single --bootappend-live source
#
# @decision DEC-PHASE11-012
# @title Bootloader cmdline single-authority: generate isolinux.cfg + grub.cfg
#   from --bootappend-live in iso/auto/config at build time (issue #64)
# @status accepted
# @rationale The rc7-rc9 hotfix arc directly edited iso/config/includes.binary/
#   isolinux.cfg and iso/config/includes.binary/boot/grub/grub.cfg to inject
#   live-config.username= and live-config.hostname= tokens. Hardware attestation
#   of rc9 (2026-07-05) proved that /proc/cmdline never showed the tokens despite
#   three release cuts of edits — the static cfg dual-authority was dead-authority.
#   DEC-PHASE10-018 identified the hazard; this function retires it.
#
#   Single-authority discipline (Sacred Practice #12): iso/auto/config's
#   --bootappend-live string is the ONE authoritative source. This function
#   reads it, validates it, and writes both bootloader configs from embedded
#   HEREDOC templates. The generated files carry a "GENERATED — do not edit"
#   marker so any human-edit attempt is immediately visible in git diff.
#
#   The identity tokens this function injects (orionx-operator / orionx) are
#   per the DEC-PHASE11-012 product identity decision (supersedes
#   DEC-PHASE10-017 / DEC-PHASE10-018 rc7-rc9 identity of orionx / orionx-cyberdeck).
#
#   Callers: main() — invoked before configure_live_build() so the generated
#   files land in iso/config/includes.binary/ before lb_binary_local-includes
#   copies them into binary/.
# ---------------------------------------------------------------------------
generate_bootloader_configs() {
    log "Generating bootloader configs from single --bootappend-live source (DEC-PHASE11-012)..."

    local auto_config="$ISO_DIR/auto/config"
    if [[ ! -f "$auto_config" ]]; then
        log "ERROR: iso/auto/config not found at $auto_config"
        log "       Cannot extract --bootappend-live string — build aborted."
        exit 1
    fi

    # Extract the --bootappend-live value from iso/auto/config.
    # The line has the form:
    #   --bootappend-live "boot=live components ... live-config.username=... live-config.hostname=..."
    # We use grep + sed to isolate the quoted string content.
    local bootappend_line
    bootappend_line="$(grep -- '--bootappend-live' "$auto_config" | grep -v '^\s*#' | head -1)"
    if [[ -z "$bootappend_line" ]]; then
        log "ERROR: --bootappend-live not found in $auto_config"
        log "       The single-authority cmdline source is missing — build aborted."
        exit 1
    fi

    # Extract the quoted value using bash native regex.
    # BASH_REMATCH[1] captures the quoted content; using [[ =~ ]] avoids the
    # echo|sed subshell and is SC2001-clean (native regex, no external tool).
    # The + quantifier (not *) requires at least one char, so empty-quoted-content
    # fails the match and falls through to the error branch — same fail-loud behavior
    # as the previous two-step (sed + [[ -z ]]) implementation.
    local bootappend
    if [[ "$bootappend_line" =~ --bootappend-live[[:space:]]*\"([^\"]+)\" ]]; then
        bootappend="${BASH_REMATCH[1]}"
    else
        log "ERROR: Failed to parse --bootappend-live value from: $bootappend_line"
        exit 1
    fi

    # Validate that the required identity tokens are present.
    if ! echo "$bootappend" | grep -q 'live-config.username='; then
        log "ERROR: --bootappend-live does not contain live-config.username= token"
        log "       Update iso/auto/config before building. (DEC-PHASE11-012)"
        exit 1
    fi
    if ! echo "$bootappend" | grep -q 'live-config.hostname='; then
        log "ERROR: --bootappend-live does not contain live-config.hostname= token"
        log "       Update iso/auto/config before building. (DEC-PHASE11-012)"
        exit 1
    fi

    log "  --bootappend-live: $bootappend"

    # Failsafe kernel args (label-specific, orthogonal to --bootappend-live)
    local failsafe_extra="nosplash text noapic noapm nodma nomce nosmp nolapic"

    # Output paths
    local isolinux_dir="$ISO_DIR/config/includes.binary/isolinux"
    local grub_dir="$ISO_DIR/config/includes.binary/boot/grub"
    mkdir -p "$isolinux_dir" "$grub_dir"

    local isolinux_cfg="$isolinux_dir/isolinux.cfg"
    local grub_cfg="$grub_dir/grub.cfg"

    # -----------------------------------------------------------------------
    # Generate isolinux.cfg (BIOS bootloader)
    # -----------------------------------------------------------------------
    cat > "$isolinux_cfg" << ISOLINUX_EOF
# GENERATED — do not edit — regenerate via scripts/build-iso.sh
#
# @decision DEC-PHASE11-012
# @title Bootloader cmdline single-authority (issue #64)
# @status accepted
# @rationale This file is generated by scripts/build-iso.sh::generate_bootloader_configs()
#   from the single --bootappend-live source in iso/auto/config. Direct edits
#   will be overwritten on the next build. The rc7-rc9 dual-authority arc (where
#   this file was hand-edited without effect on /proc/cmdline) is retired.
#   References: DEC-PHASE11-012, DEC-PHASE10-018 (superseded), issue #64, issue #65.
#
# @decision DEC-PHASE11-042
# @title BIOS/isolinux path gets the Phoenix graphical boot menu too
# @status accepted
# @rationale The operator boots via an unknown firmware mode ("not sure").
#   The prior generated isolinux.cfg was a PLAIN auto-boot config (no 'ui'
#   directive, prompt 0, 1s timeout) — it overrode live-build's default
#   vesamenu-based menu, so a BIOS/CSM boot showed no themed menu at all,
#   only the old splash. vesamenu.c32 and its deps (libcom32/libutil/libmenu/
#   ldlinux/libgpl) are already present in the ISO (live-build stages them),
#   and vesamenu is the exact module Debian live uses, so this is low risk —
#   if VESA graphics are unavailable vesamenu falls back to a text menu rather
#   than failing to boot. We restore a 'ui vesamenu.c32' menu with the Phoenix
#   palette, a 5s visible timeout, and a fitted 640x480 Phoenix background
#   (orionx-isolinux-bg.png, default VESA mode for max legacy compatibility).
#   This retires the W11-9a3 "BIOS menu deferred" note under DEC-PHASE11-013.
#
# Generated from: iso/auto/config::--bootappend-live
# Active cmdline (live label):
#   $bootappend
#
# timeout: units are 1/10th second. timeout 50 = 5.0 seconds before auto-boot,
#   long enough to see the themed menu. prompt 0: the 'ui' menu still displays;
#   this only suppresses the legacy text "boot:" prompt.

serial 0 115200

ui vesamenu.c32
menu title Orion-X Phoenix Edition
menu background orionx-isolinux-bg.png
menu tabmsg Use arrow keys to select. Enter to boot.

# Phoenix palette. vesamenu format: menu color <element> <ansi> <fg> <bg> <shadow>
# fg/bg are AARRGGBB hex (#00000000 = fully transparent, shows the background).
menu color title       1;37;40   #ffe84000 #00000000 std
menu color sel         7;37;40   #ff101010 #ffe84000 all
menu color unsel       37;40     #fff0f0f0 #00000000 std
menu color hotsel      1;7;37;40 #ff101010 #ffe84000 all
menu color hotkey      1;37;40   #ffff6b00 #00000000 std
menu color help        37;40     #ffb0b0b0 #00000000 std
menu color timeout     1;37;40   #ffe84000 #00000000 std
menu color timeout_msg 37;40     #ffb0b0b0 #00000000 std
menu color border      30;40     #00000000 #00000000 std

default live
timeout 50
prompt 0

label live
    menu label Orion-X Live
    kernel /live/vmlinuz
    initrd /live/initrd.img
    append $bootappend

label live-noquestions
    menu label Orion-X Live (no questions)
    kernel /live/vmlinuz
    initrd /live/initrd.img
    append $bootappend orionx.wizard=0

label live-failsafe
    menu label Orion-X Live (failsafe)
    kernel /live/vmlinuz
    initrd /live/initrd.img
    append $bootappend $failsafe_extra
ISOLINUX_EOF

    log "  Generated: $isolinux_cfg"

    # -----------------------------------------------------------------------
    # Generate grub.cfg (UEFI bootloader) — graphical, ALWAYS READABLE menu.
    #
    # @decision DEC-PHASE11-044 (amended by DEC-PHASE12-042)
    # @title Retire the GRUB gfxmenu THEME; the menu itself is graphical again
    # @status accepted — amended
    # @rationale The GRUB gfxmenu theme (DEC-PHASE11-013/040/041) failed on real
    #   UEFI hardware twice: rc1-79 fell back to the text menu (no font loaded),
    #   and rc1-81 — even with the loadfont fix — errored out and rendered an
    #   unreadable font (operator report 2026-09-12). gfxmenu theming is fragile
    #   across firmware/panel combos. Per operator directive, the Phoenix boot
    #   identity moves to the Plymouth splash (DEC-PHASE11-044), which paints
    #   AFTER the kernel's i915 KMS comes up — far more reliable than GRUB
    #   graphics. So GRUB dropped gfxterm/gfxmenu/gfxmode/loadfont/`set theme`
    #   entirely and used its native text console.
    #
    #   AMENDED by DEC-PHASE12-042 (see the block below for the evidence):
    #   `set theme` and the gfxmenu ENGINE stay retired by default — that is the
    #   part that failed. gfxterm, a loaded font and a background_image come
    #   back, gated on `if loadfont`, drawing GRUB's own menu. The distinction
    #   is the whole decision: the theme engine is what rendered unreadably; a
    #   picture behind GRUB's native menu cannot. The themed BIOS isolinux
    #   vesamenu menu stays (DEC-PHASE11-042). theme.txt is still referenced
    #   only under ORIONX_GRUB_THEME=1; background.png is now used by default.
    #   Single authority preserved (DEC-PHASE11-012): generated every build.
    # -----------------------------------------------------------------------
    # ---------------------------------------------------------------------
    # Phoenix UEFI graphics — ON by default (ORIONX_GRUB_GRAPHICS, default 1).
    #
    # @decision DEC-PHASE12-042
    # @title Graphical UEFI boot menu via gfxterm + background_image, NOT gfxmenu
    # @status accepted
    # @rationale The operator asked for graphics at boot. UEFI was the one boot
    #   surface still rendering plain text, because DEC-PHASE11-044 retired the
    #   GRUB gfxmenu THEME after it failed on real hardware twice: rc1-79 loaded
    #   no font and fell back, and rc1-81 -- "even with the loadfont fix" --
    #   errored and rendered an unreadable menu. Both failures cost the operator
    #   the failsafe entry, which exists for when things are already wrong.
    #
    #   Inspecting the shipped rc4 ISO explains the first failure outright. The
    #   boot chain is:
    #     efi.img:/EFI/boot/bootx64.efi
    #       -> efi.img:/boot/grub/grub.cfg
    #            search --set=root --file /.disk/info
    #            set prefix=($root)/boot/grub
    #            configfile ($root)/boot/grub/grub.cfg      <-- THIS generator
    #   and the ISO's /boot/grub contains:
    #     unicode.pf2, config.cfg, theme.cfg, splash.png, themes/orionx/,
    #     live-theme/, x86_64-efi/*.mod
    #   There is NO /boot/grub/fonts/ directory on the ISO. DEC-PHASE12-030's
    #   revival block does `loadfont /boot/grub/fonts/unicode.pf2` -- a path
    #   that has never existed in this image. loadfont therefore failed, and
    #   `terminal_output gfxterm` ran with no font loaded. That IS the rc1-79
    #   symptom, and it is also why rc1-81's gfxmenu theme rendered unreadably:
    #   theme.txt asks for "DejaVu Sans Bold 16"/"Bold 14", GRUB resolves an
    #   unavailable font name to whatever is loaded, and nothing was.
    #   (Verified 2026-10-03 against output/orionx-phoenix-edition-v2.2.0-rc4.iso
    #   and its efi.img; live-build's own /boot/grub/config.cfg resolves the font
    #   as `unicode` or `$prefix/unicode.pf2` -- never under fonts/.)
    #
    #   So the default changes, but NOT to the thing that failed. This block:
    #     - resolves the font exactly the way live-build's own config.cfg does,
    #       which is the most field-tested resolution available for this image;
    #     - GATES everything behind `if loadfont`, so the rc1-79 state (gfxterm
    #       with no font) is now unreachable rather than merely unlikely;
    #     - draws the menu with GRUB's NATIVE menu renderer over a
    #       background_image, with explicit menu_color_* -- there is no theme
    #       engine, no theme.txt, no absolute pixel layout, and no font named by
    #       string. The rc1-81 failure mode has no code path left to occur in;
    #     - falls back to solid-colour gfxterm if background_image fails, so a
    #       missing or corrupt PNG costs the picture, never the menu;
    #     - offers gfxmode candidates smallest-known-good first rather than
    #       `auto`, keeping the text legible instead of 12px on a 4K panel.
    #
    #   Worst case at each step is "less pretty", and the menu entries stay
    #   readable and selectable. That is the property DEC-PHASE11-044 was
    #   protecting, and it is preserved here by construction rather than by
    #   avoidance. ORIONX_GRUB_GRAPHICS=0 restores the bare text menu in one
    #   env var if hardware still disagrees.
    #
    #   NOT set here: gfxpayload. Leaving it unset keeps GRUB's own default
    #   handoff to the kernel. The Plymouth splash is the one boot surface that
    #   is verified working on this hardware and it depends on that handoff;
    #   pinning a payload mode would put an unverified variable in front of a
    #   verified result.
    #
    #   ORDER MATTERS, twice over. The font must load before gfxterm is
    #   selected (that ordering was never the bug, but it is still required),
    #   and this block must come BEFORE the serial block: `terminal_output
    #   gfxterm` REPLACES the output list, so a serial append has to follow it.
    #   DEC-PHASE12-030's block sat after the serial lines and silently dropped
    #   GRUB's serial console -- the console the QEMU CI gate reads.
    # ---------------------------------------------------------------------
    local grub_graphics_block=""
    if [[ "${ORIONX_GRUB_GRAPHICS:-1}" == "1" ]]; then
        log "  GRUB UEFI graphics ENABLED (default; ORIONX_GRUB_GRAPHICS=0 to disable) — DEC-PHASE12-042"
        # shellcheck disable=SC2016  # literal grub.cfg text; $ belongs to GRUB.
        grub_graphics_block='# --- Phoenix UEFI graphics (DEC-PHASE12-042) -------------------------------
# Font resolution copied from live-build'"'"'s own /boot/grub/config.cfg. There is
# no /boot/grub/fonts/ on this ISO; unicode.pf2 sits at the root of $prefix.
if [ x$feature_default_font_path = xy ] ; then
    set orionx_font=unicode
else
    set orionx_font=$prefix/unicode.pf2
fi

# Everything graphical is gated on the font actually loading. If it does not,
# GRUB stays on its text console and the menu below is still readable.
if loadfont $orionx_font ; then
    insmod all_video
    insmod gfxterm
    insmod gfxterm_background
    insmod png
    set gfxmode=1024x768,800x600,auto
    terminal_output gfxterm

    # Phoenix background behind GRUB'"'"'s OWN menu renderer (no gfxmenu theme).
    # In gfxterm a "black" background colour is drawn transparent, so the image
    # shows through the menu text.
    if background_image -m stretch $prefix/themes/orionx/background.png ; then
        set color_normal=white/black
        set color_highlight=black/red
        set menu_color_normal=white/black
        set menu_color_highlight=black/red
    else
        set color_normal=light-gray/black
        set color_highlight=black/light-gray
        set menu_color_normal=light-gray/black
        set menu_color_highlight=black/light-gray
    fi
fi
# --- end Phoenix UEFI graphics ---------------------------------------------
'
    else
        log "  GRUB UEFI graphics DISABLED (ORIONX_GRUB_GRAPHICS=0) — plain text menu"
    fi

    # ---------------------------------------------------------------------
    # Optional GRUB gfxmenu THEME revival — still OFF unless ORIONX_GRUB_THEME=1.
    #
    # @decision DEC-PHASE12-030 (amended by DEC-PHASE12-042)
    # @title GRUB gfxmenu theme stays opt-in; its dead font path is fixed
    # @status accepted
    # @rationale DEC-PHASE11-044 retired the gfxmenu theme after two hardware
    #   failures. DEC-PHASE12-042 explains the mechanism (loadfont pointed at
    #   /boot/grub/fonts/unicode.pf2, which does not exist on the ISO) and
    #   delivers the graphics the operator asked for without the theme engine.
    #
    #   This flag is NOT promoted to default. Fixing the font path makes the
    #   gfxmenu path testable for the first time, but it does not make it
    #   verified: theme.txt still lays the menu out in absolute pixels against a
    #   gfxmode this code cannot predict, and still names DejaVu faces that are
    #   not shipped as .pf2 in this image, so GRUB will substitute. "Probably
    #   fine now" is not evidence, and the cost of being wrong is an unreadable
    #   menu with no failsafe entry. It flips when someone boots an
    #   ORIONX_GRUB_THEME=1 ISO on the reference deck and reports a readable
    #   menu -- and then it is a one-line change with a hardware result behind it.
    #
    #   When enabled, this REPLACES the native-menu colours above with the
    #   theme engine; the font load and gfxterm selection from the graphics
    #   block are reused, so this block must stay after it.
    # ---------------------------------------------------------------------
    local grub_theme_block=""
    if [[ "${ORIONX_GRUB_THEME:-0}" == "1" ]]; then
        log "  GRUB gfxmenu THEME ENABLED (ORIONX_GRUB_THEME=1) — see DEC-PHASE12-030/042"
        log "  NOTE: this path failed on UEFI hardware twice (DEC-PHASE11-044)."
        log "        The dead font path (DEC-PHASE12-042) is fixed, but the theme is"
        log "        still UNVERIFIED on hardware. Confirm the menu is READABLE"
        log "        on the reference deck before shipping an image built this way."
        if [[ "${ORIONX_GRUB_GRAPHICS:-1}" != "1" ]]; then
            log "ERROR: ORIONX_GRUB_THEME=1 requires ORIONX_GRUB_GRAPHICS=1."
            log "       The theme needs the font load and gfxterm selection that"
            log "       the graphics block performs. Re-run without ORIONX_GRUB_GRAPHICS=0."
            exit 1
        fi
        # shellcheck disable=SC2016  # literal grub.cfg text; $ belongs to GRUB.
        grub_theme_block='# gfxmenu theme (ORIONX_GRUB_THEME=1, DEC-PHASE12-030). Applies only if the
# graphics block above actually reached gfxterm — $orionx_font is set either
# way, so re-test loadfont rather than assuming.
if loadfont $orionx_font ; then
    insmod gfxmenu
    set theme=$prefix/themes/orionx/theme.txt
fi
'
    fi

    cat > "$grub_cfg" << GRUB_EOF
# GENERATED — do not edit — regenerate via scripts/build-iso.sh
#
# @decision DEC-PHASE11-012
# @title Bootloader cmdline single-authority (issue #64)
# @status accepted
# @rationale This file is generated by scripts/build-iso.sh::generate_bootloader_configs()
#   from the single --bootappend-live source in iso/auto/config. Direct edits
#   will be overwritten on the next build. The rc7-rc9 dual-authority arc (where
#   this file was hand-edited without effect on /proc/cmdline) is retired.
#   References: DEC-PHASE11-012, DEC-PHASE10-018 (superseded), issue #64, issue #65.
#
# @decision DEC-PHASE11-044, amended by DEC-PHASE12-042
# @title Graphical GRUB menu without the gfxmenu theme engine
# @status accepted
# @rationale The GRUB gfxmenu THEME errored + rendered an unreadable font on
#   real UEFI hardware (rc1-79/rc1-81); its loadfont pointed at
#   /boot/grub/fonts/unicode.pf2, a path this ISO does not have. 'set theme'
#   remains opt-in (ORIONX_GRUB_THEME=1). What is enabled by default is
#   gfxterm + background_image behind GRUB's OWN menu renderer, gated on the
#   font actually loading, so the worst case is a plain readable menu rather
#   than an unreadable one. The Plymouth splash remains the primary Phoenix
#   boot identity. ORIONX_GRUB_GRAPHICS=0 reverts to bare text.
#
# Generated from: iso/auto/config::--bootappend-live
# Active cmdline (Orion-X Live menuentry):
#   $bootappend
#
# set timeout=5: show the menu 5s (lets the operator pick failsafe), then
#   auto-boot the default. set default=0: boot the first menuentry.
# "(no questions)" appends orionx.wizard=0: the first-boot wizard takes every
#   default without prompting (DEC-PHASE12-106; UX-14 — a responder booting
#   on a hostile network at 3 a.m. should not be asked for a hostname).

${grub_graphics_block}${grub_theme_block}
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input --append serial
terminal_output --append serial

set timeout=5
set default=0

menuentry "Orion-X Live" {
    linux /live/vmlinuz $bootappend
    initrd /live/initrd.img
}

menuentry "Orion-X Live (no questions)" {
    linux /live/vmlinuz $bootappend orionx.wizard=0
    initrd /live/initrd.img
}

menuentry "Orion-X Live (failsafe)" {
    linux /live/vmlinuz $bootappend $failsafe_extra
    initrd /live/initrd.img
}
GRUB_EOF

    log "  Generated: $grub_cfg"

    # -----------------------------------------------------------------------
    # Stage GRUB theme assets to the binary-tree path live-build's GRUB reads.
    #
    # @decision DEC-PHASE11-013 (continued)
    # The chroot post-install path (/usr/share/grub/themes/orionx/ staged by
    # W11-9) is distinct from the binary-partition path GRUB actually reads
    # during live-boot (/boot/grub/themes/orionx/).  Both are needed:
    #   - chroot path: for update-grub on an installed system
    #   - binary path: for the live-boot GRUB menu (what we activate here)
    # Source of truth: iso/config/includes.chroot/usr/share/grub/themes/orionx/
    # Destination: iso/config/includes.binary/boot/grub/themes/orionx/
    # We copy (not symlink) for reliability — live-build flattens symlinks and
    # some toolchains do not preserve cross-layer symlinks during binary assembly.
    # -----------------------------------------------------------------------
    local grub_theme_src="$ISO_DIR/config/includes.chroot/usr/share/grub/themes/orionx"
    local grub_theme_dst="$ISO_DIR/config/includes.binary/boot/grub/themes/orionx"

    if [[ -d "$grub_theme_src" ]]; then
        mkdir -p "$grub_theme_dst"
        cp -f "$grub_theme_src/theme.txt" "$grub_theme_dst/theme.txt"
        if [[ -f "$grub_theme_src/background.png" ]]; then
            cp -f "$grub_theme_src/background.png" "$grub_theme_dst/background.png"
        fi
        log "  GRUB theme staged: $grub_theme_dst"
        log "    theme.txt: $(wc -c < "$grub_theme_dst/theme.txt") bytes"
        if [[ -f "$grub_theme_dst/background.png" ]]; then
            log "    background.png: $(wc -c < "$grub_theme_dst/background.png") bytes"
        fi
    else
        log "  WARN: GRUB theme source not found at $grub_theme_src — theme will not render"
        log "        W11-9 must run before this step to stage the chroot theme assets."
    fi

    log "Bootloader configs generated from single --bootappend-live source."
    log "  Identity tokens confirmed: $(echo "$bootappend" | grep -oE 'live-config\.(username|hostname)=[^ ]*' | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# Prepare build environment
# ---------------------------------------------------------------------------
prepare_build_env() {
    log "Preparing build environment..."
    mkdir -p "$OUTPUT_DIR"

    # DEC-PHASE12-112: one authority for the live-build patches, CI and macOS alike.
    # They edit the toolchain's own files, so they run only inside a build
    # container (Docker sets /.dockerenv; the macOS wrap sets ORIONX_BUILD_IN_DOCKER).
    if [[ -f /.dockerenv || -n "${ORIONX_BUILD_IN_DOCKER:-}" ]]; then
        # shellcheck disable=SC2119  # default functions dir inside the build container
        patch_live_build || exit 1
        log "  live-build patched: cp -fl -> cp -f; --allow-remove-essential in Remove_packages only"
    else
        log "  WARN: not in a build container; live-build left unpatched (DEC-PHASE12-112)."
        log "        binary_grub-efi's cleanup may stop on apt's essential-package guard."
    fi

    # @decision DEC-PHASE11-029
    # @title Clean guard must detect the REAL live-build tree, not iso/build/
    # @status accepted
    # @rationale The prior guard tested `iso/build/` — a directory live-build
    #   NEVER creates (it uses iso/chroot, iso/binary, iso/.build, iso/cache).
    #   In the persistent Docker build volume (orionx-lb-work) this made the
    #   clean dead code: `lb build` found the previous run's completed
    #   .build/chroot_hooks + .build/binary_* stamps and printed
    #   "W: Skipping chroot_hooks, already done" / "Skipping binary_hooks",
    #   reusing a stale chroot and emitting a byte-identical ISO. Proof:
    #   rc1-55 built in ~8 min with SHA ebc4e645… IDENTICAL to rc1-49, so none
    #   of the committed fixes (wallpaper, W11-14j/k, greeter) were baked.
    #   Fix: detect chroot/.build/binary and run `lb clean` (NOT --purge) so
    #   the chroot + hooks + includes + squashfs all rebuild, while the
    #   bootstrap + package caches survive (skips re-debootstrap for speed).
    #   Use --purge only when ORIONX_FULL_CLEAN=1 (drops caches too).
    if [[ -d "$ISO_DIR/chroot" || -d "$ISO_DIR/.build" || -d "$ISO_DIR/binary" ]]; then
        if [[ "${ORIONX_FULL_CLEAN:-0}" == "1" ]]; then
            log "Cleaning previous live-build tree (FULL purge — drops bootstrap+package caches)..."
            (cd "$ISO_DIR" && lb clean --purge)
        else
            log "Cleaning previous chroot/binary (force fresh chroot+hooks+includes; keep caches)..."
            (cd "$ISO_DIR" && lb clean)
        fi
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
    local lb_log="$TMP_DIR/lb-build-${VERSION}.log"
    set +e
    (cd "$ISO_DIR" && lb build) 2>&1 | tee "$lb_log"
    lb_exit=${PIPESTATUS[0]}
    set -e
    if [[ $lb_exit -ne 0 ]]; then
        log "ERROR: lb build exited with code $lb_exit — no ISO was produced."
        log "       Check the live-build log above for package resolution errors."
        log "       Common cause: non-free firmware packages not resolvable."
        log "       Ensure iso/config/archives/debian-nonfree.list.chroot exists."
        exit 1
    fi

    # DEC-PHASE12-113: a build that reused stale stages is not this tree.
    check_no_stale_skips "$lb_log" || exit 1
    log "  lb build output: no stale stage skips (bootstrap cache reuse only)"

    local built_iso="$ISO_DIR/live-image-amd64.hybrid.iso"
    if [[ ! -f "$built_iso" ]]; then
        log "ERROR: lb build exited 0 but ISO not found at $built_iso"
        log "       lb build may have silently failed. Check the live-build log."
        exit 1
    fi

    local iso_name
    iso_name="$(iso_filename "$VERSION")"
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

# DEC-PHASE12-114: also in --dry-run, so CI and tests can prove the refusal.
require_release_changelog "$VERSION" "$REPO_ROOT" || exit 1

if "$DRY_RUN"; then
    log "[dry-run] All path and prerequisite checks passed."
    log "[dry-run] Full build requires: Linux host with live-build installed."
    log "[dry-run] Run without --dry-run on a Linux host to produce the ISO."
    exit 0
fi

prepare_build_env
stage_build_env                 # W11-14: hand build metadata to the 0700 chroot hook via file, not env
stage_application_content       # DEC-PHASE8-004: stage v2.0.0 app content (fix #43)
stage_nebula_model              # DEC-PHASE10-008: stage Qwen2.5-3B + integrity chain
generate_bootloader_configs     # DEC-PHASE11-012: write isolinux.cfg + grub.cfg from single --bootappend-live source (issue #64)
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
iso_name="$(iso_filename "$VERSION")"
if [[ -f "$OUTPUT_DIR/$iso_name" ]]; then
    iso_size_bytes="$(stat --format="%s" "$OUTPUT_DIR/$iso_name" 2>/dev/null || stat -f "%z" "$OUTPUT_DIR/$iso_name" 2>/dev/null || echo 0)"
    # awk, not bc: bc is not in the build container (packages-build P3-4).
    iso_size_gb="$(awk -v b="$iso_size_bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')"
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
log "ISO : $OUTPUT_DIR/$(iso_filename "$VERSION")"
log "========================================================"
