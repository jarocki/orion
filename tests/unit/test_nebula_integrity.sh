#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for scripts/nebula/integrity.py
#
# @decision DEC-PHASE10-009
# @title test_nebula_integrity: functional tests for boot-time integrity verification
# @status accepted
# @rationale These tests prove the SHA-256 verification chain works correctly:
#   (a) True on matching manifest;
#   (b) False (no throw) on mutated file;
#   (c) FileNotFoundError / non-zero exit on missing manifest;
#   (d) TEST_NEBULA_MODELS_DIR env var restricts to test fixture dir.
#   All tests run against a temp-dir fixture — no real GGUF or chroot needed.
#
# Usage: bash tests/unit/test_nebula_integrity.sh
# Exit:  0 all tests passed, 1 one or more failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INTEGRITY_PY="$REPO_ROOT/scripts/nebula/integrity.py"

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

# ---------------------------------------------------------------------------
# Scratch area under tmp/ (Sacred Practice 3 — no /tmp/ litter)
# ---------------------------------------------------------------------------
SCRATCH="$REPO_ROOT/tmp/test_nebula_integrity_$$"
mkdir -p "$SCRATCH"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

echo "================================================================"
echo "test_nebula_integrity.sh — W10-1 integrity.py functional tests"
echo "integrity.py: $INTEGRITY_PY"
echo "================================================================"
echo ""

# ===========================================================================
# Helpers
# ===========================================================================

# Build a temp models dir with a fake model file + matching MANIFEST.sha256
make_fixture() {
    local fixture_dir="$1"
    local model_name="${2:-fake-model.gguf}"
    local content="${3:-FAKE MODEL CONTENT FOR TESTING}"
    mkdir -p "$fixture_dir"
    echo "$content" > "$fixture_dir/$model_name"
    # Generate matching MANIFEST.sha256
    (cd "$fixture_dir" && sha256sum "$model_name" > MANIFEST.sha256)
}

# Run integrity.py with the test fixture and return exit code in $INTEGRITY_RC
run_integrity() {
    local models_dir="$1"
    local manifest="$2"
    local status_file="$SCRATCH/test-status-$$.status"
    INTEGRITY_RC=0
    PYTHONPATH="$REPO_ROOT/scripts" \
        TEST_NEBULA_MODELS_DIR="$models_dir" \
        python3 "$INTEGRITY_PY" \
            --models-dir "$models_dir" \
            --manifest "$manifest" \
            --status-file "$status_file" \
        >/dev/null 2>&1 || INTEGRITY_RC=$?
    INTEGRITY_STATUS_FILE="$status_file"
}

# ===========================================================================
# T1: integrity.py exists
# ===========================================================================
echo "[T1] integrity.py exists"
if [[ -f "$INTEGRITY_PY" ]]; then
    pass "integrity.py exists at $INTEGRITY_PY"
else
    fail "integrity.py exists" "Not found at $INTEGRITY_PY — cannot continue"
    echo "================================================================"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
echo ""

# ===========================================================================
# T2: Returns True (exit 0) on a correctly matching manifest
# ===========================================================================
echo "[T2] verify_manifest returns True (exit 0) on matching SHA-256"
FIXTURE_OK="$SCRATCH/fixture_ok"
make_fixture "$FIXTURE_OK" "fake-model.gguf" "ORION NEBULA TEST MODEL CONTENT"
run_integrity "$FIXTURE_OK" "$FIXTURE_OK/MANIFEST.sha256"
if [[ "$INTEGRITY_RC" -eq 0 ]]; then
    pass "integrity check exits 0 when SHA-256 matches"
else
    fail "integrity check exits 0 when SHA-256 matches" "Got exit code: $INTEGRITY_RC"
fi

# Status file must be written with OK state
if [[ -f "$INTEGRITY_STATUS_FILE" ]]; then
    if grep -q "NEBULA_INTEGRITY=OK" "$INTEGRITY_STATUS_FILE"; then
        pass "status file contains NEBULA_INTEGRITY=OK on success"
    else
        fail "status file contains NEBULA_INTEGRITY=OK" \
             "Content: $(cat "$INTEGRITY_STATUS_FILE" 2>/dev/null)"
    fi
else
    fail "status file written on success" "Status file not created: $INTEGRITY_STATUS_FILE"
fi
echo ""

# ===========================================================================
# T3: Returns False (exit 1) on a mutated file — no throw
# ===========================================================================
echo "[T3] verify_manifest exits 1 (no throw) when file is mutated"
FIXTURE_BAD="$SCRATCH/fixture_bad"
make_fixture "$FIXTURE_BAD" "fake-model.gguf" "ORIGINAL CONTENT"
# Mutate the model by one byte (append a newline)
echo "X" >> "$FIXTURE_BAD/fake-model.gguf"
run_integrity "$FIXTURE_BAD" "$FIXTURE_BAD/MANIFEST.sha256"
if [[ "$INTEGRITY_RC" -ne 0 ]]; then
    pass "integrity check exits non-zero on SHA-256 mismatch"
else
    fail "integrity check exits non-zero on SHA-256 mismatch" "Got exit 0 — mismatch not detected"
fi

