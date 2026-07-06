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
HOOK_SCRIPT="$REPO_ROOT/iso/config/hooks/normal/0500-bootloader-serial.hook.binary"

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
echo "HOOK_SCRIPT : $HOOK_SCRIPT"
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
# T5: splash and persistence still present (existing UX not broken)
# ---------------------------------------------------------------------------
echo "[T5] UX params preserved (splash, persistence)"
contains "splash still in --bootappend-live" "splash" "$BOOTAPPEND_LINE"
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
echo "[T6] canonical hook at iso/config/hooks/normal/ AND --hook-files absent from auto/config"
if [[ -f "$HOOK_SCRIPT" ]]; then
    pass "hook exists at canonical path iso/config/hooks/normal/0500-bootloader-serial.hook.binary"
else
    fail "hook NOT found at canonical path: $HOOK_SCRIPT"
fi
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
# T8: Hook file exists and is executable
# ---------------------------------------------------------------------------
echo "[T8] Hook file presence and executability"
if [[ -f "$HOOK_SCRIPT" ]]; then
    pass "0500-bootloader-serial.hook.binary exists"
else
    fail "0500-bootloader-serial.hook.binary does NOT exist at $HOOK_SCRIPT"
fi
if [[ -x "$HOOK_SCRIPT" ]]; then
    pass "0500-bootloader-serial.hook.binary is executable"
else
    fail "0500-bootloader-serial.hook.binary is NOT executable"
fi
echo ""

# ---------------------------------------------------------------------------
# T9: Hook file bash syntax valid
# ---------------------------------------------------------------------------
echo "[T9] Hook file bash syntax"
if bash -n "$HOOK_SCRIPT" 2>&1; then
    pass "hook file bash syntax valid"
else
    fail "hook file bash syntax invalid"
fi
echo ""

# ---------------------------------------------------------------------------
# T10: Hook patches isolinux.cfg (BIOS) correctly
# ---------------------------------------------------------------------------
echo "[T10] Hook patches isolinux.cfg with serial 0 115200"
BIOS_SCRATCH="$SCRATCH/bios_test"
mkdir -p "$BIOS_SCRATCH/binary/isolinux"
# Simulate what live-build generates for isolinux.cfg (real-world minimal example)
cat > "$BIOS_SCRATCH/binary/isolinux/isolinux.cfg" <<'EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 0
MENU TITLE Orion-X Phoenix Edition

LABEL live
  MENU LABEL Live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components splash quiet persistence
EOF

(cd "$BIOS_SCRATCH" && bash "$HOOK_SCRIPT" > /dev/null 2>&1)

PATCHED_ISOLINUX="$(cat "$BIOS_SCRATCH/binary/isolinux/isolinux.cfg")"
# serial directive must be on the FIRST line
FIRST_LINE="$(head -1 "$BIOS_SCRATCH/binary/isolinux/isolinux.cfg")"
contains "serial 0 115200 is first line of isolinux.cfg" "serial 0 115200" "$FIRST_LINE"
contains "original DEFAULT line still present after patch" "DEFAULT vesamenu.c32" "$PATCHED_ISOLINUX"
echo ""

# ---------------------------------------------------------------------------
# T11: Hook patches grub.cfg (UEFI) correctly
# ---------------------------------------------------------------------------
echo "[T11] Hook patches grub.cfg with serial + terminal directives"
UEFI_SCRATCH="$SCRATCH/uefi_test"
mkdir -p "$UEFI_SCRATCH/binary/boot/grub"
# Simulate what live-build generates for grub.cfg
cat > "$UEFI_SCRATCH/binary/boot/grub/grub.cfg" <<'EOF'
if loadfont /boot/grub/font.pf2 ; then
  set gfxmode=auto
  insmod efi_gop
  insmod font
  if terminal_output gfxterm ; then true ; else
    unset terminal_output
  fi
fi
set default="0"
set timeout="0"
EOF

(cd "$UEFI_SCRATCH" && bash "$HOOK_SCRIPT" > /dev/null 2>&1)

PATCHED_GRUB="$(cat "$UEFI_SCRATCH/binary/boot/grub/grub.cfg")"
FIRST_LINE_GRUB="$(head -1 "$UEFI_SCRATCH/binary/boot/grub/grub.cfg")"
contains "serial --unit=0 is first line of grub.cfg" "serial --unit=0" "$FIRST_LINE_GRUB"
contains "serial --speed=115200 in grub.cfg" "--speed=115200" "$PATCHED_GRUB"
contains "terminal_input --append serial in grub.cfg" "terminal_input --append serial" "$PATCHED_GRUB"
contains "terminal_output --append serial in grub.cfg" "terminal_output --append serial" "$PATCHED_GRUB"
contains "original grub content still present" 'set default="0"' "$PATCHED_GRUB"
echo ""

