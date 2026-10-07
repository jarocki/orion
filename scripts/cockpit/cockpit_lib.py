#!/usr/bin/env python3
"""cockpit_lib — pure, testable logic behind the Orion Cockpit.

The Cockpit (orionx-cockpit) is the operator's live "see" channel: where
R.A.I.N. lets you HEAR cyber activity, the Cockpit lets you SEE it — an event
stream, a threat-pressure gauge, a network sparkline and system status, drawn
with Cairo and animated. Everything that is not GTK/Cairo drawing lives here so
it can be unit-tested on any machine with no display and no gi:

  - event tailing (incremental JSONL tail of the R.A.I.N. event bus),
  - threat "pressure" (severity-weighted, exponentially decaying),
  - network throughput rates from /proc/net/dev,
  - sparkline scaling, formatting helpers, colour palette.

@decision DEC-PHASE12-007
@title Orion Cockpit — live visualisation of the event bus + system telemetry
@status accepted
@rationale Operator (2026-09-14): "this should feel like a cockpit where we can
  see and hear the cyber activity around us." R.A.I.N. (DEC-PHASE11-045) covers
  hearing; the Cockpit covers seeing, consuming the SAME event bus
  (/run/orionx/events.jsonl) so both channels agree, plus non-privileged host
  telemetry (/proc/net/dev, systemctl is-active, wg0 presence, threat posture).
  Drawing is Cairo in a Gtk.DrawingArea on a GLib timer (no threads, same rule
  as the Control Center); the logic is split into this dependency-free module
  so the maths is provable in CI. Kept cheap for Bay Trail hardware.
"""

from __future__ import annotations

import json
import math
import os
import shutil
import re
import subprocess
import time
from collections import deque
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Palette (RGB floats for Cairo) — Phoenix identity
# ---------------------------------------------------------------------------
EMBER = (1.00, 0.42, 0.07)      # #FF6A13
EMBER_DIM = (0.78, 0.30, 0.09)
CYAN = (0.20, 0.85, 1.00)
GREEN = (0.20, 1.00, 0.62)      # #34ff9e
AMBER = (1.00, 0.70, 0.19)
RED = (1.00, 0.36, 0.25)
DIM = (0.55, 0.60, 0.66)
BG_TOP = (0.06, 0.07, 0.09)
BG_BOTTOM = (0.02, 0.02, 0.03)
GRID = (0.12, 0.16, 0.22)

SEVERITY_COLOR = {"info": DIM, "notice": CYAN, "warning": AMBER, "critical": RED}
SEVERITY_WEIGHT = {"info": 2.0, "notice": 8.0, "warning": 20.0, "critical": 40.0}
SEVERITIES = ("info", "notice", "warning", "critical")

EVENT_LOG = Path("/run/orionx/events.jsonl")
POSTURE_FILE = Path.home() / ".config" / "orionx" / "threat-posture"
# Runtime truth written by orionx-postured (DEC-PHASE12-024): what the tier is
# actually enforcing, as opposed to what it was set to. The distinction is the
# whole point — a tier can be selected while the IDS behind it carries no
# threat rules and therefore detects nothing.
POSTURE_STATUS_FILE = Path("/run/orionx/posture-status.json")
PRESSURE_HALF_LIFE = 60.0   # seconds for an event's contribution to halve


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------
def parse_event(line: str) -> dict[str, Any] | None:
    """Parse one JSONL bus line into a normalised event, or None if invalid."""
    line = line.strip()
    if not line:
        return None
    try:
        obj = json.loads(line)
    except ValueError:
        return None
    if not isinstance(obj, dict):
        return None
    sev = str(obj.get("severity", "notice")).lower().strip()
    if sev not in SEVERITY_WEIGHT:
        sev = "notice"
    try:
        ts = float(obj.get("ts", 0.0))
    except (TypeError, ValueError):
        ts = 0.0
    # Structured detail (DEC-PHASE12-029) rides through untruncated so the
    # drill-down view can show the source IP, signature, matching content and
    # triggering rule. The message is kept WHOLE here too: the stream row clips
    # it at draw time, the drill-down wraps all of it. Clipping at parse time
    # meant the drill-down could never show more than the stream (reference
    # deck, 2026-10-05).
    detail = obj.get("detail")
    if not isinstance(detail, dict):
        detail = {}
    return {
        "ts": ts,
        "severity": sev,
        "source": str(obj.get("source", "?"))[:24],
        "category": str(obj.get("category", ""))[:24],
        "message": str(obj.get("message", "")),
        "id": str(obj.get("id", ""))[:32],
        "detail": detail,
    }


