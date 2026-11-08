#!/usr/bin/env bash
# Cockpit honesty helpers, no display needed (DEC-PHASE12-069/070):
#   settings_io  — atomic writes that report failure; one reboot-truth line
#   posture_data — "requested" until orionx-postured confirms the tier
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
mkdir -p "$ROOT/tmp"

echo "[settings_io]"
if python3 - "$ROOT" <<'PY'
import os, sys, tempfile, pathlib
root = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(root/"scripts"))
from control_center.helpers import settings_io as S
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
td = pathlib.Path(tempfile.mkdtemp(dir=str(root/"tmp")))
f = td/"cfg"/"autonomy.json"
ok, err = S.atomic_write_text(f, '{"a": 1}\n')
ck(ok and err == "" and f.read_text() == '{"a": 1}\n', "write creates the directory and the file")
ck(sorted(p.name for p in f.parent.iterdir()) == ["autonomy.json"], "no temp file left behind")
if os.geteuid() != 0:
    ro = td/"ro"; ro.mkdir(); (ro/"x.json").write_text("old"); ro.chmod(0o500)
    ok, err = S.atomic_write_text(ro/"x.json", "new")
    ro.chmod(0o700)
    ck(not ok and "x.json" in err and (ro/"x.json").read_text() == "old",
       f"unwritable directory -> (False, reason), old content intact ({err})")
else:
    print("  ok   (skipped read-only case: running as root)")
none = td/"nopersist"
ck(S.reboot_line(none).startswith("survives reboot: NO — no /run/live/persistence directory"), S.reboot_line(none))
mnt = td/"persist"; (mnt/"sdb2").mkdir(parents=True); (mnt/"sdb2"/"persistence.conf").write_text("/ union\n")
ck(S.reboot_line(mnt) == f"survives reboot: YES (persistence at {mnt/'sdb2'})", S.reboot_line(mnt))
PY
then pass "atomic writes report failure; reboot line from tuning_lib.persistence_present"; else fail "settings_io" "see above"; fi

echo "[posture verdict: requested until orionx-postured confirms (UX-01)]"
if python3 - "$ROOT" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(root/"scripts"))
from control_center.helpers import posture_data as P
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
T = 5000.0   # request time
good = {"ts": T + 2, "tier": "1", "ids_expected": True, "ids_active": True, "rules_usable": True}
v = P.verdict("1", {}, T, T + 1)
ck(v["state"] == "pending" and v["text"].startswith("requested Tier 1") and "waiting for orionx-postured" in v["text"], v["text"])
ck("set" not in v["text"].lower().split() and "armed" not in v["text"], "the request is never called 'set' or 'armed'")
v = P.verdict("1", good, T, T + 3)
ck(v["state"] == "enforced" and v["level"] == "ok" and "enforced by orionx-postured" in v["text"], v["text"])
v = P.verdict("1", dict(good, rules_usable=False), T, T + 3)
ck(v["state"] == "degraded" and "NO IDS RULES" in v["text"], v["text"])
v = P.verdict("1", dict(good, ids_active=False), T, T + 3)
ck(v["state"] == "degraded" and "IDS DOWN" in v["text"], v["text"])
v = P.verdict("2", dict(good, tier="2", deception_armed=False), T, T + 3)
ck(v["state"] == "degraded" and "deception NOT armed" in v["text"], v["text"])
v = P.verdict("2", dict(good, tier="2", deception_armed=True), T, T + 3)
ck(v["state"] == "enforced" and "deception armed" in v["text"], v["text"])
v = P.verdict("2", {}, T, T + 20)
ck(v["state"] == "not-enforced" and "orionx-postured not running" in v["text"] and "systemctl start orionx-postured" in v["text"], v["text"])
v = P.verdict("2", dict(good, ts=T - 100, tier="0"), T, T + 20)
ck(v["state"] == "not-enforced" and "not publishing" in v["text"], v["text"])
v = P.verdict("2", dict(good, ts=T + 18, tier="0"), T, T + 20)
ck(v["state"] == "not-enforced" and "still reports Tier 0" in v["text"], v["text"])
v = P.verdict("1", dict(good, ts=T - 10), T, T + 2)
ck(v["state"] == "pending", "a status written before the request does not confirm it")
PY
then pass "posture verdict matrix"; else fail "posture verdict" "see above"; fi

