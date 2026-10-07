"""
Orion Cockpit — Comms tab: the Matrix server, who is on it, every client (DEC-PHASE12-055).

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
from ..helpers.state_polling import add_poll, get_matrix_service_state  # noqa: E402
from ..helpers.subprocess_runner import run_stdout  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "awareness"))
try:
    import deck_vitals as _V  # noqa: E402
except ImportError:  # pragma: no cover
    _V = None

_POLL_MS = 10000
_DIM = "#9aa0a6"


def _primary_ip() -> str | None:
    if _V is None:
        return None
    try:
        ifs = _V.parse_ip_addr(_V._run(["ip", "-j", "addr"]))
        rt = _V.parse_default_route(_V._run(["ip", "-j", "route", "show", "default"]))
        return _V.primary_ipv4(ifs, rt)[0]
    except Exception:  # noqa: BLE001
        return None


def build_section() -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)
    title = Gtk.Label()
    title.set_markup("<b>Comms (Matrix)</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

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
    who = Gtk.Label(label="…")
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
    for label, mode in (("Set up as server", "server"), ("Set up as client", "client")):
        b = Gtk.Button(label=label)
        b.get_style_context().add_class("orionx-tool")
        b.connect("clicked", lambda _w, m=mode: ux.launch_in_terminal(
            ["sudo", "setup-matrix.sh", "--mode", m], needs="setup-matrix.sh",
            friendly=f"Matrix setup ({m})", title=f"Orion-X Matrix — {m}"))
        setup_box.pack_start(b, False, False, 0)

    def _who_refresh(_w=None) -> None:
        if not C.MC_CREDENTIALS.exists() or not shutil.which("matrix-commander"):
            who.set_text("No Matrix login on this deck (matrix-commander --login) — nothing to list.")
            return
        rooms = C.parse_joined_rooms(run_stdout(["matrix-commander", "--joined-rooms"], timeout=12))
        members = C.parse_joined_members(run_stdout(["matrix-commander", "--joined-members", "*"], timeout=15))
        if not rooms:
            who.set_text("Logged in, but this account has joined no rooms.")
            return
        lines = []
        for r in rooms:
            ms = members.get(r, [])
            lines.append(f"{r}  — {len(ms)} member(s)" + (": " + ", ".join(ms[:8]) + ("…" if len(ms) > 8 else "") if ms else ""))
        who.set_text("\n".join(lines))

    refresh_btn.connect("clicked", _who_refresh)

    def _rebuild_clients() -> None:
        for ch in clients_box.get_children():
            clients_box.remove(ch)
        for c in C.client_states(os.path.exists, lambda n: shutil.which(n) is not None):
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
                    argv = C.desktop_exec(C.MC_DESKTOP.read_text(encoding="utf-8") if C.MC_DESKTOP.exists() else "") \
                        or ["matrix-commander", "--help"]
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
                    b.set_tooltip_text("ships on the image")
            row.pack_start(b, False, False, 0)
            clients_box.pack_start(row, False, False, 0)
        clients_box.show_all()

    def _refresh() -> bool:
        st = C.server_state(
            get_matrix_service_state(),
            shutil.which("synapse_homeserver") is not None or os.path.exists("/opt/venvs/matrix-synapse/bin/synapse_homeserver"),
            C.HOMESERVER_YAML.exists(),
            C.ELEMENT_CFG.read_text(encoding="utf-8") if C.ELEMENT_CFG.exists() else None,
            _primary_ip())
        headline.set_text(st["headline"])
        if st["mode"] == "server":
            verb = "clients connect to" if st["running"] else "once it is active, clients will connect to"
            detail.set_text(f"{C.SYNAPSE_UNIT}: {st['unit']}  ·  {verb} {st['url']}")
        elif st["mode"] == "client":
            detail.set_text(f"homeserver {st['url']}  ·  configured in {C.ELEMENT_CFG}")
        else:
            detail.set_text("")
        _rebuild_clients()
        return True

    _refresh()
    _who_refresh()
    add_poll(_POLL_MS, _refresh)
    return box
