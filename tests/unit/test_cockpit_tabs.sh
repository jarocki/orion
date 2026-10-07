#!/usr/bin/env bash
# The Cockpit as the one tabbed window (DEC-PHASE12-053..057): tab authority,
# launcher, pure tab-data helpers, wiring. No display needed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
CC="$ROOT/scripts/control_center"; CK="$ROOT/scripts/cockpit/orionx-cockpit"

echo "[tab authority]"
grep -q '^SECTIONS = \[' "$CC/app.py" && pass "app.SECTIONS is the one tab list" || fail "SECTIONS" "missing"
grep -q 'class OrionXControlCenter' "$CC/app.py" && fail "no second window class" "OrionXControlCenter still defined" || pass "the Control Center window class is gone (one window)"
grep -q 'os.execv(exe, \[exe, "--tab", tab\])' "$CC/app.py" && pass "run_app launches the Cockpit on a tab" || fail "launcher" "run_app does not exec orionx-cockpit"
grep -q '"tools", "Orion Tools"' "$CC/app.py" && pass "IR Tools is Orion Tools" || fail "rename" "label not Orion Tools"
grep -q 'from control_center import app as CC' "$CK" && grep -q 'CC.append_sections(self.nb)' "$CK" && pass "the Cockpit builds its tabs from app.SECTIONS" || fail "cockpit tabs" "not wired"
grep -q 'CCUX.set_notifier(self.toast_bar.notify)' "$CK" && pass "sections toast through the Cockpit's toast bar" || fail "toast" "not wired"
grep -q 'if not on_live and name != "F11":' "$CK" && pass "LIVE keys do not fire on GTK tabs" || fail "key routing" "missing"
grep -q 'choices=CC.TAB_KEYS' "$CK" && pass "--tab accepts exactly the authority's keys" || fail "--tab" "missing"
HOOK="$ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
grep -q 'Exec=/usr/bin/orionx-cockpit --tab network' "$HOOK" && pass "menu entry (written by the 0700 hook) opens the Cockpit tabs" || fail "desktop" "hook Exec not updated"
[[ -f "$ROOT/iso/config/includes.chroot/usr/share/applications/orionx-control-center.desktop" ]] && fail "one writer for orionx-control-center.desktop" "a static copy exists beside the hook's heredoc — it overwrote the edit in rc7" || pass "one writer for orionx-control-center.desktop (the 0700 hook; no static copy)"
python3 -m py_compile "$CC/app.py" "$CK" "$CC/sections/mesh.py" "$CC/sections/comms.py" "$CC/sections/ir.py" "$CC/sections/awareness.py" "$CC/helpers/"*.py 2>/dev/null && pass "everything compiles" || fail "compile" "syntax error"

echo "[pure helpers]"
if python3 - "$CC/helpers" "$ROOT/scripts/awareness" <<'PY'
import sys, json, tempfile, pathlib, time
sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2])
import mesh_data as M, comms_data as C, tools_data as T, spark as S, deck_vitals as V
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
st = M.parse_status("Mesh: active\n  Interface: wg0\n  VPN IP:    10.0.99.75\n  Mode:      p2p\n  Peers:     2\n  Uptime:    1h 2m\n  Health:    1 peer stale\n")
ck(st["active"] == "active" and st["vpn_ip"] == "10.0.99.75" and st["health"] == "1 peer stale", f"status parsed {st}")
ck(M.parse_status("Mesh: inactive\n")["active"] == "inactive" and M.parse_status("")["active"] == "unknown", "inactive/empty status")
now = 1_000_000
dump = "PRIV\tPUB\t51820\toff\n" + "pk1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=\t(none)\t192.168.4.20:51820\t10.0.99.20/32\t" + str(now-30) + "\t1024\t2048\t25\n" + "pk2bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=\t(none)\t(none)\t10.0.99.21/32\t0\t0\t0\toff\n"
peers = M.parse_wg_dump(dump, now)
ck(len(peers) == 2 and peers[0]["node"] == "10.0.99.20" and peers[0]["endpoint"] == "192.168.4.20:51820", "wg dump: nodes + endpoints")
ck(peers[0]["rx"] == 2048 and peers[0]["tx"] == 1024 and M.peer_state(peers[0]["handshake_age"]) == "live", "counters + live state (wg dump order is tx,rx)")
ck(peers[1]["handshake_age"] is None and M.peer_state(None) == "never" and peers[1]["endpoint"] == "", "never-handshaken peer")
ck(M.total_traffic(peers) == (2048, 1024) and M.fmt_age(90) == "1m ago" and M.fmt_bytes(2048) == "2.0 KiB", "totals + formats")
tmp = pathlib.Path(tempfile.mkdtemp())
log = tmp / "events.jsonl"
log.write_text("\n".join(json.dumps(e) for e in [
  {"ts": now-50, "severity":"info", "source":"suricata", "category":"ids", "message":"x"},
  {"ts": now-40, "severity":"notice", "source":"mesh-health", "category":"heal", "message":"bounced wg0"},
  {"ts": now-30, "severity":"info", "source":"mesh", "category":"peer", "message":"peer joined"},
  "garbage"]) + "\n")
