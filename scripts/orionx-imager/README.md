# orionx-imager

Host-side ISO downloader and USB writer for Orion-X.
Modeled after Raspberry Pi Imager: pick a USB device, pick an ISO source, write.

Layer A (this release): macOS + Linux, stdlib-only Python (no pip install).
Layer B (W11-12b): Windows, packaged installers, real progress bars, code-signing.

Reference: DEC-PHASE11-015.

---

## What This Is

`orionx-imager` automates the four steps an operator must take to image a USB
drive with Orion-X:

1. **Find** the correct ISO on GitHub Releases.
2. **Verify** its SHA256 against the release manifest (many operators skip this —
   the tool does it automatically and refuses to write on mismatch).
3. **Identify** the target USB device without accidentally picking the system disk.
4. **Write** with `dd` correctly (block size, unmount first, sync after).

It adds safety the manual approach lacks: a refuse-list that hard-blocks writes
to `/dev/disk0` (macOS system disk) and `/dev/sda` when it is the Linux root
device, mandatory SHA256 verification by default, and a type-to-confirm
prompt before any data is erased.

---

## Requirements

### macOS

- Python 3.9+ (bundled with macOS 12+; for older macOS download from python.org)
- `tkinter` (bundled with the macOS Python installer from python.org)
- `sudo` access for the write step

### Linux (Debian/Ubuntu)

- Python 3.9+: `sudo apt install python3`
- tkinter (GUI only): `sudo apt install python3-tk`
- `lsblk` (part of `util-linux`, present on all major distros)
- `findmnt` (part of `util-linux`; used for root-device detection)
- `sudo` access for the write step

### Windows

Deferred to W11-12b. For now, use WSL2 with the Linux CLI path.

---

## Installation

No pip install required. Clone the repo and run directly:

```bash
git clone https://github.com/jarocki/orion.git
cd orion/scripts/orionx-imager
```

---

## Quickstart — GUI (macOS / Linux with desktop)

```bash
cd orion/scripts/orionx-imager
./orionx-imager
```

The GUI opens. Left panel: select your USB device. Right panel: choose ISO
source (latest GitHub release, specific tag, or local file). Check the
confirmation box, then click **WRITE** and type `ERASE` to confirm.

Use **Dry Run** to preview what would happen without writing anything.

---

## Quickstart — CLI (headless / scripted)

### List connected USB devices

```bash
./orionx-imager-cli.sh --list-devices
```

### Dry run (preview without writing)

```bash
./orionx-imager-cli.sh --dry-run --iso-release latest --target /dev/disk4
```

### Download latest release and write to USB

```bash
./orionx-imager-cli.sh --iso-release latest --target /dev/disk4
```

You will be prompted to type the device path to confirm before any write occurs.

### Write a local ISO

```bash
./orionx-imager-cli.sh --iso ~/Downloads/orionx-v2.0.0.iso --target /dev/sdb
```

### Scripted / CI use (skip interactive confirmation)

```bash
./orionx-imager-cli.sh --iso-release v2.0.0 --target /dev/sdb --force
```

`--force` bypasses the interactive confirmation prompt. For CI/testing use only.

---

## Safety Model

### Refuse-list (hard-blocks internal system disks)

The tool refuses to write to:

- `/dev/disk0` on macOS — always the internal boot volume container on Apple
  Silicon and Intel Macs. There is no safe scenario for writing an ISO here.
- `/dev/sda` on Linux when it is the root device (detected via `findmnt --target /`).
  If `/dev/sda` is not the root device, the tool warns loudly and requires
  `--i-really-know-what-im-doing` to proceed.

To bypass (DANGEROUS — for CI/testing only):

```bash
./orionx-imager-cli.sh --iso <file> --target /dev/disk0 \
    --i-really-know-what-im-doing --force
```

The GUI has no bypass path for the refuse-list.

### SHA256 mandatory verification

SHA256 verification is **on by default**. The tool downloads the `SHA256SUMS`
asset from the GitHub release (emitted by `.github/workflows/release.yml`) and
verifies the downloaded ISO before writing. On mismatch the tool aborts with a
clear error.

To skip verification (NOT recommended):

```bash
./orionx-imager-cli.sh --iso-release latest --target /dev/sdb \
    --skip-verify --yes-really-skip-verify
```

Both flags are required (two-flag opt-out). The GUI never exposes skip-verify.

### Mandatory target confirmation

In interactive mode the CLI prints the device details and requires you to type
the device path back. The GUI requires typing `ERASE` in a modal dialog.
`--force` bypasses CLI confirmation; the GUI always requires `ERASE`.

---

## ISO Download Cache

Downloaded ISOs are cached at:

```
~/.cache/orionx-imager/        (Linux / macOS, or $XDG_CACHE_HOME/orionx-imager/)
```

Re-running the same release tag skips the download if the cached ISO passes
SHA256 verification. To clear the cache:

```bash
./orionx-imager-cli.sh --clear-cache
```

---

## CLI Reference

```
--list-devices               List removable USB devices and exit
--list-releases              List available GitHub release tags and exit
--iso-release <TAG|latest>   Download ISO from GitHub release
--iso <PATH>                 Use a local ISO file
--target <DEVICE>            Target block device (/dev/disk4, /dev/sdb, ...)
--dry-run                    Preview plan without writing
--skip-verify                Skip SHA256 (requires --yes-really-skip-verify)
--yes-really-skip-verify     Second flag for skip-verify opt-out
--force                      Skip interactive confirmation (CI/testing only)
--clear-cache                Remove cached downloads
--i-really-know-what-im-doing  Bypass refuse-list (DANGEROUS)
--version                    Print version
--help                       Print help
```

---

## Troubleshooting

**"GitHub API rate limit exceeded"**
The GitHub Releases API allows 60 unauthenticated requests per hour per IP.
Wait ~60 minutes, or use a local ISO with `--iso <path>`.

**"Permission denied" writing to device (Linux)**
Run with `sudo`, or add yourself to the `disk` group:
`sudo usermod -aG disk $USER` (log out and back in).

**"Resource busy" / "Couldn't unmount disk" (macOS)**
The tool runs `diskutil unmountDisk` automatically. If it persists, unmount
manually first: `diskutil unmountDisk /dev/diskN`

**"No module named tkinter" (Linux)**
Install the tkinter package: `sudo apt install python3-tk`
Or use the CLI (no tkinter needed): `./orionx-imager-cli.sh`

**"/dev/sda" refused on Linux even though it's a USB drive**
If `/dev/sda` is your root device, the refuse-list blocks it. Check
`lsblk` to confirm — USB drives usually appear as `/dev/sdb` or later.
If `/dev/sda` is genuinely a USB (not root), use `--i-really-know-what-im-doing`.

---

## Layer B Deferrals (W11-12b)

The following are deferred to W11-12b and are not present in this Layer A release:

- **Windows support** — Use WSL2 with the Linux CLI path in the meantime.
- **Real progress bar** — Layer A shows a log window; deterministic byte-count
  progress (via `pv` or `/sys/block/<dev>/stat` polling) is Layer B.
- **Packaged installers** — `.app` bundle (macOS), AppImage (Linux), `.msi` (Windows).
- **Code-signing / notarization** — macOS Gatekeeper + distro-signed packages.
- **Auto-update** of the tool itself.
- **Verification-after-write** — SHA256 of the first N MB of the written USB
  compared to the ISO (confirms the write succeeded, not just the download).
- **`.desktop` entry and icon** — menu integration for Linux desktop environments.

---

## License

Inherits the project license. See `LICENSE.md` in the repository root.
