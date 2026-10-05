#!/usr/bin/env bash
# Key material in scripts/mesh/mesh-lib.sh must be CREATED 0600, not created
# 0644 and chmod'ed a moment later. wg(8) itself warned "writing to world
# accessible file" on the reference deck (2026-10-05) because the redirect
# opened the file with the default umask before the chmod ran.
set -euo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/mesh/mesh-lib.sh"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
for gen in genkey genpsk; do
    if grep -qE "\(umask 077; wg $gen > " "$LIB"; then
        pass "wg $gen writes its file under umask 077 (born 0600)"
    else
        fail "wg $gen writes its file under umask 077" "redirect without umask — the file exists world-readable until the chmod"
    fi
done
if [[ "$(grep -cE 'chmod 0600 "\$MESH_(PRIVATE_KEY|PSK_FILE)"' "$LIB")" -ge 2 ]]; then
    pass "chmod 0600 retained as belt-and-braces"
else
    fail "chmod 0600 retained" "the explicit chmod lines are gone"
fi
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
