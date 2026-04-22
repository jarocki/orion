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
# Orion-X Phoenix Edition v2.0.0 — Setup script for Matrix secure communication
#
# NOTE: For P2P mesh networking with auto-discovery, use `orionx-mesh`.
# For team collaboration over the mesh, this script sets up Matrix/Synapse
# for encrypted messaging between Orion-X nodes.
#
# This script sets up Matrix communication for responders.
# It can operate in two modes:
# 1. Configure Orion-X as a Matrix homeserver (using Synapse)
# 2. Register the Orion-X user with an existing central Matrix server
#
# No default or hardcoded credentials are used.
#
# Usage: setup-matrix.sh [options]
#
# Options:
#   --mode <server|client>      Setup mode (required)
#   --server-name <name>        Server hostname (server mode, default: orionx.local)
#   --admin-user <username>     Admin username (server mode)
#   --admin-pass <password>     Admin password (server mode)
#   --homeserver-url <url>      Homeserver URL (client mode)
#   --user-id <@user:server>    Matrix user ID (client mode)
#   --password <password>       User password (client mode)
#   --help, -h                  Show this help

set -euo pipefail

# ---------------------------------------------------------------------------
# Dry-run guard: when ORIONX_MATRIX_DRY_RUN=1, skip system-modifying actions
# (package installs, systemctl, mkdir in /var, /etc, /usr) for safe testing.
# ---------------------------------------------------------------------------
DRY_RUN="${ORIONX_MATRIX_DRY_RUN:-0}"

LOGFILE="/var/log/orionx/matrix_setup.log"
CONFIG_DIR="/etc/matrix-synapse"
SERVER_MODE=""
SERVER_NAME=""
MATRIX_USERNAME=""
MATRIX_PASSWORD=""
CLIENT_CONFIG_DIR="/etc/element-desktop"

# CLI argument holders (empty = not provided via CLI)
CLI_SERVER_NAME=""
CLI_ADMIN_USER=""
CLI_ADMIN_PASS=""
CLI_HOMESERVER_URL=""
CLI_USER_ID=""
CLI_PASSWORD=""

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<'HELPTEXT'
Usage: setup-matrix.sh [options]

Setup Matrix/Synapse for encrypted messaging between Orion-X nodes.

Options:
  --mode <server|client>      Setup mode (required)
  --server-name <name>        Server hostname (server mode, default: orionx.local)
  --admin-user <username>     Admin username (server mode)
  --admin-pass <password>     Admin password (server mode)
  --homeserver-url <url>      Homeserver URL (client mode)
  --user-id <@user:server>    Matrix user ID (client mode)
  --password <password>       User password (client mode)
  --help, -h                  Show this help

If CLI arguments are provided, the script runs non-interactively.
If arguments are missing for required fields, interactive prompts are used.

Examples:
  # Server mode (non-interactive):
  setup-matrix.sh --mode server --server-name orionx.local --admin-user admin --admin-pass secret

  # Client mode (non-interactive):
  setup-matrix.sh --mode client --homeserver-url https://matrix.example.org \
    --user-id '@responder:example.org' --password secret

  # Interactive mode (prompts for missing values):
  setup-matrix.sh --mode server
HELPTEXT
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
            --admin-pass)
                CLI_ADMIN_PASS="${2:-}"
                shift 2
                ;;
            --homeserver-url)
                CLI_HOMESERVER_URL="${2:-}"
                shift 2
                ;;
            --user-id)
                CLI_USER_ID="${2:-}"
                shift 2
                ;;
            --password)
                CLI_PASSWORD="${2:-}"
                shift 2
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done

    # --mode is required
    if [[ -z "$SERVER_MODE" ]]; then
        echo "ERROR: --mode is required (server or client)" >&2
        usage >&2
        exit 1
    fi

    # Validate mode value
    if [[ "$SERVER_MODE" != "server" && "$SERVER_MODE" != "client" ]]; then
        echo "ERROR: --mode must be 'server' or 'client', got '$SERVER_MODE'" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Log setup — only create log directory on real runs
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p /var/log/orionx
fi

# Log function
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "$msg"
    else
        echo "$msg" | tee -a "$LOGFILE"
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
        wget -O /usr/share/keyrings/element-io-archive-keyring.gpg https://packages.element.io/debian/element-io-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian/ default main" | sudo tee /etc/apt/sources.list.d/element-io.list
        apt-get update
        apt-get install -y element-desktop

        if ! command -v element-desktop >/dev/null 2>&1; then
            log "ERROR: Failed to install Element client. Please install it manually."
            exit 1
        fi
    fi

    # Check for Synapse if server mode
    if [[ "$SERVER_MODE" == "server" ]] && ! command -v synapse_homeserver >/dev/null 2>&1; then
        log "Matrix Synapse not found. Installing..."

        # Add Matrix Synapse repository
        apt-get update
        apt-get install -y lsb-release wget apt-transport-https
        wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list
        apt-get update
        apt-get install -y matrix-synapse-py3

        if ! command -v synapse_homeserver >/dev/null 2>&1; then
            log "ERROR: Failed to install Matrix Synapse. Please install it manually."
            exit 1
        fi
    fi

    log "Requirements check complete"
}

