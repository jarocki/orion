# Orion-X YARA Rulesets

DEC-PHASE11-005: YARA rulesets for malware analysis.

## Layer A (this slice)

Skeleton + freshen mechanism. Rulesets not committed — use `orionx-freshen-yara` to fetch.

## Licensing Split

| Source | License | Auto-fetched by freshen | Path |
|---|---|---|---|
| Yara-Rules/rules | GPL-2.0 | Yes | `rules-yara-rules/` |
| ReversingLabs/reversinglabs-yara-rules | MIT | Yes | `rules-reversinglabs/` |
| BinaryAlert (managed rules subset) | Apache-2.0 | Yes | `rules-binaryalert-managed/` |
| DidierStevens/YARA | Public domain | Yes | `rules-didierstevens/` |
| Any NC or proprietary | N/A | NO — operator must accept terms locally | `rules-<name>/` |

## Usage

```bash
# Update rulesets from upstream
sudo orionx-freshen-yara

# Scan a binary
yara -r /opt/orionx/yara/rules-yara-rules/ /path/to/sample
```

## Layer B (W11-4b) — DEFERRED

Layer B will commit ruleset snapshots at build time (git clone during ISO build). Until then, `orionx-freshen-yara` must be run once post-boot to populate the rules directories.
