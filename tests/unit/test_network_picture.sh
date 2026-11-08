#!/usr/bin/env bash
# network_picture (#93, DEC-PHASE13-046): pure parsers against Zeek fixtures;
# every sighting class detected; every absence reported absent, not unknown;
# Zeek absent -> degraded rows named; collect() never raises; the Cockpit and
# the Workbench read the same module and cannot disagree (mirrors
# test_deck_vitals.sh for DEC-PHASE12-049).
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AW="$ROOT/scripts/awareness"
FX="$ROOT/tests/fixtures"
WEB="$ROOT/iso/config/includes.chroot/opt/orionx/osint"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }

echo "[fixtures are derived from their generator, not hand-edited]"
GEN_TMP="$ROOT/tmp/np-fixtures-$$"; mkdir -p "$GEN_TMP"
if python3 -I - "$FX/zeek" "$GEN_TMP" <<'PY'
import sys, shutil, pathlib, importlib.util, filecmp
src, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
shutil.copy(src / "gen_network_picture.py", tmp / "gen_network_picture.py")
spec = importlib.util.spec_from_file_location("gen", tmp / "gen_network_picture.py")
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g); g.main()
ok = True
for d in ("network_picture", "network_picture_quiet"):
    for f in sorted((tmp / d).iterdir()):
        same = filecmp.cmp(f, src / d / f.name, shallow=False)
        print(("  ok   " if same else "  FAIL ") + f"{d}/{f.name} matches the generator")
        ok = ok and same
sys.exit(0 if ok else 1)
PY
then pass "checked-in Zeek fixtures are byte-identical to gen_network_picture.py output"; else fail "fixture drift" "re-run tests/fixtures/zeek/gen_network_picture.py"; fi
rm -rf "$GEN_TMP"

echo "[pure parsers + every sighting class + absence vs unknown + fail-safe collect]"
if ORIONX_OUI_PATH="$FX/oui/oui.txt" python3 -I - "$AW" "$FX" <<'PY'
import sys, json, os, time
from pathlib import Path
sys.path.insert(0, sys.argv[1]); import network_picture as NP, zeek_logs as Z
FX = Path(sys.argv[2])
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)

# --- ip neigh ---
NEIGH = """192.168.4.1 dev wlan0 lladdr 3c:37:86:aa:bb:cc router REACHABLE
192.168.4.23 dev wlan0 lladdr b8:27:eb:11:22:33 STALE
192.168.4.44 dev wlan0 lladdr 24:0a:c4:de:ad:01 REACHABLE
192.168.4.77 dev wlan0  FAILED
192.168.4.78 dev wlan0 lladdr 02:11:22:33:44:55 DELAY
fe80::be27:ebff:fe11:2233 dev wlan0 lladdr b8:27:eb:11:22:33 router STALE
192.168.4.200 dev wlan0 INCOMPLETE
"""
rows = NP.parse_ip_neigh(NEIGH)
ck(len(rows) == 7 and sum(r["live"] for r in rows) == 5, f"ip neigh: 7 rows, 5 live (lladdr and not FAILED/INCOMPLETE) ({sum(r['live'] for r in rows)})")
ck(rows[0]["mac"] == "3C:37:86:AA:BB:CC" and rows[0]["router"] and rows[0]["state"] == "REACHABLE", "mac normalised, router flag, state kept")
ck(NP.parse_ip_neigh("") == [] and NP.parse_ip_neigh("garbage line here\n") == [], "empty/garbage neigh -> []")
ck(NP.is_random_mac("02:11:22:33:44:55") and not NP.is_random_mac("b8:27:eb:11:22:33"), "locally administered bit detected")

# --- classification: RFC 1918 and friends, never geolocation ---
for ip, want in (("192.168.4.9", "local"), ("10.0.0.1", "local"), ("172.16.5.5", "local"), ("fd00::1", "local"),
                 ("169.254.1.1", "local"), ("fe80::1", "local"), ("93.184.216.34", "internet"), ("2606:4700::1111", "internet"),
                 ("224.0.0.251", "multicast"), ("255.255.255.255", "multicast"), ("192.168.4.255", "multicast"),
                 ("0.0.0.0", "invalid"), ("not-an-ip", "invalid"), (None, "invalid")):
    ck(NP.classify_ip(ip) == want, f"classify {ip} -> {want}")

