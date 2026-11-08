#!/usr/bin/env bash
# gateway_probes (#94, DEC-PHASE13-047): offline parsers for SSDP, the device
# description and IGD SOAP; Part B (upstream probes) refused on EVERY tier in
# osint_server.OUTBOUND_BLOCKED_TIERS with the posture named and no transmitter
# called; Part A never runs automatically (no SSDP transmit on import, on
# collect(), or on any GET the page makes); the module has no module-level
# side effects. Mirrors tests/unit/test_godseye.sh for the refusal shape.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AW="$ROOT/scripts/awareness"
SRV="$ROOT/scripts/osint"
FX="$ROOT/tests/fixtures/gateway"
WEB="$ROOT/iso/config/includes.chroot/opt/orionx/osint"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }

echo "[pure parsers against fixture strings: SSDP, device XML, SOAP, DNS wire format]"
if python3 -I - "$AW" "$FX" <<'PY'
import sys, struct
from pathlib import Path
sys.path.insert(0, sys.argv[1]); import gateway_probes as GP
FX = Path(sys.argv[2])
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)

r = GP.parse_ssdp_response((FX / "ssdp_response.txt").read_bytes())
ck(r["location"] == "http://192.168.4.1:5000/rootDesc.xml" and "MiniUPnPd" in r["server"]
   and r["st"].endswith("InternetGatewayDevice:1"), f"SSDP 200 answer -> location/server/st ({r['location']})")
ck(GP.parse_ssdp_response(b"NOTIFY * HTTP/1.1\r\nLOCATION: http://192.168.4.1/\r\n\r\n") is None, "a NOTIFY is not an M-SEARCH answer")
ck(GP.parse_ssdp_response(b"HTTP/1.1 200 OK\r\nST: x\r\n\r\n") is None, "an answer without LOCATION is ignored")
ck(GP.parse_ssdp_response(b"\xff\xfe garbage") is None, "garbage datagram -> None, no exception")

for url in ("http://192.168.4.1:5000/rootDesc.xml", "http://10.0.0.1/d.xml", "http://169.254.1.1/d.xml", "http://[fe80::1]/d.xml"):
    ck(GP.location_is_local(url)[0], f"local LOCATION followed: {url}")
for url, why in (("http://93.184.216.34/d.xml", "not a local"), ("https://192.168.4.1/d.xml", "not http"),
                 ("http://router.lan/d.xml", "a name"), ("http://127.0.0.1/d.xml", "not a segment"),
                 ("http://239.255.255.250:1900/", "not a segment"), ("file:///etc/passwd", "not http")):
    ok, reason = GP.location_is_local(url)
    ck(not ok and why in reason, f"LOCATION refused, never followed: {url} ({reason})")

d = GP.parse_device_description((FX / "rootDesc.xml").read_text(encoding="utf-8"))
ck((d["friendly_name"], d["manufacturer"], d["model_name"], d["model_number"]) ==
   ("Fixture Gateway R7000", "NETGEAR", "R7000", "R7000-100NAS"), f"root device identity, namespaced XML ({d['friendly_name']})")
ck(GP.find_service(d["services"], GP.WAN_IP_SERVICES)["control_url"] == "/ctl/IPConn"
   and GP.find_service(d["services"], (GP.WAN_LINK_SERVICE,))["control_url"] == "/ctl/CmnIfCfg",
   "WANIPConnection and WANCommonInterfaceConfig found in nested deviceLists")
for bad in ('<!DOCTYPE r [<!ENTITY a "aaaa">]><root>&a;</root>', '<root><!ENTITY x SYSTEM "file:///etc/passwd"></root>'):
    try:
        GP.parse_device_description(bad); ck(False, "DTD/ENTITY accepted")
    except ValueError as exc:
        ck("refused" in str(exc), f"DTD/ENTITY refused before parsing ({exc})")

ip = GP.parse_soap_response((FX / "soap_external_ip.xml").read_text(encoding="utf-8"), "GetExternalIPAddress")
ck(ip == {"NewExternalIPAddress": "100.72.14.9"}, f"GetExternalIPAddressResponse ({ip})")
ln = GP.parse_soap_response((FX / "soap_link.xml").read_text(encoding="utf-8"), "GetCommonLinkProperties")
ck(ln["NewLayer1DownstreamMaxBitRate"] == "1000000000" and ln["NewWANAccessType"] == "Ethernet", "GetCommonLinkPropertiesResponse")
f = GP.parse_soap_response((FX / "soap_fault.xml").read_text(encoding="utf-8"), "GetExternalIPAddress")
ck(f["fault"] == {"code": "401", "description": "Invalid Action"}, f"UPnP fault surfaced, not swallowed ({f})")
try:
    GP.parse_soap_response("<a/>", "GetExternalIPAddress"); ck(False, "empty SOAP accepted")
