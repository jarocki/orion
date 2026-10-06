#!/usr/bin/env bash
# Alert tuning (DEC-PHASE12-050) and SELF origin (DEC-PHASE12-051): pure library,
# CLI round-trip in a scratch HOME, postured wiring, Cockpit wiring.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d "$ROOT/tmp/tuning-test.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

echo "[tuning_lib: pure]"
if python3 - "$ROOT/scripts/awareness" "$TMP" <<'PY'
import sys, json, os, time, pathlib
sys.path.insert(0, sys.argv[1]); import tuning_lib as T
tmp = pathlib.Path(sys.argv[2])
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
now = 1_000_000.0
ck(T.load_rules("") == [] and T.load_rules("{not json") == [] and T.load_rules('{"rules":[{"engine":"suricata","mode":"tune"}]}') == [],
   "missing/corrupt/unspecific tuning -> no rules (a broken file silences nothing)")
r1 = T.make_rule("suricata", "squelch", sid=2210000, src_ip="192.168.4.57", signature="ET POLICY archive.ph", now=now)
r2 = T.make_rule("suricata", "tune", sid=2000001, now=now)
r3 = T.make_rule("zeek", "squelch", note="Scan::Port_Scan", ttl=60, now=now)
ck(r1["expires"] == now + 3600 and r2["expires"] is None and r3["expires"] == now + 60, "squelch expires (default 1h), tune never")
rules = [r1, r2, r3]
ck(T.suppressed_by(rules, "suricata", 2210000, None, "192.168.4.57", now)["id"] == r1["id"], "sid+src rule matches that source")
ck(T.suppressed_by(rules, "suricata", 2210000, None, "10.0.0.9", now) is None, "sid+src rule does NOT match another source")
ck(T.suppressed_by(rules, "suricata", 2000001, None, "10.0.0.9", now) is not None, "sid-only rule matches any source")
ck(T.suppressed_by(rules, "zeek", None, "Scan::Port_Scan", "1.2.3.4", now) is not None, "zeek note rule matches")
ck(T.suppressed_by(rules, "zeek", None, "Scan::Port_Scan", "1.2.3.4", now + 61) is None, "squelch expires on time")
ck(T.suppressed_by(rules, "suricata", 2000001, None, None, now + 10**9) is not None, "tune is still in force far later")
ck(T.suppressed_by(rules, "zeek", 2000001, None, None, now) is None, "a suricata sid rule never silences zeek")
txt = T.suricata_threshold_text(rules, now)
ck("suppress gen_id 1, sig_id 2210000, track by_src, ip 192.168.4.57" in txt, "derived threshold: sid+src -> track by_src")
ck("suppress gen_id 1, sig_id 2000001" in txt and "Scan::Port_Scan" not in txt, "derived threshold: sid-only rule; zeek rules have no representation")
ck("GENERATED" in txt.splitlines()[0], "derived file announces itself as generated")
ck(T.suricata_threshold_text(rules, now + 3601).count("suppress") == 1, "derived text drops the expired squelch -> reload is triggered")
# persistence detection
root = tmp / "persistence"
ck(T.persistence_present(root)[0] is False, "no /run/live/persistence -> not persistent")
root.mkdir(); ck(T.persistence_present(root)[0] is False, "empty persistence dir -> not persistent (nothing mounted)")
(root / "sdb3").mkdir(); (root / "sdb3" / "persistence.conf").write_text("/ union\n")
ok, where = T.persistence_present(root); ck(ok and where.endswith("sdb3"), f"mounted-looking child -> persistent at {where}")
ck("NO" in T.survives_reboot_line(False, "x") and "YES" in T.survives_reboot_line(True, "/run/live/persistence/sdb3"), "survives-reboot line is explicit")
# file round trip + TuningState refresh/derived-change signalling
f = tmp / "home" / "op" / ".config" / "orionx" / "tuning.json"
T.write_rules(f, rules); ck(oct(f.stat().st_mode & 0o777) == "0o600", "tuning.json written 0600")
st = T.TuningState(str(f))
ck(st.refresh(now) is True and len(st.rules) == 3, "first refresh loads rules and reports derived change")
ck(st.refresh(now) is False, "unchanged file -> no derived change")
ck(st.refresh(now + 3601) is True, "an expiry alone changes the derived text (reload needed)")
ck(st.suppressed_by("suricata", 2000001, None, None, now) is not None, "TuningState answers the match question")
ck(st.status(now)["rules"] == 3 and "persistent" in st.status(now), "status reports counts + persistence")
ck(T.pick_file([tmp / "nope", f]) == f, "pick_file ignores missing candidates")
PY
then pass "tuning_lib pure semantics"; else fail "tuning_lib assertions" "see output above"; fi

