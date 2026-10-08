#!/usr/bin/env bash
# deck_vitals: pure parsers against fixtures; collect() never raises.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
if python3 - "$ROOT/scripts/awareness" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1]); import deck_vitals as V
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
m = V.parse_meminfo("MemTotal:  4000000 kB\nMemFree: 100 kB\nMemAvailable: 1000000 kB\nSwapTotal: 0 kB\n")
ck(m["total_kib"] == 4000000 and m["available_kib"] == 1000000 and m["used_pct"] == 75.0, f"meminfo -> 75% used ({m})")
ck(V.parse_meminfo("")["used_pct"] is None, "empty meminfo -> None, not a crash")
a = V.parse_cpu_stat("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3 4\n")
b = V.parse_cpu_stat("cpu  200 0 200 800 100 0 0 0 0 0\n")
ck(a == (200, 1000) and b == (400, 1300), f"cpu stat busy/total ({a}, {b})")
ck(V.cpu_percent(a, b) == 66.7, f"cpu percent between samples = {V.cpu_percent(a, b)}")
ck(V.cpu_percent(None, b) is None and V.cpu_percent(b, b) is None, "no two samples -> None")
ck(V.parse_loadavg("0.42 0.30 0.20 1/300 1234") == (0.42, 0.30, 0.20), "loadavg")
ck(V.fmt_uptime(V.parse_uptime("4980.12 9000")) == "1h 23m", f"uptime -> {V.fmt_uptime(V.parse_uptime('4980.12 9000'))}")
ck(V.fmt_uptime(None) == "\u2014" and V.fmt_uptime(90000) == "1d 1h", "uptime formats")
ipj = json.dumps([
 {"ifname":"lo","operstate":"UNKNOWN","addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8}]},
 {"ifname":"wlan0","address":"aa:bb:cc:dd:ee:ff","operstate":"UP","addr_info":[
    {"family":"inet","local":"192.168.4.57","prefixlen":24},
    {"family":"inet6","local":"fe80::1","prefixlen":64,"scope":"link"},
    {"family":"inet6","local":"2001:db8::7","prefixlen":64,"scope":"global"}]},
 {"ifname":"wg0","operstate":"UNKNOWN","addr_info":[{"family":"inet","local":"10.0.99.75","prefixlen":24}]}])
ifs = V.parse_ip_addr(ipj)
ck([i["iface"] for i in ifs] == ["wlan0","wg0"], "lo skipped, order kept")
ck(ifs[0]["ipv4"] == ["192.168.4.57/24"] and ifs[0]["ipv6"] == ["2001:db8::7/64"], "v4 kept, link-local v6 dropped, global v6 kept")
ck(ifs[0]["mac"] == "aa:bb:cc:dd:ee:ff", "mac carried")
rt = V.parse_default_route(json.dumps([{"dst":"default","gateway":"192.168.4.1","dev":"wlan0"}]))
ck(rt == {"gateway":"192.168.4.1","dev":"wlan0"}, f"default route -> {rt}")
ck(V.primary_ipv4(ifs, rt) == ("192.168.4.57","wlan0"), "primary = the route interface's address")
ck(V.primary_ipv4(ifs, {}) == ("192.168.4.57","wlan0"), "no route -> first non-tunnel address, not wg0")
ck(V.parse_ip_addr("not json") == [] and V.parse_default_route("{") == {}, "garbage JSON -> empty, no crash")
ck(V.fmt_bytes(3.1*1024**3).startswith("3.1 GiB") and V.fmt_bytes(None) == "\u2014", "bytes format")
# collect() must survive every reader failing.
def boom(*a, **k): raise OSError("nope")
d = V.collect(run=boom, read=boom, disk_path="/nonexistent/path")
ck(d["cpu_pct"] is None and d["mem"]["used_pct"] is None and d["disk"]["used_pct"] is None and d["interfaces"] == [], "collect with every reader failing -> Nones")
ck(any("cpu:" in r for r in d["reasons"]) and any("disk:" in r for r in d["reasons"]), f"and says why: {d['reasons']}")
ck("hostname" in d and "generated" in d and "cpu_sample" in d, "schema keys present")
# A real collect on this host must not raise either.
real = V.collect(sample=0.05)
ck(isinstance(real.get("interfaces"), list), "real collect returns an interface list")
PY
then pass "deck_vitals pure parsers + fail-safe collect (DEC-PHASE12-049)"; else fail "deck_vitals assertions" "see output above"; fi
grep -q "DEC-PHASE12-049" "$ROOT/scripts/awareness/deck_vitals.py" && pass "decision annotated at the point of implementation" || fail "DEC-PHASE12-049 annotation" "missing"
grep -qE "subprocess\.run|os\.system|Popen" "$ROOT/scripts/awareness/deck_vitals.py" && ! grep -qE "\b(ip|nmcli) (link|addr) (add|set|del)|sysctl -w|iptables|nft " "$ROOT/scripts/awareness/deck_vitals.py" && pass "reads only: no command in the module mutates the system" || fail "read-only" "a mutating command appears in deck_vitals.py"
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
