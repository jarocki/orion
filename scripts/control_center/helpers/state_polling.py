"""
Orion-X Control Center — periodic state polling helpers.

GLib.timeout_add is the GTK-native repeating-timer mechanism.  Every section
that polls live data registers a poller here so the poll interval is a single
tunable and the main-loop integration pattern is consistent.

All data reads go through subprocess_runner (no shell=True).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

from typing import Callable

try:
    from gi.repository import GLib  # type: ignore[import]
    _GLIB_AVAILABLE = True
except ImportError:
    _GLIB_AVAILABLE = False

from .subprocess_runner import run_stdout

# Default poll interval used by sections that do not specify one (ms).
DEFAULT_POLL_MS = 5000


def add_poll(
    interval_ms: int,
    callback: Callable[[], bool],
) -> None:
    """Register *callback* to fire every *interval_ms* milliseconds.

    The callback must return True to keep repeating (GLib convention).
    When GLib is unavailable (non-GTK test context), this is a no-op.
    """
    if _GLIB_AVAILABLE:
        GLib.timeout_add(interval_ms, callback)


# ---------------------------------------------------------------------------
# Data-fetch helpers used by multiple sections
# ---------------------------------------------------------------------------


def get_active_connections() -> list[str]:
    """Return list of active NM connection names via nmcli."""
    raw = run_stdout(
        ["nmcli", "-t", "-f", "NAME,STATE", "connection", "show", "--active"],
        timeout=5,
    )
    if not raw:
        return []
    return [line.split(":")[0] for line in raw.splitlines() if line.strip()]


def get_mesh_status() -> dict[str, str]:
    """Return a dict with 'peers', 'status', 'raw' from orionx-mesh status.

    Falls back gracefully when the mesh binary is absent.
    """
    raw = run_stdout(["sudo", "orionx-mesh", "status"], timeout=8)
    return {"raw": raw, "status": "unknown" if not raw else "ok"}


def get_matrix_service_state() -> str:
    """Return systemctl is-active result for matrix-synapse-orionx.service."""
    return run_stdout(
        ["systemctl", "is-active", "matrix-synapse-orionx.service"],
        timeout=5,
    ) or "inactive"
