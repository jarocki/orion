#!/usr/bin/env bash
# shellcheck shell=bash
# @decision DEC-PHASE11-009
# @title Orion-X ClamAV optional installer
# @status accepted
# @rationale ClamAV dropped from base ISO (350 MB, 90% freshness-decay, background network dep incompatible with air-gap). Operators who want signature scan install post-boot on a network-connected node.

set -euo pipefail

# SC1091: library lives at runtime path /opt/orionx/optional/lib/ on the target
# system; shellcheck cannot follow the absolute source path on the build host.
# shellcheck disable=SC1091
source /opt/orionx/optional/lib/orionx-installer-common.sh

orionx_require_root
orionx_require_network deb.debian.org

orionx_log_info "Installing ClamAV + freshclam..."
orionx_apt_install clamav clamav-freshclam

orionx_log_info "Running initial freshclam to populate signatures..."
freshclam || orionx_log_info "WARN: freshclam initial run failed (retry manually)"

orionx_log_info "Complete. Usage: clamscan <file>"