echo "[LIVE layout + text fitting (DEC-PHASE12-073)]"
if python3 - "$ROOT" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1]); sys.path.insert(0, str(root/"scripts/cockpit"))
import cockpit_lib as L
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
# Reference deck: 1366x768, 30 px panel, ~37 px title bar -> ~701 px window;
# minus the left tab strip the LIVE drawing area measured under Xvfb is in
# the GTK suite. Prove the layout for a range around it.
for W, H in ((1236, 695), (1180, 640), (1366, 768), (1024, 600)):
    lay = L.live_layout(W, H)
    inside = all(x >= 0 and y >= 0 and x + w <= W and y + h <= H for x, y, w, h in lay.values())
    rects = [v for k, v in lay.items() if k != "header"]
    overlap = any(a is not b and a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
                  for a in rects for b in rects)
    ck(inside and not overlap and lay["systems"][3] >= L.SYSTEMS_MIN_H,
       f"{W}x{H}: panels inside, no overlap, SYSTEMS {lay['systems'][3]} px >= {L.SYSTEMS_MIN_H}")
m = lambda t: 7.0 * len(t)          # a fixed-pitch stand-in for cairo text_extents
s = L.ellipsize("ET SCAN Nmap SYN scan 10.0.0.5 -> 10.0.0.12 from a very long signature", 140, m)
ck(m(s) <= 140 and s.endswith("…"), f"ellipsize fits and marks the cut: {s!r}")
ck(L.ellipsize("short", 140, m) == "short", "short text untouched")
ck(L.fade_for(0) == 1.0 and L.fade_for(3600) == L.FADE_FLOOR == 0.6, "fade floor 0.6 (was 0.35, ~2.4:1 contrast)")
ck(L.SEVERITY_TAG == {"info": "INFO", "notice": "NOTE", "warning": "WARN", "critical": "CRIT"}, "severity word per row")
out = ("squelched: sid 2210000 (ET SCAN Potential SSH Scan OUTBOUND) from 192.168.4.57 for 59 min [12ff24ec6d]\n"
       "rules active: 3\nsurvives reboot: NO — no /run/live/persistence directory — this boot has no persistence volume. "
       "The rule lasts until this deck reboots; set up persistence (User Guide §3) to keep it.\n")
msg = L.tune_message(out)
ck(msg.splitlines()[0].startswith("survives reboot: NO") and len(msg.splitlines()) == 3 and "[12ff24ec6d]" in msg,
   "orionx-tune lines kept, reboot verdict first, nothing cut (UX-10, P2-1)")
ev = {"message": "m " * 200, "detail": {"signature": "S" * 300, "ports_seen": list(range(40)), "src_ip": "10.0.0.9"}}
rows = L.drill_rows(ev, 60)
joined = "".join(t for _l, t in rows)
ck("S" * 300 in joined.replace(" ", "") and "39" in joined and all(len(t) <= 78 for _l, t in rows),
   f"drill-down rows carry every char of a 300-char signature and all 40 ports, wrapped ({len(rows)} rows) (UX-19)")
ck([l for l, _t in rows if l][:3] == ["message", "src ip", "signature"], "operator-first field order kept")
# #128: the producer-named tool is one cell on the event row and two rows in the drill-down.
ev3 = {"source": "suricata", "category": "ids", "message": "m",
       "detail": {"src_ip": "10.0.0.9", "signature": "ET SCAN Nmap", "tool": "nmap", "tool_conf": "high", "origin": "self"}}
