#!/usr/bin/env python3
"""
qemu_capture.py — record the REAL image booting and being driven, from the host.

Boots the built ISO in QEMU (TCG on macOS, KVM where available), grabs the
guest framebuffer through QMP `screendump` at a steady rate, records the
guest's audio output to a WAV (QEMU's `wav` audiodev — so R.A.I.N. cues and
the deck's own speech are the deck's, not re-synthesised), and drives the
deck through two channels:

  * the serial console (login as the live user, launch GUI apps with
    DISPLAY=:0, run terminal commands), and
  * QMP input events (key chords such as Ctrl+PgDn to change Cockpit tabs,
    typed text, absolute mouse clicks via usb-tablet).

A capture plan (YAML) lists steps; `mark:` steps name the scene the following
frames belong to, so the assembler can slice one long run into shots.

    python3 tools/guided-demo/qemu_capture.py --iso output/<built>.iso \
        --plan tools/guided-demo/cinematic/capture-plan.yaml --out tmp/video/capture

Outputs under --out:  frames/NNNNNN.png, frames.csv (t_rel,scene,file),
audio.wav (guest audio, 44.1 kHz stereo), serial.log, qemu.log, plan-run.log.

@decision DEC-PHASE12-062
@title Release-video boot footage is captured from the real ISO in QEMU, not drawn
@status accepted
@rationale The guided demo (DEC-PHASE12-018) records the apps in a container
  because it needs a fast, deterministic X session. It cannot show the boot
  chain, the first-boot wizard on tty1, the greeter, or the deck's own audio.
  This tool boots the actual artefact the release ships, so every boot/login/
  config frame in the trailer is evidence of the image, and the audio bed's
  "deck samples" are the deck's. The cost is TCG speed (a 1080p boot takes
  ~3-5 min of wall-clock on Apple Silicon); screendump at 2-6 fps is enough
  because the assembler time-remaps and crossfades.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

import yaml

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

OVMF_CODE_CANDIDATES = [
    "/opt/homebrew/share/qemu/edk2-x86_64-code.fd",
    "/usr/share/OVMF/OVMF_CODE_4M.fd",
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/qemu/edk2-x86_64-code.fd",
]
OVMF_VARS_CANDIDATES = [
    "/opt/homebrew/share/qemu/edk2-i386-vars.fd",
    "/usr/share/OVMF/OVMF_VARS_4M.fd",
    "/usr/share/OVMF/OVMF_VARS.fd",
    "/usr/share/qemu/edk2-i386-vars.fd",
]

# QMP qcode names for typed text (US layout). Upper-case / shifted symbols
# are sent with a held shift.
QCODE = {
    " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal", "[": "bracket_left",
    "]": "bracket_right", ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
    "\\": "backslash", ",": "comma", ".": "dot", "/": "slash",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
    "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right",
    ":": "semicolon", '"': "apostrophe", "~": "grave_accent", "|": "backslash", "<": "comma",
    ">": "dot", "?": "slash",
}
KEY_ALIASES = {"pgdn": "pgdn", "pgup": "pgup", "enter": "ret", "return": "ret", "esc": "esc",
               "super": "meta_l", "win": "meta_l", "alt": "alt", "ctrl": "ctrl", "shift": "shift",
               "space": "spc", "up": "up", "down": "down", "left": "left", "right": "right",
               "f11": "f11", "f1": "f1", "f2": "f2", "f5": "f5", "tab": "tab", "backspace": "backspace",
               "delete": "delete", "home": "home", "end": "end"}


def log(msg: str, fh=None) -> None:
    line = f"[capture {time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    if fh:
        fh.write(line + "\n")
        fh.flush()


def first_existing(paths: list[str]) -> str | None:
    for p in paths:
        if Path(p).exists():
            return p
    return None


class QMP:
    """Minimal QMP client over a unix socket (stdlib only)."""

    def __init__(self, path: Path, timeout: float = 60.0):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(str(path))
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.2)
        self.sock.settimeout(30)
        self.buf = b""
        self.lock = threading.Lock()
        self._read_obj()  # greeting
        self.cmd("qmp_capabilities")

    def _read_obj(self) -> dict:
        while True:
            if b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if line.strip():
                    return json.loads(line)
                continue
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("QMP closed")
            self.buf += chunk

    def cmd(self, name: str, **args) -> dict:
        with self.lock:
            msg = {"execute": name}
            if args:
                msg["arguments"] = args
            self.sock.sendall((json.dumps(msg) + "\n").encode())
            while True:
                obj = self._read_obj()
                if "return" in obj or "error" in obj:
                    if "error" in obj:
                        raise RuntimeError(f"QMP {name}: {obj['error']}")
                    return obj["return"]
                # else: async event — ignore

    def screendump(self, path: Path) -> None:
        self.cmd("screendump", filename=str(path), format="png")

    def send_keys(self, keys: list[str], hold_ms: int = 60) -> None:
        self.cmd("send-key", keys=[{"type": "qcode", "data": k} for k in keys], **{"hold-time": hold_ms})

    def type_text(self, text: str, delay: float = 0.06) -> None:
        for ch in text:
            if ch in SHIFTED:
                self.send_keys(["shift", SHIFTED[ch]])
            elif ch in QCODE:
                self.send_keys([QCODE[ch]])
            elif ch.isalpha():
                self.send_keys((["shift"] if ch.isupper() else []) + [ch.lower()])
            elif ch.isdigit():
                self.send_keys([ch])
            else:
                raise ValueError(f"cannot type {ch!r}")
            time.sleep(delay)

    def mouse(self, x: int, y: int, w: int, h: int, click: str | None = None) -> None:
        ev = [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / max(w - 1, 1))}},
              {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / max(h - 1, 1))}}]
        self.cmd("input-send-event", events=ev)
        if click:
            time.sleep(0.15)
            self.cmd("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": click}}])
            time.sleep(0.12)
            self.cmd("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": click}}])


class Serial:
    """Serial console over the unix socket QEMU exposes; line log + regex waits."""

    def __init__(self, path: Path, logfile: Path, timeout: float = 60.0):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(str(path))
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.2)
        self.text = ""
        self.lock = threading.Lock()
        self.log = logfile.open("ab")
        self.alive = True
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self) -> None:
        while self.alive:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            self.log.write(chunk)
            self.log.flush()
            with self.lock:
                self.text += chunk.decode("utf-8", "replace")
                if len(self.text) > 400_000:
                    self.text = self.text[-200_000:]

    def send(self, s: str) -> None:
        self.sock.sendall(s.encode())

    def wait(self, pattern: str, timeout: float, history: bool = False) -> bool:
        """Wait for `pattern` in output after this call (or anywhere, with history=True)."""
        rx = re.compile(pattern)
        deadline = time.time() + timeout
        with self.lock:
            start = 0 if history else len(self.text)
        while time.time() < deadline:
            with self.lock:
                tail = self.text[start:]
            # systemd and the shell prompt colour their output; match on plain text
            if rx.search(ANSI.sub("", tail).replace("\r", "")):
                return True
            time.sleep(0.25)
        return False

    def mark(self) -> int:
        with self.lock:
            return len(self.text)


class Capture:
    def __init__(self, qmp: QMP, out: Path, fps: float, runlog):
        self.qmp, self.out, self.runlog = qmp, out, runlog
        self.fps = fps
        self.frames_dir = out / "frames"
        self.frames_dir.mkdir(parents=True, exist_ok=True)
        self.csv = (out / "frames.csv").open("a")
        self.n = 0
        self.scene = "boot"
        self.t0 = time.time()
        self.running = True
        self.lock = threading.Lock()
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self) -> None:
        while self.running:
            period = 1.0 / max(self.fps, 0.1)
            t = time.time()
            try:
                with self.lock:
                    name = f"{self.n:06d}.png"
                    self.qmp.screendump(self.frames_dir / name)
                    self.csv.write(f"{t - self.t0:.3f},{self.scene},{name}\n")
                    self.csv.flush()
                    self.n += 1
            except Exception as e:  # QEMU may be shutting down
                log(f"screendump failed: {e}", self.runlog)
                time.sleep(1)
            dt = time.time() - t
            if dt < period:
                time.sleep(period - dt)

    def set_scene(self, name: str) -> None:
        with self.lock:
            self.scene = name

    def stop(self) -> None:
        self.running = False
        time.sleep(0.5)
        self.csv.close()


def qemu_cmd(args, out: Path) -> list[str]:
    w, h = args.res
    cmd = ["qemu-system-x86_64", "-machine", "q35", "-smp", str(args.smp), "-m", str(args.mem)]
    if Path("/dev/kvm").exists() and os.access("/dev/kvm", os.R_OK):
        cmd += ["-enable-kvm", "-cpu", "host"]
    else:
        cmd += ["-accel", "tcg,thread=multi", "-cpu", "max"]
    if args.uefi:
        code = first_existing(OVMF_CODE_CANDIDATES)
        if not code:
            sys.exit("OVMF code firmware not found")
        vars_src = first_existing(OVMF_VARS_CANDIDATES)
        vars_run = out / "OVMF_VARS.fd"
        if vars_src:
            shutil.copy(vars_src, vars_run)
        else:
            vars_run.write_bytes(b"\0" * 65536)
        cmd += ["-drive", f"if=pflash,format=raw,readonly=on,file={code}",
                "-drive", f"if=pflash,format=raw,file={vars_run}"]
    cmd += ["-drive", f"media=cdrom,file={args.iso},readonly=on", "-boot", "d",
            "-device", f"virtio-vga,xres={w},yres={h}", "-display", "none",
            "-device", "qemu-xhci", "-device", "usb-tablet",
            "-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0",
            "-audiodev", f"wav,id=snd0,path={out / 'audio.wav'}",
            "-device", "intel-hda", "-device", "hda-duplex,audiodev=snd0",
            "-qmp", f"unix:{out / 'qmp.sock'},server,nowait",
            "-serial", f"unix:{out / 'serial.sock'},server,nowait",
            "-no-reboot"]
    return cmd


def interactive(seconds: float, cap, ser, qmp, res, runlog) -> None:
    """Debug/authoring hook: poll <out>/inbox for directives while the VM runs.

    Each line of the inbox file is one directive; the file is consumed and
    removed. Plain lines go to the serial console (newline appended).
      __MARK__ scene     set the scene label for following frames
      __FPS__ n          change the screendump rate
      __KEY__ ctrl+pgdn  send a key chord      __TYPE__ text   type text via QMP
      __MOUSE__ x y [left]                      __END__        leave interactive mode
    """
    inbox = cap.out / "inbox"
    deadline = time.time() + seconds
    log(f"interactive: watching {inbox} for {seconds:.0f}s", runlog)
    while time.time() < deadline:
        if inbox.exists():
            lines = inbox.read_text().splitlines()
            inbox.unlink()
            for line in lines:
                if line.startswith("__END__"):
                    log("interactive: end", runlog)
                    return
                if line.startswith("__MARK__ "):
                    cap.set_scene(line.split(None, 1)[1].strip())
                elif line.startswith("__FPS__ "):
                    cap.fps = float(line.split()[1])
                elif line.startswith("__KEY__ "):
                    qmp.send_keys([KEY_ALIASES.get(k.lower(), k.lower()) for k in line.split()[1].split("+")])
                elif line.startswith("__TYPE__ "):
                    qmp.type_text(line.split(" ", 1)[1])
                elif line.startswith("__MOUSE__ "):
                    parts = line.split()
                    qmp.mouse(int(parts[1]), int(parts[2]), res[0], res[1], parts[3] if len(parts) > 3 else None)
                else:
                    ser.send(line + "\n")
                log(f"interactive: {line[:120]}", runlog)
        time.sleep(0.5)
    log("interactive: timeout", runlog)


def run_plan(plan: list[dict], cap: Capture, ser: Serial, qmp: QMP, res, runlog, ser_timeout: float) -> int:
    w, h = res
    failures = 0
    for i, step in enumerate(plan):
        label = step.get("label", f"step {i}")
        try:
            if "mark" in step:
                cap.set_scene(step["mark"])
                log(f"scene -> {step['mark']}", runlog)
            if "fps" in step:
                cap.fps = float(step["fps"])
            if "wait" in step:
                ok = ser.wait(step["wait"], float(step.get("timeout", ser_timeout)), bool(step.get("history", False)))
                log(f"{label}: wait /{step['wait']}/ -> {'ok' if ok else 'TIMEOUT'}", runlog)
                if not ok:
                    failures += 1
                    if step.get("required", False):
                        log("required wait failed; stopping plan", runlog)
                        return failures
            if "send" in step:
                ser.send(step["send"])
                log(f"{label}: send {step['send']!r}", runlog)
            if "key" in step:
                chord = [KEY_ALIASES.get(k.lower(), k.lower()) for k in str(step["key"]).split("+")]
                for _ in range(int(step.get("repeat", 1))):
                    qmp.send_keys(chord)
                    time.sleep(float(step.get("interval", 0.4)))
                log(f"{label}: key {chord} x{step.get('repeat', 1)}", runlog)
            if "type" in step:
                qmp.type_text(step["type"], delay=float(step.get("delay", 0.06)))
                log(f"{label}: typed {len(step['type'])} chars", runlog)
            if "mouse" in step:
                x, y = step["mouse"][:2]
                click = step["mouse"][2] if len(step["mouse"]) > 2 else None
                qmp.mouse(int(x), int(y), w, h, click)
                log(f"{label}: mouse {x},{y} {click or ''}", runlog)
            if "interactive" in step:
                interactive(float(step["interactive"]), cap, ser, qmp, res, runlog)
            if "sleep" in step:
                time.sleep(float(step["sleep"]))
        except Exception as e:
            failures += 1
            log(f"{label}: ERROR {e}", runlog)
    return failures


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--iso", required=True)
    ap.add_argument("--plan", required=True, help="YAML capture plan (list of steps)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--res", default="1920x1080")
    ap.add_argument("--fps", type=float, default=3.0, help="initial screendump rate")
    ap.add_argument("--smp", type=int, default=4)
    ap.add_argument("--mem", type=int, default=4096)
    ap.add_argument("--bios", action="store_true", help="SeaBIOS instead of UEFI")
    ap.add_argument("--serial-timeout", type=float, default=600)
    ap.add_argument("--max-seconds", type=float, default=5400, help="hard stop")
    args = ap.parse_args()
    args.uefi = not args.bios
    args.res = tuple(int(v) for v in args.res.lower().split("x"))

    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    runlog = (out / "plan-run.log").open("w")
    plan = yaml.safe_load(Path(args.plan).read_text())
    if not isinstance(plan, list):
        sys.exit("plan must be a YAML list of steps")

    cmd = qemu_cmd(args, out)
    log("qemu: " + " ".join(cmd), runlog)
    qlog = (out / "qemu.log").open("w")
    proc = subprocess.Popen(cmd, stdout=qlog, stderr=subprocess.STDOUT)
    rc = 1
    cap = None
    try:
        qmp = QMP(out / "qmp.sock")
        ser = Serial(out / "serial.sock", out / "serial.log")
        cap = Capture(qmp, out, args.fps, runlog)
        log("capture started", runlog)
        t_start = time.time()
        failures = run_plan(plan, cap, ser, qmp, args.res, runlog, args.serial_timeout)
        elapsed = time.time() - t_start
        log(f"plan finished: {failures} failing step(s), {cap.n} frames, {elapsed:.0f}s", runlog)
        rc = 0 if failures == 0 else 2
    finally:
        if cap:
            cap.stop()
        try:
            qmp.cmd("quit")
        except Exception:
            pass
        try:
            proc.wait(timeout=20)
        except Exception:
            proc.kill()
        runlog.close()
        qlog.close()
    summary = {"iso": args.iso, "frames": cap.n if cap else 0, "res": list(args.res),
               "uefi": args.uefi, "rc": rc}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary))
    return rc


if __name__ == "__main__":
    sys.exit(main())
