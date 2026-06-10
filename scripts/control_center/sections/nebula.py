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
import subprocess
import sys
from pathlib import Path
from typing import Any

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # type: ignore[import]  # noqa: E402

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

        # --- Chat placeholder (W10-2 will replace this) ---
        chat_placeholder = Gtk.Label(label="Chat:    coming in W10-2")
        chat_placeholder.set_halign(Gtk.Align.START)
        self.box.pack_start(chat_placeholder, False, False, 0)

        # --- Tools placeholder (W10-3 will replace this) ---
        tools_placeholder = Gtk.Label(label="Tools:   coming in W10-3")
        tools_placeholder.set_halign(Gtk.Align.START)
        self.box.pack_start(tools_placeholder, False, False, 0)

        # --- Warm-up button ---
        warmup_btn = Gtk.Button(label="[ Run warm-up ]")
        warmup_btn.set_halign(Gtk.Align.START)
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
        """Trigger nebula warmup in a subprocess (non-blocking)."""
        nebula_bin = Path(_NEBULA_CLI)
        if not nebula_bin.exists():
            logger.warning("nebula CLI not found at %s — cannot run warm-up", _NEBULA_CLI)
            return
        try:
            subprocess.Popen(
                [str(nebula_bin), "warmup"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError as exc:
            logger.error("Failed to launch nebula warmup: %s", exc)


def build_section() -> Gtk.Widget:
    """Return the Nebula AI section widget (live status, auto-refreshing)."""
    widget = _NebulaSectionWidget()
    return widget.box
