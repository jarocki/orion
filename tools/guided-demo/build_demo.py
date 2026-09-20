#!/usr/bin/env python3
"""
Orion-X guided-demo builder — records the narrated walkthrough from the REAL
beta applications running in a virtual X session, then assembles MP4 + WebVTT
captions + Markdown transcript + poster from tools/guided-demo/scenes.yaml.

Runs INSIDE the render container prepared by tools/guided-demo/build.sh, as the
demo user, with an XFCE session already on $DISPLAY (default :99, 1280x720).

    python3 build_demo.py --scenes /repo/tools/guided-demo/scenes.yaml --out /work/out

Every frame in the video is a screen recording (ffmpeg x11grab) of the same
scripts that ship in the ISO; the only synthesised visuals are the opening
splash (the Plymouth theme's own background) and the closing card.

@decision DEC-PHASE12-018
@title The guided demo is built from scenes.yaml by this script, never hand-edited
@status accepted
@rationale The pivotglass repo established the deliverable shape (MP4 + poster
  + VTT + transcript embedded in the README). Keeping narration, captions and
  transcript in one source file and deriving the three artefacts here means they
  cannot drift, and the video can be re-cut for every release with one command
  instead of a screen-recording session. Narration is synthesised offline with
  Piper (en_US-lessac-medium) so the build needs no cloud service.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

import yaml

DISPLAY = os.environ.get("DISPLAY", ":99")
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_MONO = "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"
VOICE = os.environ.get("PIPER_VOICE", "/work/voices/en_US-lessac-medium.onnx")
SPLASH_BG = "/usr/share/plymouth/themes/orionx-phoenix/background.png"
GUIDE_HTML = "file:///usr/share/doc/orionx/User_Guide.html"
PIVOTGLASS_URL = "http://127.0.0.1:8765/"
LOOKUP = "/opt/orionx/nucleotide/lookup.json"

# Screen coordinates on the 1280x720 demo display (measured from screenshots
# of the seeded XFCE session — panel is 30 px tall at the top).
PANEL_MENU = (40, 15)          # "Orion-X" applications-menu button
CC_POS, CC_SIZE = (40, 60), (1200, 620)
CC_SIDEBAR_X = 130
CC_SECTION_Y = {"network": 174, "mesh": 228, "comms": 282, "awareness": 336,
                "ir": 390, "nebula": 444, "healing": 498}
CC_TIER2_RADIO = (285, 493)    # "Tier 2 · Deception" radio label in Awareness (label is part of the button)
MENU_ORION_Y = int(os.environ.get("MENU_ORION_Y", "0"))  # y of the "Orion" submenu entry (0 = skip hover)

W, H, FPS = 1280, 720, 24


def log(msg: str) -> None:
    print(f"[demo] {msg}", flush=True)


def sh(cmd: str, check: bool = False, capture: bool = False, timeout: int | None = None) -> str:
    r = subprocess.run(cmd, shell=True, check=check, timeout=timeout,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None, text=True)
    return r.stdout if capture else ""


def xdo(args: str) -> None:
    sh(f"DISPLAY={DISPLAY} xdotool {args}")


def mouse(x: int, y: int, ms: int = 0) -> None:
    xdo(f"mousemove {x} {y}")
    if ms:
        time.sleep(ms / 1000)


def click(x: int, y: int) -> None:
    xdo(f"mousemove {x} {y} click 1")


def type_line(text: str, delay_ms: int = 38) -> None:
    xdo(f"type --delay {delay_ms} {shlex.quote(text)}")
    xdo("key Return")


def win_ids(pattern: str, by: str = "--class") -> list[str]:
    out = sh(f"DISPLAY={DISPLAY} xdotool search --onlyvisible {by} {shlex.quote(pattern)} 2>/dev/null", capture=True)
    return [w for w in out.split() if w.strip()]


def wait_win(pattern: str, by: str = "--class", timeout: float = 20) -> str | None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        ids = win_ids(pattern, by)
        if ids:
            return ids[-1]
        time.sleep(0.5)
    return None


def kill(pattern: str) -> None:
    # Bracket trick so the pkill pattern never matches its own command line.
    sh(f"pkill -f {shlex.quote(pattern[:-1] + '[' + pattern[-1] + ']')} 2>/dev/null")


def kill_apps() -> None:
    for p in ("control_center/app", "orionx-control-center", "orionx-cockpit", "xfce4-terminal"):
        kill(p)
    time.sleep(1.0)


def launch(cmd: str) -> None:
    subprocess.Popen(f"DISPLAY={DISPLAY} nohup {cmd} >/dev/null 2>&1 &", shell=True)


def media_duration(path: Path) -> float:
    out = sh(f"ffprobe -v error -show_entries format=duration -of csv=p=0 {shlex.quote(str(path))}", capture=True)
    try:
        return float(out.strip())
    except ValueError:
        return 0.0


# --------------------------------------------------------------------------
# Narration
# --------------------------------------------------------------------------
def synth(text: str, wav: Path) -> float:
    if not wav.exists():
        p = subprocess.run(["piper", "-m", VOICE, "-f", str(wav), "--length-scale", "1.04", "--sentence-silence", "0.35"],
                           input=text, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if p.returncode != 0 or not wav.exists():
            raise SystemExit(f"piper failed for {wav}: {p.stdout[-400:]}")
    return media_duration(wav)


def split_cues(text: str, start: float, dur: float) -> list[tuple[float, float, str]]:
    """Sentence-level cues spread proportionally over the narration duration."""
    sents = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s.strip()]
    total = sum(len(s) for s in sents) or 1
    cues, t = [], start
    for s in sents:
        d = dur * len(s) / total
        cues.append((t, t + d, s))
        t += d
    return cues


def vtt_ts(t: float) -> str:
    ms = int(round((t - math.floor(t)) * 1000))
    t = int(math.floor(t))
    return f"{t // 3600:02d}:{(t % 3600) // 60:02d}:{t % 60:02d}.{ms:03d}"


# --------------------------------------------------------------------------
# Recording primitives
# --------------------------------------------------------------------------
class Recorder:
    def __init__(self, path: Path, secs: float):
        self.path, self.secs = path, secs
        self.t0 = time.time()
        self.proc = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-y", "-f", "x11grab", "-framerate", str(FPS),
             "-video_size", f"{W}x{H}", "-i", DISPLAY, "-t", f"{secs:.2f}",
             "-c:v", "libx264", "-preset", "veryfast", "-crf", "18", "-pix_fmt", "yuv420p", str(path)])

    def at(self, t: float) -> None:
        """Sleep until t seconds into the recording."""
        delay = self.t0 + t - time.time()
        if delay > 0:
            time.sleep(delay)

    def finish(self) -> None:
        self.at(self.secs + 0.3)
        self.proc.wait(timeout=60)


def glide(points: list[tuple[int, int]], total: float) -> None:
    """Move the mouse smoothly through points over `total` seconds."""
    steps = max(1, len(points) - 1)
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        n = 18
        for i in range(1, n + 1):
            mouse(int(x0 + (x1 - x0) * i / n), int(y0 + (y1 - y0) * i / n))
            time.sleep(total / steps / n)


# --------------------------------------------------------------------------
# Scenes — each returns the path of a silent MP4 exactly `dur` seconds long
# --------------------------------------------------------------------------
def scene_splash(out: Path, dur: float, cfg: dict) -> Path:
    title = "ORION-X  PHOENIX EDITION"
    sub = f"{cfg['version']}  ·  live cyberdeck for the Good Guys"
    # Caption band sits ABOVE the scene-heading card (which occupies y=H-96..H-44).
    t1, t2 = out.with_suffix(".title.txt"), out.with_suffix(".sub.txt")
    t1.write_text(title); t2.write_text(sub)
    vf = (f"scale={W*1.08:.0f}:-2,zoompan=z='1.0+0.06*on/{int(dur*FPS)}':d={int(dur*FPS)}:s={W}x{H}:fps={FPS},"
          f"drawbox=x=0:y={H-240}:w={W}:h=120:color=black@0.45:t=fill,"
          f"drawtext=fontfile={FONT_BOLD}:textfile={t1}:fontcolor=0x33d9ff:fontsize=40:x=(w-text_w)/2:y={H-224},"
          f"drawtext=fontfile={FONT_REG}:textfile={t2}:fontcolor=white:fontsize=22:x=(w-text_w)/2:y={H-166},"
          f"fade=t=in:st=0:d=0.8")
    sh(f"ffmpeg -v error -y -loop 1 -i {SPLASH_BG} -t {dur:.2f} -vf \"{vf}\" -r {FPS} "
       f"-c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p {out}", check=True)
    return out


def scene_desktop(out: Path, dur: float, cfg: dict) -> Path:
    kill_apps()
    for w in win_ids("firefox"):
        xdo(f"windowminimize {w}")
    mouse(640, 400)
    time.sleep(1.5)
    rec = Recorder(out, dur)
    rec.at(0.8)
    glide([(640, 400), (1000, 300), (1120, 15)], 2.2)          # drift up to the panel widgets
    rec.at(dur * 0.42)
    glide([(1120, 15), PANEL_MENU], 1.0)
    click(*PANEL_MENU)                                           # open the Orion-X menu
    if MENU_ORION_Y:
        rec.at(dur * 0.42 + 1.8)
        glide([PANEL_MENU, (60, MENU_ORION_Y)], 0.9)            # hover the "Orion" group
    rec.at(dur - 1.6)
    xdo("key Escape")
    rec.finish()
    return out


def cc_open(section: str) -> None:
    for w in win_ids("firefox"):                                 # keep the browser out of the backdrop
        xdo(f"windowminimize {w}")
    if not win_ids("orionx-control-center"):
        launch("orionx-control-center")
        w = wait_win("orionx-control-center")
        if w:
            xdo(f"windowmove {w} {CC_POS[0]} {CC_POS[1]}")
            xdo(f"windowsize {w} {CC_SIZE[0]} {CC_SIZE[1]}")
            time.sleep(1.0)
    w = win_ids("orionx-control-center")
    if w:
        xdo(f"windowactivate {w[-1]}")
    click(CC_SIDEBAR_X, CC_SECTION_Y[section])
    time.sleep(1.2)


def scene_cc_awareness(out: Path, dur: float, cfg: dict) -> Path:
    cc_open("awareness")
    mouse(700, 300)
    rec = Recorder(out, dur)
    rec.at(1.0)
    glide([(700, 300), (420, 230), (420, 360)], 3.0)             # read the live-health block
    rec.at(dur * 0.55)
    glide([(420, 360), CC_TIER2_RADIO], 1.2)                     # point at the posture tiers
    rec.at(dur * 0.55 + 2.5)
    glide([CC_TIER2_RADIO, (420, 600)], 2.0)                     # down to R.A.I.N.
    rec.finish()
    return out


def scene_cc_nebula(out: Path, dur: float, cfg: dict) -> Path:
    cc_open("nebula")
    mouse(500, 190)
    rec = Recorder(out, dur)
    rec.at(1.0)
    glide([(500, 190), (640, 215), (640, 560)], 3.5)             # status line -> tools list
    rec.at(dur * 0.6)
    glide([(640, 560), (900, 570), (400, 575)], 3.0)
    rec.finish()
    return out


def scene_cockpit(out: Path, dur: float, cfg: dict) -> Path:
    kill_apps()
    launch("orionx-cockpit --demo --fullscreen")
    time.sleep(6.0)                                              # let the demo feed populate
    mouse(1270, 700)
    rec = Recorder(out, dur)
    rec.at(dur * 0.5)
    glide([(1270, 700), (1010, 230), (1000, 450)], 3.0)          # gauge -> network
    rec.finish()
    return out


def scene_toolkit(out: Path, dur: float, cfg: dict) -> Path:
    kill_apps()
    launch("xfce4-terminal --maximize --title='Orion-X Terminal'")
    wait_win("xfce4-terminal")
    time.sleep(2.0)
    mouse(1270, 700)
    rec = Recorder(out, dur)
    cmds = [
        "cat /etc/orionx-version",
        f"nucleotide lookup {LOOKUP} http://10.0.0.5/wp-login.php http://10.0.0.5/actuator/env | head -8",
        "tshark -v | head -1 ; vol -h | head -1",
        "ap --version",
    ]
    slots = [0.6, 0.30, 0.66, 0.84]
    for cmd, frac in zip(cmds, slots):
        rec.at(0.6 if frac == 0.6 else dur * frac)
        type_line(cmd)
    rec.finish()
    return out


def firefox_fullscreen(on: bool) -> None:
    """Toggle F11 only when the window is not already in the requested state."""
    w = wait_win("firefox")
    if not w:
        return
    geo = sh(f"DISPLAY={DISPLAY} xdotool getwindowgeometry {w}", capture=True)
    is_full = f"{W}x{H}" in geo
    if is_full != on:
        xdo(f"windowactivate --sync {w}")
        xdo("key F11")
        time.sleep(1.5)


def firefox_goto(url: str) -> None:
    w = wait_win("firefox")
    if not w:
        launch(f"firefox-esr {shlex.quote(url)}")
        w = wait_win("firefox", timeout=30)
    xdo(f"windowactivate {w}")
    time.sleep(0.6)
    xdo("key ctrl+l")
    time.sleep(0.3)
    xdo(f"type --delay 12 {shlex.quote(url)}")
    xdo("key Return")


def scene_pivotglass(out: Path, dur: float, cfg: dict) -> Path:
    kill_apps()
    firefox_fullscreen(False)
    firefox_goto(PIVOTGLASS_URL)
    time.sleep(3.0)
    firefox_fullscreen(True)                                     # full-screen page
    time.sleep(1.5)
    mouse(1270, 700)
    rec = Recorder(out, dur)
    rec.at(1.5)
    glide([(1270, 700), (640, 300)], 1.5)                        # hold on the header + pursuit brief
    rec.at(dur * 0.58)
    for _ in range(8):
        xdo("key Down"); time.sleep(0.28)                        # then ease down to the workbench
    rec.finish()
    return out


def scene_guide(out: Path, dur: float, cfg: dict) -> Path:
    # Prepare both pages in adjacent tabs BEFORE recording so the switch is a
    # clean ctrl+Tab (no URL bar, no autocomplete dropdown, no page-load wait).
    firefox_fullscreen(False)                                    # URL bar needed for navigation
    firefox_goto(GUIDE_HTML)
    time.sleep(2.5)
    xdo("key ctrl+t"); time.sleep(0.6)
    xdo(f"type --delay 12 {shlex.quote(cfg['release_url'])}"); xdo("key Return")
    time.sleep(8.0)                                              # real GitHub page over the network
    xdo("key ctrl+Prior")                                        # back to the guide tab
    time.sleep(0.8)
    firefox_fullscreen(True)
    time.sleep(1.0)
    mouse(1270, 700)
    rec = Recorder(out, dur)
    rec.at(1.2)
    for _ in range(14):
        xdo("key Down"); time.sleep(0.2)
    rec.at(dur * 0.5)
    xdo("key ctrl+Next")                                         # -> the release page tab
    rec.at(dur * 0.5 + 2.5)
    for _ in range(8):
        xdo("key Down"); time.sleep(0.25)
    rec.finish()
    firefox_fullscreen(False)
    return out


SCENES = {
    "splash": scene_splash, "desktop": scene_desktop, "cc-awareness": scene_cc_awareness,
    "cc-nebula": scene_cc_nebula, "cockpit": scene_cockpit, "toolkit": scene_toolkit,
    "pivotglass": scene_pivotglass, "guide": scene_guide,
}


# --------------------------------------------------------------------------
# Assembly
# --------------------------------------------------------------------------
def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace(":", "\\:").replace("'", "’").replace("%", "\\%")


def assemble(scenes: list[dict], cfg: dict, out_dir: Path, base: str) -> None:
    parts, offset, cues, transcript = [], 0.0, [], []
    for i, sc in enumerate(scenes):
        dur = sc["dur"]
        heading = esc(sc["heading"])
        vf = (f"fade=t=in:st=0:d=0.4,fade=t=out:st={dur-0.4:.2f}:d=0.4,"
              f"drawbox=x=0:y=0:w={W}:h=0:color=black@0:t=fill,"
              f"drawbox=enable='between(t,0.6,4.6)':x=40:y={H-96}:w={min(W-80, 34 + 22*len(sc['heading']))}:h=52:color=0x0e1116@0.82:t=fill,"
              f"drawbox=enable='between(t,0.6,4.6)':x=40:y={H-96}:w=6:h=52:color=0xff6a13:t=fill,"
              f"drawtext=enable='between(t,0.6,4.6)':fontfile={FONT_BOLD}:text='{heading}':fontcolor=white:fontsize=26:x=62:y={H-96+13}")
        part = out_dir / f"part_{i:02d}.mp4"
        sh(f"ffmpeg -v error -y -i {sc['video']} -i {sc['wav']} -filter_complex "
           f"\"[0:v]{vf}[v];[1:a]adelay=400|400,apad=whole_dur={dur:.2f}[a]\" -map '[v]' -map '[a]' "
           f"-t {dur:.2f} -r {FPS} -c:v libx264 -preset medium -crf 22 -pix_fmt yuv420p -c:a aac -b:a 96k {part}", check=True)
        parts.append(part)
        start = offset + 0.4
        cues += split_cues(sc["narration"], start, sc["narr"])
        transcript.append((offset, sc["heading"], sc["narration"]))
        offset += dur

    lst = out_dir / "concat.txt"
    lst.write_text("".join(f"file '{p}'\n" for p in parts))
    final = out_dir / f"{base}.mp4"
    sh(f"ffmpeg -v error -y -f concat -safe 0 -i {lst} -c copy -movflags +faststart {final}", check=True)

    # Captions
    vtt = ["WEBVTT", ""]
    for a, b, text in cues:
        vtt += [f"{vtt_ts(a)} --> {vtt_ts(b)}", text, ""]
    (out_dir / f"{base}.vtt").write_text("\n".join(vtt))

    # Transcript
    total = int(round(offset))
    md = [f"# {cfg['title']} — transcript", "",
          f"**Runtime:** {total // 60} minutes, {total % 60} seconds<br>",
          f"**Release:** {cfg['version']} (pre-release)<br>",
          "**Recorded from:** the beta's own applications and desktop, running from the release "
          "scripts in a virtual X session; the Cockpit shows its built-in synthetic demo feed, and the "
          "Nebula runtime state is a stand-in for the reference deck's verified state (no model is run "
          "while recording). Narration is synthesised offline.", ""]
    for t, heading, text in transcript:
        md += [f"## {int(t)//60:02d}:{int(t)%60:02d} — {heading}", "", text, ""]
    (out_dir / f"{base}-transcript.md").write_text("\n".join(md))

    # Poster: a frame from the desktop scene with the title. Texts go through
    # textfile= so drawtext never has to parse dashes/colons/parentheses.
    desk = next((s for s in scenes if s["id"] == "desktop"), scenes[0])
    t1, t2 = out_dir / "poster-title.txt", out_dir / "poster-sub.txt"
    t1.write_text(cfg["title"])
    t2.write_text(f"{cfg['version']}  ·  click to watch ({total // 60}:{total % 60:02d})")
    sh(f"ffmpeg -v error -y -ss 2.5 -i {desk['video']} -frames:v 1 -vf "
       f"\"drawbox=x=0:y={H-150}:w={W}:h=150:color=black@0.55:t=fill,"
       f"drawtext=fontfile={FONT_BOLD}:textfile={t1}:fontcolor=white:fontsize=36:x=(w-text_w)/2:y={H-122},"
       f"drawtext=fontfile={FONT_REG}:textfile={t2}:fontcolor=0x33d9ff:fontsize=24:x=(w-text_w)/2:y={H-66}\" "
       f"{out_dir / (base + '-poster.png')}", check=True)
    log(f"final: {final} ({media_duration(final):.1f}s, {final.stat().st_size/1e6:.1f} MB)")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scenes", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", help="comma-separated scene ids to (re)record")
    ap.add_argument("--min-dur", type=float, default=7.0)
    args = ap.parse_args()
    cfg = yaml.safe_load(Path(args.scenes).read_text())
    out_dir = Path(args.out); out_dir.mkdir(parents=True, exist_ok=True)
    base = f"orionx-guided-demo-{cfg['version']}"
    only = set(args.only.split(",")) if args.only else None

    scenes = []
    for sc in cfg["scenes"]:
        wav = out_dir / f"{sc['id']}.wav"
        narr = synth(sc["narration"], wav)
        dur = round(max(narr + 1.4, args.min_dur), 2)
        video = out_dir / f"{sc['id']}.mp4"
        if only is None or sc["id"] in only or not video.exists():
            log(f"scene {sc['id']}: narration {narr:.1f}s -> recording {dur:.1f}s")
            SCENES[sc["visual"]](video, dur, cfg)
        scenes.append({**sc, "wav": wav, "narr": narr, "dur": dur, "video": video})
    kill_apps()
    assemble(scenes, cfg, out_dir, base)
    return 0


if __name__ == "__main__":
    sys.exit(main())
