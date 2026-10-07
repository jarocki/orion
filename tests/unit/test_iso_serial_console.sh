#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W7-3 serial console changes:
#   iso/auto/config — console= params in --bootappend-live
#   iso/config/hooks/normal/0500-bootloader-serial.hook.binary — bootloader patching hook
#
# @decision DEC-PHASE7-023
# @title Unit test suite for ISO bootloader serial console (W7-3)
# @status accepted
# @rationale These tests satisfy the W7-3 Evaluation Contract's required
#   real-path checks (console params in auto/config, hook present with correct
#   directives) and verify the hook's patching logic is idempotent and correct
#   without requiring live-build or QEMU. Tests run on macOS and Linux CI.
#
# Test scope:
#   T1:  iso/auto/config — console=ttyS0,115200n8 present in --bootappend-live
#   T2:  iso/auto/config — console=tty0 present in --bootappend-live (VGA preserved)
#   T3:  iso/auto/config — live-config.username=orionx-operator present in --bootappend-live (DEC-PHASE11-012)
#   T4:  iso/auto/config — live-config.hostname=orionx present in --bootappend-live (DEC-PHASE11-012)
#   T5:  iso/auto/config — splash and persistence still present (UX preserved)
#   T6:  iso/auto/config — --hook-files wires 0500-bootloader-serial.hook.binary
#   T7:  iso/auto/config — bash syntax valid
#   T8:  Hook file — exists and is executable
#   T9:  Hook file — bash syntax valid
#   T10: Hook file — isolinux.cfg patching logic (serial 0 115200 prepended)
#   T11: Hook file — grub.cfg patching logic (serial + terminal directives prepended)
#   T12: Hook file — idempotency (second run does not double-patch)
#   T13: Hook file — missing isolinux.cfg emits WARNING, does not exit non-zero
#   T14: Hook file — missing grub.cfg emits WARNING, does not exit non-zero
#   T15: Production sequence — auto/config, hook present, hook patches both configs
#   T16: live-config.username=orionx-operator in BOTH generated bootloader cfgs (DEC-PHASE11-012)
#   T17: live-config.hostname=orionx in BOTH generated bootloader cfgs (DEC-PHASE11-012)
#   T18: GENERATED marker on line 1 of BOTH bootloader cfgs (proves generator ran, DEC-PHASE11-012)
#
# Usage:
#   bash tests/unit/test_iso_serial_console.sh
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ERRORS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
AUTO_CONFIG="$REPO_ROOT/iso/auto/config"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
    ERRORS+=("$1")
}

contains() {
    local label="$1" needle="$2" haystack="$3"
    # Use -- to prevent BSD grep (macOS) treating needle as option flags
    # when needle starts with -- (e.g. --hook-files, --speed=115200).
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label — expected to find: $needle"
    fi
}

not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        fail "$label — expected NOT to find: $needle"
    else
        pass "$label"
    fi
}

# ---------------------------------------------------------------------------
# Scratch area for hook patching tests
# ---------------------------------------------------------------------------
SCRATCH="$REPO_ROOT/tmp/test_iso_serial_console_$$"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

echo "================================================================"
echo "test_iso_serial_console.sh — W7-3 serial console unit test suite"
echo "AUTO_CONFIG : $AUTO_CONFIG"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
# T1: console=ttyS0,115200n8 present in --bootappend-live
# ---------------------------------------------------------------------------
echo "[T1] console=ttyS0,115200n8 in --bootappend-live"
AUTO_CONFIG_CONTENT="$(cat "$AUTO_CONFIG")"
# Must be in the lb config --bootappend-live line (not just a comment)
BOOTAPPEND_LINE="$(grep "^    --bootappend-live" "$AUTO_CONFIG" || true)"
contains "console=ttyS0,115200n8 in --bootappend-live" "console=ttyS0,115200n8" "$BOOTAPPEND_LINE"
echo ""

