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

echo "[threshold file under /var/lib/suricata]"
grep -q 'THRESHOLD_FILE = Path("/var/lib/suricata/orionx-threshold.config")' "$ROOT/scripts/awareness/tuning_lib.py" && pass "tuning_lib writes under /var/lib/suricata" || fail "tuning path" "still /etc"
[[ -f "$ROOT/iso/config/includes.chroot/var/lib/suricata/orionx-threshold.config" && ! -f "$ROOT/iso/config/includes.chroot/etc/suricata/orionx-threshold.config" ]] && pass "shipped threshold file moved (one location)" || fail "threshold file location" "both or neither present"

echo "[Synapse venv paths]"
S="$ROOT/scripts/setup-matrix.sh"
grep -q 'synapse_present()' "$S" && grep -q 'SYNAPSE_VENV="/opt/venvs/matrix-synapse"' "$S" && grep -q '"$SYNAPSE_VENV/bin/synapse_homeserver"' "$S" && pass "installer probes the venv binary (not only PATH)" || fail "synapse probe" "missing"
# DEC-PHASE12-102: setup-matrix no longer runs --generate-config (the package
# ships homeserver.yaml; setup writes conf.d/orionx.yaml). It must never run
# Synapse with the system python3.
! grep -qE '^\s*python3 -m synapse\.app\.homeserver' "$S" && pass "installer never runs Synapse with the system python3" || fail "system python3" "found"
# DEC-PHASE12-102: the package unit (venv python, verified) is the only unit;
# the Orion-X drop-in must not override its ExecStart.
D="$ROOT/iso/config/includes.chroot/etc/systemd/system/matrix-synapse.service.d/orionx.conf"
[[ -f "$D" ]] && ! grep -q '^ExecStart' "$D" && [[ ! -e "$U/matrix-synapse-orionx.service" ]] && pass "one Synapse unit (package), drop-in keeps its venv ExecStart" || fail "unit ExecStart" "drop-in missing or overrides ExecStart, or orionx unit back"
grep -q 'wg0.conf' "$U/matrix-synapse-orionx.service" | grep -v '^#' >/dev/null && fail "stale wg0.conf pre-check removed" "still present" || pass "stale wg0.conf pre-check removed (DEC-PHASE12-041)"
grep -q '/opt/venvs/matrix-synapse/bin/synapse_homeserver' "$ROOT/scripts/control_center/sections/comms.py" && pass "Comms installed-probe follows the venv path" || fail "comms probe" "missing"
grep -q 'once it is active, clients will connect to' "$ROOT/scripts/control_center/sections/comms.py" && pass "Comms does not imply a running server when inactive" || fail "comms wording" "missing"

echo "[keyring]"
grep -qE '^gnome-keyring$' "$ROOT/iso/config/package-lists/orionx.list.chroot" && pass "gnome-keyring on the image (DEC-PHASE12-061)" || fail "gnome-keyring" "not in package list"
grep -q 'Use no encryption' "$ROOT/docs/User_Guide.md" && pass "User Guide explains Element's keyring prompt" || fail "guide" "missing"
for d in 059 060 061; do grep -rq "DEC-PHASE12-$d" "$ROOT/scripts" "$ROOT/iso/config" && pass "DEC-PHASE12-$d annotated" || fail "DEC-PHASE12-$d" "not annotated"; done
echo "==========================================="; echo "Results: $PASS passed, $FAIL failed"; echo "==========================================="
[[ $FAIL -eq 0 ]]
