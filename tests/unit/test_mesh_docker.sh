#!/usr/bin/env bash
# shellcheck shell=bash
#
# Test suite for Docker mesh test environment (W-007)
#
# Validates that all Docker infrastructure files exist, are well-formed,
# and meet the quality requirements for 3-node mesh testing.
#
# Usage: bash tests/unit/test_mesh_docker.sh
#

set -euo pipefail

# --- Test framework ---
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

assert_file_executable() {
    local file="$1"
    local desc="${2:-$file is executable}"
    if [[ -x "$PROJECT_ROOT/$file" ]]; then
        pass "$desc"
    else
        fail "$desc" "File not executable: $file"
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

assert_file_not_contains() {
    local file="$1"
    local pattern="$2"
    local desc="${3:-$file does not contain '$pattern'}"
    if ! grep -qE "$pattern" "$PROJECT_ROOT/$file" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc" "Unexpected pattern found in $file: $pattern"
    fi
}

# ============================================================
# Test Group 1: File existence
# ============================================================
echo "=== Test Group 1: File Existence ==="

assert_file_exists "docker/Dockerfile.mesh-node" "Dockerfile.mesh-node exists"
assert_file_exists "docker/mesh-entrypoint.sh" "mesh-entrypoint.sh exists"
assert_file_exists "docker/docker-compose.mesh-test.yml" "docker-compose.mesh-test.yml exists"

# ============================================================
# Test Group 2: Dockerfile.mesh-node structure
# ============================================================
echo ""
echo "=== Test Group 2: Dockerfile.mesh-node Structure ==="

DOCKERFILE="docker/Dockerfile.mesh-node"

assert_file_contains "$DOCKERFILE" "^FROM debian:bullseye-slim" \
    "Dockerfile uses debian:bullseye-slim base"

assert_file_contains "$DOCKERFILE" "wireguard-tools" \
    "Dockerfile installs wireguard-tools"

assert_file_contains "$DOCKERFILE" "socat" \
    "Dockerfile installs socat"

assert_file_contains "$DOCKERFILE" "jq" \
    "Dockerfile installs jq"

assert_file_contains "$DOCKERFILE" "iputils-ping" \
    "Dockerfile installs iputils-ping"

assert_file_contains "$DOCKERFILE" "iproute2" \
    "Dockerfile installs iproute2"

assert_file_contains "$DOCKERFILE" "procps" \
    "Dockerfile installs procps"

assert_file_contains "$DOCKERFILE" "rm -rf /var/lib/apt/lists" \
    "Dockerfile cleans apt lists"

assert_file_contains "$DOCKERFILE" "COPY scripts/mesh/" \
    "Dockerfile copies mesh scripts"

assert_file_contains "$DOCKERFILE" "orionx-mesh" \
    "Dockerfile references orionx-mesh CLI"

assert_file_contains "$DOCKERFILE" "ENTRYPOINT" \
    "Dockerfile has ENTRYPOINT"

assert_file_contains "$DOCKERFILE" "mesh-entrypoint.sh" \
    "Dockerfile references entrypoint script"

assert_file_contains "$DOCKERFILE" "@decision DEC-MESH-003" \
    "Dockerfile has DEC-MESH-003 decision annotation"

assert_file_contains "$DOCKERFILE" "mkdir -p" \
    "Dockerfile creates required directories"

assert_file_contains "$DOCKERFILE" "/opt/orionx/scripts/mesh" \
    "Dockerfile creates mesh scripts directory"

assert_file_contains "$DOCKERFILE" "/var/log/orionx" \
    "Dockerfile creates log directory"

assert_file_contains "$DOCKERFILE" "/etc/wireguard" \
    "Dockerfile creates wireguard config directory"

# ============================================================
# Test Group 3: mesh-entrypoint.sh quality
# ============================================================
echo ""
echo "=== Test Group 3: mesh-entrypoint.sh Quality ==="

ENTRYPOINT="docker/mesh-entrypoint.sh"

assert_file_executable "$ENTRYPOINT" "mesh-entrypoint.sh is executable"

assert_file_contains "$ENTRYPOINT" "^#!/usr/bin/env bash" \
    "mesh-entrypoint.sh has proper shebang"

assert_file_contains "$ENTRYPOINT" "set -euo pipefail" \
    "mesh-entrypoint.sh uses strict mode"

assert_file_contains "$ENTRYPOINT" "orionx-mesh join" \
    "mesh-entrypoint.sh joins the mesh"

assert_file_contains "$ENTRYPOINT" "orionx-mesh status" \
    "mesh-entrypoint.sh shows status"

assert_file_contains "$ENTRYPOINT" "sleep" \
    "mesh-entrypoint.sh has sleep for health loop"

assert_file_contains "$ENTRYPOINT" "hostname" \
    "mesh-entrypoint.sh logs hostname"

# ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$PROJECT_ROOT/$ENTRYPOINT" 2>/dev/null; then
        pass "mesh-entrypoint.sh passes ShellCheck"
    else
        fail "mesh-entrypoint.sh passes ShellCheck" \
            "ShellCheck reported errors"
    fi
else
    echo "  SKIP: ShellCheck not available"
fi

# ============================================================
# Test Group 4: docker-compose.mesh-test.yml structure
# ============================================================
echo ""
echo "=== Test Group 4: docker-compose.mesh-test.yml Structure ==="

COMPOSE="docker/docker-compose.mesh-test.yml"

assert_file_contains "$COMPOSE" "node-1:" \
    "Compose defines node-1 service"

assert_file_contains "$COMPOSE" "node-2:" \
    "Compose defines node-2 service"

assert_file_contains "$COMPOSE" "node-3:" \
    "Compose defines node-3 service"

assert_file_contains "$COMPOSE" "orionx-node-1" \
    "Compose sets hostname for node-1"

assert_file_contains "$COMPOSE" "orionx-node-2" \
    "Compose sets hostname for node-2"

assert_file_contains "$COMPOSE" "orionx-node-3" \
    "Compose sets hostname for node-3"

assert_file_contains "$COMPOSE" "NET_ADMIN" \
    "Compose grants NET_ADMIN capability"

assert_file_contains "$COMPOSE" "SYS_MODULE" \
    "Compose grants SYS_MODULE capability"

assert_file_contains "$COMPOSE" "/dev/net/tun" \
    "Compose provides TUN device"

assert_file_contains "$COMPOSE" "net.ipv4.ip_forward" \
    "Compose enables IP forwarding"

assert_file_contains "$COMPOSE" "172.20.0.2" \
    "Compose assigns IP 172.20.0.2 to node-1"

assert_file_contains "$COMPOSE" "172.20.0.3" \
    "Compose assigns IP 172.20.0.3 to node-2"

assert_file_contains "$COMPOSE" "172.20.0.4" \
    "Compose assigns IP 172.20.0.4 to node-3"

assert_file_contains "$COMPOSE" "172.20.0.0/24" \
    "Compose uses 172.20.0.0/24 subnet"

assert_file_contains "$COMPOSE" "mesh-test-net" \
    "Compose defines mesh-test-net network"

assert_file_contains "$COMPOSE" "Dockerfile.mesh-node" \
    "Compose references correct Dockerfile"

# Validate YAML syntax (use python if available, with pyyaml)
if command -v python3 >/dev/null 2>&1; then
    yaml_result="$(python3 -c "
import sys
try:
    import yaml
    with open('$PROJECT_ROOT/$COMPOSE') as f:
        yaml.safe_load(f)
    print('valid')
except ImportError:
    print('skip')
except Exception as e:
    print('fail: ' + str(e))
" 2>/dev/null || echo "skip")"
    case "$yaml_result" in
        valid) pass "docker-compose.mesh-test.yml is valid YAML" ;;
        skip)  echo "  SKIP: pyyaml not installed — YAML syntax not validated" ;;
        *)     fail "docker-compose.mesh-test.yml is valid YAML" "${yaml_result}" ;;
    esac
