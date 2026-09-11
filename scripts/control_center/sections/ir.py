"""
Orion-X Control Center — IR Tools section (W11-16: "work like magic").

The forensic analyzers require an input file/dir, so launching them bare just
printed a usage error (the operator's "tools just run --help" complaint). Each
tool now gathers what it needs FIRST — via an in-process GTK file/folder picker
(the Control Center is already GTK, so no scraping a terminal) — then runs on the
chosen artifact in an xfce4-terminal (--hold, so the output stays readable). A
missing tool becomes a one-line toast, never a raw error (helpers.ux).

  Artifact Analyzer     → pick a file  → artifact-analyzer.py <file> -o ~/Analysis/…
  Storyboard Generator  → pick a folder→ storyboard-gen.py -i <dir> -o …/timeline.html
  PCAP Analyzer         → pick a pcap  → pcap-analyzer.py <file>   (self-dated output)
  Lynis Security Audit  → sudo run-lynis.sh --quick  (real audit needs root)
  Download Samples      → download-samples.sh --offline --samples-dir ~/orionx-samples
  Toggle Theme          → runs in-session (no terminal — it's a UI action)

@decision DEC-PHASE9-001
@title Terminal emulator: xfce4-terminal (lxterminal is not installed)
@status accepted
@rationale All interactive launches use xfce4-terminal (via helpers.ux), matching
  the .desktop Exec pattern.

@decision DEC-PHASE11-034
@title IR tools gather their input before running (file/folder pickers)
@status accepted
@rationale Three of the six tools have a required input; bare launch produced a
  usage error. In-process Gtk.FileChooserDialog collects the artifact, then the
  tool runs on it with a sensible ~/Analysis output — the tools now DO something.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import os

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import ux  # noqa: E402

_ANALYSIS_DIR = os.path.expanduser("~/Analysis")
_SAMPLES_DIR = os.path.expanduser("~/orionx-samples")

_ARTIFACT_PATTERNS = [
    "*.raw", "*.dmp", "*.mem", "*.vmem", "*.dd", "*.img", "*.001", "*.e01",
    "*.pcap", "*.pcapng", "*.cap", "*.log", "*.evt", "*.evtx",
]
_PCAP_PATTERNS = ["*.pcap", "*.pcapng", "*.cap"]


def _pick_file(parent: Gtk.Widget, title: str, patterns: list[str], pname: str) -> str | None:
    dlg = Gtk.FileChooserDialog(title=title, transient_for=parent.get_toplevel(),
                                action=Gtk.FileChooserAction.OPEN)
    dlg.add_button("Cancel", Gtk.ResponseType.CANCEL)
    dlg.add_button("Open", Gtk.ResponseType.OK)
    filt = Gtk.FileFilter()
    filt.set_name(pname)
    for p in patterns:
        filt.add_pattern(p)
    dlg.add_filter(filt)
    allf = Gtk.FileFilter()
    allf.set_name("All files")
    allf.add_pattern("*")
    dlg.add_filter(allf)
    path = dlg.get_filename() if dlg.run() == Gtk.ResponseType.OK else None
    dlg.destroy()
    return path


def _pick_dir(parent: Gtk.Widget, title: str) -> str | None:
    dlg = Gtk.FileChooserDialog(title=title, transient_for=parent.get_toplevel(),
                                action=Gtk.FileChooserAction.SELECT_FOLDER)
    dlg.add_button("Cancel", Gtk.ResponseType.CANCEL)
    dlg.add_button("Select", Gtk.ResponseType.OK)
    path = dlg.get_filename() if dlg.run() == Gtk.ResponseType.OK else None
    dlg.destroy()
    return path


# --- per-tool handlers (parent is the clicked widget) ---

def _run_artifact(parent: Gtk.Widget) -> None:
    path = _pick_file(parent, "Select an artifact to analyze", _ARTIFACT_PATTERNS,
                      "Forensic artifacts")
    if not path:
        return
    _ensure_dir(_ANALYSIS_DIR)
    outdir = os.path.join(_ANALYSIS_DIR, os.path.basename(path) + "-analysis")
    ux.launch_in_terminal(["artifact-analyzer.py", path, "-o", outdir],
                          needs="artifact-analyzer.py", friendly="Artifact Analyzer",
                          title="Artifact Analyzer")


def _run_storyboard(parent: Gtk.Widget) -> None:
    d = _pick_dir(parent, "Select a folder of logs to correlate")
    if not d:
        return
    _ensure_dir(_ANALYSIS_DIR)
    out = os.path.join(_ANALYSIS_DIR, "timeline-" + os.path.basename(d.rstrip("/")) + ".html")
    ux.launch_in_terminal(["storyboard-gen.py", "-i", d, "-o", out, "-f", "html"],
                          needs="storyboard-gen.py", friendly="Storyboard Generator",
                          title="Storyboard Generator")


def _run_pcap(parent: Gtk.Widget) -> None:
    path = _pick_file(parent, "Select a packet capture to analyze", _PCAP_PATTERNS,
                      "Packet captures")
    if not path:
        return
    ux.launch_in_terminal(["pcap-analyzer.py", path],
                          needs="pcap-analyzer.py", friendly="PCAP Analyzer",
                          title="PCAP Analyzer")


def _run_lynis(_parent: Gtk.Widget) -> None:
    # A meaningful audit needs root; sudo prompts inside the terminal.
    ux.launch_in_terminal(["sudo", "run-lynis.sh", "--quick"],
                          needs="run-lynis.sh", friendly="Lynis Security Audit",
                          title="Lynis Security Audit")


def _run_samples(_parent: Gtk.Widget) -> None:
    _ensure_dir(_SAMPLES_DIR)
    ux.launch_in_terminal(["download-samples.sh", "--offline", "--samples-dir", _SAMPLES_DIR],
                          needs="download-samples.sh", friendly="Download Samples",
                          title="Download Samples")


def _run_toggle_theme(_parent: Gtk.Widget) -> None:
    # A UI action, not a forensic tool — run it in-session, no terminal.
    if ux.launch_detached(["toggle-theme.sh"], needs="toggle-theme.sh", friendly="Theme"):
        ux.notify("✓ Theme toggled — new terminals + wallpaper updated", ux.LEVEL_OK)


def _ensure_dir(path: str) -> None:
    try:
        os.makedirs(path, exist_ok=True)
    except OSError:
        pass


# (label, tooltip, handler)
_IR_TOOLS = [
    ("Artifact Analyzer", "Pick a memory/disk/log artifact and analyze it", _run_artifact),
    ("Storyboard Generator", "Pick a folder of logs and build an incident timeline", _run_storyboard),
    ("PCAP Analyzer", "Pick a .pcap and run the full traffic analysis", _run_pcap),
    ("Lynis Security Audit", "Run a quick system hardening audit (asks for sudo)", _run_lynis),
    ("Download Samples", "Populate ~/orionx-samples with offline practice data", _run_samples),
    ("Toggle Theme", "Switch the amber/green desktop + terminal theme", _run_toggle_theme),
]


def build_section() -> Gtk.Widget:
    """Return the IR Tools section widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    title = Gtk.Label()
    title.set_markup("<b>IR Tools</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    desc = Gtk.Label(
        label="Click a tool — you'll be asked for the file or folder it needs, then it "
        "runs on it. If a tool isn't installed you'll get a clear message, not an error."
    )
    desc.set_halign(Gtk.Align.START)
    desc.set_line_wrap(True)
    box.pack_start(desc, False, False, 4)

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

    return box
