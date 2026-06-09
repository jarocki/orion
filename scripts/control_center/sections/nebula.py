"""
Orion-X Control Center — Nebula AI section (placeholder).

The Nebula AI runtime (W10-1), chat interface (W10-2), and MCP tool server
(W10-3) plug into this section.  The placeholder text below is the
contractually-checked surface that those slices will replace.

W10-1 implementer: replace the status line ("Runtime: not yet enabled…")
  with live ollama daemon state once nebula-runtime.service is present.
W10-2 implementer: replace the chat line with the GTK chat widget.
W10-3 implementer: replace the tools line with the MCP tool-list widget.

@decision DEC-PHASE10-005
@title Control Center ships ahead of Phase 10 Nebula AI; placeholder
       sections define the plug-in surfaces for W10-1 through W10-6.
@status accepted
@rationale Phase 9 W9-2 locks the UI surface; Phase 10 slices plug their
  runtime into the clearly-labelled placeholder sections rather than
  inventing new windows.  The exact placeholder text is contractually
  checked by the W9-2 reviewer so W10-1/W10-2/W10-3 know exactly where
  to land.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

# Placeholder text checked by W9-2 reviewer and referenced by W10-1/2/3
# implementers.  The exact strings "lands in W10-1", "coming in W10-2",
# and "coming in W10-3" are asserted by test_control_center.sh.
PLACEHOLDER_TEXT = (
    "Nebula AI\n\n"
    "Runtime: not yet enabled (lands in W10-1)\n"
    "Chat:    coming in W10-2\n"
    "Tools:   coming in W10-3"
)


def build_section() -> Gtk.Widget:
    """Return the Nebula AI placeholder section widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    title = Gtk.Label()
    title.set_markup("<b>Nebula AI</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    placeholder = Gtk.Label(label=PLACEHOLDER_TEXT)
    placeholder.set_halign(Gtk.Align.START)
    placeholder.set_line_wrap(True)
    placeholder.set_selectable(True)
    box.pack_start(placeholder, False, False, 4)

    return box
