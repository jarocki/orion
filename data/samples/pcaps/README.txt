Packet Captures Collection - Orion-X Phoenix Edition
=====================================================

This directory contains packet capture files for network forensic
analysis training and testing.

FILES IN THIS DIRECTORY:
------------------------

1. apt_malware_traffic.pcap
   Description: Placeholder for APT malware traffic capture
   Source: Placeholder (to be replaced with real sample)

2. synthetic-sample.pcap
   Description: Synthetic PCAP with valid libpcap format (magic bytes
   0xa1b2c3d4, version 2.4, LINKTYPE_ETHERNET). Contains one minimal
   Ethernet frame stub for parser validation and testing.
   Source: Generated deterministically for Phase 5 test infrastructure
   Size: 94 bytes
   Purpose: Validates that forensic parsers correctly handle pcap global
   headers and packet records without requiring large real-world captures.

USAGE:
------
These captures can be analyzed using:

- tcpdump:
  tcpdump -r synthetic-sample.pcap -nn

- Wireshark/tshark:
  tshark -r synthetic-sample.pcap

- The artifact-analyzer.py script:
  python3 scripts/artifact-analyzer.py synthetic-sample.pcap -t pcap

NOTE ON SYNTHETIC SAMPLES:
--------------------------
The synthetic-sample.pcap file is NOT a real network capture. It contains
fabricated data with valid structural format for automated testing only.
Do not use it for forensic training — use real captures from sources like
malware-traffic-analysis.net or NETRESEC.