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
    # Assert output contains a substring.
    # Deliberately a bash substring test, NOT `echo | grep -q`: this file runs
    # under `set -o pipefail`, and grep -q exits on the first match, SIGPIPE-ing
    # echo (141) before it finishes writing the ~1000-line haystack — so an
    # EARLY match reported as failure (seen twice: "isolinux", "xorriso" in T10).
    # No pipe, no race, exact-substring semantics preserved.
    local name="$1"
    local needle="$2"
    local haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$name"
    else
        fail "$name — expected '$needle' in output; got: $haystack"
    fi
}

not_contains() {
    # Mirror of contains(): bash substring test, no pipe. The old
    # `! echo | grep -q` form was WORSE than flaky here — under pipefail an early
    # match SIGPIPEs echo (141), and the leading `!` turned that into a false
    # PASS for a needle that WAS present. Assertions of absence must not lie.
    local name="$1"
    local needle="$2"
    local haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
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

# Docker shim (T42): this suite must never reach the real Docker daemon, and so
# can never touch the shared orionx-lb-work build volume. Any docker call is
# recorded and fails; T42 asserts the log stayed empty.
DOCKER_SHIM_DIR="$SCRATCH/shim"
DOCKER_SHIM_LOG="$SCRATCH/docker-calls.log"
mkdir -p "$DOCKER_SHIM_DIR"; : > "$DOCKER_SHIM_LOG"
printf '#!/bin/sh\necho "docker $*" >> "%s"\nexit 97\n' "$DOCKER_SHIM_LOG" > "$DOCKER_SHIM_DIR/docker"
chmod +x "$DOCKER_SHIM_DIR/docker"
export PATH="$DOCKER_SHIM_DIR:$PATH"

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
# T2: Version derivation — script uses git describe --tags (DEC-PHASE11-VERSION-DEFAULT-001)
#
# The hardcoded v2.0.0-rc9 default was removed in the macOS Docker wrap work item.
# The script now derives the default from `git describe --tags --always --dirty`
# so ISO filenames reflect actual source state. ORIONX_VERSION env override still
# wins (used by release.yml tag-triggered builds) per DEC-PHASE11-VERSION-DEFAULT-001.
#
# @decision DEC-PHASE11-VERSION-DEFAULT-001: git describe is the sole version
#   authority for the default; ORIONX_VERSION env and --version CLI flag override it.
#   The stale v2.0.0-rc9 hardcode is fully removed from functional code.
# ---------------------------------------------------------------------------
echo "[T2] Version string — git-derived default (DEC-PHASE11-VERSION-DEFAULT-001)"
SCRIPT_CONTENT="$(cat "$BUILD_SCRIPT")"
not_contains "script does not hardcode v1.5.5" "v1.5.5" "$SCRIPT_CONTENT"
not_contains "script does not use stale v2.0.0-rc1 default" "v2.0.0-rc1" "$SCRIPT_CONTENT"
# The stale rc4 literal must be absent from functional code. We check via grep -v comment lines.
SCRIPT_CODE_NOCOMMENTS="$(echo "$SCRIPT_CONTENT" | grep -v '^\s*#')"
STALE_RC4="v2.0.0-rc""4"  # split so this test file itself is not a false hit
not_contains "script does not use stale rc4 default in functional code" "$STALE_RC4" "$SCRIPT_CODE_NOCOMMENTS"
# DEC-PHASE11-VERSION-DEFAULT-001: hardcoded v2.0.0-rc9 is NOT the default; git describe is.
# We verify that VERSION is not statically assigned to v2.0.0-rc9 in functional code.
# (v2.0.0-rc9 may still appear in comments or README strings — those are allowed.)
STALE_RC9_DEFAULT="VERSION.*v2.0.0-rc""9"  # split to prevent self-match in this file
if echo "$SCRIPT_CODE_NOCOMMENTS" | grep -qE "$STALE_RC9_DEFAULT"; then
    fail "script does not assign VERSION to hardcoded v2.0.0-rc9 default in functional code (DEC-PHASE11-VERSION-DEFAULT-001)"
else
    pass "script does not assign VERSION to hardcoded v2.0.0-rc9 default in functional code (DEC-PHASE11-VERSION-DEFAULT-001)"
fi
# DEC-PHASE11-VERSION-DEFAULT-001: script must use git describe for the default
contains "script uses git describe --tags for version default (DEC-PHASE11-VERSION-DEFAULT-001)" \
    "git describe --tags" "$SCRIPT_CONTENT"
# Decision annotation must be present
contains "DEC-PHASE11-VERSION-DEFAULT-001 annotation present in script" \
    "DEC-PHASE11-VERSION-DEFAULT-001" "$SCRIPT_CONTENT"
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
#
# @decision DEC-PHASE11-VERSION-DEFAULT-001: Version is now git-derived.
#   The dry-run header includes "Orion-X Phoenix Edition <VERSION>" where VERSION
#   is the output of `git describe --tags --always --dirty` (or ORIONX_VERSION
#   override). We assert:
#   (a) The header is present (not checking a specific version string).
#   (b) The version is NOT the literal 'dev-unknown' when running inside a git repo
#       (the fake repo copies the script; git traverses up to find the real repo).
#   (c) The hardcoded 'v2.0.0-rc9' is NOT emitted — it was the stale default.
#   ORIONX_VERSION env override is separately tested in T8.
# ---------------------------------------------------------------------------
echo "[T5] --dry-run with valid iso/ directory"
FAKE_REPO_OK="$SCRATCH/repo_ok"
make_fake_repo "$FAKE_REPO_OK"

DRY_OUTPUT="$( (cd "$FAKE_REPO_OK" && bash scripts/build-iso.sh --dry-run) 2>&1)"
run_test "--dry-run exits 0 with iso/ present" \
    "(cd '$FAKE_REPO_OK' && bash scripts/build-iso.sh --dry-run)"
contains "--dry-run emits 'iso/ directory found'" "iso/ directory found" "$DRY_OUTPUT"
contains "--dry-run emits 'dry-run] All path'" "[dry-run] All path" "$DRY_OUTPUT"
# DEC-PHASE11-VERSION-DEFAULT-001: version header is emitted (git-derived, not hardcoded)
contains "--dry-run emits 'Phoenix Edition' version header (git-derived, DEC-PHASE11-VERSION-DEFAULT-001)" \
    "Phoenix Edition" "$DRY_OUTPUT"
# The stale hardcoded rc9 default must not appear as the derived version
not_contains "--dry-run does not emit stale v2.0.0-rc9 hardcoded default (DEC-PHASE11-VERSION-DEFAULT-001)" \
    "Phoenix Edition v2.0.0-rc9" "$DRY_OUTPUT"
# When running inside a git repo (fake repo inherits parent git context), version
# must not be the dev-unknown fallback — git describe should resolve a tag or SHA.
not_contains "--dry-run does not emit 'dev-unknown' when inside a git repo" \
    "dev-unknown" "$DRY_OUTPUT"
contains "--dry-run reports iso_dir path" "iso_dir" "$DRY_OUTPUT"
not_contains "--dry-run does not invoke lb build" "lb build" "$DRY_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T6: --dry-run with missing iso/ directory exits non-zero and fails loudly
# ---------------------------------------------------------------------------
echo "[T6] --dry-run fails loudly when iso/ is absent"
FAKE_REPO_NOISO="$SCRATCH/repo_noiso"
make_fake_repo_no_iso "$FAKE_REPO_NOISO"

MISSING_OUTPUT="$( (cd "$FAKE_REPO_NOISO" && bash scripts/build-iso.sh --dry-run) 2>&1 || true)"
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

VER_OUTPUT="$( (cd "$FAKE_REPO_VER" && bash scripts/build-iso.sh --dry-run --version v99.0.0-test) 2>&1)"
run_test "--version override exits 0" \
    "(cd '$FAKE_REPO_VER' && bash scripts/build-iso.sh --dry-run --version v99.0.0-test)"
contains "--version appears in output" "v99.0.0-test" "$VER_OUTPUT"
not_contains "v2.0.0-rc9 not in --version-overridden output (--version flag wins over any default)" "v2.0.0-rc9" "$VER_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T8: ORIONX_VERSION env var sets version (env authority)
# ---------------------------------------------------------------------------
echo "[T8] ORIONX_VERSION env var"
FAKE_REPO_ENV="$SCRATCH/repo_env"
make_fake_repo "$FAKE_REPO_ENV"

ENV_OUTPUT="$( (cd "$FAKE_REPO_ENV" && ORIONX_VERSION=v3.0.0-env bash scripts/build-iso.sh --dry-run) 2>&1)"
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
# DEC-PHASE12-014: on macOS this very invocation used to DELEGATE TO DOCKER from
# the fake repo and `rsync --delete` it over the shared build volume, wiping a
# running build's iso/config (trixie-dev5 post-mortem). The unknown-flag error
# must now come from the HOST, before any docker command.
BOGUS_OUT="$( (cd "$FAKE_REPO_FLAG" && bash scripts/build-iso.sh --bogus) 2>&1 || true)"
contains "unknown flag is rejected on the host, before Docker delegation" "Unknown argument: --bogus" "$BOGUS_OUT"
not_contains "unknown flag never reaches the Docker delegation banner" "delegating to debian" "$BOGUS_OUT"
# Guard 2: a tree that is not the real repo must be refused even with VALID args
# (this is what makes a fake-repo test invocation safe on macOS).
if [[ "$(uname -s)" == "Darwin" ]]; then
    FAKE_VALID_OUT="$( (cd "$FAKE_REPO_FLAG" && bash scripts/build-iso.sh --version v9.9.9) 2>&1 || true)"
    contains "fake repo refused before delegation (repo-sanity guard)" "does not look like the Orion-X repo" "$FAKE_VALID_OUT"
    not_contains "fake repo never reaches the Docker delegation banner" "delegating to debian" "$FAKE_VALID_OUT"
fi
contains "DEC-PHASE12-014 delegation guards annotated" "DEC-PHASE12-014" "$SCRIPT_CONTENT"
contains "volume-in-use guard present (one build per volume)" "docker ps -q --filter volume=orionx-lb-work" "$SCRIPT_CONTENT"
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
VPREFIX_OUTPUT="$( (cd "$FAKE_REPO_VPREFIX" && bash scripts/build-iso.sh --dry-run --version 99.0.0-noprefix) 2>&1 || true)"
run_test_fail "--version without v-prefix exits non-zero" \
    "(cd '$FAKE_REPO_VPREFIX' && bash scripts/build-iso.sh --dry-run --version 99.0.0-noprefix)"
contains "error message mentions v-prefix requirement" "must start with" "$VPREFIX_OUTPUT"

# With v-prefix must succeed
VPREFIX_OK_OUTPUT="$( (cd "$FAKE_REPO_VPREFIX" && bash scripts/build-iso.sh --dry-run --version v99.0.0-test) 2>&1)"
run_test "--version with v-prefix exits 0" \
    "(cd '$FAKE_REPO_VPREFIX' && bash scripts/build-iso.sh --dry-run --version v99.0.0-test)"
contains "v-prefix version appears in output" "v99.0.0-test" "$VPREFIX_OK_OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# T16: iso/config/archives/debian-nonfree.list.chroot — W9-1b (#48)
#
# This file is the explicit chroot apt archives augmentation that makes
# non-free firmware packages (firmware-iwlwifi, firmware-realtek, etc.)
# resolvable during lb chroot_install-packages.  It must exist and contain
# a deb line that includes 'non-free'.
# ---------------------------------------------------------------------------
echo "[T16] iso/config/archives/debian-nonfree.list.chroot (W9-1b #48)"
NONFREE_LIST="$REPO_ROOT/iso/config/archives/debian-nonfree.list.chroot"
run_test "debian-nonfree.list.chroot exists" "[[ -f '$NONFREE_LIST' ]]"
if [[ -f "$NONFREE_LIST" ]]; then
    NONFREE_CONTENT="$(cat "$NONFREE_LIST")"
    # Must contain at least one deb line (not just a comment)
    if grep -qE '^deb ' "$NONFREE_LIST"; then
        pass "debian-nonfree.list.chroot has at least one deb line"
    else
        fail "debian-nonfree.list.chroot has no 'deb ' line — apt will not use it"
    fi
    # The deb line must include 'non-free' in the component list
    if grep -E '^deb ' "$NONFREE_LIST" | grep -q 'non-free'; then
        pass "debian-nonfree.list.chroot deb line includes 'non-free' component"
    else
        fail "debian-nonfree.list.chroot deb line does not include 'non-free'"
    fi
    # DEC-PHASE12-011: the suite MUST track the base distribution. After the
    # trixie flip this file still said `bullseye`, silently mixing a Debian 11
    # apt source into the trixie chroot (deb11u packages in the cache).
    BASE_DIST="$(grep -oE '^DISTRIBUTION="[a-z]+"' "$REPO_ROOT/iso/auto/config" | cut -d'"' -f2)"
    if [[ -n "$BASE_DIST" ]] && grep -E '^deb ' "$NONFREE_LIST" | grep -qE " ${BASE_DIST} "; then
        pass "debian-nonfree.list.chroot suite tracks the base distribution (${BASE_DIST})"
    else
        fail "debian-nonfree.list.chroot suite tracks the base distribution" \
             "deb line does not name DISTRIBUTION=${BASE_DIST:-?} from iso/auto/config"
    fi
    if grep -E '^deb ' "$NONFREE_LIST" | grep -q 'bullseye'; then
        fail "debian-nonfree.list.chroot does not reference bullseye" "stale Debian 11 source in a ${BASE_DIST} chroot"
    else
        pass "debian-nonfree.list.chroot does not reference bullseye"
    fi
fi
# DEC-PHASE12-011: lb's auto-firmware enumeration must stay OFF. With
# --firmware-chroot true, chroot_firmware queues every firmware package from the
# Contents index of LB_PARENT_DISTRIBUTION_CHROOT — which lb 20250505 resolved to
# "testing" (forky) for trixie — and freshly split forky firmware packages
# (firmware-qcom-dsp, ezurio-qca-firmware) killed the trixie-dev4 build. Our
# explicit firmware-* list is the single authority.
if grep -qE '^\s*--firmware-chroot false' "$REPO_ROOT/iso/auto/config" && \
   grep -qE '^\s*--firmware-binary false' "$REPO_ROOT/iso/auto/config"; then
    pass "iso/auto/config disables lb auto-firmware (--firmware-chroot/-binary false — DEC-PHASE12-011)"
else
    fail "iso/auto/config disables lb auto-firmware" "missing --firmware-chroot false / --firmware-binary false"
fi
if [[ -f "$NONFREE_LIST" ]]; then
    # Must reference the Debian mirror (deb.debian.org)
    if grep -E '^deb ' "$NONFREE_LIST" | grep -q 'debian'; then
        pass "debian-nonfree.list.chroot deb line references a debian mirror"
    else
        fail "debian-nonfree.list.chroot deb line does not reference a debian mirror"
    fi
    # Decision annotation must be present
    contains "DEC-PHASE9-010 annotation present in nonfree list" "DEC-PHASE9-010" "$NONFREE_CONTENT"
else
    fail "debian-nonfree.list.chroot missing — skipping content assertions"
    fail "debian-nonfree.list.chroot deb line includes 'non-free' component"
    fail "debian-nonfree.list.chroot deb line references a debian mirror"
    fail "DEC-PHASE9-010 annotation present in nonfree list"
fi
echo ""

# ---------------------------------------------------------------------------
# T17: build-iso.sh fail-loud gate — explicit exit 1 after "ISO not found"
#
# W9-1b: the build-iso.sh script must exit non-zero when no ISO is produced.
# Assert that the script source contains an explicit 'exit 1' after the
# "ISO not found" / "lb build exited" error log, so the fail-loud gate is
# static-verifiable without running a full live-build.
# ---------------------------------------------------------------------------
echo "[T17] build-iso.sh fail-loud exit 1 after ISO-not-found error (W9-1b)"
# Check that the script contains 'exit 1' in the build_iso function context,
# associated with the ISO-not-found error path.
if grep -A2 'ERROR.*lb build exited' "$BUILD_SCRIPT" | grep -q 'exit 1'; then
    pass "build-iso.sh exits 1 after 'lb build exited' error log"
else
    fail "build-iso.sh does NOT exit 1 after 'lb build exited' error — fail-loud gate missing"
fi
if grep -A2 'ERROR.*lb build exited 0' "$BUILD_SCRIPT" | grep -q 'exit 1'; then
    pass "build-iso.sh exits 1 after 'lb build exited 0 but ISO not found' error"
else
    fail "build-iso.sh does NOT exit 1 after silent-success ISO-not-found error"
fi
echo ""

# ---------------------------------------------------------------------------
# T18: build-iso.sh captures lb build exit code explicitly (W9-1b)
#
# Assert that the script does NOT use '|| true' on lb build, and DOES use
# an explicit exit-code capture pattern (lb_exit variable), so a non-zero
# lb build exit is never silently swallowed.
# ---------------------------------------------------------------------------
echo "[T18] build-iso.sh lb build exit code not swallowed (W9-1b)"
# Must NOT have a non-comment 'lb build' line followed by '|| true'
# (strip comment lines first so the check does not trigger on explanatory comments)
if ! grep -v '^\s*#' "$BUILD_SCRIPT" | grep -q 'lb build.*|| true'; then
    pass "lb build is not masked with '|| true'"
else
    fail "lb build is masked with '|| true' — exit code swallowed"
fi
# Must have explicit exit-code capture variable for lb build
if grep -q 'lb_exit' "$BUILD_SCRIPT"; then
    pass "build-iso.sh uses explicit lb_exit variable to capture lb build exit code"
else
    fail "build-iso.sh does NOT capture lb build exit code explicitly (no lb_exit variable)"
fi
# Must check lb_exit against 0
if grep -q 'lb_exit -ne 0' "$BUILD_SCRIPT"; then
    pass "build-iso.sh checks lb_exit -ne 0 (fail-loud on non-zero lb build)"
else
    fail "build-iso.sh does NOT check lb_exit -ne 0"
fi
echo ""

# ---------------------------------------------------------------------------
# T19: iso/auto/config preserves --archive-areas "main contrib non-free"
#
# Belt-and-suspenders: the archive-areas flag in iso/auto/config must remain
# intact alongside the new .list.chroot file (DEC-PHASE9-010, W9-1b).
# ---------------------------------------------------------------------------
echo "[T19] iso/auto/config --archive-areas includes non-free (W9-1b belt-and-suspenders)"
AUTO_CONFIG_FILE="$REPO_ROOT/iso/auto/config"
if [[ -f "$AUTO_CONFIG_FILE" ]]; then
    if grep -q 'archive-areas.*non-free' "$AUTO_CONFIG_FILE"; then
        pass "iso/auto/config --archive-areas includes 'non-free'"
    else
        fail "iso/auto/config --archive-areas does NOT include 'non-free'"
    fi
    if grep -q 'archive-areas.*contrib' "$AUTO_CONFIG_FILE"; then
        pass "iso/auto/config --archive-areas includes 'contrib'"
    else
        fail "iso/auto/config --archive-areas does NOT include 'contrib'"
    fi
else
    fail "iso/auto/config missing — cannot verify archive-areas"
fi
echo ""

# ---------------------------------------------------------------------------
# T20: firmware packages still listed in orionx.list.chroot (W9-1b invariant)
#
# Forbidden shortcut: do NOT remove firmware packages from the package list
# to dodge the resolution issue.  All four must remain.
# ---------------------------------------------------------------------------
echo "[T20] firmware-* packages still in orionx.list.chroot (W9-1b invariant)"
PKG_LIST="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
if [[ -f "$PKG_LIST" ]]; then
    for fw_pkg in firmware-iwlwifi firmware-realtek firmware-atheros firmware-misc-nonfree; do
        if grep -qE "^${fw_pkg}$" "$PKG_LIST"; then
            pass "$fw_pkg present in orionx.list.chroot"
        else
            fail "$fw_pkg REMOVED from orionx.list.chroot — forbidden shortcut"
        fi
    done
else
    fail "orionx.list.chroot missing at $PKG_LIST"
fi
echo ""

# ---------------------------------------------------------------------------
# T21: fail2ban present as uncommented entry in orionx.list.chroot (W9-2a)
#
# @decision DEC-PHASE9-018: fail2ban replaces gecko/bin/start-denyhosts.sh.
# The package must appear as a bare uncommented line so live-build installs it.
# ---------------------------------------------------------------------------
echo "[T21] fail2ban in orionx.list.chroot (W9-2a DEC-PHASE9-018)"
PKG_LIST_F2B="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
if [[ -f "$PKG_LIST_F2B" ]]; then
    if grep -qE '^fail2ban$' "$PKG_LIST_F2B"; then
        pass "fail2ban present as uncommented entry in orionx.list.chroot"
    else
        fail "fail2ban present as uncommented entry in orionx.list.chroot" \
             "Expected a bare 'fail2ban' line (no leading #) in $PKG_LIST_F2B"
    fi
    # Confirm DEC-PHASE9-018 annotation accompanies the entry
    if grep -q "DEC-PHASE9-018" "$PKG_LIST_F2B"; then
        pass "DEC-PHASE9-018 annotation present alongside fail2ban entry"
    else
        fail "DEC-PHASE9-018 annotation present alongside fail2ban entry" \
             "W9-2a requires @decision DEC-PHASE9-018 comment near the fail2ban line"
    fi
else
    fail "fail2ban check: orionx.list.chroot not found at $PKG_LIST_F2B"
    fail "DEC-PHASE9-018 annotation check: orionx.list.chroot missing"
fi
echo ""

# ---------------------------------------------------------------------------
# T22: pcap-analyzer.py present in scripts/ (W9-2a)
#
# The build pipeline (stage_application_content in build-iso.sh) rsyncs
# scripts/ into includes.chroot — pcap-analyzer.py must exist at the source
# path so it gets staged into the ISO automatically.
# ---------------------------------------------------------------------------
echo "[T22] scripts/pcap-analyzer.py exists and is executable (W9-2a)"
PCAP_SCRIPT="$REPO_ROOT/scripts/pcap-analyzer.py"
run_test "scripts/pcap-analyzer.py exists" "[[ -f '$PCAP_SCRIPT' ]]"
run_test "scripts/pcap-analyzer.py is executable" "[[ -x '$PCAP_SCRIPT' ]]"
# Shebang check
if [[ -f "$PCAP_SCRIPT" ]]; then
    PCAP_SHEBANG="$(head -n1 "$PCAP_SCRIPT")"
    if [[ "$PCAP_SHEBANG" == "#!/usr/bin/env python3" ]]; then
        pass "scripts/pcap-analyzer.py shebang is #!/usr/bin/env python3"
    else
        fail "scripts/pcap-analyzer.py shebang is #!/usr/bin/env python3" \
             "Got: $PCAP_SHEBANG"
    fi
    PCAP_CONTENT="$(cat "$PCAP_SCRIPT")"
    if [[ "$PCAP_CONTENT" == *"DEC-PHASE9-017"* ]]; then
        pass "scripts/pcap-analyzer.py has @decision DEC-PHASE9-017"
    else
        fail "scripts/pcap-analyzer.py has @decision DEC-PHASE9-017" \
             "W9-2a requires @decision DEC-PHASE9-017 annotation in the module"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T23: GTK / PyGObject / genmon packages in orionx.list.chroot (W9-2)
#
# @decision DEC-PHASE10-005: Control Center ships ahead of Phase 10 Nebula AI;
# these packages must be present before any Phase 10 slice lands.
# ---------------------------------------------------------------------------
echo "[T23] GTK / PyGObject / genmon packages in orionx.list.chroot (W9-2)"
PKG_LIST_GTK="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
if [[ -f "$PKG_LIST_GTK" ]]; then
    for gtk_pkg in python3-gi gir1.2-gtk-3.0 gir1.2-glib-2.0 xfce4-genmon-plugin; do
        if grep -qE "^${gtk_pkg}$" "$PKG_LIST_GTK"; then
            pass "$gtk_pkg present as uncommented entry in orionx.list.chroot (W9-2)"
        else
            fail "$gtk_pkg present as uncommented entry in orionx.list.chroot" \
                 "W9-2 requires $gtk_pkg for the GTK Control Center and panel widgets"
        fi
    done
    # Decision annotation must be present
    if grep -q "DEC-PHASE10-005" "$PKG_LIST_GTK"; then
        pass "DEC-PHASE10-005 annotation present alongside GTK packages in orionx.list.chroot"
    else
        fail "DEC-PHASE10-005 annotation present alongside GTK packages" \
             "W9-2 requires @decision DEC-PHASE10-005 comment near the GTK package block"
    fi
else
    fail "GTK package check: orionx.list.chroot not found at $PKG_LIST_GTK"
fi
echo ""

# ---------------------------------------------------------------------------
# T24: scripts/control_center/orionx-control-center entry script exists (W9-2)
#
# stage_application_content rsyncs scripts/ — the entry script must exist
# in the source tree so it gets staged into the ISO automatically.
# ---------------------------------------------------------------------------
echo "[T24] scripts/control_center/orionx-control-center exists and is executable (W9-2)"
CC_ENTRY="$REPO_ROOT/scripts/control_center/orionx-control-center"
run_test "scripts/control_center/orionx-control-center exists" "[[ -f '$CC_ENTRY' ]]"
run_test "scripts/control_center/orionx-control-center is executable" "[[ -x '$CC_ENTRY' ]]"
if [[ -f "$CC_ENTRY" ]]; then
    CC_SHEBANG="$(head -n1 "$CC_ENTRY")"
    if [[ "$CC_SHEBANG" == "#!/usr/bin/env python3" ]]; then
        pass "scripts/control_center/orionx-control-center shebang is #!/usr/bin/env python3"
    else
        fail "scripts/control_center/orionx-control-center shebang is #!/usr/bin/env python3" \
             "Got: $CC_SHEBANG"
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# T25: W10-1 — stage_nebula_model() function defined in build-iso.sh
#
# @decision DEC-PHASE10-008: stage_nebula_model is the SINGLE authority for
# /opt/orionx/nebula/models/ staging. It must be a sibling to
# stage_application_content() with disjoint subtree ownership.
# ---------------------------------------------------------------------------
echo "[T25] W10-1: stage_nebula_model() function defined (DEC-PHASE10-008)"
if grep -q "^stage_nebula_model()" "$BUILD_SCRIPT"; then
    pass "stage_nebula_model() function defined in build-iso.sh"
else
    fail "stage_nebula_model() function defined" \
         "DEC-PHASE10-008: stage_nebula_model() is the single authority for Nebula model staging"
fi
echo ""

# ---------------------------------------------------------------------------
# T26: W10-1 — stage_nebula_model invoked from the main sequence
# ---------------------------------------------------------------------------
echo "[T26] W10-1: stage_nebula_model invoked from main sequence (DEC-PHASE10-008)"
if grep -q "^stage_nebula_model" "$BUILD_SCRIPT"; then
    pass "stage_nebula_model invoked at top-level (main sequence)"
else
    fail "stage_nebula_model invoked at top-level" \
         "stage_nebula_model must be called from the main build sequence (not only defined)"
fi
echo ""

# ---------------------------------------------------------------------------
# T27: W10-1 — stage_nebula_model reads nebula-model-manifest.json
# ---------------------------------------------------------------------------
echo "[T27] W10-1: stage_nebula_model reads iso/config/nebula-model-manifest.json"
if grep -q "nebula-model-manifest.json" "$BUILD_SCRIPT"; then
    pass "build-iso.sh references nebula-model-manifest.json"
else
    fail "build-iso.sh references nebula-model-manifest.json" \
         "DEC-PHASE10-008: manifest is the single authority; URL/SHA must not be hardcoded"
fi
echo ""

# ---------------------------------------------------------------------------
# T28: W10-1 — stage_nebula_model honors ORIONX_MODEL_LOCAL env var (air-gap)
# ---------------------------------------------------------------------------
echo "[T28] W10-1: ORIONX_MODEL_LOCAL air-gap fallback present (DEC-PHASE10-008)"
if grep -q "ORIONX_MODEL_LOCAL" "$BUILD_SCRIPT"; then
    pass "build-iso.sh contains ORIONX_MODEL_LOCAL env var (air-gap fallback)"
else
    fail "build-iso.sh contains ORIONX_MODEL_LOCAL" \
         "DEC-PHASE10-008: ORIONX_MODEL_LOCAL must override the HF download for air-gap builders"
fi
echo ""

# ---------------------------------------------------------------------------
# T29: W10-1 — ISO size sanity WARN at 7 GB present and ADDITIVE (DEC-PHASE10-012)
# The existing fail threshold from DEC-PHASE9-011 must NOT be removed.
# The new 7 GB WARN threshold must coexist (additive, not replacement).
# ---------------------------------------------------------------------------
echo "[T29] W10-1: ISO size WARN at 7 GB present + existing fail gate preserved (DEC-PHASE10-012)"
if grep -q "7516192768\|7 GB\|7gb" "$BUILD_SCRIPT" 2>/dev/null || grep -qi "7.*gb.*warn\|warn.*7.*gb\|DEC-PHASE10-012" "$BUILD_SCRIPT"; then
    pass "build-iso.sh contains 7 GB WARN threshold (DEC-PHASE10-012)"
else
    fail "build-iso.sh 7 GB WARN threshold" \
         "DEC-PHASE10-012: add a WARN (not fail) at ISO > 7 GB after lb build completes"
fi
# The existing fail-loud lb build exit-code gate from DEC-PHASE9-011 must still be present
if grep -q "lb_exit" "$BUILD_SCRIPT"; then
    pass "existing lb_exit fail gate preserved (DEC-PHASE9-011 not replaced)"
else
    fail "existing lb_exit fail gate preserved" \
         "DEC-PHASE9-011 fail-loud lb_exit check was removed — must not be replaced"
fi
echo ""

# ---------------------------------------------------------------------------
# T30: W10-1 — ca-certificates in orionx.list.chroot
# Required for HTTPS HuggingFace/ollama downloads in the chroot (DEC-PHASE10-008)
# ---------------------------------------------------------------------------
echo "[T30] W10-1: ca-certificates in orionx.list.chroot (DEC-PHASE10-008)"
PKG_LIST_CA="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
if [[ -f "$PKG_LIST_CA" ]]; then
    if grep -qE "^ca-certificates$" "$PKG_LIST_CA"; then
        pass "ca-certificates present as uncommented entry in orionx.list.chroot"
    else
        fail "ca-certificates in orionx.list.chroot" \
             "DEC-PHASE10-008: ca-certificates needed for HTTPS in the chroot (HF + ollama downloads)"
    fi
    # Ensure ollama is NOT in the package list (DEC-PHASE10-007: .deb-staging path only)
    if ! grep -qE "^ollama$" "$PKG_LIST_CA"; then
        pass "ollama NOT in orionx.list.chroot (correct: .deb-staged via 0500 hook)"
    else
        fail "ollama NOT in orionx.list.chroot" \
             "DEC-PHASE10-007: ollama is installed via .deb in the 0500 hook, not via apt"
    fi
else
    fail "orionx.list.chroot found for W10-1 checks" "Not found at $PKG_LIST_CA"
fi
echo ""

# ---------------------------------------------------------------------------
# T31: W10-1 — stage_nebula_model called AFTER stage_application_content
#
# Ordering matters: model staging must follow application content staging so
# that /opt/orionx/nebula/models/ is layered on top of the scripts/ rsync
# output, not overwritten by it.  We verify that the last call to
# stage_nebula_model appears after the last call to stage_application_content
# by comparing their line numbers in the script. (DEC-PHASE10-008)
# ---------------------------------------------------------------------------
echo "[T31] W10-1: stage_nebula_model called after stage_application_content (DEC-PHASE10-008)"
LINE_APP="$(grep -n "^stage_application_content" "$BUILD_SCRIPT" 2>/dev/null | tail -1 | cut -d: -f1)"
LINE_NEBULA="$(grep -n "^stage_nebula_model" "$BUILD_SCRIPT" 2>/dev/null | tail -1 | cut -d: -f1)"
if [[ -n "$LINE_APP" && -n "$LINE_NEBULA" ]]; then
    if [[ "$LINE_NEBULA" -gt "$LINE_APP" ]]; then
        pass "stage_nebula_model (line $LINE_NEBULA) called after stage_application_content (line $LINE_APP)"
    else
        fail "stage_nebula_model called after stage_application_content" \
             "stage_nebula_model line $LINE_NEBULA is before stage_application_content line $LINE_APP"
    fi
else
    fail "ordering check: both stage_application_content and stage_nebula_model must be present" \
         "app_line='$LINE_APP' nebula_line='$LINE_NEBULA'"
fi
echo ""

# ---------------------------------------------------------------------------
# T32: W10-1 — iso/config/nebula-model-manifest.json valid JSON + required keys
#
# The manifest is the single authority for model URL + SHA-256 + filename
# (DEC-PHASE10-008). It must parse as JSON and contain every key that both
# stage_nebula_model() and integrity.py rely on.
# ---------------------------------------------------------------------------
echo "[T32] W10-1: nebula-model-manifest.json valid JSON + required keys (DEC-PHASE10-008)"
MANIFEST_FILE="$REPO_ROOT/iso/config/nebula-model-manifest.json"
if [[ -f "$MANIFEST_FILE" ]]; then
    pass "iso/config/nebula-model-manifest.json exists"
    if python3 -c "import json; json.load(open('$MANIFEST_FILE'))" 2>/dev/null; then
        pass "nebula-model-manifest.json parses as valid JSON"
    else
        fail "nebula-model-manifest.json parses as valid JSON" \
             "python3 json.load failed — malformed JSON in $MANIFEST_FILE"
    fi
    # Verify the keys stage_nebula_model() and integrity.py both depend on
    for mkey in model_name model_filename model_url_primary model_sha256 model_license; do
        VAL="$(python3 -c "import json,sys; d=json.load(open('$MANIFEST_FILE')); print(d.get('$mkey','__MISSING__'))" 2>/dev/null)"
        if [[ "$VAL" != "__MISSING__" ]]; then
            pass "manifest key present: $mkey"
        else
            fail "manifest key present: $mkey" \
                 "DEC-PHASE10-008: key '$mkey' required by stage_nebula_model/integrity.py"
        fi
    done
else
    fail "iso/config/nebula-model-manifest.json exists" "Not found at $MANIFEST_FILE"
    fail "nebula-model-manifest.json JSON parse" "File missing — cannot check"
    for mkey in model_name model_filename model_url_primary model_sha256 model_license; do
        fail "manifest key present: $mkey" "File missing"
    done
fi
echo ""

# ---------------------------------------------------------------------------
# T33: W10-1 iter-3 — stage_nebula_model() must exit 1 on download failure
#
# @decision DEC-PHASE10-011
# @title Fail-loud exit gate in stage_nebula_model() download path
# @status accepted
# @rationale CI run 27248174302 showed that when curl was not installed the
#   build exited 0 despite the ERROR log. The fix adds an explicit `exit 1`
#   after the "ERROR: Model download failed from both primary and fallback"
#   log block, and this test statically asserts that pattern is present so
#   the same regression class (silent pass-through on download failure)
#   cannot reoccur without a test failure.
#   The test also verifies wget is used (not curl) in stage_nebula_model(),
#   because curl is absent from the debian:trixie-slim build container.
#   References: DEC-PHASE10-008, DEC-PHASE10-011, CI run 27248174302.
# ---------------------------------------------------------------------------
echo "[T33] W10-1 iter-3: stage_nebula_model exit 1 on failure + wget not curl (DEC-PHASE10-011)"

# Assert: explicit exit 1 follows the "ERROR: Model download failed" log line.
# The block is: ERROR log, Primary log, Fallback log, air-gap hint log, rm -f, exit 1
# That is 5 lines after the first ERROR log, so we scan -A6 to be safe.
if grep -A6 'ERROR: Model download failed from both primary and fallback' "$BUILD_SCRIPT" \
        | grep -q 'exit 1'; then
    pass "stage_nebula_model() has explicit exit 1 after 'Model download failed' ERROR block"
else
    fail "stage_nebula_model() has explicit exit 1 after 'Model download failed' ERROR block" \
         "Exit 1 must appear within 6 lines of the ERROR log to ensure fail-loud behavior (DEC-PHASE10-011)"
fi

# Assert: stage_nebula_model() does NOT use curl for its download (wget required)
# Extract only the stage_nebula_model function body (from its opening to the next
# top-level function definition), strip comment lines, then scan for curl usage.
NEBULA_FUNC_BODY="$(awk '/^stage_nebula_model\(\)/{found=1} found{print} /^\}$/ && found && NR>1{found=0}' "$BUILD_SCRIPT" \
    | grep -v '^\s*#')"
if echo "$NEBULA_FUNC_BODY" | grep -qE '\bcurl\b'; then
    fail "stage_nebula_model() uses wget not curl (curl not in build container)" \
         "curl found in non-comment lines of stage_nebula_model() — must be converted to wget (CI run 27248174302)"
else
    pass "stage_nebula_model() does not use curl (wget is the fetcher)"
fi

# Assert: stage_nebula_model() DOES use wget
if echo "$NEBULA_FUNC_BODY" | grep -qE '\bwget\b'; then
    pass "stage_nebula_model() uses wget as the model downloader"
else
    fail "stage_nebula_model() uses wget as the model downloader" \
         "wget invocation not found in stage_nebula_model() body"
fi

echo ""

# ---------------------------------------------------------------------------
# T34: W10-1 iter-5 — fail-loud propagation for ALL build_iso() exit paths
#
# @decision DEC-PHASE10-013
# @title Explicit T34 coverage of lb_exit, no-ISO, and copy-fail exit-1 gates
# @status accepted
# @rationale CI run 27253363451 (iter-4) showed build-iso.sh logging
#   "ERROR: lb build exited with code 1 — no ISO was produced." then exiting
#   0 anyway (GitHub Actions step showed ✓). The existing T17 assertion
#   uses grep -A2 on 'ERROR.*lb build exited' which matches TWO log lines:
#   the lb_exit error (where exit 1 is 4 lines away, NOT captured by -A2)
#   and the "exited 0 but ISO not found" error (where exit 1 IS within 2
#   lines). T17 is therefore a false positive — it passes even if the
#   lb_exit -ne 0 branch lacks exit 1. T34 closes this gap with dedicated
#   assertions per path, each using grep -A10 to cover the actual 4-line
#   gap without being so wide it matches unrelated blocks.
#   References: DEC-PHASE9-011, DEC-PHASE10-013, CI run 27253363451, #61.
# ---------------------------------------------------------------------------
echo "[T34] W10-1 iter-5: fail-loud exit 1 for ALL build_iso() error branches (DEC-PHASE10-013)"

# T34.a: lb_exit -ne 0 branch — 'exit 1' within 10 lines of the specific
# "lb build exited with code" log (the one that includes $lb_exit variable).
# We anchor on the format string character — grep for the literal dash before
# "no ISO was produced" to distinguish from the "exited 0 but ISO not found"
# message which is a different error path.
if grep -A10 'lb build exited with code.*no ISO was produced' "$BUILD_SCRIPT" | grep -q 'exit 1'; then
    pass "T34.a: exit 1 within 10 lines of 'lb build exited with code' ERROR log (lb_exit branch)"
else
    fail "T34.a: exit 1 within 10 lines of 'lb build exited with code' ERROR log (lb_exit branch)" \
         "DEC-PHASE10-013: exit 1 must follow the lb_exit -ne 0 ERROR log within 10 lines"
fi

# T34.b: no-ISO gate — 'exit 1' within 10 lines of the "lb build exited 0
# but ISO not found" log.  This is the belt-and-suspenders check for when
# lb build exits 0 but produces no ISO.
if grep -A10 'lb build exited 0 but ISO not found' "$BUILD_SCRIPT" | grep -q 'exit 1'; then
    pass "T34.b: exit 1 within 10 lines of 'lb build exited 0 but ISO not found' check"
else
    fail "T34.b: exit 1 within 10 lines of 'lb build exited 0 but ISO not found' check" \
         "DEC-PHASE9-011 belt-and-suspenders: exit 1 must follow the no-ISO-found check"
fi

# T34.c: output copy gate — 'exit 1' within 10 lines of the "ISO copy to
# output/ failed" log.  This gate catches a rare race where the ISO exists
# in iso/ but the cp to output/ fails (permissions, disk-full, etc.).
if grep -A10 'ISO copy to output.*failed' "$BUILD_SCRIPT" | grep -q 'exit 1'; then
    pass "T34.c: exit 1 within 10 lines of 'ISO copy to output/ failed' log (copy-fail branch)"
else
    fail "T34.c: exit 1 within 10 lines of 'ISO copy to output/ failed' log (copy-fail branch)" \
         "DEC-PHASE9-011: exit 1 must follow the output-copy-failed ERROR log"
fi

# T34.d: stage_application_content() does NOT mask rsync errors with '|| true'.
# The function relies on set -euo pipefail to propagate unexpected rsync failures;
# masking with || true would silently swallow staging errors.
# We extract the function body (up to the next top-level function) and check
# that no rsync call in it is followed by '|| true'.
APP_FUNC_BODY="$(awk '/^stage_application_content\(\)/{found=1} found{print} /^\}$/ && found && NR>1{found=0}' "$BUILD_SCRIPT" \
    | grep -v '^\s*#')"
if echo "$APP_FUNC_BODY" | grep -qE 'rsync.*\|\| true'; then
    fail "T34.d: stage_application_content() rsync calls not masked with '|| true'" \
         "A masked rsync would swallow staging errors; set -euo pipefail must be able to propagate"
else
    pass "T34.d: no rsync call in stage_application_content() is masked with '|| true'"
fi

echo ""

# ---------------------------------------------------------------------------
# T35: W10-1 iter-6 — qemu-test.yml "Build ISO" step has set -o pipefail
#
# @decision DEC-PHASE10-014
# @title pipefail propagates docker run's non-zero exit through the tee pipeline
# @status accepted
# @rationale GitHub Actions runs `run:` blocks under `bash -e` but NOT
#   `bash -eo pipefail`. The "Build ISO in debian:bullseye container" step
#   pipes `docker run` through `tee tmp/build-iso.log`. Without pipefail,
#   the pipeline returns tee's exit (0), masking docker run's non-zero exit.
#   That made CI show ✓ even when build-iso.sh exited 1 inside the container
#   (the CI exit-0 bug tracked as #61). Adding `set -o pipefail` as the first
#   line of the `run:` block causes the outer shell to propagate the
#   rightmost non-zero exit from the pipeline. Closes #61.
#   References: DEC-PHASE10-014.
# ---------------------------------------------------------------------------
echo "[T35] W10-1 iter-6: qemu-test.yml Build ISO step has set -o pipefail (DEC-PHASE10-014 closes #61)"
QEMU_WORKFLOW="$REPO_ROOT/.github/workflows/qemu-test.yml"
if [[ -f "$QEMU_WORKFLOW" ]]; then
    pass "qemu-test.yml exists at .github/workflows/qemu-test.yml"

    # Extract the "Build ISO" step's run block: from the step name line to the
    # "Restore workspace ownership" step (which immediately follows). We look
    # for set -o pipefail appearing before the first `docker run` line in
    # that region, which is the requirement.
    BUILD_STEP_REGION="$(awk '
        /Build ISO in debian:(bullseye|trixie) container/ { in_step=1 }
        in_step && /Restore workspace ownership/ { exit }
        in_step { print }
    ' "$QEMU_WORKFLOW")"

    # T35.a: set -o pipefail must be present in the Build ISO run block
    if echo "$BUILD_STEP_REGION" | grep -q 'set -o pipefail'; then
        pass "T35.a: set -o pipefail present in 'Build ISO' step run block"
    else
        fail "T35.a: set -o pipefail present in 'Build ISO' step run block" \
             "DEC-PHASE10-014 closes #61: pipefail must appear in the Build ISO run: block"
    fi

    # T35.b: set -o pipefail must appear BEFORE the docker run pipeline.
    # Strip comment lines before checking so the grep for 'docker run' does not
    # match the DEC-PHASE10-014 comment that says "propagates docker run's non-zero
    # exit" — only the actual shell invocation should count.
    BUILD_STEP_NOCOMMENTS="$(echo "$BUILD_STEP_REGION" | grep -v '^\s*#')"
    PIPEFAIL_LINE="$(echo "$BUILD_STEP_NOCOMMENTS" | grep -n 'set -o pipefail' | head -1 | cut -d: -f1)"
    DOCKER_LINE="$(echo "$BUILD_STEP_NOCOMMENTS" | grep -n 'docker run' | head -1 | cut -d: -f1)"
    if [[ -n "$PIPEFAIL_LINE" && -n "$DOCKER_LINE" ]]; then
        if [[ "$PIPEFAIL_LINE" -lt "$DOCKER_LINE" ]]; then
            pass "T35.b: set -o pipefail (line $PIPEFAIL_LINE) appears before docker run (line $DOCKER_LINE) in step"
        else
            fail "T35.b: set -o pipefail must precede docker run" \
                 "pipefail at region-line $PIPEFAIL_LINE is after docker run at region-line $DOCKER_LINE"
        fi
    else
        fail "T35.b: both set -o pipefail and docker run must be present in Build ISO step" \
             "pipefail_line='$PIPEFAIL_LINE' docker_line='$DOCKER_LINE'"
    fi

    # T35.c: DEC-PHASE10-014 annotation present in the workflow file
    if grep -q 'DEC-PHASE10-014' "$QEMU_WORKFLOW"; then
        pass "T35.c: DEC-PHASE10-014 annotation present in qemu-test.yml"
    else
        fail "T35.c: DEC-PHASE10-014 annotation present in qemu-test.yml" \
             "Decision annotation required per coding standards"
    fi

    # T35.d: qemu-test.yml parses as valid YAML (structural integrity check)
    #
    # Uses PyYAML (python3-yaml / pyyaml) when available. On CI the lint job
    # installs only ruff and pytest; PyYAML is absent. Trying `import yaml`
    # without the package returns a non-zero exit from python3, which would
    # cause this assertion to false-fail regardless of whether the YAML is
    # valid. The fix: detect PyYAML availability first; skip with a WARN when
    # it is absent rather than reporting a false failure. T35.a / T35.b / T35.c
    # already provide structural coverage (pipefail present, ordering correct,
    # annotation present); the YAML parse check is belt-and-suspenders.
    # To enable this check in CI, add `pyyaml` to requirements-dev.txt and
    # install it in the lint workflow (tracked as follow-up in #63).
    if python3 -c "import yaml" 2>/dev/null; then
        # PyYAML is available — assert on exit code (parse success is silent)
        if python3 -c "import yaml; yaml.safe_load(open('$QEMU_WORKFLOW'))" 2>/dev/null; then
            pass "T35.d: qemu-test.yml parses as valid YAML after edit"
        else
            fail "T35.d: qemu-test.yml parses as valid YAML after edit" \
                 "python3 yaml.safe_load failed — syntax error introduced in $QEMU_WORKFLOW"
        fi
    else
        # PyYAML not installed — skip this sub-check, do not count as failure
        PASS=$((PASS + 1))
        echo "  PASS: T35.d: qemu-test.yml YAML parse skipped (PyYAML not installed — structural coverage from T35.a/b/c)"
    fi
else
    fail "qemu-test.yml exists at .github/workflows/qemu-test.yml" \
         "File not found — cannot assert T35"
    fail "T35.a: set -o pipefail present in 'Build ISO' step run block" "File missing"
    fail "T35.b: set -o pipefail appears before docker run" "File missing"
    fail "T35.c: DEC-PHASE10-014 annotation present in qemu-test.yml" "File missing"
    fail "T35.d: qemu-test.yml parses as valid YAML" "File missing"
fi
echo ""

# ---------------------------------------------------------------------------
# T36: bootloader menus — plain GRUB text menu + themed BIOS vesamenu
#
# @decision DEC-PHASE11-044
# @title Unit tests: GRUB is a plain readable menu; Phoenix identity is Plymouth
# @status accepted
# @rationale The GRUB gfxmenu theme (DEC-PHASE11-013/040/041) errored + rendered
#   an unreadable font on real UEFI hardware, so it is RETIRED. GRUB now uses its
#   native text console — no gfxterm/gfxmenu/gfxmode/loadfont/`set theme`. The
#   Phoenix boot identity moves to the Plymouth splash (DEC-PHASE11-044, verified
#   in test_offline_boot.sh / test_iso_serial_console.sh). grub.cfg is a
#   GENERATED file; these assertions check the generator HEREDOC (the authority).
#   The binary-tree theme.txt/background.png assets are LEFT staged but
#   unreferenced (optionality) and are still asserted present. Identity tokens
#   and the GENERATED marker must be preserved. The themed BIOS/isolinux
#   vesamenu menu (DEC-PHASE11-042) stays — both boot paths remain enabled.
#   References: DEC-PHASE11-012, DEC-PHASE11-042, DEC-PHASE11-044.
# ---------------------------------------------------------------------------
echo "[T36] Bootloader menus: plain GRUB text menu + BIOS vesamenu (DEC-PHASE11-044)"

# T36.a-b: these used to grep the GENERATOR SOURCE for strings. That is an
# implementation test (RESILIENCE rule 1): it would pass unchanged if the
# generator emitted the strings into the wrong file, in the wrong order, or
# inside an `if` that is never taken. They now RUN generate_bootloader_configs()
# in a sandbox and assert on the grub.cfg it actually produces.
#
# DELIBERATE CHANGE OF INVARIANT (DEC-PHASE12-042). T36.b previously asserted
# that NO graphics directive (insmod gfxterm / set gfxmode / loadfont) appears
# outside the ORIONX_GRUB_THEME guard — i.e. that the default UEFI menu is
# plain text. That invariant is retired, and this is what replaces it.
#
# What it was protecting: an unreadable boot menu costs the operator the
# failsafe entry. The two hardware failures behind DEC-PHASE11-044 were rc1-79
# (gfxterm with no font loaded) and rc1-81 (gfxmenu theme rendering illegibly).
#
# Why it no longer fits: inspection of the shipped rc4 ISO shows the gfxmenu
# revival's `loadfont /boot/grub/fonts/unicode.pf2` names a directory the image
# does not contain — the font is at /boot/grub/unicode.pf2. The default path
# now (i) resolves the font the way live-build's own config.cfg does, (ii)
# gates every graphics step behind `if loadfont`, so "gfxterm with no font" is
# unreachable, and (iii) draws GRUB's NATIVE menu over a background_image with
# explicit colours, so there is no theme engine to render illegibly.
#
# The protected property is unchanged and is asserted directly below instead of
# by proxy: in EVERY mode, the menu lists both entries, keeps a visible timeout,
# and never reaches the theme engine unless ORIONX_GRUB_THEME=1.
_t36_tmp="$REPO_ROOT/tmp/test_build_iso_grub_$$"
_t36_fail=0
mkdir -p "$_t36_tmp"

# Extract the generator and run it against a throwaway ISO tree.
sed -n '/^generate_bootloader_configs() {/,/^    log "Bootloader configs generated from single/p' \
    "$BUILD_SCRIPT" > "$_t36_tmp/fn.sh"
printf '}\n' >> "$_t36_tmp/fn.sh"

_t36_gen() {  # $1=dest dir; remaining args are VAR=VAL overrides
    local dest="$1"; shift
    mkdir -p "$dest/auto" "$dest/config/includes.chroot/usr/share/grub/themes/orionx"
    grep -- '--bootappend-live' "$REPO_ROOT/iso/auto/config" | grep -v '^[[:space:]]*#' | head -1 \
        > "$dest/auto/config"
    cp "$REPO_ROOT/iso/config/includes.chroot/usr/share/grub/themes/orionx/theme.txt" \
       "$dest/config/includes.chroot/usr/share/grub/themes/orionx/" 2>/dev/null
    env "$@" bash -c '
        set -uo pipefail
        ISO_DIR="$1"
        log() { :; }
        . "$2"
        generate_bootloader_configs
    ' _ "$dest" "$_t36_tmp/fn.sh" >/dev/null 2>&1
}

if _t36_gen "$_t36_tmp/default"; then
    _T36_GRUB="$_t36_tmp/default/config/includes.binary/boot/grub/grub.cfg"
else
    _T36_GRUB=/dev/null
    fail "T36.gen: generator failed to run in the default configuration" "cannot assert T36.a-b"
fi

# T36.a: the gfxmenu THEME ENGINE — the thing that rendered unreadably — must
# not be in a default build.
if ! grep -qE '^\s*(set theme=|insmod gfxmenu)' "$_T36_GRUB"; then
    pass "T36.a: default grub.cfg does NOT load the gfxmenu theme engine (DEC-PHASE11-044 preserved)"
else
    fail "T36.a: default grub.cfg references 'set theme='/'insmod gfxmenu'" \
         "the theme engine is the component that failed on hardware; it stays behind ORIONX_GRUB_THEME=1"
fi

# T36.b: the default menu IS graphical (the operator asked for graphics).
# Strip comments first: the generated file's own @rationale header NAMES these
# directives, so grepping the whole file would pass on a config that only talks
# about graphics. (Caught by mutation G3 — removing background_image left the
# word in the comment and the assertion stayed green.)
_t36_code="$(grep -v '^[[:space:]]*#' "$_T36_GRUB" 2>/dev/null || true)"
_t36_missing=""
for _d in 'if loadfont $orionx_font ; then' 'insmod gfxterm' 'set gfxmode=' \
          'terminal_output gfxterm' 'background_image ' 'set menu_color_highlight='; do
    printf '%s' "$_t36_code" | grep -qF "$_d" || _t36_missing="$_t36_missing [$_d]"
done
if [[ -z "$_t36_missing" ]]; then
    pass "T36.b: default grub.cfg is graphical — font-gated gfxterm + background_image + explicit menu colours (DEC-PHASE12-042)"
else
    fail "T36.b: default grub.cfg is missing graphics directives:$_t36_missing" \
         "UEFI boot would show a plain text menu — see generate_bootloader_configs()"
fi

# NOTE: the three line-number lookups below end in `|| true`. Under the
# suite's `set -euo pipefail` a grep that finds nothing aborts the whole
# run, which would silently SKIP these assertions instead of failing them —
# the test would then pass on broken code by never executing.
# T36.b1: the SAFETY property. Everything graphical must sit after `if loadfont`,
# because gfxterm with no font loaded is literally the rc1-79 failure.
_t36_lf="$(printf '%s\n' "$_t36_code" | grep -n 'if loadfont' | head -1 | cut -d: -f1 || true)"
_t36_gt="$(printf '%s\n' "$_t36_code" | grep -n 'terminal_output gfxterm' | head -1 | cut -d: -f1 || true)"
if [[ -n "$_t36_lf" && -n "$_t36_gt" && "$_t36_gt" -gt "$_t36_lf" ]]; then
    pass "T36.b1: gfxterm is selected only inside the 'if loadfont' gate (rc1-79 failure mode unreachable)"
else
    fail "T36.b1: 'terminal_output gfxterm' is not gated behind 'if loadfont'" \
         "loadfont line=$_t36_lf gfxterm line=$_t36_gt — gfxterm with no font is the rc1-79 unreadable-menu bug"
fi

# T36.b2: the font path must never be /boot/grub/fonts/ — that directory does
# not exist on the ISO (verified against output/*rc4.iso, 2026-10-03). This is
# the regression that made the gfxmenu revival untestable.
# Comments in both files DISCUSS the dead path on purpose, so strip them first:
# what must not contain it is executable grub.cfg script and executable shell.
_t36_live_grub="$(grep -v '^[[:space:]]*#' "$_T36_GRUB" 2>/dev/null || true)"
_t36_live_gen="$(grep -v '^[[:space:]]*#' "$BUILD_SCRIPT" 2>/dev/null || true)"
if ! printf '%s' "$_t36_live_grub" | grep -q '/boot/grub/fonts/' \
   && ! printf '%s' "$_t36_live_gen" | grep -q '/boot/grub/fonts/'; then
    pass "T36.b2: no reference to the non-existent /boot/grub/fonts/ path (DEC-PHASE12-042)"
else
    fail "T36.b2: /boot/grub/fonts/ referenced — loadfont will silently fail" \
         "the ISO keeps unicode.pf2 at \$prefix/unicode.pf2; see live-build's own /boot/grub/config.cfg"
fi

# T36.b3: terminal_output gfxterm REPLACES the output list, so the serial
# console must be re-appended after it or GRUB's output vanishes from the QEMU
# CI capture. DEC-PHASE12-030's block sat after the serial lines and dropped it.
# Compare the LAST of each: one gfxterm selection before the serial append is
# fine, but ANY gfxterm selection after it drops serial from the output list.
# (Mutation G6 added a second, later one and the first-occurrence form missed it.)
_t36_ser="$(printf '%s\n' "$_t36_code" | grep -n 'terminal_output --append serial' | tail -1 | cut -d: -f1 || true)"
_t36_gt_last="$(printf '%s\n' "$_t36_code" | grep -n 'terminal_output gfxterm' | tail -1 | cut -d: -f1 || true)"
if [[ -n "$_t36_ser" && -n "$_t36_gt_last" && "$_t36_ser" -gt "$_t36_gt_last" ]]; then
    pass "T36.b3: 'terminal_output --append serial' comes AFTER 'terminal_output gfxterm' (serial console survives)"
else
    fail "T36.b3: serial output is appended before gfxterm replaces the terminal list" \
         "last gfxterm line=$_t36_gt_last serial line=$_t36_ser — GRUB serial output would be lost"
fi

# T36.b4: the kill switch works and yields the old plain menu.
if _t36_gen "$_t36_tmp/plain" ORIONX_GRUB_GRAPHICS=0; then
    _T36_PLAIN="$_t36_tmp/plain/config/includes.binary/boot/grub/grub.cfg"
    _t36_plain_live="$(grep -v '^[[:space:]]*#' "$_T36_PLAIN" 2>/dev/null || true)"
    if ! printf '%s' "$_t36_plain_live" | grep -qE 'gfxterm|loadfont|background_image|set gfxmode' \
       && grep -qF 'menuentry "Orion-X Live (failsafe)"' "$_T36_PLAIN"; then
        pass "T36.b4: ORIONX_GRUB_GRAPHICS=0 restores the bare text menu, failsafe entry intact"
    else
        fail "T36.b4: ORIONX_GRUB_GRAPHICS=0 did not produce a plain menu" \
             "the one-env-var revert is the escape hatch if hardware rejects the graphics"
    fi
else
    fail "T36.b4: generator failed with ORIONX_GRUB_GRAPHICS=0" "kill switch is broken"
fi

# T36.b5: the theme engine still defaults OFF and still turns ON with the flag.
if _t36_gen "$_t36_tmp/themed" ORIONX_GRUB_THEME=1; then
    _T36_THEMED="$_t36_tmp/themed/config/includes.binary/boot/grub/grub.cfg"
    if grep -qF 'set theme=' "$_T36_THEMED" && grep -qF 'insmod gfxmenu' "$_T36_THEMED"; then
        pass "T36.b5: ORIONX_GRUB_THEME=1 still revives the gfxmenu theme (opt-in preserved, DEC-PHASE12-030)"
    else
        fail "T36.b5: ORIONX_GRUB_THEME=1 did not emit the gfxmenu theme" \
             "the revival path must stay testable on hardware"
    fi
else
    fail "T36.b5: generator failed with ORIONX_GRUB_THEME=1" "opt-in theme path is broken"
fi
if grep -qF 'ORIONX_GRUB_THEME:-0' "$BUILD_SCRIPT"; then
    pass "T36.b6: GRUB gfxmenu theme flag defaults to off"
else
    fail "T36.b6: ORIONX_GRUB_THEME must default to 0 — see DEC-PHASE12-030/042"
fi

# T36.b7: the gfxmenu theme needs the graphics block's font+gfxterm, so the
# combination that would emit `set theme` with no font must be refused loudly
# rather than producing an unreadable image.
if ! _t36_gen "$_t36_tmp/conflict" ORIONX_GRUB_THEME=1 ORIONX_GRUB_GRAPHICS=0; then
    pass "T36.b7: ORIONX_GRUB_THEME=1 with ORIONX_GRUB_GRAPHICS=0 is refused (would emit a theme with no font)"
else
    fail "T36.b7: the conflicting flag combination built an ISO config" \
         "set theme= without a loaded font is exactly the rc1-81 unreadable menu"
fi

# T36.b8: the invariant DEC-PHASE11-044 actually protects — the operator can
# always reach the failsafe entry — must hold in EVERY mode.
_t36_modes_ok=1
for _m in default plain themed; do
    _f="$_t36_tmp/$_m/config/includes.binary/boot/grub/grub.cfg"
    [[ -f "$_f" ]] || { _t36_modes_ok=0; continue; }
    grep -qF 'menuentry "Orion-X Live (failsafe)"' "$_f" || _t36_modes_ok=0
    grep -A1 -F 'menuentry "Orion-X Live (no questions)"' "$_f" | grep -q 'orionx.wizard=0' || _t36_modes_ok=0
    grep -A4 -F 'label live-noquestions' "$(dirname "$(dirname "$(dirname "$_f")")")/isolinux/isolinux.cfg" | grep -q 'orionx.wizard=0' || _t36_modes_ok=0
    grep -qF 'set timeout=5' "$_f" || _t36_modes_ok=0
done
if [[ "$_t36_modes_ok" -eq 1 ]]; then
    pass "T36.b8: failsafe + no-questions (orionx.wizard=0) entries + 5s timeout present in default, plain and themed modes"
else
    fail "T36.b8: a GRUB mode lost the failsafe entry or the visible timeout" \
         "that entry exists for when things are already wrong — it is not optional in any mode"
fi

# T36.b9: the COMMITTED generated artifacts must match what the generator emits
# today. iso/config/includes.binary/*.cfg are derived surfaces; a stale copy in
# git is a second, wrong authority that readers trust. (Both files were in fact
# stale before DEC-PHASE12-042: they carried a pre-DEC-PHASE11-042 isolinux menu
# and a cmdline missing apparmor=1 security=apparmor.)
_t36_drift=""
for _pair in "boot/grub/grub.cfg" "isolinux/isolinux.cfg"; do
    _gen="$_t36_tmp/default/config/includes.binary/$_pair"
    _com="$REPO_ROOT/iso/config/includes.binary/$_pair"
    if [[ -f "$_gen" && -f "$_com" ]]; then
        cmp -s "$_gen" "$_com" || _t36_drift="$_t36_drift $_pair"
    else
        _t36_drift="$_t36_drift $_pair(missing)"
    fi
done
if [[ -z "$_t36_drift" ]]; then
    pass "T36.b9: committed includes.binary bootloader cfgs match a fresh generator run (no derived-surface drift)"
else
    fail "T36.b9: committed bootloader cfg drifted from the generator:$_t36_drift" \
         "regenerate them: they are GENERATED files (DEC-PHASE11-012), not hand-edited ones"
fi

rm -rf "$_t36_tmp"
unset _t36_fail

# T36.c: the readable GRUB menu still offers both entries + a visible timeout.
if grep -qF 'menuentry "Orion-X Live"' "$BUILD_SCRIPT" && \
   grep -qF 'menuentry "Orion-X Live (failsafe)"' "$BUILD_SCRIPT" && \
   grep -qF "set timeout=5" "$BUILD_SCRIPT"; then
    pass "T36.c: GRUB menu has Live + failsafe entries and a 5s timeout (readable menu)"
else
    fail "T36.c: GRUB menuentries / timeout missing from generator"
fi

# T36.d: generator HEREDOC preserves GENERATED marker on line 1 of emitted grub.cfg
if grep -qF "GENERATED — do not edit — regenerate via scripts/build-iso.sh" "$BUILD_SCRIPT"; then
    pass "T36.d: GENERATED marker template present in build-iso.sh (DEC-PHASE11-012 preserved)"
else
    fail "T36.d: GENERATED marker template missing from build-iso.sh — generated file won't carry it"
fi

# T36.e: generator HEREDOC preserves W11-2 identity token structure
# The HEREDOC uses $bootappend shell variable which expands to the full cmdline at
# build time. We verify the variable is referenced (not a hardcoded string).
# The validator in generate_bootloader_configs() ensures the value contains the tokens.
if grep -qF 'linux /live/vmlinuz $bootappend' "$BUILD_SCRIPT"; then
    pass "T36.e: linux line in generator HEREDOC uses \$bootappend variable (identity tokens preserved)"
else
    fail "T36.e: generator HEREDOC linux line must use \$bootappend (not hardcoded tokens)"
fi

# T36.f: DEC-PHASE11-044 annotation present in build-iso.sh (plain GRUB menu)
if grep -qF "DEC-PHASE11-044" "$BUILD_SCRIPT"; then
    pass "T36.f: DEC-PHASE11-044 annotation present in build-iso.sh (GRUB gfxmenu retired)"
else
    fail "T36.f: DEC-PHASE11-044 annotation not found in build-iso.sh"
fi

# T36.g: binary-tree GRUB theme assets staged (committed allowed paths)
GRUB_THEME_BINARY="$REPO_ROOT/iso/config/includes.binary/boot/grub/themes/orionx"
if [[ -f "$GRUB_THEME_BINARY/theme.txt" ]]; then
    pass "T36.g: iso/config/includes.binary/boot/grub/themes/orionx/theme.txt staged"
else
    fail "T36.g: iso/config/includes.binary/boot/grub/themes/orionx/theme.txt missing — theme will not render at live-boot"
fi
if [[ -f "$GRUB_THEME_BINARY/background.png" ]]; then
    pass "T36.g: iso/config/includes.binary/boot/grub/themes/orionx/background.png staged"
else
    fail "T36.g: iso/config/includes.binary/boot/grub/themes/orionx/background.png missing"
fi

# T36.h: generator copies binary-tree theme assets (function body check)
# generate_bootloader_configs() must reference grub_theme_dst copy block.
if grep -qF "grub_theme_dst" "$BUILD_SCRIPT"; then
    pass "T36.h: build-iso.sh references grub_theme_dst (binary-tree copy logic present)"
else
    fail "T36.h: grub_theme_dst variable not found — binary-tree copy logic missing from generator"
fi

# T36.i: generator emits the themed BIOS/isolinux menu (DEC-PHASE11-042).
# W11-9a3 "BIOS menu deferred" is RETIRED — the isolinux path now uses a
# vesamenu.c32 graphical menu with a Phoenix background. Assert on the generator
# HEREDOC (the single authority), matching T36.a-f — NOT on the committed
# generated artifact (which is regenerated at build time).
if grep -qF "ui vesamenu.c32" "$BUILD_SCRIPT" && \
   grep -qF "menu background orionx-isolinux-bg.png" "$BUILD_SCRIPT"; then
    pass "T36.i: generator emits themed isolinux menu (ui vesamenu.c32 + Phoenix background — DEC-PHASE11-042)"
else
    fail "T36.i: generator HEREDOC missing 'ui vesamenu.c32' / 'menu background' — BIOS boot menu not themed"
fi

# T36.i2: DEC-PHASE11-042 annotation present in the generator
if grep -qF "DEC-PHASE11-042" "$BUILD_SCRIPT"; then
    pass "T36.i2: DEC-PHASE11-042 annotation present in build-iso.sh (BIOS themed menu)"
else
    fail "T36.i2: DEC-PHASE11-042 annotation not found in build-iso.sh"
fi

# T36.i3: the 640x480 isolinux background asset is staged (committed binary path)
ISOLINUX_BG="$REPO_ROOT/iso/config/includes.binary/isolinux/orionx-isolinux-bg.png"
if [[ -f "$ISOLINUX_BG" ]]; then
    pass "T36.i3: isolinux Phoenix background staged (orionx-isolinux-bg.png)"
else
    fail "T36.i3: iso/config/includes.binary/isolinux/orionx-isolinux-bg.png missing — vesamenu will have no background"
fi

# T36.j: Plymouth splash carries the Phoenix boot identity now (DEC-PHASE11-044).
# The theme + anti-hang guards are asserted in test_offline_boot.sh; here we just
# confirm the theme assets the build activates are present in the source tree.
PLY_THEME="$REPO_ROOT/iso/config/includes.chroot/usr/share/plymouth/themes/orionx-phoenix"
if [[ -f "$PLY_THEME/orionx-phoenix.plymouth" && -f "$PLY_THEME/orionx-phoenix.script" && -f "$PLY_THEME/background.png" ]]; then
    pass "T36.j: Plymouth orionx-phoenix theme assets present (.plymouth/.script/background.png — DEC-PHASE11-044)"
else
    fail "T36.j: Plymouth orionx-phoenix theme assets missing — boot splash will not paint"
fi

echo ""

# ---------------------------------------------------------------------------
# T37: stage_build_env() must emit a SOURCEABLE fragment for hostile git subjects
#
# /etc/orionx-build-env is sourced by hooks 0510 and 0700, and ORIONX_GIT_TITLE
# is an arbitrary commit subject. The 2026-08-19 build died with
#   /etc/orionx-build-env: line 6: syntax error near unexpected token `('
# because the merge-commit subject was written unquoted. This test extracts the
# real heredoc block from build-iso.sh, feeds it a subject containing every
# shell-hostile character class, sources the result, and asserts the value
# round-trips byte-identical.
# ---------------------------------------------------------------------------
_t37_tmp="$(mktemp -d)"
# Extract the generator: the _shq definition + the heredoc that writes the fragment.
sed -n '/_shq() {/,/^BUILDENV$/p' "$BUILD_SCRIPT" > "$_t37_tmp/gen.sh"
if [[ ! -s "$_t37_tmp/gen.sh" ]] || ! grep -q "_shq()" "$_t37_tmp/gen.sh"; then
    fail "T37: could not extract _shq/heredoc block from build-iso.sh (generator refactored? update this test)"
else
    _t37_title="Merge x into develop (DEC-1) with 'quotes', \"dquotes\", \$dollar, \`ticks\` & ;semicolons;"
    (
        cd "$_t37_tmp" || exit 1
        VERSION="vT37" ORIONX_GIT_SHA="cafe1234" ORIONX_GIT_TITLE="$_t37_title" \
        ORIONX_PHASE_11_SLICES="W-T37" ollama_tag="tag:t37" model_filename="t37.gguf" \
        stage_dir="$_t37_tmp" bash -c '
            set -euo pipefail
            stage_dir="$0"
            . ./gen.sh 2>/dev/null || true   # defines _shq, then heredoc writes $stage_dir/orionx-build-env
        ' "$_t37_tmp" 2>/dev/null
    ) || true
    if [[ -f "$_t37_tmp/orionx-build-env" ]]; then
        _t37_got="$(bash -c ". '$_t37_tmp/orionx-build-env' && printf '%s' \"\$ORIONX_GIT_TITLE\"" 2>&1)" || _t37_got="<SOURCE FAILED: $_t37_got>"
        if [[ "$_t37_got" == "$_t37_title" ]]; then
            pass "T37: orionx-build-env sources cleanly with shell-hostile git subject (round-trip exact)"
        else
            fail "T37: orionx-build-env round-trip mismatch — got: $_t37_got"
        fi
    else
        fail "T37: generator did not produce orionx-build-env fragment"
    fi