# Status file must be written with FAIL state
if [[ -f "$INTEGRITY_STATUS_FILE" ]]; then
    if grep -q "NEBULA_INTEGRITY=FAIL" "$INTEGRITY_STATUS_FILE"; then
        pass "status file contains NEBULA_INTEGRITY=FAIL on mismatch"
    else
        fail "status file contains NEBULA_INTEGRITY=FAIL" \
             "Content: $(cat "$INTEGRITY_STATUS_FILE" 2>/dev/null)"
    fi
else
    fail "status file written on mismatch" "Status file not created"
fi
echo ""

# ===========================================================================
# T4: FileNotFoundError / non-zero exit when MANIFEST.sha256 is missing
# ===========================================================================
echo "[T4] exits non-zero (FileNotFoundError) when MANIFEST.sha256 is absent"
FIXTURE_NOMANIFEST="$SCRATCH/fixture_nomanifest"
mkdir -p "$FIXTURE_NOMANIFEST"
echo "SOME CONTENT" > "$FIXTURE_NOMANIFEST/fake-model.gguf"
# Do NOT create MANIFEST.sha256
run_integrity "$FIXTURE_NOMANIFEST" "$FIXTURE_NOMANIFEST/MANIFEST.sha256"
if [[ "$INTEGRITY_RC" -ne 0 ]]; then
    pass "integrity check exits non-zero when MANIFEST.sha256 missing"
else
    fail "integrity check exits non-zero when MANIFEST.sha256 missing" \
         "Expected fail-loud per DEC-PHASE10-009; got exit 0"
fi
echo ""

# ===========================================================================
# T5: TEST_NEBULA_MODELS_DIR restricts verification to the fixture directory
# ===========================================================================
echo "[T5] TEST_NEBULA_MODELS_DIR env var restricts verification to test fixture"
FIXTURE_ENV="$SCRATCH/fixture_env"
make_fixture "$FIXTURE_ENV" "test-model.gguf" "ENV OVERRIDE CONTENT"
# Run with a bogus models_dir but correct TEST_NEBULA_MODELS_DIR
STATUS_F="$SCRATCH/env-status-$$.status"
ENV_RC=0
PYTHONPATH="$REPO_ROOT/scripts" \
    TEST_NEBULA_MODELS_DIR="$FIXTURE_ENV" \
    python3 "$INTEGRITY_PY" \
        --models-dir /nonexistent/production/path \
        --manifest "$FIXTURE_ENV/MANIFEST.sha256" \
        --status-file "$STATUS_F" \
    >/dev/null 2>&1 || ENV_RC=$?
if [[ "$ENV_RC" -eq 0 ]]; then
    pass "TEST_NEBULA_MODELS_DIR overrides production models_dir for test fixture"
else
    fail "TEST_NEBULA_MODELS_DIR overrides models_dir" \
         "Exits non-zero ($ENV_RC) — test override not working"
fi
echo ""

# ===========================================================================
# T6: verify_manifest is importable as a Python function
# ===========================================================================
echo "[T6] verify_manifest() importable from scripts context"
IMPORT_OUT="$(PYTHONPATH="$REPO_ROOT/scripts" python3 - <<'PYEOF' 2>&1
from nebula.integrity import verify_manifest
from pathlib import Path
import inspect
sig = inspect.signature(verify_manifest)
params = list(sig.parameters.keys())
assert "models_dir" in params, f"models_dir not in params: {params}"
assert "manifest_path" in params, f"manifest_path not in params: {params}"
print("OK")
PYEOF
)"
if [[ "$IMPORT_OUT" == "OK" ]]; then
    pass "verify_manifest() importable with correct signature"
else
    fail "verify_manifest() importable" "Got: $IMPORT_OUT"
fi
echo ""

# ===========================================================================
# T7: Compound interaction — full chain: fixture -> MANIFEST -> verify -> status file
# ===========================================================================
echo "[T7] Compound-interaction: full integrity chain (fixture -> manifest -> verify -> status)"
FIXTURE_CI="$SCRATCH/fixture_compound"
make_fixture "$FIXTURE_CI" "compound-model.gguf" "COMPOUND INTERACTION TEST"
STATUS_CI="$SCRATCH/compound-status.status"
CI_RC=0
PYTHONPATH="$REPO_ROOT/scripts" \
    TEST_NEBULA_MODELS_DIR="$FIXTURE_CI" \
    python3 "$INTEGRITY_PY" \
        --models-dir "$FIXTURE_CI" \
        --manifest "$FIXTURE_CI/MANIFEST.sha256" \
        --status-file "$STATUS_CI" \
    >/dev/null 2>&1 || CI_RC=$?

if [[ "$CI_RC" -eq 0 ]]; then
    pass "compound: integrity check exits 0 for matched chain"
else
    fail "compound: integrity check exits 0" "Exit code: $CI_RC"
fi

if [[ -f "$STATUS_CI" ]]; then
    pass "compound: status file written"
    if grep -q "NEBULA_INTEGRITY=OK" "$STATUS_CI"; then
        pass "compound: status file contains NEBULA_INTEGRITY=OK"
    else
        fail "compound: status file NEBULA_INTEGRITY=OK" "$(cat "$STATUS_CI")"
    fi
    if grep -q "NEBULA_INTEGRITY_TS=" "$STATUS_CI"; then
        pass "compound: status file contains NEBULA_INTEGRITY_TS timestamp"
    else
        fail "compound: NEBULA_INTEGRITY_TS in status file" "$(cat "$STATUS_CI")"
    fi
else
    fail "compound: status file written" "File not found: $STATUS_CI"
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
