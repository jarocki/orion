# Orion-X QEMU Boot Test Harness

Boots the Orion-X Phoenix Edition hybrid ISO under both BIOS (SeaBIOS) and
UEFI (OVMF) firmware in QEMU, captures the serial console to disk, and grants
PASS only when a known-good systemd boot milestone appears within the timeout
window. The harness is a single bash script — `scripts/qemu-boot-test.sh` —
that owns QEMU lifecycle, OVMF resolution, KVM detection, serial-log capture,
and PASS/FAIL/SKIP record-keeping for one run.

## Overview

The harness exists to prove the W7-3 goal-contract claim: **"ISO boots in
QEMU under UEFI and BIOS"** — without re-building the ISO, without diverging
the BIOS and UEFI definitions of "booted", and without silently passing when
firmware is missing.

What it does, in order:

1. Parse arguments and resolve runtime values (mode, ISO path, timeout).
2. Detect KVM availability via `[ -r /dev/kvm ]` and pick acceleration flags.
3. Run preflight checks: `qemu-system-x86_64` present, ISO file present,
   OVMF firmware resolved (when UEFI mode is requested).
4. For each requested mode, launch QEMU with the same hybrid ISO but
   different firmware:
   - **BIOS**: QEMU's default SeaBIOS, ISO as cdrom, boot from `d`.
   - **UEFI**: `-drive if=pflash,...,file=OVMF_CODE.fd` (readonly) plus a
     per-run writable copy of `OVMF_VARS.fd`, ISO as cdrom, boot from `d`.
5. Capture the serial console to `tmp/qemu-artifacts/<run-id>/serial-<mode>.log`
   and poll it for any entry in the `BOOT_SUCCESS_MARKERS` array. First match
   wins; the matched marker is recorded with the elapsed boot time.
6. Optionally invoke a W7-4 post-boot script and/or hold QEMU alive
   (`--keep-running`) for external attachment.
7. Tear QEMU down via the EXIT trap, then write
   `tmp/qemu-artifacts/<run-id>/qemu-boot-summary.json` with per-mode status,
   ISO SHA-256, OVMF path, KVM state, and elapsed seconds.

## Invocation

### Via Makefile (recommended)

```bash
make test-qemu-boot
# Override ISO path:
make test-qemu-boot ISO=output/some-other.iso
```

The `test-qemu-boot` target is a one-line wrapper that calls the bash harness
in `--mode both`.

### Direct invocation

```bash
bash scripts/qemu-boot-test.sh [options]
```

### CLI flags

| Flag | Description | Default |
|---|---|---|
| `--mode bios\|uefi\|both` | Boot mode(s) to test | `both` |
| `--iso <path>` | Path to hybrid ISO image | `output/orionx-phoenix-edition-v2.0.0-rc1.iso` |
| `--ovmf <path>` | Override `OVMF_CODE.fd` path for UEFI mode | distro-packaged path |
| `--timeout <sec>` | Per-mode boot timeout in seconds | `300` |
| `--post-boot-script <path>` | W7-4 attach point: host-side script run after boot marker is detected; receives `RUN_ID` and `SERIAL_LOG` as positional args | (none) |
| `--keep-running` | W7-4 attach point: hold QEMU alive after marker detection so an external driver can attach | off |
| `--dry-run` | Validate prerequisites (ISO, QEMU, OVMF) without launching QEMU | off |
| `--help` / `-h` | Show usage and exit | — |

Environment override: `ISO=<path> bash scripts/qemu-boot-test.sh --mode both`
(equivalent to `--iso`; explicit flag wins over env var, env var wins over
the default path).

### Examples