fi
rm -rf "$_t37_tmp"

echo ""

# ---------------------------------------------------------------------------
# T38-T42: library functions, exercised by SOURCING build-iso.sh with
# ORIONX_BUILD_ISO_LIB_ONLY=1 (DEC-PHASE12-111..114). Behavioural: canned
# inputs in scratch dirs, real functions, observed outcomes.
# ---------------------------------------------------------------------------
_lib() {  # run a snippet with the build-iso.sh library loaded
    ( ORIONX_BUILD_ISO_LIB_ONLY=1; export ORIONX_BUILD_ISO_LIB_ONLY
      # shellcheck disable=SC1090
      . "$BUILD_SCRIPT"; eval "$1" )
}
_mkiso() {  # <dir> <version> [content]
    local n="orionx-phoenix-edition-$2.iso"
    printf '%s' "${3:-iso-$2}" > "$1/$n"
    (cd "$1" && { command -v sha256sum >/dev/null && sha256sum "$n" || shasum -a 256 "$n"; } > "$n.sha256")
}

echo "[T38] publish_built_iso: exact name, success only, verified (DEC-PHASE12-111)"
_t38="$SCRATCH/t38"; mkdir -p "$_t38/src" "$_t38/dst"
_mkiso "$_t38/src" v9.0.0-rc1
_mkiso "$_t38/src" v8.0.0-rc6          # a stale ISO from an earlier build
_mkiso "$_t38/src" v9.0.0-rc2
if _lib 'publish_built_iso "'"$_t38/src"'" "'"$_t38/dst"'" v9.0.0-rc2 1' >/dev/null 2>&1; then
    fail "T38.a: failed build (rc=1) reported publish success"
