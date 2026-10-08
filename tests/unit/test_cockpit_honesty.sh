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
PY
then pass "LIVE layout fits the reference deck; text is fitted, never clipped mid-word"; else fail "LIVE layout" "see above"; fi

echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
