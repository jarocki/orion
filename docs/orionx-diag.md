# orionx-diag — Diagnostic Tool Reference

**Shipped in:** v3.0.0 and the v2.2.0 release candidates from rc5 (first added in the v2.1.0 Bullseye line, W11-11).
**Source of truth:** `scripts/orionx-diag`
**Location on ISO:** `/usr/bin/orionx-diag` (symlink to `/opt/orionx/scripts/orionx-diag`)
**Decision:** DEC-PHASE11-015

> **History (beta audit BLK-1):** the tool was *missing* from the v2.2.0-beta
> image. The build staged `scripts/` over `/opt/orionx/scripts/` with
> `--delete`, and the tool lived only in the chroot overlay, so every build
> deleted it. The source now lives at `scripts/orionx-diag` — the directory the
> build stages — and the tool ships again. Content-presence section 27 is the
> regression gate.

---

## Overview

`orionx-diag` is the in-ISO self-verification tool for Orion-X Phoenix Edition.
It answers the question "is this running system actually a correctly-built Orion-X?"
by executing 46 structured assertions across 10 categories.

**Why it exists:** ISO builds pass CI gates (unit tests, content-presence, QEMU
boot) but those gates run against the *build tree*, not the *booted live system*.
Hardware boot surfaces a different class of failure: wrong user identity, missing
symlinks in the live filesystem, systemd units that failed to start, model files
that failed integrity. `orionx-diag` closes this gap by running on the live booted
system and asserting the exact conditions that production operation requires.

**When to run it:**

- After booting a new ISO on hardware (first-boot confidence check)
- After a field upgrade or USB re-image
- When diagnosing a tool that appears missing or broken
- Against a QEMU-booted image (`--json` output; no CI workflow invokes it today)
- Before declaring an incident response engagement ready

---

## Invocation

```bash
# Full check (all 10 categories)
sudo orionx-diag

# Machine-readable JSON output
sudo orionx-diag --json

# Single category
sudo orionx-diag --category identity
sudo orionx-diag --category nebula

# Verbose (shows SKIP reasons and full assertion text)
sudo orionx-diag --verbose

# Print the ISO version string and exit
orionx-diag --version
```

`orionx-diag` requires no arguments for a full run. Root (`sudo`) is required
for assertions that inspect systemd unit state and AppArmor profiles. The tool
never calls `sudo` itself.

---

## 10 Check Categories

The category list is the `_all_categories` array in the script; `--category`
accepts any of these names. Assertion texts below are the ones the tool prints.

### 1. `identity`

Verifies the live session's identity matches the build.

- `whoami == orionx-operator` — read from `SUDO_USER` when present, since the
  documented invocation is `sudo orionx-diag` and a bare `whoami` under sudo
  is always `root`
- `hostname set and consistent with /etc/hostname` — the wizard's default is
  `orionx-node`; the check accepts whatever the operator chose, as long as
  `hostname` and `/etc/hostname` agree (DEC-PHASE12-021)
- `/proc/cmdline` contains `live-config.username=orionx-operator`
- `/proc/cmdline` contains `live-config.hostname=orionx`

Example output:

```
[identity] whoami == orionx-operator ... PASS
[identity] hostname set and consistent with /etc/hostname ... PASS (orionx-node)
[identity] cmdline live-config.username=orionx-operator present ... PASS
[identity] cmdline live-config.hostname=orionx present ... PASS
```

### 2. `version-manifest`

Verifies `/etc/orionx-version` KEY=VALUE manifest fields are populated:
`ISO_VERSION`, `BUILD_TIMESTAMP`, `GIT_HEAD_SHA`, `GIT_HEAD_TITLE`,
`PHASE_11_SLICES` — each present and non-empty. See the manifest section below.

### 3. `packages`

Verifies the Debian packages the image depends on:

- `ssdeep` (fuzzy hashing), `hashdeep` (provides `md5deep`, `sha1deep`,
  `hashdeep`), `yara`, `python3-yara`, `suricata` installed
