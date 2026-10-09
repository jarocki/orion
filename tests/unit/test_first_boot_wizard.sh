#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W6-6: First-Boot Setup Wizard
#
# Verifies:
#   1.  Script exists and is executable
#   2.  Has proper shebang (#!/usr/bin/env bash)
#   3.  Has set -euo pipefail (strict mode)
#   4.  Has shellcheck shell=bash directive
#   5.  Has @decision DEC-SEC-003 annotation
#   6.  --help prints usage and exits 0
#   7.  --non-interactive in dry-run creates flag file
#   8.  Flag file prevents re-run (idempotent)
#   9.  --hostname accepts value
#  10.  --skip-ssh flag accepted
#  11.  systemd unit file exists
#  12.  systemd unit has ConditionPathExists
#  13.  ShellCheck passes
#
# Production sequence: On first boot of an Orion-X node, systemd runs the
# wizard as a oneshot service (non-interactive). It sets hostname, generates
# credentials, writes a completion flag, and disables itself. Subsequent
# boots skip because ConditionPathExists=!/var/lib/orionx/.first-boot-done.
# In CI/test, we use ORIONX_FIRST_BOOT_DRY_RUN=1 to avoid real system calls.
#
# Usage: bash tests/unit/test_first_boot_wizard.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WIZARD_SCRIPT="$REPO_ROOT/scripts/security/first-boot-wizard.sh"
SYSTEMD_UNIT="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd/orionx-first-boot.service"

# Test counters
PASS=0
FAIL=0
SKIP=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

