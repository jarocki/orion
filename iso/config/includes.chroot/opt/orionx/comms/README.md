# Orion-X Team Comms

DEC-PHASE11-006: Matrix-based team communications for incident response.

## Layer A (this slice — W11-5)

- **matrix-commander** (pip venv at /opt/orionx/venv/comms/) — CLI Matrix client, symlinked at /usr/local/bin/matrix-commander
- Runs over existing Phase 4 Matrix homeserver + Phase 3 WireGuard mesh

## Layer B (W11-5b) — DEFERRED

- **gomuks** (static binary from mautrix/gomuks releases) — terminal Matrix TUI client, staged to /opt/orionx/comms/gomuks/

## Layer C (W11-8) — DEFERRED

- **element-desktop** (optional installer, ~150 MB) — GUI Matrix client for operators who prefer graphical UX

## Usage

```bash
# CLI messaging
matrix-commander --credentials ~/.config/matrix-commander/credentials.json --room "!<roomid>" --message "IR ping"

# TUI (Layer B — install via W11-5b first)
gomuks
```

## Wiring

- Matrix homeserver: Synapse from Phase 4, listens on Phase 3 WireGuard mesh (no public exposure)
- Credentials: created via `matrix-commander --login` on first use
