"""
Orion-X Control Center — Comms section.

Displays matrix-synapse-orionx.service status and provides a button to open
the Element-web chat interface.  The button is present-but-disabled when the
service is inactive, with a tooltip explaining why.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers.state_polling import (  # noqa: E402
    DEFAULT_POLL_MS,
    add_poll,
    get_matrix_service_state,
)
from ..helpers.subprocess_runner import run  # noqa: E402

_MATRIX_CHAT_URL = "https://localhost:8008/"


def build_section() -> Gtk.Widget:
    """Return the Comms section widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    title = Gtk.Label()
    title.set_markup("<b>Comms (Matrix)</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    status_label = Gtk.Label(label="Checking Matrix service…")
    status_label.set_halign(Gtk.Align.START)
    status_label.set_selectable(True)
    box.pack_start(status_label, False, False, 4)

    chat_btn = Gtk.Button(label="Open Matrix Chat")
    chat_btn.set_tooltip_text(f"Open {_MATRIX_CHAT_URL} in the default browser")

    def _open_chat(_widget: Gtk.Widget) -> None:
        run(["xdg-open", _MATRIX_CHAT_URL], timeout=2)

    chat_btn.connect("clicked", _open_chat)
    box.pack_start(chat_btn, False, False, 0)

    def _refresh_comms() -> bool:
        state = get_matrix_service_state()
        is_active = state == "active"
        status_label.set_text(f"matrix-synapse-orionx: {state}")
        chat_btn.set_sensitive(is_active)
        if not is_active:
            chat_btn.set_tooltip_text(
                f"Matrix service is {state} — start it with: "
                "sudo systemctl start matrix-synapse-orionx"
            )
        else:
            chat_btn.set_tooltip_text(f"Open {_MATRIX_CHAT_URL} in the default browser")
        return True

    _refresh_comms()
    add_poll(DEFAULT_POLL_MS, _refresh_comms)

    return box
