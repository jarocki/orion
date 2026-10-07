#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_release_tooling.sh — scripts/release/* behaviour (DEC-PHASE12-114/115)
#
# Behavioural: runs the real scripts on a small random "ISO" in scratch, with a
# throwaway GnuPG home and key, and checks what they produce. Nothing here
# touches output/, the network, or the operator's keyring.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

ERN="$REPO_ROOT/scripts/release/extract-release-notes.sh"
STAGE="$REPO_ROOT/scripts/release/stage-split-release.sh"
S="$REPO_ROOT/tmp/trt_$$"; mkdir -p "$S"
cleanup() { gpgconf --homedir "$S/g" --kill all >/dev/null 2>&1 || true; rm -rf "$S"; }
trap cleanup EXIT

section "extract-release-notes.sh: missing or empty is an error (F-20, F-32)"
cat > "$S/CHANGELOG.md" <<'EOF'
# Changelog

## [v9.1.0] — 2026-01-01

- shipped thing

## Open Issues Carried Forward

- not part of v9.1.0

## [v9.0.0]

## [v8.0.0]

- old
EOF
OUT="$(CHANGELOG_PATH="$S/CHANGELOG.md" bash "$ERN" v9.1.0 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == "- shipped thing" ]] && pass "section extracted, ends at the next '## ' heading" || fail "extract v9.1.0" "rc=$RC out=$OUT"
CHANGELOG_PATH="$S/CHANGELOG.md" bash "$ERN" 9.1.0 >/dev/null 2>&1 && pass "bare version (no v) still works" || fail "bare version" "rc!=0"
OUT="$(CHANGELOG_PATH="$S/CHANGELOG.md" bash "$ERN" v3.0.0 2>&1)"; RC=$?
[[ $RC -ne 0 && "$OUT" == *"no '## [v3.0.0]' section"* ]] && pass "missing section exits non-zero and says so" || fail "missing section" "rc=$RC out=$OUT"
OUT="$(CHANGELOG_PATH="$S/CHANGELOG.md" bash "$ERN" v9.0.0 2>/dev/null)"; RC=$?
[[ $RC -ne 0 && -z "$OUT" ]] && pass "empty section exits non-zero with no stdout" || fail "empty section" "rc=$RC out=$OUT"
CHANGELOG_PATH="$S/nope.md" bash "$ERN" v9.1.0 >/dev/null 2>&1 && fail "missing CHANGELOG" "exit 0" || pass "missing CHANGELOG.md exits non-zero"

section "stage-split-release.sh: parts, sums, signature, instructions (P1-1, F-10, F-18)"
# A tag that has a CHANGELOG section in this repository.
TAG="v2.2.0-rc9"
NAME="orionx-phoenix-edition-$TAG.iso"
head -c 2621440 /dev/urandom > "$S/build.iso"   # 2.5 MiB
(cd "$S" && sha256 build.iso > build.iso.sha256)
export GNUPGHOME="$S/g"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
if gpg --batch --passphrase '' --quick-gen-key "Release Test <release-test@example.invalid>" ed25519 sign never >/dev/null 2>&1; then
    FPR="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ {print $10; exit}')"
    OUT="$(bash "$STAGE" "$S/build.iso" "$TAG" --out "$S/rel" --part-size 1m --key "$FPR" 2>&1)"; RC=$?
    [[ $RC -eq 0 ]] && pass "signed staging succeeds" || fail "staging" "rc=$RC $OUT"
    NP="$(find "$S/rel" -name "$NAME.part-*" | wc -l | tr -d ' ')"
    [[ "$NP" == "3" ]] && pass "2.5 MiB at 1m -> 3 parts" || fail "part count" "$NP"
    BIG="$(find "$S/rel" -name "$NAME.part-*" -size +1024k | wc -l | tr -d ' ')"
    [[ "$BIG" == "0" ]] && pass "no part exceeds the part size" || fail "part size" "$BIG oversize"
    WANT="$(awk '{print $1}' "$S/build.iso.sha256")"
    GOT="$(cat "$S/rel/$NAME".part-* | sha256 | awk '{print $1}')"
    [[ "$GOT" == "$WANT" ]] && pass "cat part-* reproduces the ISO byte for byte" || fail "reassembly" "$GOT != $WANT"
    head -1 "$S/rel/SHA256SUMS" | grep -qx "$WANT  $NAME" && pass "SHA256SUMS line 1 is the whole ISO under its published name" || fail "SHA256SUMS ISO line" "$(head -1 "$S/rel/SHA256SUMS")"
    [[ "$(grep -c '\.part-' "$S/rel/SHA256SUMS")" == "3" ]] && pass "SHA256SUMS lists every part" || fail "SHA256SUMS parts" "count"
    cp "$S/build.iso" "$S/rel/$NAME"
    (cd "$S/rel" && { command -v sha256sum >/dev/null && sha256sum -c --quiet SHA256SUMS || shasum -a 256 -c --quiet SHA256SUMS; }) \
        && pass "the documented 'sha256sum -c SHA256SUMS' passes on a reassembled download" || fail "sha256sum -c" "failed"
    rm -f "$S/rel/$NAME"
    gpg --batch --verify "$S/rel/SHA256SUMS.asc" "$S/rel/SHA256SUMS" >/dev/null 2>&1 && pass "SHA256SUMS.asc verifies" || fail "signature" "SHA256SUMS.asc"
    gpg --batch --verify "$S/rel/SHA512SUMS.asc" "$S/rel/SHA512SUMS" >/dev/null 2>&1 && pass "SHA512SUMS.asc verifies" || fail "signature" "SHA512SUMS.asc"
    grep -q "$WANT" "$S/rel/REASSEMBLE.txt" && grep -q "cat $NAME.part-\* > $NAME" "$S/rel/REASSEMBLE.txt" && grep -q "gpg --verify SHA256SUMS.asc SHA256SUMS" "$S/rel/REASSEMBLE.txt" \
        && pass "REASSEMBLE.txt carries the hash, the cat recipe and the gpg --verify step" || fail "REASSEMBLE.txt" "content"
    grep -q "copy /b $NAME.part-aa + $NAME.part-ab + $NAME.part-ac $NAME" "$S/rel/REASSEMBLE.txt" && pass "Windows copy /b lists the parts in order" || fail "copy /b" "content"
    grep -q '^## Download and verify' "$S/rel/RELEASE-NOTES.md" && grep -q "$WANT" "$S/rel/RELEASE-NOTES.md" \
        && pass "RELEASE-NOTES.md = CHANGELOG section + download/verify instructions" || fail "RELEASE-NOTES.md" "content"
    grep -q "Not yet booted on the deck\|release candidate" "$S/rel/RELEASE-NOTES.md" && pass "release notes body comes from the CHANGELOG section" || fail "notes body" "CHANGELOG text absent"
    OUT="$(bash "$STAGE" "$S/build.iso" "$TAG" --out "$S/rel" --part-size 1m --key "$FPR" 2>&1)" \
        && fail "non-empty --out" "accepted" || pass "refuses to mix with an existing asset set"