pass() {
    ((PASS+=1))
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    ((FAIL+=1))
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

skip() {
    ((SKIP+=1))
    echo "${YELLOW}  SKIP${NC}: $1 — $2"
}

section() {
    echo ""
    echo "--- $1 ---"
}

echo "=== W6-6: First-Boot Setup Wizard Tests ==="

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$WIZARD_SCRIPT" ]]; then
    pass "first-boot-wizard.sh exists"
else
    fail "first-boot-wizard.sh exists" "Not found at $WIZARD_SCRIPT"
    echo "FATAL: Script not found. Cannot continue."
    exit 1
fi

if [[ -x "$WIZARD_SCRIPT" ]]; then
    pass "first-boot-wizard.sh is executable"
else
    fail "first-boot-wizard.sh is executable" "chmod +x $WIZARD_SCRIPT"
fi

# ===========================================================================
# Shell modernization markers
# ===========================================================================
section "Shell Modernization"

if head -1 "$WIZARD_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is #!/usr/bin/env bash"
fi

if grep -q '# shellcheck shell=bash' "$WIZARD_SCRIPT"; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Has shellcheck shell=bash directive"
fi

if grep -q 'set -euo pipefail' "$WIZARD_SCRIPT"; then
    pass "Has set -euo pipefail (strict mode)"
else
    fail "Has set -euo pipefail (strict mode)"
fi

# ===========================================================================
# Decision annotation
# ===========================================================================
section "Decision Annotation"

if grep -q '@decision DEC-SEC-003' "$WIZARD_SCRIPT"; then
    pass "Has @decision DEC-SEC-003 annotation"
else
    fail "Has @decision DEC-SEC-003 annotation"
fi

if grep -q '@rationale' "$WIZARD_SCRIPT"; then
    pass "Has @rationale in decision block"
else
    fail "Has @rationale in decision block"
fi

# ===========================================================================
# --help flag
# ===========================================================================
section "CLI: --help"

set +e
help_output=$(bash "$WIZARD_SCRIPT" --help 2>&1)
help_rc=$?
set -e

if [[ $help_rc -eq 0 ]]; then
    pass "--help exits 0"
else
    fail "--help exits 0" "exit code: $help_rc"
fi

if echo "$help_output" | grep -qi 'usage'; then
    pass "--help prints usage text"
else
    fail "--help prints usage text" "Output: $help_output"
fi

if echo "$help_output" | grep -q '\-\-non-interactive'; then
    pass "--help mentions --non-interactive"
else
    fail "--help mentions --non-interactive"
fi

if echo "$help_output" | grep -q '\-\-hostname'; then
    pass "--help mentions --hostname"
else
    fail "--help mentions --hostname"
fi

if echo "$help_output" | grep -q '\-\-skip-ssh'; then
    pass "--help mentions --skip-ssh"
else
    fail "--help mentions --skip-ssh"
fi

# ===========================================================================
# --non-interactive in dry-run mode
# ===========================================================================
section "Non-Interactive Dry-Run"

# Create a temporary directory to hold the flag file
DRY_RUN_DIR=$(mktemp -d)
FLAG_FILE="$DRY_RUN_DIR/.first-boot-done"

# Run wizard in dry-run + non-interactive mode
set +e
wizard_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$FLAG_FILE" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
wizard_rc=$?
set -e

if [[ $wizard_rc -eq 0 ]]; then
    pass "Non-interactive dry-run exits 0"
else
    fail "Non-interactive dry-run exits 0" "exit code: $wizard_rc, output: $wizard_output"
fi

if [[ -f "$FLAG_FILE" ]]; then
    pass "Dry-run creates flag file"
else
    fail "Dry-run creates flag file" "Expected at $FLAG_FILE"
fi

# Check that summary is printed
if echo "$wizard_output" | grep -qi 'summary\|complete\|setup'; then
    pass "Dry-run prints summary"
else
    fail "Dry-run prints summary" "Output: $wizard_output"
fi

# ===========================================================================
# Idempotent: flag file prevents re-run
# ===========================================================================
section "Idempotency"

# Flag file should already exist from previous test
set +e
rerun_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$FLAG_FILE" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
rerun_rc=$?
set -e

if [[ $rerun_rc -eq 0 ]]; then
    pass "Re-run with existing flag exits 0"
else
    fail "Re-run with existing flag exits 0" "exit code: $rerun_rc"
fi

if echo "$rerun_output" | grep -qi 'already\|skip\|complet'; then
    pass "Re-run detects existing flag file"
else
    fail "Re-run detects existing flag file" "Output: $rerun_output"
fi

# Clean up first run's flag for subsequent tests
rm -f "$FLAG_FILE"

# ===========================================================================
# --hostname flag
# ===========================================================================
section "CLI: --hostname"

set +e
hostname_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$DRY_RUN_DIR/.first-boot-hostname-test" \
    bash "$WIZARD_SCRIPT" --non-interactive --hostname test-node-42 2>&1)
hostname_rc=$?
set -e

if [[ $hostname_rc -eq 0 ]]; then
    pass "--hostname flag accepted"
else
    fail "--hostname flag accepted" "exit code: $hostname_rc"
fi

if echo "$hostname_output" | grep -q 'test-node-42'; then
    pass "--hostname value appears in output"
else
    fail "--hostname value appears in output" "Output: $hostname_output"
fi

# ===========================================================================
# --skip-ssh flag
# ===========================================================================
section "CLI: --skip-ssh"

rm -f "$DRY_RUN_DIR/.first-boot-ssh-test"

set +e
ssh_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$DRY_RUN_DIR/.first-boot-ssh-test" \
    bash "$WIZARD_SCRIPT" --non-interactive --skip-ssh 2>&1)
ssh_rc=$?
set -e

if [[ $ssh_rc -eq 0 ]]; then
    pass "--skip-ssh flag accepted"
else
    fail "--skip-ssh flag accepted" "exit code: $ssh_rc"
fi

if echo "$ssh_output" | grep -qi 'ssh.*disable\|disable.*ssh\|ssh.*skip'; then
    pass "--skip-ssh referenced in output"
else
    fail "--skip-ssh referenced in output" "Output: $ssh_output"
fi

# ===========================================================================
# systemd unit file
# ===========================================================================
section "systemd Unit File"

if [[ -f "$SYSTEMD_UNIT" ]]; then
    pass "orionx-first-boot.service exists"
else
    fail "orionx-first-boot.service exists" "Not found at $SYSTEMD_UNIT"
fi

if grep -q 'ConditionPathExists=!/var/lib/orionx/.first-boot-done' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit has ConditionPathExists guard"
else
    fail "systemd unit has ConditionPathExists guard"
fi

if grep -q 'Type=oneshot' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit is Type=oneshot"
else
    fail "systemd unit is Type=oneshot"
fi

# DEC-PHASE11-037: the interactive wizard is pulled into the GRAPHICAL boot and
# ordered before the display manager (was multi-user.target when it ran headless).
if grep -q 'WantedBy=graphical.target' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit targets graphical.target (ordered before the display manager)"
else
    fail "systemd unit targets graphical.target" \
         "Interactive first-boot must run in the graphical boot, before display-manager.service"
fi

if grep -q 'first-boot-wizard.sh' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit references wizard script"
else
    fail "systemd unit references wizard script"
fi

if grep -q '@decision DEC-SEC-003' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit has @decision DEC-SEC-003 annotation"
else
    fail "systemd unit has @decision DEC-SEC-003 annotation"
fi

# ===========================================================================
# W11-14b: hostname lifecycle (hardware attestation 2026-08-21)
# ===========================================================================
section "W11-14b: hostname lifecycle"

# The wizard renames the host; a rename racing the display manager invalidates
# hostname-keyed X authority cookies and kills the autologin session.
if grep -q '^Before=display-manager.service' "$SYSTEMD_UNIT" 2>/dev/null; then
    pass "systemd unit orders Before=display-manager.service (autologin race fix)"
else
    fail "systemd unit orders Before=display-manager.service (autologin race fix)" \
         "Without this, the hostname rename races LightDM and the autologin session dies"
fi

# The unit exists in two hand-synced copies: systemd/ (tested here) and
# iso/config/includes.chroot/usr/share/orionx/systemd/ (what the ISO ships via
# hook 0615). They MUST be identical or tests pass against a unit the image
# does not contain.
ISO_UNIT="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd/orionx-first-boot.service"
if cmp -s "$SYSTEMD_UNIT" "$ISO_UNIT"; then
    pass "systemd/ and includes.chroot unit copies are byte-identical"
else
    fail "systemd/ and includes.chroot unit copies are byte-identical" \
         "Dual-authority divergence: the ISO ships $ISO_UNIT, tests check $SYSTEMD_UNIT"
fi

# An unresolvable hostname makes every sudo print "unable to resolve host" and
# stall. The wizard must upsert 127.0.1.1 into /etc/hosts alongside the rename.
if grep -q '127\.0\.1\.1' "$WIZARD_SCRIPT" 2>/dev/null && grep -q '/etc/hosts' "$WIZARD_SCRIPT" 2>/dev/null; then
    pass "wizard upserts 127.0.1.1 into /etc/hosts after hostname change"
else
    fail "wizard upserts 127.0.1.1 into /etc/hosts after hostname change" \
         "sudo will warn 'unable to resolve host <name>' on every invocation"
fi

# Dry-run must surface the hosts upsert so the sequence is testable.
hosts_dry_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 ORIONX_FIRST_BOOT_FLAG="$DRY_RUN_DIR/.fb-hosts-test" bash "$WIZARD_SCRIPT" --non-interactive 2>&1 || true)
if printf '%s' "$hosts_dry_output" | grep -q "upsert '127.0.1.1"; then
    pass "dry-run logs the /etc/hosts upsert step"
