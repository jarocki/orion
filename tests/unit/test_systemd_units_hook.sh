#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for 0615-install-systemd-units.hook.chroot (W7-4-A)
#
# Validates the hook file structurally — no chroot or root access needed.
# Asserts: file existence, permissions, shebang, strict mode, single
# autostart-array authority, correct install target, correct source path,
# all 12 unit file references present, and that the hook does NOT write
# directly to /etc/systemd/system/ (systemctl enable owns symlinks).
#
# @decision DEC-PHASE7-SYSTEMD-INSTALL-TEST-001
# @title Structural unit tests for systemd unit installation hook
# @status accepted
# @rationale The hook runs inside a live-build chroot as root during ISO
#   build, making direct execution impossible on macOS dev machines.
#   Structural validation catches regressions (missing unit reference,
#   broken shebang, wrong target path, duplicate array authority) without
#   requiring a full ISO build cycle. The compound-interaction check
#   verifies that the hook's install list and autostart list are both
#   present and that the single-authority array invariant holds.
#
# Production sequence:
#   1. live-build copies includes.chroot/usr/share/orionx/systemd/ into chroot
#   2. live-build runs 0615-install-systemd-units.hook.chroot (inside chroot)
#   3. Hook cp's units from /usr/share/orionx/systemd/ -> /lib/systemd/system/
#   4. Hook calls systemctl enable for each AUTOSTART_UNITS entry
#   5. live-build runs 0620-service-hardening.hook.chroot — now finds installed units
#
# Usage: bash tests/unit/test_systemd_units_hook.sh

set -euo pipefail

# Resolve repo root from this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK_FILE="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"

# ---------------------------------------------------------------------------
# Test counters — use ((VAR+=1)) to avoid set -e firing on zero-result
# arithmetic in bash 5+
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

# Color output when running in a terminal
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

echo "=== W7-4-A: Systemd Unit Installation Hook — Structural Tests ==="

# ===========================================================================
# 1. File existence and permissions
# ===========================================================================
section "File existence and permissions"

if [[ -f "$HOOK_FILE" ]]; then
    pass "hook file exists at canonical path"
else
    fail "hook file exists at canonical path" "Not found: $HOOK_FILE"
    echo ""
    echo "FATAL: hook file not found — cannot continue."
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if [[ -x "$HOOK_FILE" ]]; then
    pass "hook file is executable"
else
    fail "hook file is executable" "Run: chmod +x $HOOK_FILE"
fi

# ===========================================================================
# Read hook content once for all subsequent checks
# ===========================================================================
HOOK_CONTENT="$(cat "$HOOK_FILE")"
FIRST_LINE="$(head -n1 "$HOOK_FILE")"

# ===========================================================================
# 2. Shebang and strict mode
# ===========================================================================
section "Shebang and strict mode"

if [[ "$FIRST_LINE" == "#!/bin/bash" ]]; then
    pass "shebang is #!/bin/bash"
else
    fail "shebang is #!/bin/bash" "Got: $FIRST_LINE"
fi

if [[ "$HOOK_CONTENT" == *"set -euo pipefail"* ]]; then
    pass "has set -euo pipefail"
else
    fail "has set -euo pipefail" "strict mode directive missing"
fi

# ===========================================================================
# 3. Decision annotation
# ===========================================================================
section "@decision annotation"

if [[ "$HOOK_CONTENT" == *"@decision DEC-PHASE7-SYSTEMD-INSTALL-001"* ]]; then
    pass "has @decision DEC-PHASE7-SYSTEMD-INSTALL-001"
else
    fail "has @decision DEC-PHASE7-SYSTEMD-INSTALL-001" "@decision annotation missing or wrong ID"
fi

if [[ "$HOOK_CONTENT" == *"@status accepted"* ]]; then
    pass "has @status accepted"
else
    fail "has @status accepted"
fi

# ===========================================================================
# 4. Single autostart-array authority
#    The array must be declared exactly once. We grep for the array variable
#    name as a declaration (AUTOSTART_UNITS=() pattern).
# ===========================================================================
section "Single autostart-array authority"

