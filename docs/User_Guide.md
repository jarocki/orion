# Orion-X Phoenix Edition User Guide

Release: **v2.2.0 (Trixie line)** — Debian 13 "trixie", Python 3.13, Linux 6.12.

## Table of Contents

1. [Introduction](#1-introduction)
   - [About Orion-X Phoenix Edition](#about-orion-x-phoenix-edition)
   - [Key Features](#key-features)
   - [Use Cases](#use-cases)

2. [Getting Started](#2-getting-started)
   - [System Requirements](#system-requirements)
   - [Creating Bootable Media](#creating-bootable-media)
   - [Verifying Your Installation](#verifying-your-installation)

3. [Booting and Initial Setup](#3-booting-and-initial-setup)
   - [Boot Menu and Boot Chain](#boot-menu-and-boot-chain)
   - [First-Boot Wizard](#first-boot-wizard)
   - [Persistence Options](#persistence-options)

4. [The Desktop](#4-the-desktop)
   - [Orion Application Menu](#orion-application-menu)
   - [Top Panel Widgets](#top-panel-widgets)
   - [Control Center](#control-center)

5. [Networking](#5-networking)
   - [Connecting to Local Networks](#connecting-to-local-networks)
   - [Setting Up WireGuard VPN](#setting-up-wireguard-vpn)
   - [WireGuard P2P Mesh](#wireguard-p2p-mesh)
   - [Network Configuration Verification](#network-configuration-verification)

6. [Secure Communication](#6-secure-communication)
   - [Matrix Setup](#matrix-setup)
   - [Matrix Clients](#matrix-clients)
   - [Communication Best Practices](#communication-best-practices)

7. [Awareness: R.A.I.N. and the Orion Cockpit](#7-awareness-rain-and-the-orion-cockpit)
   - [R.A.I.N. — Real-time Audible Intrusion Notification](#rain-real-time-audible-intrusion-notification)
   - [The Event Bus](#the-event-bus)
   - [Orion Cockpit](#orion-cockpit)

8. [Nebula AI](#8-nebula-ai)
   - [Using Nebula](#using-nebula)
   - [MCP Tools](#mcp-tools)
   - [go-roast: OAST Triage](#go-roast-oast-triage)
   - [Pivotglass: Adversary-Infrastructure Hunting](#pivotglass-adversary-infrastructure-hunting)

9. [Forensic Evidence Collection](#9-forensic-evidence-collection)
   - [Memory Acquisition](#memory-acquisition)
   - [Disk Imaging](#disk-imaging)
   - [Network Traffic Capture](#network-traffic-capture)
   - [Log Collection](#log-collection)
   - [Chain of Custody Documentation](#chain-of-custody-documentation)

10. [Artifact Analysis](#10-artifact-analysis)
    - [Using artifact-analyzer.py](#using-artifact-analyzerpy)
    - [Memory Analysis](#memory-analysis)
    - [Disk Analysis](#disk-analysis)
    - [Network Analysis](#network-analysis)
    - [Log Analysis](#log-analysis)
    - [Detection and Classification Tools](#detection-and-classification-tools)

11. [Timeline Generation](#11-timeline-generation)
    - [Using storyboard-gen.py](#using-storyboard-genpy)
    - [Working with Multiple Log Sources](#working-with-multiple-log-sources)
    - [Visualizing the Timeline](#visualizing-the-timeline)

12. [Data Management](#12-data-management)
    - [Local Storage Options](#local-storage-options)
    - [Uploading to Artifact Vault](#uploading-to-artifact-vault)
    - [Data Security Considerations](#data-security-considerations)

13. [Customization](#13-customization)
    - [Switching Visual Themes](#switching-visual-themes)
    - [Visual Identity](#visual-identity)
    - [Customizing Terminal Environment](#customizing-terminal-environment)
    - [Adding Custom Tools](#adding-custom-tools)

14. [Sample Data](#14-sample-data)
    - [Working with PCAP Samples](#working-with-pcap-samples)
    - [Memory Dump Analysis](#memory-dump-analysis)
    - [Firmware Analysis](#firmware-analysis)
    - [Log File Examples](#log-file-examples)

15. [Optional Installers](#15-optional-installers)

16. [Troubleshooting](#16-troubleshooting)
    - [Boot Issues](#boot-issues)
    - [Network Connectivity](#network-connectivity)
    - [VPN and Mesh Troubleshooting](#vpn-and-mesh-troubleshooting)
    - [Matrix Connection Issues](#matrix-connection-issues)
    - [R.A.I.N. and Nebula Issues](#rain-and-nebula-issues)
    - [Tool Execution Problems](#tool-execution-problems)

17. [Appendices](#17-appendices)
    - [Command Reference](#command-reference)
    - [File Locations](#file-locations)
    - [Keyboard Shortcuts](#keyboard-shortcuts)

## 1. Introduction

### About Orion-X Phoenix Edition

Orion-X Phoenix Edition is a comprehensive cybersecurity toolkit designed specifically for incident response and digital forensics. It provides a hardened Linux-based live environment that emphasizes security, privacy, and team collaboration.

The "Phoenix" name symbolizes the toolkit's ability to help organizations rise from the ashes of security incidents through effective investigation and response. The current release, v2.2.0 (Trixie line), is built on Debian 13 "trixie" with Python 3.13 and Linux 6.12. It adds an on-device AI assistant (Nebula), audible intrusion alerts (R.A.I.N.), a live visualization dashboard (the Orion Cockpit), a peer-to-peer WireGuard mesh, and a graphical Control Center.

Orion-X is designed to be booted directly from USB media, leaving no traces on the host system. It can run entirely in memory, providing a secure and isolated environment for analyzing potentially compromised systems.

### Key Features

- **Hardened Linux Environment**: Debian 13 "trixie" base, RAM-only operation with optional full disk encryption
- **Control Center**: One window for network, mesh, comms, awareness, IR tools, Nebula AI and auto-healing — designed for your 3am self
- **R.A.I.N.**: Real-time Audible Intrusion Notification — hear intrusions without watching the screen
- **Orion Cockpit**: Live dashboard of the event stream, threat pressure, network activity and system status
- **Nebula AI**: On-device language model (ollama + Qwen2.5-3B-Instruct) with tool access through MCP; nothing leaves the deck
- **Secure Communication**: Matrix homeserver setup for encrypted team collaboration
- **Private Networking**: WireGuard VPN and a peer-to-peer WireGuard mesh between Orion-X nodes
- **Comprehensive Forensic Tools**: Built-in utilities for memory acquisition, disk imaging, network analysis, detection (suricata, yara, capa) and OAST triage (go-roast)
- **Automated Analysis**: Custom scripts for rapid artifact processing and timeline generation
- **Sample Data Library**: Synthetic and public forensic samples for training and testing
- **Visual Distinction**: Themed interface with two modes (dark/amber and green) for operational clarity
- **Documentation**: This guide and reference materials accessible within the environment

### Use Cases

Orion-X Phoenix Edition is ideal for:

- **Security Incident Response**: Investigating suspected compromises or breaches
- **Digital Forensics**: Collecting and analyzing digital evidence
- **Malware Analysis**: Examining suspected malicious code in a controlled environment
- **Security Training**: Teaching incident response and forensic techniques
- **Penetration Testing**: As part of a security assessment toolkit
- **Emergency Response**: Quick deployment for urgent security situations

## 2. Getting Started

### System Requirements

To effectively run Orion-X Phoenix Edition, your system should meet these minimum requirements:

- **CPU**: 64-bit processor (x86_64)
- **RAM**: 4GB minimum (8GB+ recommended for memory analysis; Nebula AI benefits from 8GB+)
- **Storage**: 8GB+ USB drive for bootable media
- **Boot Support**: UEFI or Legacy BIOS
- **Network**: Wired or wireless network adapter

For intensive operations like memory analysis of large dumps or processing multiple disk images, we recommend:

- **RAM**: 16GB or more
- **CPU**: Multi-core processor
- **Storage**: Additional external storage for saving artifacts

### Creating Bootable Media

Before you can use Orion-X, you need to create bootable media (typically a USB drive). Release images follow the name pattern `orionx-phoenix-edition-<version>.iso`.

#### Recommended: orionx-imager

`orionx-imager` is the host-side USB writer for macOS, Linux and Windows. It downloads the release ISO, verifies its SHA-256, refuses to write to internal disks, asks for your password inside the app, and shows a real byte-accurate progress bar while writing. See [orionx-imager.md](orionx-imager.md) for installation and usage.

#### Alternative: dd (Linux)

1. Download the Orion-X Phoenix Edition ISO file
2. Open a terminal and identify your USB device:
   ```bash
   lsblk
   ```
3. Create bootable media (replace `/dev/sdX` with your device):
   ```bash
   sudo dd if=/path/to/orionx-phoenix-edition-<version>.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

#### Alternative: Rufus or balenaEtcher (Windows)

1. Download the Orion-X Phoenix Edition ISO file
2. Download and install [Rufus](https://rufus.ie) or [balenaEtcher](https://www.balena.io/etcher/)
3. Insert your USB drive
4. Open Rufus or balenaEtcher and follow the instructions to select the ISO and USB drive
5. Create the bootable USB (select "DD Image mode" if prompted)

#### Alternative: dd (macOS)

1. Download the Orion-X Phoenix Edition ISO file
2. Open Terminal and identify your USB drive:
   ```bash
   diskutil list
   ```
3. Unmount the drive (replace `N` with your disk number):
   ```bash
   diskutil unmountDisk /dev/diskN
   ```
4. Create bootable media:
   ```bash
   sudo dd if=/path/to/orionx-phoenix-edition-<version>.iso of=/dev/rdiskN bs=1m
   ```
5. Eject the drive when complete:
   ```bash
   diskutil eject /dev/diskN
   ```

### Verifying Your Installation

To verify the integrity of your bootable media:

1. Calculate the SHA-256 hash of the ISO before writing to USB:
   ```bash
   # On Linux/macOS
   sha256sum orionx-phoenix-edition-<version>.iso

   # On Windows (PowerShell)
   Get-FileHash orionx-phoenix-edition-<version>.iso -Algorithm SHA256
   ```

2. Compare the calculated hash with the one provided on the download page (`orionx-imager` does this for you)

3. After creating the bootable media, boot into Orion-X and verify the version:
   ```bash
   grep ISO_VERSION= /etc/orionx-version
   ```

## 3. Booting and Initial Setup

### Boot Menu and Boot Chain

What you see depends on how your firmware boots the USB drive:

- **UEFI**: a plain, readable GRUB menu with two entries — **Orion-X Live** and **Orion-X Live (failsafe)**. The default entry boots after a 5 s timeout.
- **Legacy BIOS**: the same two entries on the themed isolinux menu.

After you choose an entry, the Plymouth **"Orion-X Phoenix"** splash is shown while the kernel and live system start. On the very first boot the splash is followed by the first-boot wizard on the console (next section); on later boots the system goes straight to the login screen and desktop.

![Orion-X boot chain](images/orionx-boot-chain.svg)

*Figure: From power-on to desktop — firmware, boot menu, Plymouth splash, first-boot wizard, login screen.*

To edit kernel parameters for a single boot, press **e** in the GRUB menu (UEFI) or **Tab** in the isolinux menu (BIOS), append the parameters, and boot.

### First-Boot Wizard

On the first boot only, Orion-X pauses on the console (tty1) and shows a full-screen banner: **"the boot has PAUSED — your input is needed."** The wizard then asks, in order:

1. **Hostname** for this deck
2. **Primary account** — username and password (if you change the username, the live user is renamed)
3. **Wi-Fi** — SSID and password, asked **only** when no wired link is detected

Every prompt auto-continues with its default after 120 seconds, so an unattended boot still completes. When the wizard finishes, the system continues to the login screen and desktop.

You can re-run the wizard at any time:

```bash
sudo orionx-wizard
```

![Login screen](images/login_screen.png)

*Figure: Login screen.*

### Persistence Options

Orion-X can operate in two primary modes:

#### Amnesic Mode (Default)

- Runs entirely in RAM
- Leaves no trace on the host system
- All changes are lost on reboot
- Ideal for maximum security and forensic integrity

#### Persistent Mode

- Changes are saved between reboots
- Configurations, collected evidence, and installed tools are preserved
- Optional encrypted persistence for sensitive data

A USB stick written with `dd` or `orionx-imager` contains **two** partitions (the live system and the EFI system partition). Persistence needs a **third** partition, which you create yourself in the free space after the image. This build does not expose persistence as a boot-menu entry; it is enabled with the `persistence` kernel parameter that Debian live-boot understands.

To set up encrypted persistence:

1. Boot Orion-X normally
2. Create a third partition in the free space (replace `/dev/sdX` with the USB device, not a partition):
   ```bash
   sudo fdisk /dev/sdX      # n (new), accept defaults to use the free space, w (write)
   lsblk /dev/sdX           # confirm the new partition, e.g. /dev/sdX3
   ```
3. Format it as an encrypted persistence volume:
   ```bash
   sudo cryptsetup luksFormat /dev/sdX3
   sudo cryptsetup luksOpen /dev/sdX3 orionx_persist
   sudo mkfs.ext4 -L persistence /dev/mapper/orionx_persist
   sudo mount /dev/mapper/orionx_persist /mnt
   echo "/ union" | sudo tee /mnt/persistence.conf
   sudo umount /mnt
   sudo cryptsetup luksClose orionx_persist
   ```
4. Reboot; at the boot menu press **e** (GRUB) or **Tab** (isolinux) and append `persistence persistence-encryption=luks` to the kernel line. You will be asked for the passphrase during boot.

## 4. The Desktop

After login you land on the XFCE desktop with the Phoenix wallpaper, a top panel with live status widgets, and the Control Center, which starts automatically.

![Orion-X desktop](images/desktop_screenshot.png)

*Figure: Orion-X desktop.*

### Orion Application Menu

Applications → **Orion** (Phoenix icon) groups the Orion-X tools:

- **Orion-X Control Center**
- **Orion Cockpit**
- **Orion-X Mesh**
- **Orion-X — Start Mesh**
- **Orion-X Matrix Setup**
- **Matrix Commander**
- **Orion-X Artifact Analyzer**
- **Orion-X Storyboard Generator**

### Top Panel Widgets

The top panel shows, left to right:

| Widget | Meaning |
|---|---|
| ▲ *interface* | Active network interface; shows ▼ when offline |
| ◆ *N peers* | Connected mesh peers; shows — when the mesh is idle |
| ◎ *scans* | Scan count |
| ◉ *clients* | Client count |

### Control Center

The Control Center (`orionx-control-center`) opens automatically with the desktop session. Its header carries the tagline **"Designed for your 3am self"**, a **◈ COCKPIT** button that opens the Orion Cockpit, and a toast bar that reports every action you take. It is organized into seven tabs:

**Network · Mesh · Comms · Awareness · IR Tools · Nebula AI · Auto-Healing**

- **Network** — local connectivity (wired/Wi-Fi) and VPN.
- **Mesh** — join, inspect and leave the WireGuard P2P mesh (see [WireGuard P2P Mesh](#wireguard-p2p-mesh)).
- **Comms** — Matrix setup and clients (see [Secure Communication](#6-secure-communication)).
- **Awareness**
    - *Live health*: CPU load, memory, disk, uptime, Nebula AI, Network, Mesh, Firewall — each green/amber/red, refreshed every 3 s.
    - *Threat posture* (radio): **Tier 0 · Passive**, **Tier 1 · Active Monitoring**, **Tier 2 · Deception** (opt-in). Stored in `~/.config/orionx/threat-posture`.
    - *Audible alerts · R.A.I.N.*: **Enable audible alerts**, **Alert from severity** (Info / Notice / Warning / Critical; default Warning), **Volume** slider, **Spoken voice cue**, **Test alert** button. Stored in `~/.config/orionx/rain.json`. See [R.A.I.N.](#rain-real-time-audible-intrusion-notification).
- **IR Tools** — Artifact Analyzer, Storyboard Generator, PCAP Analyzer, Lynis Security Audit, Download Samples, Toggle Theme. Click one, pick the file or folder it needs, and it runs. A tool that is not installed produces a clear message, not an error.
- **Nebula AI** — runtime status, start/stop, the **Ask Nebula** chat pane, and the list of MCP tools (see [Nebula AI](#8-nebula-ai)).
- **Auto-Healing** — an autonomy grid: for each class of action choose **off / propose / confirm / autonomous**. Stored in `~/.config/orionx/autonomy.json`.

## 5. Networking

### Connecting to Local Networks

Orion-X supports both wired and wireless network connections. Interface names follow Debian's predictable scheme (for example `enp2s0` for wired and `wlp3s0` for wireless); check yours with `ip link`.

#### Wired Connection

1. Connect an Ethernet cable to your system
2. The connection should be established automatically
3. Verify with the ▲ interface widget in the top panel, or `nmcli connection show --active`

#### Wireless Connection

Wi-Fi may already be configured if the first-boot wizard asked for it. Otherwise:

1. Click the network icon in the top panel and select your wireless network, or use the terminal:
   ```bash
   nmcli device wifi list
   nmcli device wifi connect SSID password PASS
   ```
2. Confirm the connection:
   ```bash
   nmcli connection show --active
   ```

To verify your network connection:

```bash
ip a
ping -c 4 1.1.1.1
```

### Setting Up WireGuard VPN

Use this when your team runs a central WireGuard server. For direct node-to-node links without a server, use the [mesh](#wireguard-p2p-mesh) instead.

1. Open a terminal
2. Run the WireGuard setup script:
   ```bash
   sudo setup-wireguard.sh
   ```
3. Follow the prompts to configure the VPN:
   - Server endpoint (IP:Port)
   - Server public key
   - Your assigned client IP address
   - DNS settings (optional)
   - Allowed IPs (optional)

The script will:

1. Generate your client keys (public and private)
2. Create the WireGuard configuration
3. Activate the connection automatically

For manual control of your VPN connection:

- **Start VPN**: `sudo wg-quick up orionx`
- **Stop VPN**: `sudo wg-quick down orionx`
- **Check status**: `sudo wg show`

### WireGuard P2P Mesh

The mesh links Orion-X nodes directly over WireGuard (interface `wg0`) — every node peers with every other node, and no central server is required. Use the Control Center's **Mesh** tab, the Orion menu entries **Orion-X Mesh** / **Orion-X — Start Mesh**, or the CLI:

```bash
sudo orionx-mesh join                       # discover peers on the LAN and join
sudo orionx-mesh join --config peers.conf   # join a pre-planned mesh from a peer list
orionx-mesh status                          # this node's mesh state
orionx-mesh peers                           # connected peers
sudo orionx-mesh leave                      # tear down wg0 and leave the mesh
```

Add `--verbose` to any subcommand for detailed output. The ◆ widget in the top panel shows the current peer count.

![P2P mesh: every node peers directly; a relay is optional](images/orionx-mesh-topology.svg)

*Figure: P2P mesh topology — every node peers directly; a relay is optional.*

### Network Configuration Verification

To verify your network configuration:

1. Check interface status:
   ```bash
   ip a
   nmcli connection show --active
   ```

2. Verify DNS resolution:
   ```bash
   getent hosts example.com
   ```

3. Check VPN and mesh connectivity:
   ```bash
   sudo wg show
   orionx-mesh status
   ```

4. Test connection to team infrastructure:
   ```bash
   ping -c 4 [artifact-vault-ip]
   ```

5. Trace a path (if `traceroute` is installed on this build):
   ```bash
   traceroute [destination]
   ```

## 6. Secure Communication

### Matrix Setup

Orion-X uses Matrix for secure, encrypted team communication. Start it from the Orion menu (**Orion-X Matrix Setup**), the Control Center **Comms** tab, or a terminal:

1. Open a terminal
2. Run the Matrix setup script:
   ```bash
   sudo setup-matrix.sh
   ```
3. Choose your configuration mode:
   - **Client Mode**: Connect to your team's existing Matrix server
   - **Server Mode**: Configure this Orion-X instance as a Matrix homeserver

#### Client Mode Configuration

If connecting to an existing server:

1. Enter the Matrix homeserver URL (e.g., `https://matrix.example.org`)
2. Enter your Matrix user ID (`@username:server.org`)
3. Enter your password
4. The script configures the client for you

#### Server Mode Configuration

If setting up a local server:

1. Enter a server name for the Matrix homeserver
2. Create an admin username and password
3. The script will:
   - Generate a secure configuration
   - Create a self-signed certificate
   - Start the Matrix Synapse server
   - Register your admin user
   - Configure the client

### Matrix Clients

Two clients are available:

- **Matrix Commander** (Orion menu) — a lightweight command-line client, present on the base image.
- **Element** — the graphical Matrix client. Element is **not** on the base ISO; it is an optional post-boot installer that needs network access (see [Optional Installers](#15-optional-installers)):
  ```bash
  sudo /opt/orionx/optional/install-element.sh
  ```
  After installation, launch Element from the Applications menu or with `element-desktop`, log in, and join your team's incident response room. A terminal client, gomuks, is available the same way (`install-gomuks.sh`).

Matrix features in Orion-X:

- End-to-end encryption for all messages
- File sharing (for small artifacts and screenshots)
- Room history for maintaining investigation context
- Direct messaging between team members
- Optional voice/video calls (if supported by the server and client)

### Communication Best Practices

When using Matrix for incident response:

1. **Create dedicated rooms** for each incident or investigation
2. **Use clear room names** that include case numbers or identifiers
3. **Invite only necessary team members** to maintain confidentiality
4. **Verify device keys** of all team members when possible
5. **Share sensitive information** only in encrypted chats
6. **Maintain a communication log** for handovers between shifts
7. **Set appropriate retention policies** for message history

## 7. Awareness: R.A.I.N. and the Orion Cockpit

Orion-X publishes everything noteworthy — detections, mesh changes, scan results, your own notes — to a single event bus. Two consumers read it: **R.A.I.N.** turns events into sound, and the **Orion Cockpit** turns them into a live picture.

![One event bus: R.A.I.N. hears it, the Cockpit shows it](images/orionx-event-bus.svg)

*Figure: One event bus — R.A.I.N. hears it, the Cockpit shows it.*

### R.A.I.N. — Real-time Audible Intrusion Notification

R.A.I.N. lets you hear intrusions without watching the screen. The `orionx-rain` daemon starts automatically with the desktop session, watches the event bus, and plays a tone for each event at or above your chosen severity. Tones escalate with severity, and cues are throttled: each severity has its own cooldown and no two cues are ever played less than 1.5 s apart.

Configure it in the Control Center → **Awareness** → **Audible alerts · R.A.I.N.** panel (enable, alert-from severity, volume, spoken voice cue, Test alert). Settings are stored in `~/.config/orionx/rain.json`.

From a terminal:

```bash
orionx-rain --test warning   # play a sample cue for the given severity
orionx-rain --oneshot        # play the most urgent pending event once, then exit
```

### The Event Bus

The bus is an append-only JSON Lines file at `/run/orionx/events.jsonl`. Each line has the fields `ts`, `iso`, `severity`, `source`, `category`, `message`.

Publish an event from any script or terminal with `orionx-event`:

```bash
orionx-event --severity warning --source myscan --category recon "port sweep from 10.0.0.9"
orionx-event -s critical -c malware --source yara "match: Emotet_loader in /tmp/x"
```

Severity is one of `info`, `notice`, `warning`, `critical` (short flags: `-s` for severity, `-c` for category). Events you publish are heard by R.A.I.N. and shown in the Cockpit like any other.

### Orion Cockpit

The Orion Cockpit (`orionx-cockpit`; also in the Orion menu and behind the **◈ COCKPIT** button in the Control Center) is a full-window live dashboard:

- **EVENT STREAM** — newest first, coloured by severity, fading with age. Warning and critical events flash the whole deck — the visual twin of the R.A.I.N. tone.
- **THREAT PRESSURE** gauge — severity-weighted with a 60 s half-life: **CALM** below 25, **ELEVATED** below 60, **HOSTILE** at 60 and above.
- **NETWORK** — rx/tx sparkline.
- **SYSTEMS** LEDs — Nebula, Firewall, Mesh, R.A.I.N.
- Posture badge (current threat-posture tier) and clock.

Keys: **F11** toggles fullscreen; **Esc** or **q** quits. Flags: `--fullscreen` starts fullscreen; `--demo` feeds synthetic events for a demonstration.

![Orion Cockpit layout](images/orionx-cockpit-layout.svg)

*Figure: Orion Cockpit layout.*

## 8. Nebula AI

Nebula is Orion-X's on-device assistant: ollama serving **Qwen2.5-3B-Instruct** (Q4_K_M quantization), run by `nebula-runtime.service`. It answers questions, explains output, and can call a fixed set of local tools. Nothing leaves the deck.

### Using Nebula

From the Control Center → **Nebula AI** tab: check runtime status, start or stop it, chat in the **Ask Nebula** pane, and see the MCP tools it can call.

From a terminal:

```bash
nebula status                  # runtime status (add --json for machine-readable)
nebula chat                    # interactive chat
nebula chat --session triage   # named session
nebula tools                   # list available MCP tools (add --json)
nebula tools --serve           # run the MCP tool server on stdio (for other clients)
```

### MCP Tools

Nebula reaches the system through an MCP tool server. Available tools:

`nebula_status`, `systemctl_status`, `list_connections`, `wg_show`, `tshark_summary`, `pcap_analyze`, `artifact_analyze`, `oast_extract`, `oast_decode`, `oast_analyze`

Every call is schema-validated, executed argv-only (no shell), subject to a timeout, and audited to `/var/log/orionx/nebula-mcp.log`.

![Nebula runs on-device; tools reach the model through MCP](images/orionx-nebula-mcp.svg)

*Figure: Nebula runs on-device; tools reach the model through MCP.*

### go-roast: OAST Triage

`roast` (go-roast, at `/usr/local/bin/roast`) works with Interactsh out-of-band application security testing (OAST) callback domains: it extracts them from logs, decodes the machine-id / pid / timestamp metadata they embed, and clusters them into campaigns.

```bash
roast extract -f /var/log/nginx/access.log -o table   # find OAST domains in a log
roast decode  -f domains.txt -o json                  # decode embedded metadata
roast analyze -f domains.txt -o csv                   # cluster into campaigns
cat access.log | roast extract                        # reads stdin when -f is omitted
roast mcp                                             # stdio MCP server
roast serve                                           # local web UI
```

Subcommands: `extract`, `decode`, `analyze` (input from stdin or `-f FILE`; output `-o json|csv|table`), `mcp`, `serve`. The same three analyses are exposed to Nebula as `oast_extract`, `oast_decode` and `oast_analyze`.

### Pivotglass: Adversary-Infrastructure Hunting

Pivotglass is an AI-augmented framework for hunting, pivoting on, and discovering adversary infrastructure, indicators and TTPs. It keeps every investigation in a workspace with evidence, provenance and a relationship graph, can export STIX 2, and — importantly for a deck that is often air-gapped — ships a **complete offline learning investigation** that needs no API key, model, account or network.

Launch it from **Applications → Orion → Pivotglass**, or from a terminal:

```bash
ap            # local browser cockpit at http://127.0.0.1:8765 (same as: ap web)
ap tui        # full-screen terminal deck
ap basic      # direct use → set → run module console
ap --version
```

Your first investigation, fully offline — type this inside the Pivotglass prompt:

```text
workspace learn first-case
```

The browser interface listens only on the local machine. Workspaces and configuration live in `~/.ap/` (on the live system they do not survive a reboot — export what you need). Fourteen optional intelligence modules (VirusTotal, Shodan, GreyNoise, OTX, urlscan, crt.sh, …) activate when you add keys and have connectivity; nothing is required for local pivoting. Exposing Pivotglass hunts to Nebula as MCP tools is a planned follow-up.

## 9. Forensic Evidence Collection

Some third-party acquisition tools mentioned below may not be present on every Orion-X build. Check before you rely on one: `command -v avml dc3dd dcfldd ewfacquire`.

### Memory Acquisition

Memory acquisition is critical for capturing volatile system state. Orion-X includes several methods:

#### For Linux Target Systems

1. Use the AVML tool (may not be present on this build — check with `command -v avml`):
   ```bash
   sudo avml /path/to/output.raw
   ```

2. Use the LiME kernel module (for kernel-specific acquisition):
   ```bash
   sudo insmod lime.ko "path=/path/to/output.lime format=lime"
   ```

#### For Windows Target Systems

- Run DumpIt.exe or WinPmem from a USB drive on the target
- Copy the resulting memory dump to Orion-X for analysis with Volatility 3

#### Memory Acquisition Best Practices

- Always acquire memory before any other actions that might alter system state
- Document the system time and acquisition time for proper timeline correlation
- Use write blockers when possible to prevent accidental writes to evidence
- Verify integrity by calculating hash values immediately after acquisition

### Disk Imaging

To create forensic images of storage devices:

1. Identify the target disk:
   ```bash
   sudo fdisk -l
   ```

2. Create a bit-by-bit copy with dd:
   ```bash
   sudo dd if=/dev/sdX of=/path/to/image.dd bs=4M status=progress
   ```

3. For enhanced logging and verification, use dc3dd:
   ```bash
   sudo dc3dd if=/dev/sdX of=/path/to/image.dd hash=sha256 log=/path/to/acquisition.log hlog=/path/to/image.dd.hash
   ```

4. With dcfldd (may not be present on this build — check with `command -v dcfldd`):
   ```bash
   sudo dcfldd if=/dev/sdX of=/path/to/image.dd bs=4M hash=sha256 hashlog=/path/to/hash.log
   ```

5. For E01 format imaging, use ewfacquire (may not be present on this build — check with `command -v ewfacquire`):
   ```bash
   sudo ewfacquire -t /path/to/image.E01 /dev/sdX
   ```

### Network Traffic Capture

Network traffic capture can reveal communication patterns, malware command and control, and data exfiltration. Replace `IFACE` with your interface (e.g. `enp2s0` / `wlp3s0` — check `ip link`).

1. List available network interfaces:
   ```bash
   ip link
   ```

2. Capture traffic with tcpdump:
   ```bash
   sudo tcpdump -i IFACE -w /path/to/capture.pcap
   ```

3. Apply filters to focus on specific traffic:
   ```bash
   # Capture HTTP traffic
   sudo tcpdump -i IFACE -w /path/to/http.pcap port 80 or port 443

   # Capture DNS traffic
   sudo tcpdump -i IFACE -w /path/to/dns.pcap port 53

   # Capture traffic to/from a specific host
   sudo tcpdump -i IFACE -w /path/to/host.pcap host 192.168.1.10
   ```

4. Use Wireshark for real-time traffic analysis:
   ```bash
   sudo wireshark
   ```

### Log Collection

System logs contain valuable forensic information:

1. Collect standard Linux logs:
   ```bash
   sudo tar czf /path/to/linux_logs.tar.gz /var/log
   ```

2. Extract Windows event logs:
   ```bash
   # Mount the Windows partition
   sudo mount /dev/sdXN /mnt

   # Copy event logs
   sudo cp /mnt/Windows/System32/winevt/Logs/*.evtx /path/to/windows_logs/
   ```

3. Collect application logs:
   ```bash
   # Web server logs
   sudo cp -r /var/www/logs /path/to/web_logs

   # Database logs
   sudo cp -r /var/lib/mysql/logs /path/to/db_logs
   ```

4. Create a timestamped log summary:
   ```bash
   sudo find /var/log -type f -exec ls -la {} \; > /path/to/log_inventory.txt
   ```

### Chain of Custody Documentation

Maintaining chain of custody is essential for evidence integrity:

1. Document each acquisition with:
   - Date and time of collection
   - System identifiers (hostname, serial number)
   - Evidence description
   - Hash values for verification
   - Names of personnel involved

2. `artifact-analyzer.py` writes a chain-of-custody document alongside every analysis run, so analyzing an artifact also records it:
   ```bash
   python3 /opt/orionx/scripts/artifact-analyzer.py /path/to/artifact -o /path/to/output_dir
   ```

3. For manual documentation, create custody forms:
   ```bash
   # Generate custody form template
   echo "CHAIN OF CUSTODY" > custody_form.txt
   echo "Date: $(date)" >> custody_form.txt
   echo "Evidence: [Description]" >> custody_form.txt
   echo "Hash: $(sha256sum /path/to/evidence)" >> custody_form.txt
   echo "Collector: [Name]" >> custody_form.txt
   ```

4. Store chain of custody documentation with the evidence it describes

## 10. Artifact Analysis

The Orion-X analysis scripts live in `/opt/orionx/scripts/` and are symlinked into `/usr/bin/`, so `artifact-analyzer.py`, `storyboard-gen.py` and `pcap-analyzer.py` can be run by name from any directory. The Control Center **IR Tools** tab runs the same scripts with a file picker.

### Using artifact-analyzer.py

Orion-X includes a powerful artifact analysis automation tool:

1. Basic usage:
   ```bash
   artifact-analyzer.py /path/to/artifact_file -o /path/to/output_dir
   ```

2. With explicit artifact type specification:
   ```bash
   artifact-analyzer.py /path/to/artifact_file -t memory -o /path/to/output_dir
   ```

3. Uploading results to an artifact vault:
   ```bash
   artifact-analyzer.py /path/to/artifact_file --upload --vault-url https://vault.example.com --vault-token your_token
   ```

4. The script will:
   - Identify the artifact type if not specified (`-t` accepts `memory`, `disk`, `network`, `log`)
   - Generate a chain of custody document
   - Run appropriate analysis tools
   - Create summary reports
   - Optionally upload results

### Memory Analysis

For detailed memory analysis:

1. Using Volatility 3:
   ```bash
   # List available plugins
   vol -h

   # List running processes
   vol -f /path/to/memory.raw windows.pslist

   # Network connections
   vol -f /path/to/memory.raw windows.netscan

   # Command history
   vol -f /path/to/memory.raw windows.cmdline
   ```

2. Using the artifact analyzer (automates multiple plugins):
   ```bash
   artifact-analyzer.py /path/to/memory.raw -t memory
   ```

3. Review key indicators in memory:
   - Unusual processes or services
   - Suspicious network connections
   - Injected code or hidden DLLs
   - Evidence of credential theft
   - Registry artifacts in memory

### Disk Analysis

For analyzing disk images:

1. Using The Sleuth Kit tools:
   ```bash
   # List partitions
   mmls /path/to/disk.img

   # Browse filesystem (offset from mmls)
   fls -o 2048 /path/to/disk.img

   # Extract files
   icat -o 2048 /path/to/disk.img [inode] > extracted_file
   ```

2. Mount disk image for analysis:
   ```bash
   # Create a loopback device
   sudo losetup -f -P /path/to/disk.img

   # Find the assigned device
   losetup -a

   # Mount the partition
   sudo mount /dev/loop0p1 /mnt
   ```

3. Use automated analysis:
   ```bash
   artifact-analyzer.py /path/to/disk.img -t disk
   ```

4. Search for specific patterns with bulk_extractor (may not be present on this build — check with `command -v bulk_extractor`):
   ```bash
   bulk_extractor -o output_dir /path/to/disk.img
   ```

### Network Analysis

For analyzing network captures:

1. Basic analysis with tshark:
   ```bash
   # Protocol hierarchy statistics
   tshark -r /path/to/capture.pcap -q -z io,phs

   # HTTP requests
   tshark -r /path/to/capture.pcap -Y "http.request" -T fields -e http.host -e http.request.uri

   # DNS queries
   tshark -r /path/to/capture.pcap -Y "dns" -T fields -e dns.qry.name
   ```

2. Using Wireshark for visual analysis:
   ```bash
   wireshark /path/to/capture.pcap
   ```

3. Quick triage with the Orion-X PCAP analyzer (also in the Control Center IR Tools tab and as the Nebula tool `pcap_analyze`):
   ```bash
   pcap-analyzer.py --help
   pcap-analyzer.py /path/to/capture.pcap
   ```

4. Using Zeek for protocol analysis (may not be present on this build — check with `command -v zeek`):
   ```bash
   zeek -r /path/to/capture.pcap
   ```

5. Automated network analysis:
   ```bash
   artifact-analyzer.py /path/to/capture.pcap -t network
   ```

### Log Analysis

For analyzing log files:

1. Basic analysis with Unix tools:
   ```bash
   # Search for errors
   grep -i "error\|fail\|critical" /path/to/logfile.log

   # Extract timestamps with context
   grep -A 2 -B 2 "2023-01-01" /path/to/logfile.log
   ```

2. Using the log analyzer component:
   ```bash
   artifact-analyzer.py /path/to/logfile.log -t log
   ```

3. Windows event log analysis with evtxexport (may not be present on this build — check with `command -v evtxexport`):
   ```bash
   # Convert to XML for easier parsing
   evtxexport /path/to/Security.evtx > security.xml

   # Search for specific event IDs
   grep -A 10 -B 2 "EventID>4624" security.xml
   ```

4. Timeline creation from logs:
   ```bash
   storyboard-gen.py -i /path/to/logs/ -o timeline.html
   ```

### Detection and Classification Tools

- **suricata** — network IDS with a bundled ruleset. Run it over a capture:
  ```bash
  sudo suricata -r /path/to/capture.pcap -l /path/to/output_dir
  ```
  Refresh the rules when you have network access:
  ```bash
  sudo orionx-freshen-suricata
  ```
- **yara** — pattern matching against files, images and memory dumps, with rules under `/opt/orionx/yara/`:
  ```bash
  yara -r /opt/orionx/yara /path/to/suspect_dir
  ```
  Refresh the rules when you have network access:
  ```bash
  sudo orionx-freshen-yara
  ```
- **capa** — identifies capabilities in executables. It runs from its own Python virtual environment:
  ```bash
  /opt/orionx/venv/re/bin/capa /path/to/sample.exe
  ```
- **roast** — OAST callback-domain triage; see [go-roast](#go-roast-oast-triage).
- **nucleotide** — attributes observed HTTP requests to the *Nuclei* scanner templates that produced them, grades each match (`weak` / `medium` / `strong`), and builds portable threat-actor behaviour fingerprints. A lookup table covering the full nuclei-templates catalogue is built into the image at `/opt/orionx/nucleotide/lookup.json`, with matching Snort/Suricata rules under `/opt/orionx/nucleotide/snort/`, so attribution works offline.

  Attribute one or more URLs (arguments or stdin):
  ```bash
  nucleotide lookup /opt/orionx/nucleotide/lookup.json https://victim.example/wp-content/plugins/akismet/readme.txt
  ```
  Stream a web log into the event bus — every UNIQUE attribution becomes an event, so R.A.I.N. sounds it and the Cockpit shows it (`--dry-run` prints instead of publishing):
  ```bash
  awk '{print $7}' /var/log/nginx/access.log | orionx-nucleotide-watch --min-quality medium
  ```
  Fingerprint an actor from a batch of observed events, then compare or match against a saved fingerprint:
  ```bash
  nucleotide fingerprint events.jsonl --lookup /opt/orionx/nucleotide/lookup.json --actor-id case-2026-001 --out actor.yml
  nucleotide compare ref-actor.yml actor.yml
  ```
  Rebuild the lookup table when you have network access: `nucleotide build --out /opt/orionx/nucleotide/lookup.json`. Nebula can call it too, via the `nucleotide_lookup` and `nucleotide_fingerprint` MCP tools.

## 11. Timeline Generation

### Using storyboard-gen.py

Orion-X includes a tool for creating chronological timelines from multiple sources:

1. Basic usage:
   ```bash
   storyboard-gen.py -i /path/to/logs/ -o timeline.html
   ```

2. Specifying case information:
   ```bash
   storyboard-gen.py -i /path/to/logs/ -o timeline.html -c "Ransomware Incident" -id "CASE-2025-001" -a "Investigator Name"
   ```

3. Generating a text report instead of HTML:
   ```bash
   storyboard-gen.py -i /path/to/logs/ -o timeline.txt -f text
   ```

### Working with Multiple Log Sources

To combine multiple log sources into a coherent timeline:

1. Collect logs from various sources:
   - Web server logs
   - Authentication logs
   - Firewall logs
   - Application logs
   - Windows event logs

2. Place them in a common directory structure:
   ```text
   /case/logs/
   ├── web/
   │   ├── access.log
   │   └── error.log
   ├── firewall/
   │   └── fw.log
   ├── windows/
   │   ├── security.evtx
   │   └── system.evtx
   └── auth.log
   ```

3. Generate a comprehensive timeline:
   ```bash
   storyboard-gen.py -i /case/logs/ -o /case/timeline.html
   ```

4. The storyboard generator will:
   - Parse different log formats automatically
   - Extract timestamps and normalize them
   - Sort events chronologically
   - Color-code by severity
   - Link events to their source files

### Visualizing the Timeline

The storyboard generator creates visual timelines to help identify patterns:

1. HTML timeline features:
   - Color-coded events by severity (info, warning, error)
   - Collapsible sections by source
   - Sortable columns
   - Search functionality
   - Interactive time range selection

2. Filtering the timeline view:
   - By time range (before or after specific events)
   - By severity level
   - By log source
   - By keyword or pattern

3. Exporting and sharing:
   - Save as HTML for interactive viewing
   - Print to PDF for reporting
   - Export as CSV for further analysis

4. Integration with other tools:
   - Link timeline events to original artifacts
   - Import timeline data into other visualization tools
   - Add annotations and investigator notes

## 12. Data Management

### Local Storage Options

For managing collected evidence and analysis results:

1. External storage devices:
   ```bash
   # List available devices
   sudo fdisk -l

   # Mount an external drive
   sudo mount /dev/sdX1 /mnt/external

   # Copy evidence to external storage
   cp -r /path/to/evidence/ /mnt/external/
   ```

2. RAM disk for temporary storage:
   ```bash
   # Create a RAM disk (1GB)
   sudo mkdir -p /mnt/ramdisk
   sudo mount -t tmpfs -o size=1024m tmpfs /mnt/ramdisk
   ```

3. Encrypted containers for sensitive data:
   ```bash
   # Create a 1GB encrypted container
   dd if=/dev/urandom of=/path/to/container.img bs=1M count=1024
   sudo cryptsetup luksFormat /path/to/container.img
   sudo cryptsetup luksOpen /path/to/container.img secure_data
   sudo mkfs.ext4 /dev/mapper/secure_data
   sudo mount /dev/mapper/secure_data /mnt/secure
   ```

### Uploading to Artifact Vault

Orion-X can interface with centralized evidence repositories:

1. Configure vault connection:
   ```bash
   # Set environment variables for vault connection
   export ORIONX_VAULT_URL="https://vault.example.com"
   export ORIONX_VAULT_TOKEN="your_vault_token"
   ```

2. Create a vault configuration file:
   ```bash
   sudo mkdir -p /etc/orionx
   sudo tee /etc/orionx/vault_config.conf > /dev/null << EOF
   ORIONX_VAULT_URL="https://vault.example.com"
   ORIONX_VAULT_TOKEN="your_vault_token"
   EOF
   sudo chmod 600 /etc/orionx/vault_config.conf
   ```

3. Upload artifacts using the analyzer (it reads `ORIONX_VAULT_URL` / `ORIONX_VAULT_TOKEN` from the environment):
   ```bash
   artifact-analyzer.py /path/to/artifact --upload
   ```

4. Manual upload with curl:
   ```bash
   # Upload a file to the vault API
   curl -X POST -H "Authorization: Bearer $ORIONX_VAULT_TOKEN" \
        -F "file=@/path/to/evidence.dd" \
        -F "metadata={\"case\":\"CASE-2025-001\",\"type\":\"disk\",\"hash\":\"$(sha256sum /path/to/evidence.dd | cut -d' ' -f1)\"}" \
        "$ORIONX_VAULT_URL/api/artifacts/upload"
   ```

### Data Security Considerations

When handling forensic data:

1. Sanitize destination media:
   ```bash
   # Securely wipe a device
   sudo dd if=/dev/urandom of=/dev/sdX bs=4M status=progress
   ```

2. Verify data integrity with hashes:
   ```bash
   # Generate hash before transfer
   sha256sum /path/to/evidence.dd > evidence.dd.sha256

   # Verify after transfer
   sha256sum -c evidence.dd.sha256
   ```

3. Encrypt sensitive data during transfer:
   ```bash
   # Create encrypted archive
   tar czf - /path/to/evidence/ | gpg -c > evidence.tar.gz.gpg
   ```

4. Implement secure deletion when needed:
   ```bash
   # Securely delete files
   shred -u /path/to/sensitive_file
   ```

5. Maintain backup copies of critical evidence
6. Document all data handling in chain of custody records

## 13. Customization

### Switching Visual Themes

Orion-X includes two visual themes for different operational contexts:

1. Using the theme toggle script (also **Toggle Theme** in the Control Center IR Tools tab):
   ```bash
   toggle-theme.sh
   ```

2. The script will:
   - Switch between dark/amber and green themes
   - Update terminal colors
   - Change the desktop wallpaper
   - Modify the bash prompt

3. Theme use guidelines:
   - Dark/amber theme: Default for normal operations
   - Green theme: Typically used for secure or root operations
   - Visual distinction helps prevent accidental execution of commands in the wrong context

### Visual Identity

Orion-X ships with a coherent visual identity across the boot chain and desktop:

- **Plymouth splash** — "Orion-X Phoenix" theme on kernel handoff
- **Boot menu** — plain, readable GRUB menu on UEFI; themed isolinux menu on BIOS
- **Login screen** — Orion-X-Greeter with Phoenix backdrop and Iosevka font
- **XFCE desktop** — `Orion-X-Cyberdeck` GTK theme (Adwaita-dark fork with Phoenix red-orange `#FF5722` accent)
- **Icons** — `Orion-X-Icons` (Papirus-Dark inheritance)
- **Fonts** — Iosevka (SIL OFL-1.1) primary, Hack (permissive) secondary
- **Terminal** — xfce4-terminal defaults to Iosevka 11pt, dark background, Phoenix accent selection
- **MOTD** — ASCII wordmark on login

### Customizing Terminal Environment

You can customize the terminal for your workflow:

1. Edit your bash configuration:
   ```bash
   nano ~/.bashrc
   ```

2. Add custom aliases for common commands:
   ```bash
   # Add to ~/.bashrc
   alias ll='ls -la'
   alias memcheck='free -h'
   alias netcheck='ip a && ping -c 4 1.1.1.1'
   ```

3. Create custom functions:
   ```bash
   # Add to ~/.bashrc
   function analyze() {
     artifact-analyzer.py "$1" -o "./analysis_results"
   }
   ```

4. Set custom environment variables:
   ```bash
   # Add to ~/.bashrc
   export CASE_ID="CASE-2025-001"
   export INVESTIGATOR="Your Name"
   ```

5. Source the updated configuration:
   ```bash
   source ~/.bashrc
   ```

### Adding Custom Tools

You can extend Orion-X with additional tools:

1. Install additional packages:
   ```bash
   sudo apt update
   sudo apt install package-name
   ```

2. Install Python packages (Debian 13 marks the system Python as externally managed, so use a virtual environment):
   ```bash
   python3 -m venv ~/venv
   ~/venv/bin/pip install package-name
   ```

3. Download and compile tools:
   ```bash
   git clone https://github.com/example/tool.git
   cd tool
   make
   sudo make install
   ```

4. Add custom scripts to your path:
   ```bash
   mkdir -p ~/bin
   cp your-script.sh ~/bin/
   chmod +x ~/bin/your-script.sh

   # Add to ~/.bashrc
   export PATH="$HOME/bin:$PATH"
   ```

5. Create desktop shortcuts for frequently used tools:
   ```bash
   # Create a .desktop file
   cat > ~/Desktop/custom-tool.desktop << EOF
   [Desktop Entry]
   Name=Custom Tool
   Comment=Description of your tool
   Exec=/path/to/your-tool
   Icon=utilities-terminal
   Terminal=false
   Type=Application
   Categories=Utility;
   EOF

   chmod +x ~/Desktop/custom-tool.desktop
   ```

6. Publish results to the event bus so R.A.I.N. and the Cockpit pick them up:
   ```bash
   orionx-event -s notice --source my-tool -c custom "scan of $TARGET finished"
   ```

## 14. Sample Data

Sample data lives under `/opt/orionx/data/samples/`. Synthetic samples are generated on the box; public samples are fetched on demand with `download-samples.sh` (also **Download Samples** in the Control Center IR Tools tab), which needs network access.

```bash
download-samples.sh --help
```

### Working with PCAP Samples

Orion-X includes network traffic samples for analysis practice:

1. Location of sample PCAPs:
   ```text
   /opt/orionx/data/samples/
   ```
   Files: `synthetic-traffic.pcap`, `maccdc2012_sample.pcap`, `dns_local_lookup.pcap`

2. Analyzing sample PCAPs:
   ```bash
   # Using Wireshark
   wireshark /opt/orionx/data/samples/synthetic-traffic.pcap

   # Using tshark
   tshark -r /opt/orionx/data/samples/maccdc2012_sample.pcap -Y "http"

   # Using the Orion-X PCAP analyzer
   pcap-analyzer.py /opt/orionx/data/samples/dns_local_lookup.pcap
   ```

3. Extracting files from PCAPs:
   ```bash
   # Extract all HTTP objects
   tshark -r /opt/orionx/data/samples/maccdc2012_sample.pcap --export-objects http,./extracted_files
   ```

4. Practice exercises:
   - Identify malicious domains and IPs
   - Extract payloads and analyze them
   - Reconstruct the attack timeline
   - Identify lateral movement attempts

### Memory Dump Analysis

Practice memory forensics with included samples:

1. Location of memory dumps:
   ```text
   /opt/orionx/data/samples/
   ```
   Files: `synthetic-memdump.raw`, `mini_sample_SYNTHETIC.raw`

2. Analyzing memory dumps:
   ```bash
   # Using Volatility 3
   vol -f /opt/orionx/data/samples/synthetic-memdump.raw windows.info

   # Using the artifact analyzer
   artifact-analyzer.py /opt/orionx/data/samples/synthetic-memdump.raw -t memory
   ```

3. Practice exercises:
   - Find hidden or injected processes
   - Analyze network connections
   - Extract authentication artifacts
   - Recover browser history from memory
   - Identify persistence mechanisms

### Firmware Analysis

Analyze IoT firmware samples:

1. Location of firmware samples:
   ```text
   /opt/orionx/data/samples/
   ```
   File: `synthetic-firmware.bin`

2. Basic firmware analysis:
   ```bash
   # Identify firmware components
   binwalk /opt/orionx/data/samples/synthetic-firmware.bin

   # Extract firmware contents
   binwalk -e /opt/orionx/data/samples/synthetic-firmware.bin
   ```

3. Explore the extracted contents:
   ```bash
   cd _synthetic-firmware.bin.extracted
   ls -la
   ```

4. Practice exercises:
   - Locate hardcoded credentials
   - Identify outdated libraries with vulnerabilities
   - Find insecure configuration defaults
   - Examine startup scripts for security issues

### Log File Examples

Practice log analysis with sample datasets:

1. Location of log samples:
   ```text
   /opt/orionx/data/samples/
   ```
   Files: `synthetic-syslog.log` (Linux syslog with SSH brute-force and firewall blocks), `synthetic-web-access.log` (Apache access log with SQL injection and path traversal)

2. Analyzing various log types:
   ```bash
   # SSH brute-force in syslog
   grep -i "failure" /opt/orionx/data/samples/synthetic-syslog.log

   # Web attack logs
   grep "' OR '1'='1" /opt/orionx/data/samples/synthetic-web-access.log

   # Automated log analysis
   artifact-analyzer.py /opt/orionx/data/samples/synthetic-syslog.log -t log
   ```

3. Creating timelines from logs:
   ```bash
   # Generate timeline from multiple logs
   storyboard-gen.py -i /opt/orionx/data/samples/ -o attack_timeline.html
   ```

4. Practice exercises:
   - Identify attacker IP addresses and techniques
   - Trace the progression of an attack
   - Correlate events across multiple log sources
   - Extract indicators of compromise

## 15. Optional Installers

Some tools that would bloat the base ISO or require network access are shipped
as post-boot installers under `/opt/orionx/optional/`:

| Installer | Tool | Size |
|---|---|---|
| `install-clamav.sh` | ClamAV signature scanner | ~350 MB |
| `install-ghidra.sh` | NSA Ghidra (RE) | ~500 MB |
| `install-element.sh` | Element desktop Matrix client | ~200 MB |
| `install-floss.sh` | Mandiant FLOSS | ~50 MB |
| `install-trid.sh` | File type identification | ~5 MB |
| `install-gomuks.sh` | Matrix TUI client | ~20 MB |

### Usage

```bash
# Verify network first (Orion-X is designed for air-gap — installers require net)
sudo /opt/orionx/optional/install-clamav.sh
```

Each installer:

- Requires root (`sudo`)
- Verifies network connectivity to the download source first
- Exits cleanly with an error message on air-gap (no partial installs)
- Uses the shared `lib/orionx-installer-common.sh` for logging, apt/wget helpers,
  and SHA256 verification

## 16. Troubleshooting

### Boot Issues

If you encounter problems booting Orion-X:

1. **USB not recognized as bootable**
   - Verify the ISO was written correctly to the USB (`orionx-imager` verifies the download hash for you)
   - Try recreating the bootable media with a different tool
   - Check BIOS/UEFI settings for boot order and USB boot support
   - Try a different USB port (preferably USB 2.0)

2. **Black screen after boot selection**
   - Try the **Orion-X Live (failsafe)** entry
   - Add kernel parameters: press **e** in the GRUB menu (UEFI) or **Tab** in the isolinux menu (BIOS) and add `nomodeset` or `acpi=off`
   - Check if your GPU is compatible with the included drivers

3. **System freezes during boot**
   - Try the **Orion-X Live (failsafe)** entry to use minimal drivers
   - Add `noapic` or `irqpoll` kernel parameters
   - Disable hardware in BIOS/UEFI that might be causing conflicts

4. **Boot appears to stop at a text banner**
   - That is the first-boot wizard waiting for input on tty1 ("the boot has PAUSED — your input is needed"). Answer the prompts, or wait: each prompt continues with its default after 120 s.

5. **"Invalid signature" with Secure Boot**
   - Temporarily disable Secure Boot in BIOS/UEFI
   - If Secure Boot is required, build a custom ISO with signed bootloader

### Network Connectivity

For network connection issues (replace `IFACE` with your interface, e.g. `enp2s0` / `wlp3s0` — check `ip link`):

1. **Wired network not working**
   - Check physical connection (cable and port LEDs)
   - Verify interface status:
     ```bash
     ip a
     nmcli device status
     ```
   - Try forcing a connection:
     ```bash
     sudo nmcli device connect IFACE
     ```
   - Check for hardware blocking:
     ```bash
     sudo rfkill list
     ```

2. **Wireless network not working**
   - Verify wireless hardware is detected:
     ```bash
     lspci | grep -i -E "wireless|network"
     nmcli device status
     ```
   - Scan for networks:
     ```bash
     nmcli device wifi list
     ```
   - Connect:
     ```bash
     nmcli device wifi connect SSID password PASS
     ```
   - Confirm the active connection:
     ```bash
     nmcli connection show --active
     ```
   - Re-run the first-boot wizard to reconfigure Wi-Fi interactively: `sudo orionx-wizard`

3. **DNS resolution issues**
   - Test DNS resolution:
     ```bash
     getent hosts example.com
     ```
   - Check current DNS configuration:
     ```bash
     cat /etc/resolv.conf
     ```
   - Set alternative DNS servers for the active connection (NetworkManager owns `/etc/resolv.conf`; editing it directly is overwritten):
     ```bash
     nmcli connection modify "CONNECTION NAME" ipv4.dns 1.1.1.1
     nmcli connection up "CONNECTION NAME"
     ```

### VPN and Mesh Troubleshooting

If experiencing VPN or mesh connection issues:

1. **WireGuard connection fails**
   - Check WireGuard configuration:
     ```bash
     cat /etc/wireguard/orionx.conf
     ```
   - Verify server endpoint is reachable:
     ```bash
     ping -c 4 [server-ip]
     ```
   - Ensure the local interface is up:
     ```bash
     ip a
     ```
   - Check WireGuard logs:
     ```bash
     journalctl -xeu wg-quick@orionx
     ```

2. **VPN connected but no traffic**
   - Verify routing table:
     ```bash
     ip route
     ```
   - Check firewall rules:
     ```bash
     sudo nft list ruleset
     ```
   - Test connection to internal resources:
     ```bash
     ping -c 4 [internal-resource-ip]
     ```
   - Verify DNS resolution through VPN:
     ```bash
     getent hosts internal.example.com
     ```

3. **Lost connection to VPN**
   - Restart the VPN connection:
     ```bash
     sudo wg-quick down orionx
     sudo wg-quick up orionx
     ```
   - Regenerate the configuration:
     ```bash
     sudo setup-wireguard.sh
     ```
   - Check for network changes that might affect connection

4. **Mesh shows no peers**
   - Check this node's state and the `wg0` interface:
     ```bash
     orionx-mesh status --verbose
     sudo wg show wg0
     ```
   - Make sure the peers are on the same LAN (auto-discovery) or listed in your `peers.conf`
   - Leave and re-join:
     ```bash
     sudo orionx-mesh leave
     sudo orionx-mesh join --verbose
     ```

### Matrix Connection Issues

For problems with Matrix communication:

1. **Cannot connect to Matrix server**
   - Check if the server is reachable:
     ```bash
     curl -I [matrix-server-url]
     ```
   - Look for SSL/TLS certificate issues:
     ```bash
     curl -vI [matrix-server-url]
     ```

2. **Authentication failures**
   - Verify your Matrix ID and password
   - Check for typing errors in your user ID
   - Re-run the setup script:
     ```bash
     sudo setup-matrix.sh
     ```
   - If you installed Element and want a clean client state:
     ```bash
     rm -rf ~/.config/Element
     ```

3. **Local Matrix server issues**
   - Check server status:
     ```bash
     sudo systemctl status matrix-synapse
     ```
   - Review server logs:
     ```bash
     sudo journalctl -u matrix-synapse
     ```
   - Restart the service:
     ```bash
     sudo systemctl restart matrix-synapse
     ```

### R.A.I.N. and Nebula Issues

1. **No sound from R.A.I.N.**
   - Confirm audible alerts are enabled and the volume is up in Control Center → Awareness → Audible alerts · R.A.I.N.
   - Check the alert-from severity: events below it are silent by design (default: Warning)
   - Play a test cue:
     ```bash
     orionx-rain --test warning
     ```
   - Confirm events are actually arriving on the bus:
     ```bash
     tail -f /run/orionx/events.jsonl
     orionx-event -s warning --source manual -c test "R.A.I.N. check"
     ```

2. **Nebula not responding**
   - Check the runtime:
     ```bash
     nebula status
     systemctl status nebula-runtime.service
     ```
   - Start or stop it from the Control Center → Nebula AI tab
   - Review tool-call audit entries:
     ```bash
     sudo tail /var/log/orionx/nebula-mcp.log
     ```

### Tool Execution Problems

When experiencing issues with specific tools:

1. **Command not found errors**
   - Verify the tool is installed:
     ```bash
     command -v [command]
     ```
   - Check if the tool is in your PATH:
     ```bash
     echo $PATH
     ```
   - Orion-X scripts live in `/opt/orionx/scripts/` and are symlinked into `/usr/bin/`; try the full path:
     ```bash
     /opt/orionx/scripts/[script]
     ```
   - Third-party tools that are not on this build may be available as [optional installers](#15-optional-installers)

2. **Permission denied errors**
   - Try running with sudo:
     ```bash
     sudo [command]
     ```
   - Check file permissions:
     ```bash
     ls -la [file-or-directory]
     ```
   - Ensure scripts are executable:
     ```bash
     chmod +x [script-file]
     ```

3. **Python script errors**
   - Check Python version (Orion-X ships Python 3.13 on Debian 13 "trixie"):
     ```bash
     python3 --version
     ```
   - Verify required packages are installed:
     ```bash
     pip3 list | grep [package-name]
     ```
   - Look for syntax errors in custom scripts:
     ```bash
     python3 -m py_compile [script-file]
     ```

4. **Disk space issues**
   - Check available space:
     ```bash
     df -h
     ```
   - Find large files:
     ```bash
     sudo find / -type f -size +100M
     ```
   - Remove only files you created (for example old analysis output). Do **not** clear `/tmp` wholesale: on the live system it is RAM-backed and holds session state for running tools.
     ```bash
     rm -rf ~/analysis_results/old-run
     ```

## 17. Appendices

### Command Reference

Quick reference for commonly used commands:

```text
# System Information
uname -a                       # System and kernel information
grep ISO_VERSION= /etc/orionx-version   # Orion-X release
lsblk                          # List block devices
df -h                          # Disk usage
free -h                        # Memory usage
lspci                          # List PCI devices
ip a                           # Network interfaces

# Orion-X Desktop
orionx-control-center          # Control Center
orionx-cockpit [--fullscreen] [--demo]   # Orion Cockpit dashboard
sudo orionx-wizard             # Re-run the first-boot wizard

# Awareness (R.A.I.N. / event bus)
orionx-event -s SEV --source NAME -c CAT "msg"   # Publish an event
orionx-rain --test warning     # Play a sample alert cue
orionx-rain --oneshot          # Play the most urgent pending event once
tail -f /run/orionx/events.jsonl   # Watch the event bus

# Nebula AI
nebula status [--json]         # Runtime status
nebula chat [--session NAME]   # Chat with Nebula
nebula tools [--json|--serve]  # List MCP tools / run MCP server

# Networking
sudo setup-wireguard.sh        # Configure WireGuard VPN (central server)
wg show                        # Show WireGuard status
sudo orionx-mesh join          # Join the P2P mesh (LAN discovery)
orionx-mesh status | peers     # Mesh state / peers
sudo orionx-mesh leave         # Leave the mesh
nmcli device wifi list         # Scan Wi-Fi
nmcli connection show --active # Active connections
ping -c 4 example.com          # Test connectivity
getent hosts example.com       # DNS lookup
curl -I example.com            # HTTP header request

# Forensic Acquisition
dd if=/dev/sdX of=disk.img     # Create disk image
dc3dd if=/dev/sdX of=disk.img hash=sha256 hlog=disk.hash   # Image with hash log
tcpdump -i IFACE -w capture.pcap   # Capture network traffic

# Analysis Tools
vol -f memory.raw windows.info # Volatility 3
mmls disk.img                  # List partitions
fls -o 2048 disk.img           # List files in filesystem
tshark -r capture.pcap         # Analyze network capture
pcap-analyzer.py capture.pcap  # Orion-X PCAP triage
suricata -r capture.pcap -l out/   # IDS over a capture
yara -r /opt/orionx/yara DIR   # YARA scan
/opt/orionx/venv/re/bin/capa sample.exe   # Capability analysis
roast extract -f access.log -o table      # OAST domain extraction
grep -i "error" logfile.log    # Search log files

# Orion-X Scripts
setup-matrix.sh                # Set up Matrix communication
toggle-theme.sh                # Switch visual themes
run-lynis.sh                   # Run security audit
artifact-analyzer.py           # Automated artifact analysis
storyboard-gen.py              # Create event timeline
download-samples.sh            # Fetch public sample data
orionx-freshen-suricata        # Refresh suricata rules
orionx-freshen-yara            # Refresh YARA rules

# File Operations
sha256sum file                 # Calculate SHA-256 hash
mount /dev/sdX1 /mnt           # Mount a filesystem
umount /mnt                    # Unmount a filesystem
tar czf archive.tar.gz dir/    # Create compressed archive
cryptsetup luksOpen file enc   # Open encrypted container
```

### File Locations

Important file locations within Orion-X:

```text
# System Files
/etc/orionx-version            # Release identity (ISO_VERSION=...)
/etc/wireguard/                # WireGuard VPN configuration
/etc/matrix-synapse/           # Matrix server configuration
/var/log/                      # System logs
/var/log/orionx/               # Orion-X specific logs
/var/log/orionx/nebula-mcp.log # Nebula MCP tool-call audit
/run/orionx/events.jsonl       # Event bus (append-only JSON lines)

# Orion-X Files
/opt/orionx/scripts/           # Orion-X scripts (symlinked into /usr/bin/)
/opt/orionx/theme/             # Theme assets (wallpapers, etc.)
/opt/orionx/data/samples/      # Sample data for analysis
/opt/orionx/yara/              # YARA rules
/opt/orionx/venv/re/           # Python venv for RE tools (capa)
/opt/orionx/optional/          # Optional post-boot installers
/usr/local/bin/roast           # go-roast binary
/usr/share/doc/orionx/         # Documentation
/usr/share/doc/orionx/User_Guide.html   # This guide, rendered

# User Files (in the primary account's home)
~/.bashrc                      # Bash configuration
~/.config/                     # Application configurations
~/.config/orionx/threat-posture   # Threat posture tier
~/.config/orionx/rain.json     # R.A.I.N. settings
~/.config/orionx/autonomy.json # Auto-Healing autonomy grid
~/Desktop/                     # Desktop shortcuts
```

### Keyboard Shortcuts

Keyboard shortcuts for improved efficiency:

```text
# Terminal Shortcuts
Ctrl+Shift+T                   # New terminal tab
Ctrl+C                         # Interrupt current command
Ctrl+L                         # Clear terminal screen
Ctrl+R                         # Search command history
Tab                            # Auto-complete command or path
!!                             # Repeat last command
Ctrl+A/E                       # Move to start/end of line

# Desktop Environment
Alt+Tab                        # Switch between windows
Alt+F4                         # Close current window
Ctrl+Alt+L                     # Lock screen
Print Screen                   # Take screenshot
Alt+F2                         # Run command dialog
Ctrl+Alt+Arrow                 # Switch workspace

# Orion Cockpit
F11                            # Toggle fullscreen
Esc / q                        # Quit

# Text Editors
Ctrl+S                         # Save file
Ctrl+O                         # Open file
Ctrl+F                         # Find text
Ctrl+G                         # Go to line
Ctrl+Z                         # Undo action
Ctrl+Shift+Z/Ctrl+Y            # Redo action

# Wireshark
Ctrl+/                         # Apply display filter
Ctrl+. / Ctrl+,                # Go to next/previous packet
Ctrl+B                         # Start/stop capture
Ctrl+E                         # Export packet dissections
```

---

This User Guide provides a comprehensive overview of Orion-X Phoenix Edition v2.2.0 (Trixie line). For further assistance or to report issues, see [SUPPORT.md](SUPPORT.md) or consult the project repository.
