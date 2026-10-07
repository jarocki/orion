"""
Orion-X Control Center — periodic state polling helpers.

Shared probes for the tabs. They block (subprocess with a timeout), so they
are only ever called from a background.Poller worker, never the GTK thread.
All data reads go through subprocess_runner (no shell=True).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.
"""
from __future__ import annotations

from .subprocess_runner import run_stdout

# Default poll interval used by sections that do not specify one (ms).
# Polling itself is helpers/background.Poller (threaded, visible-tab only,
# DEC-PHASE12-068); this module only holds shared probes.
DEFAULT_POLL_MS = 5000


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


# Mesh state: helpers/mesh_data.mesh_summary(load_snapshot()) (DEC-PHASE12-067).
# Matrix unit state: helpers/comms_data.SYNAPSE_UNIT, read by the Comms tab.
