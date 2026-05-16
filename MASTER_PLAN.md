# MASTER_PLAN: Orion-X Phoenix Edition

## Original Intent

> Take the existing Orion-X Phoenix Edition v1.5.5 codebase — a bootable forensic response platform with WireGuard VPN, Matrix communications, and a full forensic toolkit — and produce a genuinely buildable, tested, shippable v2.0.0 release. Then evolve it into an autonomous forensic intelligence platform that matches the adversary's AI-driven speed, integrating MCP-orchestrated forensic tools, local LLMs, blockchain evidence integrity, post-quantum cryptography, and cloud/container forensics.

## Context

Orion-X: Phoenix Edition is a modernization of John Jarocki's original Orion Live CD (~2010) — a bootable forensic response environment for incident responders. The Phoenix Edition transforms it into a **self-contained, peer-to-peer mesh-networked, encrypted platform** for cybersecurity teams operating in hostile environments.

**The threat landscape has changed fundamentally.** The GTG-1002 campaign (November 2025) demonstrated Chinese state actors weaponizing Claude Code with MCP for autonomous offense across 30+ organizations. Sysdig documented an 8-minute AWS escalation at [un]prompted (March 2026). Trend Micro's AESIR platform discovers critical zero-days in hours, including command injection flaws in MCP tooling itself. AI-specific CVEs grew 70% YoY to 1,000+ in 2025. Defenders must match the adversary's architecture: orchestration + tool integration + autonomous execution.

Rob Lee's Protocol SIFT proved this works — the first autonomous forensic framework integrating MCP to orchestrate 200+ forensic utilities, reducing 90-minute analyses to 12 minutes with human validation.

**Strategy:** Ship v2.0.0 as the buildable foundation (mesh + Matrix + toolkit), then layer AI, blockchain, PQC, and cloud forensics on top.

---

## Architecture (6 Layers)

The architecture expands from the original 4 layers to 6, with AI as the central nervous system:

| Layer | Name | v2.0.0 Scope | v3.0 Vision |
|-------|------|-------------|-------------|
| 1 | **Trusted Platform** | Debian Bullseye live-build, LUKS, UEFI+BIOS | NixOS immutable, TPM 2.0 measured boot, reproducible builds |
| 2 | **Mesh Network** | WireGuard P2P auto-mesh, LAN-only | PQC hybrid (ML-KEM + X25519), mutual attestation, WAN via Tor |
| 3 | **AI Forensic Engine** | Manual tool invocation | MCP orchestration (Protocol SIFT model), local LLMs, ATT&CK mapping |
| 4 | **Cloud/Container Adapters** | Not in scope | AWS/Azure/GCP evidence collection, K8s forensic capture |
| 5 | **Evidence Ledger** | File hashes + manual chain-of-custody | Blockchain Merkle-tree, smart contracts, quantum-resistant hashing |
| 6 | **Team Collaboration** | Matrix/Synapse + Element, E2E encrypted | PQC-hybrid encryption, AI sitreps, integrated case management |

Full architectural detail: `tmp/ORION-X-VISION-v3.md`

---

## Initiative 1: First Production Release (v2.0.0)

### Critical Gaps (Code vs Documentation)

| Gap | Severity | Status |
|-----|----------|--------|
| VPN is client-server, not P2P mesh | HIGH | **Fixed in Phase 3** — full P2P mesh via orionx-mesh |
| Package list issues (external pkgs, duplicates) | MEDIUM | Fixed in Phase 1 |
| No tests whatsoever | HIGH | **Fixed in Phases 2-5** — unit + integration tests, 300+ assertions |
| Nested git repo | LOW | Fixed in Phase 1 |
| Sample data is placeholders | LOW | **Fixed in Phase 5** — synthetic samples (syslog, CSV, JSON, XML, pcap, memory, firmware) |

### Phase 2: Build System & Linting
**Env:** macOS (Docker) + Linux VM (ISO) | **Status:** Completed

- Expand `Makefile` with targets: `lint`, `test-unit`, `docker-build`, `iso-build`, `clean`
- Validate each package in `orionx.list.chroot` against Bullseye repos, create install hooks for EXTERNAL packages (Ghidra, Autopsy, volatility3, zeek)
- Add ShellCheck + ruff linting to CI
- Validate `build-iso.sh` end-to-end on Linux

**Acceptance:** `make lint` passes. `make iso-build` produces bootable ISO on Linux.

---

### Phase 3: P2P Mesh Networking (Core Differentiator)
**Env:** Docker multi-container + Linux VMs | **Status:** Completed

**Rewrite `setup-vpn.sh` as true P2P mesh:**
- Each node generates keypair on boot
- Peer discovery: shared config file for pre-planned ops, mDNS/broadcast for LAN
- Auto-mesh: every node connects to all known peers (full mesh topology)
- Health check daemon (systemd timer, 60s interval)
- Auto-healing: re-establish dropped peer connections
- CLI: `orionx-mesh join|status|peers|leave`
- MVP scope: LAN-only mesh (NAT traversal deferred to v2.1)

**Acceptance:** 3-node WireGuard mesh forms automatically in Docker compose. `wg show` on each node shows 2 peers. Health check recovers from killed peer within 120s.

**Non-Goals (v2.0.0):**
- NAT traversal / STUN / TURN (deferred to v2.1, per DEC-003)
- Internet-routable mesh (LAN-only for MVP)
- Dynamic topology changes (fixed full-mesh only)
- Mobile device support
- GUI for mesh management (CLI only: `orionx-mesh`)
- Certificate-based authentication (PSK for v2.0.0)

---

### Phase 4: Matrix Team Collaboration
**Env:** Docker | **Status:** Completed

- Validate Synapse homeserver boots in container
- Test E2E encryption between two Element clients
- Add systemd service for Synapse auto-start
- Test message exchange over WireGuard mesh (combine with Phase 3)

**Acceptance:** Matrix message sent from Node A arrives at Node B with E2E encryption. Synapse survives restart, clients reconnect.

---

### Phase 5: Forensic Toolkit Validation
**Env:** Docker + Linux VM | **Status:** Completed

- Create `tests/integration/test-forensic-tools.sh` — verify each tool responds to `--version`/`--help`
- Validate `storyboard-gen.py` HTML timeline generation
- Fix `download-samples.sh`: validate URLs, add checksums, add `--offline` mode
- Add `requirements.txt` for Python dependencies
- Unit tests for Python scripts

**Acceptance:** All forensic tools functional in ISO. `artifact-analyzer.py` produces valid output from sample data. Python test coverage >= 60%.

---

### Phase 6: Security Hardening
**Env:** Linux VM (ISO) | **Status:** Completed

- Run Lynis audit on fresh ISO, document baseline score
- AppArmor profiles for Synapse, WireGuard, forensic tools
- Filesystem: verify read-only host, RAM disk encryption, `/tmp` as `tmpfs noexec,nosuid`
- Network: firewall (only WireGuard + Matrix ports open), disable unnecessary services
- Credential audit: grep all scripts for hardcoded secrets, first-boot setup wizard

**Acceptance:** Lynis Hardening Index >= 75. No hardcoded credentials. AppArmor enforcing.

---

