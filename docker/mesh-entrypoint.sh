#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Mesh Node — Container Entrypoint
#
# Joins the WireGuard mesh on startup and runs periodic health checks.
# The host machine must have the WireGuard kernel module loaded
# (modprobe wireguard) because wireguard-go is not available in
# the bullseye-slim image.
#
# @decision DEC-MESH-005
# @title Retry-and-survive entrypoint for mesh test containers
# @status accepted
# @rationale Mesh join may fail if peers aren't ready yet (race condition
#   during parallel container startup). Retry once after 3s covers the
#   common case. On persistent failure the container stays alive for
#   debugging rather than crashing — this lets the integration test
#   script (W-008) inspect logs and diagnose issues.
#

set -euo pipefail

echo "[entrypoint] Orion-X Mesh Node starting..."
echo "[entrypoint] Hostname: $(hostname)"

# Extract IP — handle cases where eth0 may not exist yet
if ip -4 addr show eth0 >/dev/null 2>&1; then
    NODE_IP="$(ip -4 addr show eth0 | grep -oP 'inet \K[0-9.]+')" || NODE_IP="unknown"
else
    NODE_IP="$(hostname -I | awk '{print $1}')" || NODE_IP="unknown"
fi
echo "[entrypoint] IP: ${NODE_IP}"

# Wait for network to be ready
sleep 2

# Join the mesh with retry logic
join_mesh() {
    orionx-mesh join || {
        echo "[entrypoint] WARNING: mesh join failed, retrying in 3s..."
        sleep 3
        orionx-mesh join || {
            echo "[entrypoint] ERROR: mesh join failed after retry"
            return 1
        }
    }
}

if ! join_mesh; then
    echo "[entrypoint] Continuing without mesh — container will stay alive for debugging"
fi

# Show initial status
orionx-mesh status || true

# Keep container alive and periodically run health checks
while true; do
    sleep 60
    orionx-mesh status 2>/dev/null || true
done
