#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-008
# @title Orion-X Suricata ET-Open freshen (W11-6 Layer A)
# @status accepted
# @rationale Suricata IDS Layer A ships no bundled ruleset (Layer B deferred to
#   W11-6b). This script is the operator-facing tool to fetch ET-Open rules
#   (BSD-2-Clause) from emergingthreats.net post-boot. Requires network access;
#   fails loudly on air-gap or DNS failure so the operator knows immediately.
#   Root required: writes to /var/lib/suricata/rules (owned by root in Debian
#   packaging). Layer B will automate this at build time and wire the tier
#   selector; until then, this script is the only freshen mechanism.

set -euo pipefail

RULES_DIR="/var/lib/suricata/rules"
ET_URL="https://rules.emergingthreats.net/open/suricata-6.0/emerging.rules.tar.gz"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: orionx-freshen-suricata requires root" >&2
    exit 1
fi

if ! getent hosts rules.emergingthreats.net >/dev/null 2>&1; then
    echo "ERROR: rules.emergingthreats.net unreachable (air-gap or DNS)" >&2
    exit 1
fi

mkdir -p "$RULES_DIR"
tmp=$(mktemp)
echo "[orionx-freshen-suricata] Downloading ET-Open rules..."
wget -q -O "$tmp" "$ET_URL"
tar -xzf "$tmp" -C "$RULES_DIR" --strip-components=1
rm -f "$tmp"
echo "[orionx-freshen-suricata] Complete. $(find "$RULES_DIR" -name '*.rules' | wc -l) rule files installed."