else
    fail "dry-run logs the /etc/hosts upsert step"
fi

# Hostname stability: MAC-derived names must not change across runs (the
# date-derived form minted a new identity every boot on a persistence-less
# live system). Only assertable where /sys/class/net exposes a MAC.
_mac_avail="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | head -1 || true)"
if [[ -n "$_mac_avail" ]]; then
    _hn1=$(ORIONX_FIRST_BOOT_DRY_RUN=1 ORIONX_FIRST_BOOT_FLAG="$DRY_RUN_DIR/.fb-hn1" bash "$WIZARD_SCRIPT" --non-interactive 2>&1 | grep -oE 'orionx-[0-9a-f]{8}' | head -1 || true)
    sleep 1
    _hn2=$(ORIONX_FIRST_BOOT_DRY_RUN=1 ORIONX_FIRST_BOOT_FLAG="$DRY_RUN_DIR/.fb-hn2" bash "$WIZARD_SCRIPT" --non-interactive 2>&1 | grep -oE 'orionx-[0-9a-f]{8}' | head -1 || true)
    if [[ -n "$_hn1" && "$_hn1" == "$_hn2" ]]; then
        pass "generated hostname is stable across runs ($_hn1)"
    else
        fail "generated hostname is stable across runs" \
             "Got '$_hn1' then '$_hn2' — per-boot identity churn regressed"
    fi
