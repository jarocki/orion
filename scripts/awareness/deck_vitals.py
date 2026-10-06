#!/usr/bin/env python3
"""deck_vitals — what this deck is, where it is on the network, and how it is doing.

@decision DEC-PHASE12-049
@title Deck vitals come from one module, read by the Cockpit and the Workbench
@status accepted
@rationale On the reference deck (2026-10-05) neither the Cockpit nor the
  Workbench could say the deck's own hostname, addresses, gateway, disk,
  memory or CPU — the operator had to open a terminal to learn where the
  machine they were defending actually was. Two surfaces each growing their
  own readers would be two answers to "what is my IP"; this module is the
  one answer, and both draw from it.

  Parsers are PURE (text in, dict out) so they are testable against fixtures
  with no root, no network and no display. collect() wraps them with thin
  readers and NEVER raises: every field is independently None with a reason
  when it cannot be read, because a dashboard that crashes on a missing
  /proc file tells the operator less than one that shows a dash.

  Reads only. Nothing here changes the system. stdlib only.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from typing import Any, Callable

PROC_MEMINFO = "/proc/meminfo"
PROC_STAT = "/proc/stat"
PROC_LOADAVG = "/proc/loadavg"
PROC_UPTIME = "/proc/uptime"
SKIP_IFACES = ("lo",)


# ---------------------------------------------------------------- pure parsers

def parse_meminfo(text: str) -> dict[str, Any]:
    """MemTotal/MemAvailable (kiB) and used_pct; None fields when absent."""
    vals: dict[str, int] = {}
    for line in (text or "").splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        parts = v.split()
        if parts and parts[0].isdigit():
            vals[k.strip()] = int(parts[0])
    total = vals.get("MemTotal")
    avail = vals.get("MemAvailable")
    used_pct = None
    if total and avail is not None and total > 0:
        used_pct = round(100.0 * (total - avail) / total, 1)
    return {"total_kib": total, "available_kib": avail, "used_pct": used_pct}


def parse_cpu_stat(text: str) -> tuple[int, int] | None:
    """(busy, total) jiffies from the aggregate 'cpu ' line, or None."""
    for line in (text or "").splitlines():
        if line.startswith("cpu "):
            f = line.split()[1:]
            if len(f) < 4:
                return None
            try:
                nums = [int(x) for x in f]
            except ValueError:
                return None
            idle = nums[3] + (nums[4] if len(nums) > 4 else 0)   # idle + iowait
            total = sum(nums)
            return (total - idle, total)
    return None


def cpu_percent(prev: tuple[int, int] | None, cur: tuple[int, int] | None) -> float | None:
    """Busy percentage between two /proc/stat samples; None without two."""
    if not prev or not cur:
        return None
    dt = cur[1] - prev[1]
    if dt <= 0:
        return None
    return round(max(0.0, min(100.0, 100.0 * (cur[0] - prev[0]) / dt)), 1)


def parse_loadavg(text: str) -> tuple[float, float, float] | None:
    p = (text or "").split()
    try:
        return (float(p[0]), float(p[1]), float(p[2]))
    except (IndexError, ValueError):
        return None


def parse_uptime(text: str) -> float | None:
    try:
        return float((text or "").split()[0])
    except (IndexError, ValueError):
        return None


def fmt_uptime(seconds: float | None) -> str:
    if seconds is None:
        return "—"
    s = int(seconds)
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m = s // 60
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {m:02d}m"
    return f"{m}m"


def parse_ip_addr(json_text: str) -> list[dict[str, Any]]:
    """`ip -j addr` -> [{iface, mac, state, ipv4:[cidr], ipv6:[cidr]}], lo skipped."""
    try:
        data = json.loads(json_text or "[]")
    except json.JSONDecodeError:
        return []
    out = []
    for it in data if isinstance(data, list) else []:
        name = str(it.get("ifname", ""))
        if not name or name in SKIP_IFACES:
            continue
        v4, v6 = [], []
        for a in it.get("addr_info", []) or []:
            fam = a.get("family")
            addr = a.get("local")
            if not addr:
                continue
            cidr = f"{addr}/{a.get('prefixlen', '')}".rstrip("/")
            if fam == "inet":
                v4.append(cidr)
            elif fam == "inet6" and a.get("scope") != "link":
                v6.append(cidr)
        out.append({"iface": name, "mac": it.get("address"), "state": it.get("operstate"),
                    "ipv4": v4, "ipv6": v6})
    return out


def parse_default_route(json_text: str) -> dict[str, Any]:
    """`ip -j route show default` -> {gateway, dev} or {}."""
    try:
        data = json.loads(json_text or "[]")
    except json.JSONDecodeError:
        return {}
    for r in data if isinstance(data, list) else []:
        if r.get("dst") in ("default", "0.0.0.0/0", None) and r.get("gateway"):
            return {"gateway": r.get("gateway"), "dev": r.get("dev")}
    return {}


def primary_ipv4(ifaces: list[dict[str, Any]], route: dict[str, Any]) -> tuple[str | None, str | None]:
    """(address, iface): the route interface's first IPv4, else the first non-wg IPv4."""
    dev = route.get("dev")
    for it in ifaces:
        if it["iface"] == dev and it["ipv4"]:
            return it["ipv4"][0].split("/")[0], it["iface"]
    for it in ifaces:
        if it["ipv4"] and not it["iface"].startswith(("wg", "docker", "veth", "br-")):
            return it["ipv4"][0].split("/")[0], it["iface"]
    return None, None


