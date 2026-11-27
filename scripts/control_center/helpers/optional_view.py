"""optional_view — what the Cockpit's Tools tab shows for optional tools (#199). No GTK.

Every word, colour and button the tab draws comes from a function here, fed
by `orionx-optional status --json` (DEC-PHASE13-057, the one authority), so
the rules are unit-tested and the GTK code only places widgets.

@decision DEC-PHASE13-060
@category UX
@title The Cockpit's Tools tab shows every optional tool's state at a glance and installs or removes it in place
@status accepted
@rationale #199 (owner, 2026-11-25): "they UI need to show their state
  (installed, active, health, etc.) AS WELL AS allow for the installation and
  uninstallation from the same interface. Having to copy a command to a
  separate terminal adds analyst friction." The Tools tab draws one tile per
  tool in its functional group: a light, one state word and one line of
  reason, version or health, and the one button that state allows. Install
  and uninstall run `pkexec orionx-optional ACTION ID` (DEC-PHASE13-058) in a
  worker thread; its PROGRESS lines drive a bar and its output a live log in
  the detail panel, and the helper publishes the bus events, so the Cockpit
  never writes a second copy. Uninstall asks first and says how much its
  record will remove; install does not, since nothing is lost and polkit
  already asks. A dismissed or refused authentication changes nothing, so it
  is a toast plus one info event, not a failure. The Workbench keeps a
  read-only mirror (#200): privileged actions stay out of the loopback page
  (DEC-PHASE13-049).
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

HELPER = "/opt/orionx/scripts/optional/orionx-optional"   # the path the polkit action pins

GREEN, AMBER, RED, DIM, CYAN = "#34ff9e", "#ffb330", "#ff5c40", "#8c99a8", "#33d9ff"
OFF = "#3a4552"

# state -> (word, colour, pulses)
LOOK = {
    "active": ("ACTIVE", GREEN, False),
    "installed": ("INSTALLED", GREEN, False),
    "degraded": ("DEGRADED", AMBER, False),
    "failed": ("FAILED", RED, False),
    "working": ("WORKING", AMBER, True),
    "not_installed": ("NOT INSTALLED", OFF, False),
}


def helper_path() -> str:
    """The pinned helper on a deck; a checkout's copy when run from the tree (tests, development)."""
    if os.path.exists(HELPER):
        return HELPER
    here = Path(__file__).resolve().parents[2] / "optional" / "orionx-optional"
    return str(here) if here.exists() else (shutil.which("orionx-optional") or HELPER)


def collect(run=subprocess.run, helper: str | None = None) -> dict:
    """`orionx-optional status --json`, or {'error': why}. Worker thread only."""
    argv = [helper or helper_path(), "status", "--json"]
    try:
        r = run(argv, capture_output=True, text=True, timeout=30, check=False)
    except FileNotFoundError:
        return {"error": f"{argv[0]} is not on this deck"}
    except (OSError, subprocess.SubprocessError) as exc:
        return {"error": f"could not ask orionx-optional: {exc}"}
    if r.returncode != 0:
        return {"error": f"orionx-optional status exited {r.returncode}: {(r.stderr or '').strip()[:160]}"}
    try:
        d = json.loads(r.stdout)
    except ValueError:
        return {"error": "orionx-optional status did not return JSON"}
    return d if isinstance(d, dict) and "tools" in d else {"error": "orionx-optional status: unexpected reply"}


def grouped(status: dict) -> list[tuple[dict, list[dict]]]:
    """[(group, [tool, ...]), ...] in catalogue order; empty groups dropped."""
    tools = status.get("tools") or []
    return [(g, [t for t in tools if t.get("group") == g.get("id")]) for g in status.get("groups") or []
            if any(t.get("group") == g.get("id") for t in tools)]


