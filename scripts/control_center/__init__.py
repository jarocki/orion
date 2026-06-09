"""
Orion-X Control Center — package marker.

This package ships under scripts/control_center/ and is staged into the
ISO at /opt/orionx/scripts/control_center/ by stage_application_content()
in scripts/build-iso.sh (no build-script changes required — the existing
rsync of scripts/ handles it automatically).

Entry point: scripts/control_center/orionx-control-center (executable script,
no .py extension, #!/usr/bin/env python3 shebang).
"""
from __future__ import annotations
