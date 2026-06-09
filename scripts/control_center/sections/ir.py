"""
Orion-X Control Center — IR Tools section.

Provides one-click launcher buttons for the six existing Orion-X tools.
Each button opens xfce4-terminal with --hold so the operator can read output
after the tool exits (matching the 0700 hook's .desktop Exec pattern).

@decision DEC-PHASE9-001
@title Terminal emulator: xfce4-terminal replaces lxterminal
@status accepted
@rationale lxterminal is NOT installed in the Orion-X ISO. All interactive
  launcher Exec lines must use xfce4-terminal --hold. This module follows
  the same pattern as the .desktop entries in 0700-orionx-setup.hook.chroot.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

from ..helpers.subprocess_runner import run  # noqa: E402

# (label, command) pairs — command is the tool name already on PATH via /usr/bin/
_IR_TOOLS: list[tuple[str, str]] = [
    ("Artifact Analyzer", "artifact-analyzer.py"),
    ("Storyboard Generator", "storyboard-gen.py"),
    ("PCAP Analyzer", "pcap-analyzer.py"),
    ("Lynis Security Audit", "run-lynis.sh"),
    ("Download Samples", "download-samples.sh"),
    ("Toggle Theme", "toggle-theme.sh"),
]


def build_section() -> Gtk.Widget:
    """Return the IR Tools section widget."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    box.set_border_width(12)

    title = Gtk.Label()
    title.set_markup("<b>IR Tools</b>")
    title.set_halign(Gtk.Align.START)
    box.pack_start(title, False, False, 0)

    desc = Gtk.Label(
        label="Click a tool to open it in a terminal window (xfce4-terminal --hold)."
    )
    desc.set_halign(Gtk.Align.START)
    desc.set_line_wrap(True)
    box.pack_start(desc, False, False, 4)

    grid = Gtk.Grid()
    grid.set_column_spacing(8)
    grid.set_row_spacing(6)
    box.pack_start(grid, False, False, 0)

    for idx, (label, cmd) in enumerate(_IR_TOOLS):
        row = idx // 2
        col = idx % 2
        btn = Gtk.Button(label=label)
        btn.set_tooltip_text(f"Launch: {cmd}")

        # Capture cmd in the closure via default argument.
        def _launch(_widget: Gtk.Widget, _cmd: str = cmd) -> None:
            run(
                [
                    "xfce4-terminal",
                    "--hold",
                    "-e",
                    f"bash -c '{_cmd}; exec bash'",
                ],
                timeout=2,
            )

        btn.connect("clicked", _launch)
        grid.attach(btn, col, row, 1, 1)

    return box
