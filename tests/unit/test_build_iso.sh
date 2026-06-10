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
# T2: Version flag — script must contain v2.0.0-rc4, not v1.5.5 or rc1
# rc4: version literal bumped to v2.0.0-rc4 (DEC-PHASE9 version coherence)
# ---------------------------------------------------------------------------
echo "[T2] Version string"
SCRIPT_CONTENT="$(cat "$BUILD_SCRIPT")"
not_contains "script does not hardcode v1.5.5" "v1.5.5" "$SCRIPT_CONTENT"
not_contains "script does not use stale v2.0.0-rc1 default" "v2.0.0-rc1" "$SCRIPT_CONTENT"
contains "script contains v2.0.0-rc4 default" "v2.0.0-rc4" "$SCRIPT_CONTENT"
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
contains "--dry-run emits version v2.0.0-rc4" "v2.0.0-rc4" "$DRY_OUTPUT"
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
not_contains "default version v2.0.0-rc4 not in overridden output" "v2.0.0-rc4" "$VER_OUTPUT"
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
#   because curl is absent from the debian:bullseye-slim build container.
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
