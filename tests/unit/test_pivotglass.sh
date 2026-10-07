#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_pivotglass.sh — Pivotglass port (roadmap #90, DEC-PHASE12-013)
#
# Vendored package + packaged static web export, launcher, apt/pip dependency
# split, PATH + Orion-menu wiring, provenance, and (with Docker) a live run on
# trixie: `ap --version` and `ap web` serving HTTP 200.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf "  ${YELLOW}SKIP${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

P="$REPO_ROOT/scripts/pivotglass"
PKG="$P/pivotglass"   # renamed upstream between 0.9.6 and 1.2.0
SETUP="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
EXT="$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot"
PKGS="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"

section "Vendored package + packaged web export"
[[ -f "$PKG/__main__.py" && -f "$PKG/web/server.py" ]] && pass "pivotglass package package vendored" || fail "package vendored" "missing __main__/web/server.py"
[[ -f "$PKG/web/static/index.html" ]] && pass "static web export at the PACKAGED path (web/static/index.html)" || fail "static export" "server.py expects web/static/ next to it"
grep -q '_PACKAGED_WEB_ROOT = Path(__file__).with_name("static")' "$PKG/web/server.py" && pass "server.py supports the packaged static layout" || fail "packaged layout support" "upstream changed web root resolution"
# Committed bytecode is the defect; a local __pycache__ from another suite's
# import is ignored by .gitignore and excluded by build-iso.sh's rsync.
if git -C "$PKG" ls-files -- . | grep -qE '(^|/)__pycache__/|\.pyc$'; then fail "no bytecode vendored" "__pycache__/*.pyc committed"; else pass "no bytecode vendored"; fi
for junk in tests docs node_modules; do [[ -e "$P/$junk" || -e "$PKG/web/$junk" ]] && fail "no upstream $junk shipped" "size discipline"; done; pass "no upstream tests/docs/node_modules shipped"
[[ -x "$P/ap" ]] && pass "ap launcher executable" || fail "ap launcher" "missing/not +x"
grep -q 'exec python3 -m pivotglass' "$P/ap" && pass "launcher runs python3 -m pivotglass (no uv/venv)" || fail "launcher form" "expected python3 -m"
grep -q 'while \[ -h "\$_SOURCE" \]' "$P/ap" && pass "launcher resolves its /usr/bin symlink" || fail "symlink resolution" "missing"
[[ -f "$P/PROVENANCE.txt" && -f "$P/LICENSE.pivotglass" ]] && pass "provenance + MIT licence shipped" || fail "provenance/licence" "missing"
# Compile with the bytecode cache redirected — otherwise this very check would
# write __pycache__ into the vendored package and trip the no-bytecode assertion.
if PYTHONPYCACHEPREFIX="$(mktemp -d)" python3 -m py_compile "$PKG/__main__.py" "$PKG/web/server.py" 2>/dev/null; then pass "package entry points compile on host python"; else fail "compile" "py_compile error"; fi

section "Dependency split: apt for everything trixie has, pip only for stix2"
for d in python3-cmd2 python3-rich python3-sqlalchemy python3-httpx python3-pydantic python3-tomli-w python3-yaml python3-requests python3-pytz python3-simplejson python3-prompt-toolkit; do
    grep -qE "^$d$" "$PKGS" && pass "apt: $d" || fail "apt: $d" "missing from package list"
done
# Debian's python3-pyfiglet (+dfsg) lacks the contributed fonts the TUI needs.
if grep -qE "^python3-pyfiglet$" "$PKGS"; then fail "python3-pyfiglet NOT from apt" "+dfsg repack lacks ansi_shadow → ap tui crashes"; else pass "python3-pyfiglet not taken from apt (dfsg font strip)"; fi
# DEC-PHASE12-116: stix2 + pyfiglet come from the hash-locked pivotglass set,
# hard-fail. The live run below installs from that same lock.
LOCK="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/pip/pivotglass.txt"
grep -qF "pip_locked pip3 pivotglass --break-system-packages || {" "$EXT" && pass "0500 hook installs stix2 + pyfiglet from the pivotglass lock (PEP 668 escape hatch)" || fail "stix2/pyfiglet pip step" "0500 does not use the pivotglass lock"
grep -q '^stix2==' "$LOCK" && grep -q '^pyfiglet==' "$LOCK" && [[ "$(grep -c -- '--hash=sha256:' "$LOCK")" -ge 4 ]] && pass "pivotglass lock pins stix2 + pyfiglet with sha256 hashes" || fail "pivotglass lock" "unpinned or unhashed"
grep -q "pyfiglet.Figlet(font='ansi_shadow')" "$EXT" && pass "0500 hook verifies stix2 import AND the ansi_shadow font" || fail "post-install verify" "no import/font check"
grep -q "DEC-PHASE12-013" "$EXT" && pass "DEC-PHASE12-013 annotation in 0500" || fail "annotation" "missing"