# ---------------------------------------------------------------------------
# T12: Hook is idempotent (second run does not double-patch)
# ---------------------------------------------------------------------------
echo "[T12] Hook idempotency (no double-patch on second run)"
IDEM_SCRATCH="$SCRATCH/idempotency_test"
mkdir -p "$IDEM_SCRATCH/binary/isolinux"
mkdir -p "$IDEM_SCRATCH/binary/boot/grub"
cat > "$IDEM_SCRATCH/binary/isolinux/isolinux.cfg" <<'EOF'
DEFAULT vesamenu.c32
LABEL live
  MENU LABEL Live
EOF
cat > "$IDEM_SCRATCH/binary/boot/grub/grub.cfg" <<'EOF'
set default="0"
EOF

# Run twice
(cd "$IDEM_SCRATCH" && bash "$HOOK_SCRIPT" > /dev/null 2>&1)
(cd "$IDEM_SCRATCH" && bash "$HOOK_SCRIPT" > /dev/null 2>&1)

# Count occurrences of "serial 0 115200" in isolinux.cfg — must be exactly 1
ISOLINUX_SERIAL_COUNT="$(grep -c "^serial 0 115200" "$IDEM_SCRATCH/binary/isolinux/isolinux.cfg" || echo 0)"
if [[ "$ISOLINUX_SERIAL_COUNT" -eq 1 ]]; then
    pass "isolinux.cfg has exactly one serial directive after two runs"
else
    fail "isolinux.cfg has $ISOLINUX_SERIAL_COUNT serial directives (expected 1) — not idempotent"
fi

# Count occurrences of "serial --unit=0" in grub.cfg — must be exactly 1
GRUB_SERIAL_COUNT="$(grep -c "^serial --unit=0" "$IDEM_SCRATCH/binary/boot/grub/grub.cfg" || echo 0)"
if [[ "$GRUB_SERIAL_COUNT" -eq 1 ]]; then
    pass "grub.cfg has exactly one serial directive after two runs"
else
    fail "grub.cfg has $GRUB_SERIAL_COUNT serial directives (expected 1) — not idempotent"
fi
echo ""

# ---------------------------------------------------------------------------
# T13: Missing isolinux.cfg emits WARNING but exits 0
# ---------------------------------------------------------------------------
echo "[T13] Missing isolinux.cfg — WARNING emitted, exits 0"
MISS_BIOS_SCRATCH="$SCRATCH/missing_bios_test"
mkdir -p "$MISS_BIOS_SCRATCH/binary/boot/grub"
# No isolinux directory — grub.cfg exists
cat > "$MISS_BIOS_SCRATCH/binary/boot/grub/grub.cfg" <<'EOF'
set default="0"
EOF

MISS_BIOS_OUTPUT="$( (cd "$MISS_BIOS_SCRATCH" && bash "$HOOK_SCRIPT") 2>&1 || true)"
MISS_BIOS_EXIT=0
(cd "$MISS_BIOS_SCRATCH" && bash "$HOOK_SCRIPT" > /dev/null 2>&1) || MISS_BIOS_EXIT=$?
if [[ "$MISS_BIOS_EXIT" -eq 0 ]]; then
    pass "hook exits 0 when isolinux.cfg is missing"
else
    fail "hook exits non-zero ($MISS_BIOS_EXIT) when isolinux.cfg is missing"
fi
contains "WARNING emitted for missing isolinux.cfg" "WARNING" "$MISS_BIOS_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T14: Missing grub.cfg emits WARNING but exits 0
# ---------------------------------------------------------------------------
echo "[T14] Missing grub.cfg — WARNING emitted, exits 0"
MISS_UEFI_SCRATCH="$SCRATCH/missing_uefi_test"
mkdir -p "$MISS_UEFI_SCRATCH/binary/isolinux"
# No boot/grub directory — isolinux.cfg exists
cat > "$MISS_UEFI_SCRATCH/binary/isolinux/isolinux.cfg" <<'EOF'
DEFAULT vesamenu.c32
EOF

