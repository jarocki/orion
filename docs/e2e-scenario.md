# Orion-X Phase 7 End-to-End Scenario

Validates the full Orion-X operational workflow in a single Docker run:
WireGuard mesh formation, Synapse Matrix communication, forensic analysis,
and chain-of-custody report generation.

## The 7-Step Scenario

| # | Step | What it proves |
|---|------|----------------|
| 1 | Spin up 3-node compose stack | `docker-compose.e2e-test.yml` on subnet 172.22.0.0/24 starts 3 `matrix-node` containers (`e2e-server`, `e2e-node-2`, `e2e-node-3`) |
| 2 | Verify WireGuard mesh forms | All 3 nodes each show 2 WireGuard peers; VPN cross-node pings succeed |
| 3 | Verify Synapse boots | `e2e-server` responds at `/_matrix/client/versions`; `e2e-node-2` can reach Synapse on the internal Docker network |
| 4 | Register users + encrypted room | Two Matrix users (`e2e-alice`, `e2e-bob`) register/login; a room with `m.megolm.v1.aes-sha2` encryption is created and both users join |
| 5 | Forensic analysis | `scripts/artifact-analyzer.py` runs on `data/samples/logs/synthetic-syslog.log`; produces `chain_of_custody.txt` and `log_analysis/suspicious_entries.txt` |
| 6 | Share result via Matrix | `e2e-alice` posts the forensic summary to the encrypted room; `e2e-bob` retrieves it |
| 7 | HTML report | `scripts/storyboard-gen.py` generates `tmp/e2e-artifacts/<run-id>/report.html` — a timestamped chain-of-custody incident timeline |

Cleanup always runs (success **or** failure): `docker compose down -v` tears down the stack and verifies zero leaked containers, networks, and volumes.

## Expected Runtime

Under 10 minutes on a developer machine with a warm Docker image cache.
First run (cold image build including Synapse) may take 15-20 minutes.
Runs exceeding 15 minutes after the first build should be tracked as a P0
follow-up (not a blocking failure).

## Prerequisites

- Docker Engine with compose v2 plugin
- Host WireGuard kernel module (`sudo modprobe wireguard` on Linux; built into macOS kernel for Docker Desktop)
- `jq`, `curl`, `python3` on the host (used by the test script for Matrix API calls and forensic tool invocation)
- `data/samples/logs/synthetic-syslog.log` present (Phase 5 deliverable)

## How to Run

```bash
# Recommended (via Makefile)
make test-e2e

# Direct invocation (from repo root)
bash tests/integration/test-e2e-scenario.sh
```

## Artifacts

Every run writes artifacts under `tmp/e2e-artifacts/<run-id>/` (Sacred Practice 3 — never `/tmp/`):

```
tmp/e2e-artifacts/<run-id>/
  report.html                        # Chain-of-custody HTML report (storyboard-gen.py)
  scenario-summary.json              # Per-step status, timing, run metadata
  forensic-analysis/
    chain_of_custody.txt             # SHA-256 hash + provenance record
    log_analysis/
      suspicious_entries.txt         # Grep patterns matched in syslog
```

## Network Isolation

The E2E stack uses subnet **172.22.0.0/24** and Docker project name `orionx-e2e-test`, which is distinct from:

- `orionx-mesh-test` — 172.20.0.0/24 (Phase 3 mesh regression suite)
- `orionx-matrix-test` — 172.21.0.0/24 (Phase 4 Matrix regression suite)

All three stacks can run concurrently on the same Docker host without IP or port collisions. Synapse in the E2E stack is exposed on **host port 8108** (not 8008) for the same reason.

## Idempotency

Two back-to-back runs both succeed and leave zero leaked resources between runs. Each run generates a unique `run-id` so artifact directories never collide.

## Decision Annotations

| ID | Title | Location |
|----|-------|----------|
| DEC-PHASE7-007 | E2E 3-node compose stack on 172.22.0.0/24 | `docker/docker-compose.e2e-test.yml` |
| DEC-PHASE7-008 | Synapse on port 8108 to avoid host conflict | `docker/docker-compose.e2e-test.yml` |
| DEC-PHASE7-009 | No `set -e`; trap-based cleanup + explicit step tracking | `tests/integration/test-e2e-scenario.sh` |
| DEC-PHASE7-010 | Run-id stamped artifacts under `tmp/e2e-artifacts/` | `tests/integration/test-e2e-scenario.sh` |
| DEC-PHASE7-011 | SYNAPSE_URL targets port 8108 | `tests/integration/test-e2e-scenario.sh` |
| DEC-PHASE7-013 | CI workflow pre-creates `/var/log/orionx` with sudo to satisfy analyzer scripts (workaround pending analyzer log-path fix) | `.github/workflows/e2e-test.yml` |

## W7-4 Integration Seam

W7-4 (QEMU runtime validation) will reuse this script to confirm the same
7 steps pass when executed against a real booted QEMU VM rather than Docker
containers. The seam is the `SYNAPSE_URL` variable and the compose project
name — W7-4 can override `SYNAPSE_URL` to point at the QEMU VM's exposed
port and skip Steps 1-3 (stack is already up) by invoking a subset of steps
directly. No changes to this script are needed for W7-4 to consume it.
