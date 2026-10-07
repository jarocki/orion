# orionx-imager — Host-Side ISO Downloader + USB Writer

**Ships in:** repo `scripts/orionx-imager/` (not on ISO — host tool)
**Modeled after:** Raspberry Pi Imager
**Decision:** DEC-PHASE11-015
**Layer A supports:** macOS + Linux (Windows deferred to W11-12b)

## Overview

`orionx-imager` downloads an Orion-X release ISO from GitHub Releases,
verifies its SHA256 against the release manifest, and guides you through writing
it to a bootable USB device with internal-disk safety checks.

Releases larger than GitHub's 2 GB asset limit are published as
`<name>.iso.part-aa`, `.part-ab`, … The imager detects that form, downloads
the parts (each verified against `SHA256SUMS`; a bad part is named so you only
re-fetch that one), reassembles them in the cache and verifies the whole ISO
before anything is written (DEC-PHASE12-019). You never handle parts by hand.

**"latest" means the latest stable release** — GitHub's `/releases/latest`
never returns a pre-release. v3.0.0 is the first stable release, so `latest`
resolves to it; to get a pre-release such as the v2.2.0-beta, name its tag
(`--iso-release v2.2.0-beta`) or pass `--allow-prerelease` with `latest`.

Two front-ends over the same Python 3 core:

- **`orionx-imager`** — Python tkinter GUI (run without args)
- **`orionx-imager-cli.sh`** — bash CLI wrapper (scripting / headless)

Both use only Python 3 stdlib — no pip install, no venv, no third-party deps.

## Quick Start (GUI)

```bash
# From the repo checkout:
cd /path/to/orion
scripts/orionx-imager/orionx-imager
```

Then in the window:

1. **SELECT DEVICE** — pick a USB from the dropdown (internal disks are excluded)
2. **SELECT ISO** — choose "Latest release" (auto-download) or "Local file"
3. Check the ERASE confirmation box
4. Click WRITE
5. Type `ERASE` in the confirmation dialog

## Quick Start (CLI)

```bash
# List available USB devices
scripts/orionx-imager/orionx-imager-cli.sh --list-devices

# Dry-run: show what would happen
scripts/orionx-imager/orionx-imager-cli.sh \
  --iso-release latest \
  --target /dev/disk4 \
  --dry-run

# Actual write
scripts/orionx-imager/orionx-imager-cli.sh \
  --iso-release latest \
  --target /dev/disk4
```

## CLI Flags

| Flag | Description |
|---|---|
| `--list-devices` | Enumerate USB / removable devices, exit 0 |
| `--iso <path>` | Use a local ISO file |
| `--iso-release latest` | Download the latest **stable** GitHub release from `jarocki/orion` |
| `--iso-release <tag>` | Download a specific release tag (e.g. `v3.0.0`, or a pre-release such as `v2.2.0-beta`) |
| `--allow-prerelease` | With `--iso-release latest`: include pre-releases (betas) |
| `--target <device>` | Write target (e.g., `/dev/disk4` macOS, `/dev/sdb` Linux) |
| `--dry-run` | Print the write plan without executing |
| `--skip-verify` | Skip SHA256 verification (NOT recommended; CLI-only; needs `--yes-really-skip-verify` too) |
| `--yes-really-skip-verify` | Second flag required before `--skip-verify` takes effect |
| `--force` | Skip the interactive confirmation (CI/testing only) |
| `--list-releases` | List the GitHub releases and exit |
| `--clear-cache` | Clear the local ISO download cache and exit |
| `--i-really-know-what-im-doing` | Bypass internal-disk refuse-list (DANGEROUS) |
| `--version` | Print imager version |
| `--help` | Show this help |

## Safety

Multiple layers prevent common mistakes:

1. **Internal-disk refuse-list** — the disk holding your running system is hard-refused: `/dev/disk0` on macOS; on Linux the whole disk behind `/` (SATA, NVMe or eMMC, resolved through LUKS/LVM), and `/dev/sda` unconditionally if the root disk cannot be determined. Override requires `--i-really-know-what-im-doing` on CLI only (GUI has no bypass).
2. **Mandatory SHA256 verification by default** — SHA256SUMS from the GitHub release is downloaded alongside the ISO and verified before write. CLI can opt out with `--skip-verify`; GUI cannot.
3. **Type-`ERASE` confirmation** — both CLI and GUI require typing the word "ERASE" (case-sensitive) as a final safety gate.
4. **Dry-run default is off** — you always know if you're about to actually write.