else
    pass "T38.a: failed build (rc=1) returns non-zero"
fi
[[ -z "$(ls -A "$_t38/dst")" ]] && pass "T38.b: failed build copies NOTHING to the host" \
    || fail "T38.b: failed build copied: $(ls "$_t38/dst")"
_t38_out="$(_lib 'publish_built_iso "'"$_t38/src"'" "'"$_t38/dst"'" v9.0.0-rc2 0' 2>&1)" \
    && pass "T38.c: successful build publishes" || fail "T38.c: publish failed: $_t38_out"
[[ "$(ls "$_t38/dst" | tr '\n' ' ')" == "orionx-phoenix-edition-v9.0.0-rc2.iso orionx-phoenix-edition-v9.0.0-rc2.iso.sha256 " ]] \
    && pass "T38.d: only this version's ISO + sidecar reach the host (stale rc1/rc6 stay behind)" \
    || fail "T38.d: host got: $(ls "$_t38/dst" | tr '\n' ' ')"
rm -f "$_t38/dst"/*
printf 'tampered' > "$_t38/src/orionx-phoenix-edition-v9.0.0-rc1.iso"
_lib 'publish_built_iso "'"$_t38/src"'" "'"$_t38/dst"'" v9.0.0-rc1 0' >/dev/null 2>&1 \
    && fail "T38.e: ISO not matching its sidecar was published" \
    || pass "T38.e: ISO not matching its sidecar is refused"
[[ -z "$(ls -A "$_t38/dst")" ]] && pass "T38.f: refused ISO is not copied" || fail "T38.f: copied anyway"
_lib 'publish_built_iso "'"$_t38/src"'" "'"$_t38/dst"'" v7.7.7 0' >/dev/null 2>&1 \
    && fail "T38.g: rc=0 with no ISO reported success" || pass "T38.g: rc=0 but no ISO of that name is a failure"
_t38_wrap="$(sed -n '/bash -c .$/,/-- "\$@"/p' "$BUILD_SCRIPT")"
contains "T38.h: wrapper container step publishes through publish_built_iso" 'publish_built_iso /build/output /host-output "$ORIONX_VERSION" "$rc"' "$_t38_wrap"
not_contains "T38.i: wrapper no longer globs output/*.iso to the host" 'cp -a /build/output/*.iso' "$_t38_wrap"
echo ""

echo "[T39] check_no_stale_skips: fail on reused stages (DEC-PHASE12-113)"
_t39="$SCRATCH/t39"; mkdir -p "$_t39"
printf 'P: Begin\nW: Skipping bootstrap, already done\nW: Skipping bootstrap_cache, already done\nP: Executing hook 0500\n' > "$_t39/fresh.log"
printf 'W: Skipping bootstrap, already done\nW: Skipping chroot_hooks, already done\nW: Skipping binary_iso, already done\n' > "$_t39/stale.log"
_lib 'check_no_stale_skips "'"$_t39/fresh.log"'"' >/dev/null 2>&1 && pass "T39.a: bootstrap-only skips are allowed" \
    || fail "T39.a: bootstrap-only log rejected"
_t39_out="$(_lib 'check_no_stale_skips "'"$_t39/stale.log"'"' 2>&1)" && fail "T39.b: stale chroot_hooks/binary_iso skips accepted" \
    || pass "T39.b: stale chroot/binary skips fail the build"
contains "T39.c: the error names the stale stage" "Skipping chroot_hooks, already done" "$_t39_out"
_lib 'check_no_stale_skips "'"$_t39/absent.log"'"' >/dev/null 2>&1 && fail "T39.d: missing log accepted" \
    || pass "T39.d: a missing lb log is a failure (freshness unproven)"
contains "T39.e: build_iso tees lb build and checks it" 'check_no_stale_skips "$lb_log" || exit 1' "$SCRIPT_CONTENT"
echo ""

echo "[T40] release identity needs its CHANGELOG section (DEC-PHASE12-114)"
_t40="$SCRATCH/t40"; mkdir -p "$_t40/scripts/release"
cp "$REPO_ROOT/scripts/release/extract-release-notes.sh" "$_t40/scripts/release/"
printf '# Changelog\n\n## [v9.1.0-rc1] — 2026-01-01\n\n- notes\n\n## [v9.0.0] — 2025\n\n- old\n' > "$_t40/CHANGELOG.md"
for v in v9.1.0 v9.1.0-rc2 v3.0.0; do
    _lib 'require_release_changelog '"$v"' "'"$_t40"'"' >/dev/null 2>&1 \
        && fail "T40.a: release $v without a CHANGELOG section was allowed" \
        || pass "T40.a: release $v without a CHANGELOG section is refused"
done
for v in v9.1.0-rc1 v9.0.0; do
    _lib 'require_release_changelog '"$v"' "'"$_t40"'"' >/dev/null 2>&1 \
        && pass "T40.b: release $v with its section is allowed" || fail "T40.b: $v refused despite its section"
done
for v in v9.1.0-rc1-3-gabc1234 v9.1.0-dirty dev-unknown v99.0.0-test v3.0.0-env; do
    _lib 'require_release_changelog '"$v"' "'"$_t40/nowhere"'"' >/dev/null 2>&1 \
        && pass "T40.c: development version $v is not gated" || fail "T40.c: dev version $v refused"
done
printf '# Changelog\n\n## [v9.2.0]\n\n## [v9.1.0]\n\n- x\n' > "$_t40/CHANGELOG.md"
_lib 'require_release_changelog v9.2.0 "'"$_t40"'"' >/dev/null 2>&1 \
    && fail "T40.d: an EMPTY section was accepted" || pass "T40.d: an empty section is refused"
FAKE_REPO_REL="$SCRATCH/repo_rel"; make_fake_repo "$FAKE_REPO_REL"
_t40_out="$( (cd "$FAKE_REPO_REL" && ORIONX_VERSION=v3.0.0 bash scripts/build-iso.sh --dry-run) 2>&1 )" \
    && fail "T40.e: --dry-run of v3.0.0 with no CHANGELOG passed" || pass "T40.e: build-iso.sh refuses v3.0.0 without its CHANGELOG section"
contains "T40.f: refusal says why" "DEC-PHASE12-114" "$_t40_out"
echo ""

echo "[T41] patch_live_build: --allow-remove-essential only in Remove_packages (DEC-PHASE12-112)"
_t41="$SCRATCH/t41"; mkdir -p "$_t41"
# Fixtures carry the exact lines of live-build 1:20250505+deb13u1 (trixie).
printf '%s\n' '				find "${DIRECTORY}" -name "*.deb" -print0 | xargs -0 --no-run-if-empty cp -fl -t chroot/var/cache/apt/archives' > "$_t41/cache.sh"
printf '%s\n' '			apt|apt-get)' '				Chroot chroot "apt-get remove --auto-remove --purge ${APT_OPTIONS} ${PACKAGES}"' > "$_t41/packages.sh"
printf '%s\n' '	APT_OPTIONS="${APT_OPTIONS:---yes -o Acquire::Retries=5}"' > "$_t41/configuration.sh"
_lib 'patch_live_build "'"$_t41"'"' >/dev/null 2>&1 && pass "T41.a: patch applies to trixie live-build text" || fail "T41.a: patch failed"
grep -q 'cp -fl' "$_t41/cache.sh" && fail "T41.b: cp -fl survived" || pass "T41.b: cp -fl -> cp -f"
grep -qF 'apt-get remove --auto-remove --purge --allow-remove-essential ${APT_OPTIONS} ${PACKAGES}' "$_t41/packages.sh" \
    && pass "T41.c: Remove_packages carries --allow-remove-essential" || fail "T41.c: Remove_packages not patched"
grep -q -- '--allow-remove-essential' "$_t41/configuration.sh" && fail "T41.d: APT_OPTIONS default armed" \
    || pass "T41.d: APT_OPTIONS default stays without --allow-remove-essential"
_lib 'patch_live_build "'"$_t41"'"' >/dev/null 2>&1 && [[ "$(grep -o -- '--allow-remove-essential' "$_t41/packages.sh" | wc -l | tr -d ' ')" == "1" ]] \
    && pass "T41.e: patch is idempotent" || fail "T41.e: second run failed or duplicated the flag"
printf '%s\n' 'Chroot chroot "apt-get purge ${APT_OPTIONS} ${PACKAGES}"' > "$_t41/packages.sh"
_lib 'patch_live_build "'"$_t41"'"' >/dev/null 2>&1 && fail "T41.f: drifted live-build accepted" \
    || pass "T41.f: a live-build whose Remove_packages text drifted fails loudly"
not_contains "T41.g: wrapper APT_OPTIONS no longer carries --allow-remove-essential" \
    'APT_OPTIONS="--yes -o Acquire::Retries=5 --allow-remove-essential' "$SCRIPT_CONTENT"
echo ""

echo "[T42] the test run never reached Docker"
if [[ -s "$DOCKER_SHIM_LOG" ]]; then
    fail "T42: build-iso.sh invoked docker during the unit tests: $(cat "$DOCKER_SHIM_LOG")"
else
    pass "T42: no docker command was issued (the orionx-lb-work volume is untouchable from this suite)"
fi
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