ARRAY_DECL_COUNT="$(grep -c "^AUTOSTART_UNITS=(" "$HOOK_FILE" || true)"
if [[ "$ARRAY_DECL_COUNT" -eq 1 ]]; then
    pass "AUTOSTART_UNITS array declared exactly once (single authority)"
else
    fail "AUTOSTART_UNITS array declared exactly once (single authority)" \
         "Found $ARRAY_DECL_COUNT declarations; expected 1"
fi

# ===========================================================================
# 5. Autostart array contains exactly the documented 8 members
#    W10-1 added 2 to AUTOSTART_UNITS (only the integrity check + socket;
#    runtime + warmup are lazy/opt-in)
# ===========================================================================
section "Autostart array members"

EXPECTED_AUTOSTART=(
    "matrix-synapse-orionx.service"
    "orionx-mesh-discover.timer"
    "orionx-mesh-health.timer"
    "orionx-mesh-beacon.service"
    "orionx-firewall.service"
    "orionx-first-boot.service"
    # W10-1 added 2 Nebula units (DEC-PHASE10-009 integrity + DEC-PHASE10-010 socket lazy-start)
    "nebula-integrity-check.service"
    "nebula-runtime.socket"
)

for unit in "${EXPECTED_AUTOSTART[@]}"; do
    if [[ "$HOOK_CONTENT" == *"\"$unit\""* ]]; then
        pass "autostart array contains: $unit"
    else
        fail "autostart array contains: $unit" "Unit not found in AUTOSTART_UNITS array"
    fi
done

# Count quoted unit entries inside the AUTOSTART_UNITS block to verify
# exactly 8 members. Extract just the lines between AUTOSTART_UNITS=(
# and the closing ) to avoid false positives from the UNIT_FILES array.
# W10-1 added 2 to AUTOSTART_UNITS (only the integrity check + socket;
# runtime + warmup are lazy/opt-in)
AUTOSTART_BLOCK="$(awk '/^AUTOSTART_UNITS=\(/{p=1} p{print} /^\)/{if(p) p=0}' "$HOOK_FILE")"
AUTOSTART_MEMBER_COUNT="$(grep -c '".*\.service"\|".*\.timer"\|".*\.socket"' <(echo "$AUTOSTART_BLOCK") || true)"
if [[ "$AUTOSTART_MEMBER_COUNT" -eq 8 ]]; then
    pass "AUTOSTART_UNITS array has exactly 8 members"
else
    fail "AUTOSTART_UNITS array has exactly 8 members" \
         "Found $AUTOSTART_MEMBER_COUNT; expected 8"
fi

# ===========================================================================
# 6. Install target is /lib/systemd/system/ (NOT /etc/systemd/system/)
# ===========================================================================
section "Install target path"

if [[ "$HOOK_CONTENT" == *"/lib/systemd/system"* ]]; then
    pass "references /lib/systemd/system/ as install target"
else
    fail "references /lib/systemd/system/ as install target" \
         "Units must go to /lib/systemd/system/ not /etc/systemd/system/"
fi

# ===========================================================================
# 7. Source path is /usr/share/orionx/systemd/
# ===========================================================================
section "Source path"

if [[ "$HOOK_CONTENT" == *"/usr/share/orionx/systemd"* ]]; then
    pass "references /usr/share/orionx/systemd/ as source path"
else
    fail "references /usr/share/orionx/systemd/ as source path" \
         "Source path missing or incorrect"
fi

# ===========================================================================
# 8. All 12 expected unit file names referenced for copy
#    W10-1 added 4 Nebula units (DEC-PHASE10-009 integrity + DEC-PHASE10-010
#    socket activation)
# ===========================================================================
section "All 12 unit files referenced"

EXPECTED_UNITS=(
    "matrix-synapse-orionx.service"
    "orionx-mesh-health.service"
    "orionx-mesh-health.timer"
    "orionx-mesh-discover.service"
    "orionx-mesh-discover.timer"
    "orionx-mesh-beacon.service"
    "orionx-firewall.service"
    "orionx-first-boot.service"
    # W10-1 added 4 Nebula units (DEC-PHASE10-009 integrity + DEC-PHASE10-010 socket lazy-start)
    "nebula-integrity-check.service"
    "nebula-runtime.service"
    "nebula-runtime.socket"
    "nebula-warmup.service"
)

for unit in "${EXPECTED_UNITS[@]}"; do
    if [[ "$HOOK_CONTENT" == *"\"$unit\""* ]]; then
        pass "unit file referenced: $unit"
    else
        fail "unit file referenced: $unit" "Not found in UNIT_FILES array"
    fi
done

# Count members in the UNIT_FILES array (must be exactly 12)
# W10-1 added 4 Nebula units (DEC-PHASE10-009 integrity + DEC-PHASE10-010 socket lazy-start)
UNIT_FILES_BLOCK="$(awk '/^UNIT_FILES=\(/{p=1} p{print} /^\)/{if(p) p=0}' "$HOOK_FILE")"
UNIT_FILES_COUNT="$(grep -c '".*\.service"\|".*\.timer"\|".*\.socket"' <(echo "$UNIT_FILES_BLOCK") || true)"
if [[ "$UNIT_FILES_COUNT" -eq 12 ]]; then
    pass "UNIT_FILES array has exactly 12 members"
else
    fail "UNIT_FILES array has exactly 12 members" \
         "Found $UNIT_FILES_COUNT; expected 12"
fi

# ===========================================================================
# 9. Hook does NOT write directly to /etc/systemd/system/
#    (systemctl enable owns the symlinks there; the hook must not bypass it)
# ===========================================================================
section "No direct writes to /etc/systemd/system/"

# We expect no cp/install commands that target /etc/systemd/system/.
# systemctl enable is fine (it manages symlinks), but direct file writes are not.
if grep -qE 'cp.*\/etc\/systemd\/system|install.*\/etc\/systemd\/system' "$HOOK_FILE"; then
    fail "hook does NOT write directly to /etc/systemd/system/" \
         "Found cp/install command targeting /etc/systemd/system/ — use systemctl enable instead"
else
    pass "hook does NOT write directly to /etc/systemd/system/"
fi

# ===========================================================================
# 10. Completion log marker present (grep-based validation in CI)
# ===========================================================================
section "Completion log marker"

if [[ "$HOOK_CONTENT" == *"[install-systemd-units] systemd unit installation complete"* ]]; then
    pass "completion marker '[install-systemd-units] systemd unit installation complete' present"
else
    fail "completion marker '[install-systemd-units] systemd unit installation complete' present" \
         "Marker missing — CI log grepping will fail"
fi

# ===========================================================================
# 11. ShellCheck (skip gracefully when not installed)
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$HOOK_FILE"; then
        pass "ShellCheck passes clean"
    else
        fail "ShellCheck passes clean"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# Compound-interaction: verify the production sequence is coherent
#   - includes.chroot staging directory exists with all 8 unit files
#   - hook file is lexically ordered before 0620-service-hardening
# ===========================================================================
section "Compound-interaction: production sequence coherence"

STAGING_DIR="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd"

if [[ -d "$STAGING_DIR" ]]; then
    pass "includes.chroot staging directory exists: $STAGING_DIR"
else
    fail "includes.chroot staging directory exists" "Missing: $STAGING_DIR"
fi

for unit in "${EXPECTED_UNITS[@]}"; do
    if [[ -f "$STAGING_DIR/$unit" ]]; then
        pass "unit file staged in includes.chroot: $unit"
    else
        fail "unit file staged in includes.chroot: $unit" \
             "Missing: $STAGING_DIR/$unit"
    fi
done

# Lexical ordering: 0615 must sort before 0620
HOOK_DIR="$REPO_ROOT/iso/config/hooks/live"
HOOK_0615="$HOOK_DIR/0615-install-systemd-units.hook.chroot"
HOOK_0620="$HOOK_DIR/0620-service-hardening.hook.chroot"

if [[ -f "$HOOK_0615" && -f "$HOOK_0620" ]]; then
    FIRST="$(printf '%s\n' "$HOOK_0615" "$HOOK_0620" | sort | head -n1)"
    if [[ "$FIRST" == "$HOOK_0615" ]]; then
        pass "lexical ordering: 0615-install-systemd-units runs before 0620-service-hardening"
    else
        fail "lexical ordering: 0615-install-systemd-units runs before 0620-service-hardening" \
             "0615 does not sort before 0620 — ProtectSystem injection will no-op"
    fi
else
    fail "lexical ordering check" "One or both hook files missing"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL + SKIP ))
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