echo "[orionx-tune CLI round trip in a scratch HOME]"
export HOME="$TMP/home2"; mkdir -p "$HOME"; unset ORIONX_TUNING_FILE
TUNE="$ROOT/scripts/awareness/orionx-tune"
OUT="$(PATH="$TMP/nobin:$PATH" python3 "$TUNE" squelch --sid 2210000 --src 192.168.4.57 --signature "ET POLICY archive.ph" --ttl 1800 2>&1)"
if grep -q "squelched: sid 2210000" <<<"$OUT" && grep -qE "survives reboot: (YES|NO)" <<<"$OUT"; then pass "squelch writes a rule and states reboot survival"; else fail "squelch output" "$OUT"; fi
[[ -f "$HOME/.config/orionx/tuning.json" ]] && pass "rule file at ~/.config/orionx/tuning.json" || fail "rule file" "missing"
OUT2="$(python3 "$TUNE" tune --note Scan::Port_Scan 2>&1)"; grep -q "tuned off (kept): Zeek note Scan::Port_Scan" <<<"$OUT2" && pass "tune by Zeek note" || fail "tune output" "$OUT2"
ID="$(python3 "$TUNE" list | awk 'NR==1{print $1}')"
python3 "$TUNE" list | grep -q "active" && pass "list shows active rules" || fail "list" "$(python3 "$TUNE" list)"
python3 "$TUNE" remove "$ID" | grep -q "removed $ID" && pass "remove by id" || fail "remove" "id=$ID"
[[ "$(python3 "$TUNE" list | grep -c .)" -eq 1 ]] && pass "one rule remains after remove" || fail "remove count" "$(python3 "$TUNE" list)"
python3 "$TUNE" status | grep -q "survives reboot" && pass "status states persistence" || fail "status" "$(python3 "$TUNE" status)"
OUTR="$(python3 "$TUNE" squelch 2>&1 || true)"; grep -q "needs a Suricata sid or a Zeek note" <<<"$OUTR" && pass "refuses an unspecific rule" || fail "unspecific rule refused" "$OUTR"
python3 "$TUNE" squelch --sid 1 --ttl 1 >/dev/null; sleep 1.2; python3 "$TUNE" squelch --sid 2 >/dev/null 2>&1; python3 "$TUNE" list | grep -q "sid 1 " && fail "expired squelch pruned on next write" "sid 1 still listed" || pass "expired squelch pruned on next write"

