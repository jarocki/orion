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

SYNTHETIC SAMPLES (Phase 5 Test Infrastructure):
-------------------------------------------------

3. synthetic-firmware.bin
   Description: 512-byte synthetic firmware binary with ELF magic header
   Source: Deterministically generated for Phase 5 parser testing
   Size: 512 bytes
   Contents: ELF magic (0x7f454c46) at offset 0, followed by null padding,
   text "Synthetic firmware for testing", and 0xff fill to 512 bytes.
   Purpose: Validates that firmware analysis parsers correctly identify
   ELF magic bytes without requiring large real firmware images.

NOTE: This is NOT real firmware. It contains fabricated data with valid
structural markers for automated testing only. Do NOT flash to hardware.

LICENSE:
-------
The OpenWrt firmware is distributed under the GNU General Public License v2.
Other firmware images are for educational use only within Orion-X.