def fmt_bytes(n: float | None) -> str:
    if n is None:
        return "—"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.0f} {unit}" if unit in ("B", "KiB") else f"{n:.1f} {unit}"
        n /= 1024.0
    return "—"


# ---------------------------------------------------------------- thin readers

def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def _run(cmd: list[str], timeout: float = 2.0) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def disk(path: str = "/") -> dict[str, Any]:
    try:
        st = os.statvfs(path)
    except OSError:
        return {"path": path, "total_bytes": None, "free_bytes": None, "used_pct": None}
    total = st.f_blocks * st.f_frsize
    free = st.f_bavail * st.f_frsize
    used_pct = round(100.0 * (total - free) / total, 1) if total else None
    return {"path": path, "total_bytes": total, "free_bytes": free, "used_pct": used_pct}


def collect(prev_cpu: tuple[int, int] | None = None, sample: float = 0.0,
            run: Callable[..., str] = _run, read: Callable[[str], str] = _read,
            disk_path: str = "/") -> dict[str, Any]:
    """Everything, best effort. Never raises. 'cpu_sample' feeds the next call's prev_cpu.

    With prev_cpu=None and sample>0, two /proc/stat readings `sample` seconds
    apart give a one-shot CPU figure (the Workbench's status request). The
    Cockpit instead passes last poll's sample and gets a figure for free.
    """
    out: dict[str, Any] = {"generated": time.time(), "reasons": []}

    def _safe(fn: Callable[..., str], *args: Any) -> str:
        # The contract is "never raises" even when a caller injects a reader
        # that does (tests do exactly that). A failing reader is an empty read.
        try:
            return fn(*args) or ""
        except Exception:  # noqa: BLE001 - any reader failure is "unreadable"
            return ""
    try:
        out["hostname"] = socket.gethostname() or None
    except OSError:
        out["hostname"] = None
    if not out["hostname"]:
        out["reasons"].append("hostname: gethostname failed")
    cur = parse_cpu_stat(_safe(read, PROC_STAT))
    if cur and prev_cpu is None and sample > 0:
        time.sleep(sample)
        prev_cpu, cur = cur, parse_cpu_stat(_safe(read, PROC_STAT))
    out["cpu_sample"] = cur
    out["cpu_pct"] = cpu_percent(prev_cpu, cur)
    if cur is None:
        out["reasons"].append(f"cpu: {PROC_STAT} unreadable")
    out["cpu_count"] = os.cpu_count()
    out["load"] = parse_loadavg(_safe(read, PROC_LOADAVG))
    out["uptime_s"] = parse_uptime(_safe(read, PROC_UPTIME))
    out["mem"] = parse_meminfo(_safe(read, PROC_MEMINFO))
    if out["mem"]["total_kib"] is None:
        out["reasons"].append(f"mem: {PROC_MEMINFO} unreadable")
    out["disk"] = disk(disk_path)
    if out["disk"]["total_bytes"] is None:
        out["reasons"].append(f"disk: statvfs({disk_path}) failed")
    ifaces = parse_ip_addr(_safe(run, ["ip", "-j", "addr"]))
    route = parse_default_route(_safe(run, ["ip", "-j", "route", "show", "default"]))
    if not ifaces:
        out["reasons"].append("interfaces: `ip -j addr` returned nothing")
    out["interfaces"] = ifaces
    out["gateway"] = route.get("gateway")
    out["gateway_dev"] = route.get("dev")
    out["primary_ipv4"], out["primary_iface"] = primary_ipv4(ifaces, route)
    return out


if __name__ == "__main__":
    print(json.dumps(collect(sample=0.2), indent=2, default=str))
