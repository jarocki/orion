# Orion-X Scripts — Operator Reference

This directory contains the Orion-X diagnostic and maintenance scripts staged
into the live ISO at `/opt/orionx/scripts/`. Each script is symlinked into
`/usr/bin/` (or `/usr/local/bin/`) by the `0700-orionx-setup.hook.chroot` at
build time.

---

## orionx-diag — In-ISO Diagnostic Tool

`orionx-diag` is the primary in-ISO verification tool for Orion-X. It runs a
suite of 47 self-checks across 10 categories and produces a PASS/FAIL/SKIP
report proving the running system matches the build manifest.

### Quick start

```bash
# Full suite (recommended — run as root for all checks)
sudo orionx-diag

# Machine-readable JSON (for piping or Control Center integration)
sudo orionx-diag --json

# Single category
sudo orionx-diag --category identity

# Verbose (show SKIP reasons)
sudo orionx-diag --verbose
```

### Check categories

| Category         | Assertions | What it checks |
|------------------|-----------|----------------|
| `identity`       | 4         | `whoami`, `hostname`, `/proc/cmdline` live-config tokens |
| `version-manifest` | 5       | `/etc/orionx-version` KEY=VALUE fields (ISO_VERSION, BUILD_TIMESTAMP, GIT_HEAD_SHA, GIT_HEAD_TITLE, PHASE_11_SLICES) |
| `packages`       | 8         | dpkg presence of RE toolkit, YARA, Suricata; clamav ABSENT gate (W11-7) |
| `files`          | 12        | Nebula model, comms/yara/suricata skeletons, optional lib, branding assets |
| `systemd`        | 5         | nebula-integrity-check, nebula-runtime.socket, suricata lazy-start, NetworkManager, lightdm |
| `python`         | 2         | `from control_center.app import run_app`, `import yara` |
| `nebula`         | 4         | ollama binary, version check, model SHA-256 vs MANIFEST.sha256, last integrity-check result |
| `branding`       | 4         | Plymouth theme, GTK theme wiring, GRUB cfg directive, MOTD wordmark |
| `freshen`        | 2         | `orionx-freshen-yara` and `orionx-freshen-suricata` symlinks + targets executable |
| `optional`       | 2         | All 6 installers source common lib; common lib defines all 7 functions |

### Understanding output

**Human mode** (default):

```
Orion-X System Diagnostic
=========================

[identity]
  PASS  [identity] whoami == orionx-operator
  PASS  [identity] hostname == orionx
  PASS  [identity] cmdline live-config.username=orionx-operator present
  PASS  [identity] cmdline live-config.hostname=orionx present

...

Summary: 45 PASS  0 FAIL  2 SKIP

Overall: PASS
```

- **PASS** — check succeeded; no action needed.
- **FAIL** — check failed; the `detail:` line explains what was found vs. expected.
  File a support issue (see below) if a FAIL occurs on a freshly booted ISO with
  no manual modifications.
- **SKIP** — check could not run (e.g., requires root, file absent, or value is
  `unknown` because the ISO was built outside CI). Run as `sudo` to eliminate
  most root-required SKIPs.

**JSON mode** (`--json`):

```json
{
  "iso_version": "v2.1.0-rc9",
  "build_timestamp": "2026-07-19T14:22:37Z",
  "git_head_sha": "86dd6ee12abc",
  "overall": "PASS",
  "pass": 45,
  "fail": 0,
  "skip": 2,
  "categories": {
    "identity": { "pass": 4, "fail": 0, "skip": 0, "assertions": [...] },
    ...
  }
}
```

### Build metadata — `/etc/orionx-version`

`orionx-diag` reads `/etc/orionx-version` (written by the `0700` hook at build
time) for build provenance. The file format is KEY=VALUE:

```
ISO_VERSION=v2.1.0-rc9
BUILD_TIMESTAMP=2026-07-19T14:22:37Z
GIT_HEAD_SHA=86dd6ee12abc
GIT_HEAD_TITLE=Merge feature/phase11-w11-11-diagnostic-tool into develop
PHASE_11_SLICES=W11-1,W11-2,...,W11-9b
```

If any value is `unknown`, the ISO was likely built outside the CI pipeline
(e.g., a developer hand-build without `scripts/build-iso.sh`). `orionx-diag`
emits SKIP for those fields rather than FAIL.

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | All checks PASS (or SKIP — no failures) |
| `1`  | One or more FAIL |
| `2`  | Invalid arguments or unknown `--category` name |

### Filing issues

If `orionx-diag` emits a FAIL on a freshly booted, unmodified ISO:

1. Capture output: `sudo orionx-diag --json > /tmp/orionx-diag-$(date +%s).json`
2. Include: ISO version (`--version`), hardware model, boot method (USB/DVD/QEMU)
3. File a GitHub issue referencing DEC-PHASE11-015 and attaching the JSON output.

---

## Other scripts in this directory

| Script | Description |
|--------|-------------|
| `mesh/orionx-mesh` | WireGuard P2P mesh CLI |
| `control_center/orionx-control-center` | GTK Control Center (cyberdeck UI) |
| `nebula/nebula` | Nebula AI CLI dispatcher |
| `orionx-freshen-yara.sh` | Post-boot YARA ruleset updater |
| `orionx-freshen-suricata.sh` | Post-boot Suricata ET-Open rule fetcher |

For the full operator command reference, run `orionx-help` in any shell or see
`/usr/share/doc/orionx/User_Guide.md`.
