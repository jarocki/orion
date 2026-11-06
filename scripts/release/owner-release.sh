#!/usr/bin/env bash
# shellcheck shell=bash
#
# owner-release.sh — the owner's end of a release, as one script with checks,
# retries and waits (release-process §1, §4, §10; DEC-PHASE13-029).
#
# @decision DEC-PHASE13-038
# @title The owner's release steps are a script with error checking, retries
#   and waits, not a list of commands to paste
# @status accepted
# @rationale v3.1.3 was tagged on the wrong commit because seven stacked PRs
#   were merged nine seconds apart, before GitHub retargeted them, and the
#   fast-forward and tag followed from a pasted list without a check between
#   steps (2026-11-02). Every step here verifies its effect before the next
#   runs, every network call retries, and every wait polls with a delay. The
#   script is idempotent per step and can resume (--from STEP). It never holds
#   the passphrase: `stage-split-release.sh` asks gpg, which asks you.
#
# Steps, in order (each checks its preconditions and its outcome):
#   merge     wait for the PR's checks, merge it, wait until GitHub says MERGED
#   ff-main   main := origin/develop by fast-forward only; push
#   tag       annotated tag on main == origin/develop; refuses to move an
#             existing tag unless --retag; push
#   ci        wait for the tag's release.yml run; it must end green (its last
#             step is the hand-off to you, by design)
#   download  the run's artifact; verify the ISO against its sidecar
#   stage     stage-split-release.sh on the CI ISO (checkout must be at the tag)
#   release   draft GitHub Release with notes + sums + signatures; upload the
#             parts one by one, each verified by size through the API, retried
#   verify    asset count and sizes; fresh download of SHA256SUMS(.asc); gpg
#   publish   flip the draft (only with --publish)
#
# Usage:
#   bash scripts/release/owner-release.sh --tag v3.1.3 [--pr 166] [--retag]
#        [--publish] [--from STEP] [--dry-run] [--key FPR]
#
#   --tag TAG      the release tag (required)
#   --pr N         PR to merge into develop first (omit when develop is ready)
#   --retag        allow deleting an existing tag that points elsewhere
#   --publish      flip the draft to published at the end (default: leave draft)
#   --from STEP    resume at STEP (merge|ff-main|tag|ci|download|stage|release|verify|publish)
#   --dry-run      plan only; no git/artifact/release changes (append log only)
#   --key FPR      signing key fingerprint (default: the release key)
#   --part-size S  split size for the ISO parts, split(1) syntax (default 64m).
#                  Size the parts so one upload takes ~1–2 min at today's
#                  throughput: uploads.github.com resets streams that run
#                  ~5 min (release-process §10.1). v3.1.3 at ~0.9 MB/s: 190m
#                  parts took 3–5 min and the third one never got through.
#   --restage      discard the staged tree and every asset already on the
#                  draft, then stage, sign and upload again (use with a new
#                  --part-size; the sums and REASSEMBLE.txt change with it)
#   ORIONX_REPO_ROOT=<dir>  run against that checkout (e.g. from a worktree copy)
#
# Runs from the repository root on the Mac. Needs: gh (authenticated), git,
# shasum, gpg, xorriso, unsquashfs, python3, dpkg (for signed staging), and
# caffeinate (optional; keeps the Mac awake during uploads).

set -Eeuo pipefail   # -E: the ERR trap below also fires inside functions and $(...)

TAG=""; PR=""; RETAG=0; PUBLISH=0; FROM="merge"; DRY=0; PART_SIZE="64m"; RESTAGE=0
KEY="4CB08BD1D0B3281613DD15DB1DCCDF47FEEDEEEF"
REPO="jarocki/orion"
STEPS="merge ff-main tag ci download stage release verify publish"

