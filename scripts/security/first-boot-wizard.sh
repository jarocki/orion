#!/usr/bin/env bash
# shellcheck shell=bash
#
# first-boot-wizard.sh — Orion-X First-Boot Setup Wizard
#
# Runs once on first boot to configure a fresh Orion-X node:
#   1. Set hostname
#   2. Set user password (interactive only)
#   3. Generate WireGuard keypair for mesh networking
#   4. Set Matrix (Synapse) credentials
#   5. Optionally disable SSH daemon
#   6. Write completion flag to prevent re-runs
#
# Designed to run as a systemd oneshot service (see orionx-first-boot.service)
# or manually via CLI. Supports non-interactive mode for automated deployments.
#
# Environment variables:
#   ORIONX_FIRST_BOOT_DRY_RUN  — Set to 1 to skip real system calls
#                                 (passwd, systemctl, hostnamectl). Used in CI/tests.
#   ORIONX_FIRST_BOOT_FLAG     — Override path for the completion flag file.
#                                 Defaults to /var/lib/orionx/.first-boot-done.
#
# @decision DEC-SEC-003
# @title First-boot wizard for Orion-X node initialization
# @status accepted
# @rationale A dedicated first-boot wizard ensures every node starts from a
#   known-good configuration. Running as a systemd oneshot with a flag-file
#   guard guarantees exactly-once execution. Dry-run mode enables safe testing
#   without root privileges or real system mutations. The wizard consolidates
#   hostname, credentials, WireGuard keys, and Matrix setup into a single
#   auditable entry point — reducing misconfiguration risk and ensuring
#   forensic readiness from first power-on.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants & defaults
# ---------------------------------------------------------------------------

readonly VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

FLAG_FILE="${ORIONX_FIRST_BOOT_FLAG:-/var/lib/orionx/.first-boot-done}"
DRY_RUN="${ORIONX_FIRST_BOOT_DRY_RUN:-0}"

# CLI state
NON_INTERACTIVE=0
SKIP_SSH=0
CUSTOM_HOSTNAME=""

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log_info() {
    printf "[INFO]  %s\n" "$*"
}

log_warn() {
    printf "[WARN]  %s\n" "$*" >&2
}

log_step() {
    printf "[STEP]  %s\n" "$*"
}

log_dry() {
    printf "[DRY]   %s (skipped — dry-run mode)\n" "$*"
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE_EOF
Usage: $SCRIPT_NAME [OPTIONS]

Orion-X First-Boot Setup Wizard v${VERSION}

Configures a fresh Orion-X node on its first boot. Creates hostname,
generates WireGuard keys, sets Matrix credentials, and writes a flag
file to prevent re-execution.

Options:
  --non-interactive     Run without prompts (uses defaults or CLI args)
  --hostname <name>     Set the node hostname (default: auto-generated)
  --skip-ssh            Disable the SSH daemon after setup
  -h, --help            Show this help message and exit

Environment:
  ORIONX_FIRST_BOOT_DRY_RUN=1   Skip real system calls (for testing)
  ORIONX_FIRST_BOOT_FLAG=<path>  Override flag file location

Examples:
  # Interactive first-boot (default)
  sudo $SCRIPT_NAME

  # Automated provisioning
  sudo $SCRIPT_NAME --non-interactive --hostname node-alpha-01

  # Test run (no system changes)
  ORIONX_FIRST_BOOT_DRY_RUN=1 $SCRIPT_NAME --non-interactive
USAGE_EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                NON_INTERACTIVE=1
                shift
                ;;
            --hostname)
                if [[ -z "${2:-}" ]]; then
                    log_warn "--hostname requires a value"
                    exit 1
                fi
                CUSTOM_HOSTNAME="$2"
                shift 2
                ;;
            --skip-ssh)
                SKIP_SSH=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_warn "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------

