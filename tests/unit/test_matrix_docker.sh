#!/usr/bin/env bash
# shellcheck shell=bash
#
# Test suite for Matrix Docker infrastructure (W1-1)
#
# Validates that all Matrix Docker infrastructure files exist, are well-formed,
# and meet the quality requirements for Synapse homeserver testing.
# No Docker daemon required — tests are static file/config analysis only.
#
# Usage: bash tests/unit/test_matrix_docker.sh
#

set -euo pipefail

# --- Test framework (mirrors test_mesh_docker.sh pattern) ---
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
# Test Group 1: File Existence
# ============================================================
echo "=== Test Group 1: File Existence ==="

assert_file_exists "docker/Dockerfile.matrix-node" \
    "Dockerfile.matrix-node exists"

assert_file_exists "docker/matrix/homeserver.yaml" \
    "homeserver.yaml template exists"

assert_file_exists "docker/matrix/log.config" \
    "log.config exists"

assert_file_exists "docker/matrix-entrypoint.sh" \
    "matrix-entrypoint.sh exists"

# ============================================================
# Test Group 2: homeserver.yaml template structure
# ============================================================
echo ""
echo "=== Test Group 2: homeserver.yaml Template ==="

HS_YAML="docker/matrix/homeserver.yaml"

assert_file_contains "$HS_YAML" "ORIONX_SERVER_NAME" \
    "homeserver.yaml has server_name placeholder"

assert_file_contains "$HS_YAML" "ORIONX_REGISTRATION_SECRET" \
    "homeserver.yaml has registration_secret placeholder"

assert_file_contains "$HS_YAML" "ORIONX_MACAROON_SECRET" \
    "homeserver.yaml has macaroon_secret placeholder"

assert_file_contains "$HS_YAML" "ORIONX_FORM_SECRET" \
    "homeserver.yaml has form_secret placeholder"

assert_file_contains "$HS_YAML" "sqlite3" \
    "homeserver.yaml uses SQLite database"

assert_file_not_contains "$HS_YAML" "psycopg2|postgres" \
    "homeserver.yaml does NOT use PostgreSQL"

assert_file_contains "$HS_YAML" "enable_registration: true" \
    "homeserver.yaml has enable_registration: true"

assert_file_contains "$HS_YAML" "report_stats: false" \
    "homeserver.yaml has report_stats: false"

assert_file_contains "$HS_YAML" "trusted_key_servers: \[\]" \
    "homeserver.yaml has empty trusted_key_servers"

assert_file_contains "$HS_YAML" "port: 8008" \
    "homeserver.yaml listens on port 8008"

assert_file_contains "$HS_YAML" "signing_key_path" \
    "homeserver.yaml specifies signing key path"

assert_file_contains "$HS_YAML" "media_store_path" \
    "homeserver.yaml specifies media store path"

assert_file_contains "$HS_YAML" "suppress_key_server_warning: true" \
    "homeserver.yaml suppresses key server warning"

assert_file_contains "$HS_YAML" "enable_registration_without_verification: true" \
    "homeserver.yaml allows registration without verification"

# ============================================================
# Test Group 3: log.config structure
# ============================================================
echo ""
echo "=== Test Group 3: log.config ==="

LOG_CFG="docker/matrix/log.config"

assert_file_contains "$LOG_CFG" "version: 1" \
    "log.config has version: 1"

assert_file_contains "$LOG_CFG" "formatters:" \
    "log.config defines formatters"

assert_file_contains "$LOG_CFG" "handlers:" \
    "log.config defines handlers"

assert_file_contains "$LOG_CFG" "console:" \
    "log.config defines console handler"

assert_file_contains "$LOG_CFG" "logging.StreamHandler" \
    "log.config uses StreamHandler for console"

assert_file_contains "$LOG_CFG" "synapse.storage.SQL" \
    "log.config configures synapse.storage.SQL logger"

assert_file_contains "$LOG_CFG" "level: WARNING" \
    "log.config sets SQL logger to WARNING"

assert_file_contains "$LOG_CFG" "level: INFO" \
    "log.config sets root logger to INFO"

assert_file_contains "$LOG_CFG" "disable_existing_loggers: false" \
    "log.config does not disable existing loggers"

# Validate YAML-ish structure (basic check: valid indentation, no tabs)
if ! grep -P '\t' "$PROJECT_ROOT/$LOG_CFG" >/dev/null 2>&1; then
    pass "log.config uses spaces (no tabs)"
else
    fail "log.config uses spaces (no tabs)" "Found tab characters"
fi

# ============================================================
# Test Group 4: Dockerfile.matrix-node structure
# ============================================================
echo ""
echo "=== Test Group 4: Dockerfile.matrix-node Structure ==="

DOCKERFILE="docker/Dockerfile.matrix-node"

assert_file_contains "$DOCKERFILE" "^FROM debian:bullseye-slim" \
    "Dockerfile uses debian:bullseye-slim base"

assert_file_contains "$DOCKERFILE" "wireguard-tools" \
    "Dockerfile installs wireguard-tools"

assert_file_contains "$DOCKERFILE" "python3" \
    "Dockerfile installs python3"

assert_file_contains "$DOCKERFILE" "matrix-synapse|synapse" \
    "Dockerfile installs Synapse (repo or pip)"

assert_file_contains "$DOCKERFILE" "COPY scripts/mesh/" \
    "Dockerfile copies mesh scripts"

assert_file_contains "$DOCKERFILE" "COPY docker/matrix/homeserver.yaml" \
    "Dockerfile copies homeserver.yaml template"

