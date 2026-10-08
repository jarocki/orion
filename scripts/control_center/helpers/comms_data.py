"""comms_data — pure state for the Comms tab (DEC-PHASE12-055).

@decision DEC-PHASE12-071
@title The Comms tab derives the client URL from Synapse's own listener
@status accepted
@rationale ux.md UX-02. See server_state(). An unreadable config says
  "URL unknown — read …" instead of printing a guess.

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
# setup-matrix.sh writes the deck's ONE listener here. The package unit loads
# homeserver.yaml then conf.d/, and a later file's top-level key replaces the
# earlier one, so when this file has `listeners:` it is what Synapse binds.
ORIONX_SYNAPSE_CONF = Path("/etc/matrix-synapse/conf.d/orionx.yaml")
ELEMENT_CFG = Path("/etc/element-desktop/config.json")
MC_CREDENTIALS = Path.home() / ".config" / "matrix-commander" / "credentials.json"
MC_DESKTOP = Path("/usr/share/applications/orionx-matrix-commander.desktop")
# The package unit (lead decision, QA round 1: system.md P1-2 option b). The
# orionx-specific unit was never installed; one constant, read by this tab only.
SYNAPSE_UNIT = "matrix-synapse.service"
CLIENTS = (  # (id, label, probe path or command, installer command)
    ("matrix-commander", "Matrix chat (CLI)", "matrix-commander", None),
    ("element", "Element (desktop)", "/usr/bin/element-desktop", "sudo /opt/orionx/optional/install-element.sh"),
    ("gomuks", "gomuks (terminal)", "/usr/local/bin/gomuks", "sudo /opt/orionx/optional/install-gomuks.sh"),
)
_LOOPBACK = ("127.", "::1", "localhost")


def _scalar(v: str):
    v = v.split(" #", 1)[0].strip()
    if v.startswith("[") and v.endswith("]"):
        return [_scalar(x) for x in v[1:-1].split(",") if x.strip()]
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        return v[1:-1]
    if v.lower() in ("true", "yes"):
        return True
    if v.lower() in ("false", "no"):
        return False
    try:
        return int(v)
    except ValueError:
        return v


def parse_listeners(yaml_text: str) -> list[dict]:
    """The `listeners:` block of a Synapse homeserver.yaml. Pure, stdlib-only.

    Handles the shapes Synapse's generated config writes: a list of mappings
    with scalar keys (port, tls, type, bind_addresses as an inline or block
    list) and a nested `resources: - names: [...]` (inline or block). Anything
    else is ignored rather than guessed at.
    """
    lines = (yaml_text or "").splitlines()
    out: list[dict] = []
    i = 0
    while i < len(lines) and not lines[i].rstrip().startswith("listeners:"):
        i += 1
    i += 1
    cur: dict | None = None
    item_indent = None
    pending_list: str | None = None
    for raw in lines[i:]:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent == 0:
            break
        body = raw.strip()
        if body.startswith("- ") and (item_indent is None or indent <= item_indent):
            item_indent = indent
            cur = {"names": []}
            out.append(cur)
            body = body[2:].strip()
            pending_list = None
        if cur is None:
            continue
        if body.startswith("- ") and pending_list and ":" not in body:
            val = _scalar(body[2:])
            (cur["names"] if pending_list == "names" else cur.setdefault(pending_list, [])).append(val)
            continue
        if body.startswith("- "):
            body = body[2:].strip()           # e.g. resources: - names: [...]
        if ":" not in body:
            continue
        k, v = body.split(":", 1)
        k = k.strip()
        if k == "names":
            if v.strip() == "":
                pending_list = "names"
                continue
            val = _scalar(v)
            cur["names"].extend(val if isinstance(val, list) else [val])
            continue
        if indent > (item_indent or 0) + 2:
            continue                          # nested keys we do not need
        if v.strip() == "":
            pending_list = k
            cur.setdefault(k, [])
            continue
        pending_list = None
        cur[k] = _scalar(v)
    return out


def effective_listener_source(confd_text: Optional[str], hs_text: Optional[str],
                              confd_exists: bool = False) -> tuple[Optional[str], Path]:
    """(text, path) of the file whose `listeners:` Synapse actually uses. Pure.

    Mirrors Synapse's merge: conf.d/orionx.yaml is loaded after homeserver.yaml
    and its top-level `listeners` replaces the main file's (B1, QA round 1).
    If that file exists but this user cannot read it, the answer is "unknown"
    (text None, path conf.d) — never the package default, which is the wrong
    listener (QA round 2, P2-1).
    """
    if confd_text is not None and parse_listeners(confd_text):
        return confd_text, ORIONX_SYNAPSE_CONF
    if confd_text is None and confd_exists:
        return None, ORIONX_SYNAPSE_CONF
    return hs_text, HOMESERVER_YAML


def client_endpoint(listeners: list[dict], primary_ip: Optional[str]) -> dict:
    """Where a teammate's client must connect, from the listener itself. Pure.

    {'url', 'loopback_only', 'listener'} or {'url': '', 'why': ...}.
    """
    http = [x for x in listeners if str(x.get("type", "http")) == "http" and isinstance(x.get("port"), int)]
    pick = next((x for x in http if "client" in x.get("names", [])), http[0] if http else None)
    if pick is None:
        return {"url": "", "why": "homeserver.yaml has no http client listener"}
    scheme = "https" if pick.get("tls") is True else "http"
    binds = pick.get("bind_addresses")
    binds = [str(b) for b in (binds if isinstance(binds, list) else [binds] if binds else [])]
    loop = bool(binds) and all(b.startswith(_LOOPBACK) for b in binds)
    wildcard = not binds or any(b in ("0.0.0.0", "::", "*") for b in binds)
    if loop:
        host = binds[-1]
    elif wildcard:
        host = primary_ip or "this-deck"
    else:
        host = next(b for b in binds if not b.startswith(_LOOPBACK))
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"
    return {"url": f"{scheme}://{host}:{pick['port']}", "loopback_only": loop, "listener": pick}


def server_state(unit_active: str, synapse_installed: bool, homeserver_yaml_exists: bool,
                 element_cfg_text: Optional[str], primary_ip: Optional[str],
                 homeserver_text: Optional[str] = None, homeserver_err: str = "",
                 source: Optional[Path] = None) -> dict:
    """Where Matrix is for this deck, and in what state. Pure.

    UX-02: the client URL is DERIVED from the listener in homeserver.yaml
    (port, tls, bind_addresses). It used to be the constant
    https://<ip>:8008, which matched neither Synapse's generated default
    (http, loopback) nor the Element config setup-matrix.sh writes (:8448).
    """
    mode = "none"
    url = ""
    note = ""
    if homeserver_yaml_exists or synapse_installed:
        mode = "server"
        src = source or HOMESERVER_YAML
        if homeserver_text is None:
            note = (f"URL unknown — read {src}"
                    + (f" ({homeserver_err})" if homeserver_err else " (not present yet)"))
        else:
            ep = client_endpoint(parse_listeners(homeserver_text), primary_ip)
            url = ep["url"]
            if not url:
                note = f"URL unknown — {ep['why']} ({src})"
            elif ep["loopback_only"]:
                note = (f"listener {url} is bound to loopback only — other machines cannot connect "
                        f"(bind_addresses in {src})")
    elif element_cfg_text:
        try:
            cfg = json.loads(element_cfg_text)
            url = (cfg.get("default_server_config", {}).get("m.homeserver", {}).get("base_url")
                   or cfg.get("default_hs_url") or "")
            if url:
                mode = "client"
        except (ValueError, AttributeError):
            pass
    state = unit_active.strip() or "inactive"
    if mode == "server":
        headline = f"Homeserver on this deck — {state}"
    elif mode == "client":
        headline = f"Client of a remote homeserver — {url}"
    else:
        headline = "No Matrix configured on this deck (opt-in: sudo setup-matrix.sh --mode server|client)"
    return {"mode": mode, "url": url, "unit": state, "headline": headline, "note": note,
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
