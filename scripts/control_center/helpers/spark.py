"""spark — a small GTK sparkline widget with a pure point mapper.

@decision DEC-PHASE12-056
@title Awareness shows trends, not just instants
@status accepted
@rationale A single "CPU 37%" tells the operator nothing about whether the
  deck is settling or climbing. The Cockpit's LIVE tab already draws rx/tx
  sparklines in Cairo; the GTK tabs get the same idea as a widget. The point
  mapping is a pure function (tested); the widget only draws it.
"""
from __future__ import annotations

from collections import deque
from typing import Callable, Deque, Iterable, Optional

try:
    import gi
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk  # type: ignore[import]
    _GTK = True
except (ImportError, ValueError):  # pragma: no cover - test hosts without GTK
    _GTK = False


def points(values: Iterable[float], w: float, h: float,
           vmax: Optional[float] = None, pad: float = 2.0) -> list[tuple[float, float]]:
    """Map a series onto a w×h box; y grows downward. Flat/empty series sit at the bottom."""
    vals = [max(0.0, float(v)) for v in values]
    if not vals:
        return []
    top = vmax if vmax and vmax > 0 else max(max(vals), 1.0)
    n = len(vals)
    step = (w - 2 * pad) / max(1, n - 1)
    out = []
    for i, v in enumerate(vals):
        x = pad + i * step
        y = pad + (h - 2 * pad) * (1.0 - min(1.0, v / top))
        out.append((x, y))
    return out


if _GTK:
    class Spark(Gtk.DrawingArea):
        """A sparkline with a caption: `label  <latest>`."""

        def __init__(self, label: str, fmt: Callable[[float], str], color=(1.0, 0.42, 0.07),
                     maxlen: int = 90, vmax: Optional[float] = None, height: int = 46) -> None:
            super().__init__()
            self.label, self.fmt, self.color, self.vmax = label, fmt, color, vmax
            self.values: Deque[float] = deque(maxlen=maxlen)
            self.set_size_request(120, height)
            self.connect("draw", self._draw)

        def push(self, value: Optional[float]) -> None:
            if value is None:
                return
            self.values.append(float(value))
            self.queue_draw()

        def _draw(self, _w, cr) -> bool:
            w = self.get_allocated_width()
            h = self.get_allocated_height()
            cr.set_source_rgba(0.06, 0.07, 0.09, 1.0)
            cr.rectangle(0, 0, w, h)
            cr.fill()
            graph_h = h - 16
            pts = points(self.values, w, graph_h, self.vmax)
            if len(pts) >= 2:
                cr.set_source_rgba(*self.color, 0.9)
                cr.set_line_width(1.5)
                cr.move_to(*pts[0])
                for p in pts[1:]:
                    cr.line_to(*p)
                cr.stroke()
            latest = self.fmt(self.values[-1]) if self.values else "—"
            cr.set_source_rgba(0.6, 0.63, 0.66, 1.0)
            cr.select_font_face("Hack")
            cr.set_font_size(10)
            cr.move_to(4, h - 4)
            cr.show_text(f"{self.label}  {latest}")
            return True
