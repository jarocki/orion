#!/usr/bin/env python3
"""
Orion-X XFCE panel widget — mesh status (xfce4-genmon-plugin format).

Outputs a single line to stdout on each invocation:
  "🔗 3p"  — mesh running, 3 peers visible
  "🔗 0p"  — mesh interface up but no peers
  "—"      — mesh not running or orionx-mesh not on PATH

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See control_center/helpers/subprocess_runner.py for full rationale.
"""
from __future__ import annotations

import subprocess
import sys


def _get_peer_count() -> int | None:
    """Return WireGuard peer count from orionx-mesh status, or None if unavailable."""
    try:
        result = subprocess.run(
            ["sudo", "orionx-mesh", "status"],
            capture_output=True,
            text=True,
            timeout=8,
        )
        if result.returncode != 0 or not result.stdout.strip():
            return None
        # Count "peer:" lines in wg show output embedded in status output.
        peer_count = sum(
            1 for line in result.stdout.splitlines() if line.strip().startswith("peer:")
        )
        return peer_count
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None


def main() -> None:
    count = _get_peer_count()
    if count is None:
        print("—")  # em-dash — mesh not running
    else:
        print(f"\U0001f517 {count}p")  # 🔗 Np


if __name__ == "__main__":
    main()
    sys.exit(0)
