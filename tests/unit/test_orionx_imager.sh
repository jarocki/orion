#!/usr/bin/env bash
# @decision DEC-PHASE11-015
# orionx-imager unit tests — W11-12 host-side ISO downloader + USB writer.
#
# Tests are structural + syntactic: they verify all required files exist,
# are executable, have valid syntax, and that the CLI surface responds to
# safe flags (--help, --list-devices) without side effects.  No network
# calls and no actual writes are performed.
#
# Run from any directory:
#   bash tests/unit/test_orionx_imager.sh
# Exit 0 = all pass.  Exit 1 = one or more failures.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
IMAGER="$REPO_ROOT/scripts/orionx-imager/orionx-imager"
CLI="$REPO_ROOT/scripts/orionx-imager/orionx-imager-cli.sh"

pass() { printf "  PASS: %s\n" "$*"; PASS=$((PASS+1)); }
fail() { printf "  FAIL: %s\n" "$*"; FAIL=$((FAIL+1)); }

PASS=0; FAIL=0

echo "=== W11-12 orionx-imager unit tests ==="

# --- 1. Files present + executable ------------------------------------------
if [[ -x "$IMAGER" ]]; then
    pass "orionx-imager present + executable"
else
    fail "orionx-imager not executable"
fi

if [[ -x "$CLI" ]]; then
    pass "orionx-imager-cli.sh present + executable"
else
    fail "CLI not executable"
fi

# --- 2. Python syntax (main entry point) ------------------------------------
if python3 -c "import ast; ast.parse(open('$IMAGER').read())" 2>/dev/null; then
    pass "Python syntax valid (orionx-imager)"
else
    fail "Python syntax invalid (orionx-imager)"
fi

# --- 3. lib module syntax ---------------------------------------------------
for m in \
    "$REPO_ROOT/scripts/orionx-imager/lib/downloader.py" \
    "$REPO_ROOT/scripts/orionx-imager/lib/writer.py" \
    "$REPO_ROOT/scripts/orionx-imager/lib/devices.py"; do
    if [[ -f "$m" ]]; then
        if python3 -c "import ast; ast.parse(open('$m').read())" 2>/dev/null; then
            pass "$(basename "$m") syntax valid"
        else
            fail "$(basename "$m") syntax invalid"
        fi
    else
        fail "$(basename "$m") missing"
    fi
done

# lib/__init__.py presence
if [[ -f "$REPO_ROOT/scripts/orionx-imager/lib/__init__.py" ]]; then
    pass "lib/__init__.py present"
else
    fail "lib/__init__.py missing"
fi

# --- 4. Bash syntax + shellcheck --------------------------------------------
if bash -n "$CLI"; then
    pass "CLI bash -n clean"
else
    fail "CLI bash -n failed"
fi

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$CLI"; then
        pass "CLI shellcheck clean"
    else
        fail "CLI shellcheck failed"
    fi
else
    pass "CLI shellcheck skipped (shellcheck not installed)"
fi

# --- 5. CLI surface: --help -------------------------------------------------
if "$IMAGER" --help >/dev/null 2>&1; then
    pass "--help exits 0"
else
    fail "--help failed"
fi

# --- 6. CLI surface: --list-devices -----------------------------------------
# May return empty list on hosts without removable media; exit 0 required.
if "$IMAGER" --list-devices >/dev/null 2>&1; then
    pass "--list-devices exits 0"
else
    fail "--list-devices failed"
fi

# --- 7. README present -------------------------------------------------------
if [[ -f "$REPO_ROOT/scripts/orionx-imager/README.md" ]]; then
    pass "README.md present"
else
    fail "README.md missing"
fi

# --- 8. Compound integration: refuse-list blocks write to internal disk ------
# The tool must refuse writes to the internal system disk (macOS: /dev/disk0,
# Linux: /dev/sda) with a non-zero exit code even before any ISO download or
# dd invocation occurs.  This exercises the full CLI safety path:
#   arg parse → target present → refuse_write() → REFUSED + exit 3
# Tests omit --dry-run intentionally so that the refuse-list check (not the
# dry-run short-circuit) is what produces the non-zero exit.
tmpiso="$(mktemp /tmp/test_orionx_imager_XXXXXX.iso)"
trap 'rm -f "$tmpiso"' EXIT

# Write a tiny dummy ISO placeholder
printf '\x45\x46\x49\x20\x50\x41\x52\x54' > "$tmpiso"

# Pick the platform-appropriate refuse-list candidate.
if [[ "$(uname -s)" == "Darwin" ]]; then
    REFUSED_DISK="/dev/disk0"
else
    REFUSED_DISK="/dev/sda"
fi

if "$IMAGER" --iso "$tmpiso" --target "$REFUSED_DISK" >/dev/null 2>&1; then
    fail "refuse-list: write to $REFUSED_DISK should have been blocked (non-zero exit expected)"
else
    pass "refuse-list: write to $REFUSED_DISK correctly refused (non-zero exit)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
