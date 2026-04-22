#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Matrix Node — Container Entrypoint
#
# Joins the WireGuard mesh on startup, then starts Synapse homeserver
# (server role) or stays alive for testing (client role).
#
# Supports two roles via ORIONX_MATRIX_ROLE env var:
#   server — Substitutes config placeholders, generates signing key,
#            starts Synapse in foreground.
#   client — Joins mesh, then waits (for API testing against server).
#
# @decision DEC-MATRIX-003
# @title Pre-built homeserver.yaml template with placeholder substitution
# @status accepted
# @rationale Reproducible, fast container startup, inspectable in code review.
#   Config template lives in docker/matrix/homeserver.yaml with ORIONX_*
#   placeholders. Secrets are generated at startup from /dev/urandom if not
#   provided via environment variables. Signing key generated on first run
#   via synapse --generate-keys. Server role uses exec to replace shell with
#   Synapse process (proper signal handling, PID 1 reaping).
#

set -euo pipefail

ROLE="${ORIONX_MATRIX_ROLE:-server}"
SERVER_NAME="${ORIONX_SERVER_NAME:-orionx.local}"

echo "[matrix-entrypoint] Role: $ROLE"
echo "[matrix-entrypoint] Server name: $SERVER_NAME"

# Join WireGuard mesh first
echo "[matrix-entrypoint] Joining mesh..."
sleep 2
orionx-mesh join || {
    echo "[matrix-entrypoint] WARNING: mesh join failed, retrying..."
    sleep 3
    orionx-mesh join || echo "[matrix-entrypoint] ERROR: mesh join failed"
}

if [[ "$ROLE" == "server" ]]; then
    echo "[matrix-entrypoint] Starting Synapse homeserver..."

    # Generate secrets if not provided via environment
    REG_SECRET="${ORIONX_REGISTRATION_SECRET:-$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)}"
    MACAROON="${ORIONX_MACAROON_SECRET:-$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)}"
    FORM="${ORIONX_FORM_SECRET:-$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)}"

    # Substitute placeholders in config template
    if [[ ! -f /data/homeserver.yaml ]] || [[ -f /data/homeserver.yaml.template ]]; then
        sed \
            -e "s|ORIONX_SERVER_NAME|$SERVER_NAME|g" \
            -e "s|ORIONX_REGISTRATION_SECRET|$REG_SECRET|g" \
            -e "s|ORIONX_MACAROON_SECRET|$MACAROON|g" \
            -e "s|ORIONX_FORM_SECRET|$FORM|g" \
            /data/homeserver.yaml.template > /data/homeserver.yaml
    fi

    # Generate signing key if missing
    if [[ ! -f /data/signing.key ]]; then
        python3 -m synapse.app.homeserver \
            --config-path /data/homeserver.yaml \
            --generate-keys
    fi

    # Start Synapse in foreground (exec replaces shell for proper PID 1)
    exec python3 -m synapse.app.homeserver \
        --config-path /data/homeserver.yaml
else
    echo "[matrix-entrypoint] Client mode — no Synapse server."
    echo "[matrix-entrypoint] Waiting for mesh + server availability..."

    # Keep alive for testing
    while true; do
        sleep 60
        orionx-mesh status 2>/dev/null || true
    done
fi
