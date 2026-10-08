#!/usr/bin/env bash
# import-rootfs.sh — import a built ISO's squashfs as the capture image.
#   tools/guided-demo/cinematic/import-rootfs.sh output/<iso> <tag>
# Produces docker images orionx-rootfs:<tag> (the squashfs, unmodified) and
# orionx-capture:<tag> (plus Xvfb/xdotool/ffmpeg). See DEC-PHASE12-140.
set -euo pipefail
ISO="$1"; TAG="$2"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ISO" ]] || { echo "no such ISO: $ISO" >&2; exit 1; }
echo "[import] $ISO -> orionx-rootfs:$TAG"
docker run --rm --platform linux/amd64 -v "$(cd "$(dirname "$ISO")" && pwd):/iso:ro" debian:trixie-slim bash -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq squashfs-tools xorriso >/dev/null 2>&1
  xorriso -osirrox on -indev "/iso/'"$(basename "$ISO")"'" -extract /live/filesystem.squashfs /tmp/fs.sq >/dev/null 2>&1
  unsquashfs -q -n -d /r /tmp/fs.sq >/dev/null && rm /tmp/fs.sq && tar -C /r --numeric-owner -cf - .' \
  | docker import --platform linux/amd64 -c 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' - "orionx-rootfs:$TAG"
mkdir -p "$REPO/tmp/video/rootfs-build"
cat > "$REPO/tmp/video/rootfs-build/Dockerfile" <<'DF'
ARG BASE
FROM ${BASE}
# Capture tooling ONLY; everything else is the ISO's own squashfs, unmodified.
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      xvfb xdotool ffmpeg x11-utils >/dev/null && rm -rf /var/lib/apt/lists/*
DF
docker build --platform linux/amd64 -q -t "orionx-capture:$TAG" --build-arg "BASE=orionx-rootfs:$TAG" "$REPO/tmp/video/rootfs-build"
docker run --rm --platform linux/amd64 "orionx-capture:$TAG" cat /etc/orionx-version | head -2
