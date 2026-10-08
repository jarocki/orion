#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-MATRIX-SETUP-001
# @title Modernize setup-matrix.sh with CLI arguments and strict mode
# @status accepted
# @rationale Interactive prompts don't work in automated/Docker environments.
#   CLI arguments enable scripted deployment. Strict mode (pipefail) catches
#   silent failures in package installation pipelines.
#
# @decision DEC-PHASE12-102
# @title Server mode drives the package unit matrix-synapse.service, writes ONE
#   explicit listener, keeps registration closed and never puts a password on
#   argv
# @status accepted
# @rationale What server mode used to do (security F10, shell P1-2, UX-35):
#   - died with exit 141 at the registration-secret line
#     (`tr </dev/urandom | fold | head` + pipefail: tr takes SIGPIPE), after
#     the packages were installed and before any config was written;
#   - flipped enable_registration to TRUE (open sign-up on the team server);
#   - passed the admin password to register_new_matrix_user with -p, and
#     accepted --admin-pass/--password on its own argv: readable by every
#     local uid in /proc/*/cmdline while running;
#   - never set a bind address and then pointed Element at
#     https://<name>:8448, a TLS listener nothing configured;
#   - ran apt with no root or network preflight, so offline the operator got
#     raw apt errors after the Cockpit had said "Opened Matrix setup".
#   Now:
#   - preflight first: root, then network (only when something must be
#     downloaded), each with one plain-language line and the remedy, reusing
#     /opt/orionx/optional/lib/orionx-installer-common.sh;
#   - the secret comes from `openssl rand -hex 32` (no pipeline);
#   - ONE listener is written to /etc/matrix-synapse/conf.d/orionx.yaml
#     (Synapse merges conf.d over homeserver.yaml, top-level keys replace):
#       listeners[0]: port 8008, tls false, type http,
#                     bind_addresses [127.0.0.1, <wg0 IPv4 if the deck has
#                     joined the mesh>], resources client+federation
#       enable_registration: false
#       registration_shared_secret: <random>
#     The Comms tab derives the URL from exactly those keys:
#     http://<bind_addresses non-loopback entry or 127.0.0.1>:<port>.
#     The firewall admits 8008 only on wg0 (nftables.conf, DEC-PHASE12-104);
#   - the unit is matrix-synapse.service (DEC-PHASE12-102 in its drop-in);
#   - the admin password goes to register_new_matrix_user through
#     --password-file (a 0600 temp file, removed at once) or its own tty
#     prompt; --admin-pass-file supplies it non-interactively. A password on
#     this script's command line is refused with that pointer.
#   Verified 2026-10-07 in debian:trixie (amd64) with matrix-synapse-py3
#   1.162.0+trixie1, Synapse run directly as matrix-synapse with this conf.d:
#   listens on exactly 127.0.0.1:8008 and the wg0 address, /register answers
#   "Registration has been disabled", register_new_matrix_user
#   --password-file creates the admin, who can log in. NOT verified: the
#   systemd drop-in at runtime (emulated systemd in the container could not
#   spawn units), and nothing on hardware.
#
# Orion-X Phoenix Edition — Setup script for Matrix secure communication
#
# NOTE: For P2P mesh networking with auto-discovery, use `orionx-mesh`.
# For team collaboration over the mesh, this script sets up Matrix/Synapse
# for encrypted messaging between Orion-X nodes.
#
# Modes:
# 1. server — run a Synapse homeserver on this deck (packages.matrix.org)
# 2. client — point Element at an existing homeserver
#
# No default or hardcoded credentials are used.
#
# Usage: setup-matrix.sh [options]   (see --help)

set -euo pipefail

# ---------------------------------------------------------------------------
# Dry-run guard: when ORIONX_MATRIX_DRY_RUN=1, skip system-modifying actions
# (package installs, systemctl, mkdir in /var, /etc, /usr) for safe testing.
# ---------------------------------------------------------------------------
DRY_RUN="${ORIONX_MATRIX_DRY_RUN:-0}"

