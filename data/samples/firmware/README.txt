Firmware Images Collection - Orion-X Phoenix Edition v1.5.5
==========================================================

This directory contains firmware binary dumps from IoT devices for
reverse engineering and vulnerability analysis practice.

FILES IN THIS DIRECTORY:
-----------------------

1. openwrt-19.07-archer.bin
   Description: OpenWrt firmware image for TP-Link Archer series router
   Version: 19.07.8
   Source: OpenWrt Project
   Size: 16 MB
   License: GPLv2
   
2. defcon-iot-challenge.bin
   Description: Firmware from a past DEF CON IoT Village challenge
   Device: Aruba AP-303H access point
   Source: Rapid7 IoT Village exercise
   Size: 8 MB
   Notes: Contains intentionally vulnerable services for practice

USAGE:
-----
These firmware images can be analyzed using the following tools:

- Binwalk (for initial analysis)
  
  binwalk openwrt-19.07-archer.bin

- Ghidra (for deeper code analysis)

IMPORTANT NOTES:
--------------
1. These firmware images are provided for educational purposes only
2. Do not flash these images to actual hardware
3. Some images contain intentional vulnerabilities for training

ATTRIBUTION:
-----------
- OpenWrt firmware is © OpenWrt contributors and is provided under the GPL v2 license
- DEF CON IoT Village challenge firmware is provided courtesy of Rapid7 and the IoT Village organizers

LICENSE:
-------
The OpenWrt firmware is distributed under the GNU General Public License v2.
Other firmware images are for educational use only within Orion-X.


