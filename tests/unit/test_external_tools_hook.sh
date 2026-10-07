#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_external_tools_hook.sh — 0500 hook: hash-locked pip, hard-fail tools,
# fingerprint-pinned Zeek with a real rollback (DEC-PHASE12-116/117).
#
# Behavioural: sources the hook with ORIONX_0500_LIB_ONLY=1 and drives its
# functions with stub pip/wget/gpg/apt-get on PATH and scratch paths. The
# locks themselves are checked for shape (every pin exact and hashed). The
# real installs were proven separately in debian:trixie-slim amd64 (see the
# DEC-PHASE12-116 block in the hook); this suite needs no network.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

HOOK="$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot"
LOCKS="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/pip"
INSTALLER="$REPO_ROOT/iso/config/includes.chroot/opt/orionx/optional/install-zeek.sh"
S="$REPO_ROOT/tmp/test_ext_hook_$$"; mkdir -p "$S/bin"; trap 'rm -rf "$S"' EXIT

lib() {  # run a snippet with the hook's library loaded and stubs first on PATH
    ( export PATH="$S/bin:$PATH" ORIONX_0500_LIB_ONLY=1 PIP_LOCKS="${PIP_LOCKS_OVERRIDE:-$LOCKS}" ZEEK_INSTALLER="${ZEEK_INSTALLER_OVERRIDE:-$INSTALLER}"
      # shellcheck disable=SC1090
      . "$HOOK"; eval "$1" )
}

section "lock files: every pin exact and hashed (P2-4, F13)"
for set in forensics pivotglass re comms; do
    f="$LOCKS/$set.txt"
    [[ -f "$f" ]] || { fail "$set.txt" "missing"; continue; }
    bad="$(python3 - "$f" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
reqs = re.split(r"\n(?=[A-Za-z0-9])", "\n".join(l for l in text.splitlines() if not l.startswith("#")).strip())
bad = [r.split()[0] for r in reqs if not re.match(r"^[A-Za-z0-9_.\-]+==\S+ \\", r) or "--hash=sha256:" not in r]
print(" ".join(bad))
PY
)"
    [[ -z "$bad" ]] && pass "$set.txt: every requirement is name==version with sha256 hashes" || fail "$set.txt" "unpinned/unhashed: $bad"
    cmp -s <(grep -E '^[A-Za-z0-9]' "$LOCKS/$set.in" | sort) <(grep -oE '^[A-Za-z0-9_.\-]+==[^ ]+' "$f" | sort) \
        && pass "$set.txt locks exactly the pins in $set.in" || fail "$set lock vs .in" "differs (re-run scripts/release/pip-lock.py)"
done
grep -q '^volatility3==2.28.2 ' "$LOCKS/forensics.txt" && pass "forensics: volatility3 2.28.2 (the rc9 version)" || fail "forensics pin" "volatility3"
grep -q '^flare-capa==9.4.0 ' "$LOCKS/re.txt" && pass "re: flare-capa 9.4.0 (rc9)" || fail "re pin" "capa"
grep -q '^matrix-commander==8.0.6 ' "$LOCKS/comms.txt" && pass "comms: matrix-commander 8.0.6 (rc9)" || fail "comms pin" "matrix-commander"
grep -qE '^(argparse|asyncio|uuid)==' "$LOCKS/comms.txt" && fail "comms" "stdlib-shadowing backports locked" || pass "comms: argparse/asyncio/uuid backports excluded"
grep -q '^stix2==3.0.2 ' "$LOCKS/pivotglass.txt" && grep -q '^pyfiglet==1.0.4 ' "$LOCKS/pivotglass.txt" && pass "pivotglass: stix2 3.0.2 + pyfiglet 1.0.4 (rc9)" || fail "pivotglass pins" "stix2/pyfiglet"

section "pip_locked installs only from the lock, hash-required, no resolver"
printf '#!/bin/sh\necho "$0 $*" >> "%s/pip.calls"\nexit 0\n' "$S" > "$S/bin/fakepip"; chmod +x "$S/bin/fakepip"
lib 'pip_locked fakepip forensics' >/dev/null 2>&1 && pass "pip_locked succeeds when the lock exists" || fail "pip_locked" "failed"
CALL="$(cat "$S/pip.calls" 2>/dev/null)"
[[ "$CALL" == *"install --no-input --require-hashes --no-deps -r $LOCKS/forensics.txt"* ]] \
    && pass "pip is called with --require-hashes --no-deps -r <lock>" || fail "pip args" "$CALL"
PIP_LOCKS_OVERRIDE="$S/nolocks" lib 'pip_locked fakepip forensics' >/dev/null 2>&1 \
    && fail "missing lock" "accepted" || pass "a missing lock file is fatal"
printf '#!/bin/sh\nexit 1\n' > "$S/bin/badpip"; chmod +x "$S/bin/badpip"
lib 'pip_locked badpip re' >/dev/null 2>&1 && fail "pip failure" "swallowed" || pass "a pip failure propagates"