- `pefile` importable (from `python3-pefile` or the RE venv)
- `clamav` **ABSENT** (dropped from the base ISO per DEC-PHASE11-009; available
  via `/opt/orionx/optional/install-clamav.sh`)

`radare2` is not asserted: it is not packaged in Debian trixie and is not on the
image (#85). Ghidra is the reverse-engineering option, via `install-ghidra.sh`.

### 4. `files`

Verifies files and directories that must exist in the live filesystem:

- Nebula model weights present (> 1.5 GB) as a `models/blobs/sha256-*` blob in
  ollama's consolidated store (DEC-PHASE12-016 — there is no bare `.gguf`
  file), with `MANIFEST.sha256` alongside
- `capa` binary present in the RE venv (`/opt/orionx/venv/re/`)
- `/opt/orionx/comms/README.md`
- `/opt/orionx/yara/README.md` and `/opt/orionx/yara/LOCKFILE.json` (the
  rulesets themselves are fetched post-boot by `orionx-freshen-yara`)
- `/var/lib/suricata/orionx-README.md`
- Optional installer library `/opt/orionx/optional/lib/orionx-installer-common.sh`
- All 6 optional installers present and executable
  (`install-{clamav,ghidra,element,floss,trid,gomuks}.sh`)
- GTK theme `/usr/share/themes/Orion-X-Cyberdeck/`
- Plymouth theme `/usr/share/plymouth/themes/orionx-phoenix/`

The `files` category asserts no GRUB theme *directory*: the graphical GRUB
theme was retired (DEC-PHASE11-044) and the boot identity is the Plymouth
splash. The `branding` category checks that identity from the other side — see
§8.

### 5. `systemd`

Verifies systemd unit state for Orion-X managed services:

- `nebula-integrity-check.service` enabled
- `nebula-runtime.service` enabled (socket activation was removed in
  DEC-PHASE11-033 — there is no `nebula-runtime.socket`; the model is loaded
  lazily on the first request)
- `suricata.service` masked **or** gated by `ConditionPathExists=` (the
  lazy-start drop-in `suricata.service.d/orionx-lazy.conf`)
- `NetworkManager.service` enabled
- `lightdm.service` active or enabled

Suricata is held back on a fresh boot by design. Enable it per engagement:

```bash
sudo orionx-freshen-suricata                  # fetch ET-Open rules (network)
sudo touch /var/lib/suricata/orionx-enabled   # satisfy the ConditionPathExists gate
sudo systemctl start suricata
```

No `systemctl unmask` step is needed; the gate is the sentinel file.

### 6. `python`

- `from control_center.app import run_app` succeeds (the W9-2 import-path fix)
- `import yara` succeeds in the system Python (`python3-yara`)

### 7. `nebula`

- `/usr/local/bin/ollama` present and executable
- `ollama --version` exits 0
- Model SHA-256 matches `MANIFEST.sha256`
- `nebula-integrity-check` last run successful (reads
  `/var/log/orionx/nebula-integrity.log`)

### 8. `branding`

- Plymouth default theme is `orionx-phoenix`
- XFCE `xsettings.xml` references the `Orion-X-Cyberdeck` GTK theme
- `/etc/plymouth/plymouthd.conf` declares `Theme=orionx-phoenix`
- MOTD contains the `Orion-X Phoenix Edition` wordmark

**On the Plymouth assertions:** the two are deliberately different questions.
The first asks what Plymouth *resolves* at runtime via
`plymouth-set-default-theme`, and SKIPs where that binary is absent. The second
reads `/etc/plymouth/plymouthd.conf`, the declarative configuration authority
for the theme (DEC-PHASE11-010), and so holds on an installed system as well as
a live one.

This replaced an assertion that `/boot/grub/grub.cfg` contained a
`set theme=/boot/grub/themes/orionx/theme.txt` directive. DEC-PHASE11-044
retired the graphical GRUB theme after it failed on hardware, so the generated
`grub.cfg` no longer sets a theme at all — and on a live boot that file does not
exist in the running filesystem anyway. The old check therefore SKIPped on every
live session and would have FAILed on any installed-to-disk system built from
this tree, in both cases telling the operator nothing true about the image.

