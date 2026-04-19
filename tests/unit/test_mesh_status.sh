#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC1091
#
# Orion-X Phoenix Edition — Unit Tests for mesh formatting functions
#
# Tests the formatting helper functions added to mesh-lib.sh:
# mesh_format_duration, mesh_format_bytes, mesh_format_handshake.
#
# @decision DEC-MESH-TEST-002
# @title Unit tests for mesh formatting helpers
# @status accepted
# @rationale Each formatting function is a pure function (no side effects,
#   no external dependencies). Testing boundary conditions (0, exact thresholds,
#   overflow into next unit) ensures the status and peers output is correct.
#   The handshake formatter depends on wall-clock time, so we test that relative
#   output contains "ago" rather than matching an exact string.
#
# Usage:  bash tests/unit/test_mesh_status.sh
#   (from worktree root)

set -euo pipefail

# Source mesh-lib for formatting functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export MESH_LOG_FILE="/dev/null"
export MESH_STATE_FILE="/tmp/test-mesh-state-$$"
source "$SCRIPT_DIR/scripts/mesh/mesh-lib.sh"

PASS=0; FAIL=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"; (( PASS++ )) || true
    else
        echo "  FAIL: $desc (expected='$expected', got='$actual')"; (( FAIL++ )) || true
    fi
}

echo "=== mesh formatting Unit Tests ==="
echo
echo "--- mesh_format_duration ---"
assert_eq "0 seconds" "0s" "$(mesh_format_duration 0)"
assert_eq "45 seconds" "45s" "$(mesh_format_duration 45)"
assert_eq "59 seconds (boundary)" "59s" "$(mesh_format_duration 59)"
assert_eq "60 seconds (boundary)" "1m 0s" "$(mesh_format_duration 60)"
assert_eq "90 seconds" "1m 30s" "$(mesh_format_duration 90)"
assert_eq "3599 seconds (boundary)" "59m 59s" "$(mesh_format_duration 3599)"
assert_eq "3600 seconds (boundary)" "1h 0m" "$(mesh_format_duration 3600)"
assert_eq "3661 seconds" "1h 1m" "$(mesh_format_duration 3661)"
assert_eq "86399 seconds (boundary)" "23h 59m" "$(mesh_format_duration 86399)"
assert_eq "86400 seconds (boundary)" "1d 0h" "$(mesh_format_duration 86400)"
assert_eq "90000 seconds" "1d 1h" "$(mesh_format_duration 90000)"

echo
echo "--- mesh_format_bytes ---"
assert_eq "0 bytes" "0B" "$(mesh_format_bytes 0)"
assert_eq "500 bytes" "500B" "$(mesh_format_bytes 500)"
assert_eq "1023 bytes (boundary)" "1023B" "$(mesh_format_bytes 1023)"
assert_eq "1024 bytes" "1.0K" "$(mesh_format_bytes 1024)"
assert_eq "1536 bytes" "1.5K" "$(mesh_format_bytes 1536)"
assert_eq "1048575 bytes (boundary)" "1023.9K" "$(mesh_format_bytes 1048575)"
assert_eq "1048576 bytes" "1.0M" "$(mesh_format_bytes 1048576)"
assert_eq "1073741824 bytes" "1.0G" "$(mesh_format_bytes 1073741824)"

echo
echo "--- mesh_format_handshake ---"
assert_eq "zero timestamp" "never" "$(mesh_format_handshake 0)"
assert_eq "empty timestamp" "never" "$(mesh_format_handshake "")"
# Test with a recent timestamp
now=$(date +%s)
recent=$((now - 30))
result=$(mesh_format_handshake "$recent")
assert_eq "recent handshake contains 'ago'" "yes" "$([[ "$result" == *ago* ]] && echo yes || echo no)"
# Test with a timestamp 2 hours ago
two_hours_ago=$((now - 7200))
result2=$(mesh_format_handshake "$two_hours_ago")
assert_eq "2h-ago handshake contains 'ago'" "yes" "$([[ "$result2" == *ago* ]] && echo yes || echo no)"
assert_eq "2h-ago handshake starts with 2h" "yes" "$([[ "$result2" == 2h* ]] && echo yes || echo no)"

echo
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed (total: $((PASS + FAIL)))"
echo "==========================================="

rm -f "$MESH_STATE_FILE"
[[ "$FAIL" -eq 0 ]] || exit 1
