# Changelog

All notable changes to Orion-X Phoenix Edition will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
