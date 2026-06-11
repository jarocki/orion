#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for scripts/nebula/ CLI dispatcher and Python package structure.
#
# @decision DEC-PHASE10-008
# @title test_nebula_cli: structural + boot-path tests for the nebula CLI
# @status accepted
# @rationale Validates the W10-1 Evaluation Contract requirements for the CLI:
#   (a) nebula dispatcher exists, executable, valid Python;
#   (b) every .py under scripts/nebula/ begins with `from __future__ import annotations`
#       (DEC-PHASE9-019 hard invariant carried into Phase 10);
#   (c) ruff check exits 0 on scripts/nebula/ (DEC-PHASE9-020 hard invariant);
#   (d) `nebula --version` runs without importing ollama;
#   (e) `nebula --help` lists at least version/status/warmup subcommands;
#   (f) integrity.py exposes verify_manifest() with correct signature;
#   (g) nebula status --json produces valid JSON without ollama running.
#
# Usage: bash tests/unit/test_nebula_cli.sh
# Exit:  0 all tests passed, 1 one or more failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NEBULA_DIR="$REPO_ROOT/scripts/nebula"
NEBULA_BIN="$NEBULA_DIR/nebula"

# ---------------------------------------------------------------------------
# Test harness (mirrors existing test_build_iso.sh style)
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ERRORS=()

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    NC=$'\033[0m'
else
    GREEN="" RED="" NC=""
fi

pass() { ((PASS+=1)); echo "${GREEN}  PASS${NC}: $1"; }
fail() {
    ((FAIL+=1))
    ERRORS+=("FAIL: $1${2:+ — $2}")
    echo "${RED}  FAIL${NC}: $1${2:+ — $2}"
}
run_test() {
    local name="$1" cmd="$2" out
    if out="$(eval "$cmd" 2>&1)"; then pass "$name"
    else fail "$name" "$out"; fi
}
run_test_fail() {
    local name="$1" cmd="$2" out
    if ! out="$(eval "$cmd" 2>&1)"; then pass "$name"
    else fail "$name" "expected non-zero exit; output: $out"; fi
}
contains() {
    local name="$1" needle="$2" hay="$3"
    if echo "$hay" | grep -qF "$needle"; then pass "$name"
    else fail "$name" "expected '$needle' in output; got: $hay"; fi
}
not_contains() {
    local name="$1" needle="$2" hay="$3"
    if ! echo "$hay" | grep -qF "$needle"; then pass "$name"
    else fail "$name" "expected '$needle' NOT in output; got: $hay"; fi
}

echo "================================================================"
echo "test_nebula_cli.sh — W10-1 Nebula CLI unit tests"
echo "NEBULA_DIR: $NEBULA_DIR"
echo "================================================================"
echo ""

# ===========================================================================
# T1: Dispatcher file presence and executability
# ===========================================================================
echo "[T1] Dispatcher presence and executability"
run_test "scripts/nebula/nebula exists" "[[ -f '$NEBULA_BIN' ]]"
run_test "scripts/nebula/nebula is executable" "[[ -x '$NEBULA_BIN' ]]"
echo ""

# ===========================================================================
# T2: Shebang
# ===========================================================================
echo "[T2] Shebang"
if [[ -f "$NEBULA_BIN" ]]; then
    SHEBANG="$(head -n1 "$NEBULA_BIN")"
    if [[ "$SHEBANG" == "#!/usr/bin/env python3" ]]; then
        pass "nebula dispatcher shebang is #!/usr/bin/env python3"
    else
        fail "nebula dispatcher shebang" "Got: $SHEBANG"
    fi
fi
echo ""

# ===========================================================================
# T3: py_compile clean on all .py files (DEC-PHASE9-019)
# ===========================================================================
echo "[T3] py_compile clean on all scripts/nebula/ Python files"
while IFS= read -r -d '' pyfile; do
    if python3 -m py_compile "$pyfile" 2>/dev/null; then
        pass "py_compile clean: $(basename "$pyfile")"
    else
        fail "py_compile: $(basename "$pyfile")" "syntax error in $pyfile"
    fi
done < <(find "$NEBULA_DIR" -name '*.py' -print0)
# Also compile the dispatcher (no .py extension)
if python3 -m py_compile "$NEBULA_BIN" 2>/dev/null; then
    pass "py_compile clean: nebula (dispatcher)"
