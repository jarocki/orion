#!/usr/bin/env bash
# shellcheck shell=bash
#
# orionx-diag's clamav gate (W11-7, DEC-PHASE11-009) against the v3.2.0
# optional-tools manager: ClamAV added by `orionx-optional install clamav`
# (which leaves /var/lib/orionx/optional/clamav.json) passes; ClamAV with no
# such record (shipped in the image, or installed another way) still fails.
# Runs the real script with a stubbed dpkg; reads its --json output.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIAG="$ROOT/scripts/orionx-diag"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        ${2:-}"; FAIL=$((FAIL+1)); }

T="$ROOT/tmp/test-diag-clamav.$$"
mkdir -p "$T/bin" "$T/records"
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

# dpkg -l <pkg>: clamav is installed when $T/clamav-installed exists.
cat > "$T/bin/dpkg" <<STUB
#!/bin/bash
[[ "\$1" == -l && "\$2" == clamav && -f "$T/clamav-installed" ]] && { echo "ii  clamav  1.4.6  amd64  anti-virus utility"; exit 0; }
exit 1
STUB
chmod +x "$T/bin/dpkg"

clamav_check() {  # -> "status|name|detail" of the clamav assertion
    PATH="$T/bin:$PATH" ORIONX_OPTIONAL_RECORD_DIR="$T/records" bash "$DIAG" --json --category packages 2>/dev/null |
        python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = [a for c in d.get("categories", {}).values() for a in c.get("assertions", [])]
for r in rows:
    if "clamav" in r.get("name", ""):
        print("%s|%s|%s" % (r.get("status"), r.get("name"), r.get("detail", "")))
'
}

echo "[orionx-diag: clamav gate]"
rm -f "$T/clamav-installed" "$T/records/clamav.json"
OUT="$(clamav_check)"
[[ "$OUT" == PASS\|clamav\ ABSENT* ]] && pass "clamav absent: PASS" || fail "clamav absent" "$OUT"

touch "$T/clamav-installed"
OUT="$(clamav_check)"
[[ "$OUT" == FAIL\|* ]] && pass "clamav present with no orionx-optional record: FAIL (base-image regression)" || fail "no record must fail" "$OUT"
[[ "$OUT" == *"sudo orionx-optional install clamav"* && "$OUT" != *install-clamav.sh* ]] \
    && pass "... and the remedy names orionx-optional, not the old script" || fail "remedy text" "$OUT"

echo '{"id": "clamav"}' > "$T/records/clamav.json"
OUT="$(clamav_check)"
[[ "$OUT" == PASS\|*"installed by orionx-optional"* ]] && pass "clamav installed by orionx-optional (record present): PASS" || fail "record must pass" "$OUT"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
