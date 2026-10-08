#!/usr/bin/env bash
# shellcheck shell=bash
#
# first-boot-wizard.sh — Orion-X First-Boot Setup Wizard
#
# Runs once on first boot to configure a fresh Orion-X node. Interactive on the
# console (tty1) via orionx-first-boot.service, BEFORE the display manager:
#   1. Set hostname
#   2. Set primary account username + password (rename the live user if changed)
#   3. Wi-Fi setup (SSID + password) — only when there is no wired link
#   4. Matrix admin registration (only if Synapse is already set up)
#   5. Report the SSH posture (sshd is NOT started at boot; --skip-ssh also
#      stops it now)
#   6. Write completion flag to prevent re-runs
#   (Mesh keys are created by `orionx-mesh join`, the single authority, not
#   here: DEC-PHASE12-105.)
#
# Designed to run as a systemd oneshot service (see orionx-first-boot.service)
# or manually via CLI (`sudo orionx-wizard`). Every prompt has an input timeout
# (falls back to defaults) so the wizard always completes and never hangs boot.
# Supports --non-interactive for automated deployments / CI (skips all prompts).
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

# Primary live account (from live-config.username / DEC-PHASE11-012). The operator
# can rename it in the interactive wizard. Overridable for tests.
PRIMARY_USER="${ORIONX_PRIMARY_USER:-orionx-operator}"

# Per-prompt input timeout (seconds). If the operator walks away, prompts fall
# back to their defaults so the wizard always completes and never hangs the boot.
# UX-14 (DEC-PHASE12-106): 30 s, not 120 s — five prompts at 120 s held an
# unattended deck at a text console for up to ten minutes.
PROMPT_TIMEOUT="${ORIONX_FIRST_BOOT_PROMPT_TIMEOUT:-30}"

# Kernel command line (overridable for tests). `orionx.wizard=0` = no prompts.
CMDLINE_FILE="${ORIONX_CMDLINE_FILE:-/proc/cmdline}"

# live-config writes these naming the live user literally (0040-sudo,
# 1080-policykit); an account rename must repoint them (DEC-PHASE12-106).
SUDOERS_LIVE="${ORIONX_SUDOERS_LIVE:-/etc/sudoers.d/live}"
POLKIT_LIVE="${ORIONX_POLKIT_LIVE:-/usr/share/polkit-1/rules.d/sudo_on_live.rules}"
WIFI_KEYFILE_DIR="${ORIONX_NM_CONN_DIR:-/etc/NetworkManager/system-connections}"
MATRIX_CONF="${ORIONX_MATRIX_CONF:-/etc/matrix-synapse/conf.d/orionx.yaml}"

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
registers a Matrix admin if Synapse is set up, and writes a flag
file to prevent re-execution. Mesh keys come from "orionx-mesh join".
Boot with orionx.wizard=0 on the kernel command line to skip all prompts.

Options:
  --non-interactive     Run without prompts (uses defaults or CLI args)
  --hostname <name>     Set the node hostname (default: auto-generated)
  --skip-ssh            Also stop sshd now (it is never started at boot)
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
            # Derive from the first non-loopback MAC so the name is STABLE per
            # device. The previous `date +%s | shasum` form minted a different
            # hostname on every boot: a live system has no persistence for the
            # first-boot sentinel, so the wizard re-runs each boot and the node
            # changed identity every time (hardware attestation 2026-08-21
            # observed orionx-218419db). Fallback to the timestamp form only
            # when no NIC exposes an address (e.g. minimal CI containers).
            # `|| true` is load-bearing: under set -euo pipefail an empty grep
            # result would otherwise kill the wizard mid-step (no /sys on
            # non-Linux test hosts; only-lo systems on real hardware).
            local _mac
            _mac="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | head -1 || true)"
            if [[ -n "$_mac" ]]; then
                hostname="orionx-$(printf '%s' "$_mac" | shasum | cut -c1-8)"
            else
                hostname="orionx-$(date +%s | shasum | cut -c1-8)"
            fi
        else
            printf "Enter hostname for this node [orionx-node]: "
            read -r -t "$PROMPT_TIMEOUT" hostname || hostname=""
            hostname="${hostname:-orionx-node}"
        fi
    fi

    log_step "Setting hostname: $hostname"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "hostnamectl set-hostname $hostname"
        log_dry "upsert '127.0.1.1 $hostname' in /etc/hosts"
    else
        hostnamectl set-hostname "$hostname" 2>/dev/null || \
            hostname "$hostname" 2>/dev/null || \
            log_warn "Could not set hostname (not running as root?)"
        # Keep /etc/hosts in sync. An unresolvable hostname makes every sudo
        # invocation print "unable to resolve host <name>" and stall on the
        # lookup timeout (hardware attestation 2026-08-21). Replace an existing
        # 127.0.1.1 line if present, append otherwise.
        if [[ -w /etc/hosts ]]; then
            if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
                sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${hostname}/" /etc/hosts
            else
                printf '127.0.1.1\t%s\n' "$hostname" >> /etc/hosts
            fi
        else
            log_warn "/etc/hosts not writable — hostname will not resolve locally (sudo will warn)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Set primary account username + password
