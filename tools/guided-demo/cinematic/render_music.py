#!/usr/bin/env python3
"""
render_music.py — procedural cinematic score for the release trailer.

No samples, no licences to clear: every sound is synthesised here (numpy),
so the trailer can be rebuilt for every release with one command. The score
follows a cue list (start, end, intensity 0..1, flags) so the music swells
where the picture does.

    python3 render_music.py --cues cues.json --out music.wav [--seed 7]

cues.json: {"duration": 150.0, "bpm": 96,
            "cues": [{"t": 0, "intensity": 0.15}, {"t": 18, "intensity": 0.4, "hit": true}, ...]}
Intensity is linearly interpolated between cue points; "hit": true drops an
impact at that time; "riser": N schedules an N-second riser ending there;
"braam": true adds a brass-like swell ending there.

@decision DEC-PHASE12-063
@title The trailer's music bed is synthesised, not licensed
@rationale A release video that ships in the repo and on GitHub must be
  redistributable without a music licence trail. Synthesis keeps the whole
  deliverable reproducible from source (same standard as the narration and
  the captured frames) and lets the score follow the cut exactly.
"""
from __future__ import annotations

import argparse
import json
import math

import numpy as np
import soundfile as sf

SR = 48000


def note(name: str) -> float:
    """'D2' -> Hz."""
    names = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
    n, octv = name[:-1], int(name[-1])
    midi = 12 * (octv + 1) + names[n]
    return 440.0 * 2 ** ((midi - 69) / 12)


# D minor progression, four chords of two bars each: Dm – Bb – F – C (i – VI – III – VII), then
# Dm – Bb – Gm – A for the lift. Voicings kept low and open for weight.
PROGRESSION = [
    ["D2", "A2", "D3", "F3", "A3"],
    ["A#1", "F2", "A#2", "D3", "F3"],
    ["F2", "C3", "F3", "A3", "C4"],
    ["C2", "G2", "C3", "E3", "G3"],
    ["D2", "A2", "D3", "F3", "A3"],
    ["A#1", "F2", "A#2", "D3", "F3"],
    ["G1", "D2", "G2", "A#2", "D3"],
    ["A1", "E2", "A2", "C#3", "E3"],
]
ARP_NOTES = ["D4", "F4", "A4", "D5", "A4", "F4"]


def env_adsr(n: int, a: float, d: float, s: float, r: float) -> np.ndarray:
    a_n, d_n, r_n = int(a * SR), int(d * SR), int(r * SR)
    s_n = max(n - a_n - d_n - r_n, 0)
    parts = [np.linspace(0, 1, a_n, endpoint=False), np.linspace(1, s, d_n, endpoint=False),
             np.full(s_n, s), np.linspace(s, 0, r_n)]
    e = np.concatenate(parts)
    return e[:n] if len(e) >= n else np.pad(e, (0, n - len(e)))


def saw_bl(freq: float, n: int, harmonics: int = 24, phase: float = 0.0) -> np.ndarray:
    """Band-limited sawtooth via additive harmonics (keeps aliasing out of the pads)."""
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(1, harmonics + 1):
        if freq * k > SR / 2.2:
            break
        out += np.sin(2 * math.pi * freq * k * t + phase * k) / k
    return out * (2 / math.pi)


def onepole_lp(x: np.ndarray, cutoff: np.ndarray | float) -> np.ndarray:
    """One-pole low-pass with a per-sample (or constant) cutoff in Hz."""
    if np.isscalar(cutoff):
        cutoff = np.full(len(x), float(cutoff))
    alpha = 1 - np.exp(-2 * math.pi * np.clip(cutoff, 20, SR / 2.5) / SR)
    y = np.empty_like(x)
    acc = 0.0
    # block-wise loop is still fast enough for a 3-minute cue (~9M samples)
    for i in range(0, len(x), 4096):
        xa, aa = x[i:i + 4096], alpha[i:i + 4096]
        for j in range(len(xa)):
            acc += aa[j] * (xa[j] - acc)
            y[i + j] = acc
    return y


def lp_fft(x: np.ndarray, cutoff: float) -> np.ndarray:
    """Cheap linear-phase low-pass for whole-buffer layers (fast)."""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    gain = 1 / (1 + (f / max(cutoff, 20)) ** 4)
    return np.fft.irfft(X * gain, n=len(x))


def bp_fft(x: np.ndarray, lo: float, hi: float) -> np.ndarray:
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    gain = (1 / (1 + (lo / np.maximum(f, 1)) ** 4)) * (1 / (1 + (f / hi) ** 4))
    return np.fft.irfft(X * gain, n=len(x))


