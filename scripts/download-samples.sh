#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-FORENSIC-003
# @title download-samples.sh follows setup-matrix.sh CLI pattern
# @status accepted
# @rationale Consistent project conventions from Phase 3-4. CLI arguments
#   enable automated/scripted deployment. --offline mode generates synthetic
#   data locally for air-gapped environments.
#
# Orion-X Phoenix Edition v2.0.0 — Download / generate forensic sample datasets
#
# Downloads sample forensic data (PCAPs, memory dumps, firmware, logs) for
# analysis training and tool validation. In air-gapped environments, use
# --offline to generate synthetic data locally without network access.
#
# Usage: download-samples.sh [options]
#
# Options:
#   --samples-dir DIR     Target directory (default: data/samples)
#   --offline             Generate synthetic data locally (no downloads)
#   --validate-urls       Check HTTP status of all download URLs
#   --checksums           Verify SHA-256 checksums after download
#   --help, -h            Show this help

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SAMPLES_DIR="data/samples"
OFFLINE=false
VALIDATE_URLS=false
VERIFY_CHECKSUMS=false

# Download URLs (used in online mode and --validate-urls)
declare -a DOWNLOAD_URLS=(
    "https://download.netresec.com/pcap/maccdc-2012/maccdc2012_00000.pcap"
    "https://github.com/sbousseaden/PCAP-ATTACK/raw/master/Discovery/dns_local_lookup.pcap"
)

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
    cat <<'HELPTEXT'
Usage: download-samples.sh [options]

Download or generate forensic sample datasets for Orion-X.

Options:
  --samples-dir DIR     Target directory (default: data/samples)
  --offline             Generate synthetic data locally (no downloads)
  --validate-urls       Check HTTP status of all download URLs
  --checksums           Verify SHA-256 checksums after download
  --help, -h            Show this help

Modes:
  Default (no flags):   Download sample data from public sources
  --offline:            Generate minimal synthetic data locally (air-gapped)
  --validate-urls:      Check HTTP reachability of download URLs
  --checksums:          Verify SHA-256 checksums against SHA256SUMS file

Examples:
  download-samples.sh --offline --samples-dir /evidence/samples
  download-samples.sh --validate-urls
  download-samples.sh --checksums
HELPTEXT
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# ---------------------------------------------------------------------------
# CLI argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --samples-dir)
                if [[ $# -lt 2 ]]; then
                    log_error "--samples-dir requires a directory argument"
                    exit 1
                fi
                SAMPLES_DIR="$2"
                shift 2
                ;;
            --offline)
                OFFLINE=true
                shift
                ;;
            --validate-urls)
                VALIDATE_URLS=true
                shift
                ;;
            --checksums)
                VERIFY_CHECKSUMS=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Validate URLs (--validate-urls)
# ---------------------------------------------------------------------------
validate_urls() {
    log "Validating download URLs..."
    local url status failures=0
    for url in "${DOWNLOAD_URLS[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            status=$(curl -o /dev/null -s -w '%{http_code}' --head --max-time 10 "$url" 2>/dev/null || echo "timeout")
        else
            log_error "curl not found — cannot validate URLs"
            return 1
        fi
        if [[ "$status" == "200" ]]; then
            log "  OK  ($status): $url"
        else
            log "  FAIL ($status): $url"
            ((failures++))
        fi
    done
    if [[ $failures -gt 0 ]]; then
        log "$failures URL(s) failed validation"
        return 1
    fi
    log "All URLs validated successfully"
    return 0
}

# ---------------------------------------------------------------------------
# Verify checksums (--checksums)
# ---------------------------------------------------------------------------
verify_checksums() {
    local sums_file="$SAMPLES_DIR/SHA256SUMS"
    if [[ ! -f "$sums_file" ]]; then
        log_error "SHA256SUMS file not found at $sums_file"
        return 1
    fi
    log "Verifying SHA-256 checksums from $sums_file..."

    local failures=0 checked=0 line expected_hash filepath
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        expected_hash="${line%% *}"
        # SHA256SUMS uses two-space separator: "hash  filename"
        filepath="${line#*  }"
        local full_path="$SAMPLES_DIR/$filepath"

        if [[ ! -f "$full_path" ]]; then
            log "  MISSING: $filepath"
            ((failures++))
            ((checked++))
            continue
        fi

        local actual_hash
        if command -v shasum >/dev/null 2>&1; then
            actual_hash=$(shasum -a 256 "$full_path" | cut -d' ' -f1)
        elif command -v sha256sum >/dev/null 2>&1; then
            actual_hash=$(sha256sum "$full_path" | cut -d' ' -f1)
        else
            log_error "Neither shasum nor sha256sum found"
            return 1
        fi

        if [[ "$actual_hash" == "$expected_hash" ]]; then
            log "  OK: $filepath"
        else
            log "  MISMATCH: $filepath"
            log "    expected: $expected_hash"
            log "    actual:   $actual_hash"
            ((failures++))
        fi
        ((checked++))
    done < "$sums_file"

    if [[ $checked -eq 0 ]]; then
        log_error "No entries found in SHA256SUMS"
        return 1
    fi
    if [[ $failures -gt 0 ]]; then
        log "$failures of $checked file(s) failed checksum verification"
        return 1
    fi
    log "All $checked file(s) verified successfully"
    return 0
}

