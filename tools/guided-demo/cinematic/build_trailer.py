#!/usr/bin/env python3
"""
build_trailer.py — assemble the cinematic release trailer from trailer.yaml.

Inputs
  trailer.yaml                 shots, narration, on-screen text (single source)
  <capture>/frames.csv+frames  real-ISO footage from qemu_capture.py
  <capture>/audio.wav          the guest's own audio (R.A.I.N. cues and voice)
  render_music.py              the procedural score, cued from the shot list

Outputs (--out DIR, basename orionx-trailer-<version>)
  .mp4  1920x1080 H.264 + AAC, loudness-normalised (-14 LUFS)
  .vtt  WebVTT captions of the narration
  -transcript.md
  -poster.png

    python3 build_trailer.py --script trailer.yaml --capture tmp/video/capture-main \
        --out tmp/video/out [--preview]   # --preview renders 960x540 at 15 fps

Host requirements: python3 with numpy, pillow, soundfile, pyyaml, kokoro-onnx
(model files under --models), ffmpeg. The macOS fonts named below are used
when present; otherwise DejaVu is used.

@decision DEC-PHASE12-064
@title The release trailer is derived from trailer.yaml + real-ISO footage
@status accepted
@rationale Same contract as DEC-PHASE12-018: narration, captions and
  transcript come from one file so they cannot drift, and every UI frame is
  the shipped ISO running (qemu_capture.py). Narration uses Kokoro (open
  weights, Apache-2.0) because the user asked for a natural, Descript-class
  voice; Piper/espeak, which the deck itself uses, sound robotic in a trailer.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import soundfile as sf
import yaml
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE))
import render_music  # noqa: E402

SR = 48000
HOME = Path.home()


def _font(cands: list[str], size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    for c in cands:
        p = Path(os.path.expanduser(c))
        if p.exists():
            try:
                return ImageFont.truetype(str(p), size, index=index)
            except OSError:
                continue
    return ImageFont.truetype("DejaVuSans.ttf", size)


DISPLAY = ["~/Library/Fonts/nulshock bd.ttf"]
COND = ["/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf"]
MONO = ["~/Library/Fonts/SourceCodePro-Medium.ttf", "/usr/share/fonts/truetype/hack/Hack-Regular.ttf"]
MONOB = ["~/Library/Fonts/SourceCodePro-Bold.ttf", "/usr/share/fonts/truetype/hack/Hack-Bold.ttf"]
SANS = ["~/Library/Fonts/Overpass-VariableFont_wght.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]

# Palette (the deck's own: Phoenix orange accent on near-black, cyan/green signals)
BG = (7, 9, 13)
ORANGE = (255, 87, 34)
AMBER = (255, 179, 0)
CYAN = (34, 211, 238)
GREEN = (12, 250, 84)
RED = (255, 59, 48)
TEXT = (230, 237, 243)
DIM = (91, 107, 122)
PANEL = (16, 21, 30)

WALLPAPER = REPO / "iso/config/includes.chroot/opt/orionx/theme/wallpapers/orionx-phoenix-wallpaper.png"
RAIN_DIR = REPO / "iso/config/includes.chroot/usr/share/orionx/rain"


def ease(x: float) -> float:
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def ease_out(x: float) -> float:
    x = min(max(x, 0.0), 1.0)
    return 1 - (1 - x) ** 3


def lerp(a, b, t):
    return a + (b - a) * t


# ------------------------------------------------------------------ narration
def synth_narration(shots: list[dict], cfg: dict, models: Path, cache: Path) -> dict[str, np.ndarray]:
    """Kokoro TTS per shot (cached by text+voice); returns 48 kHz mono float arrays."""
    from kokoro_onnx import Kokoro
    cache.mkdir(parents=True, exist_ok=True)
    k = None
    voice, speed = cfg.get("voice", "af_heart"), float(cfg.get("voice_speed", 0.95))
    out = {}
    for s in shots:
        text = s.get("narration")
        if not text:
            continue
        key = f"{voice}-{speed}-" + hashlib.sha256(text.encode()).hexdigest()[:12]
        wav = cache / f"{s['id']}-{key}.wav"
        if not wav.exists():
            if k is None:
                k = Kokoro(str(models / "kokoro-v1.0.onnx"), str(models / "voices-v1.0.bin"))
            lang = "en-gb" if voice.startswith("b") else "en-us"
            samples, sr = k.create(text, voice=voice, speed=speed, lang=lang)
            sf.write(wav, samples, sr)
        a, sr = sf.read(wav, dtype="float32")
        if a.ndim > 1:
            a = a.mean(axis=1)
        a = resample(a, sr, SR)
        a = trim_silence(a)
        out[s["id"]] = a
        print(f"[tts] {s['id']}: {len(a) / SR:.2f}s", flush=True)
    return out


def resample(a: np.ndarray, sr: int, target: int) -> np.ndarray:
    if sr == target:
        return a.astype(np.float32)
    n = int(len(a) * target / sr)
    x = np.linspace(0, len(a) - 1, n)
    return np.interp(x, np.arange(len(a)), a).astype(np.float32)


def trim_silence(a: np.ndarray, thr: float = 0.004) -> np.ndarray:
    idx = np.where(np.abs(a) > thr)[0]
    if len(idx) == 0:
        return a
    s, e = max(idx[0] - int(0.02 * SR), 0), min(idx[-1] + int(0.08 * SR), len(a))
    return a[s:e]


# ------------------------------------------------------------------ capture
@dataclass
class Capture:
    root: Path
    scenes: dict[str, list[tuple[float, Path]]] = field(default_factory=dict)
    extra_roots: list[Path] = field(default_factory=list)

    @classmethod
    def load(cls, root: Path) -> "Capture":
        c = cls(root)
        with (root / "frames.csv").open() as fh:
            for row in csv.reader(fh):
                if len(row) != 3:
                    continue
                t, scene, name = float(row[0]), row[1], row[2]
                p = root / "frames" / name
                if p.exists() and p.stat().st_size > 0:
                    c.scenes.setdefault(scene, []).append((t, p))
        return c

    def frames(self, scene: str, window=(0.0, 1.0)) -> list[tuple[float, Path]]:
        fr = self.scenes.get(scene, [])
        if not fr:
            return []
        a, b = int(window[0] * (len(fr) - 1)), int(math.ceil(window[1] * (len(fr) - 1)))
        return fr[a:b + 1] or fr[-1:]


class FrameCache:
    def __init__(self, size: tuple[int, int], cap: int = 48):
        self.size, self.cap, self.d = size, cap, {}

    def get(self, p: Path) -> Image.Image:
        im = self.d.get(p)
        if im is None:
            im = Image.open(p).convert("RGB")
            if len(self.d) >= self.cap:
                self.d.pop(next(iter(self.d)))
            self.d[p] = im
        return im


# ------------------------------------------------------------------ text helpers
def glow_text(size, xy, text, font, fill, glow=10, glow_alpha=180, anchor="mm", spacing=0):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    if spacing:
        draw_tracked(d, xy, text, font, fill, spacing, anchor)
    else:
        d.text(xy, text, font=font, fill=fill, anchor=anchor)
    if glow:
        g = layer.filter(ImageFilter.GaussianBlur(glow))
        a = g.getchannel("A").point(lambda v: min(255, int(v * glow_alpha / 100)))
        g.putalpha(a)
        base = Image.new("RGBA", size, (0, 0, 0, 0))
        base.alpha_composite(g)
        base.alpha_composite(layer)
        return base
    return layer


def text_width(font, text, spacing=0):
    return font.getlength(text) + spacing * max(len(text) - 1, 0)


def draw_tracked(d, xy, text, font, fill, spacing, anchor="mm"):
    w = text_width(font, text, spacing)
    x, y = xy
    if anchor[0] == "m":
        x -= w / 2
    elif anchor[0] == "r":
        x -= w
    for ch in text:
        d.text((x, y), ch, font=font, fill=fill, anchor="l" + anchor[1])
        x += font.getlength(ch) + spacing


# ------------------------------------------------------------------ renderer
class Renderer:
    def __init__(self, W: int, H: int, fps: int, cap: Capture | None):
        self.W, self.H, self.fps = W, H, fps
        self.s = W / 1920.0
        self.cap = cap
        self.cache = FrameCache((W, H))
        self.f = {
            "display": lambda n: _font(DISPLAY, int(n * self.s)),
            "cond": lambda n: _font(COND, int(n * self.s)),
            "mono": lambda n: _font(MONO, int(n * self.s)),
            "monob": lambda n: _font(MONOB, int(n * self.s)),
            "sans": lambda n: _font(SANS, int(n * self.s)),
        }
        self._fonts = {}
        yy, xx = np.mgrid[0:H, 0:W]
        r = np.sqrt(((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2)
        self.vignette = np.clip(1.08 - 0.42 * r ** 2.2, 0.45, 1.0).astype(np.float32)[..., None]
        rng = np.random.default_rng(3)
        self.grain = [rng.normal(0, 5.5, (H // 2, W // 2)).astype(np.float32) for _ in range(6)]
        self.static: dict = {}
        self.wall = Image.open(WALLPAPER).convert("RGB") if WALLPAPER.exists() else None

    def font(self, kind: str, n: int):
        key = (kind, n)
        if key not in self._fonts:
            self._fonts[key] = self.f[kind](n)
        return self._fonts[key]

    # --- finishing (applied to every frame) ---
    def finish(self, im: Image.Image, frame_no: int, grade=True) -> np.ndarray:
        a = np.asarray(im, dtype=np.float32)
        if grade:
            # gentle teal-shadow / warm-highlight split tone + contrast
            lum = a.mean(axis=2, keepdims=True) / 255.0
            shadow = np.array([-4, 3, 8], np.float32)
            high = np.array([6, 2, -5], np.float32)
            a = a + shadow * (1 - lum) + high * lum
            a = (a - 128) * 1.06 + 128
        a *= self.vignette
        g = self.grain[frame_no % len(self.grain)]
        g = np.repeat(np.repeat(g, 2, axis=0), 2, axis=1)[: self.H, : self.W]
        a += g[..., None]
        return np.clip(a, 0, 255).astype(np.uint8)

    # --- capture shots ---
    def capture_frame(self, shot: dict, lt: float, dur: float) -> Image.Image:
        frames = shot["_frames"]
        if not frames:
            return self.missing(shot)
        n = len(frames)
        pos = (lt / max(dur, 1e-3)) * (n - 1)
        i = int(pos)
        frac = pos - i
        a = self.cache.get(frames[min(i, n - 1)][1])
        if frac > 0.02 and i + 1 < n:
            b = self.cache.get(frames[i + 1][1])
            if b.size == a.size:
                a = Image.blend(a, b, frac)
        z = shot.get("zoom") or {"from": [0, 0, 1, 1], "to": [0, 0, 1, 1]}
        e = ease(lt / max(dur, 1e-3))
        rect = [lerp(z["from"][k], z["to"][k], e) for k in range(4)]
        sw, sh = a.size
        x0, y0 = rect[0] * sw, rect[1] * sh
        w, h = rect[2] * sw, rect[3] * sh
        x0, y0 = min(max(x0, 0), sw - w), min(max(y0, 0), sh - h)
        return a.resize((self.W, self.H), Image.LANCZOS if self.W >= 1280 else Image.BILINEAR,
                        box=(x0, y0, x0 + w, y0 + h))

    def missing(self, shot: dict) -> Image.Image:
        im = Image.new("RGB", (self.W, self.H), BG)
        d = ImageDraw.Draw(im)
        d.text((self.W / 2, self.H / 2), f"[missing footage: {shot.get('scene')}]",
               font=self.font("mono", 36), fill=RED, anchor="mm")
        return im

    def montage_frame(self, shot: dict, lt: float, dur: float) -> Image.Image:
        frames = shot["_frames"]
        if not frames:
            return self.missing(shot)
        cuts = int(shot.get("cuts", 6))
        picks = [frames[int(k * (len(frames) - 1) / max(cuts - 1, 1))] for k in range(cuts)]
        seg = dur / cuts
        k = min(int(lt / seg), cuts - 1)
        st = (lt - k * seg) / seg
        im = self.cache.get(picks[k][1])
        sw, sh = im.size
        zoom = 1.0 + 0.06 * st + (0.05 if k % 2 else 0)
        w, h = sw / zoom, sh / zoom
        ox = (sw - w) * (0.5 + (0.2 if k % 3 == 0 else -0.15) * st)
        oy = (sh - h) * 0.5
        out = im.resize((self.W, self.H), Image.BILINEAR, box=(ox, oy, ox + w, oy + h))
        if st < 0.12:  # cut flash
            out = Image.blend(out, Image.new("RGB", out.size, (255, 240, 230)), (0.12 - st) / 0.12 * 0.35)
        return out

    # --- titles ---
    def title_frame(self, shot: dict, lt: float, dur: float) -> Image.Image:
        style = shot["text"]["style"]
        lines = shot["text"]["lines"]
        W, H = self.W, self.H
        im = Image.new("RGB", (W, H), BG)
        if style in ("title", "finale") and self.wall is not None:
            z = 1.12 - 0.08 * (lt / dur)
            sw, sh = self.wall.size
            w, h = sw / z, sh / z
            bg = self.wall.resize((W, H), Image.BILINEAR, box=((sw - w) / 2, (sh - h) / 2, (sw + w) / 2, (sh + h) / 2))
            bg = ImageEnhance.Brightness(bg).enhance(0.34 if style == "title" else 0.46)
            # the wallpaper carries its own wordmark right of the bird; fade it out
            mask = self.static.get("wallmask")
            if mask is None:
                ramp = np.clip((0.47 - np.linspace(0, 1, W)) / 0.12, 0, 1) ** 1.4
                mask = Image.fromarray((np.tile(ramp, (H, 1)) * 255).astype(np.uint8), "L")
                self.static["wallmask"] = mask
            m = mask.point(lambda v: int(v * ease(lt / 1.2)))
            im = Image.composite(bg, im, m)
        rgba = im.convert("RGBA")
        if style == "terminal":
            f = self.font("monob", 54)
            shown = 0.0
            for idx, line in enumerate(lines):
                start = 0.3 + idx * 1.1
                n = int(max(0.0, lt - start) * 22)
                txt = line[:n]
                cursor = "█" if (int(lt * 2.5) % 2 == 0 and n < len(line) + 6 and lt > start) else ""
                y = H / 2 - 40 + idx * 80
                col = AMBER if idx == 0 else TEXT
                rgba.alpha_composite(glow_text((W, H), (W / 2, y), txt + cursor, f, col + (255,), glow=6, glow_alpha=120))
                shown += 1
        elif style in ("title", "finale"):
            f1 = self.font("display", 150 if style == "title" else 132)
            f2 = self.font("cond", 64)
            f3 = self.font("mono", 40)
            a = ease_out((lt - 0.15) / 1.4)
            track = int(lerp(80, 22, a) * self.s)
            col1 = TEXT + (int(255 * a),)
            cxT = W * 0.66
            layer = glow_text((W, H), (cxT, H / 2 - 60 * self.s), lines[0], f1, col1, glow=int(18 * self.s),
                              glow_alpha=140, spacing=track)
            rgba.alpha_composite(layer)
            a2 = ease_out((lt - 0.9) / 1.2)
            if len(lines) > 1:
                rgba.alpha_composite(glow_text((W, H), (cxT, H / 2 + 70 * self.s), lines[1], f2,
                                               ORANGE + (int(255 * a2),), glow=int(10 * self.s), glow_alpha=160,
                                               spacing=int(18 * self.s)))
            if len(lines) > 2:
                a3 = ease_out((lt - 1.8) / 1.0)
                rgba.alpha_composite(glow_text((W, H), (cxT, H / 2 + 160 * self.s), lines[2], f3,
                                               AMBER + (int(255 * a3),), glow=int(6 * self.s), glow_alpha=120,
                                               spacing=int(10 * self.s)))
            d = ImageDraw.Draw(rgba)
            lw = int(lerp(0, 420 * self.s, ease_out((lt - 0.6) / 1.3)))
            d.line([(cxT - lw, H / 2 + 18 * self.s), (cxT + lw, H / 2 + 18 * self.s)], fill=ORANGE + (200,), width=max(1, int(2 * self.s)))
        elif style == "chapter":
            f = self.font("cond", 150)
            # glitch-in: RGB split that settles
            g = max(0.0, 1 - lt / 0.45)
            off = int(22 * g * self.s)
            base = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            for dx, col in ((-off, (255, 40, 40)), (off, (40, 230, 255)), (0, TEXT)):
                lay = glow_text((W, H), (W / 2 + dx, H / 2), lines[0], f, col + (255 if dx == 0 else int(200 * g),),
                                glow=int(14 * self.s) if dx == 0 else 0, glow_alpha=120, spacing=int(14 * self.s))
                base.alpha_composite(lay)
            rgba.alpha_composite(base)
            d = ImageDraw.Draw(rgba)
            bw = int(lerp(0, 180 * self.s, ease_out(lt / 0.8)))
            d.rectangle([W / 2 - bw, H / 2 + 92 * self.s, W / 2 + bw, H / 2 + 98 * self.s], fill=ORANGE + (255,))
        elif style == "endcard":
            f1 = self.font("mono", 52)
            f2 = self.font("sans", 34)
            a = ease_out(lt / 1.0)
            rgba.alpha_composite(glow_text((W, H), (W / 2, H / 2 - 30 * self.s), lines[0], f1, AMBER + (int(255 * a),), glow=8, glow_alpha=110))
            rgba.alpha_composite(glow_text((W, H), (W / 2, H / 2 + 50 * self.s), lines[1], f2, DIM + (int(255 * a),), glow=0))
        # fade out at the end of finale/endcard
        out = rgba.convert("RGB")
        if style in ("finale", "endcard") and lt > dur - 1.2:
            out = Image.blend(out, Image.new("RGB", out.size, (0, 0, 0)), ease((lt - (dur - 1.2)) / 1.2))
        return out

    def black_frame(self, shot: dict, lt: float, dur: float) -> Image.Image:
        if shot.get("text"):
            return self.title_frame(shot, lt, dur)
        return Image.new("RGB", (self.W, self.H), (0, 0, 0))

    # --- overlays: chapter label + tag ---
    def overlays(self, im: Image.Image, shot: dict, lt: float, dur: float) -> Image.Image:
        if not shot.get("chapter") and not shot.get("tag"):
            return im
        rgba = im.convert("RGBA")
        d = ImageDraw.Draw(rgba)
        s = self.s
        if shot.get("chapter"):
            a = ease_out((lt - 0.2) / 0.6) * (1 - ease((lt - (dur - 0.5)) / 0.5))
            if a > 0:
                f = self.font("cond", 54)
                x, y = 70 * s, self.H - 140 * s
                bar_w = int(lerp(0, 8 * s, a))
                plate = Image.new("RGBA", rgba.size, (0, 0, 0, 0))
                pd = ImageDraw.Draw(plate)
                tw = text_width(f, shot["chapter"], int(8 * s))
                pd.rectangle([x - 20 * s, y - 44 * s, x + tw + 40 * s, y + 40 * s], fill=(0, 0, 0, int(150 * a)))
                rgba.alpha_composite(plate)
                d.rectangle([x - 20 * s, y - 44 * s, x - 20 * s + bar_w, y + 40 * s], fill=ORANGE + (int(255 * a),))
                draw_tracked(d, (x, y), shot["chapter"], f, TEXT + (int(255 * a),), int(8 * s), anchor="lm")
        if shot.get("tag"):
            a = ease_out((lt - 0.6) / 0.6) * (1 - ease((lt - (dur - 0.5)) / 0.5))
            if a > 0:
                f = self.font("mono", 22)
                txt = shot["tag"]
                tw = f.getlength(txt)
                x, y = self.W - 60 * s - tw, self.H - 60 * s
                d.rectangle([x - 14 * s, y - 22 * s, x + tw + 14 * s, y + 18 * s], fill=(0, 0, 0, int(160 * a)))
                d.text((x, y), txt, font=f, fill=AMBER + (int(255 * a),), anchor="lm")
        return rgba.convert("RGB")

    # --- diagrams ---
    def diagram_frame(self, shot: dict, lt: float, dur: float) -> Image.Image:
        kind = shot["diagram"]
        fn = getattr(self, f"dg_{kind}")
        im = Image.new("RGBA", (self.W, self.H), BG + (255,))
        self._grid(im, lt)
        fn(im, lt, dur)
        return im.convert("RGB")

    def _grid(self, im, lt):
        d = ImageDraw.Draw(im)
        s = self.s
        step = int(60 * s)
        off = int((lt * 12 * s) % step)
        for x in range(-step, self.W + step, step):
            d.line([(x + off, 0), (x + off, self.H)], fill=(14, 20, 28, 255), width=1)
        for y in range(-step, self.H + step, step):
            d.line([(0, y + off), (self.W, y + off)], fill=(14, 20, 28, 255), width=1)

    def _heading(self, im, text, sub, lt):
        a = ease_out(lt / 0.6)
        s = self.s
        im.alpha_composite(glow_text(im.size, (90 * s, 90 * s), text, self.font("cond", 64), TEXT + (int(255 * a),),
                                     glow=int(8 * s), glow_alpha=90, anchor="lm", spacing=int(6 * s)))
        if sub:
            d = ImageDraw.Draw(im)
            d.text((92 * s, 140 * s), sub, font=self.font("mono", 26), fill=DIM + (int(255 * a),), anchor="lm")
            d.rectangle([90 * s, 165 * s, 90 * s + lerp(0, 260 * s, a), 169 * s], fill=ORANGE + (255,))

    def _box(self, im, box, title, lines, color, a, lit=1.0, title_size=34, line_size=22):
        if a <= 0:
            return
        s = self.s
        x0, y0, x1, y1 = box
        lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(lay)
        fill = tuple(int(lerp(PANEL[k], color[k] * 0.22 + PANEL[k] * 0.78, lit)) for k in range(3))
        d.rounded_rectangle(box, radius=int(14 * s), fill=fill + (int(235 * a),),
                            outline=color + (int(255 * a * (0.45 + 0.55 * lit)),), width=max(2, int(3 * s)))
        if lit > 0.05:
            gl = lay.filter(ImageFilter.GaussianBlur(int(16 * s)))
            gl.putalpha(gl.getchannel("A").point(lambda v: int(v * 0.8 * lit)))
            im.alpha_composite(gl)
        im.alpha_composite(lay)
        d = ImageDraw.Draw(im)
        cx = (x0 + x1) / 2
        ty = y0 + (y1 - y0) * (0.36 if lines else 0.5)
        d.text((cx, ty), title, font=self.font("cond", title_size), fill=(color if lit > 0.5 else TEXT) + (int(255 * a),), anchor="mm")
        for k, ln in enumerate(lines):
            d.text((cx, ty + (title_size * 0.75 + 6 + k * (line_size + 8)) * s), ln, font=self.font("mono", line_size),
                   fill=TEXT + (int(220 * a),), anchor="mm")

    def _arrow(self, im, p0, p1, color, a, prog=1.0, width=3, head=True):
        if a <= 0 or prog <= 0:
            return
        d = ImageDraw.Draw(im)
        s = self.s
        x = lerp(p0[0], p1[0], prog)
        y = lerp(p0[1], p1[1], prog)
        d.line([p0, (x, y)], fill=color + (int(255 * a),), width=max(1, int(width * s)))
        if head and prog >= 0.98:
            ang = math.atan2(p1[1] - p0[1], p1[0] - p0[0])
            L = 16 * s
            pts = [p1, (p1[0] - L * math.cos(ang - 0.45), p1[1] - L * math.sin(ang - 0.45)),
                   (p1[0] - L * math.cos(ang + 0.45), p1[1] - L * math.sin(ang + 0.45))]
            d.polygon(pts, fill=color + (int(255 * a),))

    def _dot(self, im, p, color, r=8, a=1.0, glow=True):
        s = self.s
        d = ImageDraw.Draw(im)
        if glow:
            lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
            ImageDraw.Draw(lay).ellipse([p[0] - r * 2.4 * s, p[1] - r * 2.4 * s, p[0] + r * 2.4 * s, p[1] + r * 2.4 * s], fill=color + (int(110 * a),))
            im.alpha_composite(lay.filter(ImageFilter.GaussianBlur(int(8 * s))))
        d.ellipse([p[0] - r * s, p[1] - r * s, p[0] + r * s, p[1] + r * s], fill=color + (int(255 * a),))

    def dg_bootchain(self, im, lt, dur):
        s = self.s
        self._heading(im, "BOOT CHAIN", "power-on → desktop · every stage is on the stick", lt)
        stages = [("FIRMWARE", ["UEFI or BIOS"]), ("BOOTLOADER", ["GRUB · isolinux"]), ("KERNEL 6.12", ["live-boot", "squashfs"]),
                  ("PLYMOUTH", ["Phoenix splash"]), ("FIRST BOOT", ["name · account", "WireGuard keys"]), ("DESKTOP", ["LightDM → XFCE", "autologin"])]
        n = len(stages)
        bw, gap = 250 * s, 46 * s
        total = n * bw + (n - 1) * gap
        x = (self.W - total) / 2
        y0, y1 = self.H / 2 - 110 * s, self.H / 2 + 110 * s
        t0, per = 0.5, (dur - 1.6) / n
        for i, (title, lines) in enumerate(stages):
            ts = t0 + i * per
            a = ease_out((lt - ts + 0.3) / 0.5)
            lit = ease((lt - ts) / 0.4) * (1 - 0.6 * ease((lt - ts - per) / 0.6)) if i < n - 1 else ease((lt - ts) / 0.4)
            color = ORANGE if i < 4 else (AMBER if i == 4 else GREEN)
            bx = x + i * (bw + gap)
            self._box(im, (bx, y0, bx + bw, y1), title, lines, color, a, lit)
            if i < n - 1:
                p0, p1 = (bx + bw + 6 * s, (y0 + y1) / 2), (bx + bw + gap - 6 * s, (y0 + y1) / 2)
                self._arrow(im, p0, p1, DIM, a, ease((lt - ts - per * 0.6) / 0.35))
        d = ImageDraw.Draw(im)
        prog = ease((lt - 0.4) / (dur - 1.2))
        d.rectangle([x, y1 + 70 * s, x + total, y1 + 74 * s], fill=(30, 38, 50, 255))
        d.rectangle([x, y1 + 70 * s, x + total * prog, y1 + 74 * s], fill=ORANGE + (255,))
        d.text((x, y1 + 104 * s), "read-only squashfs · changes live in RAM · nothing written to the host disk",
               font=self.font("mono", 24), fill=DIM + (255,), anchor="lm")

    def dg_eventbus(self, im, lt, dur):
        s = self.s
        self._heading(im, "ONE EVENT BUS", "producers publish once · R.A.I.N. sounds it · the Cockpit shows it", lt)
        prods = ["Suricata IDS", "Zeek notices", "scanwatch", "health monitor", "posture daemon", "orionx-event CLI"]
        px0, px1 = 120 * s, 470 * s
        top = 250 * s
        ph = 92 * s
        bus = (760 * s, self.H / 2 - 120 * s, 1160 * s, self.H / 2 + 120 * s)
        rain = (1440 * s, 300 * s, 1800 * s, 480 * s)
        cock = (1440 * s, 620 * s, 1800 * s, 800 * s)
        for i, p in enumerate(prods):
            a = ease_out((lt - 0.2 - i * 0.12) / 0.5)
            y = top + i * (ph + 16 * s)
            self._box(im, (px0, y, px1, y + ph), p, [], CYAN, a, 0.15, title_size=32)
            self._arrow(im, (px1 + 8 * s, y + ph / 2), (bus[0] - 10 * s, (bus[1] + bus[3]) / 2 + (i - 2.5) * 22 * s), (40, 60, 80), a, ease((lt - 0.8) / 0.6), width=2, head=False)
        ab = ease_out((lt - 0.9) / 0.6)
        self._box(im, bus, "EVENT BUS", ["/run/orionx/events.jsonl", "append-only · tmpfs", "{ts, severity, source, msg}"], ORANGE, ab, 0.5 + 0.5 * abs(math.sin(lt * 2.0)) * ab, title_size=44, line_size=22)
        ar = ease_out((lt - 1.4) / 0.6)
        # consumer pulses when a packet arrives
        pulse_r = pulse_c = 0.0
        rng = np.random.default_rng(5)
        for k in range(14):
            t_emit = 1.8 + k * 0.42 + rng.uniform(0, 0.2)
            src = int(rng.integers(0, len(prods)))
            sev = [CYAN, AMBER, ORANGE, RED][int(rng.integers(0, 4))]
            y = top + src * (ph + 16 * s) + ph / 2
            u = (lt - t_emit) / 0.9
            if 0 <= u <= 1:
                p0 = (px1 + 8 * s, y)
                p1 = (bus[0], (bus[1] + bus[3]) / 2)
                self._dot(im, (lerp(p0[0], p1[0], ease(u)), lerp(p0[1], p1[1], ease(u))), sev, 7)
            u2 = (lt - t_emit - 0.9) / 0.8
            if 0 <= u2 <= 1:
                c = (bus[2], (bus[1] + bus[3]) / 2)
                for tgt in (rain, cock):
                    p1 = (tgt[0], (tgt[1] + tgt[3]) / 2)
                    self._dot(im, (lerp(c[0], p1[0], ease(u2)), lerp(c[1], p1[1], ease(u2))), sev, 7)
            if 0 <= (lt - t_emit - 1.7) < 0.35:
                pulse_r = pulse_c = 1 - (lt - t_emit - 1.7) / 0.35
        self._box(im, rain, "R.A.I.N.", ["severity → sound + voice"], GREEN, ar, 0.25 + 0.75 * pulse_r, title_size=44)
        self._box(im, cock, "ORION COCKPIT", ["stream · pressure · vitals"], AMBER, ar, 0.25 + 0.75 * pulse_c, title_size=40)
        for tgt in (rain, cock):
            self._arrow(im, (bus[2] + 8 * s, (bus[1] + bus[3]) / 2), (tgt[0] - 8 * s, (tgt[1] + tgt[3]) / 2), (40, 60, 80), ar, ease((lt - 1.5) / 0.5), width=2)
        if pulse_r > 0:  # sound waves out of R.A.I.N.
            d = ImageDraw.Draw(im)
            cx, cy = rain[2] + 20 * s, (rain[1] + rain[3]) / 2
            for k in range(3):
                r = (30 + k * 26 + (1 - pulse_r) * 40) * s
                d.arc([cx - r, cy - r, cx + r, cy + r], -40, 40, fill=GREEN + (int(255 * pulse_r * (1 - k * 0.25)),), width=max(2, int(3 * s)))

    def dg_mesh(self, im, lt, dur):
        s = self.s
        self._heading(im, "WIREGUARD MESH · NO HUB", "every deck peers directly with every other · wg0 · 10.0.99.0/24", lt)
        names = [("ox-alpha", "10.0.99.1"), ("ox-bravo", "10.0.99.2"), ("ox-charlie", "10.0.99.3"), ("ox-delta", "10.0.99.4"), ("ox-echo", "10.0.99.5")]
        cx, cy, R = self.W / 2, self.H / 2 + 50 * s, 320 * s
        pts = []
        for i in range(len(names)):
            ang = -math.pi / 2 + i * 2 * math.pi / len(names)
            pts.append((cx + R * math.cos(ang) * 1.35, cy + R * math.sin(ang)))
        pairs = [(i, j) for i in range(len(pts)) for j in range(i + 1, len(pts))]
        d = ImageDraw.Draw(im)
        for k, (i, j) in enumerate(pairs):
            prog = ease((lt - 1.0 - k * 0.22) / 0.5)
            if prog > 0:
                p0, p1 = pts[i], pts[j]
                d.line([p0, (lerp(p0[0], p1[0], prog), lerp(p0[1], p1[1], prog))], fill=(255, 87, 34, 150), width=max(2, int(3 * s)))
                if prog >= 1:
                    u = ((lt * 0.6 + k * 0.37) % 1.0)
                    self._dot(im, (lerp(p0[0], p1[0], u), lerp(p0[1], p1[1], u)), AMBER, 5)
        for i, (nm, ip) in enumerate(names):
            a = ease_out((lt - 0.3 - i * 0.15) / 0.5)
            x, y = pts[i]
            self._box(im, (x - 120 * s, y - 50 * s, x + 120 * s, y + 50 * s), nm, [ip], GREEN if i == 0 else CYAN, a, 0.35 if i else 0.8, title_size=34, line_size=22)
        a = ease_out((lt - 3.5) / 0.6)
        d = ImageDraw.Draw(im)
        d.text((self.W / 2, self.H - 70 * s), "sudo orionx-mesh join   ·   LAN auto-discovery   ·   keys made on the deck, never shipped",
               font=self.font("mono", 24), fill=DIM + (int(255 * a),), anchor="mm")

    def dg_nebula(self, im, lt, dur):
        s = self.s
        self._heading(im, "NEBULA · ON-DEVICE AI", "the model, the tools and the audit log all run on the deck", lt)
        deck = (110 * s, 210 * s, self.W - 110 * s, self.H - 110 * s)
        d = ImageDraw.Draw(im)
        a0 = ease_out((lt - 0.2) / 0.6)
        d.rounded_rectangle(deck, radius=int(24 * s), outline=(60, 75, 95, int(255 * a0)), width=max(2, int(3 * s)))
        d.text((deck[0] + 24 * s, deck[1] + 24 * s), "THE DECK", font=self.font("cond", 30), fill=DIM + (int(255 * a0),), anchor="lm")
        gate = (220 * s, 420 * s, 520 * s, 620 * s)
        model = (720 * s, 380 * s, 1160 * s, 660 * s)
        a1 = ease_out((lt - 0.6) / 0.5)
        self._box(im, gate, "SHA-256 GATE", ["checked at boot", "mismatch → no start"], GREEN, a1, ease((lt - 1.0) / 0.5))
        self._arrow(im, (gate[2] + 8 * s, 520 * s), (model[0] - 8 * s, 520 * s), GREEN, a1, ease((lt - 1.3) / 0.4))
        a2 = ease_out((lt - 1.4) / 0.5)
        self._box(im, model, "QWEN 2.5 · 3B", ["ollama · listens on 127.0.0.1 only", "AppArmor-confined"], ORANGE, a2, 0.6 * a2, title_size=44)
        tools = ["pcap_analyze", "tshark_summary", "artifact_analyze", "oast_decode", "wg_show", "list_connections"]
        for i, t in enumerate(tools):
            a = ease_out((lt - 2.0 - i * 0.15) / 0.4)
            y = 270 * s + i * 82 * s
            box = (1330 * s, y, 1700 * s, y + 64 * s)
            self._box(im, box, t, [], CYAN, a, 0.2 + 0.6 * max(0.0, math.sin(lt * 3 - i)), title_size=28)
            self._arrow(im, (model[2] + 8 * s, 520 * s), (box[0] - 8 * s, y + 32 * s), (50, 70, 90), a, 1.0, width=2, head=False)
        # outbound attempt blocked
        a3 = ease_out((lt - 3.6) / 0.4)
        if a3 > 0:
            p0 = (940 * s, model[3] + 10 * s)
            p1 = (940 * s, deck[3] + 70 * s)
            u = min(1.0, (lt - 3.6) / 0.6)
            yb = lerp(p0[1], deck[3] - 6 * s, ease(u))
            d.line([p0, (p0[0], yb)], fill=RED + (int(255 * a3),), width=max(2, int(4 * s)))
            if u >= 1:
                cx, cy, r = p0[0], deck[3], 26 * s
                d.line([(cx - r, cy - r), (cx + r, cy + r)], fill=RED + (255,), width=max(3, int(6 * s)))
                d.line([(cx - r, cy + r), (cx + r, cy - r)], fill=RED + (255,), width=max(3, int(6 * s)))
                d.text((cx + 50 * s, cy), "nothing leaves the deck", font=self.font("mono", 26), fill=RED + (255,), anchor="lm")
        a4 = ease_out((lt - 4.4) / 0.5)
        d.text((deck[0] + 40 * s, deck[1] + 70 * s), "every tool call: schema-checked · plain argv, no shell · timeout · audit log",
               font=self.font("mono", 22), fill=TEXT + (int(220 * a4),), anchor="lm")

    def dg_architecture(self, im, lt, dur):
        s = self.s
        self._heading(im, "ONE STICK", "Debian 13 live · x86-64 · works air-gapped", lt)
        layers = [
            ("SURFACES", ["Orion Cockpit", "R.A.I.N. voice", "Orion Workbench", "terminal toolkit"], AMBER),
            ("EVENT BUS", ["/run/orionx/events.jsonl"], ORANGE),
            ("SERVICES", ["Suricata", "Zeek", "scanwatch", "postured", "heald", "WireGuard", "Synapse", "Nebula"], CYAN),
            ("PLATFORM", ["Debian 13", "kernel 6.12", "AppArmor", "nftables", "RAM overlay"], GREEN),
        ]
        x0, x1 = 300 * s, self.W - 140 * s
        top, lh, gap = 230 * s, 150 * s, 22 * s
        d = ImageDraw.Draw(im)
        for i, (name, items, col) in enumerate(reversed(layers)):
            idx = len(layers) - 1 - i
            a = ease_out((lt - 0.3 - i * 0.45) / 0.6)
            y = top + idx * (lh + gap) + (1 - a) * 60 * s
            box = (x0, y, x1, y + lh)
            lay = Image.new("RGBA", im.size, (0, 0, 0, 0))
            ImageDraw.Draw(lay).rounded_rectangle(box, radius=int(16 * s), fill=PANEL + (int(230 * a),), outline=col + (int(200 * a),), width=max(2, int(3 * s)))
            im.alpha_composite(lay)
            d.text((x0 - 30 * s, y + lh / 2), name, font=self.font("cond", 40), fill=col + (int(255 * a),), anchor="rm")
            n = len(items)
            cw = (x1 - x0 - 40 * s) / n
            for k, it in enumerate(items):
                ak = ease_out((lt - 0.6 - i * 0.45 - k * 0.06) / 0.4)
                cx = x0 + 20 * s + cw * (k + 0.5)
                d.text((cx, y + lh / 2), it, font=self.font("mono", 26 if n <= 5 else 22), fill=TEXT + (int(255 * ak),), anchor="mm")
        verbs = ["MONITOR", "DETECT", "DEFEND", "TRIAGE", "TIMELINE"]
        vt0 = 2.6
        f = self.font("cond", 46)
        total = sum(text_width(f, v, int(6 * s)) for v in verbs) + 80 * s * (len(verbs) - 1)
        x = (self.W - total) / 2
        y = self.H - 70 * s
        for k, v in enumerate(verbs):
            ts = vt0 + k * 0.55
            a = ease_out((lt - ts) / 0.4)
            hot = max(0.0, 1 - abs(lt - ts - 0.3) / 0.5)
            col = tuple(int(lerp(DIM[c], ORANGE[c], max(hot, 0.35))) for c in range(3))
            if a > 0:
                im.alpha_composite(glow_text(im.size, (x, y), v, f, col + (int(255 * a),), glow=int(10 * s * hot), glow_alpha=150, anchor="lm", spacing=int(6 * s)))
            x += text_width(f, v, int(6 * s)) + 80 * s

    # --- dispatcher ---
    def shot_frame(self, shot: dict, lt: float, dur: float) -> Image.Image:
        kind = shot["kind"]
        if kind == "capture":
            im = self.capture_frame(shot, lt, dur)
        elif kind == "montage":
            im = self.montage_frame(shot, lt, dur)
        elif kind == "diagram":
            im = self.diagram_frame(shot, lt, dur)
        elif kind == "title":
            im = self.title_frame(shot, lt, dur)
        else:
            im = self.black_frame(shot, lt, dur)
        return self.overlays(im, shot, lt, dur)


# ------------------------------------------------------------------ timeline
XF = 0.45


def build_timeline(shots: list[dict], narr: dict[str, np.ndarray]) -> float:
    t = 0.0
    for i, s in enumerate(shots):
        d = float(s.get("dur", 4.0))
        a = narr.get(s["id"])
        lead = float(s.get("narration_lead", 0.35))
        if a is not None:
            d = max(d, lead + len(a) / SR + 0.45)
        s["_dur"] = d
        s["_start"] = t
        nxt = shots[i + 1] if i + 1 < len(shots) else None
        hard = nxt is None or nxt["kind"] == "title" or s["kind"] in ("title", "black") or (nxt.get("music") or {}).get("hit")
        s["_xf"] = 0.0 if hard else XF
        t += d
    return t


def active(shots, t):
    for i, s in enumerate(shots):
        if s["_start"] <= t < s["_start"] + s["_dur"]:
            prev = shots[i - 1] if i > 0 else None
            if prev is not None and prev["_xf"] > 0 and t < s["_start"] + prev["_xf"]:
                return s, prev, (t - s["_start"]) / prev["_xf"]
            return s, None, 1.0
    return shots[-1], None, 1.0


# ------------------------------------------------------------------ audio
def deck_audio(cap: Capture | None, key: str) -> np.ndarray | None:
    if key in ("critical", "warning", "notice", "info"):
        a, sr = sf.read(RAIN_DIR / f"{key}.wav", dtype="float32")
        if a.ndim > 1:
            a = a.mean(axis=1)
        return resample(a, sr, SR)
    if key == "rain-voice" and cap is not None:
        # the guest's own speech for the Zeek alert published in scene x-rain,
        # located by energy in the guest recording (QEMU wav audiodev, real time)
        per_scene = next((r / "audio" / "x-rain.wav" for r in [cap.root, *cap.extra_roots]
                          if (r / "audio" / "x-rain.wav").exists()), None)   # record_scenes.py layout
        if per_scene is not None:
            seg, sr = sf.read(per_scene, dtype="float32")
            if seg.ndim > 1:
                seg = seg.mean(axis=1)
            # skip the four cue tones at the start; keep the spoken alert after them
            seg = seg[int(7.5 * sr):]
        else:                                               # qemu_capture.py layout
            wav = cap.root / "audio.wav"
            span = cap.scenes.get("x-rain")
            if not wav.exists() or not span:
                return None
            a, sr = sf.read(wav, dtype="float32")
            if a.ndim > 1:
                a = a.mean(axis=1)
            t_a, t_b = span[0][0], span[-1][0] + 2.0
            seg = a[int(t_a * sr): int(t_b * sr)]
        if len(seg) == 0:
            return None
        env = np.convolve(np.abs(seg), np.ones(int(0.05 * sr)) / int(0.05 * sr), mode="same")
        act = env > max(0.01, env.max() * 0.08)
        # longest active run (speech is longer than the cues)
        best, cur, start, bstart = 0, 0, 0, 0
        for i, v in enumerate(act[:: int(0.01 * sr)]):
            if v:
                if cur == 0:
                    start = i
                cur += 1
                if cur > best:
                    best, bstart = cur, start
            else:
                cur = 0 if cur < 30 else cur  # tolerate short gaps between words
                if cur >= 30 and not v:
                    cur = 0
        s0 = max(0, bstart * int(0.01 * sr) - int(0.15 * sr))
        s1 = min(len(seg), s0 + max(best, 100) * int(0.01 * sr) + int(0.6 * sr))
        out = resample(seg[s0:s1], sr, SR)
        peak = np.max(np.abs(out)) or 1.0
        return out / peak * 0.8
    return None


def mix_audio(shots, narr, cap, total, out_wav: Path, music_seed=7):
    n = int(total * SR) + SR
    voice = np.zeros(n, np.float32)
    deck = np.zeros(n, np.float32)
    captions = []
    for s in shots:
        st = s["_start"]
        a = narr.get(s["id"])
        if a is not None:
            o = int((st + float(s.get("narration_lead", 0.35))) * SR)
            voice[o:o + len(a)] += a[: max(0, n - o)]
            captions.append((o / SR, (o + len(a)) / SR, s["narration"]))
        if s.get("deck_audio"):
            da = deck_audio(cap, s["deck_audio"])
            if da is not None:
                o = int((st + 0.15) * SR)
                deck[o:o + len(da)] += da[: max(0, n - o)] * 0.9
            else:
                print(f"[audio] WARNING: deck audio {s['deck_audio']!r} unavailable for {s['id']}", flush=True)
        if s["kind"] == "title" and (s.get("music") or {}).get("hit") and s["text"]["style"] == "chapter":
            da = deck_audio(cap, "notice")
            o = int((st + 0.05) * SR)
            deck[o:o + len(da)] += da[: max(0, n - o)] * 0.5
    # music cue list from the shots
    cues = []
    for s in shots:
        m = s.get("music") or {}
        c = {"t": s["_start"], "intensity": float(m.get("intensity", 0.5))}
        if m.get("hit"):
            c["hit"] = True
        if m.get("riser"):
            c["riser"] = float(m["riser"])
        cues.append(c)
        if m.get("braam"):
            cues.append({"t": s["_start"] + s["_dur"], "intensity": float(m.get("intensity", 0.5)), "braam": True})
    cues.append({"t": total, "intensity": 0.05})
    cues.sort(key=lambda c: c["t"])
    # risers must end at the cue time; render_music expects that
    score = render_music.Score(total + 1.0, 96, cues, music_seed)
    music = score.render()[:n]
    if len(music) < n:
        music = np.pad(music, ((0, n - len(music)), (0, 0)))
    # duck under narration and deck audio (smoothed envelope)
    env = np.abs(voice) + np.abs(deck)
    win = int(0.25 * SR)
    env = np.convolve(env, np.ones(win) / win, mode="same")
    duck = 1.0 - 0.62 * np.clip(env / 0.02, 0, 1)
    for s in shots:
        if s.get("duck_music") is not None:
            a, b = int(s["_start"] * SR), int((s["_start"] + s["_dur"]) * SR)
            duck[a:b] = np.minimum(duck[a:b], float(s["duck_music"]))
    duck = np.convolve(duck, np.ones(win) / win, mode="same")
    mix = music * duck[:, None] * 0.55 + (voice * 1.0)[:, None] + (deck * 0.85)[:, None]
    peak = np.max(np.abs(mix)) or 1.0
    if peak > 0.98:
        mix = mix / peak * 0.98
    sf.write(out_wav, mix.astype(np.float32), SR, subtype="FLOAT")
    return captions


# ------------------------------------------------------------------ captions
def fmt_ts(t: float) -> str:
    h, rem = divmod(t, 3600)
    m, sec = divmod(rem, 60)
    return f"{int(h):02d}:{int(m):02d}:{sec:06.3f}"


def write_vtt(captions, path: Path):
    lines = ["WEBVTT", ""]
    for i, (a, b, text) in enumerate(captions, 1):
        words = text.split()
        chunks, cur = [], ""
        for w in words:
            if len(cur) + len(w) + 1 > 42:
                chunks.append(cur)
                cur = w
            else:
                cur = (cur + " " + w).strip()
        chunks.append(cur)
        body = "\n".join(chunks[:2]) if len(chunks) <= 2 else None
        if body is not None:
            lines += [str(i), f"{fmt_ts(a)} --> {fmt_ts(b)}", body, ""]
        else:
            # split long lines into two timed cues proportional to length
            half = len(chunks) // 2
            mid = a + (b - a) * (len(" ".join(chunks[:half])) / max(len(text), 1))
            lines += [f"{i}a", f"{fmt_ts(a)} --> {fmt_ts(mid)}", "\n".join(chunks[:half]), ""]
            lines += [f"{i}b", f"{fmt_ts(mid)} --> {fmt_ts(b)}", "\n".join(chunks[half:]), ""]
    path.write_text("\n".join(lines))


def write_transcript(cfg, shots, captions, total, path: Path):
    out = [f"# {cfg['title']} {cfg['version']} — release trailer — transcript", "",
           f"**Runtime:** {int(total // 60)} min {int(total % 60)} s<br>",
           "**Picture:** boot, first-boot wizard and desktop are the release ISO booting in QEMU (UEFI, 1920x1080); "
           "every application scene is the ISO's own userspace running in a container (`record_scenes.py`); "
           "title cards and architecture diagrams are drawn by `tools/guided-demo/cinematic/build_trailer.py`.<br>",
           "**Sound:** narration synthesised offline (Kokoro v1.0, voice `" + cfg.get("voice", "") + "`); "
           "procedural score (`render_music.py`); deck samples are the image's own R.A.I.N. cues and voice.<br>",
           "**Cockpit LIVE tab:** built-in demo feed plus real events published with `orionx-event` during the capture.", ""]
    for s in shots:
        if s.get("narration"):
            out += [f"## {fmt_ts(s['_start'])[3:8]} — {s['id']}", "", s["narration"], ""]
    path.write_text("\n".join(out))


# ------------------------------------------------------------------ main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", default=str(HERE / "trailer.yaml"))
    ap.add_argument("--capture", required=True, action="append",
                    help="capture dir (repeatable; a later dir's scenes override an earlier one's)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--models", default=str(REPO / "tmp/video/models"))
    ap.add_argument("--preview", action="store_true", help="960x540 @ 15 fps")
    ap.add_argument("--only", help="comma-separated shot ids (renders just those, for review)")
    ap.add_argument("--stills", action="store_true", help="write one mid-shot PNG per shot and exit")
    args = ap.parse_args()

    cfg = yaml.safe_load(Path(args.script).read_text())
    shots = cfg["shots"]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    W, H = cfg["resolution"]
    fps = int(cfg["fps"])
    if args.preview:
        W, H, fps = W // 2, H // 2, 15

    cap = None
    for cdir in args.capture:
        if not Path(cdir, "frames.csv").exists():
            print(f"[cap] WARNING: {cdir} has no frames.csv", flush=True)
            continue
        c = Capture.load(Path(cdir))
        if cap is None:
            cap = c
        else:
            cap.scenes.update(c.scenes)
            cap.extra_roots.append(c.root)
    if cap:
        print("[cap] scenes: " + ", ".join(f"{k}={len(v)}" for k, v in cap.scenes.items()), flush=True)
    for s in shots:
        if s["kind"] == "capture":
            s["_frames"] = cap.frames(s["scene"], tuple(s.get("window", (0, 1)))) if cap else []
        elif s["kind"] == "montage":
            fr = []
            for sc in s["scenes"]:
                fr += cap.frames(sc) if cap else []
            s["_frames"] = fr
        if s["kind"] in ("capture", "montage") and not s.get("_frames"):
            print(f"[cap] WARNING: no footage for shot {s['id']} (scene {s.get('scene') or s.get('scenes')})", flush=True)

    narr = synth_narration(shots, cfg, Path(args.models), REPO / "tmp/video/tts-cache")
    total = build_timeline(shots, narr)
    print(f"[timeline] {len(shots)} shots, {total:.1f}s", flush=True)
    R = Renderer(W, H, fps, cap)

    if args.stills:
        for s in shots:
            im = R.shot_frame(s, s["_dur"] * 0.7, s["_dur"])
            Image.fromarray(R.finish(im, 0, grade=s["kind"] in ("capture", "montage"))).save(out / f"still-{s['id']}.png")
        print(f"[stills] wrote {len(shots)} stills to {out}")
        return 0

    base = f"orionx-trailer-{cfg['version']}" + ("-preview" if args.preview else "")
    wav = out / f"{base}.mix.wav"
    captions = mix_audio(shots, narr, cap, total, wav)

    video = out / f"{base}.video.mp4"
    nframes = int(total * fps)
    enc = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{W}x{H}", "-r", str(fps), "-i", "-", "-c:v", "libx264", "-preset", "medium" if not args.preview else "veryfast",
           "-crf", "17" if not args.preview else "26", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(video)]
    p = subprocess.Popen(enc, stdin=subprocess.PIPE)
    only = set(args.only.split(",")) if args.only else None
    poster = None
    for fno in range(nframes):
        t = fno / fps
        cur, prev, alpha = active(shots, t)
        if only and cur["id"] not in only:
            continue
        im = R.shot_frame(cur, t - cur["_start"], cur["_dur"])
        if prev is not None:
            pim = R.shot_frame(prev, t - prev["_start"], prev["_dur"])
            im = Image.blend(pim, im, ease(alpha))
        grade = cur["kind"] in ("capture", "montage")
        frame = R.finish(im, fno, grade=grade)
        if cur["id"] == "finale" and poster is None and t - cur["_start"] > 3.2:
            poster = frame
        p.stdin.write(frame.tobytes())
        if fno % (fps * 5) == 0:
            print(f"[render] {t:6.1f}s / {total:.1f}s  ({cur['id']})", flush=True)
    p.stdin.close()
    if p.wait() != 0:
        sys.exit("ffmpeg video encode failed")

    final = out / f"{base}.mp4"
    subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(video), "-i", str(wav),
                    "-af", "loudnorm=I=-14:TP=-1.5:LRA=11", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                    "-ar", "48000", "-shortest", "-movflags", "+faststart", str(final)], check=True)
    write_vtt(captions, out / f"{base}.vtt")
    write_transcript(cfg, shots, captions, total, out / f"{base}-transcript.md")
    if poster is not None:
        Image.fromarray(poster).save(out / f"{base}-poster.png")
    video.unlink(missing_ok=True)
    meta = {"total_seconds": round(total, 2), "shots": [{"id": s["id"], "start": round(s["_start"], 2), "dur": round(s["_dur"], 2),
                                                         "frames": len(s.get("_frames", []))} for s in shots]}
    (out / f"{base}.timeline.json").write_text(json.dumps(meta, indent=2))
    print(f"[done] {final}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
