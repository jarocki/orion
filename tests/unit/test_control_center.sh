#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for scripts/control_center/ (W9-2 GTK Control Center)
#
# Validates structural and content properties of the Control Center Python
# package without requiring a GTK display, a running ISO, or chroot access.
#
# @decision DEC-PHASE9-019
# @title Bullseye Python 3.9 + PEP-563 test gate
# @status accepted
# @rationale Every new .py file must start with `from __future__ import
#   annotations` as the first import.  This test asserts that invariant
#   mechanically so regressions are caught before CI.
#
# @decision DEC-PHASE9-020
# @title ruff check enforced on all new Python in Phase 9+
# @status accepted
# @rationale ruff is invoked here when available; the test skips gracefully
#   when ruff is absent so macOS dev machines without ruff stay unblocked,
#   but CI (which has ruff) will fail on any lint regression.
#
# @decision DEC-PHASE10-005
# @title Control Center ships ahead of Phase 10 Nebula AI; placeholder
#        sections define the plug-in surfaces for W10-1 through W10-6.
# @status accepted
# @rationale The Nebula ("lands in W10-1") and Auto-Healing ("lands in W10-6")
#   placeholder texts are asserted here so the W9-2 reviewer can confirm the
#   plug-in surfaces exist and W10-1..W10-6 implementers know exactly where to
#   land their runtime code.
#
# Production sequence:
#   1. stage_application_content rsyncs scripts/ → includes.chroot/opt/orionx/scripts/
#   2. live-build copies includes.chroot/ into the chroot filesystem
#   3. 0700-orionx-setup.hook.chroot symlinks orionx-control-center → /usr/bin/
#   4. Operator clicks .desktop → /usr/bin/orionx-control-center executes → GTK window
#
# Usage: bash tests/unit/test_control_center.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CC_DIR="$REPO_ROOT/scripts/control_center"
ENTRY="$CC_DIR/orionx-control-center"

# ---------------------------------------------------------------------------
# Test counters (((VAR+=1)) avoids set -e firing on zero-result arithmetic)
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
    RED="" GREEN="" YELLOW="" NC=""
fi

pass() { ((PASS+=1)); echo "${GREEN}  PASS${NC}: $1"; }
fail() {
    ((FAIL+=1))
    echo "${RED}  FAIL${NC}: $1"
    [[ -n "${2:-}" ]] && echo "        $2"
}
skip() { ((SKIP+=1)); echo "${YELLOW}  SKIP${NC}: $1 — $2"; }
section() { echo ""; echo "--- $1 ---"; }

echo "=== W9-2: Control Center — Structural Unit Tests ==="

# ===========================================================================
# 1. Entry script presence, permissions, shebang
# ===========================================================================
section "Entry script: orionx-control-center"

if [[ -f "$ENTRY" ]]; then
    pass "orionx-control-center exists"
else
    fail "orionx-control-center exists" "Not found: $ENTRY"
    echo "FATAL: entry script missing — cannot continue."
    exit 1
fi

if [[ -x "$ENTRY" ]]; then
    pass "orionx-control-center is executable"
else
    fail "orionx-control-center is executable" "Run: chmod +x $ENTRY"
fi

SHEBANG="$(head -n1 "$ENTRY")"
if [[ "$SHEBANG" == "#!/usr/bin/env python3" ]]; then
    pass "shebang is #!/usr/bin/env python3"
else
    fail "shebang is #!/usr/bin/env python3" "Got: $SHEBANG"
fi

# ===========================================================================
# 2. Python compile check on entry script and every .py in control_center/
# ===========================================================================
section "Python compile check (py_compile)"

if python3 -m py_compile "$ENTRY" 2>&1; then
    pass "py_compile: orionx-control-center"
else
    fail "py_compile: orionx-control-center"
fi

while IFS= read -r -d '' pyfile; do
    relpath="${pyfile#"$REPO_ROOT/"}"
    if python3 -m py_compile "$pyfile" 2>&1; then
        pass "py_compile: $relpath"
    else
        fail "py_compile: $relpath"
    fi
done < <(find "$CC_DIR" -name "*.py" -print0 | sort -z)

# ===========================================================================
# 3. from __future__ import annotations — first import in EVERY .py
#    (DEC-PHASE9-019 hard invariant)
# ===========================================================================
section "from __future__ import annotations (DEC-PHASE9-019)"

