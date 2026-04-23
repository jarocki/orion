#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-MATRIX-COMPOSE-TEST-001
# @title Unit tests for Docker Compose Matrix test environment (W2-1)
# @status accepted
# @rationale Static file analysis validates compose structure, service
#   definitions, network isolation (172.21.0.0/24 vs mesh 172.20.0.0/24),
#   healthcheck wiring, and Makefile integration without requiring a Docker
#   daemon. Mirrors test_mesh_docker.sh / test_matrix_docker.sh patterns.
#
# Validates that docker-compose.matrix-test.yml and Makefile targets exist,
# are well-formed, and meet the quality requirements for 2-node Matrix testing
# over the WireGuard mesh. No Docker daemon required — tests are static
# file/config analysis only.
#
# Usage: bash tests/unit/test_matrix_compose.sh
#

set -euo pipefail

# --- Test framework (mirrors test_mesh_docker.sh / test_matrix_docker.sh) ---
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
# Test Group 1: File Existence
# ============================================================
echo "=== Test Group 1: File Existence ==="

assert_file_exists "docker/docker-compose.matrix-test.yml" \
    "docker-compose.matrix-test.yml exists"

# ============================================================
# Test Group 2: Service Definitions
# ============================================================
echo ""
echo "=== Test Group 2: Service Definitions ==="

COMPOSE="docker/docker-compose.matrix-test.yml"

assert_file_contains "$COMPOSE" "matrix-server:" \
    "Compose defines matrix-server service"

assert_file_contains "$COMPOSE" "matrix-client:" \
    "Compose defines matrix-client service"

# ============================================================
# Test Group 3: Server Service Configuration
# ============================================================
echo ""
echo "=== Test Group 3: Server Service Configuration ==="

assert_file_contains "$COMPOSE" "ORIONX_MATRIX_ROLE=server" \
    "Server has ORIONX_MATRIX_ROLE=server"

assert_file_contains "$COMPOSE" "ORIONX_SERVER_NAME=orionx.local" \
    "Server has ORIONX_SERVER_NAME=orionx.local"

assert_file_contains "$COMPOSE" "ORIONX_REGISTRATION_SECRET" \
    "Server has ORIONX_REGISTRATION_SECRET"

assert_file_contains "$COMPOSE" "ORIONX_MACAROON_SECRET" \
    "Server has ORIONX_MACAROON_SECRET"

assert_file_contains "$COMPOSE" "ORIONX_FORM_SECRET" \
    "Server has ORIONX_FORM_SECRET"

assert_file_contains "$COMPOSE" "8008:8008" \
    "Server exposes port 8008"

assert_file_contains "$COMPOSE" "matrix-data" \
    "Server references matrix-data volume"

assert_file_contains "$COMPOSE" "orionx-matrix-server" \
    "Server has hostname orionx-matrix-server"

# ============================================================
# Test Group 4: Client Service Configuration
# ============================================================
echo ""
echo "=== Test Group 4: Client Service Configuration ==="

assert_file_contains "$COMPOSE" "ORIONX_MATRIX_ROLE=client" \
    "Client has ORIONX_MATRIX_ROLE=client"

assert_file_contains "$COMPOSE" "orionx-matrix-client" \
    "Client has hostname orionx-matrix-client"

# Client depends on server being healthy
assert_file_contains "$COMPOSE" "depends_on:" \
    "Client has depends_on directive"

assert_file_contains "$COMPOSE" "service_healthy" \
    "Client depends on server healthcheck (service_healthy)"

# ============================================================
# Test Group 5: Shared Capabilities (both services)
# ============================================================
echo ""
echo "=== Test Group 5: Shared Capabilities ==="

assert_file_contains "$COMPOSE" "NET_ADMIN" \
    "Compose grants NET_ADMIN capability"

assert_file_contains "$COMPOSE" "SYS_MODULE" \
    "Compose grants SYS_MODULE capability"

assert_file_contains "$COMPOSE" "/dev/net/tun" \
    "Compose provides TUN device"

assert_file_contains "$COMPOSE" "net.ipv4.ip_forward" \
    "Compose enables IP forwarding"

# ============================================================
# Test Group 6: Server Healthcheck
# ============================================================
echo ""
echo "=== Test Group 6: Server Healthcheck ==="

assert_file_contains "$COMPOSE" "healthcheck:" \
    "Server has healthcheck definition"

assert_file_contains "$COMPOSE" "_matrix/client/versions" \
    "Healthcheck tests Synapse versions endpoint"

assert_file_contains "$COMPOSE" "interval:" \
    "Healthcheck has interval"

assert_file_contains "$COMPOSE" "timeout:" \
    "Healthcheck has timeout"

assert_file_contains "$COMPOSE" "retries:" \
    "Healthcheck has retries"

assert_file_contains "$COMPOSE" "start_period:" \
    "Healthcheck has start_period"