section "PATH + Orion menu"
grep -qE '\["ap"\]="/opt/orionx/scripts/pivotglass/ap"' "$SETUP" && pass "SCRIPT_MAP: ap" || fail "SCRIPT_MAP ap" "missing"
grep -qE '\["pivotglass"\]="/opt/orionx/scripts/pivotglass/ap"' "$SETUP" && pass "SCRIPT_MAP: pivotglass alias" || fail "SCRIPT_MAP pivotglass" "missing"
grep -q "orionx-pivotglass.desktop" "$SETUP" && grep -q "^Exec=/usr/bin/ap web" "$SETUP" && pass "Pivotglass .desktop launches 'ap web'" || fail "Pivotglass .desktop" "missing or wrong Exec"
awk '/orionx-pivotglass.desktop/,/DESKTOP_EOF$/' "$SETUP" | grep -q "Categories=X-Orion" && pass "Pivotglass .desktop grouped under the Orion menu" || fail "Pivotglass menu group" "not X-Orion"
grep -q -i "pivotglass" "$REPO_ROOT/docs/User_Guide.md" && pass "User Guide documents Pivotglass" || fail "User Guide" "no Pivotglass section"

section "Live run on trixie / Python 3.13 (needs Docker)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    OUT=$(docker run --rm --platform linux/amd64 -v "$P:/opt/orionx/scripts/pivotglass:ro" -v "$LOCK:/lock.txt:ro" -e PYTHONPYCACHEPREFIX=/tmp/pyc debian:trixie-slim bash -c '
        apt-get update -q >/dev/null 2>&1
        apt-get install -y -q --no-install-recommends python3 python3-pip python3-cmd2 python3-rich python3-sqlalchemy python3-httpx python3-pydantic python3-tomli-w python3-yaml python3-requests python3-pytz python3-simplejson python3-prompt-toolkit curl ca-certificates >/dev/null 2>&1
        pip3 install --break-system-packages --no-input -q --require-hashes --no-deps -r /lock.txt >/dev/null 2>&1 && echo "LOCK-INSTALL: ok"
        ln -s /opt/orionx/scripts/pivotglass/ap /usr/bin/ap
        export HOME=/tmp/h; mkdir -p $HOME
        echo "VERSION: $(ap --version 2>&1 | head -1)"
        echo "TUI-IMPORT: $(PYTHONPATH=/opt/orionx/scripts/pivotglass python3 -c "import pivotglass.agent.chat" 2>&1 | tail -1 || true)ok"
        (timeout 15 ap web >/tmp/w.log 2>&1 &)
        for i in 1 2 3 4 5 6 7 8; do sleep 1; c=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8765/ 2>/dev/null); [ "$c" = "200" ] && break; done
        echo "WEB: HTTP $c"' 2>&1)
    printf '%s' "$OUT" | grep -q "LOCK-INSTALL: ok" && pass "the hash-locked set installs on trixie with --require-hashes --no-deps" || fail "lock install on trixie" "$(printf '%s' "$OUT" | head -c 200)"
    printf '%s' "$OUT" | grep -q "VERSION: pivotglass 1\.2\.0" && pass "ap --version runs via /usr/bin symlink on trixie ($(printf '%s' "$OUT" | grep -o 'VERSION: .*' | head -1))" || fail "ap --version on trixie" "$(printf '%s' "$OUT" | head -c 200)"
    printf '%s' "$OUT" | grep -q "WEB: HTTP 200" && pass "ap web serves the packaged static export (HTTP 200)" || fail "ap web on trixie" "$(printf '%s' "$OUT" | grep -o 'WEB: .*' | head -1)"
    # The terminal deck path must import cleanly with python3-prompt-toolkit (agent extra).
    if printf '%s' "$OUT" | grep -q "TUI-IMPORT: ok"; then pass "ap tui/chat module imports (prompt_toolkit via apt)"; else fail "ap tui import" "$(printf '%s' "$OUT" | grep -o 'TUI-IMPORT: .*' | head -c 200)"; fi
else
    skip "ap live run" "Docker not available"
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, ${YELLOW}%d skipped${NC}\n" "$PASS" "$FAIL" "$SKIP"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