ck(L.source_label(ev3) == "SELF suricata/ids·nmap", f"event row cell carries SELF and the tool: {L.source_label(ev3)!r}")
ck(L.source_label({"source": "firewall", "category": "scan", "detail": {}}) == "firewall/scan", "no tool named -> no suffix, no guess")
labels = [l for l, _t in L.drill_rows(ev3, 60) if l]
ck(labels[:5] == ["message", "src ip", "signature", "tool", "tool conf"], f"drill-down shows tool and its confidence right after the signature: {labels}")
ck("L.source_label(ev)" in (root/"scripts/cockpit/orionx-cockpit").read_text(), "the event row is drawn from cockpit_lib.source_label")
PY
then pass "LIVE layout fits the reference deck; text is fitted, never clipped mid-word"; else fail "LIVE layout" "see above"; fi

echo "[DEFENSIVE ACTIONS: suggestions from heald's snapshot, SOURCES from pewpew_feed, every empty reason said (#126)]"
if ORIONX_AUTONOMY_FILE="$ROOT/tmp/no-such-autonomy.json" python3 - "$ROOT" <<'PY'
import json, sys, tempfile, time, pathlib
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root/"scripts/cockpit")); sys.path.insert(0, str(root/"scripts/healing"))
sys.path.insert(0, str(root/"scripts/osint"))
import cockpit_lib as L
import healing_lib as hl
import pewpew_feed as F
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
td = pathlib.Path(tempfile.mkdtemp(dir=str(root/"tmp")))
now = time.time()
texts = lambda rows: [r["label"] + r["text"] for r in rows]

# (a) a proposal sealed into the chain reaches the pane through the ONE snapshot.
chain, status = td/"chain.jsonl", td/"healing-status.json"
hl.append_entry({"ts": now - 90, "kind": hl.KIND_PROPOSED, "playbook": "block_ip", "target": "203.0.113.9",
                 "level": "propose", "reason": "a host that swept our ports is scanning us; drop it",
                 "event_id": "ab12cd34ef56ab78"}, chain)
hl.append_entry({"ts": now - 30, "kind": hl.KIND_PROPOSED, "playbook": "block_ip", "target": "203.0.113.9",
                 "level": "propose", "reason": "again", "event_id": "ab12cd34ef56ab79"}, chain)
hl.write_status(hl.status_snapshot(chain, now, autonomy={"block_ip": "propose"}), status)
heal = L.healing_actions(status, now=now)
ck(heal["readable"] and [(p["action"], p["target"], p["count"], p["event_id"]) for p in heal["proposed"]]
   == [("block_ip", "203.0.113.9", 2, "ab12cd34ef56ab79")], f"healing_actions carries heald's proposals: {heal['proposed']}")
ck(heal["autonomy"]["block_ip"] == "propose" and heal["autonomy"]["isolate_node"] == "off", "and heald's consent levels")
t = texts(L.actions_pane(heal, None, now))
ck(any(x.startswith("SUGGESTED (1): block_ip → 203.0.113.9 ×2") for x in t), f"SUGGESTED row drawn from the snapshot: {t}")
ck("run: sudo orionx-heal run block_ip --target 203.0.113.9" in t, "with the one command that acts on it")
src = (root/"scripts/cockpit/cockpit_lib.py").read_text()
ck("KIND_PROPOSED" not in src and "chain.jsonl" not in src, "the Cockpit never reads the chain itself (DEC-PHASE12-065)")

# (c) why the pane is empty: one line per reason, never a blank pane.
base = {"readable": True, "chain_ok": True, "pending": [], "active": [], "proposed": [], "proposed_window": 1800.0}
t = texts(L.actions_pane(dict(base, autonomy={k: "off" for k in hl.PLAYBOOK_NAMES}), None, now))
ck("autonomy is OFF for every action class — Workbench → Engine, or: orionx-heal autonomy CLASS propose" in t, f"all-off reason: {t}")
hl.write_status(hl.status_snapshot(td/"none.jsonl", now, autonomy=hl.load_autonomy()), status)
t = texts(L.actions_pane(L.healing_actions(status, now=now), None, now))
ck(any(x.startswith("autonomy is OFF for every action class") for x in t), "absent autonomy.json reaches the pane as all-off (fail-closed)")
t = texts(L.actions_pane(dict(base, autonomy={"block_ip": "propose"}), None, now))
ck("no bus event met a healing trigger in the last 30 min" in t and "nothing awaiting approval, in force or suggested" in t,
   f"consent given but nothing qualified: {t}")