usage() { sed -n '/^# Usage:/,/^# caffeinate/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
        --pr) PR="${2:?--pr needs a number}"; shift 2 ;;
        --retag) RETAG=1; shift ;;
        --publish) PUBLISH=1; shift ;;
        --from) FROM="${2:?--from needs a step}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --key) KEY="${2:?--key needs a fingerprint}"; shift 2 ;;
        --part-size) PART_SIZE="${2:?--part-size needs a size like 64m}"; shift 2 ;;
        --restage) RESTAGE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ -n "$TAG" ]] || { echo "--tag is required" >&2; usage >&2; exit 2; }
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$ ]] || { echo "tag must look like v3.1.3: $TAG" >&2; exit 2; }
case " $STEPS " in *" $FROM "*) ;; *) echo "--from must be one of: $STEPS" >&2; exit 2 ;; esac

# ORIONX_REPO_ROOT lets the script run from a worktree copy against the main
# checkout (the release PR carrying this script is itself the first thing it
# merges). Default: the repository this file lives in.
ROOT="${ORIONX_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT"
[[ -f scripts/release/stage-split-release.sh ]] || { echo "ERROR: not a repository root with scripts/release/: $ROOT" >&2; exit 1; }
mkdir -p tmp
LOG="tmp/owner-release-${TAG}.log"
exec > >(tee -a "$LOG") 2>&1

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
say() { printf '[%s] %s\n' "$(ts)" "$*"; }
resume_cmd() {  # the exact invocation that continues this run: same flags, same root
    local c="bash $0 --tag $TAG --from ${CURRENT_STEP:-$FROM}"
    [[ -n "$PR" ]] && c="$c --pr $PR"
    [[ $RETAG -eq 1 ]] && c="$c --retag"
    [[ $PUBLISH -eq 1 ]] && c="$c --publish"
    [[ "$KEY" == "4CB08BD1D0B3281613DD15DB1DCCDF47FEEDEEEF" ]] || c="$c --key $KEY"
    [[ "$PART_SIZE" == "64m" ]] || c="$c --part-size $PART_SIZE"
    # --restage only until staging has run: carried past it, every resume would
    # split again and clear the draft's assets. Dropped before it, a resume
    # would reuse the staging the owner asked to replace.
    case "${CURRENT_STEP:-$FROM}" in merge|ff-main|tag|ci|download|stage) [[ $RESTAGE -eq 0 ]] || c="$c --restage" ;; esac
    [[ -n "${ORIONX_REPO_ROOT:-}" ]] && c="ORIONX_REPO_ROOT=$ORIONX_REPO_ROOT $c"
    printf '%s' "$c"
}
die() {
    # Inside $(...) or ( ... ) only the subshell ends here; the enclosing
    # command then fails and its own `|| die`, or the ERR trap at top level,
    # reports. A message from the subshell would be a false "stopped" line
    # while the run goes on (the ci poll retries a failed `gh run list`).
    [[ ${BASH_SUBSHELL:-0} -eq 0 ]] || exit 1
    printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
    printf '[%s] stopped; resume with (one line): %s\n' "$(ts)" "$(resume_cmd)" >&2
    exit 1
}
# set -e must never end the run without a word in the log (it did once: a
# failed `have="$(...)"` assignment exited between two say lines; and without
# -E a `cat` of an unreadable marker inside check_source ended the run with
# nothing but cat's own message).
trap 'die "unexpected failure (exit $?) at line ${LINENO}: ${BASH_COMMAND}"' ERR
run() {  # run <description> <cmd...>: prints, honours --dry-run, fails loudly
    local what="$1"; shift
    say "$what"
    say "  \$ $*"
    if [[ $DRY -eq 1 ]]; then return 0; fi
    "$@" || die "$what failed (exit $?)"
}
retry() {  # retry <tries> <delay-seconds> <cmd...>  (for network calls)
    local tries="$1" delay="$2" n=1; shift 2
    until "$@"; do
        if [[ $n -ge $tries ]]; then return 1; fi
        say "  retry $n/$tries in ${delay}s: $*"
        sleep "$delay"; n=$((n + 1))
    done
}
step_due() {  # true once we have reached --from in the step order
    local s; local reached=0
    for s in $STEPS; do
        [[ "$s" == "$FROM" ]] && reached=1
        [[ "$s" == "$1" ]] && { [[ $reached -eq 1 ]]; return; }
    done
    return 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 ($2)"; }

# ---------------------------------------------------------------------------
say "=== owner-release ${TAG} (from: ${FROM}; dry-run: ${DRY}; publish: ${PUBLISH}) — log: ${LOG}"
need gh "brew install gh"; need git git; need shasum coreutils; need gpg "brew install gnupg"
need xorriso "brew install xorriso"; need unsquashfs "brew install squashfs"; need python3 python3; need dpkg "brew install dpkg"
command -v caffeinate >/dev/null 2>&1 && CAFF=caffeinate || CAFF=""
[[ $DRY -eq 1 ]] || gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
# Tracked changes block (they would ride along into main); untracked files are
# the owner's notes and scratch and are ignored.
DIRTY="$(git status --porcelain --untracked-files=no)"
[[ -z "$DIRTY" ]] || die "working tree has uncommitted tracked changes; commit or stash first:
$DIRTY"

CI_DIR="tmp/release-${TAG}-ci"; R="tmp/release-${TAG}"
ISO="${CI_DIR}/output/orionx-phoenix-edition-${TAG}.iso"

# --- merge ------------------------------------------------------------------
CURRENT_STEP=merge
if step_due merge && [[ -n "$PR" ]]; then
    say "--- merge PR #${PR} into develop"
    if [[ $DRY -eq 1 ]]; then
        say "  would check: base of #${PR} is develop (a stacked PR merges into its OWN base); checks green; then merge and wait for MERGED"
        base="develop"; state="OPEN"
    else
        base="$(gh pr view "$PR" --json baseRefName --jq .baseRefName)" || die "cannot read PR #${PR}"
        [[ "$base" == "develop" ]] || die "PR #${PR} targets '${base}', not develop — a stacked PR merges into its own base; wait until GitHub retargets it, or merge the stack as one PR"
        state="$(gh pr view "$PR" --json state --jq .state)"
    fi
    if [[ "$state" == "MERGED" ]]; then
        say "PR #${PR} already merged"
    else
        say "waiting for the checks on #${PR} (lint, e2e, QEMU; the QEMU gate takes ~35 min)"
        if [[ $DRY -eq 0 ]]; then
            retry 5 60 gh pr checks "$PR" --watch --fail-fast || die "a check on #${PR} failed or could not be read; fix it before releasing"
        fi
        run "merge #${PR}" gh pr merge "$PR" --merge
        if [[ $DRY -eq 0 ]]; then
            n=0; until [[ "$(gh pr view "$PR" --json state --jq .state 2>/dev/null)" == "MERGED" ]]; do
                n=$((n + 1)); [[ $n -le 20 ]] || die "PR #${PR} not MERGED after 5 min"
                sleep 15
            done
            say "PR #${PR} MERGED"
        fi
    fi
elif step_due merge; then
    say "--- merge: no --pr given; develop is taken as ready"
fi

# --- ff-main ----------------------------------------------------------------
CURRENT_STEP=ff-main
if step_due ff-main; then
    say "--- ff-main: main := origin/develop (fast-forward only)"
    run "fetch" git fetch --prune origin
    run "checkout main" git checkout -q main
    run "pull main" git pull -q --ff-only origin main
    run "fast-forward main to origin/develop" git merge -q --ff-only origin/develop
    if [[ $DRY -eq 0 ]]; then
        [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/develop)" ]] || die "main is not at origin/develop after the fast-forward"
        grep -q "^## \[${TAG}\]" CHANGELOG.md || die "CHANGELOG.md has no '## [${TAG}]' section at this commit — the release prep is not merged; the tag run would refuse to build (DEC-PHASE12-114)"
        grep -q "\"version\": \"${TAG#v}\"" manifest.json || die "manifest.json is not at ${TAG#v}; the release prep is not merged"
    fi
    run "push main" git push -q origin main
    say "main = $(git rev-parse --short HEAD) $(git log -1 --format=%s | cut -c1-70)"
fi

# --- tag --------------------------------------------------------------------
CURRENT_STEP=tag
if step_due tag; then
    say "--- tag ${TAG} on main"
    run "fetch tags" git fetch -q origin --tags
    head="$(git rev-parse HEAD)"
    if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
        at="$(git rev-parse "${TAG}^{commit}")"
        if [[ "$at" == "$head" ]]; then
            say "tag ${TAG} already points at HEAD"
        elif [[ $RETAG -eq 1 ]]; then
            say "tag ${TAG} points at ${at:0:7}, not HEAD ${head:0:7}; --retag given: deleting it (nothing was published from it — verify that yourself: gh release view ${TAG})"
            if [[ $DRY -eq 0 ]] && gh release view "$TAG" >/dev/null 2>&1; then die "a GitHub Release ${TAG} exists; refusing to move the tag under it. Delete the release first if that is really what you want (release-process §6)."; fi
            run "delete remote tag" git push -q origin ":refs/tags/${TAG}"
            run "delete local tag" git tag -d "$TAG"
        else
            die "tag ${TAG} already exists at ${at:0:7} (HEAD is ${head:0:7}). Re-run with --retag to move it, or release the next patch version."
        fi
    fi
    if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
        run "create annotated tag" git tag -a "$TAG" -m "Orion-X Phoenix Edition ${TAG}"
    fi
    run "push tag" git push -q origin "$TAG"
    [[ $DRY -eq 1 ]] || git ls-remote --tags origin "refs/tags/${TAG}" | grep -q . || die "tag ${TAG} is not on origin after the push"
fi

# --- ci ---------------------------------------------------------------------
CURRENT_STEP=ci
RUN_ID=""
TAG_SHA=""
# Resolve the remote tag without moving local refs, including annotated tags.
# Resumes must not silently use a stale local tag after someone retags origin.
resolve_tag_commit() {
    local refs remote local_sha
    refs="$(git ls-remote --tags origin "refs/tags/${TAG}" "refs/tags/${TAG}^{}")" || die "cannot read remote tag ${TAG}"
    remote="$(printf '%s\n' "$refs" | awk '$2 ~ /\^\{\}$/ { peeled=$1 } $2 !~ /\^\{\}$/ { plain=$1 } END { print (peeled != "" ? peeled : plain) }')"
    [[ "$remote" =~ ^[0-9a-f]{40}$ ]] || die "remote tag ${TAG} has no valid commit identity"
    local_sha="$(git rev-parse --verify "refs/tags/${TAG}^{commit}")" || die "cannot resolve local tag ${TAG}"
    [[ "$local_sha" == "$remote" ]] || die "local tag ${TAG} differs from origin; refresh and inspect it before resuming"
    TAG_SHA="$remote"
}
assert_tag_unchanged() {
    local expected="$TAG_SHA"
    resolve_tag_commit
    [[ "$TAG_SHA" == "$expected" ]] || die "tag ${TAG} changed during this release; stop and inspect before resuming"
}
# The run must be for THIS tag object's commit, not merely for a run whose
# branch is named after the tag: after a --retag the previous tag's run still
# carries headBranch==TAG, and two seconds after the push the new run does
# not exist yet. Matching on the branch alone picked the old, failed run
# (the second v3.1.3 attempt, 05:07Z).
find_tag_run() {  # prints the run id for the local tag's commit, or nothing
    local sha
    sha="$(git rev-list -n 1 "$TAG" 2>/dev/null)" || return 1
    [[ "$sha" == "$TAG_SHA" ]] || return 1
    gh run list --workflow release.yml --commit "$sha" --limit 10 --json databaseId,headBranch,headSha,event \
        --jq ".[] | select(.headBranch==\"${TAG}\" and .headSha==\"${sha}\" and .event==\"push\") | .databaseId" | head -1
}
verify_run() {
    local identity
    [[ "$RUN_ID" =~ ^[0-9]+$ ]] || die "invalid release run ID"
    identity="$(gh run view "$RUN_ID" --json headSha,headBranch,event,status,conclusion --jq '[.headSha,.headBranch,.event,.status,.conclusion] | join(" ")')" || die "cannot verify release run ${RUN_ID}"
    [[ "$identity" == "$TAG_SHA $TAG push completed success" ]] || die "release run ${RUN_ID} is not a successful push of ${TAG} at ${TAG_SHA}"
}
# A marker binds a locally managed cache to the selected run, commit and ISO.
# Old tag-only caches are deliberately not adopted or deleted automatically.
check_source() {  # check_source <dir> <what it holds> <step that creates it>
    local dir="$1" what="$2" from="$3" source sha run hash extra
    [[ -e "$dir" || -L "$dir" ]] || die "no ${what} cache at ${dir}; every later step needs it present: resume with --from ${from}"
    [[ -d "$dir" && ! -L "$dir" ]] || die "unsafe cache directory ${dir} (a symlink, or not a directory); move it aside and resume with --from ${from}"
    [[ -f "$dir/.owner-release-source" && ! -L "$dir/.owner-release-source" ]] || die "unproven cache in ${dir} (no .owner-release-source marker; releases before v3.1.4 wrote none); move it aside and resume with --from ${from}"
    source="$(cat "$dir/.owner-release-source")" || die "cannot read ${dir}/.owner-release-source"
    read -r sha run hash extra <<< "$source"
    [[ "$sha" == "$TAG_SHA" && "$run" == "$RUN_ID" && "$hash" =~ ^[0-9a-f]{64}$ && -z "$extra" && "$source" == "$sha $run $hash" ]] || die "stale or invalid cache provenance in ${dir} (want '${TAG_SHA} ${RUN_ID} <iso sha256>', have '${source}'); move it aside and resume with --from ${from}"
    SOURCE_HASH="$hash"
}
if [[ $DRY -eq 0 ]]; then resolve_tag_commit; fi
if step_due ci; then
    say "--- ci: wait for the ${TAG} tag run (build ~18 min + gates; it ends at the hand-off step by design)"
    if [[ $DRY -eq 0 ]]; then
        say "looking for the release.yml push run of ${TAG} at ${TAG_SHA}"
        n=0; until RUN_ID="$(find_tag_run)" && [[ -n "$RUN_ID" ]]; do
            n=$((n + 1)); [[ $n -le 20 ]] || die "no release.yml run for ${TAG} at ${TAG_SHA} appeared within 10 min"
            say "  no run for ${TAG_SHA} yet (${n}/20); checking again in 30s"
            sleep 30
        done
        say "tag run: ${RUN_ID}  https://github.com/${REPO}/actions/runs/${RUN_ID}"
        # gh run watch can die on an API hiccup; loop on the run's state, not on watch's exit.
        while :; do
            gh run watch "$RUN_ID" --exit-status >/dev/null 2>&1 && break
            st="$(gh run view "$RUN_ID" --json status,conclusion --jq '"\(.status) \(.conclusion // "")"' 2>/dev/null || echo "unknown")"
            case "$st" in
                "completed success") break ;;
                "completed "*) die "tag run ${RUN_ID} ended '${st}'. Read it: gh run view ${RUN_ID} --log-failed" ;;
                *) say "  watch interrupted (${st}); retrying in 30s"; sleep 30 ;;
            esac
        done
        verify_run
        say "tag run ${RUN_ID} green (built, gated, handed off)"
    else
        say "  \$ gh run list --workflow release.yml ...; gh run watch <id> --exit-status"
    fi