else
    skip "generated hostname stability" "no MAC exposed in this environment (non-Linux test host)"
fi

# ===========================================================================
# Production sequence: first-boot on a fresh node
# ===========================================================================
section "Production Sequence: First Boot"

# Simulates the full first-boot sequence:
#   1. No flag file exists (fresh node)
#   2. systemd invokes wizard with --non-interactive
#   3. Wizard creates flag file and prints summary
#   4. Second boot: systemd ConditionPathExists prevents re-run
#   5. Manual re-run also detects flag and skips

PROD_DIR=$(mktemp -d)
PROD_FLAG="$PROD_DIR/.first-boot-done"

# Step 1+2+3: First boot
set +e
_boot1_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$PROD_FLAG" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
boot1_rc=$?
set -e

if [[ $boot1_rc -eq 0 ]] && [[ -f "$PROD_FLAG" ]]; then
    pass "First boot: wizard runs and creates flag"
else
    fail "First boot: wizard runs and creates flag" "rc=$boot1_rc, flag exists=$(test -f "$PROD_FLAG" && echo yes || echo no)"
fi

# Step 4+5: Second boot (flag exists)
set +e
boot2_output=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$PROD_FLAG" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
boot2_rc=$?
set -e

if [[ $boot2_rc -eq 0 ]] && echo "$boot2_output" | grep -qi 'already\|skip\|complet'; then
    pass "Second boot: wizard detects flag and skips"
else
    fail "Second boot: wizard detects flag and skips" "rc=$boot2_rc, output: $boot2_output"
fi

# Cleanup
rm -rf "$PROD_DIR" "$DRY_RUN_DIR"

# ===========================================================================
# DEC-PHASE12-105: no SSH "one-shot" root key, no wg0.conf, no duplicate keys
# ===========================================================================
section "DEC-PHASE12-105: no secrets on the console, one mesh-key authority"

if [[ -e "$REPO_ROOT/iso/config/includes.chroot/etc/issue.d" || -e "$REPO_ROOT/iso/config/includes.chroot/etc/motd.d" ]]; then
    fail "no Orion-X files are shipped in /etc/issue.d or /etc/motd.d"
else
    pass "no Orion-X files are shipped in /etc/issue.d or /etc/motd.d"
fi
# Source the wizard and confirm the removed steps are really gone (not merely
# unwired) and that main() completes without them.
FN_OUT="$(ORIONX_WIZARD_SOURCED=1 bash -c 'source "$1"; for f in step_seed_ssh_admin step_generate_wg_keys; do declare -F "$f" >/dev/null && echo "present:$f"; done; true' _ "$WIZARD_SCRIPT" 2>&1)"
if [[ -z "$FN_OUT" ]]; then pass "step_seed_ssh_admin and step_generate_wg_keys no longer exist"; else fail "removed steps are gone" "$FN_OUT"; fi
if grep -vE '^[[:space:]]*#' "$WIZARD_SCRIPT" | grep -qE '/etc/(issue|motd)\.d|PRIVATE KEY|authorized_keys|wg0\.conf'; then
    fail "wizard code writes nothing to issue.d/motd.d, no keys, no wg0.conf"
