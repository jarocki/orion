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


# ---------------------------------------------------------------- settings drawer
print("[settings drawer: posture is a request; a failed write reverts and says why (#95)]")
from control_center import settings_drawer as SDR  # noqa: E402

win = Gtk.Window()
aw = SDR.SettingsDrawer()
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

print("[settings drawer: R.A.I.N. test reports the real outcome (UX-12)]")
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

print("[settings drawer: R.A.I.N. settings go through rain_lib and toast (UX-13)]")
n0 = len(TOASTS)
aw._rain_vol.set_value(40)
wait_for(lambda: any("volume 40%" in m for _l, m in TOASTS[n0:]))
saved = (cfg_dir / "rain.json").read_text()
ck('"volume": 0.4' in saved, "volume saved through rain_lib.save_config")
ck(any("volume 40%" in m and "survives reboot:" in m for _l, m in TOASTS[n0:]), f"change toasts the setting + reboot truth ({TOASTS[n0:]})")
win.destroy()

# ---------------------------------------------------------------- Auto-Healing (#95)
print("[auto-healing consent left the Cockpit: no tab, no write on open (DEC-PHASE13-049)]")
ck(not (cfg_dir / "autonomy.json").exists(), "nothing in the Cockpit wrote autonomy.json")

# ---------------------------------------------------------------- whole Cockpit
print("[cockpit: only the visible tab polls; probes never block the main loop (P1-5)]")
from importlib.machinery import SourceFileLoader  # noqa: E402

from gi.repository import Gdk  # noqa: E402

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
# #105: the status strip's probes (vitals, systems/posture) belong to the
# strip above the tabs, not to the LIVE canvas, so they run on every tab.
status = [p for p in Poller.instances if p.owner is cw.header]
ck(len(status) == 2 and all(p.runs >= 1 for p in status), f"status-line probes ran ({len(status)} owned by the strip)")
ck(not [p for p in Poller.instances if p.owner is cw.da], "no poller is tied to the LIVE canvas any more")
mesh_page = cw._pages["mesh"]
cw.nb.set_current_page(mesh_page)
wait_for(lambda: all(p.runs >= 1 for p in Poller.instances if p.visible() and p.owner is not cw.header), 5.0)
mesh_pollers = [p for p in Poller.instances if p.visible() and p.owner is not cw.header]
ck(mesh_pollers and all(p.runs >= 1 for p in mesh_pollers), "switching to Mesh collects immediately")
runs_status = sum(p.runs for p in status)
pump(5.5)
ck(sum(p.runs for p in status) > runs_status, "status-line probes keep running while another tab is visible")
seen_header = []
for key in cw._pages:
    cw.select_tab(key)
    pump(0.2)
    seen_header.append(cw.header.get_mapped() and cw.header.get_allocated_height() >= CK.L.HEADER_H)
ck(all(seen_header), f"the status strip is on screen on every tab ({sum(seen_header)}/{len(seen_header)})")
cw.select_tab("mesh")

print("[cockpit: the settings drawer is on every tab, F2 and --settings open it (#95)]")
ck("healing" not in cw._pages and "healing" not in CCAPP.TAB_KEYS, "no Auto-Healing tab (moved to the Workbench)")
ck(not cw.drawer_rev.get_reveal_child() and not cw.settings_btn.get_active(), "the drawer starts closed")
cw.select_tab("live")
cw._on_key(None, type("K", (), {"keyval": Gdk.keyval_from_name("F2"), "state": Gdk.ModifierType(0)})())
wait_for(lambda: cw.drawer_rev.get_child_revealed(), 3.0)
ck(cw.drawer_rev.get_reveal_child() and cw.settings_btn.get_active(), "F2 on LIVE opens it, and the button says so")
dw = cw.drawer_rev.get_allocated_width()
ck(abs(dw - SDR.WIDTH) <= 24, f"it is {dw} px wide (WIDTH {SDR.WIDTH})")
ck(cw.da.get_allocated_width() >= 1100, f"LIVE keeps its width under the drawer ({cw.da.get_allocated_width()} px)")
opened = []
for key in cw._pages:
    cw.select_tab(key)
    pump(0.15)
    opened.append(cw.drawer_rev.get_child_revealed() and cw.settings.box.get_mapped())
