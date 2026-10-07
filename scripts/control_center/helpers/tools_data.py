"""tools_data — the Orion Tools tab reads the Workbench catalogue (DEC-PHASE12-057).

@decision DEC-PHASE12-057
@title "IR Tools" becomes "Orion Tools": every on-deck and optional tool, determined at runtime
@status accepted
@rationale The tab was six hard-coded buttons while the Workbench already
  held the full catalogue (links.json: `local` with runtime_path, `installable`
  with probes). Two lists of the same tools drift; so this tab READS that
  catalogue and the server's own probe logic, and shows what is actually on
  this deck — with an Install button for what is not.

@decision DEC-PHASE12-072
@title Orion Tools resolves pkg: entries, labels actions by what they do, and shows the network before offering installs
@status accepted
@rationale ux.md UX-03/04/05/24/34/36/48 and python.md P2-7. Guided actions
  passed arguments the scripts reject (each opened a terminal full of usage
  text under a "✓ Opened" toast); "On this deck" hid every pkg: entry; "Run"
  ran --help or a command with <placeholders>; installs were offered with no
  word about the network; an osint_server import failure turned every
  optional state into "unknown" with no reason. See run_action(), present()
  and sections/ir.py.
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


DPKG_INFO = Path("/var/lib/dpkg/info")


def pkg_installed(name: str, info_dir: Path = DPKG_INFO) -> bool:
    """Is a Debian package installed? dpkg's own file list, no fork (UX-05)."""
    info_dir = Path(info_dir)
    return (info_dir / f"{name}.list").exists() or any(info_dir.glob(f"{name}:*.list"))


def present(runtime_path: str, exists: Callable[[str], bool],
            pkg: Callable[[str], bool] = pkg_installed) -> bool:
    """`pkg:NAME` -> the package is installed; anything else -> the path exists."""
    rp = str(runtime_path or "")
    if rp.startswith("pkg:"):
        return bool(rp[4:]) and pkg(rp[4:])
    return bool(rp) and exists(rp)


def on_deck(local: list[dict], exists: Callable[[str], bool],
            pkg: Callable[[str], bool] = pkg_installed) -> list[dict]:
    """Local entries really present here (truth, not catalogue).

    UX-05: 12 of 25 entries are `runtime_path: "pkg:<package>"`;
    os.path.exists("pkg:nmap") is always False, so nmap, tshark, yara… were
    hidden while the copy claimed to show everything on the deck.
    """
    return [it for it in local if present(str(it.get("runtime_path") or ""), exists, pkg)]


def run_action(item: dict) -> dict | None:
    """How the tab offers an entry: {'label', 'how', 'argv', 'example'}; None = omit. Pure.

    UX-36: a "Run" that prints --help is labelled Help; a command with
    <placeholders> cannot be run as written, so it is shown as an example
    with a terminal to type it in; the Cockpit itself is omitted (this tab
    lives inside it).
    """
    if str(item.get("id")) == "cockpit":
        return None
    how, argv = launch_argv(item)
    cmd = str(item.get("command") or "")
    if how == "detached":
        return {"label": "Open", "how": how, "argv": argv, "example": ""}
    if "<" in cmd and ">" in cmd:
        return {"label": "Terminal", "how": "terminal", "argv": ["bash", "-i"], "example": cmd}
    if argv and argv[-1] in ("--help", "-h"):
        return {"label": "Help", "how": how, "argv": argv, "example": ""}
    return {"label": "Run", "how": how, "argv": argv, "example": ""}


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


# --- guided actions: argv exactly as each script's own parser expects -------

def samples_argv(samples_dir: str, has_route: bool) -> list[str]:
    """download-samples.sh accepts only --samples-dir DIR [--offline] (UX-03/48)."""
    return ["download-samples.sh", "--samples-dir", samples_dir] + ([] if has_route else ["--offline"])


def storyboard_argv(input_dir: str, analysis_dir: str, stamp: str) -> tuple[list[str], str]:
    """storyboard-gen.py requires -i INPUT and -o an output FILE (UX-04)."""
    out = f"{analysis_dir.rstrip('/')}/storyboard-{stamp}.html"
    return ["storyboard-gen.py", "-i", input_dir, "-o", out], out


# UX-24: run the toggle in a terminal so its own report (FAILED lines and
# remedies included) is visible, then open a SEPARATE terminal process — the
# only kind born with the new palette — showing --status.
THEME_ARGV = ["sh", "-c",
              "toggle-theme.sh; rc=$?; "
              "xfce4-terminal --disable-server --title 'Orion-X theme — new palette' --hold "
              "-x toggle-theme.sh --status & exit $rc"]


def network_gate(route: dict, posture: dict) -> tuple[str, str]:
    """(headline for the tab, reason installs are disabled or ''). Pure (UX-34).

    Installers fetch from the network. No default route means they will
    fail; at a raised posture (shields up) reaching out is what the operator
    asked the deck not to do. Both are said up front, not after a terminal
    opens.
    """
    has = bool(route.get("default_route"))
    rt = f"default route via {route.get('interface') or 'IPv6'}" if has else "no default route"
    tier = posture.get("tier") if posture.get("known") else None
    pl = str(posture.get("label")) if tier else f"posture unknown ({posture.get('reason') or 'no status'})"
    head = f"Network: {rt} · {pl}"
    if not has:
        return head, "no default route — connect first (Network tab); the installers need the network"
    if tier is not None and not posture.get("outbound_allowed", True):
        return head, f"{pl}: the deck is not reaching out — lower the posture (Awareness tab) to install"
    return head, ""
