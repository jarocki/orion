"""
Orion Cockpit — Mesh tab: nodes, traffic, history (DEC-PHASE12-054).

Data comes from `sudo wg show wg0 dump` (peers, handshakes, counters),
`sudo orionx-mesh status` (identity) and the R.A.I.N. bus (mesh events).
Parsing lives in helpers/mesh_data.py (pure, tested); this file draws.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import time

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import mesh_data as M  # noqa: E402
from ..helpers import ux  # noqa: E402
from ..helpers.spark import Spark  # noqa: E402
from ..helpers.state_polling import add_poll  # noqa: E402
from ..helpers.subprocess_runner import run_stdout  # noqa: E402

_POLL_MS = 3000
_DIM = "#9aa0a6"


def _kv(grid: Gtk.Grid, row: int, key: str) -> Gtk.Label:
    k = Gtk.Label()
    k.set_markup(f'<span foreground="{_DIM}">{key}</span>')
    k.set_halign(Gtk.Align.START)
    v = Gtk.Label(label="…")
    v.set_halign(Gtk.Align.START)
    v.set_selectable(True)
    grid.attach(k, 0, row, 1, 1)
    grid.attach(v, 1, row, 1, 1)
    return v


def build_section() -> Gtk.Widget:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)
    title = Gtk.Label()
    title.set_markup("<b>Mesh (WireGuard P2P)</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    headline = Gtk.Label(label="Checking mesh…")
    headline.set_halign(Gtk.Align.START)
    headline.set_line_wrap(True)
    box.pack_start(headline, False, False, 2)

    grid = Gtk.Grid()
    grid.set_column_spacing(12)
    grid.set_row_spacing(3)
    box.pack_start(grid, False, False, 0)
    vals = {k: _kv(grid, i, k) for i, k in enumerate(("Interface", "VPN IP", "Mode", "Uptime", "Health", "Traffic"))}

    sparks = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    rx_spark = Spark("rx", lambda v: f"{M.fmt_bytes(v)}/s", color=(0.2, 0.85, 0.5))
    tx_spark = Spark("tx", lambda v: f"{M.fmt_bytes(v)}/s", color=(1.0, 0.55, 0.15))
    for s in (rx_spark, tx_spark):
        s.set_hexpand(True)
        sparks.pack_start(s, True, True, 0)
    box.pack_start(sparks, False, False, 4)

    peers_hdr = Gtk.Label()
    peers_hdr.set_markup("<b>Connected nodes</b>")
    peers_hdr.set_halign(Gtk.Align.START)
    box.pack_start(peers_hdr, False, False, 2)
    store = Gtk.ListStore(str, str, str, str, str, str)  # node, state, endpoint, handshake, rx, tx
    tree = Gtk.TreeView(model=store)
    for i, col in enumerate(("Node (VPN IP)", "State", "Endpoint", "Last handshake", "RX", "TX")):
        tree.append_column(Gtk.TreeViewColumn(col, Gtk.CellRendererText(), text=i))
    tree.set_size_request(-1, 120)
    box.pack_start(tree, False, False, 0)

    hist_hdr = Gtk.Label()
    hist_hdr.set_markup("<b>History</b> <span foreground=\"#9aa0a6\">(mesh events on the bus, newest first)</span>")
    hist_hdr.set_halign(Gtk.Align.START)
    box.pack_start(hist_hdr, False, False, 2)
    hist = Gtk.Label(label="…")
    hist.set_halign(Gtk.Align.START)
    hist.set_line_wrap(True)
    hist.set_selectable(True)
    hist.set_xalign(0.0)
    box.pack_start(hist, False, False, 0)

    last = {"rx": None, "tx": None, "t": None}

    def _refresh() -> bool:
        now = time.time()
        st = M.parse_status(run_stdout(["sudo", "orionx-mesh", "status"], timeout=8))
        dump = run_stdout(["sudo", "wg", "show", M.MESH_IFACE, "dump"], timeout=5)
        peers = M.parse_wg_dump(dump, now)
        active = st.get("active") == "active" or bool(dump.strip())
        if not active:
            headline.set_text("Mesh: not joined — press Start Mesh (or: sudo orionx-mesh join)")
        else:
            live = sum(1 for p in peers if M.peer_state(p["handshake_age"]) == "live")
            headline.set_text(f"Mesh: active — {len(peers)} node(s) known, {live} live")
        vals["Interface"].set_text(st.get("interface", M.MESH_IFACE if active else "—"))
        vals["VPN IP"].set_text(st.get("vpn_ip", "—"))
        vals["Mode"].set_text(st.get("mode", "—"))
        vals["Uptime"].set_text(st.get("uptime", "—"))
        vals["Health"].set_text(st.get("health", "—"))
        rx, tx = M.total_traffic(peers)
        vals["Traffic"].set_text(f"rx {M.fmt_bytes(rx)} · tx {M.fmt_bytes(tx)} (all peers)")
        if last["t"] is not None and now > last["t"]:
            dt = now - last["t"]
            rx_spark.push(max(0.0, (rx - last["rx"]) / dt))
            tx_spark.push(max(0.0, (tx - last["tx"]) / dt))
        last.update(rx=rx, tx=tx, t=now)
        store.clear()
        for p in peers:
            store.append([p["node"] or p["short"], M.peer_state(p["handshake_age"]), p["endpoint"] or "—",
                          M.fmt_age(p["handshake_age"]), M.fmt_bytes(p["rx"]), M.fmt_bytes(p["tx"])])
        events = M.read_history()
        if events:
            hist.set_text("\n".join(
                f"{M.fmt_age(max(0.0, now - float(e.get('ts', now)))):>9}  {e.get('source','?')}/{e.get('category','')}  "
                f"{str(e.get('message',''))[:110]}" for e in events))
        else:
            hist.set_text("no mesh events on the bus yet")
        return True

    _refresh()
    add_poll(_POLL_MS, _refresh)

    box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 4)
    btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    box.pack_start(btn_box, False, False, 0)
    start_btn = Gtk.Button(label="Start Mesh")
    start_btn.get_style_context().add_class("orionx-tool")
    start_btn.set_tooltip_text("Join the WireGuard mesh (opens a terminal)")
    start_btn.connect("clicked", lambda _w: ux.launch_in_terminal(
        ["sudo", "orionx-mesh", "join"], needs="orionx-mesh", friendly="Mesh join", title="Orion-X Mesh — join"))
    btn_box.pack_start(start_btn, False, False, 0)
    stop_btn = Gtk.Button(label="Stop Mesh")
    stop_btn.get_style_context().add_class("orionx-tool")
    stop_btn.set_tooltip_text("Leave the WireGuard mesh (opens a terminal)")
    stop_btn.connect("clicked", lambda _w: ux.launch_in_terminal(
        ["sudo", "orionx-mesh", "leave"], needs="orionx-mesh", friendly="Mesh leave", title="Orion-X Mesh — leave"))
    btn_box.pack_start(stop_btn, False, False, 0)
    peers_btn = Gtk.Button(label="Peers (terminal)")
    peers_btn.get_style_context().add_class("orionx-tool")
    peers_btn.connect("clicked", lambda _w: ux.launch_in_terminal(
        ["sudo", "orionx-mesh", "peers"], needs="orionx-mesh", friendly="Mesh peers", title="Orion-X Mesh — peers"))
    btn_box.pack_start(peers_btn, False, False, 0)
    return box
