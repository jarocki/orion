Log Files Collection - Orion-X Phoenix Edition v1.5.5
====================================================

This directory contains log files from various systems showing attacks,
intrusions, and suspicious activities. These can be used for log analysis
training and incident response practice.

SUBDIRECTORIES:
-------------

1. cowrie/
   Description: Logs from Cowrie SSH/Telnet honeypot that records attacker interactions
   Source: Cowrie Project (MIT Licensed)
   Contents: JSON and text logs showing attacker sessions, commands, and downloads
   
2. web-attacks/
   Description: Sanitized web server logs containing real-world attack attempts
   Source: Various production servers (sanitized)
   Contents: Apache/Nginx access logs with SQL injection, path traversal, and scanning attempts

FILES IN THIS DIRECTORY:
----------------------

1. windows-event-ransomware.evtx
   Description: Windows event logs from a machine during a ransomware incident
   Source: Internal incident response case (sanitized)
   Size: 2.3 MB
   
2. linux-ssh-intrusion.log
   Description: Linux system syslog showing an SSH intrusion and privilege escalation
   Source: Internal incident response case (sanitized)
   Size: 1.1 MB

USAGE:
-----
These logs can be analyzed using:

- Standard Unix tools:
grep -i "failure" linux-ssh-intrusion.log

- The storyboard-gen.py script for timeline creation:
python3 /usr/bin/storyboard-gen.py -i cowrie/ -o honeypot_timeline.html

- The artifact-analyzer.py script:
python3 /usr/bin/artifact-analyzer.py linux-ssh-intrusion.log -t log

ATTRIBUTION:
-----------
- Cowrie honeypot logs are provided courtesy of the Cowrie Project (MIT License)
- Web server attack logs are sanitized logs from production servers
- Windows and Linux logs are from sanitized incident response cases

SYNTHETIC SAMPLES (Phase 5 Test Infrastructure):
-------------------------------------------------

3. synthetic-syslog.log
   Description: 15-line synthetic syslog with mixed severity events
   Source: Deterministically generated for Phase 5 parser testing
   Contents: SSH auth (accept/fail), UFW firewall blocks, cron jobs,
   Orion-X mesh health checks, Matrix Synapse requests, ClamAV malware
   detection. All IPs and hostnames are fabricated.

4. synthetic-events.csv
   Description: CSV event log with timestamp, severity, source, message
   Source: Deterministically generated for Phase 5 parser testing
   Contents: 7 events with INFO/WARNING/ERROR/CRITICAL severity levels

5. synthetic-events.json
   Description: JSON array of structured events matching CSV content
   Source: Deterministically generated for Phase 5 parser testing

6. synthetic-events.xml
   Description: XML event log with attribute-based structure
   Source: Deterministically generated for Phase 5 parser testing

NOTE: Synthetic files contain fabricated data with valid format for
automated testing. Do not use them for forensic training.

LICENSE:
-------
These logs are provided for educational purposes only. All logs have been
sanitized to remove any personally identifiable information or sensitive data.
Real IP addresses have been modified.

