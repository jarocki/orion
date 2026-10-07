#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_source_invariants.sh — the source-tree checks that used to live in the
# ISO gate's sections 29-33 (DEC-PHASE12-119, release-tests F-06).
#
# They are properties of the SOURCE (annotations, git mode bits, build-script
# text, package-list lines), so they belong in a unit suite; the ISO gate now
# asserts the shipped outcome of each fix instead. 31c was wrong: it required
# "debian:bullseye" in build-iso.sh and passed only because of a stale comment;
# it now requires the trixie build container.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $1 — ${2:-}"; }
has() { grep -q -- "$2" "$REPO_ROOT/$1" 2>/dev/null; }
hasE() { grep -qE -- "$2" "$REPO_ROOT/$1" 2>/dev/null; }
check() { if "$@"; then return 0; else return 1; fi; }

echo "[29] sample honesty, annotations, Plymouth initramfs check (P2-002, P3-001, P3-002)"
has scripts/download-samples.sh 'mini_sample_SYNTHETIC\.raw' && pass "29a: _SYNTHETIC sample name" || fail "29a" "download-samples.sh"
has scripts/download-samples.sh 'SYNTHETIC PLACEHOLDER' && pass "29b: placeholder README text" || fail "29b" "download-samples.sh"
has scripts/toggle-theme.sh 'DEC-PHASE11-014' && pass "29c: toggle-theme.sh cites DEC-PHASE11-014" || fail "29c" "annotation"
has iso/config/hooks/live/0800-orionx-branding.hook.chroot 'lsinitramfs' && pass "29d: 0800 verifies the theme with lsinitramfs" || fail "29d" "no lsinitramfs"
has iso/config/hooks/live/0800-orionx-branding.hook.chroot 'DEC-PHASE11-018' && pass "29e: 0800 cites DEC-PHASE11-018" || fail "29e" "annotation"

echo "[30] orionx-imager #77"
D=scripts/orionx-imager/lib/devices.py
hasE "$D" '"diskutil", "list", "-plist"\]|"diskutil", "list", "-plist",$' && pass "30a: diskutil list -plist without 'external'" || fail "30a" "$D"
has "$D" '"diskutil", "list", "-plist", "external"' && fail "30b" "'external' still present" || pass "30b: old 'external' call absent"
has "$D" 'DEC-PHASE11-IMAGER-001' && has "$D" RemovableMedia && has "$D" Ejectable && pass "30c-e: annotation + RemovableMedia/Ejectable filters" || fail "30c-e" "$D"

echo "[31] macOS wrap + version derivation"
B=scripts/build-iso.sh
hasE "$B" '"Darwin"' && pass "31a: Darwin detection" || fail "31a" "$B"
has "$B" ORIONX_BUILD_IN_DOCKER && pass "31b: recursion guard" || fail "31b" "$B"
has "$B" 'debian:trixie-slim' && pass "31c: build container is debian:trixie-slim (was a stale bullseye check)" || fail "31c" "no debian:trixie-slim"
has "$B" 'ORIONX_VERSION:-v2.0.0-rc9' && fail "31d" "stale default" || pass "31d: no stale v2.0.0-rc9 default"
has "$B" 'git describe --tags' && pass "31e: git-derived version" || fail "31e" "$B"
has "$B" DEC-PHASE11-MACOS-BUILD-001 && has "$B" DEC-PHASE11-VERSION-DEFAULT-001 && pass "31f-g: annotations" || fail "31f-g" "$B"
hasE Makefile 'uname.*!=.*Linux' && fail "31h" "Makefile still blocks non-Linux" || pass "31h: Makefile does not block non-Linux"

echo "[32] W11-13 source side"
has "$B" "--exclude='security/'" && fail "32a" "security/ still excluded" || pass "32a: security/ not excluded from staging"
[[ "$(grep -cE -- '-e ORIONX_GIT_SHA|-e ORIONX_GIT_TITLE|-e ORIONX_PHASE_11_SLICES' "$REPO_ROOT/$B")" -ge 3 ]] && pass "32d: git metadata plumbed into docker run" || fail "32d" "$B"
[[ "$(grep -cE 'FATAL:.*(matrix-commander|capa)' "$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot")" -ge 2 ]] && pass "32e: 0500 hard-fails capa + matrix-commander" || fail "32e" "0500"
[[ "$(grep -cE '^(git|python3-pip|firefox-esr)$' "$REPO_ROOT/iso/config/package-lists/orionx.list.chroot")" -ge 3 ]] && pass "32f: git/python3-pip/firefox-esr listed" || fail "32f" "package list"
for f in scripts/security/first-boot-wizard.sh "$B" iso/config/hooks/live/0500-install-external-tools.hook.chroot; do
    bash -n "$REPO_ROOT/$f" 2>/dev/null && pass "32j: bash -n $f" || fail "32j: bash -n $f" "syntax"
done

echo "[33] iso/auto/config execute bit (#82)"
if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    M="$(git -C "$REPO_ROOT" ls-files -s iso/auto/config | awk '{print $1}')"
    [[ "$M" == 100755 ]] && pass "33a: tracked mode 100755" || fail "33a" "mode '$M'"
else
    skip "33a: tracked mode" "not a git checkout"
fi
[[ -x "$REPO_ROOT/iso/auto/config" ]] && pass "33b: working-tree copy executable" || fail "33b" "not executable"

echo; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
