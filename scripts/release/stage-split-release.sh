#!/usr/bin/env bash
# stage-split-release.sh — stage a >2 GiB ISO as a verifiable, signed set of
# GitHub release assets.
#
# @decision DEC-PHASE12-115
# @title One script stages, splits, checksums, signs and self-verifies the release
# @status accepted
# @rationale GitHub rejects release assets over 2 GiB and every Trixie image
#   is ~3.1 GB, so release.yml's `files: output/*.iso` could never upload
#   (packages-build P1-1). The manual path (release-process §10) split at
#   1000 MiB although §10.1 records that uploads over ~5 min were reset and the
#   beta actually shipped ~190 MiB parts (F-18); it had no signing step
#   (F-10) and REASSEMBLE.txt and the download notes were hand-written each
#   time. This script is now the single authority for the asset set, used by
#   release.yml and by the §10 manual path alike:
#     <out>/<iso>.part-aa…   parts of PART_SIZE (default 190m), each < 2 GiB
#     <out>/SHA256SUMS       whole ISO + every part (the beta's format)
#     <out>/SHA512SUMS       same, SHA-512
#     <out>/SHA256SUMS.asc, SHA512SUMS.asc   detached signatures (required)
#     <out>/REASSEMBLE.txt   cat / copy /b / verify / dd instructions + ISO hash
#     <out>/RELEASE-NOTES.md the CHANGELOG section for the tag + the same
#                            download/verify instructions (the release body)
#   It refuses: an ISO that fails its .sha256 sidecar; a tag with no CHANGELOG
#   section; a part that is not < 2 GiB; unsigned output unless --unsigned is
#   given (for dry runs and tests only — never publish an --unsigned set).
#   It then proves its own output: the concatenated parts hash to the ISO
#   line, every SHA256SUMS part line verifies, and each signature verifies.
#
# Usage:
#   scripts/release/stage-split-release.sh <iso> <tag> [--out DIR]
#       [--part-size SIZE] [--key FPR] [--unsigned]
#   SIZE is split(1) syntax (190m, 1000k). The output names use <tag>, so the
#   ISO may come from a build file of another name (it is copied only as parts).
#   Environment: ORIONX_GPG_EXTRA_ARGS (e.g. "--pinentry-mode loopback" in CI).
set -euo pipefail

SIGNING_KEY_DEFAULT="4CB08BD1D0B3281613DD15DB1DCCDF47FEEDEEEF"
GITHUB_ASSET_LIMIT=2147483648   # 2 GiB, GitHub's per-asset cap

die() { echo "ERROR: $*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
sha512() { if command -v sha512sum >/dev/null 2>&1; then sha512sum "$@"; else shasum -a 512 "$@"; fi; }
fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

[[ $# -ge 2 ]] || die "usage: $0 <iso> <tag> [--out DIR] [--part-size SIZE] [--key FPR] [--unsigned]"
ISO="$1"; TAG="$2"; shift 2
OUT=""; PART_SIZE="190m"; KEY="$SIGNING_KEY_DEFAULT"; SIGN=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
        --part-size) PART_SIZE="${2:?--part-size needs a size}"; shift 2 ;;
        --key) KEY="${2:?--key needs a fingerprint}"; shift 2 ;;
        --unsigned) SIGN=0; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "$TAG" == v* ]] || die "tag must start with 'v' (got '$TAG')"
[[ -f "$ISO" ]] || die "ISO not found: $ISO"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$HERE")")"
NAME="orionx-phoenix-edition-${TAG}.iso"
OUT="${OUT:-$REPO_ROOT/tmp/release-$TAG}"

# 1. The ISO must match the sidecar the build wrote (if it is beside it).
if [[ -f "$ISO.sha256" ]]; then
    want="$(awk '{print $1; exit}' "$ISO.sha256")"
    got="$(sha256 "$ISO" | awk '{print $1}')"
    [[ "$want" == "$got" ]] || die "$ISO does not match $ISO.sha256 (want $want, got $got)"
    echo "[stage] ISO matches its build sidecar: $got"
fi

# 2. Release notes come from the CHANGELOG section; none means no release.
notes="$(CHANGELOG_PATH="$REPO_ROOT/CHANGELOG.md" bash "$HERE/extract-release-notes.sh" "$TAG")" \
    || die "no CHANGELOG.md section for $TAG; write it before staging the release"

[[ ! -e "$OUT" ]] || [[ -z "$(ls -A "$OUT")" ]] || die "$OUT exists and is not empty; refusing to mix asset sets"
mkdir -p "$OUT"

