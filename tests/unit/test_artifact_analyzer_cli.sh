#!/usr/bin/env bash
# artifact-analyzer.py output location (QA round 2, L-03): it used to write
# ./analysis_results relative to wherever the terminal was, and died with a
# raw PermissionError traceback when that was unwritable (e.g. `/`).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
T="$(mktemp -d "${ROOT}/tmp/aa-test.XXXXXX" 2>/dev/null || mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/ro"; printf 'MZ\x90\x00synthetic\n' > "$T/sample.bin"; chmod 0555 "$T/ro"
export PYTHONDONTWRITEBYTECODE=1

out="$(cd "$T/ro" && HOME="$T/home" python3 "$ROOT/scripts/artifact-analyzer.py" "$T/sample.bin" -t log 2>&1)"; rc=$?
if ls -d "$T"/home/Analysis/results/sample.bin-* >/dev/null 2>&1; then
    pass "default output goes to ~/Analysis/results/<artifact>-<UTC stamp>, not the CWD"
else
    fail "default output location" "rc=$rc; $(echo "$out" | tail -2)"
fi
echo "$out" | grep -q "Traceback" && fail "no traceback from an unwritable CWD" "$(echo "$out" | grep -m1 Error)" || pass "an unwritable CWD no longer matters (no traceback)"

out="$(HOME="$T/home" python3 "$ROOT/scripts/artifact-analyzer.py" "$T/sample.bin" -o "$T/ro/sub" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -q "Cannot create output directory" && ! echo "$out" | grep -q Traceback; then
    pass "an unwritable -o fails with a sentence and exit 2"
else
    fail "unwritable -o" "rc=$rc; $(echo "$out" | tail -2)"
fi
chmod 0755 "$T/ro"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
