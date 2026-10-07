#!/usr/bin/env bash
# shellcheck shell=bash
#
# Matrix Synapse: ONE unit authority (DEC-PHASE12-102)
#
# The package's matrix-synapse.service is the only Synapse unit. Orion-X
# hardens it with a drop-in and ships no unit and no AppArmor profile of its
# own. Every consumer that names the unit (setup-matrix.sh, runtime-verify,
# the Cockpit) must name the same one.
#
# Usage: bash tests/unit/test_matrix_systemd.sh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; return 0; }

INC="$PROJECT_ROOT/iso/config/includes.chroot"
DROPIN="$INC/etc/systemd/system/matrix-synapse.service.d/orionx.conf"
HOOK="$PROJECT_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"

echo "=== Single Synapse unit authority ==="

if [[ -e "$INC/usr/share/orionx/systemd/matrix-synapse-orionx.service" ]]; then
    fail "no Orion-X Synapse unit is shipped (it was never installed; system P1-2)"
else
    pass "no Orion-X Synapse unit is shipped"
fi

# Every live (non-comment) reference in shipped code/config names the package
# unit. scripts/control_center is A1-owned and switched to matrix-synapse.service
# on A1's branch; it is excluded here only until that merge (ledger-B1 handoff:
# drop the --exclude-dir after merging A1).
STALE="$(grep -rn --exclude-dir=control_center 'matrix-synapse-orionx' "$PROJECT_ROOT/scripts" "$INC" "$PROJECT_ROOT/iso/config/hooks" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [[ -z "$STALE" ]]; then
    pass "nothing shipped names matrix-synapse-orionx.service"
else
    fail "nothing shipped names matrix-synapse-orionx.service" "$STALE"
fi

for f in "$PROJECT_ROOT/scripts/setup-matrix.sh" "$INC/usr/lib/orionx/runtime-verify.sh"; do
    if grep -q 'matrix-synapse\.service' "$f"; then
        pass "$(basename "$f") names matrix-synapse.service"
    else
        fail "$(basename "$f") names matrix-synapse.service"
    fi
done

if grep -q 'matrix-synapse' "$HOOK"; then
    fail "0615 does not install or enable any Synapse unit (the package owns it)"
else
    pass "0615 does not install or enable any Synapse unit"
fi

echo "=== Drop-in ==="
if [[ -f "$DROPIN" ]]; then pass "drop-in exists"; else fail "drop-in exists" "$DROPIN"; fi
for d in 'NoNewPrivileges=yes' 'ProtectSystem=strict' 'ProtectHome=yes' 'PrivateTmp=yes' 'CapabilityBoundingSet=$' \
         'ReadWritePaths=.*/var/lib/matrix-synapse' 'ReadWritePaths=.*/etc/matrix-synapse' '@decision DEC-PHASE12-102'; do
    if grep -qE "^$d|^# *$d|$d" "$DROPIN" 2>/dev/null && grep -E "$d" "$DROPIN" >/dev/null; then
        pass "drop-in has $d"
    else
        fail "drop-in has $d"
    fi
done
# The package ExecStart already uses the venv python; overriding it would be a
# second authority for the command line.
if grep -qE '^ExecStart' "$DROPIN"; then
    fail "drop-in does not override ExecStart/ExecStartPre"
else
    pass "drop-in does not override ExecStart/ExecStartPre"
fi

echo "=== AppArmor ==="
if [[ -e "$INC/etc/apparmor.d/usr.bin.synapse" ]]; then
    fail "no dead Synapse AppArmor profile (venv python resolves to /usr/bin/python3.13; system P2-6)"
else
    pass "no dead Synapse AppArmor profile"
fi
if grep -rqE '^profile [^ ]+ /usr/bin/python3' "$INC/etc/apparmor.d" 2>/dev/null; then
    fail "no profile attaches to the shared system python"
else
    pass "no profile attaches to the shared system python"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    out="$(systemd-analyze verify "$DROPIN" 2>&1 || true)"
    if grep -qi 'unknown key\|invalid' <<< "$out"; then fail "systemd-analyze: drop-in keys valid" "$out"; else pass "systemd-analyze: drop-in keys valid"; fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