# 3. Split. -a 2 gives part-aa … part-zz (676 parts).
split -a 2 -b "$PART_SIZE" "$ISO" "$OUT/$NAME.part-"
parts=()
while IFS= read -r p; do parts+=("$(basename "$p")"); done < <(find "$OUT" -maxdepth 1 -name "$NAME.part-*" | sort)
[[ ${#parts[@]} -ge 1 ]] || die "split produced no parts"
for p in "${parts[@]}"; do
    [[ "$(fsize "$OUT/$p")" -lt $GITHUB_ASSET_LIMIT ]] || die "$p is not under GitHub's 2 GiB asset cap"
done

# 4. Checksums: whole ISO first (under the published name), then each part.
iso_sha="$(sha256 "$ISO" | awk '{print $1}')"
iso_sha512="$(sha512 "$ISO" | awk '{print $1}')"
{ printf '%s  %s\n' "$iso_sha" "$NAME"; (cd "$OUT" && sha256 "${parts[@]}"); } > "$OUT/SHA256SUMS"
{ printf '%s  %s\n' "$iso_sha512" "$NAME"; (cd "$OUT" && sha512 "${parts[@]}"); } > "$OUT/SHA512SUMS"

# 5. Instructions, rendered once and used for both REASSEMBLE.txt and the notes.
n=${#parts[@]}
first="${parts[0]##*.part-}"; last="${parts[$((n - 1))]##*.part-}"
copy_list="$(printf '%s + ' "${parts[@]}")"; copy_list="${copy_list% + }"
iso_bytes="$(fsize "$ISO")"
sig_lines=""
if [[ $SIGN -eq 1 ]]; then
    sig_lines="
   Then check the signature on the checksums (signing key
   $KEY — compare it with the fingerprint published outside this repository):

   gpg --recv-keys $KEY     # or import it from a trusted copy
   gpg --verify SHA256SUMS.asc SHA256SUMS
"
fi
instructions="GitHub caps release assets at 2 GiB per file, so the ${iso_bytes}-byte ISO is
published as ${n} parts (part-${first} … part-${last}). Download ALL ${n} parts,
SHA256SUMS and SHA256SUMS.asc into one directory.

1. Reassemble (Linux / macOS):

   cat ${NAME}.part-* > ${NAME}

   Windows (cmd, or PowerShell via cmd /c):

   copy /b ${copy_list} ${NAME}

2. Verify. The reassembled ISO MUST hash to:

   ${iso_sha}

   Linux:   sha256sum -c SHA256SUMS
   macOS:   shasum -a 256 -c SHA256SUMS
   Windows: Get-FileHash ${NAME} -Algorithm SHA256

   SHA256SUMS also lists each part, so a bad download can be pinpointed and
   re-fetched without pulling everything again.
${sig_lines}
3. Write to USB (8 GB or larger; the ISO is hybrid: UEFI and legacy BIOS):

   Linux:   sudo dd if=${NAME} of=/dev/sdX bs=4M status=progress conv=fsync
   macOS:   sudo dd if=${NAME} of=/dev/rdiskN bs=1m

Do not flash a single .part-* file. It is not bootable on its own."
{ echo "Orion-X Phoenix Edition ${TAG}"; echo "=================================================="; echo; echo "$instructions"; } > "$OUT/REASSEMBLE.txt"
# shellcheck disable=SC2016  # the backticks are literal Markdown fences
{ printf '%s\n\n## Download and verify\n\n```\n%s\n```\n' "$notes" "$instructions"; } > "$OUT/RELEASE-NOTES.md"

# 6. Sign the checksum manifests (they cover every part and the whole ISO).
if [[ $SIGN -eq 1 ]]; then
    command -v gpg >/dev/null 2>&1 || die "gpg not found; signing is required (use --unsigned only for dry runs)"
    for f in SHA256SUMS SHA512SUMS; do
        # shellcheck disable=SC2086  # ORIONX_GPG_EXTRA_ARGS is a list of flags
        gpg --batch --yes ${ORIONX_GPG_EXTRA_ARGS:-} --local-user "$KEY" \
            --armor --detach-sign --output "$OUT/$f.asc" "$OUT/$f" \
            || die "gpg could not sign $f with $KEY"
    done
else
    echo "[stage] WARNING: --unsigned: this asset set is NOT publishable (DEC-PHASE12-115)" >&2
fi

# 7. Prove the output before anyone uploads it.
re_sha="$(cat "${parts[@]/#/$OUT/}" | sha256 | awk '{print $1}')"
[[ "$re_sha" == "$iso_sha" ]] || die "reassembled parts hash $re_sha, ISO is $iso_sha"
grep -F ".part-" "$OUT/SHA256SUMS" > "$OUT/.parts.sha256"
(cd "$OUT" && sha256 -c .parts.sha256 >/dev/null) || { rm -f "$OUT/.parts.sha256"; die "a part does not match SHA256SUMS"; }
rm -f "$OUT/.parts.sha256"
if [[ $SIGN -eq 1 ]]; then
    for f in SHA256SUMS SHA512SUMS; do
        gpg --batch --verify "$OUT/$f.asc" "$OUT/$f" 2>/dev/null || die "signature on $f does not verify"
    done
fi
for f in "$OUT"/*; do
    [[ "$(fsize "$f")" -lt $GITHUB_ASSET_LIMIT ]] || die "asset $(basename "$f") is not under 2 GiB"
done

echo "[stage] OK: $n parts of $PART_SIZE, ISO sha256 $iso_sha, signed=$SIGN"
echo "[stage] Assets in $OUT:"
ls -l "$OUT"
echo "[stage] Upload one at a time (release-process §10): gh release upload $TAG --clobber <file>"