def reverb(x: np.ndarray, seconds: float = 2.8, mix: float = 0.35, seed: int = 1) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    ir = rng.standard_normal(n) * np.exp(-np.arange(n) / (SR * seconds / 5.5))
    ir = lp_fft(ir, 5000)
    ir /= np.sqrt(np.sum(ir ** 2)) * 3.5
    wet = np.fft.irfft(np.fft.rfft(x, len(x) + n) * np.fft.rfft(ir, len(x) + n))[: len(x)]
    return x * (1 - mix) + wet * mix


def intensity_curve(cues: list[dict], n: int) -> np.ndarray:
    ts = [c["t"] for c in cues]
    vs = [c["intensity"] for c in cues]
    t = np.arange(n) / SR
    return np.interp(t, ts, vs)


class Score:
    def __init__(self, duration: float, bpm: float, cues: list[dict], seed: int):
        self.n = int(duration * SR)
        self.bpm = bpm
        self.beat = 60.0 / bpm
        self.cues = cues
        self.rng = np.random.default_rng(seed)
        self.inten = intensity_curve(cues, self.n)
        self.t = np.arange(self.n) / SR

    # ---- layers -----------------------------------------------------------
    def drone(self) -> np.ndarray:
        f = note("D1")
        x = np.sin(2 * math.pi * f * self.t) * 0.55 + np.sin(2 * math.pi * f * 2 * self.t) * 0.25
        x += 0.12 * saw_bl(f * 2, self.n, harmonics=10)
        lfo = 0.85 + 0.15 * np.sin(2 * math.pi * 0.07 * self.t)
        return lp_fft(x * lfo, 220) * (0.35 + 0.35 * self.inten)

    def pads(self) -> np.ndarray:
        out = np.zeros(self.n)
        chord_len = int(2 * 4 * self.beat * SR)  # two bars per chord
        i = 0
        k = 0
        while i < self.n:
            chord = PROGRESSION[k % len(PROGRESSION)]
            seg = min(chord_len, self.n - i)
            voice = np.zeros(seg)
            for nm in chord:
                f = note(nm)
                for det in (-0.35, 0.0, 0.35):
                    voice += saw_bl(f * 2 ** (det / 1200), seg, harmonics=16,
                                    phase=float(self.rng.uniform(0, 2 * math.pi)))
            voice *= env_adsr(seg, 1.2, 0.5, 0.85, 1.6) / (len(chord) * 3)
            out[i:i + seg] += voice
            i += seg
            k += 1
        cutoff = 300 + 2400 * self.inten ** 1.5
        out = onepole_lp(out, cutoff)
        return out * (0.45 + 0.55 * self.inten) * 0.9

    def arp(self) -> np.ndarray:
        out = np.zeros(self.n)
        step = self.beat / 2
        i = 0
        while (t0 := i * step) < self.n / SR:
            inten = float(np.interp(t0, [c["t"] for c in self.cues], [c["intensity"] for c in self.cues]))
            if inten > 0.3:
                f = note(ARP_NOTES[i % len(ARP_NOTES)])
                ln = int(step * 1.6 * SR)
                s = int(t0 * SR)
                ln = min(ln, self.n - s)
                tt = np.arange(ln) / SR
                tone = np.sin(2 * math.pi * f * tt) + 0.4 * np.sin(2 * math.pi * 2 * f * tt) + 0.15 * np.sin(2 * math.pi * 3 * f * tt)
                tone *= np.exp(-tt * 9) * (inten - 0.3) / 0.7
                out[s:s + ln] += tone * 0.22
            i += 1
        return out

    def percussion(self) -> np.ndarray:
        out = np.zeros(self.n)
        bar = self.beat * 4
        nbars = int(self.n / SR / bar) + 1
        for b in range(nbars):
            for beat_i in range(4):
                t0 = b * bar + beat_i * self.beat
                if t0 >= self.n / SR:
                    break
                inten = float(np.interp(t0, [c["t"] for c in self.cues], [c["intensity"] for c in self.cues]))
                s = int(t0 * SR)
                if inten > 0.45 and beat_i in (0, 2):
                    self._kick(out, s, inten)
                if inten > 0.6:
                    for sub in (0.5,) if inten < 0.8 else (0.25, 0.5, 0.75):
                        self._tick(out, int((t0 + sub * self.beat) * SR), inten)
                if inten > 0.75 and beat_i == 3 and b % 2 == 1:
                    self._tick(out, int((t0 + 0.5 * self.beat) * SR), inten, long=True)
        return out

    def _kick(self, out: np.ndarray, s: int, inten: float) -> None:
        ln = min(int(0.45 * SR), self.n - s)
        tt = np.arange(ln) / SR
        f = 48 + 110 * np.exp(-tt * 28)
        ph = 2 * math.pi * np.cumsum(f) / SR
        k = np.sin(ph) * np.exp(-tt * 7)
        k += self.rng.standard_normal(ln) * np.exp(-tt * 90) * 0.4
        out[s:s + ln] += k * (0.5 + 0.5 * inten) * 0.9

    def _tick(self, out: np.ndarray, s: int, inten: float, long: bool = False) -> None:
        ln = min(int((0.18 if long else 0.05) * SR), self.n - s)
        if ln <= 0:
            return
        tt = np.arange(ln) / SR
        h = self.rng.standard_normal(ln) * np.exp(-tt * (18 if long else 70))
        out[s:s + ln] += bp_fft(h, 5000, 12000) * 0.18 * inten

    def impacts(self) -> np.ndarray:
        out = np.zeros(self.n)
        for c in self.cues:
            s = int(c["t"] * SR)
            if c.get("riser"):
                ln = int(float(c["riser"]) * SR)
                st = max(s - ln, 0)
                ln = s - st
                tt = np.arange(ln) / SR
                noise = self.rng.standard_normal(ln)
                sweep = np.zeros(ln)
                for i in range(0, ln, 2048):
                    frac = i / ln
                    lo, hi = 200 + 1800 * frac ** 2, 900 + 9000 * frac ** 2
                    seg = noise[i:i + 2048]
                    sweep[i:i + 2048] = bp_fft(seg, lo, hi)
                ramp = (tt / tt[-1]) ** 2.2 if ln > 1 else np.ones(ln)
                out[st:s] += sweep * ramp * 0.5
            if c.get("hit"):
                ln = min(int(2.4 * SR), self.n - s)
                tt = np.arange(ln) / SR
                boom = np.sin(2 * math.pi * (38 + 60 * np.exp(-tt * 12)) * tt) * np.exp(-tt * 2.2)
                crack = self.rng.standard_normal(ln) * np.exp(-tt * 40)
                out[s:s + ln] += boom * 1.1 + lp_fft(crack, 3000) * 0.5
            if c.get("braam"):
                ln = int(3.2 * SR)
                st = max(s - ln, 0)
                ln = s - st
                tt = np.arange(ln) / SR
                br = np.zeros(ln)
                for f in (note("D2"), note("A2"), note("D3")):
                    for det in (-12, -4, 4, 12):
                        br += saw_bl(f * 2 ** (det / 1200), ln, harmonics=20)
                br /= 12
                br *= (tt / tt[-1]) ** 1.5 if ln > 1 else 1
                br = lp_fft(br, 1200)
                out[st:s] += br * 0.9
                tail = min(int(1.6 * SR), self.n - s)
                out[s:s + tail] += lp_fft(br[-1:].repeat(tail) * 0, 1200)  # keep shape; impact handles the tail
        return out

    # ---- mix ------------------------------------------------------------------
    def render(self) -> np.ndarray:
        print("[music] drone", flush=True)
        mix = self.drone()
        print("[music] pads", flush=True)
        mix += self.pads()
        print("[music] arp", flush=True)
        mix += self.arp()
        print("[music] percussion", flush=True)
        mix += self.percussion()
        print("[music] impacts", flush=True)
        mix += self.impacts()
        print("[music] reverb", flush=True)
        mix = reverb(mix, 2.6, 0.32)
        # stereo widening: slight delay + inverted low-mid on one side
        delay = int(0.011 * SR)
        left = mix
        right = np.concatenate([np.zeros(delay), mix[:-delay]]) if delay < len(mix) else mix
        st = np.stack([left * 0.98 + right * 0.02, right * 0.98 + left * 0.02], axis=1)
        # soft limiter
        peak = np.max(np.abs(st)) or 1.0
        st = np.tanh(st / peak * 1.6) / math.tanh(1.6)
        st *= 0.89
        # fade in / out
        fi, fo = int(1.5 * SR), int(4.0 * SR)
        st[:fi] *= np.linspace(0, 1, fi)[:, None]
        st[-fo:] *= np.linspace(1, 0, fo)[:, None]
        return st.astype(np.float32)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cues", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    spec = json.loads(open(a.cues).read())
    score = Score(float(spec["duration"]), float(spec.get("bpm", 96)), spec["cues"], a.seed)
    audio = score.render()
    sf.write(a.out, audio, SR, subtype="PCM_16")
    print(f"[music] wrote {a.out}: {len(audio) / SR:.1f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