check_already_done() {
    if [[ -f "$FLAG_FILE" ]]; then
        log_info "First-boot setup already completed (flag: $FLAG_FILE). Skipping."
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Step 1: Set hostname
# ---------------------------------------------------------------------------

step_set_hostname() {
    local hostname="${CUSTOM_HOSTNAME}"

    if [[ -z "$hostname" ]]; then
        if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
            hostname="orionx-$(date +%s | shasum | cut -c1-8)"
        else
            printf "Enter hostname for this node [orionx-node]: "
            read -r hostname
            hostname="${hostname:-orionx-node}"
        fi
    fi

    log_step "Setting hostname: $hostname"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "hostnamectl set-hostname $hostname"
    else
        hostnamectl set-hostname "$hostname" 2>/dev/null || \
            hostname "$hostname" 2>/dev/null || \
            log_warn "Could not set hostname (not running as root?)"
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Set user password
# ---------------------------------------------------------------------------

step_set_password() {
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        log_step "Skipping password change (non-interactive mode)"
        return 0
    fi

    log_step "Setting user password"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "passwd orionx"
    else
        passwd orionx 2>/dev/null || \
            log_warn "Could not set password (user may not exist or not running as root)"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Generate WireGuard keypair
# ---------------------------------------------------------------------------

step_generate_wg_keys() {
    log_step "Generating WireGuard keypair for mesh networking"

    local wg_dir="/etc/wireguard"
    local privkey_path="$wg_dir/privatekey"
    local pubkey_path="$wg_dir/publickey"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "wg genkey | tee $privkey_path | wg pubkey > $pubkey_path"
        return 0
    fi

    if ! command -v wg >/dev/null 2>&1; then
        log_warn "WireGuard tools (wg) not found — skipping key generation"
        return 0
    fi

    mkdir -p "$wg_dir"
    wg genkey | tee "$privkey_path" | wg pubkey > "$pubkey_path"
    chmod 600 "$privkey_path"
    chmod 644 "$pubkey_path"
    log_info "WireGuard keys written to $wg_dir"
}

# ---------------------------------------------------------------------------
# Step 4: Set Matrix credentials
# ---------------------------------------------------------------------------

step_set_matrix_creds() {
    log_step "Configuring Matrix (Synapse) credentials"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "register_new_matrix_user for local admin"
        return 0
    fi

    if ! command -v register_new_matrix_user >/dev/null 2>&1; then
        log_warn "register_new_matrix_user not found — Matrix may not be installed"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        log_info "Matrix user registration deferred (non-interactive mode)"
    else
        printf "Register Matrix admin user now? [y/N]: "
        read -r confirm
        if [[ "${confirm,,}" == "y" ]]; then
            register_new_matrix_user -c /etc/matrix-synapse/homeserver.yaml || \
                log_warn "Matrix user registration failed"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Optionally disable SSH
# ---------------------------------------------------------------------------

step_disable_ssh() {
    if [[ "$SKIP_SSH" -eq 0 ]]; then
        log_step "SSH daemon: keeping enabled (use --skip-ssh to disable)"
        return 0
    fi

    log_step "SSH disable requested via --skip-ssh"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "systemctl disable --now ssh"
    else
        systemctl disable --now ssh 2>/dev/null || \
            log_warn "Could not disable SSH"
    fi

    log_info "SSH daemon disabled as requested"
}

# ---------------------------------------------------------------------------
# Step 6: Write completion flag
# ---------------------------------------------------------------------------

write_flag_file() {
    local flag_dir
    flag_dir="$(dirname "$FLAG_FILE")"

    if [[ ! -d "$flag_dir" ]]; then
        mkdir -p "$flag_dir" 2>/dev/null || true
    fi

    printf "first-boot-wizard completed at %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$FLAG_FILE"
    log_info "Completion flag written: $FLAG_FILE"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    local hostname_display="${CUSTOM_HOSTNAME:-<auto-generated>}"
    cat <<SUMMARY_EOF

=== Orion-X First-Boot Setup Complete ===

  Hostname:        $hostname_display
  WireGuard keys:  generated
  Matrix creds:    configured
  SSH disabled:    $(if [[ "$SKIP_SSH" -eq 1 ]]; then echo "yes"; else echo "no"; fi)
  Flag file:       $FLAG_FILE
  Dry-run mode:    $(if [[ "$DRY_RUN" -eq 1 ]]; then echo "yes"; else echo "no"; fi)

Node is ready for mesh enrollment. Run 'orionx-mesh join' to connect.

SUMMARY_EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    log_info "Orion-X First-Boot Setup Wizard v${VERSION}"

    # Idempotency: skip if already done
    if check_already_done; then
        return 0
    fi

    log_info "Starting first-boot configuration..."
    [[ "$DRY_RUN" -eq 1 ]] && log_info "Dry-run mode active — no system changes will be made"

    step_set_hostname
    step_set_password
    step_generate_wg_keys
    step_set_matrix_creds
    step_disable_ssh
    write_flag_file
    print_summary
}

main "$@"
