"""net_data — what the Network tab shows, read without privilege (#107-#109).

@decision DEC-PHASE13-022
@title The Network tab reads, and only a visible terminal changes anything
@status accepted
@rationale The tab was a list of NetworkManager connection names and one
  button. It now shows per-interface state and rates, traffic by protocol,
  third-party VPN connections and PCAP capture, and every one of those reads
  comes from somewhere the operator can already read:
    - interfaces, routes and DNS: deck_vitals (`ip -j`, /proc/net/dev,
      resolv.conf), the parser Awareness and the Workbench already use;
    - protocol counters: /proc/net/snmp{,6} through deck_vitals.parse_snmp —
      system-wide, because per-protocol counts per interface need packet
      capture or Zeek (issue #93), not a /proc read;
    - VPNs: `nmcli` connections of type vpn or wireguard (DEC-PHASE13-014);
    - capture: the `capture` key of /run/orionx/posture-status.json, the one
      runtime-truth authority (DEC-PHASE12-028); the ring itself is root's.
  Connect/disconnect go through nmcli as the session user (NetworkManager's
  polkit policy allows network control for the active local session).
  Importing a provider's .conf, and starting, stopping or exporting a capture,
  run in a terminal with sudo, the Cockpit's never-silent-sudo convention
  (mesh.py:5-8). The mesh's own wg0 is the Mesh tab's and is not listed here.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

_SCRIPTS = Path(__file__).resolve().parents[2]
if str(_SCRIPTS / "awareness") not in sys.path:
    sys.path.insert(0, str(_SCRIPTS / "awareness"))
import deck_vitals as V  # noqa: E402

POSTURE_STATUS = Path("/run/orionx/posture-status.json")
EXPORT_DIR = Path.home() / "Captures"        # where `orionx-capture export` lands
STATUS_STALE_S = 60                          # postured rewrites it every few seconds
MESH_IFACES = {"wg0"}                        # the Mesh tab owns these
# Fallback devices the kernel creates whenever a tunnel module loads. They are
# never configured and carry nothing; listing them buried the real interfaces.
KERNEL_FALLBACK = {"gre0", "gretap0", "erspan0", "ip_vti0", "ip6_vti0", "ip6tnl0",
                   "ip6gre0", "sit0", "tunl0"}
PROTOCOLS = ("tcp", "udp", "icmp")
VPN_TYPES = {"vpn", "wireguard"}
# NetworkManager names an imported WireGuard connection, and its interface,
# after the file: Linux interface names are at most 15 characters.
WG_IMPORT_NAME = re.compile(r"^[A-Za-z0-9_=+.-]{1,15}$")


def _run(cmd: list[str], timeout: float = 3.0) -> tuple[int, str]:
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return res.returncode, res.stdout
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, str(exc)


def _read(path: str | Path) -> str:
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def split_nmcli_terse(line: str) -> list[str]:
    r"""Split one `nmcli -t` line: fields are ':'-separated, '\:' and '\\' escaped."""
    fields, cur, i = [], [], 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and i + 1 < len(line):
            cur.append(line[i + 1])
            i += 2
            continue
        if ch == ":":
            fields.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    fields.append("".join(cur))
    return fields


def parse_vpn_connections(text: str) -> list[dict[str, Any]]:
    """`nmcli -t -f NAME,UUID,TYPE,DEVICE,ACTIVE connection show` -> VPN rows."""
    out = []
    for line in (text or "").splitlines():
        f = split_nmcli_terse(line)
        if len(f) < 5 or f[2] not in VPN_TYPES or f[3] in MESH_IFACES:
            continue
        out.append({"name": f[0], "uuid": f[1], "type": f[2],
                    "device": f[3] or None, "active": f[4] == "yes"})
    return sorted(out, key=lambda c: (not c["active"], c["name"].lower()))


def wg_import_problem(path: str | Path) -> str | None:
    """Why NetworkManager would refuse to import this WireGuard file, or None."""
    p = Path(path)
    if p.suffix != ".conf":
        return f"{p.name}: a WireGuard config file ends in .conf"
    if not WG_IMPORT_NAME.match(p.stem):
        short = re.sub(r"[^A-Za-z0-9_=+.-]", "-", p.stem)[:15].strip("-") or "vpn"
        return (f"NetworkManager names the connection and its interface after the "
                f"file, and '{p.stem}' is not a valid interface name (at most 15 "
                f"letters, digits or - _ . = +). Rename it, e.g. {short}.conf")
    return None


def capture_state(status_path: Path = POSTURE_STATUS, now: float | None = None) -> dict[str, Any]:
    """Running captures from postured's status file, or why that is unknown."""
    now = time.time() if now is None else now
    text = _read(status_path)
    if not text:
        return {"known": False, "captures": [],
                "reason": f"{status_path} not readable — is orionx-postured running? "
                          "(sudo systemctl status orionx-postured)"}
    try:
        status = json.loads(text)
    except ValueError:
        return {"known": False, "captures": [], "reason": f"{status_path} is not valid JSON"}
    age = now - float(status.get("ts") or 0)
    if age > STATUS_STALE_S:
        return {"known": False, "captures": [],
                "reason": f"orionx-postured last wrote its status {age:.0f}s ago — "
                          "capture state may be out of date"}
    caps = [c for c in status.get("capture") or [] if isinstance(c, dict) and c.get("iface")]
    for c in caps:
        try:
            c["elapsed_s"] = max(0.0, now - float(c.get("started") or now))
        except (TypeError, ValueError):
            c["elapsed_s"] = None
    return {"known": True, "captures": caps, "reason": ""}


