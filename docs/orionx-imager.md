# orionx-imager — Host-Side ISO Downloader + USB Writer

**Ships in:** repo `scripts/orionx-imager/` (not on ISO — host tool)
**Modeled after:** Raspberry Pi Imager
**Decision:** DEC-PHASE11-015
**Layer A supports:** macOS + Linux (Windows deferred to W11-12b)

## Overview

`orionx-imager` downloads the latest Orion-X release ISO from GitHub Releases,
verifies its SHA256 against the release manifest, and guides you through writing
it to a bootable USB device with internal-disk safety checks.

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
| `--iso-release latest` | Download latest GitHub release from `jarocki/orion` |
| `--iso-release <tag>` | Download a specific release tag |
| `--target <device>` | Write target (e.g., `/dev/disk4` macOS, `/dev/sdb` Linux) |
| `--dry-run` | Print the write plan without executing |
| `--skip-verify` | Skip SHA256 verification (NOT recommended; CLI-only) |
| `--i-really-know-what-im-doing` | Bypass internal-disk refuse-list (DANGEROUS) |
| `--version` | Print imager version |
| `--help` | Show this help |

## Safety

Multiple layers prevent common mistakes:

1. **Internal-disk refuse-list** — `/dev/disk0` on macOS and `/dev/sda`/`/dev/nvme0n1` on Linux are hard-refused. Override requires `--i-really-know-what-im-doing` on CLI only (GUI has no bypass).
2. **Mandatory SHA256 verification by default** — SHA256SUMS from the GitHub release is downloaded alongside the ISO and verified before write. CLI can opt out with `--skip-verify`; GUI cannot.
3. **Type-`ERASE` confirmation** — both CLI and GUI require typing the word "ERASE" (case-sensitive) as a final safety gate.
4. **Dry-run default is off** — you always know if you're about to actually write.

## Platform Support

### macOS

- Uses `diskutil list` to enumerate removable disks.
- Writes via `sudo dd if=<iso> of=/dev/rdiskN bs=4m` (raw device for ~10x speed).
- Unmounts target automatically before write.

### Linux

- Uses `lsblk -Jo NAME,TYPE,SIZE,MODEL,VENDOR,RM` (JSON) to enumerate removable disks.
- Writes via `sudo dd if=<iso> of=/dev/sdX bs=4M status=progress`.
- Unmounts any mounted partitions first.

### Windows (deferred to W11-12b)

Not currently supported. See DEC-PHASE11-015 for rationale. Windows users can:
- Use WSL2 with the Linux path
- Use Rufus, BalenaEtcher, or Raspberry Pi Imager (with the ISO downloaded manually + SHA256 verified per `docs/release-process.md`)

## Architecture

Under `scripts/orionx-imager/`:

- `orionx-imager` — Python entry point; delegates to CLI when args provided, launches tkinter GUI otherwise
- `orionx-imager-cli.sh` — bash wrapper that calls the Python entry with `python3`
- `lib/downloader.py` — GitHub Releases REST API v3 client, streaming download with progress
- `lib/writer.py` — Platform-dispatched `dd` invocation with unmount + progress
- `lib/devices.py` — Platform-specific USB enumeration + refuse-list

## Troubleshooting

**"REFUSED: /dev/diskN is on internal-disk refuse list"**
You selected an internal disk. Choose a USB device from `--list-devices`.

**"SHA256 mismatch"**
The downloaded ISO doesn't match the release's SHA256SUMS. Do NOT write. Try re-downloading; if it persists, verify you're pulling from the official repo (`jarocki/orion`) and file an issue.

**"tkinter TclError" on GUI launch**
tkinter isn't available (rare on macOS/Linux system Python). Use the CLI instead, or install `python3-tk` (Debian) / `python-tk` (Homebrew).

**"Operation not permitted" from dd**
You need `sudo`. Both CLI and GUI paths invoke `sudo dd`; be at the terminal to enter your password.

## Post-Write

After a successful write:

1. Eject the USB (`diskutil eject /dev/disk4` on macOS)
2. Boot the target machine from USB
3. Autologin as `orionx-operator` (see [User Guide](User_Guide.md))
4. Run `orionx-diag` to verify the boot (see [orionx-diag](orionx-diag.md))

## References

- Source: `scripts/orionx-imager/`
- Tests: `tests/unit/test_orionx_imager.sh`
- Decision: DEC-PHASE11-015 (in `MASTER_PLAN.md`)
- Related: `docs/orionx-diag.md` (in-ISO diagnostic), `docs/release-process.md` (rc-cut cadence)
