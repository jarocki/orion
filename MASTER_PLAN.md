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
**Env:** Docker + QEMU + physical hardware | **Status:** Active

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
| W7-1 | ISO build pipeline modernization | Linux/Docker | 1 | - | M | review |
| W7-2 | E2E scenario script (Docker, 3-node) | Docker | 1 | - | M | review |
| W7-3 | QEMU boot test harness (UEFI + BIOS) | Linux/QEMU | 2 | W7-1 | L | review |
| W7-4 | QEMU runtime verification (mesh + Matrix + AppArmor) | Linux/QEMU | 3 | W7-2, W7-3 | L | review |
| W7-5 | Performance benchmark suite | Linux/QEMU | 4 | W7-3, W7-4 | M | review |
| W7-6 | Failure-mode recovery tests | Docker + QEMU | 4 | W7-2, W7-4 | M | review |
| W7-7 | Physical USB boot validation | Hardware | 5 | W7-3 | S | approve |
| W7-8 | Phase 7 closure + Phase 8 activation | Repo | 6 | W7-1..W7-7 | S | review |

**Critical path:** W7-1 -> W7-3 -> W7-4 -> W7-6 -> W7-8 (5 waves).
**Max parallel width:** 2 (W7-1 and W7-2 in wave 1; W7-5 and W7-6 in wave 4).
**Hardware gate:** W7-7 requires physical USB and human-in-the-loop and is the
only `approve` gate; runs in parallel with W7-4..W7-6 once W7-3 lands.

Detailed Scope Manifests and Evaluation Contracts for each work item live in
`reckonings/2026-04-28-phase7-plan.md` (this section is the index; the
expanded contracts are produced per-dispatch by the planner trailer when each
W7-N item is provisioned).

---

### Phase 8: Release v2.0.0
**Env:** macOS + Linux | **Status:** Planned

- Bump all version strings to v2.0.0
- Documentation audit (User Guide matches reality)
- Release artifacts: ISO + SHA-256/SHA-512 checksums (GPG signed)
- Git tag `v2.0.0`, GitHub Release with ISO attached
- Close all phase issues

**Acceptance:** `sha256sum -c` passes. User Guide walkthrough succeeds on fresh ISO.

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