fi

# --- download ---------------------------------------------------------------
CURRENT_STEP=download
if step_due download; then
    say "--- download: the CI-built ISO and its sidecar"
    if [[ $DRY -eq 0 ]]; then
        [[ -n "$RUN_ID" ]] || RUN_ID="$(find_tag_run || true)"
        [[ -n "$RUN_ID" ]] || die "cannot find the ${TAG} tag run to download from"
        verify_run
        if [[ -e "$CI_DIR" || -L "$CI_DIR" ]]; then
            check_source "$CI_DIR" "downloaded ISO" download
            [[ -f "$ISO" ]] || die "incomplete cache in ${CI_DIR}; preserve/move it aside before downloading"
            [[ "$(shasum -a 256 "$ISO" | awk '{print $1}')" == "$SOURCE_HASH" ]] || die "cached ISO differs from its recorded source hash"
            say "ISO already present with matching provenance: ${ISO}"
        else
            run "download artifact release-artifacts-${RUN_ID}" retry 3 30 gh run download "$RUN_ID" -n "release-artifacts-${RUN_ID}" -D "$CI_DIR"
        fi
        [[ -f "$ISO" ]] || die "ISO not found at ${ISO} after download"
        (cd "${CI_DIR}/output" && shasum -a 256 -c "orionx-phoenix-edition-${TAG}.iso.sha256") || die "ISO does not match its sidecar"
        SOURCE_HASH="$(shasum -a 256 "$ISO" | awk '{print $1}')"
        [[ "$SOURCE_HASH" =~ ^[0-9a-f]{64}$ ]] || die "cannot hash downloaded ISO"
        printf '%s %s %s\n' "$TAG_SHA" "$RUN_ID" "$SOURCE_HASH" > "$CI_DIR/.owner-release-source"
        say "ISO verified: ${SOURCE_HASH:0:16}…  $(stat -f %z "$ISO" 2>/dev/null || stat -c %s "$ISO") bytes"
    else
        say "  would download the successful run for the current tag commit; existing artifacts are preserved"
    fi
