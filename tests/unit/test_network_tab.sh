#!/usr/bin/env bash
# Network tab data layer (#107-#109, DEC-PHASE13-022): interface and protocol
# rates, VPN rows from nmcli, capture state from postured, the WireGuard
# import-name rule, and the per-interface /proc/net/dev parser — on fixtures.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "$ROOT/tmp/network-tab.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
if python3 - "$ROOT/scripts" "$WORK" <<'PY'
import json, sys, time
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from control_center.helpers import net_data as N
V = N.V
work = Path(sys.argv[2])
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)

dev = """Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 999 9 0 0 0 0 0 0 999 9 0 0 0 0 0 0
  eth0: 1000 10 0 0 0 0 0 0 500 5 0 0 0 0 0 0
   wg0: 200 2 0 0 0 0 0 0 100 1 0 0 0 0 0 0
"""
by = V.parse_net_dev_by_iface(dev)
ck(set(by) == {"eth0", "wg0"} and by["eth0"]["tx_bytes"] == 500, f"per-interface /proc/net/dev, lo skipped ({sorted(by)})")
ck(V.parse_net_dev(dev) == {"rx_bytes": 1200, "tx_bytes": 600, "rx_packets": 12, "tx_packets": 6},
   "totals are the sum of the per-interface parse (one parser)")
snmp = "Tcp: RtoAlgorithm CurrEstab InSegs OutSegs\nTcp: 1 4 100 80\nUdp: InDatagrams OutDatagrams\nUdp: 10 6\nIcmp: InMsgs OutMsgs\nIcmp: 2 1\n"
s6 = "Udp6InDatagrams 5\nUdp6OutDatagrams 4\nIcmp6InMsgs 1\nIcmp6OutMsgs 0\n"
p = V.parse_snmp(snmp, s6)
ck(p == {"tcp_established": 4, "tcp_in": 100, "tcp_out": 80, "udp_in": 15, "udp_out": 10,
         "icmp_in": 3, "icmp_out": 1}, f"snmp + snmp6: v6 UDP/ICMP added in ({p})")
ck(V.parse_snmp("") == {} and V.per_second(None, {"a": 1}, 1) == {}, "no counters / first sample -> empty, not a crash")
ck(V.per_second({"a": 50}, {"a": 10}, 2) == {"a": 0.0}, "a counter reset reads 0/s, not negative")

rows = N.protocol_rows({"tcp_in": 60, "tcp_out": 20, "udp_in": 15, "udp_out": 5, "icmp_in": 0, "icmp_out": 0})
ck([r["proto"] for r in rows] == ["TCP", "UDP", "ICMP"] and abs(rows[0]["share"] - 0.8) < 1e-9
   and rows[2]["share"] == 0.0, f"protocol shares of total packets/s ({[round(r['share'], 2) for r in rows]})")
ck(all(r["share"] == 0.0 for r in N.protocol_rows({})), "no traffic -> 0% everywhere, no division by zero")

ifs = [{"iface": "eth0", "state": "UP", "ipv4": ["10.0.0.5/24"], "ipv6": []},
       {"iface": "wg0", "state": "UNKNOWN", "ipv4": ["10.99.0.1/24"], "ipv6": []}]
ir = N.interface_rows(ifs, {"eth0": {"rx_bytes": 300.0, "tx_bytes": 100.0}, "wg0": {"rx_bytes": 100.0, "tx_bytes": 0.0}}, by)
ck([r["iface"] for r in N.interface_rows([], {}, {"sit0": {"rx_bytes": 0, "tx_bytes": 0}, "eth0": by["eth0"]})] == ["eth0"],
   "kernel fallback tunnel devices (sit0, gre0, …) are not listed")
ck([r["iface"] for r in ir] == ["eth0", "wg0"] and abs(ir[0]["share"] - 0.8) < 1e-9
   and ir[1]["mesh"] and ir[0]["state"] == "up", "interface rows: rates, share of bytes/s, mesh flagged")

nm = ("Home Wi-Fi:1111:802-11-wireless:wlan0:yes\n"
      "mullvad-nyc:2222:wireguard:mullvad-nyc:yes\n"
      "Work\\: VPN:3333:vpn::no\n"
      "mesh:4444:wireguard:wg0:yes\n")
v = N.parse_vpn_connections(nm)
ck([c["name"] for c in v] == ["mullvad-nyc", "Work: VPN"], f"only vpn/wireguard rows, mesh wg0 left to the Mesh tab, escaped ':' kept ({[c['name'] for c in v]})")
ck(v[0]["active"] and v[0]["device"] == "mullvad-nyc" and not v[1]["active"] and v[1]["device"] is None,
   "active state and device read")
