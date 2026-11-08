"""
Orion Cockpit — Orion Tools tab (DEC-PHASE12-057, DEC-PHASE12-072): every
on-deck tool, read from the Workbench catalogue at runtime, plus the guided
actions.

#95 (DEC-PHASE13-048): the optional installers are the Workbench's (its
Optional section, DEC-PHASE12-052), so this tab's copy of them, and the
network gate that only they needed, are gone; the tab points there. Toggle
Theme is a display control and moved to the settings drawer.

The catalogue and the presence probes are collected in a worker thread while
the tab is visible (DEC-PHASE12-068).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import tools_data as T  # noqa: E402
from ..helpers import style, ux  # noqa: E402
from ..helpers.background import Poller  # noqa: E402

_ROOT = Path(__file__).resolve().parents[2]
if str(_ROOT / "osint") not in sys.path:
    sys.path.insert(0, str(_ROOT / "osint"))
try:
    import osint_server as _OS  # noqa: E402  (single authority for probes, route, posture)
    _OS_ERR = ""
except Exception as _exc:  # noqa: BLE001 - P2-7: shown in the tab, not swallowed
    _OS, _OS_ERR = None, f"{_exc.__class__.__name__}: {_exc}"
    print(f"orionx-cockpit: Orion Tools cannot import osint_server: {_OS_ERR}", file=sys.stderr)

_ANALYSIS_DIR = os.path.expanduser("~/Analysis")
_SAMPLES_DIR = os.path.expanduser("~/orionx-samples")
_ARTIFACT_PATTERNS = ["*.raw", "*.mem", "*.dd", "*.img", "*.E01", "*.vmem", "*.log", "*.evtx"]
_PCAP_PATTERNS = ["*.pcap", "*.pcapng", "*.cap"]
_DIM = "#9aa0a6"
_POLL_MS = 30000


def _esc(t: str) -> str:
    return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def network_state() -> tuple[dict, dict]:
    """(route, posture) from osint_server's readers; unknowns when it is unavailable."""
    if _OS is None:
        return ({"default_route": False, "interface": None},
                {"known": False, "reason": f"osint_server unavailable: {_OS_ERR}"})
    route = _OS.read_default_route(_OS._read(_OS.PROC_ROUTE) or "", _OS._read(_OS.PROC_ROUTE6) or "")
    return route, _OS.read_posture(_OS._read(_OS.POSTURE_STATUS))


def _pick_file(parent: Gtk.Widget, title: str, patterns: list[str], pname: str) -> str | None:
    dlg = Gtk.FileChooserDialog(title=title, parent=parent.get_toplevel(), action=Gtk.FileChooserAction.OPEN)
    dlg.add_button("Cancel", Gtk.ResponseType.CANCEL)
    dlg.add_button("Open", Gtk.ResponseType.OK)
    f = Gtk.FileFilter()
    f.set_name(pname)
    for p in patterns:
        f.add_pattern(p)
    dlg.add_filter(f)
    allf = Gtk.FileFilter()
    allf.set_name("All files")
    allf.add_pattern("*")
    dlg.add_filter(allf)
    path = dlg.get_filename() if dlg.run() == Gtk.ResponseType.OK else None
    dlg.destroy()
    return path


def _pick_dir(parent: Gtk.Widget, title: str) -> str | None:
    dlg = Gtk.FileChooserDialog(title=title, parent=parent.get_toplevel(), action=Gtk.FileChooserAction.SELECT_FOLDER)
    dlg.add_button("Cancel", Gtk.ResponseType.CANCEL)
    dlg.add_button("Select", Gtk.ResponseType.OK)
    path = dlg.get_filename() if dlg.run() == Gtk.ResponseType.OK else None
    dlg.destroy()
    return path


def _run_artifact(parent: Gtk.Widget) -> None:
    path = _pick_file(parent, "Choose an artifact to analyze", _ARTIFACT_PATTERNS, "Forensic artifacts")
    if path:
        os.makedirs(_ANALYSIS_DIR, exist_ok=True)
        ux.launch_in_terminal(["artifact-analyzer.py", path, "--output", _ANALYSIS_DIR],
                              needs="artifact-analyzer.py", friendly="Artifact Analyzer", title="Artifact Analyzer",
                              done_note=f"results go to {_ANALYSIS_DIR}")