check_annotations() {
    local file="$1"
    local relpath="${file#"$REPO_ROOT/"}"
    # Strip the shebang line (if any) and blank/comment lines, then check
    # whether the first import-looking line is `from __future__ import annotations`.
    local first_import
    first_import="$(grep -v '^\s*#' "$file" | grep -v '^\s*$' | grep -E '^\s*(import |from )' | head -n1)"
    if [[ "$first_import" == *"from __future__ import annotations"* ]]; then
        pass "__future__ annotations first: $relpath"
    else
        fail "__future__ annotations first: $relpath" \
             "Expected 'from __future__ import annotations' but got: $first_import"
    fi
}

check_annotations "$ENTRY"
while IFS= read -r -d '' pyfile; do
    check_annotations "$pyfile"
done < <(find "$CC_DIR" -name "*.py" -print0 | sort -z)

# ===========================================================================
# 4. --help exits 0
# ===========================================================================
section "--help exits 0"

if python3 "$ENTRY" --help >/dev/null 2>&1; then
    pass "orionx-control-center --help exits 0"
else
    fail "orionx-control-center --help exits 0"
fi

# ===========================================================================
# 5. Nebula placeholder text contains "lands in W10-1" (DEC-PHASE10-005)
# ===========================================================================
section "Nebula placeholder text (DEC-PHASE10-005)"

NEBULA_PY="$CC_DIR/sections/nebula.py"
if [[ -f "$NEBULA_PY" ]]; then
    if grep -q "lands in W10-1" "$NEBULA_PY"; then
        pass "nebula.py contains 'lands in W10-1' placeholder (W10-1 plug-in surface)"
    else
        fail "nebula.py contains 'lands in W10-1' placeholder" \
             "W10-1 implementer needs this text to locate the correct section"
    fi
    if grep -q "coming in W10-2" "$NEBULA_PY"; then
        pass "nebula.py contains 'coming in W10-2' (W10-2 chat plug-in surface)"
    else
        fail "nebula.py contains 'coming in W10-2'" \
             "W10-2 implementer needs this text to locate the correct section"
    fi
    if grep -q "coming in W10-3" "$NEBULA_PY"; then
        pass "nebula.py contains 'coming in W10-3' (W10-3 MCP plug-in surface)"
    else
        fail "nebula.py contains 'coming in W10-3'" \
             "W10-3 implementer needs this text to locate the correct section"
    fi
else
    fail "sections/nebula.py exists" "Not found: $NEBULA_PY"
fi

# ===========================================================================
# 6. Auto-Healing placeholder text contains "lands in W10-6" (DEC-PHASE10-005)
# ===========================================================================
section "Auto-Healing placeholder text (DEC-PHASE10-005)"

AUTO_PY="$CC_DIR/sections/auto_healing.py"
if [[ -f "$AUTO_PY" ]]; then
    if grep -q "lands in W10-6" "$AUTO_PY"; then
        pass "auto_healing.py contains 'lands in W10-6' (W10-6 plug-in surface)"
    else
        fail "auto_healing.py contains 'lands in W10-6'" \
             "W10-6 implementer needs this text to locate the correct tab"
    fi
else
    fail "sections/auto_healing.py exists" "Not found: $AUTO_PY"
fi

# ===========================================================================
# 7. Six sections discoverable (directory listing of sections/)
# ===========================================================================
section "6 sections discoverable in sections/"

SECTIONS_DIR="$CC_DIR/sections"
EXPECTED_SECTIONS=(
    "network.py"
    "mesh.py"
    "comms.py"
    "awareness.py"
    "ir.py"
    "nebula.py"
)

for sec in "${EXPECTED_SECTIONS[@]}"; do
    if [[ -f "$SECTIONS_DIR/$sec" ]]; then
        pass "section present: $sec"
    else
        fail "section present: $sec" "Not found: $SECTIONS_DIR/$sec"
    fi
done

# Auto-Healing is a TAB (separate from the 6 main sections)
if [[ -f "$SECTIONS_DIR/auto_healing.py" ]]; then
    pass "Auto-Healing tab module present: auto_healing.py"
else
    fail "Auto-Healing tab module present: auto_healing.py"
fi

# ===========================================================================
# 8. No third-party imports (stdlib + gi.repository only)
#    Scan for any `import X` or `from X import` where X is not in the
#    allowed set (stdlib names or 'gi').
# ===========================================================================
section "No third-party imports (stdlib + gi.repository only)"

_ALLOWED_PREFIXES="(os|sys|subprocess|typing|argparse|gi|__future__|control_center|\\.\\.)"