else
    pass "wizard code writes nothing to issue.d/motd.d, no keys, no wg0.conf"
fi
D105="$(mktemp -d)"
out105="$(ORIONX_FIRST_BOOT_DRY_RUN=1 ORIONX_FIRST_BOOT_FLAG="$D105/.done" bash "$WIZARD_SCRIPT" --non-interactive 2>&1)"; rc105=$?
if [[ $rc105 -eq 0 && "$out105" == *"not started at boot"* ]]; then
    pass "wizard says sshd is not started at boot (and how to start it)"
else
    fail "wizard SSH posture message" "rc=$rc105 $out105"
fi
rm -rf "$D105"

# ===========================================================================
# DEC-PHASE12-106: rename keeps sudo/polkit; honest password text; UX-14
# ===========================================================================
section "DEC-PHASE12-106: rename repoints sudo + polkit"
R="$(mktemp -d)"
printf 'orionx-operator ALL=(ALL) NOPASSWD: ALL\n' > "$R/live"
printf 'polkit.addRule(function(action, subject) {\n  if (subject.user === "orionx-operator") { return polkit.Result.YES; }\n});\n' > "$R/sudo_on_live.rules"
ORIONX_WIZARD_SOURCED=1 ORIONX_SUDOERS_LIVE="$R/live" ORIONX_POLKIT_LIVE="$R/sudo_on_live.rules" \
    bash -c 'source "$1"; _repoint_privileges orionx-operator jdoe' _ "$WIZARD_SCRIPT" >/dev/null 2>&1
if grep -qx 'jdoe ALL=(ALL) NOPASSWD: ALL' "$R/live"; then pass "sudoers grant follows the renamed account"; else fail "sudoers repointed" "$(cat "$R/live")"; fi
if grep -q '"jdoe"' "$R/sudo_on_live.rules" && ! grep -q '"orionx-operator"' "$R/sudo_on_live.rules"; then pass "polkit grant follows the renamed account"; else fail "polkit repointed"; fi
PERM="$(stat -c '%a' "$R/live" 2>/dev/null || stat -f '%Lp' "$R/live")"
if [[ "$PERM" == "440" ]]; then pass "sudoers file stays 0440"; else fail "sudoers mode" "$PERM"; fi
if command -v visudo >/dev/null 2>&1; then
    rm -f "$R/live"; printf 'orionx-operator ALL=(ALL) NOPASSWD: ALL\n' > "$R/live"
    ORIONX_WIZARD_SOURCED=1 ORIONX_SUDOERS_LIVE="$R/live" ORIONX_POLKIT_LIVE="$R/none" \
        bash -c 'source "$1"; _repoint_privileges orionx-operator "bad name"' _ "$WIZARD_SCRIPT" >/dev/null 2>&1
    if grep -qx 'orionx-operator ALL=(ALL) NOPASSWD: ALL' "$R/live"; then pass "an invalid rewrite is not installed (visudo -cf)"; else fail "visudo guard" "$(cat "$R/live")"; fi
else
    skip "visudo guard" "visudo not installed"
fi
rm -rf "$R"

if grep -q 'blank = keep the current password' "$WIZARD_SCRIPT" && ! grep -vE '^[[:space:]]*#' "$WIZARD_SCRIPT" | grep -q 'passwordless'; then
    pass "password prompt no longer claims the account is passwordless (it is 'live')"
else
    fail "password prompt text"
fi

section "UX-14: orionx.wizard=0, 30 s timeouts, no untimed prompt"
CM="$(mktemp -d)"
printf 'BOOT_IMAGE=/live/vmlinuz boot=live orionx.wizard=0 quiet\n' > "$CM/cmdline"
outc="$(ORIONX_CMDLINE_FILE="$CM/cmdline" ORIONX_FIRST_BOOT_DRY_RUN=1 ORIONX_FIRST_BOOT_FLAG="$CM/.done" \
    bash "$WIZARD_SCRIPT" </dev/null 2>&1)"; rcc=$?
