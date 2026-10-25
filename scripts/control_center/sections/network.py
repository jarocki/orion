"""
Orion-X Control Center — Network section.

Interfaces and their rates, traffic by protocol, third-party VPN connections
(NetworkManager WireGuard, DEC-PHASE13-014) and bounded PCAP capture with a
path into Wireshark (DEC-PHASE13-015, DEC-PHASE13-021). What it reads and why
nothing here changes state without a visible terminal: helpers/net_data.py
(DEC-PHASE13-022).

Probes run in a worker thread while the tab is visible (DEC-PHASE12-068).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import net_data as N  # noqa: E402
from ..helpers import style, ux  # noqa: E402
from ..helpers.background import Poller, run_async  # noqa: E402

_POLL_MS = 2000
_DIM = "#9aa0a6"
_GREEN = "#34ff9e"
_AMBER = "#ffb15c"
_RED = "#ff6a50"


def _esc(text: object) -> str:
    return GLib.markup_escape_text(str(text))


def _color(text: object, colour: str) -> str:
    return f'<span foreground="{colour}">{_esc(text)}</span>'


def _rate(bps: float | None) -> str:
    return "—" if bps is None else f"{N.V.fmt_bytes(bps)}/s"


def _pps(v: float | None) -> str:
    return "—" if v is None else f"{v:,.0f}/s"


def _label(markup: str, xalign: float = 0.0, selectable: bool = False) -> Gtk.Label:
    lab = Gtk.Label()
    lab.set_markup(markup)
    lab.set_xalign(xalign)
    lab.set_selectable(selectable)
    lab.set_line_wrap(True)
    return lab


def _share_bar(fraction: float) -> Gtk.LevelBar:
    bar = Gtk.LevelBar()
    bar.set_min_value(0.0)
    bar.set_max_value(1.0)
    bar.set_value(max(0.0, min(1.0, fraction)))
    bar.set_size_request(120, 8)
    bar.set_valign(Gtk.Align.CENTER)
    return bar


def _clear(container: Gtk.Container) -> None:
    for child in container.get_children():
        container.remove(child)


def _tool_button(text: str, tip: str, on_click) -> Gtk.Button:
    btn = Gtk.Button(label=text)
    btn.get_style_context().add_class("orionx-tool")
    btn.set_tooltip_text(tip)
    btn.connect("clicked", lambda _w: on_click())
    return btn


def build_section() -> Gtk.Widget:
    """Return the Network section widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    # --- Interfaces (#107) ---------------------------------------------------
    box.pack_start(style.heading("<b>Interfaces</b>"), False, False, 2)
    route_label = _label(_color("Reading interfaces…", _DIM), selectable=True)
    box.pack_start(route_label, False, False, 0)
    if_grid = Gtk.Grid(column_spacing=14, row_spacing=4)
    box.pack_start(if_grid, False, False, 2)

    box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

    # --- Traffic by protocol (#107) -----------------------------------------
    box.pack_start(style.heading("<b>Traffic by protocol</b>"), False, False, 2)
    box.pack_start(_label(_color("packets/s, every interface; per-interface protocol counts need a capture", _DIM)), False, False, 0)
    proto_grid = Gtk.Grid(column_spacing=14, row_spacing=4)
    box.pack_start(proto_grid, False, False, 2)

    box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

    # --- VPN (#108) ---------------------------------------------------------
    box.pack_start(style.heading("<b>VPN</b>"), False, False, 2)
    box.pack_start(_label(_color("NetworkManager VPN and WireGuard connections; the mesh is on the Mesh tab", _DIM)), False, False, 0)
    vpn_grid = Gtk.Grid(column_spacing=14, row_spacing=4)
    box.pack_start(vpn_grid, False, False, 2)
    vpn_actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    box.pack_start(vpn_actions, False, False, 2)

    box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

    # --- Packet capture (#109) ----------------------------------------------
    box.pack_start(style.heading("<b>Packet capture</b>"), False, False, 2)
    box.pack_start(_label(_color("bounded ring via orionx-capture; start, stop and copy run in a terminal with sudo", _DIM)), False, False, 0)
    cap_note = _label(_color("Reading capture state…", _DIM), selectable=True)
    box.pack_start(cap_note, False, False, 0)
    cap_grid = Gtk.Grid(column_spacing=14, row_spacing=4)
    box.pack_start(cap_grid, False, False, 2)
    shark_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    box.pack_start(shark_row, False, False, 2)

    box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)
    nm_btn = _tool_button("Open Network Manager", "Launch nm-connection-editor to manage connections",
                          lambda: ux.launch_detached(["nm-connection-editor"], friendly="Network Manager"))
    box.pack_start(nm_btn, False, False, 0)

    sampler = N.NetSampler()
    # Grids holding buttons are rebuilt only when what they show changes, so a
    # 2 s refresh never pulls a button out from under the operator's click.
    shown = {"vpn": None, "cap": None, "shark": None}
    poller_ref: dict = {}

    def _kick() -> None:
        if poller_ref.get("p"):
            poller_ref["p"].kick()

    # ---- VPN actions ----
    def _vpn_toggle(conn: dict) -> None:
        verb = "down" if conn["active"] else "up"
        ux.notify(f"{'Disconnecting' if conn['active'] else 'Connecting'} {conn['name']}…", ux.LEVEL_INFO)

        def _done(res, err) -> None:
            rc, out = res if err is None else (1, str(err))
            if rc == 0:
                ux.notify(f"✓ {conn['name']} {'disconnected' if conn['active'] else 'connected'}", ux.LEVEL_OK)
            else:
                ux.notify(f"✗ nmcli connection {verb} {conn['name']} failed: {out.strip()[:200]}", ux.LEVEL_ERROR)
            _kick()
        run_async(lambda: N._run(["nmcli", "connection", verb, "uuid", conn["uuid"]], timeout=45.0), _done)

    def _import_wireguard() -> None:
        dialog = Gtk.FileChooserDialog(title="Import a WireGuard .conf from your VPN provider",
                                       transient_for=box.get_toplevel(), action=Gtk.FileChooserAction.OPEN)
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Import", Gtk.ResponseType.ACCEPT)
        filt = Gtk.FileFilter()
        filt.set_name("WireGuard config (*.conf)")
        filt.add_pattern("*.conf")
        dialog.add_filter(filt)
        path = dialog.get_filename() if dialog.run() == Gtk.ResponseType.ACCEPT else None
        dialog.destroy()
        if not path:
            return
        problem = N.wg_import_problem(path)
        if problem:
            ux.notify(f"✗ Not imported: {problem}", ux.LEVEL_ERROR)
            return
        ux.launch_in_terminal(["sudo", "nmcli", "connection", "import", "type", "wireguard", "file", path],
                              needs="nmcli", friendly="WireGuard import",
                              done_note="it appears under VPN once NetworkManager has it")

    vpn_actions.pack_start(_tool_button(
        "Import WireGuard .conf…",
        "Add a provider's WireGuard config (Mullvad, Proton, IVPN…) as a NetworkManager connection",
        _import_wireguard), False, False, 0)

    # ---- capture actions ----
    def _capture(verb: str, iface: str) -> None:
        notes = {"start": "a bounded ring; Stop here or let it end on its own",
                 "stop": "the files stay in /var/lib/orionx/capture",
                 "export": "then press Open in Wireshark"}
        ux.launch_in_terminal(["sudo", "orionx-capture", verb, iface], needs="orionx-capture",
                              friendly=f"capture {verb} on {iface}", done_note=notes[verb])
        GLib.timeout_add(3000, lambda: (_kick(), False)[1])

    def _open_wireshark(path: str) -> None:
        ux.launch_detached(["wireshark", "-r", path], friendly="Wireshark")

    # ---- drawing ----
    def _draw_interfaces(d: dict) -> None:
        route = d["route"]
        gw = (f"default route via {route['gateway']} on {route.get('dev') or '?'}"
              if route.get("gateway") else "no default route")
        dns = ", ".join(d["dns"]) if d["dns"] else "none in /etc/resolv.conf"
        route_label.set_markup(f"{_color(gw, _GREEN if route.get('gateway') else _AMBER)}"
                               f"   {_color('DNS', _DIM)} {_esc(dns)}")
        _clear(if_grid)
        for col, head in enumerate(("interface", "state", "addresses", "down", "up", "share", "since boot")):
            if_grid.attach(_label(_color(head, _DIM)), col, 0, 1, 1)
        for row, it in enumerate(d["interfaces"], start=1):
            up = it["state"] == "up"
            colour = _GREEN if up else (_DIM if it["state"] in ("down", "unknown") else _AMBER)
            name = it["iface"] + (" (mesh)" if it["mesh"] else "")
            if_grid.attach(_label(_esc(name)), 0, row, 1, 1)
            if_grid.attach(_label(_color(it["state"].upper(), colour)), 1, row, 1, 1)
            if_grid.attach(_label(_esc(", ".join(it["addrs"]) or "—"), selectable=True), 2, row, 1, 1)
            if_grid.attach(_label(_esc(_rate(it["rx_s"]))), 3, row, 1, 1)
            if_grid.attach(_label(_esc(_rate(it["tx_s"]))), 4, row, 1, 1)
            if_grid.attach(_share_bar(it["share"]), 5, row, 1, 1)
            totals = f"↓ {N.V.fmt_bytes(it['rx_total'])}  ↑ {N.V.fmt_bytes(it['tx_total'])}"
            if_grid.attach(_label(_color(totals, _DIM)), 6, row, 1, 1)
        if not d["interfaces"]:
            if_grid.attach(_label(_color("no interfaces reported by `ip -j addr`", _RED)), 0, 1, 7, 1)
        if_grid.show_all()

    def _draw_protocols(d: dict) -> None:
        _clear(proto_grid)
        if not d["snmp_readable"]:
            proto_grid.attach(_label(_color("/proc/net/snmp is not readable here", _RED)), 0, 0, 5, 1)
        elif not d["protocols"]:
            proto_grid.attach(_label(_color("measuring… (rates need two samples)", _DIM)), 0, 0, 5, 1)
        else:
            for col, head in enumerate(("protocol", "in", "out", "share")):
                proto_grid.attach(_label(_color(head, _DIM)), col, 0, 1, 1)
            for row, p in enumerate(d["protocols"], start=1):
                proto_grid.attach(_label(f"<b>{_esc(p['proto'])}</b>"), 0, row, 1, 1)
                proto_grid.attach(_label(_esc(_pps(p["in_s"]))), 1, row, 1, 1)
                proto_grid.attach(_label(_esc(_pps(p["out_s"]))), 2, row, 1, 1)
                proto_grid.attach(_share_bar(p["share"]), 3, row, 1, 1)
                proto_grid.attach(_label(_color(f"{100 * p['share']:.0f}%", _DIM)), 4, row, 1, 1)
            est = d.get("tcp_established")
            if est is not None:
                proto_grid.attach(_label(_color(f"TCP connections established now: {est}", _DIM)),
                                  0, len(d["protocols"]) + 1, 5, 1)
        proto_grid.show_all()

    def _draw_vpns(d: dict) -> None:
        sig = (d["vpn_error"], tuple((c["uuid"], c["active"], c["device"]) for c in d["vpns"]))
        if sig == shown["vpn"]:
            return
        shown["vpn"] = sig
        _clear(vpn_grid)
        if d["vpn_error"]:
            vpn_grid.attach(_label(_color(d["vpn_error"], _RED), selectable=True), 0, 0, 4, 1)
        elif not d["vpns"]:
            vpn_grid.attach(_label(_color(
                "No VPN connections. Import your provider's WireGuard .conf to add one.", _DIM)), 0, 0, 4, 1)
        for row, c in enumerate(d["vpns"]):
            state = f"CONNECTED on {c['device']}" if c["active"] else "not connected"
            vpn_grid.attach(_label(f"<b>{_esc(c['name'])}</b>"), 0, row, 1, 1)
            vpn_grid.attach(_label(_color(c["type"], _DIM)), 1, row, 1, 1)
            vpn_grid.attach(_label(_color(state, _GREEN if c["active"] else _DIM)), 2, row, 1, 1)
            vpn_grid.attach(_tool_button("Disconnect" if c["active"] else "Connect",
                                         f"nmcli connection {'down' if c['active'] else 'up'} {c['name']}",
                                         lambda c=c: _vpn_toggle(c)), 3, row, 1, 1)
        vpn_grid.show_all()

    def _draw_capture(d: dict) -> None:
        cap = d["capture"]
        running = {c["iface"]: c for c in cap["captures"]}
        if cap["known"]:
            cap_note.set_markup(_color(
                f"{len(running)} capture(s) running" if running else "No capture running.",
                _GREEN if running else _DIM))
        else:
            cap_note.set_markup(_color(f"capture state unknown: {cap['reason']}", _AMBER))
        candidates = [it["iface"] for it in d["interfaces"]]
        sig = (cap["known"], tuple(candidates),
               tuple(sorted((k, int(v.get("elapsed_s") or 0) // 10) for k, v in running.items())))
        if sig != shown["cap"]:
            shown["cap"] = sig
            _clear(cap_grid)
            for row, iface in enumerate(candidates):
                c = running.get(iface)
                if c:
                    elapsed = c.get("elapsed_s") or 0
                    detail = (f"RUNNING {elapsed:.0f}s of {c.get('duration')}s, "
                              f"cap {c.get('budget_mb')} MB → {c.get('out_path')}")
                    colour = _GREEN
                else:
                    detail, colour = "idle", _DIM
                cap_grid.attach(_label(f"<b>{_esc(iface)}</b>"), 0, row, 1, 1)
                cap_grid.attach(_label(_color(detail, colour), selectable=True), 1, row, 1, 1)
                cap_grid.attach(_tool_button("Stop" if c else "Start",
                                             f"sudo orionx-capture {'stop' if c else 'start'} {iface}",
                                             lambda i=iface, v=("stop" if c else "start"): _capture(v, i)),
                                2, row, 1, 1)
                cap_grid.attach(_tool_button("Copy to ~/Captures",
                                             f"sudo orionx-capture export {iface}: a 0600 copy you can open",
                                             lambda i=iface: _capture("export", i)), 3, row, 1, 1)
            cap_grid.show_all()
        export = d["export"]
        if str(export) != shown["shark"]:
            shown["shark"] = str(export)
            _clear(shark_row)
            if export is None:
                shark_row.pack_start(_label(_color(
                    "No capture copy in ~/Captures yet — Copy one first, then open it.", _DIM)),
                    False, False, 0)
            else:
                shark_row.pack_start(_tool_button(
                    "Open in Wireshark", f"wireshark -r {export}", lambda p=str(export): _open_wireshark(p)),
                    False, False, 0)
                shark_row.pack_start(_label(_color(f"newest copy: {export.name}", _DIM)), False, False, 0)
            shark_row.show_all()

    def _apply(d, err) -> None:
        if err is not None:
            route_label.set_markup(_color(f"Network probes failed: {err}", _RED))
            return
        _draw_interfaces(d)
        _draw_protocols(d)
        _draw_vpns(d)
        _draw_capture(d)

    poller_ref["p"] = Poller(box, _POLL_MS, lambda _vis: sampler.collect(), _apply)
    return box
