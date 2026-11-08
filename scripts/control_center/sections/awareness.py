"""
Orion Cockpit — Awareness tab: live health and trends.

Surfaces:

  1. LIVE HEALTH — CPU load, memory, disk, uptime, and the units that matter
     (Nebula runtime, network, WireGuard mesh, firewall), colour-coded.
  2. TRENDS — packets/s, CPU, memory, disk sparklines (DEC-PHASE12-056).

The threat-posture selector and the R.A.I.N. controls that used to sit below
these moved to the Cockpit settings drawer (#95, DEC-PHASE13-048:
control_center/settings_drawer.py), so they are one click away on every tab.

Probes run in a worker thread (helpers/background, DEC-PHASE12-068). Only the
two alertable service probes keep running while the tab is hidden, so a
degraded firewall still sounds while the operator watches LIVE.

@decision DEC-PHASE10-005
@title W10-5 Awareness: live health monitor + threat-posture tier selector
@status accepted
@rationale Phase 9 W9-2 locked this section as a plug-in surface. W10-5 fills it
  with the live health monitor the operator asked for. (The tier selector it
  also carried is in the settings drawer since #95; its writer is
  posture_data.request_tier.) No privileged calls, no third-party imports
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
from ..helpers import style, ux  # noqa: E402
from ..helpers.background import Poller  # noqa: E402

# python.md P2-3: import once. Inserting into sys.path on every probe grew it
# by one entry per call (~130k a day).
_SCRIPTS = Path(__file__).resolve().parents[2]
if str(_SCRIPTS / "awareness") not in sys.path:
    sys.path.insert(0, str(_SCRIPTS / "awareness"))
import deck_vitals as _V  # noqa: E402

# Live-health refresh cadence (ms).
_POLL_MS = 3000

# Colour markup helpers (Pango).
_GREEN = "#34ff9e"
_AMBER = "#ffb300"
_RED = "#ff6a4a"
_DIM = "#9aa0a6"


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


class _AwarenessWidget:
    """Live health monitor and trends."""

    def __init__(self) -> None:
        self.box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.box.set_border_width(12)

        hdr = style.heading("<b>Live health</b>")
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
        moved = Gtk.Label()
        moved.set_markup(f'<span foreground="{_DIM}">Threat posture and R.A.I.N. alert settings: '
                         "Settings (top right, or F2) on every tab.</span>")
        moved.set_halign(Gtk.Align.START)
        moved.set_line_wrap(True)
        self.box.pack_start(moved, False, False, 4)

        self._poller = Poller(self.box, _POLL_MS, self._collect, self._apply, run_hidden=True)

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
            ux.emit_event(_ALERTABLE[name], "health", "service", f"{name} degraded: {value}")
        elif healthy and not prev:
            ux.emit_event("notice", "health", "service", f"{name} recovered: {value}")


def build_section() -> Gtk.Widget:
    """Return the Awareness tab (live health and trends)."""
    return _AwarenessWidget().box
