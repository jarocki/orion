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


def parse_net_dev_by_iface(text: str) -> dict[str, dict[str, int]]:
    """/proc/net/dev per non-loopback interface: rx/tx bytes and packets."""
    out: dict[str, dict[str, int]] = {}
    for line in (text or "").splitlines():
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        name = name.strip()
        if name in SKIP_IFACES:
            continue
        f = rest.split()
        if len(f) < 10:
            continue
        try:
            out[name] = {"rx_bytes": int(f[0]), "rx_packets": int(f[1]),
                         "tx_bytes": int(f[8]), "tx_packets": int(f[9])}
        except ValueError:
            continue
    return out


def parse_net_dev(text: str) -> dict[str, int]:
    """/proc/net/dev totals over non-loopback interfaces: rx/tx bytes and packets."""
    out = {"rx_bytes": 0, "tx_bytes": 0, "rx_packets": 0, "tx_packets": 0}
    for counters in parse_net_dev_by_iface(text).values():
        for key in out:
            out[key] += counters[key]
    return out


# /proc/net/snmp{,6} counters behind the Network tab's protocol breakdown
# (#107). Tcp's segment counters already cover IPv4 and IPv6 (the kernel keeps
# one TCP MIB); UDP and ICMP have separate v6 counters, which are added in.
_SNMP_FIELDS = {
    ("Tcp", "InSegs"): "tcp_in", ("Tcp", "OutSegs"): "tcp_out",
    ("Tcp", "CurrEstab"): "tcp_established",
    ("Udp", "InDatagrams"): "udp_in", ("Udp", "OutDatagrams"): "udp_out",
    ("Icmp", "InMsgs"): "icmp_in", ("Icmp", "OutMsgs"): "icmp_out",
}
_SNMP6_FIELDS = {
    "Udp6InDatagrams": "udp_in", "Udp6OutDatagrams": "udp_out",
    "Icmp6InMsgs": "icmp_in", "Icmp6OutMsgs": "icmp_out",
}


