"""
Orion Cockpit — Orion Tools tab (DEC-PHASE12-057, DEC-PHASE12-072): every
on-deck and optional tool, read from the Workbench catalogue at runtime, plus
the guided actions.

The catalogue, the presence probes and the network/posture gate are
collected in a worker thread while the tab is visible (DEC-PHASE12-068).

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
from ..helpers import ux  # noqa: E402
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
_AMBER = "#ffb300"
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


def _run_toggle_theme(_parent: Gtk.Widget) -> None:
    ux.launch_in_terminal(T.THEME_ARGV, needs="toggle-theme.sh", friendly="Toggle Theme",
                          title="Orion-X theme — toggle report", own_process=True,
                          done_note="its report says what changed; a second window opens in the new palette")


_IR_TOOLS = [
    ("Artifact Analyzer", "Pick a memory/disk/log artifact and analyze it", _run_artifact),
    ("Storyboard Generator", "Pick a folder of logs and build an HTML incident timeline in ~/Analysis", _run_storyboard),
    ("PCAP Analyzer", "Pick a .pcap and run the full traffic analysis", _run_pcap),
    ("Lynis Security Audit", "Run a quick system hardening audit (asks for sudo)", _run_lynis),
    ("Download Samples", "Populate ~/orionx-samples with practice data (downloads when there is a route; "
                         "generates synthetic data offline when there is not)", _run_samples),
    ("Toggle Theme", "Switch amber ↔ green: wallpaper, GTK accent, window frames, terminal, prompt "
                     "(shows the toggle's report, then a new terminal in the new palette)", _run_toggle_theme),
]


def _hdr(box: Gtk.Box, text: str) -> Gtk.Label:
    h = Gtk.Label()
    h.set_markup(f"<b>{text}</b>")
    h.set_halign(Gtk.Align.START)
    box.pack_start(h, False, False, 4)
    return h


def collect_tools(_visible: bool = True) -> dict:
    """Worker thread: catalogue, presence, optional-installer evidence, network gate."""
    local, installable = T.load_catalogue()
    states: dict = {}
    states_err = _OS_ERR
    if _OS is not None:
        try:
            geo = _OS.geoip_state(Path(_OS.pewpew_feed.GEOIP_COUNTRY_DB), Path(_OS.pewpew_feed.GEOIP_ASN_DB))
            states = _OS.optional_state(installable, bool(geo.get("available")))
        except Exception as exc:  # noqa: BLE001 - shown in the tab
            states_err = f"{exc.__class__.__name__}: {exc}"
    route, posture = network_state()
    head, block = T.network_gate(route, posture)
    deck = [(it, T.run_action(it)) for it in T.on_deck(local, os.path.exists)]
    return {"deck": [(it, a) for it, a in deck if a is not None], "installable": installable,
            "states": states, "states_err": states_err, "net_head": head, "block": block,
            "catalogue_empty": not local and not installable}


def build_section() -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)
    desc = Gtk.Label(label="Everything on this deck, and everything you can add. The list is read from the "
                           "Workbench catalogue at runtime and checked against what is installed here.")
    desc.set_halign(Gtk.Align.START)
    desc.set_line_wrap(True)
    box.pack_start(desc, False, False, 2)
    net = Gtk.Label(label="Network: checking…")
    net.set_halign(Gtk.Align.START)
    net.set_line_wrap(True)
    net.set_selectable(True)
    box.pack_start(net, False, False, 2)

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
    opt_hdr = _hdr(box, "Optional — install when you need it")
    opt_grid = Gtk.Grid()
    opt_grid.set_column_spacing(8)
    opt_grid.set_row_spacing(4)
    box.pack_start(opt_grid, False, False, 0)

    def _clear(g: Gtk.Grid) -> None:
        for ch in g.get_children():
            g.remove(ch)

    def _apply(d: dict | None, err) -> None:
        if err is not None:
            net.set_text(f"Could not read the tool catalogue: {err}")
            return
        block = d["block"]
        net.set_markup(_esc(d["net_head"]) + (f'\n<span foreground="{_AMBER}">Installs disabled: {_esc(block)}</span>' if block else ""))
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
        states = d["states"]
        opt_hdr.set_markup("<b>Optional — install when you need it</b>" + (
            f'  <span foreground="{_AMBER}">install state unknown: {_esc(d["states_err"])}</span>' if d["states_err"] else ""))
        _clear(opt_grid)
        for i, it in enumerate(d["installable"]):
            st = states.get(str(it.get("id")), {})
            installed = bool(st.get("known") and st.get("installed"))
            name = Gtk.Label()
            tag = f"installed — {st.get('evidence', '')}" if installed else ("not installed" if st.get("known") else "unknown")
            name.set_markup(f"{_esc(it.get('name', it.get('id')))}  <span foreground=\"{_DIM}\">{_esc(tag)}</span>")
            name.set_halign(Gtk.Align.START)
            name.set_line_wrap(True)
            name.set_hexpand(True)
            opt_grid.attach(name, 0, i, 1, 1)
            b = Gtk.Button(label=("Re-run installer" if installed else "Install") + " (needs network)")
            b.get_style_context().add_class("orionx-tool")
            argv = T.install_argv(it)
            if argv and not block:
                needs = argv[1] if argv[0] == "sudo" and len(argv) > 1 else argv[0]
                b.connect("clicked", lambda _w, a=argv, nd=needs, n=it.get("name", ""): ux.launch_in_terminal(
                    a, needs=nd, friendly=f"Install {n}", title=f"Install {n}"))
            else:
                b.set_sensitive(False)
                b.set_tooltip_text(block or "no installer command in the catalogue")
            opt_grid.attach(b, 1, i, 1, 1)
        deck_grid.show_all()
        opt_grid.show_all()

    Poller(box, _POLL_MS, collect_tools, _apply)
    return box
