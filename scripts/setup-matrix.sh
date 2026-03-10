#!/bin/bash
# Orion-X Phoenix Edition v1.5.5 — Setup script for Matrix secure communication
#
# This script sets up Matrix communication for responders.
# It can operate in two modes:
# 1. Configure Orion-X as a Matrix homeserver (using Synapse)
# 2. Register the Orion-X user with an existing central Matrix server
#
# No default or hardcoded credentials are used.

set -e
LOGFILE="/var/log/orionx/matrix_setup.log"
CONFIG_DIR="/etc/matrix-synapse"
SERVER_MODE=""
SERVER_NAME=""
MATRIX_USERNAME=""
MATRIX_PASSWORD=""
CLIENT_CONFIG_DIR="/etc/element-desktop"

# Create log directory if it doesn't exist
mkdir -p /var/log/orionx

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "Starting Matrix setup for Orion-X Phoenix Edition v1.5.5"

# Function to check for required packages
check_requirements() {
    log "Checking requirements..."
    
    # Check for Element client
    if ! command -v element-desktop &> /dev/null; then
        log "Element client not found. Installing..."
        
        # Add Element repository (keyrings pattern — apt-key add is deprecated since Debian Bullseye)
        wget -O /usr/share/keyrings/element-io-archive-keyring.gpg https://packages.element.io/debian/element-io-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian/ default main" | sudo tee /etc/apt/sources.list.d/element-io.list
        apt-get update
        apt-get install -y element-desktop
        
        if ! command -v element-desktop &> /dev/null; then
            log "ERROR: Failed to install Element client. Please install it manually."
            exit 1
        fi
    fi
    
    # Check for Synapse if server mode
    if [ "$SERVER_MODE" = "server" ] && ! command -v synapse_homeserver &> /dev/null; then
        log "Matrix Synapse not found. Installing..."
        
        # Add Matrix Synapse repository
        apt-get update
        apt-get install -y lsb-release wget apt-transport-https
        wget -O /usr/share/keyrings/matrix-org-archive-keyring.gpg https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] https://packages.matrix.org/debian/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/matrix-org.list
        apt-get update
        apt-get install -y matrix-synapse-py3
        
        if ! command -v synapse_homeserver &> /dev/null; then
            log "ERROR: Failed to install Matrix Synapse. Please install it manually."
            exit 1
        fi
    fi
    
    log "Requirements check complete"
}

# Function to get setup mode
get_setup_mode() {
    echo "Please select Matrix setup mode:"
    echo "1) Configure this device as a Matrix homeserver"
    echo "2) Connect to an existing Matrix homeserver"
    read -rp "Select mode (1 or 2): " mode_choice
    
    if [ "$mode_choice" = "1" ]; then
        SERVER_MODE="server"
        log "Selected mode: Matrix homeserver"
    elif [ "$mode_choice" = "2" ]; then
        SERVER_MODE="client"
        log "Selected mode: Matrix client"
    else
        log "Invalid choice. Defaulting to client mode."
        SERVER_MODE="client"
    fi
}

# Function to setup Matrix server
setup_matrix_server() {
    log "Setting up Matrix Synapse homeserver..."
    
    # Get server name
    read -rp "Enter server name (e.g., orionx.local): " SERVER_NAME
    
    # Generate a random registration shared secret
    REGISTRATION_SECRET=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
    
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
    sed -i "s/#tls_certificate_path: .*/tls_certificate_path: \"$CONFIG_DIR\/tls\/server.crt\"/" "$CONFIG_DIR/homeserver.yaml"
    sed -i "s/#tls_private_key_path: .*/tls_private_key_path: \"$CONFIG_DIR\/tls\/server.key\"/" "$CONFIG_DIR/homeserver.yaml"
    
    # Set up admin user
    log "Setting up admin user..."
    read -rp "Enter admin username: " MATRIX_USERNAME
    read -rsp "Enter admin password: " MATRIX_PASSWORD
    echo ""
    
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

# Function to setup Matrix client
setup_matrix_client() {
    log "Setting up Matrix client..."
    
    # Get homeserver URL
    read -rp "Enter Matrix homeserver URL (e.g., https://matrix.example.org): " HOMESERVER_URL
    
    # Get user credentials
    read -rp "Enter Matrix user ID (@username:server.org): " MATRIX_USER_ID
    read -rsp "Enter password: " MATRIX_PASSWORD
    echo ""
    
    # Configure Element client
    setup_element_client "$HOMESERVER_URL" "$MATRIX_USER_ID"
    
    log "Matrix client setup complete"
}

# Function to configure Element client
setup_element_client() {
    local homeserver_url="$1"
    local _user_id="$2"  # reserved for future use
    
    log "Configuring Element client..."
    
    # Create client config directory
    mkdir -p "$CLIENT_CONFIG_DIR"
    
    # Create Element config
    cat > "$CLIENT_CONFIG_DIR/config.json" << EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "$homeserver_url",
            "server_name": "$(echo "$homeserver_url" | sed 's|^https://||' | sed 's|:.*$||')"
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
    cat > /usr/share/applications/orionx-matrix.desktop << EOF
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

# Main script execution
get_setup_mode
check_requirements

if [ "$SERVER_MODE" = "server" ]; then
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