## Platform Support

### macOS

- Uses `diskutil list` to enumerate removable disks.
- Writes with the imager's own raw writer (`lib/raw_write.py`, run under `sudo`): 4 MiB chunks to the raw node `/dev/rdiskN` (~10x faster than `/dev/diskN`), reporting exact bytes written.
- Unmounts target automatically before write.

### Linux

- Uses `lsblk -Jo NAME,TYPE,SIZE,MODEL,VENDOR,RM,MOUNTPOINT` (JSON) to enumerate removable disks.
- Writes with the same raw writer (`lib/raw_write.py` under `sudo`, 4 MiB chunks).
- Unmounts any mounted partitions first.

### Windows — not supported by the imager

The imager does not run on Windows (no device enumeration or raw writer for it
yet; DEC-PHASE11-015). Windows users:

1. Download every `.part-*` file plus `SHA256SUMS` from the release page.
2. Reassemble with `copy /b` exactly as `REASSEMBLE.txt` shows (list every part, in order).
3. Check the hash: `Get-FileHash orionx-phoenix-edition-<version>.iso -Algorithm SHA256`
   (PowerShell prints it in UPPER CASE; compare letters case-insensitively).
4. Write with [Rufus](https://rufus.ie): select the ISO, keep the defaults, and choose
   **"Write in DD Image mode"** when Rufus asks. Windows may then offer to
   "format" the stick — click **Cancel**; the stick is correct as written.

WSL2 users can run the Linux imager path inside WSL only if the USB device is
attached to WSL (usbipd); most people will find Rufus simpler.

## Architecture

Under `scripts/orionx-imager/`:

- `orionx-imager` — Python entry point; delegates to CLI when args provided, launches tkinter GUI otherwise
- `orionx-imager-cli.sh` — bash wrapper that calls the Python entry with `python3`
- `lib/downloader.py` — GitHub Releases REST API v3 client, streaming download with progress
- `lib/writer.py` — unmount, then run the elevated writer and relay its progress
- `lib/raw_write.py` — the root-side raw copy (stdlib only; prints cumulative bytes)
- `lib/devices.py` — Platform-specific USB enumeration + refuse-list

## Troubleshooting

**"REFUSED: /dev/diskN is on internal-disk refuse list"**
You selected an internal disk. Choose a USB device from `--list-devices`.

**"SHA256 mismatch"**
The downloaded ISO doesn't match the release's SHA256SUMS. Do NOT write. Try re-downloading; if it persists, verify you're pulling from the official repo (`jarocki/orion`) and file an issue.

**"tkinter TclError" on GUI launch**
tkinter isn't available (rare on macOS/Linux system Python). Use the CLI instead, or install `python3-tk` (Debian) / `python-tk` (Homebrew).

**"Operation not permitted" during the write**
The write needs root. The CLI runs the raw writer with `sudo` (be at the terminal to enter your password); the GUI asks for the password in a dialog.

## Post-Write

After a successful write:

1. Eject the USB (`diskutil eject /dev/disk4` on macOS)
2. Boot the target machine from USB (Secure Boot off; boot-menu key F12/F10/F9/Esc/Del)
3. Answer the first-boot wizard on the console (hostname, account name, optional
   password, Wi-Fi if no cable) — or wait 120 s per prompt for the defaults —
   then the desktop opens automatically logged in (see [User Guide](User_Guide.md))
4. Run `sudo orionx-diag` in a terminal to verify the boot (see [orionx-diag](orionx-diag.md))

## References

- Source: `scripts/orionx-imager/`
- Tests: `tests/unit/test_orionx_imager.sh`
- Decision: DEC-PHASE11-015 (in `MASTER_PLAN.md`)
- Related: `docs/orionx-diag.md` (in-ISO diagnostic), `docs/release-process.md` (rc-cut cadence)
