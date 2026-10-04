"""
Orion-X Control Center — Situational Awareness (W10-5 working core).

Two live surfaces, both refreshed on a GLib timer (no threads — the Control
Center stays stdlib + gi only):

  1. LIVE HEALTH MONITOR — at-a-glance system + service health for the operator's
     3am self: CPU load, memory, disk, uptime, and the state of the units that
     matter (Nebula runtime, network, WireGuard mesh, firewall). Each row is
     colour-coded green / amber / red.

  2. THREAT POSTURE — the tier selector from the W10-5 design (Tier 0 Passive /
     Tier 1 Active Monitoring / Tier 2 Deception). Selecting a tier persists it
     to ~/.config/orionx/threat-posture so the (follow-up) detection daemon can
     read it. Tier 2 (deception: canaries/honeytokens/tarpits) requires explicit
     operator opt-in per DEC-PHASE9-008.

The AI-augmented detection daemon itself (Suricata + ET rules → Nebula
contextualizer → ATT&CK mapping) is the XL remainder of W10-5 and is tracked
separately; this module lands the operator-facing surfaces + posture authority.

@decision DEC-PHASE10-005
@title W10-5 Awareness: live health monitor + threat-posture tier selector
@status accepted
@rationale Phase 9 W9-2 locked this section as a plug-in surface. W10-5 fills it
  with (a) the live health monitor the operator asked for and (b) the tier
  selector that is the single authority for threat posture (persisted to
  ~/.config/orionx/threat-posture). The detection daemon plugs into that posture
  file later. Reads go through subprocess/‑proc only; no privileged calls, no
  third-party imports (test_control_center.sh import invariant).

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # type: ignore[import]  # noqa: E402

# Live-health refresh cadence (ms).
_POLL_MS = 3000

# Threat-posture state file — single authority, user-writable (no sudo).
_POSTURE_FILE = Path.home() / ".config" / "orionx" / "threat-posture"

# R.A.I.N. config authority (mirrors scripts/rain/rain_lib.py; DEC-PHASE11-045).
# The Control Center is held to a strict import allowlist, so it cannot import
# rain_lib — it reads/writes this JSON directly and EMITS events by shelling out
# to the `orionx-event` CLI (subprocess, non-blocking).
_RAIN_CONFIG = Path.home() / ".config" / "orionx" / "rain.json"
_RAIN_SEVERITIES = ("info", "notice", "warning", "critical")


def _emit_event(severity: str, source: str, category: str, message: str) -> None:
    """Publish an event onto the Orion-X event bus (heard via R.A.I.N.).

    Fire-and-forget: the Control Center must never block or crash on the emitter
    being absent (e.g. running outside the ISO). Non-blocking Popen, output
    discarded — RAIN reacts to the bus, this call just writes to it.
    """
    try:
        subprocess.Popen(
            ["orionx-event", "--severity", severity, "--source", source,
             "--category", category, message],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except OSError:
        pass


def _load_rain() -> dict:
    """Load rain.json over defaults; tolerant of missing/corrupt file.

    Keys this panel does not know about are carried through untouched. The
    authority for rain.json's schema is scripts/rain/rain_lib.py, and this
    panel owns only the widgets below — it must not act as a second authority
    that silently drops whatever R.A.I.N. adds next (RESILIENCE rule 7). It
    did exactly that to "speech" (DEC-PHASE12-046) before this change.
    """
    cfg = {"enabled": True, "min_severity": "warning", "volume": 0.8,
           "voice": False, "speech": False}
    try:
        with _RAIN_CONFIG.open(encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            cfg.update(data)
    except (OSError, ValueError):
        pass
    if cfg["min_severity"] not in _RAIN_SEVERITIES:
        cfg["min_severity"] = "warning"
    return cfg


def _save_rain(cfg: dict) -> None:
    try:
        _RAIN_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        with _RAIN_CONFIG.open("w", encoding="utf-8") as fh:
            json.dump(cfg, fh, indent=2, sort_keys=True)
    except OSError:
        pass

# Tier id -> (label, description). Ids are what get persisted.
_TIERS = [
    ("0", "Tier 0 · Passive",
     "Quiet monitoring only — passive host/network observation, no active probing."),
    ("1", "Tier 1 · Active Monitoring",
     "IDS-style detection (Suricata + rules) with Nebula contextualising alerts."),
    ("2", "Tier 2 · Deception",
     "Canaries / honeytokens / tarpits. Explicit opt-in (DEC-PHASE9-008)."),
]

# Colour markup helpers (Pango).
_GREEN = "#34ff9e"
_AMBER = "#ffb300"
_RED = "#ff6a4a"
_DIM = "#9aa0a6"


def _color(text: str, hexcol: str) -> str:
    return f'<span foreground="{hexcol}">{text}</span>'


# Health probes that raise an audible event when they go unhealthy (R.A.I.N.).
# name -> severity emitted on a healthy->degraded transition. Edge-triggered off a
# baseline established on the first poll, so normal boot-time flapping is silent.
_ALERTABLE = {"Nebula AI": "critical", "Firewall": "warning"}


# ---------------------------------------------------------------------------
# Health probes — all best-effort, all non-privileged.
# ---------------------------------------------------------------------------

def _loadavg() -> tuple[str, str]:
    """Return (value, color) for the 1/5/15 load average."""
    try:
        parts = Path("/proc/loadavg").read_text().split()
        one = float(parts[0])
        ncpu = os.cpu_count() or 1
        ratio = one / ncpu
        col = _GREEN if ratio < 0.7 else _AMBER if ratio < 1.2 else _RED
        return f"{parts[0]} {parts[1]} {parts[2]}  ({ncpu} cpu)", col
    except (OSError, ValueError, IndexError):
        return "n/a", _DIM


def _memory() -> tuple[str, str]:
    """Return (value, color) for memory usage from /proc/meminfo."""
    try:
        info: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, _, v = line.partition(":")
            info[k.strip()] = int(v.strip().split()[0])  # kB
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", info.get("MemFree", 0))
        if total <= 0:
            return "n/a", _DIM
        used_pct = int((total - avail) * 100 / total)
        gb = 1024 * 1024
        col = _GREEN if used_pct < 70 else _AMBER if used_pct < 88 else _RED
        return f"{used_pct}%  ({(total - avail) / gb:.1f} / {total / gb:.1f} GB)", col
    except (OSError, ValueError):
        return "n/a", _DIM


def _disk() -> tuple[str, str]:
    """Return (value, color) for used space on / via statvfs."""
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total <= 0:
            return "n/a", _DIM
        used_pct = int((total - free) * 100 / total)
        gb = 1000 ** 3
        col = _GREEN if used_pct < 80 else _AMBER if used_pct < 92 else _RED
        return f"{used_pct}%  ({(total - free) / gb:.1f} / {total / gb:.1f} GB)", col
    except OSError:
        return "n/a", _DIM


def _uptime() -> tuple[str, str]:
    try:
        secs = float(Path("/proc/uptime").read_text().split()[0])
        d, rem = divmod(int(secs), 86400)
        h, rem = divmod(rem, 3600)
        m, _ = divmod(rem, 60)
        parts = (f"{d}d " if d else "") + f"{h}h {m}m"
        return parts, _DIM
    except (OSError, ValueError):
        return "n/a", _DIM


def _svc_active(unit: str) -> bool:
    """True if systemctl reports the unit active (no sudo needed for is-active)."""
    try:
        out = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True, text=True, timeout=4,
        )
        return out.stdout.strip() == "active"
    except (OSError, subprocess.TimeoutExpired):
        return False


def _nebula_health() -> tuple[str, str]:
    if _svc_active("nebula-runtime.service"):
        return "running", _GREEN
    return "down (start it in Nebula AI tab)", _RED


def _network_health() -> tuple[str, str]:
    try:
        out = subprocess.run(
            ["nmcli", "-t", "-f", "NAME,STATE", "connection", "show", "--active"],
            capture_output=True, text=True, timeout=4,
        )
        conns = [ln.split(":")[0] for ln in out.stdout.splitlines() if ln.strip()]
        if conns:
            return f"{len(conns)} active: {', '.join(conns[:2])}", _GREEN
        return "no active connection", _AMBER
    except (OSError, subprocess.TimeoutExpired):
        return "n/a", _DIM


def _mesh_health() -> tuple[str, str]:
    # wg0 present = joined; absent = not joined (offline-friendly, no sudo).
    if Path("/sys/class/net/wg0").exists():
        return "wg0 up (mesh joined)", _GREEN
    return "not joined", _AMBER


def _firewall_health() -> tuple[str, str]:
    if _svc_active("orionx-firewall.service"):
        return "active", _GREEN
    return "inactive", _AMBER


class _AwarenessWidget:
    """Live health monitor + threat-posture selector."""

    def __init__(self) -> None:
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.set_border_width(12)

        title = Gtk.Label()
        title.set_markup("<b>Situational Awareness</b>")
        title.set_halign(Gtk.Align.START)
        self.box.pack_start(title, False, False, 0)

        # --- Live health monitor ---
        hdr = Gtk.Label()
        hdr.set_markup("<b>Live health</b>")
        hdr.set_halign(Gtk.Align.START)
        self.box.pack_start(hdr, False, False, 2)

        grid = Gtk.Grid()
        grid.set_column_spacing(12)
        grid.set_row_spacing(3)
        self.box.pack_start(grid, False, False, 0)

        # (row label, probe fn) — value labels are created and refreshed in place.
        self._probes = [
            ("CPU load", _loadavg),
            ("Memory", _memory),
            ("Disk /", _disk),
            ("Uptime", _uptime),
            ("Nebula AI", _nebula_health),
            ("Network", _network_health),
            ("Mesh", _mesh_health),
            ("Firewall", _firewall_health),
        ]
        # Edge-trigger state for R.A.I.N. service alerts (baseline on first poll).
        self._svc_prev: dict[str, bool] = {}

        self._value_labels: list[Gtk.Label] = []
        for i, (name, _fn) in enumerate(self._probes):
            key = Gtk.Label()
            key.set_markup(f'<span foreground="{_DIM}">{name}</span>')
            key.set_halign(Gtk.Align.START)
            val = Gtk.Label(label="…")
            val.set_halign(Gtk.Align.START)
            val.set_selectable(True)
            grid.attach(key, 0, i, 1, 1)
            grid.attach(val, 1, i, 1, 1)
            self._value_labels.append(val)

        self._refresh_health()
        GLib.timeout_add(_POLL_MS, self._refresh_health)

        self.box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL),
                            False, False, 6)

        # --- Threat posture ---
        phdr = Gtk.Label()
        phdr.set_markup("<b>Threat posture</b>")
        phdr.set_halign(Gtk.Align.START)
        self.box.pack_start(phdr, False, False, 2)

        current = self._load_posture()
        self._posture_status = Gtk.Label()
        self._posture_status.set_halign(Gtk.Align.START)
        self._posture_status.set_line_wrap(True)

        group: Gtk.RadioButton | None = None
        for tier_id, label, desc in _TIERS:
            rb = Gtk.RadioButton.new_with_label_from_widget(group, label)
            if group is None:
                group = rb
            rb.set_tooltip_text(desc)
            if tier_id == current:
                rb.set_active(True)
            rb.connect("toggled", self._on_tier_toggled, tier_id, desc)
            self.box.pack_start(rb, False, False, 0)

        self.box.pack_start(self._posture_status, False, False, 4)
        self._show_posture(current)

        # --- R.A.I.N. (audible alerts) ---
        self.box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL),
                            False, False, 6)
        self._build_rain_controls()

    # ------------------------------------------------------------------

    def _build_rain_controls(self) -> None:
        """Audible-alert (R.A.I.N.) controls, persisted to ~/.config/orionx/rain.json."""
        cfg = _load_rain()

        rhdr = Gtk.Label()
        rhdr.set_markup("<b>Audible alerts · R.A.I.N.</b>")
        rhdr.set_halign(Gtk.Align.START)
        self.box.pack_start(rhdr, False, False, 2)

        sub = Gtk.Label()
        sub.set_markup(_color(
            "Hear intrusions without watching the screen — for your 3am self.", _DIM))
        sub.set_halign(Gtk.Align.START)
        self.box.pack_start(sub, False, False, 0)

        # Enable toggle.
        self._rain_enable = Gtk.CheckButton(label="Enable audible alerts")
        self._rain_enable.set_active(bool(cfg["enabled"]))
        self._rain_enable.connect("toggled", self._on_rain_changed)
        self.box.pack_start(self._rain_enable, False, False, 2)

        # Minimum severity.
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        mlbl = Gtk.Label(label="Alert from severity:")
        mlbl.set_halign(Gtk.Align.START)
        self._rain_sev = Gtk.ComboBoxText()
        for sev in _RAIN_SEVERITIES:
            self._rain_sev.append(sev, sev.capitalize())
        self._rain_sev.set_active_id(cfg["min_severity"])
        self._rain_sev.connect("changed", self._on_rain_changed)
        row.pack_start(mlbl, False, False, 0)
        row.pack_start(self._rain_sev, False, False, 0)
        self.box.pack_start(row, False, False, 2)

        # Volume.
        vrow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vlbl = Gtk.Label(label="Volume:")
        self._rain_vol = Gtk.Scale.new_with_range(
            Gtk.Orientation.HORIZONTAL, 0, 100, 5)
        self._rain_vol.set_value(max(0, min(100, int(float(cfg["volume"]) * 100))))
        self._rain_vol.set_hexpand(True)
        self._rain_vol.set_draw_value(True)
        self._rain_vol.connect("value-changed", self._on_rain_changed)
        vrow.pack_start(vlbl, False, False, 0)
        vrow.pack_start(self._rain_vol, True, True, 0)
        self.box.pack_start(vrow, False, False, 2)

        # Voice cue toggle + Test button.
        brow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self._rain_voice = Gtk.CheckButton(label="Spoken voice cue")
        self._rain_voice.set_active(bool(cfg["voice"]))
        self._rain_voice.connect("toggled", self._on_rain_changed)
        # DEC-PHASE12-046. Off by default and deliberately labelled with the
        # consequence: speech is intelligible to everyone within earshot, a
        # tone is not. It narrates AFTER the cue and never delays it.
        self._rain_speech = Gtk.CheckButton(label="Narrate alerts aloud")
        self._rain_speech.set_active(bool(cfg.get("speech", False)))
        self._rain_speech.set_tooltip_text(
            "Speak a one-sentence description after the alert tone. "
            "Audible to everyone in the room — the tone is not."
        )
        self._rain_speech.connect("toggled", self._on_rain_changed)
        test_btn = Gtk.Button(label="Test alert")
        test_btn.connect("clicked", self._on_rain_test)
        brow.pack_start(self._rain_voice, False, False, 0)
        brow.pack_start(self._rain_speech, False, False, 0)
        brow.pack_start(test_btn, False, False, 0)
        self.box.pack_start(brow, False, False, 2)

    def _refresh_health(self) -> bool:
        for label, (name, fn) in zip(self._value_labels, self._probes):
            try:
                value, color = fn()
            except Exception:  # a probe must never kill the poller
                value, color = "n/a", _DIM
            label.set_markup(_color(GLib.markup_escape_text(value), color))
            self._maybe_alert(name, value, color)
        return True  # keep polling

    def _maybe_alert(self, name: str, value: str, color: str) -> None:
        """Emit a R.A.I.N. event when an alertable service changes health state.

        Edge-triggered against a baseline captured on the first poll, so a service
        that is merely still warming up at startup does not sound an alarm.
        """
        if name not in _ALERTABLE:
            return
        healthy = color == _GREEN
        prev = self._svc_prev.get(name)
        self._svc_prev[name] = healthy
        if prev is None:
            return  # baseline poll — establish state, stay silent
        if prev and not healthy:
            _emit_event(_ALERTABLE[name], "health", "service",
                        f"{name} degraded: {value}")
        elif healthy and not prev:
            _emit_event("notice", "health", "service", f"{name} recovered: {value}")

    def _load_posture(self) -> str:
        try:
            val = _POSTURE_FILE.read_text(encoding="utf-8").strip()
            return val if val in ("0", "1", "2") else "0"
        except OSError:
            return "0"

    def _show_posture(self, tier_id: str) -> None:
        label = next((lbl for tid, lbl, _d in _TIERS if tid == tier_id), "unknown")
        self._posture_status.set_markup(
            _color(f"Current posture: {GLib.markup_escape_text(label)}", _AMBER)
        )

    def _on_tier_toggled(self, rb: Gtk.RadioButton, tier_id: str, desc: str) -> None:
        if not rb.get_active():
            return
        try:
            _POSTURE_FILE.parent.mkdir(parents=True, exist_ok=True)
            _POSTURE_FILE.write_text(tier_id + "\n", encoding="utf-8")
        except OSError:
            pass
        self._show_posture(tier_id)
        # Announce the posture change on the event bus (heard via R.A.I.N.).
        label = next((lbl for tid, lbl, _d in _TIERS if tid == tier_id), tier_id)
        _emit_event("warning" if tier_id == "2" else "notice", "posture", "posture",
                    f"Threat posture changed to {label}")
        # Toast via the shared UX sink if available.
        try:
            from ..helpers import ux  # noqa: PLC0415
            note = "⚠ Tier 2 Deception armed — opt-in assets active" if tier_id == "2" \
                else f"✓ Threat posture set: {desc.split('—')[0].strip()}"
            ux.notify(note, ux.LEVEL_OK if tier_id != "2" else ux.LEVEL_INFO)
        except Exception:
            pass

    def _on_rain_changed(self, _widget: Gtk.Widget) -> None:
        """Persist the R.A.I.N. config; the daemon re-reads rain.json live."""
        cfg = _load_rain()          # keep keys this panel does not own
        cfg.update({
            "enabled": self._rain_enable.get_active(),
            "min_severity": self._rain_sev.get_active_id() or "warning",
            "volume": round(self._rain_vol.get_value() / 100.0, 2),
            "voice": self._rain_voice.get_active(),
            "speech": self._rain_speech.get_active(),
        })
        _save_rain(cfg)

    def _on_rain_test(self, _btn: Gtk.Button) -> None:
        """Play a sample cue so the operator can set the volume by ear."""
        self._on_rain_changed(_btn)  # save first so the test honours current volume
        try:
            subprocess.Popen(
                ["orionx-rain", "--test", "warning"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass
        try:
            from ..helpers import ux  # noqa: PLC0415
            ux.notify("🔊 R.A.I.N. test alert played", ux.LEVEL_INFO)
        except Exception:
            pass


def build_section() -> Gtk.Widget:
    """Return the Situational Awareness section (live health + threat posture)."""
    return _AwarenessWidget().box
