#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
#
# Orion-X Phoenix Edition v2.0.0 — Credential Audit Tool
#
# Scans scripts and configs for hardcoded passwords, tokens, keys.
# Exit 0 = clean, Exit 1 = findings.
#
# Usage: audit-credentials.sh [--help|-h]
#
# @decision DEC-SEC-AUDIT-001
# @title Automated credential audit for all scripts
# @status accepted
# @rationale Zero hardcoded credentials is a Phase 6 acceptance criterion.
#   Grep-based scanning catches common credential patterns while excluding
#   template placeholders (ORIONX_*), test fixtures, and comments about
#   credential handling. Advisory notes are emitted for known-safe patterns
#   that warrant documentation (e.g., passwordless live user).

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------------------------------------------------------------------------
# CLI: --help
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'USAGE'
Usage: audit-credentials.sh [--help|-h]

Scans Orion-X project scripts and configs for hardcoded credentials.

Directories scanned: scripts/, iso/, docker/
Exclusions: tests/, template placeholders (ORIONX_*), labeled test secrets,
            comments explaining credential handling, this script itself.

Exit codes:
  0  No hardcoded credentials found (clean)
  1  One or more hardcoded credentials found

Output format:
  CLEAN:   File has no hardcoded credentials
  NOTE:    Advisory (known-safe pattern, documented)
  FINDING: Hardcoded credential detected (causes exit 1)
USAGE
    exit 0
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
FILES_SCANNED=0
FINDINGS=0
NOTES=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
report_clean() {
    echo "  CLEAN: $1 (no hardcoded credentials)"
}

report_note() {
    echo "  NOTE:  $1 — $2"
    NOTES=$((NOTES + 1))
}

report_finding() {
    echo "  FINDING: $1 — $2"
    FINDINGS=$((FINDINGS + 1))
}

# ---------------------------------------------------------------------------
# Credential patterns (extended regex)
# ---------------------------------------------------------------------------
# Each pattern is a grep -E regex. We search for assignment patterns that
# could indicate hardcoded secrets, then filter out known-safe exclusions.
PATTERNS=(
    'password=|passwd=|PASSWORD='
    'token=|TOKEN='
    'secret=|SECRET='
    'api_key=|API_KEY='
    '-----BEGIN.*KEY-----'
)

