"""
Orion-X Control Center — Auto-Healing tab (placeholder).

The auto-healing playbook engine, per-class autonomy toggles, and
reversible-action ledger land in W10-6.  This module renders the
discoverable placeholder text that W10-6's implementer will replace
with live tier controls.

W10-6 implementer: replace the status text and add the per-class autonomy
  toggle grid (off / propose / confirm / autonomous).

@decision DEC-PHASE10-005
@title Control Center ships ahead of Phase 10 Nebula AI; placeholder
       sections define the plug-in surfaces for W10-1 through W10-6.
@status accepted
@rationale Phase 9 W9-2 locks the UI surface; Phase 10 slices plug their
  runtime into the clearly-labelled placeholder sections rather than
  inventing new windows.  The exact placeholder text is contractually
  checked by the W9-2 reviewer so W10-6 knows exactly where to land.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

# Placeholder text checked by W9-2 reviewer and referenced by W10-6
# implementer.  The exact string "lands in W10-6" is asserted by
# test_control_center.sh.
PLACEHOLDER_TEXT = (
    "Auto-Healing Playbooks\n\n"
    "Status: not yet enabled (lands in W10-6)\n"
    "Operator pre-approval per action class — Control Center will host\n"
    "the per-class autonomy toggles (off / propose / confirm / autonomous)."
)


def build_section() -> Gtk.Widget:
    """Return the Auto-Healing placeholder tab widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    title = Gtk.Label()
    title.set_markup("<b>Auto-Healing Playbooks</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    placeholder = Gtk.Label(label=PLACEHOLDER_TEXT)
    placeholder.set_halign(Gtk.Align.START)
    placeholder.set_line_wrap(True)
    placeholder.set_selectable(True)
    box.pack_start(placeholder, False, False, 4)

    return box
