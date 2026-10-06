"""
Orion-X Control Center — GTK Application + main window.

Tab authority for the Orion Cockpit (DEC-PHASE12-053):
  LIVE (Cockpit), Network, Mesh, Comms, Awareness, Orion Tools, Nebula AI, Auto-Healing

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

@decision DEC-PHASE12-053
@title The Orion Cockpit is the one tabbed window; this module is the tab authority
@status accepted
@rationale Operator decision 2026-10-05/06: the Cockpit is for seeing, hearing
  and changing the immediate environment, and these tabs ARE that. Two windows
  with overlapping concerns was the drift. So: SECTIONS below is the single
  list of tabs; the Cockpit builds its notebook from it (LIVE first, then
  these); the CSS, tab labels and toast bar live here and are imported by the
  Cockpit; and `orionx-control-center` is a launcher that opens the Cockpit on
  a tab. There is no second window class to drift against.
"""
from __future__ import annotations

import os
import shutil
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # type: ignore[import]  # noqa: E402

from .sections import auto_healing, awareness, comms, ir, mesh, nebula, network  # noqa: E402

# Dark-cyberdeck accent — layered OVER the system theme, not a full replacement.
#
# @decision DEC-PHASE12-008
# @title Futuristic "deck" theming pass for the Control Center
# @status accepted
# @rationale Operator (2026-09-14): the desktop lacks "pizzaz" and should feel
#   like a futuristic cockpit. GTK3 CSS gives us gradients, glow (box-/text-
#   shadow), transitions and @keyframes, so the accent layer now carries the
#   Phoenix identity: an ember-glow header, a pulsing tagline, neon-edged tool
#   buttons that light on hover, and an accent-lit active tab. Every property
#   used is GTK 3.22+; anything a theme lacks is ignored with a warning, never a
#   crash. Kept as an overlay so the system theme still supplies base widgets.
_CSS = b"""
/* --- header: ember glow, wordmark tracking, pulsing tagline --- */
headerbar {
    background: linear-gradient(to bottom, #171a21, #0d0f13);
    border-bottom: 1px solid rgba(255,106,19,0.55);
    box-shadow: 0 2px 12px rgba(255,106,19,0.28);
}
headerbar .title { color: #f2f2f2; letter-spacing: 1px; font-weight: bold; }
.orionx-subtitle {
    color: #ff8a2a; font-size: 90%; letter-spacing: 1px;
    animation: orionx-pulse 2.6s ease-in-out infinite alternate;
}
@keyframes orionx-pulse {
    from { text-shadow: 0 0 3px rgba(255,120,30,0.25); color: #e07a24; }
    to   { text-shadow: 0 0 12px rgba(255,140,40,0.95); color: #ffa24a; }
}
/* --- Cockpit launcher: the one loud button on the header --- */
button.orionx-cockpit {
    background: linear-gradient(to right, #ff6a13, #d43f1c);
    color: #0b0b0e; font-weight: bold; letter-spacing: 1px;
    border: none; border-radius: 4px; padding: 4px 14px;
    box-shadow: 0 0 10px rgba(255,106,19,0.55);
    transition: all 160ms ease;
}
button.orionx-cockpit:hover { box-shadow: 0 0 18px rgba(255,120,40,1.0); color: #000; }
/* --- vertical tabs: accent-lit active tab --- */
notebook > header { background: #0f1116; }
notebook > header tab { padding: 8px 10px; color: #9aa0a6; border-left: 3px solid transparent; }
notebook > header tab:checked {
    color: #ffb15c; border-left: 3px solid #ff6a13;
    background: rgba(255,106,19,0.08);
    box-shadow: inset 8px 0 12px -10px rgba(255,106,19,0.9);
}
notebook > header tab:hover { color: #e6e6e6; }
/* --- tool buttons: neon edge that lights on hover --- */
button.orionx-tool {
    padding: 9px 12px;
    border: 1px solid rgba(255,120,30,0.30); border-radius: 4px;
    background: rgba(20,22,28,0.92); color: #e6e6e6;
    transition: all 150ms ease;
}
button.orionx-tool:hover {
    border-color: #ff6a13; color: #ffffff;
    box-shadow: 0 0 10px rgba(255,106,19,0.5), inset 0 0 6px rgba(255,106,19,0.15);
}
/* --- toasts --- */
.orionx-toast { padding: 8px 12px; border-radius: 5px; font-family: monospace; }
.orionx-toast.ok    { background-color: rgba(52,255,158,0.16);  color: #34ff9e; box-shadow: 0 0 8px rgba(52,255,158,0.25); }
.orionx-toast.error { background-color: rgba(255,80,40,0.18);   color: #ff8a5a; box-shadow: 0 0 8px rgba(255,80,40,0.30); }
.orionx-toast.info  { background-color: rgba(150,180,230,0.14); color: #cfe0ff; }
"""


