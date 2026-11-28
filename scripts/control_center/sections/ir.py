"""
Orion Cockpit — Orion Tools tab (DEC-PHASE12-057, DEC-PHASE12-072): every
on-deck tool, read from the Workbench catalogue at runtime, plus the guided
actions.

#199 (DEC-PHASE13-060): optional tools are managed here again, at the top of
the tab: grouped status tiles that install and uninstall in place through
`pkexec orionx-optional` (sections/optional.py). #95 had moved them to the
Workbench, which can only show a command to copy (its loopback page never
runs root actions, DEC-PHASE13-049); the Workbench keeps a read-only mirror.
Toggle Theme is a display control and lives in the settings drawer.

The catalogue and the presence probes are collected in a worker thread while
the tab is visible (DEC-PHASE12-068).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import posture_data as PD  # noqa: E402  (DEC-PHASE13-073: sensor start/stop requests)
from ..helpers import tools_data as T  # noqa: E402
from ..helpers import style, ux  # noqa: E402
from ..helpers.background import Poller  # noqa: E402
from . import optional as OPT  # noqa: E402  (#199: optional tools, grouped, install/uninstall in place)
from . import tiles as TL  # noqa: E402  (DEC-PHASE13-074: one tile for every list on this tab)

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


# (label, tooltip, handler, the command it needs on PATH)
_IR_TOOLS = [
    ("Artifact Analyzer", "Pick a memory/disk/log artifact and analyze it", _run_artifact, "artifact-analyzer.py"),
    ("Storyboard Generator", "Pick a folder of logs and build an HTML incident timeline in ~/Analysis",
     _run_storyboard, "storyboard-gen.py"),
    ("PCAP Analyzer", "Pick a .pcap and run the full traffic analysis", _run_pcap, "pcap-analyzer.py"),
    ("Lynis Security Audit", "Run a quick system hardening audit (asks for sudo)", _run_lynis, "run-lynis.sh"),
    ("Download Samples", "Populate ~/orionx-samples with practice data (downloads when there is a route; "
                         "generates synthetic data offline when there is not)", _run_samples, "download-samples.sh"),
]

NEBULA_UNIT = "nebula-runtime.service"


def _hdr(box: Gtk.Box, text: str, note: str = "") -> Gtk.Label:
    h = style.heading(f"<b>{text}</b>")
    box.pack_start(h, False, False, 4)
    if note:
        n = Gtk.Label(xalign=0)
        n.set_line_wrap(True)
        n.set_markup(f'<span foreground="{OPT.V.DIM}" size="small">{_esc(note)}</span>')
        box.pack_start(n, False, False, 0)
    return h


def _active(unit: str) -> bool:
    try:
        r = subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.stdout.strip() == "active"


# ---------------------------------------------------------------- pure views
def deck_groups(local: list[dict], exists, pkg=T.pkg_installed) -> list[tuple[str, list[dict]]]:
    """On this deck, grouped: [(title, [{'item','present','action'}, ...]), ...]. Pure but for the probes.

    Every catalogue entry is listed, present or not (DEC-PHASE13-074): an entry
    missing from this deck is shown as MISSING rather than hidden, so the list
    is the catalogue checked against the deck, not the catalogue filtered by it.
    """
    groups: dict[str, list[dict]] = {"Workbench pages": [], "Orion-X commands": [], "Base tools": []}
    for it in local:
        act = T.run_action(it)
        if act is None:          # the Cockpit itself
            continue
        rp = str(it.get("runtime_path") or "")
        here = T.present(rp, exists, pkg)
        key = ("Workbench pages" if it.get("kind") == "page"
               else "Base tools" if rp.startswith("pkg:") else "Orion-X commands")
        groups[key].append({"item": it, "present": here, "action": act})
    return [(k, v) for k, v in groups.items() if v]


def deck_tile(e: dict) -> dict:
    """{'word','level','line','tip'} for one On-this-deck entry. Pure."""
    it, act = e["item"], e["action"]
    blurb = str(it.get("blurb", ""))
    rp = str(it.get("runtime_path") or "")
    if not e["present"]:
        return {"word": "MISSING", "level": "error",
                "line": f"not on this deck ({rp[4:] + ' package' if rp.startswith('pkg:') else rp})",
                "tip": blurb}
    word = "IN THE IMAGE" if rp.startswith("pkg:") else "READY"
    line = f"e.g. {act['example']}" if act.get("example") else (str(it.get("command") or "") or blurb)
    return {"word": word, "level": "ok", "line": line,
            "tip": blurb + (f"\n\ne.g. {act['example']}" if act.get("example") else "")}


def guided_tile(needs: str, which=shutil.which, online: bool | None = None, name: str = "") -> dict:
    """{'word','level','line'} for one guided action. Pure but for `which`."""
    if not which(needs):
        return {"word": "MISSING", "level": "error", "line": f"{needs} is not on PATH"}
    if name == "Download Samples" and online is not None:
        return {"word": "READY", "level": "ok",
                "line": "online: downloads the practice set" if online else "offline: generates synthetic practice data"}
    return {"word": "READY", "level": "ok", "line": f"runs {needs} in a terminal"}


def service_tile(kind: str, d: dict) -> dict:
    """{'word','level','line','start','stop'} for the Nebula runtime and the Workbench server. Pure."""
    if kind == "nebula":
        on = bool(d.get("nebula_active"))
        return {"word": "RUNNING" if on else "STOPPED", "level": "ok" if on else "info",
                "line": ("local model server on 127.0.0.1 · nebula stop frees its memory" if on
                         else "model server stopped · Start, or nebula start"),
                "start": not on, "stop": on}
    wb = d.get("workbench") or {}
    on = bool(wb.get("running"))
    return {"word": "RUNNING" if on else "STOPPED", "level": "ok" if on else "info",
            "line": str(wb.get("note", "unknown")), "start": True, "stop": on}


# ---------------------------------------------------------------- workers
def collect_tools(_visible: bool = True) -> dict:
    """Worker thread: catalogue, presence, the sensors' and services' state."""
    local, installable = T.load_catalogue()
    route, _posture = network_state()
    return {"deck": deck_groups(local, os.path.exists),
            "guided": [(name, tip, handler, guided_tile(needs, online=bool(route.get("default_route")), name=name))
                       for name, tip, handler, needs in _IR_TOOLS],
            "status": PD.read_status(),
            "overrides": PD.load_sensor_overrides(),
            "nebula_active": _active(NEBULA_UNIT),
            "workbench": T.workbench_state(),
            "now": time.time(),
            "catalogue_empty": not local and not installable}


def _run_bg(argv: list[str], friendly: str, done, ok_text: str) -> None:
    """Run argv off the GTK thread; report through the toast bar; then `done()`."""
    def work() -> None:
        try:
            r = subprocess.run(argv, capture_output=True, text=True, timeout=180, check=False,
                               stdin=subprocess.DEVNULL)
            rc, out = r.returncode, (r.stderr or r.stdout or "").strip().splitlines()
            msg = ok_text if rc == 0 else f"✗ {friendly}: exit {rc} — {out[-1] if out else 'no output'}"
        except FileNotFoundError:
            rc, msg = 127, f"✗ {friendly}: {argv[0]} is not on this deck"
        except (OSError, subprocess.SubprocessError) as exc:
            rc, msg = 1, f"✗ {friendly}: {exc}"
        GLib.idle_add(lambda: (ux.notify(msg, ux.LEVEL_OK if rc == 0 else ux.LEVEL_ERROR), done(), False)[2])
    ux.notify(f"{friendly}: working…", ux.LEVEL_INFO)
    threading.Thread(target=work, daemon=True, name="orionx-tools-svc").start()


# ---------------------------------------------------------------- the tab
def build_section() -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)
    desc = Gtk.Label(label="Everything on this deck, and everything you can add. Each tool shows its status "
                           "and the switches that change it: start/stop for sensors and services, "
                           "install/uninstall for optional tools, run/open for the rest.")
    desc.set_halign(Gtk.Align.START)
    desc.set_line_wrap(True)
    box.pack_start(desc, False, False, 2)

    _hdr(box, "Sensors &amp; services",
         "Suricata and Zeek follow the threat-posture tier (on at Tier 1 and 2). Start or Stop overrides "
         "the tier for that sensor until you change the tier or press Follow tier.")
    svc_flow = TL.flow()
    box.pack_start(svc_flow, False, False, 0)

    panel = OPT.build()
    box.pack_start(panel.box, False, False, 4)
    box.optional_panel = panel   # tests/unit/cockpit_gtk_checks.py reaches the panel through the tab

    _hdr(box, "Guided actions", "Each one picks its input, then runs in a terminal you can watch.")
    guided_flow = TL.flow()
    box.pack_start(guided_flow, False, False, 0)

    _hdr(box, "On this deck", "The Workbench catalogue checked against this deck: what is here, and how to use it.")
    deck_flow = TL.flow()
    box.pack_start(deck_flow, False, False, 0)
    err = Gtk.Label(xalign=0)
    err.set_line_wrap(True)
    box.pack_start(err, False, False, 0)

    def _clear(fb: Gtk.FlowBox) -> None:
        for ch in fb.get_children():
            fb.remove(ch)

    poller: list = []

    def _kick() -> None:
        if poller:
            poller[0].kick()

    def _sensor(name: str, state) -> None:
        ok, why = PD.request_sensor(name, state)
        label = "Suricata" if name == "suricata" else "Zeek"
        what = "start" if state is True else "stop" if state is False else "follow the tier"
        ux.notify(f"{label}: {what} requested — orionx-postured applies it within a few seconds" if ok
                  else f"✗ {label}: could not save the request: {why}", ux.LEVEL_INFO if ok else ux.LEVEL_ERROR)
        GLib.timeout_add(3000, lambda: (_kick(), False)[1])

    def _service(kind: str, start: bool) -> None:
        if kind == "nebula":
            _run_bg(["nebula", "start" if start else "stop"], "Nebula", _kick,
                    "Nebula started — nebula warmup loads the model" if start else "Nebula stopped")
        elif start:
            ux.launch_detached(["orionx-osint"], needs="orionx-osint", friendly="the Workbench")
            GLib.timeout_add(4000, lambda: (_kick(), False)[1])
        else:
            _run_bg(["orionx-osint", "--stop"], "Workbench server", _kick, "Workbench server stopped")

    def _apply(d: dict | None, e) -> None:
        if e is not None:
            err.set_text(f"Could not read the tool catalogue: {e}")
            return
        err.set_text(f"catalogue missing or unreadable: {T.CATALOGUE}" if d["catalogue_empty"] else "")

        # Sensors & services
        _clear(svc_flow)
        frame, gb = TL.group("Sensors", f"{sum(1 for n in PD.SENSOR_NAMES if PD.sensor_view(n, d['status'], d['now'], d['overrides'])['word'] == 'RUNNING')} of 2 running")
        for n in PD.SENSOR_NAMES:
            v = PD.sensor_view(n, d["status"], d["now"], d["overrides"])
            # A switch, not a pair: only the action that applies is offered
            # (both when the state is UNKNOWN, so the operator is never stuck).
            btns = []
            if v["start"]:
                btns.append(("Start", lambda n=n: _sensor(n, True), True, f"Run {v['label']} now, whatever the tier"))
            if v["stop"]:
                btns.append(("Stop", lambda n=n: _sensor(n, False), True, f"Stop {v['label']} now, whatever the tier"))
            if v["follow"]:
                btns.append(("Follow tier", lambda n=n: _sensor(n, None), True,
                             f"Let the threat-posture tier decide {v['label']} again"))
            row, _w = TL.tile(v["label"], v["word"], TL.LEVEL_COLOR[v["level"]], v["line"], btns,
                              tooltip=v["line"])
            gb.pack_start(row, False, False, 0)
        svc_flow.add(frame)
        frame, gb = TL.group("Services", "")
        for kind, label in (("nebula", "Nebula AI runtime"), ("workbench", "Workbench server")):
            v = service_tile(kind, d)
            start_label = "Open" if kind == "workbench" else "Start"
            btns = []
            if v["start"]:
                btns.append((start_label, lambda k=kind: _service(k, True), True, ""))
            if v["stop"]:
                btns.append(("Stop", lambda k=kind: _service(k, False), True, ""))
            row, _w = TL.tile(label, v["word"], TL.LEVEL_COLOR[v["level"]], v["line"], btns, tooltip=v["line"])
            gb.pack_start(row, False, False, 0)
        svc_flow.add(frame)
        svc_flow.show_all()

        # Guided actions
        _clear(guided_flow)
        ready = sum(1 for g in d["guided"] if g[3]["word"] == "READY")
        frame, gb = TL.group("Guided actions", f"{ready} of {len(d['guided'])} ready")
        for name, tip, handler, v in d["guided"]:
            row, w = TL.tile(name, v["word"], TL.LEVEL_COLOR[v["level"]], v["line"],
                             [("Run", None, v["word"] == "READY", tip)], tooltip=tip)
            w["buttons"][0].connect("clicked", lambda b, h=handler: h(b))
            gb.pack_start(row, False, False, 0)
        guided_flow.add(frame)
        guided_flow.show_all()

        # On this deck
        _clear(deck_flow)
        for title, entries in d["deck"]:
            here = sum(1 for e in entries if e["present"])
            frame, gb = TL.group(title, f"{here} of {len(entries)} ready")
            for e in entries:
                it, act, v = e["item"], e["action"], deck_tile(e)
                nm = str(it.get("name", it.get("id")))
                row, w = TL.tile(nm, v["word"], TL.LEVEL_COLOR[v["level"]], v["line"],
                                 [(act["label"], None, bool(act["argv"]) and e["present"], v["tip"])],
                                 tooltip=v["tip"])
                _wire(w["buttons"][0], act, nm)
                gb.pack_start(row, False, False, 0)
            deck_flow.add(frame)
        deck_flow.show_all()

    poller.append(Poller(box, _POLL_MS, collect_tools, _apply))
    return box


def _wire(b: Gtk.Button, act: dict, n: str) -> None:
    """Connect an On-this-deck button to its launch (unchanged from UX-36)."""
    argv = act["argv"]
    if not argv:
        return
    if act["how"] == "detached":
        b.connect("clicked", lambda _w, a=argv: ux.launch_detached(a, needs=a[0], friendly=n))
        return
    needs = argv[1] if argv[0] == "sudo" and len(argv) > 1 else argv[0]
    if act["example"]:
        needs = act["example"].split()[0]
    b.connect("clicked", lambda _w, a=argv, nd=needs: ux.launch_in_terminal(a, needs=nd, friendly=n, title=n))
