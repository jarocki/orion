#!/usr/bin/env bash
# shellcheck shell=bash
#
# orionx-imager-cli.sh — Bash CLI wrapper for orionx-imager
#
# Provides a documented, shellcheck-clean shell entry point for headless /
# scripted use.  All substantive logic is delegated to the Python tool
# (scripts/orionx-imager/orionx-imager).  This wrapper exists to:
#   1. Give operators a discoverable shell-script interface with --help.
#   2. Validate preconditions (Python 3 present, entry point exists) before
#      handing off, with clear error messages.
#   3. Serve as a stable shebang-based entry point for PATH installs or symlinks.
#
# Usage:
#   ./orionx-imager-cli.sh [OPTIONS]
#
# @decision DEC-PHASE11-015
# @title    Orion-X imager — bash CLI wrapper (Layer A)
# @status   accepted
# @rationale
#   Bash wrapper keeps the shell-operator interface explicit and shellcheck-clean.
#   Python entry point handles all logic; wrapper is a thin validated proxy.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGER_PY="${SCRIPT_DIR}/orionx-imager"

# ---------------------------------------------------------------------------
# Precondition checks
# ---------------------------------------------------------------------------
_check_preconditions() {
    if ! command -v python3 &>/dev/null; then
        echo "ERROR: python3 not found in PATH." >&2
        echo "  macOS:  Python 3 is bundled; if missing, install via https://python.org" >&2
        echo "  Linux:  sudo apt install python3" >&2
        exit 1
    fi

    if [[ ! -f "${IMAGER_PY}" ]]; then
        echo "ERROR: orionx-imager Python entry point not found at ${IMAGER_PY}" >&2
        echo "  Ensure you are running this script from within scripts/orionx-imager/" >&2
        echo "  or have cloned the full Orion-X repository." >&2
        exit 1
    fi

    if [[ ! -x "${IMAGER_PY}" ]]; then
        echo "ERROR: ${IMAGER_PY} is not executable." >&2
        echo "  Fix: chmod +x ${IMAGER_PY}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Help text (printed by --help and when no args given)
# ---------------------------------------------------------------------------
_print_help() {
    cat <<'EOF'
orionx-imager-cli — Orion-X ISO downloader and USB writer (CLI)

USAGE
  orionx-imager-cli.sh [OPTIONS]

OPTIONS
  --list-devices
      List available removable / USB devices and exit.

  --list-releases
      List available GitHub release tags and exit.

  --iso-release <TAG|latest>
      Download the ISO from the specified GitHub release tag (or 'latest').
      Downloads to ~/.cache/orionx-imager/ and verifies SHA256 automatically.

  --iso <PATH>
      Use a local ISO file instead of downloading from GitHub.

  --target <DEVICE>
      Target block device to write the ISO to (e.g. /dev/disk4, /dev/sdb).
      SAFETY: /dev/disk0 (macOS) and /dev/sda (Linux root) are refused.

  --dry-run
      Print the intended download + write plan without executing anything.
      Recommended for first-time use to verify your device selection.

  --skip-verify
      Skip SHA256 verification of the downloaded ISO. NOT RECOMMENDED.
      Requires --yes-really-skip-verify as a second flag (two-flag opt-out).

  --yes-really-skip-verify
      Second flag required to actually disable verification. See --skip-verify.

  --force
      Skip interactive confirmation prompt. FOR CI/TESTING USE ONLY.

  --clear-cache
      Remove all cached ISO downloads and exit.

  --i-really-know-what-im-doing
      Bypass the internal-disk refuse-list. DANGEROUS — for CI/testing only.

  --version
      Print version and exit.

  --help, -h
      Print this help text and exit.

EXAMPLES
  # List connected USB devices:
  ./orionx-imager-cli.sh --list-devices

  # Dry-run: see what would happen without writing anything:
  ./orionx-imager-cli.sh --dry-run --iso-release latest --target /dev/disk4

  # Download latest release, verify SHA256, write to /dev/disk4:
  ./orionx-imager-cli.sh --iso-release latest --target /dev/disk4

  # Write a local ISO you already have:
  ./orionx-imager-cli.sh --iso ~/Downloads/orionx-v2.0.0.iso --target /dev/sdb

SAFETY
  The refuse-list hard-blocks writes to /dev/disk0 (macOS system disk) and
  /dev/sda when it is the Linux root device.  You must type the target device
  path back at the confirmation prompt, or supply --force for scripted use.

  SHA256 verification is mandatory by default.  The integrity manifest is
  downloaded automatically from the GitHub release SHA256SUMS asset
  (emitted by .github/workflows/release.yml).

LAYER B DEFERRALS (W11-12b)
  Windows support, real progress bars, packaged installers (.app / AppImage /
  .msi), code-signing / notarization, and verification-after-write are
  deferred to W11-12b.  On Windows, use WSL2 and this CLI for now.

TROUBLESHOOTING
  "Rate limit exceeded":  Use --iso <local-file> to bypass the GitHub API,
                          or wait ~60 minutes.
  "Permission denied":    Run with sudo, or add yourself to the 'disk' group
                          (Linux).
  "Resource busy" (macOS): The tool auto-unmounts, but if persistent:
                          diskutil unmountDisk /dev/diskN

EOF
}

# ---------------------------------------------------------------------------
# Argument scan: intercept --help / -h before delegating to Python
# ---------------------------------------------------------------------------
_check_help() {
    for arg in "$@"; do
        case "${arg}" in
            --help|-h)
                _print_help
                exit 0
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # No arguments: show help (headless script — GUI is the Python entry point)
    if [[ $# -eq 0 ]]; then
        _print_help
        exit 0
    fi

    _check_help "$@"
    _check_preconditions

    # Delegate all logic to the Python entry point
    exec python3 "${IMAGER_PY}" "$@"
}

main "$@"
