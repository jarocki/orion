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
#   4. Generate WireGuard keypair for mesh networking
#   5. Seed a one-shot SSH admin path
#   6. Set Matrix (Synapse) credentials
#   7. Optionally disable SSH daemon
#   8. Write completion flag to prevent re-runs
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
PROMPT_TIMEOUT="${ORIONX_FIRST_BOOT_PROMPT_TIMEOUT:-120}"

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
            PRIMARY_USER="$newuser"
            log_info "Primary account renamed to '$newuser'"
        else
            log_warn "Could not rename account to '$newuser' — keeping '$PRIMARY_USER'"
        fi
    fi

    # --- Set the password (confirmed). Blank keeps the account passwordless ---
    local p1="" p2=""
    printf "Set a password for '%s' (blank = keep passwordless): " "$PRIMARY_USER"
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
            log_warn "Passwords did not match — leaving '$PRIMARY_USER' passwordless"
        fi
    else
        log_info "Keeping '$PRIMARY_USER' passwordless"
    fi
}

# ---------------------------------------------------------------------------
# Step 2b: Wi-Fi setup (only when there is no wired link)
#
# A cyberdeck is often used without ethernet. When no wired NIC has carrier we
# prompt for an SSID + password and bring up the connection via nmcli so the
# operator is online for mesh/updates immediately after first boot.
# ---------------------------------------------------------------------------

