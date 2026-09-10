"""
Orion-X Control Center — UX helpers: non-blocking launchers + toast feedback.

Every operator action gets immediate, plain-language feedback and never blocks
the GTK main loop or throws a raw error at the user.  This is the "works like
magic / designed for my 3am self" layer.

  - launch_detached() / launch_in_terminal(): fire-and-forget Popen.  We never
    use subprocess_runner.run(..., timeout=N) inside a click handler, because
    that BLOCKS the GTK thread for up to N seconds and then SIGKILLs the
    launched GUI at the timeout — the exact bug that made "Open Network
    Manager" freeze the whole window and close the editor after 2 s.
  - shutil.which() preflight: if a tool is not installed we say so in one line
    instead of surfacing a Python traceback, a silent no-op, or a terminal
    full of "command not found".
  - notify(): routes a one-line result to the window's toast bar.  Sections
    depend only on this function, not on the window, so they stay importable
    and testable with no GTK display (notify() is a no-op until app.py
    registers a sink via set_notifier()).

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale See helpers/subprocess_runner.py for the full rationale.

@decision DEC-PHASE11-030
@title Control Center UX layer: non-blocking launchers + toast feedback
@status accepted
@rationale Operator directive 2026-09-09: "when I click a button I just get
  errors ... it should work LIKE MAGIC ... designed for my 3am self."  Every
  section launcher previously used run(..., timeout=2) in the click handler,
  which (a) blocked the GTK loop and (b) SIGKILLed long-running GUIs
  (nm-connection-editor, xfce4-terminal) at the 2 s mark.  This module is the
  single launcher authority: detached Popen + which() preflight + a toast, so a
  click either does the thing and says "Launched X" or explains "X is not
  installed" — never a raw error.
"""
from __future__ import annotations

import shutil
import subprocess
from typing import Callable, Optional, Sequence

# Toast levels — app.py maps these to CSS classes (ok / error / info).
LEVEL_OK = "ok"
LEVEL_ERROR = "error"
LEVEL_INFO = "info"

# Registered by app.py; sections never import the window directly.
_notifier: Optional[Callable[[str, str], None]] = None


def set_notifier(fn: Callable[[str, str], None]) -> None:
    """Register the window's toast sink.  Called once by app.py."""
    global _notifier
    _notifier = fn


def notify(message: str, level: str = LEVEL_INFO) -> None:
    """Send a one-line result to the toast bar (no-op until a sink is set)."""
    if _notifier is not None:
        _notifier(message, level)


def have(cmd: str) -> bool:
    """True when *cmd* resolves to an executable on PATH."""
    return shutil.which(cmd) is not None


def launch_detached(
    args: Sequence[str],
    *,
    needs: Optional[str] = None,
    friendly: Optional[str] = None,
) -> bool:
    """Launch *args* without blocking the GTK loop; toast the outcome.

    Parameters
    ----------
    args:
        Full argv of the process to launch.
    needs:
        Executable to preflight with which() (defaults to args[0]).
    friendly:
        Human name used in the toast (defaults to *needs*).

    Returns True when the process was successfully spawned.
    """
    exe = needs or (args[0] if args else "")
    label = friendly or exe
    if not have(exe):
        notify(f"✗ {label} is not installed on this system", LEVEL_ERROR)
        return False
    try:
        subprocess.Popen(
            list(args),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        notify(f"✗ Could not launch {label}: {exc}", LEVEL_ERROR)
        return False
    notify(f"✓ Launched {label}", LEVEL_OK)
    return True


def launch_in_terminal(
    inner_argv: Sequence[str],
    *,
    needs: str,
    friendly: str,
    title: Optional[str] = None,
    hold: bool = True,
) -> bool:
    """Open *inner_argv* inside xfce4-terminal; preflight the real tool first.

    Uses ``xfce4-terminal -x <argv...>`` so the command is passed as a proper
    argument vector — no nested ``bash -c '...'`` string, no shell quoting, and
    none of the single-quote-apostrophe breakage that has bitten us before.
    ``--hold`` keeps the window open so the operator can read the output after
    the tool exits.

    Preflights both xfce4-terminal and *needs* (the actual tool) so a missing
    tool is reported in plain language rather than as a terminal full of
    "command not found".
    """
    if not have("xfce4-terminal"):
        notify("✗ xfce4-terminal is not installed", LEVEL_ERROR)
        return False
    if not have(needs):
        notify(f"✗ {friendly} is not installed on this system", LEVEL_ERROR)
        return False
    argv = ["xfce4-terminal", "-T", title or friendly]
    if hold:
        argv.append("--hold")
    argv.append("-x")
    argv.extend(inner_argv)
    try:
        subprocess.Popen(
            argv,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        notify(f"✗ Could not launch {friendly}: {exc}", LEVEL_ERROR)
        return False
    notify(f"✓ Opened {friendly} in a terminal", LEVEL_OK)
    return True