def tile(t: dict) -> dict:
    """{'word','color','pulse','line','button','action','enabled','tip'} for one tool."""
    word, color, pulse = LOOK.get(t.get("state"), ("UNKNOWN", DIM, False))
    st = t.get("state")
    line, action, label, enabled, tip = "", None, "", False, ""
    if st == "working":
        p = t.get("progress") or {}
        word = f"{'INSTALLING' if p.get('action') == 'install' else 'REMOVING'} {p.get('n', '?')}/{p.get('m', '?')}"
        line = p.get("line") or p.get("step") or ""
        label, enabled, tip = "Details", True, "Show progress and the live log"
    elif st in ("installed", "active", "degraded"):
        line = t.get("reason") or t.get("version") or ""
        label, action = "Uninstall", "uninstall"
        enabled = bool(t.get("can_uninstall"))
        tip = "Remove what orionx-optional installed" if enabled else t.get("uninstall_reason", "")
        if not enabled and not t.get("reason"):
            line = (t.get("version") + " · " if t.get("version") else "") + "shipped with the image"
    else:  # not_installed / failed
        line = t.get("reason") if st == "failed" else (t.get("install_reason") or t.get("size") or "")
        label, action = ("Retry" if st == "failed" else "Install"), "install"
        enabled = bool(t.get("can_install"))
        tip = (f"Download and install ({t.get('size') or 'size unknown'})" if enabled
               else t.get("install_reason", ""))
    return {"word": word, "color": color, "pulse": pulse, "line": line, "button": label, "action": action,
            "enabled": enabled, "tip": tip}


def summary_line(status: dict) -> str:
    s = status.get("summary") or {}
    n = len(status.get("tools") or [])
    parts = [f"{n} optional", f"{s.get('active', 0) + s.get('installed', 0)} ready"]
    for key, word in (("degraded", "attention"), ("failed", "failed"), ("working", "working")):
        if s.get(key):
            parts.append(f"{s[key]} {word}")
    return " · ".join(parts)


def network_line(status: dict) -> tuple[str, str]:
    """(text, colour): can installs reach the network right now?"""
    reasons = [t.get("install_reason", "") for t in status.get("tools") or [] if t.get("state") != "working"]
    if any("no network route" in r for r in reasons):
        return "network OFFLINE (no route): installs wait for a connection", RED
    if any(r.startswith("needs network") for r in reasons):
        return "network: some download sources do not resolve (see each tool)", AMBER
    return "network online: installs allowed", GREEN


def action_argv(action: str, tool_id: str, helper: str | None = None) -> list[str]:
    if action not in ("install", "uninstall"):
        raise ValueError(action)
    return ["pkexec", helper or HELPER, action, tool_id]


def parse_line(line: str) -> tuple:
    """('progress', n, m, label) | ('result', ok, message) | ('log', text)."""
    s = line.rstrip("\n")
    if s.startswith("PROGRESS "):
        try:
            nm, label = s[9:].split(" ", 1)
            n, m = nm.split("/")
            return ("progress", int(n), int(m), label)
        except ValueError:
            pass
    if s.startswith("RESULT "):
        rest = s[7:]
        ok = rest.startswith("ok")
        return ("result", ok, rest.split(" ", 1)[1] if " " in rest else "")
    return ("log", s[2:] if s.startswith("| ") else s)


# pkexec's own exit codes: the helper never ran.
PKEXEC_CODES = {126: "authentication was dismissed", 127: "not authorized (polkit refused)"}


def outcome(name: str, action: str, rc: int, result: tuple | None) -> tuple[str, str, bool]:
    """(toast text, level, helper_ran) once the process has exited."""
    verb = "install" if action == "install" else "uninstall"
    if result is not None:
        ok, msg = result[1], result[2]
        return ((f"✓ {msg}" if ok else f"✗ {name} {verb} failed: {msg}"), ("ok" if ok else "error"), True)
    if rc in PKEXEC_CODES:
        return (f"{name}: {verb} not started, {PKEXEC_CODES[rc]}", "info", False)
    return (f"✗ {name} {verb}: orionx-optional exited {rc} without a result", "error", True)


def confirm_text(t: dict) -> str:
    r = t.get("record") or {}
    what = ", ".join(f"{r[k]} {label}" for k, label in (("apt", "Debian packages"), ("pip", "pip packages"),
                                                       ("paths", "files or folders")) if r.get(k))
    return (f"Uninstall {t.get('name', t.get('id'))}?\n\nThis removes what orionx-optional installed: "
            f"{what or 'nothing recorded beyond the tool itself'}. apt is asked first and the removal "
            "is refused if it would take anything else.")
