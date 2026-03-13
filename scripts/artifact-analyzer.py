#!/usr/bin/env python3
"""
Orion-X Phoenix Edition — Artifact Analyzer
============================================
Automates triage of collected forensic artifacts (network captures, memory
dumps, disk images, log files) to speed up the incident responder's workflow.

Usage:
    artifact-analyzer.py <artifact> [-o <output_dir>] [-t <type>] [--upload]

Rationale:
    Wraps Volatility, tshark, zeek, TSK and bulk_extractor behind a unified
    CLI so analysts do not need to remember per-tool invocation syntax.
    Produces a chain-of-custody document alongside every analysis run.

@decision DEC-003 [BOOTSTRAP]
@title Phase 1 bootstrap — copy with targeted bug fixes
@status accepted
@rationale Bare except: clauses replaced with typed exceptions; file(1)
           failure is a non-fatal fallback so CalledProcessError is caught
           and logged at DEBUG rather than silently swallowed.
"""
#
# Orion-X Phoenix Edition v1.5.5
# Artifact Analyzer Script
#
# This script automates the analysis of collected artifacts (network captures,
# memory dumps, disk images, etc.) to speed up the responder's workflow.

import os
import sys
import argparse
import subprocess
import logging
import json
import hashlib
import datetime
import shutil
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("/var/log/orionx/artifact_analyzer.log"),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("orionx-artifact-analyzer")

# Define artifact types and tools
ARTIFACT_TYPES = {
    "memory": {
        "extensions": [".raw", ".dmp", ".mem", ".vmem"],
        "tools": {
            "volatility": {
                "cmd": "vol",
                "plugins": ["pslist", "psscan", "netscan", "malfind", "cmdline", "shellbags", "timeliner"]
            }
        }
    },
    "disk": {
        "extensions": [".dd", ".img", ".001", ".e01"],
        "tools": {
            "tsk": {
                "cmd": "tsk_recover",
                "params": "-a"
            },
            "bulk_extractor": {
                "cmd": "bulk_extractor",
                "params": "-o {output_dir}"
            }
        }
    },
    "network": {
        "extensions": [".pcap", ".pcapng", ".cap"],
        "tools": {
            "tshark": {
                "cmd": "tshark",
                "filters": [
                    "-Y \"http\"",
                    "-Y \"dns\"",
                    "-Y \"ip.addr==10.0.0.0/8 || ip.addr==172.16.0.0/12 || ip.addr==192.168.0.0/16\""
                ]
            },
            "zeek": {
                "cmd": "zeek",
                "params": "-r"
            }
        }
    },
    "log": {
        "extensions": [".log", ".evt", ".evtx"],
        "tools": {
            "grep": {
                "cmd": "grep",
                "patterns": [
                    "error", "failed", "warning", "critical", "exploit", "malware", 
                    "suspicious", "backdoor", "unauthorized", "refused", "blocked"
                ]
            }
        }
    }
}

def identify_artifact_type(filename):
    """Determine the artifact type based on file extension."""
    file_ext = os.path.splitext(filename)[1].lower()
    
    for artifact_type, info in ARTIFACT_TYPES.items():
        if file_ext in info["extensions"]:
            return artifact_type
    
    # Try to identify by file command if extension doesn't match
    try:
        file_output = subprocess.check_output(["file", filename]).decode("utf-8").lower()
        if "pcap" in file_output:
            return "network"
        elif "memory" in file_output or "dump" in file_output:
            return "memory"
        elif "filesystem" in file_output or "disk" in file_output:
            return "disk"
    except subprocess.CalledProcessError:
        # @defprog-exempt: fallback type detection — `file` command unavailable is non-fatal
        logger.debug("file(1) unavailable or returned non-zero; artifact type remains unknown")

    return "unknown"