h = M.read_history(log, limit=5)
ck([e["source"] for e in h] == ["mesh", "mesh-health"], f"history: mesh events only, newest first ({[e['source'] for e in h]})")
ck(M.read_history(tmp / "nope") == [], "missing bus -> empty, no crash")
s = C.server_state("active", True, True, None, "192.168.4.57")
ck(s["mode"] == "server" and s["url"] == "https://192.168.4.57:8008" and s["running"], f"server mode {s['headline']}")
s2 = C.server_state("inactive", False, False, json.dumps({"default_server_config":{"m.homeserver":{"base_url":"https://matrix.example.org"}}}), None)
ck(s2["mode"] == "client" and s2["url"] == "https://matrix.example.org" and not s2["running"], "client mode from Element config")
ck(C.server_state("inactive", False, False, None, None)["mode"] == "none", "nothing configured -> none, with the opt-in remedy")
ck(C.parse_joined_rooms("!abc:x\n  @a:x\n!def:x\n") == ["!abc:x", "!def:x"], "joined rooms")
ck(C.parse_joined_members("!abc:x room\n  @a:x\n  @b:x\n!def:x\n") == {"!abc:x": ["@a:x","@b:x"], "!def:x": []}, "joined members per room")
ck(C.desktop_exec("[Desktop Entry]\nExec=xfce4-terminal --hold -e \"matrix-commander --listen tail\" %u\n") == ["xfce4-terminal","--hold","-e","matrix-commander --listen tail"], "desktop Exec parsed, field codes dropped")
cs = C.client_states(lambda p: p == "/usr/bin/element-desktop", lambda n: n == "matrix-commander")
ck([c["installed"] for c in cs] == [True, True, False] and cs[2]["installer"].startswith("sudo /opt/orionx/optional/install-gomuks.sh"), "client detection + installer")
local = [{"id":"a","name":"A","kind":"command","command":"orionx-a --x","runtime_path":"/opt/a"}, {"id":"cyberchef","name":"CC","kind":"page","runtime_path":"/opt/cc"}, {"id":"gone","runtime_path":"/opt/gone"}]
od = T.on_deck(local, lambda p: p in ("/opt/a","/opt/cc"))
ck([i["id"] for i in od] == ["a","cyberchef"], "on_deck keeps only entries whose runtime_path exists")
ck(T.launch_argv(local[0]) == ("terminal", ["orionx-a","--x"]) and T.launch_argv(local[1]) == ("detached", ["orionx-osint","--page","cyberchef"]), "launch argv per kind")
ck(T.install_argv({"command":"sudo /opt/orionx/optional/install-x.sh"}) == ["sudo","/opt/orionx/optional/install-x.sh"], "install argv")
ck(T.load_catalogue(tmp / "none.json") == ([], []), "missing catalogue -> empty")
pts = S.points([0, 5, 10], 100, 50)
ck(len(pts) == 3 and pts[0][1] > pts[2][1] and abs(pts[2][0] - 98) < 1e-6, f"spark points: rising series rises, spans width ({pts})")
ck(S.points([], 100, 50) == [] and S.points([0, 0], 100, 50)[0][1] == S.points([0, 0], 100, 50)[1][1], "empty/flat series")
nd = V.parse_net_dev("Inter-|   Receive\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n    lo: 100 2 0 0 0 0 0 0 100 2 0 0 0 0 0 0\n wlan0: 5000 40 0 0 0 0 0 0 7000 60 0 0 0 0 0 0\n")
ck(nd == {"rx_bytes":5000,"tx_bytes":7000,"rx_packets":40,"tx_packets":60}, f"net_dev totals skip lo {nd}")
ck(V.parse_resolv_conf("# x\nnameserver 192.168.4.1\nnameserver 1.1.1.1\nnameserver 192.168.4.1\nsearch lan\n") == ["192.168.4.1","1.1.1.1"], "resolv.conf nameservers de-duplicated")
PY
then pass "mesh/comms/tools/spark/vitals pure helpers"; else fail "pure helper assertions" "see output above"; fi