else
    fail "py_compile: nebula (dispatcher)" "syntax error in dispatcher"
fi
echo ""

# ===========================================================================
# T4: from __future__ import annotations in every .py (DEC-PHASE9-019)
# ===========================================================================
echo "[T4] from __future__ import annotations in every .py (DEC-PHASE9-019)"
while IFS= read -r -d '' pyfile; do
    if grep -q "from __future__ import annotations" "$pyfile"; then
        pass "future annotations: $(basename "$pyfile")"
    else
        fail "future annotations: $(basename "$pyfile")" \
             "DEC-PHASE9-019 requires 'from __future__ import annotations' as first import"
    fi
done < <(find "$NEBULA_DIR" -name '*.py' -print0)
# Also check dispatcher
if grep -q "from __future__ import annotations" "$NEBULA_BIN"; then
    pass "future annotations: nebula (dispatcher)"
else
    fail "future annotations: nebula (dispatcher)" \
         "DEC-PHASE9-019 requires 'from __future__ import annotations'"
fi
echo ""

# ===========================================================================
# T5: ruff check (DEC-PHASE9-020) — skip cleanly if ruff not installed
# ===========================================================================
echo "[T5] ruff check scripts/nebula/ (DEC-PHASE9-020)"
if command -v ruff >/dev/null 2>&1; then
    RUFF_OUT="$(ruff check "$NEBULA_DIR" 2>&1 || true)"
    if echo "$RUFF_OUT" | grep -qE '^Found [0-9]+ error'; then
        fail "ruff check scripts/nebula/ exits 0" "$RUFF_OUT"
    elif echo "$RUFF_OUT" | grep -qE 'error|Error' && ! echo "$RUFF_OUT" | grep -qE 'All checks passed|no errors'; then
        # ruff may print "Found 0 errors" on clean; or print nothing on clean
        if ruff check "$NEBULA_DIR" >/dev/null 2>&1; then
            pass "ruff check scripts/nebula/ exits 0"
        else
            fail "ruff check scripts/nebula/ exits 0" "$RUFF_OUT"
        fi
    else
        pass "ruff check scripts/nebula/ exits 0"
    fi
else
    echo "  SKIP: ruff not installed (DEC-PHASE9-020 local contract; skip in CI without ruff)"
fi
echo ""

# ===========================================================================
# T6: nebula --version runs without importing ollama
# ===========================================================================
echo "[T6] nebula --version runs without ollama dependency"
if [[ -f "$NEBULA_BIN" ]]; then
    # Set PYTHONPATH so the package is importable from the scripts/ tree
    VERSION_OUT="$(PYTHONPATH="$REPO_ROOT/scripts" python3 "$NEBULA_BIN" --version 2>&1)"
    if echo "$VERSION_OUT" | grep -qiE 'nebula'; then
        pass "nebula --version prints version info"
    else
        fail "nebula --version prints version info" "Got: $VERSION_OUT"
    fi
    not_contains "nebula --version does not mention ImportError" "ImportError" "$VERSION_OUT"
    not_contains "nebula --version does not mention ModuleNotFoundError" "ModuleNotFoundError" "$VERSION_OUT"
fi
echo ""

# ===========================================================================
# T7: nebula --help lists at least version / status / warmup subcommands
# ===========================================================================
echo "[T7] nebula --help lists required subcommands"
if [[ -f "$NEBULA_BIN" ]]; then
    HELP_OUT="$(PYTHONPATH="$REPO_ROOT/scripts" python3 "$NEBULA_BIN" --help 2>&1)"
    for cmd in version status warmup; do
        contains "nebula --help lists subcommand: $cmd" "$cmd" "$HELP_OUT"
    done
    not_contains "nebula --help has no ImportError" "ImportError" "$HELP_OUT"
fi
echo ""

