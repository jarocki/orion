Packet Captures Collection - Orion-X Phoenix Edition
=====================================================

This directory contains packet capture files for network forensic
analysis training and testing.

FILES IN THIS DIRECTORY:
------------------------

1. apt_malware_traffic.pcap   (SYNTHETIC — no malware, no real hosts)
   Description: A 241-packet, ~9-minute intrusion story for practice:
     - DNS lookup of update-cdn-sync.example, HTTP GET /stage1.bin
       from 203.0.113.45 (the "payload" is a labelled text placeholder)
     - ten TLS beacons to 198.51.100.23:443 (SNI cdn-telemetry.example)
       every ~60 s with jitter — the C2 rhythm pcap-analyzer.py reports
     - DNS TXT tunnelling under exfil.example (hex-encoded labels)
     - a SYN sweep of 10.10.20.20-79 on 445/3389, three hosts answer
     - an SMB2 negotiate to the file server 10.10.20.30
   Addresses: victim network 10.10.20.0/24 (RFC 1918); every outside
   address is RFC 5737 documentation space; every domain is .example.
   Source: tools/samples/make_training_pcap.py (deterministic; re-running
   it reproduces this file byte for byte). Try:
     tshark -r apt_malware_traffic.pcap -q -z conv,ip
     tshark -r apt_malware_traffic.pcap -Y tls.handshake.extensions_server_name
     pcap-analyzer.py apt_malware_traffic.pcap

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