class EventTail:
    """Incremental tail of the JSONL event bus.

    On first open it reads the last `backfill` events (so the cockpit is not
    empty at launch), then `poll()` returns only new events. Handles the file
    not existing yet and tmpfs rotation (inode change / truncation).
    """

    def __init__(self, path: Path = EVENT_LOG, backfill: int = 40, keep: int = 200) -> None:
        self.path = Path(path)
        self.keep = keep
        self.events: deque[dict[str, Any]] = deque(maxlen=keep)
        self._backfill = backfill
        self._fh = None
        self._inode = -1
        self._pos = 0
        # @decision DEC-PHASE12-066
        # @title A bus line read before its writer finished is completed, not dropped
        # @status accepted
        # @rationale python.md P1-6: readline() can return a line with no
        #   trailing newline while a writer is mid-append; it failed to parse,
        #   _pos moved past it, and that event never reached the stream. Such
        #   a fragment is held here and prefixed to the next read.
        self._partial = ""

    def _open(self, from_start: bool = False) -> bool:
        try:
            st = self.path.stat()
        except OSError:
            return False
        try:
            fh = self.path.open("r", encoding="utf-8", errors="replace")
        except OSError:
            return False
        self._fh = fh
        self._inode = st.st_ino
        if from_start:
            # A rotated/recreated/truncated bus: everything in the NEW file
            # is unseen, so read it from the top (it used to be skipped).
            self._pos = 0
            return True
        # First open: backfill the last N events, then continue from EOF.
        try:
            lines = fh.readlines()
        except OSError:
            lines = []
        if lines and not lines[-1].endswith("\n"):
            self._partial = lines.pop()
        tail = lines[-self._backfill:] if self._backfill else []
        for ln in tail:
            ev = parse_event(ln)
            if ev:
                self.events.append(ev)
        self._pos = fh.tell()
        return True

    def poll(self) -> list[dict[str, Any]]:
        """Return events appended since the last poll (possibly empty)."""
        if self._fh is None and not self._open():
            return []
        # Rotation / recreation / truncation: reopen and read the new file from
        # the top. A deleted bus (stat fails) keeps the old handle until a new
        # file appears; the poll simply returns nothing meanwhile.
        try:
            st = self.path.stat()
            if st.st_ino != self._inode or st.st_size < self._pos:
                self._fh.close()
                self._fh = None
                self._partial = ""
                if not self._open(from_start=True):
                    return []
        except OSError:
            return []
        new: list[dict[str, Any]] = []
        try:
            while True:
                line = self._fh.readline()
                if not line:
                    break
                if not line.endswith("\n"):
                    self._partial += line      # writer is mid-line: finish it next poll
                    break
                line, self._partial = self._partial + line, ""
                ev = parse_event(line)
                if ev:
                    new.append(ev)
                    self.events.append(ev)
            self._pos = self._fh.tell()
        except OSError:
            pass
        return new


