# orionx-diag — Diagnostic Tool Reference

**Shipped in:** v2.1.0-dev (W11-11)
**Location on ISO:** `/usr/bin/orionx-diag` (symlink to `/opt/orionx/scripts/orionx-diag`)
**Decision:** DEC-PHASE11-015

---

## Overview

`orionx-diag` is the in-ISO self-verification tool for Orion-X Phoenix Edition.
It answers the question "is this running system actually a correctly-built Orion-X?"
by executing up to 200 structured assertions across 10 categories.

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
- In CI (via `--json` output) to validate QEMU-booted images
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
for assertions that inspect systemd unit state and AppArmor profiles.

---

## 10 Check Categories

### 1. `identity`

Verifies the live system's runtime identity matches the Orion-X build.

Assertions (4):
- `whoami` returns `orionx-operator`
- `hostname` returns `orionx`
- `/proc/cmdline` contains `live-config.username=orionx-operator`
- `/proc/cmdline` contains `live-config.hostname=orionx`

Example output:

```
[identity] whoami == orionx-operator ... PASS
[identity] hostname == orionx ... PASS
[identity] /proc/cmdline live-config.username=orionx-operator ... PASS
[identity] /proc/cmdline live-config.hostname=orionx ... PASS
```

### 2. `version-manifest`

Verifies `/etc/orionx-version` KEY=VALUE manifest fields are populated.

Assertions (5):
- `ISO_VERSION` key present and non-empty
- `BUILD_TIMESTAMP` key present and non-empty
- `GIT_HEAD_SHA` key present and non-empty
- `GIT_HEAD_TITLE` key present and non-empty
- `PHASE_11_SLICES` key present and non-empty

See the `/etc/orionx-version` reference section below for field semantics.

### 3. `packages`

Verifies installed Debian packages match the W11-3 through W11-7 Layer A manifest.

Assertions (8):
- `radare2` installed (RE toolkit, W11-3)
- `ssdeep` installed (fuzzy hashing, W11-3)
- `md5deep` installed (hash sets, W11-3)
- `yara` installed (YARA engine, W11-4)
- `python3-yara` installed (Python YARA bindings, W11-3)
- `suricata` installed (IDS, W11-6)
- `python3-pefile` installed (PE parsing, W11-3)
- `clamav` ABSENT (dropped from base ISO per DEC-PHASE11-009 / W11-7)

The ClamAV absence gate is intentional: ClamAV's signature database is large
(~350 MB) and freshness-decays within hours, making it unsuitable for a static
ISO. It is available via `/opt/orionx/optional/install-clamav.sh`.

### 4. `files`

Verifies files and directories that must exist in the live filesystem.

Assertions (12):
- Nebula model GGUF file present in `/opt/orionx/nebula/models/`
- `MANIFEST.sha256` present alongside the model
- capa virtual environment present at `/opt/orionx/venv/re/`
- comms skeleton present at `/opt/orionx/venv/comms/`
- YARA rules directory present at `/opt/orionx/yara/`
- Suricata skeleton directory present at `/var/lib/suricata/`
- Optional installer library present at `/opt/orionx/optional/orionx-installer-common.sh`
- All 6 optional installers present (`install-{clamav,ghidra,element,floss,trid,gomuks}.sh`)
- GTK theme directory present at `/usr/share/themes/Orion-X-Cyberdeck/`
- Plymouth theme directory present at `/usr/share/plymouth/themes/orionx-phoenix/`
- GRUB theme directory present at `/boot/grub/themes/orionx/`

### 5. `systemd`

Verifies systemd unit state for Orion-X managed services.

Assertions (5):
- `nebula-integrity-check.service` exists and last-result is `success`
- `nebula-runtime.socket` is active (listening)
- `suricata.service` is masked (lazy-start per DEC-PHASE11-007)
- `NetworkManager.service` is active
- `lightdm.service` is active

The Suricata `masked` state is expected on a fresh boot. Suricata is enabled
per-engagement by running:

```bash
sudo touch /var/lib/suricata/orionx-enabled
sudo systemctl unmask suricata
sudo systemctl start suricata
```

### 6. `python`

Verifies Python package availability and import paths in the live venv.

Assertions (2):
- `from control_center.app import run_app` succeeds (validates W9-2 import path fix)
- `import yara` succeeds in the system Python (validates `python3-yara` installation)

### 7. `nebula`

Verifies the AI copilot runtime is correctly installed and healthy.

Assertions (4):
- `ollama` binary present at `/usr/local/bin/ollama`
- `ollama --version` exits cleanly
- Model file SHA-256 matches `MANIFEST.sha256`
- `nebula-integrity-check` last-run status is `success` (reads
  `/var/log/orionx/nebula-integrity.log`)

### 8. `branding`

Verifies the cyberdeck visual identity is correctly installed.

Assertions (4):
- Plymouth default theme is `orionx-phoenix`
- XFCE `xsettings.xml` references `Orion-X-Cyberdeck` GTK theme
- `grub.cfg` contains `set theme=` directive for the Orion-X theme
- MOTD (`/etc/update-motd.d/10-orionx-welcome`) contains the ASCII wordmark

### 9. `freshen`

Verifies that the ruleset-freshening scripts are properly wired.