except ValueError:
    ck(True, "a SOAP body with neither response nor fault is an error")
env = GP.soap_envelope("urn:schemas-upnp-org:service:WANIPConnection:1", "GetExternalIPAddress")
ck("<u:GetExternalIPAddress xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">" in env, "SOAP envelope names the action and service")

for addr, want in (("100.72.14.9", "carrier-grade NAT"), ("192.168.1.10", "behind another NAT"), ("0.0.0.0", "unspecified"),
                   ("203.0.113.7", "not a routable"), ("8.8.8.8", "public address"), ("", "none reported"), ("x", "not an IP")):
    ck(want in GP.classify_external_ip(addr), f"claimed WAN {addr!r} -> {GP.classify_external_ip(addr)}")
ck(GP.fmt_bitrate("1000000000") == "1.0 Gbit/s" and GP.fmt_bitrate("35000000") == "35 Mbit/s" and GP.fmt_bitrate("0") is None
   and GP.fmt_bitrate(None) is None, "bit rates formatted; 0/absent -> None, never '0 bit/s'")

q = GP.build_dns_query("dns.google", 0xBEEF)
ck(q[:4] == b"\xbe\xef\x01\x00" and q[12:] == b"\x03dns\x06google\x00\x00\x01\x00\x01", "DNS query: id, RD, QNAME, A/IN")
ans = b"".join(b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 300, 4) + bytes(a) for a in ((8, 8, 8, 8), (8, 8, 4, 4)))
resp = struct.pack(">HHHHHH", 0xBEEF, 0x8180, 1, 2, 0, 0) + q[12:] + ans
ck(GP.parse_dns_response(resp, 0xBEEF)["answers"] == ["8.8.8.8", "8.8.4.4"], "DNS answer: compressed names, two A records")
nx = GP.parse_dns_response(struct.pack(">HHHHHH", 7, 0x8183, 1, 0, 0, 0) + q[12:], 7)
ck(nx["rcode_name"] == "NXDOMAIN" and nx["answers"] == [], "NXDOMAIN parsed")
for bad, tx, why in ((resp, 0x1234, "id mismatch"), (b"\x00" * 5, 0, "short"), (q, 0xBEEF, "not a response")):
    try:
        GP.parse_dns_response(bad, tx); ck(False, why + " accepted")
    except ValueError as exc:
        ck(True, f"DNS {why} -> ValueError ({exc})")
PY
then pass "parsers: SSDP, LOCATION policy, device XML (DTD refused), SOAP + fault, WAN class, DNS wire"; else fail "parsers" "see output above"; fi

echo "[Part A with fakes: identity populates, every value labelled a claim; no answer is said so]"
if python3 -I - "$AW" "$FX" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2])
import gateway_probes as GP, fakes
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
log = fakes.install(GP)
e = GP.run_gateway()
r = e["result"]
ck(e["id"] == "gateway" and e["state"] == "done" and set(e) >= {"id", "label", "state", "gated_by", "result"},
   "entry carries {id, label, state, gated_by, result} — the shape the page renders")
ck(r["device"]["manufacturer"] == "NETGEAR" and r["device"]["model_name"] == "R7000" and r["device"]["friendly_name"] == "Fixture Gateway R7000",
   "identity fields populate from the description")
ck(r["wan"]["external_ip"] == "100.72.14.9" and "carrier-grade" in r["wan"]["external_ip_class"] and r["wan"]["downstream_label"] == "1.0 Gbit/s"
   and r["wan"]["upstream_label"] == "35 Mbit/s" and r["wan"]["access_type"] == "Ethernet", "WAN claims populate")
L = GP.GATEWAY_CLAIM_LABEL
ck(L == "reported by the gateway, not measured" and r["claim_label"] == L and r["device"]["claim_label"] == L
   and r["wan"]["claim_label"] == L and e["claim_label"] == L, "every gateway section carries the fixed claim label")
