#!/usr/bin/env bash
# shellcheck shell=bash
#
# install-bluetooth.sh — optional Bluetooth support (mouse, keyboard, headset)
# on the live deck, no reboot (#151, DEC-PHASE13-035)
#
# @decision DEC-PHASE13-035
# @title Bluetooth is an operator-run optional installer that prefers a deb
#   cache baked into the ISO at build time and falls back to the network
# @status accepted
# @rationale The image ships no Bluetooth userspace by design (fewer radios on
#   by default; 0620 masks bluetooth.service when it exists). The kernel
#   modules and firmware are already on the image (stock Debian kernel +
#   firmware-* packages), so only userspace is missing and nothing needs a
#   reboot. The operator asked for exactly that (#151): "an optional installer
#   that does not require a reboot".
#
#   WHAT, measured against the v3.1.2 package set in a debian:trixie-slim
#   container (2026-11-01): bluez + blueman with --no-install-recommends is
#   20 debs / 6.8 MB; adding pulseaudio-module-bluetooth (headsets) makes it
#   21 / 6.9 MB; blueman's Recommends would drag 75.7 MB of multimedia
#   packages behind it. So: the three packages, --no-install-recommends.
#
#   WHY A CACHE: the deck most likely wants a mouse at a desk with no
#   network, and the clock/apt failure that motivated #148 showed how fragile
#   "apt on a live deck" is. 7 MB of debs on a 3 GB ISO is a cheap way to
#   make this work offline, and a cache downloaded by the SAME apt run that
#   built the image is pinned to the libraries the image actually has —
#   strictly safer than pulling whatever the mirror holds months later. The
#   0500 hook downloads them (soft-fail, like Zeek) into
#   /opt/orionx/optional/cache/bluetooth/ reading the package list from THIS
#   file, so the list has one home. If the cache is absent or apt rejects it
#   (a package the trim hook removed), the installer says so and uses the
#   network exactly like every other optional installer.
#
#   POSTURE: this turns a radio on. The banner says so, says how to turn it
#   off (rfkill block bluetooth) and how to remove it. Persistence: on a plain
#   live stick the install lives in the RAM overlay and is gone at reboot;
#   with a persistence volume it survives — stated, not assumed.
#
#   Idempotent: a re-run on a deck that has it ensures the service is up and
#   the radio unblocked and exits 0 without apt. --check is a verdict
#   (exit 1 when absent). --dry-run prints the plan (cache or network) and
#   changes nothing.
#
# Usage (as root on the deck):
#   sudo /opt/orionx/optional/install-bluetooth.sh
#   sudo /opt/orionx/optional/install-bluetooth.sh --check      # report only
#   sudo /opt/orionx/optional/install-bluetooth.sh --dry-run    # plan only
#   sudo /opt/orionx/optional/install-bluetooth.sh --force      # reinstall
#
# What this installs:
#   bluez 5.82, blueman 2.4 (GPL-3), pulseaudio-module-bluetooth  ~7 MB
#   Enables bluetooth.service, unblocks the radio (rfkill), opens
#   blueman-manager for pairing.
#   Mission verb: operate — a mouse or keyboard on the deck.

set -euo pipefail

# ORIONX_INSTALLER_LIB overrides the library path for tests ONLY (the pattern
# install-zeek.sh set, DEC-PHASE12-117). Production sources the runtime path.
# shellcheck disable=SC1090,SC1091
source "${ORIONX_INSTALLER_LIB:-/opt/orionx/optional/lib/orionx-installer-common.sh}"

# ---------------------------------------------------------------------------
# Single authority for the package set and the cache location. The 0500 hook
# reads BLUETOOTH_PACKAGES from this file (bluetooth_pin) when it fills the
# cache at build time.
# ---------------------------------------------------------------------------
BLUETOOTH_PACKAGES="bluez blueman pulseaudio-module-bluetooth"
BLUETOOTH_CACHE="${ORIONX_BLUETOOTH_CACHE:-/opt/orionx/optional/cache/bluetooth}"
BLUETOOTH_UNIT="bluetooth.service"

