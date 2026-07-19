#!/usr/bin/env bash
# shellcheck shell=bash
# @decision DEC-PHASE11-009
# @title Orion-X ClamAV optional installer
# @status accepted
# @rationale ClamAV dropped from base ISO (350 MB, 90% freshness-decay, background network dep incompatible with air-gap). Operators who want signature scan install post-boot on a network-connected node.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: install-clamav requires root" >&2
    exit 1
fi

if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "ERROR: deb.debian.org unreachable (air-gap or DNS). ClamAV install requires network." >&2
    exit 1
fi

echo "[install-clamav] Installing ClamAV + freshclam..."
apt-get update
apt-get install -y clamav clamav-freshclam

echo "[install-clamav] Running initial freshclam to populate signatures..."
freshclam || echo "[install-clamav] WARN: freshclam initial run failed (retry manually)"

echo "[install-clamav] Complete. Usage: clamscan <file>"