def _run_storyboard(parent: Gtk.Widget) -> None:
    path = _pick_dir(parent, "Choose a folder of logs")
    if path:
        os.makedirs(_ANALYSIS_DIR, exist_ok=True)
        argv, out = T.storyboard_argv(path, _ANALYSIS_DIR, time.strftime("%Y%m%d-%H%M%S"))
        ux.launch_in_terminal(argv, needs="storyboard-gen.py", friendly="Storyboard Generator",
                              title="Storyboard Generator", done_note=f"report: {out}")


def _run_pcap(parent: Gtk.Widget) -> None:
    path = _pick_file(parent, "Choose a packet capture", _PCAP_PATTERNS, "Packet captures")
    if path:
        ux.launch_in_terminal(["pcap-analyzer.py", path], needs="pcap-analyzer.py",
                              friendly="PCAP Analyzer", title="PCAP Analyzer")


def _run_lynis(_parent: Gtk.Widget) -> None:
    ux.launch_in_terminal(["sudo", "run-lynis.sh", "--quick"], needs="run-lynis.sh",
                          friendly="Lynis Security Audit", title="Lynis Security Audit")


def _run_samples(_parent: Gtk.Widget) -> None:
    route, _posture = network_state()
    has = bool(route.get("default_route"))
    ux.launch_in_terminal(T.samples_argv(_SAMPLES_DIR, has), needs="download-samples.sh",
                          friendly="Download Samples", title="Download Samples",
                          done_note=(f"downloading into {_SAMPLES_DIR}" if has else
                                     f"no default route, so --offline: synthetic practice data into {_SAMPLES_DIR}"))


_IR_TOOLS = [
    ("Artifact Analyzer", "Pick a memory/disk/log artifact and analyze it", _run_artifact),
    ("Storyboard Generator", "Pick a folder of logs and build an HTML incident timeline in ~/Analysis", _run_storyboard),
    ("PCAP Analyzer", "Pick a .pcap and run the full traffic analysis", _run_pcap),
    ("Lynis Security Audit", "Run a quick system hardening audit (asks for sudo)", _run_lynis),
    ("Download Samples", "Populate ~/orionx-samples with practice data (downloads when there is a route; "
                         "generates synthetic data offline when there is not)", _run_samples),
]


def _hdr(box: Gtk.Box, text: str) -> Gtk.Label:
    h = style.heading(f"<b>{text}</b>")
    box.pack_start(h, False, False, 4)
    return h


def collect_tools(_visible: bool = True) -> dict:
    """Worker thread: catalogue and presence."""
    local, installable = T.load_catalogue()
    wb = T.workbench_state()
    deck = [(it, T.run_action(it)) for it in T.on_deck(local, os.path.exists)]
    return {"deck": [(it, a) for it, a in deck if a is not None], "n_installable": len(installable),
            "workbench": wb, "catalogue_empty": not local and not installable}