# Paths (overridable for tests; the defaults are the deck's).
LOGFILE="${ORIONX_MATRIX_LOGFILE:-/var/log/orionx/matrix_setup.log}"
CONFIG_DIR="${ORIONX_MATRIX_CONFIG_DIR:-/etc/matrix-synapse}"
ORIONX_CONF="$CONFIG_DIR/conf.d/orionx.yaml"            # the listener: 0644, the Cockpit reads it as the operator
ORIONX_SECRET_CONF="$CONFIG_DIR/conf.d/orionx-secret.yaml" # registration_shared_secret: 0640 root:matrix-synapse
CLIENT_CONFIG_DIR="${ORIONX_MATRIX_CLIENT_DIR:-/etc/element-desktop}"
DESKTOP_FILE="${ORIONX_MATRIX_DESKTOP_FILE:-/usr/share/applications/orionx-matrix.desktop}"
INSTALLER_LIB="${ORIONX_INSTALLER_LIB:-/opt/orionx/optional/lib/orionx-installer-common.sh}"
SYNAPSE_UNIT="matrix-synapse.service"
SYNAPSE_PORT=8008
MESH_IFACE="${MESH_IFACE:-wg0}"

# DEC-PHASE12-060: matrix-synapse-py3 (packages.matrix.org) is a dh-virtualenv
# package. It links synctl/register_new_matrix_user into /usr/bin but NOT
# synapse_homeserver, and the system python3 has no `synapse` module.
SYNAPSE_VENV="/opt/venvs/matrix-synapse"
synapse_present() {
    [[ -x "$SYNAPSE_VENV/bin/synapse_homeserver" ]] || command -v synapse_homeserver >/dev/null 2>&1
}
SERVER_MODE=""
SERVER_NAME=""
MATRIX_USERNAME=""
MATRIX_PASSWORD=""

# CLI argument holders (empty = not provided via CLI)
CLI_SERVER_NAME=""
CLI_ADMIN_USER=""
CLI_ADMIN_PASS_FILE=""
CLI_HOMESERVER_URL=""
CLI_USER_ID=""

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<'HELPTEXT'
Usage: setup-matrix.sh [options]

Setup Matrix/Synapse for encrypted messaging between Orion-X nodes.

Options:
  --mode <server|client>        Setup mode (required)
  --server-name <name>          Server name (server mode, default: orionx.local)
  --admin-user <username>       Admin username (server mode)
  --admin-pass-file <file>      Read the admin password from <file> (server mode).
                                Without it you are prompted. Passwords are never
                                accepted on the command line (visible in ps).
  --homeserver-url <url>        Homeserver URL (client mode)
  --user-id <@user:server>      Matrix user ID (client mode)
  --help, -h                    Show this help

Server mode needs root and, the first time, network access (it installs
Synapse from packages.matrix.org). Synapse listens on 127.0.0.1:8008 and, if
this deck has joined the mesh, on its wg0 address; registration stays closed.

Examples:
  sudo setup-matrix.sh --mode server --server-name orionx.local --admin-user admin
  setup-matrix.sh --mode client --homeserver-url https://matrix.example.org \
    --user-id '@responder:example.org'
