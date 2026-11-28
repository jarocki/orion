"""Shared status tiles for the Orion Tools tab (DEC-PHASE13-074).

@decision DEC-PHASE13-074
@title Every list on Orion Tools is the same tile: status light, name, status
  word, one detail line, and the buttons that change that status
@status accepted
@rationale John (2026-11-27): Guided actions and On this deck should look like
  Optional tools, and every tool should show a status and the switches that
  apply to it (install/uninstall and/or start/stop). The optional-tools tile
  was the one design already proven on the deck (#199), so it moved here and
  every group on the tab is drawn by these three functions; a second copy of
  the tile in another section would drift from the first the next time either
  changed. Words and colours stay with each section's pure view helper
  (optional_view, posture_data.sensor_view, tools_data); this module only draws.
"""
from __future__ import annotations

from html import escape as _esc
from typing import Callable

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Pango  # type: ignore[import]  # noqa: E402

from ..helpers import optional_view as V  # noqa: E402

#: level -> light colour, shared by every section
LEVEL_COLOR = {"ok": V.GREEN, "info": V.CYAN, "warn": V.AMBER, "error": V.RED, "off": V.OFF}

Button = tuple  # (label, callback(), sensitive: bool, tooltip: str)


def flow() -> Gtk.FlowBox:
    """Groups side by side, two per line at the reference deck width."""
    fb = Gtk.FlowBox()
    fb.set_selection_mode(Gtk.SelectionMode.NONE)
    fb.set_min_children_per_line(1)
    fb.set_max_children_per_line(2)
    fb.set_column_spacing(10)
    fb.set_row_spacing(10)
    # Not homogeneous: a 1-tool group no longer reserves the height of a
    # 4-tool one (the empty boxes in the v3.2.0 screenshot).
    fb.set_homogeneous(False)
    fb.set_valign(Gtk.Align.START)
    return fb


def group(title: str, count: str) -> tuple[Gtk.Frame, Gtk.Box]:
    """A titled group frame; pack tiles into the returned box."""
    frame = Gtk.Frame()
    frame.set_valign(Gtk.Align.START)
    gb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
    gb.set_border_width(8)
    head = Gtk.Label(xalign=0)
    head.set_markup(f'<span foreground="{V.CYAN}"><b>{_esc(title.upper())}</b></span>'
                    f'  <span foreground="{V.DIM}">{_esc(count)}</span>')
    gb.pack_start(head, False, False, 2)
    frame.add(gb)
    return frame, gb


def tile(name: str, word: str, color: str, line: str, buttons: list[Button],
         tooltip: str = "", on_select: Callable[[], None] | None = None) -> tuple[Gtk.Box, dict]:
    """One tool row. Returns (row, {'led','name','line','buttons'})."""
    row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    led = Gtk.Label()
    led.set_markup(f'<span foreground="{color}" size="large">●</span>')
    texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
    nl = Gtk.Label(xalign=0)
    nl.set_markup(f'<b>{_esc(name)}</b>  <span foreground="{color}" size="small"><b>{_esc(word)}</b></span>')
    nl.set_ellipsize(Pango.EllipsizeMode.END)
    ll = Gtk.Label(xalign=0)
    ll.set_markup(f'<span foreground="{V.DIM}" size="small">{_esc(line)}</span>')
    ll.set_ellipsize(Pango.EllipsizeMode.END)
    texts.pack_start(nl, False, False, 0)
    texts.pack_start(ll, False, False, 0)
    ev = Gtk.EventBox()
    ev.add(texts)
    if tooltip:
        ev.set_tooltip_text(tooltip)
    if on_select is not None:
        ev.connect("button-press-event", lambda *_a: (on_select(), True)[1])
    row.pack_start(led, False, False, 0)
    row.pack_start(ev, True, True, 0)
    made = []
    for label, cb, sensitive, tip in reversed(buttons):
        b = Gtk.Button(label=label)
        b.get_style_context().add_class("orionx-tool")
        b.set_size_request(104 if len(buttons) == 1 else 84, -1)
        b.set_sensitive(bool(sensitive))
        if tip:
            b.set_tooltip_text(tip)
        if cb is not None:          # None: the caller connects its own handler
            b.connect("clicked", lambda _w, c=cb: c())
        row.pack_end(b, False, False, 0)
        made.insert(0, b)
    return row, {"led": led, "name": nl, "line": ll, "buttons": made}
