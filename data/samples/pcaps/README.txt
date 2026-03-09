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

1. 2025-01-22-traffic-analysis-exercise.pcap.zip
   Description: PCAP of an infection where a user downloaded a fake Google 
   Authenticator installer
   Source: Malware-Traffic-Analysis.net (Brad Duncan)
   Password: "infected" (standard password from the site's "about" page)

2. [Additional PCAP files would be listed here]

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
PCAP files courtesy of Malware-Traffic-Analysis.net - © 2025 Brad Duncan.
Used with permission for educational purposes.
Refer to https://www.malware-traffic-analysis.net for original sources.

LICENSE:
--------
These files are shared for educational use only. Please respect the original
source's terms of use. Do not redistribute these samples outside of Orion-X
without proper attribution.