HELPTEXT
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --mode)
                SERVER_MODE="${2:-}"
                shift 2
                ;;
            --server-name)
                CLI_SERVER_NAME="${2:-}"
                shift 2
                ;;
            --admin-user)
                CLI_ADMIN_USER="${2:-}"
                shift 2
                ;;
            --admin-pass-file)
                CLI_ADMIN_PASS_FILE="${2:-}"
                shift 2
                ;;
            --admin-pass|--password)
                # DEC-PHASE12-102: refused, not silently ignored.
                die "$1 is no longer accepted: a password on the command line is readable by every local user (ps, /proc/*/cmdline). Use --admin-pass-file <file>, or omit it to be prompted. (Client mode never needed a password: Element asks at login.)"
                ;;
            --homeserver-url)
                CLI_HOMESERVER_URL="${2:-}"
                shift 2
                ;;
            --user-id)
                CLI_USER_ID="${2:-}"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    # --mode is required. When launched interactively without it (the Orion
    # menu entry, or an operator typing the bare command as the User Guide
    # shows), ask instead of failing — DEC-PHASE12-020 (beta audit BLK-4).
    if [[ -z "$SERVER_MODE" ]]; then
        if [[ -t 0 && -t 1 ]]; then
            echo "Orion-X Matrix setup — choose a mode:"
            echo "  1) client  — connect this deck to an existing Matrix homeserver"
            echo "  2) server  — run a Synapse homeserver on this deck (needs root, and network the first time)"
            local _choice=""
            read -r -p "Mode [1/2, or client/server]: " _choice
            case "${_choice,,}" in
                1|client|c) SERVER_MODE="client" ;;
                2|server|s) SERVER_MODE="server" ;;
                *) echo "ERROR: unrecognised choice '${_choice}'" >&2; exit 1 ;;
            esac
        else
            echo "ERROR: --mode is required (server or client)" >&2
            usage >&2
            exit 1
        fi
    fi

    # Validate mode value
    if [[ "$SERVER_MODE" != "server" && "$SERVER_MODE" != "client" ]]; then
        echo "ERROR: --mode must be 'server' or 'client', got '$SERVER_MODE'" >&2
        exit 1
    fi
}

# Log function (never given a secret)
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "$msg"
    else
        mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
        echo "$msg" | tee -a "$LOGFILE" 2>/dev/null || echo "$msg"
    fi
}

