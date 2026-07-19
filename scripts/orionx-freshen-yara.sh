#!/usr/bin/env bash
# shellcheck shell=bash
# @decision DEC-PHASE11-005
# @title Orion-X YARA ruleset freshen script
# @status accepted
# @rationale Post-boot script to git clone/pull upstream YARA rulesets per DEC-PHASE11-005.
#            Operators run this once post-boot (or periodically) to update rulesets before
#            scanning. Layer A skeleton: rulesets are NOT committed at build time (that is
#            Layer B / W11-4b). This script is the operator's mechanism to populate the
#            rules-*/ directories under /opt/orionx/yara/.
#
# Usage:
#   sudo orionx-freshen-yara
#
# Reads ruleset metadata from /opt/orionx/yara/LOCKFILE.json via python3 (jq may
# not be installed). After each git clone/pull, update LOCKFILE.json commit_sha
# fields manually if you require reproducibility.

set -euo pipefail

YARA_DIR="/opt/orionx/yara"
LOCKFILE="$YARA_DIR/LOCKFILE.json"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: orionx-freshen-yara requires root (writes to /opt/orionx/yara/)" >&2
    exit 1
fi

if [[ ! -f "$LOCKFILE" ]]; then
    echo "ERROR: LOCKFILE.json not found at $LOCKFILE" >&2
    exit 1
fi

echo "[orionx-freshen-yara] Updating YARA rulesets to $YARA_DIR"

# Read repo URLs from LOCKFILE via python3 (jq may not be installed on all
# operator environments; python3 is always present in the Orion-X ISO).
repos=$(python3 -c "
import json, sys
with open('$LOCKFILE') as f:
    d = json.load(f)
for name, meta in d.get('rulesets', {}).items():
    print(f\"{name}|{meta['repo']}|{meta.get('branch','master')}\")
")

for line in $repos; do
    IFS='|' read -r name repo branch <<< "$line"
    dest="$YARA_DIR/rules-$name"
    echo "[orionx-freshen-yara] $name from $repo (branch: $branch)"
    if [[ -d "$dest/.git" ]]; then
        git -C "$dest" fetch --depth 1 origin "$branch" && \
            git -C "$dest" reset --hard "origin/$branch"
    else
        git clone --depth 1 --branch "$branch" "$repo" "$dest"
    fi
done

echo "[orionx-freshen-yara] Complete. Update LOCKFILE.json with resolved SHAs manually if reproducibility needed."