# ============================================================
# Test Group 7: Network Configuration
# ============================================================
echo ""
echo "=== Test Group 7: Network Configuration ==="

assert_file_contains "$COMPOSE" "matrix-test-net" \
    "Compose defines matrix-test-net network"

assert_file_contains "$COMPOSE" "172.21.0.0/24" \
    "Network uses 172.21.0.0/24 subnet (avoids 172.20.0.0/24 mesh conflict)"

assert_file_contains "$COMPOSE" "172.21.0.2" \
    "Server gets IP 172.21.0.2"

assert_file_contains "$COMPOSE" "172.21.0.3" \
    "Client gets IP 172.21.0.3"

# Verify no service uses 172.20.0.x IPs (comments may reference it for context)
if grep -E '^\s+ipv4_address:.*172\.20\.0' "$PROJECT_ROOT/$COMPOSE" >/dev/null 2>&1; then
    fail "No service uses 172.20.0.x IPs (reserved for mesh-test)" \
        "Found 172.20.0.x in an ipv4_address assignment"
else
    pass "No service uses 172.20.0.x IPs (reserved for mesh-test)"
fi

# ============================================================
# Test Group 8: Build Configuration
# ============================================================
echo ""
echo "=== Test Group 8: Build Configuration ==="

assert_file_contains "$COMPOSE" "Dockerfile.matrix-node" \
    "Compose references Dockerfile.matrix-node"

assert_file_contains "$COMPOSE" "context:.*\.\." \
    "Build context is parent directory (..)"

# ============================================================
# Test Group 9: Volume Definition
# ============================================================
echo ""
echo "=== Test Group 9: Volume Definition ==="

# Top-level volumes section must define matrix-data
assert_file_contains "$COMPOSE" "^volumes:" \
    "Compose has top-level volumes section"

assert_file_contains "$COMPOSE" "matrix-data:" \
    "Compose defines matrix-data volume"

# ============================================================
# Test Group 10: Makefile Integration
# ============================================================
echo ""
echo "=== Test Group 10: Makefile Integration ==="

assert_file_contains "Makefile" "test-matrix:" \
    "Makefile has test-matrix target"

assert_file_contains "Makefile" "docker-build-matrix:" \
    "Makefile has docker-build-matrix target"

assert_file_contains "Makefile" "docker-compose.matrix-test.yml" \
    "Makefile references matrix compose file"

assert_file_contains "Makefile" "\.PHONY:.*test-matrix" \
    "test-matrix is declared as .PHONY"

assert_file_contains "Makefile" "\.PHONY:.*docker-build-matrix" \
    "docker-build-matrix is declared as .PHONY"

assert_file_contains "Makefile" "## .*[Mm]atrix" \
    "Matrix targets have help comments"

# ============================================================
# Test Group 11: YAML Syntax Validation
# ============================================================
echo ""
echo "=== Test Group 11: YAML Syntax Validation ==="

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
        valid) pass "docker-compose.matrix-test.yml is valid YAML" ;;
        skip)  echo "  SKIP: pyyaml not installed — YAML syntax not validated" ;;
        *)     fail "docker-compose.matrix-test.yml is valid YAML" "${yaml_result}" ;;
    esac
else
    echo "  SKIP: python3 not available for YAML validation"
fi

# No tabs in YAML
if ! grep -P '\t' "$PROJECT_ROOT/$COMPOSE" >/dev/null 2>&1; then
    pass "docker-compose.matrix-test.yml uses spaces (no tabs)"
else
    fail "docker-compose.matrix-test.yml uses spaces (no tabs)" "Found tab characters"
fi

# ============================================================
# Test Group 12: No modification of existing Docker/Matrix files
# ============================================================
echo ""
echo "=== Test Group 12: Existing Files Untouched ==="

if command -v git >/dev/null 2>&1; then
    # Verify W1-1 files not modified
    w1_changes="$(git -C "$PROJECT_ROOT" diff --name-only -- \
        docker/Dockerfile.matrix-node \
        docker/matrix-entrypoint.sh \
        docker/matrix/homeserver.yaml \
        docker/matrix/log.config \
        2>/dev/null || echo "")"
    if [[ -z "$w1_changes" ]]; then
        pass "No modifications to W1-1 Docker/Matrix files"
    else
        fail "No modifications to W1-1 Docker/Matrix files" \
            "Modified files: $w1_changes"
    fi

    # Verify existing mesh files not modified
    mesh_changes="$(git -C "$PROJECT_ROOT" diff --name-only -- \
        docker/Dockerfile.mesh-node \
        docker/mesh-entrypoint.sh \
        docker/docker-compose.mesh-test.yml \
        2>/dev/null || echo "")"
    if [[ -z "$mesh_changes" ]]; then
        pass "No modifications to existing mesh Docker files"
    else
        fail "No modifications to existing mesh Docker files" \
            "Modified files: $mesh_changes"
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