ck(not any("autonomy is OFF" in x for x in t), "and it does not claim autonomy is off")
old = dict(json.loads(status.read_text()), ts=now - 45); status.write_text(json.dumps(old))
t = texts(L.actions_pane(L.healing_actions(status, now=now), None, now))
ck(t[:2] == ["state unknown — orionx-heald not publishing (snapshot 45 s old)",
             "check: systemctl status orionx-heald  ·  sudo orionx-heal status"], f"stale snapshot: {t[:2]}")
t = texts(L.actions_pane(L.healing_actions(td/"missing.json", now=now), None, now))
ck(t[0].startswith("state unknown — orionx-heald not publishing") and "missing" in t[0], f"heald not running: {t[0]}")
ck("SOURCES: event buffer not read yet" in t, "SOURCES still says something while healing state is unknown")

# (b) SOURCES rows ARE build_feed's sources for the same events (cannot disagree).
bus = td/"events.jsonl"
lines = [json.dumps({"ts": now - 4000, "severity": "critical", "source": "firewall", "category": "scan",
                     "message": "old", "detail": {"src_ip": "192.0.2.1"}}), "not json"]
for i in range(9):
    ip = f"203.0.113.{i % 6 + 1}"
    lines.append(json.dumps({"ts": now - 60 + i, "severity": ("warning", "critical", "notice")[i % 3],
                             "source": ("firewall", "suricata", "zeek")[i % 3], "category": "scan", "id": f"e{i}",
                             "message": f"port scan from {ip}",
                             "detail": {"src_ip": ip, "detector": "orionx-scanwatch", "tool": ("nmap", "masscan")[i % 2]}}))
lines.append(json.dumps({"ts": now - 2, "severity": "warning", "source": "suricata", "category": "ids", "message": "no address"}))
bus.write_text("\n".join(lines) + "\n")
tail = L.EventTail(bus, backfill=200); tail.poll()
got = L.attack_sources(tail.events, now)
feed = F.build_feed(bus.read_text().splitlines(), now=now)
want = [{k: s[k] for k in L.SOURCE_FIELDS} for s in feed["sources"][:L.SOURCES_MAX]]
ck(got["rows"] == want and got["total"] == len(feed["sources"]) == 6 and got["window"] == feed["window_seconds"],
   f"SOURCES rows == pewpew_feed.build_feed sources for the same bus lines ({len(want)} of {got['total']})")
ck(set(L.SOURCE_FIELDS) == {"ip", "events", "last_seen", "max_severity", "detectors", "tools"}, "ip, events, last_seen, severity, detectors, tools")
ck(got["rows"][0]["tools"] and got["rows"][0]["max_severity"] == "critical", f"producer tools ride through: {got['rows'][0]}")
t = texts(L.actions_pane(dict(base, autonomy={"block_ip": "propose"}), got, now))
i = t.index("SOURCES (6, last 15 min)")
ck(t[i + 1].startswith(f"• {want[0]['ip']}  CRIT  {want[0]['events']} ev") and len(t[i + 1:i + 1 + L.SOURCES_MAX]) == 4,
   f"SOURCES header, then one row per source in the feed's order: {t[i + 1]!r}")
ck("+2 more — the Attack Map (click this panel) lists all" in t, "rows past SOURCES_MAX are counted, not dropped")
import inspect
body = inspect.getsource(L.attack_sources)
ck("_pewpew.build_feed(" in body and "+=" not in body and "sorted(" not in body and "classify_ip" not in body,
   "attack_sources calls build_feed and does no counting, sorting or classifying of its own")
empty = L.attack_sources([], now)
t = texts(L.actions_pane(dict(base, autonomy={"block_ip": "propose"}), empty, now))
ck("SOURCES: no attributed source in the last 15 min (0 bus events held)" in t, f"no sources is said: {t[-1]}")
PY
then pass "DEFENSIVE ACTIONS shows proposals, SOURCES and every empty reason from one authority each (#126)"; else fail "DEFENSIVE ACTIONS pane model" "see above"; fi

echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