assert_file_contains "$DOCKERFILE" "COPY docker/matrix/log.config" \
    "Dockerfile copies log.config"

assert_file_contains "$DOCKERFILE" "COPY docker/matrix-entrypoint.sh" \
    "Dockerfile copies matrix-entrypoint.sh"

assert_file_contains "$DOCKERFILE" "EXPOSE 8008" \
    "Dockerfile exposes port 8008"

assert_file_contains "$DOCKERFILE" "VOLUME /data" \
    "Dockerfile declares /data volume"

assert_file_contains "$DOCKERFILE" "ENTRYPOINT" \
    "Dockerfile has ENTRYPOINT"

assert_file_contains "$DOCKERFILE" "matrix-entrypoint.sh" \
    "Dockerfile references matrix-entrypoint.sh"

assert_file_contains "$DOCKERFILE" "@decision DEC-MATRIX-002" \
    "Dockerfile has DEC-MATRIX-002 decision annotation"

assert_file_contains "$DOCKERFILE" "orionx-mesh" \
    "Dockerfile references orionx-mesh CLI"

assert_file_contains "$DOCKERFILE" "rm -rf /var/lib/apt/lists" \
    "Dockerfile cleans apt lists"

assert_file_contains "$DOCKERFILE" "mkdir -p" \
    "Dockerfile creates required directories"

# ============================================================
# Test Group 5: matrix-entrypoint.sh quality
# ============================================================
echo ""
echo "=== Test Group 5: matrix-entrypoint.sh Quality ==="

ENTRYPOINT="docker/matrix-entrypoint.sh"

assert_file_executable "$ENTRYPOINT" \
    "matrix-entrypoint.sh is executable"

assert_file_contains "$ENTRYPOINT" "^#!/usr/bin/env bash" \
    "matrix-entrypoint.sh has proper shebang"

assert_file_contains "$ENTRYPOINT" "set -euo pipefail" \
    "matrix-entrypoint.sh uses strict mode"

# Role handling
assert_file_contains "$ENTRYPOINT" "ORIONX_MATRIX_ROLE" \
    "matrix-entrypoint.sh reads ORIONX_MATRIX_ROLE env"

assert_file_contains "$ENTRYPOINT" 'server' \
    "matrix-entrypoint.sh handles server role"

assert_file_contains "$ENTRYPOINT" 'client' \
    "matrix-entrypoint.sh handles client role"

# Mesh integration
assert_file_contains "$ENTRYPOINT" "orionx-mesh join" \
    "matrix-entrypoint.sh joins mesh"

# Synapse startup
assert_file_contains "$ENTRYPOINT" "synapse.app.homeserver" \
    "matrix-entrypoint.sh starts Synapse via python3 module"

# Config template substitution
assert_file_contains "$ENTRYPOINT" "sed" \
    "matrix-entrypoint.sh substitutes placeholders via sed"

assert_file_contains "$ENTRYPOINT" "ORIONX_SERVER_NAME" \
    "matrix-entrypoint.sh substitutes server name"

assert_file_contains "$ENTRYPOINT" "ORIONX_REGISTRATION_SECRET" \
    "matrix-entrypoint.sh substitutes registration secret"

assert_file_contains "$ENTRYPOINT" "ORIONX_MACAROON_SECRET" \
    "matrix-entrypoint.sh substitutes macaroon secret"

assert_file_contains "$ENTRYPOINT" "ORIONX_FORM_SECRET" \
    "matrix-entrypoint.sh substitutes form secret"

# Secret generation fallback
assert_file_contains "$ENTRYPOINT" "/dev/urandom" \
    "matrix-entrypoint.sh generates secrets from /dev/urandom"

# Signing key generation
assert_file_contains "$ENTRYPOINT" "generate-keys|signing.key" \
    "matrix-entrypoint.sh handles signing key generation"

# Decision annotation
assert_file_contains "$ENTRYPOINT" "@decision DEC-MATRIX-003" \
    "matrix-entrypoint.sh has DEC-MATRIX-003 decision annotation"

# ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$PROJECT_ROOT/$ENTRYPOINT" 2>/dev/null; then
        pass "matrix-entrypoint.sh passes ShellCheck"
    else
        fail "matrix-entrypoint.sh passes ShellCheck" \
            "ShellCheck reported errors"
    fi
else
    echo "  SKIP: ShellCheck not available"
fi

# ============================================================
# Test Group 6: No modification of existing files
# ============================================================
echo ""
echo "=== Test Group 6: Existing Files Untouched ==="

# Verify mesh scripts were not modified
if command -v git >/dev/null 2>&1; then
    local_changes="$(git -C "$PROJECT_ROOT" diff --name-only -- scripts/mesh/ 2>/dev/null || echo "")"
    if [[ -z "$local_changes" ]]; then
        pass "No modifications to scripts/mesh/"
    else
        fail "No modifications to scripts/mesh/" \
            "Modified files: $local_changes"
    fi

    # Verify existing Docker files not modified
    mesh_docker_changes="$(git -C "$PROJECT_ROOT" diff --name-only -- docker/Dockerfile.mesh-node docker/mesh-entrypoint.sh docker/docker-compose.mesh-test.yml 2>/dev/null || echo "")"
    if [[ -z "$mesh_docker_changes" ]]; then
        pass "No modifications to existing Phase 3 Docker files"
    else
        fail "No modifications to existing Phase 3 Docker files" \
            "Modified files: $mesh_docker_changes"
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
