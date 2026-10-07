"""
Orion Cockpit — Awareness tab: live health, trends, threat posture, R.A.I.N.

Surfaces:

  1. LIVE HEALTH — CPU load, memory, disk, uptime, and the units that matter
     (Nebula runtime, network, WireGuard mesh, firewall), colour-coded.
  2. TRENDS — packets/s, CPU, memory, disk sparklines (DEC-PHASE12-056).
  3. THREAT POSTURE — the tier selector (Tier 0 Passive / Tier 1 Active
     Monitoring / Tier 2 Deception). Selecting a tier writes
     ~/.config/orionx/threat-posture; orionx-postured (root) enforces it and
     reports what it actually enforces in /run/orionx/posture-status.json.
     The tab says "requested" until that file confirms (DEC-PHASE12-070).
  4. R.A.I.N. — audible-alert settings, through rain_lib (its own authority).

Probes run in a worker thread (helpers/background, DEC-PHASE12-068). Only the
two alertable service probes keep running while the tab is hidden, so a
degraded firewall still sounds while the operator watches LIVE.

@decision DEC-PHASE10-005
@title W10-5 Awareness: live health monitor + threat-posture tier selector
@status accepted
@rationale Phase 9 W9-2 locked this section as a plug-in surface. W10-5 fills it
  with (a) the live health monitor the operator asked for and (b) the tier
  selector that is the single authority for the REQUESTED threat posture
  (persisted to ~/.config/orionx/threat-posture). Enforcement truth is
  orionx-postured's status file. No privileged calls, no third-party imports
  (test_control_center.sh import invariant).

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # type: ignore[import]  # noqa: E402

from ..helpers import mesh_data as M  # noqa: E402
from ..helpers import posture_data as P  # noqa: E402
from ..helpers import settings_io as S  # noqa: E402
from ..helpers import ux  # noqa: E402
from ..helpers.background import Poller, run_async  # noqa: E402

# python.md P2-3: import once. Inserting into sys.path on every probe grew it
# by one entry per call (~130k a day).
_SCRIPTS = Path(__file__).resolve().parents[2]
for _sub in ("awareness", "rain"):
    if str(_SCRIPTS / _sub) not in sys.path:
        sys.path.insert(0, str(_SCRIPTS / _sub))
import deck_vitals as _V  # noqa: E402
import rain_lib  # noqa: E402  (rain.json schema + atomic save: the one authority)

# Live-health refresh cadence (ms).
_POLL_MS = 3000

# Threat-posture REQUEST file — user-writable, read by orionx-postured.
_POSTURE_FILE = Path.home() / ".config" / "orionx" / "threat-posture"
_RAIN_SEVERITIES = rain_lib.SEVERITIES


def _emit_event(severity: str, source: str, category: str, message: str) -> None:
    """Publish an event onto the Orion-X event bus (heard via R.A.I.N.). Non-blocking."""
    try:
        subprocess.Popen(
            ["orionx-event", "--severity", severity, "--source", source,
             "--category", category, message],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        print(f"awareness: could not publish to the bus: {exc}", file=sys.stderr)


# Tier id -> (label, description). Ids are what get persisted.
_TIERS = [
    ("0", P.TIER_LABEL["0"],
     "Quiet monitoring only — passive host/network observation, no active probing."),
    ("1", P.TIER_LABEL["1"],
     "IDS-style detection (Suricata + rules) with Nebula contextualising alerts."),
    ("2", P.TIER_LABEL["2"],
     "Canaries / honeytokens / tarpits. Explicit opt-in (DEC-PHASE9-008)."),
]

# Colour markup helpers (Pango).
_GREEN = "#34ff9e"
_AMBER = "#ffb300"
_RED = "#ff6a4a"
_DIM = "#9aa0a6"
_LEVEL_COLOR = {"ok": _GREEN, "info": _AMBER, "error": _RED}


def _color(text: str, hexcol: str) -> str:
    return f'<span foreground="{hexcol}">{text}</span>'


# Health probes that raise an audible event when they go unhealthy (R.A.I.N.).
_ALERTABLE = {"Nebula AI": "critical", "Firewall": "warning"}


# ---------------------------------------------------------------------------
# Health probes — all best-effort, all non-privileged. Run in a worker thread.
# ---------------------------------------------------------------------------

def _loadavg(_v: dict) -> tuple[str, str]:
    try:
        parts = Path("/proc/loadavg").read_text().split()
        one = float(parts[0])
        ncpu = os.cpu_count() or 1
        ratio = one / ncpu
        col = _GREEN if ratio < 0.7 else _AMBER if ratio < 1.2 else _RED
        return f"{parts[0]} {parts[1]} {parts[2]}  ({ncpu} cpu)", col
    except (OSError, ValueError, IndexError) as exc:
        return f"n/a ({exc.__class__.__name__})", _DIM


def _memory(v: dict) -> tuple[str, str]:
    mem = v.get("mem") or {}
    pct = mem.get("used_pct")
    if pct is None:
        return "n/a", _DIM
    gb = 1024 * 1024
    used = (mem["total_kib"] - mem["available_kib"]) / gb
    col = _GREEN if pct < 70 else _AMBER if pct < 88 else _RED
    return f"{pct:.0f}%  ({used:.1f} / {mem['total_kib'] / gb:.1f} GB)", col


def _disk(v: dict) -> tuple[str, str]:
    d = v.get("disk") or {}
    pct = d.get("used_pct")
    if pct is None:
        return "n/a", _DIM
    col = _GREEN if pct < 80 else _AMBER if pct < 92 else _RED
    return f"{pct:.0f}%  ({_V.fmt_bytes(d.get('free_bytes'))} free)", col


def _uptime(v: dict) -> tuple[str, str]:
    return _V.fmt_uptime(v.get("uptime_s")), _DIM


def _svc_active(unit: str) -> bool:
    """True if systemctl reports the unit active (no sudo needed for is-active)."""
    try:
        out = subprocess.run(["systemctl", "is-active", unit],
                             capture_output=True, text=True, timeout=4)
        return out.stdout.strip() == "active"
    except (OSError, subprocess.TimeoutExpired):
        return False


def _nebula_health(_v: dict) -> tuple[str, str]:
    if _svc_active("nebula-runtime.service"):
        return "running", _GREEN
    # UX-29: the Nebula tab has no start button; name the command that works.
    return "down — sudo systemctl start nebula-runtime.service", _RED


def _network_health(_v: dict) -> tuple[str, str]:
    try:
        out = subprocess.run(
            ["nmcli", "-t", "-f", "NAME,STATE", "connection", "show", "--active"],
            capture_output=True, text=True, timeout=4,
        )
        conns = [ln.split(":")[0] for ln in out.stdout.splitlines() if ln.strip()]
        if conns:
            return f"{len(conns)} active: {', '.join(conns[:2])}", _GREEN
        return "no active connection", _AMBER
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"n/a (nmcli: {exc.__class__.__name__})", _DIM


def _mesh_health(_v: dict) -> tuple[str, str]:
    # DEC-PHASE12-067: the same snapshot verdict as the Mesh tab and the panel.
    now = time.time()
    s = M.mesh_summary(M.load_snapshot(now=now), now, wg_up=M.sysfs_bytes() is not None)
    col = {"active": _GREEN, "down": _AMBER}.get(s["state"], _RED)
    return s["text"].removeprefix("Mesh: "), col


def _firewall_health(_v: dict, up: bool | None = None) -> tuple[str, str]:
    up = _svc_active("orionx-firewall.service") if up is None else up
    return ("active", _GREEN) if up else ("inactive", _AMBER)


def _firewall_addr(v: dict, up: bool) -> tuple[str, str]:
    addrs = [f"{i['iface']} {i['ipv4'][0].split('/')[0]}" for i in v.get("interfaces", []) if i.get("ipv4")]
    txt = ("active" if up else "INACTIVE") + (" · " + ", ".join(addrs) if addrs else " · no addresses")
    return txt, (_GREEN if up else _RED)


def _next_hop(v: dict) -> tuple[str, str]:
    gw = v.get("gateway")
    if gw:
        return f"{gw} via {v.get('gateway_dev') or '?'}", _GREEN
    return "no default route", _AMBER


def _dns(v: dict) -> tuple[str, str]:
    dns = v.get("dns") or []
    return (", ".join(dns), _GREEN) if dns else ("no nameserver configured", _AMBER)


_ROWS = ["CPU load", "Memory", "Disk /", "Uptime", "Nebula AI", "Network", "Mesh",
         "Firewall", "Firewall address", "Next hop", "DNS"]


def collect_health(visible: bool, cpu_prev=None) -> dict:
    """All probes, once per tick, one deck_vitals.collect() shared by every row.

    Hidden: only the alertable services (so R.A.I.N. still hears a degraded
    firewall). Runs in a worker thread; returns plain data.
    """
    fw_up = _svc_active("orionx-firewall.service")
    rows: dict[str, tuple[str, str]] = {"Nebula AI": _nebula_health({}), "Firewall": _firewall_health({}, fw_up)}
    out: dict = {"rows": rows, "vitals": None}
    if not visible:
        return out
    v = _V.collect(cpu_prev)
    out["vitals"] = v
    for name, fn in (("CPU load", _loadavg), ("Memory", _memory), ("Disk /", _disk), ("Uptime", _uptime),
                     ("Network", _network_health), ("Mesh", _mesh_health), ("Next hop", _next_hop), ("DNS", _dns)):
        try:
            rows[name] = fn(v)
        except Exception as exc:  # noqa: BLE001 - shown in the row, not hidden
            rows[name] = (f"n/a ({exc})", _DIM)
    rows["Firewall address"] = _firewall_addr(v, fw_up)
    return out


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


class _AwarenessWidget:
    """Live health monitor + threat-posture selector."""

    def __init__(self) -> None:
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.set_border_width(12)

        hdr = Gtk.Label()
        hdr.set_markup("<b>Live health</b>")
        hdr.set_halign(Gtk.Align.START)
        self.box.pack_start(hdr, False, False, 2)

        grid = Gtk.Grid()
        grid.set_column_spacing(12)
        grid.set_row_spacing(3)
        self.box.pack_start(grid, False, False, 0)
        self._svc_prev: dict[str, bool] = {}
        self._value_labels: dict[str, Gtk.Label] = {}
        for i, name in enumerate(_ROWS):
            key = Gtk.Label()
            key.set_markup(f'<span foreground="{_DIM}">{name}</span>')
            key.set_halign(Gtk.Align.START)
            val = Gtk.Label(label="…")
            val.set_halign(Gtk.Align.START)
            val.set_selectable(True)
            val.set_line_wrap(True)
            grid.attach(key, 0, i, 1, 1)
            grid.attach(val, 1, i, 1, 1)
            self._value_labels[name] = val

        # --- Trends (DEC-PHASE12-056): packets/s, CPU, memory, disk ---
        from ..helpers.spark import Spark  # noqa: PLC0415
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self._sp_pkts = Spark("packets/s", lambda v: f"{v:.0f}", color=(0.2, 0.85, 0.5))
        self._sp_cpu = Spark("cpu", lambda v: f"{v:.0f}%", vmax=100.0)
        self._sp_mem = Spark("mem", lambda v: f"{v:.0f}%", vmax=100.0, color=(0.55, 0.7, 1.0))
        self._sp_disk = Spark("disk", lambda v: f"{v:.0f}%", vmax=100.0, color=(0.9, 0.75, 0.3))
        for s in (self._sp_pkts, self._sp_cpu, self._sp_mem, self._sp_disk):
            s.set_hexpand(True)
            row.pack_start(s, True, True, 0)
        self.box.pack_start(row, False, False, 4)
        self._trend_prev: dict = {}

        self.box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)

        # --- Threat posture ---
        phdr = Gtk.Label()
        phdr.set_markup("<b>Threat posture</b>")
        phdr.set_halign(Gtk.Align.START)
        self.box.pack_start(phdr, False, False, 2)

        current = self._load_posture()
        self._requested = current
        try:
            self._requested_at = _POSTURE_FILE.stat().st_mtime
        except OSError:
            self._requested_at = 0.0
        self._announced = True        # the startup state is not a fresh request
        self._posture_status = Gtk.Label()
        self._posture_status.set_halign(Gtk.Align.START)
        self._posture_status.set_line_wrap(True)
        self._posture_status.set_selectable(True)

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

        # --- R.A.I.N. (audible alerts) ---
        self.box.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 6)
        self._build_rain_controls()

        self._poller = Poller(self.box, _POLL_MS, self._collect, self._apply, run_hidden=True)
        GLib.timeout_add(1000, self._posture_tick)

    # ------------------------------------------------------------------ health

    def _collect(self, visible: bool) -> dict:
        return collect_health(visible, self._trend_prev.get("cpu"))

    def _apply(self, data: dict | None, err: BaseException | None) -> None:
        if err is not None:
            for lbl in self._value_labels.values():
                lbl.set_markup(_color(GLib.markup_escape_text(f"probe failed: {err}"), _RED))
            return
        for name, (value, color) in data["rows"].items():
            self._value_labels[name].set_markup(_color(GLib.markup_escape_text(value), color))
            self._maybe_alert(name, value, color)
        v = data.get("vitals")
        if v:
            now = v.get("generated") or time.time()
            net = v.get("net") or {}
            pk = net.get("rx_packets", 0) + net.get("tx_packets", 0)
            if "pk" in self._trend_prev and now > self._trend_prev["t"]:
                self._sp_pkts.push(max(0.0, (pk - self._trend_prev["pk"]) / (now - self._trend_prev["t"])))
            self._trend_prev.update(pk=pk, t=now, cpu=v.get("cpu_sample"))
            self._sp_cpu.push(v.get("cpu_pct"))
            self._sp_mem.push((v.get("mem") or {}).get("used_pct"))
            self._sp_disk.push((v.get("disk") or {}).get("used_pct"))

    def _maybe_alert(self, name: str, value: str, color: str) -> None:
        """Edge-triggered R.A.I.N. event when an alertable service changes health."""
        if name not in _ALERTABLE:
            return
        healthy = color == _GREEN
        prev = self._svc_prev.get(name)
        self._svc_prev[name] = healthy
        if prev is None:
            return  # baseline poll — establish state, stay silent
        if prev and not healthy:
            _emit_event(_ALERTABLE[name], "health", "service", f"{name} degraded: {value}")
        elif healthy and not prev:
            _emit_event("notice", "health", "service", f"{name} recovered: {value}")

    # ----------------------------------------------------------------- posture

    def _load_posture(self) -> str:
        try:
            val = _POSTURE_FILE.read_text(encoding="utf-8").strip()
            return val if val in ("0", "1", "2") else "0"
        except OSError:
            return "0"

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
        ok, err = S.atomic_write_text(_POSTURE_FILE, tier_id + "\n")
        if not ok:
            # The request never reached postured: say so and put the control back.
            self._reverting = True
            self._radios[self._requested].set_active(True)
            self._reverting = False
            ux.notify(f"✗ Threat posture NOT changed — could not write {err}", ux.LEVEL_ERROR)
            return
        self._requested, self._requested_at, self._announced = tier_id, time.time(), False
        label = P.TIER_LABEL[tier_id]
        _emit_event("warning" if tier_id == "2" else "notice", "posture", "posture",
                    f"Threat posture change requested: {label}")
        v = self._show_posture()
        ux.notify(f"{v['text']}  ·  {S.reboot_line()}", ux.LEVEL_INFO)

    # ----------------------------------------------------------------- R.A.I.N.

    def _build_rain_controls(self) -> None:
        """Audible-alert controls; rain_lib owns rain.json's schema and its atomic save."""
        cfg = rain_lib.load_config()

        rhdr = Gtk.Label()
        rhdr.set_markup("<b>Audible alerts · R.A.I.N.</b>")
        rhdr.set_halign(Gtk.Align.START)
        self.box.pack_start(rhdr, False, False, 2)

        sub = Gtk.Label()
        sub.set_markup(_color("Hear intrusions without watching the screen — for your 3am self.", _DIM))
        sub.set_halign(Gtk.Align.START)
        self.box.pack_start(sub, False, False, 0)

        self._rain_enable = Gtk.CheckButton(label="Enable audible alerts")
        self._rain_enable.set_active(bool(cfg["enabled"]))
        self._rain_enable.connect("toggled", self._on_rain_changed)
        self.box.pack_start(self._rain_enable, False, False, 2)

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

        vrow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        vlbl = Gtk.Label(label="Volume:")
        self._rain_vol = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 5)
        self._rain_vol.set_value(max(0, min(100, int(float(cfg["volume"]) * 100))))
        self._rain_vol.set_hexpand(True)
        self._rain_vol.set_draw_value(True)
        self._rain_vol.connect("value-changed", self._on_rain_changed)
        vrow.pack_start(vlbl, False, False, 0)
        vrow.pack_start(self._rain_vol, True, True, 0)
        self.box.pack_start(vrow, False, False, 2)

        brow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self._rain_voice = Gtk.CheckButton(label="Spoken voice cue")
        self._rain_voice.set_active(bool(cfg["voice"]))
        # UX-13: say how this differs from narration.
        self._rain_voice.set_tooltip_text(
            "Speak a short fixed phrase with each tone (for example \"Warning. Suspicious "
            "activity.\"). It never says what the alert was — that is narration.")
        self._rain_voice.connect("toggled", self._on_rain_changed)
        # DEC-PHASE12-046. Off by default and labelled with the consequence.
        self._rain_speech = Gtk.CheckButton(label="Narrate alerts aloud")
        self._rain_speech.set_active(bool(cfg.get("speech", False)))
        self._rain_speech.set_tooltip_text(
            "Speak a one-sentence description of the alert after the tone. "
            "Audible to everyone in the room — the tone is not."
        )
        self._rain_speech.connect("toggled", self._on_rain_changed)
        test_btn = Gtk.Button(label="Test alert")
        test_btn.connect("clicked", self._on_rain_test)
        self._test_btn = test_btn
        brow.pack_start(self._rain_voice, False, False, 0)
        brow.pack_start(self._rain_speech, False, False, 0)
        brow.pack_start(test_btn, False, False, 0)
        self.box.pack_start(brow, False, False, 2)
        self._rain_timer = 0

    def _rain_cfg_from_widgets(self) -> dict:
        cfg = rain_lib.load_config()
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

    def _on_rain_test(self, _btn: Gtk.Button) -> None:
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


def build_section() -> Gtk.Widget:
    """Return the Awareness tab (live health, trends, threat posture, R.A.I.N.)."""
    return _AwarenessWidget().box
