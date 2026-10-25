"""style — the CSS class names the Cockpit tabs are themed by (DEC-PHASE13-019).

@decision DEC-PHASE13-019
@title Every Cockpit tab wears the LIVE look; classes are named once, here
@status accepted
@rationale #106: LIVE is drawn in Cairo (gradient, 40 px grid, ember-framed
  panel, Hack, glowing ember titles) while the other tabs were stock widgets
  under a small CSS overlay. The Cockpit now paints each tab page with LIVE's
  own primitives (orionx-cockpit _page_backdrop), and app.py's CSS gives the
  widgets inside it the matching font, headings and dividers. Sections used to
  hand-build bold headings at each site, which CSS cannot select;
  heading() is the one way now, so a heading is themed because it is a
  heading, not because someone remembered a class.
"""
from __future__ import annotations

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

PAGE = "orionx-page"                # a tab's page: painted by the Cockpit
PANEL_TITLE = "orionx-panel-title"  # the tab's name at the top of its panel
HEADING = "orionx-heading"          # a group heading inside a tab


def heading(markup: str) -> Gtk.Label:
    """A left-aligned group heading. `markup` is Pango markup, as authored."""
    label = Gtk.Label()
    label.set_markup(markup)
    label.set_halign(Gtk.Align.START)
    label.get_style_context().add_class(HEADING)
    return label
