#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for the three W10-1 Nebula systemd unit files.
#
# @decision DEC-PHASE10-009
# @title test_nebula_systemd_units: structural validation of nebula service units
# @status accepted
# @rationale The units run inside the chroot at boot where direct execution is
#   impossible on a macOS dev machine. Structural validation catches missing
#   ordering directives (Before=/After=/Requires=), wrong Type=, hard-coded
#   relative paths, and the warmup-NOT-autoenabled invariant (DEC-PHASE10-010)
#   without requiring a full ISO build cycle. The compound-interaction check
#   verifies that the three units form a valid ordering chain:
#   nebula-integrity-check -> nebula-runtime (via Requires= + After=).
#
# Usage: bash tests/unit/test_nebula_systemd_units.sh
# Exit:  0 all tests passed, 1 one or more failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYSTEMD_DIR="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd"
HOOK_0615="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"

INTEGRITY_SVC="$SYSTEMD_DIR/nebula-integrity-check.service"
RUNTIME_SVC="$SYSTEMD_DIR/nebula-runtime.service"
WARMUP_SVC="$SYSTEMD_DIR/nebula-warmup.service"
SOCKET_UNIT="$SYSTEMD_DIR/nebula-runtime.socket"

PASS=0
FAIL=0
ERRORS=()

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
else
    GREEN="" RED="" NC=""
fi

pass() { ((PASS+=1)); echo "${GREEN}  PASS${NC}: $1"; }
fail() {
    ((FAIL+=1))
    ERRORS+=("FAIL: $1${2:+ — $2}")
    echo "${RED}  FAIL${NC}: $1${2:+ — $2}"
}
contains_in_file() {
    local name="$1" needle="$2" file="$3"
    if grep -qE "$needle" "$file" 2>/dev/null; then pass "$name"
    else fail "$name" "Pattern '$needle' not found in $file"; fi
}
not_in_file() {
    local name="$1" needle="$2" file="$3"
    if ! grep -qE "$needle" "$file" 2>/dev/null; then pass "$name"
    else fail "$name" "Pattern '$needle' found but should be absent in $file"; fi
}

echo "================================================================"
echo "test_nebula_systemd_units.sh — W10-1 systemd unit structural tests"
echo "SYSTEMD_DIR: $SYSTEMD_DIR"
echo "================================================================"
echo ""

# ===========================================================================
# T1: All unit files exist
# ===========================================================================
echo "[T1] Unit files exist"
for unit_file in "$INTEGRITY_SVC" "$RUNTIME_SVC" "$WARMUP_SVC" "$SOCKET_UNIT"; do
    if [[ -f "$unit_file" ]]; then
        pass "$(basename "$unit_file") exists"
    else
        fail "$(basename "$unit_file") exists" "Not found at $unit_file"
    fi
done
echo ""

# ===========================================================================
# T2: nebula-integrity-check.service structural assertions
# ===========================================================================
echo "[T2] nebula-integrity-check.service structure"
if [[ -f "$INTEGRITY_SVC" ]]; then
    contains_in_file "Type=oneshot" "^Type=oneshot" "$INTEGRITY_SVC"
    contains_in_file "ExecStart uses absolute /usr/bin/python3 path" \
        "^ExecStart=/usr/bin/python3" "$INTEGRITY_SVC"
    contains_in_file "ExecStart references integrity.py" \
        "integrity\.py" "$INTEGRITY_SVC"
    contains_in_file "Before=nebula-runtime.service ordering" \
        "^Before=.*nebula-runtime" "$INTEGRITY_SVC"
    contains_in_file "DEC-PHASE10-009 reference in file" \
        "DEC-PHASE10-009" "$INTEGRITY_SVC"
    contains_in_file "log written to /var/log/orionx/" \
        "/var/log/orionx/" "$INTEGRITY_SVC"
    # Must use absolute paths only — no relative PATH references
    not_in_file "no bare 'python3' without absolute path" \
        "^ExecStart=python3 " "$INTEGRITY_SVC"
fi
echo ""

