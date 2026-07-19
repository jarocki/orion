#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-004
# @title Orion-X Ghidra optional installer (post-boot, network-required)
# @status accepted
# @rationale Ghidra bulk staging was removed from the base ISO by W11-2
#   (DEC-PHASE11-004) to save ~500 MB.  Operators who need Ghidra for reverse
#   engineering install post-boot on a network-connected node via this script.
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer framework
# @status accepted
# @rationale Sources the shared installer library for DRY preflight checks,
#   log helpers, and download/extract helpers.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-ghidra.sh
#
# What this installs:
#   Ghidra 11.0.1 (NSA/ghidra, Apache-2.0)  ~400 MB extracted
#   Destination: /opt/ghidra/
#   Symlink:     /usr/local/bin/ghidra → /opt/ghidra/ghidraRun
#   Requires:    java (openjdk-17-jdk or later)
#   Mission verb: analyze (static reverse-engineering workbench)
#
# Note: SHA-256 pin is deferred to the first green CI build (DEC-PHASE10-008
# trust-on-first-use; a follow-up MICRO-SLICE pins the digest before v2.1.0 tag).

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
orionx_log_info "=== Orion-X optional installer: Ghidra ==="
orionx_log_info "  Size:    ~400 MB download + extraction"
orionx_log_info "  License: Apache-2.0 (NationalSecurityAgency/ghidra)"
orionx_log_info "  Network: github.com (release tarball download)"
orionx_log_info "  Mission: analyze — static reverse-engineering workbench"

# Ensure Java runtime is available (Ghidra requires JDK 17+)
orionx_log_info "Ensuring openjdk-17-jdk is installed..."
orionx_apt_install openjdk-17-jdk

# ---------------------------------------------------------------------------
# Download and extract Ghidra
# ---------------------------------------------------------------------------
GHIDRA_VERSION="11.0.1"
GHIDRA_DATE="20240130"
GHIDRA_ZIP_URL="https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip"
GHIDRA_DEST="/opt/ghidra"

orionx_log_info "Downloading Ghidra ${GHIDRA_VERSION}..."
orionx_wget_extract "$GHIDRA_ZIP_URL" "$GHIDRA_DEST"

# ---------------------------------------------------------------------------
# PATH symlink
# ---------------------------------------------------------------------------
orionx_log_info "Creating /usr/local/bin/ghidra symlink..."
ln -sf "${GHIDRA_DEST}/ghidraRun" /usr/local/bin/ghidra

orionx_log_info "=== Ghidra ${GHIDRA_VERSION} installed. Run: ghidra ==="
