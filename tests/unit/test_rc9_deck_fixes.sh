#!/usr/bin/env bash
# rc9 deck fixes (DEC-PHASE12-059..061): mesh snapshot, Synapse venv paths, keyring.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d "$ROOT/tmp/rc9-test.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
U="$ROOT/iso/config/includes.chroot/usr/share/orionx/systemd"

echo "[mesh snapshot: the writer, with wg stubbed]"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/wg" <<'STUB'
#!/usr/bin/env bash
# `wg show wg0 dump`: interface line, then peers (pubkey psk endpoint allowed hs tx rx keepalive)
printf 'PRIV\tPUB\t51820\toff\n'
printf 'pk1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\t(none)\t192.168.4.20:51820\t10.0.99.20/32\t%s\t1024\t2048\t25\n' "$(( $(date +%s) - 30 ))"
printf 'pk2BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\t(none)\t(none)\t10.0.99.21/32\t0\t0\t0\toff\n'
STUB
chmod +x "$TMP/bin/wg"
printf '#!/usr/bin/env bash\n[[ "$1 $2 $3" == "link show wg0" ]] && exit 0; exit 1\n' > "$TMP/bin/ip"; chmod +x "$TMP/bin/ip"   # mesh_is_active also asks the kernel
printf '{\n  "interface": "wg0",\n  "vpn_ip": "10.0.99.85",\n  "mode": "discovery",\n  "start_time": "%s",\n  "pubkey": "9i3m5aW6xyz"\n}\n' "$(( $(date +%s) - 3600 ))" > "$TMP/state.json"
OUT="$(cd "$ROOT" && PATH="$TMP/bin:$PATH" MESH_STATE_FILE="$TMP/state.json" MESH_SNAPSHOT_FILE="$TMP/run/mesh-status.json" MESH_EVENT_CLI=/nonexistent bash -c 'source scripts/mesh/mesh-lib.sh; mesh_snapshot_write' 2>&1)"
if [[ -f "$TMP/run/mesh-status.json" ]]; then pass "snapshot written (dir created)"; else fail "snapshot written" "$OUT"; fi
python3 - "$TMP/run/mesh-status.json" "$ROOT/scripts/control_center/helpers" <<'PY' && pass "snapshot JSON parses and carries identity + peers; Cockpit loader reads it" || fail "snapshot content" "see above"
import json, sys, time
sys.path.insert(0, sys.argv[2]); import mesh_data as M
d = json.load(open(sys.argv[1]))
assert d["active"] is True and d["interface"] == "wg0" and d["vpn_ip"] == "10.0.99.85" and d["mode"] == "discovery", d
assert isinstance(d["start_time"], int) and d["start_time"] > 0 and d["pubkey_short"] == "9i3m5aW6xy", d
assert len(d["peers"]) == 2 and d["peers"][0]["node"] == "10.0.99.20" and d["peers"][0]["endpoint"] == "192.168.4.20:51820", d["peers"]
assert d["peers"][0]["rx"] == 2048 and d["peers"][0]["tx"] == 1024 and d["peers"][1]["endpoint"] == "" and d["peers"][1]["handshake"] == 0, d["peers"]
s = M.load_snapshot(sys.argv[1]); assert s and s["peers"][0]["handshake_age"] is not None and 25 <= s["peers"][0]["handshake_age"] <= 90, s["peers"][0]
assert s["peers"][1]["handshake_age"] is None and M.peer_state(None) == "never" and M.peer_state(s["peers"][0]["handshake_age"]) == "live"
assert M.load_snapshot(sys.argv[1] + ".nope") is None and M.snapshot_age(s, time.time()) is not None
PY
[[ "$(stat -f %Lp "$TMP/run/mesh-status.json" 2>/dev/null || stat -c %a "$TMP/run/mesh-status.json")" == "644" ]] && pass "snapshot is world-readable (0644) — the Cockpit runs as the operator" || fail "snapshot mode" "$(stat -f %Lp "$TMP/run/mesh-status.json" 2>/dev/null)"
OUT2="$(cd "$ROOT" && PATH="$TMP/bin:$PATH" MESH_STATE_FILE="$TMP/absent.json" MESH_SNAPSHOT_FILE="$TMP/run/mesh-status.json" bash -c 'source scripts/mesh/mesh-lib.sh; mesh_snapshot_write' 2>&1)"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['active'] is False and d['vpn_ip']=='' , d" "$TMP/run/mesh-status.json" && pass "no state file -> snapshot says inactive (what leave writes)" || fail "inactive snapshot" "$OUT2"
# sysfs reader against a fixture
mkdir -p "$TMP/sys/wg0/statistics"; echo 5000 > "$TMP/sys/wg0/statistics/rx_bytes"; echo 7000 > "$TMP/sys/wg0/statistics/tx_bytes"
python3 -c "
import sys, pathlib; sys.path.insert(0, sys.argv[1]); import mesh_data as M
assert M.sysfs_bytes('wg0', pathlib.Path(sys.argv[2])) == (5000, 7000) and M.sysfs_bytes('wg9', pathlib.Path(sys.argv[2])) is None" "$ROOT/scripts/control_center/helpers" "$TMP/sys" && pass "kernel counters read from sysfs without privilege" || fail "sysfs reader" "mismatch"

