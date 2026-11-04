#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_owner_release.sh — the owner's release script (DEC-PHASE13-038)
#
# The script is EXECUTED in --dry-run against stub gh/git so its argument
# handling, step gating and plan output run for real without touching GitHub.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
S="$REPO_ROOT/scripts/release/owner-release.sh"
# Never allow a failed allocation to turn fixture paths into /bin or /repo.
TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)" || exit 1
WORK="$(mktemp -d "$TEMP_PARENT/ownerrel.XXXXXX")" || exit 1
[[ -n "$WORK" && -d "$WORK" && ! -L "$WORK" ]] || exit 1
case "$WORK" in "$TEMP_PARENT"/ownerrel.*) ;; *) exit 1 ;; esac
trap 'rm -rf -- "$WORK"' EXIT

echo "[structure]"
[[ -x "$S" ]] && pass "owner-release.sh present + executable" || fail "present+exec"
bash -n "$S" && pass "parses (bash -n)" || fail "bash -n"
if command -v shellcheck >/dev/null 2>&1; then shellcheck "$S" >/dev/null 2>&1 && pass "shellcheck clean" || fail "shellcheck" "$(shellcheck "$S" 2>&1 | tail -4)"; fi
grep -q '@decision DEC-PHASE13-038' "$S" && pass "carries DEC-PHASE13-038" || fail "decision"
for must in 'gh pr checks "$PR" --watch --fail-fast' 'merge -q --ff-only origin/develop' 'git tag -a "$TAG"' 'gh run watch "$RUN_ID" --exit-status' 'shasum -a 256 -c' 'stage-split-release.sh' 'gh release create "$TAG" --draft' '--clobber' 'gpg --verify' 'gh release edit "$TAG" --draft=false'; do
    grep -qF -- "$must" "$S" && pass "step present: $must" || fail "step missing" "$must"
done
grep -q 'targets .* not develop' "$S" && pass "refuses to merge a PR whose base is not develop (the v3.1.3 mishap)" || fail "base check"
grep -q "has no '## \[\${TAG}\]' section" "$S" && pass "refuses to tag when the CHANGELOG section is missing (DEC-PHASE12-114 would fail the tag run)" || fail "changelog check"
grep -q 'refusing to move the tag under it' "$S" && pass "never moves a tag that has a GitHub Release" || fail "release-under-tag guard"
grep -qE 'mapfile|\$\{[a-z_]+,,\}|declare -A' "$S" && fail "bash-4-only construct (the Mac runs bash 3.2)" || pass "bash 3.2 compatible (no mapfile / \${var,,} / declare -A)"
grep -q 'git status --porcelain --untracked-files=no' "$S" && pass "clean-tree guard ignores untracked files (the owner's notes blocked the first v3.1.3 run)" || fail "untracked guard"
grep -q 'releases/tags/' "$S" && fail "REST releases/tags/<tag> lookup present (404 for a DRAFT release; the first v3.1.3 upload died on it)" || pass "no releases/tags/<tag> REST lookup; drafts are read via gh release view"
grep -q "trap 'die .*' ERR" "$S" && pass "ERR trap: set -e can never end the run silently" || fail "ERR trap missing"
grep -q 'headSha==\\"\${sha}\\"' "$S" && grep -q 'git rev-list -n 1 "\$TAG"' "$S" && pass "ci step selects the run by the tag's commit, not by branch name (a re-tag leaves the old run named after the tag)" || fail "ci run selection by headSha"
for flag in '--pr $PR' '--retag' '--publish' 'ORIONX_REPO_ROOT=$ORIONX_REPO_ROOT'; do
    grep -qF -- "$flag" "$S" && grep -q 'resume_cmd' "$S" && pass "resume hint carries: $flag" || fail "resume hint lacks" "$flag"
done

echo "[arguments]"
bash "$S" --help >/dev/null 2>&1 && pass "--help exits 0" || fail "--help"
bash "$S" >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "no --tag -> usage, exit 2" || fail "no tag exit"
bash "$S" --tag 3.1.3 >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "malformed tag refused" || fail "tag format"
bash "$S" --tag v9.9.9 --from nowhere >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "unknown --from refused" || fail "from check"
bash "$S" --tag v9.9.9 --wat >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "unknown option refused" || fail "unknown option"

