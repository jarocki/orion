"""engine_view — what the engine controls read and the commands that change them (#201). No GTK.

One module for both surfaces: the Cockpit's Settings drawer (Engine group,
where the controls live) and the Workbench's read-only Engine cards. The
writers stay what they were: `orionx-heal autonomy` (healing_lib.set_autonomy,
the only writer of autonomy.json, DEC-PHASE13-049), `nebula warmup`, and
systemd's own unit enablement for the boot-time warm-up.

@decision DEC-PHASE13-062
@category UX
@title Auto-healing consent and Nebula warm-up are Cockpit controls; every change is a bus event
@status accepted
@rationale #201 (owner, 2026-11-25): no copy-a-command step for any control,
  and every change reaches the event bus. #95 put these on the Workbench as
  read-only cards with commands to copy, because a loopback page must not
  write consent (DEC-PHASE13-049); that rule stays, and the controls move to
  the native Cockpit (Settings drawer, Engine group) instead. Each control
  runs the existing writer as the operator: the autonomy grid runs
  `orionx-heal autonomy CLASS LEVEL` (which now publishes the change, warning
  when a class becomes autonomous, so the event comes from the writer whatever
  surface made it); Run now runs `nebula warmup` (which now publishes its
  outcome); the boot switch runs `systemctl enable|disable
  nebula-warmup.service`, which systemd gates with its own polkit action
  (org.freedesktop.systemd1.manage-unit-files), and the Cockpit publishes the
  change. Choosing autonomous asks first. The engine state both surfaces
  show is computed here, once.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

_here = Path(__file__).resolve().parent
if str(_here) not in sys.path:
    sys.path.insert(0, str(_here))
import healing_lib  # noqa: E402

WARMUP_UNIT = "nebula-warmup.service"
WARMUP_WANTS = Path(os.environ.get(
    "ORIONX_WARMUP_WANTS", "/etc/systemd/system/multi-user.target.wants/nebula-warmup.service"))
WARMUP_LOG = Path(os.environ.get("ORIONX_WARMUP_LOG", "/var/log/orionx/nebula-warmup.log"))


def engine_state(wants: Path | None = None, log: Path | None = None) -> dict:
    """Auto-healing consent as heald reads it (an unset class is off) and the warm-up's state."""
    wants = wants or WARMUP_WANTS
    log = log or WARMUP_LOG
    levels = healing_lib.load_autonomy()
    classes = [{"id": p.name, "summary": p.summary,
                "level": healing_lib.level_for(levels, p.name), "set": p.name in levels}
               for p in healing_lib.REGISTRY]
    try:
        last = log.stat().st_mtime
    except OSError:
        last = None
    return {
        "autonomy": {
            "file": str(healing_lib.AUTONOMY_FILE),
            "present": healing_lib.AUTONOMY_FILE.is_file(),
            "levels": list(healing_lib.LEVELS),
            "classes": classes,
            "command": "orionx-heal autonomy <class> <level>",
            "show": "orionx-heal autonomy",
        },
        "warmup": {
            "enabled_at_boot": wants.exists(),
            "last_run": last,
            "log": str(log),
            "now": "nebula warmup",
            "enable": f"systemctl enable {WARMUP_UNIT}",
            "disable": f"systemctl disable {WARMUP_UNIT}",
        },
    }


def autonomy_argv(cls: str, level: str) -> list[str]:
    if cls not in healing_lib.PLAYBOOK_NAMES or level not in healing_lib.LEVELS:
        raise ValueError(f"{cls} {level}")
    return ["orionx-heal", "autonomy", cls, level]


def warmup_argv() -> list[str]:
    return ["nebula", "warmup"]


def boot_argv(on: bool) -> list[str]:
    return ["systemctl", "enable" if on else "disable", WARMUP_UNIT]


def consent_event(cls: str, old: str, new: str) -> tuple[str, str]:
    """(severity, message) for one consent change; autonomous acts without asking -> warning."""
    sev = "warning" if new == "autonomous" else "notice"
    tail = " (acts WITHOUT asking)" if new == "autonomous" else ""
    return sev, f"Auto-healing consent: {cls} {old} → {new}{tail}"


def boot_event(on: bool, rc: int) -> tuple[str, str]:
    what = "enabled" if on else "disabled"
    if rc == 0:
        return "notice", f"Nebula warm-up at boot {what} ({WARMUP_UNIT})"
    return "warning", f"Nebula warm-up at boot NOT {what}: systemctl exited {rc}"
