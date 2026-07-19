# Orion-X RE Toolkit (Layer A)

DEC-PHASE11-004 lean RE + malware analysis toolkit.

## Installed (Layer A — W11-3)

- radare2 (Debian package)
- ssdeep (fuzzy hashing)
- md5deep / hashdeep (bulk hashing)
- python3-pefile (PE parsing)
- python3-yara (YARA bindings — see W11-4 for rulesets)
- python3-capstone (disassembler library)
- capa (via /opt/orionx/venv/re/, Apache-2.0) — symlinked at /usr/bin/capa
- python-magic (file type detection)

## Deferred (Layer B — W11-3b, follow-up)

- FLOSS (Apache-2.0 upstream binary tarball)
- TrID (upstream binary tarball)
- remnux-mcp-server (GPL-3.0, requires Node.js 20 LTS runtime)
- AppArmor profile for remnux-mcp-server

## Usage

Run RE tools directly from PATH. capa: `capa <binary>`. radare2: `r2 <binary>`.