echo "[orionx-postured wiring]"
PD="$ROOT/scripts/awareness/orionx-postured"
grep -q "import tuning_lib" "$PD" && pass "postured imports tuning_lib" || fail "import" "missing"
[[ "$(grep -c 'self.tuning.suppressed_by(' "$PD")" -ge 2 ]] && pass "both engines consult the tuning rules" || fail "suppressed_by calls" "$(grep -c 'self.tuning.suppressed_by(' "$PD")"
grep -q 'self.tuned_suppressed += 1' "$PD" && grep -q '"tuned_suppressed": self.tuned_suppressed' "$PD" && pass "tuned suppressions are counted and reported in status" || fail "counting" "missing"
grep -q 'detail=self._alert_detail(alert, "suricata"' "$PD" && grep -q 'detail=self._alert_detail(alert, "zeek"' "$PD" && pass "IDS events carry structured detail (sid/signature/addresses)" || fail "detail" "missing"
grep -q 'd\["origin"\] = "self"' "$PD" && pass "deck-sourced alerts get origin=self (DEC-PHASE12-051)" || fail "origin self" "missing"
grep -q 'ruleset-reload-nonblocking' "$PD" && grep -q 'tuning_lib.THRESHOLD_FILE' "$PD" && pass "derived threshold file written + ruleset reload over the socket" || fail "derived surface" "missing"
grep -q 'self._refresh_tuning(now)' "$PD" && pass "tuning re-read every loop pass" || fail "loop refresh" "missing"
python3 -m py_compile "$PD" 2>/dev/null && pass "postured compiles" || fail "postured compiles" "syntax error"
grep -q '^threshold-file: /etc/suricata/orionx-threshold.config' "$ROOT/iso/config/includes.chroot/etc/suricata/orionx.yaml" && pass "orionx.yaml names the derived threshold file" || fail "orionx.yaml" "threshold-file missing"
[[ -f "$ROOT/iso/config/includes.chroot/etc/suricata/orionx-threshold.config" ]] && pass "empty threshold file ships so Suricata starts clean" || fail "shipped threshold file" "missing"
grep -q '\["orionx-tune"\]=' "$ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot" && pass "orionx-tune on PATH via 0700" || fail "0700 symlink" "missing"

echo "[Cockpit wiring]"
if python3 - "$ROOT/scripts/cockpit" <<'PY'
import sys
sys.path.insert(0, sys.argv[1]); import cockpit_lib as L
def ck(c, m):
    print(("  ok   " if c else "  FAIL ") + m)
    if not c: raise SystemExit(1)
ev = {"source":"suricata","category":"ids","severity":"warning","message":"ET POLICY x — 192.168.4.57 → 1.2.3.4 (tcp) sid:2210000",
      "detail":{"sid":2210000,"signature":"ET POLICY x","src_ip":"192.168.4.57"}}
a = L.tune_args(ev, "squelch")
ck(a[:2] == ["orionx-tune","squelch"] and "--sid" in a and a[a.index("--sid")+1] == "2210000" and "--src" in a, f"suricata event -> squelch args {a}")
ck(L.tune_args({"source":"suricata","message":"x sid:42","detail":{}}, "tune")[3] == "42", "sid recovered from the message when detail lacks it")
ck(L.tune_args({"source":"zeek","detail":{"note":"Scan::Port_Scan","src_ip":"9.9.9.9"}}, "tune")[2:4] == ["--note","Scan::Port_Scan"], "zeek event -> note args")
ck(L.tune_args({"source":"postured","category":"health","message":"x","detail":{}}, "squelch") is None, "a health event is not tunable")
ck(L.tune_args(ev, "delete") is None, "unknown mode refused")
now = 1000.0
hostile = [{"ts":now,"severity":"critical","category":"ids"}]
selfev = [{"ts":now,"severity":"critical","category":"ids","detail":{"origin":"self"}}]
ck(L.pressure(hostile, now) > 0 and L.pressure(selfev, now) == 0.0, "origin=self contributes 0 threat pressure (DEC-PHASE12-051)")
PY
then pass "cockpit_lib tune_args + SELF pressure"; else fail "cockpit_lib assertions" "see output above"; fi
CK="$ROOT/scripts/cockpit/orionx-cockpit"
grep -q 'self._tune_selected("squelch" if name == "s" else "tune")' "$CK" && pass "drill-down keys s/t wired" || fail "keys" "missing"
grep -q '\[s\] squelch this signature' "$CK" && pass "drill-down shows the two keys for tunable events" || fail "footer" "missing"
grep -q 'tag = "SELF "' "$CK" && pass "stream row tags SELF events" || fail "SELF tag" "missing"
python3 -m py_compile "$CK" "$ROOT/scripts/cockpit/cockpit_lib.py" 2>/dev/null && pass "cockpit compiles" || fail "cockpit compiles" "syntax"
echo "==========================================="; echo "Results: $PASS passed, $FAIL failed"; echo "==========================================="
[[ $FAIL -eq 0 ]]
