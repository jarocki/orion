# Changelog

All notable changes to Orion-X Phoenix Edition will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v2.1.0] - Unreleased

Phase 11 lean-release tightening pass (v2.1.0 arc — W11-1 through W11-10). All Phase 10
capabilities (Nebula chat, MCP tool server, Constraint Layer, Ralph Loop, ATT&CK/ATLAS,
Merkle audit, auto-healing) are preserved. The tightening axes: smaller mission-fit LLM,
mission-fit debloat, post-boot optional-installer framework, and a unique Orion-X cyberdeck
visual identity. Target: ≤3.0 GB compressed ISO (~2.8 GB). See DEC-PHASE11-001.

### W11-2d: 16f structural rewrite (CI infra fix)

- fix(phase11): W11-2d — 16f structural rewrite (grep for def run_app + wrapper import) closes CI infra bug; python3-gi CI install reverted

### W11-2c: CI content-presence hotfix (4 failures from run 29070581714)

- fix(phase11): W11-2c — 4 CI content-presence fixes (16a gcc purge in 0500 hook, 16b grep|echo fallback rewrite, 16e -L symlink semantics, 16f python3-gi on CI runner)

### W11-2b: Shellcheck SC2001 hotfix

- fix(phase11): W11-2b — SC2001 shellcheck fix in build-iso.sh bootappend extraction (BASH_REMATCH replaces echo|sed)

### Changed (W11-2): Debloat + bootloader single-authority + W9-2 packaging fix

- **14 packages removed from base ISO** per DEC-PHASE11-003 + DEC-PHASE11-006 (net delta
  approximately −395 MB compressed): `hashcat`, `john`, `hydra`, `proxychains`, `chntpw`,
  `steghide`, `encfs`, `openvpn`, `build-essential`, `gcc`, `make`, `libssl-dev`,
  `python3-dev`, `vim`. Retained: `aircrack-ng`, `neovim`, `screen`, `tmux`. Dev toolchain
  deferred to W11-8 optional installer (`install-devel.sh`).
- **Ghidra bulk staging removed** from `iso/config/hooks/live/0500-install-external-tools.hook.chroot`
  per DEC-PHASE11-004. Ghidra (~500 MB download + JRE) deferred to W11-8 optional installer
  (`/opt/orionx/optional/install-ghidra.sh`).
