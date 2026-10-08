"""
Orion Cockpit — Comms tab: the Matrix server, who is on it, every client (DEC-PHASE12-055).

Everything that forks (systemctl, ip, matrix-commander) runs in a worker
thread (DEC-PHASE12-068): `matrix-commander --joined-*` against a slow or
unreachable homeserver used to freeze the whole Cockpit for up to 27 s, at
every launch, whichever tab was open (UX-28).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import comms_data as C  # noqa: E402
from ..helpers import ux  # noqa: E402
from ..helpers.background import Poller, run_async  # noqa: E402
from ..helpers.subprocess_runner import run_stdout  # noqa: E402

_SCRIPTS = Path(__file__).resolve().parents[2]
for _sub in ("awareness", "osint"):
    if str(_SCRIPTS / _sub) not in sys.path:
        sys.path.insert(0, str(_SCRIPTS / _sub))
import deck_vitals as _V  # noqa: E402
try:
    import osint_server as _OS  # noqa: E402  (read_default_route: the one route probe)
    _OS_ERR = ""
except Exception as _exc:  # noqa: BLE001 - reported in the preflight, not hidden
    _OS, _OS_ERR = None, f"{_exc.__class__.__name__}: {_exc}"

_POLL_MS = 10000
_DIM = "#9aa0a6"
_SYNAPSE_BIN = "/opt/venvs/matrix-synapse/bin/synapse_homeserver"


def _primary_ip() -> str | None:
    try:
        ifs = _V.parse_ip_addr(_V._run(["ip", "-j", "addr"]))
        rt = _V.parse_default_route(_V._run(["ip", "-j", "route", "show", "default"]))
        return _V.primary_ipv4(ifs, rt)[0]
    except Exception:  # noqa: BLE001 - "no address" is shown as unknown host
        return None


def _synapse_installed() -> bool:
    return shutil.which("synapse_homeserver") is not None or os.path.exists(_SYNAPSE_BIN)


def _read(path: Path) -> tuple[str | None, str]:
    try:
        return path.read_text(encoding="utf-8"), ""
    except FileNotFoundError:
        return None, ""
    except OSError as exc:
        return None, f"not readable as this user: {exc.strerror or exc}"


def collect_state() -> dict:
    """Worker thread: every probe the tab draws from."""
    hs_text, hs_err = _read(C.HOMESERVER_YAML)
    confd_text, confd_err = _read(C.ORIONX_SYNAPSE_CONF)
    hs_text, src = C.effective_listener_source(confd_text, hs_text, confd_exists=C.ORIONX_SYNAPSE_CONF.exists())
    if hs_text is None and confd_err:
        hs_err = confd_err
    el_text, _ = _read(C.ELEMENT_CFG)
    st = C.server_state(
        run_stdout(["systemctl", "is-active", C.SYNAPSE_UNIT], timeout=5) or "inactive",
        _synapse_installed(), C.HOMESERVER_YAML.exists(), el_text, _primary_ip(),
        homeserver_text=hs_text, homeserver_err=hs_err, source=src)
    mc_desktop, _ = _read(C.MC_DESKTOP)
    clients = C.client_states(os.path.exists, lambda n: shutil.which(n) is not None)
    st["source"] = str(src)
    return {"state": st, "clients": clients, "mc_desktop": mc_desktop or ""}


def route_preflight() -> tuple[bool, str]:
    """May `setup-matrix.sh --mode server` reach apt? (UX-35). Never raises."""
    if _synapse_installed():
        return True, ""
    if _OS is None:
        return True, f"(route check unavailable: {_OS_ERR})"
    r4, r6 = _OS._read(_OS.PROC_ROUTE) or "", _OS._read(_OS.PROC_ROUTE6) or ""
    if _OS.read_default_route(r4, r6).get("default_route"):
        return True, ""
    return False, ("✗ Set up as server needs the network to install Synapse, and this deck has no "
                   "default route. Nothing was changed. Connect (Network tab), then try again.")


def collect_members() -> str:
    """Worker thread: rooms + members via matrix-commander (12 s + 15 s timeouts)."""
    if not C.MC_CREDENTIALS.exists() or not shutil.which("matrix-commander"):
        return "No Matrix login on this deck (matrix-commander --login) — nothing to list."
    rooms = C.parse_joined_rooms(run_stdout(["matrix-commander", "--joined-rooms"], timeout=12))
    if not rooms:
        return "Logged in, but this account has joined no rooms (or the homeserver did not answer within 12 s)."
    members = C.parse_joined_members(run_stdout(["matrix-commander", "--joined-members", "*"], timeout=15))
    lines = []
    for r in rooms:
        ms = members.get(r, [])
        lines.append(f"{r}  — {len(ms)} member(s)" + (": " + ", ".join(ms[:8]) + ("…" if len(ms) > 8 else "") if ms else ""))
    return "\n".join(lines)


def build_section() -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)
    headline = Gtk.Label(label="Checking Matrix…")
    headline.set_halign(Gtk.Align.START)
    headline.set_line_wrap(True)
    headline.set_selectable(True)
    box.pack_start(headline, False, False, 2)
    detail = Gtk.Label(label="")
    detail.set_halign(Gtk.Align.START)
    detail.set_line_wrap(True)
    detail.set_selectable(True)
    box.pack_start(detail, False, False, 0)

    who_hdr = Gtk.Label()
    who_hdr.set_markup("<b>Who is connected</b>")
    who_hdr.set_halign(Gtk.Align.START)
    box.pack_start(who_hdr, False, False, 2)
    who = Gtk.Label(label="Press Refresh to list rooms and members.")
    who.set_halign(Gtk.Align.START)
    who.set_line_wrap(True)
    who.set_selectable(True)
    who.set_xalign(0.0)
    box.pack_start(who, False, False, 0)
    refresh_btn = Gtk.Button(label="Refresh rooms & members")
    refresh_btn.get_style_context().add_class("orionx-tool")
    box.pack_start(refresh_btn, False, False, 2)

    clients_hdr = Gtk.Label()
    clients_hdr.set_markup("<b>Clients</b>")
    clients_hdr.set_halign(Gtk.Align.START)
    box.pack_start(clients_hdr, False, False, 2)
    clients_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
    box.pack_start(clients_box, False, False, 0)

    setup_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 4)
    box.pack_start(setup_box, False, False, 0)

    def _setup(mode: str) -> None:
        if mode == "server":
            ok, why = route_preflight()
            if not ok:
                ux.notify(why, ux.LEVEL_ERROR)
                return
        ux.launch_in_terminal(["sudo", "setup-matrix.sh", "--mode", mode], needs="setup-matrix.sh",
                              friendly=f"Matrix setup ({mode})", title=f"Orion-X Matrix — {mode}")

    for label, mode in (("Set up as server", "server"), ("Set up as client", "client")):
        b = Gtk.Button(label=label)
        b.get_style_context().add_class("orionx-tool")
        b.connect("clicked", lambda _w, m=mode: _setup(m))
        setup_box.pack_start(b, False, False, 0)

    def _who_refresh(_w=None) -> None:
        refresh_btn.set_sensitive(False)
        who.set_text("refreshing… (asks the homeserver; up to 27 s)")

        def _done(text, err) -> None:
            refresh_btn.set_sensitive(True)
            who.set_text(text if err is None else f"Could not list rooms: {err}")
        run_async(collect_members, _done)

    refresh_btn.connect("clicked", _who_refresh)
    # Listed once, in the background, the first time the tab is shown.
    first = {"done": False}

    def _on_map(*_a) -> None:
        if not first["done"]:
            first["done"] = True
            _who_refresh()
    box.connect("map", _on_map)

    def _rebuild_clients(clients: list[dict], mc_desktop: str) -> None:
        for ch in clients_box.get_children():
            clients_box.remove(ch)
        for c in clients:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            lbl = Gtk.Label()
            state = "installed" if c["installed"] else "not installed"
            lbl.set_markup(f"{c['label']}  <span foreground=\"{_DIM}\">{state}</span>")
            lbl.set_halign(Gtk.Align.START)
            row.pack_start(lbl, True, True, 0)
            if c["installed"]:
                b = Gtk.Button(label="Open")
                b.get_style_context().add_class("orionx-tool")
                if c["id"] == "matrix-commander":
                    argv = C.desktop_exec(mc_desktop) or ["matrix-commander", "--help"]
                    b.connect("clicked", lambda _w, a=argv: ux.launch_in_terminal(
                        a, needs=a[0], friendly="Matrix chat (CLI)", title="Orion-X Matrix Comms"))
                elif c["id"] == "gomuks":
                    b.connect("clicked", lambda _w: ux.launch_in_terminal(
                        ["gomuks"], needs="gomuks", friendly="gomuks", title="gomuks"))
                else:
                    b.connect("clicked", lambda _w: ux.launch_detached(["element-desktop"], needs="element-desktop", friendly="Element"))
            else:
                b = Gtk.Button(label="Install")
                b.get_style_context().add_class("orionx-tool")
                inst = c["installer"]
                if inst:
                    b.connect("clicked", lambda _w, i=inst, lab=c["label"]: ux.launch_in_terminal(
                        i.split(), needs=i.split()[1] if i.startswith("sudo ") else i.split()[0],
                        friendly=f"Install {lab}", title=f"Install {lab}"))
                else:
                    b.set_sensitive(False)
                    # UX-46: it should be here; say so and how to find out why.
                    b.set_tooltip_text("expected on the image but not found — run: sudo orionx-diag")
            row.pack_start(b, False, False, 0)
            clients_box.pack_start(row, False, False, 0)
        clients_box.show_all()

    def _apply(d: dict | None, err) -> None:
        if err is not None:
            headline.set_text(f"Matrix state unknown: {err}")
            return
        st = d["state"]
        headline.set_text(st["headline"])
        if st["mode"] == "server":
            if st["url"] and not st["note"]:
                verb = "clients connect to" if st["running"] else "once it is active, clients will connect to"
                detail.set_text(f"{C.SYNAPSE_UNIT}: {st['unit']}  ·  {verb} {st['url']}  (from {st.get('source', C.HOMESERVER_YAML)})")
            else:
                detail.set_text(f"{C.SYNAPSE_UNIT}: {st['unit']}  ·  {st['note']}")
        elif st["mode"] == "client":
            detail.set_text(f"homeserver {st['url']}  ·  configured in {C.ELEMENT_CFG}")
        else:
            detail.set_text("")
        _rebuild_clients(d["clients"], d["mc_desktop"])

    Poller(box, _POLL_MS, lambda _vis: collect_state(), _apply)
    return box
