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
# DEC-PHASE12-122: the vendor serves only "latest" under fixed names, so these
# pins are the files as downloaded 2026-10-07 (431,726 and 2,783,928 bytes).
# When mark0.net updates either file the install REFUSES (fail closed); review
# the new file and update the pin. There is no vendor signature to verify.
TRID_BIN_SHA256="3fb9ccfed650123f7bb5fc5a93ccbfcbc6ff98876cc659c8958c03a582467aa9"

orionx_log_info "Downloading TrID binary..."
orionx_apt_install unzip

mkdir -p "$TRID_DEST"

# Download and extract the TrID binary (bare zip — no top-level directory)
local_bin="$(mktemp)"
orionx_download_verified "$TRID_BIN_URL" "$local_bin" "$TRID_BIN_SHA256"
unzip -q -o "$local_bin" -d "$TRID_DEST"
rm -f "$local_bin"

# Download and extract the TrID definitions
orionx_log_info "Downloading TrID definitions (triddefs.zip)..."
# @decision DEC-PHASE13-059
# @category TOOLING
# @title TrID definitions are checked for shape, not pinned; the TrID program stays pinned
# @status accepted
# @rationale #197. triddefs.zip sits at one unversioned URL and upstream
#   replaces it as definitions are added: the pin written on 2026-10 no
#   longer matched on 2026-11-25, so every TrID install was refused. A fixed
#   pin on a moving file breaks again every few months. The definitions are
#   data that trid reads, not code that runs, so DEC-PHASE12-122 (every
#   fetched executable is SHA-256 pinned) is kept for the binary and relaxed
#   for this file only: it must be a zip of exactly one entry, triddefs.trd,
#   under 64 MB unpacked, fetched over TLS from mark0.net. The hash actually
#   received is logged and kept in DEFS-SHA256 (the version orionx-optional
#   reports), so an install can be traced to the exact file. This supersedes
#   DEC-PHASE13-005 (2026-10-18: keep TrID pins fail-closed, add --print-pin),
#   which the owner replaced on 2026-11-26 by approving this approach; the
#   conflict was found afterwards and is recorded here.
local_def="$(mktemp)"
if ! wget -q -O "$local_def" "$TRID_DEF_URL"; then
    rm -f "$local_def"; orionx_log_error "Download failed: $TRID_DEF_URL"; exit 1
fi
def_entries="$(unzip -Z1 "$local_def" 2>/dev/null || true)"
def_bytes="$(unzip -l "$local_def" 2>/dev/null | awk 'END {print $1}')"
if [[ "$def_entries" != "triddefs.trd" || ! "$def_bytes" =~ ^[0-9]+$ || "$def_bytes" -gt 67108864 ]]; then
    rm -f "$local_def"
    orionx_log_error "triddefs.zip is not a single triddefs.trd under 64 MB (entries: ${def_entries:-none}); refusing it."
    exit 1
fi
def_sha="$(sha256sum "$local_def" | awk '{print $1}')"
unzip -q -o "$local_def" triddefs.trd -d "$TRID_DEST"
rm -f "$local_def"
printf 'triddefs %s\n' "$def_sha" > "$TRID_DEST/DEFS-SHA256"
orionx_log_info "TrID definitions installed (triddefs.zip sha256 $def_sha)"
chmod +x "$TRID_DEST/trid"

# ---------------------------------------------------------------------------
# PATH symlink
# ---------------------------------------------------------------------------
orionx_log_info "Creating /usr/local/bin/trid symlink..."
ln -sf "${TRID_DEST}/trid" /usr/local/bin/trid

orionx_log_info "=== TrID installed. Run: trid <file> ==="
