"""comms_data — pure state for the Comms tab (DEC-PHASE12-055).

@decision DEC-PHASE12-055
@title Comms shows where the Matrix server is, who is on it, and every client — or the install button
@status accepted
@rationale The tab showed a unit name and a button that opened a URL that
  might not exist. An operator needs: is there a homeserver, where (this
  deck or a remote), who is in the rooms this deck is logged into, and which
  clients are actually installed — with a one-click install for the ones
  that are not. Every claim here comes from a file or a command on the deck.
"""
from __future__ import annotations

import json
import re
import shlex
from pathlib import Path
from typing import Callable, Optional

HOMESERVER_YAML = Path("/etc/matrix-synapse/homeserver.yaml")
ELEMENT_CFG = Path("/etc/element-desktop/config.json")
MC_CREDENTIALS = Path.home() / ".config" / "matrix-commander" / "credentials.json"
MC_DESKTOP = Path("/usr/share/applications/orionx-matrix-commander.desktop")
SYNAPSE_UNIT = "matrix-synapse-orionx.service"
CLIENTS = (  # (id, label, probe path or command, installer command)
    ("matrix-commander", "Matrix chat (CLI)", "matrix-commander", None),
    ("element", "Element (desktop)", "/usr/bin/element-desktop", "sudo /opt/orionx/optional/install-element.sh"),
    ("gomuks", "gomuks (terminal)", "/usr/local/bin/gomuks", "sudo /opt/orionx/optional/install-gomuks.sh"),
)


def server_state(unit_active: str, synapse_installed: bool, homeserver_yaml_exists: bool,
                 element_cfg_text: Optional[str], primary_ip: Optional[str]) -> dict:
    """Where Matrix is for this deck, and in what state. Pure."""
    mode = "none"
    url = ""
    if homeserver_yaml_exists or synapse_installed:
        mode = "server"
        url = f"https://{primary_ip or 'localhost'}:8008"
    elif element_cfg_text:
        try:
            cfg = json.loads(element_cfg_text)
            url = (cfg.get("default_server_config", {}).get("m.homeserver", {}).get("base_url")
                   or cfg.get("default_hs_url") or "")
            if url:
                mode = "client"
        except ValueError:
            pass
    state = unit_active.strip() or "inactive"
    if mode == "server":
        headline = f"Homeserver on this deck — {state}"
    elif mode == "client":
        headline = f"Client of a remote homeserver — {url}"
    else:
        headline = "No Matrix configured on this deck (opt-in: sudo setup-matrix.sh --mode server|client)"
    return {"mode": mode, "url": url, "unit": state, "headline": headline,
            "running": mode == "server" and state == "active"}


def parse_joined_rooms(text: str) -> list[str]:
    return [ln.strip() for ln in (text or "").splitlines() if ln.strip().startswith("!")]


def parse_joined_members(text: str) -> dict[str, list[str]]:
    """matrix-commander --joined-members output: room lines then '  @user:server' lines."""
    rooms: dict[str, list[str]] = {}
    cur = None
    for ln in (text or "").splitlines():
        s = ln.strip()
        if s.startswith("!"):
            cur = s.split()[0]
            rooms.setdefault(cur, [])
        elif s.startswith("@") and cur is not None:
            rooms[cur].append(s.split()[0])
    return rooms


def desktop_exec(text: str) -> list[str] | None:
    """The Exec= argv of a .desktop file (field codes stripped), or None."""
    m = re.search(r"^Exec=(.+)$", text or "", re.M)
    if not m:
        return None
    argv = shlex.split(m.group(1))
    return [a for a in argv if not re.fullmatch(r"%[a-zA-Z]", a)] or None


def client_states(exists: Callable[[str], bool], have: Callable[[str], bool]) -> list[dict]:
    out = []
    for cid, label, probe, installer in CLIENTS:
        installed = exists(probe) if probe.startswith("/") else have(probe)
        out.append({"id": cid, "label": label, "installed": installed,
                    "evidence": probe, "installer": installer})
    return out
