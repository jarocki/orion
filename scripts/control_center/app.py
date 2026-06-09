"""
Orion-X Control Center — GTK Application + main window.

Builds a Gtk.Notebook with one tab per section:
  Network, Mesh, Comms, Awareness, IR Tools, Nebula AI, Auto-Healing

The Nebula AI and Auto-Healing sections are PLACEHOLDERS in this slice.
Phase 10 slices (W10-1 through W10-6) will replace the placeholder text
with live runtime controls by importing from their own modules and
swapping the section widget in the notebook.

@decision DEC-PHASE10-005
@title Control Center ships ahead of Phase 10 Nebula AI; placeholder
       sections define the plug-in surfaces for W10-1 through W10-6.
@status accepted
@rationale Phase 9 W9-2 locks the UI surface that Phase 10 slices plug
  into.  The six sections (Network, Mesh, Comms, Awareness, IR, Nebula)
  plus the Auto-Healing tab are the contractually-checked plug-in surfaces.
  Nebula runtime code (ollama, llama.cpp, model staging) is explicitly
  out of scope for W9-2 (see DEC-PHASE10-005) — no AI inference code
  lives in this file.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale All shipped Python in Phase 9 / Phase 10 must use
  `from __future__ import annotations` as the first import.  This
  guarantees forward-compatible annotation evaluation under Python 3.9
  (Debian Bullseye default) and enables ruff PEP-563 enforcement
  (DEC-PHASE9-020).

@decision DEC-PHASE9-020
@title ruff check enforced on all new Python in Phase 9+
@status accepted
@rationale Static lint catches style and correctness issues before CI.
  All new .py files must pass `ruff check` locally before commit.  The
  unit test suite asserts this invariant mechanically.
"""
from __future__ import annotations

import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from .sections import auto_healing, awareness, comms, ir, mesh, nebula, network  # noqa: E402


class OrionXControlCenter(Gtk.Application):
    """GTK Application shell for the Orion-X Control Center."""

    APP_ID = "org.orionx.ControlCenter"

    def __init__(self) -> None:
        super().__init__(application_id=self.APP_ID)
        self.connect("activate", self._on_activate)

    # ------------------------------------------------------------------
    # GTK Application lifecycle
    # ------------------------------------------------------------------

    def _on_activate(self, _app: Gtk.Application) -> None:
        """Build and show the main window."""
        win = Gtk.ApplicationWindow(application=self)
        win.set_title("Orion-X Control Center")
        win.set_default_size(700, 520)
        win.set_icon_name("preferences-desktop")

        notebook = Gtk.Notebook()
        notebook.set_tab_pos(Gtk.PositionType.LEFT)

        # Section definitions — order matches the mission brief.
        # (tab_label, builder_function)
        _sections = [
            ("Network", network.build_section),
            ("Mesh", mesh.build_section),
            ("Comms", comms.build_section),
            ("Awareness", awareness.build_section),
            ("IR Tools", ir.build_section),
            ("Nebula AI", nebula.build_section),
            ("Auto-Healing", auto_healing.build_section),
        ]

        for tab_label, builder in _sections:
            widget = builder()
            scrolled = Gtk.ScrolledWindow()
            scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
            scrolled.add(widget)
            label = Gtk.Label(label=tab_label)
            notebook.append_page(scrolled, label)

        win.add(notebook)
        win.show_all()


def run_app(argv: list[str] | None = None) -> int:
    """Entry point called by the orionx-control-center script.

    Returns the GApplication exit status (0 on clean exit).
    """
    app = OrionXControlCenter()
    return app.run(argv if argv is not None else sys.argv)