FORCE=0
CHECK_ONLY=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --force)   FORCE=1 ;;
        --check)   CHECK_ONLY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '/^# Usage/,/^#   Mission verb/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            orionx_log_error "unknown argument: $arg (see --help)"
            exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Truth probes. "dpkg says installed" for each package AND the manager binary
# runs — a half-configured install must not be reported as done.
# ---------------------------------------------------------------------------
pkg_installed() {
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" == "installed" ]]
}

bluetooth_installed() {
    local p
    for p in bluez blueman; do
        pkg_installed "$p" || return 1
    done
    command -v blueman-manager >/dev/null 2>&1
}

cache_debs() {
    # Every .deb in the cache, or nothing. The glob is expanded here so the
    # caller can test emptiness without nullglob leaking.
    local d
    shopt -s nullglob
    for d in "$BLUETOOTH_CACHE"/*.deb; do printf '%s\n' "$d"; done
    shopt -u nullglob
}

bluetooth_emit() {
    local sev="$1"; shift
    command -v orionx-event >/dev/null 2>&1 || return 0
    # source=installer / category=tooling: an install is not a detection and
    # must not move THREAT PRESSURE (same rule as install-zeek.sh).
    orionx-event --severity "$sev" --source installer --category tooling "$*" \
        >/dev/null 2>&1 || true
}

# Service + radio: the part a re-run always re-asserts, because a masked
# unit or a soft-blocked radio is the same "nothing pairs" symptom as an
# absent package.
enable_radio() {
    if [[ $DRY_RUN -eq 1 ]]; then
        orionx_log_info "[dry-run] systemctl unmask $BLUETOOTH_UNIT; systemctl enable --now $BLUETOOTH_UNIT; rfkill unblock bluetooth"
        return 0
    fi
    systemctl unmask "$BLUETOOTH_UNIT" >/dev/null 2>&1 || true
    if ! systemctl enable --now "$BLUETOOTH_UNIT" >/dev/null 2>&1; then
        orionx_log_error "$BLUETOOTH_UNIT did not start: systemctl status $BLUETOOTH_UNIT"
        return 1
    fi
    if command -v rfkill >/dev/null 2>&1; then
        rfkill unblock bluetooth 2>/dev/null || orionx_log_info "rfkill unblock bluetooth failed (no Bluetooth radio?)"
    fi
    local state
    state="$(systemctl is-active "$BLUETOOTH_UNIT" 2>/dev/null || true)"
    if [[ "$state" != "active" ]]; then
        orionx_log_error "$BLUETOOTH_UNIT is $state, not active"
        return 1
    fi
    return 0
}

launch_manager() {
    # Best effort, only when an operator desktop is reachable from this sudo.
    [[ $DRY_RUN -eq 0 ]] || return 0
    [[ -n "${SUDO_USER:-}" && -n "${DISPLAY:-}" ]] || return 0
    command -v blueman-manager >/dev/null 2>&1 || return 0
    sudo -u "$SUDO_USER" env DISPLAY="$DISPLAY" \
        XAUTHORITY="${XAUTHORITY:-/home/$SUDO_USER/.Xauthority}" \
        setsid blueman-manager >/dev/null 2>&1 < /dev/null &
}

# ---------------------------------------------------------------------------
# Idempotence gate — before the root/network preflight, so --check and a
# re-run on a provisioned deck work offline.
# ---------------------------------------------------------------------------
if bluetooth_installed; then
    orionx_log_info "Bluetooth support already installed ($(dpkg-query -W -f='${Version}' bluez 2>/dev/null || echo bluez), blueman)."
    if [[ $CHECK_ONLY -eq 1 ]]; then
        exit 0
    fi
    if [[ $FORCE -eq 0 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            orionx_log_info "[dry-run] would only re-assert the service and the radio."
            exit 0
        fi
        orionx_require_root
        orionx_log_info "Nothing to install. Re-asserting the service and the radio (re-run with --force to reinstall)."
        enable_radio || exit 1
        orionx_log_info "Bluetooth is on. Pair with: blueman-manager  (panel: blueman-applet)"
        exit 0
    fi
    orionx_log_info "--force given; reinstalling over the existing install."
elif [[ $CHECK_ONLY -eq 1 ]]; then
    orionx_log_info "Bluetooth support is NOT installed (no bluez + blueman)."
    orionx_log_info "  Install with: sudo $0"
    exit 1
fi

# ---------------------------------------------------------------------------
# Plan: the on-ISO cache when it is there, the network otherwise.
# ---------------------------------------------------------------------------
# No mapfile: the unit tests run this under macOS bash 3.2 as well.
CACHED=()
while IFS= read -r _deb; do
    [[ -n "$_deb" ]] && CACHED+=("$_deb")
done < <(cache_debs)
if [[ ${#CACHED[@]} -gt 0 ]]; then
    SOURCE="cache"
else
    SOURCE="network"
fi

orionx_log_info "=== Orion-X optional installer: Bluetooth support ==="
orionx_log_info "  Packages: $BLUETOOTH_PACKAGES (--no-install-recommends)"
orionx_log_info "  Size:     ~7 MB (measured 2026-11-01 against the v3.1.2 package set)"
orionx_log_info "  License:  GPL-2 (bluez), GPL-3 (blueman), LGPL (pulseaudio module)"
if [[ "$SOURCE" == "cache" ]]; then
    orionx_log_info "  Source:   on-ISO cache $BLUETOOTH_CACHE (${#CACHED[@]} debs, baked at build time; no network needed)"
else
    orionx_log_info "  Source:   network (deb.debian.org); the on-ISO cache at $BLUETOOTH_CACHE is empty or absent"
fi
orionx_log_info "  Radio:    this turns the Bluetooth radio ON (rfkill unblock bluetooth)."
orionx_log_info "            Off again: sudo rfkill block bluetooth   Remove: sudo apt-get purge bluez blueman"
orionx_log_info "  Persist:  RAM overlay on a plain live stick (gone at reboot); kept with a persistence volume"
orionx_log_info "  Mission:  operate — a mouse, keyboard or headset on the deck"

if [[ $DRY_RUN -eq 1 ]]; then
    if [[ "$SOURCE" == "cache" ]]; then
        orionx_log_info "[dry-run] apt-get install -y --no-install-recommends <${#CACHED[@]} cached debs>"
        printf '    %s\n' "${CACHED[@]##*/}"
    else
        # shellcheck disable=SC2086
        orionx_log_info "[dry-run] apt-get update && apt-get install -y --no-install-recommends $BLUETOOTH_PACKAGES"
    fi
    enable_radio
    orionx_log_info "[dry-run] nothing was changed."
    exit 0