echo "[wiring]"
grep -q '^        snapshot)' "$ROOT/scripts/mesh/orionx-mesh" && pass "orionx-mesh snapshot subcommand" || fail "subcommand" "missing"
grep -q 'mesh_snapshot_write 2>/dev/null || true' "$ROOT/scripts/mesh/mesh-join.sh" && grep -q 'mesh_snapshot_write 2>/dev/null || true' "$ROOT/scripts/mesh/mesh-leave.sh" && pass "join and leave write the snapshot immediately" || fail "join/leave snapshot" "missing"
grep -q 'mesh_emit info service "joined the mesh' "$ROOT/scripts/mesh/mesh-join.sh" && grep -q 'mesh_emit info service "left the mesh' "$ROOT/scripts/mesh/mesh-leave.sh" && pass "join and leave publish to the bus (History)" || fail "mesh events" "missing"
for f in orionx-mesh-status.service orionx-mesh-status.timer; do [[ -f "$U/$f" ]] && pass "unit ships: $f" || fail "unit" "$f missing"; done
grep -q 'ExecStart=/opt/orionx/scripts/mesh/orionx-mesh snapshot' "$U/orionx-mesh-status.service" && grep -q 'CapabilityBoundingSet=CAP_NET_ADMIN' "$U/orionx-mesh-status.service" && grep -q 'ReadWritePaths=/run/orionx' "$U/orionx-mesh-status.service" && pass "snapshot unit: root, NET_ADMIN only, writes /run/orionx only" || fail "snapshot unit hardening" "see unit"
grep -q 'OnUnitActiveSec=10s' "$U/orionx-mesh-status.timer" && pass "timer every 10 s" || fail "timer" "cadence"
grep -q '"orionx-mesh-status.timer"' "$ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot" && grep -q '"orionx-mesh-status.service"' "$ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot" && pass "0615 installs + autostarts the snapshot timer" || fail "0615" "units not listed"
grep -qE '^d /run/orionx ' "$ROOT/iso/config/includes.chroot/usr/lib/tmpfiles.d/orionx.conf" && pass "/run/orionx guaranteed by tmpfiles" || fail "tmpfiles" "no /run/orionx"

echo "[threshold file under /var/lib/suricata — executed, not grepped (F-13)]"
# The writer's path (tuning_lib.THRESHOLD_FILE) must be the file the shipped
# Suricata config loads, and the text the writer generates must be threshold
# syntax Suricata accepts for a suppress rule.
TH_OUT="$(cd "$ROOT/scripts/awareness" && PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/iso/config/includes.chroot/etc/suricata/orionx.yaml" <<'PY' 2>&1
import re, sys, time
import tuning_lib as T
yaml_line = [l for l in open(sys.argv[1]) if l.startswith("threshold-file:")]
assert len(yaml_line) == 1, "orionx.yaml must name exactly one threshold-file"
loaded = yaml_line[0].split(":", 1)[1].strip()
assert str(T.THRESHOLD_FILE) == loaded, f"writer writes {T.THRESHOLD_FILE}, Suricata loads {loaded}"
assert str(T.THRESHOLD_FILE).startswith("/var/lib/suricata/"), "postured is ProtectSystem=strict; /etc is read-only to it"
now = time.time()
r = T.make_rule("suricata", "tune", sid=2010935, src_ip="10.0.0.9", now=now)
txt = T.suricata_threshold_text([r], now)
rules = [l for l in txt.splitlines() if l and not l.startswith("#")]
assert len(rules) == 1 and re.match(r"^suppress gen_id 1, sig_id 2010935, track by_src, ip 10\.0\.0\.9\b", rules[0]), rules
print("ok", loaded)
PY
)"
[[ "$TH_OUT" == ok* ]] && pass "tuning_lib writes the file orionx.yaml loads, under /var/lib/suricata, in suppress syntax" || fail "threshold writer vs loader" "$TH_OUT"
[[ -f "$ROOT/iso/config/includes.chroot/var/lib/suricata/orionx-threshold.config" && ! -f "$ROOT/iso/config/includes.chroot/etc/suricata/orionx-threshold.config" ]] && pass "shipped threshold file moved (one location)" || fail "threshold file location" "both or neither present"

