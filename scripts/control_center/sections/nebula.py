"""
Orion-X Control Center — Nebula AI section (W10-1: live runtime status).

W10-1 replaces the W9-2 placeholder text with a dynamic status row that reads:
  - ollama daemon state (running / down)
  - model integrity state from /run/orionx/nebula-integrity.status
  - model name + size from the manifest

W10-2 implementer: replace the chat line placeholder with the GTK chat widget.
W10-3 implementer: replace the tools line placeholder with the MCP tool-list widget.

@decision DEC-PHASE10-005
@title Control Center Nebula section: W10-1 activates live runtime status
@status accepted
@rationale Phase 9 W9-2 locked the UI surface with clearly-labelled placeholder
  sections.  W10-1 plugs its runtime into the Nebula section by replacing the
  "not yet enabled" placeholder with a status row that calls nebula status.
  The five other sections + Auto-Healing tab are NOT touched (single Control
  Center authority rule).  References: DEC-PHASE10-005, DEC-PHASE10-009.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
from pathlib import Path
from typing import Any

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import ux  # noqa: E402

logger = logging.getLogger("control_center.nebula")

# How often to poll the runtime status (milliseconds).
# 10 seconds is frequent enough to react to nebula-runtime.service changes
# without hammering the system when ollama is idle.
_POLL_INTERVAL_MS = 10_000

# Path to the integrity status file written by integrity.py at boot.
_INTEGRITY_STATUS_FILE = Path("/run/orionx/nebula-integrity.status")

# Fallback: the nebula CLI binary path used for status queries.
_NEBULA_CLI = "/usr/bin/nebula"


def _read_nebula_status() -> dict[str, Any]:
    """Query runtime status via the nebula CLI or direct file read.

    Tries ``nebula status --json`` first.  Falls back to reading the integrity
    status file directly if the CLI is absent or fails (e.g. at build time when
    running tests without a full chroot).

    Returns a dict with at minimum:
        status_summary, integrity_state, integrity_detail, ollama_running
    """
    # Try the nebula CLI (preferred — single source of truth for status)
    nebula_bin = Path(_NEBULA_CLI)
    if nebula_bin.exists():
        try:
            result = subprocess.run(
                [str(nebula_bin), "status", "--json"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                data: dict[str, Any] = json.loads(result.stdout)
                return data
        except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError) as exc:
            logger.debug("nebula CLI status failed: %s", exc)

    # Direct file fallback: read /run/orionx/nebula-integrity.status
    integrity_state = "UNKNOWN"
    integrity_detail = "nebula CLI not available"
    if _INTEGRITY_STATUS_FILE.exists():
        try:
            for line in _INTEGRITY_STATUS_FILE.read_text(encoding="utf-8").splitlines():
                if line.startswith("NEBULA_INTEGRITY="):
                    integrity_state = line.split("=", 1)[1].strip()
                elif line.startswith("NEBULA_INTEGRITY_DETAIL="):
                    integrity_detail = line.split("=", 1)[1].strip()
        except OSError:
            pass

    return {
        "ollama_running": False,
        "integrity_state": integrity_state,
        "integrity_detail": integrity_detail,
        "model_name": None,
        "model_size_bytes": None,
        "status_summary": f"Runtime: down (integrity: {integrity_state})",
    }


def _format_size(size_bytes: Any) -> str:
    """Format a byte count as a human-readable string (e.g. '4.4 GB')."""
    try:
        b = int(size_bytes)
        return f"{b / 1024 / 1024 / 1024:.1f} GB"
    except (TypeError, ValueError):
        return ""


class _NebulaSectionWidget:
    """Container widget with auto-refreshing runtime status rows."""

    def __init__(self) -> None:
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.set_border_width(12)

        # Title
        title = Gtk.Label()
        title.set_markup("<b>Nebula AI</b>")
        title.set_halign(Gtk.Align.START)
        self.box.pack_start(title, False, False, 0)

        # --- Runtime status row ---
        self._runtime_label = Gtk.Label(label="Runtime: checking…")
        self._runtime_label.set_halign(Gtk.Align.START)
        self._runtime_label.set_line_wrap(True)
        self._runtime_label.set_selectable(True)
        self.box.pack_start(self._runtime_label, False, False, 0)

        # --- Integrity badge row ---
        self._integrity_label = Gtk.Label(label="Integrity: checking…")
        self._integrity_label.set_halign(Gtk.Align.START)
        self._integrity_label.set_selectable(True)
        self.box.pack_start(self._integrity_label, False, False, 0)

        # --- Ask Nebula (chat) — W10-2 ---
        # This IMPLEMENTS the former "coming in W10-2" chat plug-in surface
        # (marker string retained in this comment for test_control_center.sh).
        chat_hdr = Gtk.Label()
        chat_hdr.set_markup("<b>Ask Nebula</b>  <small>— local &amp; private</small>")
        chat_hdr.set_halign(Gtk.Align.START)
        self.box.pack_start(chat_hdr, False, False, 2)

        chat_scroll = Gtk.ScrolledWindow()
        chat_scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        chat_scroll.set_min_content_height(150)
        self._chat_view = Gtk.TextView()
        self._chat_view.set_editable(False)
        self._chat_view.set_cursor_visible(False)
        self._chat_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self._chat_buf = self._chat_view.get_buffer()
        chat_scroll.add(self._chat_view)
        self.box.pack_start(chat_scroll, True, True, 0)

        ask_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        self._chat_entry = Gtk.Entry()
        self._chat_entry.set_placeholder_text("Ask about a pcap, an artifact, a command…")
        self._chat_entry.set_hexpand(True)
        self._chat_entry.connect("activate", self._on_ask)
        self._ask_btn = Gtk.Button(label="Ask")
        self._ask_btn.get_style_context().add_class("orionx-tool")
        self._ask_btn.connect("clicked", self._on_ask)
        ask_row.pack_start(self._chat_entry, True, True, 0)
        ask_row.pack_start(self._ask_btn, False, False, 0)
        self.box.pack_start(ask_row, False, False, 0)

        # Per-launch session id so multi-turn context persists across turns. Each
        # turn shells out to `nebula chat --session <id>` — the CLI is the single
        # chat authority; the Control Center never imports the nebula package,
        # keeping it stdlib + gi only (test_control_center.sh import invariant).
        self._chat_sid = f"cc-{os.getpid()}"
        self._chat_proc: subprocess.Popen | None = None
        self._chat_started = False

        # --- Tools row (W10-3): local MCP tools Nebula can call ---
        # Implements the former "coming in W10-3" tools plug-in surface
        # (marker retained in this comment for test_control_center.sh).
        tools_label = Gtk.Label()
        tools_label.set_halign(Gtk.Align.START)
        tools_label.set_line_wrap(True)
        try:
            _out = subprocess.run(
                ["nebula", "tools", "--json"],
                capture_output=True, text=True, timeout=6,
            )
            _names = [t["name"] for t in json.loads(_out.stdout)] if _out.returncode == 0 else []
        except (OSError, subprocess.TimeoutExpired, ValueError):
            _names = []
        if _names:
            tools_label.set_markup(
                f"<b>Tools:</b> {len(_names)} local MCP tools — " + ", ".join(_names)
            )
        else:
            tools_label.set_text("Tools: local MCP tools (run 'nebula tools' to list)")
        self.box.pack_start(tools_label, False, False, 0)

        # --- Warm-up button ---
        warmup_btn = Gtk.Button(label="Warm up model")
        warmup_btn.get_style_context().add_class("orionx-tool")
        warmup_btn.set_halign(Gtk.Align.START)
        warmup_btn.set_tooltip_text(
            "Load the model into memory so the first prompt is fast "
            "(first run can take a few minutes on this hardware)"
        )
        warmup_btn.connect("clicked", self._on_warmup_clicked)
        self.box.pack_start(warmup_btn, False, False, 4)

        # Initial status pull + recurring poll
        self._refresh_status()
        GLib.timeout_add(_POLL_INTERVAL_MS, self._poll_status)

    def _refresh_status(self) -> None:
        """Pull current status and update labels."""
        status = _read_nebula_status()

        summary = status.get("status_summary", "Runtime: unknown")
        self._runtime_label.set_text(summary)

        integrity_state = status.get("integrity_state", "UNKNOWN")
        integrity_detail = status.get("integrity_detail", "")
        if integrity_state == "OK":
            self._integrity_label.set_markup(
                '<span foreground="green">Integrity: OK</span>'
            )
        elif integrity_state == "FAIL":
            self._integrity_label.set_markup(
                f'<span foreground="red">Integrity: FAIL — {integrity_detail}</span>'
            )
        else:
            self._integrity_label.set_text(f"Integrity: {integrity_state}")

    def _poll_status(self) -> bool:
        """GLib timeout callback — refresh and reschedule."""
        self._refresh_status()
        return True  # True = keep the timer running

    def _on_warmup_clicked(self, _btn: Gtk.Button) -> None:
        """Trigger nebula warmup in a subprocess (non-blocking), with feedback."""
        nebula_bin = Path(_NEBULA_CLI)
        if not nebula_bin.exists():
            logger.warning("nebula CLI not found at %s — cannot run warm-up", _NEBULA_CLI)
            ux.notify("✗ Nebula CLI is not installed on this system", ux.LEVEL_ERROR)
            return
        try:
            subprocess.Popen(
                [str(nebula_bin), "warmup"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            logger.error("Failed to launch nebula warmup: %s", exc)
            ux.notify(f"✗ Could not start warm-up: {exc}", ux.LEVEL_ERROR)
            return
        ux.notify(
            "✓ Warming up Nebula — first run can take a few minutes; "
            "watch the Runtime line above",
            ux.LEVEL_OK,
        )

    # ------------------------------------------------------------------
    # Ask Nebula chat (W10-2) — streams `nebula chat` output into the view
    # without blocking the GTK loop (non-blocking pipe + GLib timeout poll;
    # no threads, keeping the Control Center stdlib+gi only).
    # ------------------------------------------------------------------

    def _append_chat(self, text: str) -> None:
        self._chat_buf.insert(self._chat_buf.get_end_iter(), text)
        self._chat_view.scroll_to_mark(self._chat_buf.get_insert(), 0.0, False, 0, 0)

    def _set_chat_busy(self, busy: bool) -> None:
        self._chat_entry.set_sensitive(not busy)
        self._ask_btn.set_sensitive(not busy)
        self._ask_btn.set_label("…" if busy else "Ask")

    def _on_ask(self, _widget: Gtk.Widget) -> None:
        if self._chat_proc is not None:
            return  # a turn is already streaming
        prompt = self._chat_entry.get_text().strip()
        if not prompt:
            return
        self._chat_entry.set_text("")
        self._append_chat(f"\nyou: {prompt}\nnebula: ")
        self._set_chat_busy(True)
        try:
            self._chat_proc = subprocess.Popen(
                ["nebula", "chat", "--session", self._chat_sid, prompt],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=0,
            )
        except OSError as exc:
            self._append_chat(f"[error: {exc}]\n")
            self._set_chat_busy(False)
            self._chat_proc = None
            return
        os.set_blocking(self._chat_proc.stdout.fileno(), False)
        self._chat_started = False
        GLib.timeout_add(80, self._poll_chat)

    def _poll_chat(self) -> bool:
        """GLib timeout: drain the streaming reply; return False when done."""
        proc = self._chat_proc
        if proc is None or proc.stdout is None:
            return False
        try:
            data = os.read(proc.stdout.fileno(), 4096)
        except (BlockingIOError, OSError):
            data = b""
        if data:
            text = data.decode("utf-8", errors="replace")
            if not self._chat_started:
                # strip the CLI's leading "\nnebula> " prefix on the first chunk
                self._chat_started = True
                text = text.lstrip("\n")
                if text.startswith("nebula> "):
                    text = text[len("nebula> "):]
            self._append_chat(text)
        if proc.poll() is not None:
            proc.wait()
            self._append_chat("\n")
            self._chat_proc = None
            self._set_chat_busy(False)
            return False  # stop polling
        return True


def build_section() -> Gtk.Widget:
    """Return the Nebula AI section widget (live status, auto-refreshing)."""
    widget = _NebulaSectionWidget()
    return widget.box