echo "[mesh: one snapshot verdict on every surface (DEC-PHASE12-067)]"
if PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import sys, json, tempfile, pathlib, importlib.util
root = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(root/"scripts"))
from control_center.helpers import mesh_data as M
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
now = 2_000_000.0
td = pathlib.Path(tempfile.mkdtemp(dir=str(root/"tmp")))
def snap(age, active=True, peers=None):
    p = td/f"s{age}{active}.json"
    p.write_text(json.dumps({"ts": now - age, "active": active, "interface": "wg0", "vpn_ip": "10.0.99.7",
                             "peers": peers if peers is not None else
                             [{"pubkey_short": "aaaa", "node": "10.0.99.2", "handshake": now - 20 - age, "rx": 5, "tx": 6},
                              {"pubkey_short": "bbbb", "node": "10.0.99.3", "handshake": now - 400, "rx": 1, "tx": 1}]}))
    return p
s = M.mesh_summary(M.load_snapshot(snap(5), now=now), now)
ck(s["state"] == "active" and s["live"] == 1 and s["short"] == "◆ 1 peer" and "5 s old" in s["text"], f"fresh: {s['short']} / {s['text']}")
st = M.mesh_summary(M.load_snapshot(snap(612), now=now), now)
ck(st["state"] == "stale" and "612 s" in st["text"] and "orionx-mesh-status.timer" in st["text"] and "active" not in st["text"].split("—")[0],
   f"stale snapshot says stale, not active: {st['text']}")
ck(st["live"] == 0, "handshake ages measured against now: a frozen snapshot shows no live peers (UX-26)")
ck(M.mesh_summary(M.load_snapshot(snap(3, active=False, peers=[]), now=now), now)["state"] == "down", "not joined")
ns = M.mesh_summary(M.load_snapshot(td/"missing.json"), now, wg_up=True)
ck(ns["state"] == "no-snapshot" and ns["short"] == "— (no snapshot)" and "wg0 is up" in ns["text"], f"no snapshot: {ns['text']}")
bad = td/"bad.json"; bad.write_text(json.dumps({"ts": now, "active": True, "peers": [{"handshake": "x", "rx": "y"}, "junk", None]}))
b = M.load_snapshot(bad, now=now)
ck(b is not None and len(b["peers"]) == 1 and b["peers"][0]["handshake_age"] is None, "malformed peers neither raise nor count (P3-4)")
spec = importlib.util.spec_from_file_location("mesh_status", root/"scripts/control_center/widgets/mesh-status.py")
w = importlib.util.module_from_spec(spec); spec.loader.exec_module(w)
out = w.render(snap(5), now=now)
ck(out.startswith("<txt>◆ 1 peer</txt>") and "<tool>Mesh: active" in out, f"panel widget renders the snapshot: {out.splitlines()[0]}")
ck(w.render(snap(95), now=now).startswith("<txt>◆ stale (95 s)</txt>"), "panel widget says stale past 30 s")
ck(w.render(td/"none.json", now=now).startswith("<txt>— (no snapshot)</txt>"), "panel widget: no snapshot")
PY
then pass "mesh verdict: tab, Awareness, LIVE LED and panel widget share mesh_summary"; else fail "mesh verdict" "see output above"; fi
for f in "$CC/sections/awareness.py" "$CK" "$CC/sections/mesh.py"; do grep -q "mesh_summary(" "$f" || fail "mesh verdict wired" "$f does not use mesh_summary"; done