# --- OUI registries: txt, csv, nmap ---
t = NP.parse_oui_txt(open(FX / "oui" / "oui.txt", encoding="utf-8"))
ck(t == {"3C3786": "NETGEAR", "B827EB": "Raspberry Pi Foundation", "240AC4": "Espressif Inc."}, f"oui.txt (base 16) lines -> {t}")
c = NP.parse_oui_csv(open(FX / "oui" / "oui.csv", encoding="utf-8"))
ck(c == t, "oui.csv parses to the same table")
n = NP.parse_nmap_prefixes(["# comment", "000000 Xerox", "3C3786 Netgear"])
ck(n == {"000000": "Xerox", "3C3786": "Netgear"}, "nmap-mac-prefixes fallback format")
ck(NP.oui_vendor("b8-27-eb-00-00-01", t) == "Raspberry Pi Foundation" and NP.oui_vendor("ff:ff:ff:00:00:00", t) is None, "lookup by 24-bit prefix; unknown -> None")
table, info = NP.load_oui([str(FX / "oui" / "oui.txt")])
ck(info["source"].endswith("oui.txt") and info["entries"] == 3, f"load_oui names its source and entry count ({info})")
table2, info2 = NP.load_oui([str(FX / "oui" / "oui.txt")])
ck(table2 is table, "second load is the cached table (same object)")
table3, info3 = NP.load_oui(["/nonexistent/oui.txt"])
ck(table3 == {} and "no OUI registry readable" in info3["reason"], f"no registry -> empty table with a reason ({info3['reason']})")

# --- Zeek tail reader: window, cap, header ---
NOW = 1790658600.0
recs, inf = NP.read_log_tail(FX / "zeek" / "network_picture" / "conn.log", 1 << 20, NOW, 900.0)
ck(len(recs) == 11 and inf["lines"] == 12 and inf["in_window"] == 11, f"conn.log: 12 records, 11 inside the 900 s window ({inf})")
ck(all(r.get("id.orig_h") != "192.168.4.99" for r in recs), "the 1600 s old record (host .99) is outside the window")
recs_small, inf_small = NP.read_log_tail(FX / "zeek" / "network_picture" / "conn.log", 400, NOW, 900.0)
ck(inf_small["tail_truncated"] and len(recs_small) < 11 and inf_small["coverage_seconds"] is not None, f"a tail cap is reported, not hidden ({inf_small['tail_truncated']}, {len(recs_small)} recs, coverage {inf_small['coverage_seconds']})")
_, inf_missing = NP.read_log_tail(FX / "zeek" / "nope.log", 1024, NOW, 900.0)
ck(inf_missing["error"] and not _, "a missing log is an error string, not an exception")
late, _i = NP.read_log_tail(FX / "zeek" / "network_picture" / "conn.log", 1 << 20, NOW, 900.0, deadline=time.monotonic() - 1)
ck(late == [] and _i["budget_exhausted"], "an exhausted time budget stops the parse and says so")

# --- collect() on the rich fixture: every class present ---
ADDR = json.dumps([{"ifname": "wlan0", "address": "aa:bb:cc:dd:ee:ff", "operstate": "UP",
                    "addr_info": [{"family": "inet", "local": "192.168.4.57", "prefixlen": 24}]}])
def run(cmd, timeout=2.0):
    return NEIGH if cmd[:2] == ["ip", "neigh"] else ADDR if cmd[:3] == ["ip", "-j", "addr"] else ""
p = NP.collect(now=NOW, log_dirs=[str(FX / "zeek" / "network_picture")], run=run)
ck(p["decision"] == "DEC-PHASE13-046" and p["label"] == "observed by this deck", "picture carries the decision and the label")
S = p["sightings"]
for k in ("wpad", "netbios", "llmnr", "mdns", "ldap", "dhcp", "ssdp", "iot"):
    ck(S[k]["state"] == "present" and S[k]["count"] >= 1, f"sighting {k}: present ({S[k]['count']}, sources {S[k]['sources']})")