ck([x[0] for x in log] == ["ssdp", "get", "soap", "soap"] and log[1][1] == "http://192.168.4.1:5000/rootDesc.xml"
   and log[2][1] == "http://192.168.4.1:5000/ctl/IPConn", f"sent exactly: 1 search, 1 GET, 2 SOAP POSTs ({log})")
ck(len(r["sent"]) == 4 and "239.255.255.250:1900" in r["sent"][0], "the result says what was sent")
caution = GP.run_gateway({"state": "shields-up", "headline": "Tier 2 · Deception — off-deck links disabled"})["result"]
ck("Tier 2 · Deception" in caution.get("caution", ""), "at a raised posture the result says the operator transmitted on a hostile segment")

log2 = fakes.install(GP, ssdp_answers=False)
n = GP.run_gateway()
ck(n["state"] == "no-answer" and n["result"]["answered"] is False and "No gateway answered" in n["result"]["note"]
   and [x[0] for x in log2] == ["ssdp"], f"no answer -> the page says so, nothing else sent ({n['result']['note'][:60]}...)")

# a gateway that names an internet LOCATION is not followed
log3 = fakes.install(GP)
GP.ssdp_discover = lambda *a, **k: [{"location": "http://93.184.216.34/rootDesc.xml", "st": "x"}]
o = GP.run_gateway()
ck(o["state"] == "no-answer" and o["result"]["skipped"][0]["why"].endswith("not followed") and not [x for x in log3 if x[0] == "get"],
   "an internet LOCATION is recorded as skipped and never fetched")
# a transmitter that raises still yields an answer, not an exception
def boom(*a, **k): raise OSError("network is unreachable")
GP.ssdp_discover = boom
x = GP.run_gateway()
ck(x["state"] == "error" and "network is unreachable" in x["result"]["errors"][0], "a failing transmitter -> state error with the reason")
PY
then pass "Part A: claims labelled, exact transmit list, no-answer stated, internet LOCATION not followed"; else fail "Part A" "see output above"; fi

echo "[Part B: refused on EVERY tier in OUTBOUND_BLOCKED_TIERS, posture named, nothing sent (mirrors test_godseye.sh)]"
if python3 -I - "$AW" "$SRV" <<'PY'
import sys
sys.path.insert(0, sys.argv[2]); sys.path.insert(0, sys.argv[1])
import osint_server as S, gateway_probes as GP
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
calls = []
def boom(*a, **k):
    calls.append(a); raise AssertionError("a transmitter ran on a refused verdict")
up = {"default_route": True, "interface": "eth0"}
ck(len(S.OUTBOUND_BLOCKED_TIERS) >= 1, f"blocked tiers declared once, in osint_server ({S.OUTBOUND_BLOCKED_TIERS})")
for tier in S.OUTBOUND_BLOCKED_TIERS:
    label = "Tier %s · Fixture" % tier
    v = S.outbound_verdict(S.read_posture('{"tier": "%s", "label": "%s"}' % (tier, label)), up)
    e = GP.run_outbound(v, system_q=boom, direct_q=boom, captive=boom, connect=boom)
    r = e.get("refusal") or {}
    ck(e["state"] == "refused" and e["result"] is None, f"tier {tier}: refused, no result")
    ck(label in r.get("headline", ""), f"tier {tier}: refusal names the posture ({r.get('headline')!r})")
    for field in ("headline", "what", "so_what", "still_works", "remedy"):
        ck(len(str(r.get(field) or "").strip()) >= 12, f"tier {tier}: refusal names {field}")
    ck(r["remedy"] == S.POSTURE_REMEDY and r["label"] == GP.PROBE_LABEL == "probe, posture-gated", f"tier {tier}: remedy is the server's, label is the probe label")
    ck(all(h in r["what"] for h in GP.third_parties()), f"tier {tier}: refusal names every party it would have contacted")
ck(calls == [], "no transmitter was called on any blocked tier")
for name, verdict in (("posture unknown", S.outbound_verdict(S.read_posture(None), up)),
                      ("no route", S.outbound_verdict(S.read_posture('{"tier": "0"}'), {"default_route": False}))):
    e = GP.run_outbound(verdict, system_q=boom, direct_q=boom, captive=boom, connect=boom)
    ck(e["state"] == "refused" and e["refusal"]["state"] == verdict["state"] and e["refusal"]["remedy"], f"{name}: refused ({verdict['state']}) with a remedy")