_has_wired_link() {
    local carrier
    for carrier in /sys/class/net/e*/carrier /sys/class/net/en*/carrier; do
        [[ -e "$carrier" ]] || continue
        [[ "$(cat "$carrier" 2>/dev/null || echo 0)" == "1" ]] && return 0
    done
    return 1
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
    printf "Wi-Fi password for '%s' (blank = open network): " "$ssid"
    read -r -s -t "$PROMPT_TIMEOUT" psk || psk=""
    printf "\n"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "nmcli radio wifi on; nmcli device wifi connect '$ssid' [password ****]"
        return 0
    fi

    nmcli radio wifi on 2>/dev/null || true
    local ok=1
    if [[ -n "$psk" ]]; then
        nmcli device wifi connect "$ssid" password "$psk" 2>/dev/null && ok=0
    else
        nmcli device wifi connect "$ssid" 2>/dev/null && ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        log_info "Connected to Wi-Fi '$ssid'"
    else
        log_warn "Could not connect to '$ssid' (check name/password/coverage) — you can retry later from the panel"
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Generate WireGuard keypair
# ---------------------------------------------------------------------------

step_generate_wg_keys() {
    # @decision DEC-PHASE11-016
    # @title first-boot wizard authors wg0.conf + mesh-private.key at exact paths
    # @status accepted
    # @rationale Hardware attestation (2026-08-03) showed that even with the wizard
    #   running, wg-quick@wg0 failed because wg0.conf did not exist, and
    #   orionx-mesh-beacon failed because mesh-lib.sh:39 reads mesh-private.key
    #   (not 'privatekey'). This step authors both files immediately after key
    #   generation so the mesh cascade starts green on first boot without requiring
    #   a manual 'orionx-mesh join' pre-configuration step.
    log_step "Generating WireGuard keypair for mesh networking"

    local wg_dir="/etc/wireguard"
    local privkey_path="$wg_dir/privatekey"
    local pubkey_path="$wg_dir/publickey"
    local mesh_privkey_path="$wg_dir/mesh-private.key"
    local wg0_conf_path="$wg_dir/wg0.conf"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "wg genkey | tee $privkey_path | wg pubkey > $pubkey_path"
        log_dry "cp $privkey_path $mesh_privkey_path  # path expected by mesh-lib.sh:39"
        log_dry "author $wg0_conf_path  # [Interface] stanza for wg-quick@wg0"
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

    # Copy private key to the exact path mesh-lib.sh:39 and orionx-mesh-beacon
    # expect. Using cp rather than a symlink keeps key material in one canonical
    # location with the same ACL, and avoids broken-symlink edge cases on fresh
    # mounts (DEC-PHASE11-016).
    cp "$privkey_path" "$mesh_privkey_path"
    chmod 600 "$mesh_privkey_path"
    log_info "mesh-private.key written (path expected by orionx-mesh-beacon)"

    # Derive the host-specific mesh address from the host's first IPv4 address.
    # Use the fourth octet for a /24 inside 10.100.0.0/24. Fallback to .1 when
    # no IPv4 is yet available (e.g., pre-DHCP early-boot context). Peer entries
    # are added dynamically by 'orionx-mesh join' — this conf only brings wg0 up
    # so wg-quick@wg0 succeeds (DEC-PHASE11-016, R1: host-octet collision risk is
    # documented and mitigated by DHCP uniqueness on a real LAN).
    # Derived via ip(8), NOT `hostname -I`: the hostname binary is diverted by
    # live-build during image builds and was shipped MISSING on rc1-31 (divert
    # never restored across resumed builds). `hostname -I` then dies 127 under
    # set -euo pipefail — the exact first-boot failure of the 2026-08-23
    # attestation, killing the wizard between key generation and wg0.conf and
    # cascading into wg-quick@wg0 + both mesh units. ip(8) is iproute2, which
    # nothing diverts. `|| true` guards the empty-result pipefail case.
    local host_ip
    host_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
    local host_octet
    host_octet="$(echo "$host_ip" | awk -F. '{print $4}')"
    if [[ -z "$host_octet" || "$host_octet" == "0" ]]; then
        host_octet="1"
        log_warn "Could not derive host IPv4 octet; wg0 Address defaulting to 10.100.0.1/24"
    fi

    local privkey_value
    privkey_value="$(cat "$privkey_path")"

    cat > "$wg0_conf_path" <<WG0_EOF
# Orion-X mesh VPN interface
# Authored by first-boot-wizard.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Peer entries are added by 'orionx-mesh join' — do not hand-edit Address or PrivateKey.
# @decision DEC-PHASE11-016

[Interface]
PrivateKey = ${privkey_value}
Address = 10.100.0.${host_octet}/24
ListenPort = 51820
WG0_EOF
    chmod 600 "$wg0_conf_path"
    log_info "wg0.conf written at $wg0_conf_path (Address=10.100.0.${host_octet}/24)"
}

# ---------------------------------------------------------------------------
# Step 3b: Seed SSH admin one-shot path
# ---------------------------------------------------------------------------
#
# @decision DEC-PHASE11-019
# @title First-boot wizard seeds a one-shot SSH admin path via /root/.ssh/authorized_keys
# @status accepted
# @rationale Hardware attestation (2026-08-03) showed that sshd with default Debian
#   config (PasswordAuthentication yes) was the only SSH entry point for headless
#   Apple Silicon boots, and there was no documented admin path for operators
#   seeding persistent authorized_keys. This step generates a single-use ed25519
#   keypair on every first boot, installs the public half as the root authorized key,
#   and prints the one-shot password + private key fingerprint to /etc/motd.d/ and
#   /etc/issue.d/ so operators see it at console and pre-login. Subsequent boots skip
#   this step (idempotency via FLAG_FILE). Operators MUST seed their persistent
#   authorized_keys before rebooting; the one-shot password rotates on every wizard run.
#   Explicitly forbidden: do NOT relax PasswordAuthentication in any shipped sshd_config.
#   Follow-up W11-13c will author sshd_config.d/orionx-hardening.conf (out of scope here).

step_seed_ssh_admin() {
    log_step "Seeding SSH admin one-shot path"

    local ssh_dir="/root/.ssh"
    local auth_keys="$ssh_dir/authorized_keys"
    local oneshot_key="$ssh_dir/orionx-oneshot"
    local motd_file="/etc/motd.d/orionx-ssh-admin"
    local issue_file="/etc/issue.d/orionx-ssh-admin.issue"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_dry "Generate one-shot password via /dev/urandom"
        log_dry "ssh-keygen -q -t ed25519 -N <password> -f $oneshot_key -C orionx-oneshot@\$(hostname)"
        log_dry "install pubkey at $auth_keys"
        log_dry "write $motd_file and $issue_file with one-shot credentials"
        return 0
    fi

    # Generate a 20-character one-shot password from /dev/urandom.
    # head -c 15 gives 15 raw bytes → base64 yields ~20 chars; tr removes URL-unsafe
    # chars; head -c 20 trims to exactly 20 alphanumeric chars.
    local oneshot_password
    oneshot_password="$(head -c 15 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # Generate a temporary ed25519 keypair. The private key is protected with the
    # one-shot password. The private key file is printed to the admin outputs and
    # then wiped so it is not persistent on the system (operators paste it once).
    rm -f "$oneshot_key" "${oneshot_key}.pub"
    ssh-keygen -q -t ed25519 -N "$oneshot_password" \
        -f "$oneshot_key" \
        -C "orionx-oneshot@$(hostname 2>/dev/null || echo orionx)" \
        2>/dev/null

    # Install the public key as the authorized root key.
    cat "${oneshot_key}.pub" > "$auth_keys"
    chmod 600 "$auth_keys"

    # Capture the fingerprint for display.
    local fingerprint
    fingerprint="$(ssh-keygen -lf "${oneshot_key}.pub" 2>/dev/null | awk '{print $2}')"

    # Read the private key contents for the one-time console display.
    local privkey_contents
    privkey_contents="$(cat "$oneshot_key")"

    # Wipe the private key file — it exists only for the display window.
    rm -f "$oneshot_key" "${oneshot_key}.pub"

    mkdir -p /etc/motd.d /etc/issue.d

    # Write admin message to both motd and issue using printf to avoid heredoc-
    # inside-$() quoting complications (single quotes in body confuse the bash
    # tokenizer when the heredoc is inside a command substitution).
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
        "=== Orion-X SSH Admin One-Shot ===" \
        "" \
        "One-shot password : $oneshot_password" \
        "Key fingerprint   : $fingerprint" \
        "Key type          : ed25519" \
        "" \
        "Private key (paste into your SSH client, then seed persistent authorized_keys):" \
        "$privkey_contents" \
        "" \
        "INSTRUCTIONS:" \
        "  1. SSH in as root using this private key + the one-shot password above." \
        "  2. Append your persistent public key to /root/.ssh/authorized_keys." \
        "  3. Reboot — the wizard idempotency check skips SSH seeding on subsequent boots," \
        "     and sshd accepts your persistent key only." \
        "" \
        "WARNING: The one-shot password rotates on every wizard run until persistent" \
        "         authorized_keys are seeded. Keep this output confidential." \
        "==================================" \
        > "$motd_file"
    chmod 644 "$motd_file"

    cp "$motd_file" "$issue_file"
    chmod 644 "$issue_file"

    log_info "SSH admin one-shot written to $motd_file and $issue_file"
    log_info "Root authorized_keys seeded at $auth_keys"

    # Also print to the console so headless operators see it during first boot.
    log_info "=== SSH ADMIN ONE-SHOT (see /etc/motd.d/orionx-ssh-admin for persistent copy) ==="
    log_info "One-shot password: $oneshot_password  |  Fingerprint: $fingerprint"
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
    printf '  %sEach prompt auto-continues with its default after %ss if left blank.%s\n\n' \
        "$DIM" "$PROMPT_TIMEOUT" "$RST"
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

    # Make it unmistakable that the boot has paused for the operator (tty1).
    announce_interactive_start

    # Operator onboarding first (hostname → account → Wi-Fi), then node provisioning.
    step_set_hostname
    step_set_user_credentials
    step_setup_wifi
    step_generate_wg_keys
    step_seed_ssh_admin
    step_set_matrix_creds
    step_disable_ssh
    write_flag_file
    print_summary
}

main "$@"
