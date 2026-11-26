#!/usr/bin/env bash
# shellcheck shell=bash
#
# deck-check.sh — the v3.2.0 hardware boot test in one command. Collects, on a
# booted deck, the evidence the build host cannot produce, into one tarball
# to attach to the issues (#96 narration timing, #121 apt, #188 deck checks,
# #40/#78 boot and session, #163 Nebula on Ollama 0.40, #197-#202 Cockpit).
#
# Usage (on the deck, from the desktop session, once the desktop is up):
#   sudo /opt/orionx/optional/deck-check.sh            # prints the tarball path last
#   sudo /opt/orionx/optional/deck-check.sh --no-audio # skip the spoken-narration test
#
# What it does, so nothing surprises you:
#   - Reads state: versions, boot timing, units, journals, AppArmor denials,
#     memory, the Cockpit's sources (orionx-optional, heald, postured).
#   - Runs the in-guest CI probes directly (runtime-verify.sh, perf-measure.sh):
#     the same session and boot-time checks the QEMU job makes, on hardware.
#   - Asks Nebula one question ("Reply with the single word OK.") and times it:
#     this loads the model into memory (about 2 GB) for a few minutes.
#   - Plays the narration test three times (orionx-rain --speech-test
#     --all-engines) unless --no-audio: you will hear it.
#   - Runs apt-evidence.sh (read-only; every apt call is a simulation) and
#     includes its tarball.
# It installs, starts, stops, enables and deletes nothing outside its own
# output directory. tests/unit/test_deck_check.sh runs it against stubs and
# asserts that.
#
# Exit codes: 0 bundle written (individual steps may have failed: see
# SUMMARY.txt); 1 not root, or the bundle could not be written; 2 argument error.
set -uo pipefail

AUDIO=1
for a in "$@"; do
    case "$a" in
        --no-audio) AUDIO=0 ;;
        -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d'; exit 0 ;;
        *) echo "deck-check: unknown argument: $a (try --help)" >&2; exit 2 ;;
    esac
done
if [[ "${ORIONX_DECK_CHECK_ALLOW_NONROOT:-0}" != 1 && "$(id -u)" -ne 0 ]]; then
    echo "deck-check: run it with sudo (journals, AppArmor and apt logs are root-only)" >&2
    exit 1
fi

OPERATOR="${SUDO_USER:-orionx-operator}"
OP_UID="$(id -u "$OPERATOR" 2>/dev/null || echo 1000)"
OP_HOME="$(getent passwd "$OPERATOR" 2>/dev/null | cut -d: -f6)"; OP_HOME="${OP_HOME:-/home/$OPERATOR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_PARENT="${ORIONX_DECK_CHECK_OUT:-$OP_HOME}"
OUT="$OUT_PARENT/orionx-deck-check-$STAMP"
OPT="${ORIONX_DECK_CHECK_OPT:-/opt/orionx}"
PROBES="${ORIONX_DECK_CHECK_PROBES:-/usr/lib/orionx}"
mkdir -p "$OUT" || { echo "deck-check: cannot create $OUT" >&2; exit 1; }
SUMMARY="$OUT/SUMMARY.txt"
: > "$SUMMARY"

# step <id> <seconds> <command...>: run one bounded step, keep its output,
# record rc and duration. One failing or hanging step never stops the rest.
step() {
    local id="$1" limit="$2"; shift 2
    local start rc line
    start=$(date +%s)
    { echo "\$ $*"; echo; timeout "$limit" "$@"; } > "$OUT/$id.txt" 2>&1
    rc=$?
    [[ $rc -eq 124 ]] && echo "(timed out after ${limit}s)" >> "$OUT/$id.txt"
    line="$(printf '%-24s rc=%-3s %ss' "$id" "$rc" "$(( $(date +%s) - start ))")"
    echo "$line" >> "$SUMMARY"
    echo "[deck-check] $line"
}
# A command prefix (not a function: `timeout` can only run programs) that
# runs in the operator's session, for audio and user state.
AS_OP=(sudo -u "$OPERATOR" env XDG_RUNTIME_DIR="/run/user/$OP_UID"
       DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$OP_UID/bus" HOME="$OP_HOME")

echo "[deck-check] writing to $OUT"

# --- identity -------------------------------------------------------------
step identity 20 sh -c 'cat /etc/os-release; echo; cat /etc/orionx-release 2>/dev/null; uname -a; echo; cat /proc/cmdline; echo; systemd-detect-virt || true; grep -m1 "model name" /proc/cpuinfo; nproc; free -m; lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS'

# --- boot and session (#40, #78) ------------------------------------------
step boot-time 30 sh -c 'systemd-analyze time; echo; systemd-analyze blame --no-pager | head -25; echo; systemd-analyze critical-chain --no-pager graphical.target'
step boot-integrity-hash 15 systemctl show -p ExecMainStartTimestampMonotonic,ExecMainExitTimestampMonotonic,Result nebula-integrity-check.service
step probe-runtime-verify 120 env ORIONX_PROBE_SESSION_WAIT=10 bash "$PROBES/runtime-verify.sh"
step probe-perf-measure 120 env ORIONX_PROBE_SESSION_WAIT=10 ORIONX_PROBE_SETTLE=0 bash "$PROBES/perf-measure.sh"
step failed-units 15 systemctl --failed --no-pager

# --- Nebula on Ollama 0.40 (#163) -----------------------------------------
step nebula-version 15 sh -c '/usr/local/bin/ollama --version 2>&1; systemctl show -p ActiveState,SubState,MainPID,MemoryCurrent nebula-runtime.service; cat /run/orionx/nebula-integrity.status 2>/dev/null'
step nebula-chat 600 python3 - <<'PY'
import json, time, urllib.request
def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("http://127.0.0.1:11434" + path, data, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=580))
print("tags:", [m["name"] for m in call("/api/tags")["models"]])
t = time.time()
r = call("/api/chat", {"model": "qwen2.5:3b-instruct-q4_K_M", "stream": False,
                       "messages": [{"role": "user", "content": "Reply with the single word OK."}]})