else
    echo "  SKIP: python3 not available for YAML validation"
fi

# ============================================================
# Test Group 5: Makefile integration
# ============================================================
echo ""
echo "=== Test Group 5: Makefile Integration ==="

assert_file_contains "Makefile" "test-mesh:" \
    "Makefile has test-mesh target"

assert_file_contains "Makefile" "docker-compose.mesh-test.yml" \
    "Makefile references mesh compose file"

assert_file_contains "Makefile" "docker compose" \
    "Makefile uses 'docker compose' (v2 syntax)"

assert_file_contains "Makefile" "\.PHONY:.*test-mesh" \
    "test-mesh is declared as .PHONY"

assert_file_contains "Makefile" "## .*mesh" \
    "test-mesh has help comment"

# ============================================================
# Test Group 6: No modification of existing mesh scripts
# ============================================================
echo ""
echo "=== Test Group 6: Existing Scripts Untouched ==="

# Verify mesh scripts were not modified (check git status)
if command -v git >/dev/null 2>&1; then
    local_changes="$(git -C "$PROJECT_ROOT" diff --name-only -- scripts/mesh/ 2>/dev/null || echo "")"
    if [[ -z "$local_changes" ]]; then
        pass "No modifications to scripts/mesh/"
    else
        fail "No modifications to scripts/mesh/" \
            "Modified files: $local_changes"
    fi
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
