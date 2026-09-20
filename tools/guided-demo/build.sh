#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tools/guided-demo/build.sh — build the narrated guided walkthrough
# (MP4 + poster + WebVTT + transcript) from the real beta applications.
#
# Usage (macOS or Linux host with Docker):
#   tools/guided-demo/build.sh [--iso output/<built>.iso] [--keep]
#
# What it does:
#   1. starts a debian:trixie-slim container with the repo mounted read-only,
#   2. extracts the Orion .desktop entries and the nucleotide lookup table from
#      the built ISO (so the menu and the toolkit scene use shipped data),
#   3. container-setup.sh — mirrors the ISO layout, seeds the XFCE skel config
#      via the real 0100 hook, renders the User Guide via the real 0810 hook,
#      installs Piper for offline narration,
#   4. session-start.sh — Xvfb + a real XFCE session + event bus + Pivotglass,
#   5. build_demo.py — records every scene from scenes.yaml, synthesises the
#      narration, assembles the artefacts,
#   6. copies the four artefacts into docs/media/.
#
# The container is removed afterwards unless --keep is given (keep it to
# re-record single scenes with `build_demo.py --only <scene-id>`).
# ---------------------------------------------------------------------------
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ISO="$(ls -t "$REPO"/output/*.iso 2>/dev/null | head -1 || true)"
KEEP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso) ISO="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[[ -f "$ISO" ]] || { echo "ERROR: built ISO not found (pass --iso)"; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker required"; exit 1; }
command -v 7z >/dev/null && command -v unsquashfs >/dev/null || { echo "ERROR: 7z + unsquashfs required on the host"; exit 1; }

NAME=orionx-demo
WORK="$REPO/tmp/guided-demo"; mkdir -p "$WORK/image"
echo "[build] extracting image assets from $(basename "$ISO")"
( cd "$WORK" && 7z x -y "$ISO" live/filesystem.squashfs >/dev/null \
    && rm -rf ex && unsquashfs -q -d ex live/filesystem.squashfs usr/share/applications opt/orionx/nucleotide >/dev/null \
    && rm -rf image/applications image/nucleotide \
    && cp -a ex/usr/share/applications image/applications && cp -a ex/opt/orionx/nucleotide image/nucleotide \
    && rm -rf ex live )

echo "[build] starting container $NAME"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -v "$REPO:/repo:ro" -v "$WORK:/work" -w /work debian:trixie-slim sleep infinity >/dev/null
docker exec "$NAME" bash /repo/tools/guided-demo/container-setup.sh
docker exec "$NAME" bash /repo/tools/guided-demo/session-start.sh :99

echo "[build] recording + assembling"
docker exec "$NAME" su - orionx-operator -c \
    "export DISPLAY=:99 PYTHONDONTWRITEBYTECODE=1 MENU_ORION_Y=267; python3 /repo/tools/guided-demo/build_demo.py --scenes /repo/tools/guided-demo/scenes.yaml --out /work/out"

VERSION="$(python3 -c "import yaml,sys; print(yaml.safe_load(open('$REPO/tools/guided-demo/scenes.yaml'))['version'])")"
BASE="orionx-guided-demo-$VERSION"
mkdir -p "$REPO/docs/media"
for ext in .mp4 .vtt -transcript.md -poster.png; do
    cp "$WORK/out/$BASE$ext" "$REPO/docs/media/$BASE$ext"
done
ls -l "$REPO/docs/media/$BASE"*
[[ $KEEP -eq 1 ]] || docker rm -f "$NAME" >/dev/null
echo "[build] done"