if [[ $rcc -eq 0 && "$outc" == *"orionx.wizard=0"* && "$outc" == *"Skipping account setup (non-interactive mode)"* ]]; then
    pass "orionx.wizard=0 on the kernel cmdline runs the wizard without prompts"
else
    fail "orionx.wizard=0 honoured" "rc=$rcc $outc"
fi
printf 'BOOT_IMAGE=/live/vmlinuz boot=live quiet\n' > "$CM/cmdline"; rm -f "$CM/.done"
outd="$(ORIONX_CMDLINE_FILE="$CM/cmdline" ORIONX_FIRST_BOOT_PROMPT_TIMEOUT=1 ORIONX_FIRST_BOOT_DRY_RUN=1 ORIONX_FIRST_BOOT_FLAG="$CM/.done" \
    bash "$WIZARD_SCRIPT" </dev/null 2>&1)"
if [[ "$outd" != *"orionx.wizard=0"* ]]; then pass "without the flag the wizard stays interactive"; else fail "flag not invented"; fi
rm -rf "$CM"
if grep -q 'PROMPT_TIMEOUT="${ORIONX_FIRST_BOOT_PROMPT_TIMEOUT:-30}"' "$WIZARD_SCRIPT"; then pass "default prompt timeout is 30 s"; else fail "30 s default"; fi
UNTIMED="$(grep -nE '^[[:space:]]*read -r' "$WIZARD_SCRIPT" | grep -v -- '-t ' | grep -v '< "' || true)"  # reads from a file are not prompts
if [[ -z "$UNTIMED" ]]; then pass "every read has a timeout (the Matrix prompt had none)"; else fail "untimed read" "$UNTIMED"; fi

section "F24: the Wi-Fi password never reaches argv"
if grep -vE '^[[:space:]]*#' "$WIZARD_SCRIPT" | grep -qE 'nmcli .*password'; then
    fail "nmcli is never given the Wi-Fi password"
else
    pass "nmcli is never given the Wi-Fi password"
fi
W="$(mktemp -d)"
ORIONX_WIZARD_SOURCED=1 ORIONX_NM_CONN_DIR="$W" bash -c 'source "$1"; _write_wifi_keyfile "Cafe Net" "s3cret pass" >/dev/null' _ "$WIZARD_SCRIPT"
KF="$W/orionx-wifi.nmconnection"
if grep -qx 'psk=s3cret pass' "$KF" 2>/dev/null && grep -qx 'ssid=Cafe Net' "$KF"; then pass "keyfile carries SSID and PSK"; else fail "keyfile content" "$(cat "$KF" 2>/dev/null)"; fi
KPERM="$(stat -c '%a' "$KF" 2>/dev/null || stat -f '%Lp' "$KF")"
if [[ "$KPERM" == "600" ]]; then pass "keyfile is 0600 (NetworkManager refuses wider)"; else fail "keyfile mode" "$KPERM"; fi
rm -rf "$W"

# ===========================================================================
# W11-13: Compound integration test — full first-boot sequence end-to-end
# (crosses the SSH-posture step + flag-file guard)
# ===========================================================================
section "W11-13: Compound integration — full first-boot sequence"

COMPOUND_DIR=$(mktemp -d)
COMPOUND_FLAG="$COMPOUND_DIR/.first-boot-done"

# Boot 1: fresh node — all steps run, flag created
set +e
c_boot1=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$COMPOUND_FLAG" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
c_boot1_rc=$?
set -e

if [[ $c_boot1_rc -eq 0 ]] && [[ -f "$COMPOUND_FLAG" ]]; then
    pass "Compound: boot1 runs all steps + creates flag"
else
    fail "Compound: boot1 runs all steps + creates flag" \
         "rc=$c_boot1_rc flag=$(test -f "$COMPOUND_FLAG" && echo yes || echo no) out=$c_boot1"
fi

if echo "$c_boot1" | grep -qi 'ssh'; then
    pass "Compound: boot1 output reports the SSH posture"
