#!/bin/bash
#
# Orion-X Phoenix Edition v1.5.5
# Build script for creating the Orion-X live ISO image
#
# This script leverages Debian/Ubuntu's live-build tools to assemble the ISO.
# It is configured to use the ISO/ directory included in the package.

set -e
LOGFILE="./orionx-iso-build.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ISO_DIR="$REPO_ROOT/ISO"
OUTPUT_DIR="$REPO_ROOT/output"
VERSION="1.5.5"
ISO_NAME="orionx-phoenix-edition-v$VERSION.iso"

# Create log file
touch "$LOGFILE"

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check for required packages
    for pkg in live-build debootstrap squashfs-tools xorriso isolinux; do
        if ! dpkg -s $pkg &>/dev/null; then
            log "Required package '$pkg' is not installed"
            log "Installing required packages..."
            sudo apt-get update
            sudo apt-get install -y live-build debootstrap squashfs-tools xorriso isolinux
            break
        fi
    done
    
    # Check if ISO directory exists
    if [ ! -d "$ISO_DIR" ]; then
        log "ERROR: ISO directory not found at $ISO_DIR"
        exit 1
    fi
    
    log "Prerequisites check completed"
}

# Function to prepare build environment
prepare_build_env() {
    log "Preparing build environment..."
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Clean any previous build
    if [ -d "$ISO_DIR/build" ]; then
        log "Cleaning previous build..."
        cd "$ISO_DIR"
        lb clean --purge
    fi
    
    log "Build environment prepared"
}

# Function to configure the live build
configure_live_build() {
    log "Configuring live build..."
    
    cd "$ISO_DIR"
    
    # Run lb config with our settings
    lb config \
        --binary-images iso-hybrid \
        --distribution bullseye \
        --debian-installer false \
        --debian-installer-gui false \
        --archive-areas "main contrib non-free" \
        --updates true \
        --security true \
        --apt-indices false \
        --memtest none \
        --bootappend-live "boot=live components splash quiet persistence" \
        --iso-volume "Orion-X Phoenix v$VERSION" \
        --iso-application "Orion-X Phoenix Edition" \
        --iso-publisher "Orion-X Project" \
        --linux-packages "linux-image linux-headers" \
        --linux-flavours amd64 \
        --bootloaders "grub-efi syslinux" \
        --apt-recommends true
    
    log "Live build configured"
}

# Function to customize the ISO
customize_iso() {
    log "Customizing ISO content..."
    
    # Copy our custom content into the ISO configuration
    
    # Check if we have custom packages to include
    if [ -d "$REPO_ROOT/packages" ]; then
        log "Copying custom packages..."
        mkdir -p "$ISO_DIR/config/packages.chroot"
        cp "$REPO_ROOT/packages"/*.deb "$ISO_DIR/config/packages.chroot/" 2>/dev/null || log "No custom packages found"
    fi
    
    # Copy sample data
    if [ -d "$REPO_ROOT/data/samples" ]; then
        log "Copying sample data..."
        mkdir -p "$ISO_DIR/config/includes.chroot/opt/orionx/samples"
        cp -r "$REPO_ROOT/data/samples"/* "$ISO_DIR/config/includes.chroot/opt/orionx/samples/"
    fi
    
    # Copy scripts
    if [ -d "$REPO_ROOT/scripts" ]; then
        log "Copying scripts..."
        mkdir -p "$ISO_DIR/config/includes.chroot/usr/bin"
        for script in "$REPO_ROOT/scripts"/*.{sh,py}; do
            if [ -f "$script" ]; then
                cp "$script" "$ISO_DIR/config/includes.chroot/usr/bin/"
                chmod +x "$ISO_DIR/config/includes.chroot/usr/bin/$(basename "$script")"
            fi
        done
    fi
    
    # Copy theme assets
    if [ -d "$REPO_ROOT/theme" ]; then
        log "Copying theme assets..."
        mkdir -p "$ISO_DIR/config/includes.chroot/usr/share/orionx/theme"
        cp -r "$REPO_ROOT/theme"/* "$ISO_DIR/config/includes.chroot/usr/share/orionx/theme/"
    fi
    
    # Copy documentation
    log "Copying documentation..."
    mkdir -p "$ISO_DIR/config/includes.chroot/usr/share/doc/orionx"
    cp "$REPO_ROOT"/*.md "$ISO_DIR/config/includes.chroot/usr/share/doc/orionx/"
    cp "$REPO_ROOT/manifest.json" "$ISO_DIR/config/includes.chroot/usr/share/doc/orionx/"
    
    # Create version file
    echo "Orion-X Phoenix Edition v$VERSION" > "$ISO_DIR/config/includes.chroot/usr/share/doc/orionx/version"
    
    log "ISO customization complete"
}

# Function to build the ISO
build_iso() {
    log "Building ISO..."
    
    cd "$ISO_DIR"
    
    # Run the build
    lb build
    
    # Check if build was successful
    if [ -f "$ISO_DIR/live-image-amd64.hybrid.iso" ]; then
        log "Build successful!"
        
        # Copy the ISO to the output directory with our preferred name
        cp "$ISO_DIR/live-image-amd64.hybrid.iso" "$OUTPUT_DIR/$ISO_NAME"
        
        # Calculate and store the checksum
        cd "$OUTPUT_DIR"
        sha256sum "$ISO_NAME" > "$ISO_NAME.sha256"
        
        log "ISO has been created: $OUTPUT_DIR/$ISO_NAME"
        log "SHA-256 checksum: $(cat "$ISO_NAME.sha256")"
    else
        log "ERROR: Build failed!"
        exit 1
    fi
}

# Function to clean up
cleanup() {
    log "Cleaning up build environment..."
    
    # Optional: Clean up build files to save space
    # Uncomment the following lines if you want to clean up after building
    # cd "$ISO_DIR"
    # lb clean --purge
    
    log "Clean up complete"
}

# Main execution
log "Starting Orion-X Phoenix Edition v$VERSION ISO build"

check_prerequisites
prepare_build_env
configure_live_build
customize_iso
build_iso
cleanup

log "Build process completed successfully"
echo ""
echo "=============================================="
echo "Orion-X Phoenix Edition v$VERSION ISO build completed!"
echo "ISO file: $OUTPUT_DIR/$ISO_NAME"
echo "SHA-256: $(cat "$OUTPUT_DIR/$ISO_NAME.sha256")"
echo "=============================================="
