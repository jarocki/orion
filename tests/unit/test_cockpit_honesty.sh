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

echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
