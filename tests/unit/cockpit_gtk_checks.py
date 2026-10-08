"""GTK behaviour checks for the Cockpit; driven by tests/unit/test_cockpit_gtk.sh.

Needs a display (xvfb-run). Writes only under a temporary HOME.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
WORK = Path(tempfile.mkdtemp(prefix="orionx-gtk-"))
HOME = WORK / "home"
HOME.mkdir()
os.environ["HOME"] = str(HOME)
BIN = WORK / "bin"
BIN.mkdir()
os.environ["PATH"] = f"{BIN}:{os.environ.get('PATH', '/usr/bin:/bin')}"
sys.path.insert(0, str(ROOT / "scripts"))

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

PASS = FAIL = 0


def ck(cond: bool, msg: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS: " + msg)
    else:
        FAIL += 1
        print("  FAIL: " + msg)


def pump(seconds: float = 0.3) -> None:
    end = time.time() + seconds
    while time.time() < end:
        # Bounded by the clock too: under emulation the 160 ms LIVE redraw can
        # keep an event pending forever, and an unbounded inner loop hung.
        while Gtk.events_pending() and time.time() < end:
            Gtk.main_iteration_do(False)
        time.sleep(0.01)


def wait_for(cond, timeout: float = 10.0) -> bool:
    """Pump until cond() is true (emulated amd64 is slow; fixed sleeps flaked)."""
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        pump(0.1)
    return bool(cond())


def stub(name: str, body: str) -> None:
    p = BIN / name
    p.write_text("#!/bin/sh\n" + body + "\n")
    p.chmod(0o755)


def walk(w):
    yield w
    if isinstance(w, Gtk.Container):
        for c in w.get_children():
            yield from walk(c)


stub("orionx-event", "exit 0")
from control_center.helpers import ux  # noqa: E402

TOASTS: list[tuple[str, str]] = []
ux.set_notifier(lambda m, lvl: TOASTS.append((lvl, m)))


def last_toast() -> tuple[str, str]:
    return TOASTS[-1] if TOASTS else ("", "")


# ---------------------------------------------------------------- Awareness
print("[awareness: posture is a request; a failed write reverts and says why]")
from control_center.sections import awareness as AW  # noqa: E402

win = Gtk.Window()
aw = AW._AwarenessWidget()
win.add(aw.box)
win.show_all()
pump(0.5)
cfg_dir = HOME / ".config" / "orionx"
cfg_dir.mkdir(parents=True, exist_ok=True)
aw._radios["1"].set_active(True)
pump(0.2)
ck((cfg_dir / "threat-posture").read_text() == "1\n", "selecting Tier 1 writes the request file")
lvl, msg = last_toast()
ck(msg.startswith("requested Tier 1") and "waiting for orionx-postured" in msg and "survives reboot:" in msg,
   f"toast says requested + reboot truth, not 'set' ({msg})")
ck("enforced" not in aw._posture_status.get_text().split("—")[0], f"status line is not 'enforced' ({aw._posture_status.get_text()})")
if os.geteuid() != 0:
    cfg_dir.chmod(0o500)
    aw._radios["2"].set_active(True)
    pump(0.2)
    cfg_dir.chmod(0o700)
    lvl, msg = last_toast()
    ck(lvl == "error" and "NOT changed" in msg and "threat-posture" in msg, f"unwritable config -> error toast ({msg})")
    ck(aw._radios["1"].get_active() and not aw._radios["2"].get_active(), "the radio reverts to the tier actually requested")
    ck((cfg_dir / "threat-posture").read_text() == "1\n", "request file unchanged")
else:
    print("  (skipped unwritable case: root)")

print("[awareness: R.A.I.N. test reports the real outcome (UX-12)]")
stub("orionx-rain", 'echo "paplay: no audio device" >&2; exit 3')
n0 = len(TOASTS)
aw._on_rain_test(None)
wait_for(lambda: any("exit 3" in m for _l, m in TOASTS[n0:]))
msgs = [m for _l, m in TOASTS[n0:]]
ck(any("✗ R.A.I.N. test failed (exit 3): paplay: no audio device" in m for m in msgs), f"failed test says so with the error ({msgs})")
ck(not any("played" in m and "✗" not in m for m in msgs[1:]), "no success toast after a failure")
stub("orionx-rain", "exit 0")
n0 = len(TOASTS)
aw._on_rain_test(None)
wait_for(lambda: any("exit 0" in m for _l, m in TOASTS[n0:]))
ck(any("exit 0" in m for _l, m in TOASTS[n0:]), "exit 0 is reported as exit 0, with the next step if nothing was heard")
(BIN / "orionx-rain").unlink()
n0 = len(TOASTS)
aw._on_rain_test(None)
wait_for(lambda: any("not installed" in m for _l, m in TOASTS[n0:]))
ck(any("not installed" in m for _l, m in TOASTS[n0:]), "missing orionx-rain -> 'not installed'")

print("[awareness: R.A.I.N. settings go through rain_lib and toast (UX-13)]")
n0 = len(TOASTS)
aw._rain_vol.set_value(40)
wait_for(lambda: any("volume 40%" in m for _l, m in TOASTS[n0:]))
saved = (cfg_dir / "rain.json").read_text()
ck('"volume": 0.4' in saved, "volume saved through rain_lib.save_config")
ck(any("volume 40%" in m and "survives reboot:" in m for _l, m in TOASTS[n0:]), f"change toasts the setting + reboot truth ({TOASTS[n0:]})")
win.destroy()

# ---------------------------------------------------------------- Auto-Healing
print("[auto-healing: a failed write reverts and says why (P2-5, UX-11)]")
from control_center.sections import auto_healing as AH  # noqa: E402

win = Gtk.Window()
ah = AH._AutoHealingWidget()
win.add(ah.box)
win.show_all()
pump(0.2)
ck((cfg_dir / "autonomy.json").exists() and "Wrote default" in ah._status.get_text(), "materialised defaults are announced")
ck("survives reboot:" in ah._status.get_text(), "the grid states whether the pre-approvals survive reboot")
combo = ah._combos["block_ip"]
combo.set_active(AH._LEVELS.index("autonomous"))
pump(0.2)
ck('"block_ip": "autonomous"' in (cfg_dir / "autonomy.json").read_text(), "level saved")
if os.geteuid() != 0:
    cfg_dir.chmod(0o500)
    combo.set_active(AH._LEVELS.index("off"))
    pump(0.2)
    cfg_dir.chmod(0o700)
    lvl, msg = last_toast()
    ck(lvl == "error" and "NOT changed" in msg, f"unwritable -> error toast ({msg})")
    ck(combo.get_active_text() == "autonomous", "combo reverts to what the engine will read")
win.destroy()

# ---------------------------------------------------------------- whole Cockpit
print("[cockpit: only the visible tab polls; probes never block the main loop (P1-5)]")
from importlib.machinery import SourceFileLoader  # noqa: E402

from control_center.helpers.background import Poller  # noqa: E402

CK = SourceFileLoader("orionx_cockpit", str(ROOT / "scripts/cockpit/orionx-cockpit")).load_module()
CCAPP = sys.modules["control_center.app"]
stub("systemctl", "sleep 3; echo inactive")      # a slow probe: must not stall the loop
Poller.instances.clear()
t0 = time.time()
cw = CK.Cockpit(tab="live")
build_s = time.time() - t0
cw.set_default_size(1366, 701)
cw.show_all()
ck(build_s < 2.0, f"window built in {build_s:.2f} s with a 3 s systemctl (was serial, 30 s+ with Matrix unreachable)")
ticks = {"n": 0}
from gi.repository import GLib  # noqa: E402


def _beat() -> bool:
    ticks["n"] += 1
    return True


GLib.timeout_add(50, _beat)
pump(4.0)
ck(ticks["n"] >= 50, f"main loop kept ticking while probes ran ({ticks['n']} x 50 ms beats in 4 s)")
hidden = [p for p in Poller.instances if not p.visible() and not p.run_hidden]
ck(hidden and all(p.runs == 0 for p in hidden), f"{len(hidden)} hidden-tab pollers ran {sum(p.runs for p in hidden)} times")
live = [p for p in Poller.instances if p.owner is cw.da]
ck(live and all(p.runs >= 1 for p in live), "LIVE probes ran while LIVE is visible")
mesh_page = cw._pages["mesh"]
cw.nb.set_current_page(mesh_page)
wait_for(lambda: all(p.runs >= 1 for p in Poller.instances if p.visible() and p.owner is not cw.da), 5.0)
mesh_pollers = [p for p in Poller.instances if p.visible() and p.owner is not cw.da]
ck(mesh_pollers and all(p.runs >= 1 for p in mesh_pollers), "switching to Mesh collects immediately")
runs_live = sum(p.runs for p in live)
pump(5.5)
ck(sum(p.runs for p in live) == runs_live, "LIVE probes stop while another tab is visible")

print("[cockpit: one name per tab; no retired surface names on screen (UX-45)]")
for key, label, _icon, _b in CCAPP.SECTIONS:
    page = cw.nb.get_nth_page(cw._pages[key])
    texts = [w.get_text() for w in walk(page) if isinstance(w, Gtk.Label)]
    ck(texts and texts[0] == label, f"tab '{label}' content opens with its own name ({texts[:1]})")
retired = ("Control Center", "IR Tools", "Investigation Surface", "Situational Awareness")
seen = []
for w in walk(cw):
    for t in ((w.get_text() if isinstance(w, Gtk.Label) else ""), (w.get_tooltip_text() or ""),
              (w.get_label() if isinstance(w, Gtk.Button) else "") or ""):
        if any(r in t for r in retired):
            seen.append(t)
ck(not seen, f"no retired names in any label, button or tooltip ({seen[:3]})")

print("[LIVE at the 1366x768 reference deck (UX-10/16..23)]")
import cairo  # noqa: E402

cw.nb.set_current_page(0)
cw.unmaximize()
cw.resize(1366, 701)            # 768 - 30 px panel - ~37 px title bar
pump(1.0)
W, H = cw.da.get_allocated_width(), cw.da.get_allocated_height()
print(f"  (LIVE drawing area at a 1366x701 window: {W}x{H})")
ck(W >= 1100 and H >= 600, f"LIVE gets {W}x{H}")
cw.vitals = {"hostname": "incident-2026-10-07-site-b-laptop-03-with-an-even-longer-name", "primary_ipv4": "10.200.113.17",
             "interfaces": [{"iface": "wlan0", "ipv4": ["10.200.113.17/24"]}], "gateway": "10.200.113.1",
             "gateway_dev": "wlan0", "uptime_s": 4000, "cpu_pct": 37.0, "load": (0.5, 0.4, 0.3), "cpu_count": 4,
             "mem": {"used_pct": 61.0, "total_kib": 8000000, "available_kib": 3000000},
             "disk": {"used_pct": 40.0, "free_bytes": 9 * 1024 ** 3, "path": "/"}}
cw.posture, cw.posture_status = "1", {}
cw.heal = {"readable": True, "chain_ok": True, "pending": [{"id": "p1", "action": "block_ip", "target": "10.0.0.5", "proposed_ts": time.time()}],
           "active": [{"id": "a1", "action": "kill_process", "target": "4242", "applied_ts": time.time(), "expires_ts": time.time() + 600}]}
cw.systems = {"NEBULA": True, "FIREWALL": False, "MESH": None, "R.A.I.N.": True}
long = "ET SCAN Potential SSH Scan OUTBOUND from 192.168.4.57 to 203.0.113.9 port 22 — repeated 41 times in 60 s by the same source"
for i, sev in enumerate(("info", "notice", "warning", "critical") * 6):
    cw.tail.events.append({"ts": time.time() - i * 90, "severity": sev, "source": "suricata", "category": "ids",
                           "message": long, "id": "", "detail": {"src_ip": "192.168.4.57", "sid": 2210000,
                                                                 "signature": "S" * 3000, "ports_seen": list(range(60))}})
drawn: list = []
orig_text = cw._text


def rec_text(cr, x, y, s, size=12.0, color=None, bold=False, align="left", glow=0.0, max_w=None):
    kw = {"bold": bold, "align": align, "glow": glow, "max_w": max_w}
    if color is not None:
        kw["color"] = color
    adv = orig_text(cr, x, y, s, size, **kw)
    shown = cw._fit(cr, s, size, max_w, bold) if max_w is not None else s
    left = x - (adv if align == "right" else adv / 2 if align == "center" else 0)
    drawn.append((left, y, adv, size, max_w, shown))
    return adv


cw._text = rec_text
surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)
cw.sel = 2
err = None
try:
    cw._draw(cw.da, cairo.Context(surf))
    n_first = len(drawn)
    surf.write_to_png(os.environ.get("ORIONX_GTK_PNG", str(WORK / "live.png")).replace(".png", "-stream.png"))
    cw.drill = True
    cw._draw(cw.da, cairo.Context(surf))
    surf.write_to_png(os.environ.get("ORIONX_GTK_PNG") or str(WORK / "live.png"))
except Exception as exc:  # noqa: BLE001
    err = exc
cw._text = orig_text
ck(err is None, f"LIVE renders with long hostname, messages, pending action and drill-down open ({err})")
lay = CK.L.live_layout(W, H)
sx, sy, sw, sh = lay["systems"]
sys_texts = [d for d in drawn if sx <= d[0] <= sx + sw and sy <= d[1] <= sy + sh + 30]
ck(sys_texts and all(d[1] <= sy + sh - 4 for d in sys_texts), f"SYSTEMS words sit inside their panel (bottom {sy + sh}; lowest baseline {max(d[1] for d in sys_texts) if sys_texts else None})")
ck(all(d[3] >= 11 or d[3] == 0 for d in drawn), f"no text below 11 px (min {min(d[3] for d in drawn)})")
fitted = [d for d in drawn if d[4] is not None]
ck(fitted and all(d[2] <= d[4] + 0.5 for d in fitted), f"every fitted string fits its width ({len(fitted)} strings)")
who = [d for d in drawn if d[5].startswith("incident-")]
ck(who and who[0][5].endswith("…") and who[0][0] + who[0][2] < W - 16 - 180 - 300 - 16, "long hostname ellipsised before the posture badge")
stream = [d for d in drawn[:n_first] if d[5].startswith("ET SCAN")]
ck(stream and all(d[5].endswith("…") for d in stream), "stream messages end with an ellipsis, not a mid-word clip")
ck(any(d[5] == "CRIT" for d in drawn) and any(d[5] == "INFO" for d in drawn), "severity words drawn in the stream")
ck(any("rows 1" in d[5] for d in drawn), "drill-down pages long detail (rows x–y of n)")
toasts_before = len(TOASTS)
cw._say("survives reboot: NO — test\nsquelched: sid 1", "ok")
ck(cw.toast_bar.get_reveal_child() and "survives reboot" in cw.toast_bar._label.get_text(), "LIVE outcomes use the shared, wrapping ToastBar")
ck((HOME / ".cache" / "orionx" / "cockpit.log").read_text().count("survives reboot: NO — test") == 1, "toasts are logged to ~/.cache/orionx/cockpit.log")
cw.toast_bar.notify("✗ boom", "error")
pump(9.0)
ck(cw.toast_bar.get_reveal_child(), "an error toast is still up after 9 s (dismiss with ✕)")
_ = toasts_before

print("[keys: Ctrl+PgUp/PgDn reach GTK, Alt+N picks a tab, a stray q/Esc does not quit (UX-20, UX-47)]")
from gi.repository import Gdk  # noqa: E402

quits: list = []
CK.Gtk.main_quit = lambda *a: quits.append(1)


class _Key:
    def __init__(self, name: str, state=0):
        self.keyval = Gdk.keyval_from_name(name)
        self.state = Gdk.ModifierType(state)


C_, A_ = int(Gdk.ModifierType.CONTROL_MASK), int(Gdk.ModifierType.MOD1_MASK)
cw.toast_bar.set_reveal_child(False)
cw.drill = False
cw.nb.set_current_page(0)
ck(cw._on_key(None, _Key("Page_Down", C_)) is False, "Ctrl+PgDn on LIVE is left to the notebook")
ck(cw._on_key(None, _Key("3", A_)) is True and cw.nb.get_current_page() == 2, "Alt+3 opens the third tab")
ck(cw._on_key(None, _Key("s")) is False, "'s' on a GTK tab is not swallowed")
cw.nb.set_current_page(0)
cw._on_key(None, _Key("q"))
cw._on_key(None, _Key("Escape"))
ck(not quits, "plain q and Esc do not quit the live view")
cw._on_key(None, _Key("q", C_))
ck(len(quits) == 1, "Ctrl+Q quits")

# --tab must land on the tab: GtkNotebook ignores set_current_page for a page
# that is not visible yet, so selecting in __init__ left every --tab on LIVE.
ck(cw.select_tab("mesh") and cw.nb.get_current_page() == cw._pages["mesh"], "--tab mesh lands on the Mesh tab after show_all")
ck(cw.select_tab("live") and cw.nb.get_current_page() == 0, "and back to LIVE")
ck(not cw.select_tab("no-such-tab"), "unknown tab key is refused, not ignored")

print(f"Results: {PASS} passed, {FAIL} failed", flush=True)
os._exit(1 if FAIL else 0)   # skip GTK teardown: it can hang under Xvfb