def latest_export(export_dir: Path = EXPORT_DIR) -> Path | None:
    """The newest capture copy the operator owns, for "Open in Wireshark"."""
    try:
        found = [p for p in export_dir.glob("*.pcapng") if p.is_file()]
    except OSError:
        return None
    return max(found, key=lambda p: p.stat().st_mtime) if found else None


def protocol_rows(rates: dict[str, float]) -> list[dict[str, Any]]:
    """[{proto, in_s, out_s, share}] where share is of all TCP+UDP+ICMP packets/s."""
    totals = {p: rates.get(f"{p}_in", 0.0) + rates.get(f"{p}_out", 0.0) for p in PROTOCOLS}
    grand = sum(totals.values())
    return [{"proto": p.upper(), "in_s": rates.get(f"{p}_in"), "out_s": rates.get(f"{p}_out"),
             "share": (totals[p] / grand) if grand else 0.0} for p in PROTOCOLS]


def interface_rows(ifaces: list[dict[str, Any]], rates: dict[str, dict[str, float]],
                   counters: dict[str, dict[str, int]]) -> list[dict[str, Any]]:
    """One row per interface with its addresses, rates and share of traffic."""
    by_name = {i["iface"]: i for i in ifaces}
    names = sorted((set(by_name) | set(counters)) - KERNEL_FALLBACK)
    load = {n: rates.get(n, {}).get("rx_bytes", 0.0) + rates.get(n, {}).get("tx_bytes", 0.0)
            for n in names}
    grand = sum(load.values())
    rows = []
    for n in names:
        it = by_name.get(n, {})
        r = rates.get(n, {})
        rows.append({
            "iface": n, "state": (it.get("state") or "unknown").lower(),
            "addrs": list(it.get("ipv4") or []) + list(it.get("ipv6") or []),
            "rx_s": r.get("rx_bytes"), "tx_s": r.get("tx_bytes"),
            "rx_total": counters.get(n, {}).get("rx_bytes"),
            "tx_total": counters.get(n, {}).get("tx_bytes"),
            "share": (load[n] / grand) if grand else 0.0,
            "mesh": n in MESH_IFACES,
        })
    return rows


class NetSampler:
    """Collects one Network-tab snapshot per call; keeps the previous counters
    so rates come from consecutive polls (worker thread only)."""

    def __init__(self, run: Callable[[list[str]], tuple[int, str]] = _run,
                 read: Callable[[str | Path], str] = _read,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.run, self.read, self.clock = run, read, clock
        self._prev: tuple[float, dict, dict] | None = None

    def collect(self) -> dict[str, Any]:
        now = self.clock()
        dev = V.parse_net_dev_by_iface(self.read("/proc/net/dev"))
        snmp = V.parse_snmp(self.read("/proc/net/snmp"), self.read("/proc/net/snmp6"))
        if_rates: dict[str, dict[str, float]] = {}
        proto_rates: dict[str, float] = {}
        if self._prev:
            t0, dev0, snmp0 = self._prev
            dt = now - t0
            if_rates = {n: V.per_second(dev0.get(n), c, dt) for n, c in dev.items()}
            proto_rates = V.per_second(snmp0, snmp, dt)
        self._prev = (now, dev, snmp)
        _rc, addr = self.run(["ip", "-j", "addr"])
        _rc, route = self.run(["ip", "-j", "route", "show", "default"])
        ifaces = V.parse_ip_addr(addr)
        rc, nm = self.run(["nmcli", "-t", "-f", "NAME,UUID,TYPE,DEVICE,ACTIVE", "connection", "show"])
        return {
            "interfaces": interface_rows(ifaces, if_rates, dev),
            "route": V.parse_default_route(route),
            "dns": V.parse_resolv_conf(self.read("/etc/resolv.conf")),
            "protocols": protocol_rows(proto_rates) if proto_rates else [],
            "tcp_established": snmp.get("tcp_established"),
            "snmp_readable": bool(snmp),
            "vpns": parse_vpn_connections(nm) if rc == 0 else [],
            "vpn_error": None if rc == 0 else f"nmcli failed ({rc}): {nm.strip()[:120]}",
            "capture": capture_state(),
            "export": latest_export(),
        }
