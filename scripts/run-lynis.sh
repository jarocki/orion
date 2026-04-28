#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-SEC-005
# @title Modernize run-lynis.sh, retire run-lynis-v2.sh
# @status accepted
# @rationale Single source of truth. run-lynis-v2.sh was a Docker workaround
#   that duplicated logic with Docker-specific hacks. This unified script
#   handles all environments: bare metal, Docker, CI. Custom Lynis profile
#   generation tunes for Orion-X live CD forensic environment. Threshold
#   gating and JSON output enable CI pipeline integration.
#
# Orion-X Phoenix Edition v2.0.0 — Lynis security audit runner
#
# Runs Lynis to perform a security audit on the Orion-X system, with
# custom profile generation tuned for forensic live CDs. Supports
# threshold-based CI gating and JSON summary output.
#
# Usage: run-lynis.sh [options]
#
# Options:
#   --profile <path>      Custom Lynis profile (default: built-in orionx profile)
#   --output-dir <dir>    Output directory (default: /var/log/orionx/lynis)
#   --quick               Quick audit (skip slow tests)
#   --threshold <N>       Minimum hardening index (exit non-zero if below, default: 75)
#   --json                Output JSON summary
#   --help, -h            Show this help

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CUSTOM_PROFILE=""
OUTPUT_DIR="/var/log/orionx/lynis"
QUICK_MODE=false
THRESHOLD=75
JSON_OUTPUT=false

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<'HELPTEXT'
Usage: run-lynis.sh [options]

Run a Lynis security audit on the Orion-X system.

Options:
  --profile <path>      Custom Lynis profile (default: built-in orionx profile)
  --output-dir <dir>    Output directory (default: /var/log/orionx/lynis)
  --quick               Quick audit (skip slow tests)
  --threshold <N>       Minimum hardening index (exit non-zero if below, default: 75)
  --json                Output JSON summary
  --help, -h            Show this help

The script generates a custom Lynis profile tuned for Orion-X forensic
live CD environments, skipping tests irrelevant to ephemeral systems
(bootloader passwords, password aging, etc.) and focusing on runtime
security posture.

When --threshold is set, the script exits non-zero if the Lynis
Hardening Index falls below the given value. Combined with --json,
this enables automated CI/CD security gates.

Examples:
  # Standard audit with default threshold (75):
  run-lynis.sh

  # Quick audit with JSON output for CI:
  run-lynis.sh --quick --json --threshold 80

  # Custom profile and output directory:
  run-lynis.sh --profile /etc/lynis/custom.prf --output-dir /evidence/audit

  # Quick check, relaxed threshold:
  run-lynis.sh --quick --threshold 60
