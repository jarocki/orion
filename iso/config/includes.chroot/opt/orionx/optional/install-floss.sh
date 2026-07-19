#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-004
# @title Orion-X FLOSS optional installer (post-boot, network-required)
# @status accepted
# @rationale FLOSS (Mandiant obfuscated-string solver) was deferred from the
#   base ISO by the W11-3 Layer A detail plan (line 3309: "Do NOT ship FLOSS,
#   TrID, Node.js 20 LTS, or remnux-mcp-server payloads in this slice").
#   Operators who need FLOSS for malware triage install post-boot on a
#   network-connected node via this script.
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer framework
# @status accepted
# @rationale Sources the shared installer library for DRY preflight checks,
#   log helpers, and download/extract helpers.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-floss.sh
#
# What this installs:
#   FLOSS v3 (Mandiant/flare-floss, Apache-2.0)  ~15 MB
#   Destination: /opt/orionx/floss/
#   Symlink:     /usr/local/bin/floss → /opt/orionx/floss/floss
#   Mission verb: triage — extract obfuscated strings from malware binaries

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
orionx_log_info "=== Orion-X optional installer: FLOSS ==="
orionx_log_info "  Size:    ~15 MB download"
orionx_log_info "  License: Apache-2.0 (mandiant/flare-floss)"
orionx_log_info "  Network: github.com (release tarball download)"
orionx_log_info "  Mission: triage — extract obfuscated strings from malware"

# ---------------------------------------------------------------------------
# Download and extract FLOSS
# DEC-PHASE10-008 trust-on-first-use: SHA-256 pin deferred to first green
# CI build of W11-8; a follow-up MICRO-SLICE pins the digest before v2.1.0 tag.
# ---------------------------------------------------------------------------
FLOSS_VERSION="3.1.0"
FLOSS_URL="https://github.com/mandiant/flare-floss/releases/download/v${FLOSS_VERSION}/floss-v${FLOSS_VERSION}-linux.zip"
FLOSS_DEST="/opt/orionx/floss"

orionx_log_info "Downloading FLOSS v${FLOSS_VERSION}..."
orionx_apt_install unzip

# FLOSS releases ship a bare binary in a zip (no top-level directory),
# so we extract directly into the destination directory.
local_tmp="$(mktemp)"
wget -q -O "$local_tmp" "$FLOSS_URL"
mkdir -p "$FLOSS_DEST"
unzip -q -o "$local_tmp" -d "$FLOSS_DEST"
rm -f "$local_tmp"
chmod +x "$FLOSS_DEST"/floss

# ---------------------------------------------------------------------------
# PATH symlink
# ---------------------------------------------------------------------------
orionx_log_info "Creating /usr/local/bin/floss symlink..."
ln -sf "${FLOSS_DEST}/floss" /usr/local/bin/floss

orionx_log_info "=== FLOSS v${FLOSS_VERSION} installed. Run: floss <binary> ==="