ck(N.split_nmcli_terse(r"a\\b:c\:d:") == ["a\\b", "c:d", ""], "nmcli terse escapes")

ck(N.wg_import_problem("/x/mullvad-nyc.conf") is None, "a short provider file name is importable")
long = N.wg_import_problem("/x/mullvad-us-nyc-wg-301.conf")
ck(long and "15" in long and "mullvad-us-nyc-.conf" not in long and ".conf" in long,
   f"a name too long for an interface is refused with a suggested rename ({long})")
ck(N.wg_import_problem("/x/provider.ovpn") is not None, "a non-.conf file is refused")

status = work / "posture-status.json"
ck(not N.capture_state(status)["known"], "no status file -> capture state unknown, with a reason")
now = time.time()
status.write_text(json.dumps({"ts": now - 2, "capture": [{"iface": "eth0", "budget_mb": 512, "duration": 900,
                                                         "started": now - 30, "out_path": "/var/lib/orionx/capture/eth0/eth0.pcapng"}]}))
cs = N.capture_state(status, now=now)
ck(cs["known"] and cs["captures"][0]["iface"] == "eth0" and 29 <= cs["captures"][0]["elapsed_s"] <= 31,
   "running capture read from postured, with elapsed time")
status.write_text(json.dumps({"ts": now - 600, "capture": []}))
st = N.capture_state(status, now=now)
ck(not st["known"] and "600s ago" in st["reason"], f"a stale status file is not trusted ({st['reason']})")

exp = work / "Captures"; exp.mkdir()
ck(N.latest_export(exp) is None, "no copies -> nothing to open")
(exp / "eth0_00001.pcapng").write_text("a"); time.sleep(0.02); (exp / "eth0_00002.pcapng").write_text("b")
ck(N.latest_export(exp).name == "eth0_00002.pcapng", "Open in Wireshark picks the newest copy")

reads = {"/proc/net/dev": [dev, dev.replace("eth0: 1000 10", "eth0: 3000 30").replace("0 0 500 5", "0 0 1500 15")],
         "/proc/net/snmp": [snmp, snmp.replace("Tcp: 1 4 100 80", "Tcp: 1 4 300 180")],
         "/proc/net/snmp6": [s6, s6], "/etc/resolv.conf": ["nameserver 9.9.9.9\n"] * 2}
calls = {"n": 0}
clock = iter([100.0, 102.0])
def fake_read(path):
    seq = reads.get(str(path), [""])
    return seq[min(calls["n"], len(seq) - 1)]
def fake_run(cmd):
    if cmd[:3] == ["ip", "-j", "addr"]:
        return 0, json.dumps([{"ifname": "eth0", "operstate": "UP", "addr_info": [{"family": "inet", "local": "10.0.0.5", "prefixlen": 24}]}])
    if cmd[:3] == ["ip", "-j", "route"]:
        return 0, json.dumps([{"dst": "default", "gateway": "10.0.0.1", "dev": "eth0"}])
    return 0, nm
sampler = N.NetSampler(run=fake_run, read=fake_read, clock=lambda: next(clock))
first = sampler.collect(); calls["n"] = 1; second = sampler.collect()
ck(first["protocols"] == [] and first["interfaces"][0]["rx_s"] is None, "first sample: no rates yet, said as such")
eth = next(r for r in second["interfaces"] if r["iface"] == "eth0")
ck(eth["rx_s"] == 1000.0 and eth["tx_s"] == 500.0, f"second sample: eth0 rates over 2 s ({eth['rx_s']}, {eth['tx_s']})")
tcp = second["protocols"][0]
ck(tcp["in_s"] == 100.0 and tcp["out_s"] == 50.0, f"TCP segments/s over 2 s ({tcp['in_s']}, {tcp['out_s']})")
ck(second["route"]["gateway"] == "10.0.0.1" and second["dns"] == ["9.9.9.9"] and len(second["vpns"]) == 2,
   "route, DNS and VPN rows land in the snapshot")
failing = N.NetSampler(run=lambda cmd: (127, "nmcli: not found") if cmd[0] == "nmcli" else fake_run(cmd), read=fake_read)
ck(failing.collect()["vpn_error"].startswith("nmcli failed"), "a failing nmcli is reported, not shown as 'no VPNs'")
PY
then echo "Results: network tab data layer OK"; else echo "Results: FAILED"; exit 1; fi
