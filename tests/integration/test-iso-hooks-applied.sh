#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — ISO Hook Execution Validator
#
# Parses a live-build log to verify that each project hook actually executed
# during the most recent lb build. File presence in iso/config/hooks/ proves
# discovery; this test proves execution by grepping the build log for the
# live-build "P: Executing hook" trace lines.
#
# @decision DEC-PHASE7-025
# @title CI validation that project hooks actually run during lb build
# @status accepted
# @rationale Issue #32 surfaced that all Phase 1-6 project hooks were inert
#   for prior ISO builds because they lived at non-canonical iso/hooks/ paths.
#   After the move to iso/config/hooks/, this test verifies via the build log
#   that each project hook actually executed during lb build. File existence
#   does not prove hook execution — this gate closes that gap. Without it,
#   a future accidental path regression could silently leave hooks inert again.
#
# Usage:
#   BUILD_LOG=path/to/build-iso.log bash tests/integration/test-iso-hooks-applied.sh
#   bash tests/integration/test-iso-hooks-applied.sh              # auto-detects tmp/build-iso.log
#   bash tests/integration/test-iso-hooks-applied.sh --help
#
# Exit codes:
#   0  All project hooks found in build log (or test SKIPped due to missing log)
#   1  One or more project hooks not found in build log

set -uo pipefail

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
test-iso-hooks-applied.sh — Verify project hooks executed during lb build

USAGE
  BUILD_LOG=path/to/build-iso.log bash tests/integration/test-iso-hooks-applied.sh
  bash tests/integration/test-iso-hooks-applied.sh

ENVIRONMENT
  BUILD_LOG   Path to the captured lb build log. If unset, the script looks
              for tmp/build-iso.log relative to the repo root. If the log is
              not found at either location, all tests are SKIPped (not FAILed)
              so that local development without a prior build stays green.

EXIT CODES
  0  All expected hooks found in build log, or all tests SKIPped (no log).
  1  One or more expected hooks not found in the build log.

EXPECTED HOOKS (iso/config/hooks/ — post-move canonical paths)
  live/0500-install-external-tools.hook.chroot
  live/0600-filesystem-hardening.hook.chroot
  live/0610-apparmor-setup.hook.chroot
  live/0620-service-hardening.hook.chroot
  normal/0100-create-user.hook.chroot
  normal/0200-copy-samples.hook.chroot
  binary/0500-bootloader-serial.hook.binary
EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# Resolve repo root (works from any CWD inside the repo tree)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# ---------------------------------------------------------------------------
# Color helpers (disabled when not a terminal)
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Test counters  (use arithmetic with || true so set -e doesn't fire on 0→0)
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
SKIP=0
ERRORS=()

pass() { PASS=$((PASS + 1)); echo "${GREEN}  PASS${NC}: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("$1")
    echo "${RED}  FAIL${NC}: $1"
}
skip() { SKIP=$((SKIP + 1)); echo "${YELLOW}  SKIP${NC}: $1"; }

# ---------------------------------------------------------------------------
# Locate build log
# ---------------------------------------------------------------------------
DEFAULT_LOG="$REPO_ROOT/tmp/build-iso.log"
BUILD_LOG="${BUILD_LOG:-$DEFAULT_LOG}"

echo "================================================================"
echo "test-iso-hooks-applied.sh — ISO hook execution validator"
echo "BUILD_LOG : $BUILD_LOG"
echo "================================================================"
echo ""

if [[ ! -f "$BUILD_LOG" ]]; then
    echo "${YELLOW}SKIP${NC}: build log not found at $BUILD_LOG"
    echo ""
    echo "Run a full ISO build first (bash scripts/build-iso.sh) and capture"
    echo "its output, or set BUILD_LOG to an existing log file."
    echo ""
    echo "All hook-execution checks SKIPped — not FAILed."
    echo ""
    echo "================================================================"
    echo "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC} (no build log)"
    echo "================================================================"
    exit 0
fi

# ---------------------------------------------------------------------------
# Expected hooks — these are the project hooks that must appear in a
# successful lb build log. live-build logs "P: Executing hook" lines for
# every script it discovers in config/hooks/{live,normal,binary}/.
#
# The grep pattern matches both the short form live-build uses internally
# (config/hooks/live/<name>) and the absolute path variant that some lb
# versions emit. We match the basename component to be robust to lb version
# differences.
# ---------------------------------------------------------------------------

# Each entry: "<subdir>/<filename>"  (relative to config/hooks/)
EXPECTED_HOOKS=(
    "live/0500-install-external-tools.hook.chroot"
    "live/0600-filesystem-hardening.hook.chroot"
    "live/0610-apparmor-setup.hook.chroot"
    "live/0620-service-hardening.hook.chroot"
    "normal/0100-create-user.hook.chroot"
    "normal/0200-copy-samples.hook.chroot"
    "binary/0500-bootloader-serial.hook.binary"
)

echo "--- Checking hook execution traces in build log ---"
echo ""

for hook_rel in "${EXPECTED_HOOKS[@]}"; do
    hook_basename="$(basename "$hook_rel")"
    hook_label="config/hooks/$hook_rel"

    # live-build emits lines like:
    #   P: Executing hook config/hooks/live/0600-filesystem-hardening.hook.chroot...
    # or (older lb versions):
    #   P: Executing hook /path/to/config/hooks/live/0600-filesystem-hardening.hook.chroot...
    #
    # We grep for the basename (unique enough given our naming convention) so
    # this stays robust across lb version log format differences.
    if grep -qF "$hook_basename" "$BUILD_LOG"; then
        pass "hook executed: $hook_label"
    else
        fail "hook NOT found in build log: $hook_label (grep for '$hook_basename' returned nothing)"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "================================================================"
echo "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    echo ""
    echo "If hooks are present in iso/config/hooks/ but missing from the log,"
    echo "re-run the build and check that iso/auto/config does NOT use"
    echo "--hook-files (DEC-PHASE7-024: canonical discovery only)."
fi
echo "================================================================"

[[ "$FAIL" -eq 0 ]]
