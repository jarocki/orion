#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for 0700-orionx-setup.hook.chroot (W8-content-staging)
#
# Validates the hook file structurally — no chroot or root access needed.
# Asserts: file existence, permissions, shebang, strict mode, @decision
# annotation, PATH symlinks for all 8 scripts, XDG desktop entries, MOTD,
# completion marker, ShellCheck clean, and lexical ordering.
#
# @decision DEC-PHASE8-TEST-002
# @title Structural unit tests for 0700-orionx-setup chroot hook
# @status accepted
# @rationale The hook runs inside a live-build chroot as root during ISO
#   build, making direct execution impossible on macOS dev machines.
#   Structural validation catches regressions (missing script reference,
#   broken shebang, wrong XDG entry, missing completion marker) without
#   requiring a full ISO build cycle. The compound-interaction check verifies
#   that 0700 is the single PATH-symlink authority and that it sorts after
#   0620 in the live-build hook execution order.
#
# Production sequence:
#   1. live-build copies includes.chroot/ content into chroot filesystem
#   2. live-build runs 0500-0620 (tools, hardening, systemd units)
#   3. THIS HOOK (0700) runs inside chroot: symlinks, .desktop, MOTD, perms
#   4. live-build compresses chroot into filesystem.squashfs
#
# Usage: bash tests/unit/test_orionx_setup_hook_unit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HOOK_FILE="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
HOOK_DIR="$REPO_ROOT/iso/config/hooks/live"

# ---------------------------------------------------------------------------
# Test counters — use ((VAR+=1)) to avoid set -e firing on zero-result
# arithmetic in bash 5+
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0

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

echo "=== W8-content-staging: 0700-orionx-setup Hook — Structural Tests ==="

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

if [[ "$HOOK_CONTENT" == *"@decision DEC-PHASE8-005"* ]]; then
    pass "has @decision DEC-PHASE8-005"
else
    fail "has @decision DEC-PHASE8-005" "@decision annotation missing or wrong ID"
fi

if [[ "$HOOK_CONTENT" == *"@status accepted"* ]]; then
    pass "has @status accepted"
else
    fail "has @status accepted"
fi

# ===========================================================================
# 4. PATH symlinks for all 8 Orion-X scripts
# ===========================================================================
section "PATH symlinks for all 8 scripts"

EXPECTED_SCRIPTS=(
    "orionx-mesh"
    "setup-wireguard.sh"
    "setup-matrix.sh"
    "artifact-analyzer.py"
    "storyboard-gen.py"
    "toggle-theme.sh"
    "run-lynis.sh"
    "download-samples.sh"
)

for script in "${EXPECTED_SCRIPTS[@]}"; do
    if [[ "$HOOK_CONTENT" == *"\"$script\""* || "$HOOK_CONTENT" == *"[$script]"* || "$HOOK_CONTENT" == *"${script}"* ]]; then
        pass "references script for PATH symlink: $script"
    else
        fail "references script for PATH symlink: $script" \
             "Script not found in hook SCRIPT_MAP"
    fi
done

# Verify the mesh CLI has a special subpath (mesh/orionx-mesh not scripts/orionx-mesh)
if [[ "$HOOK_CONTENT" == *"mesh/orionx-mesh"* ]]; then
    pass "orionx-mesh uses mesh/ subpath (not flat scripts/ root)"
else
    fail "orionx-mesh uses mesh/ subpath (not flat scripts/ root)" \
         "Expected /opt/orionx/scripts/mesh/orionx-mesh path"
fi

# Verify /usr/bin/ is the symlink target directory
if [[ "$HOOK_CONTENT" == *"/usr/bin/"* ]]; then
    pass "PATH symlinks target /usr/bin/"
else
    fail "PATH symlinks target /usr/bin/" \
         "Expected ln -sf ... /usr/bin/<script>"
fi

# ===========================================================================
# 5. XDG desktop entries
# ===========================================================================
section "XDG desktop entries"

EXPECTED_DESKTOP_APPS=(
    "orionx-mesh"
    "setup-matrix.sh"
    "artifact-analyzer.py"
    "storyboard-gen.py"
)

for app in "${EXPECTED_DESKTOP_APPS[@]}"; do
    if [[ "$HOOK_CONTENT" == *"$app"* ]] && \
       [[ "$HOOK_CONTENT" == *".desktop"* ]]; then
        pass "XDG desktop entry references: $app"
    else
        fail "XDG desktop entry references: $app" \
             "App not found in .desktop creation block"
    fi
done

if [[ "$HOOK_CONTENT" == *"/usr/share/applications"* ]]; then
    pass "desktop entries written to /usr/share/applications/"
else
    fail "desktop entries written to /usr/share/applications/" \
         "Expected mkdir -p /usr/share/applications"
fi

if [[ "$HOOK_CONTENT" == *"[Desktop Entry]"* ]]; then
    pass "XDG [Desktop Entry] section present"
else
    fail "XDG [Desktop Entry] section present" \
         "No [Desktop Entry] header found — entries are not valid XDG format"
fi

# ===========================================================================
# 6. MOTD / welcome message
# ===========================================================================
section "MOTD and orionx-help bashrc function"

if [[ "$HOOK_CONTENT" == *"orionx-help"* ]]; then
    pass "references orionx-help function"
