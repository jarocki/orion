# Orion-X Phoenix Edition — guided walkthrough — transcript

**Runtime:** 2 minutes, 37 seconds<br>
**Release:** v2.2.0-beta (pre-release)<br>
**Recorded from:** the beta's own applications and desktop, running from the release scripts in a virtual X session; the Cockpit shows its built-in synthetic demo feed, and the Nebula runtime state is a stand-in for the reference deck's verified state (no model is run while recording). Narration is synthesised offline.

## 00:00 — Boot from a stick

This is Orion-X Phoenix Edition, version 2.2.0 beta: a live USB cyberdeck for incident responders working in networks they cannot trust. It boots from a USB stick on Debian 13, runs entirely from RAM, and works fully air-gapped. Nothing has to be installed on the machine you are standing at.

## 00:21 — A desktop built for 3 a.m.

The desktop is XFCE, themed as a cyberdeck. The panel shows what matters at a glance: the mesh you are joined to, scan and intrusion events seen on the event bus, and the number of hosts on the local network. Every Orion-X tool lives under one Orion menu.

## 00:38 — Control Center

The Control Center is designed for your 3 a.m. self. Live health, the WireGuard mesh, and the firewall are on one page. Threat posture has three tiers, from passive to deception. R.A.I.N. — Real-time Audible Intrusion Notification — turns detections into severity-mapped sound cues, so an intrusion is heard, not just watched.

## 01:01 — Nebula: a local copilot

Nebula is the on-device assistant: ollama serving Qwen 2.5 3B, verified at boot by a SHA-256 integrity gate before it is allowed to start. It can reach twelve local MCP tools — pcap summaries, artifact analysis, OAST decoding, nuclei-template lookups — and nothing leaves the deck.

## 01:23 — The Cockpit

The Cockpit is where you see and hear the cyber activity around you: a scrolling event stream, a threat-pressure gauge that decays over time, a network sparkline, subsystem lights and the current posture. This feed is synthetic demo traffic; on a real deck it is the live event bus.

## 01:41 — The toolkit

Underneath is a curated forensics toolkit: Wireshark and Zeek for the wire, Volatility 3 for memory, capa and YARA for binaries, go-roast for out-of-band payloads, and nucleotide, which maps URLs to nuclei templates from a lookup table built into the image.

## 01:59 — Pivotglass

Pivotglass is the adversary-infrastructure hunting deck. It runs locally in the browser, keeps hypotheses, evidence and contradictions as separate records, and ships with an offline learning case so you can practise without any network at all.

## 02:14 — Get the beta

The full User Guide is rendered into the image and on GitHub. The beta ISO is 3.09 gigabytes, published as seven parts because of GitHub's two-gigabyte limit: download them, concatenate, verify the SHA-256, and write the image to an eight-gigabyte stick. Beta means we want your bug reports. That is Orion-X.