# ---------------------------------------------------------------------------
# Generate synthetic PCAP
# ---------------------------------------------------------------------------
generate_synthetic_pcap() {
    local dir="$1"
    mkdir -p "$dir"

    log "Generating synthetic PCAP sample..."
    # Minimal valid PCAP file header (24 bytes) + one packet
    # PCAP magic: 0xd4c3b2a1, version 2.4, snaplen 65535, network ethernet
    python3 -c "
import struct, sys
# PCAP global header
header = struct.pack('<IHHiIII',
    0xa1b2c3d4,  # magic
    2, 4,        # version
    0,           # timezone
    0,           # sigfigs
    65535,       # snaplen
    1            # network (ethernet)
)
# One dummy ethernet frame (14 bytes eth + 20 bytes IP + 8 bytes payload)
frame = b'\\xff' * 6 + b'\\x00' * 6 + b'\\x08\\x00'  # eth header
frame += b'\\x45\\x00\\x00\\x1c' + b'\\x00' * 16       # minimal IP header
# Packet header: ts_sec, ts_usec, incl_len, orig_len
pkt_hdr = struct.pack('<IIII', 1705300000, 0, len(frame), len(frame))
sys.stdout.buffer.write(header + pkt_hdr + frame)
" > "$dir/synthetic-traffic.pcap"

    cat > "$dir/README.txt" << 'EOF'
PCAP Files Collection - Orion-X Phoenix Edition v2.0.0
======================================================

This directory contains packet capture files for forensic analysis
training and tool validation.

SYNTHETIC SAMPLES:
-----------------
synthetic-traffic.pcap — Minimal valid PCAP with a single dummy frame.
Generated by --offline mode for air-gapped environments.

USAGE:
------
These PCAPs can be analyzed using:
- Wireshark or TShark
- artifact-analyzer.py (with --type network flag)
- Zeek/Bro for protocol analysis
- Suricata IDS for alert generation

WARNING:
--------
In production use, this directory may contain PCAPs from actual malware
traffic. Handle with care. Do not execute extracted binaries.
EOF
    log "Created synthetic PCAP: $dir/synthetic-traffic.pcap"
}

# ---------------------------------------------------------------------------
# Generate synthetic memory dump
# ---------------------------------------------------------------------------
generate_synthetic_memory() {
    local dir="$1"
    mkdir -p "$dir"

    log "Generating synthetic memory sample..."
    # Create a small synthetic memory dump with recognizable patterns
    python3 -c "
import sys
# Start with a PAGE_SIZE-aligned block containing recognizable strings
data = bytearray(4096)
# Write some process-like strings at known offsets
strings = [
    (0, b'PAGESIZE4K'),
    (64, b'cmd.exe\x00'),
    (128, b'svchost.exe\x00'),
    (256, b'\\x4d\\x5a'),  # MZ header signature
    (512, b'This program cannot be run in DOS mode'),
    (1024, b'KERNEL32.DLL\x00'),
    (2048, b'ntdll.dll\x00'),
]
for offset, s in strings:
    data[offset:offset+len(s)] = s
sys.stdout.buffer.write(bytes(data))
" > "$dir/synthetic-memdump.raw"

    cat > "$dir/README.txt" << 'EOF'
Memory Dumps Collection - Orion-X Phoenix Edition v2.0.0
========================================================

This directory contains volatile memory images for forensic analysis
training and tool validation.

SYNTHETIC SAMPLES:
-----------------
synthetic-memdump.raw — 4KB synthetic memory image with recognizable
process artifacts (PE headers, DLL names). Generated by --offline mode.

USAGE:
------
Memory dumps can be analyzed using:
- Volatility 3: vol -f synthetic-memdump.raw windows.pslist
- artifact-analyzer.py: python3 artifact-analyzer.py synthetic-memdump.raw -t memory

NOTE: Synthetic samples are intentionally small. Real memory dumps
are typically 1-16 GB. The structures here are for tool validation only.
EOF
    log "Created synthetic memory sample: $dir/synthetic-memdump.raw"
}