ck(calls == [], "and none on unknown posture or no route")
# the gate is the server's, not a second one: allowed tiers run
for tier in ("0", "1"):
    if tier in S.OUTBOUND_BLOCKED_TIERS: continue
    v = S.outbound_verdict(S.read_posture('{"tier": "%s"}' % tier), up)
    ran = []
    e = GP.run_outbound(v, system_q=lambda n: (ran.append(n), {"answers": [], "rcode_name": "NXDOMAIN"})[1],
                        direct_q=lambda n, s: {"answers": [], "rcode_name": "NXDOMAIN"},
                        captive=lambda h, p: {"status": 204}, connect=lambda h, p: "connected")
    ck(e["state"] == "done" and ran, f"tier {tier}: allowed by outbound_verdict -> probes run")
import ast
tree = ast.parse(open(GP.__file__, encoding="utf-8").read())
names = {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)} | {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)}
doc = ast.get_docstring(tree, clean=False)
strs = [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value != doc]
ck(not names & {"OUTBOUND_BLOCKED_TIERS", "read_posture", "POSTURE_STATUS", "tier"}
   and not any("posture-status" in s for s in strs),
   "gateway_probes grows no second gate in code (no tier list, no posture read; docstrings aside)")
PY
then pass "Part B refused on every blocked tier with the posture named; unknown/no-route refused; gate reused, not copied"; else fail "Part B gate" "see output above"; fi

echo "[Part A never runs automatically: no transmit on import, collect(), or any page GET]"
if python3 -I - "$AW" "$SRV" "$WEB" "$ROOT/tests/fixtures/oui/oui.txt" <<'PY'
import sys, socket, threading, http.client, ast, json, os
from pathlib import Path
os.environ["ORIONX_OUI_PATH"] = sys.argv[4]
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
# Record every UDP socket and every sendto BEFORE anything is imported.
udp, sent = [], []
_Real = socket.socket
class Rec(_Real):
    def __init__(self, family=-1, type=-1, *a, **k):
        super().__init__(family, type, *a, **k)
        if self.type == socket.SOCK_DGRAM: udp.append(self.family)
    def sendto(self, data, *a):
        sent.append(bytes(data[:40])); raise AssertionError("sendto during a passive path")
socket.socket = Rec
sys.path.insert(0, sys.argv[2]); sys.path.insert(0, sys.argv[1])
import gateway_probes as GP, network_picture as NP, osint_server as S
ck(udp == [] and sent == [], "importing gateway_probes / network_picture / osint_server opens no UDP socket")
hits = {"probe": 0}
real_discover = GP.ssdp_discover
def counting(*a, **k):
    hits["probe"] += 1; return []
GP.ssdp_discover = counting
for fn in ("run_gateway", "run_outbound"):
    setattr(GP, fn, (lambda real: lambda *a, **k: (hits.__setitem__("probe", hits["probe"] + 1), real(*a, **k))[1])(getattr(GP, fn)))
p = NP.collect(budget=0.5)
ck([a["state"] for a in p["active"]] == ["idle", "idle"] and hits["probe"] == 0 and udp == [] and sent == [],
   "collect() returns idle descriptors and runs no probe, opens no UDP socket")
S.WEB_ROOT = Path(sys.argv[3])
httpd, port = S.bind(Path(sys.argv[3]), 18200 + (os.getpid() % 500))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
def req(method, path, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = {"Host": "127.0.0.1:%d" % port}; h.update(headers or {})
    c.request(method, path, headers=h); r = c.getresponse(); b = r.read(); c.close()
    return r.status, b
for path in ("/network/", "/network/network.js", "/api/network.json", "/api/network.json?window=300",
             "/api/network/gateway", "/api/network/outbound", "/api/status.json"):
    req("GET", path)
ck(hits["probe"] == 0 and udp == [] and sent == [], "GET of the page, its script, the API and even the probe URLs runs nothing")
st, _ = req("POST", "/api/network/gateway")
ck(st == 403 and hits["probe"] == 0, f"a POST without the operator header is refused ({st}) and runs nothing")
st, _ = req("POST", "/api/network/gateway", {"X-Orionx-Operator": "1", "Origin": "http://evil.example"})
ck(st == 403 and hits["probe"] == 0, f"a cross-origin POST is refused ({st}) and runs nothing")
st, body = req("POST", "/api/network/gateway", {"X-Orionx-Operator": "1"})
ck(st == 200 and hits["probe"] >= 1 and json.loads(body)["state"] == "no-answer",
   "positive control: the button's POST is what runs the probe (the recorder can see it)")
httpd.shutdown(); httpd.server_close()
GP.ssdp_discover = real_discover

# Static shape: the passive engine reaches gateway_probes through describe() only,
# and the server through run_active() inside do_POST only.
np_src = open(NP.__file__, encoding="utf-8").read()
uses = {n.attr for n in ast.walk(ast.parse(np_src)) if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name) and n.value.id == "gateway_probes"}
ck(uses == {"describe"}, f"network_picture uses gateway_probes.{uses} only")
srv_tree = ast.parse(open(S.__file__, encoding="utf-8").read())
def callers(name):
    out = set()
    for fn in ast.walk(srv_tree):
        if isinstance(fn, ast.FunctionDef):
            for n in ast.walk(fn):
                if isinstance(n, ast.Call) and getattr(n.func, "attr", getattr(n.func, "id", None)) == name: out.add(fn.name)
    return out