fi

orionx_require_root

installed_from=""
if [[ "$SOURCE" == "cache" ]]; then
    orionx_log_info "Installing from the on-ISO cache..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${CACHED[@]}"; then
        installed_from="cache"
    else
        orionx_log_error "apt rejected the cached debs (a dependency the image no longer carries?). Falling back to the network."
    fi
fi
if [[ -z "$installed_from" ]]; then
    orionx_require_network deb.debian.org
    # shellcheck disable=SC2086
    orionx_apt_install --no-install-recommends $BLUETOOTH_PACKAGES
    installed_from="network"
fi

if ! bluetooth_installed; then
    orionx_log_error "apt finished but bluez/blueman are not both installed and runnable. Nothing else was changed."
    exit 1
fi

enable_radio || exit 1
launch_manager

BLUEZ_VER="$(dpkg-query -W -f='${Version}' bluez 2>/dev/null || echo '?')"
orionx_log_info "=== Installed: bluez $BLUEZ_VER + blueman (from the $installed_from) ==="
orionx_log_info "bluetooth.service is active and the radio is unblocked. Pair a device:"
orionx_log_info "  blueman-manager          # graphical (opened for you if a desktop was reachable)"
orionx_log_info "  bluetoothctl             # terminal: scan on / pair <MAC> / connect <MAC>"
orionx_log_info "Turn the radio off again with: sudo rfkill block bluetooth"
bluetooth_emit notice "Bluetooth support installed from the $installed_from (bluez $BLUEZ_VER, blueman); bluetooth.service active, radio unblocked. The deck now has one more radio on."
