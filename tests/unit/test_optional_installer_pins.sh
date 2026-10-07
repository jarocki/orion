#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_optional_installer_pins.sh — optional installers refuse unverified
# downloads (DEC-PHASE12-122; security F11, F12).
#
# Behavioural: sources lib/orionx-installer-common.sh and drives
# orionx_download_verified / orionx_wget_extract with a stub wget; runs the
# Element key check against stub gpg output. No network, no root.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
OPT="$REPO_ROOT/iso/config/includes.chroot/opt/orionx/optional"
S="$REPO_ROOT/tmp/test_inst_pins_$$"; mkdir -p "$S/bin"; trap 'rm -rf "$S"' EXIT
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

printf 'payload-v1\n' > "$S/payload"
GOOD="$(sha256 "$S/payload" | awk '{print $1}')"
printf '#!/bin/sh\n# stub wget: -q -O <dest> <url>\n[ "$1" = -q ] && shift; [ "$1" = -O ] && cp "%s/payload" "$2"\nexit 0\n' "$S" > "$S/bin/wget"
chmod +x "$S/bin/wget"
[[ "$(command -v sha256sum)" ]] || { printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$S/bin/sha256sum"; chmod +x "$S/bin/sha256sum"; }

run() {  # run a snippet with the installer library loaded
    ( export PATH="$S/bin:$PATH"
      # shellcheck disable=SC1091
      . "$OPT/lib/orionx-installer-common.sh" >/dev/null 2>&1; eval "$1" )
}

run 'orionx_download_verified https://x/f "'"$S"'/f1" '"$GOOD" >/dev/null 2>&1 && [[ -f "$S/f1" ]] \
    && pass "matching SHA-256: file kept" || fail "good pin" "refused"
run 'orionx_download_verified https://x/f "'"$S"'/f2" '"$(printf '0%.0s' {1..64})" >/dev/null 2>&1 \
    && fail "mismatch" "accepted" || pass "mismatching SHA-256 is refused (exit non-zero)"
[[ ! -e "$S/f2" ]] && pass "the mismatching download is deleted" || fail "mismatch cleanup" "file left"
run 'orionx_download_verified https://x/f "'"$S"'/f3" ""' >/dev/null 2>&1 \
    && fail "empty pin" "accepted (trust-on-first-use)" || pass "an empty pin is refused (no trust-on-first-use)"
[[ ! -e "$S/f3" ]] && pass "with no pin nothing is even downloaded" || fail "empty pin" "downloaded anyway"
run 'orionx_wget_extract https://x/a.tar.gz "'"$S"'/dest"' >/dev/null 2>&1 \
    && fail "wget_extract without pin" "extracted" || pass "orionx_wget_extract requires a pin"
[[ ! -d "$S/dest" ]] && pass "nothing extracted without a pin" || fail "extract" "dest created"

for f in install-floss.sh install-trid.sh install-ghidra.sh install-gomuks.sh; do
    grep -qE '^[[:space:]]*(wget -q -O|wget -qO)' "$OPT/$f" && fail "$f" "raw wget of an executable remains" || pass "$f: no unverified wget"
done
for v in FLOSS_SHA256 TRID_BIN_SHA256 TRID_DEF_SHA256 GHIDRA_ZIP_SHA256; do
    grep -qE "^$v=\"[0-9a-f]{64}\"" "$OPT"/install-*.sh && pass "$v pinned (64 hex)" || fail "$v" "not pinned"
done
grep -q '^GOMUKS_SHA256=""' "$OPT/install-gomuks.sh" && pass "gomuks has no pin (dead upstream URL) and therefore refuses" || fail "gomuks pin state" "unexpected"

# Element key: run the installer's own key check block with stub gpg.
blk="$(sed -n '/^ELEMENT_KEY_URL=/,/^orionx_log_info "Element signing key fingerprint verified/p' "$OPT/install-element.sh")"
mkdir -p "$S/k"
for case in good bad; do
    fpr=12D4CD600C2240A9F4A82071D7B0B66941D01538; [[ $case == bad ]] && fpr=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    printf '#!/bin/sh\necho "fpr:::::::::%s:"\n' "$fpr" > "$S/bin/gpg"; chmod +x "$S/bin/gpg"
    printf '#!/bin/sh\nshift; shift; cp "$1" "$2"\n' > "$S/bin/install"; chmod +x "$S/bin/install"
    rm -f "$S/k/ring"
    run 'orionx_apt_install() { :; }; '"${blk//\/usr\/share\/keyrings\/element-io-archive-keyring.gpg/$S/k/ring}" >/dev/null 2>&1; rc=$?
    if [[ $case == good ]]; then
        [[ $rc -eq 0 && -f "$S/k/ring" ]] && pass "Element key with the pinned fingerprint is installed" || fail "element good" "rc=$rc"
    else
        [[ $rc -ne 0 && ! -f "$S/k/ring" ]] && pass "Element key with another fingerprint is refused, no keyring written" || fail "element bad" "rc=$rc"
    fi
done

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