def parse_snmp(text: str, text6: str = "") -> dict[str, int]:
    """Protocol counters from /proc/net/snmp (+ /proc/net/snmp6). Missing = absent."""
    out: dict[str, int] = {}
    lines = (text or "").splitlines()
    for names, values in zip(lines[::2], lines[1::2]):
        n_proto, _, n_rest = names.partition(":")
        v_proto, _, v_rest = values.partition(":")
        if n_proto != v_proto:
            continue
        for field, value in zip(n_rest.split(), v_rest.split()):
            key = _SNMP_FIELDS.get((n_proto, field))
            if key:
                try:
                    out[key] = int(value)
                except ValueError:
                    pass
    for line in (text6 or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in _SNMP6_FIELDS:
            try:
                key = _SNMP6_FIELDS[parts[0]]
                out[key] = out.get(key, 0) + int(parts[1])
            except ValueError:
                pass
    return out


def per_second(prev: dict[str, int] | None, cur: dict[str, int], dt: float) -> dict[str, float]:
    """Counter deltas over dt seconds; a counter that went backwards (reset) is 0."""
    if not prev or dt <= 0:
        return {}
    return {k: max(0, v - prev[k]) / dt for k, v in cur.items() if k in prev}


def parse_resolv_conf(text: str) -> list[str]:
    """nameserver entries from resolv.conf, in order, de-duplicated."""
    out: list[str] = []
    for line in (text or "").splitlines():
        s = line.strip()
        if s.startswith("nameserver"):
            parts = s.split()
            if len(parts) >= 2 and parts[1] not in out:
                out.append(parts[1])
    return out


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


# ---------------------------------------------------------------------------
# @decision DEC-PHASE13-063
# @category COCKPIT
# @title One table of resource thresholds; postured announces each crossing once, LIVE and Awareness colour by it
# @status accepted
# @rationale #202 (owner, 2026-11-25): "when resources are running low ...
#   all of this should be instantly observable and understandable from the
#   cyber deck cockpit." There were three threshold sets (LIVE bars 75/90 for
#   everything, Awareness memory 70/88 and disk 80/92) and no alarm: a full
#   disk was a red bar on a tab you might not be looking at. THRESHOLDS is now
#   the one table; resource_levels() grades a vitals snapshot by it, and both
#   surfaces colour from that. Crossings is the alarm: an upward crossing is
#   announced once, a level clears only HYSTERESIS points below its line (no
#   flapping at 89.9/90.1), and CPU must stay over a line for CPU_SUSTAIN_S
#   before it counts (a compile is not an incident). orionx-postured, the
#   always-on daemon whose events the broker signs, feeds it every
#   RESOURCE_POLL_S, so the alarm reaches R.A.I.N. and LIVE whether or not the
#   Cockpit is open. On a live stick "/" is the RAM-backed overlay: disk full
#   is memory full, hence the higher disk lines. Battery counts only when
#   discharging.
THRESHOLDS: dict[str, tuple[float, float]] = {   # name -> (amber at, red at), percent used
    "mem": (80.0, 90.0),
    "disk": (85.0, 95.0),
    "cpu": (85.0, 95.0),
    "battery": (80.0, 90.0),   # percent DRAINED (100 - charge): amber at 20 % left, red at 10 %
}
HYSTERESIS = 5.0
CPU_SUSTAIN_S = 60.0
RESOURCE_POLL_S = 10.0
LEVELS = ("ok", "amber", "red")
LABEL = {"mem": "memory", "disk": "disk /", "cpu": "CPU", "battery": "battery"}


def grade(name: str, pct: float | None) -> str:
    """'ok' | 'amber' | 'red' | 'unknown' for one resource, with no memory of the past."""
    if pct is None or name not in THRESHOLDS:
        return "unknown"
    amber, red = THRESHOLDS[name]
    return "red" if pct >= red else "amber" if pct >= amber else "ok"


def resource_pcts(v: dict[str, Any]) -> dict[str, float | None]:
    """The four graded figures from a vitals snapshot (battery: drained %, only when discharging)."""
    bat = v.get("battery") or {}
    drained = (100.0 - bat["pct"]) if bat.get("pct") is not None and bat.get("status") == "Discharging" else None
    return {"mem": (v.get("mem") or {}).get("used_pct"), "disk": (v.get("disk") or {}).get("used_pct"),
            "cpu": v.get("cpu_pct"), "battery": drained}


def resource_levels(v: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {k: {"pct": p, "level": grade(k, p)} for k, p in resource_pcts(v).items()}


class Crossings:
    """Announce each resource level change once, with hysteresis and a CPU sustain window."""

    def __init__(self) -> None:
        self.level: dict[str, str] = {}
        self._cpu_since: dict[str, float] = {}

    def _held(self, name: str, pct: float, current: str) -> str:
        """The level `pct` implies given where we are now (clear only HYSTERESIS below a line)."""
        amber, red = THRESHOLDS[name]
        raw = grade(name, pct)
        if LEVELS.index(raw) >= LEVELS.index(current):
            return raw
        if current == "red" and pct > red - HYSTERESIS:
            return "red"
        if current in ("red", "amber") and pct > amber - HYSTERESIS:
            return "amber"
        return raw

    def update(self, pcts: dict[str, float | None], now: float) -> list[tuple[str, str, str, float]]:
        """[(name, old, new, pct), ...] for every level change since the last update."""
        out = []
        for name, pct in pcts.items():
            if pct is None or name not in THRESHOLDS:
                continue
            cur = self.level.get(name, "ok")
            new = self._held(name, pct, cur)
            if name == "cpu" and LEVELS.index(new) > LEVELS.index(cur):
                since = self._cpu_since.setdefault(new, now)
                if now - since < CPU_SUSTAIN_S:
                    continue
            if name == "cpu":
                for lv in list(self._cpu_since):
                    if LEVELS.index(lv) > LEVELS.index(new) or lv == new:
                        self._cpu_since.pop(lv, None)
            if new != cur:
                self.level[name] = new
                out.append((name, cur, new, pct))
        return out


def crossing_event(name: str, old: str, new: str, pct: float, v: dict[str, Any]) -> tuple[str, str]:
    """(severity, message) for one crossing, saying what to look at."""
    what = LABEL.get(name, name)
    if name == "battery":
        figure = f"{100 - pct:.0f}% left"
    elif name == "disk":
        figure = f"{pct:.0f}% used, {fmt_bytes((v.get('disk') or {}).get('free_bytes'))} free"
    else:
        figure = f"{pct:.0f}%"
    if new == "ok":
        return "notice", f"Deck {what} back to normal ({figure})"
    sev = "critical" if new == "red" else "warning"
    hint = {"disk": " — on a live stick this is RAM: clear captures or ~/Analysis",
            "mem": " — the largest processes: ps aux --sort=-rss | head",
            "cpu": " — sustained for over a minute",
            "battery": " — connect power"}.get(name, "")
    return sev, f"Deck {what} {new.upper()}: {figure}{hint}"


def battery(read: Callable[[str], str] = _read, root: str = "/sys/class/power_supply") -> dict[str, Any] | None:
    """{'pct', 'status'} of the first battery, or None (desktop, VM)."""
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return None
    for n in names:
        if (read(f"{root}/{n}/type") or "").strip() != "Battery":
            continue
        try:
            pct = float((read(f"{root}/{n}/capacity") or "").strip())
        except ValueError:
            continue
        return {"pct": pct, "status": (read(f"{root}/{n}/status") or "").strip() or "Unknown"}
    return None


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
    out["battery"] = battery(lambda path: _safe(read, path))
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
    out["net"] = parse_net_dev(_safe(read, "/proc/net/dev"))
    out["dns"] = parse_resolv_conf(_safe(read, "/etc/resolv.conf"))
    return out


if __name__ == "__main__":
    print(json.dumps(collect(sample=0.2), indent=2, default=str))
