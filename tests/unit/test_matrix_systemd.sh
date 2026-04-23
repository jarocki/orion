#!/usr/bin/env bash
# shellcheck shell=bash
#
# Test suite for Matrix Synapse systemd unit file (W2-2)
#
# Validates the systemd service unit for Matrix Synapse with WireGuard mesh
# dependency. Static analysis only — no systemd runtime required.
# If systemd-analyze is available, runs structural verification.
#
# Usage: bash tests/unit/test_matrix_systemd.sh
#

set -euo pipefail

# --- Test framework (mirrors test_matrix_docker.sh pattern) ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Resolve project root (this script lives in tests/unit/)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass() {
    (( TESTS_PASSED++ )) || true
    (( TESTS_RUN++ )) || true
    echo "  PASS: $1"
}

fail() {
    (( TESTS_FAILED++ )) || true
    (( TESTS_RUN++ )) || true
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

assert_file_exists() {
    local file="$1"
    local desc="${2:-$file exists}"
    if [[ -f "$PROJECT_ROOT/$file" ]]; then
        pass "$desc"
    else
        fail "$desc" "File not found: $file"
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local desc="${3:-$file contains '$pattern'}"
    if grep -qE "$pattern" "$PROJECT_ROOT/$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc" "Pattern not found in $file: $pattern"
    fi
}

# ============================================================
# Test Group 1: File Existence
# ============================================================
echo "=== Test Group 1: File Existence ==="

UNIT_FILE="systemd/matrix-synapse-orionx.service"

assert_file_exists "$UNIT_FILE" \
    "matrix-synapse-orionx.service exists"

# ============================================================
# Test Group 2: Unit Section
# ============================================================
echo ""
echo "=== Test Group 2: [Unit] Section ==="

assert_file_contains "$UNIT_FILE" '^\[Unit\]' \
    "Has [Unit] section"

assert_file_contains "$UNIT_FILE" 'Description=.*Matrix Synapse' \
    "Has Matrix Synapse description"

assert_file_contains "$UNIT_FILE" 'After=network-online\.target' \
    "Has After=network-online.target"

assert_file_contains "$UNIT_FILE" 'After=wg-quick@wg0\.service' \
    "Has After=wg-quick@wg0.service (WireGuard dependency)"

assert_file_contains "$UNIT_FILE" 'Wants=network-online\.target' \
    "Has Wants=network-online.target"

assert_file_contains "$UNIT_FILE" 'Requires=wg-quick@wg0\.service' \
    "Has Requires=wg-quick@wg0.service"

# ============================================================
# Test Group 3: Service Section
# ============================================================
echo ""
echo "=== Test Group 3: [Service] Section ==="

assert_file_contains "$UNIT_FILE" '^\[Service\]' \
    "Has [Service] section"

assert_file_contains "$UNIT_FILE" 'Type=notify' \
    "Has Type=notify for Synapse readiness signaling"

assert_file_contains "$UNIT_FILE" 'User=matrix-synapse' \
    "Has User=matrix-synapse"

assert_file_contains "$UNIT_FILE" 'Group=matrix-synapse' \
    "Has Group=matrix-synapse"

assert_file_contains "$UNIT_FILE" 'Restart=on-failure' \
    "Has Restart=on-failure"

assert_file_contains "$UNIT_FILE" 'RestartSec=10' \
    "Has RestartSec=10"

assert_file_contains "$UNIT_FILE" 'synapse\.app\.homeserver' \
    "ExecStart references synapse.app.homeserver"

assert_file_contains "$UNIT_FILE" 'ExecStartPre=.*wireguard' \
    "ExecStartPre checks WireGuard config"

assert_file_contains "$UNIT_FILE" 'StandardOutput=journal' \
    "Has StandardOutput=journal"

assert_file_contains "$UNIT_FILE" 'StandardError=journal' \
    "Has StandardError=journal"

assert_file_contains "$UNIT_FILE" 'SyslogIdentifier=matrix-synapse' \
    "Has SyslogIdentifier=matrix-synapse"

assert_file_contains "$UNIT_FILE" 'NotifyAccess=main' \
    "Has NotifyAccess=main"

assert_file_contains "$UNIT_FILE" 'WorkingDirectory=/var/lib/matrix-synapse' \
    "Has WorkingDirectory=/var/lib/matrix-synapse"

# ============================================================
# Test Group 4: Security Hardening
# ============================================================
echo ""
echo "=== Test Group 4: Security Hardening ==="

assert_file_contains "$UNIT_FILE" 'ProtectSystem=strict' \
    "Has ProtectSystem=strict"

assert_file_contains "$UNIT_FILE" 'ProtectHome=true' \
    "Has ProtectHome=true"

assert_file_contains "$UNIT_FILE" 'NoNewPrivileges=true' \
    "Has NoNewPrivileges=true"

assert_file_contains "$UNIT_FILE" 'ReadWritePaths=.*/var/lib/matrix-synapse' \
    "Has ReadWritePaths for /var/lib/matrix-synapse"

assert_file_contains "$UNIT_FILE" 'ReadWritePaths=.*/var/log/matrix-synapse' \
    "Has ReadWritePaths for /var/log/matrix-synapse"

# ============================================================
# Test Group 5: Install Section
# ============================================================
echo ""
echo "=== Test Group 5: [Install] Section ==="

assert_file_contains "$UNIT_FILE" '^\[Install\]' \
    "Has [Install] section"

assert_file_contains "$UNIT_FILE" 'WantedBy=multi-user\.target' \
    "Has WantedBy=multi-user.target"

# ============================================================
# Test Group 6: Decision Annotation
# ============================================================
echo ""
echo "=== Test Group 6: Decision Annotation ==="

assert_file_contains "$UNIT_FILE" '@decision DEC-MATRIX-005' \
    "Has @decision DEC-MATRIX-005 annotation"

assert_file_contains "$UNIT_FILE" '@title' \
    "Has @title in decision annotation"

assert_file_contains "$UNIT_FILE" '@status accepted' \
    "Has @status accepted in decision annotation"

assert_file_contains "$UNIT_FILE" '@rationale' \
    "Has @rationale in decision annotation"

# ============================================================
# Test Group 7: systemd-analyze verify (Linux only)
# ============================================================
echo ""
echo "=== Test Group 7: systemd-analyze verify ==="

if command -v systemd-analyze >/dev/null 2>&1; then
    # systemd-analyze verify checks unit file syntax
    if systemd-analyze verify "$PROJECT_ROOT/$UNIT_FILE" 2>&1; then
        pass "systemd-analyze verify passes"
    else
        # Some warnings are expected (missing user, etc.) — only fail on errors
        verify_output="$(systemd-analyze verify "$PROJECT_ROOT/$UNIT_FILE" 2>&1 || true)"
        if echo "$verify_output" | grep -qi "error"; then
            fail "systemd-analyze verify passes" "Errors found: $verify_output"
        else
            pass "systemd-analyze verify passes (warnings only)"
        fi
    fi
else
    echo "  SKIP: systemd-analyze not available (macOS or missing systemd)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
echo "============================================"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
