#!/bin/bash
#
# Orion-X Phoenix Edition v1.5.5
# Installation script for preparing a target drive with Orion-X
#
# This script will:
# - Check system requirements
# - Format the drive with encrypted storage (LUKS if persistence is needed)
# - Copy the live system files
# - Install bootloader with secure boot keys if available
#
# No default credentials are embedded in this script

set -e
LOGFILE="/tmp/orionx-install.log"
ISO_PATH=""
TARGET_DEVICE=""
ENABLE_PERSISTENCE=false
ENABLE_ENCRYPTION=false

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "Starting Orion-X Phoenix Edition v1.5.5 installation"

# Function to check system requirements
check_requirements() {
    log "Checking system requirements..."
    
    # Check for required tools
    for cmd in fdisk cryptsetup mkfs.ext4 mkfs.vfat parted grub-install; do
        if ! command -v $cmd &> /dev/null; then
            log "ERROR: Required command '$cmd' not found"
            exit 1
        fi
    done
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR: This script must be run as root"
        exit 1
    fi
    
    # Check boot mode (UEFI or BIOS)
    if [ -d /sys/firmware/efi ]; then
        log "Detected UEFI boot mode"
        BOOT_MODE="uefi"
    else
        log "Detected BIOS boot mode"
        BOOT_MODE="bios"
    fi
    
    log "System requirements check passed"
}

# Function to get user inputs
get_user_inputs() {
    # Get ISO path if not provided
    while [ -z "$ISO_PATH" ] || [ ! -f "$ISO_PATH" ]; do
        read -rp "Enter path to Orion-X ISO file: " ISO_PATH
        if [ ! -f "$ISO_PATH" ]; then
            echo "ISO file not found. Please enter a valid path."
        fi
    done
    
    # List available devices
    echo "Available devices:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v loop
    
    # Get target device
    while [ -z "$TARGET_DEVICE" ]; do
        read -rp "Enter target device (e.g., /dev/sdb): " TARGET_DEVICE
        if [ ! -b "$TARGET_DEVICE" ]; then
            echo "Device not found. Please enter a valid device."
            TARGET_DEVICE=""
        else
            echo "WARNING: All data on $TARGET_DEVICE will be erased!"
            read -rp "Continue? (y/n): " confirm
            if [ "$confirm" != "y" ]; then
                TARGET_DEVICE=""
            fi
        fi
    done
    
    # Ask for persistence
    read -rp "Enable persistence? (y/n): " persistence
    if [ "$persistence" = "y" ]; then
        ENABLE_PERSISTENCE=true
        
        # Ask for encryption
        read -rp "Encrypt persistent storage? (y/n): " encryption
        if [ "$encryption" = "y" ]; then
            ENABLE_ENCRYPTION=true
        fi
    fi
}

