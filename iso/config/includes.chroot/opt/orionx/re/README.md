# Orion-X RE Toolkit (Layer A)

DEC-PHASE11-004 lean RE + malware analysis toolkit.

## Installed

- ssdeep (fuzzy hashing)
- hashdeep (bulk recursive hashing — provides `md5deep` and `sha1deep`)
- python3-pefile (PE parsing)
- python3-yara (YARA bindings — see W11-4 for rulesets)
- python3-capstone (disassembler library)
- capa (via /opt/orionx/venv/re/, Apache-2.0) — symlinked at /usr/bin/capa
- python-magic (file type detection)

## Not on this image

`radare2` and `bulk_extractor` have **no candidate package in Debian 13
(trixie)** and are not installed by any other route (#85). Earlier Bullseye-line
documentation listed radare2 as part of this toolkit; that is no longer true.

For interactive reverse engineering, install Ghidra on a network-connected node:

```
sudo /opt/orionx/optional/install-ghidra.sh
```

## Available via optional installers

Run as root on a network-connected node — see `/opt/orionx/optional/`:

- FLOSS (`install-floss.sh`) — Mandiant string extractor
- TrID (`install-trid.sh`) — file type identification
- Ghidra (`install-ghidra.sh`) — NSA reverse engineering suite

## Usage

Run the installed tools directly from PATH — for example `capa <binary>`,
`ssdeep -r <dir>`, `md5deep -r <dir>`.
