# Orion-X Phoenix Edition — Archive Inventory

This directory contains legacy artifacts from the Orion-X development history.
These files are gitignored (not tracked) but preserved locally for reference.

## Version Progression

| Version | Codename | Date | Key Changes |
|---------|----------|------|-------------|
| v1.0.0 | Squirrel | 2024-01-15 | Initial prototype |
| v1.2.0 | — | 2024-06-10 | VPN mesh + sample PCAP data |
| v1.3.5 | — | 2024-09-30 | Matrix communication, artifact analyzer stubs |
| v1.4.0 | — | 2025-04-15 | ISO building, Lynis audit, backup/restore, credential provisioning |
| v1.5.0 | Phoenix | 2025-03-01 | UI redesign, full disk encryption, graphing analysis (networkx/matplotlib) |
| v1.5.5 | Phoenix | 2025-05-03 | Security audit (Lynis), credential removal, IoT samples, enhanced storyboard |

## Directory Structure

```
archive/
├── legacy-orionx/          # v1.5.0, v1.5.5, PDFs, architecture diagrams
│   ├── v1.5.0/             # Prior version with unique graphing analysis scripts
│   │   └── scripts/analysis/
│   │       ├── auto_analysis.py    # ArtifactAnalyzer with YARA, python-magic
│   │       └── storyteller.py      # networkx graphs + matplotlib timelines
│   ├── v1.5.5/             # Latest pre-Phoenix version (full git repo)
│   ├── orionx-phoenix-installation-bundle/
│   ├── Orion-X full chat.pdf       # Design conversation transcript
│   ├── Orion_X_Phoenix_Edition_Deployment_Kit.pdf
│   └── OrionX_arch_diagram.png
├── versions/
│   ├── v1.2/               # Sample PCAP, theme assets (wallpapers, terminal BGs)
│   ├── v1.3/               # Artifact analyzer/storyboard stubs
│   └── v1.4/               # Most complete script manifest: ISO build, Lynis,
│                            #   backup/restore, credential provisioning, config validation
├── artifacts/
│   ├── orionx-phoenix-structure.txt  # 89KB aggregated v1.5.5 code + docs
│   └── orion_artifacts/              # v1.5.0 install scripts, release notes, user guide
└── INVENTORY.md            # This file (tracked in git)
```

## What Was Carried Forward to Active Codebase

These files evolved from legacy versions into the current `scripts/` directory:

| Legacy File | Active Equivalent | Changes |
|-------------|-------------------|---------|
| v1.5.5 `artifact-analyzer.py` | `scripts/artifact-analyzer.py` | Bare except → typed exceptions, @decision DEC-003 |
| v1.5.5 `storyboard-gen.py` | `scripts/storyboard-gen.py` | Bare except → typed exceptions, @decision DEC-004 |
| v1.5.5 `setup-vpn.sh` | `scripts/setup-vpn.sh` (deprecated) → `scripts/mesh/orionx-mesh` | Complete rewrite to P2P mesh |
| v1.5.5 shell scripts | `scripts/*.sh` | Identical with minor fixes |

## Ideas Worth Revisiting

These capabilities exist in legacy versions but are NOT yet in the active codebase:

1. **Graphing/Visualization** (v1.5.0 `storyteller.py`)
   - networkx event correlation graphs
   - matplotlib timeline plots with severity coloring
   - Relevant for Phase 5 (AI integration) and incident narrative generation

2. **Vault Integration** (v1.5.5 `orionx-phoenix-structure.txt`)
   - Artifact vault upload with URL/token auth
   - Chain-of-custody document generation
   - HTML/JSON dual-format report generation

3. **Backup/Restore** (v1.4 scripts)
   - `backup-artifacts.py` / `restore-artifacts.py`
   - Retry logic, offline batch mode

4. **Security Hardening** (v1.5.0 release notes)
   - Pre-flight validation (API keys, YARA rules, dependencies)
   - Credential validation at install time
   - Multi-channel communication fallback (SSH via satellite, TCP tunneling)

5. **Desktop/Theme Infrastructure** (v1.2)
   - Terminal background themes (gold, VT100/220)
   - XFCE desktop configuration
   - Lightdm login theming