_found_violation=0
while IFS= read -r -d '' pyfile; do
    # Extract import lines, strip comments and blank lines
    while IFS= read -r line; do
        # Normalise and extract the top-level module name
        if [[ "$line" =~ ^from[[:space:]]+([a-zA-Z_][a-zA-Z0-9_.]*) ]]; then
            module="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^import[[:space:]]+([a-zA-Z_][a-zA-Z0-9_.]*) ]]; then
            module="${BASH_REMATCH[1]}"
        else
            continue
        fi
        # Relative imports (start with dot) are always internal — allowed
        if [[ "$line" == from\ .* ]]; then
            continue
        fi
        top="${module%%.*}"
        # Check against allowed prefixes
        if ! [[ "$top" =~ ^(os|sys|subprocess|typing|argparse|gi|__future__)$ ]]; then
            fail "no third-party import: ${pyfile#"$REPO_ROOT/"} imports '$top'" \
                 "Only stdlib + gi.repository allowed in shipped Python"
            _found_violation=1
        fi
    done < <(grep -E '^\s*(import |from )' "$pyfile" | grep -v '^\s*#')
done < <(find "$CC_DIR" -name "*.py" -print0 | sort -z)

if [[ "$_found_violation" -eq 0 ]]; then
    pass "no third-party imports found in scripts/control_center/"
fi

# ===========================================================================
# 9. @decision DEC-PHASE10-005 annotation present in app.py
# ===========================================================================
section "@decision DEC-PHASE10-005 in app.py"

APP_PY="$CC_DIR/app.py"
if [[ -f "$APP_PY" ]]; then
    if grep -q "DEC-PHASE10-005" "$APP_PY"; then
        pass "@decision DEC-PHASE10-005 present in app.py"
    else
        fail "@decision DEC-PHASE10-005 present in app.py" \
             "Required decision annotation missing from app.py module docstring"
    fi
else
    fail "app.py exists" "Not found: $APP_PY"
fi

# ===========================================================================
# 10. ruff check (DEC-PHASE9-020) — skip gracefully when ruff not installed
# ===========================================================================
section "ruff check (DEC-PHASE9-020)"

if command -v ruff >/dev/null 2>&1; then
    if ruff check "$CC_DIR/" 2>&1; then
        pass "ruff check scripts/control_center/ passes clean"
    else
        fail "ruff check scripts/control_center/ passes clean" \
             "Fix all ruff errors before committing (DEC-PHASE9-020)"
    fi
else
    skip "ruff check" "ruff not installed — install with: pip3 install ruff"
fi

# ===========================================================================
# 11. Compound-interaction: production sequence coherence
#     Verify that the package is wired consistently end-to-end:
#     a) app.py imports all 6 sections + auto_healing
#     b) orionx-control-center calls main() which calls run_app()
#     c) helpers package is importable from sections (relative imports)
#     d) widgets directory exists with 4 scripts
# ===========================================================================
section "Compound-interaction: package wiring coherence"

# a) app.py imports all section modules
if grep -q "from .sections import" "$APP_PY" 2>/dev/null; then
    IMPORTS_LINE="$(grep 'from .sections import' "$APP_PY")"
    for sec_mod in network mesh comms awareness ir nebula auto_healing; do
        if [[ "$IMPORTS_LINE" == *"$sec_mod"* ]]; then
            pass "app.py imports section module: $sec_mod"
        else
            fail "app.py imports section module: $sec_mod" \
                 "Section module not in app.py import line: $IMPORTS_LINE"
        fi
    done
else
    fail "app.py has 'from .sections import' line"
fi

# b) entry script calls main()
if grep -q "main(" "$ENTRY" 2>/dev/null; then
    pass "orionx-control-center calls main()"
else
    fail "orionx-control-center calls main()"
fi

# c) helpers __init__.py exists (importable package marker)
if [[ -f "$CC_DIR/helpers/__init__.py" ]]; then
    pass "helpers/__init__.py present (package marker)"
else
    fail "helpers/__init__.py present (package marker)"
fi

# d) 4 widget scripts present
WIDGETS_DIR="$CC_DIR/widgets"
EXPECTED_WIDGETS=(
    "net-status.py"
    "mesh-status.py"
    "clients-count.py"
    "scans-count.py"
)
for w in "${EXPECTED_WIDGETS[@]}"; do
    if [[ -f "$WIDGETS_DIR/$w" ]]; then
        pass "widget present: $w"
    else
        fail "widget present: $w" "Not found: $WIDGETS_DIR/$w"
    fi
done

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
