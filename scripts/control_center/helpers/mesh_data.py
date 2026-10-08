"""mesh_data — pure parsers for the Mesh tab (DEC-PHASE12-054).

@decision DEC-PHASE12-054
@title The Mesh tab shows nodes, traffic and history, from wg itself and the bus
@status accepted
@rationale On the rc6 deck the mesh was up and the tab said one word. The
  truth is already on the machine: `wg show wg0 dump` has every peer, its
  endpoint, last handshake and byte counters; `orionx-mesh status` has the
  interface identity; the R.A.I.N. bus has every mesh event (joins, heals,
  stale peers). This module turns those texts into data; the tab only draws it.
"""
from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

MESH_IFACE = "wg0"
EVENT_LOG = Path("/run/orionx/events.jsonl")
SNAPSHOT = Path("/run/orionx/mesh-status.json")   # DEC-PHASE12-059, written by orionx-mesh snapshot (root)
SYSFS_NET = Path("/sys/class/net")
MESH_SOURCES = ("mesh", "mesh-health", "mesh-beacon", "orionx-mesh", "wg")


def parse_status(text: str) -> dict[str, str]:
    """`orionx-mesh status` text -> {active, interface, vpn_ip, mode, peers, uptime, health}."""
    out: dict[str, str] = {"active": "unknown"}
    for raw in (text or "").splitlines():
        line = raw.strip()
        if line.lower().startswith("mesh:"):
            out["active"] = line.split(":", 1)[1].strip().lower()
            continue
        if ":" in line:
            k, v = line.split(":", 1)
            key = k.strip().lower().replace(" ", "_")
            out[key] = v.strip()
    return out


def parse_wg_dump(text: str, now: float | None = None) -> list[dict[str, Any]]:
    """`wg show <iface> dump` -> one dict per peer (first line, the interface, skipped)."""
    now = time.time() if now is None else now
    peers = []
    lines = (text or "").splitlines()
    for line in lines[1:]:
        f = line.split("\t")
        if len(f) < 8:
            continue
        pub, _psk, endpoint, allowed, hs, tx, rx, keepalive = f[:8]
        try:
            hs_i = int(hs)
        except ValueError:
            hs_i = 0
        node = allowed.split(",")[0].split("/")[0] if allowed and allowed != "(none)" else ""
        peers.append({
            "pubkey": pub, "short": pub[:10] + "…", "endpoint": endpoint if endpoint != "(none)" else "",
            "allowed_ips": allowed, "node": node,
            "handshake": hs_i, "handshake_age": (now - hs_i) if hs_i > 0 else None,
            "rx": int(rx) if rx.isdigit() else 0, "tx": int(tx) if tx.isdigit() else 0,
            "keepalive": keepalive,
        })
    return peers


def peer_state(age: float | None) -> str:
    if age is None:
        return "never"
    if age <= 180:
        return "live"
    return "stale"


def fmt_age(seconds: float | None) -> str:
    if seconds is None:
        return "never"
    s = int(seconds)
    if s < 60:
        return f"{s}s ago"
    if s < 3600:
        return f"{s // 60}m ago"
    return f"{s // 3600}h {(s % 3600) // 60}m ago"


def fmt_bytes(n: float) -> str:
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} GiB"


def total_traffic(peers: list[dict[str, Any]]) -> tuple[int, int]:
    return sum(p["rx"] for p in peers), sum(p["tx"] for p in peers)


def _num(v: Any) -> float:
    try:
        return float(v) if v is not None and not isinstance(v, bool) else 0.0
    except (TypeError, ValueError):
        return 0.0


def load_snapshot(path: Path = SNAPSHOT, now: float | None = None) -> dict[str, Any] | None:
    """The root-written snapshot, or None (missing/corrupt). Never raises.

    Handshake ages are measured against `now` (the reader's clock), not the
    snapshot's own ts: a frozen snapshot must not make old handshakes look
    live (UX-26). Malformed peers are dropped, not raised into a GLib timer.
    """
    now = time.time() if now is None else now
    try:
        d = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict) or "active" not in d:
        return None
    peers = []
    for p in d.get("peers") if isinstance(d.get("peers"), list) else []:
        if not isinstance(p, dict):
            continue
        hs = _num(p.get("handshake"))
        p["handshake_age"] = None if hs <= 0 else max(0.0, now - hs)
        p["rx"], p["tx"] = int(_num(p.get("rx"))), int(_num(p.get("tx")))
        p.setdefault("short", str(p.get("pubkey_short", "")) + "…")
        peers.append(p)
    d["peers"] = peers
    return d