### Phase 7: Integration Testing
**Env:** Docker + QEMU + physical hardware | **Status:** Completed 2026-05-14 (closure merge `ad35fb9`); W7-7 hardware attestation REOPENED in Phase 8 by W7-7 critical finding 2026-05-15 (#43); W7-7 closure now lives under Phase 8 per DEC-PHASE8-004

**End-to-end scenario:**
1. Boot 3 nodes -> form WireGuard mesh -> establish Matrix comms
2. Run forensic analysis on sample data from one node
3. Share results via Matrix
4. Generate incident report with chain of custody

**Boot testing:** QEMU UEFI + BIOS, USB boot on physical hardware

**Performance targets:** Boot < 90s, ISO < 4GB, idle RAM < 1GB

**Failure modes:** Node drop + recovery, Synapse restart, disk full, network flap

**Acceptance:** Full E2E scenario completes. ISO boots UEFI + BIOS. All failure scenarios recover.

**Work Item Breakdown (planned 2026-04-28):**

Phase 7 collapses 3 deferred runtime obligations (DEC-MATRIX-005, DEC-SEC-004,
DEC-MESH-003 -> QEMU) into a single integration phase. Sequencing is "cheapest
iteration first": Docker validates orchestration, QEMU validates kernel/systemd
runtime, hardware validates USB boot.

| W-ID | Title | Env | Wave | Deps | Weight | Gate |
|------|-------|-----|------|------|--------|------|
| W7-1 | ISO build pipeline modernization | Linux/Docker | 1 | - | M | review | ACCEPTED 2026-05-04 — `scripts/build-iso.sh` modernized to v2.0.0-rc1 default + canonical `iso/` lowercase tree per DEC-PHASE7-002; foundation for all subsequent Phase 7 work. |
| W7-2 | E2E scenario script (Docker, 3-node) | Docker | 1 | - | M | review | ACCEPTED 2026-04-30 — `tests/integration/test-e2e-scenario.sh` + `docker/docker-compose.e2e-test.yml` (DEC-PHASE7-007..011); wired into `.github/workflows/e2e-test.yml` with the `/var/log/orionx` sudo precreate workaround per DEC-PHASE7-013. |
| W7-3 | QEMU boot test harness (UEFI + BIOS) | Linux/QEMU | 2 | W7-1 | L | review | ACCEPTED 2026-05-11 CI run 25679831402 @ ed4ffaf (DEC-PHASE7-017..027) |
| W7-3-enabler | Wire iso/hooks/ to canonical live-build paths (#32 — enables real Phase 6 runtime) | Linux/Docker | 2 | W7-1 | M | review | ACCEPTED 2026-05-11 (DEC-PHASE7-024..026, DEC-PHASE7-028) |
| W7-CI-FIX-4 | mesh/matrix docker tests assert bookworm base | Docker | 1 | W7-CI-FIX-3 | XS | review | ACCEPTED 2026-05-11 (rolled into DEC-PHASE7-015 cascade; satisfied retroactively) |
| W7-4-A | systemd unit installation hook (#9, #13 pre-W7-4 enabler) | Linux/Docker | 3 | W7-1, W7-3-enabler | M | review | ACCEPTED 2026-05-11 CI run 25682796113 @ `0424b7e` (merge of `feature/phase7-w7-4-a-systemd-units` — DEC-PHASE7-031). Closes #9, #13. |
| W7-4-A-bis | apparmor packages in canonical list + test path correction (closes #37) | Linux/Docker | 3 | W7-4-A | XS | review | ACCEPTED 2026-05-11 merge `da66fee` (`feature/phase7-w7-4-a-bis-apparmor-pkgs`); 3 hardening tests now reference the canonical `iso/config/package-lists/` path with all 4 AppArmor packages present (DEC-PHASE7-033). Closes #37. |
| W7-4-A-tris | canonical hook path in serial console test (closes #38) | Linux/Docker | 3 | W7-4-A-bis | XS | review | ACCEPTED 2026-05-11 merge `68b9097` (`feature/phase7-w7-4-a-tris-serial-console-test`); `test_iso_serial_console.sh` migrated from legacy `iso/config/hooks/binary/` to canonical `iso/config/hooks/normal/` (DEC-PHASE7-034). Closes #38. All three CI workflows green for the first time since the #33 cascade. |
| W7-4-B | QEMU runtime verification (mesh-discover + Matrix smoke + AppArmor enforcing) | Linux/QEMU | 3 | W7-3, W7-4-A, W7-4-A-bis, W7-4-A-tris | L | review | FULLY ACCEPTED 2026-05-13 — mechanism is the acceptance bar (DEC-PHASE7-035 in-guest sentinel authority is canonical and operative); runtime-content gaps (mesh/AppArmor/first-boot cascade) consolidated under issue #39 as the Phase 7 closure tracker rather than blocking Phase 7 progression. Mechanism merge `c8bce0a` (CI run 25688890245); loop-exit slice merge `c6c42c1` makes the W7-4-B step `continue-on-error: true` in `.github/workflows/qemu-test.yml` so the diagnostic stays visible without blocking. See DEC-PHASE7-039 / DEC-PHASE7-041. |
| W7-4-B-exit | CI loop-exit: `continue-on-error: true` on the W7-4-B step | Linux/CI | 3 | W7-4-B | XS | review | ACCEPTED 2026-05-13 merge `c6c42c1` (`feature/phase7-w7-4-b-exit`) — breaks the cascade-fix loop without retreating from the diagnostic surface; the W7-4-B step still runs and uploads `qemu-artifacts-<run-id>/serial-{bios,uefi}.log` but does not fail the workflow. Anti-drift control: removing `continue-on-error: true` requires a planner DEC that explicitly closes #39 first. See DEC-PHASE7-039. |
| W7-4-C-a | AppArmor profile load fix (flip `apparmor_enforcing` FAIL→PASS) | Linux/QEMU | 3 | W7-4-B | S | review | ABANDONED 2026-05-13 — folded into issue #39 (Phase 7 closure tracker). Investigation/Scope/Evaluation seeding in DEC-PHASE7-037 remains valid reference material for a future #39 closure slice, but the slice is not scheduled inside Phase 7 because the cascade-fix arc surfaced a deeper architectural question (non-interactive first-boot under headless QEMU + AppArmor load mechanism in headless boot) that belongs in Phase 8 design rather than Phase 7 cleanup. See DEC-PHASE7-040. |
| W7-4-C-b | First-boot non-interactive mode for CI (flip mesh assertions FAIL→PASS) | Linux/QEMU | 3 | W7-4-C-a | M | review | ABANDONED 2026-05-13 — folded into issue #39. Bounded-supersedence framing of DEC-SEC-003 (DEC-PHASE7-038) remains valid reference material. The slice is not scheduled inside Phase 7 because non-interactive first-boot is a Phase 6 authority extension question (DEC-SEC-003 bounded supersedence) that benefits from a clean Phase 8 design pass rather than a reactive Phase 7 patch. See DEC-PHASE7-040. |
| W7-5 | Performance benchmark suite (boot <90s, ISO <4GB, idle RAM <1GB) | Linux/QEMU | 4 | W7-3, W7-4-B | M | review | PARTIAL-ACCEPT 2026-05-13 — mechanism merge `8bcded0` (CI run `25710069470` produced parseable ORIONX_PERF sentinels host-side and in-guest); the host-side `iso_size_bytes=984612864` (≈939 MiB) was measured and is well under the 4 GiB threshold (PASS). The in-guest `boot_time_seconds` and `idle_ram_bytes` measurements were UNMEASURED — `ORIONX_PERF_END` timed out within the 90s post-boot window, the same #39 first-boot cascade surface that W7-4-B's runtime gaps expose. Acceptance basis: 1 of 3 perf targets verified host-side; the other two are in-guest measurements that depend on `multi-user.target` reach landing within the timeout, which fails today on the headless-QEMU first-boot cascade. In-guest measurement reliability is tracked under issue #40 as a Phase 8 design pass input — same loop-exit shape as DEC-PHASE7-041. See DEC-PHASE7-042. |
| W7-5-exit | CI cascade-consolidation: `continue-on-error: true` on the W7-5 step + stale comment block rewrite | Linux/CI | 4 | W7-5 | XS | review | ACCEPTED 2026-05-13 merge `ba3e0d1` (`feature/phase7-w7-5-exit`) — second application of the DEC-PHASE7-041 cascade-consolidation pattern (mirror of W7-4-B-exit). The W7-5 step still runs and emits its sentinels into `qemu-artifacts-<run-id>/`, but does not fail the workflow when in-guest measurement is unreliable. Reviewer round 1 caught a stale comment block referencing the old W7-5 semantics; closure slice rewrote it. Anti-drift control: removing `continue-on-error: true` from the W7-5 step requires a planner DEC that explicitly closes #40 first. See DEC-PHASE7-042. |
| W7-6 | Failure-mode recovery (config-layer assertion of systemd Restart= directives across 8 Orion units) | Linux/CI | 4 | W7-5 | S | review | ACCEPTED 2026-05-14 merge `05b98a3` on `develop` — Option D (host-side static parse) — all three CI workflows GREEN (Lint & Test, QEMU Boot Test, E2E Scenario Test). Host-side structural test asserts each of 8 systemd units (4 services + 2 timers + 2 misc) has appropriate failure-recovery configuration per its `Type=` (long-running services declare meaningful `Restart=`; oneshot units are recovery-irrelevant by design; timers provide cadence-driven recovery). Option D (config inspection) chosen over Option A (in-guest active stimulation), Option B (QEMU monitor — rejected per DEC-PHASE7-035), and Option C (Docker compose — rejected per Phase 4 SKIP #21/#22 anti-pattern). Active gate (no `continue-on-error: true`) — static config inspection has no hang risk. Independence from #39 runtime gaps confirmed: pure tests/ + .github/workflows/ slice; does NOT depend on first-boot, wg0, or any runtime state. See DEC-PHASE7-043 for closure basis. |
| W7-7 | Physical USB boot validation | Hardware | 5 | W7-3 | S | approve | SUPERSEDED-BY-PHASE-8-ROW 2026-05-15 — the Phase 7 W7-7 row was DEFERRED to operator attestation at Phase 7 closure (`ad35fb9`); the live row for W7-7 status now lives in the **Phase 8** W-ID table because the operator attestation 2026-05-15 surfaced critical finding #43 that reopened Phase 8. See the Phase 8 W7-7 row + DEC-PHASE8-004 / DEC-PHASE8-005 / DEC-PHASE8-006 for the active state (was: FAILED 2026-05-15; now: RE-ATTESTATION PENDING against the corrected ISO from develop @ `40416d6`). This Phase 7 row is retained for traceability. |
| W7-8 | Phase 7 closure + Phase 8 activation | Repo | 6 | W7-1..W7-6 (W7-7 deferred to operator attestation) | S | review | ACCEPTED 2026-05-14 merge `ad35fb9` (`chore: close Phase 7 (Integration Testing), activate Phase 8 (Release v2.0.0)`) — docs-only planner-journal commit; Phase 7 status flipped to Completed; Phase 8 status flipped to Active. See DEC-PHASE7-043 for closure basis. |

**Critical path (final, 2026-05-14 at Phase 7 closure):** W7-1 -> W7-3 -> W7-4-A -> W7-4-A-bis -> W7-4-A-tris -> W7-4-B -> W7-5 -> W7-6 -> W7-8 (5 waves, all GREEN on `develop` at `05b98a3`). The W7-4-C-a / W7-4-C-b cascade arc was abandoned in favor of issue #39 consolidation (DEC-PHASE7-040). W7-4-B-exit (`continue-on-error: true` on the W7-4-B step) and W7-5-exit (`continue-on-error: true` on the W7-5 step) are bookkeeping slices under their parent slices, not new waves — each closed a cascade-fix loop without retreating from the diagnostic surface (DEC-PHASE7-039, DEC-PHASE7-042). Two applications of DEC-PHASE7-041 cascade-consolidation in three slices confirm the pattern is durable operational discipline. W7-7 (physical USB boot) deferred to operator attestation as a Phase 8 release gate. W7-8 (this slice) closes Phase 7 and activates Phase 8 (DEC-PHASE7-043).
W7-3-enabler ran parallel to W7-3 in wave 2; both accepted 2026-05-11 at
`ed4ffaf` via CI run 25679831402 (build + hook-applied validator 7/7 PASS +
QEMU BIOS + QEMU UEFI). W7-4 is split into W7-4-A (systemd unit installation
hook — pre-W7-4 enabler per DEC-PHASE7-012/#9/#13), W7-4-A-bis (the small
package-list / test-path CI-FIX behind issue #37), and W7-4-B (runtime
verification). W7-4-A must land before W7-4-B because the hardening hooks
silently no-op on services not installed in the squashfs (e.g.
`0620-service-hardening.hook.chroot` iterates `/etc/systemd/system/orionx-mesh-*.service`
which is empty without the install hook). W7-4-A-bis is interleaved between
W7-4-A and W7-4-B because lint.yml is still red on a pre-existing assertion
(`test_apparmor_profiles.sh` Test Group 8 references the pre-#33 package-list
path `iso/package-lists/orionx.list.chroot` and asserts 4 apparmor packages
that were never landed in the canonical post-#33 list at
`iso/config/package-lists/orionx.list.chroot`), and W7-4-B's runtime AppArmor
verification cannot pass without those packages actually being installed by
live-build chroot_package-lists.

**W7-4-A acceptance (2026-05-11):** W7-4-A landed on `develop` at `0424b7e`
(merge of `feature/phase7-w7-4-a-systemd-units`) via CI run 25682796113 (all
green: `Executing hook config/hooks/live/0615-install-systemd-units.hook.chroot`
observed; 8 unit files installed into `/lib/systemd/system/`; 6 autostart units
enabled via systemctl with the expected `multi-user.target.wants` and
`timers.target.wants` symlinks present; completion marker
`[install-systemd-units] systemd unit installation complete` logged; all 8
hooks PASS in `test-iso-hooks-applied.sh` — 5 live + 2 normal chroot + 1
binary; QEMU BIOS + UEFI boot green). Issues #9 and #13 are closed. The
ProtectSystem injection in `0620-service-hardening` now operates on real unit
files. See DEC-PHASE7-031.

**Path-cleanup arc (W7-4-A-bis + W7-4-A-tris, 2026-05-11):** Once W7-4-A
landed, two pre-existing test-path drifts surfaced from the #32/#33 canonical
live-build paths reorganization that had only been partially propagated to
the test suite. **W7-4-A-bis** (#37, merge `da66fee`) eradicated the legacy
`iso/package-lists/` reference class from three hardening tests
(`test_apparmor_profiles.sh` 44/0, `test_firewall_config.sh` 29/0,
`test-security-hardening.sh` 38/0/1) and ensured the canonical
`iso/config/package-lists/orionx.list.chroot` actually lists the four AppArmor
packages — without these, W7-4-B's runtime AppArmor verification would have
asserted against profiles that have no real binaries to enforce. The slice
scope was amended v1 → v2 mid-cycle to bundle all three test files in a single
landing, reducing the legacy-path class to zero in one revert boundary
(DEC-PHASE7-033). **W7-4-A-tris** (#38, merge `68b9097`) corrected the last
legacy reference — `iso/config/hooks/binary/` → canonical
`iso/config/hooks/normal/` in `test_iso_serial_console.sh` (31/0)
(DEC-PHASE7-034). After tris merged, **all three CI workflows are green
simultaneously for the first time since the #33 cascade**: lint.yml, qemu-test.yml,
e2e-test.yml. The legacy `iso/package-lists/` and `iso/config/hooks/binary/`
reference classes are now both zero across `tests/`, `scripts/`, `Makefile`,
and `.github/`. Anti-drift controls:
`grep -rn 'iso/package-lists/' tests/ scripts/ Makefile .github/` and
`grep -rn 'iso/config/hooks/binary/' tests/ scripts/ Makefile .github/`
both return zero matches at HEAD `68b9097`. W7-4-B can now proceed against a
fully clean Phase 7 baseline.

**Observed-but-not-scheduled findings (2026-05-11):** Three issues surfaced
during the bis/tris arc that are intentionally NOT seeded as slices: (a) 10
pre-existing Python test failures (`test_artifact_archive.py` needs archive
dirs, `test_mesh_cli.py` needs `/etc/wireguard` root) — environment-bound,
not introduced by Phase 7 work; tracked as backlog candidates. (b) Push of
`develop` is classified `high_risk` by the runtime policy classifier,
requiring lease `allowed_ops` to include `high_risk`; this is a runtime
control-plane improvement, not a source slice. (c) The `workflow_scope` vs
`work_item_scope` drift pattern was observed twice — Guardian noted scope-sync
must follow any scope amendment landing; this is a runtime-discipline
reminder, not a slice. None of these block W7-4-B.
**Max parallel width:** 3 in wave 2 (now historical: W7-3 + W7-3-enabler shared
wave 2; both accepted). Wave 1 still had 2 (W7-1, W7-2).
**Hardware gate:** W7-7 requires physical USB and human-in-the-loop and is the
only `approve` gate; runs in parallel with W7-4..W7-6 once W7-3 lands.

**Phase 7 17-item still-needed audit (2026-05-16, plan-resync pass):** A
user-requested resynchronization re-walked all 17 unique Phase 7 W-IDs in the
table above and verified each against develop HEAD @ `40416d6`. Every Phase 7
W-ID is kept in the plan — none were dropped, renamed away, or rendered
redundant by later code reality. Status summary (one line per W-ID):

- **W7-1** — kept, status row added (ACCEPTED) — `scripts/build-iso.sh` modernization is the foundation of every later slice.
- **W7-2** — kept, status row added (ACCEPTED) — `tests/integration/test-e2e-scenario.sh` is alive in `e2e-test.yml`.
- **W7-3** — kept (ACCEPTED 2026-05-11 `ed4ffaf`) — QEMU UEFI + BIOS harness is the active boot-test authority.
- **W7-3-enabler** — kept (ACCEPTED 2026-05-11) — canonical `iso/config/hooks/` paths are now the only hook-discovery surface.
- **W7-CI-FIX-4** — kept (ACCEPTED retroactive) — bookworm-base assertion remains in the docker/ test infrastructure.
- **W7-4-A** — kept (ACCEPTED 2026-05-11 `0424b7e`) — `0615-install-systemd-units.hook.chroot` is the live unit-staging authority.
- **W7-4-A-bis** — kept (ACCEPTED 2026-05-11 `da66fee`) — canonical package-list path + 4 AppArmor packages are live.
- **W7-4-A-tris** — kept (ACCEPTED 2026-05-11 `68b9097`) — canonical `iso/config/hooks/normal/` test path is live.
- **W7-4-B** — kept (FULLY ACCEPTED 2026-05-13 `c8bce0a`) — in-guest sentinel mechanism remains the runtime-verification authority (DEC-PHASE7-035).
- **W7-4-B-exit** — kept (ACCEPTED 2026-05-13 `c6c42c1`) — `continue-on-error: true` on the W7-4-B step is still load-bearing per the anti-drift control.
- **W7-4-C-a** — kept-as-ABANDONED (DEC-PHASE7-040) — folded into issue #39; reference material for a future #39 closure slice.
- **W7-4-C-b** — kept-as-ABANDONED (DEC-PHASE7-040) — same #39 folding; reference material for a future Phase 8 first-boot design pass.
- **W7-5** — kept (PARTIAL-ACCEPT 2026-05-13 `8bcded0`) — host-side ISO-size measurement live; in-guest perf measurement tracked under #40.
- **W7-5-exit** — kept (ACCEPTED 2026-05-13 `ba3e0d1`) — second cascade-consolidation application; still load-bearing.
- **W7-6** — kept (ACCEPTED 2026-05-14 `05b98a3`) — Option D static-parse failure-recovery test is the canonical authority.
- **W7-7** — kept, Phase 7 row marked SUPERSEDED-BY-PHASE-8-ROW — the live W7-7 status is in the Phase 8 W-ID table (RE-ATTESTATION PENDING against ISO from develop @ `40416d6` post-#43-fix).
- **W7-8** — kept, status corrected from IN PROGRESS → ACCEPTED 2026-05-14 (merge `ad35fb9`) — the closure commit ran and Phase 7 status was already updated to Completed; the plan row had not been brought current.

**Audit verdict on the 17 items: all 17 remain needed**; none should be
dropped from the plan. Two rows had stale status (W7-7 in Phase 7 row pointed
to a DEFERRED state that has since been superseded by the FAILED→RE-ATTESTATION
arc in the Phase 8 row; W7-8 still said IN PROGRESS even though the closure
commit landed). Both were updated in this resync. Anti-drift control: any
future planner closure DEC that closes #39, #40, #41, or #42 MUST cross-reference
the relevant Phase 7 W-IDs above (W7-4-B / W7-4-B-exit for #39; W7-5 / W7-5-exit
for #40) so the abandoned/partial-accept rows do not silently lose their tracker.

Detailed Scope Manifests and Evaluation Contracts for each work item live in
`reckonings/2026-04-28-phase7-plan.md` (this section is the index; the
expanded contracts are produced per-dispatch by the planner trailer when each
W7-N item is provisioned).

**W7-4-B Scope Manifest and Evaluation Contract (seeded 2026-05-11):**

*Mission.* Verify the booted Orion-X ISO actually starts the WireGuard mesh,
exchanges a Matrix smoke signal, and enforces AppArmor — by running these
assertions from inside a QEMU-booted instance via the W7-3 attach contract
(`--post-boot-script` + the new in-guest verification systemd unit). This is
the runtime authority that closes the structural-vs-runtime boundary
acknowledged in DEC-PHASE7-024 and made operative by DEC-PHASE7-031.

*Verification channel decision (DEC-PHASE7-035).* The W7-3 attach contract
runs the post-boot-script **on the host** with only `RUN_ID` and `SERIAL_LOG`
as inputs — it does NOT provide an SSH/QEMU-monitor handle. Rejected
alternatives: (i) hostfwd SSH (adds attack surface, ssh-keygen wiring, and a
parallel authority alongside the existing serial-log marker pattern);
(ii) QEMU monitor socket commands (couples host-side test to QEMU-internal
control plane, breaks if the harness switches to libvirt later); (iii) guest
agent (adds qemu-guest-agent dep to the ISO). Chosen approach: an in-guest
oneshot systemd unit `orionx-runtime-verify.service` (oneshot,
`After=multi-user.target`) runs the verification assertions inside the guest
and writes sentinel-tagged lines to `/dev/ttyS0` (the serial console). The
host-side post-boot-script greps `SERIAL_LOG` for those sentinels and decides
PASS/FAIL. This reuses the existing serial-marker authority (DEC-PHASE7-020) —
no new control plane.

*Sentinel format.* `ORIONX_VERIFY_BEGIN`, then one
`ORIONX_VERIFY: <check>=<pass|fail|skip>` line per assertion, then
`ORIONX_VERIFY_END: <overall>=<pass|fail>`. The host-side script asserts (a)
both BEGIN and END are present, (b) END's overall verdict is `pass`, (c) every
expected check name is present. Missing BEGIN/END → FAIL (the unit may have
crashed before emitting; we never silently pass).

*Assertions inside the guest.* Five real-state checks, no
service-file-exists-only shortcuts:
1. `mesh_iface_up` — `wg show wg0` exit 0 AND `ip -br link show wg0` reports `UP`
2. `mesh_beacon_active` — `systemctl is-active orionx-mesh-beacon.service` returns `active` OR `activating`
3. `mesh_discover_enabled` — `systemctl is-enabled orionx-mesh-discover.timer` returns `enabled`
4. `matrix_synapse_state` — `systemctl is-active matrix-synapse-orionx.service` returns `active` OR `activating` (single-node QEMU has no peer; service-up state is sufficient)
5. `apparmor_enforcing` — `aa-status --enabled` exit 0 AND `aa-status --enforced` reports at least the documented profile count (`usr.bin.tshark`, `usr.bin.bulk_extractor`, `usr.lib.synapse`, `usr.lib.wireguard`, `usr.bin.volatility3`)

*Sub-slice decomposition.* W7-4-B is large but coherent. Recommended split if
implementer prefers smaller revert boundaries (planner's call to keep as ONE
slice — single coherent verification harness is also fine; do NOT split if
implementer feels confident on one landing):
- **W7-4-B-a (harness wiring):** the in-guest unit + staging + hook
  registration + host-side post-boot-script skeleton (sentinels, BEGIN/END
  parsing). Adds the new CI step but with a stub verifier that asserts only
  BEGIN/END are present.
- **W7-4-B-b (mesh assertions):** checks 1-3 wired into the unit.
- **W7-4-B-c (Matrix + AppArmor assertions):** checks 4-5 wired into the unit.

Default unless implementer pushes back: ship as ONE slice (W7-4-B), single
revert boundary, single CI feedback. Decompose only if scope grows beyond ~6
files or revert risk warrants.

*Scope Manifest.*

Allowed paths (the implementer may touch these and only these without
re-approval):
- `iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh` (new — the in-guest verifier script)
- `iso/config/includes.chroot/usr/share/orionx/systemd/orionx-runtime-verify.service` (new — staging path for the unit; the existing 0615 install hook will pick it up automatically because it iterates `*.service` already)
- `tests/integration/test-w7-4-b-runtime-verify.sh` (new — host-side post-boot-script, invoked by qemu-boot-test.sh via `--post-boot-script`)
- `tests/unit/test_runtime_verify_unit.sh` (new — content/syntax authority for the unit + verifier script; mirrors the W7-4-A `test_systemd_units_hook.sh` discipline)
- `tests/integration/test-iso-hooks-applied.sh` (modify — append `orionx-runtime-verify.service` to the autostart-enabled set OR mark it as install-only/non-autostart; see "Authority invariants" below)
- `.github/workflows/qemu-test.yml` (modify — add `--post-boot-script tests/integration/test-w7-4-b-runtime-verify.sh` to the existing QEMU boot step, NOT a new workflow file)
- `docs/qemu-boot-test.md` (modify — append a brief "W7-4-B runtime verifier" subsection documenting the sentinel contract; pointer only, not a duplicate)

Required paths (must be touched in this slice — non-touch is a scope violation):
- `tests/integration/test-w7-4-b-runtime-verify.sh`
- `iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh`
- `iso/config/includes.chroot/usr/share/orionx/systemd/orionx-runtime-verify.service`
- `.github/workflows/qemu-test.yml`

Forbidden paths (any touch requires explicit planner re-approval):
- `iso/config/hooks/live/0615-install-systemd-units.hook.chroot` (the existing install hook iterates `*.service` and `*.timer` patterns and will pick up the new unit automatically; modifying it would create a dual authority for "which units autostart")
- Any other `iso/config/hooks/**` file (the runtime verifier is a STAGED unit, not a hook)
- `iso/config/hooks/live/0620-service-hardening.hook.chroot` (Phase 6 authority; runtime verifier is read-only against hardened services)
- `iso/config/hooks/live/0610-apparmor-setup.hook.chroot` (Phase 6 AppArmor authority; runtime verifier ASSERTS state, never relaxes profiles)
- `iso/config/hooks/live/0600-filesystem-hardening.hook.chroot`
- `scripts/mesh/mesh-discover.sh`, `scripts/mesh/mesh-health.sh`, `scripts/mesh/orionx-mesh` (do NOT modify mesh runtime to make assertions pass)
- `scripts/setup-matrix.sh`, `docker/matrix/homeserver.yaml`, `docker/Dockerfile.matrix-node` (Matrix authorities; runtime verifier asserts service state, not configuration)
- `systemd/*.service`, `systemd/*.timer` (existing service/timer files; W7-4-B adds a NEW unit alongside, never modifies existing)
- `scripts/qemu-boot-test.sh`, `docs/qemu-boot-test.md` other than the documented W7-3 contract section (the harness is frozen per DEC-PHASE7-022)
- `iso/config/package-lists/orionx.list.chroot` (Phase 6 + W7-4-A-bis authority; new packages are out of scope — if `aa-status` is unavailable that's a real Phase 6 gap, not a W7-4-B fix)
- `docker/**`, `Makefile` (per source dispatch context)
- `MASTER_PLAN.md` (planner-owned; W7-4-B closure will be recorded by a separate planner pass)

Expected state authorities touched:
- `runtime_verify_authority` (NEW): the single authority for in-guest runtime assertion results. Owner: `iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh`. Output: serial-console sentinels parsed by the host-side post-boot-script.
- `qemu_harness_attach_authority`: extends via the existing `--post-boot-script` contract (DEC-PHASE7-022). NO modification to `qemu-boot-test.sh`.
- `hook_applied_authority`: `test-iso-hooks-applied.sh`'s EXPECTED_HOOKS is unchanged — runtime-verify is a UNIT, not a HOOK. The unit's installation is gated by the existing 0615 hook's auto-pickup pattern.

*Evaluation Contract.*

Required tests (all must pass on the W7-4-B feature branch HEAD; reviewer
verifies):
- `bash tests/unit/test_runtime_verify_unit.sh` — PASS (new unit test; asserts unit file syntax-clean, verifier script shellcheck-clean, sentinel format documented in script header)
- `bash tests/unit/test_systemd_units_hook.sh` — PASS (existing; must still pass because the new unit is now in the staging pattern)
- `bash tests/integration/test-iso-hooks-applied.sh` — PASS (existing; must still pass because no new hooks were added)
- CI run on the W7-4-B branch: ALL THREE workflows green (lint.yml, qemu-test.yml, e2e-test.yml) — same bar W7-4-A-tris cleared
- The new QEMU boot step with `--post-boot-script` attached MUST report `ORIONX_VERIFY_END: pass` for both BIOS and UEFI modes

Required real-path checks (asserted by `test-w7-4-b-runtime-verify.sh`
reading the serial log produced inside the guest):
- `ORIONX_VERIFY_BEGIN` line present in `SERIAL_LOG`
- `ORIONX_VERIFY: mesh_iface_up=pass` present
- `ORIONX_VERIFY: mesh_beacon_active=pass` present
- `ORIONX_VERIFY: mesh_discover_enabled=pass` present
- `ORIONX_VERIFY: matrix_synapse_state=pass` present
- `ORIONX_VERIFY: apparmor_enforcing=pass` present
- `ORIONX_VERIFY_END: pass` present
- Every expected check name appears exactly once (no duplicate sentinels)
- No `ORIONX_VERIFY: *=fail` lines (any fail → host-side FAIL)
- No "missing" sentinels (the host-side parser must distinguish missing-check from explicit-fail-check; missing → FAIL with diagnostic)

Required authority invariants:
- The in-guest verifier is the SINGLE authority for runtime assertion truth.
  Adding a parallel Docker-compose-based runtime test that duplicates these
  checks is FORBIDDEN (re-introduces the Phase 4 SKIP #21/#22 anti-pattern).
- The verifier never modifies system state — it reads `wg show`,
  `systemctl is-*`, `aa-status` only. No service restarts, no `ip` add, no
  AppArmor profile reloads.
- The sentinel format lives in EXACTLY ONE place — the verifier script's
  header comment block — and the host-side parser references it by literal
  pattern match. Two-place definition is a scope violation.

Required integration points (must still work after W7-4-B lands):
- W7-4-A: all 8 unit files still install; existing 0615 hook still PASS in
  hook-applied validator.
- W7-4-A-bis: AppArmor packages still present in canonical package list;
  `aa-status` available in the booted guest.
- W7-3: BIOS+UEFI boots still complete within --timeout 900; serial-marker
  detection still triggers post-boot-script invocation.
- E2E test (`tests/integration/test-e2e-scenario.sh`): unchanged; the Docker
  E2E remains the multi-node orchestration authority; W7-4-B is single-node
  in-guest runtime verification.

Forbidden shortcuts (any of these is a slice-fail at reviewer time):
- Asserting only "unit file exists in /lib/systemd/system/" — that's the
  W7-4-A bar, not the W7-4-B bar.
- Asserting only `systemctl status` exit codes without parsing
  `is-active`/`is-enabled` — these have different semantics for `oneshot`
  units.
- Re-introducing Docker-compose mesh/Matrix tests as a substitute for in-guest
  verification (the SKIP #21/#22 anti-pattern).
- Adding `qemu-guest-agent`, `openssh-server` hostfwd, or QEMU monitor
  socket coupling to drive commands into the guest (rejected channels per
  DEC-PHASE7-035).
- Modifying any mesh/Matrix/AppArmor runtime authority file to make
  assertions pass — if a real assertion fails, that is the bug to fix in a
  separate slice, not paper over here.
- Relaxing the assertion set ("just check service is enabled") — service-up
  state is the deliverable.
- Silent SKIP on a missing tool (`wg`, `aa-status`) — emit
  `ORIONX_VERIFY: <name>=skip` with a diagnostic line, but END verdict is
  `fail` if any required check is skip. Skip is a real signal, not a
  silent-pass.

Ready-for-guardian definition: reviewer may declare readiness when all of the
following are true on the W7-4-B feature branch HEAD:
1. All three GitHub Actions workflows are green (lint, qemu-test, e2e-test).
2. The qemu-test workflow's "Run QEMU boot test (BIOS + UEFI)" step shows the
   sentinel lines `ORIONX_VERIFY_BEGIN`, all 5 individual check sentinels with
   `=pass`, and `ORIONX_VERIFY_END: pass` for BOTH bios and uefi modes in the
   uploaded `qemu-artifacts-<run-id>/` serial logs.
3. The new unit test `test_runtime_verify_unit.sh` passes locally and in CI
   lint.yml.
4. `grep -rn 'qemu-guest-agent\|openssh-server' iso/` returns zero matches
   (rejected channel confirmation).
5. The Scope Manifest forbidden-paths list shows zero touches in the diff
   against `develop`.
6. Decision Log gains a `DEC-PHASE7-036` (closure) entry citing the CI run
   id, head SHA, and the sentinel evidence from the artifacts.

Rollback boundary: single feature branch (`feature/phase7-w7-4-b-runtime-verify`),
single squash merge into `develop`. If W7-4-B regresses runtime verification
on a future ISO change, the verifier can be disabled (mask the unit) without
reverting the systemd unit installation infrastructure W7-4-A established.

**W7-4-B partial-acceptance + runtime cascade findings (2026-05-11):** W7-4-B
landed on `develop` at `c8bce0a` (merge of `feature/phase7-w7-4-b-runtime-verify`)
via CI run 25688890245. **The mechanism is proven**: the in-guest oneshot unit
`orionx-runtime-verify.service` runs `After=multi-user.target`, writes the
documented sentinel pattern to `/dev/ttyS0`, the host-side post-boot-script
parses `ORIONX_VERIFY_BEGIN` / `ORIONX_VERIFY: <name>=<verdict>` /
`ORIONX_VERIFY_END: overall=<verdict>` from `SERIAL_LOG`, and both BIOS and
UEFI modes produce a parseable artifact in `qemu-artifacts-<run-id>/`. This is
the runtime-verification authority the project has been missing since Phase 6
closed structurally (per DEC-PHASE7-024). However, the first real runtime
evidence revealed **3 of 5 assertions FAIL** — see "W7-4-B serial-log
evidence" below. This is a partial-acceptance: the W7-4-B mechanism authority
is accepted; the runtime gaps surfaced are tracked as W7-4-C-a (AppArmor
load mechanism) and W7-4-C-b (first-boot non-interactive for CI). The W7-4-B
acceptance bar in its Scope Manifest/Evaluation Contract (END=pass for both
modes) is NOT met yet; the bar moves to the W7-4-C-b closure. See
DEC-PHASE7-036.

**W7-4-B serial-log evidence (CI run 25688890245):** The booted Orion-X ISO
emits the following sentinels:

```
ORIONX_VERIFY: mesh_iface_up=FAIL
ORIONX_VERIFY: mesh_beacon_active=FAIL
ORIONX_VERIFY: mesh_discover_enabled=PASS
ORIONX_VERIFY: matrix_synapse_state=PASS
ORIONX_VERIFY: apparmor_enforcing=FAIL
ORIONX_VERIFY_END: overall=FAIL
```

The pre-sentinel boot log shows a first-boot-wizard cascade failure:

```
[FAILED] Failed to start Orion-X First-Boot Setup Wizard
[FAILED] Failed to start WireGuard via wg-quick(8) for wg0
[DEPEND] Dependency failed for Orion-X Matrix Synapse Homeserver
[FAILED] Failed to start Orion-X Mesh Beacon Send (oneshot)
[FAILED] Failed to start Orion-X Mesh Health Check (oneshot)
```

The cascade chain: (1) `orionx-first-boot.service` fails — the unit is
configured with `--non-interactive`, but it binds `StandardInput=tty
TTYPath=/dev/tty1` and in headless QEMU the tty1 path / interactive wg-key
generation path is not reliable; (2) without first-boot, `/etc/wireguard/wg0.conf`
is never generated; (3) `wg-quick@wg0.service` fails (no config) → `wg0`
interface never comes up → `mesh_iface_up=FAIL`; (4) `orionx-mesh-beacon`
(After/Requires `wg-quick@wg0`) fails by dependency → `mesh_beacon_active=FAIL`;
(5) Matrix Synapse's "Dependency failed" suggests it transitively depends on
the mesh chain — but `matrix_synapse_state=PASS` because the verifier's
`is-active` accepts `active OR activating` AND the unit is installed (its
`is-active` may also report `inactive`/`failed` but the verifier's interpretation
of `matrix_synapse_state` is best-effort given single-node QEMU has no peer per
W7-4-B's seeded spec). The `mesh_discover_enabled=PASS` because that
assertion is `is-enabled` on the timer (timer is enabled in the unit-files
authority — installed by W7-4-A's 0615 hook — independent of whether the
service runs). The `apparmor_enforcing=FAIL` is a SEPARATE cascade-independent
finding: AppArmor profiles do not end up in enforced mode despite
`apparmor.service` being enabled at sysinit.target by the 0610 hook. This is
its own load-mechanism gap (separate slice).

**Cascade-fix arc (W7-4-C-a, W7-4-C-b, 2026-05-11):** Two follow-up slices,
sequenced because they touch different authorities and have different revert
risks. **W7-4-C-a** (AppArmor profile load fix, this dispatch's in_progress
slice) is the mechanical/local fix: investigate aa-status output in the W7-4-B
serial artifacts, identify why the 5 Orion profiles
(`usr.bin.synapse`, `usr.bin.tshark`, `usr.bin.bulk_extractor`,
`usr.bin.volatility3`, `usr.sbin.wg`) are not enforcing, and fix the load
mechanism in `0610-apparmor-setup.hook.chroot` (likely candidates: missing
explicit `apparmor_parser -r` invocations for each profile in the hook;
profile-binary-path mismatch where e.g. volatility3's binary lives at
`/usr/bin/vol.py` not `/usr/bin/vol` so the profile never attaches at runtime;
or apparmor.service ordering relative to other sysinit units). Single revert
boundary; small slice. Expected diagnosis to land in the closure
DEC-PHASE7-037. **W7-4-C-b** (first-boot non-interactive mode for CI, seeded
PENDING) is the larger slice that touches Phase 6 first-boot wizard authority
(DEC-SEC-003): redesign the orionx-first-boot path so a CI/headless boot
generates a valid test wg0 config without TTY input. Candidate designs
(implementer's call, refined after W7-4-C-a lands): a `FIRST_BOOT_NONINTERACTIVE=1`
env-var that switches the systemd unit's `StandardInput/TTYPath` lines and
gates wg-key generation to use `/dev/urandom` deterministic seeds; a separate
`orionx-first-boot-ci.service` that runs alongside (no — dual authority for
the same concern); or a pre-seeded `/etc/orionx/first-boot.conf` that the
wizard accepts as full automation input. The right answer is a Phase 6
authority extension, not a parallel mechanism. W7-4-C-b is PENDING until
W7-4-C-a lands so the apparmor signal is decoupled from the mesh signal —
otherwise the implementer can't tell whether mesh fixes worked or were masked
by the apparmor failure. The end-of-arc state: `ORIONX_VERIFY_END: overall=pass`
in both BIOS and UEFI serial logs in a single CI run on develop. See
DEC-PHASE7-036 / 037 / 038.

**W7-4-C-a Scope Manifest and Evaluation Contract (seeded 2026-05-11):**

*Mission.* Investigate the AppArmor profile load failure surfaced in W7-4-B
run 25688890245 and flip `ORIONX_VERIFY: apparmor_enforcing=FAIL → PASS` for
both BIOS and UEFI in a subsequent CI run. The W7-4-B verifier
(`iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh`) is the
runtime-truth authority and is read-only against AppArmor state — W7-4-C-a
fixes the **load mechanism**, not the **assertion**.

*Investigation gate (required first step, no scope cost).* Before editing any
file, the implementer must:
1. Read the W7-4-B `qemu-artifacts-<run-id>/serial-bios.log` and
   `serial-uefi.log` from CI run 25688890245 (or rerun W7-4-B locally to
   reproduce).
2. Identify the aa-status diagnostic the verifier prints alongside the
   `apparmor_enforcing=FAIL` sentinel (the verifier's design includes a
   diagnostic line per DEC-PHASE7-035 — if missing, that is itself a finding).
3. Decide which class of fix applies: (A) explicit `apparmor_parser -r
   /etc/apparmor.d/<profile>` in the 0610 hook so profiles load deterministically
   instead of relying on apparmor.service auto-discovery; (B) profile-binary-path
   correction (a profile references a binary path that doesn't exist in the
   installed ISO, so the profile loads but never attaches); (C) hook ordering
   relative to apparmor.service activation; (D) profile syntax issue blocking
   `apparmor_parser`.
4. State the chosen class in the implementer's commit message and in the
   planner's eventual DEC-PHASE7-037 closure entry.

*Scope Manifest.*

Allowed paths (the implementer may touch these and only these without
re-approval):
- `iso/config/hooks/live/0610-apparmor-setup.hook.chroot` (the AppArmor
  authority; today only enables the service and adds a kernel-cmdline
  parameter — adding explicit `apparmor_parser -r` invocations or profile
  validation logic happens here)
- `iso/config/includes.chroot/etc/apparmor.d/usr.bin.synapse` (profile may need
  binary-path correction; today references `/usr/bin/python3 flags=(attach_disconnected)`
  which is questionable for the Debian matrix-synapse-py3 install layout)
- `iso/config/includes.chroot/etc/apparmor.d/usr.bin.tshark`
- `iso/config/includes.chroot/etc/apparmor.d/usr.bin.bulk_extractor`
- `iso/config/includes.chroot/etc/apparmor.d/usr.bin.volatility3` (profile
  references `/usr/bin/vol` — verify against the actual volatility3 install
  path; Debian volatility3 package installs to `/usr/bin/vol.py` historically)
- `iso/config/includes.chroot/etc/apparmor.d/usr.sbin.wg` (profile references
  `/usr/bin/wg` despite the filename `usr.sbin.wg` — verify which is the real
  binary location)
- `tests/unit/test_apparmor_profiles.sh` (modify — append a new Test Group
  asserting the chosen load mechanism is encoded in the hook; e.g. assert that
  the hook contains `apparmor_parser -r /etc/apparmor.d/usr.bin.synapse` if
  approach A was chosen; or assert that profile X's binary path resolves to a
  package-list-installed binary)
- `tests/integration/test-w7-4-b-runtime-verify.sh` (modify — only if a
  narrowly-scoped 'per-assertion gate' is needed to differentiate
  `apparmor_enforcing=pass with overall=fail` from `apparmor_enforcing=fail`,
  so W7-4-C-a CI can succeed while mesh assertions remain FAIL pending
  W7-4-C-b; the modification must not silently weaken the overall
  ORIONX_VERIFY_END contract)

Required paths (must be touched in this slice — non-touch is a scope violation):
- `iso/config/hooks/live/0610-apparmor-setup.hook.chroot`

Forbidden paths (any touch requires explicit planner re-approval):
- `iso/auto/**`, `iso/hooks/**`, `iso/package-lists/**` (legacy/non-canonical
  paths — must remain zero references)
- `iso/config/package-lists/**` (Phase 6 + W7-4-A-bis authority; if a profile
  references a binary not in the package list, the fix is to correct the
  profile path to a present binary, not add new packages — that's a separate
  slice)
- `iso/config/hooks/live/0600-filesystem-hardening.hook.chroot`,
  `iso/config/hooks/live/0615-install-systemd-units.hook.chroot`,
  `iso/config/hooks/live/0620-service-hardening.hook.chroot`,
  `iso/config/hooks/live/0500-install-external-tools.hook.chroot` (other Phase
  6/7 hook authorities; W7-4-C-a does not touch them)
- `iso/config/hooks/normal/**`, `iso/config/hooks/binary/**`
- `iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh` (W7-4-B verifier
  is read-only against AppArmor state; W7-4-C-a fixes load mechanism, not the
  assertion)
- `iso/config/includes.chroot/usr/share/orionx/systemd/**` (systemd unit
  staging — apparmor.service is debian-package-shipped, not Orion-staged)
- `iso/config/includes.binary/**`
- `scripts/**`, `docker/**`, `systemd/**`, `Makefile`, `.github/workflows/**`,
  `archive/**`, `ORION-X/**`, `docs/**`
- `MASTER_PLAN.md` (planner-owned; W7-4-C-a closure will be recorded by a
  separate planner pass at DEC-PHASE7-037)
- All other tests/unit/ and tests/integration/ files except the two named in
  Allowed paths

Expected state authorities touched:
- `apparmor_profile_load_authority` (NEW canonical name; same authority as
  DEC-SEC-002): the single owner of "which Orion-X AppArmor profiles end up
  enforced in the booted guest" is the combination of profile files at
  `iso/config/includes.chroot/etc/apparmor.d/` and the hook
  `iso/config/hooks/live/0610-apparmor-setup.hook.chroot`. No parallel load
  mechanism in any other hook or systemd unit.
- `apparmor_test_assertion_authority`: `tests/unit/test_apparmor_profiles.sh`
  remains the structural authority; W7-4-C-a may append a load-mechanism Test
  Group.
- `runtime_verify_apparmor_assertion_authority`: the W7-4-B verifier's
  apparmor-state read remains the runtime truth; no modification unless the
  diagnostic surface needs better failure messages.

*Evaluation Contract.*

Required tests (all must pass on the W7-4-C-a feature branch HEAD):
- `bash tests/unit/test_apparmor_profiles.sh` — PASS (existing 44/0 plus any
  new load-mechanism Test Group asserting the chosen fix is encoded in the
  hook)
- `bash tests/unit/test_systemd_units_hook.sh` — PASS (existing; must still
  pass)
- `bash tests/integration/test-iso-hooks-applied.sh` — PASS (existing; must
  still pass)
- CI run on W7-4-C-a branch: lint.yml + qemu-test.yml + e2e-test.yml all
  green per the W7-4-A-tris bar, with the documented exception that
  `qemu-test.yml`'s artifact will show `ORIONX_VERIFY_END: overall=fail`
  because mesh assertions remain FAIL until W7-4-C-b — this is acceptable
  as long as the `apparmor_enforcing=pass` sentinel is present in both
  BIOS and UEFI serial logs (the W7-4-C-a-specific gate)

Required real-path checks (asserted by reading the W7-4-C-a CI artifacts):
- `ORIONX_VERIFY: apparmor_enforcing=pass` present in
  `qemu-artifacts-<run-id>/serial-bios.log`
- `ORIONX_VERIFY: apparmor_enforcing=pass` present in
  `qemu-artifacts-<run-id>/serial-uefi.log`
- The diagnostic line(s) surrounding the apparmor sentinel show aa-status
  reporting at least 5 Orion-X profiles in enforced mode (synapse, tshark,
  bulk_extractor, volatility3, wireguard)
- No `ORIONX_VERIFY: apparmor_enforcing=fail` line in either log
- `grep -rn 'qemu-guest-agent\|openssh-server' iso/` returns zero matches
  (rejected channel confirmation, inherited from W7-4-B)
- If approach A (explicit `apparmor_parser -r`) was chosen, the build log
  shows the parser invocations during the 0610 hook execution

Required authority invariants:
- `apparmor_profile_load_authority` has exactly one owner: the combination of
  `iso/config/includes.chroot/etc/apparmor.d/` (profile content) and
  `iso/config/hooks/live/0610-apparmor-setup.hook.chroot` (load mechanism).
  Adding a new hook to load profiles would create dual authority.
- DEC-SEC-002 preserved: profiles remain in
  `iso/config/includes.chroot/etc/apparmor.d/`, not generated at hook time,
  not fetched at runtime.
- Profile binary paths inside each profile match real binary locations in the
  booted ISO. A profile attached to a non-existent binary is a packaging gap
  (fix the path or the package list), not a load success.
- W7-4-B verifier remains read-only against AppArmor state.

Required integration points (must still work after W7-4-C-a lands):
- W7-4-A: all 8 unit files still install; existing 0615 hook still PASS.
- W7-4-A-bis: AppArmor packages still present; aa-status available in guest.
- W7-4-B: ORIONX_VERIFY_BEGIN / ORIONX_VERIFY_END sentinel contract honored
  by the same parser; the apparmor sentinel transitions FAIL→PASS without
  changing the contract surface.
- 0620-service-hardening: ProtectSystem injection unchanged.
- Phase 6 acceptance: DEC-SEC-002 / DEC-SEC-004 preserved.

Forbidden shortcuts (any of these is a slice-fail at reviewer time):
- Relaxing the W7-4-B `apparmor_enforcing` assertion to require fewer than 5
  enforced profiles — masks the gap.
- Removing AppArmor profiles to make aa-status report 'all enforced' —
  superseding profiles requires plan approval (DEC-SEC-002).
- Loading profiles in `complain` mode and counting that as PASS — enforce
  mode is the deliverable; complain is debugging-only.
- Moving profile load logic out of `0610-apparmor-setup.hook.chroot` into a
  new hook (e.g. `0611-apparmor-load.hook.chroot`) — dual authority.
- Modifying `scripts/qemu-boot-test.sh` (frozen per DEC-PHASE7-022).
- Adding `qemu-guest-agent`, `openssh-server` hostfwd, or any new control
  plane to drive `aa-status` from the host.
- Touching mesh authorities (`scripts/mesh/**`, `systemd/orionx-mesh-*`) —
  AppArmor-only slice; mesh cascade is W7-4-C-b.
- Counting loaded-but-unattached profiles. A profile attached to a
  non-existent binary is a packaging gap, not a load success.

Ready-for-guardian definition: reviewer may declare readiness when all of the
following are true on the W7-4-C-a feature branch HEAD:
1. lint.yml + qemu-test.yml + e2e-test.yml all green (or qemu-test.yml's
   step-success aligned with the per-assertion gate documented in
   acceptance_notes — see Evaluation Contract notes).
2. `ORIONX_VERIFY: apparmor_enforcing=pass` present in BOTH bios and uefi
   serial logs in `qemu-artifacts-<run-id>/`.
3. At least 5 Orion-X profiles in enforced mode in the diagnostic context
   surrounding the apparmor sentinel.
4. `tests/unit/test_apparmor_profiles.sh` passes; any new load-mechanism
   Test Group is documented.
5. Scope Manifest forbidden-paths list shows zero touches in the diff vs
   `develop`.
6. The implementer's commit message names the root-cause class
   (A/B/C/D from the Investigation gate) so DEC-PHASE7-037 can cite it.

Rollback boundary: single feature branch
(`feature/phase7-w7-4-c-a-apparmor-load`), single squash merge into `develop`.
Reverting this slice leaves W7-4-A, W7-4-A-bis, and W7-4-B intact. Note: in
the W7-4-C-a CI artifacts the overall `ORIONX_VERIFY_END: overall=fail` is
EXPECTED because mesh assertions remain FAIL pending W7-4-C-b. The
W7-4-C-a acceptance bar is the apparmor sentinel specifically.

**W7-4-C-b Scope stub (seeded PENDING 2026-05-11):**

*Mission (refined after W7-4-C-a lands).* Produce a non-interactive
first-boot path that runs cleanly under headless QEMU boot, generates a valid
test `wg0.conf`, lets `wg-quick@wg0.service` come up, and unblocks the mesh
cascade — flipping `mesh_iface_up`, `mesh_beacon_active` from FAIL to PASS
and consequently driving `ORIONX_VERIFY_END: overall=pass` for both BIOS and
UEFI in a single CI run.

*Open design decisions (resolve in the W7-4-C-b planning pass, NOT now).*
- `FIRST_BOOT_NONINTERACTIVE=1` env-var that the unit reads via
  `EnvironmentFile=-/etc/default/orionx-first-boot` and that the script
  branches on; vs `--auto-defaults` CLI flag; vs pre-seeded
  `/etc/orionx/first-boot.conf` that the wizard accepts as full automation.
- Should the same wg keypair be used for every CI boot (deterministic, but
  forbids any future cross-CI-run peer testing) or a fresh keypair each
  boot via `/dev/urandom` (matches production semantics, but the test must
  not depend on key value)?
- Does the existing `--non-interactive` flag at line 87 of
  `scripts/security/first-boot-wizard.sh` already do everything except the
  `StandardInput=tty TTYPath=/dev/tty1` binding in the systemd unit? If yes,
  the slice is much smaller (unit-only edit + a one-line wg-key generation
  path); if no, the script needs a separate code path.
- Does the resulting test wg0 config have any production-security risk if
  it accidentally ships on a non-CI boot? (Should not — first-boot wizard
  runs once and the flag file at `/var/lib/orionx/.first-boot-done` prevents
  re-run.)

*Likely allowed paths (subject to refinement):*
- `systemd/orionx-first-boot.service` (likely — to relax the
  `StandardInput=tty TTYPath=/dev/tty1` binding for non-interactive mode)
- `scripts/security/first-boot-wizard.sh` (likely — to add CI-mode behavior
  for wg-key generation and config emission, beyond the existing
  `--non-interactive` flag's `read` skips)
- Possibly a new `iso/config/includes.chroot/etc/default/orionx-first-boot`
  file for env-var configuration

*Known forbidden:*
- Any modification to `scripts/mesh/**`, `scripts/setup-wireguard.sh` (mesh
  runtime authority — DEC-MESH-* family)
- Any modification to `iso/config/hooks/**` other than to install a new
  default-config file via the standard chroot copy pattern
- Any modification to the W7-4-B verifier
- Any modification to `scripts/qemu-boot-test.sh` (frozen)
- Any new package added to `iso/config/package-lists/orionx.list.chroot`
  unless it is a wg-tools dep that is unexpectedly missing

*Scope expansion note (DEC-PHASE7-038).* W7-4-C-b touches Phase 6 first-boot
wizard authority (DEC-SEC-003), which is a bounded supersedence in the same
shape as DEC-PHASE7-024's path-canonicalization: the wizard authority
remains a single owner (DEC-SEC-003 + this slice), but it gains a documented
non-interactive code path for CI/headless boot semantics. The Phase 6
"first-boot wizard runs once via systemd" property is preserved — only the
input channel changes when the env-var or seeded config is present.

**W7-5 Scope Manifest and Evaluation Contract (seeded 2026-05-13):**

*Mission.* Measure and assert the three Phase 7 performance targets stated
in the goal-contract `desired_end_state` for `g-initial-planning`:
**boot <90s, ISO <4GB, idle RAM <1GB**. The slice produces an in-guest
performance measurer that emits sentinel-tagged measurements on the serial
console (mirroring the W7-4-B in-guest verifier pattern from DEC-PHASE7-035)
plus a host-side ISO-size check. All three measurements travel through one
authority surface — `ORIONX_PERF: <metric>=<value>` sentinels parsed by a
host-side post-boot-script under the same `--post-boot-script` attach
contract (DEC-PHASE7-022) the runtime verifier already uses.

*Critical independence constraint.* W7-5 MUST be **independent of**
first-boot-wizard / wg0 / mesh runtime state — boot time, ISO size, and
idle RAM are measurable regardless of whether the W7-4-B mesh assertions
pass or fail. This is the lesson from the W7-4-B cascade trap: a slice that
depends on first-boot completion inherits #39's runtime gaps and re-opens
the cascade-fix loop. The perf-measure unit must NOT call `wg`,
`systemctl is-active orionx-mesh-*`, or otherwise probe mesh state.
multi-user.target reach is the synchronization point; that is reached
whether or not first-boot succeeds.

*Measurement methodology.*
- **boot_time_seconds**: read from inside the guest via `systemd-analyze
  time` (canonical "Startup finished in <kernel> + <userspace> = <total>s")
  OR `journalctl -b -o short-monotonic` last entry timestamp at
  multi-user.target reach. The chosen method is documented in
  `perf-measure.sh`'s header comment. Wall-clock from the host is rejected
  because QEMU firmware-load overhead is not part of the OS boot time the
  goal contract refers to.
- **iso_size_bytes**: read host-side via `du -b output/*.iso` on the build
  artifact, emitted as a serial-style sentinel in the host post-boot-script
  output for symmetry with the in-guest sentinels. The truth source for
  this metric is the host filesystem, not `/dev/ttyS0`.
- **idle_ram_bytes**: read from inside the guest after
  `orionx-runtime-verify.service` completes (so transient init-time RAM
  use has settled), via `/proc/meminfo`'s `MemAvailable` line multiplied
  by 1024 to convert kB to bytes. The unit's ordering uses
  `After=multi-user.target` plus a short poll for runtime-verify
  completion; documented in unit-file comments.

*Sentinel format.* `ORIONX_PERF_BEGIN`, then one
`ORIONX_PERF: <metric>=<integer>` line per measurement, then
`ORIONX_PERF_END: <overall>=<pass|fail>`. The host-side parser asserts
(a) BEGIN and END are present, (b) END's overall verdict is `pass`,
(c) all three expected metrics are present, (d) each numeric value is
below its threshold (90, 4294967296, 1073741824 respectively).
Missing BEGIN/END → FAIL.

*Scope Manifest.*

Allowed paths (the implementer may touch these and only these without
re-approval):
- `iso/config/includes.chroot/usr/lib/orionx/perf-measure.sh` (new — the
  in-guest measurer script)
- `iso/config/includes.chroot/usr/share/orionx/systemd/orionx-perf-measure.service`
  (new — staging path for the unit; the existing 0615 install hook will
  pick it up automatically because it iterates `*.service`)
- `tests/integration/test-w7-5-performance.sh` (new — host-side
  post-boot-script invoked by `qemu-boot-test.sh` via `--post-boot-script`;
  also emits the host-side ISO-size sentinel)
- `tests/unit/test_perf_measure_unit.sh` (new — content/syntax authority
  for the unit + measurer script; mirrors the W7-4-B
  `test_runtime_verify_unit.sh` discipline)
- `.github/workflows/qemu-test.yml` (modify — add a perf step that
  invokes `qemu-boot-test.sh ... --post-boot-script
  tests/integration/test-w7-5-performance.sh` OR layers it onto the
  existing W7-4-B step; do NOT introduce a new workflow file unless the
  qemu-test.yml step composition becomes unwieldy)
- `docs/qemu-boot-test.md` (modify — append a brief "W7-5 performance
  sentinel contract" subsection; pointer only, not a duplicate)

Required paths (must be touched in this slice — non-touch is a scope
violation):
- `iso/config/includes.chroot/usr/lib/orionx/perf-measure.sh`
- `iso/config/includes.chroot/usr/share/orionx/systemd/orionx-perf-measure.service`
- `tests/integration/test-w7-5-performance.sh`
- `.github/workflows/qemu-test.yml`

Forbidden paths (any touch requires explicit planner re-approval):
- `iso/config/hooks/live/0615-install-systemd-units.hook.chroot` (the
  existing install hook iterates `*.service` and will pick up the new
  unit automatically; modifying it would create a dual authority for
  "which units autostart")
- All other `iso/config/hooks/**` files (perf-measure is a STAGED unit,
  not a hook)
- `iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh` (W7-4-B
  verifier authority — read-only against perf state, not modified by
  W7-5)
- `iso/config/includes.chroot/usr/share/orionx/systemd/orionx-runtime-verify.service`
- `iso/config/includes.chroot/etc/apparmor.d/**` (Phase 6 AppArmor
  authority)
- `iso/config/package-lists/**` (Phase 6 + W7-4-A-bis authority; if
  `systemd-analyze` or any measurement tool is unavailable that is a
  real Phase 6 gap, not a W7-5 fix)
- `scripts/qemu-boot-test.sh` (frozen per DEC-PHASE7-022)
- `scripts/build-iso.sh`, `scripts/mesh/**`, `scripts/setup-matrix.sh`,
  `scripts/setup-wireguard.sh`, `scripts/security/first-boot-wizard.sh`
  (other authorities; W7-5 does not touch them)
- `systemd/*.service`, `systemd/*.timer` (existing service/timer files;
  W7-5 adds a NEW unit alongside, never modifies existing)
- `docker/**`, `Makefile`, `archive/**`, `ORION-X/**`
- `MASTER_PLAN.md` (planner-owned; W7-5 closure will be recorded by a
  separate planner pass)
- `.github/workflows/lint.yml`, `.github/workflows/e2e-test.yml`
- All other tests/unit/ and tests/integration/ files except the two
  named in Allowed paths

Expected state authorities touched:
- `perf_measure_authority` (NEW): single canonical owner for in-guest
  performance measurement results. Owner:
  `iso/config/includes.chroot/usr/lib/orionx/perf-measure.sh`. Output:
  serial-console sentinels parsed by the host-side post-boot-script.
  No parallel performance measurement script anywhere else in the repo.
- `qemu_harness_attach_authority`: extends via the existing
  `--post-boot-script` contract (DEC-PHASE7-022). NO modification to
  `qemu-boot-test.sh`.
- `ci_workflow_authority`: `.github/workflows/qemu-test.yml` adds a perf
  step; no new workflow file unless step composition becomes unwieldy.

*Evaluation Contract.*

Required tests (all must pass on the W7-5 feature branch HEAD):
- `bash tests/unit/test_perf_measure_unit.sh` — PASS (new unit test;
  asserts unit file syntax-clean, measurer script shellcheck-clean,
  sentinel format documented in header, no forbidden mesh/wg references
  in the measurer)
- `bash tests/integration/test-w7-5-performance.sh` — PASS (when invoked
  with a fresh ISO build artifact)
- `bash tests/unit/test_systemd_units_hook.sh` — PASS (existing; must
  still pass because the new unit is now in the staging pattern)
- `bash tests/integration/test-iso-hooks-applied.sh` — PASS (existing;
  must still pass because no new hooks were added)
- CI run on W7-5 branch: lint.yml + qemu-test.yml + e2e-test.yml all
  green; the new perf step shows `ORIONX_PERF_END: pass` for both BIOS
  and UEFI modes

Required real-path checks (asserted by `test-w7-5-performance.sh`):
- `ORIONX_PERF_BEGIN` line present in BIOS and UEFI `SERIAL_LOG`
- `ORIONX_PERF: boot_time_seconds=<integer>` present with value < 90 in
  both modes
- `ORIONX_PERF: idle_ram_bytes=<integer>` present with value <
  1073741824 (1 GiB) in both modes
- `ORIONX_PERF: iso_size_bytes=<integer>` (emitted host-side) with value
  < 4294967296 (4 GiB)
- `ORIONX_PERF_END: pass` present in both serial logs
- No `ORIONX_PERF: *=fail` lines in either serial log when thresholds
  are met
- `grep -rn 'qemu-guest-agent\|openssh-server' iso/` returns zero
  matches (rejected channel invariant inherited from DEC-PHASE7-035)
- `grep -nE 'wg show|wg-quick|wg0|orionx-mesh' iso/config/includes.chroot/usr/lib/orionx/perf-measure.sh`
  returns zero matches (independence invariant; the perf measurer must
  not probe mesh state)

Required authority invariants:
- The perf measurer is the SINGLE authority for in-guest performance
  measurement truth. Adding a parallel Docker-compose-based perf test
  or a script under `scripts/perf-*` is FORBIDDEN (re-introduces the
  Phase 4 SKIP #21/#22 anti-pattern in another shape).
- The measurer never modifies system state — reads `systemd-analyze`,
  `journalctl`, `/proc/meminfo` only. No service restarts, no
  kernel-tuning, no AppArmor changes.
- Sentinel format defined in EXACTLY ONE place — the measurer script's
  header comment block — and the host-side parser references it by
  literal pattern match. Two-place definition is a scope violation.
- Independence invariant (HARD): the measurer MUST NOT call `wg`,
  `ip link show wg0`, or `systemctl is-active` on any
  `orionx-mesh-*` unit, and MUST NOT read any first-boot or wg0 state.
  Boot-time + ISO-size + idle-RAM are deterministic regardless of mesh
  runtime state.

Required integration points (must still work after W7-5 lands):
- W7-4-A: all 8 existing unit files plus `orionx-runtime-verify.service`
  still install; existing 0615 hook still PASS in hook-applied
  validator; new `orionx-perf-measure.service` auto-picked-up as a
  tenth (the hook iterates `*.service`).
- W7-4-B: `ORIONX_VERIFY_*` sentinel emission and parsing unchanged;
  the W7-4-B step in `qemu-test.yml` remains `continue-on-error: true`
  and emits its diagnostic; W7-5's perf step is a separate step that
  parses `ORIONX_PERF_*` sentinels only.
- W7-3: BIOS+UEFI boots still complete within `--timeout 900`;
  serial-marker detection still triggers post-boot-script invocation.
- E2E test (`tests/integration/test-e2e-scenario.sh`): unchanged; the
  Docker E2E remains the multi-node orchestration authority; W7-5 is
  single-node in-guest performance measurement.

Forbidden shortcuts (any of these is a slice-fail at reviewer time):
- Depending on first-boot-wizard / wg0 / `orionx-mesh-*` runtime state
  in any perf assertion (re-opens the W7-4-B cascade trap).
- Asserting forensic toolkit performance, Matrix latency, or any
  non-Phase-7-target metric (scope creep; W7-5 has exactly three
  targets from the goal-contract `desired_end_state`).
- Measuring ISO size from inside the guest (the guest has no view of
  the build artifact).
- Boot-time measurement that ignores systemd's own startup accounting
  (must use `systemd-analyze` or `journalctl` boot timestamps — not a
  wall-clock sleep + grep).
- Idle-RAM measurement that races boot (must wait until
  `orionx-runtime-verify.service` or perf-measure unit
  `After=multi-user.target` completes so transient init-time RAM use
  is excluded).
- Re-introducing Docker-compose perf tests as a substitute (Phase 4
  SKIP #21/#22 anti-pattern in another shape).
- Adding `qemu-guest-agent`, `openssh-server` hostfwd, or QEMU monitor
  socket coupling (rejected channels per DEC-PHASE7-035).
- Modifying `scripts/qemu-boot-test.sh` (frozen per DEC-PHASE7-022).
- Adding new hooks to `iso/config/hooks/`.
- Duplicating sentinel format in more than one file.
- Silent SKIP on a missing tool — emit
  `ORIONX_PERF: <name>=skip` with a diagnostic line; END verdict is
  `fail` if any required check is skip.
- Relaxing the three thresholds (90s, 4GB, 1GB) without an explicit
  planner DEC entry — these are the goal-contract `desired_end_state`
  values; relaxing them supersedes the goal contract.
- Touching first-boot-wizard, mesh authorities, AppArmor profiles, or
  Matrix configuration to "make perf pass" — those are different state
  authorities and out of W7-5 scope.

Ready-for-guardian definition: reviewer may declare readiness when all of
the following are true on the W7-5 feature branch HEAD:
1. All three GitHub Actions workflows are green (lint.yml,
   qemu-test.yml, e2e-test.yml).
2. The qemu-test workflow's perf step shows `ORIONX_PERF_BEGIN`, three
   sentinels with numeric values within thresholds, and
   `ORIONX_PERF_END: pass` for BOTH bios and uefi modes in uploaded
   `qemu-artifacts-<run-id>/` serial logs.
3. The new unit test `test_perf_measure_unit.sh` passes locally and in
   lint.yml CI.
4. Host-side ISO-size emitted in CI step log:
   `iso_size_bytes < 4294967296` with PASS.
5. `grep -rn 'qemu-guest-agent|openssh-server' iso/` returns zero
   matches.
6. `grep -nE 'wg show|wg-quick|wg0|orionx-mesh' iso/config/includes.chroot/usr/lib/orionx/perf-measure.sh`
   returns zero matches (independence invariant).
7. Scope Manifest forbidden-paths list shows zero touches in the diff
   against `develop`.
8. Decision Log gains a `DEC-PHASE7-042` (closure) entry citing the CI
   run id, head SHA, and the three numeric values measured on both
   BIOS and UEFI.

Rollback boundary: single feature branch
(`feature/phase7-w7-5-performance-benchmark`), single squash merge
into `develop`. Reverting this slice removes the perf-measure unit and
the qemu-test.yml perf step; W7-4-A, W7-4-A-bis, W7-4-A-tris, W7-4-B
(mechanism + loop-exit) all remain intact and the rest of the Phase 7
acceptance bar is unaffected.

**Acceptance notes.** DEC-PHASE7-004 marked perf budgets as "soft gates
with documented exceptions" — meaning if a threshold is exceeded on a
specific CI environment (e.g. TCG-only no-KVM per DEC-PHASE7-021), the
failure must be loud, the value must be recorded, and either a
remediation issue or a DEC supersedence must follow. W7-5 implements the
loud-failure path; the documented-exception path is a follow-up planner
pass if a real CI environment cannot meet a threshold.

**W7-6 Scope Manifest and Evaluation Contract (seeded 2026-05-13):**

*Mission.* Verify the platform's four documented failure modes from the
goal-contract `desired_end_state` (node drop, Synapse restart, disk full,
network flap) are addressed at the systemd-configuration layer. Each of
the 8 Orion-X units in `systemd/` (4 services + 2 timers + 2 oneshot
services + the existing matrix/firewall/first-boot services — a total of
6 `*.service` files and 2 `*.timer` files) is inspected against a per-Type
recovery contract: long-running services (`Type=notify`, `Type=simple`,
`Type=forking`) must declare a meaningful `Restart=` directive
(`on-failure`, `always`, `on-abnormal`); `Type=oneshot` services are
recovery-irrelevant by design (they run once and exit; recovery is
timer-driven via sibling `*.timer` units); timers themselves provide the
cadence-driven recovery surface for node-drop and network-flap failure
modes via their `OnUnitActiveSec=` / `OnBootSec=` directives.

*Channel choice (W7-6 first pass: Option D, host-side config inspection).*
Four channel options were considered for failure-mode verification:
- **Option A**: in-guest active stimulation (kill processes, fill disk,
  toggle interfaces) via a new `orionx-failure-mode-test.service` emitting
  `ORIONX_FAILURE_*` sentinels. Real-state but complex; risks a third
  cascade-fix loop on top of #39 and #40 if active stimulation interacts
  with the headless-QEMU first-boot gap.
- **Option B**: QEMU monitor socket commands from a post-boot-script.
  **REJECTED** per DEC-PHASE7-035 (no new control plane).
- **Option C**: Docker compose for failure-mode testing. **REJECTED** per
  Phase 4 SKIP #21/#22 anti-pattern (the original Docker-mesh skips were
  precisely what runtime testing was meant to retire).
- **Option D** (chosen): host-side static inspection of `systemd/*.service`
  and `systemd/*.timer` content asserting each unit's recovery
  configuration. Less rigorous than Option A but feasible in CI without
  active stimulation, with no hang risk, and with zero dependency on the
  #39 / #40 first-boot cascade surface. **First-pass deliverable.**

Option A may follow as a `W7-6-bis` slice if Phase 7 closure (W7-8) requires
deeper assurance — the cascade-consolidation discipline (DEC-PHASE7-041 /
DEC-PHASE7-042) applies: land the simple, working check first and escalate
scope only if the simple check is insufficient.

*Per-Type recovery contract.* Documented in EXACTLY ONE place — the
header comment block of `tests/integration/test-w7-6-failure-resilience.sh`:
- `Type=notify` (Matrix Synapse): MUST declare `Restart=` with
  `on-failure`, `always`, or `on-abnormal`. The current
  `matrix-synapse-orionx.service` declares `Restart=on-failure` with
  `RestartSec=10` — passes. Covers the **Synapse restart** failure mode.
- `Type=simple` (mesh-discover daemon): MUST declare `Restart=` with
  `on-failure`, `always`, or `on-abnormal`. The current
  `orionx-mesh-discover.service` declares `Restart=on-failure` with
  `RestartSec=5` — passes.
- `Type=oneshot` (firewall, first-boot, mesh-beacon, mesh-health): MAY
  omit `Restart=` or declare `Restart=no`. Oneshot units are
  recovery-irrelevant by design; their recovery comes from timer-driven
  re-firing.
- `*.timer` units (mesh-discover.timer, mesh-health.timer): MUST be
  present and MUST declare `OnUnitActiveSec=` or `OnBootSec=`. The
  cadence-driven re-firing covers the **node drop** failure mode
  (mesh-discover re-runs and re-adds dropped peers) and the **network
  flap** failure mode (mesh-health re-runs and re-establishes broken
  links).
- **Disk full** failure mode is NOT covered by Restart= or timer config
  alone; it is documented as a known gap in W7-6's acceptance notes and
  routed to W7-6-bis or Phase 8 design (out of scope for the
  configuration-layer first pass).

*Scope Manifest.*

Allowed paths (the implementer may touch these and only these without
re-approval):
- `tests/integration/test-w7-6-failure-resilience.sh` (new — host-side
  config-inspection authority; iterates systemd/*.service and
  systemd/*.timer; reads per-Type contract from its own header block; emits
  per-unit PASS/FAIL diagnostics)
- `tests/unit/test_failure_resilience_unit.sh` (new — structural authority
  for the integration test; asserts test exists, shellcheck-clean, header
  contract documented, EXPECTED_UNITS array matches actual file set)
- `.github/workflows/qemu-test.yml` (modify — add a W7-6 step that invokes
  the integration test as an active gate; NO `continue-on-error: true`
  because static config inspection has no hang risk)

Required paths (must be touched in this slice — non-touch is a scope
violation):
- `tests/integration/test-w7-6-failure-resilience.sh`
- `tests/unit/test_failure_resilience_unit.sh`
- `.github/workflows/qemu-test.yml`

Forbidden paths (any touch requires explicit planner re-approval):
- `systemd/*.service`, `systemd/*.timer` (frozen Phase 4/6 + W7-4-A
  authority; if a unit's `Restart=` is wrong, the fix is a separate slice
  with its own DEC, not a paper-over inside W7-6)
- All `iso/config/hooks/**` and `iso/config/includes.chroot/**` files
  (W7-6 is host-side static inspection; no new ISO content)
- `iso/config/package-lists/**` (Phase 6 + W7-4-A-bis authority)
- `iso/auto/**`, `iso/hooks/**`, `iso/package-lists/**` (legacy paths —
  must remain zero references)
- `scripts/qemu-boot-test.sh` (frozen per DEC-PHASE7-022)
- `scripts/build-iso.sh`, `scripts/mesh/**`, `scripts/setup-matrix.sh`,
  `scripts/setup-wireguard.sh`, `scripts/security/first-boot-wizard.sh`
- `docker/**`, `Makefile`, `archive/**`, `ORION-X/**`
- `MASTER_PLAN.md` (planner-owned; W7-6 closure recorded by separate
  planner pass)
- `.github/workflows/lint.yml`, `.github/workflows/e2e-test.yml`
- All other `tests/unit/` and `tests/integration/` files except the two
  named in Allowed paths

Expected state authorities touched:
- `failure_resilience_assertion_authority` (NEW): single canonical owner is
  `tests/integration/test-w7-6-failure-resilience.sh`. No parallel
  failure-resilience config assertion anywhere else in the repo.
- `ci_workflow_authority`: `.github/workflows/qemu-test.yml` adds a single
  W7-6 step; no new workflow file.

*Evaluation Contract.*

Required tests (all must pass on the W7-6 feature branch HEAD; reviewer
verifies):
- `bash tests/unit/test_failure_resilience_unit.sh` — PASS (new unit test)
- `bash tests/integration/test-w7-6-failure-resilience.sh` — PASS (reads
  all 8 unit files at `systemd/` and asserts the per-Type contract)
- `bash tests/unit/test_systemd_units_hook.sh` — PASS (existing; must
  still pass because no `systemd/*.service` files are modified)
- `bash tests/integration/test-iso-hooks-applied.sh` — PASS (existing;
  must still pass because no new hooks are added)
- CI run on the W7-6 branch: lint.yml + qemu-test.yml + e2e-test.yml all
  green; the new W7-6 step in qemu-test.yml passes as an active gate

Required real-path checks (asserted by `test-w7-6-failure-resilience.sh`):
- `matrix-synapse-orionx.service` declares `Restart=on-failure|always|on-abnormal`
  (current value: `Restart=on-failure` — PASS)
- `orionx-mesh-discover.service` declares `Restart=on-failure|always|on-abnormal`
  (current value: `Restart=on-failure` — PASS)
- `orionx-firewall.service` is `Type=oneshot` — no `Restart=` required
  (PASS by definition)
- `orionx-first-boot.service` is `Type=oneshot` — no `Restart=` required
  (PASS by definition)
- `orionx-mesh-beacon.service` is `Type=oneshot` — no `Restart=` required
  (PASS by definition)
- `orionx-mesh-health.service` is `Type=oneshot` — no `Restart=` required
  (PASS by definition)
- `orionx-mesh-discover.timer` declares `OnUnitActiveSec=` or `OnBootSec=`
  (covers node drop and network flap failure modes)
- `orionx-mesh-health.timer` declares `OnUnitActiveSec=` or `OnBootSec=`
  (mesh-health cadence)
- Per-unit diagnostic emitted on failure: e.g.
  `[W7-6 FAIL] matrix-synapse-orionx.service: Type=notify but Restart= missing or 'no'`
- EXPECTED_UNITS array matches `ls systemd/*.service systemd/*.timer`
  enumeration in the unit test (single-authority for the set of 8 units)

Required authority invariants:
- `failure_resilience_assertion_authority` has exactly one owner
  (`tests/integration/test-w7-6-failure-resilience.sh`). Adding a parallel
  Docker-compose-based failure test is FORBIDDEN (re-introduces the Phase
  4 SKIP #21/#22 anti-pattern in another shape).
- Per-Type contract defined in EXACTLY ONE place — the integration test's
  header comment block — and referenced from the unit test structural
  assertion. Two-place definition is a scope violation.
- Read-only against unit files: the integration test MUST NOT modify any
  `systemd/*.service` or `systemd/*.timer` file.
- No active in-guest stimulation in this slice (no kill -9 of services, no
  disk-full simulation, no interface toggling). Active stimulation is
  explicitly deferred to a possible W7-6-bis follow-up — DEC-PHASE7-041 /
  DEC-PHASE7-042 cascade-consolidation discipline.

Required integration points (must still work after W7-6 lands):
- W7-4-A: all 8 unit files still present at `systemd/`; the W7-6 test
  reads them but does not modify them.
- W7-4-B: `ORIONX_VERIFY_*` sentinel emission unchanged; the W7-6 step in
  qemu-test.yml is a separate step that does not parse `ORIONX_VERIFY_*`.
- W7-5 / W7-5-exit: `ORIONX_PERF_*` sentinel emission unchanged; W7-5
  step's `continue-on-error: true` is preserved (W7-6 step does not affect
  it).
- W7-3 QEMU harness: `scripts/qemu-boot-test.sh` signature unchanged.
- E2E test: unchanged.

Forbidden shortcuts (any of these is a slice-fail at reviewer time):
- Modifying any file in `systemd/` to make assertions pass.
- Introducing Docker compose for failure-mode testing (re-opens Phase 4
  SKIP #21/#22 anti-pattern).
- Using QEMU monitor channels, qemu-guest-agent, openssh-server hostfwd,
  or any new control plane (rejected per DEC-PHASE7-035).
- Adding active in-guest failure stimulation in this slice (defer to
  W7-6-bis).
- Asserting `Restart=` on `Type=oneshot` units (semantic mismatch).
- Adding `continue-on-error: true` to the W7-6 step — static config
  inspection cannot hang, so the diagnostic is the deliverable.
- Touching any `iso/`, `scripts/`, `docker/`, or `MASTER_PLAN.md` file.
- Silent SKIP on a missing unit file — emit a diagnostic line and exit
  non-zero.

Ready-for-guardian definition: reviewer may declare readiness when all of
the following are true on the W7-6 feature branch HEAD:
1. All three GitHub Actions workflows are green (lint.yml, qemu-test.yml,
   e2e-test.yml).
2. The qemu-test.yml W7-6 step (active gate) passes for all 8 units.
3. The new unit test `test_failure_resilience_unit.sh` passes locally and
   in lint.yml CI.
4. `tests/integration/test-w7-6-failure-resilience.sh` passes locally
   against the source-of-truth `systemd/*.service` and `systemd/*.timer`
   files.
5. Scope Manifest forbidden-paths list shows zero touches in the diff
   against `develop` — most critically, no touches to `systemd/`, `iso/`,
   `scripts/`, or `docker/`.
6. EXPECTED_UNITS array in the integration test matches the actual file
   set (the unit test asserts this).
7. Planner closure entry (DEC-PHASE7-043) can be authored citing the CI
   run id, head SHA, and per-unit verdict summary.

Rollback boundary: single feature branch
(`feature/phase7-w7-6-failure-resilience`), single squash merge into
`develop`. Reverting this slice removes the W7-6 integration test, its
unit test, and the W7-6 step in qemu-test.yml; W7-4-A/B (mechanism +
loop-exit), W7-5 / W7-5-exit, and all `systemd/` unit files remain
intact.

**Acceptance notes.** Failure modes per goal-contract `desired_end_state`:
node drop, Synapse restart, disk full, network flap. W7-6 (Option D, this
slice) addresses three of four at the configuration layer — node drop and
network flap via timer cadence, Synapse restart via `Restart=on-failure`.
Disk full is a known gap not covered by `Restart=` or timer config alone;
it is routed to W7-6-bis or Phase 8 design (out of W7-6 first-pass scope).
This is the DEC-PHASE7-041 / DEC-PHASE7-042 cascade-consolidation
discipline applied: land the working subset cleanly, document the
remaining gap, escalate only if W7-8 closure requires deeper assurance.

**Loop exit (2026-05-13).** After W7-4-B landed PARTIAL-ACCEPT at `c8bce0a`,
the cascade-fix arc (W7-4-C-a then W7-4-C-b) was seeded to chase the three
runtime-FAIL assertions (`mesh_iface_up`, `mesh_beacon_active`,
`apparmor_enforcing`). The pattern that emerged across the next dispatch
cycles: **each cascade-fix slice surfaced more cascade**. AppArmor profile
load investigation revealed binary-path mismatches that intersected the
first-boot non-interactive question; the first-boot non-interactive
investigation revealed open design decisions (env-var vs CLI flag vs
seeded-config; deterministic vs fresh keypair) that benefit from a clean
Phase 8 design pass rather than a reactive Phase 7 patch. The cascade-fix
loop was consuming Bullseye-EOL clock without converging.

The decision (consolidate under issue #39): rather than continue chasing
runtime gaps slice-by-slice, the planner consolidates the open runtime
content under a single tracker (issue #39, "Phase 7 closure: consolidated
runtime gaps") and exits the cascade loop via a sibling slice — **W7-4-B-exit**
adds `continue-on-error: true` to the W7-4-B step in `.github/workflows/qemu-test.yml`
(merge `c6c42c1`). The step still runs, still emits sentinels, still uploads
artifacts, but does not fail the workflow. Anti-drift control:
removing `continue-on-error: true` requires a planner DEC that explicitly
closes #39 first.

The mechanism-vs-runtime split (DEC-PHASE7-039). W7-4-B's value is the
**mechanism**: the in-guest sentinel-emitting oneshot unit, the host-side
parser, the `/dev/ttyS0` serial-marker reuse (DEC-PHASE7-035). That mechanism
is the single runtime-verification authority the project has been missing
since Phase 6 closed structurally — accepting it is not premature closure,
it is the correct boundary. The **runtime content** that the mechanism
surfaces (which assertions PASS in which boot environment) is a separate
authority that lives in #39 and will be settled in a Phase 8 design pass.
The W7-4-B step continues to emit those assertions as a visible diagnostic
on every CI run; the failure signal is preserved, the workflow gate is not.

The architectural insight (DEC-PHASE7-040). Non-interactive first-boot under
headless QEMU is a DEC-SEC-003 bounded-supersedence question, not a
Phase 7 implementation gap. Phase 6 designed the first-boot wizard for
interactive operator boot; QEMU-CI is a different operational context that
needs its own input channel (env-var, seeded config, or CLI flag) — choosing
between those is a design decision, not a fix. Likewise, AppArmor profile
enforcement under headless QEMU intersects with the same design surface (which
binaries are present at boot, which profiles attach, which load mechanism the
hook uses). These two questions belong in a Phase 8 design pass that can
consider them together, not in serial Phase 7 cleanup slices.

The meta-lesson (DEC-PHASE7-041). When each fix slice surfaces a new cascade
of fixes, the right move is to consolidate the open work under a single
tracker, preserve the diagnostic surface, and proceed in parallel with the
remaining Phase work rather than continuing serial cascade-fix slices.
Cascade-fix loops are a signal that the problem class is bigger than the
slice scope; the fix is at the design level, not the patch level.

**W7-5 partial-accept (2026-05-13).** W7-5 (performance benchmark) landed at
merge `8bcded0`, and its first real CI run produced parseable
`ORIONX_PERF: iso_size_bytes=984612864` host-side — **939 MiB, well under
the 4 GiB threshold (PASS)**. One of three Phase 7 performance targets from
the goal-contract `desired_end_state` is now verified end-to-end with a
recorded numeric value. The other two targets — `boot_time_seconds` and
`idle_ram_bytes` — are in-guest measurements that depend on
`ORIONX_PERF_END` reaching `/dev/ttyS0` within the 90s post-boot window,
and that window was exceeded on the first CI run. The same #39 first-boot
cascade surface that gates W7-4-B's mesh assertions also gates W7-5's
in-guest measurements: `multi-user.target` reach is unreliable on headless
QEMU until the non-interactive first-boot question is resolved in Phase 8
design.

The exit slice (W7-5-exit, merge `ba3e0d1`) applied DEC-PHASE7-041 cascade
consolidation for the second time: `continue-on-error: true` on the W7-5
step so the diagnostic stays visible without blocking, and a rewrite of a
stale comment block flagged by the reviewer in round 1. Anti-drift control:
removing `continue-on-error: true` from the W7-5 step requires a planner DEC
that explicitly closes issue #40 (in-guest boot/RAM measurement reliability
tracker, filed 2026-05-13 as a Phase 8 design pass input).

**Cascade-consolidation as durable operational discipline (DEC-PHASE7-042).**
W7-4-B and W7-5 both surfaced the same architectural boundary: a slice that
depends on headless-QEMU first-boot completion inherits #39's runtime gaps.
The right response is not to chase the cascade slice-by-slice (which the
abandoned W7-4-C-a / W7-4-C-b arc proved); it is to apply DEC-PHASE7-041
consolidation: accept the mechanism, preserve the diagnostic surface, move
the resolution to a clean Phase 8 design pass. Two applications of this
pattern in three slices (W7-4-B-exit, W7-5-exit) confirm it is durable
operational discipline, not a one-off escape hatch.

**Optional Guardian-stewardship note (informational, not DEC-scoped).**
Two operational observations from Guardian's W7-5 / W7-5-exit landings:
(a) a stale `.git/index.lock` blocked the first W7-5-exit merge attempt and
consumed one approval token before failing — possible candidate for a
pre-merge invariant or cron cleanup, not blocking now; (b) workflow
`base_branch` was `main` while merges target `develop`, and Guardian
re-bound mid-slice across several recent landings — a one-line
`cc-policy workflow bind` standardization to `base_branch=develop` for
phase7 work would eliminate this papercut. Both are flagged for the
operator's attention; neither merits a Decision Log entry on its own. If
acted on, they belong in a separate runtime/control-plane reckoning, not a
Phase 7 source slice.

**Phase 7 closure (2026-05-14, DEC-PHASE7-043).** Phase 7 (Integration
Testing) closes on `develop` at `05b98a3` with all three CI workflows green
simultaneously (Lint & Test, QEMU Boot Test, E2E Scenario Test). Seven
implementation slices were accepted in arc order: W7-1 (build infrastructure,
pre-session), W7-3 (serial console + QEMU harness, pre-session), W7-4-A
(systemd unit install hook, merge `0424b7e`, closes #9 and #13), W7-4-A-bis
(legacy `iso/package-lists/` path cleanup across three hardening tests, merge
`da66fee`, closes #37), W7-4-A-tris (legacy `iso/config/hooks/binary/` path
cleanup in serial console test, merge `68b9097`, closes #38), W7-4-B
(in-guest runtime verification mechanism, merge `c8bce0a` — mechanism FULL
ACCEPTED, runtime content gaps consolidated under #39 per DEC-PHASE7-039 +
DEC-PHASE7-041), W7-5 (performance benchmark, merge `8bcded0` —
`iso_size_bytes=984612864` (~939 MiB) PASS host-side; in-guest
`boot_time_seconds`/`idle_ram_bytes` reliability tracked under #40 per
DEC-PHASE7-042), and W7-6 (failure-mode recovery via Option D config-layer
assertion of systemd `Restart=` directives across 8 Orion units, merge
`05b98a3`).

Two cascade-consolidation exit slices were applied between these arc-defining
landings: W7-4-B-exit (merge `c6c42c1`, `continue-on-error: true` on the
W7-4-B step — DEC-PHASE7-039 first application of DEC-PHASE7-041) and
W7-5-exit (merge `ba3e0d1`, `continue-on-error: true` on the W7-5 step plus
a stale-comment rewrite — DEC-PHASE7-042 second application). Two applications
of DEC-PHASE7-041 in three slices is the evidence that **cascade-consolidation
is durable operational discipline**, not a one-off escape hatch. The next
phase or feature that encounters a slice-by-slice cascade-fix loop should
prefer this pattern: consolidate the open runtime content under a single
tracker, preserve the diagnostic surface (artifacts uploaded, sentinels
emitted, step runs), and route the design question to the next planned
design pass. Removing `continue-on-error: true` from W7-4-B or W7-5 steps
requires a planner DEC that explicitly closes #39 or #40 respectively —
that boundary prevents the relaxed gate from becoming silent skip.

The W7-4-C-a (AppArmor profile load fix) and W7-4-C-b (first-boot
non-interactive for CI) slices were ABANDONED inside Phase 7 (DEC-PHASE7-040)
because the cascade arc surfaced architectural questions that belong in a
clean Phase 8 design pass rather than a reactive Phase 7 patch — specifically
non-interactive first-boot under headless QEMU (DEC-SEC-003 bounded
supersedence) and AppArmor profile load mechanism under headless boot. Their
seeded Scope Manifests and Evaluation Contracts (DEC-PHASE7-037,
DEC-PHASE7-038) remain valid reference material for a future #39 closure
slice.

Partial-acceptance rationale (DEC-PHASE7-039, DEC-PHASE7-042). W7-4-B and
W7-5 were both accepted with diagnostic surfaces preserved rather than
reopened to chase deeper architectural questions. The mechanisms (sentinel
contract, perf-measure unit, host-side parsers) are the canonical authorities
the project required and are operative end-to-end; the runtime-content gaps
they surface are tracked as Phase 8 design pass inputs. This matches the
single-authority discipline that runs throughout Phase 7: the mechanism is
the acceptance bar; the runtime content is a separate authority.

W7-7 (physical USB boot validation) is DEFERRED to operator attestation as a
release-gate step in Phase 8 rather than a Phase 7-blocking slice. The
`approve` gate per DEC-PHASE7-005 always reserved W7-7 as
human-in-the-loop hardware validation running in parallel with the software
track; the QEMU BIOS + UEFI boot path is already proven for the same hybrid
ISO, so physical USB sign-off is a release prerequisite rather than a
Phase 7 closure prerequisite.

Open trackers carried into Phase 8 design pass: #36 (`iso/config/includes.binary/`
contents not appearing under `binary/` at hook time — Phase 7 polish, not
blocking), #39 (Phase 7 closure tracker: W7-4-B runtime gaps — mesh cascade
+ AppArmor enforcement under headless QEMU), #40 (W7-5 in-guest `boot_time`
and `idle_ram` measurement reliability), #41 (runtime-control-plane hygiene
filed at Phase 7 closure: `decode_work_item_contract` rejects `workflow_id`
in `evaluation_json` — flagged repeatedly by the SubagentStart hook across
Phase 7 dispatches; non-blocking but should be addressed before Phase 8
release work generates more dispatches of similar shape), plus older Phase 7
follow-ups #32 (legacy `iso/hooks/` path — resolved by W7-3-enabler arc,
kept open for post-closure verification), #33 (Phase 5 hook missing
pip3/curl/gpg/unzip in chroot), and #23 (W7-CI-FIX series runtime-hygiene
reminder). None of these block Phase 8 release prep; #39 and #40 are
explicitly routed to a Phase 8 design pass that considers the
headless-QEMU non-interactive boot semantics question together rather than
in serial cleanup slices.

Phase 8 is now ACTIVE. The release-gate work (version bump, documentation
audit, release artifacts, GitHub Release with ISO attached, W7-7 operator
attestation) begins in a fresh planning slice; the closure scope of W7-8 is
deliberately limited to recording Phase 7 acceptance and activating Phase 8,
not to producing detailed Phase 8 implementation content.

---

### Phase 8: Release v2.0.0
**Env:** macOS + Linux | **Status:** Active — software track FULLY CLOSED 2026-05-16 (develop @ `40416d6`, all five software slices ACCEPTED, issue #43 CLOSED); only operator-action remains. Original activation 2026-05-14 (Phase 7 closed at `05b98a3` / `ad35fb9`); REOPENED 2026-05-15 by W7-7 critical finding #43 (DEC-PHASE8-003 SUPERSEDED by DEC-PHASE8-004); content-staging fix landed at `e725895` (DEC-PHASE8-006); rsync-exit-23 cascade fix landed at `40416d6` (DEC-PHASE8-007); W7-7 re-attestation against the corrected ISO is now the next operator action (parallel to GPG key provisioning) before W8-7 final tag + publish.

Phase 8 takes the post-Phase-7 `develop` tree to a tagged, GPG-signed,
publicly-downloadable `v2.0.0` release. The phase has two parallel tracks:
the software release track (version finalization, CHANGELOG, release notes,
documentation audit, signed artifacts, GitHub Release, git tag) and the
operator attestation track (W7-7 physical USB boot validation; runtime-content
design pass for issues #39 / #40 if the operator validation requires those
gaps closed before tagging). The release track is CI-runnable and is the
focus of the planner's bounded slices; the operator track runs in parallel.

**Acceptance:** `sha256sum -c` passes on the published ISO. User Guide
walkthrough succeeds on fresh ISO. Git tag `v2.0.0` exists on `main`. GitHub
Release with ISO attached and SHA-256/SHA-512 checksums (GPG signed)
published. Operator has attested physical-USB boot on at least one piece of
real hardware (W7-7).

**Already-accepted Phase 8 prep work (operator-driven landings during Phase 7
closure window):**

- **W7-7 enabler — ISO artifact upload (operator-driven, accepted at `b411c47`).**
  Wired `.github/workflows/qemu-test.yml` to upload the built ISO as a GitHub
  Actions artifact (`orionx-iso-<run_id>`) so the operator can
  `gh run download <run_id> -n orionx-iso-<run_id>` and dd-write to USB for
  the W7-7 physical-boot attestation without a separate local build. This is
  enablement plumbing for the operator track, not the W7-7 attestation
  itself. The attestation remains an `approve`-gate human-in-the-loop step.
- **W8 Dockerfile cleanup — apt-unavailable package removal (operator-driven,
  accepted at `44c7b25`).** Removed three packages from `Dockerfile` that
  were no longer available in the Bookworm Debian apt index (same gap class
  as #33 in Phase 7 ISO chroot — release-readiness hygiene). First Phase 8
  release-readiness fix; same drift class the canonical-paths cascade
  exposed throughout Phase 7. The pattern (apt index drift between
  development and release tagging) is one Phase 8 should watch for in
  parallel surfaces (ISO chroot list, Dockerfile, docker-compose images).

**Work Item Breakdown (planned 2026-05-14, slices seeded one at a time):**

Phase 8 is decomposed conservatively: only the next slice is seeded with a
full Scope Manifest and Evaluation Contract; downstream slices are sketched
as the dependency graph but not detail-planned until each predecessor lands.
This applies DEC-PHASE7-041 cascade-consolidation discipline preemptively —
each Phase 8 slice may surface a downstream design question (release-tagging
authority, GPG signing key authority, GitHub Release authorship) that
benefits from being considered with full evidence from prior slices rather
than speculatively up-front.

| W-ID | Title | Env | Wave | Deps | Weight | Gate | Status |
|------|-------|-----|------|------|--------|------|--------|
| W8-1 | Version-string finalization to `v2.0.0-rc1` (single-authority) | Repo | 1 | - | S | review | ACCEPTED 2026-05-14 merge `ee5861b` (`feature/phase8-w8-1-version-rc1`) — Dockerfile + README.md propagated `v2.0.0-dev` → `v2.0.0-rc1`; `scripts/build-iso.sh` and `iso/auto/config` unchanged (canonical authority preserved per DEC-PHASE7-002); 41/41 unit tests pass; reviewer 0 findings. See DEC-PHASE8-001. |
| W8-2 | CHANGELOG.md generation from git log + Decision Log | Repo | 2 | W8-1 | M | review | CONSOLIDATED 2026-05-14 into `wi-w8-finish-A` (docs bundle) per DEC-PHASE8-002 cascade-consolidation |
| W8-3 | Documentation audit (User Guide / README walkthrough matches reality) | Repo | 2 | W8-1 | M | review | CONSOLIDATED 2026-05-14 into `wi-w8-finish-A` (docs bundle) per DEC-PHASE8-002 cascade-consolidation. NOTE 2026-05-15 (DEC-PHASE8-004): the audit landed at `586fa05` verified version strings and walkthrough script paths against repo HEAD but did NOT verify that User_Guide.md content presence matched the booted-ISO reality (the audit asked "do these scripts exist in scripts/?" not "are these scripts in the booted ISO?"). W7-7 hardware attestation surfaced the gap in #43. Future docs-audit slices MUST expand scope to assert ISO-content presence not just repo-content presence. See DEC-PHASE8-004. |
| W8-4 | Release artifact pipeline (ISO + SHA-256/SHA-512 + detached GPG signatures) | Linux/CI | 3 | W8-1, wi-w8-finish-A | L | review | CONSOLIDATED 2026-05-14 into `wi-w8-finish-B` (release pipeline bundle) per DEC-PHASE8-002 cascade-consolidation; GPG signing step uses `secrets.GPG_PRIVATE_KEY` with `continue-on-error: true` until operator provisions the key (hard human boundary, parallel) |
| W8-5 | GitHub Release scaffolding (draft release with ISO + checksums + signatures + release notes) | Repo/CI | 3 | wi-w8-finish-A | M | review | CONSOLIDATED 2026-05-14 into `wi-w8-finish-B` (release pipeline bundle) per DEC-PHASE8-002 cascade-consolidation; DRAFT mode enforces W8-7 publish gate per DEC-PHASE7-005 |
| W8-6 | Workflow rename `phase7-integration` → `phase8-release` (runtime hygiene) | Repo | * | - | XS | review | PARTIAL 2026-05-14 — consolidated into `wi-w8-finish-B` per DEC-PHASE8-002, but the runtime-state rename itself is BLOCKED by issue #42 (`cc-policy workflow bind` FK constraint failure when rebinding an existing worktree). Impact is decorative only: runtime still reports `workflow_id: phase7-integration` while Phase 8 software-track is otherwise complete. No software functionality is affected; release.yml, GitHub Actions, and all source-tree authorities are independent of the runtime workflow identity string. Resolution path: #42 lands → operator runs the rename via `cc-policy workflow unbind` + `bind`, OR planner re-binds manually once the FK bug is fixed. See DEC-PHASE8-003. |
| wi-w8-finish-A | Docs bundle (W8-2 CHANGELOG + W8-3 documentation audit, consolidated) | Repo | 2 | W8-1 | M-L | review | ACCEPTED 2026-05-14 merge `586fa05` (`feature/phase8-finish-a-docs`) — `CHANGELOG.md` created at repo root with curated `## [v2.0.0-rc1]` section covering Phases 1–7 + W8-1 (W-ID and DEC cross-references); `docs/User_Guide.md` audited end-to-end, version literals propagated `v1.5.5` → `v2.0.0-rc1`; reviewer ready_for_guardian; CI green. See DEC-PHASE8-003. |
| wi-w8-finish-B | Release pipeline bundle (W8-4 checksums + GPG signing CI plumbing + W8-5 GitHub Release draft scaffold + W8-6 workflow rename, consolidated) | Repo/CI | 3 | wi-w8-finish-A | L | review | ACCEPTED 2026-05-14 merge `0b8f1b0` (`feature/phase8-finish-b-release-pipeline`) — `.github/workflows/release.yml` triggers on `v*` tag + workflow_dispatch, builds ISO via `scripts/build-iso.sh`, emits SHA-256/SHA-512, signs with `secrets.GPG_PRIVATE_KEY` (continue-on-error: true until operator key provisioning), creates DRAFT GitHub Release with notes sourced from `CHANGELOG.md`; `scripts/release/extract-release-notes.sh` helper; `docs/release-process.md` operator runbook documenting the W8-7 publish sequence. W8-6 runtime rename PARTIAL (blocked by #42 — decorative drift only; see W8-6 row + DEC-PHASE8-003). See DEC-PHASE8-003. |
| W7-7 | Physical USB boot validation (operator track, parallel — HARD HUMAN BOUNDARY) | Hardware | * | W7-3, W8-1, wi-w8-content-staging, wi-w8-staging-defensive | S | approve | **RE-ATTESTATION PENDING 2026-05-16** — was FAILED 2026-05-15 (operator hardware attestation found the ISO MISSING the entire Orion-X application layer per #43). The #43 fix (wi-w8-content-staging) landed at `e725895` 2026-05-15 and the rsync exit-23 cascade fix (wi-w8-staging-defensive) landed at `40416d6` 2026-05-16; issue #43 CLOSED 2026-05-16. The corrected ISO from develop @ `40416d6` is now expected to contain `/opt/orionx/scripts/` (all eight entrypoints), `/opt/orionx/theme/`, `/opt/orionx/data/`, `/usr/share/doc/orionx/`, and the `/usr/bin/` PATH symlinks; `tests/integration/test-iso-content-presence.sh` enforces this as an ACTIVE CI gate per DEC-PHASE8-006. Operator must re-`dd`-write the new ISO (via `qemu-test.yml` artifact or future DRAFT release.yml artifact) to physical USB, boot on real hardware (UEFI laptop + BIOS desktop or equivalent), and validate the `docs/User_Guide.md` walkthrough end-to-end (mesh-up, Matrix-up, forensic toolkit, PATH-accessibility of all eight entrypoints). Same `approve` gate per DEC-PHASE7-005 / DEC-PHASE8-004 — no new boundary. Closure DEC will be authored at re-attestation pass time. See DEC-PHASE8-004, DEC-PHASE8-005, DEC-PHASE8-006. |
| W8-7 | `v2.0.0` release tag + final GitHub Release publish (HARD HUMAN BOUNDARY) | Repo/CI | 5 | wi-w8-content-staging (ACCEPTED), wi-w8-staging-defensive (ACCEPTED), wi-w8-finish-B (ACCEPTED), W7-7 operator re-attestation (PENDING), operator GPG key provisioning (PENDING) | XS | approve | **BLOCKED 2026-05-16** — software-track #43 fix has fully landed (`e725895` + `40416d6`, issue #43 CLOSED). Remaining blockers reduce to operator action only: (1) operator re-runs W7-7 against the corrected ISO from develop @ `40416d6` and signs off; (2) operator provisions `secrets.GPG_PRIVATE_KEY` + `secrets.GPG_PASSPHRASE`; (3) operator retags/version-bumps to `v2.0.0` per `docs/release-process.md` (cut `v2.0.0-rc1` first, validate the DRAFT release, then promote to `v2.0.0`); (4) `gh release edit v2.0.0 --draft=false`. Explicit `approve` gate per DEC-PHASE7-005. Planner records closure DEC-PHASE8-NNN at publish. See DEC-PHASE8-004, DEC-PHASE8-005, DEC-PHASE8-006. |
| wi-w8-content-staging | Stage Orion-X application content into ISO + content-presence test gate (#43 fix) | Repo/CI | 4 | wi-w8-finish-A, wi-w8-finish-B | L | review | **ACCEPTED 2026-05-15** merge `e725895` (commit `9eaf7f1` `feat(phase8): stage Orion-X application layer into ISO (closes #43)`) — `scripts/build-iso.sh` gained `stage_application_content()` (rsyncs `scripts/`, `theme/`, `data/`, `docs/` into `iso/config/includes.chroot/{opt/orionx,usr/share/doc/orionx}/` at build time, NOT committed); `iso/config/hooks/live/0700-orionx-setup.hook.chroot` created `/usr/bin/` symlinks for the eight named entrypoints (orionx-mesh, setup-matrix.sh, setup-wireguard.sh, artifact-analyzer.py, storyboard-gen.py, toggle-theme.sh, run-lynis.sh, download-samples.sh) and set executable bits; `.gitignore` excludes staged paths; `tests/integration/test-iso-content-presence.sh` (295 lines) + `tests/unit/test_iso_content_staging_unit.sh` (295 lines) + `tests/unit/test_orionx_setup_hook_unit.sh` (371 lines) authored; content-presence test wired into `.github/workflows/qemu-test.yml` as an ACTIVE gate (no `continue-on-error`). Issue #43 CLOSED 2026-05-16. CI verification on `e725895` was incomplete: Lint & Test green, E2E Scenario green, QEMU Boot Test FAILED (1m25s — rsync exit 23 on empty `theme/wallpapers/`) → required wi-w8-staging-defensive amendment. See DEC-PHASE8-005 (seeding) and DEC-PHASE8-006 (closure). |
| wi-w8-staging-defensive | Defensive amendment: tolerate missing-source dirs in `stage_application_content()` + `.gitkeep` for empty `theme/wallpapers/` (CI fix for #43 cascade) | Repo | 4 | wi-w8-content-staging | XS | review | **ACCEPTED 2026-05-16** merge `40416d6` (commit `ab56a67` `fix(phase8): make stage_application_content tolerant of missing source dirs`) — three-file defensive fix that unblocked the `e725895` QEMU Boot Test failure (rsync exit 23 on empty `theme/wallpapers/`): (a) `scripts/build-iso.sh` gained existence guards on all four rsync calls + early bulk diagnostic for missing source dirs; (b) `theme/wallpapers/.gitkeep` (with a comment pointing to #43 follow-up) makes the directory tracked by git so `rsync` finds a real source path; (c) `tests/unit/test_iso_content_staging_unit.sh` gained +9 assertions covering the defensive guards (now 32/32 passing). This is a DEC-PHASE7-041 cascade-consolidation pattern applied to a hard-CI-blocker amendment: the slice scope is minimal (rsync-tolerance + tracked-empty-dir pattern), preserves DEC-PHASE8-005's `iso_content_staging_authority` (build-iso.sh remains the single staging authority — the change is internal robustness, not a new pipeline), and resolves the CI red without modifying the content-staging contract or the content-presence integration test. The `.gitkeep` pattern is established here as the canonical idiom for tracked-empty-source-dirs that participate in ISO staging (DEC-PHASE8-007). Anti-drift: future implementers MUST NOT delete the existence guards without an explicit planner DEC that names the new `iso_content_staging_authority` invariant. See DEC-PHASE8-007. |

**Critical path (revised 2026-05-16 post-#43 fix + defensive amendment):**
`W8-1 (ACCEPTED) → wi-w8-finish-A (ACCEPTED) → wi-w8-finish-B (ACCEPTED) → wi-w8-content-staging (ACCEPTED) → wi-w8-staging-defensive (ACCEPTED) → W7-7 re-attestation (operator track, PENDING against ISO from develop @ `40416d6`) → W8-7 (approve gate, hard human boundary)`.

Pre-reopen the critical path was three software slices then operator action; the reopen added a fourth software slice (wi-w8-content-staging), and the CI cascade from the empty `theme/wallpapers/` source dir added a fifth (wi-w8-staging-defensive). All FIVE Phase 8 software slices are now ACCEPTED on develop (W8-1, wi-w8-finish-A, wi-w8-finish-B, wi-w8-content-staging, wi-w8-staging-defensive). Two hard human boundaries remain at phase end: W7-7 (physical USB re-attestation against the corrected ISO from develop @ `40416d6`, runs in parallel on operator hardware, must complete before W8-7 publish) and W8-7 (final tag + publish, explicit `approve` gate per DEC-PHASE7-005). DEC-PHASE8-003 (premature software-track closure) is SUPERSEDED by DEC-PHASE8-004; cascade-consolidation discipline per DEC-PHASE7-041 was NOT applied to the content-staging slice (DEC-PHASE8-005) but WAS applied to the defensive amendment (DEC-PHASE8-007 — minimal three-file fix that preserved the existing authority). CI verification of the cascade fix is in-flight at audit time: `develop @ 40416d6` had Lint & Test GREEN, E2E Scenario GREEN, QEMU Boot Test IN PROGRESS (CI run 25967158637 ~9m at audit time).

**Max parallel width:** 1 in the consolidated path (each bundle has a sequencing dependency on the prior). W7-7 operator track runs in parallel on hardware, not on CI; the artifact channel is wi-w8-finish-B's DRAFT-release ISO.

**Phase 8 work item authority discipline:** Detailed Scope Manifests and
Evaluation Contracts are seeded one slice at a time at planner-dispatch time
(same pattern as Phase 7 W-IDs). The expanded contracts live in
`tmp/scope-wi-<id>.json` and `tmp/eval-wi-<id>.json`, written by the planner
before each work item's implementer dispatch.

**W8-1 Scope Manifest and Evaluation Contract (seeded 2026-05-14):**

*Mission.* Bring the entire `develop` tree to a single canonical version
string of `v2.0.0-rc1` (matching `scripts/build-iso.sh`'s default and
`iso/auto/config`'s current value per DEC-PHASE7-002 — the build-iso version
authority). Today, four active-source surfaces disagree: `Dockerfile` LABEL
+ MOTD + bashrc still say `v2.0.0-dev`, `README.md` headline + dd
command-line example still say `v2.0.0-dev`, while `scripts/build-iso.sh`
and `iso/auto/config` already say `v2.0.0-rc1`. This is a live
dual-authority bug — a future implementer reading either surface gets a
different version. W8-1 collapses the surfaces to one, matches the ISO
build authority, and unblocks every later Phase 8 slice (CHANGELOG range
boundary, release notes title, GitHub Release tag name) by establishing
which version string they should reference.

*Version-string decision.* The chosen final value is `v2.0.0-rc1`, NOT
`v2.0.0`. Rationale: (a) the build-iso authority already defaults to `rc1`
per DEC-PHASE7-002 (changing it would supersede that decision without a new
DEC); (b) the actual `v2.0.0` git tag belongs at W8-7 after the operator has
attested USB boot, release notes are finalized, and the signed ISO is
attached to the GitHub Release — pre-bumping to `v2.0.0` now would claim
release-candidate readiness while #39 / #40 runtime gaps remain open and
W7-7 attestation is pending. `rc1` accurately describes the artifact's
current state and matches semver release-candidate conventions.

*Scope Manifest.*

Allowed paths (the implementer may touch these and only these without
re-approval):
- `Dockerfile` — modify `LABEL version="2.0.0-dev"` and the two `v2.0.0-dev` literal references in the MOTD block and the bashrc help block
- `README.md` — modify the `v2.0.0-dev` headline and the `orionx-phoenix-edition-v2.0.0-dev.iso` dd-command example
- `tests/unit/test_build_iso.sh` — modify any test assertion that asserts a specific version literal (verify by `grep -n 'v2\.0\.0' tests/unit/test_build_iso.sh`) so the test still passes against `v2.0.0-rc1`. If the test asserts the version via the `VERSION` constant authority rather than a literal, no change is required — the implementer must check before editing
- `MASTER_PLAN.md` — FORBIDDEN to implementer (planner-owned; the W8-1 closure entry is recorded by a separate planner pass)

Required paths (must be touched in this slice — non-touch is a scope
violation):
- `Dockerfile` (LABEL + MOTD + bashrc literals)
- `README.md` (headline + dd example)

Forbidden paths (any touch requires explicit planner re-approval):
- `scripts/build-iso.sh` — the canonical version authority per DEC-PHASE7-002; modifying the `VERSION="${ORIONX_VERSION:-v2.0.0-rc1}"` line is out of scope (the default value is ALREADY `v2.0.0-rc1` — no change needed)
- `iso/auto/config` — already at `v2.0.0-rc1` (ORIONX_VERSION default); modifying would create version drift
- `scripts/qemu-boot-test.sh`, `docs/qemu-boot-test.md` — Phase 7 harness contains version references in the W7-3 attach contract section; modifying would re-open Phase 7 scope
- `iso/config/hooks/**`, `iso/config/includes.chroot/**`, `iso/config/package-lists/**` — Phase 6/7 ISO authority; no version references expected, any touch is a scope violation
- `systemd/*.service`, `systemd/*.timer` — Phase 4/6/W7-4-A authority; no version references expected
- `tests/integration/**` other than the W8-1 path-check additions if needed — Phase 7 integration test authority; version references should not exist there but if any do, the implementer must flag rather than edit
- `.github/workflows/**` — release workflow changes are W8-4 scope, NOT W8-1
- `docker/**` (mesh-node, matrix-node Dockerfiles, compose files) — those are Phase 3/4/7 Docker test infrastructure; if any contain version strings they are part of a future Docker version-sync slice, not W8-1
- `Makefile` — no version literals expected; any touch is a scope violation
- `MASTER_PLAN.md` — planner-owned per general Phase 7/8 discipline
- `archive/**`, `ORION-X/**` — frozen historical content per DEC-012

Expected state authorities touched:
- `version_string_authority`: single canonical value `v2.0.0-rc1` across all
  active-source surfaces. Owner: `scripts/build-iso.sh`'s `VERSION` constant
  (DEC-PHASE7-002, unchanged by W8-1). All other surfaces become
  derived/consistent rather than independent authorities.

*Evaluation Contract — required tests.*
- `bash tests/unit/test_build_iso.sh` passes locally and in lint.yml CI on the W8-1 feature branch HEAD (asserts build-iso emits the expected version literal; whether the test changes depends on whether it asserts via constant or literal — implementer must verify)
- `grep -rn 'v2\.0\.0-dev' Dockerfile README.md tests/ scripts/ docs/ Makefile .github/ docker/ iso/` returns ZERO matches after the slice lands (anti-drift control: the legacy `v2.0.0-dev` string class collapses to zero across active-source surfaces)
- `grep -rn 'v2\.0\.0-rc1' Dockerfile README.md scripts/build-iso.sh iso/auto/config` returns at least one match in each of the four named files (positive: the canonical string appears in every surface that should have it)
- All three GitHub Actions workflows green on W8-1 feature branch HEAD (lint.yml, qemu-test.yml, e2e-test.yml) — version-string changes should not perturb any runtime path

*Evaluation Contract — required real-path checks.*
- After the slice lands, building the Docker image with `make docker-build` (or the equivalent build command) produces an image whose `LABEL version` is `2.0.0-rc1` — verifiable via `docker inspect --format='{{ index .Config.Labels "version" }}' <image>` (note: the LABEL value omits the `v` prefix per Docker convention; the README and shell-visible MOTD strings retain the `v` prefix per release-notes convention; the implementer documents this convention in the Dockerfile header comment if not already present)
- `grep -c 'v2\.0\.0-rc1' README.md` returns >= 2 (the headline plus the dd-command example, plus any additional references the implementer adds for clarity — at minimum the headline must change)

*Evaluation Contract — required authority invariants.*
- `version_string_authority` is single-source: `scripts/build-iso.sh`'s `VERSION="${ORIONX_VERSION:-v2.0.0-rc1}"` constant remains the canonical authority. No file may hard-code a different version literal that disagrees with this constant. All `v2.0.0-rc1` literals in `Dockerfile`, `README.md`, and other surfaces are derived/consistent rather than independent — they MUST match the build-iso authority's default
- The `v2.0.0-dev` legacy string class is COMPLETELY ERADICATED from active-source surfaces (the anti-drift control mirrors DEC-PHASE7-025's "test path moves with the file" discipline and DEC-PHASE7-033's "legacy reference class collapses to zero" pattern)
- DEC-PHASE7-002 (build-iso as single version authority) is PRESERVED, not superseded — W8-1 is a propagation slice that aligns the derived surfaces with the existing authority, not a new authority decision
- No new `*.version` file, no new `VERSION` env var, no new version-emission script — propagation is by literal edit only

*Evaluation Contract — required integration points.*
- W7-1 (ISO build pipeline modernization): `scripts/build-iso.sh` unchanged; the build authority's default value is the truth source
- W7-3 (QEMU boot harness): `scripts/qemu-boot-test.sh` references the version in the W7-3 attach contract section; W8-1 leaves it untouched per scope discipline. If a version mismatch surfaces in qemu-test.yml CI, it is a Phase 7 follow-up, not a W8-1 fix
- W7-7 enabler (`b411c47`): ISO artifact upload remains operative; the uploaded ISO filename becomes `orionx-phoenix-edition-v2.0.0-rc1.iso` (already true since `iso/auto/config` was already at `rc1`)
- Phase 4 Matrix Docker compose: `docker/docker-compose.matrix-test.yml`, `docker/Dockerfile.matrix-node`, `docker/Dockerfile.mesh-node` — if any contain `v2.0.0-dev` strings they are flagged in the implementer's discovery pass but NOT modified in W8-1 (those are Phase 3/4/7 Docker authority; a follow-up Phase 8 slice may sync them if drift is found, but W8-1's scope is the primary user-facing surfaces only). The implementer reports any findings in the slice's REVIEW_* completion

*Forbidden shortcuts.*
- Bumping to `v2.0.0` (no `-rc1` suffix) — that is W8-7's scope, not W8-1's, and would claim release readiness without the operator attestation and signed artifacts
- Bumping to `v2.0.0-rc2` or higher — there is no `rc1` to date in the project; the first release-candidate is `rc1` by definition
- Modifying `scripts/build-iso.sh`'s `VERSION` constant — that is the canonical authority per DEC-PHASE7-002; the default is already `v2.0.0-rc1`
- Modifying `iso/auto/config`'s `ORIONX_VERSION` default — already `v2.0.0-rc1`; touching it would invert the propagation direction (authority follows derived, not derived follows authority)
- Touching `MASTER_PLAN.md` from the implementer seat — planner-owned per general Phase 7/8 discipline
- Touching any file in the forbidden-paths list, including the Phase 7 frozen authorities (W7-3 harness, systemd/, iso/config/, etc.)
- Adding a CI lint step that asserts version-string consistency — that is W8-4 release-pipeline scope, not W8-1
- Generating a CHANGELOG entry in this slice — that is W8-2 scope
- Adding a release-notes section to README.md — that is W8-5 scope

*Ready-for-guardian definition.*
- All three GitHub Actions workflows green on W8-1 feature branch HEAD (lint.yml, qemu-test.yml, e2e-test.yml)
- `grep -rn 'v2\.0\.0-dev' Dockerfile README.md tests/ scripts/ docs/ Makefile .github/ docker/ iso/` returns zero matches at HEAD
- `grep -rn 'v2\.0\.0-rc1' Dockerfile` returns at least one match (LABEL or shell literal)
- `grep -rn 'v2\.0\.0-rc1' README.md` returns at least two matches (headline + dd example)
- `scripts/build-iso.sh` and `iso/auto/config` show no diff from develop HEAD (single-authority preserved)
- `tests/unit/test_build_iso.sh` passes locally and in lint.yml CI
- Scope Manifest forbidden-paths list shows zero touches in the diff against develop — most critically, no touches to `scripts/build-iso.sh`, `iso/auto/config`, `systemd/**`, `iso/config/**`, `.github/workflows/**`, `MASTER_PLAN.md`
- Reviewer's REVIEW_* completion includes the per-surface diff summary (which line in Dockerfile, which line in README.md, what the test_build_iso.sh change was if any) so a future implementer reading the closure DEC sees exactly what was edited
- Planner closure entry (DEC-PHASE8-002 or DEC-PHASE8-001 amendment at closure time) can be authored citing CI run id, head SHA, and the per-surface diff summary

*Rollback boundary.* Single feature branch `feature/phase8-w8-1-version-rc1`
with one squash merge into `develop`. Reverting this slice restores
`v2.0.0-dev` in `Dockerfile` and `README.md` (and the test if it was
modified); `scripts/build-iso.sh` and `iso/auto/config` remain at
`v2.0.0-rc1` because W8-1 does not touch them. Anti-drift: future
version-string changes (W8-7 `v2.0.0`, future `v2.1.0-rc1`, etc.) must touch
`scripts/build-iso.sh`'s `VERSION` constant as the authoritative source and
re-propagate via the same surface list — a planner DEC is required for any
version bump.

**W8-1 closure (2026-05-14, merge `ee5861b`):** Dockerfile + README.md
propagated from `v2.0.0-dev` to `v2.0.0-rc1` (six lines across the two files
per the merge stat). `scripts/build-iso.sh` and `iso/auto/config` unchanged
per the scope manifest (canonical authority preserved per DEC-PHASE7-002).
Reviewer: 0 findings. Tests: `tests/unit/test_build_iso.sh` 41/41 pass on
HEAD. The Dockerfile `LABEL version="2.0.0-rc1"` (no leading `v` per Docker
convention) and the README dd-example `orionx-phoenix-edition-v2.0.0-rc1.iso`
match the existing `iso/auto/config` ISO output name. Anti-drift check
post-merge: `grep -rn 'v2\.0\.0-dev' Dockerfile README.md` returns zero
matches. Two operator-driven Phase 8 prep landings remain folded into Phase 8
per DEC-PHASE8-001 (`b411c47` W7-7 enabler, `44c7b25` Docker apt cleanup).

**Phase 8 consolidation (2026-05-14, DEC-PHASE8-002):** Post-W8-1 the
remaining pre-bundle W-IDs (W8-2 CHANGELOG, W8-3 Documentation audit, W8-4
release artifact pipeline, W8-5 GitHub Release scaffolding, W8-6 workflow
rename) are reconsidered through the DEC-PHASE7-041 cascade-consolidation
lens. The sequencing W8-2 → W8-3 → W8-4 → W8-5 → W8-6 has no architectural
meaning: W8-2 and W8-3 share the same docs-only forbidden-paths surface, and
W8-4 + W8-5 + W8-6 all touch CI / runtime control plane with overlapping
forbidden-paths surfaces and no source-code touch. Consolidating each natural
cluster into one bundle eliminates artificial slice boundaries while
preserving the planner's per-slice contract discipline. The two resulting
slices are `wi-w8-finish-A` (docs bundle: W8-2 + W8-3) and `wi-w8-finish-B`
(release pipeline bundle: W8-4 + W8-5 + W8-6). The pre-bundle W8-2..W8-6 rows
remain in the W-ID table for traceability but their Status column points to
their consolidated parent and they are NOT seeded as standalone work items.
W7-7 (operator USB attestation) and W8-7 (final tag + publish) remain as hard
human boundaries — both unaffected by the consolidation.

**wi-w8-finish-A Scope Manifest and Evaluation Contract (seeded 2026-05-14):**

*Mission.* Produce a human-curated `CHANGELOG.md` at repo root for the
v2.0.0-rc1 release, sourced from the squash-merge `git log` on `develop`
(Phase 1 through W8-1 `ee5861b` plus the two operator-driven Phase 8 prep
landings `b411c47` and `44c7b25`) with cross-references to the DEC table
where DEC entries provide rationale. Audit `README.md` and
`docs/User_Guide.md` end-to-end so that every install-command, dd-command,
mesh-up command, Matrix-up command, and forensic-toolkit command actually
matches the behavior of the v2.0.0-rc1 ISO that builds from develop HEAD; any
drift (wrong command name, wrong path, stale flag, removed feature, missing
step, version-string mismatch) is corrected. The slice consolidates the
pre-bundle W8-2 (CHANGELOG generation) and W8-3 (Documentation audit) slices
per DEC-PHASE8-002. No runtime behavior change.

*Scope Manifest.* Allowed: `CHANGELOG.md`, `README.md`, `docs/User_Guide.md`,
`docs/CONTRIBUTING.md`, `docs/SUPPORT.md`, `docs/DEVELOPMENT_CHECKLIST.md`,
`docs/e2e-scenario.md`. Required: `CHANGELOG.md`, `README.md`,
`docs/User_Guide.md`. Forbidden (any touch requires planner re-approval):
`scripts/**`, `iso/**`, `systemd/**`, `docker/**`, `Dockerfile`, `Makefile`,
`docker-compose.yml`, `docs/qemu-boot-test.md`, `.github/workflows/**`,
`tests/**`, `MASTER_PLAN.md`, `DECISIONS.md`, `LICENSE.md`, `archive/**`,
`ORION-X/**`, `reckonings/**`. State authorities touched:
`release_notes_authority` (CHANGELOG.md as single canonical changelog),
`user_facing_documentation_authority` (README.md + docs/User_Guide.md
canonical entrypoints). Full contract in `tmp/scope-wi-w8-finish-A.json` and
`tmp/eval-wi-w8-finish-A.json`.

*Acceptance gates (summary).* All three GitHub Actions workflows green on
HEAD (lint.yml, qemu-test.yml, e2e-test.yml); `CHANGELOG.md` exists at repo
root with a `## [v2.0.0-rc1]` section referencing >= 20 W-IDs and >= 10 DEC
IDs across Phases 1-7 + W8-1; `grep -rn 'v2\.0\.0-dev' CHANGELOG.md README.md
docs/User_Guide.md` returns zero matches (anti-drift mirror of W8-1
discipline); every script reference in `docs/User_Guide.md` resolves to an
existing file at develop HEAD; reviewer REVIEW_* includes per-file diff
summary and flagged-but-not-modified findings for follow-up planner
attention.

*Rollback boundary.* Single feature branch
`feature/phase8-w8-finish-A-docs` with one squash merge into `develop`.
Reverting deletes `CHANGELOG.md` and restores the pre-audit `README.md` /
`docs/User_Guide.md`. All other authorities remain at develop HEAD.

**wi-w8-finish-B Scope Manifest and Evaluation Contract (seeded 2026-05-14;
pending wi-w8-finish-A landing):**

*Mission.* Produce four release-pipeline surfaces so that the only remaining
steps to publish v2.0.0 are W7-7 operator USB attestation and W8-7 final tag
+ publish (both hard human boundaries). (1) `.github/workflows/release.yml`
triggers on `v*` tag push or manual workflow_dispatch, builds (or downloads)
the ISO via the canonical `scripts/build-iso.sh` authority, computes SHA-256
and SHA-512 checksums, and produces detached GPG signatures using
`secrets.GPG_PRIVATE_KEY` + `secrets.GPG_PASSPHRASE` with
`continue-on-error: true` on the signing step (operator key provisioning is
a hard human boundary; the workflow does not block on it). (2) Drafts a
GitHub Release in DRAFT mode, attaches ISO + checksums + (optional)
signatures, sources release-notes body from `CHANGELOG.md`. (3) Renames the
runtime workflow identity `phase7-integration` → `phase8-release` via
`cc-policy workflow rename` (runtime-state operation, not source-tree edit).
(4) Optional `docs/release-process.md` operator runbook documenting the W8-7
publish sequence. The slice consolidates pre-bundle W8-4 + W8-5 + W8-6 per
DEC-PHASE8-002. No source-code change to scripts/build-iso.sh, no ISO
behavior change.

*Scope Manifest.* Allowed: `.github/workflows/release.yml`,
`.github/workflows/qemu-test.yml` (only if W7-7-enabler artifact contract
needs adjustment), `scripts/release/**` (helper scripts for the release
pipeline), `docs/release-process.md`. Required:
`.github/workflows/release.yml`. Forbidden (any touch requires planner
re-approval): `scripts/build-iso.sh`, `scripts/qemu-boot-test.sh`,
`scripts/mesh/**`, `scripts/setup-*.sh`, `scripts/security/**`,
`scripts/artifact-analyzer.py`, `scripts/storyboard-gen.py`, `systemd/**`,
`iso/**`, `docker/**`, `Dockerfile`, `Makefile`, `docker-compose.yml`,
`tests/**`, `README.md`, `CHANGELOG.md`, `docs/User_Guide.md`,
`docs/qemu-boot-test.md`, `.github/workflows/lint.yml`,
`.github/workflows/e2e-test.yml`, `MASTER_PLAN.md`, `DECISIONS.md`,
`LICENSE.md`, `archive/**`, `ORION-X/**`, `reckonings/**`. State authorities
touched: `release_pipeline_authority` (release.yml as single canonical
release pipeline), `release_artifact_signing_authority` (operator-provisioned
GPG secrets), `github_release_authorship_authority` (DRAFT mode enforces W8-7
publish gate per DEC-PHASE7-005), `workflow_identity_authority` (runtime
rename phase7-integration → phase8-release). Full contract in
`tmp/scope-wi-w8-finish-B.json` and `tmp/eval-wi-w8-finish-B.json`.

*Acceptance gates (summary).* All four GitHub Actions workflows green on
HEAD (lint.yml, qemu-test.yml, e2e-test.yml, release.yml `workflow_dispatch`
dry-run with run id captured); release.yml triggers on `v*` tag and
workflow_dispatch; contains SHA-256 + SHA-512 + detached GPG signing (with
`continue-on-error: true` on the GPG step) + GitHub Release scaffold in
DRAFT mode; references `secrets.GPG_PRIVATE_KEY` + `secrets.GPG_PASSPHRASE`;
sources release-notes from `CHANGELOG.md` (wi-w8-finish-A output); a
`workflow_dispatch` run on the feature branch HEAD has completed end-to-end
with the GPG-signing step optionally failing non-blocking but all other
steps succeeding; runtime workflow identity renamed via `cc-policy workflow
rename phase7-integration phase8-release` (command + output captured in
REVIEW_*); subsequent `cc-policy context role` returns
`workflow_id: phase8-release`.

*Rollback boundary.* Single feature branch
`feature/phase8-w8-finish-B-release-pipeline` with one squash merge into
`develop`. Reverting deletes `release.yml`, `scripts/release/**`, and
`docs/release-process.md`. The runtime workflow-identity rename is a
separate runtime-state operation; reverting requires `cc-policy workflow
rename phase8-release phase7-integration` (implementer documents the
rollback runbook in REVIEW_*).

**Hard human boundaries at phase end (no software slice can close these):**

- **W7-7 (Physical USB boot attestation).** Operator downloads the
  DRAFT-release ISO + checksums (or the qemu-test.yml artifact), `dd`-writes
  to a physical USB, boots on at least one real piece of hardware, validates
  the User_Guide walkthrough end-to-end (mesh-up, Matrix-up, forensic
  toolkit), and signs off. `approve` gate per DEC-PHASE7-005. The artifact
  channel is wi-w8-finish-B's DRAFT release going forward; until then, the
  W7-7 enabler `b411c47` qemu-test.yml artifact upload is the channel.
- **Operator GPG key provisioning.** Before W8-7 publish, the operator
  generates a GPG keypair, uploads the private key to
  `secrets.GPG_PRIVATE_KEY` and the passphrase to `secrets.GPG_PASSPHRASE`
  (or matching organization-secret equivalents), publishes the public key
  out-of-band (keyserver, gpg.jarocki.org, or a `.well-known` URL referenced
  from README.md and CHANGELOG.md). This is one-time work; subsequent
  release.yml runs produce signatures automatically. No software slice can
  generate the key — that would defeat signature verification.
- **W8-7 (final `v2.0.0` tag + GitHub Release publish).** Operator runs
  (a) retag `v2.0.0-rc1` → `v2.0.0` (or creates a new `v2.0.0` tag on the
  same commit), (b) confirms `secrets.GPG_PRIVATE_KEY` and
  `secrets.GPG_PASSPHRASE` are provisioned, (c) re-runs release.yml on the
  new tag (signatures now produced unconditionally), (d) verifies
  signatures + W7-7 attestation complete, (e) `gh release edit v2.0.0
  --draft=false` to publish, (f) the planner records the closure DEC
  (DEC-PHASE8-005 or successor; numbering depends on intermediate closure
  DECs at wi-w8-finish-A and wi-w8-finish-B). Explicit `approve` gate per
  DEC-PHASE7-005. The slice contract for W8-7 is intentionally minimal —
  the slice is operator action, not implementer work.

**Phase 8 reopen (2026-05-15, DEC-PHASE8-004 / DEC-PHASE8-005 — supersedes DEC-PHASE8-003):**
W7-7 hardware attestation on 2026-05-15 found the ISO produced by the current
build pipeline is MISSING the entire Orion-X application layer — no
`/opt/orionx/scripts/`, no `/opt/orionx/theme/`, no `/opt/orionx/data/`, no
`/usr/share/doc/orionx/`, no PATH symlinks at `/usr/bin/orionx-mesh` etc. The
ISO boots a stock Debian Bullseye + Phase 6/7 infrastructure (AppArmor
profiles, systemd units, security hardening) but is NOT a recognizable
Orion-X release. v2.0.0-rc1 MUST NOT be tagged in its current form. Filed as
issue #43.

*Root cause.* `scripts/build-iso.sh` runs `lb config` + `lb build`, and
`iso/config/includes.chroot/` contains AppArmor profiles, systemd units, and
helper scripts under `/usr/local/bin`, but does NOT contain the application
layer. The Dockerfile `COPY scripts/ /opt/orionx/scripts/` and equivalent
operations populate the dev-container image; there's no equivalent staging
step in the ISO build path. The dual-authority gap was that the ISO build
pipeline silently produced an ISO without application content while the
Dockerfile-built dev container had it, and no test gated on content presence
inside the booted ISO.

*Why Phase 7 tests didn't catch this.* The Phase 7 test surface gated on
infrastructure: hooks ran (test-iso-hooks-applied.sh), systemd units exist
(test-w7-4-b-runtime-verify.sh), performance thresholds met
(test-w7-5-performance.sh), failure-resilience configs correct
(test-w7-6-failure-resilience.sh). None of those tests asserted that any
specific application file is present in the booted ISO. A stock Debian + the
Phase 6 hooks + the Phase 6 systemd units passes every Phase 7 test. This is
the integration-testing blind spot that W7-7 hardware attestation was
designed to surface — and it surfaced exactly as intended. **W7-7 is praised
here as the operator gate correctly catching this before tag publication**
(best-case W7-7 outcome: human attestation finds a class of failure that
automated CI is structurally blind to).

*Architectural framing — NOT a cascade-consolidation candidate.* The
DEC-PHASE7-041 cascade-consolidation discipline (now applied three times:
W7-4-B-exit, W7-5-exit, Phase 8 finish-A/B bundling per DEC-PHASE8-002) does
NOT apply here. This is not a downstream cascade exit where a slice has
mostly landed and a remaining sliver needs to be folded into a larger
follow-up; this is a fundamental architectural gap that requires a real fix
slice with its own Scope Manifest and Evaluation Contract. Bundling
content-staging with hypothetical future work (e.g., a runtime-cleanup slice
for #41/#42, or a documentation-pass slice that adds wallpaper assets) would
conflate a release-readiness gate fix with unrelated work and reduce the
diff's reviewability. wi-w8-content-staging is seeded as a single dedicated
slice per DEC-PHASE8-005.

*Structural fix established as a release-readiness invariant.* Going forward,
release-readiness for any Orion-X ISO is gated not only on infrastructure
correctness but also on content presence. `tests/integration/test-iso-content-presence.sh`
becomes the canonical gate (mounts the squashfs, asserts canonical
application paths exist), wired into `.github/workflows/qemu-test.yml` as an
ACTIVE gate (no `continue-on-error`). Any future regression in
`stage_application_content` turns CI red. This is the durable lesson:
infrastructure tests are necessary but not sufficient — content-presence
tests are a separate axis that must be gated explicitly.

**Phase 8 software-track closure (re-established 2026-05-16, develop @ `40416d6`):** The
Phase 8 software track was first declared complete 2026-05-14 (DEC-PHASE8-003,
develop @ `0b8f1b0`), then SUPERSEDED 2026-05-15 by DEC-PHASE8-004 because
W7-7 operator hardware attestation surfaced critical finding #43 (the ISO
was missing the entire Orion-X application layer). Software-track closure
is **re-established 2026-05-16** at develop @ `40416d6` (issue #43 CLOSED)
after two follow-on slices landed: **wi-w8-content-staging** (`e725895`,
DEC-PHASE8-006 — staged the application layer + content-presence ACTIVE
gate) and **wi-w8-staging-defensive** (`40416d6`, DEC-PHASE8-007 — rsync
tolerance + `.gitkeep` pattern fixing the CI cascade from the empty
`theme/wallpapers/` source dir). The original 2026-05-14 closure narrative
is retained below for traceability — readers should treat its claims about
"two items remain to reach goal_complete" as describing the pre-reopen
state, then read the revised handoff summary at the end of this section
for the current operator action plan. Five implementation slices landed on
`develop` (W8-1 `ee5861b` version-string finalization; wi-w8-finish-A
`586fa05` docs bundle — CHANGELOG.md + User_Guide.md audit; wi-w8-finish-B
`0b8f1b0` release pipeline bundle — release.yml + extract-release-notes.sh
+ release-process.md), plus two operator-driven prep landings folded into
Phase 8 (`b411c47` W7-7 enabler ISO artifact upload; `44c7b25` Dockerfile
apt-unavailable package cleanup). The release pipeline is live and
tag-driven: operators can `git tag -a v2.0.0-rc1 && git push origin
v2.0.0-rc1` to trigger release.yml and emit a DRAFT GitHub Release with
ISO + SHA-256/SHA-512 checksums + (optional) GPG signatures, sourcing the
release-notes body from `CHANGELOG.md`. Two items remain to reach
goal_complete, both HARD HUMAN BOUNDARIES that no software slice can
close: **W7-7** (operator physical USB attestation, runs in parallel on
real hardware; artifact channels are qemu-test.yml CI artifact and the
DRAFT release.yml ISO) and **W8-7** (final `v2.0.0` retag + DRAFT → public
publish flip, explicit `approve` gate per DEC-PHASE7-005, requires W7-7
attestation + operator GPG key provisioning + `gh release edit
v2.0.0 --draft=false`). Two runtime-control-plane hygiene findings
surfaced during this slice and are tracked for Phase 8 design pass /
runtime cleanup: **#41** (`decode_work_item_contract` rejects
`workflow_id` in `evaluation_json` — already tracked at Phase 7 closure
per DEC-PHASE7-043) and **#42** (`cc-policy workflow bind` FK constraint
failure when rebinding an existing worktree — newly filed; blocks the W8-6
workflow rename `phase7-integration` → `phase8-release` as decorative
drift only, no software functionality impact). Neither finding blocks
Phase 8 closure or any operator action.

**Workflow identity drift note (informational, 2026-05-14):** Per #42, the
runtime `workflow_id` for this development worktree is still
`phase7-integration` even though Phase 8 is the active phase and its
software track is complete. This is dual-authority drift between the
MASTER_PLAN.md `### Phase 8` narrative (Phase 8 active) and the
`cc-policy context role` runtime state (workflow_id still phase7).
**Impact is decorative only**: release.yml, GitHub Actions, the source
tree, the canonical version authority (`scripts/build-iso.sh`), and every
state authority enumerated in the Phase 7 / Phase 8 narratives are
independent of the runtime workflow identity string. The drift resolves
when #42 lands (operator runs `cc-policy workflow unbind` + `bind` with
the new identity) or by manual planner re-bind once the FK bug is fixed.
W8-6 status (PARTIAL) in the W-ID table records this same observation.

**What the operator does next (handoff summary, REVISED 2026-05-16 post-#43-fix):**

The #43 fix has landed in two slices (wi-w8-content-staging at `e725895`
and wi-w8-staging-defensive at `40416d6`) and issue #43 is CLOSED. The
ISO produced by `scripts/build-iso.sh` from develop @ `40416d6` now
contains the Orion-X application layer (scripts/theme/data/docs staged
into the chroot plus PATH symlinks for the eight named entrypoints), and
`tests/integration/test-iso-content-presence.sh` is wired as an ACTIVE
CI gate in `.github/workflows/qemu-test.yml` against any future
regression. The revised operator sequence:

1. **CI verification of `40416d6` completes** (in-flight at audit time,
   CI run `25967158637`). Lint & Test and E2E Scenario already GREEN on
   the merge commit; QEMU Boot Test must complete green for the
   content-presence test to be confirmed effective in CI. If the run
   surfaces a new failure (e.g., a Phase 6 hook regression triggered by
   the new content presence), the cascade-consolidation discipline of
   DEC-PHASE7-041 / DEC-PHASE8-007 applies: planner seeds the next
   minimal-scope amendment slice, not a wholesale rework.
2. **W7-7 re-attestation.** Operator downloads the corrected ISO from the
   `qemu-test.yml` CI artifact at the green run (`gh run download <run_id>
   -n orionx-iso-<run_id>`); `dd`-writes to physical USB; boots on at
   least one real piece of hardware (UEFI laptop + BIOS desktop or
   equivalent); validates the `docs/User_Guide.md` walkthrough end-to-end
   (mesh-up, Matrix-up, forensic toolkit, all eight PATH entrypoints
   accessible). Re-engages the same `approve` gate per DEC-PHASE7-005;
   this is not a new boundary. Planner records closure DEC for W7-7 at
   attestation pass time.
3. **Promote `v2.0.0-rc1` → `v2.0.0` final.** Once W7-7 re-attestation
   passes: provision `secrets.GPG_PRIVATE_KEY` + `secrets.GPG_PASSPHRASE`
   in GitHub repo settings; cut rc1 via `git tag -a v2.0.0-rc1`; perform
   the version bump + retag procedure in `docs/release-process.md`; re-run
   `release.yml` on the new `v2.0.0` tag; verify GitHub Release contents;
   `gh release edit v2.0.0 --draft=false` to publish. The planner records
   closure DEC-PHASE8-NNN at publish.

**Open question (operator clarification welcome).** The W7-7 finding mentions
"LLM-assisted workflows" as missing content. Planner discovery 2026-05-15:
no script in `scripts/` is explicitly labeled "LLM-assisted"; the closest
candidates are `artifact-analyzer.py` + `storyboard-gen.py` (the Phase 5
forensic-orchestration pair per DEC-005). The slice includes both; if the
operator's intent is a different/hypothetical SIFT-AI script not yet in the
tree, that requires a separate planner pass and DEC to specify.

---

## Initiative 2: Autonomous Forensic Platform (v2.1 -> v3.x)

This initiative transforms Orion X from a toolkit into an autonomous forensic intelligence platform. Each release builds on v2.0.0 and is independently valuable.

### v2.1.0 — AI Integration (Protocol SIFT Model)

**The core transformation.** Integrate MCP-orchestrated AI forensics inspired by Protocol SIFT.

- **MCP Tool Server** — Expose all forensic utilities (Volatility3, tshark, bulk_extractor, Ghidra headless, Plaso, Zeek, sleuthkit, binwalk) as MCP tools with semantic descriptions
- **Local LLM Runtime** — Self-hosted models via Ollama/llama.cpp. All AI processing is LOCAL. No evidence data leaves the platform
- **Inference Constraint Layer** — High constraint mode (default): AI directs verified tool execution and interprets output. Direct evidence summarization without tool verification is blocked
- **Ralph Wiggum Loop** — Failure-recovery: when tools fail, the engine reads errors, adjusts hypotheses, retries with alternatives
- **Natural Language Interface** — "Show me lateral movement in the last 48 hours" -> coordinated multi-tool analysis
- **MITRE ATT&CK v18+ Mapping** — Automatic indicator-to-technique mapping, ATLAS for AI threats
- **Evidence integrity logging** — Merkle-tree hash chain for all evidence operations (blockchain MVP)
- **AI stack self-defense** — Sandboxed MCP execution, input validation, dependency CVE scanning, model integrity verification (informed by AESIR's MCP vulnerability discoveries)

### v2.2.0 — Cloud & Container Forensics

- **Cloud forensic adapters** — AWS CloudTrail/GCP Audit/Azure Activity evidence collection via API
- **Kubernetes forensic capture** — Pod snapshots, syscall traces via Falco/Sysdig, container post-mortem
- **Serverless function log analysis** — Lambda, Cloud Functions, Azure Functions
- **Multi-cloud evidence normalization** — Unified event schema
- **8-minute response automation** — Rapid capture playbooks for ephemeral evidence

### v3.0.0 — Blockchain & Post-Quantum Cryptography

- **Distributed blockchain evidence ledger** — Private Merkle-tree across mesh nodes, smart contract chain-of-custody rules
- **Quantum-resistant mesh encryption** — WireGuard with ML-KEM/Kyber + X25519 hybrid
- **Quantum-resistant evidence hashing** — SLH-DSA/SPHINCS+ for long-term integrity
- **AI audit trail** — Every inference, prompt, tool output, and conclusion recorded on-chain
- **Court export** — Human-readable reports + cryptographic proofs + verifiable AI reasoning chains

### v3.1.0 — Immutable Platform Migration

- **NixOS migration** — Declarative, reproducible builds replacing Debian live-build
- **TPM 2.0 measured boot** — Cryptographic platform attestation
- **Mutual mesh attestation** — Nodes verify each other's integrity before joining
- **Hardware Security Module integration** — YubiKey/Nitrokey for key material
- **Atomic updates with rollback** — No configuration drift between deployments

---

## Design Principles

**From the original Orion (retained):**
1. Trusted platform in hostile environments
2. Strong authentication and encrypted communications
3. Self-contained operation (no dependency on compromised infrastructure)
4. Pre-installed tools ready for immediate use

**Extended for the modern era:**
5. **AI-first, human-validated** — The machine proposes, the analyst disposes. Every AI conclusion requires verifiable tool output
6. **Evidence integrity by default** — Everything is logged. There is no "unlogged" mode
7. **Quantum-ready today** — Hybrid crypto everywhere. "Harvest now, decrypt later" is an active threat
8. **Cloud-native forensics** — The crime scene extends to every cloud provider and container orchestrator
9. **Reproducible trust** — The platform itself is cryptographically verifiable
10. **Match the adversary's speed** — If offense operates at AI speed, defense must too

---

## Git Strategy

- **`main`** — Sacred, release-only (tagged releases)
- **`develop`** — Integration branch
- **`feature/phase-N-*`** — One branch per phase, worktree-based development
- Squash merges to develop for clean history

## Decision Log

| ID | Date | Decision | Rationale |
|----|------|----------|-----------|
| DEC-001 | 2026-03-08 | [FOUNDATION] Start from v1.5.5 as foundation | Most mature version, has all scripts and ISO config |
| DEC-002 | 2026-03-08 | [INFRA] Debian Bullseye retained for v2.0 | Stable, known working; NixOS migration deferred to v3.1 |
| DEC-003 | 2026-03-08 | [MESH] LAN-only mesh for MVP | NAT traversal adds complexity; defer to v2.1. Code: `scripts/artifact-analyzer.py` |
| DEC-004 | 2026-03-08 | [ARCH] Expand from 4 to 6 layers | AI engine, cloud adapters, blockchain ledger are essential for modern threats. Code: `scripts/storyboard-gen.py` |
| DEC-005 | 2026-03-08 | [BUILD] Protocol SIFT as AI architecture model | Proven by SANS (40+ students, 2/3 improved), MCP orchestration is the right pattern. Code: `Makefile` |
| DEC-006 | 2026-03-08 | [SECURITY] All AI processing must be LOCAL | Evidence data must never leave the platform; no cloud AI APIs |
| DEC-007 | 2026-03-08 | [SECURITY] MCP tool server needs sandboxed execution | AESIR found command injection in MCP tooling; our AI stack is an attack surface |
| DEC-008 | 2026-03-08 | [STRATEGY] Ship v2.0 before AI integration | Foundation must work first; AI layers on top of proven mesh+comms+toolkit |
| DEC-009 | 2026-03-12 | [INFRA] Retain Bullseye for v2.0.0; plan Bookworm migration as future initiative | Bullseye EOL June 2026; v2.0.0 ships before EOL. Bookworm migration deferred to post-v2.0.0 initiative |
| DEC-010 | 2026-04-05 | [STRATEGY] Aggressive timeline — ship v2.0.0 on Bullseye before June 2026 EOL | 6 phases remain, ~2 months to EOL. No margin for delay. Reckoning confirmed foundations are sound — execute now |
| DEC-011 | 2026-04-05 | [MESH] Full P2P mesh scope for Phase 3 | Core differentiator. Reduced scope would undermine the project's identity. LAN-only constraint (DEC-003) already limits complexity |
| DEC-012 | 2026-04-05 | [HOUSEKEEPING] Move ORION-X/ to archive/legacy-orionx/ | 17MB of legacy PDFs, images, and old versions at repo root. v1.5.5 scripts already flattened. v1.5.0 analysis scripts preserved as reference for future AI phases |
| DEC-013 | 2026-04-05 | [PROCESS] Weekly development cadence with session checkpoints | Project demonstrated burst execution (4 days) then stalled 24 days. Regular cadence prevents drift |
| DEC-MESH-001 | 2026-04-06 | [MESH] UDP broadcast + shared config for dual-mode peer discovery | Avahi overkill for LAN-only; UDP broadcast zero-dep, works on Docker bridge. Code: `scripts/mesh/mesh-discover.sh` |
| DEC-MESH-002 | 2026-04-06 | [MESH] systemd timer + oneshot for health checking (60s interval) | Native journald, crash recovery, dependency management. Code: `scripts/mesh/mesh-health.sh` |
| DEC-MESH-003 | 2026-04-06 | [MESH] In-kernel Docker testing with dedicated 3-node compose file | Production fidelity; separate compose keeps mesh testing isolated. Code: `docker/Dockerfile.mesh-node` |
| DEC-MESH-004 | 2026-04-06 | [MESH] Single bash CLI (orionx-mesh) with case-based subcommands | Consistent with existing codebase. Code: `scripts/mesh/orionx-mesh` |
| DEC-MESH-005 | 2026-04-06 | [MESH] Direct wg/ip for runtime, wg-quick for bootstrap only | Soft healing avoids 2-min handshake lockout. Code: `scripts/mesh/mesh-health.sh` |
| DEC-MESH-STANDALONE-001 | 2026-04-20 | [MESH] Retain standalone WireGuard setup alongside mesh | Not every scenario needs full mesh; simple tunnel useful for individual operators. Code: `scripts/setup-wireguard.sh` |
| DEC-MATRIX-002 | 2026-04-22 | [MATRIX] Layered Docker — matrix node extends mesh capabilities | Tests Matrix-over-WireGuard mesh (actual acceptance criteria). Code: `docker/Dockerfile.matrix-node` |
| DEC-MATRIX-003 | 2026-04-22 | [MATRIX] Pre-built homeserver.yaml template with placeholder substitution | Reproducible, fast container startup, inspectable. Code: `docker/matrix/homeserver.yaml` |
| DEC-MATRIX-004 | 2026-04-22 | [MATRIX] SQLite backend, not PostgreSQL | Small forensic team (< 50 users), local-only operation, simplicity. Code: `docker/matrix/homeserver.yaml` |
| DEC-MATRIX-005 | 2026-04-22 | [MATRIX] systemd unit validated statically, runtime testing in Phase 7 | Docker lacks systemd; validate correctness, defer runtime to QEMU. Code: `systemd/matrix-synapse-orionx.service` |
| DEC-MATRIX-SETUP-001 | 2026-04-22 | [MATRIX] Modernize setup-matrix.sh with CLI arguments | Interactive prompts don't work in Docker. CLI args enable automated deployment. Code: `scripts/setup-matrix.sh` |
| DEC-MATRIX-TEST-001 | 2026-04-23 | [MATRIX] CLI-based E2E verification via Synapse API, not Element Desktop | Headless Docker needs CLI tools. E2E property is what matters, not specific client. Code: `tests/integration/test-matrix.sh` |
| DEC-FORENSIC-001 | 2026-04-25 | [FORENSIC] Test pure logic functions without mocking subprocess | Honest >= 60% coverage; forensic tools not available in CI. Code: `tests/unit/test_artifact_analyzer.py`, `tests/unit/test_storyboard_gen.py` |
| DEC-FORENSIC-002 | 2026-04-24 | [FORENSIC] Commit small synthetic sample files to repo | Deterministic tests, works offline, valid format headers. Code: `data/samples/` |
| DEC-FORENSIC-003 | 2026-04-26 | [FORENSIC] download-samples.sh follows setup-matrix.sh CLI pattern | Consistent project conventions. --offline mode for air-gapped. Code: `scripts/download-samples.sh` |
| DEC-SEC-001 | 2026-04-27 | [SECURITY] nftables over iptables/ufw for firewall | Debian Bullseye default, kernel-native. Code: `iso/config/includes.chroot/etc/nftables.conf` |
| DEC-SEC-002 | 2026-04-27 | [SECURITY] Static AppArmor profiles shipped in repo | Inspectable, version-controlled, deterministic. Code: `iso/config/includes.chroot/etc/apparmor.d/` |
| DEC-SEC-003 | 2026-04-28 | [SECURITY] First-boot wizard as shell script + systemd oneshot | Zero additional deps, runs once and disables. Code: `scripts/security/first-boot-wizard.sh` |
| DEC-SEC-004 | 2026-04-27 | [SECURITY] Structural validation in CI, runtime in Phase 7 | Docker lacks systemd/AppArmor kernel. Configs validated structurally. Code: `tests/integration/test-security-hardening.sh` |
| DEC-SEC-005 | 2026-04-27 | [SECURITY] Modernize run-lynis.sh, retire v2 | Single source of truth. Code: `scripts/run-lynis.sh` |
| DEC-PHASE7-001 | 2026-04-28 | [INTEGRATION] Cheapest-iteration-first sequencing: Docker -> QEMU -> hardware | Docker validates orchestration in seconds, QEMU validates kernel/systemd in minutes, hardware validates USB boot once. Inverting this order would burn the Bullseye-EOL clock. Code: `MASTER_PLAN.md` Phase 7 work breakdown |
| DEC-PHASE7-002 | 2026-04-28 | [INTEGRATION] ISO build script must be modernized as W7-1 before QEMU work | `scripts/build-iso.sh` still references v1.5.5 and uppercase `ISO/` path; `iso/` (lowercase) holds Phase 1-6 hardening assets. QEMU testing requires a build that actually emits hardened bits. Code: `scripts/build-iso.sh` |
| DEC-PHASE7-003 | 2026-04-28 | [INTEGRATION] E2E scenario in Docker first, full mesh+Matrix+forensics+report flow | Docker mesh+matrix compose already exists; combining them validates the operator workflow before paying QEMU cost. QEMU re-runs the same script to confirm it works on real systemd. Code: `tests/integration/test-e2e-scenario.sh` (new) |
| DEC-PHASE7-004 | 2026-04-28 | [INTEGRATION] Performance budgets are soft gates with documented exceptions | Boot <90s / ISO <4GB / idle RAM <1GB are operator-experience targets, not security invariants. If exceeded, ship with documented values and a remediation issue rather than blocking v2.0.0 release. EOL clock dominates. Code: `tests/integration/test-performance.sh` (new) |
| DEC-PHASE7-005 | 2026-04-28 | [INTEGRATION] Hardware USB boot is mandatory but parallelizable with QEMU work | Goal contract names physical hardware explicitly; cannot defer. But hardware validation is human-in-the-loop, so it runs as parallel `approve` gate beside the QEMU automation track to avoid blocking software work. Code: `docs/phase7-hardware-boot-procedure.md` (new) |
| DEC-PHASE7-006 | 2026-04-28 | [INTEGRATION] Failure-mode coverage is all 4: node drop, Synapse restart, disk full, network flap | All four are named in the desired end state; reducing coverage requires user signoff. Implementation: each as a discrete sub-test inside W7-6 with PASS/FAIL/SKIP semantics so partial completion is visible. Code: `tests/integration/test-failure-modes.sh` (new) |
| DEC-PHASE7-007 | 2026-04-28 | [W7-2] E2E scenario is a single bash script, not docker-compose-only orchestration | Matches existing project pattern (test-mesh.sh, test-matrix.sh, test-security-hardening.sh are all bash). Compose alone cannot express step-by-step PASS/FAIL/SKIP across mesh formation -> Matrix bootstrap -> forensic analysis -> share -> chain-of-custody report. Bash gives per-step instrumentation, structured failure reporting, and a single-file rollback boundary. Code: `tests/integration/test-e2e-scenario.sh` (new) |
| DEC-PHASE7-008 | 2026-04-28 | [W7-2] Unified 3-node compose with subnet 172.22.0.0/24, reusing Dockerfile.matrix-node | matrix-node is a superset of mesh-node (DEC-MATRIX-002); 3 matrix-node containers can form a mesh with one designated as Synapse server. Subnet 172.22 avoids collision with mesh-test (172.20) and matrix-test (172.21) so all three stacks coexist. Single image, single compose file, no new Dockerfile required. Code: `docker/docker-compose.e2e-test.yml` (new) |
| DEC-PHASE7-009 | 2026-04-28 | [W7-2] Inline minimal verification per phase, do NOT shell out to existing test-mesh.sh / test-matrix.sh | Existing scripts assume their own compose files and project names; invoking them as sub-scripts would either spin up duplicate stacks (slow, IP collisions) or require parameterizing them (out of W7-2 scope, would touch forbidden_paths). E2E is an integrated linear scenario; the per-phase scripts remain the granular regression suite. Shared helpers may live in `tests/integration/lib/` for future refactor. Code: `tests/integration/test-e2e-scenario.sh` |
| DEC-PHASE7-010 | 2026-04-28 | [W7-2] Output: terminal log + JSON summary + HTML chain-of-custody report | Terminal log is the live operator view. `tmp/e2e-artifacts/<run-id>/scenario-summary.json` is machine-readable status (per-step PASS/FAIL/SKIP, timing, run metadata). The HTML chain-of-custody report is the *deliverable of the scenario itself* — generated by `scripts/storyboard-gen.py` as the final scenario step, archived to `tmp/e2e-artifacts/<run-id>/report.html`. The test runner does not generate its own HTML; it consumes the script-under-test's HTML as evidence. Code: `tests/integration/test-e2e-scenario.sh` |
| DEC-PHASE7-011 | 2026-04-28 | [W7-2] Trap-based teardown with explicit run_step helper; no global set -e | A single failed step must (a) report which step failed, (b) capture container logs to `tmp/e2e-artifacts/<run-id>/logs/`, (c) run cleanup (compose down -v + network rm), (d) exit non-zero with summary. Global `set -e` would skip the cleanup phase. Pattern: `set -uo pipefail` (no -e) + `trap cleanup EXIT` + per-step `if ! step_X; then mark_fail "step_X"; fi` with the run loop short-circuiting on first failure. Idempotency: a second back-to-back run must produce identical PASS results with zero leaked Docker resources. Code: `tests/integration/test-e2e-scenario.sh` |
| DEC-PHASE7-012 | 2026-04-28 | [W7-2] F-W71-004 (systemd unit -> squashfs hook) does NOT block W7-2; it blocks W7-4 only | W7-2 runs entirely inside Docker containers that lack systemd. Mesh starts via `mesh-entrypoint.sh`; Matrix starts via `matrix-entrypoint.sh`. Both are existing entrypoints from Phases 3-4. F-W71-004 governs whether systemd units land in the live-build squashfs, which only matters when QEMU boots a real systemd PID 1 (W7-4). W7-2's Evaluation Contract explicitly forbids depending on `systemctl` inside containers, codifying the boundary. Code: `MASTER_PLAN.md` Phase 7 work breakdown |
| DEC-PHASE7-013 | 2026-04-29 | [W7-2] CI workflow pre-creates `/var/log/orionx` with sudo to satisfy analyzer scripts | `scripts/artifact-analyzer.py` and `scripts/storyboard-gen.py` (Phase 5) open `/var/log/orionx/*.log` at module import. On unprivileged CI runners (ubuntu-latest, non-root), the directory does not exist and import fails. W7-2 cannot modify the analyzer scripts (forbidden scope). The `e2e-test.yml` workflow runs `sudo mkdir -p /var/log/orionx && sudo chmod 777 /var/log/orionx` before `make test-e2e` so the directory is writable to the test process. This is a workaround pending a future work item that fixes the analyzer log-path handling (e.g., env-var override or relative-path support). Code: `.github/workflows/e2e-test.yml` |
| DEC-PHASE7-014 | 2026-04-30 | [W7-CI-FIX-2] Synapse install via pip3 only — matrix-org Debian package incompatible with frozen entrypoint | matrix-synapse-py3 Debian package installs Synapse to a private venv at /opt/venvs/matrix-synapse/ which is NOT on system python3 import path. matrix-entrypoint.sh (frozen, DEC-MATRIX-005) invokes `python3 -m synapse.app.homeserver` requiring system-python importability. pip3 install matrix-synapse to /usr/local/lib/python3.x/site-packages satisfies the contract. matrix-org Debian repo path removed from Dockerfile.matrix-node entirely. Code: `docker/Dockerfile.matrix-node` |
| DEC-PHASE7-015 | 2026-05-01 | [W7-CI-FIX-3] matrix-node + mesh-node containers switched to debian:bookworm-slim | Bullseye Python 3.9 incompatible with latest matrix-synapse via `class X(Generic[T], Collector)` MRO TypeError on Python <3.10 (#19 user adjudication option b). Bookworm Python 3.11 resolves cleanly with no version pin. Bounded supersedence of DEC-009: applies to docker/ container builds ONLY — iso/ live-build retains debian:bullseye for v2.0.0 release. DEC-MATRIX-005 entrypoint contract preserved. Code: `docker/Dockerfile.matrix-node`, `docker/Dockerfile.mesh-node` |
| DEC-PHASE7-016 | 2026-05-01 | [W7-CI-FIX-5] pip3 install requires --break-system-packages on Bookworm | Bookworm enforces PEP 668 (externally-managed environment) — system-wide pip3 installs fail with "This environment is externally managed" by default. Inside containers the entire filesystem is dedicated to the application; venv is forbidden because matrix-entrypoint.sh (frozen) invokes `python3 -m synapse.app.homeserver` from system python3. --break-system-packages is the canonical Bookworm container escape hatch. Code: `docker/Dockerfile.matrix-node` |
| DEC-PHASE7-017 | 2026-04-28 | [W7-3] Single bash harness `scripts/qemu-boot-test.sh`, not Python or Make-only | Matches existing project pattern (test-mesh.sh, test-matrix.sh, test-security-hardening.sh, test-e2e-scenario.sh are all bash). Make alone cannot express per-mode PASS/FAIL/SKIP, serial-log capture, OVMF resolution order, KVM detection, and trap-based QEMU process cleanup. Python would import a new state authority for what is fundamentally a `qemu-system-x86_64 + grep + tee` orchestration. Bash is the right tool. The Makefile target `test-qemu-boot` is a one-line wrapper. Code: `scripts/qemu-boot-test.sh` (new) |
| DEC-PHASE7-018 | 2026-04-28 | [W7-3] Boot the SAME hybrid ISO twice with different QEMU firmware (no UEFI-specific build) | iso/auto/config already configures `--bootloader 'syslinux,grub-efi'` producing a hybrid ISO that supports both BIOS (isolinux) and UEFI (grub-efi) boot. The harness invokes qemu-system-x86_64 twice on the same `output/orionx-phoenix-edition-*.iso`: once with default SeaBIOS for legacy boot, once with `-drive if=pflash,...,file=OVMF_CODE.fd` for UEFI. Producing two ISOs would diverge from the actual shipping artifact and double W7-1's build time. Two firmware paths against one ISO is the correct test of the hybrid claim. Code: `scripts/qemu-boot-test.sh` |
| DEC-PHASE7-019 | 2026-04-28 | [W7-3] OVMF resolution order with explicit SKIP on missing firmware (never silent PASS) | UEFI boot requires OVMF firmware, which is distribution-packaged: Debian/Ubuntu `ovmf` -> /usr/share/OVMF/OVMF_CODE.fd; Fedora/RHEL `edk2-ovmf` -> /usr/share/edk2/ovmf/OVMF_CODE.fd. The harness searches in order: 1) explicit `--ovmf <path>`, 2) Debian path, 3) Fedora path. If none found, emit a SKIP record with all paths searched and exit non-zero. Silent UEFI-skip would hide a regression that breaks the goal contract ("ISO boots in QEMU under UEFI and BIOS"). The CI workflow installs `ovmf` as a step so the Debian path always resolves on ubuntu-latest. Code: `scripts/qemu-boot-test.sh` |
| DEC-PHASE7-020 | 2026-04-28 | [W7-3] Serial-file capture with single-constant boot-success marker matcher | QEMU `-nographic -serial file:tmp/qemu-artifacts/<run-id>/serial-<mode>.log -monitor none` captures the entire boot stream to disk while the harness greps for a success marker. Marker pattern lives ONCE as a named bash array `BOOT_SUCCESS_MARKERS` at the top of the script — first match wins. Default order: 'Reached target Multi-User System' (systemd canonical), 'Reached target multi-user.target' (older systemd), 'orionx login:' (orionx getty), 'debian login:' (live-build default getty). Modes share the same matcher; no per-mode duplication. This avoids the dual-authority bug where BIOS and UEFI silently diverge on what 'booted' means. Code: `scripts/qemu-boot-test.sh` |
| DEC-PHASE7-021 | 2026-04-28 | [W7-3] KVM-when-available, TCG-fallback, 300s default timeout (covers slowest CI path) | GitHub Actions ubuntu-latest runners since 2024 expose `/dev/kvm` on larger SKUs but not on every job. The harness checks `[ -r /dev/kvm ]` at runtime: if accessible, append `-enable-kvm -cpu host` (typical boot ~30s); otherwise fall back to `-accel tcg -cpu max` (typical boot ~120-270s). Default `--timeout 300` covers the slowest realistic TCG path. Local developers with KVM can pass `--timeout 90` for the fast path. PASS is granted when the success marker appears within `--timeout`; performance gating is INFORMATIONAL only per DEC-PHASE7-004. Workflow stays green on any ubuntu-latest SKU. Code: `scripts/qemu-boot-test.sh`, `.github/workflows/qemu-test.yml` |
| DEC-PHASE7-022 | 2026-04-28 | [W7-3] Pre-declared W7-4 attach contract: --post-boot-script + --keep-running | W7-4 (mesh + Matrix + AppArmor runtime verification) needs to drive commands inside the booted VM. Adding those drivers later inside `qemu-boot-test.sh` would cause scope creep and dual ownership of the QEMU lifecycle. W7-3 instead exposes two extension points NOW so W7-4 can attach without touching the harness: 1) `--post-boot-script <path>` runs a host-side script after marker detection with run-id and serial-log path as args (W7-4 supplies the script that pastes commands via the QEMU monitor or SSHes to a forwarded port), 2) `--keep-running` holds the QEMU process alive after marker detection so an external test driver can attach to the serial monitor or guest agent. Both flags are documented in docs/qemu-boot-test.md as the W7-4 contract. This is anti-drift: the surface W7-4 will use is fixed at W7-3 land time. Code: `scripts/qemu-boot-test.sh`, `docs/qemu-boot-test.md` |
| DEC-PHASE7-024 | 2026-04-28 | [W7-3-enabler] Canonical live-build hook discovery via iso/config/hooks/{live,normal,binary}/; delete iso/hooks/ tree and remove --hook-files workaround | CI run 25475860825 surfaced a latent Phase 1-6 architectural gap (issue #32): the build log shows only 24 hooks executed during lb build — all 24 are live-build BUILT-IN hooks. ZERO project hooks ran. Live-build searches `config/hooks/{normal,live,binary}/` relative to the lb config root (`iso/`). Project hooks lived at `iso/hooks/{live,binary_rootfs,normal}/` — paths live-build does NOT search. The `--hook-files "hooks/normal/0500-bootloader-serial.hook.binary"` workaround in `iso/auto/config` also did not produce an 'Executing hook' line. Phase 6 hardening was therefore structurally validated but never runtime-validated. Option A (git mv into canonical `iso/config/hooks/`) is the chosen end-state. Option B (symlink layer) and Option C (build-time copy in scripts/build-iso.sh) were rejected because each introduces dual-authority drift (Architecture Preservation). The `--hook-files` line is removed because canonical auto-discovery makes it redundant; keeping both would produce dual registration. Bounded supersedence of DEC-PHASE7-023's wiring paragraph (the kernel cmdline `console=` contribution still stands; only the `--hook-files` mechanism is superseded). Code: `iso/config/hooks/**`, `iso/auto/config` |
| DEC-PHASE7-025 | 2026-04-28 | [W7-3-enabler] Test path authority MUST move with the hook files; six tests updated atomically | Five unit tests (`test_filesystem_hardening.sh`, `test_apparmor_profiles.sh`, `test_service_hardening.sh`, `test_iso_serial_console.sh`, `test_phase2_build_system.py`) and one integration test (`test-security-hardening.sh`) hard-code paths under `iso/hooks/*`. Leaving them pointing at the old paths after the file move would silently break `make test-unit` AND create a dual-authority bug where one test asserts a hook 'exists at the canonical path' while another asserts it 'exists at the legacy path' — exactly the failure mode that hid the Phase 6 runtime gap. The reviewer enforces this by running `grep -rn 'iso/hooks/' tests/ scripts/ Makefile .github/` and demanding zero matches. The post-move state of `test_iso_serial_console.sh` also replaces its T4 ('--hook-files wires the binary hook') with a negative assertion that --hook-files is NOT in iso/auto/config — preserving the test's coverage of the wiring authority while inverting its expected truth. Code: `tests/unit/test_*.sh`, `tests/unit/test_phase2_build_system.py`, `tests/integration/test-security-hardening.sh` |
| DEC-PHASE7-026 | 2026-04-28 | [W7-3-enabler] tests/integration/test-iso-hooks-applied.sh as the new runtime-execution authority; CI gates on it before qemu-boot | Structural tests (file exists, content correct) are necessary but not sufficient — that's the gap #32 exposed. The new integration test consumes a build log (BUILD_LOG=<path>) and asserts an `Executing hook config/hooks/.../<name>` line is present for each of the 7 project hooks: 0500-install-external-tools, 0600-filesystem-hardening, 0610-apparmor-setup, 0620-service-hardening (config/hooks/live/), 0100-create-user, 0200-copy-samples (config/hooks/normal/), 0500-bootloader-serial (config/hooks/binary/). The single bash array EXPECTED_HOOKS is the project-wide authority for 'which hooks exist'; any new hook MUST be added there AND to a content unit test (no orphan hooks). `.github/workflows/qemu-test.yml` gains a step BEFORE `qemu-boot-test` that tees the docker build stdout to `tmp/build-iso.log` and invokes this test — so a hook-wiring regression fails at the hook-applied step, NOT misdiagnosed inside qemu-boot. This is the anti-drift control: a future change that breaks hook discovery breaks CI loudly, in the right step, with a per-hook MISS row pointing at exactly which hook is misregistered. Code: `tests/integration/test-iso-hooks-applied.sh` (new), `.github/workflows/qemu-test.yml` |
| DEC-PHASE7-027 | 2026-05-11 | [W7-3 closure] cpio added to Debian builder container apt install | live-build's binary stage uses `cpio` to assemble the initramfs and to write the ISO9660 + El Torito image. The `debian:bullseye` builder container used by `scripts/build-iso.sh` did not include cpio, so the binary stage failed late in the build with a non-obvious `cpio: command not found`. Fix is one-line in the Dockerfile/install step: `apt-get install -y cpio` alongside the existing live-build packages. Verified by CI run 25679831402 on `ed4ffaf` (full build + hook-applied + QEMU BIOS + QEMU UEFI all green). Code: `scripts/build-iso.sh` (builder container apt install). |
| DEC-PHASE7-028 | 2026-05-11 | [W7-3 closure] W7-3 + W7-3-enabler accepted at `ed4ffaf` (CI run 25679831402); polish #36 deferred | The full W7-3 cascade closes: #28/#27 (BIOS timeout, UEFI OVMF path), #30 (serial console + true CI testability — DEC-PHASE7-023..025), #32 (canonical hook wiring — DEC-PHASE7-024), #33 (Phase 5 hook deps), #35 (pre-baked bootloader configs via includes.binary/ — DEC-PHASE7-026 anti-drift control), plus DEC-PHASE7-027 (cpio dep). Issue #36 (`iso/config/includes.binary/` contents not appearing under `binary/` at hook time) is filed as polish, NOT blocking: kernel-side serial works because `--bootappend-live` already propagates `console=ttyS0,115200n8`, and the hook-applied validator gates on hook execution not file appearance. The W7-3 acceptance bar — "ISO boots in QEMU under UEFI and BIOS, surfaces a serial boot-success marker, and project hooks demonstrably executed during build" — is met. W7-4 may proceed against the v2.0.0 hybrid ISO produced at this SHA. Code: CI run 25679831402, commit `ed4ffaf` on `develop`. |
| DEC-PHASE7-029 | 2026-05-11 | [W7-4 split] W7-4 split into W7-4-A (systemd unit install hook) and W7-4-B (runtime verification) | DEC-PHASE7-012 already named F-W71-004 (systemd unit -> squashfs hook) as the W7-4 blocker, but the original W7-4 work item conflated install + verification. They have different scopes, different test authorities, and different risk surfaces. W7-4-A is a build-time hook (live-build chroot hook + integration with `test-iso-hooks-applied.sh`'s EXPECTED_HOOKS array). W7-4-B is a runtime test using the W7-3 attach contract (`--post-boot-script` + `--keep-running` per DEC-PHASE7-022) inside a booted QEMU guest. Splitting also makes W7-4-A reviewable on its own (small, mechanical, structural) and W7-4-B reviewable against an ISO whose services are actually installed. This is the same dual-authority discipline DEC-PHASE7-024 enforced for hook discovery: structural vs runtime are different authorities and need different acceptance gates. The merged W7-4 entry in the W-ID table is replaced by W7-4-A (wave 3) and W7-4-B (wave 3, depends on W7-4-A). Code: `MASTER_PLAN.md` Phase 7 work breakdown. |
| DEC-PHASE7-030 | 2026-05-11 | [W7-4-A] Single chroot hook `0700-install-systemd-units.hook.chroot` is the squashfs authority for orionx units; `0620-service-hardening` MUST sort lexically AFTER it | The proposed binary-stage variant (issue #13 option A) was rejected because (a) the live-build chroot stage is where systemd units canonically live in `/lib/systemd/system/`, (b) the binary stage runs after the squashfs is sealed so `systemctl enable` would not persist, and (c) the existing service-hardening hook already runs in the chroot stage and depends on the units being present. Canonical sequence: 0700-install-systemd-units (cp + enable) runs before 0620-service-hardening (ProtectSystem additions). Note: lexical ordering of `0620` < `0700` would put hardening first; therefore the install hook is renamed/renumbered as `0615-install-systemd-units.hook.chroot` so it sorts between apparmor-setup (0610) and service-hardening (0620). The hook copies `systemd/*.service` and `systemd/*.timer` from a chroot-included staging path (`/usr/share/orionx/systemd/`) into `/lib/systemd/system/` then runs `systemctl enable` per a single explicit array (one authority for "which units autostart"). The EXPECTED_HOOKS array in `tests/integration/test-iso-hooks-applied.sh` MUST gain the new hook so the hook-applied validator gates on its execution. A new unit test `tests/unit/test_systemd_units_hook.sh` is the content authority (asserts hook exists, syntax-clean, lists every unit in `systemd/*.service` plus expected timers, enables only the documented autostart set). Code: `iso/config/hooks/live/0615-install-systemd-units.hook.chroot` (new), `iso/config/includes.chroot/usr/share/orionx/systemd/` (new staging), `tests/integration/test-iso-hooks-applied.sh` (EXPECTED_HOOKS append), `tests/unit/test_systemd_units_hook.sh` (new). |
| DEC-PHASE7-031 | 2026-05-11 | [W7-4-A closure] W7-4-A accepted at `0424b7e` (CI run 25682796113); closes #9 and #13, makes Phase 6 service-hardening operative, enables W7-4-B runtime verification | The W7-4-A acceptance bar — "systemd units installed into `/lib/systemd/system/` during lb chroot stage, autostart units enabled, hook-applied validator gates on the new hook's execution" — is met. CI run 25682796113 on commit `0424b7e` (merge of `feature/phase7-w7-4-a-systemd-units` into `develop`) showed: `Executing hook config/hooks/live/0615-install-systemd-units.hook.chroot` in the lb chroot_hooks pass; 8 unit files installed (`matrix-synapse-orionx.service`, `orionx-mesh-{health,discover}.{service,timer}`, `orionx-mesh-beacon.service`, `orionx-firewall.service`, `orionx-first-boot.service`); 6 autostart units enabled with `multi-user.target.wants` + `timers.target.wants` symlinks present in chroot; completion marker logged; all 8 hooks PASS in `tests/integration/test-iso-hooks-applied.sh` (5 live + 2 normal chroot + 1 binary marker); QEMU BIOS and UEFI both boot green. With units in the squashfs, `0620-service-hardening`'s ProtectSystem injection now operates on real files (Phase 6 hardening is operative end-to-end). W7-4-A closes #9 (systemd units in squashfs) and #13 (chroot-stage vs binary-stage placement). W7-4-B (runtime verification) becomes meaningful next, gated by W7-4-A-bis (#37) for AppArmor packages. Code: `iso/config/hooks/live/0615-install-systemd-units.hook.chroot`, `iso/config/includes.chroot/usr/share/orionx/systemd/`, `tests/integration/test-iso-hooks-applied.sh`, `tests/unit/test_systemd_units_hook.sh`, merge commit `0424b7e` on `develop`. |
| DEC-PHASE7-032 | 2026-05-11 | [W7-4-A-bis] Interleave #37 apparmor-package fix between W7-4-A and W7-4-B; canonical package-list path is the single authority | `lint.yml` remains red on a pre-existing failure (filed as #37) that surfaced once W7-4-A landed: `tests/unit/test_apparmor_profiles.sh` Test Group 8 (Package List) references `iso/package-lists/orionx.list.chroot` — the pre-#33 path that is no longer the live-build search path — and asserts presence of 4 apparmor packages (`apparmor`, `apparmor-utils`, `apparmor-profiles`, `apparmor-profiles-extra`). The canonical path post-#33 is `iso/config/package-lists/orionx.list.chroot`, which currently lacks those 4 packages. Either fix alone leaves the test red and W7-4-B's runtime AppArmor verification ungrounded (packages must actually install during chroot_package-lists for the AppArmor profiles to enforce against real binaries). The W7-4-A-bis slice does both atomically: (a) add the 4 packages to the canonical list; (b) correct the test's Test Group 8 to reference the canonical path. Rejected alternatives: adding apparmor to `docker/Dockerfile*` (out of scope — container builds diverge from ISO authority); modifying `0610-apparmor-setup.hook.chroot` to install packages at hook time (would create a parallel authority alongside `chroot_package-lists`, violating Single Source of Truth); leaving lint.yml red and proceeding to W7-4-B (would mask the regression and fail W7-4-B for the wrong reason). Anti-drift control: the Evaluation Contract requires `grep -rn 'iso/package-lists/' tests/ scripts/ Makefile .github/` to return zero matches after the fix — same shape as DEC-PHASE7-025's "test path moves with the file" discipline. Single-commit revert boundary. Code: `iso/config/package-lists/orionx.list.chroot`, `tests/unit/test_apparmor_profiles.sh`. |
| DEC-PHASE7-033 | 2026-05-11 | [W7-4-A-bis closure] W7-4-A-bis accepted at merge `da66fee` (closes #37); scope amended v1→v2 mid-cycle to bundle three hardening tests in a single landing | The original W7-4-A-bis scope (v1, DEC-PHASE7-032) covered `test_apparmor_profiles.sh` Test Group 8 plus the canonical package-list addition. Reviewer surfaced two additional tests with the same `iso/package-lists/` legacy reference class: `test_firewall_config.sh` (29 assertions) and `tests/integration/test-security-hardening.sh` (38 assertions, one SKIP for runtime-only systemd). Scope was amended v1→v2 to include all three test files in one slice so the legacy reference class collapses to zero in a single revert boundary, matching DEC-PHASE7-025's "test path moves with the file" discipline. Acceptance evidence on `da66fee` (`feature/phase7-w7-4-a-bis-apparmor-pkgs` → develop): `tests/unit/test_apparmor_profiles.sh` 44/0; `tests/unit/test_firewall_config.sh` 29/0; `tests/integration/test-security-hardening.sh` 38/0 plus 1 documented SKIP (runtime AppArmor enforcement — runs in W7-4-B inside QEMU); canonical `iso/config/package-lists/orionx.list.chroot` lists `apparmor`, `apparmor-utils`, `apparmor-profiles`, `apparmor-profiles-extra`. Anti-drift control verified: `grep -rn 'iso/package-lists/' tests/ scripts/ Makefile .github/` returns zero matches at HEAD `da66fee`. lint.yml turned green for the first time since #33. W7-4-A-bis closes #37. Code: `iso/config/package-lists/orionx.list.chroot`, `tests/unit/test_apparmor_profiles.sh`, `tests/unit/test_firewall_config.sh`, `tests/integration/test-security-hardening.sh`, merge commit `da66fee` on `develop`. |
| DEC-PHASE7-034 | 2026-05-11 | [W7-4-A-tris closure] W7-4-A-tris accepted at merge `68b9097` (closes #38); same path-correction class as W7-4-A-bis applied to `iso/config/hooks/binary/` → canonical `iso/config/hooks/normal/` | W7-4-A-bis cleared the `iso/package-lists/` legacy reference class but a second class survived: `tests/unit/test_iso_serial_console.sh` referenced `iso/config/hooks/binary/` for the bootloader serial hook. Post-#32 canonical placement is `iso/config/hooks/normal/0500-bootloader-serial.hook.binary` (the hook is a `.binary` extension running in the live-build `normal` stage, not in a `binary/` directory). Single test file, mechanical fix — but landed as its own slice for a clean revert boundary because the failure manifested in qemu-test.yml (not lint.yml like #37) and proving the test passes on the canonical path is its own validation. Rejected alternative: bundling into W7-4-A-bis post hoc — would have required reopening the merged feature branch and re-running CI; cheaper to land as a sibling slice. Acceptance evidence on `68b9097` (`feature/phase7-w7-4-a-tris-serial-console-test` → develop): `tests/unit/test_iso_serial_console.sh` 31/0 (was 0/31 at start). Anti-drift control verified: `grep -rn 'iso/config/hooks/binary/' tests/ scripts/ Makefile .github/` returns zero matches at HEAD `68b9097`. **All three CI workflows green simultaneously for the first time since the #33 cascade** (lint.yml, qemu-test.yml, e2e-test.yml) — this is the clean Phase 7 baseline that unblocks W7-4-B. W7-4-A-tris closes #38. Code: `tests/unit/test_iso_serial_console.sh`, merge commit `68b9097` on `develop`. |
| DEC-PHASE7-035 | 2026-05-11 | [W7-4-B seeding] In-guest verification channel: systemd oneshot emits serial-console sentinels parsed by host-side post-boot-script; SSH/monitor/guest-agent channels rejected | W7-3's `--post-boot-script` attach contract (DEC-PHASE7-022) hands the post-boot-script only `RUN_ID` and `SERIAL_LOG` — it does NOT provide an SSH/QEMU-monitor handle into the guest. To verify mesh + Matrix + AppArmor enforcement at runtime, W7-4-B must establish a verification channel. Rejected alternatives: (i) SSH via hostfwd (`-netdev user,hostfwd=tcp::2222-:22` + `openssh-server` in the ISO) — adds attack surface, ssh-key wiring, a parallel control plane alongside the existing serial-marker authority, and is not how the production ISO will be operated; (ii) QEMU monitor socket (`-monitor unix:...`) — couples the host-side test to QEMU-internal control plane, breaks if the harness switches to libvirt later; (iii) qemu-guest-agent — adds a daemon dependency to the shipping ISO purely for testing. Chosen approach: an in-guest oneshot systemd unit `orionx-runtime-verify.service` (`After=multi-user.target`, `Type=oneshot`) runs the verification assertions inside the guest and writes sentinel-tagged lines to `/dev/ttyS0` (the serial console, which `qemu-boot-test.sh` already captures to `SERIAL_LOG`). The host-side post-boot-script greps `SERIAL_LOG` for the `ORIONX_VERIFY_BEGIN` / `ORIONX_VERIFY: <name>=<verdict>` / `ORIONX_VERIFY_END: <overall>` sentinel pattern and decides PASS/FAIL. This reuses the existing serial-marker authority (DEC-PHASE7-020) — no new control plane, no additional packages in the shipping ISO, no harness modification. The unit is auto-installed by W7-4-A's `0615-install-systemd-units.hook.chroot` because that hook already iterates `*.service` in the staging dir; W7-4-B places the new unit alongside the existing eight. Anti-drift control: `grep -rn 'qemu-guest-agent\|openssh-server' iso/` must return zero matches at W7-4-B acceptance. Single-slice revert boundary; the verifier can be masked at runtime without reverting any other Phase 7 work. Code (planned): `iso/config/includes.chroot/usr/lib/orionx/runtime-verify.sh`, `iso/config/includes.chroot/usr/share/orionx/systemd/orionx-runtime-verify.service`, `tests/integration/test-w7-4-b-runtime-verify.sh`, `tests/unit/test_runtime_verify_unit.sh`, `.github/workflows/qemu-test.yml` (`--post-boot-script` attach), `docs/qemu-boot-test.md` (sentinel contract documentation). |
| DEC-PHASE7-036 | 2026-05-11 | [W7-4-B partial-acceptance + cascade findings] Mechanism authority accepted at `c8bce0a`; runtime cascade tracked as W7-4-C-a and W7-4-C-b | W7-4-B landed on `develop` at merge `c8bce0a` (`feature/phase7-w7-4-b-runtime-verify`) via CI run 25688890245. The in-guest verification mechanism is proven end-to-end: `orionx-runtime-verify.service` runs `After=multi-user.target`, writes the documented sentinel pattern (`ORIONX_VERIFY_BEGIN` / `ORIONX_VERIFY: <name>=<verdict>` / `ORIONX_VERIFY_END: overall=<verdict>`) to `/dev/ttyS0`, the host-side post-boot-script parses from `SERIAL_LOG`, and both BIOS and UEFI modes produce a parseable artifact in `qemu-artifacts-<run-id>/`. This is the runtime-verification authority the project has been missing since Phase 6 closed structurally (per DEC-PHASE7-024). However, **3 of 5 assertions FAIL** on the first runtime evidence: `mesh_iface_up=FAIL`, `mesh_beacon_active=FAIL`, `apparmor_enforcing=FAIL`; `mesh_discover_enabled=PASS` (timer is enabled via 0615 hook regardless of whether wg0 is up), `matrix_synapse_state=PASS` (verifier accepts `active OR activating` AND unit-installed state). Root cause analysis from the pre-sentinel boot log: a first-boot-wizard cascade — `orionx-first-boot.service` fails (the `--non-interactive` CLI flag is honored but the systemd unit binds `StandardInput=tty TTYPath=/dev/tty1` which is unreliable in headless QEMU; wg-key generation may also need a non-interactive path) → `/etc/wireguard/wg0.conf` is never generated → `wg-quick@wg0.service` fails → `wg0` interface absent → `mesh_iface_up=FAIL` → `orionx-mesh-beacon` fails by dependency. The `apparmor_enforcing=FAIL` is a separate, cascade-independent finding: AppArmor profiles do not end up in enforced mode despite `apparmor.service` being enabled by the 0610 hook — the load mechanism in the hook is incomplete (today only `systemctl enable apparmor` + a kernel-cmdline addition; no explicit `apparmor_parser -r` per profile). **Partial-acceptance rationale**: rejecting W7-4-B and reopening the slice to chase 3 independent runtime gaps would conflate scopes and produce a giant landing with mixed revert risk. Accepting the mechanism authority NOW (the sentinel-format, verifier-script-as-runtime-truth, host-side-parser-as-host-truth contract is proven) and tracking the runtime gaps as named follow-up slices (W7-4-C-a apparmor, W7-4-C-b first-boot non-interactive) gives each gap its own revert boundary and its own evaluation contract. The W7-4-B Evaluation Contract's `ready_for_guardian` bar (END=pass for both modes) was NOT met by `c8bce0a`; that bar moves to the W7-4-C-b closure (where mesh and overall=pass land together). Single-slice rule preserved: W7-4-B is the mechanism slice, W7-4-C-a is the apparmor slice, W7-4-C-b is the mesh/first-boot slice. Anti-drift control: the W7-4-B verifier remains the SINGLE authority for runtime assertion truth — neither W7-4-C-a nor W7-4-C-b adds a parallel verifier. Code: merge commit `c8bce0a` on `develop`; CI run 25688890245 artifacts (`qemu-artifacts-25688890245/serial-{bios,uefi}.log`). |
| DEC-PHASE7-037 | 2026-05-11 | [W7-4-C-a scope] AppArmor profile load fix — fix the mechanism, not the assertion | W7-4-B's `apparmor_enforcing=FAIL` is a load-mechanism gap. The `0610-apparmor-setup.hook.chroot` today does only `systemctl enable apparmor` + a kernel-cmdline parameter; it relies on apparmor.service auto-discovery to load profiles from `/etc/apparmor.d/`. The five Orion-X profiles (`usr.bin.synapse`, `usr.bin.tshark`, `usr.bin.bulk_extractor`, `usr.bin.volatility3`, `usr.sbin.wg`) end up not enforcing in the booted guest. Candidate root causes (the implementer chooses one via the Investigation gate in the W7-4-C-a Scope Manifest): (A) the hook needs explicit `apparmor_parser -r /etc/apparmor.d/<profile>` invocations to load profiles deterministically — the canonical fix shape since it makes the load mechanism observable in the build log and stops relying on apparmor.service ordering relative to other sysinit units; (B) profile-binary-path mismatches — e.g. `usr.bin.volatility3` references `/usr/bin/vol` but the Debian volatility3 package installs to `/usr/bin/vol.py`, so the profile loads but never attaches to a running binary and aa-status `--enforced` doesn't list it; `usr.sbin.wg` references `/usr/bin/wg` despite the filename suggesting `/usr/sbin/wg` — verify against the actual install; (C) hook ordering relative to apparmor.service activation; (D) profile syntax issue blocking `apparmor_parser`. **Rejected alternatives**: (i) relaxing the W7-4-B `apparmor_enforcing` assertion threshold (e.g. 'enforce >=1 profile' instead of '>=5') — that masks the gap and breaks DEC-SEC-002's "AppArmor enforcing" Phase 6 acceptance criterion; (ii) loading profiles in `complain` mode and counting that as PASS — debugging-only; enforce is the deliverable; (iii) removing AppArmor profiles to make aa-status report 'all enforced' — supersedes DEC-SEC-002 without authority; (iv) moving profile load logic into a new hook (e.g. `0611-apparmor-load.hook.chroot`) — creates dual authority alongside 0610. **Scope discipline**: the implementer must NOT touch mesh authorities, the W7-4-B verifier (read-only against apparmor state), `scripts/qemu-boot-test.sh` (frozen), or add new control planes (`qemu-guest-agent`, `openssh-server`). The W7-4-C-a acceptance bar is narrowly the apparmor sentinel transitioning FAIL→PASS in both BIOS and UEFI serial logs; the overall `ORIONX_VERIFY_END: overall=fail` is EXPECTED in W7-4-C-a CI artifacts because mesh assertions remain FAIL pending W7-4-C-b. The closure pass for W7-4-C-a will append the chosen root-cause class (A/B/C/D) into this decision entry so future implementers see what was actually wrong. Code (planned): `iso/config/hooks/live/0610-apparmor-setup.hook.chroot`, possibly `iso/config/includes.chroot/etc/apparmor.d/<profile>` for binary-path corrections, `tests/unit/test_apparmor_profiles.sh` for the load-mechanism Test Group, and a narrow gate addition in `tests/integration/test-w7-4-b-runtime-verify.sh` only if needed to distinguish per-assertion PASS from overall PASS for the duration of the C-a/C-b arc. |
| DEC-PHASE7-038 | 2026-05-11 | [W7-4-C-b scope] First-boot non-interactive mode for CI — bounded supersedence of DEC-SEC-003 | W7-4-B's `mesh_iface_up=FAIL` and `mesh_beacon_active=FAIL` are the runtime evidence that the first-boot wizard (Phase 6, DEC-SEC-003) does not run cleanly under headless QEMU boot, so `/etc/wireguard/wg0.conf` is never generated, `wg-quick@wg0.service` fails, and the mesh cascade collapses. The systemd unit `systemd/orionx-first-boot.service` invokes `/opt/orionx/scripts/security/first-boot-wizard.sh --non-interactive` — the script's `--non-interactive` flag (line 87 of the script) does exist and does cause `read` prompts to be skipped, but the unit's `StandardInput=tty / StandardOutput=tty / StandardError=tty / TTYPath=/dev/tty1` binding is unreliable in headless QEMU and the wg-key generation path may still depend on interactive confirmation. **Chosen direction (subject to refinement after W7-4-C-a lands)**: extend the first-boot authority to recognize a CI/headless code path that does not require tty1 and that generates a deterministic test wg0 config without user input. The implementer chooses the channel — env-var `FIRST_BOOT_NONINTERACTIVE=1` via `EnvironmentFile=`, CLI flag `--auto-defaults` beyond the existing `--non-interactive`, or pre-seeded `/etc/orionx/first-boot.conf` — in a refined W7-4-C-b planning pass. **Rejected alternatives**: (i) creating a separate `orionx-first-boot-ci.service` that runs alongside the production unit — dual authority for the same concern; (ii) generating wg0.conf in a new hook at build time — moves first-boot concerns out of the wizard authority into the build authority, breaks DEC-SEC-003; (iii) skipping wg0 startup in CI by masking `wg-quick@wg0.service` — masks the test we are trying to run; (iv) adding `qemu-guest-agent` or `openssh-server` to drive the wizard from the host — rejected channels per DEC-PHASE7-035. **Bounded supersedence shape**: DEC-SEC-003 ("First-boot wizard as shell script + systemd oneshot") remains the canonical authority for the first-boot concern. W7-4-C-b extends it with a documented non-interactive input channel for CI/headless boot semantics. The Phase 6 "first-boot wizard runs once via systemd" property is preserved (the `ConditionPathExists=!/var/lib/orionx/.first-boot-done` guard remains; only the input channel changes when the env-var or seeded config is present). Production interactive boot semantics are unchanged. **Sequencing**: W7-4-C-b is PENDING until W7-4-C-a lands so the apparmor signal is decoupled from the mesh signal in CI artifacts — otherwise the implementer cannot tell whether mesh fixes worked or were masked by the apparmor failure. **End-of-arc state**: `ORIONX_VERIFY_END: overall=pass` in both BIOS and UEFI serial logs in a single CI run on `develop`; this is the W7-4 acceptance bar that DEC-PHASE7-036 deferred from the original W7-4-B contract. Code (planned, subject to refinement): `systemd/orionx-first-boot.service` (relax tty binding for non-interactive path), `scripts/security/first-boot-wizard.sh` (add CI-mode behavior for wg-key generation and config emission beyond the existing `--non-interactive` flag's `read` skips), possibly a new `iso/config/includes.chroot/etc/default/orionx-first-boot` file for env-var configuration. |
| DEC-PHASE7-039 | 2026-05-13 | [W7-4-B FULL acceptance via loop-exit] Mechanism is the acceptance bar; runtime gaps consolidated under #39 | After the cascade-fix arc seeded as W7-4-C-a + W7-4-C-b began to surface deeper Phase 6 design questions (non-interactive first-boot under headless QEMU; AppArmor load mechanism under headless boot; binary-path mismatches that intersect both) the planner exited the cascade-fix loop. W7-4-B is now FULLY ACCEPTED on the basis that its **mechanism** (in-guest oneshot emitting `ORIONX_VERIFY_*` sentinels on `/dev/ttyS0`; host-side post-boot-script parser; reuse of the existing serial-marker authority per DEC-PHASE7-020 — see DEC-PHASE7-035) is the single canonical runtime-verification authority the project required and is operative end-to-end. The **runtime content** that the mechanism surfaces (which assertions PASS in which boot environment) is a separate authority tracked under issue #39 ("Phase 7 closure: consolidated runtime gaps") and will be settled in a Phase 8 design pass, not in Phase 7 cleanup slices. Anti-drift control: the loop-exit slice (merge `c6c42c1`) adds `continue-on-error: true` to the W7-4-B step in `.github/workflows/qemu-test.yml` so the step still runs, still emits sentinels, still uploads `qemu-artifacts-<run-id>/serial-{bios,uefi}.log`, but does not fail the workflow. **Removing `continue-on-error: true` requires a planner DEC that explicitly closes #39 first** — that is the boundary that prevents this from becoming silent skip. Note: the loop-exit CI run showed the W7-4-B step in a TIMEOUT mode (runtime-verify.sh hung before emitting `ORIONX_VERIFY_END`); this is a new diagnostic data point added to #39 and does not change the acceptance basis. Code: merge commits `c8bce0a` (mechanism) and `c6c42c1` (loop-exit) on `develop`; issue #39 tracker. |
| DEC-PHASE7-040 | 2026-05-13 | [W7-4-C-a / W7-4-C-b abandonment] Cascade-fix slices folded into issue #39; non-interactive first-boot is a Phase 8 design question | Both W7-4-C-a (AppArmor profile load fix) and W7-4-C-b (first-boot non-interactive for CI) are ABANDONED inside Phase 7. The seeded Scope Manifests and Evaluation Contracts (DEC-PHASE7-037, DEC-PHASE7-038) remain valid reference material — they document the investigation paths and the candidate root-cause classes — but the slices are not scheduled inside Phase 7 because: (a) non-interactive first-boot under headless QEMU is a DEC-SEC-003 bounded-supersedence question that belongs in a Phase 8 design pass, not a reactive Phase 7 patch; (b) AppArmor profile enforcement under headless QEMU intersects the same design surface (which binaries are present at boot, which profiles attach, which load mechanism the hook uses) and benefits from being considered together with the first-boot question; (c) the cascade-fix loop was consuming Bullseye-EOL clock without converging — each fix slice surfaced a new cascade. **Rejected alternative**: continuing the cascade-fix arc serially would have produced multiple small slices each with its own incomplete Scope Manifest, multiple revert boundaries with mixed risk, and a Phase 7 timeline that drifts past the Bullseye EOL window. **Consolidation rationale**: a single tracker (#39) preserves the diagnostic surface (the W7-4-B step still emits sentinels on every CI run; the runtime FAIL signals are visible in artifacts), makes the open work visible in one place, and lets Phase 7 proceed to W7-5 (performance) and W7-6 (failure modes) in parallel rather than serial with cascade cleanup. **Cross-references**: issue #39 (consolidated runtime gaps tracker); DEC-PHASE7-035 (sentinel mechanism authority — preserved); DEC-PHASE7-036 (W7-4-B partial-acceptance — superseded by DEC-PHASE7-039 FULL acceptance); DEC-PHASE7-037 (W7-4-C-a Scope reference material); DEC-PHASE7-038 (W7-4-C-b bounded supersedence framing — preserved as Phase 8 design input). Code: issue #39 tracker; W-ID table updates marking W7-4-C-a and W7-4-C-b ABANDONED 2026-05-13. |
| DEC-PHASE7-041 | 2026-05-13 | [META] When each fix slice surfaces a new cascade, consolidate under a single tracker and proceed in parallel rather than serial | General principle, not Phase 7-specific, observed during the W7-4-B → W7-4-C-a → W7-4-C-b cascade-fix arc. Pattern recognition: when a slice meant to close a partial-acceptance surfaces a deeper question that itself decomposes into more questions, the loop has reached the wrong scale — the problem class is bigger than the slice scope. **Symptoms**: (a) each fix slice's investigation gate produces multiple candidate root-cause classes, each with its own design decisions; (b) the slice scope grows to touch authorities outside the original feature (DEC-SEC-003 first-boot, DEC-SEC-002 AppArmor, DEC-MESH-* mesh runtime); (c) the seeded Scope Manifest's "rollback boundary" is tested by the second cascade fix, then the third; (d) the EOL/release clock advances faster than convergence. **Right move**: stop the serial-cascade arc, consolidate open runtime content under a single tracker, preserve the diagnostic surface (don't mask the failure signals — keep them visible in artifacts), and route the design question to the next planned design pass. **Anti-drift control**: when consolidating, the diagnostic surface MUST remain visible (artifacts uploaded, sentinels emitted, step runs) — only the workflow gate is relaxed. Removing the diagnostic surface (e.g. removing the W7-4-B step entirely) would be silent skip; keeping it with `continue-on-error: true` is loud-but-non-blocking. **Future Implementer guidance**: if a planning dispatch arrives at this principle in a different phase or feature context, prefer this pattern over continuing a cascade-fix arc. Cite this DEC when consolidating. Code: this dogma applies project-wide; the operative example is W7-4-B FULL acceptance + W7-4-C-a/b abandonment under issue #39. |
| DEC-PHASE7-043 | 2026-05-14 | [W7-8 / Phase 7 closure] Phase 7 (Integration Testing) closed on `develop` at `05b98a3` with all three CI workflows green; Phase 8 (Release v2.0.0) activated | Acceptance basis: all three CI workflows green simultaneously on `develop` at `05b98a3` (Lint & Test, QEMU Boot Test, E2E Scenario Test) after the W7-6 failure-mode recovery slice landed (Option D config-layer assertion of systemd `Restart=` directives across 8 Orion units). Seven implementation slices accepted in arc order: W7-1, W7-3, W7-4-A (`0424b7e`, closes #9 #13), W7-4-A-bis (`da66fee`, closes #37), W7-4-A-tris (`68b9097`, closes #38), W7-4-B (`c8bce0a` — mechanism FULL ACCEPTED per DEC-PHASE7-039), W7-5 (`8bcded0` — `iso_size` PASS host-side per DEC-PHASE7-042), W7-6 (`05b98a3`). Two cascade-consolidation exit slices applied (W7-4-B-exit at `c6c42c1`, W7-5-exit at `ba3e0d1`) confirm DEC-PHASE7-041 as durable operational discipline rather than a one-off escape hatch. W7-4-C-a and W7-4-C-b ABANDONED per DEC-PHASE7-040; their seeded Scope Manifests remain valid reference material for a future #39 closure slice in Phase 8 design. W7-7 (physical USB boot) DEFERRED to operator attestation as a Phase 8 release gate per DEC-PHASE7-005 (`approve` gate was always human-in-the-loop, never a CI-runnable slice; the same hybrid ISO is already proven bootable in QEMU under BIOS and UEFI via W7-3). Open trackers carried to Phase 8 design pass: #36 (Phase 7 polish, non-blocking), #39 (W7-4-B runtime gaps — mesh cascade + AppArmor enforcement under headless QEMU), #40 (W7-5 in-guest boot_time/idle_ram measurement reliability), #41 (runtime-control-plane hygiene: `decode_work_item_contract` rejects `workflow_id` in `evaluation_json` — filed at closure 2026-05-14, non-blocking), plus older #32, #33, #23 (none blocking). The Phase 7 acceptance bar — "Full E2E scenario completes. ISO boots UEFI + BIOS. All failure scenarios recover." — is met in the canonical-authority sense: the E2E scenario passes (Docker), the ISO boots under both QEMU firmware paths (W7-3), the runtime-verification mechanism is operative (W7-4-B), the perf-measurement mechanism is operative with `iso_size` verified (W7-5), and the failure-recovery configuration is asserted across all long-running units (W7-6). The runtime-content gaps that the W7-4-B and W7-5 mechanisms surface are tracked as Phase 8 design pass inputs under #39 and #40 rather than as Phase 7 closure blockers — this is the consistent application of the single-authority discipline that runs throughout Phase 7 (the mechanism is the acceptance bar; the runtime content is a separate authority). **Phase 8 activation**: Phase 8 (Release v2.0.0) is now ACTIVE — release-gate work (version bump, documentation audit, release artifacts, GitHub Release with ISO attached, W7-7 operator attestation) begins in a fresh planning slice; the closure scope of W7-8 is deliberately limited to recording Phase 7 acceptance and activating Phase 8, not to producing detailed Phase 8 implementation content. Code: merge commit `05b98a3` on `develop` (W7-6); CI run on `05b98a3` showing all three workflows green; this Decision Log entry; the W-ID table updates (W7-6 ACCEPTED, W7-7 DEFERRED, W7-8 IN PROGRESS); the Phase 7 closure narrative (above) and Phase 8 status header (now Active). |
| DEC-PHASE8-001 | 2026-05-14 | [PHASE 8 START / W8-1 seeding] Phase 8 (Release v2.0.0) activated; first slice is version-string finalization to `v2.0.0-rc1`, NOT `v2.0.0` | Phase 8 begins one slice at a time per DEC-PHASE7-041 cascade-consolidation discipline applied preemptively — detailed Scope Manifests and Evaluation Contracts are seeded at planner-dispatch time, not speculatively up-front, because each Phase 8 slice may surface downstream design questions (release-tagging authority, GPG signing key authority, GitHub Release authorship) that benefit from full evidence from prior slices. **First slice (W8-1) rationale**: live dual-authority bug in the tree at Phase 7 closure — `scripts/build-iso.sh` (canonical version authority per DEC-PHASE7-002) and `iso/auto/config` already default to `v2.0.0-rc1`, but `Dockerfile` (LABEL + MOTD + bashrc literals) and `README.md` (headline + dd-command example) still say `v2.0.0-dev`. A future implementer reading either surface gets a different version. W8-1 collapses the surfaces to one canonical string and matches the build-iso authority. **`v2.0.0-rc1` chosen over `v2.0.0`**: (a) the build-iso authority already defaults to `rc1` per DEC-PHASE7-002, so propagating `v2.0.0-rc1` preserves that decision; bumping to `v2.0.0` would supersede DEC-PHASE7-002 without a new DEC; (b) the actual `v2.0.0` git tag belongs at W8-7 after W7-7 operator attestation, signed-artifact pipeline (W8-4), and finalized release notes (W8-5) are in place — pre-bumping to `v2.0.0` now would claim release-candidate readiness while #39/#40 runtime gaps remain open and W7-7 attestation is pending; (c) `rc1` is the semver-conventional first release-candidate label and matches the artifact's actual state. **Rejected alternatives**: (i) bumping straight to `v2.0.0` now — claims readiness ahead of W7-7 + signed-artifact pipeline; supersedes DEC-PHASE7-002 without a new authority decision; (ii) seeding all six Phase 8 W-IDs with full Scope Manifests up-front — re-introduces the speculative-planning anti-pattern that DEC-PHASE7-041 abandons; (iii) starting with CHANGELOG generation (W8-2) — would reference version literals that have not yet been finalized to one canonical string; W8-1 must land first so W8-2 has a single version target. **Already-accepted Phase 8 prep work**: two operator-driven landings during the Phase 7 closure window are folded into Phase 8 as already-accepted prep, NOT seeded as W-IDs requiring further work: (a) **W7-7 enabler `b411c47`** — `.github/workflows/qemu-test.yml` uploads the built ISO as artifact `orionx-iso-<run_id>` so the operator can `gh run download` and dd-write to USB without a separate local build (operator track enablement plumbing, not the W7-7 attestation itself); (b) **W8 Dockerfile cleanup `44c7b25`** — removed three apt-unavailable packages from `Dockerfile` (same drift class as Phase 7 #33 — release-readiness hygiene). The pattern (apt index drift between development and release tagging) is one Phase 8 should watch for in parallel surfaces (ISO chroot list, Dockerfile, docker-compose images). **Phase 8 W-ID numbering**: DEC-PHASE8-NNN sequence is independent of DEC-PHASE7-001..043; the next entry will be DEC-PHASE8-002 at W8-1 closure (or an amendment to this entry recording the closure SHA + CI run id + per-surface diff summary, mirroring DEC-PHASE7-031/033/034 closure-DEC shape). Code: `MASTER_PLAN.md` Phase 8 section (this slice's plan-edit); `tmp/scope-wi-w8-1-version-rc1.json`; `tmp/eval-wi-w8-1-version-rc1.json`; W-ID table additions (W8-1 IN PROGRESS, W8-2..W8-7 sketch). |
| DEC-PHASE8-002 | 2026-05-14 | [W8-1 CLOSURE + PHASE 8 CONSOLIDATION] W8-1 accepted at merge `ee5861b`; pre-bundle W8-2..W8-6 consolidated into two implementer slices `wi-w8-finish-A` (docs bundle) and `wi-w8-finish-B` (release pipeline bundle); W7-7 and W8-7 carved out as remaining hard human boundaries | **Two decisions in one DEC entry, both flowing from W8-1 acceptance.** **Part 1 — W8-1 closure record (closure-DEC amendment shape mirroring DEC-PHASE7-031/033/034)**: W8-1 landed at merge `ee5861b` on `develop` 2026-05-14 (`feature/phase8-w8-1-version-rc1`, feature HEAD `f151315`). Per-surface diff: `Dockerfile` (3 lines: LABEL + MOTD + bashrc literals updated from `v2.0.0-dev` to `v2.0.0-rc1`; LABEL value `"2.0.0-rc1"` omits leading `v` per Docker convention), `README.md` (3 lines: headline + dd-command example updated). `scripts/build-iso.sh` and `iso/auto/config` unchanged per scope manifest (canonical authority preserved per DEC-PHASE7-002). Reviewer: 0 findings. Tests: `tests/unit/test_build_iso.sh` 41/41 pass on HEAD. Anti-drift check post-merge: `grep -rn 'v2\.0\.0-dev' Dockerfile README.md` returns zero matches. **Part 2 — Phase 8 finish consolidation**: Post-W8-1, the remaining pre-bundle Phase 8 W-IDs (W8-2 CHANGELOG, W8-3 Documentation audit, W8-4 release artifact pipeline, W8-5 GitHub Release scaffolding, W8-6 workflow rename) are reconsidered through the DEC-PHASE7-041 cascade-consolidation lens. The pre-bundle sequencing W8-2 → W8-3 → W8-4 → W8-5 → W8-6 has no architectural meaning: (a) W8-2 (CHANGELOG generation from git log + DEC table) and W8-3 (Documentation audit of README.md / docs/User_Guide.md) share the identical docs-only forbidden-paths surface; both are mechanical, both are pure-docs, both touch the same operator-facing surfaces; they would land back-to-back with effectively identical Scope Manifests. (b) W8-4 (SHA-256/SHA-512 checksums + GPG signing CI plumbing), W8-5 (GitHub Release draft scaffolding), and W8-6 (runtime workflow rename `phase7-integration` → `phase8-release`) all touch the CI surface or the runtime control plane, none touch source code, all share overlapping forbidden-paths surfaces (Dockerfile/scripts/iso/systemd/tests/MASTER_PLAN.md/etc. all forbidden); they too would land back-to-back. Consolidating each natural cluster into one bundle eliminates artificial slice boundaries while preserving the planner's per-slice contract discipline (each bundle has its own Scope Manifest + Evaluation Contract written before implementer dispatch). **The two resulting slices**: `wi-w8-finish-A` (docs bundle: W8-2 + W8-3, in_progress, Scope Manifest in `tmp/scope-wi-w8-finish-A.json`, Evaluation Contract in `tmp/eval-wi-w8-finish-A.json`); `wi-w8-finish-B` (release pipeline bundle: W8-4 + W8-5 + W8-6, pending until wi-w8-finish-A lands, Scope Manifest in `tmp/scope-wi-w8-finish-B.json`, Evaluation Contract in `tmp/eval-wi-w8-finish-B.json`). The pre-bundle W8-2..W8-6 rows remain in the W-ID table for traceability but their Status column marks them CONSOLIDATED with a pointer to the consolidated parent. **W7-7 and W8-7 carve-out (the remaining hard human boundaries)**: W7-7 (physical USB boot attestation) remains operator-track per DEC-PHASE7-005 — no software slice can perform it; the artifact channel is wi-w8-finish-B's DRAFT-release ISO once landed, with the W7-7 enabler `b411c47` qemu-test.yml ISO upload as the current channel. W8-7 (final v2.0.0 retag + GitHub Release publish) remains an explicit `approve` gate per DEC-PHASE7-005, with operator GPG key provisioning (`secrets.GPG_PRIVATE_KEY` + `secrets.GPG_PASSPHRASE`) as a paired prerequisite — also a hard human boundary because committing a private key or generating one in-workflow would defeat signature verification. The release.yml workflow handles the GPG-signing step with `continue-on-error: true` until the operator provisions the key (same `continue-on-error: true` cascade-consolidation discipline DEC-PHASE7-041 established for W7-4-B-exit and W7-5-exit — keep the diagnostic surface visible, do not block the workflow on an unresolved upstream gate). **Rejected alternatives**: (i) seeding W8-2..W8-6 as five separate slices — re-introduces the speculative-planning anti-pattern DEC-PHASE7-041 abandons; each slice's scope manifest would duplicate the previous one's; the sequencing has no architectural meaning. (ii) Consolidating all five remaining W-IDs into ONE bundle — couples docs work (which only requires markdown editing tools) with CI/runtime work (which requires `cc-policy` runtime access and `workflow_dispatch` CI verification); two separable forbidden-paths surfaces are present so the bundling boundary is real, not artificial. (iii) Treating W8-6 (workflow rename) as a separate `XS` slice that runs anywhere in the sequence — the rename is most naturally paired with the release-pipeline bundle because both are runtime-control-plane surfaces and both close out the Phase 7 → Phase 8 identity transition; pairing them in one slice avoids a third small slice for one runtime command. (iv) Implementing GPG-signing CI plumbing as a deferred follow-up to W8-finish-B — leaves the release pipeline incomplete and creates a fourth Phase 8 slice that has no architectural distinction from W8-finish-B's scope; better to wire the signing step now with `continue-on-error: true` so the operator's later key provisioning is the only remaining action. **Critical path (revised post-consolidation)**: W8-1 (ACCEPTED) → wi-w8-finish-A (docs, in_progress) → wi-w8-finish-B (release pipeline, pending) → W8-7 (approve gate, hard human). W7-7 runs in parallel on operator hardware; its acceptance is a prerequisite to W8-7 publish but does not block the software track. **Meta-confirmation of DEC-PHASE7-041**: this is the third operative instance of cascade-consolidation discipline (after W7-4-B-exit per DEC-PHASE7-039 and W7-5-exit per DEC-PHASE7-042; the W7-8 Phase 7 closure narrative cites two instances; this Phase 8 consolidation is the third). The pattern is now durable operational discipline applied preemptively to plan a phase's remaining slices, not only retrospectively to exit cascades. Code: `MASTER_PLAN.md` Phase 8 section (W-ID table updates: W8-1 ACCEPTED, W8-2..W8-6 CONSOLIDATED, wi-w8-finish-A IN PROGRESS, wi-w8-finish-B PENDING, W7-7 / W8-7 hard human boundaries; this DEC entry); `tmp/scope-wi-w8-finish-A.json`; `tmp/eval-wi-w8-finish-A.json`; `tmp/scope-wi-w8-finish-B.json`; `tmp/eval-wi-w8-finish-B.json`. |
| DEC-PHASE8-003 | 2026-05-14 | [PHASE 8 SOFTWARE-TRACK CLOSURE] wi-w8-finish-A + wi-w8-finish-B accepted on `develop` at `586fa05` + `0b8f1b0`; Phase 8 software track complete; W7-7 + W8-7 + #42 carved out as terminal boundaries / non-blocking follow-ups | **Acceptance basis (software track only — operator track W7-7 and operator publish W8-7 remain hard human boundaries per DEC-PHASE7-005, which is how the goal contract framed them from inception).** Five implementation slices have landed clean on `develop`: (a) W8-1 `ee5861b` version-string finalization to `v2.0.0-rc1` (per DEC-PHASE8-001/002); (b) wi-w8-finish-A `586fa05` docs bundle — `CHANGELOG.md` curated for `## [v2.0.0-rc1]` covering Phases 1–7 + W8-1 with W-ID and DEC cross-references, `docs/User_Guide.md` audited end-to-end with version literals propagated `v1.5.5` → `v2.0.0-rc1` (feature HEAD `a5e0776`, feature branch `feature/phase8-finish-a-docs`); (c) wi-w8-finish-B `0b8f1b0` release pipeline bundle — `.github/workflows/release.yml` triggering on `v*` tag push + `workflow_dispatch`, building the ISO via the canonical `scripts/build-iso.sh` authority, emitting SHA-256 + SHA-512 checksums, signing with `secrets.GPG_PRIVATE_KEY` + `secrets.GPG_PASSPHRASE` (with `continue-on-error: true` until operator provisioning per DEC-PHASE8-002 / DEC-PHASE7-041 cascade-consolidation discipline), creating a DRAFT GitHub Release with notes sourced from `CHANGELOG.md`; `scripts/release/extract-release-notes.sh` helper; `docs/release-process.md` operator runbook (feature HEAD `06f06a7`, feature branch `feature/phase8-finish-b-release-pipeline`). Plus two operator-driven Phase 8 prep landings already folded in per DEC-PHASE8-001: (d) W7-7 enabler `b411c47` qemu-test.yml ISO artifact upload; (e) `44c7b25` Dockerfile apt-unavailable package cleanup. **Software-track delivered**: (i) single canonical version string `v2.0.0-rc1` across all active-source surfaces; (ii) live, curated CHANGELOG.md sourced from W-ID + DEC history; (iii) audited operator documentation (User_Guide.md) that matches the v2.0.0-rc1 ISO behavior; (iv) tag-driven release pipeline producing DRAFT GitHub Releases with ISO + checksums + (optional) GPG signatures and CHANGELOG-sourced release notes; (v) operator runbook documenting the cut-rc1 / promote-to-final sequence. **Remaining items, both HARD HUMAN BOUNDARIES (no software slice can close them — this is how the goal contract framed them at Phase 7 closure)**: **W7-7** (physical USB boot attestation, operator-driven, `approve` gate per DEC-PHASE7-005) — artifact channels are the qemu-test.yml CI artifact `orionx-iso-<run_id>` per `b411c47` and (once a tag is cut) the DRAFT release.yml ISO + checksums per `0b8f1b0`; operator dd-writes, boots on real hardware, validates the User_Guide walkthrough end-to-end, signs off; and **W8-7** (final `v2.0.0` retag + DRAFT → public publish flip, `approve` gate per DEC-PHASE7-005) — operator runs the sequence in `docs/release-process.md`: cut rc1 if not already, perform W7-7, provision `secrets.GPG_PRIVATE_KEY` + `secrets.GPG_PASSPHRASE`, version-bump or retag to `v2.0.0`, re-run release.yml on the new tag, `gh release edit v2.0.0 --draft=false`. **Runtime hygiene findings tracked separately**: (i) **#41** (`decode_work_item_contract` rejects `workflow_id` in `evaluation_json`) — pre-existing, tracked at Phase 7 closure per DEC-PHASE7-043; non-blocking; (ii) **#42** (`cc-policy workflow bind` FK constraint failure when rebinding an existing worktree) — newly filed this session; impact is the W8-6 workflow rename `phase7-integration` → `phase8-release` (the runtime `workflow_id` remains `phase7-integration` even though Phase 8 software track is complete); decorative drift only, no software functionality impact, no operator-action impact, no release.yml / GitHub Actions / source-tree impact. W8-6 row in the W-ID table is updated to PARTIAL with the issue-#42 pointer. Both findings are Phase 8 design pass / runtime cleanup work, NOT release-blockers. **Rejected alternatives**: (i) declaring `PLAN_VERDICT: goal_complete` only after W7-7 + W8-7 land — these are explicit `approve` gates per the goal contract; agents cannot close them; treating them as blockers would mean Phase 8 software-track never reports complete, which is structurally wrong; (ii) closing #42 inside Phase 8 software-track as a release-blocker — the bug is in the runtime control plane (`cc-policy workflow bind` FK), not in the release pipeline; release.yml does not consult the runtime workflow identity; (iii) running the workflow rename manually via direct SQLite mutation as a workaround — bypasses the runtime authority and creates a new dual-authority surface in an area the constitution explicitly forbids per CLAUDE.md "Architecture Preservation". **Workflow-identity drift accepted as informational**: per the Phase 8 narrative addition, the runtime `workflow_id` is still `phase7-integration` even though Phase 8 software track is complete. The MASTER_PLAN.md `### Phase 8` section is the canonical phase-status authority; the `cc-policy context role` runtime state is a coordination-layer cache that resolves when #42 lands. **Critical path post-closure**: (operator) `git tag -a v2.0.0-rc1 && git push` → release.yml DRAFT emission → (operator) W7-7 hardware attestation in parallel → (operator) GPG key provisioning → (operator) W8-7 final retag + publish → planner records DEC-PHASE8-004 (or successor) at publish. **The software-track planner role is terminal at this DEC entry**: no further implementation slice is required to reach the `v2.0.0` publish; the remaining path is operator action gated by `approve` per DEC-PHASE7-005. Code: merge commits `586fa05` (wi-w8-finish-A) and `0b8f1b0` (wi-w8-finish-B) on `develop`; feature HEADs `a5e0776` and `06f06a7`; this DEC entry; W-ID table updates (wi-w8-finish-A ACCEPTED, wi-w8-finish-B ACCEPTED, W8-6 PARTIAL with #42 pointer, W7-7 DEFERRED unchanged, W8-7 PENDING); Phase 8 software-track closure narrative (MASTER_PLAN.md `### Phase 8` section addition); workflow-identity drift note (same section); operator-facing handoff summary (same section); issues #41 and #42 trackers. |
| DEC-PHASE8-004 | 2026-05-15 | [PHASE 8 REOPEN / W7-7 CRITICAL FINDING] DEC-PHASE8-003 SUPERSEDED; ISO missing application layer (#43); content-presence-test gate established as a release-readiness invariant going forward | **DEC-PHASE8-003 (Phase 8 software-track closure on 2026-05-14) is SUPERSEDED.** Operator hardware attestation on 2026-05-15 (W7-7) found that the ISO produced by the current build pipeline is MISSING the entire Orion-X application layer: no `/opt/orionx/scripts/` (artifact-analyzer.py, mesh CLI, setup-matrix.sh, storyboard-gen.py, toggle-theme.sh, run-lynis.sh, download-samples.sh, setup-wireguard.sh), no `/opt/orionx/theme/` (wallpapers, GTK theme, login branding), no `/opt/orionx/data/` (Phase 5 sample-data tree), no `/usr/share/doc/orionx/` (User_Guide.md and other docs), no PATH symlinks at `/usr/bin/orionx-mesh`, `/usr/bin/setup-matrix.sh`, etc. The ISO boots a stock Debian Bullseye with the Phase 6 infrastructure (AppArmor profiles, systemd units, security hardening hooks) but is NOT a recognizable Orion-X release. v2.0.0-rc1 MUST NOT be tagged in its current form. Filed as issue #43. **Root cause**: `scripts/build-iso.sh` runs `lb config` + `lb build`, and `iso/config/includes.chroot/` contains AppArmor profiles + systemd units + helper scripts under `/usr/local/bin`, but does NOT contain the application layer. The Dockerfile `COPY scripts/ /opt/orionx/scripts/` and equivalent operations populate the dev-container image; there's no equivalent staging step in the ISO build path. The dual-authority gap was that the ISO build pipeline silently produced an ISO without application content while the Dockerfile-built dev container had it. **Why Phase 7 tests didn't catch this**: the Phase 7 test surface gated on infrastructure (hooks ran via `test-iso-hooks-applied.sh`; systemd units exist via `test-w7-4-b-runtime-verify.sh`; perf thresholds met via `test-w7-5-performance.sh`; failure-resilience configs correct via `test-w7-6-failure-resilience.sh`). NONE of those tests asserted that any specific application file is present in the booted ISO. A stock Debian + the Phase 6 hooks + the Phase 6 systemd units passes every Phase 7 test. This is the integration-testing blind spot that W7-7 hardware attestation was designed to surface — and it surfaced exactly as intended. **W7-7 is praised here as the operator gate correctly catching this before tag publication** (best-case W7-7 outcome: human attestation finds a class of failure that automated CI is structurally blind to). **Why this is NOT a cascade-consolidation candidate per DEC-PHASE7-041**: this is a fundamental architectural gap, not a downstream cascade exit. The DEC-PHASE7-041 pattern applies when a slice has mostly landed and a remaining sliver needs to be folded into a larger follow-up; here the entire content-staging axis is missing and requires its own dedicated slice with its own Scope Manifest and Evaluation Contract. Bundling content-staging with hypothetical future work (e.g., a runtime-cleanup slice for #41/#42, or wallpaper-asset population) would conflate a release-readiness gate fix with unrelated work and reduce the diff's reviewability. **Release-readiness invariant established**: going forward, release-readiness for any Orion-X ISO is gated not only on infrastructure correctness but also on content presence inside the booted ISO. `tests/integration/test-iso-content-presence.sh` (authored in wi-w8-content-staging per DEC-PHASE8-005) becomes the canonical gate — mounts the squashfs, asserts canonical application paths exist, wired into `.github/workflows/qemu-test.yml` as an ACTIVE gate (no `continue-on-error`). Any future regression in `stage_application_content` turns CI red. **Phase 8 W-ID table updates**: W7-7 status changes from DEFERRED to FAILED 2026-05-15 (with re-attestation pending after #43 fix); W8-7 status changes from PENDING to BLOCKED 2026-05-15 (pending #43 fix and W7-7 re-attestation); W8-3 row carries a NOTE that the audit verified version strings + script-path-in-repo but did NOT verify ISO-content presence; future docs-audit slices MUST expand scope to include content presence (this is a project-wide pattern, not a Phase 8 footnote). DEC-PHASE8-003 is preserved as a historical decision in the Decision Log but its operative claims about software-track closure no longer hold; readers should follow this entry forward. **Rejected alternatives**: (i) tagging v2.0.0-rc1 anyway and treating the content gap as a follow-up — would publish a release that does not match its name; (ii) attempting to ship a "v2.0.0-rc1.1" patch release with content staging post-hoc — would supersede DEC-PHASE8-001's choice of rc1 as the first release-candidate label without a real benefit; the right fix is to land content-staging on develop before any tag is cut; (iii) treating the gap as a runtime-cleanup issue (alongside #41/#42) — runtime-cleanup is decorative; content staging is fundamental to what the ISO IS; (iv) treating Dockerfile changes as the fix path — Dockerfile builds the dev container, not the ISO; the ISO build path runs in debian:bullseye-slim per `qemu-test.yml` and has its own staging surface. **Cross-references**: issue #43 (W7-7 critical finding tracker — this DEC's fix target); DEC-PHASE8-003 (SUPERSEDED here); DEC-PHASE8-005 (wi-w8-content-staging slice scope/eval); DEC-PHASE7-002 (build-iso as single canonical version authority — PRESERVED); DEC-PHASE7-041 (cascade-consolidation discipline — NOT applicable here, framing reaffirmed); DEC-005 (Phase 5 forensic toolkit, artifact-analyzer.py + storyboard-gen.py — the two scripts likely meant by "LLM-assisted workflows" in the W7-7 finding, pending operator clarification). Code: `MASTER_PLAN.md` Phase 8 status header (Active → Active REOPENED 2026-05-15), Phase 8 reopen narrative section (above), W-ID table updates (W7-7 FAILED, W8-7 BLOCKED, W8-3 NOTE, wi-w8-content-staging added), revised handoff summary; this DEC entry; issue #43 tracker; wi-w8-content-staging work item registered in runtime. |
| DEC-PHASE8-005 | 2026-05-15 | [wi-w8-content-staging SEEDING] Single dedicated slice for ISO application-layer content staging + content-presence test gate (#43 fix) | **Slice seeded**: `wi-w8-content-staging` with full Scope Manifest in `tmp/scope-wi-w8-content-staging.json` and Evaluation Contract in `tmp/eval-wi-w8-content-staging.json`, registered via `cc-policy workflow work-item-set phase7-integration g-initial-planning wi-w8-content-staging --status pending` and `cc-policy workflow scope-sync phase7-integration --work-item-id wi-w8-content-staging`. **Mission**: make the ISO contain the actual Orion-X application layer. Concretely: (a) add `stage_application_content()` to `scripts/build-iso.sh` that rsyncs `scripts/` → `iso/config/includes.chroot/opt/orionx/scripts/` (excluding `build-iso.sh`, `qemu-boot-test.sh`, `release/`, `security/test` scripts, `__pycache__/`), `theme/` → `iso/config/includes.chroot/opt/orionx/theme/`, `data/` → `iso/config/includes.chroot/opt/orionx/data/`, `docs/` → `iso/config/includes.chroot/usr/share/doc/orionx/`; run order is `prepare_build_env → stage_application_content → configure_live_build → build_iso → cleanup`; (b) add `iso/config/hooks/live/0700-orionx-setup.hook.chroot` creating PATH symlinks in `/usr/bin/` for `orionx-mesh`, `setup-wireguard.sh`, `setup-matrix.sh`, `artifact-analyzer.py`, `storyboard-gen.py`, `toggle-theme.sh`, `run-lynis.sh`, `download-samples.sh`, setting executable bits on `/opt/orionx/scripts/**`, configuring wallpaper (with empty-directory guard — see notes below), and conditionally installing XDG desktop entries (only if the live ISO has a desktop environment present per `iso/config/package-lists/`; otherwise SKIP loud-and-clear); (c) `.gitignore` exclusions for the staged paths (`iso/config/includes.chroot/opt/orionx/**` and `iso/config/includes.chroot/usr/share/doc/orionx/**`) — staged at build time, NOT committed; (d) `tests/integration/test-iso-content-presence.sh` mounts the iso9660, extracts `live/filesystem.squashfs`, asserts canonical paths exist (the eight `/opt/orionx/scripts/` entrypoints, `theme/wallpapers/` directory, `data/samples/` directory, `User_Guide.md`, and the eight `/usr/bin/` symlinks); (e) `tests/unit/test_iso_content_staging_unit.sh` and `tests/unit/test_orionx_setup_hook_unit.sh` are structural tests (mirror W7-4-A pattern); (f) wire the content-presence test into `.github/workflows/qemu-test.yml` after the build step as an ACTIVE gate (NO `continue-on-error`). **State authorities**: `iso_content_staging_authority` (build-iso.sh as single staging authority — no parallel Makefile target, no separate stage-content.sh helper); `iso_build_pipeline_authority` (preserved per DEC-PHASE7-002 — VERSION constant and ORIONX_VERSION default unchanged); `release_readiness_gate_authority` (new content-presence test as the canonical content-gate, complement to the existing infrastructure gates). **Forbidden touch points**: source content at `scripts/**`, `theme/**`, `data/**`, `docs/**` (single-source-of-truth preserved — these remain the canonical inputs to staging); the existing Phase 6 hooks `0500/0600/0610/0615/0620` (preserved); `Dockerfile` (separate authority — dev container, not ISO build); `systemd/**` (preserved); `MASTER_PLAN.md`, `README.md`, `CHANGELOG.md`, `docs/**` (planner / wi-w8-finish-A authored surfaces — out of scope); `release.yml` (wi-w8-finish-B authored — release.yml will pick up the new staging step automatically because it invokes `scripts/build-iso.sh`). **Forbidden shortcuts**: committing staged content to git (creates dual authority for application content); duplicating `scripts/` under a different repo-root path; modifying Dockerfile COPY operations as the fix path; pass-through gating the content-presence test with `continue-on-error: true`; using `cp` instead of `rsync` (rsync `--exclude` is required to skip build artifacts cleanly); pre-staging `/usr/bin/` symlinks into `includes.chroot/usr/bin/` directly instead of creating them inside the chroot via the 0700 hook; touching MASTER_PLAN.md or DECISIONS.md from the implementer seat. **Empty-directory note** (planner discovery 2026-05-15): `theme/wallpapers/` is empty in develop HEAD. The content-presence test asserts directory-existence, NOT non-emptiness, for theme paths. Populating wallpaper assets is a separate slice with its own DEC. The 0700 hook's wallpaper-configuration portion must guard against the empty case (either SKIP wallpaper setting loud-and-clear or fail-loud with a clear message — implementer's call documented in REVIEW_*). **"LLM-assisted workflows" ambiguity** (open question, operator clarification welcome): the W7-7 finding mentions "LLM-assisted workflows" as missing content. Planner discovery 2026-05-15: no script in `scripts/` is explicitly labeled "LLM-assisted"; the closest candidates are `artifact-analyzer.py` + `storyboard-gen.py` (the Phase 5 forensic-orchestration pair per DEC-005, which once on PATH and referenced by User_Guide.md may BE what the operator means by "LLM-assisted workflows"). The slice includes both scripts in the staging contract. If the operator's intent is a different/hypothetical SIFT-AI script not yet in the tree, that requires a separate planner pass and DEC to specify — this is recorded as a follow-up question, not a slice blocker. **Sequencing within the slice**: implementer should (1) write the two unit tests first so the structural contract is encoded before implementation; (2) add `stage_application_content()` to build-iso.sh with rsync rules; (3) author the 0700 hook; (4) add .gitignore exclusions; (5) author the content-presence integration test; (6) wire it into qemu-test.yml. **Ready-for-guardian gates** (summary): all four GitHub Actions workflows green on the feature-branch HEAD; the content-presence test wired as an ACTIVE gate AND passing against a freshly built ISO in CI; the two new unit tests pass locally; the diff against develop touches ONLY the seven allowed paths from the Scope Manifest and ZERO forbidden paths; the staged content under `iso/config/includes.chroot/opt/orionx/` and `iso/config/includes.chroot/usr/share/doc/orionx/` is NOT in the git index (verifiable via `git ls-files iso/config/includes.chroot/opt iso/config/includes.chroot/usr/share/doc` returning empty); reviewer's REVIEW_* completion includes the per-path source→stage mapping table, the list of `/usr/bin/` symlinks, confirmation that the 0700 hook runs after 0620 service-hardening per numeric ordering, the content-presence test's run id and pass status, and flagged-but-not-modified findings for any User_Guide.md script references that don't resolve in scripts/. Closure DEC for this slice will be DEC-PHASE8-006 at acceptance. **Rejected alternatives**: (i) bundling content-staging with a hypothetical runtime-cleanup slice for #41/#42 — see DEC-PHASE8-004 rejection rationale; (ii) seeding two sub-slices (one for staging mechanism, one for the test gate) — they share an identical surface and forbidden-paths list; they would land back-to-back; consolidation is correct here, fragmentation is not; (iii) committing the staged tree to git as a one-off and not bothering with stage_application_content() — creates dual authority; the second time a script in `scripts/` is modified, the staged copy drifts; the next attestation finds a different bug; (iv) staging only `scripts/` and deferring `theme/data/docs` to a follow-up — would leave User_Guide.md still missing from `/usr/share/doc/orionx/` and operator-visible documentation absent from the ISO; the whole-content axis is fixed in one slice. **Cross-references**: issue #43 (#43 fix target); DEC-PHASE8-004 (Phase 8 reopen + this DEC's parent decision); DEC-PHASE7-002 (build-iso single canonical authority — preserved); DEC-PHASE7-041 (cascade-consolidation — NOT applicable, reaffirmed); DEC-PHASE7-035 (sentinel mechanism — unaffected by this slice); DEC-005 (Phase 5 forensic-orchestration tools — referenced as "LLM-assisted workflows" candidates); wi-w8-finish-A (DEC-PHASE8-003 closure) and wi-w8-finish-B (DEC-PHASE8-003 closure) — both preserved and untouched; #41 and #42 (runtime hygiene findings — NOT blockers for this slice). Code: `tmp/scope-wi-w8-content-staging.json`; `tmp/eval-wi-w8-content-staging.json`; runtime registration via `cc-policy workflow work-item-set phase7-integration g-initial-planning wi-w8-content-staging` and `cc-policy workflow scope-sync phase7-integration --work-item-id wi-w8-content-staging`; this DEC entry; W-ID table addition (wi-w8-content-staging PENDING). |
| DEC-PHASE8-006 | 2026-05-15 | [wi-w8-content-staging CLOSURE / #43 FIX LANDED] ISO application-layer content staging is live; content-presence test is now an ACTIVE release-readiness CI gate | **Slice closed**: `wi-w8-content-staging` landed on `develop` at merge `e725895` (commit `9eaf7f1` `feat(phase8): stage Orion-X application layer into ISO (closes #43)`). The slice executed per DEC-PHASE8-005's contract: `scripts/build-iso.sh` gained `stage_application_content()` rsyncing `scripts/` → `iso/config/includes.chroot/opt/orionx/scripts/` (excluding `build-iso.sh`, `qemu-boot-test.sh`, `release/`, `security/`, `__pycache__/`), `theme/` → `iso/config/includes.chroot/opt/orionx/theme/`, `data/` → `iso/config/includes.chroot/opt/orionx/data/`, `docs/` → `iso/config/includes.chroot/usr/share/doc/orionx/` (plus `CHANGELOG.md` + `README.md`); `iso/config/hooks/live/0700-orionx-setup.hook.chroot` creates `/usr/bin/` symlinks for all eight named entrypoints + sets executable bits + configures wallpaper with empty-dir guard + conditionally installs XDG desktop entries; `.gitignore` excludes the staged paths; three new tests live in `tests/integration/test-iso-content-presence.sh` (295 lines, mounts the iso9660 + extracts the squashfs + asserts canonical paths), `tests/unit/test_iso_content_staging_unit.sh` (295 lines, structural test of build-iso's staging logic), `tests/unit/test_orionx_setup_hook_unit.sh` (371 lines, structural test of the 0700 hook); the content-presence test is wired into `.github/workflows/qemu-test.yml` as an ACTIVE gate (NO `continue-on-error`). Issue **#43 CLOSED 2026-05-16**. **CI verification on `e725895` was incomplete**: Lint & Test GREEN, E2E Scenario GREEN, QEMU Boot Test FAILED (1m25s — rsync exit 23 on empty `theme/wallpapers/`). The CI cascade was repaired by wi-w8-staging-defensive (DEC-PHASE8-007) without modifying the content-staging contract or the content-presence test. **State authorities now live**: `iso_content_staging_authority` (build-iso.sh's `stage_application_content()` is the single canonical staging surface — no parallel Makefile target, no separate stage-content.sh helper, no Dockerfile COPY duplication for ISO content); `release_readiness_gate_authority` (the content-presence integration test is the canonical content-axis gate, complement to existing infrastructure gates like `test-iso-hooks-applied.sh`, `test-w7-4-b-runtime-verify.sh`, `test-w7-5-performance.sh`, `test-w7-6-failure-resilience.sh`); `iso_build_pipeline_authority` (preserved per DEC-PHASE7-002 — VERSION constant + ORIONX_VERSION default unchanged). **Architectural lesson re-affirmed**: integration tests must gate on content presence inside the booted artifact, not only on infrastructure structure. The Phase 7 surface had a blind spot exactly here (a stock Debian + Phase 6 hooks + Phase 6 systemd units passed every Phase 7 test); W7-7 operator attestation was designed to catch this and did. **Dual-path resolution** (Dockerfile dev container vs ISO chroot): there are intentionally TWO build targets in this repo — `Dockerfile` builds a dev-iteration container (`COPY scripts/ /opt/orionx/scripts/` lives there per DEC-PHASE7-014/015 history), `scripts/build-iso.sh` builds the release ISO (`stage_application_content()` lives here per this DEC). Both surfaces consume the SAME single-source-of-truth (the repo-root `scripts/`, `theme/`, `data/`, `docs/` trees), and their two staging mechanisms are not parallel authorities for the same target — they are two consumers of one authority. The single-source discipline is preserved by NOT committing the staged tree under `iso/config/includes.chroot/opt/orionx/` (`.gitignore` rules and `git ls-files iso/config/includes.chroot/opt iso/config/includes.chroot/usr/share/doc` should return empty at HEAD). **Rejected (at closure) alternatives**: (i) committing the staged tree to git as a one-off — would create dual authority for application content; the second modification to `scripts/` would drift the staged copy and the next attestation would surface a new bug. (ii) folding the staging step into the Dockerfile as well — would create dual authorities for ISO content (build-iso.sh and Dockerfile both staging the same content into different consumers). The Dockerfile's `COPY scripts/` is for the dev container, not the ISO; cross-pollination would re-introduce the dual-authority bug at a different boundary. **Cross-references**: DEC-PHASE8-005 (slice seeding); DEC-PHASE8-004 (Phase 8 reopen); DEC-PHASE8-007 (defensive amendment that landed CI green); DEC-PHASE7-002 (build-iso authority — preserved); DEC-PHASE7-041 (cascade-consolidation discipline — NOT applied to this slice; was applied to DEC-PHASE8-007 amendment); issue #43 (target, now CLOSED). Code: `scripts/build-iso.sh` (stage_application_content + .gitignore-tolerant rsync paths); `iso/config/hooks/live/0700-orionx-setup.hook.chroot` (PATH symlinks + executable bits + XDG entries); `.gitignore` (staged-path exclusions); `tests/integration/test-iso-content-presence.sh` (canonical content-gate); `tests/unit/test_iso_content_staging_unit.sh`; `tests/unit/test_orionx_setup_hook_unit.sh`; `.github/workflows/qemu-test.yml` (content-presence ACTIVE gate wiring); merge `e725895`. |
| DEC-PHASE8-007 | 2026-05-16 | [wi-w8-staging-defensive CI CASCADE FIX] `stage_application_content()` tolerates missing source dirs; `.gitkeep` is the canonical idiom for tracked-empty-source-dirs that participate in ISO staging | **Slice closed**: `wi-w8-staging-defensive` landed on `develop` at merge `40416d6` (commit `ab56a67` `fix(phase8): make stage_application_content tolerant of missing source dirs`). This is a DEC-PHASE7-041 cascade-consolidation amendment to DEC-PHASE8-005/006: the wi-w8-content-staging slice landed at `e725895` and its QEMU Boot Test CI step FAILED at 1m25s with rsync exit 23 because `theme/wallpapers/` was empty on develop (an empty source dir is not a valid rsync source). Three-file defensive fix preserves DEC-PHASE8-006's `iso_content_staging_authority` invariant while making the staging step robust to optional/empty content trees: (a) **`scripts/build-iso.sh`** — added existence guards on all four rsync calls in `stage_application_content()` (scripts/, theme/, data/, docs/) so a missing or empty source dir is logged as a SKIP rather than a FAIL; added an early bulk diagnostic that enumerates the four source dirs at function entry and reports their populated/empty/missing state for fast forensic context if a future regression surfaces. (b) **`theme/wallpapers/.gitkeep`** — placeholder file (with comment pointing to #43 follow-up for actual wallpaper assets) makes `theme/wallpapers/` tracked by git so the directory always exists on every checkout; this is the **canonical idiom for tracked-empty-source-dirs that participate in ISO staging** going forward (DEC-PHASE8-007 establishes the pattern). (c) **`tests/unit/test_iso_content_staging_unit.sh`** — gained +9 assertions covering the defensive guards (test passes 32/32 after the amendment). **State-authority discipline**: `iso_content_staging_authority` (build-iso.sh) is PRESERVED — the change is internal robustness, not a new pipeline or a parallel staging mechanism; no Makefile target was added, no helper script was extracted, the content-presence integration test was not weakened. **`continue-on-error`** was NOT applied to the staging or content-presence steps — fix-the-root-cause discipline per DEC-PHASE7-041 was applied here exactly: minimal-scope amendment that makes the cascade green without retreating from the diagnostic surface. **Anti-drift control**: future implementers MUST NOT delete the rsync existence guards without an explicit planner DEC that names a new `iso_content_staging_authority` invariant. Future implementers MUST adopt the `.gitkeep` pattern for any new tracked-empty-source-dir that participates in ISO staging (e.g., if a future slice adds `theme/icons/` or `theme/sounds/` that may be empty at the time of landing). **CI verification (in-flight at audit time)**: `develop @ 40416d6` Lint & Test GREEN (31s), E2E Scenario GREEN (2m34s), QEMU Boot Test IN PROGRESS (CI run `25967158637` ~9m at audit time). The expected outcome is GREEN once the QEMU boot run completes, which fully reopens the release pipeline (the DRAFT release.yml ISO becomes operator-attestable). **Rejected alternatives**: (i) applying `continue-on-error: true` to the staging step — would mask the issue without fixing it and would propagate empty rsync targets into a malformed ISO; explicit anti-pattern. (ii) committing wallpaper placeholder content directly under `theme/wallpapers/` — would invite dual authority (the canonical source tree would then contain build-output-like files); `.gitkeep` is the smaller surface that achieves the tracked-empty-dir guarantee without polluting the source tree. (iii) deleting the `theme/wallpapers/` rsync entirely from `stage_application_content()` — would weaken DEC-PHASE8-005's content-staging contract (User_Guide.md references wallpaper-toggle workflow and the ISO must support the canonical `/opt/orionx/theme/wallpapers/` path even when empty so a future content-population slice has a stable target). (iv) hoisting the empty-dir handling into the 0700 hook — would mix staging-time concerns into runtime-time concerns; the 0700 hook already has its own empty-wallpapers guard for runtime configuration, and that is correctly distinct from build-time staging tolerance. **Cross-references**: DEC-PHASE8-005 (wi-w8-content-staging seeding — preserved contract); DEC-PHASE8-006 (wi-w8-content-staging closure — preserved authorities); DEC-PHASE7-041 (cascade-consolidation discipline — APPLIED here as the minimal scope amendment pattern); DEC-PHASE7-002 (build-iso single canonical version authority — preserved); issue #43 (the parent finding — CLOSED 2026-05-16 by the combination of DEC-PHASE8-006 + DEC-PHASE8-007). Code: `scripts/build-iso.sh` (existence guards + early bulk diagnostic); `theme/wallpapers/.gitkeep` (canonical tracked-empty-dir idiom); `tests/unit/test_iso_content_staging_unit.sh` (+9 assertions, 32/32 passing); merge `40416d6`. |
| DEC-PHASE7-042 | 2026-05-13 | [W7-5 partial-accept + cascade-consolidation reapplication] W7-5 mechanism accepted with 1-of-3 targets verified; in-guest measurement reliability tracked under issue #40; DEC-PHASE7-041 reapplied as durable operational discipline | W7-5 (performance benchmark) landed at merge `8bcded0` and produced parseable `ORIONX_PERF: iso_size_bytes=984612864` (≈939 MiB, well under the 4 GiB threshold — **PASS**) host-side on first CI run. The other two Phase 7 performance targets from the goal-contract `desired_end_state` (`boot_time_seconds`, `idle_ram_bytes`) were UNMEASURED because `ORIONX_PERF_END` did not reach `/dev/ttyS0` within the 90s post-boot window — the same #39 first-boot cascade surface that gates W7-4-B's mesh assertions also gates W7-5's in-guest measurements (`multi-user.target` reach is unreliable on headless QEMU until non-interactive first-boot is resolved in Phase 8 design). **Partial-acceptance rationale**: rejecting W7-5 and reopening to chase the in-guest measurement reliability would be precisely the cascade-fix loop DEC-PHASE7-041 abandons. The mechanism (perf-measure unit + sentinel parser + host-side ISO-size measurement) is the value W7-5 delivers; 1 of 3 targets verified is real progress on the goal contract; the remaining two targets are blocked on the same architectural question Phase 8 design will resolve. **Exit slice (W7-5-exit, merge `ba3e0d1`)**: applied `continue-on-error: true` to the W7-5 step in `.github/workflows/qemu-test.yml` (mirror of W7-4-B-exit per DEC-PHASE7-039) and rewrote a stale comment block (caught by reviewer round 1). The step still runs, still emits sentinels, still uploads `qemu-artifacts-<run-id>/serial-{bios,uefi}.log`, but does not fail the workflow. **Issue #40 filed (2026-05-13)** as the in-guest boot_time / idle_ram measurement reliability tracker; routed as Phase 8 design pass input alongside #39. **Anti-drift control**: removing `continue-on-error: true` from the W7-5 step requires a planner DEC that explicitly closes #40 first. **Meta-confirmation of DEC-PHASE7-041**: this is the second application of the cascade-consolidation pattern in three slices (W7-4-B-exit, W7-5-exit). The pattern is durable operational discipline, not a one-off escape hatch. Both #39 and #40 share a root architectural question (headless-QEMU non-interactive boot semantics, DEC-SEC-003 bounded supersedence per DEC-PHASE7-038), and Phase 8 design will address them together rather than in serial cleanup slices. **Rejected alternative**: reopening W7-5 to chase the in-guest measurement window would have produced (a) another cascade-fix arc; (b) coupling with #39 work that belongs in Phase 8; (c) pressure to relax the 90s threshold without a real DEC — which would silently supersede the goal-contract `desired_end_state` values. **Cross-references**: DEC-PHASE7-035 (sentinel mechanism authority — preserved); DEC-PHASE7-039 (W7-4-B-exit first application); DEC-PHASE7-041 (meta-principle); DEC-PHASE7-040 (#39 cascade-consolidation precedent); issue #40 (in-guest measurement reliability tracker). Operational note: two Guardian-stewardship findings surfaced during this slice (stale `.git/index.lock` blocking the first W7-5-exit merge; workflow `base_branch=main` while merges target `develop`); both are runtime/control-plane discipline observations rather than source slices and are logged in the Phase 7 narrative for the operator's attention without a separate DEC entry. Code: merge commits `8bcded0` (W7-5 mechanism), `ba3e0d1` (W7-5-exit) on `develop`; CI run `25710069470`; issue #40 tracker; W-ID table updates marking W7-5 PARTIAL-ACCEPT and adding W7-5-exit ACCEPTED. |

## Risk Register

| Risk | Mitigation |
|------|------------|
| Packages not in Bullseye (Ghidra, Autopsy, zeek) | Install hooks from upstream; Bookworm/NixOS in v3.1 |
| P2P mesh complexity (NAT traversal) | MVP = LAN-only mesh; NAT traversal deferred |
| ISO build needs Linux | Document build env; GitHub Actions CI |
| Debian Bullseye EOL June 2026 | DEC-010: Aggressive timeline, ship before EOL. Weekly cadence (DEC-013). Scope constrained by DEC-003 (LAN-only) and Phase 3 non-goals |
| Sample data URLs go stale | `--offline` mode with synthetic data |
| MCP tooling vulnerabilities (AESIR findings) | Sandboxed execution, input validation, CVE monitoring |
| LLM hallucination in forensic analysis | Inference Constraint Layer, tool-output-only conclusions |
| AI stack as attack surface | Air-gap capable, model integrity verification, audit logging |
| Post-quantum transition urgency | Hybrid crypto from v3.0; classical remains secure for now |

## References

- [1] Jarocki, J. "Orion Incident Response Live CD" — SANS White Paper #33368
- [2] Lee, R.T. "Introducing Protocol SIFT" — robtlee73.substack.com, March 2026
- [3] NIST FIPS 203 (ML-KEM), FIPS 204 (ML-DSA), FIPS 205 (SLH-DSA) — PQC Standards
- [4] MITRE ATT&CK v18.1 (Dec 2025); MITRE ATLAS AI Threat Framework
- [5] ForensicLLM — Fine-tuned LLaMA-3.1-8B for digital forensics (ResearchGate, 2025)
- [6] SANS FOR563 — Applied AI for DFIR with Local LLMs
- [7] GTG-1002 Campaign — Chinese state-sponsored AI-driven attacks, Nov 2025
- [8] Sysdig — 8-minute AWS escalation, [un]prompted March 2026
- [9] mcp-forensic-toolkit — Open-source MCP forensic server (GitHub)
- [10] Trend Micro AESIR — 21 critical CVEs including MCP tooling flaws, Jan 2026
- [11] Deep Research — `.claude/research/DeepResearch_OrionX_Modern_Vision_2026-03-08/report.md`

## Completed Initiatives

### Phase 1: Repository Bootstrap (v2.0.0)
**Completed:** 2026-03-08 | **Commit:** `1d8845f` on `develop`

Flattened v1.5.5 into repo root. 35 files, clean structure (scripts/, iso/, data/, docs/, tests/, archive/). Fixed: bare `except:` in Python scripts, deprecated `apt-key` in setup-matrix.sh, duplicate `cryptsetup` in package list, external packages tagged. Created Makefile and CI scaffold.

### Phase 2: Build System & Linting (v2.0.0)
**Completed:** 2026-04-05 | **Commit:** `562d998` on `develop`

Makefile with 9 targets (lint, test-unit, docker-build, iso-build, clean, and supporting targets). Dockerfile and docker-compose.yml for containerized builds. GitHub Actions CI (lint.yml) with ShellCheck + ruff linting. Unit test suite (tests/test_phase2_build_system.py, 250 lines). requirements.txt for Python dependencies. All linting passes.

### Phase 3: P2P Mesh Networking (v2.0.0)
**Completed:** 2026-04-20 | **Commits:** `edff558`..`03b6704` on `develop`

Full P2P WireGuard mesh networking — the project's core differentiator. 9 work items across 5 waves:
- Core library (`mesh-lib.sh`) with WireGuard helpers, state management, config parsing
- `orionx-mesh` CLI: join|status|peers|leave with human-readable formatting
- UDP broadcast peer discovery (socat, port 55555) + shared config for pre-planned ops
- Health check daemon (systemd timer, 60s) with soft/aggressive auto-healing
- Docker 3-node test environment with integration tests for all 4 acceptance criteria
- Standalone WireGuard retained as `setup-wireguard.sh` (renamed from setup-vpn.sh)

Decisions: DEC-MESH-001 (UDP broadcast), DEC-MESH-002 (systemd timer), DEC-MESH-003 (Docker testing), DEC-MESH-004 (bash CLI), DEC-MESH-005 (soft heal), DEC-MESH-STANDALONE-001 (standalone WireGuard retained)

### Phase 4: Matrix Team Collaboration (v2.0.0)
**Completed:** 2026-04-23 | **Commits:** `53faabb`..`a8c822f` on `develop`

Encrypted team communications over the WireGuard mesh. 6 work items across 3 waves:
- Synapse Docker infrastructure with homeserver.yaml template and server/client entrypoint
- Modernized setup-matrix.sh with CLI arguments (--mode, --server-name, --admin-user)
- Docker Compose 2-node test environment with health-gated startup
- systemd unit for Synapse with WireGuard mesh dependency (After + Requires wg-quick@wg0)
- 751-line integration test: user registration, encrypted rooms, message exchange, restart survival
- Security hardening: ProtectSystem, NoNewPrivileges, SQLite backend

Decisions: DEC-MATRIX-002 (layered Docker), DEC-MATRIX-003 (template config), DEC-MATRIX-004 (SQLite), DEC-MATRIX-005 (static systemd validation), DEC-MATRIX-SETUP-001 (CLI args), DEC-MATRIX-TEST-001 (API-based E2E)

### Phase 5: Forensic Toolkit Validation (v2.0.0)
**Completed:** 2026-04-26 | **Commits:** `1cd88b1`..`c380f82` on `develop`

Forensic toolkit validation and Python test infrastructure. 6 work items across 3 waves:
- requirements.txt (runtime: volatility3, scapy) + requirements-dev.txt (pytest, ruff)
- Synthetic sample data: syslog, CSV, JSON, XML logs + binary pcap/memory/firmware stubs
- Forensic tools integration test validating 24 tools (PASS/SKIP/FAIL pattern)
- 61 unit tests for artifact-analyzer.py (type detection, hashing, chain-of-custody)
- 56 unit tests for storyboard-gen.py (parsing, timeline, HTML/text reports)
- Modernized download-samples.sh with --offline mode for air-gapped environments

Decisions: DEC-FORENSIC-001 (test pure logic), DEC-FORENSIC-002 (synthetic samples), DEC-FORENSIC-003 (CLI pattern)

### Phase 6: Security Hardening (v2.0.0)
**Completed:** 2026-04-28 | **Commits:** `a1af67e`..`229690c` on `develop`

Platform security hardening for hostile environments. 8 work items across 3 waves:
- Credential audit tool (zero hardcoded secrets, CI-ready)
- nftables firewall: default-deny, WireGuard+Matrix+SSH only
- Filesystem hardening: /tmp noexec, core dumps disabled, UMASK 027
- 5 AppArmor profiles (Synapse, WireGuard, Volatility3, bulk_extractor, tshark)
- Modernized Lynis with CLI args, threshold gate (>= 75), retired v2
- First-boot wizard forcing credential setup on initial boot
- Service hardening: SSH key-only, sysctl hardening, disabled unnecessary services
- Integration test suite (36 checks across all 8 components)

Decisions: DEC-SEC-001 (nftables), DEC-SEC-002 (static AppArmor), DEC-SEC-003 (first-boot wizard), DEC-SEC-004 (structural validation), DEC-SEC-005 (single Lynis)

**Runtime-validation boundary (acknowledged 2026-04-28 via DEC-PHASE7-024):**
Phase 6 closed with all hook files present at `iso/hooks/live/*.hook.chroot`,
shellcheck-clean and content-verified by the 36-check structural suite. CI run
25475860825 (Phase 7 qemu-boot validation) revealed that NONE of the project
hooks at `iso/hooks/**` were on any live-build search path — `config/hooks/`
auto-discovery looks under `config/hooks/{normal,live,binary}/` relative to
the lb config root (`iso/`), so canonical paths are `iso/config/hooks/...`,
not `iso/hooks/...`. Phase 6 hardening was therefore structurally complete
but never executed during the actual build. The Phase 6 deliverables (hooks,
profiles, firewall rules, wizard) are correct in content; only their wiring
was on a non-canonical path. The Phase 7 enabler `W7-3-enabler` (issue #32)
moves the seven project hooks into the canonical tree and adds
`tests/integration/test-iso-hooks-applied.sh` as the new runtime-execution
authority gated in CI. After that enabler lands, Phase 6 hardening will
actually take effect at ISO build time and Phase 7's W7-4 (mesh + Matrix +
AppArmor runtime verification) becomes meaningful. DEC-SEC-001..005 stand;
this note documents the structural-vs-runtime boundary that Phase 6's
"completed" status implicitly assumed.
