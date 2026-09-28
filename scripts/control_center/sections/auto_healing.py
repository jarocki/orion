"""
Orion-X Control Center — Auto-Healing (W10-6 working core).

The headline W10-6 feature is an auto-healing playbook engine with tiered
autonomy per DEC-PHASE10-004. This module lands the operator-facing authority:
a per-action-class autonomy grid where the operator pre-approves, in advance,
how much Orion-X may act on its own for each class of response:

    off         — never run this playbook automatically
    propose     — surface a suggestion only; the operator runs it manually
    confirm     — ask the operator (one click) before running
    autonomous  — run it without asking, within this pre-approval

Selections persist to ~/.config/orionx/autonomy.json — the SINGLE authority the
healing engine reads before taking any action. Nothing acts beyond the level
set here.

The engine that consumes this file is orionx-heald (scripts/healing/,
DEC-PHASE12-023). All six playbooks execute for real, each with an undo and a
rollback timer, and every decision — including refusals — is sealed into a
hash-chained audit ledger the operator can verify with `orionx-heal verify`.
Until that engine landed, this grid was a control that controlled nothing: an
operator could select "autonomous" and be wrong about it during an incident.

@decision DEC-PHASE10-004
@title Tiered per-action-class autonomy (off / propose / confirm / autonomous)
@status accepted
@rationale The operator pre-approves autonomy per action class in advance; the
  auto-healing engine never exceeds the level recorded here. This tab is the
  single authority for those levels (persisted to ~/.config/orionx/autonomy.json).
  W10-6 populates the former "lands in W10-6" placeholder (marker retained in a
  comment below for test_control_center.sh).

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import json
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # type: ignore[import]  # noqa: E402

# Single authority for pre-approved autonomy levels (user-writable, no sudo).
# The auto-healing engine reads this file before every action (lands in W10-6).
_AUTONOMY_FILE = Path.home() / ".config" / "orionx" / "autonomy.json"

_LEVELS = ["off", "propose", "confirm", "autonomous"]
_DEFAULT_LEVEL = "propose"

# (action-class id, label, what it does) — mirrors scripts/nebula/playbooks/.
_ACTION_CLASSES = [
    ("block_ip", "Block IP", "Drop traffic from a hostile source (nftables)."),
    ("kill_process", "Kill process", "Terminate a malicious/runaway process."),
    ("quarantine_file", "Quarantine file", "Move a suspicious file to a sealed vault."),
    ("isolate_node", "Isolate node", "Cut this host off the network (containment)."),
    ("rotate_mesh_keys", "Rotate mesh keys", "Re-key the WireGuard mesh."),
    ("revoke_matrix_session", "Revoke Matrix session", "Kill a compromised chat session."),
]


def _load_autonomy() -> dict[str, str]:
    try:
        data = json.loads(_AUTONOMY_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return {k: v for k, v in data.items() if v in _LEVELS}
    except (OSError, ValueError):
        pass
    return {}


def _save_autonomy(levels: dict[str, str]) -> bool:
    try:
        _AUTONOMY_FILE.parent.mkdir(parents=True, exist_ok=True)
        _AUTONOMY_FILE.write_text(json.dumps(levels, indent=2), encoding="utf-8")
        return True
    except OSError:
        return False


class _AutoHealingWidget:
    """Per-action-class autonomy grid, persisted as the engine's authority."""

    def __init__(self) -> None:
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.set_border_width(12)

        title = Gtk.Label()
        title.set_markup("<b>Auto-Healing Playbooks</b>")
        title.set_halign(Gtk.Align.START)
        self.box.pack_start(title, False, False, 0)

        intro = Gtk.Label(
            label=(
                "Pre-approve how much Orion-X may act on its own, per response class.\n"
                "Nothing ever exceeds the level you set here — this is your standing consent.\n"
                "    off · never    propose · suggest only    "
                "confirm · ask first    autonomous · act now"
            )
        )
        intro.set_halign(Gtk.Align.START)
        intro.set_line_wrap(True)
        self.box.pack_start(intro, False, False, 4)

        # The engine fails closed: a key absent from autonomy.json is "off",
        # not the _DEFAULT_LEVEL this grid displays. Rather than let the
        # display and the authority disagree, materialise the full map on
        # first open so the file says exactly what the operator is looking at.
        self._levels = _load_autonomy()
        if any(cid not in self._levels for cid, _l, _d in _ACTION_CLASSES):
            for cid, _label, _desc in _ACTION_CLASSES:
                self._levels.setdefault(cid, _DEFAULT_LEVEL)
            _save_autonomy(self._levels)

        grid = Gtk.Grid()
        grid.set_column_spacing(12)
        grid.set_row_spacing(6)
        self.box.pack_start(grid, False, False, 6)

        self._combos: dict[str, Gtk.ComboBoxText] = {}
        for row, (cid, label, desc) in enumerate(_ACTION_CLASSES):
            name = Gtk.Label(label=label)
            name.set_halign(Gtk.Align.START)
            name.set_tooltip_text(desc)
            combo = Gtk.ComboBoxText()
            for lvl in _LEVELS:
                combo.append_text(lvl)
            current = self._levels.get(cid, _DEFAULT_LEVEL)
            combo.set_active(_LEVELS.index(current))
            combo.connect("changed", self._on_level_changed, cid)
            combo.set_tooltip_text(desc)
            self._combos[cid] = combo
            grid.attach(name, 0, row, 1, 1)
            grid.attach(combo, 1, row, 1, 1)

        self._status = Gtk.Label()
        self._status.set_halign(Gtk.Align.START)
        self.box.pack_start(self._status, False, False, 4)
        self._refresh_status()

        # The W10-6 plug-in surface: the autonomy engine (orionx-heald,
        # DEC-PHASE12-023) lands in W10-6 and reads exactly this file.
        note = Gtk.Label()
        note.set_markup(
            "<small>These pre-approvals are the engine's authority. Live playbooks "
            "run via orionx-heald; every action is reversible, expires on a "
            "rollback timer, and is recorded in a tamper-evident chain.\n"
            "Inspect with <tt>orionx-heal status</tt> · confirm with "
            "<tt>orionx-heal confirm &lt;id&gt;</tt> · audit with "
            "<tt>orionx-heal verify</tt>.</small>"
        )
        note.set_halign(Gtk.Align.START)
        note.set_line_wrap(True)
        self.box.pack_start(note, False, False, 0)

    def _on_level_changed(self, combo: Gtk.ComboBoxText, cid: str) -> None:
        level = combo.get_active_text()
        if level not in _LEVELS:
            return
        self._levels[cid] = level
        _save_autonomy(self._levels)
        self._refresh_status()
        try:
            from ..helpers import ux  # noqa: PLC0415
            lvl_note = "⚠ autonomous" if level == "autonomous" else level
            ux.notify(f"✓ {cid}: {lvl_note}",
                      ux.LEVEL_INFO if level == "autonomous" else ux.LEVEL_OK)
        except Exception:
            pass

    def _refresh_status(self) -> None:
        auton = sum(1 for v in self._levels.values() if v == "autonomous")
        if auton:
            self._status.set_markup(
                f'<span foreground="#ffb300">{auton} class(es) set to autonomous — '
                "these will act without asking.</span>"
            )
        else:
            self._status.set_markup(
                '<span foreground="#9aa0a6">No class is fully autonomous.</span>'
            )


def build_section() -> Gtk.Widget:
    """Return the Auto-Healing tab (per-class autonomy authority — W10-6)."""
    return _AutoHealingWidget().box