```bash
# Full BIOS+UEFI run against the default ISO
bash scripts/qemu-boot-test.sh --mode both

# BIOS-only, custom ISO, fast local timeout
bash scripts/qemu-boot-test.sh --mode bios --iso output/myiso.iso --timeout 90

# Validate prerequisites without booting
bash scripts/qemu-boot-test.sh --mode uefi --dry-run

# Explicit OVMF override (e.g. non-standard distro)
bash scripts/qemu-boot-test.sh --mode uefi --ovmf /opt/ovmf/OVMF_CODE.fd
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All requested modes PASS |
| `1` | At least one mode FAIL (preflight failure or boot timeout) |
| `2` | At least one mode SKIP, none failed (e.g. UEFI skipped because OVMF missing in `both` mode) |

## Dependencies

| Package | Debian/Ubuntu | Fedora/RHEL | macOS |
|---|---|---|---|
| QEMU x86_64 system emulator | `qemu-system-x86` | `qemu-system-x86` | `brew install qemu` |
| OVMF UEFI firmware | `ovmf` | `edk2-ovmf` | bundled with `qemu` |
| `sha256sum` (or `shasum`) | `coreutils` (default) | `coreutils` (default) | built-in |

CI installs `qemu-system-x86 ovmf` via apt on `ubuntu-latest`. Local
developers typically already have these from prior Phase 7 work.

## KVM vs TCG

The harness checks `[ -r /dev/kvm ]` once at startup and picks acceleration
flags accordingly:

| Mode | Flags | Typical boot time |
|---|---|---|
| KVM (Linux host with `/dev/kvm` access) | `-enable-kvm -cpu host` | ~30s |
| TCG fallback (no KVM, e.g. macOS, restricted CI runner) | `-accel tcg -cpu max` | ~120-270s |

The default `--timeout 300` covers the slowest realistic TCG path on any
`ubuntu-latest` SKU. Local KVM developers can pass `--timeout 90` for the
fast path. **Performance is informational only** per DEC-PHASE7-004 — PASS is
granted on marker detection within the timeout window; we do not gate on
boot speed.

## Boot-success markers

A boot is declared PASS when **any** of the following strings appears in the
serial log within the timeout. The list is the single authority for both BIOS
and UEFI modes — there is no per-mode override (DEC-PHASE7-020):

```bash
BOOT_SUCCESS_MARKERS=(
    "Reached target Multi-User System"     # systemd canonical (modern)
    "Reached target multi-user.target"     # systemd canonical (older)
    "orionx login:"                        # orionx getty banner
    "debian login:"                        # live-build default getty banner
)
```

First match wins. If a future Orion-X build emits a different banner, update
this array — do not add per-mode marker logic in `run_mode()`.

## Artifacts

Every run writes a `run-id`-stamped directory under `tmp/qemu-artifacts/`
(Sacred Practice 3 — never `/tmp/`):

```
tmp/qemu-artifacts/<run-id>/
  serial-bios.log              # Full BIOS-mode serial console capture
  serial-uefi.log              # Full UEFI-mode serial console capture
  OVMF_VARS.fd                 # Per-run writable UEFI variable store (UEFI mode only)
  qemu-boot-summary.json       # Per-mode status, timing, ISO SHA-256, OVMF path, KVM state
```

The `run-id` is `YYYYMMDD-HHMMSS` from the harness start time. Multiple
back-to-back runs never collide.

### `qemu-boot-summary.json` shape

```json
{
  "harness_version": "1.0.0",
  "run_id": "20260428-143012",
  "iso_path": "/abs/path/to/orionx-phoenix-edition-v2.0.0-rc1.iso",
  "iso_sha256": "abc123...",
  "host_kvm": true,
  "ovmf_path": "/usr/share/OVMF/OVMF_CODE.fd",
  "timeout_sec": 300,
  "bios": { "status": "PASS", "boot_seconds": 28 },
  "uefi": { "status": "PASS", "boot_seconds": 31 }
}
```

`status` values: `PASS`, `FAIL`, `SKIP`, `NOT_RUN`. `ovmf_path` is `null` when
no UEFI mode ran.

## W7-4 attach contract

W7-3 declares a stable surface for W7-4 (mesh + Matrix + AppArmor runtime
verification inside the booted VM) so W7-4 can attach **without modifying
this harness**. This contract is fixed at W7-3 land time per DEC-PHASE7-022.

### `--post-boot-script <path>`

When set, after a successful boot-marker match the harness invokes:

```
bash <path> <RUN_ID> <SERIAL_LOG>
```

- `<RUN_ID>` is the harness run-id (e.g. `20260428-143012`).
- `<SERIAL_LOG>` is the absolute path to `tmp/qemu-artifacts/<run-id>/serial-<mode>.log`
  for the mode that just booted.
- The script runs **per mode** — it fires once after BIOS boot and once after
  UEFI boot when `--mode both` is used.
- A non-zero exit from the post-boot script is logged as a warning. The
  boot itself remains PASS. W7-4 should treat its own pass/fail in a separate
  artifact, not by failing the boot harness.
- The harness does not pipe stdin to the script. Drive the VM via the host
  side (forwarded ports, QEMU monitor socket, guest-agent, or whatever
  channel W7-4 selects).

### `--keep-running`

When set, after a successful boot-marker match the harness **does not** kill
the QEMU process. It records the QEMU PID and exits the per-mode block,
leaving the VM available for external attachment. The harness's EXIT trap
still cleans up on overall script exit, so callers using `--keep-running`
should attach inside the post-boot script's lifetime or fork their driver
before the harness returns.

Useful combinations:

```bash
# W7-4 launches its own driver against the booted VM
bash scripts/qemu-boot-test.sh --mode bios \
  --post-boot-script tests/integration/test-mesh-on-qemu.sh \
  --keep-running