ck(S["wpad"]["hosts"] == ["192.168.4.23"] and "wpad.lan" in S["wpad"]["samples"], f"WPAD from dns.log `wpad.` query, host named ({S['wpad']})")
ck("192.168.4.23" in S["netbios"]["hosts"] and "192.168.4.88" in S["netbios"]["hosts"], "NetBIOS from 137 (udp) and 445 (tcp)")
ck(S["llmnr"]["hosts"] == ["192.168.4.44"] and "fileserver" in S["llmnr"]["samples"], "LLMNR 5355 with the name asked for")
ck("_googlecast._tcp.local" in S["mdns"]["samples"], "mDNS 5353 with service names")
ck(S["ldap"]["count"] == 2 and S["ldap"]["established"] == 1, f"LDAP 389+636 counted, handshakes separated ({S['ldap']['established']} of {S['ldap']['count']})")
ck(S["dhcp"]["sources"] == ["dhcp.log"] and S["dhcp"]["servers"] == ["192.168.4.1"] and "pi-sensor" in S["dhcp"]["samples"], f"DHCP from dhcp.log names the server and the lease ({S['dhcp']})")
ck(S["ssdp"]["sources"] == ["ssdp.log"] and any("Sonos" in s for s in S["ssdp"]["samples"]), "SSDP from ssdp.log with the announcing agent")
ck(S["iot"]["heuristic"] is True and any("Espressif" in h["why"] for h in S["iot"]["hits"]) and any("_hap._tcp" in h["why"] for h in S["iot"]["hits"]), "IoT heuristic from OUI vendor and mDNS service, labelled heuristic")
ck(p["degraded"] == [] and all(s["window_seconds"] == 900.0 for s in S.values()), "nothing degraded; every sighting carries its window")
H = p["hosts"]
ck(H["count"] == 6 and H["from_neigh"] == 4 and H["zeek_only"] == 2, f"hosts: 4 by MAC from neigh (v4+v6 of one Pi merged, randomised counted, self excluded) + 2 only in conn.log = 6 ({H})")
sp = p["split"]
ck(sp["available"] and sp["basis"] == "bytes" and sp["conns"] == 11 and sp["internet"]["conns"] == 2 and round(sp["local_pct"] + sp["internet_pct"]) == 100, f"local/internet split by RFC 1918 over conn.log bytes ({sp['local_pct']} / {sp['internet_pct']}, {sp['conns']} conns)")
arp = {r["ip"]: r for r in p["arp"]["rows"]}
ck(arp["192.168.4.1"]["vendor"] == "NETGEAR" and arp["192.168.4.44"]["vendor"] == "Espressif Inc.", "ARP rows carry the OUI vendor")
ck(arp["192.168.4.78"]["vendor"] is None and arp["192.168.4.78"]["random_mac"] and "randomised" in arp["192.168.4.78"]["vendor_note"], "a randomised MAC has no vendor and says why")
ck("192.168.4.57" not in arp and "192.168.4.77" not in arp, "self is never a host; a FAILED entry without lladdr is not an ARP row")
summ = p["summary"]
ck(summ["headline"] == "6 hosts · ARP table + Zeek 15 min · observed by this deck", f"headline: {summ['headline']}")
ck(summ["split_line"].startswith("30% local / 70% internet by bytes") and "15 min" in summ["split_line"], f"split line: {summ['split_line']}")
ck([a["id"] for a in p["active"]] == ["gateway", "outbound"] and all(a["state"] == "idle" and a["result"] is None for a in p["active"]),
   "the #94 extension point returns the two IDLE descriptors only; collect() runs no probe (DEC-PHASE13-047)")

# --- quiet fixture: logs present, every class ABSENT (never unknown) ---
q = NP.collect(now=NOW, log_dirs=[str(FX / "zeek" / "network_picture_quiet")], run=run)
for k in ("wpad", "netbios", "llmnr", "mdns", "ldap", "dhcp", "ssdp"):
    ck(q["sightings"][k]["state"] == "absent" and q["sightings"][k]["count"] == 0, f"quiet: {k} absent, not unknown (sources {q['sightings'][k]['sources']})")
ck(q["degraded"] == [] and q["split"]["available"], "quiet: nothing degraded, split available")
ck(q["sightings"]["iot"]["state"] == "present" and all(h["why"].startswith("vendor OUI") for h in q["sightings"]["iot"]["hits"]), "quiet: IoT still flags the Espressif OUI (vendor hint only)")

# --- Zeek absent: degrade honestly, name the rows ---
a = NP.collect(now=NOW, log_dirs=[str(FX / "zeek" / "does-not-exist")], run=run)
for k in ("wpad", "netbios", "llmnr", "mdns", "ldap", "dhcp", "ssdp"):
    ck(a["sightings"][k]["state"] == "unknown" and "needs Zeek" in a["sightings"][k]["detail"], f"zeek absent: {k} unknown, naming its log ({a['sightings'][k]['detail']})")