#
# Prompts for the account name (default: the live user) and a password. Runs
# BEFORE the display manager starts, so no graphical session holds the account
# and it is safe to rename. If the operator picks a different name we rename the
# account + move its home + repoint LightDM autologin at it. All destructive
# steps are guarded: a failure leaves the original account usable and warns.
# ---------------------------------------------------------------------------

step_set_user_credentials() {
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        log_step "Skipping account setup (non-interactive mode)"
        return 0
    fi

    log_step "Account setup"

    local newuser=""
    printf "Username for the primary account [%s]: " "$PRIMARY_USER"
    read -r -t "$PROMPT_TIMEOUT" newuser || newuser=""
    newuser="${newuser:-$PRIMARY_USER}"
    # Sanitize: allow only a valid Linux username; otherwise keep the default.
    if ! printf '%s' "$newuser" | grep -qE '^[a-z_][a-z0-9_-]*$'; then
        log_warn "Invalid username '$newuser' — keeping '$PRIMARY_USER'"
        newuser="$PRIMARY_USER"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "rename '$PRIMARY_USER' -> '$newuser' (if changed) + move home + repoint autologin"
        log_dry "set password for '$newuser' via chpasswd"
        return 0
    fi

    # --- Rename the account if the operator chose a different name ---
    if [[ "$newuser" != "$PRIMARY_USER" ]] && id "$PRIMARY_USER" >/dev/null 2>&1; then
        if usermod -l "$newuser" "$PRIMARY_USER" 2>/dev/null; then
            usermod -d "/home/$newuser" -m "$newuser" 2>/dev/null || \
                log_warn "Renamed login but could not move home dir; home stays /home/$PRIMARY_USER"
            groupmod -n "$newuser" "$PRIMARY_USER" 2>/dev/null || true
            # Repoint LightDM autologin (single authority file, DEC-PHASE9-005).
            local al="/etc/lightdm/lightdm.conf.d/10-orionx-autologin.conf"
            if [[ -f "$al" ]]; then
                sed -i -E "s/^autologin-user=.*/autologin-user=${newuser}/" "$al" 2>/dev/null || \
                    log_warn "Could not update LightDM autologin-user"
            fi
            _repoint_privileges "$PRIMARY_USER" "$newuser"
            PRIMARY_USER="$newuser"
            log_info "Primary account renamed to '$newuser'"
        else
            log_warn "Could not rename account to '$newuser' — keeping '$PRIMARY_USER'"
        fi
    fi

    # --- Set the password (confirmed). Blank keeps the CURRENT password ---
    # UX-14 / system P3-1: the account is not passwordless. live-config sets
    # the live user's password to "live" (0030-user-setup); say so truthfully.
    local p1="" p2=""
    printf "Set a password for '%s' (blank = keep the current password): " "$PRIMARY_USER"
    read -r -s -t "$PROMPT_TIMEOUT" p1 || p1=""
    printf "\n"
    if [[ -n "$p1" ]]; then
        printf "Confirm password: "
        read -r -s -t "$PROMPT_TIMEOUT" p2 || p2=""
        printf "\n"
        if [[ "$p1" == "$p2" ]]; then
            if printf '%s:%s\n' "$PRIMARY_USER" "$p1" | chpasswd 2>/dev/null; then
                log_info "Password set for '$PRIMARY_USER'"
            else
                log_warn "Could not set password for '$PRIMARY_USER'"
            fi
        else
            log_warn "Passwords did not match — '$PRIMARY_USER' keeps its current password"
        fi
    else
        log_info "Keeping the current password for '$PRIMARY_USER' (on a fresh live boot that is: live)"
    fi
}

