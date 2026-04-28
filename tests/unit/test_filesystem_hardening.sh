#!/bin/bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Unit Tests for 0600-filesystem-hardening.hook.chroot
#
# Tests the hook file structurally (no root/chroot needed):
# validates file existence, permissions, shebang, strict mode,
# shellcheck directive, @decision annotation, and all hardening
# content (tmpfs mounts, core dump disable, umask, sticky bit).
#
# @decision DEC-SEC-FS-TEST-001
# @title Structural unit tests for filesystem hardening hook
# @status accepted
# @rationale Live-build hooks run inside chroot as root during ISO build.
#   We cannot exercise them directly on macOS/dev machines.  Instead we
#   validate the hook file structurally: correct shebang, strict mode,
#   required hardening directives present, and ShellCheck clean.  This
#   catches regressions (accidentally deleted stanza, broken syntax)
#   without requiring a full ISO build cycle.
#
# Usage:  bash tests/unit/test_filesystem_hardening.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Test framework (same pattern as test_mesh_lib.sh)
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected: '$expected'"
        echo "        actual:   '$actual'"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_match() {
    local description="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected pattern: '$pattern'"
        echo "        actual:           '$actual'"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_contains() {
    local description="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected to contain: '$needle'"
        (( FAIL_COUNT++ )) || true
    fi
}

# ---------------------------------------------------------------------------
# Locate the hook file under test
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_FILE="$REPO_ROOT/iso/hooks/live/0600-filesystem-hardening.hook.chroot"

echo "=== Filesystem Hardening Hook — Structural Tests ==="
echo ""

# ---------------------------------------------------------------------------
# 1. File existence and permissions
# ---------------------------------------------------------------------------
echo "--- File existence & permissions ---"

if [[ -f "$HOOK_FILE" ]]; then
    echo "  PASS: hook file exists"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: hook file not found at $HOOK_FILE"
    (( FAIL_COUNT++ )) || true
    echo ""
    echo "==========================================="
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $(( PASS_COUNT + FAIL_COUNT )))"
    echo "==========================================="
    exit 1
fi

if [[ -x "$HOOK_FILE" ]]; then
    echo "  PASS: hook file is executable"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: hook file is not executable"
    (( FAIL_COUNT++ )) || true
fi
echo ""

# ---------------------------------------------------------------------------
# Read the hook file content once for all subsequent checks
# ---------------------------------------------------------------------------
HOOK_CONTENT="$(cat "$HOOK_FILE")"
FIRST_LINE="$(head -n1 "$HOOK_FILE")"

# ---------------------------------------------------------------------------
# 2. Shebang, strict mode, shellcheck directive
# ---------------------------------------------------------------------------
echo "--- Shebang, strict mode, shellcheck ---"

assert_eq "shebang is #!/usr/bin/env bash" "#!/usr/bin/env bash" "$FIRST_LINE"

assert_contains "has shellcheck directive" "# shellcheck shell=bash" "$HOOK_CONTENT"

assert_contains "has set -euo pipefail" "set -euo pipefail" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 3. @decision annotation
# ---------------------------------------------------------------------------
echo "--- @decision annotation ---"

assert_contains "has @decision DEC-SEC-FS-001" "@decision DEC-SEC-FS-001" "$HOOK_CONTENT"
assert_contains "has @title annotation" "@title" "$HOOK_CONTENT"
assert_contains "has @status accepted" "@status accepted" "$HOOK_CONTENT"
assert_contains "has @rationale annotation" "@rationale" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 4. tmpfs /tmp mount with noexec,nosuid,nodev
# ---------------------------------------------------------------------------
echo "--- tmpfs /tmp mount ---"

assert_contains "contains tmpfs /tmp mount" "tmpfs /tmp tmpfs" "$HOOK_CONTENT"
assert_contains "/tmp has noexec" "tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 5. tmpfs /var/tmp mount
# ---------------------------------------------------------------------------
echo "--- tmpfs /var/tmp mount ---"

assert_contains "contains tmpfs /var/tmp mount" "tmpfs /var/tmp tmpfs" "$HOOK_CONTENT"
assert_contains "/var/tmp has noexec" "tmpfs /var/tmp tmpfs defaults,noexec,nosuid,nodev" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 6. tmpfs /dev/shm mount
# ---------------------------------------------------------------------------
echo "--- tmpfs /dev/shm mount ---"

assert_contains "contains tmpfs /dev/shm mount" "tmpfs /dev/shm tmpfs" "$HOOK_CONTENT"
assert_contains "/dev/shm has noexec" "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 7. Core dump disable (limits.d)
# ---------------------------------------------------------------------------
echo "--- Core dump disable ---"

assert_contains "contains hard core 0" "* hard core 0" "$HOOK_CONTENT"
assert_contains "contains soft core 0" "* soft core 0" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 8. Core dump disable (sysctl — suid_dumpable)
# ---------------------------------------------------------------------------
echo "--- sysctl core dump disable ---"

assert_contains "contains suid_dumpable = 0" "fs.suid_dumpable = 0" "$HOOK_CONTENT"
assert_contains "contains core_pattern redirect" "kernel.core_pattern = |/bin/false" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 9. UMASK 027 in login.defs
# ---------------------------------------------------------------------------
echo "--- UMASK 027 login.defs ---"

assert_contains "contains UMASK 027 sed replacement" "UMASK" "$HOOK_CONTENT"
assert_match "sed replaces UMASK 022 with 027" "sed.*UMASK.*027" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 10. umask 027 profile script
# ---------------------------------------------------------------------------
echo "--- umask 027 profile.d script ---"

assert_contains "contains umask 027 in profile.d content" "umask 027" "$HOOK_CONTENT"
assert_contains "writes to /etc/profile.d/orionx-umask.sh" "/etc/profile.d/orionx-umask.sh" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 11. Sticky bit enforcement
# ---------------------------------------------------------------------------
echo "--- Sticky bit enforcement ---"

assert_contains "contains sticky bit find command" "chmod +t" "$HOOK_CONTENT"
assert_contains "find targets world-writable dirs" "-perm -0002" "$HOOK_CONTENT"
assert_contains "excludes dirs with sticky bit already set" "-perm -1000" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 12. ShellCheck passes
# ---------------------------------------------------------------------------
echo "--- ShellCheck ---"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$HOOK_FILE" 2>&1; then
        echo "  PASS: ShellCheck passes clean"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: ShellCheck reported issues"
        (( FAIL_COUNT++ )) || true
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

echo ""

# =========================================================================
# Summary
# =========================================================================
echo "==========================================="
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