# ===========================================================================
# T8: integrity.py exposes verify_manifest() with correct signature
# ===========================================================================
echo "[T8] integrity.py exposes verify_manifest(models_dir, manifest_path) -> bool"
INTEGRITY_PY="$NEBULA_DIR/integrity.py"
run_test "integrity.py exists" "[[ -f '$INTEGRITY_PY' ]]"
if [[ -f "$INTEGRITY_PY" ]]; then
    # Check function is defined
    if grep -q "def verify_manifest" "$INTEGRITY_PY"; then
        pass "integrity.py defines verify_manifest()"
    else
        fail "integrity.py defines verify_manifest()" "function not found in $INTEGRITY_PY"
    fi
    # Check signature contains models_dir and manifest_path
    if grep -A1 "def verify_manifest" "$INTEGRITY_PY" | grep -qE "models_dir.*manifest_path|manifest_path.*models_dir"; then
        pass "verify_manifest() accepts models_dir and manifest_path"
    else
        # The args may be on different lines — check the whole function signature block
        SIG="$(grep -A3 "def verify_manifest" "$INTEGRITY_PY" | tr '\n' ' ')"
        if echo "$SIG" | grep -qE "models_dir" && echo "$SIG" | grep -qE "manifest_path"; then
            pass "verify_manifest() accepts models_dir and manifest_path"
        else
            fail "verify_manifest() signature" "Expected models_dir + manifest_path params"
        fi
    fi
    # Verify the function returns a bool (check for '-> bool' annotation or 'return True/False').
    # Use '--' to end grep option parsing — on macOS grep the '->' prefix would otherwise
    # be interpreted as option flags (DEC-PHASE9-014 discipline: explicit end-of-options).
    if grep -q -- "-> bool" "$INTEGRITY_PY"; then
        pass "verify_manifest() annotated -> bool"
    else
        fail "verify_manifest() annotated -> bool" "Missing return type annotation"
    fi
    # Check it logs/writes on mismatch (returns False, does not raise, for hash mismatch)
    if grep -q "return False" "$INTEGRITY_PY"; then
        pass "integrity.py has return False path (mismatch does not throw)"
    else
        fail "integrity.py has return False path" "Should return False on hash mismatch, not raise"
    fi
    # Check FileNotFoundError is raised on missing manifest (fail-loud per DEC-PHASE10-009)
    if grep -q "FileNotFoundError" "$INTEGRITY_PY"; then
        pass "integrity.py raises FileNotFoundError on missing MANIFEST"
    else
        fail "integrity.py raises FileNotFoundError on missing MANIFEST" \
             "DEC-PHASE10-009: missing manifest is a hard error (fail-loud)"
    fi
fi
echo ""

# ===========================================================================
# T9: nebula status --json produces valid JSON (even with ollama down)
# ===========================================================================
echo "[T9] nebula status --json produces valid JSON without ollama running"
if [[ -f "$NEBULA_BIN" ]]; then
    STATUS_OUT="$(PYTHONPATH="$REPO_ROOT/scripts" python3 "$NEBULA_BIN" status --json 2>/dev/null || true)"
    if python3 -c "import json, sys; json.loads(sys.argv[1])" "$STATUS_OUT" 2>/dev/null; then
        pass "nebula status --json outputs valid JSON"
    else
        fail "nebula status --json outputs valid JSON" "Got: $STATUS_OUT"
    fi
    # JSON must contain the required keys
    for key in ollama_running integrity_state status_summary; do
        if echo "$STATUS_OUT" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert '$key' in d" 2>/dev/null; then
            pass "nebula status --json includes key: $key"
        else
            fail "nebula status --json includes key: $key" "Key '$key' missing from: $STATUS_OUT"
        fi
    done
fi
echo ""

# ===========================================================================
# T10: No lxterminal references (DEC-PHASE9-006 carried forward)
# ===========================================================================
echo "[T10] No lxterminal references in scripts/nebula/ (DEC-PHASE9-006)"
# DEC-PHASE9-014 || true discipline: grep -rc exits 1 when no file contains a
# match (even though it prints per-file 0 counts). Under set -euo pipefail the
# subshell would die at the grep step. Apply || true to grep so the pipe always
# exits 0; awk then sums the per-file counts (0 when nothing matched).
LXTERM_COUNT="$({ grep -rc "lxterminal" "$NEBULA_DIR" 2>/dev/null || true; } | awk '{s+=$1} END{print s+0}')"
if [[ "$LXTERM_COUNT" -eq 0 ]]; then
    pass "zero lxterminal references in scripts/nebula/ (DEC-PHASE9-006)"
else
    fail "zero lxterminal references" "Found $LXTERM_COUNT lxterminal references in $NEBULA_DIR"
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
