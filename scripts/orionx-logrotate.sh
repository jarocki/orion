#!/bin/bash
#
# Orion-X Phoenix Edition v1.5.5
# Log Rotation Utility
#
# This script handles rotation of logs for various Orion-X components
# to prevent the RAM disk from filling up during live operations.

set -e
LOGFILE="/var/log/orionx/logrotate.log"
LOG_DIR="/var/log/orionx"
ARCHIVE_DIR="/var/log/orionx/archives"
MAX_LOG_SIZE=10M  # Maximum size for log files before rotation
MAX_ARCHIVES=5    # Maximum number of archived log files to keep
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Create log directories if they don't exist
mkdir -p "$LOG_DIR"
mkdir -p "$ARCHIVE_DIR"

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "Starting Orion-X log rotation utility"

# Function to rotate a log file
rotate_log() {
    local log_file="$1"
    
    # Check if log file exists
    if [ ! -f "$log_file" ]; then
        log "Log file does not exist: $log_file"
        return
    fi
    
    # Get log file name without path
    local log_name
    log_name=$(basename "$log_file")
    
    # Check if log file size exceeds the limit
    if [ "$(stat -c%s "$log_file")" -gt "$(numfmt --from=iec "$MAX_LOG_SIZE")" ]; then
        log "Rotating log file: $log_file"
        
        # Create archive filename
        local archive_file="$ARCHIVE_DIR/${log_name}-${TIMESTAMP}.gz"
        
        # Compress and move to archive
        gzip -c "$log_file" > "$archive_file"
        
        # Truncate original log file
        cat /dev/null > "$log_file"
        
        log "Log file rotated to: $archive_file"
        
        # Clean up old archives
        cleanup_old_archives "$log_name"
    else
        log "Log file size is below threshold: $log_file"
    fi
}

# Function to clean up old archives
cleanup_old_archives() {
    local log_name="$1"
    
    # Count archives for this log file
    local archives=("$ARCHIVE_DIR/${log_name}-"*.gz)
    local archive_count=${#archives[@]}
    
    if [ "$archive_count" -gt "$MAX_ARCHIVES" ]; then
        log "Cleaning up old archives for: $log_name"
        
        # Sort archives by date (oldest first)
        local sorted_archives=()
        mapfile -t sorted_archives < <(find "$ARCHIVE_DIR" -maxdepth 1 -name "${log_name}-*.gz" -printf '%T@ %p\n' | sort -n | awk '{print $2}')
        
        # Calculate how many to delete
        local delete_count=$((archive_count - MAX_ARCHIVES))
        
        # Delete oldest archives
        for ((i=0; i<delete_count; i++)); do
            log "Removing old archive: ${sorted_archives[$i]}"
            rm "${sorted_archives[$i]}"
        done
    fi
}

# Function to handle uploading logs to artifact vault if configured
upload_to_vault() {
    # Check if artifact vault configuration exists
    if [ -f "/etc/orionx/vault_config.conf" ]; then
        log "Artifact vault configuration found, checking for logs to upload"
        
        # Source the configuration
        # shellcheck source=/dev/null
        source "/etc/orionx/vault_config.conf"
        
        # Check if required variables are set
        if [ -n "$ORIONX_VAULT_URL" ] && [ -n "$ORIONX_VAULT_TOKEN" ]; then
            log "Uploading log archives to artifact vault"
            
            # Find all archives from today
            local today
            today=$(date +%Y%m%d)
            local today_archives=("$ARCHIVE_DIR/"*"$today"*.gz)
            
            if [ ${#today_archives[@]} -eq 0 ]; then
                log "No archives from today to upload"
                return
            fi
            
            # Upload each archive
            for archive in "${today_archives[@]}"; do
                if [ -f "$archive" ]; then
                    log "Uploading $archive to vault"
                    
                    # Here we would put the actual code to upload to the vault
                    # For example, using curl or a custom script
                    # curl -X POST -H "Authorization: Bearer $ORIONX_VAULT_TOKEN" \
                    #      -F "file=@$archive" \
                    #      "$ORIONX_VAULT_URL/api/artifacts/logs"
                    
                    # For now, we'll just simulate the upload
                    log "Upload simulation for $archive completed"
                fi
            done
        else
            log "Artifact vault configuration is incomplete, skipping upload"
        fi
    else
        log "No artifact vault configuration found, skipping upload"
    fi
}

# Main log rotation logic

# List of logs to rotate
LOGS_TO_ROTATE=(
    "$LOG_DIR/vpn_setup.log"
    "$LOG_DIR/matrix_setup.log"
    "$LOG_DIR/artifact_analyzer.log"
    "$LOG_DIR/storyboard_gen.log"
    "$LOG_DIR/theme_toggle.log"
    "$LOG_DIR/logrotate.log"
)

# Rotate each log file
for log_file in "${LOGS_TO_ROTATE[@]}"; do
    rotate_log "$log_file"
done

# Check for other logs in the directory
for log_file in "$LOG_DIR"/*.log; do
    # Skip already processed logs
    if [[ ! " ${LOGS_TO_ROTATE[*]} " =~ (^|[[:space:]])"${log_file}"([[:space:]]|$) ]]; then
        rotate_log "$log_file"
    fi
done

# Upload logs to artifact vault if configured
upload_to_vault

log "Log rotation completed successfully"

exit 0
