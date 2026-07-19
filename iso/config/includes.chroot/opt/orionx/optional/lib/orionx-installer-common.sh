#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer common library
# @status accepted
# @rationale Shared framework for /opt/orionx/optional/install-*.sh — DRY the
#   DEC-PHASE11-011 contract (root + network preflight, log helpers, apt/wget
#   helpers, SHA-256 verify) so every installer picks up the same behavior by
#   sourcing this file instead of re-implementing five boilerplate patterns.
#
# IMPORTANT: This file is SOURCED, not executed.  Do NOT set -euo pipefail
# here — the caller owns shell options; setting them in a sourced library
# hijacks the caller's shell unexpectedly (DEC-PHASE11-011 forbidden shortcut).
# Do NOT chmod +x this file — an executable library misleads future readers.
#
# Usage:
#   source /opt/orionx/optional/lib/orionx-installer-common.sh
#
# Defined API (7 functions):
#   orionx_require_root
#   orionx_require_network <host>
#   orionx_log_info  <msg…>
#   orionx_log_error <msg…>
#   orionx_apt_install <packages…>
#   orionx_wget_extract <url> <dest_dir>
#   orionx_verify_sha256 <file> <expected_hex>

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

# orionx_log_info — emit an info line prefixed with the calling script name
orionx_log_info() {
    echo "[${0##*/}] $*"
}

# orionx_log_error — emit an error line to stderr prefixed with the calling
# script name.  Callers should exit non-zero after calling this.
orionx_log_error() {
    echo "ERROR: [${0##*/}] $*" >&2
}

# ---------------------------------------------------------------------------
# Preflight guards — LOUD-fail so air-gap operators get an actionable message
# ---------------------------------------------------------------------------

# orionx_require_root — exit 1 if caller is not running as root (EUID == 0).
# DEC-PHASE11-011: optional installers run as root; surface this requirement
# immediately rather than letting a subsequent apt-get or wget fail silently.
orionx_require_root() {
    if [[ $EUID -ne 0 ]]; then
        orionx_log_error "${0##*/} requires root. Run with sudo."
        exit 1
    fi
}

# orionx_require_network <host> — exit 1 if <host> is not DNS-resolvable.
# DEC-PHASE11-011: optional installers require network access; Orion-X is
# designed for air-gap operation.  Operators MUST connect to a network-capable
# node before running any install-*.sh script.
# Args:
#   $1  hostname to probe via getent hosts (default: deb.debian.org)
orionx_require_network() {
    local host="${1:-deb.debian.org}"
    if ! getent hosts "$host" >/dev/null 2>&1; then
        orionx_log_error "$host unreachable (air-gap or DNS)." \
            "${0##*/} requires network access." \
            "Run this installer on a network-connected node."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Package install helper
# ---------------------------------------------------------------------------

# orionx_apt_install <packages…> — run apt-get update then install the given
# packages non-interactively.  Uses DEBIAN_FRONTEND=noninteractive to suppress
# prompts that would stall an operator-run install.
# Args:
#   $@  package names forwarded verbatim to apt-get install -y
orionx_apt_install() {
    orionx_log_info "apt-get update && apt-get install -y $*"
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# ---------------------------------------------------------------------------
# Tarball / archive fetch + extract helper
# ---------------------------------------------------------------------------

# orionx_wget_extract <url> <dest_dir> — download an archive from <url> and
# extract it into <dest_dir>, creating the directory if absent.
# Supported extensions: .tar.gz / .tgz, .tar.xz, .tar.zst, .zip
# The top-level directory inside the archive is stripped on extraction
# (--strip-components=1) so the content lands directly in <dest_dir>.
# Archives that do not match a known extension cause a LOUD error + exit 1.
# Args:
#   $1  URL to download (wget -q)
#   $2  destination directory (created if absent)
orionx_wget_extract() {
    local url="${1:?url required}"
    local dest="${2:?dest_dir required}"
    local tmp
    tmp="$(mktemp)"
    orionx_log_info "Downloading $(basename "$url") → $dest"
    wget -q -O "$tmp" "$url"
    mkdir -p "$dest"
    case "$url" in
        *.tar.gz|*.tgz)
            tar -xzf "$tmp" -C "$dest" --strip-components=1 ;;
        *.tar.xz)
            tar -xJf "$tmp" -C "$dest" --strip-components=1 ;;
        *.tar.zst)
            tar --zstd -xf "$tmp" -C "$dest" --strip-components=1 ;;
        *.zip)
            # unzip does not support --strip-components; extract to a temp dir
            # then move contents up one level into $dest.
            local ztmp
            ztmp="$(mktemp -d)"
            unzip -q "$tmp" -d "$ztmp"
            # find and move first top-level entry into dest
            local inner
            inner="$(find "$ztmp" -mindepth 1 -maxdepth 1 | head -1)"
            if [[ -d "$inner" ]]; then
                # copy inner directory contents into dest
                cp -a "$inner/." "$dest/"
            else
                cp -a "$ztmp/." "$dest/"
            fi
            rm -rf "$ztmp"
            ;;
        *)
            orionx_log_error "Unknown archive format for URL: $url"
            rm -f "$tmp"
            exit 1
            ;;
    esac
    rm -f "$tmp"
    orionx_log_info "Extracted to $dest"
}

# ---------------------------------------------------------------------------
# Integrity verification helper
# ---------------------------------------------------------------------------

# orionx_verify_sha256 <file> <expected_hex> — compare the SHA-256 digest of
# <file> against <expected_hex> and exit 1 on mismatch (LOUD-fail).
# DEC-PHASE10-008: trust-on-first-use pattern; Layer A ships without pins;
# a follow-up MICRO-SLICE pins the digest after the first green CI build.
# Args:
#   $1  path to the file to verify
#   $2  expected SHA-256 hex string (64 lowercase hex characters)
orionx_verify_sha256() {
    local file="${1:?file required}"
    local expected="${2:?expected_hex required}"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        orionx_log_error "SHA-256 mismatch on $file"
        orionx_log_error "  expected: $expected"
        orionx_log_error "  actual:   $actual"
        exit 1
    fi
    orionx_log_info "SHA-256 verified: $file"
}