HELPTEXT
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                if [[ $# -lt 2 ]]; then
                    log_error "--profile requires a path argument"
                    exit 1
                fi
                CUSTOM_PROFILE="$2"
                shift 2
                ;;
            --output-dir)
                if [[ $# -lt 2 ]]; then
                    log_error "--output-dir requires a directory argument"
                    exit 1
                fi
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --quick)
                QUICK_MODE=true
                shift
                ;;
            --threshold)
                if [[ $# -lt 2 ]]; then
                    log_error "--threshold requires a numeric argument"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--threshold must be a number, got: $2"
                    exit 1
                fi
                THRESHOLD="$2"
                shift 2
                ;;
            --json)
                JSON_OUTPUT=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Generate Orion-X Lynis profile
# ---------------------------------------------------------------------------
generate_orionx_profile() {
    local profile_path="$1"
    local profile_dir
    profile_dir="$(dirname "$profile_path")"

    mkdir -p "$profile_dir"

    cat > "$profile_path" << 'PROFILE'
# Orion-X Phoenix Edition — Custom Lynis profile
# Tuned for forensic live CD environments
#
# Live CDs are ephemeral: bootloader, password aging, and persistent
# storage tests are irrelevant. Focus on runtime security posture.

# Skip tests irrelevant to live CD / forensic environments
skip-test=BOOT-5122    # Bootloader password (live CD — no persistent bootloader)
skip-test=BOOT-5184    # Secure Boot settings (handled by ISO build process)
skip-test=AUTH-9328    # Password aging (not applicable for forensic system)
skip-test=FILE-6310    # Unowned files (live CD overlay filesystem)
skip-test=KRNL-5820    # Kernel hardening sysctl (live CD kernel is pre-built)

# Tests to include (forensic/security focus)
test=FILE-7524         # Find world-writable files
test=MALW-3280         # Check for rootkits
test=NETW-3032         # Check firewall status
test=CRYP-7902         # Check SSH key permissions
test=CONT-8102         # Check Docker security
test=AUTH-9262         # Check sudo configuration
test=PRNT-2307         # Check print daemon configuration
test=USB-1000          # Check USB storage restrictions

# Custom settings
config-data=lynis.log-tests-incorrect=yes
PROFILE

    log "Generated Orion-X Lynis profile: $profile_path"
}

# ---------------------------------------------------------------------------
# Parse Lynis output for hardening index
# ---------------------------------------------------------------------------
parse_hardening_index() {
    local report_file="$1"
    local score=""

    # Lynis outputs "Hardening index : NN [########    ]" or similar
    if [[ -f "$report_file" ]]; then
        score=$(grep -oP 'Hardening index\s*:\s*\K[0-9]+' "$report_file" 2>/dev/null || true)
        # Fallback: try alternate format
        if [[ -z "$score" ]]; then
            score=$(grep "Hardening index" "$report_file" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
        fi
    fi

    echo "${score:-0}"
}

# ---------------------------------------------------------------------------
# Parse warnings and suggestions count
# ---------------------------------------------------------------------------
parse_warnings_count() {
    local report_file="$1"
    local count=""
    if [[ -f "$report_file" ]]; then
        count=$(grep -E '^\s*Warnings' "$report_file" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
    fi
    echo "${count:-0}"
}

parse_suggestions_count() {
    local report_file="$1"
    local count=""
    if [[ -f "$report_file" ]]; then
        count=$(grep -E '^\s*Suggestions' "$report_file" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
    fi
    echo "${count:-0}"
}

# ---------------------------------------------------------------------------
# Emit JSON summary
# ---------------------------------------------------------------------------
emit_json_summary() {
    local score="$1"
    local warnings="$2"
    local suggestions="$3"
    local threshold="$4"
    local passed="$5"
    local report_file="$6"

    cat <<JSONEOF
{
  "tool": "lynis",
  "version": "$(lynis --version 2>/dev/null || echo 'unknown')",
  "hardening_index": ${score},
  "threshold": ${threshold},
  "threshold_passed": ${passed},
  "warnings": ${warnings},
  "suggestions": ${suggestions},
  "report_file": "${report_file}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSONEOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Check if Lynis is installed
    if ! command -v lynis >/dev/null 2>&1; then
        log "Lynis is not installed. Skipping security audit."
        log "Install Lynis: apt-get install lynis (Debian/Ubuntu) or brew install lynis (macOS)"
        if [[ "$JSON_OUTPUT" == true ]]; then
            cat <<'SKIPJSON'
{
  "tool": "lynis",
  "status": "skipped",
  "reason": "Lynis not installed",
  "hardening_index": null,
  "threshold_passed": null
}
SKIPJSON
        fi
        exit 0
    fi

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Determine profile to use
    local profile_path
    if [[ -n "$CUSTOM_PROFILE" ]]; then
        if [[ ! -f "$CUSTOM_PROFILE" ]]; then
            log_error "Custom profile not found: $CUSTOM_PROFILE"
            exit 1
        fi
        profile_path="$CUSTOM_PROFILE"
        log "Using custom Lynis profile: $profile_path"
    else
        profile_path="$OUTPUT_DIR/orionx.prf"
        generate_orionx_profile "$profile_path"
    fi

    # Build Lynis command
    local lynis_args=("audit" "system" "--profile" "$profile_path" "--cronjob" "--no-colors")

    if [[ "$QUICK_MODE" == true ]]; then
        lynis_args+=("--quick")
        log "Running Lynis quick audit..."
    else
        log "Running Lynis full audit..."
    fi

    # Run Lynis audit
    local report_file="$OUTPUT_DIR/lynis-report.txt"
    local lynis_log="$OUTPUT_DIR/lynis-audit.log"

    set +e
    lynis "${lynis_args[@]}" > "$report_file" 2>"$lynis_log"
    local lynis_rc=$?
    set -e

    if [[ $lynis_rc -eq 0 ]]; then
        log "Lynis audit completed successfully"
    else
        log "Lynis audit completed with exit code $lynis_rc (warnings or non-fatal errors)"
    fi

    # Parse results
    local score warnings suggestions
    score=$(parse_hardening_index "$report_file")
    warnings=$(parse_warnings_count "$report_file")
    suggestions=$(parse_suggestions_count "$report_file")

    log "Hardening index: $score"
    log "Warnings: $warnings"
    log "Suggestions: $suggestions"

    # Threshold check
    local threshold_passed=true
    if [[ "$score" -lt "$THRESHOLD" ]]; then
        threshold_passed=false
        log_error "Hardening index ($score) is below threshold ($THRESHOLD)"
    else
        log "Hardening index ($score) meets threshold ($THRESHOLD)"
    fi

    # Output JSON summary if requested
    if [[ "$JSON_OUTPUT" == true ]]; then
        emit_json_summary "$score" "$warnings" "$suggestions" "$THRESHOLD" "$threshold_passed" "$report_file"
    else
        # Display human-readable summary
        echo ""
        echo "=========================================="
        echo "Lynis Security Audit Complete"
        echo "=========================================="
        echo "Report file: $report_file"
        echo "Log file:    $lynis_log"
        echo ""
        echo "Hardening index: $score (threshold: $THRESHOLD)"
        echo "Warnings:        $warnings"
        echo "Suggestions:     $suggestions"
        echo ""
        if [[ "$threshold_passed" == false ]]; then
            echo "RESULT: FAIL — hardening index below threshold"
        else
            echo "RESULT: PASS — hardening index meets threshold"
        fi
        echo "=========================================="
    fi

    # Exit non-zero if threshold not met
    if [[ "$threshold_passed" == false ]]; then
        exit 1
    fi
}

main "$@"