# ---------------------------------------------------------------------------
# Generate synthetic firmware
# ---------------------------------------------------------------------------
generate_synthetic_firmware() {
    local dir="$1"
    mkdir -p "$dir"

    log "Generating synthetic firmware sample..."
    # Create a small binary with firmware-like markers
    python3 -c "
import sys
data = bytearray(512)
# ELF magic header
data[0:4] = b'\\x7fELF'
# Add some firmware-like strings
msg = b'Synthetic firmware for offline testing'
data[64:64+len(msg)] = msg
ver = b'OpenWrt 19.07-synthetic'
data[128:128+len(ver)] = ver
uboot = b'U-Boot 2021.01'
data[192:192+len(uboot)] = uboot
# Fill remainder with 0xff (typical flash pattern)
for i in range(256, 512):
    data[i] = 0xff
sys.stdout.buffer.write(bytes(data))
" > "$dir/synthetic-firmware.bin"

    cat > "$dir/README.txt" << 'EOF'
Firmware Images Collection - Orion-X Phoenix Edition v2.0.0
==========================================================

This directory contains firmware binary dumps for reverse engineering
and vulnerability analysis practice.

SYNTHETIC SAMPLES:
-----------------
synthetic-firmware.bin — 512-byte synthetic binary with ELF magic header
and firmware-like strings. Generated by --offline mode.

USAGE:
------
Firmware images can be analyzed using:
- Binwalk: binwalk synthetic-firmware.bin
- Ghidra: for deeper code analysis
- strings: strings synthetic-firmware.bin

IMPORTANT: Do not flash synthetic samples to actual hardware.
EOF
    log "Created synthetic firmware: $dir/synthetic-firmware.bin"
}

