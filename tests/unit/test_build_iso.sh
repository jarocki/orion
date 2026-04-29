#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for scripts/build-iso.sh (W7-1 ISO build pipeline modernization)
#
# @decision DEC-PHASE7-002
# @title Unit test suite for modernized build-iso.sh
# @status accepted
# @rationale These tests fulfill the W7-1 Evaluation Contract requirement that
#   test_build_iso.sh passes (path resolution, prerequisite check, version flag,
#   dry-run mode) on macOS and Linux CI without requiring live-build installed.
#   Tests run in isolated temporary directories to avoid touching the real iso/
#   or output/ trees, and always clean up after themselves.
#
# Usage:
#   bash tests/unit/test_build_iso.sh
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ERRORS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BUILD_SCRIPT="$REPO_ROOT/scripts/build-iso.sh"

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("FAIL: $1")
    echo "  FAIL: $1"
}

run_test() {
    local name="$1"
    local result
    if result="$(eval "$2" 2>&1)"; then
        pass "$name"
    else
        fail "$name — output: $result"
    fi
}

run_test_fail() {
    # Assert the command exits non-zero
    local name="$1"
    local result
    if ! result="$(eval "$2" 2>&1)"; then
        pass "$name"
    else
        fail "$name — expected non-zero exit but got success; output: $result"
    fi
}

contains() {
    # Assert output contains a substring
    local name="$1"
    local needle="$2"
    local haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$name"
    else
        fail "$name — expected '$needle' in output; got: $haystack"
    fi
}

not_contains() {
    local name="$1"
    local needle="$2"
    local haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        pass "$name"
    else
        fail "$name — expected '$needle' NOT in output; got: $haystack"
    fi
}

# ---------------------------------------------------------------------------
# Setup: writable scratch area under tmp/ (Sacred Practice 3)
# ---------------------------------------------------------------------------
SCRATCH="$REPO_ROOT/tmp/test_build_iso_$$"
mkdir -p "$SCRATCH"