fi

# Every resumed signing/upload/verification/publication checks the same source.
if [[ $DRY -eq 0 ]]; then
    assert_tag_unchanged
    [[ -n "$RUN_ID" ]] || RUN_ID="$(find_tag_run || true)"
    [[ -n "$RUN_ID" ]] || die "no successful release.yml run for ${TAG} at ${TAG_SHA:0:7} is visible; resume with --from ci"
    verify_run
    check_source "$CI_DIR" "downloaded ISO" download
fi
check_staged_source() {
    local iso_hash="$SOURCE_HASH"
    check_source "$R" staging stage
    [[ "$SOURCE_HASH" == "$iso_hash" ]] || die "staging and downloaded ISO have different provenance"
    [[ "$(awk -v name="orionx-phoenix-edition-${TAG}.iso" '$2 == name {print $1}' "$R/SHA256SUMS")" == "$SOURCE_HASH" ]] || die "staged checksum does not match the recorded source ISO"
}

# --- stage ------------------------------------------------------------------
CURRENT_STEP=stage
if step_due stage; then
    say "--- stage: split, checksum, sign (gpg will ask for the passphrase)"
    if [[ $DRY -eq 0 ]]; then
        [[ "$(git describe --tags --exact-match 2>/dev/null || true)" == "$TAG" ]] || die "checkout is not at ${TAG} (staging reads CHANGELOG.md from the checkout): git checkout ${TAG}"
        [[ "$(shasum -a 256 "$ISO" | awk '{print $1}')" == "$SOURCE_HASH" ]] || die "ISO changed since download"
        if [[ -e "$R" || -L "$R" ]]; then
            # Explicit restaging may replace only a cache proven to belong to
            # this source. Never discard a stale, partial or symlink cache.
            check_staged_source
            if [[ $RESTAGE -eq 1 ]]; then
                say "--restage: discarding verified staging ${R}"
                rm -rf "$R"
            else
                say "staging already present in ${R}; re-verifying its source and signature (use --restage to split again)"
            fi
        fi
        if [[ ! -e "$R" ]]; then
            run "stage-split-release (${PART_SIZE} parts)" bash scripts/release/stage-split-release.sh "$ISO" "$TAG" --out "$R" --key "$KEY" --part-size "$PART_SIZE"
            cp "$CI_DIR/.owner-release-source" "$R/.owner-release-source"
        fi
        for f in SHA256SUMS SHA256SUMS.asc SHA512SUMS SHA512SUMS.asc REASSEMBLE.txt RELEASE-NOTES.md; do
            [[ -s "$R/$f" ]] || die "staging produced no ${f}"
        done
        gpg --verify "$R/SHA256SUMS.asc" "$R/SHA256SUMS" >/dev/null 2>&1 || die "SHA256SUMS.asc does not verify"
        say "staged: $(find "$R" -name '*.iso.part-*' | wc -l | tr -d ' ') parts + 6 files in ${R}"
    else
        say "  \$ bash scripts/release/stage-split-release.sh ${ISO} ${TAG} --out ${R} --key ${KEY} --part-size ${PART_SIZE}"
    fi
