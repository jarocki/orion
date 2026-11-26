#!/usr/bin/env bash
# shellcheck shell=bash
#
# #40 / #78 (DEC-PHASE13-067): what the in-guest CI probes report, and how
# the host-side tests judge it. Runs the real probes with stubbed system
# commands, and the real host tests against a fake QEMU harness that "boots"
# a fixture serial log (lines end in \r\n, as the tty writes them).
#
# Not covered here: a real boot. The probes' delivery and timing were
# measured on the v3.1.6 ISO (excerpt on #40);
# the QEMU job on the PR is the end-to-end proof.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/iso/config/includes.chroot/usr/lib/orionx"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        ${2:-}"; FAIL=$((FAIL+1)); }
has() { grep -qF -- "$2" <<<"$1"; }
check() { if has "$2" "$3"; then pass "$1"; else fail "$1" "no '$3' in: $(tr '\n' '|' <<<"$2")"; fi; }

T="$ROOT/tmp/test-probe-behaviour.$$"
mkdir -p "$T"
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Stubs: each reads its answers from files under $S, so a case is a few touches.
# ---------------------------------------------------------------------------
S="$T/state"; B="$T/bin"
mkdir -p "$B"
cat > "$B/systemctl" <<'EOF'
#!/bin/bash
# is-active / is-enabled <unit>; show -p ActiveEnterTimestampMonotonic --value <unit>; cat <unit>
case "$1" in
    is-active|is-enabled) f="$S/$1.$2" ;;
    show) f="$S/mono.${*: -1}" ;;
    *) exit 1 ;;
