# Orion-X Phoenix Edition — Cyberdeck for the Good Guys

**Version:** v2.2.0-beta — "OrionX Beta" ([download](https://github.com/jarocki/orion/releases/tag/v2.2.0-beta), pre-release)
**Base:** Debian 13 "trixie" live (kernel 6.12, Python 3.13, XFCE 4.20) | **Runtime:** Qwen2.5-3B-Instruct (Apache-2.0)
**Previous line:** v2.1.0-bullseye-rain (final Debian 11 build, kept as a known-good fallback)

**In plain words:** Orion-X is a complete Linux system that you copy onto a USB
stick and start a computer from. It does not install anything on that computer
and leaves no files behind when you unplug it. It comes with the tools an
incident responder uses to look at a possibly compromised machine or network —
packet capture, memory and disk forensics, malware triage — plus a private AI
assistant that runs on the stick itself, encrypted team chat, and an alerting
"cockpit" that lets you hear and see suspicious activity. It works with no
internet connection at all.

In the project's own words: a **live, USB-bootable cyberdeck** for incident
responders working in contested network infrastructure — a locked-down,
forensic-first Linux environment with an AI copilot, mesh-encrypted team comms,
and a curated malware-analysis toolkit, designed to work fully air-gapped.

Mission verbs: **monitor** / **detect** / **defend** / **triage** / **timeline**.

> **This is a beta.** It has been boot-tested on one reference laptop and in
> QEMU. Expect rough edges; please report anything confusing or broken via the
> [issue tracker](https://github.com/jarocki/orion/issues/new/choose). What it
> does **not** do yet: boot Apple-silicon Macs (x86-64 only), keep your changes
> between reboots unless you set up persistence, or update itself.

[![Watch the Orion-X guided walkthrough](docs/media/orionx-guided-demo-v2.2.0-beta-poster.png)](docs/media/orionx-guided-demo-v2.2.0-beta.mp4)

**[Watch or download the guided walkthrough (2½ min)](docs/media/orionx-guided-demo-v2.2.0-beta.mp4)** ·
**[Captions](docs/media/orionx-guided-demo-v2.2.0-beta.vtt)** ·
**[Read the transcript](docs/media/orionx-guided-demo-v2.2.0-beta-transcript.md)**

The walkthrough is recorded from the beta's own desktop and applications
(`tools/guided-demo/`, rebuilt per release from `scenes.yaml`); the Cockpit shows
its built-in synthetic demo feed and the narration is synthesised offline.

---

## What's on the ISO

### Detection and Triage

- **YARA** — malware pattern matching; freshen rulesets via `sudo orionx-freshen-yara`
- **Port-scan detection** — `orionx-scanwatch` reads the firewall's own drop
  log and raises a Cockpit event (and an audible R.A.I.N. cue) when one host
  sweeps many ports. Runs by default, needs no rules and no network, and sends
  no packets, so it works air-gapped at Tier 0. A wider second window also
  catches timing-evasive scans such as `nmap -T2`.
- **Suricata IDS** — lazy-start network IDS. It is **off by default and ships
  no threat rules**: enable with
  `sudo touch /var/lib/suricata/orionx-enabled && systemctl start suricata`,
  then fetch rules with `sudo orionx-freshen-suricata` (needs a network).
  Until both are done Suricata detects nothing — port-scan coverage on a stock
  deck comes from `orionx-scanwatch` above.
- **capa** — capability detection for binaries (`/opt/orionx/venv/re/`)
- **ssdeep**, **hashdeep** (provides `md5deep`/`sha1deep`), **python3-pefile** —
  fuzzy hashing, recursive hashing, and PE parsing
- **volatility3** — memory forensics
- **Wireshark / tshark / tcpdump** — network capture and analysis
- **binwalk**, **strings** — carving and pattern extraction

**Not shipped on the Trixie (v2.2.0) image:** `radare2`, `bulk_extractor` and
`nikto` have no candidate package in Debian 13 and are not installed by any
other route. Earlier release text listed them; that text was wrong. Ghidra is
the supported reverse-engineering option and installs post-boot via
`/opt/orionx/optional/install-ghidra.sh`.

### AI Copilot — Nebula Runtime

- **Ollama** serving **Qwen2.5-3B-Instruct Q4_K_M** locally (1.9 GB, Apache-2.0,
  approximately 2-3x faster than Mistral-7B on CPU — see DEC-PHASE11-002)
- **Integrity check** — the model blob ollama loads is SHA-256-verified at every
  boot by `nebula-integrity-check.service`; on mismatch the runtime is not started
  (DEC-PHASE10-009, DEC-PHASE12-016)
- **AppArmor confined** — `/usr/local/bin/ollama` runs under a local-only profile
  (no outbound network; DEC-PHASE10-011)
- **Local only** — the assistant listens on 127.0.0.1 and never sends prompts or
  data off the deck; 12 local MCP tools (pcap/artifact analysis, OAST decoding,
  nuclei-template lookup, service status)

### Team Comms (Mesh)

- **Matrix homeserver** (Synapse) over Phase 3 WireGuard mesh
- **matrix-commander** — CLI Matrix client at `/opt/orionx/venv/comms/`
- **Element desktop** — available via optional installer (see below)

### Optional Installers (network-connected nodes only)

Tools too large or freshness-sensitive for the base ISO live under
`/opt/orionx/optional/`. Run any installer as root on a network-connected node:

| Script | What it installs |
|---|---|
| `install-clamav.sh` | ClamAV (~350 MB; signature freshness decays — hence optional) |
| `install-ghidra.sh` | NSA Ghidra reverse engineering suite |
| `install-element.sh` | Element Matrix desktop client |
| `install-floss.sh` | Mandiant FLOSS string extractor |
| `install-trid.sh` | TrID file type identification |
| `install-gomuks.sh` | Gomuks Matrix TUI client |

All installers share `orionx-installer-common.sh`: root check, network check,
apt/wget helpers, and SHA256 verification. See `docs/User_Guide.md` for usage.

### Detection, Autonomy and Confinement

- **Threat posture is enforced, not just displayed** — `orionx-postured` applies
  the tier you select. Tier 0 starts nothing; Tier 1 starts Suricata and
  publishes alerts with MITRE ATT&CK technique IDs; Tier 2 adds local-only
  decoys and canary files. If a tier implies IDS coverage but Suricata has no
  threat rules, the deck says so loudly rather than watching nothing in silence.
- **Auto-healing** — `orionx-heald` executes the action classes you pre-approve
  in the Control Center, with a real undo for each, rollback timers, and a
  hash-chained audit ledger (`orionx-heal verify`). It fails closed: with no
  autonomy file it does nothing. It will not block your own address, loopback or
  the mesh.
- **Confined AI tooling** — the MCP tool server runs as its own user under
  AppArmor with no outbound network at all, so the local model can use forensic
  tools without those tools gaining a network path.

### Diagnostic Tool

- **`orionx-diag`** — 46-assertion self-check across 10 categories (identity,
  version-manifest, packages, files, systemd, python, nebula, branding, freshen,
  optional). Run it as `sudo orionx-diag`.
- `orionx-diag --json` for machine-readable output
- `orionx-diag --category <name>` for targeted probes
- See `docs/orionx-diag.md` for full reference.
- **Not in v2.2.0-beta:** the tool was deleted by a build-staging bug and ships
  again from the next build (DEC-PHASE12-021).

### Cyberdeck Visual Identity

- **Plymouth**: Phoenix splash on boot (`orionx-phoenix` theme)
- **GRUB / isolinux**: plain, readable text menus (the graphical GRUB theme was retired after failing on hardware — DEC-PHASE11-044; the boot identity is the Plymouth splash)
- **Orion Cockpit**: live Cairo dashboard on the R.A.I.N. event bus (`orionx-cockpit`, ◈ COCKPIT in the Control Center); every Orion-X tool lives under the **Orion** application menu
- **LightDM greeter**: Orion-X-Greeter with Phoenix backdrop
- **XFCE GTK theme**: `Orion-X-Cyberdeck` (Adwaita-dark fork with Phoenix red-orange `#FF5722` accent)
- **Icons**: `Orion-X-Icons` (Papirus-Dark inheritance + 4 custom SVG icons)
- **Fonts**: **Hack** (Apache-2.0) — the only monospace font on the image, community-developed only per DEC-PHASE11-013. Iosevka is *not* shipped: no `fonts-iosevka` candidate exists in Debian 13 (#85)
- **MOTD** with ASCII wordmark on terminal login

---

## Quick Start

### 1. Get the ISO

**OrionX Beta (v2.2.0-beta, 3.09 GB):** GitHub caps release assets at 2 GB per
file, so the ISO is published as seven `.part-*` files (`part-aa` … `part-ag`,
≤1000 MiB each) plus `SHA256SUMS` and `REASSEMBLE.txt` on the
[release page](https://github.com/jarocki/orion/releases/tag/v2.2.0-beta).
Download all of them into one directory, then:

```bash
cat orionx-phoenix-edition-v2.2.0-beta.iso.part-* > orionx-phoenix-edition-v2.2.0-beta.iso
shasum -a 256 -c SHA256SUMS      # Linux: sha256sum -c SHA256SUMS
```

The reassembled ISO must hash to
`606e6179887ff7f82e9d05ed973333856c153a692d45983e16e35b12a0f0e49f`. A single
`.part-*` file is not bootable on its own.

You need a **USB stick of 8 GB or more** (everything on it will be erased) and an
**x86-64 PC or laptop** that can boot from USB with **Secure Boot turned off**
(see [Before you boot](#2-boot-the-target-machine-from-usb)).

**Option A — Host imager tool (macOS / Linux; recommended):**

The imager is a small Python program in this repository (no installation):
clone or download the repo, then run it from a terminal. It downloads the
release — split `.part-*` releases are reassembled and verified automatically —
checks the SHA-256, refuses to write to your internal disk, and writes the stick.

```bash
git clone https://github.com/jarocki/orion.git && cd orion

# GUI
scripts/orionx-imager/orionx-imager

# CLI — the beta is a pre-release, so name its tag explicitly
scripts/orionx-imager/orionx-imager-cli.sh --list-devices
scripts/orionx-imager/orionx-imager-cli.sh --iso-release v2.2.0-beta --target /dev/disk4 --dry-run
scripts/orionx-imager/orionx-imager-cli.sh --iso-release v2.2.0-beta --target /dev/disk4
```

`--iso-release latest` means the latest *stable* release (GitHub's rule), so
it skips betas; add `--allow-prerelease` to include them. Full reference:
[docs/orionx-imager.md](docs/orionx-imager.md). **Windows:** the imager does
not run on Windows yet — reassemble the parts with `copy /b` (see
`REASSEMBLE.txt`), check the hash with `Get-FileHash`, and write the ISO with
[Rufus](https://rufus.ie) in "DD image" mode.

**Option B — Manual dd (macOS / Linux):**

```bash
# macOS — find the stick's disk number with `diskutil list` (NOT disk0, that is your Mac)
diskutil list
diskutil unmountDisk /dev/disk4
sudo dd if=orionx-phoenix-edition-v2.2.0-beta.iso of=/dev/rdisk4 bs=4m status=progress
diskutil eject /dev/disk4

# Linux — find the stick with `lsblk` (NOT sda/nvme0n1 if that is your system disk)
lsblk
sudo dd if=orionx-phoenix-edition-v2.2.0-beta.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

### 2. Boot the target machine from USB

**Before you boot:** in the machine's firmware settings, turn **Secure Boot
off** (the beta's bootloader is unsigned) and allow booting from USB. On a
Windows laptop with BitLocker, have the recovery key at hand before you change
firmware settings — Windows may ask for it afterwards. Nothing on the internal
disk is touched by booting Orion-X unless you mount or image it yourself.

- Boot-menu key varies by maker: usually F12, F10, F9, Esc or Del at power-on
- The boot menu shows for **5 seconds**, then starts "Orion-X Live"
- **First boot:** a short text wizard runs on the console **before** the desktop
  and asks for a hostname (default `orionx-node`), the account name (default
  `orionx-operator`) and an optional password (blank = passwordless), and Wi-Fi
  only if no wired network is found. Each question times out to its default
  after 120 s, so an unattended boot still completes.
- Then the desktop opens **automatically logged in** as that account (it has
  `sudo` rights). If you log out, the login screen asks for the password you set
  (or just Enter if you left it blank).

### 3. Verify the boot

```bash
# Full self-check (run on the booted live system)
orionx-diag

# Targeted check
orionx-diag --category identity
orionx-diag --category nebula
```

Expected: all identity, manifest, packages, files, and systemd categories PASS.
See `docs/orionx-diag.md` for interpreting results.

---

## Development

```bash
make lint              # ShellCheck + ruff
make test-unit         # bash + python unit tests (~1400+ assertions)
make iso-build         # Full ISO build (Linux only; use Docker on macOS)
make docker-build      # Build the Debian Trixie container for ISO builds
# macOS: scripts/build-iso.sh delegates to debian:trixie-slim automatically;
# set ORIONX_VERSION=<tag> explicitly (git-describe resolves to the last tag).
make test-qemu-boot    # UEFI + BIOS QEMU boot smoke tests
```

CI pipelines: `.github/workflows/{lint,qemu-test,e2e-test,release}.yml`.

Contributor guide: [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md).

---

## Documentation

- [User Guide](docs/User_Guide.md) — Comprehensive operator manual
- [orionx-diag](docs/orionx-diag.md) — Diagnostic tool reference
- [orionx-imager](docs/orionx-imager.md) — Host-side USB writer reference
- [Release Process](docs/release-process.md) — rc-cut and hotfix cadence
- [Development Checklist](docs/DEVELOPMENT_CHECKLIST.md) — Contributor pre-commit gates
- [Architecture Decisions](MASTER_PLAN.md) — DEC-PHASE*-xxx series is canonical

---

## Phase 11 Status

16 slices landed on develop (2026-07-19 arc). This table is a **historical
record of the Bullseye line** — it says what each slice set out to do, not what
the current Trixie image contains. Where the two differ (radare2 and Iosevka in
particular), "What's on the ISO" above is authoritative.

| Slice | What |
|---|---|
| W11-1 | Nebula Qwen2.5-3B model swap (−2.5 GB, Apache-2.0) |
| W11-2 | Debloat (14 packages removed) + bootloader single-authority generator |
| W11-2b | SC2001 shellcheck hotfix |
| W11-2c | CI content-presence 4-failure hotfix |
| W11-2d | CI structural rewrite (16f) |
| W11-2e | Qwen SHA256 pin (closes #67) |
| W11-2f | XFCE screen lock disable (closes #76) |
| W11-9a | Plymouth + GRUB + isolinux + LightDM boot chain branding |
| W11-9a2 | GRUB theme activation in generator (closes #74) |
| W11-9b | Desktop branding (GTK/icons/fonts) + R6 root-cause fix (DEC-PHASE11-014) |
| W11-3 | RE toolkit Layer A (radare2, ssdeep, md5deep, pefile, capa) |
| W11-4 | YARA rulesets skeleton + orionx-freshen-yara |
| W11-5 | matrix-commander pip venv + comms skeleton |
| W11-6 | Suricata IDS Layer A (lazy-start + orionx-freshen-suricata) |
| W11-7 | ClamAV dropped from base ISO to optional installer |
| W11-8 | Optional installer framework (shared lib + 6 stubs) |
| W11-11 | `orionx-diag` in-ISO diagnostic tool (current: 46 assertions — see `docs/orionx-diag.md`) |
| W11-12 | `orionx-imager` host-side USB writer (GUI + CLI, macOS/Linux) |

**Phase 12 (Trixie line, v2.2.0-beta):** base flip to Debian 13, Orion Cockpit,
Orion menu, R.A.I.N., go-roast, nucleotide, Pivotglass, User Guide rewrite,
image trim 6.63 GB → 3.09 GB (DEC-PHASE12-001 … -017).

**Next:** move the language model out of the ISO into its own release asset so
the ISO itself fits GitHub's 2 GB single-asset limit (~1.2 GB projected);
imager-created persistence partition; merge `feat/trixie-migration` → `develop`;
update `release.yml` for the Trixie build container.

**ISO size:** 3.09 GB (v2.2.0-beta); target <2 GB without the bundled model.

---

## License and Attribution

Orion-X Phoenix Edition is distributed under **GPL-3.0**. Third-party components
carry their own licenses — see `manifest.json` for the full inventory.

Key permissive dependencies:
- Qwen2.5-3B-Instruct (Apache-2.0)
- Hack font (Bitstream Vera / Apache-2.0)
- ET-Open Suricata rules (BSD-2-Clause)
- YARA rules (licensing split documented in `/opt/orionx/yara/README.md`)

Explicitly **not** shipped: JetBrains software (per DEC-PHASE11-013 — community-developed fonts only).

---

## Support and beta feedback

- **Report a problem:** https://github.com/jarocki/orion/issues/new/choose
  (templates for bug reports and beta feedback tell you what to include)
- [docs/SUPPORT.md](docs/SUPPORT.md) — what to try first, what to send us, and
  how to get `orionx-diag` output off a live system that forgets everything
- [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md)