# ---------------------------------------------------------------------------
# Step 2a: keep sudo and polkit working across an account rename
#
# @decision DEC-PHASE12-106
# @title An account rename repoints live-config's sudo and polkit grants,
#   validated before it is installed
# @status accepted
# @rationale live-config writes the live user's NAME into
#   /etc/sudoers.d/live ("<user> ALL=(ALL) NOPASSWD: ALL", 0040-sudo) and
#   into sudo_on_live.rules (subject.user === "<user>", 1080-policykit).
#   `usermod -l` changed the name and left both pointing at a user that no
#   longer existed, so every Cockpit terminal button (sudo orionx-mesh join,
#   sudo setup-matrix.sh) started asking for a password the operator had
#   just been told did not exist, and NetworkManager/udisks raised polkit
#   prompts (system P2-5). The rewrite replaces the exact old name, checks
#   the sudoers result with `visudo -cf` BEFORE installing it, and keeps the
#   old file (and says so) if the check fails.
# ---------------------------------------------------------------------------

_repoint_privileges() {
    local old="$1" new="$2" tmp
    if [[ -f "$SUDOERS_LIVE" ]]; then
        tmp="$(mktemp "${SUDOERS_LIVE}.XXXXXX")"
        sed -E "s/^${old}([[:space:]])/${new}\1/" "$SUDOERS_LIVE" > "$tmp"
        chmod 0440 "$tmp"
        if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"
            log_warn "sudoers rewrite for '$new' failed validation — left $SUDOERS_LIVE unchanged; 'sudo' will ask '$new' for a password"
        else
            mv -f "$tmp" "$SUDOERS_LIVE"
            log_info "sudo grant moved from '$old' to '$new' ($SUDOERS_LIVE)"
        fi
    fi
    if [[ -f "$POLKIT_LIVE" ]]; then
        tmp="$(mktemp "${POLKIT_LIVE}.XXXXXX")"
        sed "s/\"${old}\"/\"${new}\"/g" "$POLKIT_LIVE" > "$tmp"
        chmod 0644 "$tmp"
        mv -f "$tmp" "$POLKIT_LIVE"
        log_info "polkit grant moved from '$old' to '$new' ($POLKIT_LIVE)"
    fi
}

# ---------------------------------------------------------------------------
# Step 2b: Wi-Fi setup (only when there is no wired link)
#
# A cyberdeck is often used without ethernet. When no wired NIC has carrier we
# prompt for an SSID + password and bring up the connection via nmcli so the
# operator is online for mesh/updates immediately after first boot.
#
# DEC-PHASE12-106 (security F24): the Wi-Fi password used to go on nmcli's
# argv (`nmcli device wifi connect SSID password PSK`), readable in
# /proc/*/cmdline by every local uid while it ran. It now goes into a
# NetworkManager keyfile created 0600 root (the format NM itself stores
# secrets in), and nmcli only names the connection.
# ---------------------------------------------------------------------------

_has_wired_link() {
    local carrier
    for carrier in /sys/class/net/e*/carrier /sys/class/net/en*/carrier; do
        [[ -e "$carrier" ]] || continue
        [[ "$(cat "$carrier" 2>/dev/null || echo 0)" == "1" ]] && return 0
    done
    return 1
}

# Write a WPA-PSK (or open) keyfile. Args: ssid psk(may be empty). Prints path.
_write_wifi_keyfile() {
    local ssid="$1" psk="$2" f
    mkdir -p "$WIFI_KEYFILE_DIR"
    f="$WIFI_KEYFILE_DIR/orionx-wifi.nmconnection"
    (
        umask 077
        {
            printf '[connection]\nid=orionx-wifi\ntype=wifi\nautoconnect=true\n\n'
            printf '[wifi]\nmode=infrastructure\nssid=%s\n\n' "$ssid"
            if [[ -n "$psk" ]]; then
                printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$psk"
            fi
            printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
        } > "$f"
    )
    chmod 0600 "$f"
    printf '%s' "$f"
}

