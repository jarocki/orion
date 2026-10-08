#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — the Nebula integrity GATE, not just the hash
#
# tests/unit/test_nebula_integrity.sh already covers manifest parsing and
# hash comparison. This suite covers the thing that actually failed on rc4:
# the gate around the hash — its time bound, what it writes while it is
# still running, what it writes when it is killed, and whether any of that
# ever reaches the operator.
#
# @decision DEC-PHASE12-041
# @title Test the gate's failure modes, not only its happy path
# @status accepted
# @rationale rc4: nebula-runtime.service inactive, `journalctl -u
#   nebula-runtime` empty, because nebula-integrity-check.service was still
#   SHA-256-hashing a 1.93 GB model past systemd's implicit 90s
#   TimeoutStartSec. Every existing test passed, because every existing test
#   verified the hash and nothing verified the gate. RESILIENCE rule 1: if
#   this subsystem were broken at runtime, would any test fail? It was, and
#   none did.
#
# Usage:  bash tests/unit/test_nebula_integrity_gate.sh

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "  PASS: $1"; (( PASS_COUNT++ )) || true; }
fail() { echo "  FAIL: $1"; shift; for l in "$@"; do echo "        $l"; done; (( FAIL_COUNT++ )) || true; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UNIT="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd/nebula-integrity-check.service"
RUNTIME_UNIT="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd/nebula-runtime.service"
INTEGRITY_PY="$REPO_ROOT/scripts/nebula/integrity.py"

echo "=== Nebula integrity GATE (DEC-PHASE12-041) ==="
echo ""

# ---------------------------------------------------------------------------
# T1: the unit's time bound
# ---------------------------------------------------------------------------
echo "--- T1: the gate is explicitly time-bounded ---"

TSS="$(grep -E '^TimeoutStartSec=' "$UNIT" | tail -1 | cut -d= -f2 || true)"
if [[ -z "$TSS" ]]; then
    fail "nebula-integrity-check.service sets TimeoutStartSec" \
         "Unset means systemd's 90s default, which is SHORTER than the" \
         "measured 2min+ hash of the 1.93 GB model. The gate then fails on" \
         "slow storage and nebula-runtime never starts (rc4)."
else
    pass "TimeoutStartSec is set explicitly ($TSS)"
    if [[ "$TSS" =~ ^[0-9]+$ ]] && (( TSS > 180 )); then
        pass "TimeoutStartSec ($TSS s) exceeds the measured worst case (~130 s)"
    else
        fail "TimeoutStartSec ($TSS) must exceed the measured hash time" \
             "SHA-256 over 1.93 GB measured 2min+ under emulation."
    fi
    if [[ "$TSS" == "0" || "$TSS" == "infinity" ]]; then
        fail "TimeoutStartSec must be a BOUND, not infinity" \
             "RESILIENCE rule 4: bound every wait."
    else
        pass "TimeoutStartSec is a real bound, not infinity"
    fi
fi

if grep -qE '^DefaultDependencies=no' "$UNIT"; then
    fail "nebula-integrity-check.service still sets DefaultDependencies=no" \
         "That puts a 2-minute I/O-bound job before basic.target, competing" \
         "with early boot for the same slow disk, and leaves it with no" \
         "shutdown ordering. Nothing needs it that early."
else
    pass "default boot/shutdown ordering restored (no DefaultDependencies=no)"
fi
echo ""

# ---------------------------------------------------------------------------
# T2: the DEC-PHASE10-009 guarantee is untouched
# ---------------------------------------------------------------------------
echo "--- T2: the gate still gates (DEC-PHASE10-009) ---"
for _pat in '^Requires=.*nebula-integrity-check' '^After=.*nebula-integrity-check'; do
    if grep -qE "$_pat" "$RUNTIME_UNIT"; then
        pass "nebula-runtime.service keeps $_pat"
    else
        fail "nebula-runtime.service lost $_pat" \
             "A tampered model could then run. DEC-PHASE10-009."
    fi
done
if grep -qE '^Before=.*nebula-runtime\.service' "$UNIT"; then
    pass "the check is still ordered before the runtime"
else
    fail "the check is no longer ordered before nebula-runtime.service" ""
fi
echo ""
# ---------------------------------------------------------------------------
# T3: a kill mid-hash writes a FAIL status that explains itself
#
# Reproduces the rc4 failure directly: a FIFO as the "model file" makes
# _sha256_file() block in exactly the place a long hash blocks, so the
# SIGTERM lands where systemd's start timeout would land it.
# ---------------------------------------------------------------------------
echo "--- T3: killed mid-hash -> FAIL, with the reason and the remedy ---"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

mkdir -p "$TMPD/models"
mkfifo "$TMPD/models/blob.bin"
printf '%064d  blob.bin\n' 0 > "$TMPD/models/MANIFEST.sha256"
STATUS="$TMPD/nebula-integrity.status"
EVENTS="$TMPD/events.log"
STUB="$TMPD/orionx-event"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${EVENTS_FILE:?}"
STUBEOF
chmod +x "$STUB"

EVENTS_FILE="$EVENTS" NEBULA_EVENT_CLI="$STUB" \
    python3 "$INTEGRITY_PY" --models-dir "$TMPD/models" \
        --manifest "$TMPD/models/MANIFEST.sha256" --status-file "$STATUS" \
        >"$TMPD/out.log" 2>&1 &
PY_PID=$!

# Wait (bounded) for the CHECKING marker, which proves the status file is
# written BEFORE the hash rather than only after it.
SAW_CHECKING=0
for _i in $(seq 1 50); do
    if [[ -f "$STATUS" ]] && grep -q "NEBULA_INTEGRITY=CHECKING" "$STATUS"; then
        SAW_CHECKING=1
        break
    fi
    sleep 0.1
done

if (( SAW_CHECKING )); then
    pass "a CHECKING status is published while the hash is still running"
    echo "        (before this, the Control Center showed 'status file not"
    echo "         found' for the whole two minutes)"
else
    fail "no CHECKING status appeared while the check was running" \
         "$(cat "$STATUS" 2>/dev/null || echo '(no status file at all)')"
fi

kill -TERM "$PY_PID" 2>/dev/null || true
RC=0
wait "$PY_PID" 2>/dev/null || RC=$?

if (( RC != 0 )); then
    pass "an interrupted check exits non-zero (the gate fails CLOSED)"
else
    fail "an interrupted check exited 0" \
         "nebula-runtime would start against an unverified model."
fi

if [[ -f "$STATUS" ]] && grep -q "NEBULA_INTEGRITY=FAIL" "$STATUS"; then
    pass "an interrupted check leaves NEBULA_INTEGRITY=FAIL, not a stale CHECKING"
else
    fail "interrupted check did not leave a FAIL status" \
         "$(cat "$STATUS" 2>/dev/null || echo '(no status file)')"
fi
if grep -qi "interrupted" "$STATUS" 2>/dev/null; then
    pass "the status detail distinguishes a timeout from a hash mismatch"
else
    fail "the status detail does not say it was interrupted" \
         "'FAIL' alone reads as 'your model was tampered with'."
fi

for _needle in "NOT evidence of tampering" "TimeoutStartSec" "journalctl -u nebula-integrity-check" "severity critical" "category service"; do
    if grep -qF -- "$_needle" "$EVENTS" 2>/dev/null; then
        pass "the bus event contains: $_needle"
    else
        fail "the bus event is missing: $_needle" \
             "$(cat "$EVENTS" 2>/dev/null || echo '(nothing published)')"
    fi
done
rm -rf "$TMPD"; trap - EXIT
echo ""

# ---------------------------------------------------------------------------
# T4: a genuine mismatch is announced, and announced as self-status
# ---------------------------------------------------------------------------
echo "--- T4: a hash mismatch reaches the bus ---"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/models"
echo "this is not the model you are looking for" > "$TMPD/models/blob.bin"
printf '%064d  blob.bin\n' 0 > "$TMPD/models/MANIFEST.sha256"
STATUS="$TMPD/nebula-integrity.status"
EVENTS="$TMPD/events.log"
STUB="$TMPD/orionx-event"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${EVENTS_FILE:?}"
STUBEOF
chmod +x "$STUB"

RC=0
EVENTS_FILE="$EVENTS" NEBULA_EVENT_CLI="$STUB" \
    python3 "$INTEGRITY_PY" --models-dir "$TMPD/models" \
        --manifest "$TMPD/models/MANIFEST.sha256" --status-file "$STATUS" \
        >/dev/null 2>&1 || RC=$?

if (( RC == 1 )); then
    pass "a mismatch still exits 1 (DEC-PHASE10-009 gate holds)"
else
    fail "a mismatch exited $RC, expected 1" ""
fi
for _needle in "severity critical" "category service" "FAILED SHA-256" "unaffected" "sha256sum -c"; do
    if grep -qF -- "$_needle" "$EVENTS" 2>/dev/null; then
        pass "mismatch event contains: $_needle"
    else
        fail "mismatch event missing: $_needle" \
             "$(cat "$EVENTS" 2>/dev/null || echo '(nothing published)')"
    fi
done
if grep -qE -- "--category (ids|intrusion|malware|scan)" "$EVENTS" 2>/dev/null; then
    fail "the integrity check publishes a THREAT category" \
         "RESILIENCE rule 5: a boot self-test must not move THREAT PRESSURE."
else
    pass "no threat category is used (self-diagnosis is not a threat)"
fi

# The category it does use must really be in the status vocabulary.
if python3 - "$REPO_ROOT" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/rain")
import rain_lib
sys.exit(0 if "service" in rain_lib.STATUS_CATEGORIES else 1)
PYEOF
then
    pass "'service' is in rain_lib.STATUS_CATEGORIES (excluded from pressure)"
else
    fail "'service' is not in rain_lib.STATUS_CATEGORIES" \
         "The category used here would count as a threat."
fi
rm -rf "$TMPD"; trap - EXIT
echo ""

# ---------------------------------------------------------------------------
# T5: never claim a publication that did not happen (rule 3)
# ---------------------------------------------------------------------------
echo "--- T5: unpublished is reported as unpublished ---"
if python3 - "$REPO_ROOT" <<'PYEOF'
import importlib.util, os, sys
root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "integ", os.path.join(root, "scripts", "nebula", "integrity.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m._EVENT_CLI = "/nonexistent/orionx-event-definitely-not-here"
sys.exit(0 if m.publish_event("critical", "nobody hears this") is False else 1)
PYEOF
then
    pass "publish_event returns False when orionx-event is absent"
else
    fail "publish_event claimed success with no CLI present" \
         "This is the toggle-theme.sh defect (RESILIENCE rule 3)."
fi

if python3 - "$REPO_ROOT" <<'PYEOF'
import importlib.util, os, stat, sys, tempfile
root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "integ", os.path.join(root, "scripts", "nebula", "integrity.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = tempfile.mkdtemp()
p = os.path.join(d, "orionx-event")
open(p, "w").write("#!/bin/sh\nexit 9\n")
os.chmod(p, 0o755)
m._EVENT_CLI = p
sys.exit(0 if m.publish_event("critical", "the CLI rejects this") is False else 1)
PYEOF
then
    pass "publish_event returns False when orionx-event exits non-zero"
else
    fail "publish_event claimed success on a non-zero CLI exit" ""
fi
echo ""

echo "==========================================="
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $TOTAL)"
echo "==========================================="
[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
