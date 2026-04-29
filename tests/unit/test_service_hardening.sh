#!/bin/bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Unit Tests for 0620-service-hardening.hook.chroot
#
# Tests the hook file structurally (no root/chroot needed):
# validates file existence, permissions, shebang, strict mode,
# shellcheck directive, @decision annotation, and all hardening
# content (service disable, SSH hardening, sysctl, systemd).
#
# @decision DEC-SEC-SVC-TEST-001
# @title Structural unit tests for service hardening hook
# @status accepted
# @rationale Live-build hooks run inside chroot as root during ISO build.
#   We cannot exercise them directly on macOS/dev machines.  Instead we
#   validate the hook file structurally: correct shebang, strict mode,
#   required hardening directives present, and ShellCheck clean.  This
#   catches regressions (accidentally deleted stanza, broken syntax)
#   without requiring a full ISO build cycle.
#
# Usage:  bash tests/unit/test_service_hardening.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Test framework (same pattern as test_filesystem_hardening.sh)
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
HOOK_FILE="$REPO_ROOT/iso/hooks/live/0620-service-hardening.hook.chroot"

echo "=== Service Hardening Hook — Structural Tests ==="
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

assert_contains "has @decision DEC-SEC-SVC-001" "@decision DEC-SEC-SVC-001" "$HOOK_CONTENT"
assert_contains "has @title annotation" "@title" "$HOOK_CONTENT"
assert_contains "has @status accepted" "@status accepted" "$HOOK_CONTENT"
assert_contains "has @rationale annotation" "@rationale" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 4. Disables unnecessary services
# ---------------------------------------------------------------------------
echo "--- Service disabling ---"

assert_contains "disables avahi-daemon" "avahi-daemon" "$HOOK_CONTENT"
assert_contains "disables cups" "cups" "$HOOK_CONTENT"
assert_contains "disables bluetooth" "bluetooth" "$HOOK_CONTENT"
assert_contains "disables ModemManager" "ModemManager" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 5. SSH hardening — PermitRootLogin
# ---------------------------------------------------------------------------
echo "--- SSH hardening ---"

assert_contains "SSH: PermitRootLogin no" "PermitRootLogin no" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 6. SSH hardening — PasswordAuthentication
# ---------------------------------------------------------------------------
assert_contains "SSH: PasswordAuthentication no" "PasswordAuthentication no" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 7. SSH hardening — MaxAuthTries
# ---------------------------------------------------------------------------
assert_contains "SSH: MaxAuthTries 3" "MaxAuthTries 3" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 8. Sysctl hardening — rp_filter
# ---------------------------------------------------------------------------
echo "--- Sysctl hardening ---"

assert_contains "sysctl: rp_filter = 1" "net.ipv4.conf.all.rp_filter = 1" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 9. Sysctl hardening — randomize_va_space
# ---------------------------------------------------------------------------
assert_contains "sysctl: randomize_va_space = 2" "kernel.randomize_va_space = 2" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 10. Sysctl hardening — kptr_restrict
# ---------------------------------------------------------------------------
assert_contains "sysctl: kptr_restrict = 2" "kernel.kptr_restrict = 2" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 11. Sysctl hardening — tcp_syncookies
# ---------------------------------------------------------------------------
assert_contains "sysctl: tcp_syncookies = 1" "net.ipv4.tcp_syncookies = 1" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 12. Sysctl hardening — ptrace_scope
# ---------------------------------------------------------------------------
assert_contains "sysctl: ptrace_scope = 1" "kernel.yama.ptrace_scope = 1" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 13. Systemd unit hardening — ProtectSystem=strict
# ---------------------------------------------------------------------------
echo "--- Systemd unit hardening ---"

assert_contains "references ProtectSystem=strict" "ProtectSystem=strict" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 14. ShellCheck passes
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