def snapshot_age(snap: dict[str, Any] | None, now: float) -> float | None:
    if not snap or _num(snap.get("ts")) <= 0:
        return None
    return max(0.0, now - _num(snap["ts"]))


# @decision DEC-PHASE12-067
# @title One mesh verdict, from the root-written snapshot, for every surface
# @status accepted
# @rationale UX-15/UX-26, python.md P2-4, system.md P2-4. The panel widget ran
#   `sudo orionx-mesh status` every 5 s from genmon (no tty: it showed "—"
#   while wg0 was up), Awareness and the LIVE LED looked at sysfs, and the
#   Mesh tab kept saying "active" over a 10-minute-old snapshot. Four readers,
#   three answers. Every surface now asks mesh_summary(load_snapshot()) and
#   prints its text; past MESH_STALE_AFTER the verdict is "stale", with the
#   age and the timer to check, and no surface calls sudo.
MESH_STALE_AFTER = 30.0
_TIMER_HINT = "sudo systemctl status orionx-mesh-status.timer"


def mesh_summary(snap: dict[str, Any] | None, now: float,
                 wg_up: bool | None = None) -> dict[str, Any]:
    """The mesh verdict every surface prints. Pure.

    state: active | stale | down | no-snapshot. `text` is the full sentence;
    `short` fits a panel widget.
    """
    age = snapshot_age(snap, now)
    out: dict[str, Any] = {"age": age, "peers": 0, "live": 0, "stale_peers": 0}
    if snap is None or age is None:
        up = " wg0 is up but" if wg_up else ""
        out.update(state="no-snapshot", short="— (no snapshot)",
                   text=f"Mesh: state unknown —{up} no snapshot at {SNAPSHOT}. "
                        f"Is the snapshot timer running? {_TIMER_HINT}")
        return out
    peers = snap.get("peers") or []
    live = sum(1 for p in peers if peer_state(p.get("handshake_age")) == "live")
    stalep = sum(1 for p in peers if peer_state(p.get("handshake_age")) == "stale")
    out.update(peers=len(peers), live=live, stale_peers=stalep)
    if age > MESH_STALE_AFTER:
        out.update(state="stale", short=f"◆ stale ({age:.0f} s)",
                   text=f"Mesh: snapshot stale ({age:.0f} s old) — the state below may be wrong. "
                        f"Is the snapshot timer running? {_TIMER_HINT}")
        return out
    if not snap.get("active"):
        out.update(state="down", short="—",
                   text="Mesh: not joined — press Start Mesh (or: sudo orionx-mesh join)")
        return out
    out.update(state="active", short=f"◆ {live} peer{'s' if live != 1 else ''}",
               text=f"Mesh: active — {len(peers)} node(s) known, {live} live"
                    + (f", {stalep} stale" if stalep else "") + f"   (snapshot {age:.0f} s old)")
    return out


def sysfs_bytes(iface: str = MESH_IFACE, root: Path = SYSFS_NET) -> tuple[int, int] | None:
    """(rx_bytes, tx_bytes) from the kernel, readable by anyone; None if the interface is absent."""
    try:
        rx = int((root / iface / "statistics" / "rx_bytes").read_text().strip())
        tx = int((root / iface / "statistics" / "tx_bytes").read_text().strip())
        return rx, tx
    except (OSError, ValueError):
        return None


def read_history(path: Path = EVENT_LOG, limit: int = 12, tail_lines: int = 600) -> list[dict[str, Any]]:
    """Last `limit` bus events about the mesh, newest first. Never raises."""
    try:
        with open(path, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 200_000))
            lines = fh.read().decode("utf-8", "replace").splitlines()[-tail_lines:]
    except OSError:
        return []
    out = []
    for line in reversed(lines):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        src = str(ev.get("source", ""))
        cat = str(ev.get("category", ""))
        if src.startswith(MESH_SOURCES) or cat in ("mesh", "peer"):
            out.append(ev)
            if len(out) >= limit:
                break
    return out
