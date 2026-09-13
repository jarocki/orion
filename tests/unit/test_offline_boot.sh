#!/usr/bin/env bash
# shellcheck shell=bash
#
# W11-14f offline-boot invariants (DEC-PHASE11-024): the ISO MUST boot fully
# with NO network connection. Nothing auto-started at boot may pull
# network-online.target (blocks boot) or fail-loop waiting on a network/mesh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"
UNITDIR="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd"
BEACON="$REPO_ROOT/scripts/mesh/mesh-discover.sh"
PASS=0; FAIL=0
pass(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  FAIL: $1${2:+ — $2}"; }

echo "=== W11-14f: offline-boot invariants ==="

autostart="$(sed -n '/AUTOSTART_UNITS=(/,/^)/p' "$HOOK")"
for u in matrix-synapse-orionx.service orionx-mesh-beacon.service; do
    if printf '%s' "$autostart" | grep -qE "\"$u\""; then
        fail "$u NOT auto-enabled at boot (network-dependent → opt-in/timer only)" "found in AUTOSTART_UNITS"
    else
        pass "$u not in AUTOSTART_UNITS"
    fi
done

# No orionx unit may carry an ACTIVE network-online dependency.
bad="$(grep -lE "^[[:space:]]*(After|Wants|Requires)=.*network-online" "$UNITDIR"/*.service 2>/dev/null || true)"
if [[ -n "$bad" ]]; then
    fail "no unit pulls network-online.target" "offenders: $(echo "$bad" | xargs -n1 basename | tr '\n' ' ')"
else
    pass "no orionx unit has an active network-online dependency"
fi

# Mesh beacon must skip (not fail) when the node is not joined.
if grep -q "skipping beacon" "$BEACON" && ! grep -A2 "no VPN IP" "$BEACON" | grep -q "return 1"; then
    pass "mesh beacon skips cleanly when not joined (no fail-loop)"
else
    fail "mesh beacon skips cleanly when not joined" "not-joined guard still returns non-zero"
fi

# Timer-fired mesh units gate on the interface so offline firings are no-ops.
for u in orionx-mesh-beacon orionx-mesh-health; do
    if grep -q "ConditionPathExists=/sys/class/net/wg0" "$UNITDIR/$u.service"; then
        pass "$u gated on wg0 interface (offline firing = clean skip)"
    else
        fail "$u gated on wg0 interface" "missing ConditionPathExists=/sys/class/net/wg0"
    fi
done

# Plymouth is RE-ENABLED (DEC-PHASE11-044) with anti-hang guards. The old 21-min
# hang was plymouth-quit-wait blocking boot forever with no timeout; the guard is
# a TimeoutStartSec cap drop-in. Assert the units are UNMASKED (not masked) and
# that the cap is shipped, so the splash paints AND cannot hang boot.
if grep -q 'systemctl unmask "$punit"' "$HOOK" && ! grep -q 'systemctl mask "$punit"' "$HOOK"; then
    pass "plymouth boot units unmasked in 0615 hook (splash re-enabled, DEC-PHASE11-044)"
else
    fail "plymouth boot units unmasked in 0615 hook" "0615 still masks plymouth — splash will not paint"
fi
PQW_CAP="$REPO_ROOT/iso/config/includes.chroot/etc/systemd/system/plymouth-quit-wait.service.d/10-orionx-timeout.conf"
if [ -f "$PQW_CAP" ] && grep -qE "^TimeoutStartSec=[0-9]+" "$PQW_CAP"; then
    pass "plymouth-quit-wait TimeoutStartSec cap present (cannot hang boot, DEC-PHASE11-044)"
else
    fail "plymouth-quit-wait TimeoutStartSec cap present" "missing $PQW_CAP — quit-wait could hang boot forever"
fi
# Check the actual --bootappend-live line (not comments that mention the flag).
BOOTAPPEND_LINE=$(grep -- '--bootappend-live' "$REPO_ROOT/iso/auto/config")
if printf '%s' "$BOOTAPPEND_LINE" | grep -q "plymouth.enable=0"; then
    fail "plymouth.enable=0 removed from --bootappend-live" "still present — splash disabled"
else
    pass "plymouth.enable=0 removed from --bootappend-live (DEC-PHASE11-044)"
fi
if printf '%s' "$BOOTAPPEND_LINE" | grep -q "splash"; then
    pass "splash present in --bootappend-live (Plymouth paints, DEC-PHASE11-044)"
else
    fail "splash present in --bootappend-live" "splash missing — Plymouth will not paint"
fi

# W11-14j: tmpfiles must not chown /var/log/orionx to a group that does not exist
# at early boot (systemd-tmpfiles runs before live-config creates orionx-operator),
# or the dir is never created and nebula-integrity-check dies 209/STDOUT.
if grep -qE "^d /var/log/orionx .* orionx-operator " "$REPO_ROOT/iso/config/includes.chroot/usr/lib/tmpfiles.d/orionx.conf"; then
    fail "tmpfiles /var/log/orionx uses only early-boot users (root)" "references orionx-operator group — absent when tmpfiles runs"
else
    pass "tmpfiles /var/log/orionx uses only early-boot users (root)"
fi
# W11-14j: nebula-runtime must set HOME (ollama needs it) and not use Type=notify
NR="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd/nebula-runtime.service"
if grep -q "^Environment=HOME=" "$NR" && ! grep -q "^Type=notify" "$NR"; then
    pass "nebula-runtime sets HOME and is not Type=notify (ollama serves)"
else
    fail "nebula-runtime sets HOME and is not Type=notify" "ollama exits on undefined \$HOME / notify timeout"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
