#!/bin/bash
#
# Orion-X Phoenix Edition v1.5.5
# Setup script for WireGuard VPN
#
# This script generates a WireGuard key pair for the device and creates
# a client configuration file to connect to the team's VPN server.
# No keys are hardcoded - either user input or secure config file is used.

set -e
LOGFILE="/var/log/orionx/vpn_setup.log"
CONFIG_DIR="/etc/wireguard"
CONFIG_FILE="$CONFIG_DIR/orionx.conf"
SERVER_ENDPOINT=""
SERVER_PUBKEY=""
CLIENT_PORT="51820"
DNS_SERVERS="1.1.1.1,8.8.8.8"
ALLOWED_IPS="0.0.0.0/0, ::/0"

# Create log directory if it doesn't exist
mkdir -p /var/log/orionx

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "Starting WireGuard VPN setup for Orion-X Phoenix Edition v1.5.5"

# Check if WireGuard is installed
if ! command -v wg &> /dev/null; then
    log "ERROR: WireGuard is not installed. Installing now..."
    apt-get update
    apt-get install -y wireguard
    if ! command -v wg &> /dev/null; then
        log "ERROR: Failed to install WireGuard. Please install it manually."
        exit 1
    fi
fi

# Create WireGuard config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

# Function to get configuration inputs
get_config_inputs() {
    # Check for existing config file
    if [ -f "$CONFIG_FILE" ]; then
        read -p "WireGuard configuration already exists. Overwrite? (y/n): " overwrite
        if [ "$overwrite" != "y" ]; then
            log "Keeping existing configuration"
            return
        fi
    fi
    
    # Get server endpoint
    echo "Please enter your team's WireGuard server information:"
    read -p "Server endpoint (IP:Port): " SERVER_ENDPOINT
    
    # Get server public key
    read -p "Server public key: " SERVER_PUBKEY
    
    # Get client IP address
    read -p "Client IP address (with CIDR, e.g. 10.10.10.2/24): " CLIENT_IP
    
    # Optional: Get DNS servers
    read -p "DNS servers (comma separated, default: $DNS_SERVERS): " custom_dns
    if [ -n "$custom_dns" ]; then
        DNS_SERVERS="$custom_dns"
    fi
    
    # Optional: Get allowed IPs
    read -p "Allowed IPs (comma separated, default: $ALLOWED_IPS): " custom_ips
    if [ -n "$custom_ips" ]; then
        ALLOWED_IPS="$custom_ips"
    fi
}

# Function to generate WireGuard keys
generate_keys() {
    log "Generating WireGuard keys..."
    
    # Generate private key
    wg genkey > "$CONFIG_DIR/private.key"
    chmod 600 "$CONFIG_DIR/private.key"
    
    # Generate public key from private key
    wg pubkey < "$CONFIG_DIR/private.key" > "$CONFIG_DIR/public.key"
    
    # Store keys in variables
    PRIVATE_KEY=$(cat "$CONFIG_DIR/private.key")
    PUBLIC_KEY=$(cat "$CONFIG_DIR/public.key")
    
    log "Keys generated successfully"
    log "Public key: $PUBLIC_KEY"
}

# Function to create WireGuard configuration
create_config() {
    log "Creating WireGuard configuration..."
    
    # Create the config file
    cat > "$CONFIG_FILE" << EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $CLIENT_IP
DNS = $DNS_SERVERS
ListenPort = $CLIENT_PORT

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = $ALLOWED_IPS
PersistentKeepalive = 25
EOF
    
    chmod 600 "$CONFIG_FILE"
    
    log "Configuration created at $CONFIG_FILE"
}

# Function to activate WireGuard connection
activate_connection() {
    log "Activating WireGuard connection..."
    
    # Check if wg-quick is available
    if ! command -v wg-quick &> /dev/null; then
        log "ERROR: wg-quick not found. Please install wireguard-tools package."
        exit 1
    fi
    
    # Stop existing connection if active
    wg-quick down "$CONFIG_FILE" 2>/dev/null || true
    
    # Start new connection
    if wg-quick up "$CONFIG_FILE"; then
        log "WireGuard connection activated successfully"
    else
        log "ERROR: Failed to activate WireGuard connection"
        exit 1
    fi
    
    # Check connection status
    log "Connection status:"
    wg show
}

# Main script execution
get_config_inputs
generate_keys
create_config
activate_connection

# Print configuration information for the user
echo ""
echo "========================================"
echo "WireGuard VPN Setup Complete"
echo "========================================"
echo "Your public key (share with server admin):"
echo "$PUBLIC_KEY"
echo ""
echo "Configuration saved to: $CONFIG_FILE"
echo "Log file: $LOGFILE"
echo ""
echo "To manually control the VPN connection:"
echo "- Start VPN: sudo wg-quick up $CONFIG_FILE"
echo "- Stop VPN: sudo wg-quick down $CONFIG_FILE"
echo "- Check status: sudo wg show"
echo "========================================"

log "WireGuard VPN setup completed successfully"