esac
[[ -f "$f" ]] && cat "$f" && exit 0
exit 3
EOF
cat > "$B/pgrep" <<'EOF'
#!/bin/bash
# pgrep -u <user> -x xfce4-session | pgrep -x <name>
if [[ "$1" == "-u" ]]; then [[ -f "$S/session.$2" ]]; exit; fi
[[ -f "$S/running.$2" ]]
EOF
cat > "$B/dpkg-query" <<'EOF'
#!/bin/bash
pkg="${*: -1}"; [[ -f "$S/installed.$pkg" ]] && printf 'install ok installed'
exit 0
EOF
printf '#!/bin/bash\ncat "$S/virt" 2>/dev/null || echo none\n' > "$B/systemd-detect-virt"
printf '#!/bin/bash\necho 1000\n' > "$B/id"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$B/timeout"          # the guest has coreutils timeout
printf '#!/bin/bash\necho "3: wg0: <POINTOPOINT,NOARP,UP> mtu 1420 state UNKNOWN"\n' > "$B/ip"
chmod +x "$B"/*

reset_state() {
    rm -rf "$S"; mkdir -p "$S" "$T/net"
    rm -f "$T/net/wg0"
    printf 'ollama (enforce)\nnebula-mcp (enforce)\nwireguard (enforce)\ntshark (enforce)\n' > "$T/aa"
    echo "BOOT_IMAGE=/live/vmlinuz boot=live live-config.username=orionx-operator" > "$T/cmdline"
    # A healthy stock deck: mesh not joined, desktop up, no locker.
    echo inactive > "$S/is-active.orionx-mesh-beacon.service"
    echo enabled > "$S/is-enabled.orionx-mesh-discover.timer"
    echo active > "$S/is-active.graphical.target"
    touch "$S/session.orionx-operator"
}

verify() {
    S="$S" PATH="$B:$PATH" ORIONX_PROBE_LIB="$LIB/probe-lib.sh" ORIONX_AA_KERNEL_PROFILES="$T/aa" \
        ORIONX_PROBE_SYSFS_NET="$T/net" ORIONX_PROBE_CMDLINE="$T/cmdline" \
        ORIONX_PROBE_SESSION_WAIT=1 ORIONX_PROBE_POLL=0.2 bash "$LIB/runtime-verify.sh" 2>&1
}

echo "[runtime-verify.sh]"
reset_state; OUT="$(verify)"
check "stock deck, no wg0: mesh_iface_up passes (opt-in)" "$OUT" "mesh_iface_up=PASS (no wg0: mesh not joined, opt-in)"
check "stock deck: a beacon skipped by its condition passes" "$OUT" "mesh_beacon_active=PASS (inactive)"
check "graphical.target active passes" "$OUT" "graphical_target=PASS (active)"
check "the autologin desktop is found" "$OUT" "desktop_session=PASS (xfce4-session running for orionx-operator)"
check "no screen locker passes" "$OUT" "no_screen_locker=PASS"
check "the sentinel block is framed" "$OUT" "ORIONX_VERIFY_BEGIN"
check "the sentinel block ends with a verdict" "$OUT" "ORIONX_VERIFY_END: overall="

reset_state; echo failed > "$S/is-active.orionx-mesh-beacon.service"; OUT="$(verify)"
check "no wg0 but a FAILED beacon still fails" "$OUT" "mesh_beacon_active=FAIL (failed)"

reset_state; touch "$T/net/wg0"; OUT="$(verify)"
check "joined (wg0): the link state is read" "$OUT" "mesh_iface_up=PASS"
check "joined (wg0): an inactive beacon fails" "$OUT" "mesh_beacon_active=FAIL (inactive)"

# #78 definition of done, at unit level: an image with light-locker back fails.
reset_state; touch "$S/installed.light-locker"; OUT="$(verify)"
check "light-locker installed fails the gate" "$OUT" "no_screen_locker=FAIL (found: light-locker(installed))"
check "... and the overall verdict" "$OUT" "ORIONX_VERIFY_END: overall=FAIL"
reset_state; touch "$S/running.xscreensaver"; OUT="$(verify)"
check "a running xscreensaver fails" "$OUT" "no_screen_locker=FAIL (found: xscreensaver(running))"

reset_state; rm -f "$S/session.orionx-operator"; echo inactive > "$S/is-active.graphical.target"; OUT="$(verify)"
check "no desktop by the deadline fails, saying how long it waited" "$OUT" "desktop_session=FAIL (no xfce4-session for orionx-operator after 1s)"
check "graphical.target not reached fails" "$OUT" "graphical_target=FAIL (inactive)"

reset_state; echo "boot=live live-config.username=alice quiet" > "$T/cmdline"; OUT="$(verify)"
check "the session is looked for under live-config.username" "$OUT" "desktop_session=FAIL (no xfce4-session for alice"
touch "$S/session.alice"; OUT="$(verify)"
check "... and found there" "$OUT" "desktop_session=PASS (xfce4-session running for alice)"

echo "[perf-measure.sh]"
perf() {
    S="$S" PATH="$B:$PATH" ORIONX_PROBE_LIB="$LIB/probe-lib.sh" ORIONX_PROBE_CMDLINE="$T/cmdline" \
        ORIONX_PROBE_MEMINFO="$T/meminfo" ORIONX_PROBE_SESSION_WAIT=1 ORIONX_PROBE_POLL=0.2 \
        ORIONX_PROBE_SETTLE=0 bash "$LIB/perf-measure.sh" 2>&1
}
reset_state; echo qemu > "$S/virt"
echo 319201873 > "$S/mono.multi-user.target"; echo 296931446 > "$S/mono.user@1000.service"
printf 'MemTotal:        4002436 kB\nMemFree:  100 kB\nMemAvailable:    3287720 kB\n' > "$T/meminfo"
OUT="$(perf)"
check "reports the virtualisation" "$OUT" "ORIONX_PERF: virt=qemu"
check "reports when multi-user.target was reached" "$OUT" "ORIONX_PERF: multi_user_seconds=319"
check "boot time is the desktop session's start" "$OUT" "ORIONX_PERF: boot_time_seconds=296"
check "idle RAM is MemTotal - MemAvailable" "$OUT" "ORIONX_PERF: idle_ram_bytes=$(( (4002436 - 3287720) * 1024 ))"
check "where the RAM went is reported with it (meminfo breakdown)" "$OUT" "ORIONX_PERF: mem_detail_kb=MemTotal=4002436 MemFree=100 MemAvailable=3287720"
check "the guest reports and does not judge" "$OUT" "ORIONX_PERF_END: overall=REPORTED"
if grep -qE 'THRESHOLD|-lt [0-9]{2}' "$LIB/perf-measure.sh"; then fail "perf-measure.sh holds no thresholds" "found one"; else pass "perf-measure.sh holds no thresholds (the host test is the authority)"; fi
rm -f "$S/session.orionx-operator"; OUT="$(perf)"
check "no desktop: boot time says why it is missing" "$OUT" "boot_time_seconds=none (no desktop session for orionx-operator after 1s)"

# ---------------------------------------------------------------------------
# Host-side tests against a fake harness. The fake "boots" $FIXTURE: it writes
# the serial log the real harness would, then runs the post-boot helper.
# ---------------------------------------------------------------------------
H="$T/repo"
mkdir -p "$H/tests/integration" "$H/scripts" "$H/iso" "$H/output"
cp "$ROOT/tests/integration/test-w7-5-performance.sh" "$ROOT/tests/integration/test-w7-4-b-runtime-verify.sh" "$H/tests/integration/"
cat > "$H/scripts/qemu-boot-test.sh" <<'EOF'
#!/bin/bash
root="$(cd "$(dirname "$0")/.." && pwd)"
while [[ $# -gt 0 ]]; do [[ "$1" == --post-boot-script ]] && helper="$2"; shift; done
sleep 1                                     # the log must be newer than the helper
d="$root/tmp/qemu-artifacts/fake"; mkdir -p "$d"; cp "$FIXTURE" "$d/serial-bios.log"
bash "$helper" fake "$d/serial-bios.log"
EOF
head -c 1024 /dev/zero > "$H/output/fake.iso"
crlf() { printf '%s\r\n' "$@"; }
host() {  # <test file> <fixture> -> output; exit code in $RC
    OUT="$(FIXTURE="$2" ISO="$H/output/fake.iso" PERF_WAIT=5 VERIFY_WAIT=5 bash "$H/tests/integration/$1" 2>&1)"; RC=$?
    rm -rf "$H/tmp/qemu-artifacts"
}

echo "[test-w7-5-performance.sh, fake harness]"
crlf "[  319.9] noise" ORIONX_PERF_BEGIN "ORIONX_PERF: virt=qemu" "ORIONX_PERF: multi_user_seconds=319" \
     "ORIONX_PERF: boot_time_seconds=296" "ORIONX_PERF: idle_ram_bytes=731873280" "ORIONX_PERF_END: overall=REPORTED" > "$T/tcg.log"
host test-w7-5-performance.sh "$T/tcg.log"
check "TCG: boot time recorded, not judged" "$OUT" "boot_time_seconds=296 recorded (TCG emulation: not judged against 90s)"
check "values are read through the tty's \\r" "$OUT" "idle_ram_bytes=731873280 < 1073741824 (1 GiB) [PASS]"
if grep -q '^\[FAIL\]' <<<"$OUT"; then fail "TCG fixture: no failures" "$(grep '^\[FAIL\]' <<<"$OUT")"; else pass "TCG fixture: no failures"; fi
check "the ISO is measured (1024-byte fixture)" "$OUT" "iso_size_bytes=1024 < 4294967296 (4 GiB) [PASS]"
crlf ORIONX_PERF_BEGIN "ORIONX_PERF: virt=kvm" "ORIONX_PERF: boot_time_seconds=120" \
     "ORIONX_PERF: idle_ram_bytes=1200000000" "ORIONX_PERF_END: overall=REPORTED" > "$T/kvm.log"
host test-w7-5-performance.sh "$T/kvm.log"
check "KVM: a slow boot is judged and fails" "$OUT" "boot_time_seconds=120 >= 90s threshold"
check "RAM over 1 GiB fails" "$OUT" "idle_ram_bytes=1200000000 >= 1073741824 (1 GiB) threshold"
if [[ $RC -ne 0 ]]; then pass "... and the test exits non-zero ($RC)"; else fail "KVM fixture exits non-zero" "rc=$RC"; fi
crlf ORIONX_PERF_BEGIN "ORIONX_PERF: virt=qemu" "ORIONX_PERF: boot_time_seconds=none (no desktop session for orionx-operator after 300s)" \
     "ORIONX_PERF: idle_ram_bytes=700000000" "ORIONX_PERF_END: overall=REPORTED" > "$T/nodesk.log"
host test-w7-5-performance.sh "$T/nodesk.log"
check "no desktop: boot time fails as not measured" "$OUT" "boot_time_seconds not measured"

echo "[test-w7-4-b-runtime-verify.sh, fake harness]"
names="mesh_iface_up mesh_beacon_active mesh_discover_enabled matrix_synapse_state apparmor_enforcing zeek_unit_staged graphical_target desktop_session no_screen_locker"
{ crlf ORIONX_VERIFY_BEGIN; for n in $names; do crlf "ORIONX_VERIFY: $n=PASS"; done; crlf "ORIONX_VERIFY_END: overall=PASS"; } > "$T/v-ok.log"
host test-w7-4-b-runtime-verify.sh "$T/v-ok.log"
check "every assertion PASS: the gate passes" "$OUT" "All serial logs show ORIONX_VERIFY_END: overall=PASS"
if [[ $RC -eq 0 ]]; then pass "... exit 0"; else fail "all-PASS fixture exits 0" "rc=$RC $(grep FAIL <<<"$OUT")"; fi
{ crlf ORIONX_VERIFY_BEGIN; for n in $names; do [[ $n == desktop_session ]] || crlf "ORIONX_VERIFY: $n=PASS"; done; crlf "ORIONX_VERIFY_END: overall=PASS"; } > "$T/v-miss.log"
host test-w7-4-b-runtime-verify.sh "$T/v-miss.log"
check "a probe without the session check fails the gate" "$OUT" "assertion sentinel missing: desktop_session"
{ crlf ORIONX_VERIFY_BEGIN; for n in $names; do [[ $n == no_screen_locker ]] && crlf "ORIONX_VERIFY: $n=FAIL (found: light-locker(installed))" || crlf "ORIONX_VERIFY: $n=PASS"; done; crlf "ORIONX_VERIFY_END: overall=FAIL"; } > "$T/v-lock.log"
host test-w7-4-b-runtime-verify.sh "$T/v-lock.log"
check "a screen locker fails the gate" "$OUT" "assertion FAIL: no_screen_locker"
if [[ $RC -ne 0 ]]; then pass "... and the test exits non-zero"; else fail "locker fixture exits non-zero" "rc=$RC"; fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