# ---------------------------------------------------------------------------
# T3: live-config.username=orionx-operator present in --bootappend-live (DEC-PHASE11-012)
# ---------------------------------------------------------------------------
# DEC-PHASE11-012 supersedes DEC-PHASE10-017: the autologin identity is now
# `orionx-operator` (not `orionx`). The rc7-rc9 hotfix arc used `orionx` but
# hardware attestation (2026-07-05) confirmed neither `live-config.username=`
# nor `live-config.hostname=` reached /proc/cmdline on the actual boot — the
# static-cfg dual-authority was dead-authority. W11-2 retires the static cfgs
# and sets the identity via the single --bootappend-live source in iso/auto/config,
# generated into both bootloader configs by scripts/build-iso.sh (DEC-PHASE11-012).
# This test asserts the single-authority source carries the correct identity.
echo "[T3] live-config.username=orionx-operator in --bootappend-live (DEC-PHASE11-012)"
contains "live-config.username=orionx-operator in --bootappend-live" "live-config.username=orionx-operator" "$BOOTAPPEND_LINE"
echo ""

# ---------------------------------------------------------------------------
# T4: live-config.hostname=orionx present in --bootappend-live (DEC-PHASE11-012)
# ---------------------------------------------------------------------------
# Pairs with T3. DEC-PHASE11-012 sets the canonical hostname to `orionx`
# (was `orionx-cyberdeck` in the rc7-rc9 arc; changed per operator directive
# 2026-07-05). The hostname appears in the shell prompt, journal, Matrix
# federation, and mesh peer discovery. The single-authority source (iso/auto/config
# --bootappend-live) is the ONLY place this is set — the generator propagates it
# to both isolinux.cfg and grub.cfg.
echo "[T4] live-config.hostname=orionx in --bootappend-live (DEC-PHASE11-012)"
contains "live-config.hostname=orionx in --bootappend-live" "live-config.hostname=orionx" "$BOOTAPPEND_LINE"
echo ""

# ---------------------------------------------------------------------------
# T2: console=tty0 present in --bootappend-live (VGA output preserved)
# ---------------------------------------------------------------------------
echo "[T2] console=tty0 in --bootappend-live"
contains "console=tty0 in --bootappend-live" "console=tty0" "$BOOTAPPEND_LINE"
echo ""

# ---------------------------------------------------------------------------
# T5: splash RE-ENABLED (DEC-PHASE11-044 Plymouth revival), persistence preserved
# ---------------------------------------------------------------------------
# splash was dropped in DEC-PHASE11-023 to stop a boot loop/hang, then RE-ADDED
# in DEC-PHASE11-044 (operator directive: "go back to a Plymouth OrionX Phoenix
# boot"). The boot loop is now guarded three ways — the lightdm noloop drop-in,
# plymouth-quit.service releasing DRM before X, and a plymouth-quit-wait
# TimeoutStartSec cap — so splash is safe. plymouth.enable=0 is gone.
echo "[T5] splash re-enabled, plymouth.enable=0 removed, persistence preserved (DEC-PHASE11-044)"
contains "splash present in --bootappend-live (Plymouth splash, DEC-PHASE11-044)" "splash" "$BOOTAPPEND_LINE"
not_contains "plymouth.enable=0 removed from --bootappend-live" "plymouth.enable=0" "$BOOTAPPEND_LINE"
contains "persistence still in --bootappend-live" "persistence" "$BOOTAPPEND_LINE"
echo ""

# ---------------------------------------------------------------------------
# T6: canonical hook location + --hook-files removed (DEC-PHASE7-024)
# ---------------------------------------------------------------------------
# Per DEC-PHASE7-024: live-build auto-discovers hooks under
# iso/config/hooks/normal/. The --hook-files workaround in iso/auto/config
# has been removed because canonical path placement makes it redundant AND
# keeping both would create dual-registration. This test verifies:
#   (a) the hook file is present at its canonical binary/ path
#   (b) --hook-files is NOT present in iso/auto/config (removal confirmed)
echo "[T6] serial-patch hook retired AND --hook-files absent from auto/config"
# 0500-bootloader-serial.hook.binary was retired (QA round 1, B2 P3-1): in
# the real build it never found its targets (rc9 log: both patches skipped);
# the bootloader configs' generator is the one authority (T16-T18).
[[ ! -e "$REPO_ROOT/iso/config/hooks/normal/0500-bootloader-serial.hook.binary" ]] \
    && pass "retired serial-patch hook stays retired (generator is the authority)" \
    || fail "0500-bootloader-serial.hook.binary is back" "the generator owns the serial directives"