# Categories that describe the DECK's own condition rather than a threat to it
# (DEC-PHASE12-034). These are excluded from threat pressure.
#
# Observed on hardware: Suricata was failing to start, orionx-postured warned
# about it every 30s, and the gauge read "5.1 ELEVATED" on an idle machine with
# nothing attacking it. The deck was frightening itself with its own
# self-diagnosis. A threat gauge that rises because a service is unhealthy
# teaches the operator that the gauge means nothing, which is the one thing it
# cannot afford to teach.
#
# Health events still appear in the stream, still carry their severity, still
# sound the R.A.I.N. cue. They just do not count as threat, because they are
# not threat.
# MIRROR of rain_lib.STATUS_CATEGORIES — rain_lib is the single authority
# (DEC-PHASE12-040). A literal rather than an import, deliberately: the
# Cockpit is launched in several ways and an import with a fallback would let
# the two sets drift behind a silently successful fallback, which is the exact
# failure mode this constant exists to prevent. The invariant is enforced by
# test instead, where drift is loud: tests/unit/test_event_detail.sh asserts
# this equals rain_lib.STATUS_CATEGORIES exactly.
#
# Categories here describe the DECK's own condition rather than a threat to
# it, and are excluded from threat pressure. Observed before this existed:
# Suricata failing to start made orionx-postured warn every 30s and the gauge
# read "5.1 ELEVATED" on an idle machine — the deck frightening itself with
# its own self-diagnosis. Health events still appear in the stream and still
# sound the R.A.I.N. cue; they are simply not threat.
SELF_STATUS_CATEGORIES = frozenset({
    "health", "posture", "service", "tooling", "heal", "capture",
    "intel", "general",
})


def pressure(events, now: float, half_life: float = PRESSURE_HALF_LIFE) -> float:
    """Threat pressure 0..100: severity-weighted sum with exponential decay.

    Each event contributes weight * 0.5 ** (age / half_life). Deterministic and
    monotone in severity, so the gauge is explainable: a critical event 60s ago
    counts as 20, a warning right now counts as 20, etc. Clamped to 100.
    """
    total = 0.0
    for ev in events:
        if ev.get("category") in SELF_STATUS_CATEGORIES:
            continue
        # DEC-PHASE12-051: the deck's own traffic tripping a policy rule is
        # not threat pressure (it was: archive.ph from the deck read as HOSTILE).
        if (ev.get("detail") or {}).get("origin") == "self":
            continue
        age = max(0.0, now - float(ev.get("ts", now)))
        w = SEVERITY_WEIGHT.get(ev.get("severity", "notice"), 8.0)
        total += w * (0.5 ** (age / half_life))
    return max(0.0, min(100.0, total))


def pressure_color(p: float) -> tuple[float, float, float]:
    """Gauge colour by pressure band: green < 25, amber < 60, red otherwise."""
    if p < 25:
        return GREEN
    if p < 60:
        return AMBER
    return RED


# ---------------------------------------------------------------------------
# Network telemetry
# ---------------------------------------------------------------------------
def read_net_bytes(path: str = "/proc/net/dev") -> tuple[int, int]:
    """Total (rx_bytes, tx_bytes) across all non-loopback interfaces."""
    rx = tx = 0
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh.readlines()[2:]:
                if ":" not in line:
                    continue
                name, rest = line.split(":", 1)
                if name.strip() == "lo":
                    continue
                cols = rest.split()
                if len(cols) >= 9:
                    rx += int(cols[0])
                    tx += int(cols[8])
    except (OSError, ValueError):
        pass
    return rx, tx


class RateTracker:
    """Turn cumulative byte counters into per-second rates with a history."""

    def __init__(self, history: int = 90) -> None:
        self.rx_hist: deque[float] = deque([0.0] * history, maxlen=history)
        self.tx_hist: deque[float] = deque([0.0] * history, maxlen=history)
        self._last: tuple[int, int, float] | None = None
        self.rx_rate = 0.0
        self.tx_rate = 0.0

    def push(self, rx: int, tx: int, now: float) -> None:
        if self._last is not None:
            lrx, ltx, lt = self._last
            dt = max(1e-3, now - lt)
            self.rx_rate = max(0.0, (rx - lrx) / dt)
            self.tx_rate = max(0.0, (tx - ltx) / dt)
            self.rx_hist.append(self.rx_rate)
            self.tx_hist.append(self.tx_rate)
        self._last = (rx, tx, now)


