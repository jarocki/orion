"""moved — where each control of the old Control Center lives now (#95). No GTK.

`orionx-control-center` is this module plus a parser: it opens a Cockpit tab,
or a moved control's new home after saying where it went. Imported by app.py
(run_app) and by the wrapper (--help, --where), which must work with no
display.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

# @decision DEC-PHASE13-049
# @title The Control Center is a launcher that names where each control went; its controls moved, nothing stays as a fallback
# @status accepted
# @rationale #95, under DEC-PHASE13-048. Its window went in DEC-PHASE12-053, but
#   its sections stayed as Cockpit tabs and kept being the only writers of
#   several settings, with tool controls among them. Each control now has one
#   home: posture, R.A.I.N., the theme and the DJ deck in the Cockpit settings
#   drawer; the autonomy grid and Nebula warm-up in the Workbench's Engine
#   section; the optional installers in the Workbench's Optional section, which
#   already had them. The Workbench page stays read-only and hands over the
#   command (orionx-heal autonomy, nebula warmup): a loopback page that could
#   grant "autonomous" to kill_process is a target for any tab that reaches
#   127.0.0.1, and a terminal is where the Workbench already runs things. The
#   superseded code went in the same change: the Auto-Healing tab (which also
#   wrote "propose" for every unset class whenever the Cockpit was built, so
#   opening a window granted consent), the Awareness tab's posture and R.A.I.N.
#   block, the Nebula tab's warm-up button and the Orion Tools tab's installer
#   grid and theme button. Keeping any of them "as a fallback" would leave two
#   writers for one file, which is the bug this exists to remove.
#   `orionx-control-center` stays one release, as a launcher: `--tab KEY`
#   opens a tab, or a moved control's new home after saying where it went;
#   `--where` prints MOVED. Then it can go with its menu entry.
#
# key -> (the control, where it lives now, argv that opens it, the command that
#         changes it or ""). `orionx-control-center --tab KEY` opens the home;
#         --where prints this. The ONE list; the User Guide and MASTER_PLAN
#         subsection "Control Center demotion (#95)" describe it.
MOVED: dict[str, tuple[str, str, list[str], str]] = {
    "posture": ("Threat posture", "Orion Cockpit → Settings",
                ["orionx-cockpit", "--settings"], ""),
    "rain": ("R.A.I.N. alerts: tone, voice, narration, volume, test", "Orion Cockpit → Settings",
             ["orionx-cockpit", "--settings"], "orionx-rain --speech on|off"),
    "theme": ("Display: Toggle Theme", "Orion Cockpit → Settings",
              ["orionx-cockpit", "--settings"], "toggle-theme.sh"),
    "dj": ("DJ deck", "Orion Cockpit → Settings (opens orionx-dj)",
           ["orionx-cockpit", "--settings"], "orionx-dj"),
    "healing": ("Auto-healing consent (the autonomy grid)", "Orion Workbench → Engine",
                ["orionx-osint"], "orionx-heal autonomy CLASS LEVEL"),
    "warmup": ("Nebula warm-up", "Orion Workbench → Engine", ["orionx-osint"], "nebula warmup"),
    "installers": ("Optional installers", "Orion Workbench → Optional", ["orionx-osint"], ""),
}


def where_text(tab_keys: list[str] | None = None) -> str:
    """Plain text: every moved control with its home (and the tab keys, when given)."""
    lines = (["Orion Cockpit tabs (orionx-cockpit --tab KEY): " + ", ".join(tab_keys)] if tab_keys else []) + [
        "Moved controls (#95) — orionx-control-center --tab KEY opens the home:"]
    for key, (what, home, _argv, cmd) in MOVED.items():
        lines.append(f"  {key:<10} {what} → {home}" + (f"   (terminal: {cmd})" if cmd else ""))
    return "\n".join(lines)


def _resolve(name: str) -> str:
    """PATH first; then this tree's copy (a checkout, or /opt/orionx/scripts)."""
    here = Path(__file__).resolve().parents[1]
    local = {"orionx-cockpit": here / "cockpit" / "orionx-cockpit",
             "orionx-osint": here / "osint" / "osint_server.py"}
    return shutil.which(name) or str(local.get(name, name))


def target_argv(tab: str) -> tuple[list[str], str]:
    """(argv to exec, line to print first) for `--tab KEY`."""
    if tab in MOVED:
        what, home, argv, cmd = MOVED[tab]
        note = f"orionx-control-center: {what} moved to {home} (#95)" + (f"; in a terminal: {cmd}" if cmd else "")
        return [_resolve(argv[0])] + argv[1:], note
    return [_resolve("orionx-cockpit"), "--tab", tab], ""


def launch(args: list[str], tab_keys: list[str], default_tab: str) -> int:
    """`--tab <key>` opens a Cockpit tab, or the home of a moved control, saying so first.

    The default is the first tab, so the old habit still lands on the same
    content. `--where` prints MOVED. Execs; returns only on failure.
    """
    if "--where" in args:
        print(where_text(tab_keys))
        return 0
    tab = default_tab
    for i, a in enumerate(args):
        if a == "--tab" and i + 1 < len(args):
            tab = args[i + 1]
        elif a.startswith("--tab="):
            tab = a.split("=", 1)[1]
    if tab not in tab_keys and tab not in MOVED:
        print(f"orionx-control-center: unknown tab {tab!r}; one of {', '.join(list(tab_keys) + list(MOVED))}",
              file=sys.stderr)
        return 2
    argv_out, note = target_argv(tab)
    if note:
        print(note, file=sys.stderr)
    exe = argv_out[0]
    if not os.path.exists(exe):
        print(f"orionx-control-center: {os.path.basename(exe)} is not installed; the controls live there now "
              "(DEC-PHASE12-053, DEC-PHASE13-049). Remedy: check /opt/orionx/scripts", file=sys.stderr)
        return 127
    try:
        os.execv(exe, argv_out)
    except OSError as exc:
        print(f"orionx-control-center: could not start {exe}: {exc}", file=sys.stderr)
        return 126
    return 1  # unreachable
