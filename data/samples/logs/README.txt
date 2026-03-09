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

LICENSE:
-------
These logs are provided for educational purposes only. All logs have been
sanitized to remove any personally identifiable information or sensitive data.
Real IP addresses have been modified.

