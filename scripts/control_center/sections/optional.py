"""Optional tools on the Cockpit's Tools tab (#199, DEC-PHASE13-060).

Grouped status tiles plus a detail panel with live progress and log. Every
word and colour comes from helpers/optional_view.py; status comes from
`orionx-optional status --json` in a worker thread while the tab is visible
(DEC-PHASE12-068); install/uninstall run `pkexec orionx-optional ACTION ID`
in a worker thread whose output reaches widgets only through GLib.idle_add.
"""
from __future__ import annotations

import subprocess
import threading
from html import escape as _esc

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango  # type: ignore[import]  # noqa: E402

from ..helpers import optional_view as V  # noqa: E402
from ..helpers import style, ux  # noqa: E402
from ..helpers.background import Poller  # noqa: E402

POLL_MS = 15000          # idle refresh while the tab is visible
POLL_BUSY_MS = 2000      # while an action runs (ours or one started elsewhere)
LOG_LINES = 400

#: `orionx-cockpit --tab tools --focus ID` (the Workbench's "Manage in Cockpit", #200)
FOCUS: str | None = None


class OptionalPanel:
    """The widget tree plus its state; `box` is what the Tools tab packs."""

    def __init__(self) -> None:
        self.status: dict = {}
        self.selected: str | None = FOCUS
        self.running: dict | None = None      # {'id','action','name','result'} for the action this Cockpit started
        self._log_for: str | None = None      # whose output the log view holds
        self.tiles: dict[str, dict] = {}
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.pack_start(style.heading("<b>Optional tools</b>"), False, False, 2)

        # Everything in the header can shrink: the tab scrolls vertically only, so a
        # label that cannot ellipsize or wrap would widen the whole Cockpit past
        # the 1366 px reference deck.
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        self.net = Gtk.Label(label="network: checking…", xalign=0)
        self.summary = Gtk.Label(label="", xalign=0)
        for lab in (self.net, self.summary):
            lab.set_ellipsize(Pango.EllipsizeMode.END)
            lab.set_width_chars(20)
        top.pack_start(self.net, True, True, 0)
        top.pack_start(self.summary, True, True, 0)
        self.box.pack_start(top, False, False, 0)
        note = Gtk.Label(xalign=0)
        note.set_line_wrap(True)
        note.set_markup(f'<span foreground="{V.DIM}" size="small">admin password asked once, '
                        'then remembered about 5 minutes (polkit)</span>')
        self.box.pack_start(note, False, False, 0)

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.groups = Gtk.FlowBox()
        self.groups.set_selection_mode(Gtk.SelectionMode.NONE)
        self.groups.set_min_children_per_line(1)
        self.groups.set_max_children_per_line(2)
        self.groups.set_column_spacing(10)
        self.groups.set_row_spacing(10)
        self.groups.set_homogeneous(True)
        self.groups.set_valign(Gtk.Align.START)
        body.pack_start(self.groups, True, True, 0)
        body.pack_start(self._build_detail(), False, False, 0)
        self.box.pack_start(body, False, False, 0)

        self.error = Gtk.Label(xalign=0)
        self.error.set_line_wrap(True)
        self.box.pack_start(self.error, False, False, 0)

        self.poller = Poller(self.box, POLL_MS, lambda _vis: V.collect(), self._apply)
        GLib.timeout_add(POLL_BUSY_MS, self._busy_tick)
        GLib.timeout_add(600, self._pulse_tick)
        self._pulse_on = True

    # ---------------------------------------------------------------- detail
    def _build_detail(self) -> Gtk.Widget:
        frame = Gtk.Frame()
        frame.set_size_request(340, -1)
        v = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        v.set_border_width(10)
        self.d_title = Gtk.Label(xalign=0)
        self.d_state = Gtk.Label(xalign=0)
        self.d_blurb = Gtk.Label(xalign=0)
        self.d_blurb.set_line_wrap(True)
        self.d_blurb.set_max_width_chars(40)
        self.d_bar = Gtk.ProgressBar()
        self.d_bar.set_show_text(True)
        self.d_step = Gtk.Label(xalign=0)
        self.d_step.set_ellipsize(Pango.EllipsizeMode.END)
        self.d_log = Gtk.TextView()
        self.d_log.set_editable(False)
        self.d_log.set_cursor_visible(False)
        self.d_log.set_monospace(True)
        self.d_log.set_wrap_mode(Gtk.WrapMode.CHAR)
        self.d_log.get_style_context().add_class("orionx-log")
        sw = Gtk.ScrolledWindow()
        sw.set_size_request(-1, 220)
        sw.add(self.d_log)
        sw.set_no_show_all(True)       # shown only while there is output to read
        self.d_logwin = sw
        self.d_logpath = Gtk.Label(xalign=0)
        self.d_logpath.set_selectable(True)
        self.d_logpath.set_ellipsize(Pango.EllipsizeMode.START)
        self.d_button = Gtk.Button(label="")
        self.d_button.get_style_context().add_class("orionx-tool")
        self.d_button.connect("clicked", lambda _w: self._on_button(self.selected))
        for w in (self.d_title, self.d_state, self.d_blurb, self.d_bar, self.d_step, sw, self.d_logpath, self.d_button):
            v.pack_start(w, w is sw, w is sw, 0)
        frame.add(v)
        self._detail_frame = frame
        return frame

    def _show_detail(self) -> None:
        t = self._tool(self.selected) if self.selected else None
        if t is None:
            self.d_title.set_markup("<b>Select a tool</b>")
            for w in (self.d_state, self.d_blurb, self.d_step, self.d_logpath):
                w.set_text("")
            self.d_bar.set_visible(False)
            self.d_button.set_visible(False)
            return
        look = V.tile(t)
        self.d_title.set_markup(f"<b>{_esc(t.get('name', t['id']))}</b>")
        self.d_state.set_markup(f'<span foreground="{look["color"]}"><b>{_esc(look["word"])}</b></span>'
                                + (f"  {_esc(t.get('version'))}" if t.get("version") else ""))
        self.d_blurb.set_text((t.get("blurb") or "") + (f"\nSize: {t['size']}" if t.get("size") else ""))
        mine = self.running and self.running["id"] == t["id"]
        prog = t.get("progress") or {}
        if mine or t.get("state") == "working":
            self.d_bar.set_visible(True)
            if not mine and prog.get("m"):
                self.d_bar.set_fraction(min(1.0, (prog.get("n") or 0) / prog["m"]))
                self.d_bar.set_text(f"{prog.get('n')}/{prog.get('m')} {prog.get('step', '')}")
                self.d_step.set_text(prog.get("line") or "")
        else:
            self.d_bar.set_visible(False)
            self.d_step.set_text(look["line"])
        buf = self.d_log.get_buffer()
        has_log = bool(mine) or buf.get_char_count() > 0 and self._log_for == t["id"]
        self.d_logwin.set_visible(has_log)
        if has_log:
            self.d_log.show()
        last = t.get("last") or {}
        logp = (prog.get("log") if t.get("state") == "working" else last.get("log")) or ""
        self.d_logpath.set_text(f"log: {logp}" if logp else "")
        self.d_button.set_visible(bool(look["button"]))
        self.d_button.set_label(look["button"])
        self.d_button.set_sensitive(look["enabled"] and not (self.running and look["action"]))
        self.d_button.set_tooltip_text(look["tip"] or None)

    # ---------------------------------------------------------------- tiles
    def _tool(self, tid: str | None) -> dict | None:
        return next((t for t in self.status.get("tools") or [] if t.get("id") == tid), None)

    def _apply(self, d: dict | None, err) -> None:
        if err is not None or not d or "error" in d:
            self.error.set_markup(f'<span foreground="{V.RED}">optional tools: {_esc(str(err or (d or {}).get("error", "no reply")))}</span>')
            return
        self.error.set_text("")
        self.status = d
        text, color = V.network_line(d)
        self.net.set_markup(f'<span foreground="{color}">● {_esc(text)}</span>')
        self.summary.set_text(V.summary_line(d))
        for ch in self.groups.get_children():
            self.groups.remove(ch)
        self.tiles = {}
        for g, tools in V.grouped(d):
            frame = Gtk.Frame()
            gb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            gb.set_border_width(8)
            head = Gtk.Label(xalign=0)
            ready = sum(1 for t in tools if t.get("state") in ("installed", "active"))
            head.set_markup(f'<span foreground="{V.CYAN}"><b>{_esc(g["name"].upper())}</b></span>'
                            f'  <span foreground="{V.DIM}">{ready} of {len(tools)} ready</span>')
            gb.pack_start(head, False, False, 2)
            for t in tools:
                gb.pack_start(self._tile(t), False, False, 0)
            frame.add(gb)
            self.groups.add(frame)
        self.groups.show_all()
        if self.selected is None and FOCUS:
            self.selected = FOCUS
        self._show_detail()

    def _tile(self, t: dict) -> Gtk.Widget:
        look = V.tile(t)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        led = Gtk.Label()
        led.set_markup(f'<span foreground="{look["color"]}" size="large">●</span>')
        texts = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        name = Gtk.Label(xalign=0)
        name.set_markup(f'<b>{_esc(t.get("name", t["id"]))}</b>  '
                        f'<span foreground="{look["color"]}" size="small"><b>{_esc(look["word"])}</b></span>')
        name.set_ellipsize(Pango.EllipsizeMode.END)
        line = Gtk.Label(xalign=0)
        line.set_markup(f'<span foreground="{V.DIM}" size="small">{_esc(look["line"])}</span>')
        line.set_ellipsize(Pango.EllipsizeMode.END)
        texts.pack_start(name, False, False, 0)
        texts.pack_start(line, False, False, 0)
        btn = Gtk.Button(label=look["button"])
        btn.get_style_context().add_class("orionx-tool")
        btn.set_size_request(104, -1)
        btn.set_sensitive(look["enabled"] and not (self.running and look["action"]))
        if look["tip"]:
            btn.set_tooltip_text(look["tip"])
        btn.connect("clicked", lambda _w, i=t["id"]: self._on_button(i))
        ev = Gtk.EventBox()     # click the tile body to select it
        ev.add(texts)
        ev.connect("button-press-event", lambda *_a, i=t["id"]: self._select(i))
        row.pack_start(led, False, False, 0)
        row.pack_start(ev, True, True, 0)
        row.pack_end(btn, False, False, 0)
        self.tiles[t["id"]] = {"led": led, "button": btn, "look": look, "name": name, "line": line}
        return row

    def _select(self, tid: str) -> bool:
        self.selected = tid
        self._show_detail()
        return True

    def _pulse_tick(self) -> bool:
        self._pulse_on = not self._pulse_on
        for tid, w in self.tiles.items():
            if w["look"]["pulse"]:
                color = w["look"]["color"] if self._pulse_on else V.OFF
                w["led"].set_markup(f'<span foreground="{color}" size="large">●</span>')
        return True

    def _busy_tick(self) -> bool:
        busy = self.running or any(t.get("state") == "working" for t in self.status.get("tools") or [])
        if busy:
            self.poller.kick()
        return True

    # ---------------------------------------------------------------- actions
    def _on_button(self, tid: str | None) -> None:
        t = self._tool(tid)
        if t is None:
            return
        look = V.tile(t)
        self.selected = tid
        if look["action"] is None:          # Details
            self._show_detail()
            return
        if self.running:
            ux.notify(f"wait: {self.running['id']} {self.running['action']} is still running", ux.LEVEL_INFO)
            return
        if look["action"] == "uninstall" and not self._confirm(V.confirm_text(t)):
            return
        self.start(t, look["action"])

    def _confirm(self, text: str) -> bool:
        top = self.box.get_toplevel()
        dlg = Gtk.MessageDialog(transient_for=top if isinstance(top, Gtk.Window) else None, modal=True, message_type=Gtk.MessageType.QUESTION,
                                buttons=Gtk.ButtonsType.OK_CANCEL, text=text)
        resp = dlg.run()
        dlg.destroy()
        return resp == Gtk.ResponseType.OK

    def start(self, t: dict, action: str, argv: list[str] | None = None) -> None:
        """Run the action; argv is injectable for tests (default: pkexec the pinned helper)."""
        argv = argv or V.action_argv(action, t["id"])
        self.running = {"id": t["id"], "action": action, "name": t.get("name", t["id"]), "result": None}
        self._log_for = t["id"]
        self.d_log.get_buffer().set_text("")
        self.d_bar.set_fraction(0.0)
        self.d_bar.set_text(f"{action}: waiting for authentication…")
        self._show_detail()
        self._refresh_buttons()
        ux.notify(f"{t.get('name', t['id'])}: {action} started (authenticate when asked)", ux.LEVEL_INFO)
        threading.Thread(target=self._worker, args=(argv,), daemon=True, name="orionx-optional").start()

    def _worker(self, argv: list[str]) -> None:
        try:
            proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, text=True, errors="replace")
        except OSError as exc:
            GLib.idle_add(self._finished, 127, f"cannot start {argv[0]}: {exc}")
            return
        assert proc.stdout is not None
        for line in proc.stdout:
            GLib.idle_add(self._line, line)
        GLib.idle_add(self._finished, proc.wait(), "")

    def _line(self, line: str) -> bool:
        kind = V.parse_line(line)
        if kind[0] == "progress":
            _k, n, m, label = kind
            self.d_bar.set_fraction(min(1.0, n / m))
            self.d_bar.set_text(f"{n}/{m} {label}")
        elif kind[0] == "result":
            self.running["result"] = kind
        else:
            if kind[1].strip():
                self.d_step.set_text(kind[1][:160])
            buf = self.d_log.get_buffer()
            buf.insert(buf.get_end_iter(), kind[1] + "\n")
            if buf.get_line_count() > LOG_LINES:
                buf.delete(buf.get_start_iter(), buf.get_iter_at_line(buf.get_line_count() - LOG_LINES))
            self.d_log.scroll_to_iter(buf.get_end_iter(), 0.0, False, 0, 0)
        return False

    def _finished(self, rc: int, err: str) -> bool:
        r = self.running or {}
        text, level, ran = V.outcome(r.get("name", "?"), r.get("action", "?"), rc, r.get("result"))
        if err:
            text, level = f"✗ {err}", ux.LEVEL_ERROR
        ux.notify(text, level)
        if not ran and not err:
            # the helper never ran: nothing changed, so no failure event; one info line for the record
            ux.emit_event("info", "cockpit", "tooling", text)
        self.d_bar.set_text(text[:80])
        self.running = None
        self._refresh_buttons()
        self.poller.kick()
        return False

    def _refresh_buttons(self) -> None:
        for w in self.tiles.values():
            w["button"].set_sensitive(w["look"]["enabled"] and not (self.running and w["look"]["action"]))
        self._show_detail()


def build() -> OptionalPanel:
    return OptionalPanel()