# (key, tab label, icon, builder) — the ONE list of tabs. The Cockpit prepends LIVE.
SECTIONS = [
    ("network", "Network", "network-workgroup-symbolic", network.build_section),
    ("mesh", "Mesh", "network-vpn-symbolic", mesh.build_section),
    ("comms", "Comms", "user-available-symbolic", comms.build_section),
    ("awareness", "Awareness", "security-high-symbolic", awareness.build_section),
    ("tools", "Orion Tools", "applications-utilities-symbolic", ir.build_section),
    ("nebula", "Nebula AI", "system-run-symbolic", nebula.build_section),
    ("healing", "Auto-Healing", "emblem-synchronizing-symbolic", auto_healing.build_section),
]
TAB_KEYS = ["live"] + [k for k, _l, _i, _b in SECTIONS]


def install_css() -> None:
    """Apply the dark-cyberdeck accent at APPLICATION priority (idempotent enough)."""
    screen = Gdk.Screen.get_default()
    if screen is None:
        return
    provider = Gtk.CssProvider()
    provider.load_from_data(_CSS)
    Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


def tab_label(text: str, icon_name: str) -> Gtk.Widget:
    """Icon + text tab label (vertical tabs on the left)."""
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
    box.pack_start(Gtk.Image.new_from_icon_name(icon_name, Gtk.IconSize.MENU), False, False, 0)
    box.pack_start(Gtk.Label(label=text), False, False, 0)
    box.show_all()
    return box


def append_sections(notebook: Gtk.Notebook) -> dict[str, int]:
    """Build every section and append it as a tab. Returns {key: page_index}."""
    pages: dict[str, int] = {}
    for key, label, icon, builder in SECTIONS:
        widget = builder()
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scrolled.add(widget)
        pages[key] = notebook.append_page(scrolled, tab_label(label, icon))
    return pages


class ToastBar(Gtk.Revealer):
    """The single toast sink every section reports through (helpers.ux.set_notifier)."""

    def __init__(self) -> None:
        super().__init__()
        self._label = Gtk.Label(label="")
        self._label.set_halign(Gtk.Align.START)
        self._label.set_line_wrap(True)
        self._label.set_selectable(True)
        self._label.get_style_context().add_class("orionx-toast")
        holder = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        holder.set_border_width(6)
        holder.pack_start(self._label, True, True, 0)
        self.set_transition_type(Gtk.RevealerTransitionType.SLIDE_UP)
        self.add(holder)
        self.set_reveal_child(False)
        self._timer = 0

    def notify(self, message: str, level: str) -> None:
        self._label.set_text(message)
        ctx = self._label.get_style_context()
        for cls in ("ok", "error", "info"):
            ctx.remove_class(cls)
        ctx.add_class(level if level in ("ok", "error", "info") else "info")
        self.set_reveal_child(True)
        if self._timer:
            GLib.source_remove(self._timer)
        self._timer = GLib.timeout_add_seconds(6, self._hide)

    def _hide(self) -> bool:
        self.set_reveal_child(False)
        self._timer = 0
        return False


def run_app(argv: list[str] | None = None) -> int:
    """Entry point for `orionx-control-center`: open the Orion Cockpit on a tab.

    The Control Center window no longer exists (DEC-PHASE12-053). `--tab <key>`
    picks the tab; the default is the first section, so the old habit of
    opening the Control Center still lands on the same content.
    """
    args = list(argv if argv is not None else sys.argv)[1:]
    tab = SECTIONS[0][0]
    for i, a in enumerate(args):
        if a == "--tab" and i + 1 < len(args):
            tab = args[i + 1]
        elif a.startswith("--tab="):
            tab = a.split("=", 1)[1]
    if tab not in TAB_KEYS:
        print(f"orionx-control-center: unknown tab {tab!r}; one of {', '.join(TAB_KEYS)}", file=sys.stderr)
        return 2
    exe = shutil.which("orionx-cockpit") or str(
        __import__("pathlib").Path(__file__).resolve().parents[1] / "cockpit" / "orionx-cockpit")
    if not os.path.exists(exe):
        print("orionx-control-center: orionx-cockpit is not installed; the tabs live there now "
              "(DEC-PHASE12-053). Remedy: check /opt/orionx/scripts/cockpit/orionx-cockpit", file=sys.stderr)
        return 127
    os.execv(exe, [exe, "--tab", tab])
    return 1  # unreachable