print("reply:", repr(r["message"]["content"][:60]), "done:", r["done"])
print("total_duration_s: %.1f  load_duration_s: %.1f  wall_s: %.1f" % (r.get("total_duration", 0) / 1e9, r.get("load_duration", 0) / 1e9, time.time() - t))
PY
step nebula-memory 15 sh -c 'ps -o pid,rss,vsz,args -C ollama,llama-server; grep -E "MemTotal|MemAvailable|SwapTotal|SwapFree" /proc/meminfo'
# shellcheck disable=SC2016  # the $(...) belongs to the sh -c script
step apparmor-denials 20 sh -c 'journalctl -k -b --no-pager | grep -E "apparmor=\"DENIED\"" | tail -60; echo "denials this boot: $(journalctl -k -b --no-pager | grep -c "apparmor=\"DENIED\"")"'
step nebula-journal 15 journalctl -b -u nebula-runtime.service -u nebula-integrity-check.service --no-pager -n 80

# --- narration (#96) --------------------------------------------------------
if [[ $AUDIO -eq 1 ]]; then
    echo "[deck-check] the narration test plays audio three times now"
    for i in 1 2 3; do step "speech-test-$i" 180 "${AS_OP[@]}" orionx-rain --speech-test --all-engines; done
fi
step speech-status 30 "${AS_OP[@]}" orionx-rain --speech-status

# --- Cockpit sources (#197-#202), bus evidence (#189), healing (#95) --------
step optional-status 60 orionx-optional status
step heal-status 30 orionx-heal status
step heal-autonomy 15 orionx-heal autonomy
step postured-status 15 sh -c 'cat /run/orionx/posture-status.json 2>/dev/null || ls -la /run/orionx/'
step bus-tail 15 sh -c 'tail -n 40 /var/log/orionx/events.jsonl 2>/dev/null || journalctl -b -t orionx-event-broker --no-pager -n 40'

# --- Suricata memory, logquery, network (#188) -----------------------------
step suricata 20 sh -c 'systemctl show -p ActiveState,MemoryCurrent,MemoryPeak,MemoryMax suricata.service; grep -E "signatures processed|rules successfully loaded" /var/log/suricata/suricata.log 2>/dev/null | tail -3'
step logquery-summary 120 orionx-logquery -v --report summary
step logquery-scans 120 orionx-logquery --report scans
step logquery-ids 120 orionx-logquery --report ids
step network 20 sh -c 'ip -brief addr; ip route; ip neigh show | head -40; nmcli -t device status 2>/dev/null'

# --- apt (#121) -------------------------------------------------------------
step apt-evidence 180 env ORIONX_APT_EVIDENCE_DIR="$OUT" bash "$OPT/optional/apt-evidence.sh"

cat > "$OUT/CHECK-BY-EYE.txt" <<'EOF'
Things this script cannot see. Note what you find next to each and add the
file to the tarball, or write it on the issue.

[ ] Desktop: no password box after 10 minutes idle (#76/#78).
[ ] Cockpit Tools tab: tools grouped (network, malware, comms, deck); each
    shows installed/active/health; install and uninstall work from the tab and
    ask for your password once per few minutes (#197-#199).
[ ] Cockpit header: the deck verdict (NOMINAL/BUSY/WATCH/...) changes while an
    optional install runs, and the TASKS strip shows it (#202).
[ ] LIVE: memory/disk/battery marks; a resource crossing flashes (#202).
[ ] Settings drawer: the engine group matches `orionx-heal autonomy` after a
    reboot (#95, #201).
[ ] Workbench: optional tools show state; "Manage in Cockpit" opens the tab (#200).
[ ] DEFENSIVE ACTIONS pane reads well at the deck's resolution (#126).
[ ] Network panel / Workbench "This network": host count, local/internet split,
    vendors (#93). Gateway probes against the home router (#94).
[ ] From another host: `nmap <deck>`; then the scanner appears in the Cockpit
    and the Attack Map, and in logquery-scans (re-run this script) (#127/#128).
[ ] Narration: spoken alerts arrive in time, not dropped (#96).
EOF

# Ownership: the bundle belongs to the operator who will attach it.
TARBALL="$OUT_PARENT/orionx-deck-check-$STAMP.tar.gz"
# The apt-evidence tarball was written inside $OUT, so it travels along.
if tar -czf "$TARBALL" -C "$OUT_PARENT" "orionx-deck-check-$STAMP"; then
    chown -R "$OPERATOR": "$OUT" "$TARBALL" 2>/dev/null || true
    echo
    echo "[deck-check] steps:"; sed 's/^/  /' "$SUMMARY"
    echo "[deck-check] by eye: $OUT/CHECK-BY-EYE.txt"
    echo "$TARBALL"
    exit 0
fi
echo "deck-check: could not write $TARBALL" >&2
exit 1