### 9. `freshen`

- `orionx-freshen-yara` symlink exists in `/usr/bin/` and its target is executable
- `orionx-freshen-suricata` symlink exists in `/usr/bin/` and its target is executable

### 10. `optional`

- All 6 installer scripts source `orionx-installer-common.sh`
- `orionx-installer-common.sh` defines all 7 required functions
  (`check_root`, `check_network`, `apt_install`, `wget_verified`,
  `verify_sha256`, `log_info`, `log_error`)

---

## Interpreting Results

### Exit codes

| Exit code | Meaning |
|---|---|
| `0` | All assertions in the requested scope PASSED (SKIPs allowed) |
| `1` | One or more assertions FAILED |
| `2` | Argument error (unknown flag or category) |

### Result tokens

| Token | Meaning |
|---|---|
| `PASS` | Assertion satisfied |
| `FAIL` | Assertion not satisfied -- investigate |
| `SKIP` | Assertion not applicable (e.g., `systemctl` unavailable, service not yet started by operator) |

`SKIP` is not a failure. Run with `--verbose` to see the SKIP reason.

### JSON output

```bash
sudo orionx-diag --json
```

Produces one JSON object on stdout, with per-category counts and the individual
assertions:

```json
{
  "iso_version": "v3.0.0",
  "build_timestamp": "2026-09-20T14:32:00Z",
  "git_head_sha": "0ab8fa1",
  "overall": "PASS",
  "pass": 46,
  "fail": 0,
  "skip": 0,
  "categories": {
    "identity": {
      "pass": 4, "fail": 0, "skip": 0,
      "assertions": [
        {"name": "whoami == orionx-operator", "status": "PASS", "detail": ""}
      ]
    },
    "packages": {"pass": 7, "fail": 0, "skip": 0, "assertions": [ ... ]}
  }
}
```

The three manifest fields (`iso_version`, `build_timestamp`, `git_head_sha`) are
read from `/etc/orionx-version`. The `pass`/`fail`/`skip` counts at the top level
are run totals; each category repeats its own counts. Top-level `overall` is
`"PASS"` only when no assertion FAILed — SKIPs do not affect it. Every assertion
object carries `name`, `status` (`PASS`/`FAIL`/`SKIP`) and `detail` (empty unless
the tool has something to say, e.g. the SKIP reason or the observed value).

### Scripted use

```bash
# Assert full pass
sudo orionx-diag --json | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d['overall'] != 'PASS':
    print('FAIL:', d)
    sys.exit(1)
print('orionx-diag: all assertions pass')
"

# Assert a specific category
sudo orionx-diag --json | python3 -c "
import sys, json
d = json.load(sys.stdin)
cat = d['categories']['nebula']
if cat['fail'] > 0:
    sys.exit(1)
"
```

To keep the result on an amnesic deck, write it to a second USB stick:
`sudo orionx-diag --json > /mnt/evidence/orionx-diag.json` (see the User Guide
§12 for mounting). The JSON contains the hostname, the kernel command line and
package/service names — no Wi-Fi credentials or mesh keys — but redact the
hostname if it identifies your organisation before attaching it to a public issue.

---

## `/etc/orionx-version` Manifest

`orionx-diag --version` reads from `/etc/orionx-version`, a KEY=VALUE file
written at build time by the `0700-orionx-setup.hook.chroot` hook from the
`/etc/orionx-build-env` fragment that `scripts/build-iso.sh` stages
(DEC-PHASE11-020). Fields:

| Key | Example value | Description |
|---|---|---|
| `ISO_VERSION` | `v3.0.0` | Release identity — `ORIONX_VERSION` at build time, else `git describe` |
| `BUILD_TIMESTAMP` | `2026-09-16T04:23:56Z` | ISO 8601 UTC build time |
| `GIT_HEAD_SHA` | `32247dd2734f` | Short SHA of the commit built |
| `GIT_HEAD_TITLE` | `fix(trim): …` | First line of that commit's message |
| `PHASE_11_SLICES` | `W11-1,W11-2,…` | Comma-separated list of slices baked in |

The v2.2.0-beta image carries `ISO_VERSION=v2.2.0-trixie-dev9` because it was
built with a development label; the release runbook now asserts the baked value
equals the tag before an image is published (`docs/release-process.md` §10).

If the build environment is lost, the 0700 hook writes `ISO_VERSION=unknown-build`,
and the MOTD prints `unknown-build` when it cannot read the key (DEC-PHASE12-129);
neither falls back to a string that looks like a real release.

---

## Troubleshooting Common Failures

**`[identity] whoami == orionx-operator ... FAIL`**

First check *how* you invoked the tool. It reads `SUDO_USER`, so `sudo
orionx-diag` from the operator account passes; running as root directly (a root
shell, or `su -`) leaves `SUDO_USER` unset and this reports `root`. That is the
documented invocation doing its job, not a fault in the image.

Otherwise the live session is running as a different user. Either the operator
renamed the account in the first-boot wizard (expected — the check reports the
new name) or `live-config.username=orionx-operator` is not reaching the kernel.
Check
`/proc/cmdline` and verify the bootloader configs were generated by
`scripts/build-iso.sh` (`# GENERATED` marker on line 1 of `grub.cfg` /
`isolinux.cfg`). See DEC-PHASE11-012.

**`[identity] hostname set and consistent with /etc/hostname ... FAIL`**

`hostname` and `/etc/hostname` disagree. The wizard sets both; if you changed
the hostname by hand, use `sudo hostnamectl set-hostname <name>` so both are
updated, or re-run `sudo orionx-wizard`.

**`[nebula] model SHA-256 matches MANIFEST.sha256 ... FAIL`**

The model bytes on the stick do not match the manifest baked with them. On a
freshly written stick this means a bad write — re-image and verify the ISO hash
first. On a stick that has been out of your control, treat it as a security
event: the model at rest has been modified.

**`[systemd] nebula-integrity-check.service enabled ... FAIL`** or
**`[nebula] nebula-integrity-check last run successful ... FAIL`**

The boot-time integrity gate did not run or did not pass. Read
`/var/log/orionx/nebula-integrity.log` for the exact mismatch. Most common
cause on a rebuilt image: the model changed but `MANIFEST.sha256` was not
regenerated (`scripts/nebula/store.py consolidate` rebinds it).

**`[packages] clamav ABSENT from base ... FAIL`**

ClamAV is present on this image, which means it was not removed per
DEC-PHASE11-009. This indicates a pre-W11-7 ISO. Use `install-clamav.sh` on a
current image instead.

**`[branding] xsettings.xml contains Orion-X-Cyberdeck GTK theme ... FAIL`**

The XFCE GTK theme is not set. On pre-W11-9b images `xsettings.xml` was written
to `/home/orionx/` (dead authority) instead of `/etc/skel/` (DEC-PHASE11-014).
Re-image with a current ISO.

---

## Reference

- **DEC-PHASE11-015** -- orionx-diag design decisions (scope, JSON schema,
  SKIP semantics)
- **DEC-PHASE11-033** -- `nebula-runtime.service` enabled directly; no socket unit
- **DEC-PHASE11-044** -- GRUB graphical theme retired
- **DEC-PHASE12-021** -- hostname check accepts the wizard's value
- Source: `scripts/orionx-diag` (staged to `/opt/orionx/scripts/orionx-diag`);
  operator notes in `scripts/README.md`
- Tests: `tests/unit/test_orionx_diag.sh` (six checks, T6a–T6f: structure,
  argument parsing, JSON shape, shellcheck)
- Content-presence: `tests/integration/test-iso-content-presence.sh` section 27
