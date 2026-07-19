#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-004
# @title Orion-X TrID optional installer (post-boot, network-required)
# @status accepted
# @rationale TrID (Marco Pontello's file-type identifier) was deferred from
#   the base ISO by the W11-3 Layer A detail plan (line 3309: "Do NOT ship
#   FLOSS, TrID, Node.js 20 LTS, or remnux-mcp-server payloads in this slice").
#   Operators who need TrID for file-type triage install post-boot on a
#   network-connected node via this script.
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer framework
# @status accepted
# @rationale Sources the shared installer library for DRY preflight checks,
#   log helpers, and download/extract helpers.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-trid.sh
#
# What this installs:
#   TrID Linux 64-bit (Marco Pontello, freeware)  ~5 MB binary + definitions
#   Destination: /opt/orionx/trid/
#   Symlink:     /usr/local/bin/trid → /opt/orionx/trid/trid
#   Mission verb: triage — identify unknown file types by binary signature

set -euo pipefail

# SC1091: library lives at runtime path /opt/orionx/optional/lib/ on the target
# system; shellcheck cannot follow the absolute source path on the build host.
# shellcheck disable=SC1091
source /opt/orionx/optional/lib/orionx-installer-common.sh

orionx_require_root
orionx_require_network mark0.net

# ---------------------------------------------------------------------------
# Preflight banner (DEC-PHASE11-011: name / size / license / network / mission)
# ---------------------------------------------------------------------------
orionx_log_info "=== Orion-X optional installer: TrID ==="
orionx_log_info "  Size:    ~5 MB download (binary + definitions)"
orionx_log_info "  License: Freeware (Marco Pontello, mark0.net)"
orionx_log_info "  Network: mark0.net (upstream download)"
orionx_log_info "  Mission: triage — identify unknown file types by binary signature"

# ---------------------------------------------------------------------------
# Download and extract TrID binary + definitions
# DEC-PHASE10-008 trust-on-first-use: SHA-256 pin deferred to first green
# CI build of W11-8; a follow-up MICRO-SLICE pins the digest before v2.1.0 tag.
# ---------------------------------------------------------------------------
TRID_DEST="/opt/orionx/trid"
TRID_BIN_URL="https://mark0.net/download/trid_linux_64.zip"
TRID_DEF_URL="https://mark0.net/download/triddefs.zip"

orionx_log_info "Downloading TrID binary..."
orionx_apt_install unzip

mkdir -p "$TRID_DEST"

# Download and extract the TrID binary (bare zip — no top-level directory)
local_bin="$(mktemp)"
wget -q -O "$local_bin" "$TRID_BIN_URL"
unzip -q -o "$local_bin" -d "$TRID_DEST"
rm -f "$local_bin"

# Download and extract the TrID definitions
orionx_log_info "Downloading TrID definitions (triddefs.zip)..."
local_def="$(mktemp)"
wget -q -O "$local_def" "$TRID_DEF_URL"
unzip -q -o "$local_def" -d "$TRID_DEST"
rm -f "$local_def"

chmod +x "$TRID_DEST/trid"

# ---------------------------------------------------------------------------
# PATH symlink
# ---------------------------------------------------------------------------
orionx_log_info "Creating /usr/local/bin/trid symlink..."
ln -sf "${TRID_DEST}/trid" /usr/local/bin/trid

orionx_log_info "=== TrID installed. Run: trid <file> ==="