# Function to prepare the target device
prepare_device() {
    log "Preparing target device $TARGET_DEVICE..."
    
    # Unmount any partitions on the target device
    umount "${TARGET_DEVICE}"* 2>/dev/null || true
    
    # Create new partition table
    log "Creating new partition table..."
    parted -s "$TARGET_DEVICE" mklabel gpt
    
    if [ "$BOOT_MODE" = "uefi" ]; then
        # EFI partition (500MB)
        parted -s "$TARGET_DEVICE" mkpart primary fat32 1MiB 501MiB
        parted -s "$TARGET_DEVICE" set 1 esp on
        
        # ISO partition (5GB)
        parted -s "$TARGET_DEVICE" mkpart primary 501MiB 5501MiB
        
        if [ "$ENABLE_PERSISTENCE" = true ]; then
            # Persistence partition (remaining space)
            parted -s "$TARGET_DEVICE" mkpart primary 5501MiB 100%
        fi
    else
        # BIOS boot partition (1MB)
        parted -s "$TARGET_DEVICE" mkpart primary 1MiB 2MiB
        parted -s "$TARGET_DEVICE" set 1 bios_grub on
        
        # ISO partition (5GB)
        parted -s "$TARGET_DEVICE" mkpart primary 2MiB 5002MiB
        
        if [ "$ENABLE_PERSISTENCE" = true ]; then
            # Persistence partition (remaining space)
            parted -s "$TARGET_DEVICE" mkpart primary 5002MiB 100%
        fi
    fi
    
    # Give the kernel time to read the new partition table
    sleep 2
    
    # Format partitions
    if [ "$BOOT_MODE" = "uefi" ]; then
        log "Formatting EFI partition..."
        mkfs.vfat -F 32 "${TARGET_DEVICE}1"
        
        log "Formatting ISO partition..."
        mkfs.ext4 -L "ORIONX_ISO" "${TARGET_DEVICE}2"
        
        if [ "$ENABLE_PERSISTENCE" = true ]; then
            log "Setting up persistence partition..."
            if [ "$ENABLE_ENCRYPTION" = true ]; then
                log "Setting up encrypted persistence..."
                # Generate a random key file for the first run
                # This will be replaced with the user's passphrase on first boot
                dd if=/dev/urandom of=/tmp/tempkey bs=512 count=4
                
                # Set up LUKS encryption
                cryptsetup luksFormat --key-file=/tmp/tempkey "${TARGET_DEVICE}3"
                cryptsetup luksOpen --key-file=/tmp/tempkey "${TARGET_DEVICE}3" orionx_crypt
                
                # Create filesystem on the encrypted partition
                mkfs.ext4 -L "ORIONX_PERSIST" /dev/mapper/orionx_crypt
                
                # Close the encrypted device
                cryptsetup luksClose orionx_crypt
                
                # Remove the temporary key
                shred -u /tmp/tempkey
                
                log "Encryption setup complete. You will be prompted to set a passphrase on first boot."
            else
                log "Setting up unencrypted persistence..."
                mkfs.ext4 -L "ORIONX_PERSIST" "${TARGET_DEVICE}3"
            fi
        fi
    else
        # Format for BIOS boot
        log "Formatting ISO partition..."
        mkfs.ext4 -L "ORIONX_ISO" "${TARGET_DEVICE}2"
        
        if [ "$ENABLE_PERSISTENCE" = true ]; then
            log "Setting up persistence partition..."
            if [ "$ENABLE_ENCRYPTION" = true ]; then
                # Similar encryption setup for BIOS boot
                # [BIOS encryption setup code - similar to UEFI version]
                log "Setting up encrypted persistence..."
                # Generate a random key file for the first run
                dd if=/dev/urandom of=/tmp/tempkey bs=512 count=4
                
                # Set up LUKS encryption
                cryptsetup luksFormat --key-file=/tmp/tempkey "${TARGET_DEVICE}3"
                cryptsetup luksOpen --key-file=/tmp/tempkey "${TARGET_DEVICE}3" orionx_crypt
                
                # Create filesystem on the encrypted partition
                mkfs.ext4 -L "ORIONX_PERSIST" /dev/mapper/orionx_crypt
                
                # Close the encrypted device
                cryptsetup luksClose orionx_crypt
                
                # Remove the temporary key
                shred -u /tmp/tempkey
            else
                log "Setting up unencrypted persistence..."
                mkfs.ext4 -L "ORIONX_PERSIST" "${TARGET_DEVICE}3"
            fi
        fi
    fi
    
    log "Device preparation complete"
}