# ===========================================================================
# T3: nebula-runtime.service structural assertions
# ===========================================================================
echo "[T3] nebula-runtime.service structure"
if [[ -f "$RUNTIME_SVC" ]]; then
    # Type must be notify or simple (not forking or oneshot for a daemon)
    if grep -qE "^Type=(notify|simple)" "$RUNTIME_SVC"; then
        pass "Type=notify or Type=simple (daemon type)"
    else
        fail "Type=notify or Type=simple" \
             "nebula-runtime.service must be Type=notify or Type=simple, not forking/oneshot"
    fi
    contains_in_file "ExecStart uses /usr/bin/ollama" \
        "^ExecStart=/usr/bin/ollama" "$RUNTIME_SVC"
    contains_in_file "Requires=nebula-integrity-check.service" \
        "^Requires=.*nebula-integrity-check" "$RUNTIME_SVC"
    contains_in_file "After=nebula-integrity-check.service" \
        "^After=.*nebula-integrity-check" "$RUNTIME_SVC"
    contains_in_file "OLLAMA_HOST bound to localhost (DEC-006)" \
        "OLLAMA_HOST=127\.0\.0\.1" "$RUNTIME_SVC"
    contains_in_file "OLLAMA_MODELS points to nebula models dir" \
        "OLLAMA_MODELS=/opt/orionx/nebula/models" "$RUNTIME_SVC"
    contains_in_file "DEC-PHASE10-010 reference in file" \
        "DEC-PHASE10-010" "$RUNTIME_SVC"
fi
echo ""

# ===========================================================================
# T4: nebula-warmup.service structural assertions
# ===========================================================================
echo "[T4] nebula-warmup.service structure"
if [[ -f "$WARMUP_SVC" ]]; then
    contains_in_file "Type=oneshot" "^Type=oneshot" "$WARMUP_SVC"
    contains_in_file "ExecStart uses absolute python3 path" \
        "^ExecStart=/usr/bin/python3" "$WARMUP_SVC"
    contains_in_file "ExecStart references warmup.py" \
        "warmup\.py" "$WARMUP_SVC"
    contains_in_file "DEC-PHASE10-010 reference (opt-in)" \
        "DEC-PHASE10-010" "$WARMUP_SVC"
fi
echo ""

# ===========================================================================
# T5: nebula-runtime.socket structural assertions
# ===========================================================================
echo "[T5] nebula-runtime.socket structure"
if [[ -f "$SOCKET_UNIT" ]]; then
    contains_in_file "ListenStream on localhost:11434" \
        "^ListenStream=127\.0\.0\.1:11434" "$SOCKET_UNIT"
    contains_in_file "DEC-PHASE10-010 reference in socket" \
        "DEC-PHASE10-010" "$SOCKET_UNIT"
    contains_in_file "WantedBy=sockets.target" \
        "^WantedBy=sockets\.target" "$SOCKET_UNIT"
fi
echo ""

# ===========================================================================
# T6: nebula-warmup NOT in the 0615 autoenable array (DEC-PHASE10-010)
# ===========================================================================
echo "[T6] nebula-warmup.service NOT in 0615 AUTOSTART_UNITS (DEC-PHASE10-010)"
if [[ -f "$HOOK_0615" ]]; then
    # Extract the AUTOSTART_UNITS array block and check warmup is absent.
    # Strip comment lines (lines starting with optional whitespace + #) before
    # the check — the comment "# nebula-warmup.service is deliberately NOT listed"
    # must not trigger a false positive. DEC-PHASE9-014 || true not needed here
    # because we pipe through grep -v (always exits 0 when output is non-empty).
    AUTOSTART_BLOCK="$(awk '/^AUTOSTART_UNITS=\(/,/^\)/' "$HOOK_0615" | grep -v '^\s*#' || true)"
    if echo "$AUTOSTART_BLOCK" | grep -q "nebula-warmup"; then
        fail "nebula-warmup.service absent from AUTOSTART_UNITS" \
             "DEC-PHASE10-010: warmup must NOT be autoenabled (operator opts in)"
    else
        pass "nebula-warmup.service NOT in AUTOSTART_UNITS (DEC-PHASE10-010 opt-in preserved)"
    fi

    # nebula-integrity-check MUST be in AUTOSTART_UNITS
    if echo "$AUTOSTART_BLOCK" | grep -q "nebula-integrity-check"; then
        pass "nebula-integrity-check.service IS in AUTOSTART_UNITS"
    else
        fail "nebula-integrity-check.service in AUTOSTART_UNITS" \
             "Integrity check must be autoenabled — it is the boot gate (DEC-PHASE10-009)"
    fi

    # nebula-runtime.socket MUST be in AUTOSTART_UNITS (enables lazy-start)
    if echo "$AUTOSTART_BLOCK" | grep -q "nebula-runtime.socket"; then
        pass "nebula-runtime.socket IS in AUTOSTART_UNITS (lazy-start activation)"
    else
        fail "nebula-runtime.socket in AUTOSTART_UNITS" \
             "Socket unit must be autoenabled for lazy-start (DEC-PHASE10-010)"
    fi

    # nebula-runtime.service should NOT be directly autoenabled (socket activates it)
    if echo "$AUTOSTART_BLOCK" | grep -qE '"nebula-runtime\.service"'; then
        fail "nebula-runtime.service NOT directly in AUTOSTART_UNITS" \
             "The .service is activated by the .socket; direct autoenable would bypass lazy-start"
    else
        pass "nebula-runtime.service NOT directly in AUTOSTART_UNITS (socket activates it)"
    fi