def sparkline_points(values, x: float, y: float, w: float, h: float,
                     vmax: float | None = None) -> list[tuple[float, float]]:
    """Map a series onto a box (x, y, w, h); y grows downward (Cairo).

    Scales to `vmax` (or the series max, min 1.0 so a flat line sits at the
    bottom instead of dividing by zero). Returns [(px, py), ...] left→right.
    """
    vals = list(values)
    if not vals:
        return []
    top = vmax if vmax and vmax > 0 else max(max(vals), 1.0)
    n = len(vals)
    step = w / max(1, n - 1)
    pts = []
    for i, v in enumerate(vals):
        frac = min(1.0, max(0.0, v / top))
        pts.append((x + i * step, y + h - frac * h))
    return pts


def fmt_rate(bps: float) -> str:
    """Human-readable bytes/s: 0 B/s, 12.3 kB/s, 4.5 MB/s."""
    if bps < 1024:
        return f"{int(bps)} B/s"
    if bps < 1024 ** 2:
        return f"{bps / 1024:.1f} kB/s"
    return f"{bps / 1024 ** 2:.2f} MB/s"


def fmt_age(seconds: float) -> str:
    """Compact age: 3s, 4m, 2h."""
    s = max(0, int(seconds))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    return f"{s // 3600}h"


# ---------------------------------------------------------------------------
# System status (all non-privileged)
# ---------------------------------------------------------------------------
def service_active(unit: str) -> bool:
    """True if systemctl reports the unit active. Safe when systemctl is absent."""
    if shutil.which("systemctl") is None:
        return False
    try:
        out = subprocess.run(["systemctl", "is-active", unit],
                             capture_output=True, text=True, timeout=3)
        return out.stdout.strip() == "active"
    except (OSError, subprocess.SubprocessError):
        return False


def process_running(name: str) -> bool:
    """True if a process whose cmdline contains `name` exists (pgrep -f)."""
    if shutil.which("pgrep") is None:
        return False
    try:
        out = subprocess.run(["pgrep", "-f", name], capture_output=True, text=True, timeout=3)
        return out.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def posture_tier(path: Path = POSTURE_FILE) -> str:
    """Current threat-posture tier id ('0','1','2'); '0' if unset."""
    try:
        v = Path(path).read_text(encoding="utf-8").strip()
        return v if v in ("0", "1", "2") else "0"
    except OSError:
        return "0"


POSTURE_LABEL = {"0": "TIER 0 · PASSIVE", "1": "TIER 1 · ACTIVE", "2": "TIER 2 · DECEPTION"}