fi

if [[ $DRY -eq 0 ]]; then
    assert_tag_unchanged
    check_staged_source
fi

# --- release ----------------------------------------------------------------
CURRENT_STEP=release
# A DRAFT release is not reachable through the REST get-release-by-tag path
# (404 until published); the first v3.1.3 upload attempt died silently on
# that 404 under set -e. The draft's numeric id comes from the releases list
# (which includes drafts), and the assets are read from the REST assets
# endpoint of that id, because it is the only view that shows the hidden
# `starter` asset a reset upload leaves behind (release-process §10.1);
# `gh release view` hides it and then every retry of that name fails.
# Every $(...) assignment is guarded so a failed lookup is a retry, never an
# exit.
RELEASE_ID=""
release_id() {
    [[ -n "$RELEASE_ID" ]] || RELEASE_ID="$(gh api "repos/${REPO}/releases?per_page=100" --jq ".[] | select(.tag_name==\"${TAG}\") | .id" 2>/dev/null | head -1 || true)"
    printf '%s' "$RELEASE_ID"
}
rest_assets() {  # <jq>: every asset of the draft, starters included
    local id; release_id >/dev/null; id="$RELEASE_ID"   # not $(release_id): a subshell cannot fill the cache, so every call would re-fetch
    [[ -n "$id" ]] || return 0
    gh api --paginate "repos/${REPO}/releases/${id}/assets?per_page=100" --jq "$1" 2>/dev/null || true
}
asset_state()  { rest_assets ".[] | select(.name==\"$1\") | \"\(.size) \(.state) \(.id)\"" | head -1; }
local_size()   { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
delete_asset() {  # <id> <why>
    say "  deleting asset $1 ($2)"
    retry 3 10 gh api -X DELETE "repos/${REPO}/releases/assets/$1" >/dev/null 2>&1 || say "  delete of asset $1 returned non-zero; continuing"
    sleep 3
}
if step_due release; then
    say "--- release: draft + uploads (one file per command, verified by size and state, retried)"
    if [[ $DRY -eq 0 ]]; then
        if gh release view "$TAG" >/dev/null 2>&1; then
            say "release ${TAG} exists (id $(release_id)); reusing it"
            if [[ $RESTAGE -eq 1 ]]; then
                is_draft="$(gh release view "$TAG" --json isDraft --jq '.isDraft' 2>/dev/null || true)"
                [[ "$is_draft" == "true" ]] || die "--restage refuses to delete assets unless ${TAG} is confirmed to be a draft"
                say "--restage: removing every asset already on the draft (the sums and parts changed)"
                while read -r aid aname; do [[ -n "$aid" ]] && delete_asset "$aid" "$aname, restage"; done < <(rest_assets '.[] | "\(.id) \(.name)"')
            fi
        else
            run "create DRAFT release" gh release create "$TAG" --draft --title "Orion-X Phoenix Edition ${TAG}" --notes-file "$R/RELEASE-NOTES.md"
            sleep 10
        fi
        # Small, signed files first, so a reader of the draft can verify parts as they land.
        UPLOAD_ERR="tmp/owner-release-${TAG}-upload.err"; : > "$UPLOAD_ERR"
        for p in "$R/SHA256SUMS" "$R/SHA256SUMS.asc" "$R/SHA512SUMS" "$R/SHA512SUMS.asc" "$R/REASSEMBLE.txt" "$R"/orionx-phoenix-edition-"${TAG}".iso.part-*; do
            name="$(basename "$p")"; want="$(local_size "$p")"
            tries=0
            while :; do
                read -r have state aid <<< "$(asset_state "$name")" || true
                if [[ "${have:-}" == "$want" && "${state:-}" == "uploaded" ]]; then say "  ok  ${name} (${want} bytes)"; break; fi
                tries=$((tries + 1)); [[ $tries -le 4 ]] || die "upload of ${name} failed 4 times (on GitHub: ${have:-none} ${state:-}; local: ${want}). Last error: $(tail -1 "$UPLOAD_ERR" 2>/dev/null)"
                if [[ -n "${aid:-}" ]]; then delete_asset "$aid" "${name}: ${have} bytes, state ${state}; must be ${want} uploaded"; fi
                say "  upload ${name} (try ${tries}, $((want / 1048576)) MiB)"
                t0=$(date +%s)
                if ${CAFF:+$CAFF -i} gh release upload "$TAG" --clobber "$p" >/dev/null 2>"$UPLOAD_ERR"; then
                    say "  uploaded in $(( $(date +%s) - t0 ))s; confirming through the API"
                else
                    say "  upload returned non-zero after $(( $(date +%s) - t0 ))s: $(tail -1 "$UPLOAD_ERR" | cut -c1-160)"
                fi
                sleep 5
            done
        done
    else
        say "  \$ gh release create ${TAG} --draft ...; for p in ${R}/*; do gh release upload ${TAG} --clobber \"\$p\"; done   # ${PART_SIZE} parts"
    fi
fi

# --- verify -----------------------------------------------------------------
CURRENT_STEP=verify
if step_due verify && [[ $DRY -eq 0 ]]; then
    say "--- verify: asset set, sizes, fresh signature check"
    expected=$(( $(find "$R" -name '*.iso.part-*' | wc -l | tr -d ' ') + 5 ))
    release_id >/dev/null
    [[ -n "$RELEASE_ID" ]] || die "no release for ${TAG} is visible through the API (draft or published); check gh auth status, then resume with --from release"
    API_ERR="tmp/owner-release-${TAG}-api.err"
    assets="$(gh api --paginate "repos/${REPO}/releases/${RELEASE_ID}/assets?per_page=100" --jq '.[] | [.name, .size, .state] | @tsv' 2>"$API_ERR")" \
        || die "the GitHub API failed listing the assets of release ${RELEASE_ID} (not a count mismatch): $(tail -1 "$API_ERR" 2>/dev/null)"
    count="$(printf '%s\n' "$assets" | grep -c . || true)"   # one line per asset; '.id' on the array yielded nothing (the first v3.1.3 verify read 0 of 21)
    [[ "$count" == "$expected" ]] || die "release has ${count} assets (starters included), expected ${expected}"
    bad=0
    while IFS=$'\t' read -r name size state; do
        [[ "$state" == "uploaded" ]] || { say "  ${name}: state ${state}"; bad=1; }
        [[ -f "$R/$name" ]] && [[ "$(local_size "$R/$name")" == "$size" ]] || { say "  ${name}: size mismatch or no local file"; bad=1; }
    done < <(printf '%s\n' "$assets")
    [[ $bad -eq 0 ]] || die "asset verification failed"
    V="tmp/release-${TAG}-verify"; rm -rf "$V"; mkdir -p "$V"
    retry 3 20 gh release download "$TAG" -D "$V" -p 'SHA256SUMS' -p 'SHA256SUMS.asc' >/dev/null 2>&1 || die "could not download SHA256SUMS(.asc) for verification"
    gpg --verify "$V/SHA256SUMS.asc" "$V/SHA256SUMS" >/dev/null 2>&1 || die "downloaded SHA256SUMS.asc does not verify"
    cmp -s "$V/SHA256SUMS" "$R/SHA256SUMS" || die "downloaded SHA256SUMS differs from the staged one"
    say "verified: ${count} assets uploaded, sizes match, signature good"
elif step_due verify; then
    say "--- verify: (dry-run) asset count/sizes via the API, fresh SHA256SUMS(.asc) + gpg --verify"
fi

# --- publish ----------------------------------------------------------------
CURRENT_STEP=publish
if step_due publish; then
    if [[ $PUBLISH -eq 1 ]]; then
        [[ $DRY -eq 1 ]] || assert_tag_unchanged
        run "flip DRAFT -> published" gh release edit "$TAG" --draft=false
        [[ $DRY -eq 1 ]] || [[ "$(gh release view "$TAG" --json isDraft --jq .isDraft)" == "false" ]] || die "release is still a draft"
        say "PUBLISHED: https://github.com/${REPO}/releases/tag/${TAG}"
    else
        say "--- publish: left as DRAFT (re-run with --from publish --publish to flip): https://github.com/${REPO}/releases/tag/${TAG}"
    fi
fi
say "=== done (${TAG}); log: ${LOG}"
