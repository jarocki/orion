Memory Dumps Collection - Orion-X Phoenix Edition v1.5.5
========================================================

This directory contains volatile memory images that can be used for 
forensic analysis training and testing. These memory dumps contain
artifacts of malware or typical system usage.

FILES IN THIS DIRECTORY:
------------------------

1. magnet-forensics-ctf-2020.zip
   Description: Memory dump from the 2020 Magnet Forensics CTF competition
   Source: NIST's CFReDS digital evidence repository
   Size: 4.2 GB (compressed)
   OS: Windows 10 Pro x64
   Scenario: Corporate employee suspected of exfiltrating data
   Password: "orionx" (if password protected)

2. [Additional memory dumps would be listed here]

USAGE:
------
These memory dumps can be analyzed using:

- Volatility (included in Orion-X)
  Example commands:

vol -f magnet-forensics-ctf-2020.raw windows.pslist
vol -f magnet-forensics-ctf-2020.raw windows.netscan

- The artifact-analyzer.py script
Example:

python3 /usr/bin/artifact-analyzer.py magnet-forensics-ctf-2020.raw -t memory

SYSTEM REQUIREMENTS:
-------------------
Note that memory analysis can be memory-intensive. It's recommended to have
at least 8GB of RAM when working with larger memory dumps.

Some of these files are compressed to save space. Uncompressed sizes may be
significantly larger than the ZIP files.

ATTRIBUTION:
-----------
Memory images are provided courtesy of:
- The Volatility Foundation (volatility samples)
- NIST CFReDS (cfreds.nist.gov)
- Various CTF competitions (as noted per file)

SYNTHETIC SAMPLES (Phase 5 Test Infrastructure):
-------------------------------------------------

3. synthetic-mini.raw
   Description: 1024-byte synthetic memory dump with recognizable patterns
   Source: Deterministically generated for Phase 5 parser testing
   Size: 1024 bytes (1 KB)
   Contents: MZ (PE) header signature at offset 0, followed by repeated
   text pattern "This is synthetic memory data for Orion-X testing.",
   padded with null bytes to exactly 1024 bytes.
   Purpose: Validates that memory analysis parsers correctly identify
   PE signatures and text patterns without requiring multi-GB real dumps.

NOTE: This is NOT a real memory dump. It contains fabricated data with
valid structural markers for automated testing only.

LICENSE:
-------
These files are shared for educational and training purposes only.
Some files may contain traces of proprietary software, and should be used
only for forensic training within the Orion-X environment.

