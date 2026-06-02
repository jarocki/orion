#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for scripts/pcap-analyzer.py (W9-2a gecko-legacy port)
#
# Validates the Python tool without requiring a live ISO or root access.
# Asserts: file existence, executable bit, Python compile-clean, --help,
# error path on nonexistent input, DEC-PHASE9-017 annotation, Bejtlich STA
# phases present in docstring.
#
# @decision DEC-PHASE9-017
# @title W9-2a: pcap-analyzer.py — modernized STA PCAP tool unit tests
# @status accepted
# @rationale The tool runs inside the live ISO (or as a standalone CLI on any
#   host with tshark). These tests exercise: (a) structural assertions that can
#   run on any macOS/Linux host without tshark installed; (b) the --help exit-0
#   path (argparse-only, no PCAP needed); (c) the fail-loud path for a
#   nonexistent input file (exit 1 before tshark is invoked). The compound-
#   interaction test verifies that the full CLI call chain — arg parsing ->
#   input validation -> loud error + non-zero exit — works correctly. These
#   assertions substitute for direct PCAP analysis (which requires tshark and a
#   real capture file) in the local dev/CI-macOS environment.
#
# Usage: bash tests/unit/test_pcap_analyzer.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TOOL="$REPO_ROOT/scripts/pcap-analyzer.py"

# ---------------------------------------------------------------------------
# Test counters
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

echo "=== W9-2a: pcap-analyzer.py — Unit Tests ==="

TOOL_CONTENT="$(cat "$TOOL")"

# ===========================================================================
# 1. File existence and basic properties
# ===========================================================================
section "File existence and basic properties"

if [[ -f "$TOOL" ]]; then
    pass "pcap-analyzer.py exists at scripts/pcap-analyzer.py"
else
    fail "pcap-analyzer.py exists at scripts/pcap-analyzer.py" \
         "Not found: $TOOL"
    echo ""
    echo "FATAL: tool file not found — cannot continue."
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if [[ -x "$TOOL" ]]; then
    pass "pcap-analyzer.py is executable"
else
    fail "pcap-analyzer.py is executable" \
         "Run: chmod +x $TOOL  or  git update-index --chmod=+x scripts/pcap-analyzer.py"
fi

FIRST_LINE="$(head -n1 "$TOOL")"
if [[ "$FIRST_LINE" == "#!/usr/bin/env python3" ]]; then
    pass "shebang is #!/usr/bin/env python3"
else
    fail "shebang is #!/usr/bin/env python3" "Got: $FIRST_LINE"
fi

# ===========================================================================
# 2. Python syntax clean (py_compile)
# ===========================================================================
section "Python syntax clean"

if command -v python3 >/dev/null 2>&1; then
    if python3 -m py_compile "$TOOL" 2>&1; then
        pass "python3 -m py_compile passes clean"
    else
        fail "python3 -m py_compile passes clean" \
             "Syntax error in pcap-analyzer.py"
    fi
else
    skip "python3 -m py_compile" "python3 not on PATH"
fi

# ast.parse round-trip (strict parse, not just compile)
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import ast; ast.parse(open('$TOOL').read())" 2>&1; then
        pass "ast.parse round-trip clean"
    else
        fail "ast.parse round-trip clean" \
             "ast.parse failed on pcap-analyzer.py"
    fi
else
    skip "ast.parse" "python3 not on PATH"
fi

# ===========================================================================
# 3. Decision annotation DEC-PHASE9-017
# ===========================================================================
section "@decision DEC-PHASE9-017 annotation"

if [[ "$TOOL_CONTENT" == *"@decision DEC-PHASE9-017"* ]]; then
    pass "has @decision DEC-PHASE9-017"
else
    fail "has @decision DEC-PHASE9-017" \
         "@decision annotation missing or wrong ID"
fi

if [[ "$TOOL_CONTENT" == *"@status accepted"* ]]; then
    pass "has @status accepted"
else
    fail "has @status accepted"
fi

if [[ "$TOOL_CONTENT" == *"gecko"* ]]; then
    pass "docstring references gecko legacy origin"
else
    fail "docstring references gecko legacy origin" \
         "Module docstring should document the W9-2a gecko port rationale"
fi

# ===========================================================================
# 4. Bejtlich STA phases documented in module docstring
# ===========================================================================
section "Bejtlich STA phases in module docstring"

for phase_keyword in \
    "Phase 1" \
    "Phase 2" \
    "Phase 3" \
    "Phase 4" \
    "Phase 5" \
    "Phase 6"; do
    if [[ "$TOOL_CONTENT" == *"$phase_keyword"* ]]; then
        pass "module documents: $phase_keyword"
    else
        fail "module documents: $phase_keyword" \
             "Phase missing from module docstring or comments"
    fi
done

# Specific methodology keywords
for keyword in "tshark" "tcpdump" "argparse" "subprocess" "Bejtlich"; do
    if [[ "$TOOL_CONTENT" == *"$keyword"* ]]; then
        pass "tool references: $keyword"
    else
        fail "tool references: $keyword" \
             "Expected reference to $keyword in pcap-analyzer.py"
    fi
done

# ===========================================================================
# 5. stdlib-only (no non-stdlib imports)
# ===========================================================================
section "stdlib-only imports (no extra pip deps)"