def posture_status(path: Path = POSTURE_STATUS_FILE) -> dict[str, Any]:
    """Enforcement status from orionx-postured; {} if the daemon is not running."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def posture_badge(tier: str, status: dict[str, Any] | None = None) -> tuple[str, str]:
    """(label, state) for the header badge, where state is ok|warn|blind.

    'blind' is the honest answer for a tier that promises IDS coverage while
    Suricata has no threat rules: the badge must not read like everything is
    fine when nothing can be detected. 'warn' means the daemon that enforces
    the tier is not reporting at all, so the badge is a wish, not a fact.
    """
    label = POSTURE_LABEL.get(tier, POSTURE_LABEL["0"])
    status = status or {}
    if tier == "0":
        return label, "ok"
    if not status:
        return label + "  ⚠ UNENFORCED", "warn"
    if status.get("ids_expected") and not status.get("rules_usable", False):
        return label + "  ⚠ NO IDS RULES", "blind"
    if status.get("ids_expected") and not status.get("ids_active", False):
        return label + "  ⚠ IDS DOWN", "warn"
    return label, "ok"


def lerp(a: float, b: float, t: float) -> float:
    """Linear interpolation used for smooth needle/bar animation."""
    return a + (b - a) * max(0.0, min(1.0, t))


def now() -> float:
    return time.time()


__all__ = [
    "EMBER", "EMBER_DIM", "CYAN", "GREEN", "AMBER", "RED", "DIM", "BG_TOP", "BG_BOTTOM", "GRID",
    "SEVERITY_COLOR", "SEVERITY_WEIGHT", "SEVERITIES", "EVENT_LOG", "POSTURE_FILE",
    "parse_event", "EventTail", "pressure", "pressure_color", "read_net_bytes", "RateTracker",
    "sparkline_points", "fmt_rate", "fmt_age", "service_active", "process_running",
    "posture_tier", "POSTURE_LABEL", "POSTURE_STATUS_FILE", "posture_status",
    "posture_badge", "lerp", "now", "math",
]

# ---------------------------------------------------------------------------
# Defensive / deceptive actions (DEC-PHASE12-029)
#
# The auto-healing engine (DEC-PHASE12-023) parks an action as "pending" when
# the operator set that action class to `confirm`. Until now the only way to
# see or approve one was `orionx-heal pending` / `orionx-heal confirm <id>` on
# a terminal — which means the deck could be holding a blocked-IP decision
# while the Cockpit, the thing the operator is actually watching, showed
# nothing about it. These readers put that state on the dashboard.
#
# Reading is best-effort and never raises. The chain itself is root:0600, so
# the Cockpit reads heald's world-readable snapshot (DEC-PHASE12-065).
# ---------------------------------------------------------------------------

# @decision DEC-PHASE12-065
# @title The Cockpit reads healing state ONLY from heald's published snapshot
# @status accepted
# @rationale QA round 1 (python.md P1-1, P1-2). The Cockpit replayed the
#   root:0600 hash chain itself. It could never open it as orionx-operator, and
#   when it could (tests) it matched `status == "active"`, a value the engine
#   never writes (it writes kind="applied"), so IN FORCE stayed empty while the
#   deck was blocking a host. A second replay of the chain is a second
#   authority. orionx-heald (root) now publishes /run/orionx/healing-status.json
#   (0644, atomic) from the engine's own replay; that is the only thing read
#   here. A missing, corrupt or stale (>30 s) snapshot is "state unknown —
#   orionx-heald not publishing", never an empty list: "nothing pending" and "I
#   could not look" must not look the same on a defensive dashboard.
HEAL_STATUS = Path(os.environ.get("ORIONX_HEALING_STATUS", "/run/orionx/healing-status.json"))
HEAL_STALE_AFTER = 30.0


def _f(v: Any) -> float | None:
    try:
        return None if v is None or isinstance(v, bool) else float(v)
    except (TypeError, ValueError):
        return None


def _heal_rec(r: Any, ts_key: str) -> dict[str, Any] | None:
    if not isinstance(r, dict) or not str(r.get("id", "")).strip():
        return None
    out = {"id": str(r["id"]), "action": str(r.get("action", "?")),
           "target": str(r.get("target", "?")), ts_key: _f(r.get(ts_key))}
    if ts_key == "applied_ts":
        out["expires_ts"] = _f(r.get("expires_ts"))
    return out


def healing_actions(path: Path = HEAL_STATUS, now: float | None = None,
                    stale_after: float = HEAL_STALE_AFTER) -> dict[str, Any]:
    """Healing state from orionx-heald's snapshot. Never raises.

    Returns {'readable', 'pending', 'active', 'reason', 'age', 'chain_ok'}.
    `readable` False means the panel must say "state unknown — <reason>".
    """
    now = time.time() if now is None else now
    out: dict[str, Any] = {"readable": False, "pending": [], "active": [],
                           "reason": "", "age": None, "chain_ok": None}
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        out["reason"] = f"orionx-heald not publishing ({path} missing)"
        return out
    except OSError as exc:
        out["reason"] = f"orionx-heald snapshot unreadable ({exc.strerror or exc})"
        return out
    except ValueError:
        out["reason"] = "orionx-heald snapshot is not valid JSON"
        return out
    if not isinstance(data, dict) or _f(data.get("ts")) is None:
        out["reason"] = "orionx-heald snapshot has no timestamp"
        return out
    age = max(0.0, now - float(data["ts"]))
    out["age"] = age
    out["chain_ok"] = data.get("chain_ok") if isinstance(data.get("chain_ok"), bool) else None
    if age > stale_after:
        out["reason"] = f"orionx-heald not publishing (snapshot {age:.0f} s old)"
        return out
    if data.get("error"):
        out["reason"] = f"orionx-heald reports: {str(data['error'])[:100]}"
        return out
    pend = [x for x in (_heal_rec(r, "proposed_ts") for r in data.get("pending") or []) if x]
    act = [x for x in (_heal_rec(r, "applied_ts") for r in data.get("in_force") or []) if x]
    pend.sort(key=lambda r: r["proposed_ts"] or 0.0, reverse=True)
    act.sort(key=lambda r: r["applied_ts"] or 0.0, reverse=True)
    out.update(readable=True, pending=pend, active=act)
    return out


def _heal_cli(args: list[str], timeout: float = 4.0) -> tuple[int, str]:
    """Run orionx-heal, returning (rc, combined output). Never raises."""
    try:
        r = subprocess.run(["orionx-heal", *args], capture_output=True,
                           text=True, timeout=timeout, check=False)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except FileNotFoundError:
        return 127, ""
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)


def tune_args(ev: dict[str, Any], mode: str) -> list[str] | None:
    """orionx-tune argv for this event, or None if it is not tunable. Pure.

    Only IDS events from an engine carry a sid or a Zeek note; anything else
    (a health warning, a scan from scanwatch) has nothing to tune. The source
    address is included so a squelch is as narrow as the evidence: this
    signature FROM THIS HOST, not this signature from everyone.
    """
    if mode not in ("squelch", "tune"):
        return None
    d = ev.get("detail") or {}
    src = str(ev.get("source", ""))
    args = ["orionx-tune", mode]
    if src == "suricata" or d.get("sid") is not None:
        sid = d.get("sid")
        if sid is None:
            m = re.search(r"\bsid:(\d+)\b", str(ev.get("message", "")))
            sid = int(m.group(1)) if m else None
        if sid is None:
            return None
        args += ["--sid", str(int(sid))]
        if d.get("signature"):
            args += ["--signature", str(d["signature"])[:120]]
    elif src == "zeek" and d.get("note"):
        args += ["--note", str(d["note"])]
    else:
        return None
    if d.get("src_ip"):
        args += ["--src", str(d["src_ip"])]
    args += ["--reason", "from the Cockpit drill-down"]
    return args


def tune_event(ev: dict[str, Any], mode: str) -> tuple[bool, str]:
    """Run orionx-tune for this event. Returns (ok, the CLI's own words), which
    include whether the rule survives a reboot (DEC-PHASE12-050)."""
    args = tune_args(ev, mode)
    if args is None:
        return False, "not tunable: no IDS signature or Zeek note on this event"
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=6.0, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"orionx-tune failed: {exc}"
    out = " ".join((r.stdout or r.stderr or "").split())
    return r.returncode == 0, out or f"orionx-tune exit {r.returncode}"


def approve_action(action_id: str) -> tuple[bool, str]:
    """Approve one pending action. Returns (ok, human-readable outcome).

    Privilege is the interesting case: the chain is root-owned and the Cockpit
    is not root. If escalation is unavailable we return the exact command for
    the operator to run rather than failing silently — an approval that
    quietly did nothing is indistinguishable from one that worked, and this
    button arms real defensive actions.
    """
    aid = str(action_id).strip()
    if not aid:
        return False, "no action selected"
    rc, out = _heal_cli(["confirm", aid])
    if rc == 0:
        return True, f"approved {aid}"
    if rc == 127:
        return False, "orionx-heal not found on PATH"
    tail = (out or "").strip().splitlines()
    why = tail[-1][:80] if tail else f"exit {rc}"
    return False, f"not approved ({why}) — run: sudo orionx-heal confirm {aid}"
