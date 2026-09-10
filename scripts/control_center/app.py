"""
Orion-X Control Center — GTK Application + main window.

Builds a Gtk.Notebook with one tab per section:
  Network, Mesh, Comms, Awareness, IR Tools, Nebula AI, Auto-Healing

The window carries three "works like magic" affordances added in W11-15:
  - a HeaderBar with the operator-facing tagline ("Designed for your 3am self"),
  - a bottom toast bar that reports the result of every action in plain
    language (wired to helpers.ux.notify via set_notifier), and
  - a light dark-cyberdeck CSS accent (phoenix orange / scanner green) applied
    at APPLICATION priority so it layers over — not fights — the system theme.

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

@decision DEC-PHASE11-030
@title Control Center UX polish: header, toast feedback, dark accent
@status accepted
@rationale Operator directive 2026-09-09 ("work LIKE MAGIC ... designed for my
  3am self").  app.py owns the window chrome and registers the single toast
  sink (helpers.ux.set_notifier) that every section reports through; sections
  never touch the window directly.  CSS is applied at
  STYLE_PROVIDER_PRIORITY_APPLICATION so it accents rather than replaces the
  Orion-X-Cyberdeck GTK theme.

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
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # type: ignore[import]  # noqa: E402

from .helpers import ux  # noqa: E402
from .sections import auto_healing, awareness, comms, ir, mesh, nebula, network  # noqa: E402

# Dark-cyberdeck accent — layered OVER the system theme, not a full replacement.
_CSS = b"""
.orionx-subtitle { color: #d98a3a; font-size: 90%; }
.orionx-toast {
    padding: 8px 12px;
    border-radius: 5px;
    font-family: monospace;
}
.orionx-toast.ok    { background-color: rgba(52,255,158,0.16);  color: #34ff9e; }
.orionx-toast.error { background-color: rgba(255,80,40,0.18);   color: #ff8a5a; }
.orionx-toast.info  { background-color: rgba(150,180,230,0.14); color: #cfe0ff; }
button.orionx-tool { padding: 9px 12px; }
"""


class OrionXControlCenter(Gtk.Application):
    """GTK Application shell for the Orion-X Control Center."""

    APP_ID = "org.orionx.ControlCenter"

    def __init__(self) -> None:
        super().__init__(application_id=self.APP_ID)
        self.connect("activate", self._on_activate)
        self._toast: Gtk.Label | None = None
        self._toast_revealer: Gtk.Revealer | None = None
        self._toast_timer: int = 0

    # ------------------------------------------------------------------
    # GTK Application lifecycle
    # ------------------------------------------------------------------

    def _on_activate(self, _app: Gtk.Application) -> None:
        """Build and show the main window."""
        self._install_css()

        win = Gtk.ApplicationWindow(application=self)
        win.set_default_size(820, 600)
        win.set_icon_name("preferences-desktop")

        # --- HeaderBar: name + operator-facing tagline ---
        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.set_title("Orion-X Control Center")
        header.set_subtitle("Designed for your 3am self")
        subtitle = header.get_custom_title()
        if subtitle is not None:
            subtitle.get_style_context().add_class("orionx-subtitle")
        win.set_titlebar(header)

        # --- Root layout: notebook (expand) + toast bar (bottom) ---
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)

        notebook = Gtk.Notebook()
        notebook.set_tab_pos(Gtk.PositionType.LEFT)

        # (tab_label, icon_name, builder_function) — order matches the brief.
        _sections = [
            ("Network", "network-workgroup-symbolic", network.build_section),
            ("Mesh", "network-vpn-symbolic", mesh.build_section),
            ("Comms", "user-available-symbolic", comms.build_section),
            ("Awareness", "security-high-symbolic", awareness.build_section),
            ("IR Tools", "applications-utilities-symbolic", ir.build_section),
            ("Nebula AI", "system-run-symbolic", nebula.build_section),
            ("Auto-Healing", "emblem-synchronizing-symbolic", auto_healing.build_section),
        ]

        for tab_label, icon_name, builder in _sections:
            widget = builder()
            scrolled = Gtk.ScrolledWindow()
            scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
            scrolled.add(widget)
            notebook.append_page(scrolled, self._tab_label(tab_label, icon_name))

        root.pack_start(notebook, True, True, 0)

        # --- Toast bar (collapsed until the first action) ---
        self._toast = Gtk.Label(label="")
        self._toast.set_halign(Gtk.Align.START)
        self._toast.set_line_wrap(True)
        self._toast.set_selectable(True)
        self._toast.get_style_context().add_class("orionx-toast")
        toast_holder = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        toast_holder.set_border_width(6)
        toast_holder.pack_start(self._toast, True, True, 0)
        self._toast_revealer = Gtk.Revealer()
        self._toast_revealer.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
        self._toast_revealer.add(toast_holder)
        self._toast_revealer.set_reveal_child(False)
        root.pack_start(self._toast_revealer, False, False, 0)

        win.add(root)

        # Register the single toast sink used by every section.
        ux.set_notifier(self._notify)

        win.show_all()

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _install_css(self) -> None:
        """Apply the dark-cyberdeck accent at APPLICATION priority."""
        screen = Gdk.Screen.get_default()
        if screen is None:
            return
        provider = Gtk.CssProvider()
        provider.load_from_data(_CSS)
        Gtk.StyleContext.add_provider_for_screen(
            screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

    @staticmethod
    def _tab_label(text: str, icon_name: str) -> Gtk.Widget:
        """Build an icon + text tab label (vertical tabs on the left)."""
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        box.pack_start(Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.MENU), False, False, 0)
        box.pack_start(Gtk.Label(label=text), False, False, 0)
        box.show_all()
        return box

    def _notify(self, message: str, level: str) -> None:
        """Toast sink: show *message* styled by *level*, auto-hide after 6 s."""
        if self._toast is None or self._toast_revealer is None:
            return
        self._toast.set_text(message)
        ctx = self._toast.get_style_context()
        for cls in ("ok", "error", "info"):
            ctx.remove_class(cls)
        ctx.add_class(level if level in ("ok", "error", "info") else "info")
        self._toast_revealer.set_reveal_child(True)
        if self._toast_timer:
            GLib.source_remove(self._toast_timer)
        self._toast_timer = GLib.timeout_add_seconds(6, self._hide_toast)

    def _hide_toast(self) -> bool:
        """GLib timeout callback: collapse the toast bar."""
        if self._toast_revealer is not None:
            self._toast_revealer.set_reveal_child(False)
        self._toast_timer = 0
        return False  # one-shot


def run_app(argv: list[str] | None = None) -> int:
    """Entry point called by the orionx-control-center script.

    Returns the GApplication exit status (0 on clean exit).
    """
    app = OrionXControlCenter()
    return app.run(argv if argv is not None else sys.argv)