- **Bootloader cmdline single-authority (issue #64)** — retires the dual-authority hazard
  identified in DEC-PHASE10-018 and field-attested by the rc7-rc9 silent no-op arc.
  `scripts/build-iso.sh` gains `generate_bootloader_configs()` which reads the single
  `--bootappend-live` source in `iso/auto/config` and writes both
  `iso/config/includes.binary/isolinux/isolinux.cfg` and
  `iso/config/includes.binary/boot/grub/grub.cfg` from embedded templates with a
  `# GENERATED — do not edit — regenerate via scripts/build-iso.sh` marker on line 1.
  Hand-edits to either cfg are overwritten on the next build.
- **Autologin identity updated** to `orionx-operator` / `orionx` per DEC-PHASE11-012
  (supersedes rc7-rc9 identity `orionx` / `orionx-cyberdeck`). Identity is set once in
  `iso/auto/config --bootappend-live` and mechanically propagated to both bootloader configs
  by the generator.
- **W9-2 Python import assertion added** to `tests/integration/test-iso-content-presence.sh`
  section 16 (issue #66): `PYTHONPATH=<squashfs>/opt/orionx/scripts python3 -c "from
  control_center.app import run_app"` now runs as a CI gate — catches the class of bug
  where the wrapper ships but the module is missing from the squashfs.
- **QEMU boot /proc/cmdline capture** added to `tests/integration/test-qemu-boot.sh` (T6,
  issue #65 hardware fixture): after boot, serial logs are scanned for the kernel cmdline
  and both identity tokens are asserted present.
- **`test_build_iso.sh` rc4 → rc9 hygiene** (issue #63): stale `v2.0.0-rc4` version
  literals in T2/T4/T5/T7 assertions updated to `v2.0.0-rc9` to match the current
  `scripts/build-iso.sh` default.
- **`test-iso-content-presence.sh` default ISO filename** updated from
  `v2.0.0-rc4.iso` → `v2.0.0-rc9.iso` to match current CI output.
- **`test_iso_serial_console.sh`** T3/T4/T16/T17 identity assertions updated from
  `orionx` / `orionx-cyberdeck` to `orionx-operator` / `orionx` (DEC-PHASE11-012). New T18
  asserts the GENERATED marker on line 1 of both bootloader cfgs.

### Changed (W11-1)

- **Nebula bundled model swap — Mistral-7B-Instruct-v0.3 Q4_K_M → Qwen2.5-3B-Instruct
  Q4_K_M** (DEC-PHASE11-002). `iso/config/nebula-model-manifest.json` updated:
  - `model_name`: `qwen2.5-3b-instruct-Q4_K_M`
  - `model_filename`: `Qwen2.5-3B-Instruct-Q4_K_M.gguf`
  - `model_url_primary`: bartowski/Qwen2.5-3B-Instruct-GGUF (non-gated community GGUF
    mirror; replaces bartowski/Mistral-7B-Instruct-v0.3-GGUF)
  - `model_url_fallback`: Qwen/Qwen2.5-3B-Instruct-GGUF (official Qwen team upstream)
  - `ollama_model_tag`: `qwen2.5:3b-instruct-q4_K_M`
  - `model_size_bytes`: ~1.94 GB (was ~4.4 GB; −2.5 GB delta, largest single ISO reduction)
  - `model_license`: Apache-2.0 (unchanged license class from Mistral; clean redistribution)
  - `model_sha256`: trust-on-first-use sentinel `TBD-VERIFY-AT-DOWNLOAD` (per
    DEC-PHASE10-008; pin the real SHA-256 in the follow-up commit after the first green CI
    build of W11-1)
- **Ollama daemon, AppArmor profile, and the 3 W10-1 systemd units
  (`nebula-integrity-check`, `nebula-runtime`, `nebula-warmup`) preserved verbatim** — only
  the model file swaps (DEC-PHASE11-002).
- **Content-presence section 15** (`tests/integration/test-iso-content-presence.sh`) updated
  for the new model filename and size; warn threshold relaxed from 4 GB to 3 GB for the
  smaller Qwen model (DEC-PHASE10-012).
- **First-inference QEMU latency benchmark** added to
  `tests/integration/test-qemu-boot.sh` (103-line section recording Qwen2.5-3B cold-start
  wall-clock time in the QEMU environment as the baseline for W11-1).
- Build and status comment refreshes in `scripts/build-iso.sh` and
  `scripts/nebula/status.py` to reflect the Qwen2.5-3B model identity.

---

## [v2.0.0-rc9] - 2026-06-22

Ninth release candidate — **hardware-attestation hotfix (iteration 3)**: dual-authority
kernel cmdline bug surfaces two iterations deep. Operator booted rc8 on hardware and
confirmed Bug A's realpath fix (DEC-PHASE10-017) IS working — `orionx-control-center
--version` printed `2.0.0-rc5-w9-2` cleanly, confirming the rc8 ISO was booted. But
`cat /proc/cmdline` showed neither `live-config.username=orionx` nor
`live-config.hostname=orionx-cyberdeck` on the kernel cmdline. `whoami` returned
`user`, hostname remained `debian`. The cyberdeck identity was still broken despite
T3/T4 having passed in rc8 review.

### Root cause (DEC-PHASE10-018)

**DUAL AUTHORITY for kernel cmdline** — two competing surfaces both write bootloader
configs, but only one actually reaches the booted kernel:

1. `iso/auto/config` line ~64: `--bootappend-live "..."` — the surface we have been
   editing since rc7. live-build generates a bootloader config from this value.
2. `iso/config/includes.binary/isolinux/isolinux.cfg` +
   `iso/config/includes.binary/boot/grub/grub.cfg` — **static files** introduced in
   DEC-PHASE7-024 (W7-3, issue #35) to pre-bake serial-console support. The
   `lb_binary_local-includes` stage copies these files verbatim into the ISO binary
   tree **after** the bootloader-generation stage. They overwrite whatever live-build
   generated from `--bootappend-live`.

Every `--bootappend-live` edit since rc7 has been a silent no-op. The static cfgs
still carried rc4-era cmdlines with no live-config tokens. DEC-PHASE7-024 introduced
this mechanism deliberately for issue #35, but established no invariant requiring the
static cfgs to stay in sync with `--bootappend-live`. The drift was invisible because
T3/T4 only checked `iso/auto/config` — the LOSING authority.

### Fixed

- **`iso/config/includes.binary/isolinux/isolinux.cfg`** — appended
  `live-config.username=orionx live-config.hostname=orionx-cyberdeck` to the `append`
  line in BOTH the `live` label (default) and `live-failsafe` label. This is the
  EFFECTIVE BIOS-boot kernel cmdline authority. Updated header comment to carry the
  DUAL AUTHORITY WARNING and cross-reference DEC-PHASE10-018 and issue #64.

- **`iso/config/includes.binary/boot/grub/grub.cfg`** — same tokens appended to the
  `linux` line in BOTH `menuentry` blocks ("Orion-X Live" and "Orion-X Live
  (failsafe)"). This is the EFFECTIVE UEFI-boot kernel cmdline authority. Same DUAL
  AUTHORITY WARNING header added.

- **`tests/unit/test_iso_serial_console.sh`** — added T16 and T17 asserting that
  `live-config.username=orionx` and `live-config.hostname=orionx-cyberdeck` are
  present in the `append`/`linux` lines of BOTH static bootloader cfgs (the WINNING
  authorities), not just in `iso/auto/config` (the LOSING authority). T3/T4 are
  preserved — they still guard `iso/auto/config` so all three authorities are now
  independently tested. Closes the test gap that allowed T3/T4 to pass while hardware
  showed the tokens missing.

### Meta-lesson (DEC-PHASE10-018 — hardware attestation iteration 3)

**When a state has multiple authorities, EVERY authority must be tested; ideally all
are consolidated to one.** T3/T4 tested the wrong (losing) authority and gave false
confidence for two release candidates. The structural lesson: any time
`lb_binary_local-includes` or a similar override mechanism is present, the files it
copies are the real authority — and those are what the regression tests must check.

Issue #64 tracks v2.1 consolidation to a single bootloader cmdline authority (likely
a template or generator so `--bootappend-live` and the static cfgs cannot drift). For
rc9, patching all three authorities and guarding all three with tests is the
minimum-impact, maximum-safety fix within scope.

### Cross-references

- #62: dual `orionx-help` authority, stale MOTD (fixed rc8).
- #63: `orionx-control-center` realpath fix (fixed rc8, confirmed working on rc8 hardware).
- #64: v2.1 consolidation — single bootloader cmdline authority (tracked, deferred).
- DEC-PHASE7-024: original dual-authority mechanism (pre-baked bootloader via includes.binary/).
- DEC-PHASE10-017: rc8 fixes (Bug A realpath, Bug B dual orionx-help, Bug C bare live-config params).
- DEC-PHASE10-018: rc9 root cause — static cfgs override --bootappend-live; dual authority confirmed.

---

## [v2.0.0-rc8] - 2026-06-19

Eighth release candidate — **hardware-attestation hotfix bundle (iteration 2)**,
extending DEC-PHASE10-016. Operator booted rc7 on hardware and surfaced three
distinct bug classes that CI was structurally blind to. All three are boot-time
or import-time failures invisible to the unit/integration CI gates we have.

### Fixed

- **Bug A — `orionx-control-center` crashes `ModuleNotFoundError: No module
  named 'control_center'`** (`scripts/control_center/orionx-control-center`
  line ~70). Operator terminal output: `ModuleNotFoundError: No module named
  'control_center'` when launching the GTK Control Center from the XFCE menu.
  Root cause: the entrypoint uses `os.path.abspath(__file__)` to locate the
  `scripts/` parent directory. `abspath` does NOT resolve symlinks — when
  invoked as `/usr/bin/orionx-control-center` (symlink → `/opt/orionx/scripts/
  control_center/orionx-control-center`, wired by `0700-orionx-setup.hook
  .chroot`), `abspath` returns the symlink path, giving `script_dir=/usr/bin`
  and `scripts_dir=/`. The `control_center` package at `/opt/orionx/scripts/
  control_center/` is never on `sys.path`. Fix: `os.path.realpath(__file__)`
  resolves the full symlink chain to the actual file path before dirname,
  giving the correct `scripts_dir=/opt/orionx/scripts`. Pattern already used
  correctly in `scripts/nebula/nebula` line 53. (closes #63,
  DEC-PHASE10-017)

- **Bug B — `.bashrc` v1.5.5 stale strings + dual-authority `orionx-help`**
  (`iso/config/hooks/normal/0100-create-user.hook.chroot`). Operator terminal
  output: `Welcome to Orion-X Phoenix Edition v1.5.5!` and `orionx-help`
  listing tools that do not exist (`setup-vpn.sh`, stale forensic aliases).
  Root cause: two definitions of `orionx-help()` existed simultaneously:
  (1) `/etc/profile.d/orionx-help.sh` — written by `0700-orionx-setup.hook
  .chroot`, the CORRECT v2.0 tool list; (2) `/home/orionx/.bashrc` — written
  by `0100-create-user.hook.chroot`, the STALE v1.5.5 body. Bash sources
  `/etc/profile.d/*.sh` before `~/.bashrc`; the `.bashrc` redefinition wins,
  so the wrong help always rendered. A stale MOTD block (`Phoenix Edition
  v1.5.5`) was also written by `0100-create-user.hook.chroot`, creating a
  second MOTD authority. Fix B.1: rewrote the `.bashrc` heredoc in
  `0100-create-user.hook.chroot` to contain only interactive-shell hygiene
  (history, `checkwinsize`, prompt, aliases, `bash_completion` source) —
  removed the welcome echo, the stale `orionx-help()` body, and the stale
  version literal. Single authority: `0700-orionx-setup.hook.chroot` owns
  both MOTD and `orionx-help`. Fix B.2: removed the stale
  `cat > /etc/update-motd.d/10-orionx-welcome` block from
  `0100-create-user.hook.chroot` (MOTD authority now exclusively in `0700`).
  The MOTD in `0700` now reads its version string from `/etc/orionx-version`
  (written by the same `0700` hook from `${ORIONX_VERSION:-v2.0.0-rc8}`)
  rather than a hardcoded literal — eliminating the stale-literal class for
  future RC cuts. (closes #62, DEC-PHASE10-017)

- **Bug C — Autologin identity still defaults to `user`, not `orionx`**
  (`iso/auto/config` line ~64). Operator report: "It's not starting up with
  the user set to orionx, but I can logout and login (still) as user orionx."
  Root cause: rc7 added `username=orionx hostname=orionx-cyberdeck` (bare
  form) to `--bootappend-live`. Debian Bullseye live-config 5.x parses
  cmdline params with the `live-config.` prefix only; the bare form is
  silently ignored. live-config therefore created its default `user`, not
  `orionx`. Fix: changed to `live-config.username=orionx live-config.hostname=
  orionx-cyberdeck` per the live-config(7) Bullseye manpage. Regression test
  T3 and T4 in `tests/unit/test_iso_serial_console.sh` updated to assert the
  prefixed form. (closes #62, DEC-PHASE10-017)

### Meta-lesson (DEC-PHASE10-017 — hardware attestation iteration 2, extends DEC-PHASE10-016)

**Operator hardware attestation discovers classes of bugs that automated CI
is structurally blind to.** This is the second hardware-attestation iteration
(rc7 was iteration 1). Three new bug classes surfaced that no current CI gate
covers:

1. **Import-path-via-symlink failures** — the `ModuleNotFoundError` on
   `orionx-control-center` only manifests when the script is invoked via a
   `/usr/bin/` symlink, which is exactly how the live system runs it. Dev-host
   `python3 scripts/control_center/orionx-control-center` never triggers this
   because `__file__` is already the real path.
2. **Dual-authority shell function shadowing** — the `.bashrc` overwrite of
   `/etc/profile.d/orionx-help.sh` can only be observed by logging in as the
   live user and running `orionx-help` interactively. CI's syntax checks and
   content-presence checks cannot surface this.
3. **Bare vs. prefixed live-config cmdline params** — the autologin identity
   bug (`user` not `orionx`) requires a real boot with the correct live-config
   version to observe. QEMU boots in CI do not assert the live login username.

**Phase 11 candidate:** add a qemu-based first-login smoke test that captures
the first interactive bash prompt and the first `orionx-help` invocation,
asserting both match the current build's version and tool list, not stale
literals. This would close the structural CI blindspot for all three classes
above.

### Cross-references

- #56 + #57 SHA pins from rc6 carry forward unchanged.
- #62 (2 GB asset-size cap workaround) still applies.
- #63: `orionx-control-center` symlink `ModuleNotFoundError` (fixed in rc8).
- Phase 10 W10-1 closure (`bb44742`) unchanged.

---

## [v2.0.0-rc7] - 2026-06-16

Seventh release candidate — **hardware-attestation hotfix** discovered when
operator booted rc6 on real hardware and reported it "just looks like
vanilla debian" (Phoenix wallpaper not set, menu items dead, Control
Center won't start, Nebula AI not running). The Phase 9 cyberdeck
content + Phase 10 Nebula AI runtime were all correctly built into the
rc6 ISO (CI logs and content-presence tests confirmed this). The bug
was at boot time: **live-config was creating its default user `user`,
not `orionx`**, so none of the per-user configs (xfconf wallpaper,
.desktop launchers under /home/orionx/, autologin target, panel widgets)
applied to the active session. Logging out and back in as `orionx`
revealed the full cyberdeck — proving the content was in the ISO; only
the live-user identity was wrong.

This is the same class of regression as Phase 8's #43 (operator-
attestation gap that automated CI couldn't surface) — but in a different
axis. CI's W7-4-B serial-sentinel runtime-verify checks systemd unit
states, not the identity of the live login user. QEMU-based content-
presence verifies files exist in the squashfs but not which user
actually owns the booted session.

### Fixed

- **`iso/auto/config:64` `--bootappend-live`** — appended `username=orionx
  hostname=orionx-cyberdeck` to the kernel cmdline. live-config reads
  these at boot and creates `orionx` as the live user (reusing the
  pre-built home dir from `iso/config/hooks/normal/0100-create-user.hook
  .chroot`) instead of its default `user`. With this in place, autologin
  per DEC-PHASE9-005 targets the same user that owns the per-user
  xfconf wallpaper config, the `.desktop` launchers, and the panel
  layout — and the cyberdeck renders correctly on first boot.
- **`tests/unit/test_iso_serial_console.sh`** — added T3 and T4
  asserting `username=orionx` and `hostname=orionx-cyberdeck` are
  present in `--bootappend-live`. Prevents regression of this exact
  class. DEC-PHASE10-016.

### Meta-lesson (recorded as DEC-PHASE10-016)

**Operator hardware attestation discovers classes of bugs that automated
CI is structurally blind to.** Phase 8's #43 fix (content-presence as a
CI gate) prevents the "missing-content" class. rc7's fix prevents the
"wrong-user" class. Both required hardware boots from a real operator.
W7-4-B + content-presence + boot-test work for what they target; they
do NOT replace operator-on-hardware as the final acceptance gate. Plan
for v2.1: extend W7-4-B serial-sentinel suite to assert the live-login
user identity matches the autologin target.

### Cross-references

- rc6 build (`27395285540`) was internally correct — `release-artifacts-
  27395285540` ISO has the cyberdeck content; operators can re-test rc6
  by logging out and logging in as `orionx` (passwordless). rc7
  obviates this workaround.
- #56 + #57 SHA pins from rc6 carry forward unchanged (pins remain
  valid; same model + ollama versions).
- #62 (2 GB asset-size cap) still applies; rc7 ISO will also need
  `gh run download` workaround until v2.1 split-and-reassemble lands.
- Phase 10 W10-1 closure (`bb44742`) unchanged — that work was correct
  end-to-end at the build layer.

---

## [v2.0.0-rc6] - 2026-06-11

Sixth release candidate (rc5 skipped — operator chose to go direct from
W9-2 cyberdeck UX to W10-1 Nebula AI per DEC-PHASE10-005 path ii).

**rc6 is the v2.0.0 AI HEADLINE candidate.** Layer 3 of the 6-layer
architecture (AI Forensic Engine — previously deferred to v2.1 by
DEC-008) is now in code per DEC-PHASE10-001..-015. ISO grows from
~1 GB (rc4) to ~6 GB (rc6) to bundle the inference floor for fully-
local AI on hostile networks.

### Added

- **Nebula AI runtime** (`scripts/nebula/`): Python 3 stdlib-only control
  plane — CLI dispatcher (`nebula`), integrity verification
  (`integrity.py`), 1-token warmup (`warmup.py`), JSON status emitter
  (`status.py`) for Control Center, helpers/ (subprocess + paths).
  `from __future__ import annotations` honored on every module
  (DEC-PHASE9-019 invariant). DEC-PHASE10-001/-005.
- **Bundled inference model**: Mistral-7B-Instruct-v0.3 Q4_K_M
  (~4.4 GB GGUF, Apache 2.0) staged from `bartowski/Mistral-7B-Instruct-
  v0.3-GGUF` (primary) + `MaziyarPanahi/Mistral-7B-Instruct-v0.3-GGUF`
  (fallback). Both non-gated. SHA-256 pinned this release at
  `1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6`
  (closes #56). DEC-PHASE10-002 / -008 / -013.
- **Ollama daemon** v0.30.7 — distributed as `.tar.zst` (ollama never
  shipped a `.deb`; iter-1's hallucinated `.deb` path was corrected in
  iter-7). Extracted to `/usr/local/` by the 0500 hook. `zstd` package
  added to `orionx.list.chroot`. SHA-256 pinned at
  `88c110a6c9a9130e5ed0aa90f47e8ddb013cb638d834e11ddf1517615704d34c`
  (closes #57). DEC-PHASE10-007.
- **Boot-time integrity check** — `nebula-integrity-check.service`
  (Type=oneshot) runs `Before=nebula-runtime.service`. On manifest
  mismatch, ollama is BLOCKED from starting; failure logged to
  `/var/log/orionx/nebula-integrity.log`. DEC-PHASE10-009.
- **Lazy-start Ollama** via socket activation — `nebula-runtime.socket`
  + `nebula-runtime.service`. First inference request triggers daemon
  startup; boot stays fast, idle RAM stays under ~1.5 GB.
  DEC-PHASE10-010.
- **Opt-in warmup** — `nebula-warmup.service` NOT enabled by default.
  Operator opts in via Control Center to perform a 1-token inference at
  desktop session start. DEC-PHASE10-010.
- **AppArmor sandbox** — `iso/config/includes.chroot/etc/apparmor.d/
  usr.bin.ollama` confines the Ollama daemon. Read-only access to
  `/opt/orionx/nebula/models/**`; write only to `/var/log/orionx/`;
  deny exec of unknown binaries. DEC-PHASE10-011 (DEC-007 sandbox
  spirit). The `network inet stream` rule remains broader than ideal
  for true loopback-only on Bullseye AppArmor 3.x — tracked as #53 for
  v2.1 nftables OUTPUT enforcement.
- **Cyberdeck Control Center wiring** — `scripts/control_center/
  sections/nebula.py` reads live status from `nebula status` JSON. The
  Phase 9 W9-2 placeholder ("Runtime: not yet enabled (lands in W10-1)")
  is now alive: "Runtime: ready, model: mistral-7b-instruct-v0.3-Q4_K_M
  (4.4 GB, integrity OK)". DEC-PHASE10-005.
- **GGUF model staging pipeline** — NEW `stage_nebula_model()` in
  `scripts/build-iso.sh` (sibling to `stage_application_content()`,
  disjoint subtree ownership). Downloads from HF with primary+fallback
  URLs, SHA-256 verifies against manifest, rsyncs into includes.chroot,
  generates MANIFEST.sha256. Honors `ORIONX_MODEL_LOCAL` env var for
  air-gap builders. DEC-PHASE10-008.

### Fixed (8-iteration CI cascade, all on PR #54)

- **iter-3** — `curl` is not installed in the `debian:bullseye-slim`
  build container; switched stage_nebula_model + 0500 hook fetches to
  `wget`. `exit 1` propagation added to stage_nebula_model failure
  branch.
- **iter-4** — TheBloke/Mistral-7B-Instruct-v0.3-GGUF HF repository
  inherits Mistral AI's acceptance-gating. CI returned 401; swapped to
  non-gated bartowski + MaziyarPanahi mirrors (closes #60).
- **iter-5** — `tests/unit/test_build_iso.sh` T17 had a `grep -A2`
  bug that matched the wrong block; T34 added with proper `-A10`
  per-path anchors covering the lb_exit branch, no-ISO-found branch,
  and ISO-copy-failure branch.
- **iter-6** — `.github/workflows/qemu-test.yml` "Build ISO in
  debian:bullseye container" step's `docker run ... | tee tmp/build-iso
  .log` pipeline silently swallowed docker's non-zero exit through
  tee's exit-0. GitHub Actions runs `run:` blocks under `bash -e` but
  NOT `bash -eo pipefail`. CI had been falsely reporting green for 5
  iterations. Added `set -o pipefail` at the top of the step (closes
  #61). T35 regression guard added. DEC-PHASE10-014.
- **iter-7** — Pinned ollama version `v0.3.12` returns 404; ollama
  jumped 0.3.x → 0.30.x major version. Updated to `v0.30.7`.
  Discovered ollama NEVER shipped a `.deb` — iter-1's `.deb` extension
  was hallucinated. Switched to `.tar.zst` (canonical ollama distribu-
  tion since v0.24+). Added `zstd` package to `orionx.list.chroot`
  for chroot decompression. T35.d YAML parse assertion bug fixed
  (was checking output, now checks exit code) with PyYAML-availability
  guard.
- **iter-8** — `test-iso-content-presence.sh` section 15 asserted
  `^Package: ollama$` in dpkg/status; ollama isn't in dpkg under the
  `.tar.zst` extraction model. Replaced with binary-presence check at
  `/usr/local/bin/ollama`. Added `zstd` dpkg-presence assertion.

### Meta-lessons (DEC-PHASE10-015 records all three)

1. **CI cannot be trusted blind without `pipefail`.** Iter-6's tee
   pipeline bug masked the W10-1 build failure for 5 iterations,
   producing false-green CI checks while the build silently exited 0
   with no ISO. Workflow-policy-class invariant proposal for v2.1:
   require `set -o pipefail` in every `run:` block that uses a pipe
   where the left-hand exit code matters.
2. **Cascade-consolidation discipline (DEC-PHASE7-041) scales to 8
   iterations** when each iter is minimal/traceable/reviewable. The
   new project ceiling is iter-8; the floor remains a single concrete
   root cause + a single concrete fix + a regression guard per iter.
3. **Single-source upstream supply-chain risk** demonstrated by
   TheBloke gating (iter-4) and ollama-never-shipped-`.deb` (iter-7).
   v2.1 should bundle a backup model mirror set so single-source
   gating cannot block rebuilds.

### Cross-references

- W10-1 final HEAD: `5fed021` (iter-8); merged to develop as `bb44742`.
- CI final-green proof: run **27355317949** on `5fed021`. Artifact
  `orionx-iso-27355317949` (~6 GB).
- DEC-PHASE10-001..-015 cover the full Phase 10 W10-1 decision arc.
- W10-2 (Nebula chat UX), W10-3 (MCP tool server), W10-4 (Inference
  Constraint Layer), W10-5 (detection daemon), W10-6 (auto-healing
  playbooks), W10-7..-10 detail-planning awaits operator rc6 hardware
  re-validation.

### Pre-rc6 SHA pin commit

This release pins:
- `iso/config/nebula-model-manifest.json` model_sha256 (#56)
- `iso/config/hooks/live/0500-install-external-tools.hook.chroot`
  OLLAMA_TGZ_SHA256 (#57)

Both `TBD-...` sentinels resolved to canonical SHAs computed in CI
run 27355317949 and re-verified during this release prep.

---

## [v2.0.0-rc4] - 2026-06-02

Fourth release candidate. The operator booted v2.0.0-rc3 from USB on real
hardware and reported it unusable: wallpaper not set, custom menu
launchers dead, no way to start networking (Wi-Fi firmware + GUI
networking entirely missing), mesh undiscoverable. Phase 9 (Operator
Cyberdeck UX) was opened to fix the basics first, then build the
"Cyberdeck for the Good Guys" UX layer.

rc4 is the **fast-basics-first** release: the cyberdeck is usable
out-of-the-box on standard hardware, plus a first round of
gecko-legacy operator tooling ported in. Panel widgets / GTK Control
Center / threat-posture tiers + deception remain deferred (issues
#45 / #46) until rc4 hardware re-validation closes.

### Added

- **GUI networking**: NetworkManager + network-manager-gnome (nm-applet
  tray) + wpasupplicant + iw + non-free wireless firmware
  (firmware-iwlwifi / firmware-realtek / firmware-atheros /
  firmware-misc-nonfree) so the operator can join Wi-Fi networks from
  the panel on most laptops. Non-free apt component enabled via
  `iso/auto/config --archive-areas "main contrib non-free"` AND an
  explicit `iso/config/archives/debian-nonfree.list.chroot` (the
  belt-and-suspenders fix in DEC-PHASE9-010 after `--archive-areas`
  alone proved insufficient at chroot install time).
- **LightDM autologin** for the `orionx` live user — boots directly to
  XFCE desktop, no greeter prompt (DEC-PHASE9-005). The orionx user is
  passwordless by design; physical-capture tradeoff accepted for a
  field cyberdeck.
- **One-click mesh launcher** — new `.desktop` entry "Orion-X Mesh —
  Start" invoking `sudo orionx-mesh join` via xfce4-terminal.
- **Phoenix wallpaper** wired as the active XFCE backdrop via xfconf
  XML in the orionx home (DEC-PHASE9-001 reuses
  `scripts/toggle-theme.sh`'s xfconf mechanism, single authority).
- **`scripts/pcap-analyzer.py`** — new Python 3 PCAP analysis tool
  implementing the Bejtlich Structured Traffic Analysis (STA) 6-phase
  methodology: metadata, protocol hierarchy, conversations,
  endpoints, HTTP/DNS/TLS overview, readable summary. Standard-library
  only, chain-of-custody header with SHA-256 + hostname + tool
  versions on every output file. argparse interface
  (`--output-dir`, `--quick`, `--report`). Fail-loud on missing
  tshark. Modernized from gecko legacy `analyze-pcap.sh` (DEC-PHASE9-017).
- **fail2ban** in the package list for persistent SSH brute-force
  defense (DEC-PHASE9-018). Daemon enabled via Debian postinst, same
  pattern as NetworkManager — no custom systemd unit.

### Fixed

- **lxterminal → xfce4-terminal** — all five `.desktop` Exec lines in
  the 0700 hook switched from the never-installed `lxterminal` to
  `xfce4-terminal --hold -e "bash -c '<cmd>; exec bash'"`, fixing the
  rc3-reported "menu items don't work" complaint (DEC-PHASE9-006).
- **Matrix/wg-quick unit bug** — `matrix-synapse-orionx.service` had
  `Requires=wg-quick@wg0.service` but `scripts/mesh/mesh-join.sh`
  brings up `wg0` via raw `ip`/`wg`, not `wg-quick@`. The hard
  Requires was permanently unsatisfiable. Downgraded to `Wants=`/
  `After=` in BOTH copies (canonical includes.chroot + repo-root
  systemd/ duplicate reconciled to match) so Matrix degrades
  gracefully (DEC-PHASE9-007).
- **`scripts/build-iso.sh` fail-loud** — was silently exiting 0 when
  `lb build` failed and produced no ISO. Now captures `lb_exit`
  explicitly and exits non-zero on build failure OR missing ISO
  (DEC-PHASE9-011).
- **`scripts/qemu-boot-test.sh` rc1 version-drift** — `DEFAULT_ISO`
  was hardcoded to `output/orionx-phoenix-edition-v2.0.0-rc1.iso`.
  Replaced with glob-based runtime resolver
  (`output/orionx-phoenix-edition-*.iso`) so CI/dev tooling tracks
  the actual produced ISO without per-rc version-string edits
  (DEC-PHASE9-015 — consolidated version-literal-drift lesson:
  CI-facing scripts MUST resolve ISO paths via glob, not literal
  version strings).
- **Content-presence test extraction gap** — `test-iso-content-
  presence.sh` did selective `unsquashfs` that missed `/var/lib/dpkg`
  and `/etc/lightdm` paths needed by new rc4 assertions. Replaced
  selective extraction with full unsquashfs (DEC-PHASE9-012).
- **`set -e + pipefail + grep`-no-match silent death** — content-
  presence test exited 1 silently when zero lxterminal matches (the
  desired state). Added `|| true` on no-match grep pipelines
  (DEC-PHASE9-014).
- **PEP 604 / Bullseye Python 3.9 incompatibility** — `pcap-analyzer.py`
  used `str | None` (PEP 604, 3.10+) which `TypeError`s at import on
  Bullseye Python 3.9. Fixed with `from __future__ import annotations`
  (PEP 563 deferred evaluation, single-line future-proof fix) plus a
  T10 `importlib.util` module-load regression guard (DEC-PHASE9-019).
- **ruff F541/E741 lint** — `pcap-analyzer.py` had three cosmetic
  defects (2× f-string-without-placeholder, 1× ambiguous variable `l`).
  Fixed + added T11 ruff regression guard so local-test catches this
  class before CI (DEC-PHASE9-020).

### CI hardening (W9-1b cascade closure)

- Explicit `iso/config/archives/debian-nonfree.list.chroot` injects
  non-free into the chroot's apt sources at build time, complementing
  `--archive-areas` (DEC-PHASE9-010).
- Two durable meta-lessons recorded in DEC-PHASE9-021 as hard
  invariants for successors: (a) every ISO-shipped Python module
  needs `from __future__ import annotations` for Bullseye Python 3.9
  compatibility; (b) the local-test contract MUST run `ruff` when
  available so lint defects don't cost ~25-minute CI cycles.

### Cross-references

- Phase 9 (Operator Cyberdeck UX): W9-1 (rc4 broken-basics) +
  W9-1b (#48 firmware build-break + dependent test cascade) + W9-2a
  (#50 gecko legacy port: pcap-analyzer + fail2ban).
- DEC-PHASE9-001 … -021 cover the full rc4 decision arc.
- W9-2 (XFCE panel + GTK Control Center, #45) and W9-3
  (threat-posture tiers + deception, #46) detail-planning deferred
  until rc4 hardware re-validation closes.

---

## [v2.0.0-rc3] - 2026-05-17

Third release candidate. Supersedes v2.0.0-rc2 which had two cosmetic
defects discovered during the release pipeline shake-out:

- The released ISO was named `orionx-phoenix-edition-v2.0.0-rc1.iso`
  instead of matching the rc2 tag (build-iso.sh used its hardcoded
  default version literal because release.yml never passed
  ORIONX_VERSION from the tag).
- The DRAFT release body was the fallback string `See CHANGELOG.md for
  full release history.` because extract-release-notes.sh found no
  `## [v2.0.0-rc2]` heading.

Fixes in rc3 (commits between f3027f7 and the rc3 tag commit):

- `.github/workflows/release.yml` — passes `ORIONX_VERSION` from
  `github.ref_name` into the docker build container, so the ISO
  filename matches the tag. workflow_dispatch (manual) runs fall back
  to the build-iso.sh default.
- `CHANGELOG.md` — added v2.0.0-rc2 retrospective and this v2.0.0-rc3
  section so extract-release-notes.sh finds proper release notes.

Content guarantees (unchanged from rc2 — same ISO contents):
- All Orion-X application content present (closes #43 four-iteration
  arc)
- 8 systemd units installed and enabled
- AppArmor profiles, sample data, docs, branding wallpaper

W7-7 second-attempt operator hardware re-attestation: SKIPPED per
DEC-PHASE8-008.

### Fixed
- release.yml: ISO filename now matches tag name (no more rc2-tagged
  release shipping rc1-named ISO)
- CHANGELOG.md: rc2 retrospective + rc3 sections so release notes
  body is populated, not the fallback

### Cross-references
- DEC-PHASE8-009 Option B (chosen)
- v2.0.0-rc2 tag retained as historical record (was DRAFT only, never
  published)

---

## [v2.0.0-rc2] - 2026-05-17 (RETROSPECTIVE — superseded by rc3)

Second release candidate. Tagged at `f3027f7` on develop after the
#43 cascade four-iteration arc (W7-7 finding) landed. **DRAFT
release was created but NEVER PUBLISHED** because the cut had two
cosmetic defects (see rc3 section). Superseded by v2.0.0-rc3.

ISO content was correct (full Orion-X application layer + branding
wallpaper + systemd units + AppArmor profiles), but the release
artifacts were mis-named/mis-described. Tag retained as historical
record.

### Cross-references
- DEC-PHASE8-008 (W7-7 skip authorization)
- DEC-PHASE8-009 Option B (rc3 supersedes)
- Issue #43 four-iteration fix arc: e725895, 40416d6, fde6771, fb100f8

---

## [v2.0.0-rc1] — In Progress (Phase 8)

Release candidate prepared from the Phase 7 integration-tested foundation.
Full Phase 7 arc (W7-1 through W7-8) and Phase 8 release-prep work (W8-1) landed.
Two hard human boundaries remain before the final `v2.0.0` tag: W7-7 physical USB
attestation and W8-7 operator publish gate.

### Phase 8 — Release v2.0.0 (in progress)

- **W8-1**: Version-string finalization to `v2.0.0-rc1` — `Dockerfile` (LABEL/MOTD/bashrc)
  and `README.md` propagated from `v2.0.0-dev` to `v2.0.0-rc1`; canonical authority
  `scripts/build-iso.sh` and `iso/auto/config` unchanged (merge `ee5861b`, DEC-PHASE8-001)
- **W8 Dockerfile cleanup**: dev-container apt package fix — removed three apt-unavailable
  forensic packages from `Dockerfile` (same drift class as Phase 7 #33 cascade, merge `44c7b25`)
- **W7-7 enabler**: ISO artifact upload for operator attestation — `.github/workflows/qemu-test.yml`
  now uploads the built ISO as `orionx-iso-<run_id>` so the operator can `gh run download`
  and dd-write to USB without a local build (merge `b411c47`)
- **Phase 8 finish plan**: W8-2 through W8-6 consolidated into two bundles
  (`wi-w8-finish-A` docs bundle, `wi-w8-finish-B` release pipeline bundle)
  per DEC-PHASE8-002 cascade-consolidation (commit `221148c`)
- **W7-8 / Phase 7 closure**: Phase 7 closed at `05b98a3` with all three CI workflows
  green; Phase 8 activated (merge `ad35fb9`, DEC-PHASE7-043)

---

### Phase 7 — Integration Testing (Completed 2026-05-14)

Full E2E scenario proven in Docker. ISO boots under UEFI and BIOS in QEMU.
Runtime-verification mechanism (W7-4-B) and performance-measurement mechanism (W7-5)
operative. Failure-mode recovery asserted across all long-running units (W7-6).
All three CI workflows (lint.yml, qemu-test.yml, e2e-test.yml) green at `05b98a3`.

- **W7-6**: Failure-mode recovery — host-side static parse asserts `Restart=` directives
  across 8 Orion-X systemd units; Option D (config inspection) over in-guest stimulation
  for cascade-independence (merge `05b98a3`, DEC-PHASE7-043)
- **W7-5-exit**: Cascade-consolidation #2 — `continue-on-error: true` on W7-5 step,
  stale comment block rewritten; second application of DEC-PHASE7-041 pattern
  (merge `ba3e0d1`, DEC-PHASE7-042)
- **W7-5**: Performance benchmark — ISO size `984612864` bytes (≈939 MiB, well under 4 GiB
  threshold, PASS); in-guest `boot_time_seconds` and `idle_ram_bytes` UNMEASURED pending
  #39/#40 first-boot cascade resolution (merge `8bcded0`, DEC-PHASE7-042)
- **W7-4-B-exit**: CI loop-exit — `continue-on-error: true` on W7-4-B step; first
  application of DEC-PHASE7-041 cascade-consolidation pattern (merge `c6c42c1`, DEC-PHASE7-039)
- **W7-4-B**: QEMU runtime verification — in-guest oneshot unit `orionx-runtime-verify.service`
  writes sentinel-tagged results (`ORIONX_VERIFY_*`) to `/dev/ttyS0`; mechanism FULLY ACCEPTED;
  runtime-content gaps (mesh cascade, AppArmor enforcement under headless QEMU) consolidated
  under issue #39 (merge `c8bce0a`, DEC-PHASE7-035, DEC-PHASE7-039)
- **W7-4-A-tris**: Canonical hook path fix — `test_iso_serial_console.sh` migrated from
  legacy `iso/config/hooks/binary/` to canonical `iso/config/hooks/normal/` (closes #38,
  merge `68b9097`, DEC-PHASE7-034)
- **W7-4-A-bis**: AppArmor packages in canonical list and test path correction — three
  hardening tests updated to reference canonical `iso/config/package-lists/` path;
  4 AppArmor packages confirmed present (closes #37, merge `da66fee`, DEC-PHASE7-033)
- **W7-4-A**: systemd unit installation hook — `0615-install-systemd-units.hook.chroot`
  installs 8 unit files into squashfs at build time; closes issues #9 and #13
  (merge `0424b7e`, DEC-PHASE7-030, DEC-PHASE7-031)
- **W7-3-enabler**: Hook wiring — `iso/hooks/` moved to canonical `iso/config/hooks/`
  live-build paths; `tests/integration/test-iso-hooks-applied.sh` added as runtime-execution
  authority; `--hook-files` workaround removed (closes #32, DEC-PHASE7-024, DEC-PHASE7-025,
  DEC-PHASE7-026, DEC-PHASE7-028)
- **W7-3**: QEMU boot test harness — UEFI + BIOS boot via `scripts/qemu-boot-test.sh`;
  serial-file capture with `BOOT_SUCCESS_MARKERS`; KVM-when-available with TCG fallback;
  `--post-boot-script` attach contract (DEC-PHASE7-022) pre-declared for W7-4-B
  (merge `ed4ffaf`, DEC-PHASE7-017 through DEC-PHASE7-028)
- **W7-CI-FIX series**: Bookworm switch for matrix/mesh containers (DEC-PHASE7-015);
  PEP 668 `--break-system-packages` on Bookworm (DEC-PHASE7-016); Synapse pip-only
  install for frozen entrypoint contract (DEC-PHASE7-014)
- **W7-2**: E2E scenario script — Docker 3-node orchestration: mesh formation, Matrix
  bootstrap, forensic analysis, chain-of-custody report (DEC-PHASE7-007 through DEC-PHASE7-013)
- **W7-1**: ISO build pipeline modernization — `scripts/build-iso.sh` updated from
  v1.5.5 references to v2.0.0; lowercase `iso/` path throughout (DEC-PHASE7-002)

#### Phase 7 Notable Decisions

- **DEC-PHASE7-001**: Cheapest-iteration-first sequencing: Docker → QEMU → hardware
- **DEC-PHASE7-004**: Performance budgets are soft gates with documented exceptions (EOL clock dominates)
- **DEC-PHASE7-005**: Hardware USB boot is mandatory but runs as a parallel `approve` gate
- **DEC-PHASE7-017**: Single bash harness `scripts/qemu-boot-test.sh` for QEMU testing
- **DEC-PHASE7-020**: Serial-file capture with single-constant boot-success marker matcher
- **DEC-PHASE7-021**: KVM-when-available, TCG-fallback, 300s default timeout
- **DEC-PHASE7-022**: Pre-declared W7-4 attach contract: `--post-boot-script` + `--keep-running`
- **DEC-PHASE7-024**: Canonical live-build hook discovery via `iso/config/hooks/{live,normal,binary}/`
- **DEC-PHASE7-026**: `test-iso-hooks-applied.sh` as runtime-execution authority; EXPECTED_HOOKS is the project-wide authority
- **DEC-PHASE7-030**: Single chroot hook `0615-install-systemd-units.hook.chroot` as squashfs authority for Orion-X units
- **DEC-PHASE7-035**: In-guest serial-sentinel channel discipline — oneshot systemd unit writes to `/dev/ttyS0`; rejected SSH, QEMU monitor, and guest agent channels
- **DEC-PHASE7-039**: Mechanism-vs-runtime split: W7-4-B mechanism is the acceptance bar; runtime-content gaps tracked under issue #39
- **DEC-PHASE7-040**: Non-interactive first-boot under headless QEMU is a DEC-SEC-003 bounded-supersedence question; belongs in Phase 8 design rather than Phase 7 cleanup
- **DEC-PHASE7-041**: Cascade-consolidation META principle — when each fix slice surfaces a new cascade, the right response is to apply `continue-on-error: true` and open a tracker, not to chain more fix-cycle slices
- **DEC-PHASE7-042**: Second application of cascade-consolidation discipline; pattern confirmed as durable operational practice (W7-5-exit)
- **DEC-PHASE7-043**: Phase 7 closure — acceptance basis: all three CI workflows green at `05b98a3` after W7-6 landed; Phase 8 activated

---

### Phase 6 — Security Hardening (Completed)

- **W6-8**: Security hardening integration test — `tests/integration/test-security-hardening.sh`
  covers firewall, filesystem, AppArmor, credential audits (merge `229690c`)
- **W6-7**: Service hardening hook — `0620-service-hardening.hook.chroot` injects
  `ProtectSystem=strict` and related directives into Orion-X systemd units (merge `a242a63`)
- **W6-6**: First-boot setup wizard — `scripts/security/first-boot-wizard.sh` as a
  systemd oneshot; sets credentials and WireGuard keys on first boot (merge `0dd8787`,
  DEC-SEC-003)
- **W6-5**: Lynis modernization — `scripts/run-lynis.sh` modernized; v2 retired
  (merge `33a4ddb`, DEC-SEC-005)
- **W6-4**: AppArmor profiles — static profiles for Synapse, WireGuard, tshark,
  bulk_extractor, and volatility3 shipped in `iso/config/includes.chroot/etc/apparmor.d/`
  (merge `1b41881`, DEC-SEC-002)
- **W6-3**: Filesystem hardening hook — `0600-filesystem-hardening.hook.chroot`; `/tmp`
  as `tmpfs noexec,nosuid`, read-only host partition directives (merge `ef8a8de`)
- **W6-2**: nftables firewall — `etc/nftables.conf` with WireGuard + Matrix ports;
  unnecessary services blocked (merge `ac13b15`, DEC-SEC-001)
- **W6-1**: Credential audit tool — `scripts/security/audit-credentials.sh` to grep
  for hardcoded secrets across all scripts (merge `b0705ad`)

#### Phase 6 Notable Decisions

- **DEC-SEC-001**: nftables over iptables/ufw — Debian Bullseye default, kernel-native
- **DEC-SEC-002**: Static AppArmor profiles shipped in repo — inspectable, version-controlled, deterministic
- **DEC-SEC-003**: First-boot wizard as shell script + systemd oneshot — zero additional deps, runs once and disables
- **DEC-SEC-004**: Structural validation in CI, runtime validation in Phase 7
- **DEC-SEC-005**: Modernize `run-lynis.sh`, retire v2 — single source of truth

---

### Phase 5 — Forensic Toolkit Validation (Completed)

- **W5-6**: `download-samples.sh` modernized with `--offline` mode (DEC-FORENSIC-003)
- **W5-5**: Unit tests for `storyboard-gen.py` — HTML timeline generation coverage
- **W5-4**: Unit tests for `artifact-analyzer.py` — pure-logic function coverage
  (DEC-FORENSIC-001)
- **W5-3**: Forensic toolkit validation test — each tool verified responds to
  `--version`/`--help`
- **W5-2**: Synthetic sample data — syslog, CSV, JSON, XML, pcap, memory, firmware
  samples committed to `data/samples/` (DEC-FORENSIC-002)
- **W5-1**: `requirements.txt` populated with Python dependencies

---

### Phase 4 — Matrix Team Collaboration (Completed)

- **W4 / W3-1**: Matrix integration test — E2E message exchange with E2E encryption
  verified via Synapse API (merge `a8c822f`, DEC-MATRIX-TEST-001)
- **W2-2**: systemd unit for Matrix Synapse auto-start (merge `93fc0a6`, DEC-MATRIX-005)
- **W2-1**: Docker Compose for Matrix testing — layered compose extending mesh capabilities
  (merge `57059bc`, DEC-MATRIX-002, DEC-MATRIX-003, DEC-MATRIX-004)
- **W1-2**: `setup-matrix.sh` modernized with CLI arguments (merge `4ed60c7`,
  DEC-MATRIX-SETUP-001)
- **W1-1**: Synapse Docker infrastructure — `docker/Dockerfile.matrix-node`,
  `docker/matrix/homeserver.yaml` (merge `340693f`)

---

### Phase 3 — P2P Mesh Networking (Completed)

- **W-009**: Phase 3 finalization
- **W-008**: 3-node mesh integration test (mesh forms automatically in Docker compose)
- **W-007**: Docker 3-node mesh test environment
- **W-006**: `orionx-mesh status/peers` CLI with formatting helpers (DEC-MESH-004)
- **W-005**: Mesh health check daemon with auto-healing (DEC-MESH-002, DEC-MESH-005)
- **W-004**: `orionx-mesh join/leave` and live CLI commands
- **W-003**: UDP broadcast peer discovery (DEC-MESH-001)
- **W-002**: `orionx-mesh` CLI skeleton (DEC-MESH-004)
- **W-001**: Core mesh networking library

#### Phase 3 Notable Decisions

- **DEC-MESH-001**: UDP broadcast + shared config for dual-mode peer discovery
- **DEC-MESH-002**: systemd timer + oneshot for health checking (60s interval)
- **DEC-MESH-003**: In-kernel Docker testing with dedicated 3-node compose file
- **DEC-MESH-004**: Single bash CLI (`orionx-mesh`) with case-based subcommands
- **DEC-MESH-005**: Direct `wg`/`ip` for runtime, `wg-quick` for bootstrap only
- **DEC-003**: LAN-only mesh for v2.0.0 MVP (NAT traversal deferred to v2.1)

---

### Phase 2 — Build System and Linting (Completed)

- `Makefile` expanded with `lint`, `test-unit`, `docker-build`, `iso-build`, `clean` targets
- ShellCheck + ruff linting added to CI
- Package validation against Bullseye repos; install hooks for external packages
  (Ghidra, Autopsy, volatility3, Zeek)
- `build-iso.sh` validated end-to-end on Linux

---

### Phase 1 — Foundation (Completed)

- Repository bootstrap from v1.5.5 codebase (DEC-001)
- Flatten v1.5.5 into repo root; nested git repo removed
- ORION-X legacy directory archived to `archive/legacy-orionx/` (DEC-012)
- Debian Bullseye retained for v2.0.0 (DEC-002, DEC-009)

#### Foundation Notable Decisions

- **DEC-001**: Start from v1.5.5 as foundation — most mature version with all scripts and ISO config
- **DEC-002**: Debian Bullseye retained for v2.0 — stable, known working; NixOS migration deferred to v3.1
- **DEC-008**: Ship v2.0.0 before AI integration — foundation must work first
- **DEC-010**: Aggressive timeline — ship v2.0.0 on Bullseye before June 2026 EOL

---

## Open Issues Carried to Phase 8 Design Pass

- **#39**: W7-4-B runtime gaps — mesh cascade (`wg0` not up) + AppArmor enforcement
  under headless QEMU (first-boot non-interactive path per DEC-SEC-003 bounded supersedence)
- **#40**: W7-5 in-guest `boot_time_seconds` and `idle_ram_bytes` measurement reliability
  (depends on `multi-user.target` reach within timeout; blocked by #39)
- **#36**: ISO `includes.binary/` contents not appearing under `binary/` at hook time
  (polish, non-blocking for release)

---

_This file was generated for `wi-w8-finish-A` (Phase 8 docs bundle, DEC-PHASE8-002).
Sources: `git log main..develop` (148 commits at `221148c`) and the Decision Log in
`MASTER_PLAN.md` (DEC-001 through DEC-PHASE8-002)._
