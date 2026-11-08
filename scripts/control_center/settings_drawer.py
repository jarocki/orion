"""
Orion Cockpit — the settings drawer: the environment controls, in one place (#95).

Threat posture, R.A.I.N. (tone, voice, narration, volume), display (theme)
and the DJ deck. It slides in from the right of the Cockpit on every tab
(the Settings button in the status row, or F2), so changing what the deck
enforces or sounds never means leaving what it shows.

Writers, one per file (tests/unit/test_settings_writers.sh enforces it):
  - ~/.config/orionx/threat-posture: posture_data.request_tier()
  - ~/.config/orionx/rain.json: rain_lib.save_config() (orionx-rain's own)
  - the theme: toggle-theme.sh, run in a visible terminal (its own report)
  - ~/.config/orionx/music.json: orionx_synth.save_config(), via the DJ deck
This module calls those; it writes no file itself.

The controls and their behaviour moved here unchanged from the Awareness and
Orion Tools tabs: selecting a tier is a request that only orionx-postured's
status confirms (DEC-PHASE12-070); a write that fails reverts the control and
says why (DEC-PHASE12-069); every R.A.I.N. save keeps the keys it does not own
(DEC-PHASE12-046).

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

# @decision DEC-PHASE13-048
# @title Cockpit = the immediate environment, Workbench = the analyst's toolbox; one writer per settings file
# @status accepted
# @rationale Operator decision 2026-10-05 (#95). Three windows each owning a
#   slice of "settings" is how dual-authority bugs start, so every control has
#   one home, chosen by what it changes. A control that changes what this deck
#   enforces, sounds or shows (threat posture, R.A.I.N. tone and voice, the DJ
#   deck, the display theme) belongs to the Cockpit, in this drawer, because
#   the operator changes them while watching. A control that tunes a tool
#   (auto-healing consent, Nebula warm-up, optional installers) belongs to the
#   Workbench. Each settings file under ~/.config/orionx has exactly one
#   function that writes it; every surface that changes it calls that function
#   or runs the command that does. test_settings_writers.sh resolves the path
#   constants and fails when a file gains a second writer, or when a new
#   settings file appears without a declared writer.

import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # type: ignore[import]  # noqa: E402

from .helpers import posture_data as P  # noqa: E402
from .helpers import settings_io as S  # noqa: E402
from .helpers import style, ux  # noqa: E402
from .helpers.background import run_async  # noqa: E402
from .helpers.tools_data import THEME_ARGV  # noqa: E402

_RAIN_DIR = Path(__file__).resolve().parents[1] / "rain"
if str(_RAIN_DIR) not in sys.path:
    sys.path.insert(0, str(_RAIN_DIR))
import rain_lib  # noqa: E402  (rain.json schema + save: the one authority)

WIDTH = 380            # px; fits beside LIVE's panels on the 1366 px reference deck
_GREEN = "#34ff9e"
_AMBER = "#ffb300"
_RED = "#ff6a4a"
_DIM = "#9aa0a6"
_LEVEL_COLOR = {"ok": _GREEN, "info": _AMBER, "error": _RED}

# Tier id -> (label, description). Ids are what get persisted.
_TIERS = [
    ("0", P.TIER_LABEL["0"],
     "Quiet monitoring only — passive host/network observation, no active probing."),
    ("1", P.TIER_LABEL["1"],
     "IDS-style detection (Suricata + rules) with Nebula contextualising alerts."),
    ("2", P.TIER_LABEL["2"],
     "Canaries / honeytokens / tarpits. Explicit opt-in (DEC-PHASE9-008)."),
]


def _color(text: str, hexcol: str) -> str:
    return f'<span foreground="{hexcol}">{text}</span>'


def _label(text: str = "", markup: bool = False, selectable: bool = False) -> Gtk.Label:
    lbl = Gtk.Label()
    if markup:
        lbl.set_markup(text)
    else:
        lbl.set_text(text)
    lbl.set_halign(Gtk.Align.START)
    lbl.set_xalign(0.0)
    lbl.set_line_wrap(True)
    lbl.set_max_width_chars(44)
    lbl.set_selectable(selectable)
    return lbl


def rain_summary(cfg: dict) -> str:
    if not cfg.get("enabled"):
        return "R.A.I.N.: audible alerts OFF"
    parts = [f"alerts from {cfg.get('min_severity')}", f"volume {round(float(cfg.get('volume', 0)) * 100)}%"]
    if cfg.get("voice"):
        parts.append("voice cue on")
    if cfg.get("speech"):
        parts.append("narration on")
    return "R.A.I.N.: " + ", ".join(parts)


def rain_test_outcome(rc: int | None, stdout: str, stderr: str, err: str = "") -> tuple[bool, str]:
    """Plain-language result of `orionx-rain --test warning`. Pure."""
    last = (stderr or stdout or "").strip().splitlines()
    tail = last[-1][:140] if last else ""
    if err:
        return False, f"✗ R.A.I.N. test did not run: {err}"
    if rc == 0:
        return True, ("🔊 R.A.I.N. played the warning cue (orionx-rain exit 0). Heard nothing? "
                      "Check the volume, then: paplay /usr/share/orionx/rain/warning.wav")
    return False, f"✗ R.A.I.N. test failed (exit {rc})" + (f": {tail}" if tail else "")


class SettingsDrawer:
    """The drawer's content: a page box the Cockpit skins like a tab (DEC-PHASE13-019)."""

    TITLE = "Settings"

    def __init__(self) -> None:
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.get_style_context().add_class(style.PAGE)
        title = Gtk.Label(label=self.TITLE)
        title.get_style_context().add_class(style.PANEL_TITLE)
        title.set_halign(Gtk.Align.START)
        self.box.pack_start(title, False, False, 0)
        self.box.pack_start(_label(
            "What this deck enforces, sounds and shows. Tool settings (auto-healing "
            "consent, Nebula warm-up, optional installers) are on the Workbench."), False, False, 0)
        wb = Gtk.Button(label="Open the Workbench")
        wb.get_style_context().add_class("orionx-tool")
        wb.set_halign(Gtk.Align.START)
        wb.set_tooltip_text("orionx-osint: the analyst's toolbox, with its Engine section")
        wb.connect("clicked", lambda _b: ux.launch_detached(["orionx-osint"], friendly="the Workbench"))
        self.box.pack_start(wb, False, False, 2)
        self._build_posture()
        self._build_rain()
        self._build_display()
        self._build_dj()
        # The tick re-reads postured's status (a cheap file read) and toasts the
        # verdict on a fresh request; it dies with the widget, so a destroyed
        # drawer cannot toast into whatever window owns the notifier next.
        self._tick_id = GLib.timeout_add(1000, self._posture_tick)
        self.box.connect("destroy", self._on_destroy)

    def _on_destroy(self, _w) -> None:
        if self._tick_id:
            GLib.source_remove(self._tick_id)
            self._tick_id = 0

    def _sep(self) -> None:
        self.box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

    # ----------------------------------------------------------------- posture
    def _build_posture(self) -> None:
        self._sep()
        self.box.pack_start(style.heading("<b>Threat posture</b>"), False, False, 2)
        current = P.load_request()
        self._requested = current
        try:
            self._requested_at = P.REQUEST_FILE.stat().st_mtime
        except OSError:
            self._requested_at = 0.0
        self._announced = True        # the startup state is not a fresh request
        self._posture_status = _label(selectable=True)
        self._radios: dict[str, Gtk.RadioButton] = {}
        self._reverting = False
        group: Gtk.RadioButton | None = None
        for tier_id, label, desc in _TIERS:
            rb = Gtk.RadioButton.new_with_label_from_widget(group, label)
            if group is None:
                group = rb
            rb.set_tooltip_text(desc)
            if tier_id == current:
                rb.set_active(True)
            rb.connect("toggled", self._on_tier_toggled, tier_id)
            self._radios[tier_id] = rb
            self.box.pack_start(rb, False, False, 0)
        self.box.pack_start(self._posture_status, False, False, 4)
        self._show_posture()

    def _show_posture(self) -> dict:
        """Requested vs enforced, from postured's status file (cheap file read)."""
        v = P.verdict(self._requested, P.read_status(), self._requested_at, time.time())
        self._posture_status.set_markup(_color(GLib.markup_escape_text(v["text"]), _LEVEL_COLOR[v["level"]]))
        return v

    def _posture_tick(self) -> bool:
        v = self._show_posture()
        if not self._announced and v["state"] != "pending":
            self._announced = True
            ux.notify(v["text"], v["level"])
        return True

    def _on_tier_toggled(self, rb: Gtk.RadioButton, tier_id: str) -> None:
        if not rb.get_active() or self._reverting:
            return
        ok, err = P.request_tier(tier_id)
        if not ok:
            # The request never reached postured: say so and put the control back.
            self._reverting = True
            self._radios[self._requested].set_active(True)
            self._reverting = False
            ux.notify(f"✗ Threat posture NOT changed — could not write {err}", ux.LEVEL_ERROR)
            return
        self._requested, self._requested_at, self._announced = tier_id, time.time(), False
        label = P.TIER_LABEL[tier_id]
        ux.emit_event("warning" if tier_id == "2" else "notice", "posture", "posture",
                      f"Threat posture change requested: {label}")
        v = self._show_posture()
        ux.notify(f"{v['text']}  ·  {S.reboot_line()}", ux.LEVEL_INFO)

    # ----------------------------------------------------------------- R.A.I.N.
    def _build_rain(self) -> None:
        """Audible-alert controls; rain_lib owns rain.json's schema and its save."""
        self._sep()
        cfg = rain_lib.load_config()
        self.box.pack_start(style.heading("<b>Audible alerts · R.A.I.N.</b>"), False, False, 2)
        self.box.pack_start(_label(_color("Hear intrusions without watching the screen.", _DIM), markup=True),
                            False, False, 0)

        self._rain_enable = Gtk.CheckButton(label="Enable audible alerts")
        self._rain_enable.set_active(bool(cfg["enabled"]))
        self._rain_enable.connect("toggled", self._on_rain_changed)
        self.box.pack_start(self._rain_enable, False, False, 2)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.pack_start(Gtk.Label(label="Alert from severity:"), False, False, 0)
        self._rain_sev = Gtk.ComboBoxText()
        for sev in rain_lib.SEVERITIES:
            self._rain_sev.append(sev, sev.capitalize())
        self._rain_sev.set_active_id(cfg["min_severity"])
        self._rain_sev.connect("changed", self._on_rain_changed)
        row.pack_start(self._rain_sev, False, False, 0)
        self.box.pack_start(row, False, False, 2)

        vrow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vrow.pack_start(Gtk.Label(label="Volume:"), False, False, 0)
        self._rain_vol = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 5)
        self._rain_vol.set_value(max(0, min(100, int(float(cfg["volume"]) * 100))))
        self._rain_vol.set_hexpand(True)
        self._rain_vol.set_draw_value(True)
        self._rain_vol.connect("value-changed", self._on_rain_changed)
        vrow.pack_start(self._rain_vol, True, True, 0)
        self.box.pack_start(vrow, False, False, 2)

        self._rain_voice = Gtk.CheckButton(label="Spoken voice cue")
        self._rain_voice.set_active(bool(cfg["voice"]))
        # UX-13: say how this differs from narration.
        self._rain_voice.set_tooltip_text(
            "Speak a short fixed phrase with each tone (for example \"Warning. Suspicious "
            "activity.\"). It never says what the alert was — that is narration.")
        self._rain_voice.connect("toggled", self._on_rain_changed)
        self.box.pack_start(self._rain_voice, False, False, 0)
        # DEC-PHASE12-046. Off by default and labelled with the consequence.
        self._rain_speech = Gtk.CheckButton(label="Narrate alerts aloud")
        self._rain_speech.set_active(bool(cfg.get("speech", False)))
        self._rain_speech.set_tooltip_text(
            "Speak a one-sentence description of the alert after the tone. "
            "Audible to everyone in the room — the tone is not."
        )
        self._rain_speech.connect("toggled", self._on_rain_changed)
        self.box.pack_start(self._rain_speech, False, False, 0)
        self._test_btn = Gtk.Button(label="Test alert")
        self._test_btn.set_halign(Gtk.Align.START)
        self._test_btn.connect("clicked", self._on_rain_test)
        self.box.pack_start(self._test_btn, False, False, 2)
        self._rain_timer = 0

    def _rain_cfg_from_widgets(self) -> dict:
        cfg = rain_lib.load_config()   # keeps every key these widgets do not own
        cfg.update({
            "enabled": self._rain_enable.get_active(),
            "min_severity": self._rain_sev.get_active_id() or "warning",
            "volume": round(self._rain_vol.get_value() / 100.0, 2),
            "voice": self._rain_voice.get_active(),
            "speech": self._rain_speech.get_active(),
        })
        return cfg

    def _save_rain(self) -> bool:
        cfg = self._rain_cfg_from_widgets()
        if rain_lib.save_config(cfg):
            ux.notify(f"✓ {rain_summary(cfg)} — {S.reboot_line()}", ux.LEVEL_OK)
            return True
        ux.notify(f"✗ R.A.I.N. settings NOT saved — could not write {rain_lib.CONFIG_FILE}", ux.LEVEL_ERROR)
        return False

    def _on_rain_changed(self, _widget: Gtk.Widget) -> None:
        """Persist after the slider settles (one toast, not one per step)."""
        if self._rain_timer:
            GLib.source_remove(self._rain_timer)

        def _fire() -> bool:
            self._rain_timer = 0
            self._save_rain()
            return False
        self._rain_timer = GLib.timeout_add(600, _fire)

    def _on_rain_test(self, _btn: Gtk.Button | None) -> None:
        """Play a sample cue; report what actually happened (UX-12)."""
        if self._rain_timer:
            GLib.source_remove(self._rain_timer)
            self._rain_timer = 0
        if not self._save_rain():
            return
        self._test_btn.set_sensitive(False)
        ux.notify("R.A.I.N. test: playing the warning cue…", ux.LEVEL_INFO)

        def _work():
            try:
                r = subprocess.run(["orionx-rain", "--test", "warning"], capture_output=True,
                                   text=True, timeout=8)
                return rain_test_outcome(r.returncode, r.stdout, r.stderr)
            except FileNotFoundError:
                return rain_test_outcome(None, "", "", "orionx-rain is not installed")
            except subprocess.TimeoutExpired:
                return rain_test_outcome(None, "", "", "orionx-rain did not finish within 8 s")

        def _done(res, err) -> None:
            self._test_btn.set_sensitive(True)
            ok, msg = res if err is None else (False, f"✗ R.A.I.N. test failed: {err}")
            ux.notify(msg, ux.LEVEL_INFO if ok else ux.LEVEL_ERROR)

        run_async(_work, _done)

    # ----------------------------------------------------------------- display
    def _build_display(self) -> None:
        self._sep()
        self.box.pack_start(style.heading("<b>Display</b>"), False, False, 2)
        self.box.pack_start(_label(
            "Theme: amber ↔ green — wallpaper, GTK accent, window frames, terminal and prompt. "
            "The toggle shows its own report, then a new terminal in the new palette."), False, False, 0)
        btn = Gtk.Button(label="Toggle theme")
        btn.get_style_context().add_class("orionx-tool")
        btn.set_halign(Gtk.Align.START)
        btn.connect("clicked", lambda _b: ux.launch_in_terminal(
            THEME_ARGV, needs="toggle-theme.sh", friendly="Toggle Theme",
            title="Orion-X theme — toggle report", own_process=True,
            done_note="its report says what changed; a second window opens in the new palette"))
        self.box.pack_start(btn, False, False, 2)

    # ----------------------------------------------------------------- DJ deck
    def _build_dj(self) -> None:
        self._sep()
        self.box.pack_start(style.heading("<b>DJ deck</b>"), False, False, 2)
        self.box.pack_start(_label(
            "The generative music bed. It ducks for every R.A.I.N. alert; its faders and "
            "patterns live in the deck (~/.config/orionx/music.json)."), False, False, 0)
        btn = Gtk.Button(label="Open DJ Deck")
        btn.get_style_context().add_class("orionx-tool")
        btn.set_halign(Gtk.Align.START)
        btn.connect("clicked", lambda _b: ux.launch_detached(["orionx-dj"], friendly="DJ Deck"))
        self.box.pack_start(btn, False, False, 2)


def build_drawer() -> tuple[Gtk.Revealer, SettingsDrawer, Gtk.ScrolledWindow]:
    """(revealer, drawer, scroller): the drawer page in a vertical-only scroller, hidden."""
    drawer = SettingsDrawer()
    scrolled = Gtk.ScrolledWindow()
    scrolled.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scrolled.set_size_request(WIDTH, -1)
    scrolled.add(drawer.box)
    rev = Gtk.Revealer()
    rev.set_transition_type(Gtk.RevealerTransitionType.SLIDE_LEFT)
    rev.set_transition_duration(150)
    rev.add(scrolled)
    rev.set_reveal_child(False)
    return rev, drawer, scrolled
