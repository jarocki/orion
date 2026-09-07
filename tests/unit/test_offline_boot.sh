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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
