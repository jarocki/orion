"""
Orion-X Control Center — Network section.

Displays active NetworkManager connections and provides a button to launch
nm-connection-editor (the GUI NM editor that ships with network-manager-gnome).

Live data is polled every DEFAULT_POLL_MS via GLib.timeout_add so the list
stays current without blocking the GTK main loop.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers.state_polling import DEFAULT_POLL_MS, add_poll, get_active_connections  # noqa: E402
from ..helpers.subprocess_runner import run  # noqa: E402


def build_section() -> Gtk.Widget:
    """Return the Network section widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    title = Gtk.Label()
    title.set_markup("<b>Network</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    status_label = Gtk.Label(label="Scanning connections…")
    status_label.set_halign(Gtk.Align.START)
    status_label.set_selectable(True)
    box.pack_start(status_label, False, False, 4)

    connections_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    box.pack_start(connections_box, True, True, 0)

    def _refresh_connections() -> bool:
        """Poll active NM connections; update the UI.  Returns True to repeat."""
        conns = get_active_connections()
        for child in connections_box.get_children():
            connections_box.remove(child)
        if conns:
            status_label.set_text(f"{len(conns)} active connection(s):")
            for name in conns:
                row = Gtk.Label(label=f"  • {name}")
                row.set_halign(Gtk.Align.START)
                connections_box.pack_start(row, False, False, 0)
        else:
            status_label.set_text("No active connections")
        connections_box.show_all()
        return True  # keep polling

    _refresh_connections()
    add_poll(DEFAULT_POLL_MS, _refresh_connections)

    sep = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
    box.pack_start(sep, False, False, 4)

    btn = Gtk.Button(label="Open Network Manager")
    btn.set_tooltip_text("Launch nm-connection-editor to manage connections")

    def _open_nm(_widget: Gtk.Widget) -> None:
        run(["nm-connection-editor"], timeout=2)

    btn.connect("clicked", _open_nm)
    box.pack_start(btn, False, False, 0)

    return box