# ---------------------------------------------------------------------------
# Exclusion logic
# ---------------------------------------------------------------------------
# Returns 0 (true) if a grep match line should be excluded (not a finding).
is_excluded() {
    local line="$1"
    local file="$2"

    # Exclude: this script itself
    if [[ "$file" == "$SCRIPT_PATH" ]]; then
        return 0
    fi

    # Exclude: comment lines (# ... pattern)
    # Trim leading whitespace before checking for #
    local trimmed
    trimmed="${line#"${line%%[![:space:]]*}"}"
    if [[ "$trimmed" == \#* ]]; then
        return 0
    fi

    # Exclude: template placeholders — lines containing ORIONX_ variable names
    # These are substituted at runtime, not hardcoded credentials.
    if echo "$line" | grep -qE 'ORIONX_[A-Z_]+'; then
        return 0
    fi

    # Exclude: CLI argument parsing (--password, --admin-pass, etc.)
    # These accept user input, they don't embed credentials.
    if echo "$line" | grep -qE '^\s*--'; then
        return 0
    fi

    # Exclude: variable assignments that reference other variables or CLI args
    # e.g., MATRIX_PASSWORD="$CLI_ADMIN_PASS" or PASSWORD="${2:-}"
    if echo "$line" | grep -qE '="\$|=\$\{|=\$\('; then
        return 0
    fi

    # Exclude: read -rsp (interactive password prompt)
    if echo "$line" | grep -qE 'read\s+-r?s?p'; then
        return 0
    fi

    # Exclude: labeled test secrets in docker compose files
    if echo "$line" | grep -qiE 'test.*secret|secret.*test|do-not-use-in-prod'; then
        return 0
    fi

    # Exclude: empty variable initialization (PASSWORD="" or SECRET="")
    if echo "$line" | grep -qE '(password|passwd|secret|token|api_key)=""' 2>/dev/null; then
        return 0
    fi
    if echo "$line" | grep -qEi '(PASSWORD|PASSWD|SECRET|TOKEN|API_KEY)=""'; then
        return 0
    fi

    # Exclude: echo/log/printf statements that just mention the word
    if echo "$line" | grep -qE '^\s*(echo|log|printf)\s'; then
        return 0
    fi

    # Exclude: usage/help text lines (inside heredocs or echo)
    if echo "$line" | grep -qE '^\s*(#|echo|cat|Usage|Options|--help)'; then
        return 0
    fi

    # Exclude: case statement patterns
    if echo "$line" | grep -qE '^\s*--password\)'; then
        return 0
    fi

    # Exclude: environment variable references (checking if set, not assigning literal)
    if echo "$line" | grep -qE '\$\{?(ORIONX_|CLI_|MATRIX_)'; then
        return 0
    fi

    # Exclude: sed placeholder substitution (template engines)
    if echo "$line" | grep -qE 'sed\s'; then
        return 0
    fi

    # Exclude: conditional checks on variables ([ -n "$VAR" ])
    if echo "$line" | grep -qE '\[\s.*\$'; then
        return 0
    fi

    # Exclude: function parameter assignments from function args
    if echo "$line" | grep -qE '(local|declare)\s'; then
        return 0
    fi

    # Not excluded
    return 1
}

# ---------------------------------------------------------------------------
# Scan a single file
# ---------------------------------------------------------------------------
scan_file() {
    local file="$1"
    local rel_file="${file#"$REPO_ROOT/"}"
    local file_has_finding=false

    FILES_SCANNED=$((FILES_SCANNED + 1))

    # Skip: this script itself
    if [[ "$file" == "$SCRIPT_PATH" ]]; then
        report_clean "$rel_file"
        return
    fi

    # Advisory: passwordless user in chroot hook
    if [[ "$rel_file" == *"010-create-user.chroot"* ]]; then
        if grep -q 'passwd -d' "$file" 2>/dev/null; then
            report_note "$rel_file" "passwordless user (remediated by first-boot wizard)"
            return
        fi
    fi

    # Check each pattern
    for pattern in "${PATTERNS[@]}"; do
        local matches
        matches=$(grep -nE "$pattern" "$file" 2>/dev/null || true)

        if [[ -z "$matches" ]]; then
            continue
        fi

        # Check each matching line against exclusions
        while IFS= read -r match_line; do
            local line_content="${match_line#*:}"

            if ! is_excluded "$line_content" "$file"; then
                report_finding "$rel_file" "line ${match_line%%:*}: ${line_content}"
                file_has_finding=true
            fi
        done <<< "$matches"
    done

    if [[ "$file_has_finding" == false ]]; then
        report_clean "$rel_file"
    fi
}

# ---------------------------------------------------------------------------
# Main: collect files and scan
# ---------------------------------------------------------------------------
echo "=== Orion-X Credential Audit ==="
echo "Scanning: scripts/, iso/, docker/"
echo ""

# Collect scannable files from the three target directories
# NOTE: Uses while-read loop instead of mapfile for bash 3.2 (macOS) compat.
scan_files=()
while IFS= read -r _file; do
    scan_files+=("$_file")
done < <(
    find "$REPO_ROOT/scripts" "$REPO_ROOT/iso" "$REPO_ROOT/docker" \
        -type f \
        \( -name '*.sh' -o -name '*.chroot' -o -name '*.yml' -o -name '*.yaml' \
           -o -name '*.conf' -o -name '*.py' -o -name 'config' \) \
        ! -path '*/tests/*' \
        2>/dev/null | sort
)

for file in "${scan_files[@]}"; do
    scan_file "$file"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $NOTES -gt 0 ]]; then
    notes_text="$NOTES advisory note"
    if [[ $NOTES -gt 1 ]]; then notes_text="${notes_text}s"; fi
else
    notes_text="0 advisory notes"
fi

echo "Results: $FILES_SCANNED files scanned, $FINDINGS findings, $notes_text"

if [[ $FINDINGS -gt 0 ]]; then
    echo ""
    echo "FAILED: $FINDINGS hardcoded credential(s) detected."
    exit 1
fi

exit 0