# ---------------------------------------------------------------------------
# Function to setup Matrix server
# ---------------------------------------------------------------------------
setup_matrix_server() {
    log "Setting up Matrix Synapse homeserver..."

    # Get server name — CLI arg, then interactive fallback, then default
    if [[ -n "$CLI_SERVER_NAME" ]]; then
        SERVER_NAME="$CLI_SERVER_NAME"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rp "Enter server name (e.g., orionx.local): " SERVER_NAME
        SERVER_NAME="${SERVER_NAME:-orionx.local}"
    else
        SERVER_NAME="orionx.local"
    fi
    log "Server name: $SERVER_NAME"

    # Get admin username — CLI arg or interactive
    if [[ -n "$CLI_ADMIN_USER" ]]; then
        MATRIX_USERNAME="$CLI_ADMIN_USER"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rp "Enter admin username: " MATRIX_USERNAME
    else
        MATRIX_USERNAME="${CLI_ADMIN_USER}"
    fi

    # Get admin password — CLI arg or interactive
    if [[ -n "$CLI_ADMIN_PASS" ]]; then
        MATRIX_PASSWORD="$CLI_ADMIN_PASS"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rsp "Enter admin password: " MATRIX_PASSWORD
        echo ""
    else
        MATRIX_PASSWORD="${CLI_ADMIN_PASS}"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "Dry-run mode: skipping Synapse configuration and service start"
        log "Matrix Synapse server setup complete (dry-run)"
        log "Server name: $SERVER_NAME"
        log "Admin user: $MATRIX_USERNAME"
        return 0
    fi

    # Generate a random registration shared secret
    REGISTRATION_SECRET=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)

    # Generate configuration file
    log "Generating Synapse configuration..."

    # Run the Synapse configuration generator
    python3 -m synapse.app.homeserver \
        --server-name "$SERVER_NAME" \
        --config-path "$CONFIG_DIR/homeserver.yaml" \
        --generate-config \
        --report-stats=no

    # Modify the configuration to enable registration
    sed -i "s/enable_registration: false/enable_registration: true/" "$CONFIG_DIR/homeserver.yaml"
    sed -i "s/#registration_shared_secret: .*/registration_shared_secret: \"$REGISTRATION_SECRET\"/" "$CONFIG_DIR/homeserver.yaml"

    # Generate self-signed certificate for TLS
    log "Generating self-signed certificate..."
    mkdir -p "$CONFIG_DIR/tls"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$CONFIG_DIR/tls/server.key" \
        -out "$CONFIG_DIR/tls/server.crt" \
        -subj "/CN=$SERVER_NAME"

    # Configure TLS
    sed -i "s|#tls_certificate_path: .*|tls_certificate_path: \"$CONFIG_DIR/tls/server.crt\"|" "$CONFIG_DIR/homeserver.yaml"
    sed -i "s|#tls_private_key_path: .*|tls_private_key_path: \"$CONFIG_DIR/tls/server.key\"|" "$CONFIG_DIR/homeserver.yaml"

    # Start the Synapse server
    log "Starting Matrix Synapse server..."
    systemctl enable matrix-synapse
    systemctl start matrix-synapse

    # Wait for server to start
    sleep 5

    # Register admin user
    register_new_matrix_user -c "$CONFIG_DIR/homeserver.yaml" -u "$MATRIX_USERNAME" -p "$MATRIX_PASSWORD" -a

    log "Matrix Synapse server setup complete"
    log "Server name: $SERVER_NAME"
    log "Admin user: $MATRIX_USERNAME"

    # Configure Element client to use local server
    setup_element_client "https://$SERVER_NAME:8448"
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

    # Get user credentials — CLI arg or interactive
    if [[ -n "$CLI_USER_ID" ]]; then
        matrix_user_id="$CLI_USER_ID"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rp "Enter Matrix user ID (@username:server.org): " matrix_user_id
    else
        matrix_user_id="${CLI_USER_ID}"
    fi

    if [[ -n "$CLI_PASSWORD" ]]; then
        MATRIX_PASSWORD="$CLI_PASSWORD"
    elif [[ "$DRY_RUN" != "1" ]] && [[ -t 0 ]]; then
        read -rsp "Enter password: " MATRIX_PASSWORD
        echo ""
    else
        MATRIX_PASSWORD="${CLI_PASSWORD}"
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

    log "Configuring Element client..."

    # Create client config directory
    mkdir -p "$CLIENT_CONFIG_DIR"

    # Extract server name from URL
    local server_name
    server_name="$(echo "$homeserver_url" | sed 's|^https://||' | sed 's|:.*$||')"

    # Create Element config
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

    # Create a desktop shortcut for Element
    cat > /usr/share/applications/orionx-matrix.desktop <<EOF
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

log "Starting Matrix setup for Orion-X Phoenix Edition v2.0.0"

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
