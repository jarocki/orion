"""
Orion-X Control Center — Mesh section.

Shows live WireGuard mesh status (via `sudo orionx-mesh status`) and provides
Start / Stop buttons that open xfce4-terminal windows so the operator can
watch the join/leave output interactively.

Polling: every DEFAULT_POLL_MS to keep peer count current.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers.state_polling import DEFAULT_POLL_MS, add_poll, get_mesh_status  # noqa: E402
from ..helpers.subprocess_runner import run  # noqa: E402


def build_section() -> Gtk.Widget:
    """Return the Mesh section widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    title = Gtk.Label()
    title.set_markup("<b>Mesh (WireGuard P2P)</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    status_label = Gtk.Label(label="Checking mesh status…")
    status_label.set_halign(Gtk.Align.START)
    status_label.set_line_wrap(True)
    status_label.set_selectable(True)
    box.pack_start(status_label, False, False, 4)

    raw_label = Gtk.Label(label="")
    raw_label.set_halign(Gtk.Align.START)
    raw_label.set_line_wrap(True)
    raw_label.set_selectable(True)
    box.pack_start(raw_label, True, True, 0)

    def _refresh_mesh() -> bool:
        info = get_mesh_status()
        raw = info.get("raw", "")
        if raw:
            status_label.set_text("Mesh status: running")
            raw_label.set_text(raw[:400])  # cap display length
        else:
            status_label.set_text("Mesh status: not running or orionx-mesh unavailable")
            raw_label.set_text("")
        return True

    _refresh_mesh()
    add_poll(DEFAULT_POLL_MS, _refresh_mesh)

    sep = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
    box.pack_start(sep, False, False, 4)

    btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    box.pack_start(btn_box, False, False, 0)

    start_btn = Gtk.Button(label="Start Mesh")
    start_btn.set_tooltip_text("Run: sudo orionx-mesh join (in terminal)")

    def _start_mesh(_widget: Gtk.Widget) -> None:
        run(
            [
                "xfce4-terminal",
                "--hold",
                "-e",
                "bash -c 'sudo orionx-mesh join; exec bash'",
            ],
            timeout=2,
        )

    start_btn.connect("clicked", _start_mesh)
    btn_box.pack_start(start_btn, False, False, 0)

    stop_btn = Gtk.Button(label="Stop Mesh")
    stop_btn.set_tooltip_text("Run: sudo orionx-mesh leave (in terminal)")

    def _stop_mesh(_widget: Gtk.Widget) -> None:
        run(
            [
                "xfce4-terminal",
                "--hold",
                "-e",
                "bash -c 'sudo orionx-mesh leave; exec bash'",
            ],
            timeout=2,
        )

    stop_btn.connect("clicked", _stop_mesh)
    btn_box.pack_start(stop_btn, False, False, 0)

    return box