# ---------------------------------------------------------------------------
# Preflight (UX-35): root, then network only if something must be downloaded.
# Reuses the optional-installer guards (single authority for the wording).
# ---------------------------------------------------------------------------
if [[ -r "$INSTALLER_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$INSTALLER_LIB"
fi
if ! declare -F orionx_require_root >/dev/null; then
    orionx_require_root() {
        [[ $EUID -eq 0 ]] || die "${0##*/} requires root. Run with sudo."
    }
    orionx_require_network() {
        local host="${1:-deb.debian.org}"
        getent hosts "$host" >/dev/null 2>&1 || die "$host unreachable (air-gap or DNS). ${0##*/} requires network access. Run this on a network-connected node."
    }
fi

# @decision DEC-PHASE12-102 (amended, B2 handoff / security F11)
# @title Third-party apt keys are fingerprint-pinned and scoped with signed-by
# @status accepted
# @rationale Both keys were fetched over HTTPS and trusted unchecked, so a
#   TLS-intercepting proxy on a hostile network (or a compromised CDN) could
#   substitute key and repo and have packages installed as root. Same pattern
#   as B2's Zeek fix (0500): fetch to a temp file, compare the PRIMARY key
#   fingerprint (gpg --show-keys) with the pin, refuse on mismatch, install
#   into its own keyring, reference it only from that repo's signed-by=.
#   Pins read from the live keys 2026-10-07 (both rsa4096, expire 2033-03-13).
MATRIX_KEY_URL="https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg"
MATRIX_KEY_FPR="AAF9AE843A7584B5A3E4CD2BCF45A512DE2DA058"
MATRIX_KEYRING="${ORIONX_MATRIX_KEYRING:-/usr/share/keyrings/matrix-org-archive-keyring.gpg}"
ELEMENT_KEY_URL="https://packages.element.io/debian/element-io-archive-keyring.gpg"
ELEMENT_KEY_FPR="12D4CD600C2240A9F4A82071D7B0B66941D01538"
ELEMENT_KEYRING="${ORIONX_ELEMENT_KEYRING:-/usr/share/keyrings/element-io-archive-keyring.gpg}"
APT_SOURCES_DIR="${ORIONX_APT_SOURCES_DIR:-/etc/apt/sources.list.d}"

# fetch_pinned_keyring <url> <fingerprint> <keyring>
fetch_pinned_keyring() {
    local url="$1" pin="$2" keyring="$3" tmp actual
    tmp="$(mktemp)"
    if ! wget -qO "$tmp" "$url"; then
        rm -f "$tmp"; log "ERROR: could not download the signing key $url"; return 1
    fi
    actual="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
    if [[ "$actual" != "$pin" ]]; then
        rm -f "$tmp"
        log "ERROR: KEY FINGERPRINT MISMATCH for $url: expected $pin, got ${actual:-none}. Refusing to trust it (a proxy or mirror may be substituting packages)."
        return 1
    fi
    mkdir -p "$(dirname "$keyring")"
    install -m 0644 "$tmp" "$keyring" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    log "Signing key verified ($pin) -> $keyring"
}

preflight() {
    [[ "$DRY_RUN" == "1" ]] && return 0
    if [[ "${ORIONX_SKIP_ROOT_CHECK:-0}" != "1" ]]; then
        orionx_require_root
    fi
    local need_net=0 host=""
    if ! command -v element-desktop >/dev/null 2>&1; then need_net=1; host="packages.element.io"; fi
    if [[ "$SERVER_MODE" == "server" ]] && ! synapse_present; then need_net=1; host="packages.matrix.org"; fi
    if (( need_net )); then
        orionx_require_network "$host"
    fi
}

# ---------------------------------------------------------------------------
# Function to check for required packages
# ---------------------------------------------------------------------------
check_requirements() {
    log "Checking requirements..."

    if [[ "$DRY_RUN" == "1" ]]; then
        log "Dry-run mode: skipping package checks"
        log "Requirements check complete"
        return 0
    fi

    # Check for Element client
    if ! command -v element-desktop >/dev/null 2>&1; then
        log "Element client not found. Installing..."

        # Add Element repository (keyrings pattern — apt-key add is deprecated since Debian Bullseye)
        fetch_pinned_keyring "$ELEMENT_KEY_URL" "$ELEMENT_KEY_FPR" "$ELEMENT_KEYRING" || exit 1
        echo "deb [signed-by=$ELEMENT_KEYRING] https://packages.element.io/debian/ default main" > "$APT_SOURCES_DIR/element-io.list"
        apt-get update
        apt-get install -y element-desktop

        if ! command -v element-desktop >/dev/null 2>&1; then
            log "ERROR: Failed to install Element client. Please install it manually."
            exit 1
        fi
    fi

    # Check for Synapse if server mode
    if [[ "$SERVER_MODE" == "server" ]] && ! synapse_present; then
        log "Matrix Synapse not found. Installing..."

        apt-get update
        apt-get install -y lsb-release wget apt-transport-https
        fetch_pinned_keyring "$MATRIX_KEY_URL" "$MATRIX_KEY_FPR" "$MATRIX_KEYRING" || exit 1
        echo "deb [signed-by=$MATRIX_KEYRING] https://packages.matrix.org/debian/ $(lsb_release -cs) main" > "$APT_SOURCES_DIR/matrix-org.list"
        apt-get update
        # The package asks for the server name via debconf and writes it to
        # conf.d/server_name.yaml; preseed it so the install is non-interactive.
        echo "matrix-synapse matrix-synapse/server-name string ${SERVER_NAME}" | debconf-set-selections 2>/dev/null || true
        echo "matrix-synapse matrix-synapse/report-stats boolean false" | debconf-set-selections 2>/dev/null || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y matrix-synapse-py3

        if ! synapse_present; then
            log "ERROR: Failed to install Matrix Synapse (no $SYNAPSE_VENV/bin/synapse_homeserver and none on PATH). Please install it manually."
            exit 1
        fi
    fi

    log "Requirements check complete"
}

# ---------------------------------------------------------------------------
# Server helpers
# ---------------------------------------------------------------------------

# This deck's mesh address, if it has joined the mesh.
mesh_ipv4() {
    ip -4 -o addr show dev "$MESH_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true
}

# 32 random bytes as hex. No pipeline into `head`, so no SIGPIPE under pipefail.
random_secret() {
    local s=""
    s="$(openssl rand -hex 32 2>/dev/null)" || s=""
    if [[ -z "$s" ]]; then
        s="$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')"
    fi
    [[ ${#s} -eq 64 ]] || die "could not generate a registration secret"
    printf '%s' "$s"
}

# Write conf.d/orionx.yaml atomically: the ONE listener + closed registration.
write_orionx_conf() {
    local secret="$1"; shift
    local binds="" b
    for b in "$@"; do binds+="${binds:+, }'$b'"; done
    mkdir -p "$CONFIG_DIR/conf.d"
    local tmp
    # Two files (QA round 2, P2-1): the Cockpit's Comms tab derives the URL from
    # listeners[0] as the operator, so the listener file must be readable; the
    # registration secret must not be. One file with 0640 made the tab fall back
    # to the package's loopback listener and print the wrong URL.
    local stmp
    stmp="$(mktemp "$ORIONX_SECRET_CONF.XXXXXX")"
    chmod 0640 "$stmp"
    printf '# Written by setup-matrix.sh (DEC-PHASE12-102). Root and matrix-synapse only.\nregistration_shared_secret: "%s"\n' "$secret" > "$stmp"
    chgrp matrix-synapse "$stmp" 2>/dev/null || true
    mv -f "$stmp" "$ORIONX_SECRET_CONF"
    tmp="$(mktemp "$ORIONX_CONF.XXXXXX")"
    chmod 0644 "$tmp"
    cat > "$tmp" <<YAML
# Written by setup-matrix.sh (DEC-PHASE12-102). Re-run setup to change it.
# The Cockpit's Comms tab derives the homeserver URL from listeners[0].
# The registration secret lives in orionx-secret.yaml (0640).
listeners:
  - port: ${SYNAPSE_PORT}
    tls: false
    type: http
    x_forwarded: false
    bind_addresses: [${binds}]
    resources:
      - names: [client, federation]
        compress: false
enable_registration: false
YAML
    mv -f "$tmp" "$ORIONX_CONF"
}

# Wait for Synapse to answer on loopback; print the final state either way.
wait_for_synapse() {
    local _try
    for _try in $(seq 1 30); do
        if curl -fsS --max-time 2 "http://127.0.0.1:${SYNAPSE_PORT}/health" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# Function to setup Matrix server
# ---------------------------------------------------------------------------
collect_server_inputs() {
    if [[ -n "$CLI_SERVER_NAME" ]]; then
        SERVER_NAME="$CLI_SERVER_NAME"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rp "Enter server name (e.g., orionx.local): " SERVER_NAME
        SERVER_NAME="${SERVER_NAME:-orionx.local}"
    else
        SERVER_NAME="orionx.local"
    fi
    if [[ ! "$SERVER_NAME" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
        die "server name '$SERVER_NAME' is not a hostname"
    fi

    if [[ -n "$CLI_ADMIN_USER" ]]; then
        MATRIX_USERNAME="$CLI_ADMIN_USER"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rp "Enter admin username: " MATRIX_USERNAME
    fi
    if [[ -n "$MATRIX_USERNAME" && ! "$MATRIX_USERNAME" =~ ^[a-z0-9._=/-]+$ ]]; then
        die "admin username '$MATRIX_USERNAME' may contain only a-z 0-9 . _ = / -"
    fi

    if [[ -n "$CLI_ADMIN_PASS_FILE" ]]; then
        [[ -r "$CLI_ADMIN_PASS_FILE" ]] || die "cannot read --admin-pass-file $CLI_ADMIN_PASS_FILE"
        MATRIX_PASSWORD="$(head -n 1 "$CLI_ADMIN_PASS_FILE")"
        [[ -n "$MATRIX_PASSWORD" ]] || die "--admin-pass-file $CLI_ADMIN_PASS_FILE is empty"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]] && [[ -n "$MATRIX_USERNAME" ]]; then
        read -rsp "Enter admin password: " MATRIX_PASSWORD
        echo ""
    fi
}

setup_matrix_server() {
    log "Setting up Matrix Synapse homeserver..."
    log "Server name: $SERVER_NAME"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "Dry-run mode: skipping Synapse configuration and service start"
        log "Matrix Synapse server setup complete (dry-run)"
        log "Server name: $SERVER_NAME"
        log "Admin user: $MATRIX_USERNAME"
        return 0
    fi

    local -a binds=(127.0.0.1)
    local wg_ip
    wg_ip="$(mesh_ipv4)"
    if [[ -n "$wg_ip" ]]; then
        binds+=("$wg_ip")
    else
        log "NOTE: this deck has not joined the mesh ($MESH_IFACE has no address): Synapse will listen on 127.0.0.1 only. Run 'sudo orionx-mesh join', then re-run this setup to serve the team."
    fi

    local secret
    secret="$(random_secret)"
    log "Writing $ORIONX_CONF (listener ${binds[*]}:${SYNAPSE_PORT}, registration closed)..."
    write_orionx_conf "$secret" "${binds[@]}"

    log "Starting $SYNAPSE_UNIT..."
    systemctl enable "$SYNAPSE_UNIT" >/dev/null 2>&1 || log "WARNING: could not enable $SYNAPSE_UNIT (it will not start at next boot)"
    if ! systemctl restart "$SYNAPSE_UNIT"; then
        log "ERROR: $SYNAPSE_UNIT failed to start. Check: journalctl -u $SYNAPSE_UNIT -n 50"
        exit 1
    fi
    if ! wait_for_synapse; then
        log "ERROR: $SYNAPSE_UNIT is $(systemctl is-active "$SYNAPSE_UNIT" 2>/dev/null || echo unknown) but did not answer on http://127.0.0.1:${SYNAPSE_PORT}/health within 30 s. Check: journalctl -u $SYNAPSE_UNIT -n 50"
        exit 1
    fi
    log "Synapse is answering on http://127.0.0.1:${SYNAPSE_PORT}"

    if [[ -n "$MATRIX_USERNAME" ]]; then
        log "Registering admin user '$MATRIX_USERNAME'..."
        local -a reg=(register_new_matrix_user -c "$ORIONX_SECRET_CONF" -u "$MATRIX_USERNAME" -a)
        local pwfile=""
        if [[ -n "$MATRIX_PASSWORD" ]]; then
            pwfile="$(umask 077; mktemp "${TMPDIR:-/tmp}/orionx-matrix-pw.XXXXXX")"
            printf '%s\n' "$MATRIX_PASSWORD" > "$pwfile"
            reg+=(--password-file "$pwfile")
        fi
        reg+=("http://127.0.0.1:${SYNAPSE_PORT}")
        local rc=0
        "${reg[@]}" || rc=$?
        [[ -n "$pwfile" ]] && rm -f "$pwfile"
        MATRIX_PASSWORD=""
        if (( rc != 0 )); then
            log "ERROR: admin registration failed (register_new_matrix_user exit $rc). Synapse is running; retry with: sudo register_new_matrix_user -c $ORIONX_CONF -a http://127.0.0.1:${SYNAPSE_PORT}"
            exit 1
        fi
        log "Admin user: $MATRIX_USERNAME"
    else
        log "No admin user requested. Create one later with: sudo register_new_matrix_user -c $ORIONX_SECRET_CONF -a http://127.0.0.1:${SYNAPSE_PORT}"
    fi

    log "Matrix Synapse server setup complete"
    if [[ -n "$wg_ip" ]]; then
        log "Team homeserver URL (over the mesh): http://${wg_ip}:${SYNAPSE_PORT}"
    fi

    # This deck's Element talks to its own homeserver over loopback.
    setup_element_client "http://127.0.0.1:${SYNAPSE_PORT}" "" "$SERVER_NAME"
}

# ---------------------------------------------------------------------------
# Function to setup Matrix client
# ---------------------------------------------------------------------------
setup_matrix_client() {
    log "Setting up Matrix client..."

    local homeserver_url
    local matrix_user_id

    # Get homeserver URL — CLI arg or interactive
    if [[ -n "$CLI_HOMESERVER_URL" ]]; then
        homeserver_url="$CLI_HOMESERVER_URL"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rp "Enter Matrix homeserver URL (e.g., https://matrix.example.org): " homeserver_url
    else
        homeserver_url="${CLI_HOMESERVER_URL}"
    fi

    # Get user ID — CLI arg or interactive
    if [[ -n "$CLI_USER_ID" ]]; then
        matrix_user_id="$CLI_USER_ID"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rp "Enter Matrix user ID (@username:server.org): " matrix_user_id
    else
        matrix_user_id="${CLI_USER_ID}"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "Dry-run mode: skipping Element client configuration"
        log "Homeserver URL: $homeserver_url"
        log "User ID: $matrix_user_id"
        log "Matrix client setup complete (dry-run)"
        return 0
    fi

    # Configure Element client
    setup_element_client "$homeserver_url" "$matrix_user_id"

    log "Matrix client setup complete"
}

# ---------------------------------------------------------------------------
# Function to configure Element client
# ---------------------------------------------------------------------------
setup_element_client() {
    local homeserver_url="$1"
    local _user_id="${2:-}"  # reserved for future use
    local server_name="${3:-}"

    # Validated before it goes into JSON (shell P3-10): no quotes, backslashes
    # or control characters can reach the file.
    if [[ ! "$homeserver_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]]; then
        log "ERROR: homeserver URL '$homeserver_url' is not a plain http(s)://host[:port] URL"
        exit 1
    fi
    if [[ -z "$server_name" ]]; then
        server_name="${homeserver_url#*://}"
        server_name="${server_name%%[:/]*}"
    fi

    log "Configuring Element client..."

    mkdir -p "$CLIENT_CONFIG_DIR"
    cat > "$CLIENT_CONFIG_DIR/config.json" <<EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "$homeserver_url",
            "server_name": "$server_name"
        }
    },
    "brand": "Orion-X Phoenix Edition",
    "default_theme": "dark",
    "features": {
        "feature_new_spinner": true,
        "feature_pinning": true,
        "feature_custom_status": true,
        "feature_custom_tags": true,
        "feature_state_counters": true
    }
}
EOF

    log "Element client configuration complete"

    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Orion-X Matrix
Comment=Secure Matrix Client for Orion-X
Exec=element-desktop
Icon=/usr/share/element/resources/app/img/element.png
Terminal=false
Type=Application
Categories=Network;InstantMessaging;
EOF

    log "Desktop shortcut created"
}

# ---------------------------------------------------------------------------
# Main script execution
# ---------------------------------------------------------------------------
parse_args "$@"
preflight

log "Starting Matrix setup for Orion-X Phoenix Edition"

if [[ "$SERVER_MODE" == "server" ]]; then
    collect_server_inputs
fi

check_requirements

if [[ "$SERVER_MODE" == "server" ]]; then
    setup_matrix_server
else
    setup_matrix_client
fi

echo ""
echo "========================================"
echo "Matrix Setup Complete"
echo "========================================"
echo "You can now launch the Element client from the applications menu"
echo "or by running 'element-desktop' in a terminal."
echo ""
echo "Configuration saved to: $CLIENT_CONFIG_DIR/config.json"
echo "Log file: $LOGFILE"
echo "========================================"

log "Matrix setup completed successfully"