# ---------------------------------------------------------------------------
# Generate synthetic log samples
# ---------------------------------------------------------------------------
generate_synthetic_logs() {
    local dir="$1"
    mkdir -p "$dir"

    log "Generating synthetic log samples..."

    cat > "$dir/synthetic-syslog.log" << 'SYSLOG'
Jan 15 08:23:01 orionx-node-1 sshd[1234]: Accepted publickey for admin from 192.168.1.100 port 54321
Jan 15 08:23:05 orionx-node-1 kernel: [UFW BLOCK] IN=eth0 OUT= SRC=10.0.0.99 DST=10.0.0.1 PROTO=TCP DPT=4444
Jan 15 08:25:12 orionx-node-1 sudo: admin : TTY=pts/0 ; PWD=/home/admin ; COMMAND=/usr/bin/volatility3
Jan 15 08:30:00 orionx-node-1 cron[5678]: (root) CMD (/usr/bin/lynis audit system)
Jan 15 08:31:45 orionx-node-1 sshd[1234]: Failed password for root from 10.0.0.99 port 54322
Jan 15 08:31:46 orionx-node-1 sshd[1234]: Failed password for root from 10.0.0.99 port 54323
Jan 15 08:31:47 orionx-node-1 sshd[1234]: Failed password for root from 10.0.0.99 port 54324
Jan 15 08:32:00 orionx-node-1 kernel: [UFW BLOCK] IN=eth0 OUT= SRC=10.0.0.99 DST=10.0.0.1 PROTO=TCP DPT=22
Jan 15 08:35:00 orionx-node-1 orionx-mesh[9012]: Health check: 2 peers, 2 healthy, 0 stale
Jan 15 08:40:15 orionx-node-1 matrix-synapse[3456]: Processed request: GET /_matrix/client/versions
Jan 15 09:00:00 orionx-node-1 sshd[1234]: Accepted publickey for responder from 192.168.1.101 port 54325
Jan 15 09:15:30 orionx-node-1 kernel: [UFW ALLOW] IN=wg0 OUT= SRC=10.0.99.2 DST=10.0.99.1 PROTO=TCP DPT=8008
Jan 15 09:20:00 orionx-node-1 orionx-mesh[9012]: Discovered peer: orionx-node-2 (10.0.99.2) at 172.20.0.3
Jan 15 10:00:00 orionx-node-1 clamav[7890]: /tmp/suspicious.exe: Win.Trojan.Generic FOUND
Jan 15 10:05:00 orionx-node-1 orionx-mesh[9012]: Soft heal: refreshing endpoint for peer Ab3xK9m2
SYSLOG

    cat > "$dir/synthetic-events.json" << 'EVENTS_JSON'
[
  {"timestamp": "2025-01-15T08:23:01", "severity": "INFO", "source": "sshd", "message": "Accepted publickey for admin from 192.168.1.100"},
  {"timestamp": "2025-01-15T08:23:05", "severity": "WARNING", "source": "kernel", "message": "UFW BLOCK SRC=10.0.0.99 DST=10.0.0.1 DPT=4444"},
  {"timestamp": "2025-01-15T08:31:45", "severity": "ERROR", "source": "sshd", "message": "Failed password for root from 10.0.0.99"},
  {"timestamp": "2025-01-15T09:00:00", "severity": "INFO", "source": "sshd", "message": "Accepted publickey for responder from 192.168.1.101"},
  {"timestamp": "2025-01-15T10:00:00", "severity": "CRITICAL", "source": "clamav", "message": "Malware detected: Win.Trojan.Generic in /tmp/suspicious.exe"}
]
EVENTS_JSON

    cat > "$dir/synthetic-web-access.log" << 'WEBLOG'
192.0.2.123 - - [15/Jan/2025:03:12:18 +0000] "GET /admin HTTP/1.1" 404 196 "-" "Mozilla/5.0"
192.0.2.45 - - [15/Jan/2025:03:45:25 +0000] "GET /search.php?q=test'%20OR%20'1'='1 HTTP/1.1" 200 8721 "-" "Mozilla/5.0"
192.0.2.45 - - [15/Jan/2025:03:45:30 +0000] "GET /download.php?file=../../../etc/passwd HTTP/1.1" 403 1267 "-" "Mozilla/5.0"
WEBLOG

    cat > "$dir/README.txt" << 'EOF'
Log Files Collection - Orion-X Phoenix Edition v2.0.0
====================================================

This directory contains log files showing examples of attacks,
intrusions, and suspicious activities for log analysis training.

SYNTHETIC SAMPLES:
-----------------
synthetic-syslog.log      — Linux syslog with SSH brute-force, firewall blocks,
                            mesh health checks, and malware detection events.
synthetic-events.json     — Structured events in JSON format.
synthetic-web-access.log  — Apache access log with SQL injection and path
                            traversal attack attempts.

USAGE:
------
These logs can be analyzed using:
- Standard Unix tools: grep -i "failure" synthetic-syslog.log
- storyboard-gen.py: python3 storyboard-gen.py -i logs/ -o timeline.html
- artifact-analyzer.py: python3 artifact-analyzer.py synthetic-syslog.log -t log
EOF
    log "Created synthetic log samples in $dir/"
}

# ---------------------------------------------------------------------------
# Download PCAP samples (online mode)
# ---------------------------------------------------------------------------
download_pcaps() {
    local dir="$SAMPLES_DIR/pcaps"
    mkdir -p "$dir"

    log "Downloading PCAP samples..."

    local url="${DOWNLOAD_URLS[0]}"
    local target="$dir/maccdc2012_sample.pcap"

    if command -v wget >/dev/null 2>&1; then
        if ! wget -q -O "$target" "$url"; then
            log "Failed to download from primary source. Trying alternative..."
            url="${DOWNLOAD_URLS[1]}"
            target="$dir/dns_local_lookup.pcap"
            if ! wget -q -O "$target" "$url"; then
                log "Downloads failed. Use --offline for synthetic data."
                return 1
            fi
        fi
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -sL -o "$target" "$url"; then
            log "Failed to download from primary source. Trying alternative..."
            url="${DOWNLOAD_URLS[1]}"
            target="$dir/dns_local_lookup.pcap"
            if ! curl -sL -o "$target" "$url"; then
                log "Downloads failed. Use --offline for synthetic data."
                return 1
            fi
        fi
    else
        log_error "Neither wget nor curl found. Use --offline for synthetic data."
        return 1
    fi

    log "Downloaded PCAP sample: $target"
}

