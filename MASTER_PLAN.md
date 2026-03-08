# MASTER_PLAN: Orion-X Phoenix Edition — First Production Release (v2.0.0)

## Original Intent

> Take the existing Orion-X Phoenix Edition v1.5.5 codebase — a bootable forensic response platform with WireGuard VPN, Matrix communications, and a full forensic toolkit — and produce a genuinely buildable, tested, shippable v2.0.0 release. The v1.5.5 scripts and ISO configuration exist under `ORION-X/v1.5.5/` but have never been checked into the repository. The work spans 8 phases: repository bootstrap, build system, P2P mesh networking rewrite, Matrix collaboration validation, forensic toolkit testing, security hardening, integration testing, and final release. The core differentiator is transforming the client-server VPN into a true peer-to-peer auto-healing mesh network for teams operating in hostile environments.

## Context

Orion-X: Phoenix Edition is a modernization of John Jarocki's original Orion Live CD (~2010) — a bootable forensic response environment for incident responders. The Phoenix Edition transforms it into a **self-contained, peer-to-peer mesh-networked, encrypted platform** for cybersecurity teams operating in hostile environments.

The project currently exists as well-designed scripts and documentation across `ORION-X/v1.5.0`, `ORION-X/v1.5.5`, and `ORION-X/orionx-phoenix-installation-bundle` — none checked into the repository. v1.5.5 is the most mature and becomes our foundation.

**Goal:** Take v1.5.5 and produce a genuinely buildable, tested, shippable v2.0.0 release.

---

## Critical Gaps (Code vs Documentation)

| Gap | Severity | Detail |
|-----|----------|--------|
| **VPN is client-server, not P2P mesh** | HIGH | `setup-vpn.sh` prompts for a server endpoint + pubkey. No auto-mesh, no peer discovery, no health checks. The "auto-healing mesh" exists only in docs. |
| **Package list issues** | MEDIUM | `orionx.list.chroot` lists `ghidra`, `autopsy`, `volatility3`, `zeek` — several not in Debian Bullseye repos. Duplicate `cryptsetup` (lines 54, 79). |
| **No tests whatsoever** | HIGH | Zero shell tests, zero Python tests, no CI. |
| **Nested git repo** | LOW | v1.5.5 has its own `.git` inside the parent repo. Must flatten. |
| **Sample data is placeholders** | LOW | `data/samples/` dirs contain only README.txt files; actual data downloaded at runtime. |

---

## Architecture (4 Layers — Retained)

1. **Bootable Media** — Debian Bullseye live-build, UEFI+BIOS hybrid, LUKS persistence, read-only host FS
2. **Secure Mesh Network** — WireGuard P2P auto-mesh VPN *(needs rewrite)*
3. **Team Collaboration** — Matrix/Synapse + Element, E2E encrypted, dual-mode (local/central)
4. **Forensic Toolkit** — Volatility3, DC3DD, bulk_extractor, binwalk, TSK, Plaso, Ghidra, chain-of-custody

---

## Phased Plan

### Phase 1: Repository Bootstrap — ACTIVE
**Env:** macOS | **Status:** In Progress

Flatten v1.5.5 into the repo root with clean structure:
```
/
├── scripts/            # setup-vpn.sh, setup-matrix.sh, install.sh, *.py
├── iso/                # auto/config, hooks/, package-lists/
├── data/samples/       # pcaps/, memory/, firmware/, logs/
├── docs/               # User_Guide.md, SUPPORT.md, CONTRIBUTING.md
├── tests/unit/         # New
├── tests/integration/  # New
├── .github/workflows/  # CI scaffolding
├── Makefile            # Build orchestrator
├── README.md, LICENSE.md, manifest.json, MASTER_PLAN.md
└── archive/            # v1.5.0, orionx-phoenix-installation-bundle (preserved)
```

**Acceptance:** Clean initial commit on `develop` branch. `shellcheck scripts/*.sh` runs. `python3 -m py_compile scripts/*.py` passes. No nested `.git`.

---

### Phase 2: Build System & Linting
**Env:** macOS (Docker) + Linux VM (ISO) | **Status:** Planned

- Create `Makefile` with targets: `lint`, `test-unit`, `docker-build`, `iso-build`, `clean`
- Fix package list: remove duplicate `cryptsetup`, validate each package against Bullseye repos, create install hooks for packages needing external sources (Ghidra, Autopsy, volatility3, zeek)
- Add ShellCheck + ruff/flake8 linting
- Validate `build-iso.sh` end-to-end on Linux

**Acceptance:** `make lint` passes. `make iso-build` produces bootable ISO on Linux.

---

### Phase 3: P2P Mesh Networking (Core Differentiator)
**Env:** Docker multi-container + Linux VMs | **Status:** Planned