echo "[no sudo from the GUI except inside an operator-visible terminal]"
if PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import ast, sys, pathlib
root = pathlib.Path(sys.argv[1])
files = sorted((root/"scripts/control_center").rglob("*.py")) + [root/"scripts/cockpit/orionx-cockpit", root/"scripts/cockpit/cockpit_lib.py"]
bad = []
for f in files:
    tree = ast.parse(f.read_text(), str(f))
    parents = {c: p for p in ast.walk(tree) for c in ast.iter_child_nodes(p)}
    for n in ast.walk(tree):
        if isinstance(n, ast.List) and n.elts and isinstance(n.elts[0], ast.Constant) and n.elts[0].value == "sudo":
            p = parents.get(n)
            name = ""
            if isinstance(p, ast.Call):
                fn = p.func
                name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", "")
            if name != "launch_in_terminal":
                bad.append(f"{f.relative_to(root)}:{n.lineno}")
print("  offenders:", bad or "none")
raise SystemExit(1 if bad else 0)
PY
then pass "every sudo argv is passed straight to launch_in_terminal (system.md P2-4)"; else fail "GUI sudo" "a sudo argv runs outside a terminal"; fi

echo "[wiring]"
grep -q 'M.load_snapshot(' "$CC/sections/mesh.py" && ! grep -qE 'run_stdout\(|from \.\.helpers\.subprocess_runner' "$CC/sections/mesh.py" && pass "Mesh tab reads the root-written snapshot; no privileged reads (DEC-PHASE12-059; Start/Stop/Peers still open a sudo terminal)" || fail "mesh snapshot" "tab still reads status via sudo or does not read the snapshot"
grep -q 'M.read_history()' "$CC/sections/mesh.py" && pass "Mesh tab reads bus history" || fail "mesh history" "missing"
grep -q 'C.client_states(' "$CC/sections/comms.py" && grep -q 'Gtk.Button(label="Install")' "$CC/sections/comms.py" && pass "Comms offers Install for absent clients" || fail "comms install" "missing"
grep -q '"Next hop", _next_hop' "$CC/sections/awareness.py" && grep -q '"DNS", _dns' "$CC/sections/awareness.py" && grep -q '"Firewall address", _firewall_addr' "$CC/sections/awareness.py" && pass "Awareness rows: firewall address, next hop, DNS" || fail "awareness rows" "missing"
grep -q 'Spark("packets/s"' "$CC/sections/awareness.py" && pass "Awareness sparklines (packets/cpu/mem/disk)" || fail "sparklines" "missing"
grep -q 'T.on_deck(local, os.path.exists)' "$CC/sections/ir.py" && grep -q '_OS.optional_state(installable' "$CC/sections/ir.py" && pass "Orion Tools is dynamic: catalogue + the Workbench's probe logic" || fail "tools dynamic" "missing"
for d in 053 054 055 056 057; do grep -rq "DEC-PHASE12-$d" "$CC" && pass "DEC-PHASE12-$d annotated" || fail "DEC-PHASE12-$d" "not annotated"; done
echo "==========================================="; echo "Results: $PASS passed, $FAIL failed"; echo "==========================================="
[[ $FAIL -eq 0 ]]