# ---------------------------------------------------------------------------
# Create memory sample placeholder (online mode)
#
# @decision DEC-PHASE11-017
# @title Sample data honesty: synthetic placeholder uses _SYNTHETIC suffix
# @status accepted
# @rationale P2-002 audit finding: operators downloading this file for the
#   first time may mistake the randomly-generated placeholder for real
#   forensic memory data. The _SYNTHETIC suffix and co-located README.txt
#   make the synthetic nature unambiguous at filesystem-level inspection.
#   Real memory dumps are 100 MB+ and legally encumbered; the placeholder
#   exists solely for tool-plumbing smoke-tests in air-gapped environments.
# ---------------------------------------------------------------------------
create_memory_sample() {
    local dir="$SAMPLES_DIR/memory"
    mkdir -p "$dir"

    log "Creating memory sample placeholder..."
    # Create a small placeholder — real memory dumps are too large for default download
    # File is named _SYNTHETIC to signal this is not real forensic data (DEC-PHASE11-017)
    python3 -c "
import sys
data = bytearray(5 * 1024 * 1024)  # 5 MB placeholder
data[0:4] = b'\\x4d\\x5a\\x90\\x00'  # MZ header
sys.stdout.buffer.write(bytes(data))
" > "$dir/mini_sample_SYNTHETIC.raw" 2>/dev/null || {
        # Fallback if python3 is not available
        dd if=/dev/urandom of="$dir/mini_sample_SYNTHETIC.raw" bs=1M count=5 2>/dev/null
    }
    log "Created memory sample: $dir/mini_sample_SYNTHETIC.raw"

    # Emit README so operators immediately understand the synthetic nature
    cat > "$dir/README.txt" << 'MEMREADME'
SYNTHETIC PLACEHOLDER — NOT REAL FORENSIC DATA

Files marked _SYNTHETIC in this directory are randomly-generated placeholders
used for tool-plumbing tests only. Real memory dumps, PCAPs, and forensic
artifacts must be sourced separately (e.g., from CTF challenges, live
incident captures, or open datasets like the Volatility sample-images
repository).

This limitation exists because real forensic datasets are large (100 MB+)
and legally-encumbered; the Orion-X ISO ships with air-gap-friendly
synthetic samples so first-boot operators can smoke-test toolchains
without an internet connection.
MEMREADME
    log "Created memory README.txt: $dir/README.txt"
}

# ---------------------------------------------------------------------------
# Create firmware sample placeholder (online mode)
# ---------------------------------------------------------------------------
create_firmware_sample() {
    local dir="$SAMPLES_DIR/firmware"
    mkdir -p "$dir"

    log "Creating firmware sample placeholder..."
    python3 -c "
import sys
data = bytearray(2 * 1024 * 1024)  # 2 MB placeholder
data[0:4] = b'\\x7fELF'
msg = b'OpenWrt firmware placeholder'
data[64:64+len(msg)] = msg
sys.stdout.buffer.write(bytes(data))
" > "$dir/sample_firmware.bin" 2>/dev/null || {
        dd if=/dev/urandom of="$dir/sample_firmware.bin" bs=1M count=2 2>/dev/null
    }
    log "Created firmware sample: $dir/sample_firmware.bin"
}

# ---------------------------------------------------------------------------
# Create log samples (online mode — same as offline, logs are always synthetic)
# ---------------------------------------------------------------------------
create_log_samples() {
    generate_synthetic_logs "$SAMPLES_DIR/logs"
}

# ---------------------------------------------------------------------------
# Offline mode: generate all synthetic data locally
# ---------------------------------------------------------------------------
run_offline() {
    log "Running in offline mode — generating synthetic data in $SAMPLES_DIR"
    mkdir -p "$SAMPLES_DIR"

    generate_synthetic_pcap "$SAMPLES_DIR/pcaps"
    generate_synthetic_memory "$SAMPLES_DIR/memory"
    generate_synthetic_firmware "$SAMPLES_DIR/firmware"
    generate_synthetic_logs "$SAMPLES_DIR/logs"

    log "Offline sample generation completed in $SAMPLES_DIR"
}

# ---------------------------------------------------------------------------
# Online mode: download / create all samples
# ---------------------------------------------------------------------------
run_online() {
    log "Starting sample data download for Orion-X Phoenix Edition v2.0.0"
    mkdir -p "$SAMPLES_DIR"

    download_pcaps || log "PCAP download failed — continuing with other samples"
    create_memory_sample
    create_firmware_sample
    create_log_samples

    log "Sample data download/creation completed in $SAMPLES_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Handle --validate-urls (can run independently)
    if [[ "$VALIDATE_URLS" == true ]]; then
        validate_urls
        exit $?
    fi

    # Handle --checksums (can run independently)
    if [[ "$VERIFY_CHECKSUMS" == true ]]; then
        verify_checksums
        exit $?
    fi

    # Handle --offline vs default online mode
    if [[ "$OFFLINE" == true ]]; then
        run_offline
    else
        run_online
    fi

    echo "Sample data is available in $SAMPLES_DIR"
    echo "Use these samples with the Orion-X analysis tools."
}

main "$@"
