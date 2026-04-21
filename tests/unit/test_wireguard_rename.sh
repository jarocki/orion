#!/usr/bin/env bash
# shellcheck shell=bash
#
# Tests for W-009: setup-vpn.sh → setup-wireguard.sh rename and modernization
#
# Verifies:
#   1. setup-wireguard.sh exists and is executable
#   2. setup-vpn.sh no longer exists
#   3. setup-wireguard.sh passes ShellCheck
#   4. Modernization markers are present (set -euo pipefail, shellcheck directive, etc.)
#   5. Makefile SHELL_SCRIPTS includes scripts/mesh/*.sh
#   6. Dockerfile references setup-wireguard.sh, not setup-vpn.sh
#   7. lint.yml is configured for mesh scripts (via make lint)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
TESTS=()

pass() {
    PASS=$((PASS + 1))
    TESTS+=("PASS: $1")
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TESTS+=("FAIL: $1")
    echo "  FAIL: $1"
}

echo "=== W-009 Rename & Modernization Tests ==="
echo ""

# --- Test 1: setup-wireguard.sh exists ---
if [ -f "$REPO_ROOT/scripts/setup-wireguard.sh" ]; then
    pass "setup-wireguard.sh exists"
else
    fail "setup-wireguard.sh does not exist"
fi

# --- Test 2: setup-wireguard.sh is executable ---
if [ -x "$REPO_ROOT/scripts/setup-wireguard.sh" ]; then
    pass "setup-wireguard.sh is executable"
else
    fail "setup-wireguard.sh is not executable"
fi

# --- Test 3: setup-vpn.sh no longer exists ---
if [ ! -f "$REPO_ROOT/scripts/setup-vpn.sh" ]; then
    pass "setup-vpn.sh no longer exists (renamed)"
else
    fail "setup-vpn.sh still exists (should have been renamed)"
fi

# --- Test 4: Shebang is #!/usr/bin/env bash ---
if head -1 "$REPO_ROOT/scripts/setup-wireguard.sh" | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is not #!/usr/bin/env bash"
fi

# --- Test 5: Has shellcheck directive ---
if grep -q '# shellcheck shell=bash' "$REPO_ROOT/scripts/setup-wireguard.sh"; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Missing shellcheck shell=bash directive"
fi

# --- Test 6: Has set -euo pipefail ---
if grep -q 'set -euo pipefail' "$REPO_ROOT/scripts/setup-wireguard.sh"; then
    pass "Has set -euo pipefail"
else
    fail "Missing set -euo pipefail"
fi

# --- Test 7: Version updated from v1.5.5 ---
if ! grep -q 'v1\.5\.5' "$REPO_ROOT/scripts/setup-wireguard.sh"; then
    pass "No v1.5.5 references remain"
else
    fail "Still contains v1.5.5 references"
fi

# --- Test 8: Contains @decision annotation ---
if grep -q '@decision DEC-MESH-STANDALONE-001' "$REPO_ROOT/scripts/setup-wireguard.sh"; then
    pass "Contains @decision DEC-MESH-STANDALONE-001 annotation"
else
    fail "Missing @decision DEC-MESH-STANDALONE-001 annotation"
fi

# --- Test 9: Contains note pointing to orionx-mesh ---
if grep -q 'orionx-mesh' "$REPO_ROOT/scripts/setup-wireguard.sh"; then
    pass "Contains reference to orionx-mesh for mesh networking"
else
    fail "Missing reference to orionx-mesh"
fi

# --- Test 10: ShellCheck passes (if shellcheck is available) ---
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$REPO_ROOT/scripts/setup-wireguard.sh" 2>&1; then
        pass "ShellCheck passes on setup-wireguard.sh"
    else
        fail "ShellCheck reports errors on setup-wireguard.sh"
    fi
else
    echo "  SKIP: ShellCheck not installed, skipping lint test"
fi

# --- Test 11: Makefile uses find for SHELL_SCRIPTS (catches subdirectories) ---
if grep -q 'find scripts' "$REPO_ROOT/Makefile"; then
    pass "Makefile uses find to discover shell scripts (includes subdirs)"
else
    fail "Makefile does not use find for SHELL_SCRIPTS"
fi

# --- Test 12: Makefile does not reference setup-vpn.sh ---
if ! grep -q 'setup-vpn' "$REPO_ROOT/Makefile"; then
    pass "Makefile has no stale setup-vpn.sh references"
else
    fail "Makefile still references setup-vpn.sh"
fi

# --- Test 13: Dockerfile references setup-wireguard.sh ---
if grep -q 'setup-wireguard.sh' "$REPO_ROOT/Dockerfile"; then
    pass "Dockerfile references setup-wireguard.sh"
else
    fail "Dockerfile still references setup-vpn.sh or missing setup-wireguard.sh"
fi

# --- Test 14: Dockerfile does not reference setup-vpn.sh in executable lines ---
# (comments noting the rename are acceptable)
if ! grep -v '^#' "$REPO_ROOT/Dockerfile" | grep -q 'setup-vpn\.sh'; then
    pass "Dockerfile has no stale setup-vpn.sh references (excluding comments)"
else
    fail "Dockerfile still references setup-vpn.sh in non-comment lines"
fi

# --- Test 15: Dockerfile includes orionx-mesh symlink ---
if grep -q 'orionx-mesh' "$REPO_ROOT/Dockerfile"; then
    pass "Dockerfile includes orionx-mesh"
else
    fail "Dockerfile missing orionx-mesh reference"
fi

# --- Test 16: Dockerfile copies mesh scripts ---
if grep -q 'scripts/mesh' "$REPO_ROOT/Dockerfile" || grep -q 'COPY scripts/' "$REPO_ROOT/Dockerfile"; then
    pass "Dockerfile includes mesh scripts (via scripts/ copy or explicit)"
else
    fail "Dockerfile missing mesh scripts"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for t in "${TESTS[@]}"; do
        if [[ "$t" == FAIL* ]]; then
            echo "  - $t"
        fi
    done
    exit 1
fi
exit 0
