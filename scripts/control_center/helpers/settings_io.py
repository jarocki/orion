"""settings_io — operator settings are written atomically and the outcome is reported (DEC-PHASE12-069).

@decision DEC-PHASE12-069
@title Settings writes are atomic, failures are shown, and every write says whether it survives reboot
@status accepted
@rationale python.md P2-5, ux.md UX-01/11/13. The posture, autonomy and
  R.A.I.N. writers used plain write_text (a concurrent reader could see a
  truncated file and fail closed to "all off") and either swallowed OSError or
  ignored the return value, then toasted success. On an amnesic stick none of
  these files outlive a reboot and nothing said so. Writes now go through a
  temp file in the same directory + os.replace; the caller gets (ok, error
  text) and must show the error and revert the control on failure; and
  `reboot_line()` reuses tuning_lib.persistence_present() so every surface
  states the same reboot truth (docs/RESILIENCE.md rule 4).
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "awareness"))
import tuning_lib  # noqa: E402  (persistence_present: the one reboot-truth probe)

PERSISTENCE_ROOT = tuning_lib.PERSISTENCE_ROOT


def atomic_write_text(path: Path, text: str) -> tuple[bool, str]:
    """Write `text` to `path` via a same-directory temp file + os.replace.

    Returns (True, "") or (False, "<path>: <reason>"). Never raises.
    """
    path = Path(path)
    tmp = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix="." + path.name + ".", suffix=".tmp", dir=str(path.parent))
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        return True, ""
    except OSError as exc:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return False, f"{path}: {exc.strerror or exc}"


def reboot_line(root: Path | str = PERSISTENCE_ROOT) -> str:
    """'survives reboot: YES (persistence at …)' or 'survives reboot: NO — <why>'."""
    present, where = tuning_lib.persistence_present(root)
    if present:
        return f"survives reboot: YES (persistence at {where})"
    return f"survives reboot: NO — {where}; it is gone after this deck reboots"
