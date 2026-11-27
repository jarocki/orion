"""
Orion-X Control Center — package marker.

This package ships under scripts/control_center/ and is staged into the
ISO at /opt/orionx/scripts/control_center/ by stage_application_content()
in scripts/build-iso.sh (no build-script changes required — the existing
rsync of scripts/ handles it automatically).

No entry point of its own since #192: scripts/cockpit/orionx-cockpit imports
control_center.app (SECTIONS, the tab authority) and builds the window.
"""
from __future__ import annotations