ck(all(opened), f"the drawer stays out on every tab ({sum(opened)}/{len(opened)})")
dheads = [w.get_text() for w in walk(cw.settings.box) if isinstance(w, Gtk.Label) and w.get_style_context().has_class("orionx-heading")]
ck(dheads == ["Threat posture", "Audible alerts · R.A.I.N.", "Display", "DJ deck"], f"drawer groups: {dheads}")
first = next(w for w in walk(cw.settings.box) if isinstance(w, Gtk.Label))
ck(cw.settings.box.get_style_context().has_class("orionx-page") and first.get_text() == "Settings"
   and first.get_style_context().has_class("orionx-panel-title"), "the drawer wears the tab look, titled Settings")
dbtns = [w.get_label() for w in walk(cw.settings.box) if isinstance(w, Gtk.Button) and w.get_label()]
ck({"Toggle theme", "Open DJ Deck", "Open the Workbench", "Test alert"} <= set(dbtns), f"drawer buttons: {dbtns}")
aw_box = cw.nb.get_nth_page(cw._pages["awareness"]).get_child().get_child()
aw_radios = [w for w in walk(aw_box) if isinstance(w, Gtk.RadioButton)]
tools_box = cw.nb.get_nth_page(cw._pages["tools"]).get_child().get_child()
tools_btns = [w.get_label() for w in walk(tools_box) if isinstance(w, Gtk.Button)]
neb_box = cw.nb.get_nth_page(cw._pages["nebula"]).get_child().get_child()
neb_btns = [w.get_label() for w in walk(neb_box) if isinstance(w, Gtk.Button)]
ck(not aw_radios and "Toggle Theme" not in tools_btns and not any(str(b).startswith("Install") for b in tools_btns)
   and "Warm up model" not in neb_btns, "no tab still carries a moved control (posture, theme, installers, warm-up)")
cw._on_key(None, type("K", (), {"keyval": Gdk.keyval_from_name("F2"), "state": Gdk.ModifierType(0)})())
pump(0.4)
ck(not cw.drawer_rev.get_reveal_child() and not cw.settings_btn.get_active(), "F2 again closes it")
cw.settings_btn.set_active(True)
pump(0.2)
ck(cw.drawer_rev.get_reveal_child(), "the Settings button opens it")
cw.show_settings(False)
pump(0.3)
cw.select_tab("mesh")

print("[cockpit: one name per tab; no retired surface names on screen (UX-45)]")
for key, label, _icon, _b in CCAPP.SECTIONS:
    page = cw.nb.get_nth_page(cw._pages[key])
    texts = [w.get_text() for w in walk(page) if isinstance(w, Gtk.Label)]
    ck(texts and texts[0] == label, f"tab '{label}' content opens with its own name ({texts[:1]})")

print("[cockpit: every tab wears the LIVE look (#106)]")
import cairo  # noqa: E402
for key, label, _icon, _b in CCAPP.SECTIONS:
    box = cw.nb.get_nth_page(cw._pages[key]).get_child().get_child()
    first = next(w for w in walk(box) if isinstance(w, Gtk.Label))
    ck(box.get_style_context().has_class("orionx-page")
       and first.get_style_context().has_class("orionx-panel-title"),
       f"tab '{label}' is an orionx-page titled by an orionx-panel-title")
net_box = cw.nb.get_nth_page(cw._pages["network"]).get_child().get_child()
net_heads = [w.get_text() for w in walk(net_box) if isinstance(w, Gtk.Label) and w.get_style_context().has_class("orionx-heading")]
ck(net_heads == ["Interfaces", "Traffic by protocol", "VPN", "Packet capture"],
   f"Network tab has interfaces, protocol traffic, VPN and capture (#107-#109): {net_heads}")
net_buttons = [w.get_label() for w in walk(net_box) if isinstance(w, Gtk.Button)]
ck("Import WireGuard .conf…" in net_buttons and "Open Network Manager" in net_buttons,
   f"Network tab offers WireGuard import and the NM editor ({net_buttons})")