STDLIB_MODULES="argparse datetime hashlib os pathlib shutil socket subprocess sys textwrap"
# Extract import lines and check none are non-stdlib
IMPORT_LINES="$(grep -E '^import |^from ' "$TOOL" 2>/dev/null || true)"
UNEXPECTED_IMPORTS=""
while IFS= read -r line; do
    # Extract module name (first token after import / from)
    mod="$(echo "$line" | awk '{print $2}' | cut -d. -f1)"
    is_std=false
    for std in $STDLIB_MODULES; do
        if [[ "$mod" == "$std" ]]; then
            is_std=true
            break
        fi
    done
    if ! $is_std; then
        UNEXPECTED_IMPORTS="$UNEXPECTED_IMPORTS $mod"
    fi
done <<< "$IMPORT_LINES"

if [[ -z "${UNEXPECTED_IMPORTS// /}" ]]; then
    pass "no non-stdlib imports (stdlib-only tool, no pip deps)"
else
    fail "no non-stdlib imports" \
         "Found unexpected imports:$UNEXPECTED_IMPORTS"
fi

# ===========================================================================
# 6. CLI: --help exits 0 and shows usage
# ===========================================================================
section "--help exits 0 and shows usage"

if command -v python3 >/dev/null 2>&1; then
    HELP_OUTPUT="$(python3 "$TOOL" --help 2>&1 || true)"
    HELP_EXIT="$(python3 "$TOOL" --help >/dev/null 2>&1; echo $?)"

    if [[ "$HELP_EXIT" -eq 0 ]]; then
        pass "--help exits 0"
    else
        fail "--help exits 0" "Got exit code: $HELP_EXIT"
    fi

    if [[ "$HELP_OUTPUT" == *"pcap_file"* || "$HELP_OUTPUT" == *"pcap-analyzer"* ]]; then
        pass "--help output includes pcap_file positional or tool name"
    else
        fail "--help output includes pcap_file positional or tool name" \
             "Got: $HELP_OUTPUT"
    fi

    if [[ "$HELP_OUTPUT" == *"Phase"* || "$HELP_OUTPUT" == *"phase"* ]]; then
        pass "--help output mentions analysis phases"
    else
        fail "--help output mentions analysis phases" \
             "Got: $HELP_OUTPUT"
    fi

    if [[ "$HELP_OUTPUT" == *"--quick"* ]]; then
        pass "--help shows --quick flag"
    else
        fail "--help shows --quick flag" \
             "Got: $HELP_OUTPUT"
    fi

    if [[ "$HELP_OUTPUT" == *"--report"* ]]; then
        pass "--help shows --report flag"
    else
        fail "--help shows --report flag" \
             "Got: $HELP_OUTPUT"
    fi

    if [[ "$HELP_OUTPUT" == *"--output-dir"* ]]; then
        pass "--help shows --output-dir flag"
    else
        fail "--help shows --output-dir flag" \
             "Got: $HELP_OUTPUT"
    fi
else
    skip "--help test" "python3 not on PATH"
fi

# ===========================================================================
# 7. CLI: nonexistent PCAP file fails loud with non-zero exit
#    (input validation before tshark is invoked — no tshark needed)
# ===========================================================================
section "Fail-loud: nonexistent PCAP input exits non-zero"

if command -v python3 >/dev/null 2>&1; then
    NONEXIST_EXIT=0
    NONEXIST_OUTPUT=""
    NONEXIST_OUTPUT="$(python3 "$TOOL" /nonexistent/path/capture.pcap 2>&1)" || NONEXIST_EXIT=$?

    if [[ "$NONEXIST_EXIT" -ne 0 ]]; then
        pass "nonexistent PCAP exits non-zero (exit $NONEXIST_EXIT)"
    else
        fail "nonexistent PCAP exits non-zero" \
             "Got exit 0 — input validation is not failing loud"
    fi

    if [[ "$NONEXIST_OUTPUT" == *"not found"* || "$NONEXIST_OUTPUT" == *"ERROR"* || "$NONEXIST_OUTPUT" == *"No such"* ]]; then
        pass "nonexistent PCAP produces clear error message"
    else
        fail "nonexistent PCAP produces clear error message" \
             "Got: $NONEXIST_OUTPUT"
    fi
else
    skip "fail-loud input test" "python3 not on PATH"
fi

# ===========================================================================
# 8. Compound-interaction: full CLI arg-parse -> validate -> error chain
#    This exercises the real production sequence: argument parsing hand-off to
#    validate_input(), which must exit 1 (not 2, not 0) on a missing file.
#    Exit code 2 is reserved for the missing-tshark case; 1 is file-not-found.
# ===========================================================================
section "Compound-interaction: arg-parse -> validate -> exit-1 chain"

if command -v python3 >/dev/null 2>&1; then
    CI_EXIT=0
    python3 "$TOOL" /absolutely/nonexistent/file.pcap 2>/dev/null || CI_EXIT=$?

    # Input validation fires before tool discovery: exit must be 1 (not 2)
    if [[ "$CI_EXIT" -eq 1 ]]; then
        pass "compound-interaction: file-not-found exits 1 (not 2 = missing-tool)"
    else
        fail "compound-interaction: file-not-found exits 1" \
             "Got exit code $CI_EXIT — check validate_input() exit code vs tool-discovery exit code"
    fi
else
    skip "compound-interaction test" "python3 not on PATH"
fi

# ===========================================================================
# 9. ShellCheck (not applicable for Python, but check the file for bash idioms)
#    Static check: no bash is embedded in the Python file
# ===========================================================================
section "No embedded bash in Python file"

if grep -q '#!/bin/bash' "$TOOL"; then
    fail "Python file does not embed a bash shebang" \
         "Found #!/bin/bash inside pcap-analyzer.py — tool must be pure Python"
else
    pass "Python file is pure Python (no embedded bash shebang)"
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