ck(a["sightings"]["iot"]["state"] == "present" and "mDNS part needs Zeek dns.log" in a["sightings"]["iot"]["detail"], "zeek absent: IoT keeps the OUI half and says the mDNS half is missing")
ck(set(a["degraded"]) == {"split", "hosts.zeek"} | {f"sightings.{k}" for k in ("wpad", "netbios", "llmnr", "mdns", "ldap", "dhcp", "ssdp")}, f"degraded names every Zeek-fed row ({a['degraded']})")
ck(a["zeek"]["state"] == "absent" and "install-zeek.sh" in a["zeek"]["reason"], f"zeek state absent with the remedy ({a['zeek']['reason'][:60]}...)")
ck(a["hosts"]["count"] == 4 and a["split"]["available"] is False and a["split"]["local_pct"] is None, "hosts from the neighbour table only; split is None, not 0/0")
ck(a["summary"]["headline"] == "4 hosts · ARP table only · observed by this deck" and a["summary"]["split_line"] == "local/internet split needs Zeek (conn.log)", f"zeek-absent headline/split: {a['summary']['headline']} | {a['summary']['split_line']}")

# --- unreadable Zeek dir is distinct from absent ---
if os.geteuid() != 0:
    import tempfile
    d = Path(tempfile.mkdtemp(dir=str(Path(sys.argv[1]).parent.parent / "tmp")))
    (d / "conn.log").write_text("#fields\tts\n")
    d.chmod(0o000)
    try:
        u = NP.collect(now=NOW, log_dirs=[str(d)], run=run)
    finally:
        d.chmod(0o700)
    ck(u["zeek"]["state"] == "unreadable" and "cannot read" in u["zeek"]["reason"], f"unreadable dir is reported as unreadable, not absent ({u['zeek']['state']})")
    import shutil; shutil.rmtree(d, ignore_errors=True)
else:
    print("  ok   (skipped unreadable case: running as root)")

# --- collect() must survive every reader failing ---
def boom(*a, **k): raise OSError("nope")
b = NP.collect(run=boom, log_dirs=["/nonexistent"], oui_paths=["/nonexistent"])
ck(b["hosts"]["count"] == 0 and b["arp"]["rows"] == [] and b["summary"]["headline"].endswith("observed by this deck"), "every reader failing -> zeros with the label, no exception")
ck(any(r.startswith("ip neigh") for r in b["reasons"]) and any(r.startswith("oui") for r in b["reasons"]), f"and says why: {b['reasons']}")
ck(NP.clamp_window("abc") == 900.0 and NP.clamp_window(1) == 60.0 and NP.clamp_window(10**9) == 86400.0, "window clamped, garbage -> default")
ck(NP.fmt_window(900) == "15 min" and NP.fmt_window(3600) == "1 h" and NP.fmt_window(90) == "90 s", "window formats")

# --- shared Zeek discovery: the daemon and the engine use one module ---
ck(NP.zeek_logs is Z and Z.ZEEK_LOG_DIRS[0] == Path("/opt/zeek/logs/current"), "engine discovers Zeek through zeek_logs (the daemon's list)")
real = NP.collect(budget=0.5)
ck(isinstance(real.get("arp", {}).get("rows"), list) and real["bounded"]["elapsed_ms"] >= 0, f"a real collect on this host returns in {real['bounded']['elapsed_ms']} ms without raising")
PY
then pass "network_picture parsers, sightings, absence/unknown, degrade, fail-safe collect (DEC-PHASE13-046)"; else fail "network_picture assertions" "see output above"; fi

echo "[one module, two surfaces: the Cockpit and the Workbench cannot disagree]"
CK="$ROOT/scripts/cockpit/orionx-cockpit"; SRV="$ROOT/scripts/osint/osint_server.py"
grep -q '^import network_picture as NP' "$CK" && pass "orionx-cockpit imports network_picture" || fail "cockpit import" "missing"
grep -q '^import network_picture' "$SRV" && pass "osint_server.py imports network_picture" || fail "server import" "missing"
grep -q 'NP.collect()' "$CK" && grep -q 'network_picture.collect(window=' "$SRV" && pass "both surfaces call collect() on the same module" || fail "collect() wiring" "one surface does not call network_picture.collect"
grep -q 'summ.get("headline")' "$CK" && grep -q 'summ\["split_line"\]' "$CK" && pass "the Cockpit draws summary.headline and summary.split_line verbatim" || fail "cockpit summary" "the NETWORK panel composes its own words"
grep -q 's.headline + " — " + s.split_line' "$WEB/network/network.js" && pass "the page shows the same two summary lines verbatim" || fail "page summary" "network.js composes its own headline"
if grep -qE 'ip["'"'"'], *"neigh"|"neigh"|zeek_record|oui_vendor|/usr/share/ieee-data' "$CK" "$SRV"; then
    fail "no second reader" "a surface reads ip neigh / Zeek / OUI itself"