heads = [w for w in walk(cw.nb) if isinstance(w, Gtk.Label) and w.get_style_context().has_class("orionx-heading")]
ck(len(heads) >= 9, f"group headings come from style.heading() ({len(heads)} found)")
page_surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, 400, 300)
err = None
try:
    awareness_box = cw.nb.get_nth_page(cw._pages["awareness"]).get_child().get_child()
    cw._page_backdrop(awareness_box, cairo.Context(page_surf))
    page_surf.flush()
    px = bytes(page_surf.get_data())
    # BGRA: the frame's ember corner (x=8..22, y=8) must be drawn, the inside dark
    corner = px[(8 * 400 + 12) * 4: (8 * 400 + 12) * 4 + 4]
    inside = px[(150 * 400 + 200) * 4: (150 * 400 + 200) * 4 + 4]
    ck(corner[2] > 150 and corner[2] > corner[0] + 60, f"page backdrop draws the ember frame (corner BGRA {tuple(corner)})")
    ck(max(inside[:3]) < 40, f"page backdrop is LIVE's dark gradient (inside BGRA {tuple(inside)})")
except Exception as exc:  # noqa: BLE001
    err = exc
ck(err is None, f"page backdrop paints without error ({err})")
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
           "active": [{"id": "a1", "action": "kill_process", "target": "4242", "applied_ts": time.time(), "expires_ts": time.time() + 600}],
           "proposed": [{"action": "block_ip", "target": "203.0.113.77", "ts": time.time() - 60, "count": 3, "level": "propose",
                         "reason": "a host that swept our ports is scanning us; drop it", "event_id": "e1"}],
           "proposed_window": 1800.0, "autonomy": {"block_ip": "propose"}}
cw.systems = {"NEBULA": True, "FIREWALL": False, "MESH": None, "R.A.I.N.": True}
long = "ET SCAN Potential SSH Scan OUTBOUND from 192.168.4.57 to 203.0.113.9 port 22 — repeated 41 times in 60 s by the same source"
for i, sev in enumerate(("info", "notice", "warning", "critical") * 6):
    cw.tail.events.append({"ts": time.time() - i * 90, "severity": sev, "source": "suricata", "category": "ids",
                           "message": long, "id": "", "detail": {"src_ip": "192.168.4.57", "sid": 2210000,
                                                                 "signature": "S" * 3000, "ports_seen": list(range(60))}})
cw._sources_at = 0.0           # the events were appended by hand: let the poll re-aggregate now (#126)
cw._poll_events()
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
    cw._header(cairo.Context(surf), W, CK.L.HEADER_H - 1)   # the strip, at window width
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

# #126 (DEC-PHASE13-041): the pane draws cockpit_lib.actions_pane line for line,
# inside its own rectangle, at >= 11 px, fitted; SOURCES is build_feed's.
ax, ay, aw, ah = lay["actions"]
in_actions = [d for d in drawn[:n_first] if ax <= d[0] <= ax + aw and ay <= d[1] <= ay + ah + 30]
ck(in_actions and all(d[1] <= ay + ah - 4 for d in in_actions),
   f"DEFENSIVE ACTIONS text stays inside its panel (bottom {ay + ah}; lowest {max(d[1] for d in in_actions) if in_actions else None})")
ck(any(d[5].startswith("SUGGESTED (1)") for d in in_actions), "a heald proposal is drawn as SUGGESTED")
ck(any(d[5].startswith("IN FORCE (1)") for d in in_actions) and any(d[5] == "APPROVE?" for d in in_actions),
   "IN FORCE and APPROVE are still drawn beside it")
ck(any(d[5].startswith("SOURCES (") for d in in_actions) or any(d[5].startswith("+") and "more lines" in d[5] for d in in_actions),
   f"with every block full, SOURCES is drawn or counted, never silently cut ({[d[5] for d in in_actions][-2:]})")
ck(cw.sources is not None and cw.sources["rows"] == CK.L.attack_sources(cw.tail.events, time.time())["rows"][:len(cw.sources["rows"])]
   and cw.sources["rows"][0]["ip"] == "192.168.4.57", f"the Cockpit's SOURCES are attack_sources over its EventTail ({cw.sources and cw.sources['rows'][:1]})")


def pane_texts(heal: dict) -> list:
    cw.heal = heal
    drawn.clear()
    cw._text = rec_text
    try:
        cw._draw(cw.da, cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)))
    finally:
        cw._text = orig_text
    return [d for d in drawn if ax <= d[0] <= ax + aw and ay <= d[1] <= ay + ah]