ck(callers("run_gateway") == {"run_active"} and callers("run_outbound") == {"run_active"} and callers("run_active") == {"do_POST"},
   "osint_server runs a probe only from run_active(), called only by do_POST")

# No module-level side effects: top level is imports, defs, constants, and calls
# only to this module's own pure description helpers.
gp_tree = ast.parse(open(GP.__file__, encoding="utf-8").read())
PURE = {"gateway_sends", "outbound_sends", "tuple"}
bad = []
for node in gp_tree.body:
    if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef)): continue
    if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant): continue
    if isinstance(node, (ast.Assign, ast.AnnAssign)):
        calls = [n for n in ast.walk(node) if isinstance(n, ast.Call)]
        def pure(c):
            f = c.func
            return (isinstance(f, ast.Name) and f.id in PURE) or \
                   (isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and (f.value.id, f.attr) == ("ipaddress", "ip_network"))
        if all(pure(c) for c in calls): continue
    bad.append(ast.dump(node)[:80])
ck(bad == [], f"gateway_probes has no module-level side effect ({bad})")
PY
then pass "Part A never automatic: import/collect()/GET transmit nothing; only the POST does (DEC-PHASE13-047 rule 3)"; else fail "no automatic run" "see output above"; fi

echo "[page: the button is the only trigger; labels present; textContent only]"
JS="$WEB/network/network.js"; HTML="$WEB/network/index.html"
n_calls="$(grep -c 'runActive(' "$JS")"
if [[ "$n_calls" -eq 2 ]] && grep -q 'addEventListener("click", function(){ runActive(idle); })' "$JS"; then
    pass "runActive() is defined once and called only from the button's click handler"
else fail "page trigger" "runActive( appears $n_calls times or not from a click handler"; fi
if grep -n 'method: "POST"' "$JS" | grep -q . && [[ "$(grep -c 'method: "POST"' "$JS")" -eq 1 ]]; then
    pass "exactly one POST in the page script (inside runActive)"
else fail "POST count" "$(grep -n 'method: \"POST\"' "$JS")"; fi
grep -q 'X-Orionx-Operator' "$JS" && grep -q 'OPERATOR_HEADER = "X-Orionx-Operator"' "$SRV/osint_server.py" && pass "the page sends the operator header the server requires" || fail "operator header" "page and server disagree"
for lbl in "reported by the gateway, not measured" "probe, posture-gated"; do
    grep -q "$lbl" "$HTML" && grep -q "\"$lbl\"" "$AW/gateway_probes.py" && pass "label \"$lbl\" on the page and as a constant" || fail "label $lbl" "missing"
done
! grep -q 'innerHTML' "$JS" && pass "network.js still writes with textContent only (gateway strings are attacker-chosen)" || fail "innerHTML" "network.js uses innerHTML"
grep -q "@decision DEC-PHASE13-047" "$AW/gateway_probes.py" && pass "DEC-PHASE13-047 annotated at the point of implementation" || fail "decision" "missing"
if command -v ruff >/dev/null 2>&1; then
    ruff check --select E4,E7,E9,F,I001,BLE001 --no-cache "$AW/gateway_probes.py" "$ROOT/tests/fixtures/gateway/fakes.py" >/dev/null 2>&1 \
      && pass "ruff clean: gateway_probes.py, fakes.py" || fail "ruff" "$(ruff check --no-cache "$AW/gateway_probes.py" 2>&1 | head -3)"
fi

echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