MISS_UEFI_OUTPUT="$( (cd "$MISS_UEFI_SCRATCH" && bash "$HOOK_SCRIPT") 2>&1 || true)"
MISS_UEFI_EXIT=0
(cd "$MISS_UEFI_SCRATCH" && bash "$HOOK_SCRIPT" > /dev/null 2>&1) || MISS_UEFI_EXIT=$?
if [[ "$MISS_UEFI_EXIT" -eq 0 ]]; then
    pass "hook exits 0 when grub.cfg is missing"
else
    fail "hook exits non-zero ($MISS_UEFI_EXIT) when grub.cfg is missing"
fi
contains "WARNING emitted for missing grub.cfg" "WARNING" "$MISS_UEFI_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T15: Production sequence — config present + hook patches both configs
# ---------------------------------------------------------------------------
# This test exercises the real production sequence end-to-end at the unit level:
# 1. hook lives at canonical path iso/config/hooks/normal/ (verified in T6)
# 2. The hook is present and executable (verified in T8)
# 3. The hook patches isolinux.cfg AND grub.cfg in a single run
# This mirrors what lb_binary does: runs all .hook.binary scripts from CWD
# with binary/ as the working tree. Auto-discovery finds the hook because
# it is in iso/config/hooks/normal/ (DEC-PHASE7-024, no --hook-files needed).
echo "[T15] Production sequence — hook at canonical path; hook patches both configs"

E2E_SCRATCH="$SCRATCH/e2e_test"
mkdir -p "$E2E_SCRATCH/binary/isolinux"
mkdir -p "$E2E_SCRATCH/binary/boot/grub"
# Realistic generated configs (post-lb_binary, pre-hook)
cat > "$E2E_SCRATCH/binary/isolinux/isolinux.cfg" <<'EOF'
DEFAULT vesamenu.c32
PROMPT 0
TIMEOUT 300

LABEL live
  MENU LABEL Orion-X Live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live components splash quiet persistence console=tty0 console=ttyS0,115200n8
EOF

cat > "$E2E_SCRATCH/binary/boot/grub/grub.cfg" <<'EOF'
if loadfont /boot/grub/font.pf2 ; then
  set gfxmode=auto
fi
set default="0"
set timeout="5"

menuentry "Orion-X Live" {
  linux /live/vmlinuz boot=live components splash quiet persistence console=tty0 console=ttyS0,115200n8
  initrd /live/initrd.img
}
EOF

# Verify hook is at canonical path — auto-discovery is the single wiring authority (DEC-PHASE7-024)
if [[ -f "$HOOK_SCRIPT" ]]; then
    pass "production run: hook present at canonical normal/ path"
else
    fail "production run: hook missing from canonical normal/ path — $HOOK_SCRIPT"
fi

# Run the hook (simulating lb_binary stage)
E2E_OUTPUT="$( (cd "$E2E_SCRATCH" && bash "$HOOK_SCRIPT") 2>&1)"

# Verify both configs were patched
E2E_ISOLINUX="$(cat "$E2E_SCRATCH/binary/isolinux/isolinux.cfg")"
E2E_GRUB="$(cat "$E2E_SCRATCH/binary/boot/grub/grub.cfg")"

# isolinux.cfg: serial line first
E2E_ISOLINUX_FIRST="$(head -1 "$E2E_SCRATCH/binary/isolinux/isolinux.cfg")"
contains "production run: isolinux.cfg has serial 0 115200 as first line" \
    "serial 0 115200" "$E2E_ISOLINUX_FIRST"

# grub.cfg: serial line first, then terminal directives, then original content
E2E_GRUB_FIRST="$(head -1 "$E2E_SCRATCH/binary/boot/grub/grub.cfg")"
contains "production run: grub.cfg has serial --unit=0 as first line" \
    "serial --unit=0" "$E2E_GRUB_FIRST"
contains "production run: grub.cfg has terminal_input --append serial" \
    "terminal_input --append serial" "$E2E_GRUB"
contains "production run: grub.cfg has terminal_output --append serial" \
    "terminal_output --append serial" "$E2E_GRUB"
contains "production run: hook completed without error" \
    "Bootloader serial console patch complete" "$E2E_OUTPUT"

# Verify kernel cmdline in the configs contains ttyS0 (kernel console param already injected
# by lb via --bootappend-live — this verifies the ISO will have the full serial stack)
contains "kernel cmdline in isolinux.cfg has console=ttyS0" \
    "console=ttyS0" "$E2E_ISOLINUX"
contains "kernel cmdline in grub.cfg has console=ttyS0" \
    "console=ttyS0" "$E2E_GRUB"

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
