#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit sandboxes match what the confined code does (DEC-PHASE12-107/108)
#
# Static invariants over every shipped unit, plus (when docker is available)
# systemd-analyze verify of every unit and a REAL run of dumpcap under the
# capture@ sandbox with systemd 257 as PID 1. ORIONX_SKIP_DOCKER=1 skips the
# container parts (reported as SKIP, never as PASS).
#
# Usage: bash tests/unit/test_unit_sandbox.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
U="$ROOT/iso/config/includes.chroot/usr/share/orionx/systemd"
TMPF="$ROOT/iso/config/includes.chroot/usr/lib/tmpfiles.d"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; return 0; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $1"; }

echo "=== capture@: dumpcap must be able to drop its own privileges (P1-1) ==="
DENY="$(grep -E '^SystemCallFilter=~' "$U/orionx-capture@.service" || true)"
if [[ -n "$DENY" && "$DENY" != *"@privileged"* ]]; then pass "capture@ does not deny @privileged (capset/setresuid)"; else fail "capture@ deny list" "$DENY"; fi
for g in @clock @raw-io @chown @mount @module; do
    [[ "$DENY" == *"$g"* ]] && pass "capture@ still denies $g" || fail "capture@ still denies $g"
done

echo "=== every non-optional ReadWritePaths entry exists before the namespace (P2-1) ==="
# Provided by packages in the image (not created by Orion-X):
PKG_DIRS=" /var/lib/suricata /etc/wireguard "
TMPDIRS=" $(awk '$1=="d"{print $2}' "$TMPF"/*.conf | tr '\n' ' ') "
BAD=""
for f in "$U"/*.service; do
    own=" "
    while IFS='=' read -r k v; do
        for d in $v; do
            case "$k" in
                StateDirectory) own+="/var/lib/$d "; [[ "$d" == */* ]] && own+="/var/lib/${d%%/*} " ;;  # systemd creates parents too
                RuntimeDirectory) own+="/run/$d " ;;
                LogsDirectory) own+="/var/log/$d " ;;
            esac
        done
    done < <(grep -E '^(StateDirectory|RuntimeDirectory|LogsDirectory)=' "$f")
    for p in $(grep -E '^ReadWritePaths=' "$f" | cut -d= -f2-); do
        [[ "$p" == -* ]] && continue
        [[ "$own$PKG_DIRS$TMPDIRS" == *" $p "* ]] && continue
        BAD+=" $(basename "$f"):$p"
    done
done
if [[ -z "$BAD" ]]; then pass "no unit names a path nothing creates (would be 226/NAMESPACE)"; else fail "ReadWritePaths with no creator" "$BAD"; fi

echo "=== [Unit]-only keys are in [Unit] (P3-2) ==="
MIS=""
for f in "$U"/*.service; do
    awk '/^\[/{s=$0} /^StartLimit(IntervalSec|Burst)=/{ if (s!="[Unit]") print FILENAME": "$0" in "s }' "$f"
done > "${TMPDIR:-/tmp}/b1-sl.$$"
MIS="$(cat "${TMPDIR:-/tmp}/b1-sl.$$")"; rm -f "${TMPDIR:-/tmp}/b1-sl.$$"
if [[ -z "$MIS" ]]; then pass "StartLimit* keys only in [Unit]"; else fail "StartLimit* outside [Unit]" "$MIS"; fi

echo "=== mesh-status can write its log (P3-3); scanwatch holds no capabilities (F19) ==="
grep -q '^LogsDirectory=orionx$' "$U/orionx-mesh-status.service" && pass "orionx-mesh-status has LogsDirectory=orionx" || fail "orionx-mesh-status LogsDirectory"
grep -q '^CapabilityBoundingSet=$' "$U/orionx-scanwatch.service" && pass "orionx-scanwatch runs with an empty capability bounding set" || fail "scanwatch CapabilityBoundingSet="
for u in orionx-postured orionx-heald orionx-scanwatch; do
    for d in ProtectClock=yes ProtectHostname=yes RestrictNamespaces=yes LockPersonality=yes SystemCallArchitectures=native; do
        grep -q "^$d$" "$U/$u.service" || fail "$u has $d"
    done
done
pass "postured/heald/scanwatch carry the F19 kernel-facing hardening set (any miss is listed above)"
grep -q '^Environment=ORIONX_OPERATOR_USER=orionx-operator$' "$U/orionx-postured.service" && pass "postured knows the operator account (A2 handoff)" || fail "postured ORIONX_OPERATOR_USER"

echo "=== container checks (systemd 257, trixie) ==="
if [[ "${ORIONX_SKIP_DOCKER:-0}" == 1 ]] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "docker unavailable: systemd-analyze verify and the dumpcap run were not exercised"
else
    name="orionx-unit-sandbox-$$"
    docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "$U:/units:ro" debian:trixie-slim bash -c \
        'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null && echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections 2>/dev/null; apt-get install -y -qq --no-install-recommends systemd wireshark-common >/dev/null 2>&1; touch /ready; exec /lib/systemd/systemd' >/dev/null
    for _i in $(seq 1 180); do docker exec "$name" test -e /ready 2>/dev/null && break; sleep 1; done
    sleep 3
    VER="$(docker exec "$name" bash -c 'cd /units && for f in *.service *.timer; do systemd-analyze verify --man=no "./$f" 2>&1; done' | grep -E 'Unknown key|Unknown section|Invalid|Failed to parse' || true)"
    if [[ -z "$VER" ]]; then pass "systemd-analyze verify: no unknown keys/sections or parse errors in any unit"; else fail "systemd-analyze verify" "$VER"; fi
    CAP="$(docker exec "$name" bash -c '
        sed -n "/^\[Service\]/,/^\[Install\]/p" /units/orionx-capture@.service | grep -v "^\[Install\]" \
          | sed "s|^ExecStart=.*|ExecStart=/usr/bin/dumpcap -i lo -a duration:2 -w /run/orionx/qa.pcapng|" > /etc/systemd/system/qa-cap.service
        mkdir -p /run/orionx; rm -rf /var/lib/orionx; systemctl daemon-reload; systemctl start qa-cap; sleep 4
        echo "result=$(systemctl show qa-cap -p Result --value) bytes=$(stat -c %s /run/orionx/qa.pcapng 2>/dev/null || echo 0)"' 2>&1)"
    if [[ "$CAP" == *"result=success"* && "$CAP" != *"bytes=0"* ]]; then
        pass "dumpcap writes a pcap under the capture@ sandbox, with /var/lib/orionx absent beforehand"
    else
        fail "dumpcap under capture@ sandbox" "$CAP"
    fi
    docker rm -f "$name" >/dev/null 2>&1
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
