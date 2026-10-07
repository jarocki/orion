"""GTK behaviour checks for the Cockpit; driven by tests/unit/test_cockpit_gtk.sh.

Needs a display (xvfb-run). Writes only under a temporary HOME.
"""
from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
WORK = Path(tempfile.mkdtemp(prefix="orionx-gtk-"))
HOME = WORK / "home"
HOME.mkdir()
os.environ["HOME"] = str(HOME)
BIN = WORK / "bin"
BIN.mkdir()
os.environ["PATH"] = f"{BIN}:{os.environ.get('PATH', '/usr/bin:/bin')}"
sys.path.insert(0, str(ROOT / "scripts"))

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: E402

PASS = FAIL = 0


def ck(cond: bool, msg: str) -> None:
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS: " + msg)
    else:
        FAIL += 1
        print("  FAIL: " + msg)


def pump(seconds: float = 0.3) -> None:
    end = time.time() + seconds
    while time.time() < end:
        while Gtk.events_pending():
            Gtk.main_iteration_do(False)
        time.sleep(0.01)


def stub(name: str, body: str) -> None:
    p = BIN / name
    p.write_text("#!/bin/sh\n" + body + "\n")
    p.chmod(0o755)


def walk(w):
    yield w
    if isinstance(w, Gtk.Container):
        for c in w.get_children():
            yield from walk(c)


stub("orionx-event", "exit 0")
from control_center.helpers import ux  # noqa: E402

TOASTS: list[tuple[str, str]] = []
ux.set_notifier(lambda m, lvl: TOASTS.append((lvl, m)))


def last_toast() -> tuple[str, str]:
    return TOASTS[-1] if TOASTS else ("", "")


# ---------------------------------------------------------------- Awareness
print("[awareness: posture is a request; a failed write reverts and says why]")
from control_center.sections import awareness as AW  # noqa: E402

win = Gtk.Window()
aw = AW._AwarenessWidget()
win.add(aw.box)
win.show_all()
pump(0.5)
cfg_dir = HOME / ".config" / "orionx"
cfg_dir.mkdir(parents=True, exist_ok=True)
aw._radios["1"].set_active(True)
pump(0.2)
ck((cfg_dir / "threat-posture").read_text() == "1\n", "selecting Tier 1 writes the request file")
lvl, msg = last_toast()
ck(msg.startswith("requested Tier 1") and "waiting for orionx-postured" in msg and "survives reboot:" in msg,
   f"toast says requested + reboot truth, not 'set' ({msg})")
ck("enforced" not in aw._posture_status.get_text().split("—")[0], f"status line is not 'enforced' ({aw._posture_status.get_text()})")
if os.geteuid() != 0:
    cfg_dir.chmod(0o500)
    aw._radios["2"].set_active(True)
    pump(0.2)
    cfg_dir.chmod(0o700)
    lvl, msg = last_toast()
    ck(lvl == "error" and "NOT changed" in msg and "threat-posture" in msg, f"unwritable config -> error toast ({msg})")
    ck(aw._radios["1"].get_active() and not aw._radios["2"].get_active(), "the radio reverts to the tier actually requested")
    ck((cfg_dir / "threat-posture").read_text() == "1\n", "request file unchanged")
else:
    print("  (skipped unwritable case: root)")

print("[awareness: R.A.I.N. test reports the real outcome (UX-12)]")
stub("orionx-rain", 'echo "paplay: no audio device" >&2; exit 3')
n0 = len(TOASTS)
aw._on_rain_test(None)
pump(1.5)
msgs = [m for _l, m in TOASTS[n0:]]
ck(any("✗ R.A.I.N. test failed (exit 3): paplay: no audio device" in m for m in msgs), f"failed test says so with the error ({msgs})")
ck(not any("played" in m and "✗" not in m for m in msgs[1:]), "no success toast after a failure")
stub("orionx-rain", "exit 0")
n0 = len(TOASTS)
aw._on_rain_test(None)
pump(1.5)
ck(any("exit 0" in m for _l, m in TOASTS[n0:]), "exit 0 is reported as exit 0, with the next step if nothing was heard")
(BIN / "orionx-rain").unlink()
n0 = len(TOASTS)
aw._on_rain_test(None)
pump(1.5)
ck(any("not installed" in m for _l, m in TOASTS[n0:]), "missing orionx-rain -> 'not installed'")

print("[awareness: R.A.I.N. settings go through rain_lib and toast (UX-13)]")
n0 = len(TOASTS)
aw._rain_vol.set_value(40)
pump(1.0)
saved = (cfg_dir / "rain.json").read_text()
ck('"volume": 0.4' in saved, "volume saved through rain_lib.save_config")
ck(any("volume 40%" in m and "survives reboot:" in m for _l, m in TOASTS[n0:]), f"change toasts the setting + reboot truth ({TOASTS[n0:]})")
win.destroy()

# ---------------------------------------------------------------- Auto-Healing
print("[auto-healing: a failed write reverts and says why (P2-5, UX-11)]")
from control_center.sections import auto_healing as AH  # noqa: E402

win = Gtk.Window()
ah = AH._AutoHealingWidget()
win.add(ah.box)
win.show_all()
pump(0.2)
ck((cfg_dir / "autonomy.json").exists() and "Wrote default" in ah._status.get_text(), "materialised defaults are announced")
ck("survives reboot:" in ah._status.get_text(), "the grid states whether the pre-approvals survive reboot")
combo = ah._combos["block_ip"]
combo.set_active(AH._LEVELS.index("autonomous"))
pump(0.2)
ck('"block_ip": "autonomous"' in (cfg_dir / "autonomy.json").read_text(), "level saved")
if os.geteuid() != 0:
    cfg_dir.chmod(0o500)
    combo.set_active(AH._LEVELS.index("off"))
    pump(0.2)
    cfg_dir.chmod(0o700)
    lvl, msg = last_toast()
    ck(lvl == "error" and "NOT changed" in msg, f"unwritable -> error toast ({msg})")
    ck(combo.get_active_text() == "autonomous", "combo reverts to what the engine will read")
win.destroy()

print(f"Results: {PASS} passed, {FAIL} failed", flush=True)
os._exit(1 if FAIL else 0)   # skip GTK teardown: it can hang under Xvfb