else
    fail "gpg throwaway key" "could not generate a test key (gpg missing?)"
fi

section "stage-split-release.sh: refusals"
bash "$STAGE" "$S/build.iso" v3.0.0 --out "$S/r2" --part-size 1m --unsigned >/dev/null 2>&1 \
    && fail "tag without CHANGELOG section" "staged" || pass "a tag with no CHANGELOG section is refused"
cp "$S/build.iso" "$S/bad.iso"; echo "0000000000000000000000000000000000000000000000000000000000000000  bad.iso" > "$S/bad.iso.sha256"
bash "$STAGE" "$S/bad.iso" "$TAG" --out "$S/r3" --part-size 1m --unsigned >/dev/null 2>&1 \
    && fail "sidecar mismatch" "staged" || pass "an ISO that fails its .sha256 sidecar is refused"
OUT="$(bash "$STAGE" "$S/build.iso" "$TAG" --out "$S/r4" --part-size 1m --unsigned 2>&1)"; RC=$?
[[ $RC -eq 0 && "$OUT" == *"NOT publishable"* && ! -e "$S/r4/SHA256SUMS.asc" ]] && pass "--unsigned works for dry runs and says it is not publishable" || fail "--unsigned" "rc=$RC"
GNUPGHOME="$S/empty-g" bash "$STAGE" "$S/build.iso" "$TAG" --out "$S/r5" --part-size 1m --key 0000000000000000000000000000000000000000 >/dev/null 2>&1 \
    && fail "signing without the key" "staged" || pass "signing failure is fatal (no silent unsigned set)"

section "workflows: split publish, pipefail, release-branch CI (P1-1, P2-5, F-02)"
if python3 -c 'import yaml' 2>/dev/null; then
    WOUT="$(python3 "$SCRIPT_DIR/check_workflows.py" 2>&1)"; WRC=$?
    echo "$WOUT"
    PASS=$((PASS + $(grep -c '  PASS: ' <<<"$WOUT"))); FAIL=$((FAIL + $(grep -c '  FAIL: ' <<<"$WOUT")))
    [[ $WRC -eq 0 ]] || [[ "$WOUT" == *"FAIL: "* ]] || fail "check_workflows.py" "exit $WRC without a FAIL line: $WOUT"
else
    fail "PyYAML" "python3 -c 'import yaml' failed; the workflow checks need it (pip install pyyaml)"
fi

section "ci-local.sh runs every job and reports each (F-02)"
CI="$REPO_ROOT/scripts/release/ci-local.sh"
bash -n "$CI" && pass "ci-local.sh parses" || fail "ci-local.sh syntax" "bash -n"
OUT="$(bash "$CI" --iso /x 2>&1)"; RC=$?
[[ $RC -eq 2 && "$OUT" == *"go together"* ]] && pass "--iso without --build-log is refused" || fail "arg check" "rc=$RC"
# The job runner keeps going after a failure and exits non-zero: exercise it
# with a stub `make` on PATH (no real lint/test run inside this unit test).
mkdir -p "$S/stubbin"
printf '#!/bin/sh\n[ "$1" = lint ] && { echo lint-broke; exit 3; }\necho "make $*"; exit 0\n' > "$S/stubbin/make"; chmod +x "$S/stubbin/make"
OUT="$(PATH="$S/stubbin:$PATH" bash "$CI" 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && pass "a failing job makes ci-local.sh exit non-zero" || fail "ci-local exit" "rc=0"
[[ "$OUT" == *"lint               FAIL (exit 3)"* && "$OUT" == *"test-unit          PASS"* ]] \
    && pass "every job ran and the summary lists each result" || fail "ci-local summary" "$OUT"
rm -rf "$REPO_ROOT/tmp/ci-local"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
