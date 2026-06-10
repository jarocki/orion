"""
Nebula helpers sub-package — canonical path constants and thin runtime client.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
@rationale Bullseye ships Python 3.9; PEP-563 deferred evaluation is the single
  annotations model across all shipped Python to avoid runtime annotation errors.
"""
from __future__ import annotations
