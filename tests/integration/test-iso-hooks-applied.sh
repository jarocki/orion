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
  live/0200-copy-samples.hook.chroot
  live/0500-install-external-tools.hook.chroot
  live/0600-filesystem-hardening.hook.chroot
  live/0610-apparmor-setup.hook.chroot
  live/0615-install-systemd-units.hook.chroot
  live/0620-service-hardening.hook.chroot
  normal/0100-create-user.hook.chroot
  normal/0500-bootloader-serial.hook.binary
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
#
# @decision DEC-PHASE12-120
# @title Hooks-applied gate: no log is a failure, and the expected hooks come
#   from the hook directories themselves
# @status accepted
# @rationale The gate hard-coded 8 of the project's hooks (0510, 0520, 0616,
#   0700, 0702, 0710, 0715, 0800, 0810, 0900 and the stock 0010/0050 were never
#   asserted; packages-build P2-7, release-tests F-15b), and with no log it
#   printed "All hook-execution checks SKIPped" and exited 0 with "0 passed"
#   (F-15a) — its default path tmp/build-iso.log is not where builds log. Now:
#   the expected set is every executable hook file under iso/config/hooks/
#   {live,normal}/ at test time (one authority: the directory), each must
#   appear exactly once as `P: Executing hook config/hooks/<rel>...`; no log
#   is a FAIL; the log must show no stale stage reuse (build-iso.sh's own
#   check_no_stale_skips, sourced, not copied) and no SOFT-FAIL line (a
#   soft-failed install means the image lacks a promised tool). The source
#   greps that used to follow (0700 .desktop text, package-list lines, F-15d)
#   moved to tests/unit/test_source_invariants.sh. The 22 dangling bullseye
#   stock-hook symlinks in hooks/normal/ were deleted in the same change:
#   trixie live-build ships its own (1000-/5000-/8000-/9000-) and never ran ours.
# ---------------------------------------------------------------------------
if [[ -z "${BUILD_LOG:-}" ]]; then
    BUILD_LOG="$(ls -t "$REPO_ROOT"/tmp/build-*.log 2>/dev/null | head -1)"
fi

echo "================================================================"
echo "test-iso-hooks-applied.sh — ISO hook execution validator"
echo "BUILD_LOG : ${BUILD_LOG:-<none found>}"
echo "================================================================"
echo ""

if [[ -z "${BUILD_LOG:-}" || ! -f "$BUILD_LOG" ]]; then
    echo "${RED}FAIL${NC}: no build log (set BUILD_LOG=<log of the build that produced the ISO>)."
    echo "      A hook gate with no evidence is not a pass (DEC-PHASE12-120)."
    exit 1
fi

HOOK_ROOT="${ORIONX_HOOK_ROOT:-$REPO_ROOT/iso/config/hooks}"
EXPECTED=()
for d in live normal; do
    for f in "$HOOK_ROOT/$d"/*.hook.chroot "$HOOK_ROOT/$d"/*.hook.binary; do
        [[ -e "$f" && -x "$f" ]] || continue     # dangling or non-executable files never run
        EXPECTED+=("$d/$(basename "$f")")
    done
done

echo "--- ${#EXPECTED[@]} hooks expected (derived from $HOOK_ROOT/{live,normal}) ---"
if [[ ${#EXPECTED[@]} -eq 0 ]]; then
    fail "no hooks found under $HOOK_ROOT — cannot validate anything"
fi
for rel in "${EXPECTED[@]}"; do
    n="$(grep -cF "P: Executing hook config/hooks/$rel..." "$BUILD_LOG" || true)"
    if [[ "$n" == 1 ]]; then
        pass "hook executed once: config/hooks/$rel"
    elif [[ "$n" == 0 ]]; then
        fail "hook NOT executed: config/hooks/$rel (no 'P: Executing hook' line)"
    else
        fail "hook executed $n times: config/hooks/$rel (a re-run in one log is not one build)"
    fi
done

echo ""
echo "--- build freshness and soft-fail markers ---"
if ( ORIONX_BUILD_ISO_LIB_ONLY=1; export ORIONX_BUILD_ISO_LIB_ONLY
     # shellcheck source=scripts/build-iso.sh
     . "$REPO_ROOT/scripts/build-iso.sh"; check_no_stale_skips "$BUILD_LOG" ) >/dev/null 2>"$REPO_ROOT/tmp/.hooks-stale.$$"; then
    pass "no stale 'Skipping <stage>, already done' outside bootstrap (DEC-PHASE12-113)"
else
    fail "stale stage reuse in the build log: $(tr '\n' ' ' < "$REPO_ROOT/tmp/.hooks-stale.$$")"
fi
rm -f "$REPO_ROOT/tmp/.hooks-stale.$$"
SOFT="$(grep -E '^SOFT-FAIL' "$BUILD_LOG" || true)"
if [[ -z "$SOFT" ]]; then
    pass "no SOFT-FAIL lines (every soft-fail install succeeded)"
else
    fail "SOFT-FAIL in the build log: $(echo "$SOFT" | head -3 | tr '\n' ' ')"
fi

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
    echo "--hook-files (DEC-PHASE7-024: canonical discovery only), and that the"
    echo "log is the one from the build that produced the ISO."
fi
echo "================================================================"

[[ "$FAIL" -eq 0 ]]