section "hard-fail wiring: README-promised tools abort the build (P1-3)"
# The action body must stop on these; checked on the hook text because the
# body runs only inside a live-build chroot.
for pat in 'pip_locked /opt/orionx/venv/forensics/bin/pip forensics || {' 'pip_locked pip3 pivotglass --break-system-packages || {' \
           'pip_locked /opt/orionx/venv/re/bin/pip re 2>&1 || {' 'pip_locked /opt/orionx/venv/comms/bin/pip comms 2>&1 || {'; do
    grep -A2 -F "$pat" "$HOOK" | grep -q 'exit 1' && pass "hard-fail: $pat" || fail "hard-fail" "$pat has no exit 1"
done
grep -qF 'ln -sf "/opt/orionx/venv/forensics/bin/$b" "/usr/local/bin/$b"' "$HOOK" && pass "vol/volshell stay on PATH at /usr/local/bin" || fail "vol PATH" "no symlink"
grep -qF '/usr/local/bin/vol -h >/dev/null || {' "$HOOK" && pass "vol -h must run after install" || fail "vol probe" "missing"
grep -qE 'pip3 install --break-system-packages --no-input (volatility3|stix2)' "$HOOK" && fail "unpinned pip" "still present" || pass "no unpinned system pip install remains"

section "Zeek: fingerprint pin, signed-by scope, real rollback (F11, shell P2-2)"
mkdir -p "$S/etc"
sed -e "s|^ZEEK_KEYRING=.*|ZEEK_KEYRING=\"$S/etc/zeek.gpg\"|" -e "s|^ZEEK_SOURCE_LIST=.*|ZEEK_SOURCE_LIST=\"$S/etc/orionx-zeek.list\"|" "$INSTALLER" > "$S/install-zeek.sh"
PIN="$(sed -n 's/^ZEEK_REPO_KEY_FPR="\(.*\)"$/\1/p' "$INSTALLER")"
mkstubs() {  # <fingerprint the fake key reports> <apt-get install rc>
    printf '#!/bin/sh\n[ "$1" = -qO ] && echo KEY > "$2"\nexit 0\n' > "$S/bin/wget"
    printf '#!/bin/sh\ncase "$*" in *--show-keys*) echo "fpr:::::::::%s:";; *--dearmor*) cat;; esac\nexit 0\n' "$1" > "$S/bin/gpg"
    printf '#!/bin/sh\necho "apt-get $*" >> "%s/apt.calls"\ncase "$1" in install) exit %s;; esac\nexit 0\n' "$S" "$2" > "$S/bin/apt-get"
    chmod +x "$S/bin/wget" "$S/bin/gpg" "$S/bin/apt-get"; rm -f "$S/apt.calls" "$S/etc/"*
}
mkstubs 0000000000000000000000000000000000000000 0
OUT="$(ZEEK_INSTALLER_OVERRIDE="$S/install-zeek.sh" lib 'install_zeek' 2>&1)" && fail "fingerprint mismatch" "accepted" || pass "a key with the wrong fingerprint is refused"
[[ "$OUT" == *"KEY FINGERPRINT MISMATCH"* ]] && pass "the refusal names the mismatch" || fail "mismatch message" "$OUT"
[[ ! -e "$S/etc/orionx-zeek.list" && ! -e "$S/etc/zeek.gpg" && ! -e "$S/apt.calls" ]] \
    && pass "on refusal no source, no keyring, no apt-get update" || fail "refusal side effects" "$(ls "$S/etc"; cat "$S/apt.calls" 2>/dev/null)"
mkstubs "$PIN" 100
ZEEK_INSTALLER_OVERRIDE="$S/install-zeek.sh" lib 'install_zeek' >/dev/null 2>&1 && fail "apt install failure" "reported success" \
    || pass "an apt-get install failure fails install_zeek (not only the last command)"
grep -qx "deb \[signed-by=$S/etc/zeek.gpg\] https://download.opensuse.org/repositories/security:/zeek/Debian_13/ /" "$S/etc/orionx-zeek.list" \
    && pass "the source line is scoped with signed-by= to its own keyring" || fail "signed-by" "$(cat "$S/etc/orionx-zeek.list" 2>/dev/null)"
ZEEK_INSTALLER_OVERRIDE="$S/install-zeek.sh" lib 'zeek_rollback' >/dev/null 2>&1
[[ ! -e "$S/etc/orionx-zeek.list" && ! -e "$S/etc/zeek.gpg" ]] && pass "zeek_rollback removes the source and keyring" || fail "rollback" "left files"
grep -q 'trusted.gpg.d/zeek.gpg' "$HOOK" && ! grep -qE '> /etc/apt/trusted.gpg.d/zeek.gpg' "$HOOK" \
    && pass "no key is written to trusted.gpg.d (only removed, for old images)" || fail "trusted.gpg.d" "still written"
grep -A6 '^if install_zeek; then' "$HOOK" | grep -q 'zeek_rollback' && pass "the soft-fail path calls zeek_rollback" || fail "soft-fail path" "no rollback"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
