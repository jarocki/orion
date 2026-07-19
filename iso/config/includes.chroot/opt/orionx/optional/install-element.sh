#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-007
# @title Orion-X Element desktop optional installer (post-boot, network-required)
# @status accepted
# @rationale element-desktop is a GUI Matrix client (~200 MB). It was deferred
#   from the base ISO by the W11-5 Layer A detail plan (line 3483: "Do NOT ship
#   an install-element.sh optional installer in Layer A; that stub is owned by
#   W11-8's optional-installer framework slice"). Operators who need a GUI
#   Matrix client install post-boot on a network-connected node.
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer framework
# @status accepted
# @rationale Sources the shared installer library for DRY preflight checks,
#   log helpers, and apt install helpers.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-element.sh
#
# What this installs:
#   element-desktop (Element.io, Apache-2.0)  ~200 MB
#   Destination: system packages via apt (element-hq official Debian repo)
#   Mission verb: defend — encrypted team communications via Matrix

set -euo pipefail

# SC1091: library lives at runtime path /opt/orionx/optional/lib/ on the target
# system; shellcheck cannot follow the absolute source path on the build host.
# shellcheck disable=SC1091
source /opt/orionx/optional/lib/orionx-installer-common.sh

orionx_require_root
orionx_require_network packages.element.io

# ---------------------------------------------------------------------------
# Preflight banner (DEC-PHASE11-011: name / size / license / network / mission)
# ---------------------------------------------------------------------------
orionx_log_info "=== Orion-X optional installer: Element desktop ==="
orionx_log_info "  Size:    ~200 MB download"
orionx_log_info "  License: Apache-2.0 (element-hq/element-desktop)"
orionx_log_info "  Network: packages.element.io (official Debian repo)"
orionx_log_info "  Mission: defend — encrypted team communications via Matrix"

# ---------------------------------------------------------------------------
# Add the Element.io apt repository
# ---------------------------------------------------------------------------
orionx_log_info "Adding element-hq signing key..."
orionx_apt_install apt-transport-https

wget -qO /usr/share/keyrings/element-io-archive-keyring.gpg \
    https://packages.element.io/debian/element-io-archive-keyring.gpg

orionx_log_info "Adding element-hq apt source..."
cat > /etc/apt/sources.list.d/element-io.list <<'EOF'
deb [signed-by=/usr/share/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian/ default main
EOF

# ---------------------------------------------------------------------------
# Install element-desktop
# ---------------------------------------------------------------------------
orionx_apt_install element-desktop

orionx_log_info "=== element-desktop installed. Launch: element-desktop ==="
