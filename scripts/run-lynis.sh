#!/bin/bash
#
# Orion-X Phoenix Edition v1.5.5
# Security Audit Script using Lynis
#
# This script runs Lynis to perform a security audit on the Orion-X system
# and saves the results to a report file.

set -e
LOGFILE="/var/log/orionx/lynis_audit.log"
REPORT_DIR="/var/log/orionx/reports"
REPORT_FILE="$REPORT_DIR/lynis-report.txt"
LYNIS_PROFILE="/etc/lynis/custom.prf"

# Create log directory if it doesn't exist
mkdir -p /var/log/orionx
mkdir -p "$REPORT_DIR"

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "Starting Lynis security audit for Orion-X Phoenix Edition v1.5.5"

# Check if Lynis is installed
if ! command -v lynis &> /dev/null; then
    log "Lynis not found. Installing..."
    apt-get update
    apt-get install -y lynis
    
    if ! command -v lynis &> /dev/null; then
        log "ERROR: Failed to install Lynis. Please install it manually."
        exit 1
    fi
fi

# Create custom Lynis profile if it doesn't exist
if [ ! -f "$LYNIS_PROFILE" ]; then
    log "Creating custom Lynis profile..."
    mkdir -p "$(dirname "$LYNIS_PROFILE")"
    
    cat > "$LYNIS_PROFILE" << EOF
# Custom Lynis profile for Orion-X Phoenix Edition

# Skip tests that don't apply to a live/forensic environment
skip-test=BOOT-5122  # Bootloader password
skip-test=BOOT-5184  # Secure Boot settings (we handle this elsewhere)
skip-test=AUTH-9328  # Password aging (not applicable for forensic system)

# Tests to include
test=FILE-7524       # Find world-writable files
test=MALW-3280       # Check for rootkits
test=NETW-3032       # Check firewall status
test=CRYP-7902       # Check SSH key permissions
test=CONT-8102       # Check Docker security

# Custom settings
config-data=lynis.log-tests-incorrect=yes
EOF
    
    log "Custom profile created at $LYNIS_PROFILE"
fi

# Run Lynis audit
log "Running Lynis audit..."

if lynis audit system --profile="$LYNIS_PROFILE" --cronjob > "$REPORT_FILE" 2>> "$LOGFILE"; then
    log "Lynis audit completed successfully"
else
    log "WARNING: Lynis audit completed with warnings or errors"
fi

# Extract hardening score
HARDENING_SCORE=$(grep "Hardening index" "$REPORT_FILE" | awk '{print $NF}')
if [ -n "$HARDENING_SCORE" ]; then
    log "Hardening score: $HARDENING_SCORE"
fi

# Extract warnings count
WARNINGS_COUNT=$(grep "Warnings" "$REPORT_FILE" | head -n 1 | awk '{print $NF}')
if [ -n "$WARNINGS_COUNT" ]; then
    log "Warnings found: $WARNINGS_COUNT"
fi

# Extract suggestions count
SUGGESTIONS_COUNT=$(grep "Suggestions" "$REPORT_FILE" | head -n 1 | awk '{print $NF}')
if [ -n "$SUGGESTIONS_COUNT" ]; then
    log "Suggestions: $SUGGESTIONS_COUNT"
fi

# Display summary information
echo ""
echo "=========================================="
echo "Lynis Security Audit Complete"
echo "=========================================="
echo "Report file: $REPORT_FILE"
echo "Log file: $LOGFILE"
echo ""
if [ -n "$HARDENING_SCORE" ]; then
    echo "Hardening score: $HARDENING_SCORE"
fi
if [ -n "$WARNINGS_COUNT" ]; then
    echo "Warnings found: $WARNINGS_COUNT"
fi
if [ -n "$SUGGESTIONS_COUNT" ]; then
    echo "Suggestions: $SUGGESTIONS_COUNT"
fi
echo ""
echo "Review the report for security recommendations."
echo "To apply fixes for common issues, use:"
echo "  sudo ./harden-system.sh"
echo "=========================================="

log "Lynis audit process completed"
