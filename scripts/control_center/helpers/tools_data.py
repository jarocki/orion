"""tools_data — the Orion Tools tab reads the Workbench catalogue (DEC-PHASE12-057).

@decision DEC-PHASE12-057
@title "IR Tools" becomes "Orion Tools": every on-deck and optional tool, determined at runtime
@status accepted
@rationale The tab was six hard-coded buttons while the Workbench already
  held the full catalogue (links.json: `local` with runtime_path, `installable`
  with probes). Two lists of the same tools drift; so this tab READS that
  catalogue and the server's own probe logic, and shows what is actually on
  this deck — with an Install button for what is not.
"""
from __future__ import annotations

import json
import shlex
from pathlib import Path
from typing import Callable

CATALOGUE = Path("/opt/orionx/osint/links.json")
PAGE_IDS = ("cyberchef", "pewpew", "godseye")


def load_catalogue(path: Path = CATALOGUE) -> tuple[list[dict], list[dict]]:
    """(local, installable) from links.json; ([], []) on any failure."""
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
        return list(d.get("local", [])), list(d.get("installable", []))
    except (OSError, ValueError, AttributeError):
        return [], []


def on_deck(local: list[dict], exists: Callable[[str], bool]) -> list[dict]:
    """Local entries whose runtime_path really exists here (truth, not catalogue)."""
    out = []
    for it in local:
        rp = it.get("runtime_path")
        if rp and exists(str(rp)):
            out.append(it)
    return out


def launch_argv(item: dict) -> tuple[str, list[str]]:
    """('terminal'|'detached', argv) for a local catalogue entry."""
    kind = str(item.get("kind", "command"))
    if kind == "page":
        iid = str(item.get("id", ""))
        return "detached", (["orionx-osint", "--page", iid] if iid in PAGE_IDS else ["orionx-osint"])
    cmd = str(item.get("command") or item.get("runtime_path") or "")
    argv = shlex.split(cmd) if cmd else []
    return "terminal", argv


def install_argv(item: dict) -> list[str]:
    return shlex.split(str(item.get("command", "")))