else
    fail "0615 hook exists for autoenable check" "Not found at $HOOK_0615"
fi
echo ""

# ===========================================================================
# T7: 0615 UNIT_FILES array contains all 4 new units
# ===========================================================================
echo "[T7] 0615 UNIT_FILES array contains all 4 new Nebula units"
if [[ -f "$HOOK_0615" ]]; then
    UNIT_FILES_BLOCK="$(awk '/^UNIT_FILES=\(/,/^\)/' "$HOOK_0615")"
    for unit in "nebula-integrity-check.service" "nebula-runtime.service" \
                "nebula-runtime.socket" "nebula-warmup.service"; do
        if echo "$UNIT_FILES_BLOCK" | grep -q "$unit"; then
            pass "0615 UNIT_FILES contains: $unit"
        else
            fail "0615 UNIT_FILES contains: $unit" \
                 "Add '$unit' to UNIT_FILES array in $HOOK_0615"
        fi
    done
else
    fail "0615 hook exists for UNIT_FILES check" "Not found at $HOOK_0615"
fi
echo ""

# ===========================================================================
# T8: Compound-interaction — integrity -> runtime ordering chain is intact
# ===========================================================================
echo "[T8] Compound-interaction: integrity -> runtime ordering chain"
if [[ -f "$INTEGRITY_SVC" && -f "$RUNTIME_SVC" ]]; then
    # Chain verification:
    # 1. integrity-check has Before=nebula-runtime
    # 2. nebula-runtime has Requires=nebula-integrity-check
    # 3. nebula-runtime has After=nebula-integrity-check
    # This proves the systemd ordering: integrity must complete (and succeed)
    # before runtime can start.
    BEFORE_OK=false
    REQUIRES_OK=false
    AFTER_OK=false
    grep -qE "^Before=.*nebula-runtime" "$INTEGRITY_SVC" && BEFORE_OK=true
    grep -qE "^Requires=.*nebula-integrity-check" "$RUNTIME_SVC" && REQUIRES_OK=true
    grep -qE "^After=.*nebula-integrity-check" "$RUNTIME_SVC" && AFTER_OK=true

    if "$BEFORE_OK"; then
        pass "ordering chain: integrity-check.service has Before=nebula-runtime"
    else
        fail "ordering chain: integrity-check.service Before=nebula-runtime" \
             "Missing in $INTEGRITY_SVC"
    fi
    if "$REQUIRES_OK"; then
        pass "ordering chain: nebula-runtime has Requires=nebula-integrity-check"
    else
        fail "ordering chain: nebula-runtime Requires=nebula-integrity-check" \
             "Missing in $RUNTIME_SVC — integrity failure will NOT block runtime"
    fi
    if "$AFTER_OK"; then
        pass "ordering chain: nebula-runtime has After=nebula-integrity-check"
    else
        fail "ordering chain: nebula-runtime After=nebula-integrity-check" \
             "Missing in $RUNTIME_SVC — race condition possible at boot"
    fi

    if "$BEFORE_OK" && "$REQUIRES_OK" && "$AFTER_OK"; then
        pass "ordering chain: complete (integrity-fail WILL block runtime start)"
    else
        fail "ordering chain: complete" \
             "Incomplete ordering chain — integrity failure may NOT block runtime"
    fi
fi
echo ""

# ===========================================================================
# Summary
# ===========================================================================
echo "================================================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do echo "  $err"; done
fi
echo "================================================================"

[[ $FAIL -eq 0 ]]