Assertions (2):
- `orionx-freshen-yara` symlink exists at `/usr/bin/` and target is executable
- `orionx-freshen-suricata` symlink exists at `/usr/bin/` and target is executable

### 10. `optional`

Verifies the optional installer framework is correctly structured.

Assertions (2):
- All 6 installer scripts source `orionx-installer-common.sh`
- `orionx-installer-common.sh` defines all 7 required functions
  (`check_root`, `check_network`, `apt_install`, `wget_verified`,
  `verify_sha256`, `log_info`, `log_error`)

---

## Interpreting Results

### Exit codes

| Exit code | Meaning |
|---|---|
| `0` | All assertions in the requested scope PASSED |
| `1` | One or more assertions FAILED |
| `2` | Argument error (unknown flag or category) |

### Result tokens

| Token | Meaning |
|---|---|
| `PASS` | Assertion satisfied |
| `FAIL` | Assertion not satisfied -- investigate |
| `SKIP` | Assertion not applicable (e.g., service not yet started by operator) |

`SKIP` is not a failure. Some assertions are conditional: for example, the
Suricata `active` check is SKIP on a fresh boot because Suricata is intentionally
masked. Run with `--verbose` to see the SKIP reason.

### JSON output

```bash
sudo orionx-diag --json
```

Produces structured output suitable for CI pipelines and the Control Center
Awareness pane (W11-11b):

```json
{
  "version": "v2.1.0-dev",
  "timestamp": "2026-07-19T14:32:00Z",
  "categories": {
    "identity": {"pass": 4, "fail": 0, "skip": 0},
    "packages": {"pass": 7, "fail": 0, "skip": 1}
  },
  "total": {"pass": 47, "fail": 0, "skip": 2},
  "verdict": "PASS"
}
```

Top-level `verdict` is `"PASS"` only when all non-SKIP assertions pass.

### CI usage

```bash
# Assert full pass in CI
sudo orionx-diag --json | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d['verdict'] != 'PASS':
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

---

## `/etc/orionx-version` Manifest

`orionx-diag --version` reads from `/etc/orionx-version`, a KEY=VALUE file
written by `scripts/build-iso.sh` at build time. Fields:

| Key | Example value | Description |
|---|---|---|
| `ISO_VERSION` | `v2.1.0-dev` | Semantic version string |
| `BUILD_TIMESTAMP` | `2026-07-19T02:14:00Z` | ISO 8601 UTC build time |
| `GIT_HEAD_SHA` | `b25159a` | Short SHA of the develop HEAD at build time |
| `GIT_HEAD_TITLE` | `Merge feature/...` | First line of the HEAD commit message |
| `PHASE_11_SLICES` | `W11-1,W11-2,...,W11-12` | Comma-separated list of slices baked in |

The file is backward-compatible: the MOTD reader falls back to `v2.0.0` on
pre-W11-11 images that have only a single-line `/etc/orionx-version`.

---

## Troubleshooting Common Failures

**`[identity] whoami == orionx-operator ... FAIL`**

The live session is running as a different user. This indicates a bootloader
cmdline problem: `live-config.username=orionx-operator` is not reaching the
kernel. Check `/proc/cmdline` and verify the bootloader config was generated by
`scripts/build-iso.sh` (look for the `# GENERATED` marker on line 1 of
`grub.cfg` / `isolinux.cfg`). See DEC-PHASE11-012 and the W11-2 CHANGELOG entry.

**`[nebula] model SHA-256 mismatch ... FAIL`**

The bundled model file has changed or been corrupted. This can happen if the
build ran before the Qwen2.5-3B SHA was pinned. Rebuild with a pinned
`nebula-model-manifest.json` (closes #67, W11-2e). On an air-gap node, the
failure means the model at rest has been modified -- treat as a security event.

**`[systemd] nebula-integrity-check last-result == success ... FAIL`**

The boot-time integrity check failed. Check the log at
`/var/log/orionx/nebula-integrity.log` for the exact mismatch. Most common
cause: ISO was rebuilt with a new model but the SHA in `MANIFEST.sha256` was
not updated.

**`[packages] clamav ABSENT ... FAIL`**

ClamAV is present on this image, which means it was not removed per W11-7
(DEC-PHASE11-009). This indicates a pre-W11-7 ISO. ClamAV adds ~350 MB and
its signatures are stale within hours; use `install-clamav.sh` instead.

**`[branding] XFCE xsettings.xml ThemeName == Orion-X-Cyberdeck ... FAIL`**

The XFCE GTK theme is not set. This is the R6 root-cause symptom: on pre-W11-9b
images, the xsettings.xml was written to `/home/orionx/` (dead authority) instead
of `/etc/skel/` (correct, per DEC-PHASE11-014). Re-image with a W11-9b+ ISO.

---

## Reference

- **DEC-PHASE11-015** -- orionx-diag design decisions (scope, assertion count,
  JSON schema, SKIP semantics, CI integration pattern)
- **W11-11** -- implementation work item (Layer A; Layer B / Control Center
  integration in W11-11b)
- Source: `/opt/orionx/scripts/orionx-diag`
- Tests: `tests/unit/test_orionx_diag.sh` (16 assertions)
- Content-presence: `tests/integration/test-iso-content-presence.sh` section 27
