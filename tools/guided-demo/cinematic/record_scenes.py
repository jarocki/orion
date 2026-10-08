#!/usr/bin/env python3
"""
record_scenes.py — record the trailer's UI scenes from the ISO's own userspace.

The ISO squashfs is imported as a Docker image (linux/amd64, run under
Rosetta/binfmt at near-native speed) with only capture tooling added (Xvfb,
xdotool, ffmpeg); rootfs-session.sh starts the live user's XFCE session in it.
This script then drives one scene at a time from scenes-rootfs.yaml:

    setup   shell commands run as the live user before recording
    record  seconds of 1920x1080@30 video + the deck's PulseAudio output
    actions timed steps during the recording: {at, sh|type|key|click|move}
    teardown shell commands after recording

and finally converts every clip into the frames.csv + frames/ layout that
build_trailer.py already consumes (so QEMU footage and container footage mix).

    python3 record_scenes.py --container orionx-cap --scenes scenes-rootfs.yaml \
        --out tmp/video/capture-rootfs [--only cockpit-live,tab-mesh]

@decision DEC-PHASE12-140
@title UI scenes are recorded from the imported ISO rootfs, not from TCG QEMU
@status accepted
@rationale Full-system x86 emulation on Apple Silicon starved the guest so
  badly (841 s soft lockups) that GTK windows never mapped; the footage would
  have been either empty or a fabricated stand-in. Importing the squashfs as
  an amd64 image runs the shipped binaries and configuration unmodified at
  usable speed. What the container cannot show (firmware, kernel, Plymouth,
  the first-boot wizard on tty1) still comes from QEMU booting the ISO.
"""
from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

import yaml

USER = "orionx-operator"


def dexec(container: str, cmd: str, user: str = USER, check: bool = False, timeout: float | None = 600,
          capture: bool = False) -> str:
    full = ["docker", "exec", "-u", user, "-e", "DISPLAY=:0", "-e", "XDG_RUNTIME_DIR=/run/user/1000",
            "-e", "HOME=/home/" + USER if user == USER else "HOME=/root", container, "bash", "-lc",
            # the desktop session's D-Bus, as menu launches on the deck inherit it
            "[ -r /tmp/session.env ] && export $(cat /tmp/session.env); " + cmd]
    r = subprocess.run(full, text=True, timeout=timeout,
                       stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
                       stderr=subprocess.STDOUT if capture else subprocess.DEVNULL)
    if check and r.returncode != 0:
        raise RuntimeError(f"failed ({r.returncode}): {cmd}\n{r.stdout or ''}")
    return r.stdout or ""


def run_action(container: str, a: dict) -> None:
    if "sh" in a:
        dexec(container, a["sh"], user=a.get("user", USER), timeout=a.get("timeout", 600))
    if "type" in a:
        delay = int(a.get("delay_ms", 45))
        dexec(container, f"xdotool type --delay {delay} -- {shlex.quote(a['type'])}")
    if "key" in a:
        dexec(container, f"xdotool key --delay 120 {a['key']}")
    if "move" in a:
        x, y = a["move"]
        dexec(container, f"xdotool mousemove --sync {x} {y}")
    if "click" in a:
        x, y = a["click"][:2]
        btn = a["click"][2] if len(a["click"]) > 2 else 1
        dexec(container, f"xdotool mousemove --sync {x} {y} sleep 0.25 click {btn}")


def record(container: str, scene: dict, clips: Path) -> Path:
    sid = scene["id"]
    for cmd in scene.get("setup", []):
        dexec(container, cmd, user=scene.get("setup_user", USER), timeout=scene.get("setup_timeout", 600))
    if scene.get("settle"):
        time.sleep(float(scene["settle"]))
    dur = float(scene["record"])
    out = f"/clips/{sid}.mkv"
    rec = (f"ffmpeg -loglevel error -y -f x11grab -framerate 30 -video_size 1920x1080 -draw_mouse 1 -i :0 "
           f"-f pulse -i deck.monitor -t {dur + 0.5} -c:v libx264 -preset ultrafast -crf 14 -pix_fmt yuv420p "
           f"-c:a pcm_s16le {out}")
    t = threading.Thread(target=dexec, args=(container, rec), kwargs={"timeout": dur + 120})
    t.start()
    t0 = time.time()
    time.sleep(0.8)  # recorder warm-up
    for a in sorted(scene.get("actions", []), key=lambda x: float(x.get("at", 0))):
        wait = float(a.get("at", 0)) - (time.time() - t0)
        if wait > 0:
            time.sleep(wait)
        try:
            run_action(container, a)
        except Exception as e:  # keep recording; report
            print(f"[rec] {sid}: action failed: {e}", flush=True)
    t.join()
    for cmd in scene.get("teardown", []):
        dexec(container, cmd, user=scene.get("teardown_user", USER), timeout=120)
    p = clips / f"{sid}.mkv"
    print(f"[rec] {sid}: {p} ({p.stat().st_size / 1e6:.1f} MB)" if p.exists() else f"[rec] {sid}: NO CLIP", flush=True)
    return p


def to_frames(clips: Path, scenes: list[dict], out: Path, fps: int = 15) -> None:
    """Explode clips into the frames.csv layout build_trailer.py reads; keep audio per scene."""
    frames = out / "frames"
    frames.mkdir(parents=True, exist_ok=True)
    (out / "audio").mkdir(exist_ok=True)
    rows = []
    n = 0
    t_base = 0.0
    for sc in scenes:
        clip = clips / f"{sc['id']}.mkv"
        if not clip.exists():
            continue
        tmpd = out / f"tmp-{sc['id']}"
        tmpd.mkdir(exist_ok=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(clip), "-vf", f"fps={fps}",
                        str(tmpd / "%06d.png")], check=True)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(clip), "-vn", "-ac", "2", "-ar", "48000",
                        str(out / "audio" / f"{sc['id']}.wav")], check=False)
        files = sorted(tmpd.glob("*.png"))
        for i, f in enumerate(files):
            name = f"{n:06d}.png"
            f.rename(frames / name)
            rows.append(f"{t_base + i / fps:.3f},{sc.get('scene', sc['id'])},{name}")
            n += 1
        t_base += len(files) / fps + 1.0
        tmpd.rmdir()
    (out / "frames.csv").write_text("\n".join(rows) + "\n")
    print(f"[frames] {n} frames for {len(scenes)} scenes -> {out}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--container", default="orionx-cap")
    ap.add_argument("--scenes", required=True)
    ap.add_argument("--clips", default="tmp/video/clips")
    ap.add_argument("--out", required=True)
    ap.add_argument("--only")
    ap.add_argument("--frames-only", action="store_true")
    a = ap.parse_args()
    scenes = yaml.safe_load(Path(a.scenes).read_text())["scenes"]
    clips = Path(a.clips)
    clips.mkdir(parents=True, exist_ok=True)
    only = set(a.only.split(",")) if a.only else None
    if not a.frames_only:
        for sc in scenes:
            if only and sc["id"] not in only:
                continue
            record(a.container, sc, clips)
    to_frames(clips, scenes, Path(a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
