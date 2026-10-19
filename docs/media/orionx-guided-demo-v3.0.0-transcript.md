# Orion-X Phoenix Edition v3.0.0 — guided walkthrough — transcript

**Runtime:** 3 min 30 s<br>
**Picture:** boot, first-boot wizard and desktop are the release ISO booting in QEMU (UEFI, 1920x1080); every application scene is the ISO's own userspace running in a container (`record_scenes.py`); title cards and architecture diagrams are drawn by `tools/guided-demo/cinematic/build_trailer.py`.<br>
**Sound:** narration synthesised offline (Kokoro v1.0, voice `bf_emma 70% + af_heart 30%`, phonemes `en-us`); procedural score (`render_music.py`); deck samples are the image's own R.A.I.N. cues and voice.<br>
**Cockpit LIVE tab:** built-in demo feed plus real events published with `orionx-event` during the capture.

## 00:00 — boot

This is Orion X, Phoenix Edition, version three point zero: a live USB cyberdeck for incident responders working in networks they cannot trust. It boots from a USB stick on Debian 13 and runs with every change held in memory. It needs no network, makes no connection on its own, and installs nothing on the machine you are standing at.

## 00:21 — config

The first boot asks for a name for the deck and an account, with thirty-second defaults. Pick the no-questions entry in the boot menu and it asks nothing at all.

## 00:31 — desktop

The desktop is XFCE, themed as a cyberdeck. The panel shows the mesh you are joined to, the events seen on the bus, and the hosts on the local network. The Cockpit is one click away, and every Orion tool lives under one Orion menu.

## 00:47 — cockpit

The Cockpit's live tab is where you see and hear the activity around you: a scrolling event stream, a threat-pressure gauge that decays over time, a network sparkline, subsystem lights, the deck's own vitals, and the current posture. This feed is the built-in demo traffic; on a real deck it is the live event bus.

## 01:06 — eventbus

Everything that detects something publishes once, to one event bus. Rain, the audible notifier, turns severity into sound and speech. The Cockpit shows the same line. What you hear and what you see always agree.

## 01:20 — awareness

The Awareness tab puts live health, the firewall, the next hop and DNS on one page, with sparklines for packets, processor, memory and disk. Threat posture has three tiers, from passive watching to decoys and canaries, and the deck tells you whether a tier is actually enforced before it claims it is.

## 01:38 — tuning

When an alert is your own scanner, squelch it for a while or tune it out for good. Every answer states whether the change survives a reboot; on a stick without persistence it does not, and the deck says so.

## 01:51 — mesh

Decks find each other on the local network and form a WireGuard mesh with no hub. Keys are made on the deck when you join, and a team pre-shared key is one command away. Team chat runs over that mesh on your own Matrix server.

## 02:05 — nebula

Nebula is the on-device assistant: a local language model, verified against its hash at every boot, listening on the deck only. Its tools can look at packet captures and artifacts, but they cannot improvise commands, and nothing leaves the deck.

## 02:21 — pcap

Underneath is a curated forensics toolkit: Wireshark and Zeek for the wire, Volatility for memory, capa and YARA for binaries, and a synthetic training capture to practise on, with no real malware in it.

## 02:41 — workbench

The Orion Workbench is the analyst's toolbox in a browser: what is on the deck, what you can add, and the open-source intelligence tools, with God's Eye and Pivotglass beside CyberChef.

## 02:53 — pivotglass

Pivotglass is the adversary-infrastructure hunting deck. It runs locally, keeps hypotheses, evidence and contradictions as separate records, and ships with an offline learning case.

## 03:05 — release

The full User Guide is on the image and on GitHub. The ISO is larger than GitHub's file limit, so it ships in signed parts: download them, join them, verify the hash, and write the image to a USB stick. It is tested on one reference laptop and in QEMU, so your bug reports are welcome. That is Orion X.