cw.drill = False
base = {"readable": True, "chain_ok": True, "pending": [], "active": [], "proposed": [], "proposed_window": 1800.0}
t = pane_texts(dict(base, autonomy={"block_ip": "off", "kill_process": "off"}))
ck(any(d[5].startswith("autonomy is OFF for every action class") for d in t), "empty pane, all classes off: says so on its own line")
ck(all(d[3] >= 11 for d in t) and all(d[2] <= d[4] + 0.5 for d in t if d[4] is not None), "those lines are >= 11 px and fitted")
t = pane_texts(dict(base, autonomy={"block_ip": "propose"}))
ck(any(d[5].startswith("no bus event met a healing trigger") for d in t), "empty pane with consent: no qualifying event, said")
t = pane_texts(dict(base, autonomy={"block_ip": "propose"}, proposed=[
    {"action": "block_ip", "target": "203.0.113.77", "ts": time.time() - 60, "count": 3, "level": "propose", "reason": "r", "event_id": "e1"}]))
ck(any(d[5].startswith("SUGGESTED (1)") for d in t) and any(d[5].startswith("SOURCES (1, last 15 min)") for d in t)
   and any(d[5].startswith("192.168.4.57  CRIT") for d in t), "propose level (no approval waiting): SUGGESTED and SOURCES rows both fit")
t = pane_texts({"readable": False, "pending": [], "active": [], "reason": "orionx-heald not publishing (snapshot 45 s old)"})
ck(any(d[5].startswith("state unknown") for d in t) and any(d[5].startswith("SOURCES") for d in t),
   "stale snapshot: state unknown, and SOURCES still drawn")
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

print("[cockpit: THREAT PRESSURE / DEFENSIVE ACTIONS click opens the Attack Map (#124)]")
from types import SimpleNamespace  # noqa: E402
argv_log = WORK / "osint-argv"
stub("orionx-osint", f'echo "$@" >> "{argv_log}"')
cw.select_tab("live")
pump(0.3)
cw._draw(cw.da, cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)))   # refresh the click layout
lay = CK.L.live_layout(W, H)


def _lines() -> list:
    return argv_log.read_text().splitlines() if argv_log.exists() else []


def click(name: str, dx: float = 8, dy: float = 30):
    x, y, w, h = lay[name]
    cw.drill = False
    return cw._on_click(None, SimpleNamespace(x=x + dx, y=y + dy, type=None))


n0 = len(_lines())
ck(click("gauge") is True and wait_for(lambda: len(_lines()) == n0 + 1, 5.0), "a click on THREAT PRESSURE launches orionx-osint")
ck(_lines()[-1:] == ["--page pewpew"], f"with --page pewpew ({_lines()[-1:]})")
ck("Attack Map" in cw.toast_bar._label.get_text(), f"and the toast says so ({cw.toast_bar._label.get_text()!r})")
n1 = len(_lines())
click("actions")                                              # the title row, above the button
ck(wait_for(lambda: len(_lines()) == n1 + 1, 5.0), "a click on DEFENSIVE ACTIONS (off the button) launches it too")
# Paint a frame with an action pending (the heal poller has long since replaced
# the render test's state) and click the APPROVE button where it actually is.
cw.heal = {"readable": True, "chain_ok": True, "active": [],
           "pending": [{"id": "p2", "action": "block_ip", "target": "10.0.0.5", "proposed_ts": time.time()}]}
cw._draw(cw.da, cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, W, H)))
r = cw._approve_rect
ck(r is not None and CK.L.panel_at(lay, r[0], r[1]) == "actions", f"the APPROVE button is drawn inside DEFENSIVE ACTIONS ({r})")
n2 = len(_lines())
approved = []
cw._approve_selected = lambda: approved.append(1)
cw.drill = False
if r is not None:
    cw._on_click(None, SimpleNamespace(x=r[0] + r[2] / 2, y=r[1] + r[3] / 2, type=None))
pump(0.5)
ck(approved and len(_lines()) == n2, "the APPROVE button still approves and does not open the map")
click("events")
click("net")
click("systems")
pump(0.5)
ck(len(_lines()) == n2, "clicks on EVENTS / NETWORK / SYSTEMS launch nothing")
(BIN / "orionx-osint").unlink()
click("gauge")
pump(0.3)
ck("not installed" in cw.toast_bar._label.get_text(), f"missing orionx-osint -> error toast ({cw.toast_bar._label.get_text()!r})")

print(f"Results: {PASS} passed, {FAIL} failed", flush=True)
os._exit(1 if FAIL else 0)   # skip GTK teardown: it can hang under Xvfb