else pass "neither surface reads ip neigh, Zeek logs or the OUI table itself"; fi
grep -q '/api/network.json' "$SRV" && grep -q 'api/network.json' "$WEB/network/network.js" && pass "the page is fed by /api/network.json" || fail "api route" "missing"
grep -q '"network": "network/"' "$SRV" && grep -q '"network"' "$SRV" && pass "orionx-osint --page network opens the page" || fail "--page network" "missing"
grep -q 'This network page' "$SRV" && pass "orionx-osint --check lists the page" || fail "--check row" "missing"
grep -q '"id": "network"' "$WEB/links.json" && pass "links.json lists This network as a local page" || fail "links.json" "no network entry"
# Cockpit edits stay inside the NETWORK panel + the sys poller (brief constraint).
if python3 -I - "$CK" <<'PY'
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
hits = [m.start() for m in re.finditer(r"\bNP\.", src)]
def func_of(pos):
    head = src[:pos]
    m = list(re.finditer(r"\n    def (\w+)\(", head))
    return m[-1].group(1) if m else "<module>"
where = sorted({func_of(h) for h in hits})
print("  NP used in:", where)
sys.exit(0 if where == ["_collect_sys"] and "NP.collect()" in src else 1)
PY
then pass "NP.collect() runs only on the sys poller (POLL_SYS_MS worker thread), not on the draw path" ; else fail "cockpit scope" "network_picture used outside _collect_sys"; fi
grep -q 'POLL_SYS_MS = 5000' "$CK" && pass "Cockpit refresh interval for the picture is POLL_SYS_MS = 5000 ms (engine budget 1.5 s)" || fail "poll interval" "POLL_SYS_MS changed; re-check the engine budget"

echo "[honesty contract (DEC-PHASE13-046)]"
grep -q "@decision DEC-PHASE13-046" "$AW/network_picture.py" && pass "decision annotated at the point of implementation" || fail "DEC-PHASE13-046 annotation" "missing"
grep -q 'OBSERVED_LABEL = "observed by this deck"' "$AW/network_picture.py" && pass "the label is a named constant" || fail "label constant" "missing"
for f in "$AW/network_picture.py" "$CK" "$WEB/network/index.html" "$WEB/network/network.js" "$WEB/links.json"; do
    if grep -qi "hosts on the network" "$f"; then fail "wording: $(basename "$f")" "says 'hosts on the network'"; else pass "wording: $(basename "$f") never says 'hosts on the network'"; fi
done
for f in "$AW/network_picture.py" "$WEB/network/network.js"; do
    if grep -nE '"(lat|lon|latitude|longitude|country|city|coordinates)"|geoip|maxmind' "$f" | grep -v "no geolocation\|No geolocation\|geolocation\." >/dev/null; then
        fail "no geolocation in $(basename "$f")" "$(grep -nE '"(lat|lon|latitude|longitude|country|city|coordinates)"|geoip|maxmind' "$f" | head -2)"
    else pass "no geolocation field or lookup in $(basename "$f")"; fi
done
grep -q 'observed by this deck' "$WEB/network/index.html" && pass "the page states the label in its own words too" || fail "page label" "missing"
grep -q 'textContent' "$WEB/network/network.js" && ! grep -q 'innerHTML' "$WEB/network/network.js" && pass "the page writes API strings with textContent only (DNS/DHCP/SSDP strings are attacker-chosen)" || fail "innerHTML" "network.js uses innerHTML"
grep -q 'id="sec-active" class="hidden"' "$WEB/network/index.html" && grep -q 'def active_extensions' "$AW/network_picture.py" && pass "#94 extension point: hidden-until-entries section + active_extensions()" || fail "#94 extension point" "missing"
grep -qE "subprocess\.run" "$AW/network_picture.py" && ! grep -qE "\b(ip|nmcli) (link|addr|neigh) (add|set|del|flush|replace)|sysctl -w|iptables|nft |socket\.(socket|send)" "$AW/network_picture.py" && pass "reads only: no command or socket in the module transmits or mutates" || fail "read-only" "a mutating/transmitting call appears in network_picture.py"

echo "[orionx-postured imports the shared Zeek discovery instead of carrying a copy]"
PD="$AW/orionx-postured"
grep -q '^from zeek_logs import' "$PD" && pass "postured imports zeek_logs" || fail "postured import" "missing"
if grep -qE '^def (expand_zeek_log_dirs|assess_zeek_logs|zeek_record|zeek_fields_from_file|zeek_fields_from_header)\(' "$PD" || grep -q '^ZEEK_LOG_DIRS = ' "$PD"; then
    fail "single authority" "orionx-postured still defines its own Zeek discovery/decoder"
else pass "orionx-postured no longer defines ZEEK_LOG_DIRS / expand_zeek_log_dirs / assess_zeek_logs / zeek_record"; fi

echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