# Sanity attach: hold UEFI alive for manual monitor inspection
bash scripts/qemu-boot-test.sh --mode uefi --keep-running
```

W7-4's own driver script, scope manifest, and Evaluation Contract live in
the W7-4 plan. The harness commitment is: **these two flags will continue to
mean what this section says** for the lifetime of W7-3.

## CI workflow

`.github/workflows/qemu-test.yml` runs the harness on every push and pull
request to `develop`:

- Runner: `ubuntu-latest`
- Timeout: `30 minutes` (covers `iso-build` ~10-15min plus two TCG boot
  cycles ~5-9min each with headroom)
- Steps: checkout → install `qemu-system-x86 ovmf` → log QEMU/OVMF/KVM
  state → setup Python 3.11 → install `requirements.txt` → `make iso-build`
  (W7-1 deliverable) → `make test-qemu-boot` → upload
  `tmp/qemu-artifacts/` as `qemu-artifacts-<github.run_id>` (always, even on
  failure).

The workflow does not branch on KVM availability — the harness handles that
internally. CI artifacts are retained per the GitHub Actions default
retention policy and are sufficient to debug any failure offline.

## Failure debugging

When a mode FAILs, the harness:

1. Logs `[FAIL] <MODE> boot FAILED: timeout after <N>s — no boot marker found`.
2. Prints the path to the serial log.
3. Echoes the **last 50 lines** of the serial log to stdout for immediate
   inspection.
4. Sends `SIGTERM` to the QEMU process, then `SIGKILL` after 10s if it does
   not exit.
5. Records `FAIL` in the per-mode status and continues to the next mode (or
   exits non-zero if this was the last mode).

### Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `Preflight failed`, `qemu-system-x86_64 not found` | QEMU not installed on host | `sudo apt-get install qemu-system-x86` (Debian) / `brew install qemu` (macOS) |
| `Preflight failed`, `ISO not found` | `make iso-build` not run yet, or `--iso` path wrong | Run `make iso-build` or pass `--iso <path>` |
| `[SKIP] OVMF firmware not found` (in `--mode uefi`) | `ovmf` package missing | `sudo apt-get install ovmf` (Debian) / `sudo dnf install edk2-ovmf` (Fedora). `--mode both` will still run BIOS. |
| `UEFI boot FAILED: timeout` but BIOS passes | grub-efi config in the ISO is broken, or OVMF version mismatch | Inspect `serial-uefi.log` for grub errors; verify `iso/auto/config` still sets `--bootloader 'syslinux,grub-efi'` |
| `BIOS boot FAILED: timeout` but UEFI passes | isolinux config broken in the ISO | Inspect `serial-bios.log`; W7-1 isolinux assets |
| Both modes FAIL with `Loading initrd...` then nothing | TCG too slow for default timeout | Pass `--timeout 600` and re-run, or run on a host with KVM |
| `host_kvm: false` in summary on a Linux host you expect KVM on | User cannot read `/dev/kvm` | `sudo usermod -aG kvm $USER` and re-login, or run with `sudo` |

### Debugging tips

- The full serial log is always at `tmp/qemu-artifacts/<run-id>/serial-<mode>.log`,
  not just the last 50 lines printed to stdout.
- Re-run with `--keep-running` to hold the VM alive and attach a QEMU monitor
  socket for live inspection (requires editing the harness to add `-monitor`
  socket flags — not part of the W7-3 surface).
- The summary JSON's `iso_sha256` field lets you correlate a failure with a
  specific ISO build.

## Decision references

Decisions DEC-PHASE7-017 through DEC-PHASE7-022 are the design authorities for
this harness. Full text lives in `MASTER_PLAN.md`'s Decision Log. One-line
summaries:

| ID | Title |
|---|---|
| DEC-PHASE7-017 | Single bash harness `scripts/qemu-boot-test.sh`, not Python or Make-only |
| DEC-PHASE7-018 | Boot the SAME hybrid ISO twice with different QEMU firmware (no UEFI-specific build) |
| DEC-PHASE7-019 | OVMF resolution order with explicit SKIP on missing firmware (never silent PASS) |
| DEC-PHASE7-020 | Serial-file capture with single-constant boot-success marker matcher |
| DEC-PHASE7-021 | KVM-when-available, TCG-fallback, 300s default timeout (covers slowest CI path) |
| DEC-PHASE7-022 | Pre-declared W7-4 attach contract: `--post-boot-script` + `--keep-running` |

| Annotation location | Decisions |
|---|---|
| `scripts/qemu-boot-test.sh` (header) | DEC-PHASE7-017, 018, 019, 020, 021, 022 |
| `.github/workflows/qemu-test.yml` (header) | DEC-PHASE7-019, 021 |
| `Makefile` (`test-qemu-boot` target) | DEC-PHASE7-017 |

When code and this doc disagree about behavior, **code is truth** (Sacred
Practice 7). Update this doc to match, or — if the divergence is unintended
— file a bug against the harness.