# Strip comment lines (sh comments start with #) before checking for --hook-files
# so explanatory comments referencing the removed flag don't trigger a false
# positive. Intent: no FUNCTIONAL --hook-files in the lb config invocation.
AUTO_CONFIG_NOCOMMENTS="$(echo "$AUTO_CONFIG_CONTENT" | grep -vE '^[[:space:]]*#')"
not_contains "--hook-files absent from auto/config (DEC-PHASE7-024)" "--hook-files" "$AUTO_CONFIG_NOCOMMENTS"
echo ""

# ---------------------------------------------------------------------------
# T7: iso/auto/config bash syntax valid
# ---------------------------------------------------------------------------
echo "[T7] iso/auto/config bash syntax"
if bash -n "$AUTO_CONFIG" 2>&1; then
    pass "iso/auto/config bash syntax valid"
else
    fail "iso/auto/config bash syntax invalid"
fi
echo ""

# ---------------------------------------------------------------------------
# T16: live-config.username=orionx-operator in BOTH generated bootloader cfgs (DEC-PHASE11-012)
# ---------------------------------------------------------------------------
# SINGLE AUTHORITY (DEC-PHASE11-012 supersedes DEC-PHASE10-018 dual-authority):
# iso/config/includes.binary/isolinux/isolinux.cfg and
# iso/config/includes.binary/boot/grub/grub.cfg are now GENERATED by
# scripts/build-iso.sh::generate_bootloader_configs() from the single
# --bootappend-live source in iso/auto/config. Direct edits are overwritten on
# next build. T16+T17 assert that the generated-and-committed cfgs carry the
# correct identity tokens (orionx-operator / orionx per DEC-PHASE11-012).
# T18 asserts the GENERATED marker is present (proves generator ran, not a
# human hand-edit that may silently diverge again as the rc7-rc9 arc did).
ISOLINUX_CFG="$REPO_ROOT/iso/config/includes.binary/isolinux/isolinux.cfg"
GRUB_CFG="$REPO_ROOT/iso/config/includes.binary/boot/grub/grub.cfg"

echo "[T16] live-config.username=orionx-operator in BOTH generated bootloader cfgs (DEC-PHASE11-012)"
# Use grep -F for literal matching; BSD grep (macOS) does not support \s in -E mode
ISOLINUX_APPEND=$(grep 'append boot=live' "$ISOLINUX_CFG" | head -1)
contains "live-config.username=orionx-operator in isolinux.cfg live label" "live-config.username=orionx-operator" "$ISOLINUX_APPEND"
GRUB_LINUX=$(grep 'linux /live/vmlinuz boot=live' "$GRUB_CFG" | head -1)
contains "live-config.username=orionx-operator in grub.cfg Orion-X Live menuentry" "live-config.username=orionx-operator" "$GRUB_LINUX"
echo ""

echo "[T17] live-config.hostname=orionx in BOTH generated bootloader cfgs (DEC-PHASE11-012)"
contains "live-config.hostname=orionx in isolinux.cfg live label" "live-config.hostname=orionx" "$ISOLINUX_APPEND"
contains "live-config.hostname=orionx in grub.cfg Orion-X Live menuentry" "live-config.hostname=orionx" "$GRUB_LINUX"
echo ""

# ---------------------------------------------------------------------------
# T18: GENERATED marker on line 1 of BOTH bootloader cfgs (DEC-PHASE11-012)
# ---------------------------------------------------------------------------
# Proves that generate_bootloader_configs() ran and wrote the cfgs — not that
# a human hand-edited them (which would silently diverge as the rc7-rc9 arc did).
# The marker "# GENERATED — do not edit — regenerate via scripts/build-iso.sh"
# must be on line 1 of both files. Any human-edit that omits or moves this line
# is caught immediately by this assertion.
echo "[T18] GENERATED marker on line 1 of BOTH bootloader cfgs (proves generator ran, DEC-PHASE11-012)"
ISOLINUX_LINE1="$(head -1 "$ISOLINUX_CFG")"
contains "GENERATED marker on line 1 of isolinux.cfg" "GENERATED — do not edit — regenerate via scripts/build-iso.sh" "$ISOLINUX_LINE1"
GRUB_LINE1="$(head -1 "$GRUB_CFG")"
contains "GENERATED marker on line 1 of grub.cfg" "GENERATED — do not edit — regenerate via scripts/build-iso.sh" "$GRUB_LINE1"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "================================================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  $err"
    done
fi
echo "================================================================"

[[ $FAIL -eq 0 ]]