cleanup() {
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Helper: build a fake repo root with iso/ present (lowercase)
make_fake_repo() {
    local root="$1"
    mkdir -p "$root/iso"
    mkdir -p "$root/scripts"
    mkdir -p "$root/tmp"
    # Copy the real build script into the fake repo
    cp "$BUILD_SCRIPT" "$root/scripts/build-iso.sh"
}

# Helper: build a fake repo root WITHOUT iso/ (missing)
make_fake_repo_no_iso() {
    local root="$1"
    mkdir -p "$root/scripts"
    mkdir -p "$root/tmp"
    cp "$BUILD_SCRIPT" "$root/scripts/build-iso.sh"
}

echo "================================================================"
echo "test_build_iso.sh — W7-1 unit test suite"
echo "Script under test: $BUILD_SCRIPT"
echo "================================================================"
echo ""

# ---------------------------------------------------------------------------
# T1: Script exists and is executable
# ---------------------------------------------------------------------------
echo "[T1] Script presence and executability"
run_test "build-iso.sh exists" "[[ -f '$BUILD_SCRIPT' ]]"
run_test "build-iso.sh is executable" "[[ -x '$BUILD_SCRIPT' ]]"
echo ""

# ---------------------------------------------------------------------------
# T2: Version flag — script must contain v2.0.0-rc1, not v1.5.5
# ---------------------------------------------------------------------------
echo "[T2] Version string"
SCRIPT_CONTENT="$(cat "$BUILD_SCRIPT")"
not_contains "script does not hardcode v1.5.5" "v1.5.5" "$SCRIPT_CONTENT"
contains "script contains v2.0.0-rc1 default" "v2.0.0-rc1" "$SCRIPT_CONTENT"
echo ""

# ---------------------------------------------------------------------------
# T3: Path reference — functional lines must reference iso/ (lowercase), not ISO/
#
# We strip comment lines before checking because comments may mention the
# legacy uppercase path as a warning/explanation — what matters is that the
# executable code never assigns or uses ISO/ as a directory.
# ---------------------------------------------------------------------------
echo "[T3] Path references"
# Extract non-comment, non-empty lines for functional checks
SCRIPT_CODE="$(grep -v '^\s*#' "$BUILD_SCRIPT" | grep -v '^\s*$')"
# The ISO_DIR variable must be assigned the lowercase iso/ path, never uppercase ISO/
not_contains "functional code does not assign ISO_DIR to uppercase path" 'ISO_DIR="$REPO_ROOT/ISO"' "$SCRIPT_CODE"
not_contains "functional code does not hardcode /ISO path" '"/ISO"' "$SCRIPT_CODE"
contains "functional code assigns ISO_DIR to lowercase iso/" 'ISO_DIR="$REPO_ROOT/iso"' "$SCRIPT_CODE"
echo ""

# ---------------------------------------------------------------------------
# T4: Log file is under tmp/ — never /tmp/
# ---------------------------------------------------------------------------
echo "[T4] Logfile placement"
not_contains "logfile not under /tmp/" '/tmp/' "$SCRIPT_CONTENT"
contains "logfile under tmp/ (repo-relative)" 'TMP_DIR' "$SCRIPT_CONTENT"
echo ""

# ---------------------------------------------------------------------------
# T5: --dry-run with valid iso/ directory exits 0 and emits confirmation
# ---------------------------------------------------------------------------
echo "[T5] --dry-run with valid iso/ directory"
FAKE_REPO_OK="$SCRATCH/repo_ok"
make_fake_repo "$FAKE_REPO_OK"

DRY_OUTPUT="$((cd "$FAKE_REPO_OK" && bash scripts/build-iso.sh --dry-run) 2>&1)"
run_test "--dry-run exits 0 with iso/ present" \
    "(cd '$FAKE_REPO_OK' && bash scripts/build-iso.sh --dry-run)"
contains "--dry-run emits 'iso/ directory found'" "iso/ directory found" "$DRY_OUTPUT"
contains "--dry-run emits 'dry-run] All path'" "[dry-run] All path" "$DRY_OUTPUT"
contains "--dry-run emits version v2.0.0-rc1" "v2.0.0-rc1" "$DRY_OUTPUT"
contains "--dry-run reports iso_dir path" "iso_dir" "$DRY_OUTPUT"
not_contains "--dry-run does not invoke lb build" "lb build" "$DRY_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T6: --dry-run with missing iso/ directory exits non-zero and fails loudly
# ---------------------------------------------------------------------------
echo "[T6] --dry-run fails loudly when iso/ is absent"
FAKE_REPO_NOISO="$SCRATCH/repo_noiso"
make_fake_repo_no_iso "$FAKE_REPO_NOISO"

MISSING_OUTPUT="$((cd "$FAKE_REPO_NOISO" && bash scripts/build-iso.sh --dry-run) 2>&1 || true)"
run_test_fail "--dry-run exits non-zero when iso/ missing" \
    "(cd '$FAKE_REPO_NOISO' && bash scripts/build-iso.sh --dry-run)"
contains "error message mentions iso/ not found" "iso/ directory not found" "$MISSING_OUTPUT"
# Key invariant: failure message must not say "All path and prerequisite checks passed"
not_contains "no false success message on missing iso/" "[dry-run] All path" "$MISSING_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T7: --version flag overrides default version
# ---------------------------------------------------------------------------
echo "[T7] --version override"
FAKE_REPO_VER="$SCRATCH/repo_ver"
make_fake_repo "$FAKE_REPO_VER"

VER_OUTPUT="$((cd "$FAKE_REPO_VER" && bash scripts/build-iso.sh --dry-run --version v99.0.0-test) 2>&1)"
run_test "--version override exits 0" \
    "(cd '$FAKE_REPO_VER' && bash scripts/build-iso.sh --dry-run --version v99.0.0-test)"
contains "--version appears in output" "v99.0.0-test" "$VER_OUTPUT"
not_contains "default version v2.0.0-rc1 not in overridden output" "v2.0.0-rc1" "$VER_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T8: ORIONX_VERSION env var sets version (env authority)
# ---------------------------------------------------------------------------
echo "[T8] ORIONX_VERSION env var"
FAKE_REPO_ENV="$SCRATCH/repo_env"
make_fake_repo "$FAKE_REPO_ENV"

ENV_OUTPUT="$((cd "$FAKE_REPO_ENV" && ORIONX_VERSION=v3.0.0-env bash scripts/build-iso.sh --dry-run) 2>&1)"
run_test "ORIONX_VERSION env sets version, exits 0" \
    "(cd '$FAKE_REPO_ENV' && ORIONX_VERSION=v3.0.0-env bash scripts/build-iso.sh --dry-run)"
contains "env version appears in output" "v3.0.0-env" "$ENV_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T9: Unknown flag produces non-zero exit
# ---------------------------------------------------------------------------
echo "[T9] Unknown argument handling"
FAKE_REPO_FLAG="$SCRATCH/repo_flag"
make_fake_repo "$FAKE_REPO_FLAG"

run_test_fail "unknown flag --bogus exits non-zero" \
    "(cd '$FAKE_REPO_FLAG' && bash scripts/build-iso.sh --bogus 2>&1)"
echo ""

# ---------------------------------------------------------------------------
# T10: Prerequisite package list is defined (list must be non-empty)
# ---------------------------------------------------------------------------
echo "[T10] Prerequisite package list declared in script"
contains "live-build in prerequisite list" "live-build" "$SCRIPT_CONTENT"
contains "debootstrap in prerequisite list" "debootstrap" "$SCRIPT_CONTENT"
contains "squashfs-tools in prerequisite list" "squashfs-tools" "$SCRIPT_CONTENT"
contains "xorriso in prerequisite list" "xorriso" "$SCRIPT_CONTENT"
contains "isolinux in prerequisite list" "isolinux" "$SCRIPT_CONTENT"
echo ""

# ---------------------------------------------------------------------------
# T11: DEC-PHASE7-002 annotation present in script header
# ---------------------------------------------------------------------------
echo "[T11] DEC-PHASE7-002 decision annotation"
contains "DEC-PHASE7-002 annotation present" "DEC-PHASE7-002" "$SCRIPT_CONTENT"
echo ""

# ---------------------------------------------------------------------------
# T12: No parallel build-iso-v2.sh authority
# ---------------------------------------------------------------------------
echo "[T12] Single build script authority (no parallel build-iso-v2.sh)"
run_test_fail "build-iso-v2.sh does not exist" \
    "[[ -f '$REPO_ROOT/scripts/build-iso-v2.sh' ]]"
echo ""

# ---------------------------------------------------------------------------
# T13: iso/auto/config — no hardcoded v1.5.5, references ORIONX_VERSION
#      (F-W71-001 fix verification)
# ---------------------------------------------------------------------------
echo "[T13] iso/auto/config version string (F-W71-001)"
AUTO_CONFIG="$REPO_ROOT/iso/auto/config"
if [[ -f "$AUTO_CONFIG" ]]; then
    AUTO_CONFIG_CONTENT="$(cat "$AUTO_CONFIG")"
    not_contains "iso/auto/config does not hardcode v1.5.5" "v1.5.5" "$AUTO_CONFIG_CONTENT"
    contains "iso/auto/config references ORIONX_VERSION" "ORIONX_VERSION" "$AUTO_CONFIG_CONTENT"
    contains "iso/auto/config uses shell variable expansion for iso-volume" 'ORIONX_VERSION' "$AUTO_CONFIG_CONTENT"
else
    fail "iso/auto/config does not exist at $AUTO_CONFIG"
fi
echo ""

# ---------------------------------------------------------------------------
# T14: Makefile iso-build depends on test-unit
#      (F-W71-002 fix verification)
# ---------------------------------------------------------------------------
echo "[T14] Makefile iso-build depends on test-unit (F-W71-002)"
MAKEFILE="$REPO_ROOT/Makefile"
if [[ -f "$MAKEFILE" ]]; then
    MAKEFILE_CONTENT="$(cat "$MAKEFILE")"
    # The iso-build target line must list test-unit as a prerequisite
    if grep -q '^iso-build:.*test-unit' "$MAKEFILE"; then
        pass "Makefile iso-build target has test-unit prerequisite"
    else
        fail "Makefile iso-build target does NOT have test-unit prerequisite"
    fi
    # test-unit target must invoke bash unit tests
    if grep -q 'test-unit-bash' "$MAKEFILE"; then
        pass "Makefile test-unit depends on test-unit-bash"
    else
        fail "Makefile test-unit does not include test-unit-bash dependency"
    fi
    if grep -q 'tests/unit/test_.*\.sh' "$MAKEFILE" || grep -q 'bash.*test_' "$MAKEFILE"; then
        pass "Makefile bash unit test runner present"
    else
        fail "Makefile does not invoke bash unit test scripts"
    fi
else
    fail "Makefile does not exist at $MAKEFILE"
fi
echo ""

# ---------------------------------------------------------------------------
# T15: --version without v-prefix exits non-zero with clear error
#      (F-W71-003 fix verification)
# ---------------------------------------------------------------------------
echo "[T15] --version v-prefix enforcement (F-W71-003)"
FAKE_REPO_VPREFIX="$SCRATCH/repo_vprefix"
make_fake_repo "$FAKE_REPO_VPREFIX"

# No-prefix version must fail
VPREFIX_OUTPUT="$((cd "$FAKE_REPO_VPREFIX" && bash scripts/build-iso.sh --dry-run --version 99.0.0-noprefix) 2>&1 || true)"
run_test_fail "--version without v-prefix exits non-zero" \
    "(cd '$FAKE_REPO_VPREFIX' && bash scripts/build-iso.sh --dry-run --version 99.0.0-noprefix)"
contains "error message mentions v-prefix requirement" "must start with" "$VPREFIX_OUTPUT"

# With v-prefix must succeed
VPREFIX_OK_OUTPUT="$((cd "$FAKE_REPO_VPREFIX" && bash scripts/build-iso.sh --dry-run --version v99.0.0-test) 2>&1)"
run_test "--version with v-prefix exits 0" \
    "(cd '$FAKE_REPO_VPREFIX' && bash scripts/build-iso.sh --dry-run --version v99.0.0-test)"
contains "v-prefix version appears in output" "v99.0.0-test" "$VPREFIX_OK_OUTPUT"
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