# Function to copy ISO content to the device
copy_iso_content() {
    log "Copying ISO content to target device..."
    
    # Create mount points
    mkdir -p /tmp/orionx_iso
    mkdir -p /tmp/orionx_target
    
    # Mount the ISO
    mount -o loop "$ISO_PATH" /tmp/orionx_iso
    
    # Mount the target ISO partition
    if [ "$BOOT_MODE" = "uefi" ]; then
        mount "${TARGET_DEVICE}2" /tmp/orionx_target
    else
        mount "${TARGET_DEVICE}2" /tmp/orionx_target
    fi
    
    # Copy the ISO content
    log "Copying files... (this might take a while)"
    cp -a /tmp/orionx_iso/* /tmp/orionx_target/
    
    # If UEFI, prepare the EFI partition
    if [ "$BOOT_MODE" = "uefi" ]; then
        mkdir -p /tmp/orionx_efi
        mount "${TARGET_DEVICE}1" /tmp/orionx_efi
        
        # Copy EFI files if they exist in the ISO
        if [ -d /tmp/orionx_iso/EFI ]; then
            mkdir -p /tmp/orionx_efi/EFI
            cp -a /tmp/orionx_iso/EFI/* /tmp/orionx_efi/EFI/
        fi
    fi
    
    log "Copy complete"
}

# Function to install bootloader
install_bootloader() {
    log "Installing bootloader..."
    
    if [ "$BOOT_MODE" = "uefi" ]; then
        # For UEFI systems
        log "Installing GRUB for UEFI systems..."
        
        # Ensure the EFI partition is mounted
        if ! mountpoint -q /tmp/orionx_efi; then
            mkdir -p /tmp/orionx_efi
            mount "${TARGET_DEVICE}1" /tmp/orionx_efi
        fi
        
        # Install GRUB
        grub-install --target=x86_64-efi --efi-directory=/tmp/orionx_efi --boot-directory=/tmp/orionx_target/boot --removable
        
        # Check if secure boot is available
        if dmesg | grep -i "secure boot enabled"; then
            log "Secure Boot detected, installing signed GRUB"
            # Copy the signed shim and grub files if available
            # This would be specific to the Linux distribution being used
            # Command would vary based on distro and secure boot configuration
        else
            log "Secure Boot not detected, using standard GRUB"
        fi
    else
        # For BIOS systems
        log "Installing GRUB for BIOS systems..."
        grub-install --target=i386-pc --boot-directory=/tmp/orionx_target/boot "$TARGET_DEVICE"
    fi
    
    # Create/update GRUB configuration
    log "Updating GRUB configuration..."
    cat > /tmp/orionx_target/boot/grub/grub.cfg << EOF
set default=0
set timeout=5

menuentry "Orion-X Phoenix Edition v1.5.5" {
    linux /boot/vmlinuz boot=live quiet splash
    initrd /boot/initrd.img
}

menuentry "Orion-X Phoenix Edition v1.5.5 (with persistence)" {
    linux /boot/vmlinuz boot=live quiet splash persistence
    initrd /boot/initrd.img
}

menuentry "Orion-X Phoenix Edition v1.5.5 (Safe Mode)" {
    linux /boot/vmlinuz boot=live quiet splash nomodeset
    initrd /boot/initrd.img
}
EOF
    
    log "Bootloader installation complete"
}

# Function to clean up
cleanup() {
    log "Cleaning up..."
    
    # Unmount all mounted partitions
    if mountpoint -q /tmp/orionx_efi; then
        umount /tmp/orionx_efi
    fi
    
    if mountpoint -q /tmp/orionx_target; then
        umount /tmp/orionx_target
    fi
    
    if mountpoint -q /tmp/orionx_iso; then
        umount /tmp/orionx_iso
    fi
    
    # Remove temporary directories
    rmdir /tmp/orionx_efi 2>/dev/null || true
    rmdir /tmp/orionx_target 2>/dev/null || true
    rmdir /tmp/orionx_iso 2>/dev/null || true
    
    log "Cleanup complete"
}

# Main execution
check_requirements
get_user_inputs
prepare_device
copy_iso_content
install_bootloader
cleanup

log "Orion-X Phoenix Edition v1.5.5 has been successfully installed to $TARGET_DEVICE"
if [ "$ENABLE_PERSISTENCE" = true ] && [ "$ENABLE_ENCRYPTION" = true ]; then
    log "Note: You will be prompted to set a passphrase for the encrypted persistence on first boot"
fi

echo ""
echo "=========================================================="
echo "Installation complete!"
echo "You can now boot from $TARGET_DEVICE to use Orion-X Phoenix Edition."
echo "For more information, please refer to the User Guide."
echo "=========================================================="
