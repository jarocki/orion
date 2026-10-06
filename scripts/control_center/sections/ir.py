"""
Orion Cockpit — Orion Tools tab (DEC-PHASE12-057): every on-deck and optional tool,
read from the Workbench catalogue at runtime, plus the guided actions.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import tools_data as T  # noqa: E402
from ..helpers import ux  # noqa: E402
from ..helpers.state_polling import add_poll  # noqa: E402

_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_ROOT / "osint"))
try:
    import osint_server as _OS  # noqa: E402  (single authority for installed-probe logic)
except Exception:  # noqa: BLE001  pragma: no cover
    _OS = None

_ANALYSIS_DIR = os.path.expanduser("~/Analysis")
_SAMPLES_DIR = os.path.expanduser("~/orionx-samples")
_ARTIFACT_PATTERNS = ["*.raw", "*.mem", "*.dd", "*.img", "*.E01", "*.vmem", "*.log", "*.evtx"]
_PCAP_PATTERNS = ["*.pcap", "*.pcapng", "*.cap"]
_DIM = "#9aa0a6"
_POLL_MS = 30000


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
                              needs="artifact-analyzer.py", friendly="Artifact Analyzer", title="Artifact Analyzer")


def _run_storyboard(parent: Gtk.Widget) -> None:
    path = _pick_dir(parent, "Choose a folder of logs")
    if path:
        os.makedirs(_ANALYSIS_DIR, exist_ok=True)
        ux.launch_in_terminal(["storyboard-gen.py", path, "--output", _ANALYSIS_DIR],
                              needs="storyboard-gen.py", friendly="Storyboard Generator", title="Storyboard Generator")


def _run_pcap(parent: Gtk.Widget) -> None:
    path = _pick_file(parent, "Choose a packet capture", _PCAP_PATTERNS, "Packet captures")
    if path:
        ux.launch_in_terminal(["pcap-analyzer.py", path], needs="pcap-analyzer.py",
                              friendly="PCAP Analyzer", title="PCAP Analyzer")


def _run_lynis(_parent: Gtk.Widget) -> None:
    ux.launch_in_terminal(["sudo", "run-lynis.sh", "--quick"], needs="run-lynis.sh",
                          friendly="Lynis Security Audit", title="Lynis Security Audit")


def _run_samples(_parent: Gtk.Widget) -> None:
    ux.launch_in_terminal(["download-samples.sh", _SAMPLES_DIR], needs="download-samples.sh",
                          friendly="Download Samples", title="Download Samples")


def _run_toggle_theme(_parent: Gtk.Widget) -> None:
    # DEC-PHASE12-058: xfce4-terminal 1.1 has no file monitor on terminalrc, so
    # a window that exists when the toggle runs keeps its palette. Run the
    # toggle, THEN open a new terminal — born with the new palette — that shows
    # the script's own plan/do/check report. The operator sees both at once.
    ux.launch_detached(
        ["sh", "-c", "toggle-theme.sh; exec xfce4-terminal --title 'Orion-X theme' --hold -e 'toggle-theme.sh --status'"],
        needs="toggle-theme.sh", friendly="Toggle Theme")


_IR_TOOLS = [
    ("Artifact Analyzer", "Pick a memory/disk/log artifact and analyze it", _run_artifact),
    ("Storyboard Generator", "Pick a folder of logs and build an incident timeline", _run_storyboard),
    ("PCAP Analyzer", "Pick a .pcap and run the full traffic analysis", _run_pcap),
    ("Lynis Security Audit", "Run a quick system hardening audit (asks for sudo)", _run_lynis),
    ("Download Samples", "Populate ~/orionx-samples with offline practice data", _run_samples),
    ("Toggle Theme", "Switch amber ↔ green: wallpaper, GTK accent, window frames, terminal, prompt (opens a new terminal with the report)", _run_toggle_theme),
]


def _hdr(box: Gtk.Box, text: str) -> None:
    h = Gtk.Label()
    h.set_markup(f"<b>{text}</b>")
    h.set_halign(Gtk.Align.START)
    box.pack_start(h, False, False, 4)


def _optional_states(installable: list[dict]) -> dict:
    if _OS is None:
        return {}
    try:
        geo = _OS.geoip_state(Path(_OS.pewpew_feed.GEOIP_COUNTRY_DB), Path(_OS.pewpew_feed.GEOIP_ASN_DB))
        return _OS.optional_state(installable, bool(geo.get("available")))
    except Exception:  # noqa: BLE001
        return {}


def build_section() -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)
    title = Gtk.Label()
    title.set_markup("<b>Orion Tools</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)
    desc = Gtk.Label(label="Everything on this deck, and everything you can add. The list is read from the "
                           "Workbench catalogue at runtime, so it is what is actually here — not what a build promised.")
    desc.set_halign(Gtk.Align.START)
    desc.set_line_wrap(True)
    box.pack_start(desc, False, False, 2)

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
    opt_grid = Gtk.Grid()
    opt_grid.set_column_spacing(8)
    opt_grid.set_row_spacing(4)
    box.pack_start(opt_grid, False, False, 0)

    def _clear(g: Gtk.Grid) -> None:
        for ch in g.get_children():
            g.remove(ch)

    def _refresh() -> bool:
        local, installable = T.load_catalogue()
        _clear(deck_grid)
        for i, it in enumerate(T.on_deck(local, os.path.exists)):
            name = Gtk.Label()
            name.set_markup(f"{it.get('name', it.get('id'))}  <span foreground=\"{_DIM}\">{str(it.get('blurb', ''))[:90]}</span>")
            name.set_halign(Gtk.Align.START)
            name.set_line_wrap(True)
            name.set_hexpand(True)
            deck_grid.attach(name, 0, i, 1, 1)
            b = Gtk.Button(label="Run")
            b.get_style_context().add_class("orionx-tool")
            how, argv = T.launch_argv(it)
            if argv:
                if how == "detached":
                    b.connect("clicked", lambda _w, a=argv, n=it.get("name", ""): ux.launch_detached(a, needs=a[0], friendly=str(n)))
                else:
                    b.connect("clicked", lambda _w, a=argv, n=it.get("name", ""): ux.launch_in_terminal(
                        a, needs=a[0], friendly=str(n), title=str(n)))
            else:
                b.set_sensitive(False)
            deck_grid.attach(b, 1, i, 1, 1)
        states = _optional_states(installable)
        _clear(opt_grid)
        for i, it in enumerate(installable):
            st = states.get(str(it.get("id")), {})
            installed = bool(st.get("known") and st.get("installed"))
            name = Gtk.Label()
            tag = f"installed — {st.get('evidence', '')}" if installed else ("not installed" if st.get("known") else "unknown")
            name.set_markup(f"{it.get('name', it.get('id'))}  <span foreground=\"{_DIM}\">{tag}</span>")
            name.set_halign(Gtk.Align.START)
            name.set_line_wrap(True)
            name.set_hexpand(True)
            opt_grid.attach(name, 0, i, 1, 1)
            b = Gtk.Button(label="Re-run installer" if installed else "Install")
            b.get_style_context().add_class("orionx-tool")
            argv = T.install_argv(it)
            if argv:
                needs = argv[1] if argv[0] == "sudo" and len(argv) > 1 else argv[0]
                b.connect("clicked", lambda _w, a=argv, nd=needs, n=it.get("name", ""): ux.launch_in_terminal(
                    a, needs=nd, friendly=f"Install {n}", title=f"Install {n}"))
            else:
                b.set_sensitive(False)
            opt_grid.attach(b, 1, i, 1, 1)
        deck_grid.show_all()
        opt_grid.show_all()
        return True

    _refresh()
    add_poll(_POLL_MS, _refresh)
    return box