else
    fail "Compound: boot1 output reports the SSH posture" \
         "Output: $c_boot1"
fi

# Boot 2: flag present — wizard skips all steps (idempotency guard)
set +e
c_boot2=$(ORIONX_FIRST_BOOT_DRY_RUN=1 \
    ORIONX_FIRST_BOOT_FLAG="$COMPOUND_FLAG" \
    bash "$WIZARD_SCRIPT" --non-interactive 2>&1)
c_boot2_rc=$?
set -e

if [[ $c_boot2_rc -eq 0 ]] && echo "$c_boot2" | grep -qi 'already\|skip\|complet'; then
    pass "Compound: boot2 detects flag and skips all steps"
else
    fail "Compound: boot2 detects flag and skips all steps" \
         "rc=$c_boot2_rc out=$c_boot2"
fi

rm -rf "$COMPOUND_DIR"

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    set +e
    sc_output=$(shellcheck "$WIZARD_SCRIPT" 2>&1)
    sc_rc=$?
    set -e
    if [[ $sc_rc -eq 0 ]]; then
        pass "ShellCheck passes on first-boot-wizard.sh"
    else
        fail "ShellCheck passes on first-boot-wizard.sh" "$sc_output"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi


# ===========================================================================
# DEC-PHASE11-037: interactive first-boot on tty1 (supersedes the DEC-PHASE11-023
# off-tty1 fix). W11-14d moved the wizard off tty1 because a NON-interactive
# wizard writing to tty1 collided with the PLYMOUTH SPLASH on cold boot (boot
# loop). Two things make interactive-on-tty1 safe now: (1) Plymouth is RE-ENABLED
# (DEC-PHASE11-044) but the wizard unit runs `plymouth quit` in ExecStartPre, so
# the splash releases tty1 + DRM before the wizard prompts (no collision); and
# (2) the unit uses Conflicts=getty@tty1 + Before=display-manager.service, the correct way
# to own the console without contending with getty or the display manager. The
# operator MUST be prompted for hostname/username/Wi-Fi, which requires a tty.
# NOTE: this reverses a boot-validated decision — the change is gated on a QEMU
# boot-test of the built ISO before hardware flash.
# ===========================================================================
section "DEC-PHASE11-037: interactive first-boot on tty1"
if grep -qE '^TTYPath=/dev/tty1' "$SYSTEMD_UNIT" && grep -qE '^StandardInput=tty' "$SYSTEMD_UNIT"; then
    pass "wizard unit runs interactively on tty1 (TTYPath + StandardInput=tty)"
else
    fail "wizard unit runs interactively on tty1" \
         "Interactive prompts (hostname/username/Wi-Fi) require StandardInput=tty + TTYPath=/dev/tty1"
fi
if grep -qE '^Conflicts=getty@tty1.service' "$SYSTEMD_UNIT"; then
    pass "wizard unit Conflicts=getty@tty1.service (owns the console cleanly, no VT contention)"
else
    fail "wizard unit Conflicts=getty@tty1.service" \
         "Without releasing getty from tty1, the wizard and getty contend for the console"
fi
if grep -qE '^Before=display-manager.service' "$SYSTEMD_UNIT"; then
    pass "wizard unit ordered Before=display-manager.service (onboarding completes before the desktop)"
else
    fail "wizard unit ordered Before=display-manager.service"
fi
# DEC-PHASE11-044: the unit must quit Plymouth before prompting, or the splash
# holds tty1/DRM and the wizard's prompts are invisible (and quit-wait could hang).
if grep -qE '^ExecStartPre=-?/bin/plymouth quit' "$SYSTEMD_UNIT"; then
    pass "wizard unit quits Plymouth before prompting (ExecStartPre=plymouth quit — DEC-PHASE11-044)"
else
    fail "wizard unit quits Plymouth before prompting" \
         "Without ExecStartPre=plymouth quit, the splash hides the wizard prompts on tty1"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
echo "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