echo "[dry-run against stubs]"
mkdir -p "$WORK/bin" "$WORK/repo/scripts/release" "$WORK/repo/tmp"
cp "$S" "$WORK/repo/scripts/release/owner-release.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/repo/scripts/release/stage-split-release.sh"   # the root check looks for it
for t in gh git shasum gpg xorriso unsquashfs python3 dpkg caffeinate; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "${STUB_CALLS:?}"\n[ "%s" = git ] && [ "$1" = status ] && exit 0\n[ "%s" = git ] && [ "$1" = rev-parse ] && { echo deadbeef; exit 0; }\nexit 0\n' "$t" "$t" "$t" > "$WORK/bin/$t"
done
chmod +x "$WORK/bin/"*
: > "$WORK/calls"
# Allocation-failure injection runs only after checking the fail-closed guard.
# The child exits before any fixture setup; it never runs the vulnerable baseline.
if grep -qF 'WORK="$(mktemp -d "$TEMP_PARENT/ownerrel.XXXXXX")" || exit 1' "${BASH_SOURCE[0]}"; then
    mkdir -p "$WORK/fail-bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/fail-bin/mktemp"
    chmod +x "$WORK/fail-bin/mktemp"
    PATH="$WORK/fail-bin:/usr/bin:/bin" TMPDIR="$WORK" bash "${BASH_SOURCE[0]}" > "$WORK/allocation.out" 2>&1
    rc=$?
    [[ $rc -ne 0 && ! -s "$WORK/allocation.out" ]] && pass "failed mktemp aborts before fixture setup" || fail "allocation failure guard" "rc=$rc"
else
    fail "allocation failure guard missing; unsafe injection NOT executed"
fi
mkdir -p "$WORK/repo/tmp/release-v9.9.9-ci/output"
printf 'keep recovery data\n' > "$WORK/repo/tmp/release-v9.9.9-ci/output/recovery.log"
out="$(cd "$WORK/repo" && ORIONX_REPO_ROOT="$WORK/repo" STUB_CALLS="$WORK/calls" PATH="$WORK/bin:/usr/bin:/bin" bash scripts/release/owner-release.sh --tag v9.9.9 --pr 42 --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "--dry-run completes (exit 0)" || fail "--dry-run rc" "rc=$rc $(echo "$out" | tail -3)"
for step in "merge PR #42" "ff-main" "tag v9.9.9" "ci: wait" "download" "stage" "release" "verify" "publish"; do
    echo "$out" | grep -q -- "$step" && pass "dry-run plans: $step" || fail "dry-run plan lacks: $step"
done
if grep -qE '^gh (pr merge|release|run download|api -X DELETE)' "$WORK/calls"; then fail "dry-run changed state" "$(grep -E '^gh' "$WORK/calls" | head -3)"; else pass "dry-run issues no merging, downloading, releasing or deleting gh commands"; fi
if grep -qE '^git (fetch|pull|push|tag -a|tag -d|merge|checkout)' "$WORK/calls"; then fail "dry-run ran a state-changing git command" "$(grep -E '^git' "$WORK/calls" | head -3)"; else pass "dry-run runs no state-changing git command (including fetch)"; fi
[[ "$(cat "$WORK/repo/tmp/release-v9.9.9-ci/output/recovery.log" 2>/dev/null)" == 'keep recovery data' ]] && pass "dry-run preserves partial artifact recovery data" || fail "dry-run deleted recovery data"
echo "$out" | grep -q 'left as DRAFT' && pass "without --publish the release stays a draft" || fail "draft default" "$out"
out2="$(cd "$WORK/repo" && ORIONX_REPO_ROOT="$WORK/repo" STUB_CALLS="$WORK/calls" PATH="$WORK/bin:/usr/bin:/bin" bash scripts/release/owner-release.sh --tag v9.9.9 --dry-run --from stage 2>&1)"
echo "$out2" | grep -q -- "--- stage" && ! echo "$out2" | grep -q -- "--- ff-main" && pass "--from stage skips the earlier steps" || fail "--from gating" "$out2"
ls "$WORK/repo/tmp"/owner-release-v9.9.9.log >/dev/null 2>&1 && pass "every run is logged to tmp/owner-release-<tag>.log" || fail "log file"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
