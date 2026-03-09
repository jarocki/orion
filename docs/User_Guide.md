# Orion-X Phoenix Edition v1.5.5 User Guide

## Table of Contents

1. [Introduction](#introduction)
   - [About Orion-X Phoenix Edition](#about-orion-x-phoenix-edition)
   - [Key Features](#key-features)
   - [Use Cases](#use-cases)

2. [Getting Started](#getting-started)
   - [System Requirements](#system-requirements)
   - [Creating Bootable Media](#creating-bootable-media)
   - [Verifying Your Installation](#verifying-your-installation)

3. [Booting and Initial Setup](#booting-and-initial-setup)
   - [Boot Menu Options](#boot-menu-options)
   - [First Boot Configuration](#first-boot-configuration)
   - [Persistence Options](#persistence-options)

4. [Networking](#networking)
   - [Connecting to Local Networks](#connecting-to-local-networks)
   - [Setting Up WireGuard VPN](#setting-up-wireguard-vpn)
   - [Network Configuration Verification](#network-configuration-verification)

5. [Secure Communication](#secure-communication)
   - [Matrix Setup](#matrix-setup)
   - [Using Element Client](#using-element-client)
   - [Communication Best Practices](#communication-best-practices)

6. [Forensic Evidence Collection](#forensic-evidence-collection)
   - [Memory Acquisition](#memory-acquisition)
   - [Disk Imaging](#disk-imaging)
   - [Network Traffic Capture](#network-traffic-capture)
   - [Log Collection](#log-collection)
   - [Chain of Custody Documentation](#chain-of-custody-documentation)

7. [Artifact Analysis](#artifact-analysis)
   - [Using artifact-analyzer.py](#using-artifact-analyzerpy)
   - [Memory Analysis](#memory-analysis)
   - [Disk Analysis](#disk-analysis)
   - [Network Analysis](#network-analysis)
   - [Log Analysis](#log-analysis)

8. [Timeline Generation](#timeline-generation)
   - [Using storyboard-gen.py](#using-storyboard-genpy)
   - [Working with Multiple Log Sources](#working-with-multiple-log-sources)
   - [Visualizing the Timeline](#visualizing-the-timeline)

9. [Data Management](#data-management)
   - [Local Storage Options](#local-storage-options)
   - [Uploading to Artifact Vault](#uploading-to-artifact-vault)
   - [Data Security Considerations](#data-security-considerations)

10. [Customization](#customization)
    - [Switching Visual Themes](#switching-visual-themes)
    - [Customizing Terminal Environment](#customizing-terminal-environment)
    - [Adding Custom Tools](#adding-custom-tools)

11. [Sample Data](#sample-data)
    - [Working with PCAP Samples](#working-with-pcap-samples)
    - [Memory Dump Analysis](#memory-dump-analysis)
    - [Firmware Analysis](#firmware-analysis)
    - [Log File Examples](#log-file-examples)

12. [Troubleshooting](#troubleshooting)
    - [Boot Issues](#boot-issues)
    - [Network Connectivity](#network-connectivity)
    - [VPN Troubleshooting](#vpn-troubleshooting)
    - [Matrix Connection Issues](#matrix-connection-issues)
    - [Tool Execution Problems](#tool-execution-problems)

13. [Appendices](#appendices)
    - [Command Reference](#command-reference)
    - [File Locations](#file-locations)
    - [Keyboard Shortcuts](#keyboard-shortcuts)

## Introduction

### About Orion-X Phoenix Edition

Orion-X Phoenix Edition v1.5.5 is a comprehensive cybersecurity toolkit designed specifically for incident response and digital forensics. It provides a hardened Linux-based live environment that emphasizes security, privacy, and team collaboration.

The "Phoenix" name symbolizes the toolkit's ability to help organizations rise from the ashes of security incidents through effective investigation and response. This edition (v1.5.5) represents a significant evolution from previous versions, with enhanced security features, improved usability, and expanded capabilities.

Orion-X is designed to be booted directly from USB media, leaving no traces on the host system. It can run entirely in memory, providing a secure and isolated environment for analyzing potentially compromised systems.

### Key Features

- **Hardened Linux Environment**: Secure boot support and RAM-only operation with optional full disk encryption
- **Secure Communication**: Integrated Matrix client/server for encrypted team collaboration
- **Private Networking**: WireGuard VPN for secure connectivity to team infrastructure
- **Comprehensive Forensic Tools**: Built-in utilities for memory acquisition, disk imaging, network analysis
- **Automated Analysis**: Custom scripts for rapid artifact processing and timeline generation
- **Sample Data Library**: Real-world forensic samples for training and testing
- **Visual Distinction**: Themed interface with two modes (amber/dark and green) for operational clarity
- **Documentation**: Complete guides and reference materials accessible within the environment

### Use Cases

Orion-X Phoenix Edition is ideal for:

- **Security Incident Response**: Investigating suspected compromises or breaches
- **Digital Forensics**: Collecting and analyzing digital evidence
- **Malware Analysis**: Examining suspected malicious code in a controlled environment
- **Security Training**: Teaching incident response and forensic techniques
- **Penetration Testing**: As part of a security assessment toolkit
- **Emergency Response**: Quick deployment for urgent security situations

## Getting Started

### System Requirements

To effectively run Orion-X Phoenix Edition, your system should meet these minimum requirements:

- **CPU**: 64-bit processor (x86_64)
- **RAM**: 4GB minimum (8GB+ recommended for memory analysis)
- **Storage**: 8GB+ USB drive for bootable media
- **Boot Support**: UEFI or Legacy BIOS
- **Network**: Wired or wireless network adapter

For intensive operations like memory analysis of large dumps or processing multiple disk images, we recommend:

- **RAM**: 16GB or more
- **CPU**: Multi-core processor
- **Storage**: Additional external storage for saving artifacts

### Creating Bootable Media

Before you can use Orion-X, you need to create bootable media (typically a USB drive). The process varies by operating system:

#### On Linux

1. Download the Orion-X Phoenix Edition ISO file
2. Open a terminal and identify your USB device:
   ```bash
   lsblk
   ```
3. Create bootable media (replace `/dev/sdX` with your device):
   ```bash
   sudo dd if=/path/to/orionx-phoenix-edition-v1.5.5.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

#### On Windows

1. Download the Orion-X Phoenix Edition ISO file
2. Download and install a tool like Rufus (https://rufus.ie) or balenaEtcher (https://www.balena.io/etcher/)
3. Insert your USB drive
4. Open Rufus or balenaEtcher and follow the instructions to select the ISO and USB drive
5. Create the bootable USB (select "DD Image mode" if prompted)

#### On macOS

1. Download the Orion-X Phoenix Edition ISO file
2. Open Terminal and identify your USB drive:
   ```bash
   diskutil list
   ```
3. Unmount the drive (replace `N` with your disk number):
   ```bash
   diskutil unmountDisk /dev/diskN
   ```
4. Create bootable media:
   ```bash
   sudo dd if=/path/to/orionx-phoenix-edition-v1.5.5.iso of=/dev/rdiskN bs=1m
   ```
5. Eject the drive when complete:
   ```bash
   diskutil eject /dev/diskN
   ```

### Verifying Your Installation

To verify the integrity of your bootable media:

1. Calculate the SHA-256 hash of the ISO before writing to USB:
   ```bash
   # On Linux/macOS
   sha256sum orionx-phoenix-edition-v1.5.5.iso
   
   # On Windows (PowerShell)
   Get-FileHash orionx-phoenix-edition-v1.5.5.iso -Algorithm SHA256
   ```

2. Compare the calculated hash with the one provided on the download page

3. After creating the bootable media, boot into Orion-X and verify the version:
   ```bash
   cat /usr/share/doc/orionx/version
   ```

## Booting and Initial Setup

### Boot Menu Options

When booting from your Orion-X USB drive, you'll be presented with several boot options:

- **Orion-X Phoenix Edition v1.5.5**: Standard boot with default settings
- **Orion-X Phoenix Edition v1.5.5 (with persistence)**: Boot with persistent storage
- **Orion-X Phoenix Edition v1.5.5 (Safe Mode)**: Boot with minimal drivers for compatibility
- **Memory Test**: Run a memory diagnostic

Use the arrow keys to select your preferred option and press Enter to boot.

### First Boot Configuration

On first boot, Orion-X will automatically configure itself for the hardware. If you've enabled persistence with encryption, you'll be prompted to:

1. Set a passphrase for the encrypted partition
2. Configure keyboard layout and locale settings
3. Set the username and password (if not using the default)

The system will boot to a desktop environment with the Orion-X wallpaper and pre-configured shortcuts.

### Persistence Options

Orion-X can operate in two primary modes:

#### Amnesic Mode (Default)

- Runs entirely in RAM
- Leaves no trace on the host system
- All changes are lost on reboot
- Ideal for maximum security and forensic integrity

#### Persistent Mode

- Changes are saved between reboots
- Configurations, collected evidence, and installed tools are preserved
- Optional encrypted persistence for sensitive data
- Activated by selecting "with persistence" in the boot menu

To set up encrypted persistence after installation:

1. Boot Orion-X normally
2. Open a terminal and run:
   ```bash
   sudo cryptsetup luksFormat /dev/sdX3
   sudo cryptsetup luksOpen /dev/sdX3 orionx_persist
   sudo mkfs.ext4 -L persistence /dev/mapper/orionx_persist
   sudo mount /dev/mapper/orionx_persist /mnt
   echo "/ union" | sudo tee /mnt/persistence.conf
   sudo umount /mnt
   sudo cryptsetup luksClose orionx_persist
   ```
3. Reboot and select the persistence option

## Networking

### Connecting to Local Networks

Orion-X supports both wired and wireless network connections:

#### Wired Connection

1. Connect an Ethernet cable to your system
2. The connection should be established automatically
3. Verify by checking the network icon in the system tray

#### Wireless Connection

1. Click the network icon in the system tray (top-right corner)
2. Select your wireless network from the list
3. Enter the password when prompted
4. Wait for the connection to be established

To verify your network connection:

```bash
ip a
ping -c 4 1.1.1.1
```

### Setting Up WireGuard VPN

Orion-X uses WireGuard for secure communication with your team's infrastructure:

1. Open a terminal
2. Run the VPN setup script:
   ```bash
   sudo setup-vpn.sh
   ```
3. Follow the prompts to configure the VPN:
   - Server endpoint (IP:Port)
   - Server public key
   - Your assigned client IP address
   - DNS settings (optional)
   - Allowed IPs (optional)

The script will:
1. Generate your client keys (public and private)
2. Create the WireGuard configuration
3. Activate the connection automatically

For manual control of your VPN connection:

- **Start VPN**: `sudo wg-quick up orionx`
- **Stop VPN**: `sudo wg-quick down orionx`
- **Check status**: `sudo wg show`

If your team does not have a central VPN server, you can set up direct peer connections between Orion-X instances.

### Network Configuration Verification

To verify your network configuration:

1. Check interface status:
   ```bash
   ip a
   ```

2. Verify DNS resolution:
   ```bash
   nslookup example.com
   ```

3. Check VPN connectivity:
   ```bash
   sudo wg show
   ```

4. Test connection to team infrastructure:
   ```bash
   ping -c 4 [artifact-vault-ip]
   ```

5. Network troubleshooting:
   ```bash
   traceroute [destination]
   ```

## Secure Communication

### Matrix Setup

Orion-X uses Matrix for secure, encrypted team communication. To set up Matrix:

1. Open a terminal
2. Run the Matrix setup script:
   ```bash
   sudo setup-matrix.sh
   ```
3. Choose your configuration mode:
   - **Client Mode**: Connect to your team's existing Matrix server
   - **Server Mode**: Configure this Orion-X instance as a Matrix homeserver

#### Client Mode Configuration

If connecting to an existing server:

1. Enter the Matrix homeserver URL (e.g., `https://matrix.example.org`)
2. Enter your Matrix user ID (`@username:server.org`)
3. Enter your password
4. The script will configure the Element client automatically

#### Server Mode Configuration

If setting up a local server:

1. Enter a server name for the Matrix homeserver
2. Create an admin username and password
3. The script will:
   - Generate a secure configuration
   - Create a self-signed certificate
   - Start the Matrix Synapse server
   - Register your admin user
   - Configure the Element client

### Using Element Client

Element is the Matrix client included with Orion-X:

1. Launch Element from the Applications menu or by typing `element-desktop` in a terminal
2. If prompted, log in with your credentials
3. Join your team's incident response room
4. Create new rooms for specific investigations if needed

Matrix features in Orion-X:

- End-to-end encryption for all messages
- File sharing (for small artifacts and screenshots)
- Room history for maintaining investigation context
- Direct messaging between team members
- Optional voice/video calls (if supported by the server)

### Communication Best Practices

When using Matrix for incident response:

1. **Create dedicated rooms** for each incident or investigation
2. **Use clear room names** that include case numbers or identifiers
3. **Invite only necessary team members** to maintain confidentiality
4. **Verify device keys** of all team members when possible
5. **Share sensitive information** only in encrypted chats
6. **Maintain a communication log** for handovers between shifts
7. **Set appropriate retention policies** for message history

## Forensic Evidence Collection

### Memory Acquisition

Memory acquisition is critical for capturing volatile system state. Orion-X includes several methods:

#### For Linux Target Systems

1. Use the AVML tool:
   ```bash
   sudo avml /path/to/output.raw
   ```

2. Use LiME kernel module (for kernel-specific acquisition):
   ```bash
   sudo insmod lime.ko "path=/path/to/output.lime format=lime"
   ```

#### For Windows Target Systems

1. Via FireWire (if available):
   ```bash
   sudo fmem /dev/fw0 /path/to/output.raw
   ```

2. Using external tools:
   - Run DumpIt.exe or WinPmem from a USB drive
   - Copy the resulting memory dump to Orion-X for analysis

#### Memory Acquisition Best Practices

- Always acquire memory before any other actions that might alter system state
- Document the system time and acquisition time for proper timeline correlation
- Use write blockers when possible to prevent accidental writes to evidence
- Verify integrity by calculating hash values immediately after acquisition

### Disk Imaging

To create forensic images of storage devices:

1. Identify the target disk:
   ```bash
   sudo fdisk -l
   ```

2. Create a bit-by-bit copy with dd:
   ```bash
   sudo dd if=/dev/sdX of=/path/to/image.dd bs=4M status=progress
   ```

3. For enhanced logging and verification, use dc3dd:
   ```bash
   sudo dc3dd if=/dev/sdX of=/path/to/image.dd hash=sha256 log=/path/to/acquisition.log hof=/path/to/image.dd.hash
   ```

4. For sparse imaging of large drives:
   ```bash
   sudo dcfldd if=/dev/sdX of=/path/to/image.dd bs=4M hash=sha256 hashlog=/path/to/hash.log notrunc
   ```

5. For E01 format imaging, use ewfacquire:
   ```bash
   sudo ewfacquire -t /path/to/image.E01 /dev/sdX
   ```

### Network Traffic Capture

Network traffic capture can reveal communication patterns, malware command and control, and data exfiltration:

1. List available network interfaces:
   ```bash
   sudo ip a
   ```

2. Capture traffic with tcpdump:
   ```bash
   sudo tcpdump -i eth0 -w /path/to/capture.pcap
   ```

3. Apply filters to focus on specific traffic:
   ```bash
   # Capture HTTP traffic
   sudo tcpdump -i eth0 -w /path/to/http.pcap port 80 or port 443
   
   # Capture DNS traffic
   sudo tcpdump -i eth0 -w /path/to/dns.pcap port 53
   
   # Capture traffic to/from a specific host
   sudo tcpdump -i eth0 -w /path/to/host.pcap host 192.168.1.10
   ```

4. Use Wireshark for real-time traffic analysis:
   ```bash
   sudo wireshark
   ```

### Log Collection

System logs contain valuable forensic information:

1. Collect standard Linux logs:
   ```bash
   sudo tar czf /path/to/linux_logs.tar.gz /var/log
   ```

2. Extract Windows event logs:
   ```bash
   # Mount the Windows partition
   sudo mount /dev/sdXN /mnt
   
   # Copy event logs
   sudo cp /mnt/Windows/System32/winevt/Logs/*.evtx /path/to/windows_logs/
   ```

3. Collect application logs:
   ```bash
   # Web server logs
   sudo cp -r /var/www/logs /path/to/web_logs
   
   # Database logs
   sudo cp -r /var/lib/mysql/logs /path/to/db_logs
   ```

4. Create a timestamped log summary:
   ```bash
   sudo find /var/log -type f -exec ls -la {} \; > /path/to/log_inventory.txt
   ```

### Chain of Custody Documentation

Maintaining chain of custody is essential for evidence integrity:

1. Document each acquisition with:
   - Date and time of collection
   - System identifiers (hostname, serial number)
   - Evidence description
   - Hash values for verification
   - Names of personnel involved

2. Use the built-in chain of custody generation in artifact-analyzer.py:
   ```bash
   sudo python3 /usr/bin/artifact-analyzer.py /path/to/artifact --generate-custody
   ```

3. For manual documentation, create custody forms:
   ```bash
   # Generate custody form template
   echo "CHAIN OF CUSTODY" > custody_form.txt
   echo "Date: $(date)" >> custody_form.txt
   echo "Evidence: [Description]" >> custody_form.txt
   echo "Hash: $(sha256sum /path/to/evidence)" >> custody_form.txt
   echo "Collector: [Name]" >> custody_form.txt
   ```

4. Store chain of custody documentation with the evidence it describes

## Artifact Analysis

### Using artifact-analyzer.py

Orion-X includes a powerful artifact analysis automation tool:

1. Basic usage:
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/artifact_file -o /path/to/output_dir
   ```

2. With explicit artifact type specification:
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/artifact_file -t memory -o /path/to/output_dir
   ```

3. Uploading results to an artifact vault:
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/artifact_file --upload --vault-url https://vault.example.com --vault-token your_token
   ```

4. The script will:
   - Identify the artifact type if not specified
   - Generate a chain of custody document
   - Run appropriate analysis tools
   - Create summary reports
   - Optionally upload results

### Memory Analysis

For detailed memory analysis:

1. Using Volatility 3:
   ```bash
   # List available plugins
   vol -h
   
   # List running processes
   vol -f /path/to/memory.raw windows.pslist
   
   # Network connections
   vol -f /path/to/memory.raw windows.netscan
   
   # Command history
   vol -f /path/to/memory.raw windows.cmdline
   ```

2. Using the artifact analyzer (automates multiple plugins):
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/memory.raw -t memory
   ```

3. Review key indicators in memory:
   - Unusual processes or services
   - Suspicious network connections
   - Injected code or hidden DLLs
   - Evidence of credential theft
   - Registry artifacts in memory

### Disk Analysis

For analyzing disk images:

1. Using The Sleuth Kit tools:
   ```bash
   # List partitions
   mmls /path/to/disk.img
   
   # Browse filesystem (offset from mmls)
   fls -o 2048 /path/to/disk.img
   
   # Extract files
   icat -o 2048 /path/to/disk.img [inode] > extracted_file
   ```

2. Mount disk image for analysis:
   ```bash
   # Create a loopback device
   sudo losetup -f -P /path/to/disk.img
   
   # Find the assigned device
   losetup -a
   
   # Mount the partition
   sudo mount /dev/loop0p1 /mnt
   ```

3. Use automated analysis:
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/disk.img -t disk
   ```

4. Search for specific patterns:
   ```bash
   # Search for credit card numbers
   bulk_extractor -o output_dir /path/to/disk.img
   ```

### Network Analysis

For analyzing network captures:

1. Basic analysis with tshark:
   ```bash
   # Protocol hierarchy statistics
   tshark -r /path/to/capture.pcap -q -z io,phs
   
   # HTTP requests
   tshark -r /path/to/capture.pcap -Y "http.request" -T fields -e http.host -e http.request.uri
   
   # DNS queries
   tshark -r /path/to/capture.pcap -Y "dns" -T fields -e dns.qry.name
   ```

2. Using Wireshark for visual analysis:
   ```bash
   wireshark /path/to/capture.pcap
   ```

3. Using Zeek for protocol analysis:
   ```bash
   zeek -r /path/to/capture.pcap
   ```

4. Automated network analysis:
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/capture.pcap -t network
   ```

### Log Analysis

For analyzing log files:

1. Basic analysis with Unix tools:
   ```bash
   # Search for errors
   grep -i "error\|fail\|critical" /path/to/logfile.log
   
   # Extract timestamps with context
   grep -A 2 -B 2 "2023-01-01" /path/to/logfile.log
   ```

2. Using the log analyzer component:
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/logfile.log -t log
   ```

3. Windows event log analysis:
   ```bash
   # Convert to XML for easier parsing
   evtxexport /path/to/Security.evtx > security.xml
   
   # Search for specific event IDs
   grep -A 10 -B 2 "EventID>4624" security.xml
   ```

4. Timeline creation from logs:
   ```bash
   python3 /usr/bin/storyboard-gen.py -i /path/to/logs/ -o timeline.html
   ```

## Timeline Generation

### Using storyboard-gen.py

Orion-X includes a tool for creating chronological timelines from multiple sources:

1. Basic usage:
   ```bash
   python3 /usr/bin/storyboard-gen.py -i /path/to/logs/ -o timeline.html
   ```

2. Specifying case information:
   ```bash
   python3 /usr/bin/storyboard-gen.py -i /path/to/logs/ -o timeline.html -c "Ransomware Incident" -id "CASE-2025-001" -a "Investigator Name"
   ```

3. Generating a text report instead of HTML:
   ```bash
   python3 /usr/bin/storyboard-gen.py -i /path/to/logs/ -o timeline.txt -f text
   ```

### Working with Multiple Log Sources

To combine multiple log sources into a coherent timeline:

1. Collect logs from various sources:
   - Web server logs
   - Authentication logs
   - Firewall logs
   - Application logs
   - Windows event logs

2. Place them in a common directory structure:
   ```
   /case/logs/
   ├── web/
   │   ├── access.log
   │   └── error.log
   ├── firewall/
   │   └── fw.log
   ├── windows/
   │   ├── security.evtx
   │   └── system.evtx
   └── auth.log
   ```

3. Generate a comprehensive timeline:
   ```bash
   python3 /usr/bin/storyboard-gen.py -i /case/logs/ -o /case/timeline.html
   ```

4. The storyboard generator will:
   - Parse different log formats automatically
   - Extract timestamps and normalize them
   - Sort events chronologically
   - Color-code by severity
   - Link events to their source files

### Visualizing the Timeline

The storyboard generator creates visual timelines to help identify patterns:

1. HTML timeline features:
   - Color-coded events by severity (info, warning, error)
   - Collapsible sections by source
   - Sortable columns
   - Search functionality
   - Interactive time range selection

2. Filtering the timeline view:
   - By time range (before or after specific events)
   - By severity level
   - By log source
   - By keyword or pattern

3. Exporting and sharing:
   - Save as HTML for interactive viewing
   - Print to PDF for reporting
   - Export as CSV for further analysis

4. Integration with other tools:
   - Link timeline events to original artifacts
   - Import timeline data into other visualization tools
   - Add annotations and investigator notes

## Data Management

### Local Storage Options

For managing collected evidence and analysis results:

1. External storage devices:
   ```bash
   # List available devices
   sudo fdisk -l
   
   # Mount an external drive
   sudo mount /dev/sdX1 /mnt/external
   
   # Copy evidence to external storage
   cp -r /path/to/evidence/ /mnt/external/
   ```

2. RAM disk for temporary storage:
   ```bash
   # Create a RAM disk (1GB)
   sudo mkdir -p /mnt/ramdisk
   sudo mount -t tmpfs -o size=1024m tmpfs /mnt/ramdisk
   ```

3. Encrypted containers for sensitive data:
   ```bash
   # Create a 1GB encrypted container
   dd if=/dev/urandom of=/path/to/container.img bs=1M count=1024
   sudo cryptsetup luksFormat /path/to/container.img
   sudo cryptsetup luksOpen /path/to/container.img secure_data
   sudo mkfs.ext4 /dev/mapper/secure_data
   sudo mount /dev/mapper/secure_data /mnt/secure
   ```

### Uploading to Artifact Vault

Orion-X can interface with centralized evidence repositories:

1. Configure vault connection:
   ```bash
   # Set environment variables for vault connection
   export ORIONX_VAULT_URL="https://vault.example.com"
   export ORIONX_VAULT_TOKEN="your_vault_token"
   ```

2. Create a vault configuration file:
   ```bash
   sudo mkdir -p /etc/orionx
   sudo tee /etc/orionx/vault_config.conf > /dev/null << EOF
   ORIONX_VAULT_URL="https://vault.example.com"
   ORIONX_VAULT_TOKEN="your_vault_token"
   EOF
   sudo chmod 600 /etc/orionx/vault_config.conf
   ```

3. Upload artifacts using the analyzer:
   ```bash
   python3 /usr/bin/artifact-analyzer.py /path/to/artifact --upload
   ```

4. Manual upload with curl:
   ```bash
   # Upload a file to the vault API
   curl -X POST -H "Authorization: Bearer $ORIONX_VAULT_TOKEN" \
        -F "file=@/path/to/evidence.dd" \
        -F "metadata={\"case\":\"CASE-2025-001\",\"type\":\"disk\",\"hash\":\"$(sha256sum /path/to/evidence.dd | cut -d' ' -f1)\"}" \
        "$ORIONX_VAULT_URL/api/artifacts/upload"
   ```

### Data Security Considerations

When handling forensic data:

1. Sanitize destination media:
   ```bash
   # Securely wipe a device
   sudo dd if=/dev/urandom of=/dev/sdX bs=4M status=progress
   ```

2. Verify data integrity with hashes:
   ```bash
   # Generate hash before transfer
   sha256sum /path/to/evidence.dd > evidence.dd.sha256
   
   # Verify after transfer
   sha256sum -c evidence.dd.sha256
   ```

3. Encrypt sensitive data during transfer:
   ```bash
   # Create encrypted archive
   tar czf - /path/to/evidence/ | gpg -c > evidence.tar.gz.gpg
   ```

4. Implement secure deletion when needed:
   ```bash
   # Securely delete files
   shred -u /path/to/sensitive_file
   ```

5. Maintain backup copies of critical evidence
6. Document all data handling in chain of custody records

## Customization

### Switching Visual Themes

Orion-X includes two visual themes for different operational contexts:

1. Using the theme toggle script:
   ```bash
   /usr/bin/toggle-theme.sh
   ```

2. The script will:
   - Switch between dark/amber and green themes
   - Update terminal colors
   - Change the desktop wallpaper
   - Modify the bash prompt

3. Theme use guidelines:
   - Dark/amber theme: Default for normal operations
   - Green theme: Typically used for secure or root operations
   - Visual distinction helps prevent accidental execution of commands in the wrong context

### Customizing Terminal Environment

You can customize the terminal for your workflow:

1. Edit your bash configuration:
   ```bash
   nano ~/.bashrc
   ```

2. Add custom aliases for common commands:
   ```bash
   # Add to ~/.bashrc
   alias ll='ls -la'
   alias memcheck='free -h'
   alias netcheck='ip a && ping -c 4 1.1.1.1'
   ```

3. Create custom functions:
   ```bash
   # Add to ~/.bashrc
   function analyze() {
     python3 /usr/bin/artifact-analyzer.py "$1" -o "./analysis_results"
   }
   ```

4. Set custom environment variables:
   ```bash
   # Add to ~/.bashrc
   export CASE_ID="CASE-2025-001"
   export INVESTIGATOR="Your Name"
   ```

5. Source the updated configuration:
   ```bash
   source ~/.bashrc
   ```

### Adding Custom Tools

You can extend Orion-X with additional tools:

1. Install additional packages:
   ```bash
   sudo apt update
   sudo apt install package-name
   ```

2. Install Python packages:
   ```bash
   pip3 install --user package-name
   ```

3. Download and compile tools:
   ```bash
   git clone https://github.com/example/tool.git
   cd tool
   make
   sudo make install
   ```

4. Add custom scripts to your path:
   ```bash
   mkdir -p ~/bin
   cp your-script.sh ~/bin/
   chmod +x ~/bin/your-script.sh
   
   # Add to ~/.bashrc
   export PATH="$HOME/bin:$PATH"
   ```

5. Create desktop shortcuts for frequently used tools:
   ```bash
   # Create a .desktop file
   cat > ~/Desktop/custom-tool.desktop << EOF
   [Desktop Entry]
   Name=Custom Tool
   Comment=Description of your tool
   Exec=/path/to/your-tool
   Icon=utilities-terminal
   Terminal=false
   Type=Application
   Categories=Utility;
   EOF
   
   chmod +x ~/Desktop/custom-tool.desktop
   ```

## Sample Data

### Working with PCAP Samples

Orion-X includes network traffic samples for analysis practice:

1. Location of sample PCAPs:
   ```
   /opt/orionx/samples/pcaps/
   ```

2. Password for encrypted samples:
   - Standard password: "infected"

3. Analyzing sample PCAPs:
   ```bash
   # Using Wireshark
   wireshark /opt/orionx/samples/pcaps/2025-01-22-traffic-analysis-exercise.pcap
   
   # Using tshark
   tshark -r /opt/orionx/samples/pcaps/2025-01-22-traffic-analysis-exercise.pcap -Y "http"
   ```

4. Extracting files from PCAPs:
   ```bash
   # Extract all HTTP objects
   tshark -r /opt/orionx/samples/pcaps/2025-01-22-traffic-analysis-exercise.pcap --export-objects http,./extracted_files
   ```

5. Practice exercises:
   - Identify malicious domains and IPs
   - Extract payloads and analyze them
   - Reconstruct the attack timeline
   - Identify lateral movement attempts

### Memory Dump Analysis

Practice memory forensics with included samples:

1. Location of memory dumps:
   ```
   /opt/orionx/samples/memory/
   ```

2. Password for compressed files:
   - Standard password: "orionx"

3. Analyzing memory dumps:
   ```bash
   # Using Volatility
   vol -f /opt/orionx/samples/memory/magnet-forensics-ctf-2020.raw windows.info
   
   # Using the artifact analyzer
   python3 /usr/bin/artifact-analyzer.py /opt/orionx/samples/memory/magnet-forensics-ctf-2020.raw
   ```

4. Practice exercises:
   - Find hidden or injected processes
   - Analyze network connections
   - Extract authentication artifacts
   - Recover browser history from memory
   - Identify persistence mechanisms

### Firmware Analysis

Analyze IoT firmware samples:

1. Location of firmware samples:
   ```
   /opt/orionx/samples/firmware/
   ```

2. Basic firmware analysis:
   ```bash
   # Identify firmware components
   binwalk /opt/orionx/samples/firmware/openwrt-19.07-archer.bin
   
   # Extract firmware contents
   binwalk -e /opt/orionx/samples/firmware/openwrt-19.07-archer.bin
   ```

3. Detailed firmware exploration:
   ```bash
   # Extract filesystem
   firmware-mod-kit/extract-firmware.sh /opt/orionx/samples/firmware/openwrt-19.07-archer.bin
   
   # Navigate extracted filesystem
   cd fmk/rootfs
   ```

4. Practice exercises:
   - Locate hardcoded credentials
   - Identify outdated libraries with vulnerabilities
   - Find insecure configuration defaults
   - Examine startup scripts for security issues

### Log File Examples

Practice log analysis with sample datasets:

1. Location of log samples:
   ```
   /opt/orionx/samples/logs/
   ```

2. Analyzing various log types:
   ```bash
   # SSH intrusion logs
   less /opt/orionx/samples/logs/linux-ssh-intrusion.log
   
   # Honeypot logs
   jq '.' /opt/orionx/samples/logs/cowrie/cowrie.json
   
   # Web attack logs
   grep "' OR '1'='1" /opt/orionx/samples/logs/web-attacks/access.log
   ```

3. Creating timelines from logs:
   ```bash
   # Generate timeline from multiple logs
   python3 /usr/bin/storyboard-gen.py -i /opt/orionx/samples/logs/ -o attack_timeline.html
   ```

4. Practice exercises:
   - Identify attacker IP addresses and techniques
   - Trace the progression of an attack
   - Correlate events across multiple log sources
   - Extract indicators of compromise

## Troubleshooting

### Boot Issues

If you encounter problems booting Orion-X:

1. **USB not recognized as bootable**
   - Verify the ISO was written correctly to the USB
   - Try recreating the bootable media with a different tool
   - Check BIOS/UEFI settings for boot order and USB boot support
   - Try a different USB port (preferably USB 2.0)

2. **Black screen after boot selection**
   - Try booting with the "Safe Mode" option
   - Add kernel parameters: Press 'e' at the boot menu and add `nomodeset` or `acpi=off`
   - Check if your GPU is compatible with the included drivers

3. **System freezes during boot**
   - Try the "Safe Mode" option to use minimal drivers
   - Add `noapic` or `irqpoll` kernel parameters
   - Disable hardware in BIOS/UEFI that might be causing conflicts

4. **"Invalid signature" with Secure Boot**
   - Temporarily disable Secure Boot in BIOS/UEFI
   - If Secure Boot is required, build a custom ISO with signed bootloader

### Network Connectivity

For network connection issues:

1. **Wired network not working**
   - Check physical connection (cable and port LEDs)
   - Verify interface status:
     ```bash
     ip a
     ```
   - Try forcing a connection:
     ```bash
     sudo dhclient eth0
     ```
   - Check for hardware blocking:
     ```bash
     sudo rfkill list
     ```

2. **Wireless network not working**
   - Verify wireless hardware is detected:
     ```bash
     lspci | grep -i wireless
     ```
   - Check if the interface is up:
     ```bash
     ip a
     ```
   - Scan for networks:
     ```bash
     sudo iwlist wlan0 scan
     ```
   - Ensure drivers are loaded:
     ```bash
     lsmod | grep wifi
     ```

3. **DNS resolution issues**
   - Test DNS resolution:
     ```bash
     nslookup example.com
     ```
   - Check current DNS configuration:
     ```bash
     cat /etc/resolv.conf
     ```
   - Set alternative DNS servers:
     ```bash
     echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
     ```

### VPN Troubleshooting

If experiencing VPN connection issues:

1. **WireGuard connection fails**
   - Check WireGuard configuration:
     ```bash
     cat /etc/wireguard/orionx.conf
     ```
   - Verify server endpoint is reachable:
     ```bash
     ping -c 4 [server-ip]
     ```
   - Ensure the local interface is up:
     ```bash
     ip a
     ```
   - Check WireGuard logs:
     ```bash
     journalctl -xeu wg-quick@orionx
     ```

2. **VPN connected but no traffic**
   - Verify routing table:
     ```bash
     ip route
     ```
   - Check firewall rules:
     ```bash
     sudo iptables -L
     ```
   - Test connection to internal resources:
     ```bash
     ping -c 4 [internal-resource-ip]
     ```
   - Verify DNS resolution through VPN:
     ```bash
     nslookup internal.example.com
     ```

3. **Lost connection to VPN**
   - Restart the VPN connection:
     ```bash
     sudo wg-quick down orionx
     sudo wg-quick up orionx
     ```
   - Regenerate the configuration:
     ```bash
     sudo setup-vpn.sh
     ```
   - Check for network changes that might affect connection

### Matrix Connection Issues

For problems with Matrix communication:

1. **Cannot connect to Matrix server**
   - Verify the server URL:
     ```bash
     cat /etc/element-desktop/config.json
     ```
   - Check if the server is reachable:
     ```bash
     curl -I [matrix-server-url]
     ```
   - Look for SSL/TLS certificate issues:
     ```bash
     curl -vI [matrix-server-url]
     ```

2. **Authentication failures**
   - Verify your Matrix ID and password
   - Check for typing errors in your user ID
   - Reset your client configuration:
     ```bash
     rm -rf ~/.config/Element
     sudo setup-matrix.sh
     ```

3. **Local Matrix server issues**
   - Check server status:
     ```bash
     sudo systemctl status matrix-synapse
     ```
   - Review server logs:
     ```bash
     sudo journalctl -u matrix-synapse
     ```
   - Restart the service:
     ```bash
     sudo systemctl restart matrix-synapse
     ```

### Tool Execution Problems

When experiencing issues with specific tools:

1. **Command not found errors**
   - Verify the tool is installed:
     ```bash
     which [command]
     ```
   - Check if the tool is in your PATH:
     ```bash
     echo $PATH
     ```
   - Try using the full path to the command:
     ```bash
     /usr/bin/[command]
     ```

2. **Permission denied errors**
   - Try running with sudo:
     ```bash
     sudo [command]
     ```
   - Check file permissions:
     ```bash
     ls -la [file-or-directory]
     ```
   - Ensure scripts are executable:
     ```bash
     chmod +x [script-file]
     ```

3. **Python script errors**
   - Check Python version:
     ```bash
     python3 --version
     ```
   - Verify required packages are installed:
     ```bash
     pip3 list | grep [package-name]
     ```
   - Look for syntax errors in custom scripts:
     ```bash
     python3 -m py_compile [script-file]
     ```

4. **Disk space issues**
   - Check available space:
     ```bash
     df -h
     ```
   - Find large files:
     ```bash
     sudo find / -type f -size +100M
     ```
   - Clean temporary files:
     ```bash
     sudo rm -rf /tmp/*
     ```

## Appendices

### Command Reference

Quick reference for commonly used commands:

```
# System Information
uname -a                       # System and kernel information
lsblk                          # List block devices
df -h                          # Disk usage
free -h                        # Memory usage
lspci                          # List PCI devices
ip a                           # Network interfaces

# Forensic Acquisition
dd if=/dev/sdX of=disk.img     # Create disk image
avml output.raw                # Acquire memory
ewfacquire /dev/sdX            # Create E01 image
tcpdump -i eth0 -w capture.pcap # Capture network traffic

# Analysis Tools
vol -f memory.raw windows.info # Volatility framework
mmls disk.img                  # List partitions
fls -o 2048 disk.img           # List files in filesystem
tshark -r capture.pcap         # Analyze network capture
grep -i "error" logfile.log    # Search log files

# Orion-X Scripts
setup-vpn.sh                   # Configure WireGuard VPN
setup-matrix.sh                # Set up Matrix communication
toggle-theme.sh                # Switch visual themes
run-lynis.sh                   # Run security audit
artifact-analyzer.py           # Automated artifact analysis
storyboard-gen.py              # Create event timeline

# Networking
ping -c 4 example.com          # Test connectivity
traceroute example.com         # Trace network path
nslookup example.com           # DNS lookup
wg show                        # Show WireGuard status
curl -I example.com            # HTTP header request

# File Operations
sha256sum file                 # Calculate SHA-256 hash
mount /dev/sdX1 /mnt           # Mount a filesystem
umount /mnt                    # Unmount a filesystem
tar czf archive.tar.gz dir/    # Create compressed archive
cryptsetup luksOpen file enc   # Open encrypted container
```

### File Locations

Important file locations within Orion-X:

```
# System Files
/boot/vmlinuz                  # Linux kernel
/etc/fstab                     # Filesystem configuration
/etc/wireguard/                # WireGuard VPN configuration
/etc/matrix-synapse/           # Matrix server configuration
/etc/element-desktop/          # Element client configuration
/var/log/                      # System logs
/var/log/orionx/               # Orion-X specific logs

# Orion-X Files
/usr/bin/                      # Orion-X scripts and tools
/usr/share/doc/orionx/         # Documentation
/usr/share/orionx/theme/       # Theme assets (wallpapers, etc.)
/opt/orionx/samples/           # Sample data for analysis

# User Files
/home/orionx/                  # User home directory
/home/orionx/.bashrc           # Bash configuration
/home/orionx/.config/          # Application configurations
/home/orionx/Desktop/          # Desktop shortcuts
/home/orionx/Analysis/         # Default location for analysis
```

### Keyboard Shortcuts

Keyboard shortcuts for improved efficiency:

```
# Terminal Shortcuts
Ctrl+Alt+T                     # Open terminal
Ctrl+Shift+T                   # New terminal tab
Ctrl+C                         # Interrupt current command
Ctrl+L                         # Clear terminal screen
Ctrl+R                         # Search command history
Tab                            # Auto-complete command or path
!!                             # Repeat last command
Ctrl+A/E                       # Move to start/end of line

# Desktop Environment
Alt+Tab                        # Switch between windows
Alt+F4                         # Close current window
Ctrl+Alt+L                     # Lock screen
Print Screen                   # Take screenshot
Alt+F2                         # Run command dialog
Ctrl+Alt+Arrow                 # Switch workspace

# Text Editors
Ctrl+S                         # Save file
Ctrl+O                         # Open file
Ctrl+F                         # Find text
Ctrl+G                         # Go to line
Ctrl+Z                         # Undo action
Ctrl+Shift+Z/Ctrl+Y            # Redo action

# Wireshark
Ctrl+/                         # Apply display filter
Ctrl+.,                        # Go to next/previous packet
Ctrl+B                         # Start/stop capture
Ctrl+E                         # Export packet dissections
```

---

This User Guide provides a comprehensive overview of Orion-X Phoenix Edition v1.5.5. For further assistance or to report issues, please contact the Orion-X support team or consult the official project repository.
