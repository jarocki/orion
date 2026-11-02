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
WORK="$(mktemp -d "${TMPDIR:-$REPO_ROOT/tmp}/ownerrel.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

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
out="$(cd "$WORK/repo" && STUB_CALLS="$WORK/calls" PATH="$WORK/bin:/usr/bin:/bin" bash scripts/release/owner-release.sh --tag v9.9.9 --pr 42 --dry-run 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "--dry-run completes (exit 0)" || fail "--dry-run rc" "rc=$rc $(echo "$out" | tail -3)"
for step in "merge PR #42" "ff-main" "tag v9.9.9" "ci: wait" "download" "stage" "release" "verify" "publish"; do
    echo "$out" | grep -q -- "$step" && pass "dry-run plans: $step" || fail "dry-run plan lacks: $step"
done
if grep -qE '^gh (pr merge|release|run download|api -X DELETE)' "$WORK/calls"; then fail "dry-run changed state" "$(grep -E '^gh' "$WORK/calls" | head -3)"; else pass "dry-run issues no merging, downloading, releasing or deleting gh commands"; fi
if grep -qE '^git (push|tag -a|tag -d|merge|checkout)' "$WORK/calls"; then fail "dry-run ran a state-changing git command" "$(grep -E '^git' "$WORK/calls" | head -3)"; else pass "dry-run runs no state-changing git command"; fi
echo "$out" | grep -q 'left as DRAFT' && pass "without --publish the release stays a draft" || fail "draft default" "$out"
out2="$(cd "$WORK/repo" && STUB_CALLS="$WORK/calls" PATH="$WORK/bin:/usr/bin:/bin" bash scripts/release/owner-release.sh --tag v9.9.9 --dry-run --from stage 2>&1)"
echo "$out2" | grep -q -- "--- stage" && ! echo "$out2" | grep -q -- "--- ff-main" && pass "--from stage skips the earlier steps" || fail "--from gating" "$out2"
ls "$WORK/repo/tmp"/owner-release-v9.9.9.log >/dev/null 2>&1 && pass "every run is logged to tmp/owner-release-<tag>.log" || fail "log file"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