def build_section() -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)
    desc = Gtk.Label(label="Everything on this deck, and everything you can add. The list is read from the "
                           "Workbench catalogue at runtime and checked against what is installed here.")
    desc.set_halign(Gtk.Align.START)
    desc.set_line_wrap(True)
    box.pack_start(desc, False, False, 2)
    wbrow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    wblabel = Gtk.Label(label="Workbench server: checking…")
    wblabel.set_halign(Gtk.Align.START)
    wblabel.set_selectable(True)
    wbstop = Gtk.Button(label="Stop")
    wbstop.set_tooltip_text("Stop this operator's Workbench server (orionx-osint --stop). It restarts on the next open.")
    wbstop.set_sensitive(False)
    wbstop.connect("clicked", lambda _w: ux.launch_in_terminal(["orionx-osint", "--stop"], needs="orionx-osint",
                                                               friendly="Workbench server", title="Workbench — stop"))
    wbrow.pack_start(wblabel, True, True, 0)
    wbrow.pack_end(wbstop, False, False, 0)
    box.pack_start(wbrow, False, False, 2)

    _hdr(box, "Guided actions")
    grid = Gtk.Grid()
    grid.set_column_spacing(8)
    grid.set_row_spacing(6)
    grid.set_column_homogeneous(True)
    box.pack_start(grid, False, False, 0)
    for idx, (label, tip, handler) in enumerate(_IR_TOOLS):
        btn = Gtk.Button(label=label)
        btn.get_style_context().add_class("orionx-tool")
        btn.set_hexpand(True)
        btn.set_tooltip_text(tip)
        btn.connect("clicked", lambda w, h=handler: h(w))
        grid.attach(btn, idx % 2, idx // 2, 1, 1)

    _hdr(box, "On this deck")
    deck_grid = Gtk.Grid()
    deck_grid.set_column_spacing(8)
    deck_grid.set_row_spacing(4)
    box.pack_start(deck_grid, False, False, 0)
    _hdr(box, "Optional — install when you need it")
    opt_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    opt_note = Gtk.Label(label="The optional installers are on the Workbench (Optional), each with "
                               "whether it is installed here.")
    opt_note.set_halign(Gtk.Align.START)
    opt_note.set_line_wrap(True)
    opt_btn = Gtk.Button(label="Open the Workbench")
    opt_btn.get_style_context().add_class("orionx-tool")
    opt_btn.connect("clicked", lambda _w: ux.launch_detached(["orionx-osint"], friendly="the Workbench"))
    opt_row.pack_start(opt_note, True, True, 0)
    opt_row.pack_end(opt_btn, False, False, 0)
    box.pack_start(opt_row, False, False, 0)

    def _clear(g: Gtk.Grid) -> None:
        for ch in g.get_children():
            g.remove(ch)

    def _apply(d: dict | None, err) -> None:
        if err is not None:
            wblabel.set_text(f"Could not read the tool catalogue: {err}")
            return
        wb = d.get("workbench") or {}
        wblabel.set_text(f"Workbench server: {wb.get('note', 'unknown')}")
        wbstop.set_sensitive(bool(wb.get("running")))
        opt_note.set_text(f"The {d['n_installable']} optional installers are on the Workbench (Optional), "
                          "each with whether it is installed here.")
        _clear(deck_grid)
        if d["catalogue_empty"]:
            deck_grid.attach(Gtk.Label(label=f"catalogue missing or unreadable: {T.CATALOGUE}"), 0, 0, 1, 1)
        for i, (it, act) in enumerate(d["deck"]):
            name = Gtk.Label()
            blurb = _esc(str(it.get("blurb", ""))[:90])
            ex = f'\n<tt>e.g. {_esc(act["example"])}</tt>' if act["example"] else ""
            name.set_markup(f"{_esc(it.get('name', it.get('id')))}  <span foreground=\"{_DIM}\">{blurb}</span>{ex}")
            name.set_halign(Gtk.Align.START)
            name.set_line_wrap(True)
            name.set_hexpand(True)
            name.set_selectable(bool(act["example"]))
            deck_grid.attach(name, 0, i, 1, 1)
            b = Gtk.Button(label=act["label"])
            b.get_style_context().add_class("orionx-tool")
            argv, n = act["argv"], str(it.get("name", ""))
            if argv and act["how"] == "detached":
                b.connect("clicked", lambda _w, a=argv, n=n: ux.launch_detached(a, needs=a[0], friendly=n))
            elif argv:
                needs = argv[1] if argv[0] == "sudo" and len(argv) > 1 else argv[0]
                if act["example"]:
                    needs = act["example"].split()[0]
                b.connect("clicked", lambda _w, a=argv, nd=needs, n=n: ux.launch_in_terminal(
                    a, needs=nd, friendly=n, title=n))
            else:
                b.set_sensitive(False)
            deck_grid.attach(b, 1, i, 1, 1)
        deck_grid.show_all()

    Poller(box, _POLL_MS, collect_tools, _apply)
    return box