else
    fail "references orionx-help function" \
         "MOTD should reference orionx-help for user onboarding"
fi

if [[ "$HOOK_CONTENT" == *"/etc/update-motd.d/"* || "$HOOK_CONTENT" == *"/etc/motd"* || "$HOOK_CONTENT" == *"/etc/profile.d/"* ]]; then
    pass "MOTD/profile.d integration present"
else
    fail "MOTD/profile.d integration present" \
         "No MOTD or profile.d entry found in hook"
fi

# ===========================================================================
# 7. Permissions block
# ===========================================================================
section "Permissions block"

if [[ "$HOOK_CONTENT" == *"chmod 755"* ]]; then
    pass "chmod 755 applied to scripts"
else
    fail "chmod 755 applied to scripts" \
         "Expected: find /opt/orionx/scripts -type f -exec chmod 755"
fi

if [[ "$HOOK_CONTENT" == *"chmod 644"* ]]; then
    pass "chmod 644 applied to data/docs"
else
    fail "chmod 644 applied to data/docs"
fi

# ===========================================================================
# 8. Completion marker
# ===========================================================================
section "Completion log marker"

if [[ "$HOOK_CONTENT" == *"[orionx-setup] application layer setup complete"* ]]; then
    pass "completion marker '[orionx-setup] application layer setup complete' present"
else
    fail "completion marker '[orionx-setup] application layer setup complete' present" \
         "Marker missing — CI log grepping will fail"
fi

# ===========================================================================
# 9. Single authority: no other hook creates /usr/bin/ symlinks for orionx tools
# ===========================================================================
section "Single authority: PATH symlinks (no other hook duplicates this)"

for other_hook in "$HOOK_DIR"/0500-*.hook.chroot \
                  "$HOOK_DIR"/0600-*.hook.chroot \
                  "$HOOK_DIR"/0610-*.hook.chroot \
                  "$HOOK_DIR"/0615-*.hook.chroot \
                  "$HOOK_DIR"/0620-*.hook.chroot; do
    if [[ ! -f "$other_hook" ]]; then
        continue
    fi
    hook_name="$(basename "$other_hook")"
    if grep -q 'ln -sf.*\/usr\/bin\/orionx\|ln -sf.*\/usr\/bin\/setup-matrix\|ln -sf.*\/usr\/bin\/artifact-analyzer\|ln -sf.*\/usr\/bin\/storyboard-gen' "$other_hook" 2>/dev/null; then
        fail "single authority: $hook_name also creates /usr/bin symlinks for orionx tools" \
             "PATH symlinks must be owned by 0700-orionx-setup exclusively"
    else
        pass "single authority: $hook_name does NOT create orionx /usr/bin symlinks"
    fi
done

# ===========================================================================
# 10. Lexical ordering: 0700 sorts after 0620
# ===========================================================================
section "Lexical ordering"

HOOK_0620="$HOOK_DIR/0620-service-hardening.hook.chroot"
HOOK_0700="$HOOK_FILE"

if [[ -f "$HOOK_0620" && -f "$HOOK_0700" ]]; then
    FIRST="$(printf '%s\n' "$(basename "$HOOK_0620")" "$(basename "$HOOK_0700")" | sort | head -n1)"
    if [[ "$FIRST" == "$(basename "$HOOK_0620")" ]]; then
        pass "lexical ordering: 0620-service-hardening runs before 0700-orionx-setup"
    else
        fail "lexical ordering: 0620-service-hardening runs before 0700-orionx-setup" \
             "0700 must sort after all prior hardening hooks"
    fi
else
    fail "lexical ordering check" "One or both hook files missing: 0620=$HOOK_0620, 0700=$HOOK_0700"
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
# Compound-interaction: production sequence coherence
#   Verify the hook wires together correctly with includes.chroot staging:
#   a) The opt/orionx source dirs are referenced for permission-setting
#   b) usr/share/applications is created before desktop entries
#   c) The hook handles missing source files gracefully (no set -e abort
#      on a missing script — uses an if [[ -f ]] guard)
# ===========================================================================
section "Compound-interaction: hook ↔ staging coherence"

# a) Hook references /opt/orionx/ (staged by stage_application_content)
if [[ "$HOOK_CONTENT" == *"/opt/orionx"* ]]; then
    pass "hook references /opt/orionx/ (target of stage_application_content)"
else
    fail "hook references /opt/orionx/ (target of stage_application_content)" \
         "Hook must act on /opt/orionx/ which is staged by build-iso.sh"
fi

# b) mkdir for applications dir before desktop file writes
if [[ "$HOOK_CONTENT" == *"mkdir -p /usr/share/applications"* ]]; then
    pass "mkdir -p /usr/share/applications before desktop entries"
else
    fail "mkdir -p /usr/share/applications before desktop entries" \
         "Must create the directory before writing .desktop files"
fi

# c) Missing-script guard: the hook uses [[ -f src ]] before symlinking.
#    grep the raw file for the literal text (no shell expansion needed here).
if grep -q "\-f \"\$src\"" "$HOOK_FILE"; then
    pass "hook guards symlink creation with file-existence check"
else
    fail "hook guards symlink creation with file-existence check" \
         "Missing: if [[ -f \"\$src\" ]]; then — without guard, missing files abort hook with set -e"
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