**Rewrite `setup-vpn.sh` as true P2P mesh:**
- Each node generates keypair on boot
- Peer discovery: shared config file for pre-planned ops, mDNS/broadcast for LAN
- Auto-mesh: every node connects to all known peers (full mesh topology)
- Health check daemon (systemd timer, 60s interval)
- Auto-healing: re-establish dropped peer connections
- CLI: `orionx-mesh join|status|peers|leave`
- MVP scope: LAN-only mesh (NAT traversal deferred to v2.1)

**Acceptance:** 3-node WireGuard mesh forms automatically in Docker compose. `wg show` on each node shows 2 peers. Health check recovers from killed peer within 120s.

---

### Phase 4: Matrix Team Collaboration
**Env:** Docker | **Status:** Planned

- Validate Synapse homeserver boots in container
- Fix `apt-key add` deprecation (use `/usr/share/keyrings/`)
- Test E2E encryption between two Element clients
- Add systemd service for Synapse auto-start
- Test message exchange over WireGuard mesh (combine with Phase 3)

**Acceptance:** Matrix message sent from Node A arrives at Node B with E2E encryption. Synapse survives restart, clients reconnect.

---

### Phase 5: Forensic Toolkit Validation
**Env:** Docker + Linux VM | **Status:** Planned

- Create `tests/integration/test-forensic-tools.sh` — verify each tool responds to `--version`/`--help`
- Fix `artifact-analyzer.py`: bare `except:` → specific exceptions, add `requirements.txt`
- Validate `storyboard-gen.py` HTML timeline generation
- Fix `download-samples.sh`: validate URLs, add checksums, add `--offline` mode
- Unit tests for Python scripts (mocked subprocesses)

**Acceptance:** All forensic tools functional in ISO. `artifact-analyzer.py` produces valid output from sample data. Python test coverage >= 60%.

---

### Phase 6: Security Hardening
**Env:** Linux VM (ISO) | **Status:** Planned

- Run Lynis audit on fresh ISO, document baseline score
- AppArmor profiles for Synapse, WireGuard, forensic tools
- Filesystem: verify read-only host, RAM disk encryption, `/tmp` as `tmpfs noexec,nosuid`
- Network: firewall (only WireGuard + Matrix ports open), disable unnecessary services
- Credential audit: grep all scripts for hardcoded secrets, first-boot setup wizard

**Acceptance:** Lynis Hardening Index >= 75. No hardcoded credentials. AppArmor enforcing.

---

### Phase 7: Integration Testing
**Env:** Docker + QEMU + physical hardware | **Status:** Planned

**End-to-end scenario:**
1. Boot 3 nodes → form WireGuard mesh → establish Matrix comms
2. Run forensic analysis on sample data from one node
3. Share results via Matrix
4. Generate incident report with chain of custody

**Boot testing:** QEMU UEFI + BIOS, USB boot on physical hardware

**Performance targets:** Boot < 90s, ISO < 4GB, idle RAM < 1GB

**Failure modes:** Node drop + recovery, Synapse restart, disk full, network flap

**Acceptance:** Full E2E scenario completes. ISO boots UEFI + BIOS. All failure scenarios recover.

---

### Phase 8: Release
**Env:** macOS + Linux | **Status:** Planned

- Bump all version strings to v2.0.0
- Documentation audit (User Guide matches reality)
- Release artifacts: ISO + SHA-256/SHA-512 checksums (GPG signed)
- Git tag `v2.0.0`, GitHub Release with ISO attached
- Close all phase issues

**Acceptance:** `sha256sum -c` passes. User Guide walkthrough succeeds on fresh ISO.

---

## Git Strategy

- **`main`** — Sacred, release-only (tagged releases)
- **`develop`** — Integration branch
- **`feature/phase-N-*`** — One branch per phase, worktree-based development
- Squash merges to develop for clean history

## Decision Log

| ID | Date | Decision | Rationale |
|----|------|----------|-----------|
| DEC-001 | 2026-03-08 | Start from v1.5.5 as foundation | Most mature version, has all scripts and ISO config |
| DEC-002 | 2026-03-08 | Debian Bullseye retained for v2.0 | Stable, known working; Bookworm migration deferred to v2.1 |
| DEC-003 | 2026-03-08 | LAN-only mesh for MVP | NAT traversal adds significant complexity; defer to v2.1 |

## Risk Register

| Risk | Mitigation |
|------|------------|
| Packages not in Bullseye (Ghidra, Autopsy, zeek) | Install hooks from upstream; consider Bookworm upgrade for v2.1 |
| P2P mesh complexity (NAT traversal) | MVP = LAN-only mesh; NAT traversal deferred to v2.1 |
| ISO build needs Linux | Document build env; GitHub Actions CI |
| Debian Bullseye EOL (June 2026) | Bookworm migration planned for v2.1 |
| Sample data URLs go stale | `--offline` mode with synthetic data |

## Completed Initiatives

*(none yet)*
