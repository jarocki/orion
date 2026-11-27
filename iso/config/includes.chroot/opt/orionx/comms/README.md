# Orion-X Team Comms

DEC-PHASE11-006: Matrix-based team communications for incident response.

## Layer A (this slice — W11-5)

- **matrix-commander** (pip venv at /opt/orionx/venv/comms/) — CLI Matrix client, symlinked at /usr/local/bin/matrix-commander
- Runs over existing Phase 4 Matrix homeserver + Phase 3 WireGuard mesh

## Element (optional)

- **element-desktop** (`sudo orionx-optional install element`, ~200 MB) — GUI Matrix client for operators who prefer graphical UX

gomuks is not offered (DEC-PHASE13-003, #206): its legacy terminal client is
built on the deprecated libolm and the current one needs a separate backend.

## Usage

```bash
# CLI messaging
matrix-commander --credentials ~/.config/matrix-commander/credentials.json --room "!<roomid>" --message "IR ping"
```

## Wiring

- Matrix homeserver: Synapse from Phase 4, listens on Phase 3 WireGuard mesh (no public exposure)
- Credentials: created via `matrix-commander --login` on first use