step_setup_wifi() {
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        log_step "Skipping Wi-Fi setup (non-interactive mode)"
        return 0
    fi

    if _has_wired_link; then
        log_step "Wired network detected — skipping Wi-Fi setup"
        return 0
    fi

    log_step "No wired network — Wi-Fi setup"

    if ! command -v nmcli >/dev/null 2>&1; then
        log_warn "nmcli not available — skipping Wi-Fi setup"
        return 0
    fi

    local ssid="" psk=""
    printf "Wi-Fi network name (SSID) [blank = skip]: "
    read -r -t "$PROMPT_TIMEOUT" ssid || ssid=""
    if [[ -z "$ssid" ]]; then
        log_info "No SSID entered — skipping Wi-Fi"
        return 0
    fi
    if [[ "$ssid" == *$'\n'* || "$ssid" == *$'\r'* ]]; then
        log_warn "SSID contains a line break — skipping Wi-Fi"
        return 0
    fi
    printf "Wi-Fi password for '%s' (blank = open network): " "$ssid"
    read -r -s -t "$PROMPT_TIMEOUT" psk || psk=""
    printf "\n"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "write $WIFI_KEYFILE_DIR/orionx-wifi.nmconnection (0600) for '$ssid'; nmcli connection up orionx-wifi"
        return 0
    fi

    nmcli radio wifi on 2>/dev/null || true
    _write_wifi_keyfile "$ssid" "$psk" >/dev/null
    psk=""
    nmcli connection reload 2>/dev/null || true
    if nmcli connection up orionx-wifi 2>/dev/null; then
        log_info "Connected to Wi-Fi '$ssid'"
    else
        log_warn "Could not connect to '$ssid' (check name/password/coverage) — you can retry later from the panel"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Matrix admin registration (only when Synapse is already set up)
#
# @decision DEC-PHASE12-105
# @title The wizard no longer creates mesh keys, a wg0.conf, or an SSH
#   "one-shot" root key
# @status accepted
# @rationale Three removals, each a second authority or a leak:
#   - step_seed_ssh_admin (DEC-PHASE11-019) generated a root ed25519 key on
#     EVERY boot and wrote the private key AND its passphrase, mode 0644, to
#     /etc/motd.d and /etc/issue.d — agetty prints issue.d before login, so
#     anyone at the console could read a root credential, and every local uid
#     could read the motd copy (system P1-3, shell P1-3, security F6). It was
#     also dead: sshd ships PermitRootLogin no. Removed with the placeholder
#     files. The only SSH admin path is key-based login for the operator
#     account, over wg0 (firewall), with sshd started deliberately
#     (DEC-PHASE12-104). No secret is written to /etc/issue* or /etc/motd*.
#   - step_generate_wg_keys wrote three copies of a private key (privatekey,
#     mesh-private.key, inline in wg0.conf), the first two briefly 0644 under
#     the unit's 0022 umask (shell P2-1), and a wg0.conf at 10.100.0.x/24
#     that nothing uses while the mesh is 10.0.99.0/24 (shell P3-4, F17).
#     `orionx-mesh join` creates the one key it needs, under umask 077.
# ---------------------------------------------------------------------------

step_set_matrix_creds() {
    log_step "Matrix (Synapse) admin registration"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "register_new_matrix_user -c $MATRIX_CONF (only if Synapse is set up)"
        return 0
    fi

    if ! command -v register_new_matrix_user >/dev/null 2>&1 || [[ ! -f "$MATRIX_CONF" ]]; then
        log_info "Synapse is not set up on this deck — nothing to register (Cockpit > Comms > Set up as server)"
        return 0
    fi

    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        log_info "Matrix user registration deferred (non-interactive mode)"
    else
        local confirm=""
        printf "Register Matrix admin user now? [y/N]: "
        # UX-14 / shell P3-5: this was the one prompt with no timeout — at EOF
        # under set -e it aborted the wizard before the completion flag.
        read -r -t "$PROMPT_TIMEOUT" confirm || confirm=""
        if [[ "${confirm,,}" == "y" ]]; then
            register_new_matrix_user -c "$MATRIX_CONF" -a "http://127.0.0.1:8008" || \
                log_warn "Matrix user registration failed"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 4: SSH posture
# ---------------------------------------------------------------------------

step_disable_ssh() {
    if [[ "$SKIP_SSH" -eq 0 ]]; then
        log_step "SSH daemon: not started at boot (start it with: sudo systemctl start ssh; reachable over the mesh only, key login for '$PRIMARY_USER')"
        return 0
    fi

    log_step "SSH stop requested via --skip-ssh"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "systemctl disable --now ssh"
    else
        if systemctl disable --now ssh 2>/dev/null; then
            log_info "SSH daemon stopped and disabled"
        else
            log_warn "Could not stop SSH (systemctl disable --now ssh failed)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 5: Write completion flag
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
  SSH daemon:      $(if [[ "$SKIP_SSH" -eq 1 ]]; then echo "stopped"; else echo "not started at boot (sudo systemctl start ssh)"; fi)
  Flag file:       $FLAG_FILE
  Dry-run mode:    $(if [[ "$DRY_RUN" -eq 1 ]]; then echo "yes"; else echo "no"; fi)

Node is ready for mesh enrollment. Run 'orionx-mesh join' to connect.

SUMMARY_EOF
}

# ---------------------------------------------------------------------------
# Interactive attention banner
#
# @decision DEC-PHASE11-043
# @title First-boot wizard must visibly announce "the boot paused — your turn"
# @status accepted
# @rationale The wizard runs on tty1 BEFORE the display manager. The operator
#   reported that its prompts were indistinguishable from ordinary boot log
#   spew — nothing signalled that the boot had PAUSED to wait for input. Clear
#   the screen and print a high-contrast Phoenix-colored banner so it is
#   unmistakable that the system is waiting on the operator. Gated on
#   interactive mode + a real TTY so --non-interactive/CI runs stay clean (no
#   escape sequences in captured output).
# ---------------------------------------------------------------------------

announce_interactive_start() {
    [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
    [[ -t 1 ]] || return 0

    local RED=$'\033[1;38;5;202m'   # Phoenix orange-red (256-color; VT-safe on tty1)
    local BOLD=$'\033[1m'
    local DIM=$'\033[2m'
    local RST=$'\033[0m'
    local rule
    rule="$(printf '%0.s─' {1..64})"

    clear 2>/dev/null || printf '\033[2J\033[H'
    printf '\n%s%s%s\n' "$RED" "$rule" "$RST"
    printf '%s        ORION-X  PHOENIX  ·  FIRST-BOOT SETUP%s\n' "$RED$BOLD" "$RST"
    printf '%s%s%s\n\n' "$RED" "$rule" "$RST"
    printf '  %s>>>  The boot has PAUSED — this system needs your input.  <<<%s\n\n' "$BOLD" "$RST"
    printf '  Answer the prompts below to configure this node:\n'
    printf '    hostname  ·  primary account + password  ·  Wi-Fi (if no cable)\n\n'
    printf '  %sEach prompt auto-continues with its default after %ss if left blank.%s\n' \
        "$DIM" "$PROMPT_TIMEOUT" "$RST"
    printf '  %sTo boot without these questions: add orionx.wizard=0 to the kernel command line.%s\n\n' \
        "$DIM" "$RST"
}

# ---------------------------------------------------------------------------
# UX-14 (DEC-PHASE12-106): `orionx.wizard=0` on the kernel command line runs
# the wizard with no prompts (same as --non-interactive): an unattended or
# headless boot on a hostile network should not wait at a text console.
# ---------------------------------------------------------------------------
cmdline_disables_prompts() {
    local tok
    local -a toks=()
    [[ -r "$CMDLINE_FILE" ]] || return 1
    read -r -a toks < "$CMDLINE_FILE" || true
    for tok in "${toks[@]+"${toks[@]}"}"; do
        [[ "$tok" == "orionx.wizard=0" ]] && return 0
    done
    return 1
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

    if [[ "$NON_INTERACTIVE" -eq 0 ]] && cmdline_disables_prompts; then
        NON_INTERACTIVE=1
        log_info "orionx.wizard=0 on the kernel command line — running without prompts"
    fi

    log_info "Starting first-boot configuration..."
    [[ "$DRY_RUN" -eq 1 ]] && log_info "Dry-run mode active — no system changes will be made"

    # Make it unmistakable that the boot has paused for the operator (tty1).
    announce_interactive_start

    # Operator onboarding first (hostname → account → Wi-Fi), then node provisioning.
    step_set_hostname
    step_set_user_credentials
    step_setup_wifi
    step_set_matrix_creds
    step_disable_ssh
    write_flag_file
    print_summary
}

# Tests source this file for its functions (ORIONX_WIZARD_SOURCED=1).
if [[ "${ORIONX_WIZARD_SOURCED:-0}" == "1" ]]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || true
fi

main "$@"
