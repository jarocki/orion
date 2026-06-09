#!/usr/bin/env python3
"""
Orion-X XFCE panel widget — network status (xfce4-genmon-plugin format).

Outputs a single line to stdout on each invocation.  xfce4-genmon-plugin
calls this script on its own schedule (configure via genmon plugin settings).

Output format: "▲ wlan0" (up with interface name) or "▼ down" (no NM conns).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See control_center/helpers/subprocess_runner.py for full rationale.
"""
from __future__ import annotations

import subprocess
import sys


def _get_active_iface() -> str:
    """Return the first active NM connection name, or empty string."""
    try:
        result = subprocess.run(
            ["nmcli", "-t", "-f", "NAME,STATE", "connection", "show", "--active"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        for line in result.stdout.splitlines():
            parts = line.split(":")
            if len(parts) >= 2 and parts[1].strip():
                return parts[0].strip()
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return ""


def main() -> None:
    iface = _get_active_iface()
    if iface:
        print(f"▲ {iface}")
    else:
        print("▼ down")


if __name__ == "__main__":
    # Allow running from any directory without path manipulation.
    main()
    sys.exit(0)
