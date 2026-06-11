"""
Nebula AI — Orion-X autonomous forensic intelligence control plane.

@decision DEC-PHASE10-008
@title scripts/nebula/ is the SINGLE source tree for Nebula control-plane Python
@status accepted
@rationale All Nebula Python lives here; W10-2..W10-9 slices ADD to this tree.
  No parallel staging path. stage_application_content() in build-iso.sh rsyncs
  scripts/ into the chroot, so this package is automatically staged once the
  directory exists. References: DEC-PHASE10-008, DEC-PHASE9-019 (from __future__).
"""
from __future__ import annotations

__version__ = "0.1.0"
