#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-007
# @title Orion-X gomuks optional installer (post-boot, network-required)
# @status accepted
# @rationale gomuks (mautrix Matrix TUI client) was deferred from the base
#   ISO by the W11-5 Layer A detail plan. Operators who need a terminal-based
#   Matrix client install post-boot on a network-connected node via this script.
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer framework
# @status accepted
# @rationale Sources the shared installer library for DRY preflight checks,
#   log helpers, and download/extract helpers.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-gomuks.sh
#
# What this installs:
#   gomuks (mautrix/gomuks, Apache-2.0)  ~25 MB static binary
#   Destination: /usr/local/bin/gomuks
#   .desktop:    /usr/share/applications/gomuks.desktop
#   Mission verb: defend — terminal Matrix client for air-gap-ready comms

set -euo pipefail

# SC1091: library lives at runtime path /opt/orionx/optional/lib/ on the target
# system; shellcheck cannot follow the absolute source path on the build host.
# shellcheck disable=SC1091
source /opt/orionx/optional/lib/orionx-installer-common.sh

orionx_require_root
orionx_require_network github.com

# ---------------------------------------------------------------------------
# Preflight banner (DEC-PHASE11-011: name / size / license / network / mission)
# ---------------------------------------------------------------------------
orionx_log_info "=== Orion-X optional installer: gomuks ==="
orionx_log_info "  Size:    ~25 MB download (static binary)"
orionx_log_info "  License: Apache-2.0 (mautrix/gomuks)"
orionx_log_info "  Network: github.com (release tarball download)"
orionx_log_info "  Mission: defend — terminal Matrix client for encrypted team comms"

# ---------------------------------------------------------------------------
# Download gomuks static binary
# DEC-PHASE10-008 trust-on-first-use: SHA-256 pin deferred to first green
# CI build of W11-8; a follow-up MICRO-SLICE pins the digest before v2.1.0 tag.
# ---------------------------------------------------------------------------
GOMUKS_VERSION="v0.3.1"
GOMUKS_URL="https://github.com/mautrix/gomuks/releases/download/${GOMUKS_VERSION}/gomuks-linux-amd64"
GOMUKS_BIN="/usr/local/bin/gomuks"

orionx_log_info "Downloading gomuks ${GOMUKS_VERSION}..."
wget -q -O "$GOMUKS_BIN" "$GOMUKS_URL"
chmod +x "$GOMUKS_BIN"

# ---------------------------------------------------------------------------
# .desktop launcher
# ---------------------------------------------------------------------------
orionx_log_info "Creating gomuks .desktop launcher..."
mkdir -p /usr/share/applications
cat > /usr/share/applications/gomuks.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=gomuks
Comment=Terminal Matrix client (mautrix/gomuks)
Exec=xfce4-terminal --command=gomuks
Icon=utilities-terminal
Terminal=false
Categories=Network;Chat;
Keywords=matrix;chat;gomuks;
EOF

orionx_log_info "=== gomuks ${GOMUKS_VERSION} installed. Run: gomuks ==="