def calculate_hash(filename):
    """Calculate SHA-256 hash of a file."""
    sha256_hash = hashlib.sha256()
    
    with open(filename, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    
    return sha256_hash.hexdigest()

def check_tools_availability(tools):
    """Check if required tools are installed."""
    missing_tools = []
    
    for tool, info in tools.items():
        cmd = info["cmd"]
        if shutil.which(cmd) is None:
            missing_tools.append(cmd)
    
    return missing_tools

def analyze_memory_dump(filename, output_dir):
    """Analyze a memory dump using Volatility."""
    logger.info(f"Analyzing memory dump: {filename}")
    
    tools = ARTIFACT_TYPES["memory"]["tools"]
    missing_tools = check_tools_availability(tools)
    
    if missing_tools:
        logger.error(f"Missing required tools: {', '.join(missing_tools)}")
        logger.error("Please install Volatility using: pip install volatility3")
        return False
    
    # Create output directory for Volatility results
    vol_output_dir = os.path.join(output_dir, "volatility_results")
    os.makedirs(vol_output_dir, exist_ok=True)
    
    # Run Volatility plugins
    vol_plugins = tools["volatility"]["plugins"]
    success = True
    
    for plugin in vol_plugins:
        plugin_output_file = os.path.join(vol_output_dir, f"{plugin}.txt")
        logger.info(f"Running Volatility plugin: {plugin}")
        
        try:
            with open(plugin_output_file, "w") as outfile:
                subprocess.run(
                    ["vol", "-f", filename, plugin],
                    stdout=outfile,
                    stderr=subprocess.PIPE,
                    check=True
                )
            logger.info(f"Saved {plugin} results to {plugin_output_file}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Error running Volatility plugin {plugin}: {e}")
            success = False
    
    # Generate a summary report
    summary_file = os.path.join(output_dir, "memory_analysis_summary.txt")
    with open(summary_file, "w") as f:
        f.write(f"Memory Analysis Summary for {os.path.basename(filename)}\n")
        f.write(f"Generated on: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        
        # Process results
        if os.path.exists(os.path.join(vol_output_dir, "pslist.txt")):
            f.write("== Notable Processes ==\n")
            with open(os.path.join(vol_output_dir, "pslist.txt"), "r") as pslist:
                for line in pslist:
                    if any(suspicious in line.lower() for suspicious in ["cmd.exe", "powershell.exe", "svchost.exe", "rundll32.exe"]):
                        f.write(f"  {line.strip()}\n")
            f.write("\n")
        
        if os.path.exists(os.path.join(vol_output_dir, "netscan.txt")):
            f.write("== Network Connections ==\n")
            with open(os.path.join(vol_output_dir, "netscan.txt"), "r") as netscan:
                for line in netscan:
                    if "ESTABLISHED" in line or "LISTENING" in line:
                        f.write(f"  {line.strip()}\n")
            f.write("\n")
        
        if os.path.exists(os.path.join(vol_output_dir, "malfind.txt")):
            f.write("== Potential Malware Found ==\n")
            with open(os.path.join(vol_output_dir, "malfind.txt"), "r") as malfind:
                f.write(f"  Malfind found potential malicious code. See full report in {vol_output_dir}/malfind.txt\n")
            f.write("\n")
    
    logger.info(f"Memory analysis complete. Summary saved to {summary_file}")
    return success

def analyze_network_capture(filename, output_dir):
    """Analyze a network capture file using tshark and zeek."""
    logger.info(f"Analyzing network capture: {filename}")
    
    tools = ARTIFACT_TYPES["network"]["tools"]
    missing_tools = check_tools_availability(tools)
    
    if missing_tools:
        logger.error(f"Missing required tools: {', '.join(missing_tools)}")
        logger.error("Please install tshark and/or zeek.")
        return False
    
    # Create output directory for network analysis
    net_output_dir = os.path.join(output_dir, "network_analysis")
    os.makedirs(net_output_dir, exist_ok=True)
    
    # Run tshark with different filters
    if "tshark" not in missing_tools:
        tshark_output_dir = os.path.join(net_output_dir, "tshark")
        os.makedirs(tshark_output_dir, exist_ok=True)
        
        for filter_expr in tools["tshark"]["filters"]:
            filter_name = filter_expr.replace("-Y ", "").replace("\"", "").replace(" ", "_")
            output_file = os.path.join(tshark_output_dir, f"{filter_name}.txt")
            
            try:
                command = f"tshark -r {filename} {filter_expr} > {output_file}"
                subprocess.run(command, shell=True, check=True)
                logger.info(f"Saved tshark filter {filter_name} results to {output_file}")
            except subprocess.CalledProcessError as e:
                logger.error(f"Error running tshark with filter {filter_expr}: {e}")
    
    # Run zeek for protocol analysis
    if "zeek" not in missing_tools:
        zeek_output_dir = os.path.join(net_output_dir, "zeek")
        os.makedirs(zeek_output_dir, exist_ok=True)
        
        try:
            subprocess.run(
                ["zeek", "-r", filename, "-C", "-o", zeek_output_dir],
                check=True
            )
            logger.info(f"Saved zeek results to {zeek_output_dir}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Error running zeek: {e}")
    
    # Generate summary report
    summary_file = os.path.join(output_dir, "network_analysis_summary.txt")
    with open(summary_file, "w") as f:
        f.write(f"Network Analysis Summary for {os.path.basename(filename)}\n")
        f.write(f"Generated on: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        
        # Extract interesting traffic
        f.write("== HTTP Traffic ==\n")
        http_file = os.path.join(tshark_output_dir, "http.txt")
        if os.path.exists(http_file):
            with open(http_file, "r") as http:
                for line in http:
                    if "POST" in line or "GET" in line:
                        f.write(f"  {line.strip()}\n")
        f.write("\n")
        
        f.write("== DNS Traffic ==\n")
        dns_file = os.path.join(tshark_output_dir, "dns.txt")
        if os.path.exists(dns_file):
            domains = set()
            with open(dns_file, "r") as dns:
                for line in dns:
                    if "A?" in line:
                        domain = line.split("A? ")[1].split(" ")[0]
                        domains.add(domain)
            
            for domain in sorted(domains):
                f.write(f"  {domain}\n")
        f.write("\n")
    
    logger.info(f"Network analysis complete. Summary saved to {summary_file}")
    return True

def analyze_disk_image(filename, output_dir):
    """Analyze a disk image using TSK tools and bulk_extractor."""
    logger.info(f"Analyzing disk image: {filename}")
    
    tools = ARTIFACT_TYPES["disk"]["tools"]
    missing_tools = check_tools_availability(tools)
    
    if missing_tools:
        logger.error(f"Missing required tools: {', '.join(missing_tools)}")
        if "tsk_recover" in missing_tools:
            logger.error("Please install The Sleuth Kit (TSK) package.")
        if "bulk_extractor" in missing_tools:
            logger.error("Please install bulk_extractor package.")
        return False
    
    # Create output directory for disk analysis
    disk_output_dir = os.path.join(output_dir, "disk_analysis")
    os.makedirs(disk_output_dir, exist_ok=True)
    
    # Recover files using TSK if available
    if "tsk_recover" not in missing_tools:
        tsk_output_dir = os.path.join(disk_output_dir, "recovered_files")
        os.makedirs(tsk_output_dir, exist_ok=True)
        
        try:
            subprocess.run(
                ["tsk_recover", filename, tsk_output_dir],
                check=True
            )
            logger.info(f"Recovered files saved to {tsk_output_dir}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Error recovering files: {e}")
    
    # Run bulk_extractor if available
    if "bulk_extractor" not in missing_tools:
        bulk_output_dir = os.path.join(disk_output_dir, "bulk_extractor")
        os.makedirs(bulk_output_dir, exist_ok=True)
        
        try:
            subprocess.run(
                ["bulk_extractor", "-o", bulk_output_dir, filename],
                check=True
            )
            logger.info(f"Bulk extractor results saved to {bulk_output_dir}")
        except subprocess.CalledProcessError as e:
            logger.error(f"Error running bulk_extractor: {e}")
    
    # Generate summary report
    summary_file = os.path.join(output_dir, "disk_analysis_summary.txt")
    with open(summary_file, "w") as f:
        f.write(f"Disk Analysis Summary for {os.path.basename(filename)}\n")
        f.write(f"Generated on: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        
        # Summarize recovered files
        tsk_output_dir = os.path.join(disk_output_dir, "recovered_files")
        if os.path.exists(tsk_output_dir):
            file_count = sum(1 for _ in Path(tsk_output_dir).rglob("*") if _.is_file())
            f.write(f"== Recovered Files ==\n")
            f.write(f"  Total files recovered: {file_count}\n\n")
        
        # Summarize interesting findings from bulk_extractor
        bulk_output_dir = os.path.join(disk_output_dir, "bulk_extractor")
        if os.path.exists(bulk_output_dir):
            f.write(f"== Interesting Findings ==\n")
            
            # Check for email addresses
            email_file = os.path.join(bulk_output_dir, "email.txt")
            if os.path.exists(email_file):
                email_count = sum(1 for _ in open(email_file)) - 1  # Subtract header line
                f.write(f"  Email addresses found: {email_count}\n")
            
            # Check for credit card numbers
            ccn_file = os.path.join(bulk_output_dir, "ccn.txt")
            if os.path.exists(ccn_file):
                ccn_count = sum(1 for _ in open(ccn_file)) - 1  # Subtract header line
                f.write(f"  Credit card numbers found: {ccn_count}\n")
            
            # Check for URLs
            url_file = os.path.join(bulk_output_dir, "url.txt")
            if os.path.exists(url_file):
                url_count = sum(1 for _ in open(url_file)) - 1  # Subtract header line
                f.write(f"  URLs found: {url_count}\n")
            
            f.write("\n")
    
    logger.info(f"Disk analysis complete. Summary saved to {summary_file}")
    return True

def analyze_log_file(filename, output_dir):
    """Analyze a log file for suspicious entries."""
    logger.info(f"Analyzing log file: {filename}")
    
    # Create output directory for log analysis
    log_output_dir = os.path.join(output_dir, "log_analysis")
    os.makedirs(log_output_dir, exist_ok=True)
    
    # Extract interesting patterns
    patterns = ARTIFACT_TYPES["log"]["tools"]["grep"]["patterns"]
    output_file = os.path.join(log_output_dir, "suspicious_entries.txt")
    
    with open(output_file, "w") as outfile:
        outfile.write(f"Suspicious entries found in {os.path.basename(filename)}:\n\n")
        
        for pattern in patterns:
            outfile.write(f"=== Pattern: {pattern} ===\n")
            
            try:
                result = subprocess.run(
                    ["grep", "-i", pattern, filename],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True
                )
                
                if result.stdout:
                    outfile.write(result.stdout)
                else:
                    outfile.write("  No matches found.\n")
                
                outfile.write("\n")
            except subprocess.CalledProcessError:
                outfile.write("  No matches found.\n\n")
    
    logger.info(f"Log analysis complete. Results saved to {output_file}")
    return True

def generate_chain_of_custody(filename, artifact_type, output_dir):
    """Generate a chain of custody document for the artifact."""
    logger.info(f"Generating chain of custody document for {filename}")
    
    # Calculate file hash
    file_hash = calculate_hash(filename)
    file_size = os.path.getsize(filename)
    file_stat = os.stat(filename)
    
    # Create chain of custody document
    custody_file = os.path.join(output_dir, "chain_of_custody.txt")
    with open(custody_file, "w") as f:
        f.write("CHAIN OF CUSTODY DOCUMENT\n")
        f.write("=========================\n\n")
        f.write(f"Case ID: ORIONX-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}\n")
        f.write(f"Date of Acquisition: {datetime.datetime.fromtimestamp(file_stat.st_ctime).strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Analyst: {os.environ.get('USER', 'unknown')}\n\n")
        
        f.write("ARTIFACT DETAILS\n")
        f.write("================\n")
        f.write(f"Filename: {os.path.basename(filename)}\n")
        f.write(f"File Type: {artifact_type}\n")
        f.write(f"File Size: {file_size} bytes\n")
        f.write(f"SHA-256 Hash: {file_hash}\n\n")
        
        f.write("CUSTODY CHAIN\n")
        f.write("=============\n")
        f.write(f"1. {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} - Initial analysis by {os.environ.get('USER', 'unknown')}\n")
        f.write("   Orion-X Phoenix Edition v1.5.5 Artifact Analyzer\n\n")
        
        f.write("ANALYSIS SUMMARY\n")
        f.write("================\n")
        f.write(f"Analysis conducted using Orion-X Phoenix Edition v1.5.5\n")
        f.write(f"Results saved to: {output_dir}\n")
    
    logger.info(f"Chain of custody document generated: {custody_file}")
    return custody_file

def main():
    parser = argparse.ArgumentParser(description="Orion-X Artifact Analyzer")
    parser.add_argument("artifact", help="Path to the artifact file to analyze")
    parser.add_argument("-o", "--output", help="Output directory for analysis results", default="./analysis_results")
    parser.add_argument("-t", "--type", help="Explicitly specify artifact type (memory, disk, network, log)", default=None)
    parser.add_argument("--upload", help="Upload results to artifact vault after analysis", action="store_true")
    parser.add_argument("--vault-url", help="URL of the artifact vault", default=os.environ.get("ORIONX_VAULT_URL", ""))
    parser.add_argument("--vault-token", help="Token for artifact vault authentication", default=os.environ.get("ORIONX_VAULT_TOKEN", ""))
    args = parser.parse_args()
    
    # Check if artifact file exists
    if not os.path.isfile(args.artifact):
        logger.error(f"Artifact file not found: {args.artifact}")
        return 1
    
    # Create output directory
    output_dir = os.path.abspath(args.output)
    os.makedirs(output_dir, exist_ok=True)
    logger.info(f"Output directory: {output_dir}")
    
    # Identify artifact type
    artifact_type = args.type if args.type else identify_artifact_type(args.artifact)
    logger.info(f"Artifact type identified as: {artifact_type}")
    
    # Generate chain of custody document
    custody_file = generate_chain_of_custody(args.artifact, artifact_type, output_dir)
    
    # Analyze based on artifact type
    success = False
    if artifact_type == "memory":
        success = analyze_memory_dump(args.artifact, output_dir)
    elif artifact_type == "network":
        success = analyze_network_capture(args.artifact, output_dir)
    elif artifact_type == "disk":
        success = analyze_disk_image(args.artifact, output_dir)
    elif artifact_type == "log":
        success = analyze_log_file(args.artifact, output_dir)
    else:
        logger.error(f"Unsupported artifact type: {artifact_type}")
        return 1
    
    # Upload to artifact vault if requested
    if args.upload and success:
        if not args.vault_url:
            logger.error("Artifact vault URL not specified. Use --vault-url or set ORIONX_VAULT_URL environment variable.")
            return 1
        if not args.vault_token:
            logger.error("Artifact vault token not specified. Use --vault-token or set ORIONX_VAULT_TOKEN environment variable.")
            return 1
        
        logger.info(f"Uploading analysis results to artifact vault: {args.vault_url}")
        # This would call a function to upload to the vault
        # upload_to_vault(output_dir, args.vault_url, args.vault_token)
        logger.info("Upload feature not fully implemented in this version.")
    
    # Print summary
    if success:
        logger.info(f"Analysis completed successfully. Results saved to {output_dir}")
        print(f"\nAnalysis completed successfully. Results saved to {output_dir}")
        return 0
    else:
        logger.error("Analysis failed.")
        print("\nAnalysis failed. See log for details.")
        return 1

if __name__ == "__main__":
    sys.exit(main())