echo "[Synapse venv paths — the installer probe, executed against a fake venv]"
S="$ROOT/scripts/setup-matrix.sh"
PROBE="$TMP/probe.sh"
{ echo 'set -u'; grep -E '^SYNAPSE_VENV=' "$S"; sed -n '/^synapse_present() {/,/^}/p' "$S"; } > "$PROBE"
if grep -q '^synapse_present() {' "$PROBE"; then
    mkdir -p "$TMP/venv/bin"; printf '#!/bin/sh\n' > "$TMP/venv/bin/synapse_homeserver"; chmod +x "$TMP/venv/bin/synapse_homeserver"
    ( PATH=/usr/bin:/bin; . "$PROBE"; SYNAPSE_VENV="$TMP/venv"; synapse_present ) && pass "synapse_present finds the venv binary (not only PATH)" || fail "synapse probe" "venv binary not detected"
    ( PATH=/usr/bin:/bin; . "$PROBE"; SYNAPSE_VENV="$TMP/novenv"; synapse_present ) && fail "synapse probe" "reported present with no venv and nothing on PATH" || pass "synapse_present is false with no venv and nothing on PATH"
else
    fail "synapse probe" "synapse_present() not found in setup-matrix.sh"
fi
# DEC-PHASE12-102: setup-matrix no longer runs --generate-config (the package
# ships homeserver.yaml; setup writes conf.d/orionx.yaml); it must never run
# Synapse with the system python3.
! grep -qE '^\s*python3 -m synapse\.app\.homeserver' "$S" && pass "installer never runs Synapse with the system python3" || fail "system python3" "found"
# Synapse unit authority (lead ruling, QA round 1): the package's
# matrix-synapse.service is the authority and matrix-synapse-orionx.service is
# being retired (group B1). Whichever ships, no live line may reference
# wg0.conf, and any ExecStart must use the venv python.
D="$ROOT/iso/config/includes.chroot/etc/systemd/system/matrix-synapse.service.d/orionx.conf"
[[ ! -e "$U/matrix-synapse-orionx.service" ]] && pass "matrix-synapse-orionx.service retired (package unit is the one authority, DEC-PHASE12-102)" || fail "unit authority" "matrix-synapse-orionx.service is back"
[[ -f "$D" ]] && ! grep -q '^ExecStart' "$D" && pass "drop-in present and keeps the package's venv ExecStart" || fail "drop-in" "missing or overrides ExecStart"
for d in "$ROOT"/iso/config/includes.chroot/etc/systemd/system/matrix-synapse.service.d/*.conf; do
    [[ -f "$d" ]] || continue
    bad="$(grep -E '^ExecStart=.+' "$d" | grep -v '^ExecStart=/opt/venvs/matrix-synapse/bin/python' || true)"
    [[ -z "$bad" ]] && pass "drop-in ${d##*/}: ExecStart uses the venv python" || fail "drop-in ${d##*/}" "$bad"
    grep -v '^[[:space:]]*#' "$d" | grep -q 'wg0.conf' && fail "drop-in ${d##*/}" "references wg0.conf" || pass "drop-in ${d##*/}: no wg0.conf"
done
grep -q '/opt/venvs/matrix-synapse/bin/synapse_homeserver' "$ROOT/scripts/control_center/sections/comms.py" && pass "Comms installed-probe follows the venv path" || fail "comms probe" "missing"
grep -q 'once it is active, clients will connect to' "$ROOT/scripts/control_center/sections/comms.py" && pass "Comms does not imply a running server when inactive" || fail "comms wording" "missing"

echo "[keyring]"
grep -qE '^gnome-keyring$' "$ROOT/iso/config/package-lists/orionx.list.chroot" && pass "gnome-keyring on the image (DEC-PHASE12-061)" || fail "gnome-keyring" "not in package list"
grep -q 'Use no encryption' "$ROOT/docs/User_Guide.md" && pass "User Guide explains Element's keyring prompt" || fail "guide" "missing"
# Annotation presence is bookkeeping, not behaviour; counted separately (F-13).
ANN=0; for d in 059 060 061; do git -C "$ROOT" grep -q "DEC-PHASE12-$d" -- scripts iso/config && ANN=$((ANN+1)); done
echo "  (annotations present: $ANN/3 — not counted as behavioural passes)"
echo "==========================================="; echo "Results: $PASS passed, $FAIL failed"; echo "==========================================="
[[ $FAIL -eq 0 ]]
