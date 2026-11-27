#!/usr/bin/env bash
# shellcheck shell=bash
#
# deck-check.sh (the v3.2.0 hardware boot test) against stubs: it bundles
# every step, keeps going when one fails, runs the speech test as the
# operator, and changes nothing. Every system command it may call is a stub
# that logs its argv; the log must contain no verb that writes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DC="$ROOT/iso/config/includes.chroot/opt/orionx/optional/deck-check.sh"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        ${2:-}"; FAIL=$((FAIL+1)); }

T="$ROOT/tmp/test-deck-check.$$"
mkdir -p "$T"
# shellcheck disable=SC2329  # run by the EXIT trap
cleanup() { rm -rf "$T"; }
trap cleanup EXIT

B="$T/bin"; mkdir -p "$B" "$T/opt/optional" "$T/probes" "$T/home"
CALLS="$T/calls.log"
for c in systemctl systemd-analyze systemd-detect-virt journalctl orionx-rain orionx-optional orionx-heal \
         orionx-logquery ip nmcli ps lsblk getent free nproc ollama apt-get; do
    printf '#!/bin/bash\necho "%s $*" >> "%s"\necho "stub %s output"\n' "$c" "$CALLS" "$c" > "$B/$c"
done
# A step that fails must not stop the rest.
printf '#!/bin/bash\necho "orionx-logquery $*" >> "%s"\nexit 3\n' "$CALLS" > "$B/orionx-logquery"
# sudo -u <user> <cmd...>: record who, then run the command.
printf '#!/bin/bash\necho "sudo $*" >> "%s"\n[[ "$1" == -u ]] && shift 2\nexec "$@"\n' "$CALLS" > "$B/sudo"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$B/timeout"        # macOS has none; the deck has coreutils'
printf '#!/bin/bash\necho "probe $(basename "$0") $*" >> "%s"\necho ORIONX_VERIFY_END: overall=PASS\n' "$CALLS" > "$T/probes/runtime-verify.sh"
cp "$T/probes/runtime-verify.sh" "$T/probes/perf-measure.sh"
cat > "$T/opt/optional/apt-evidence.sh" <<EOF
#!/bin/bash
echo "apt-evidence \$ORIONX_APT_EVIDENCE_DIR" >> "$CALLS"
echo apt > "\$ORIONX_APT_EVIDENCE_DIR/orionx-apt-evidence-test.tar.gz"
EOF
chmod +x "$B"/* "$T"/probes/*.sh "$T"/opt/optional/*.sh

run() {
    : > "$CALLS"
    OUT="$(PATH="$B:$PATH" SUDO_USER=alice ORIONX_DECK_CHECK_ALLOW_NONROOT=1 ORIONX_DECK_CHECK_OUT="$T/home" \
           ORIONX_DECK_CHECK_OPT="$T/opt" ORIONX_DECK_CHECK_PROBES="$T/probes" bash "$DC" "$@" 2>&1)"; RC=$?
}

echo "[deck-check.sh]"
run
[[ $RC -eq 0 ]] && pass "exit 0" || fail "exit 0" "rc=$RC $(tail -5 <<<"$OUT")"
TB="$(tail -1 <<<"$OUT")"
if [[ "$TB" == "$T/home/orionx-deck-check-"*.tar.gz && -f "$TB" ]]; then pass "the tarball path is the last line and the tarball exists"
else fail "tarball" "last line: $TB"; fi
LIST="$(tar -tzf "$TB" 2>/dev/null)"
for f in SUMMARY.txt CHECK-BY-EYE.txt orionx-apt-evidence-test.tar.gz probe-runtime-verify.txt nebula-chat.txt speech-test-3.txt; do
    grep -q "/$f$" <<<"$LIST" && pass "bundle has $f" || fail "bundle has $f" "$(tr '\n' ' ' <<<"$LIST")"
done
D="$(find "$T/home" -mindepth 1 -maxdepth 1 -type d -name 'orionx-deck-check-*' | head -1)"
N="$(wc -l < "$D/SUMMARY.txt" | tr -d ' ')"
[[ "$N" -ge 25 ]] && pass "SUMMARY.txt records every step ($N)" || fail "SUMMARY steps" "$N lines: $(cat "$D/SUMMARY.txt")"
grep -qE '^logquery-summary +rc=3 ' "$D/SUMMARY.txt" && pass "a failing step is recorded with its rc" || fail "rc recorded" "$(grep logquery "$D/SUMMARY.txt")"
grep -q '^apt-evidence ' "$D/SUMMARY.txt" && grep -q '^network ' "$D/SUMMARY.txt" && pass "... and the steps after it still ran" || fail "kept going" "$(tail -3 "$D/SUMMARY.txt")"
[[ "$(grep -c '^sudo -u alice .*orionx-rain --speech-test --all-engines' "$CALLS")" == 3 ]] \
    && pass "the speech test runs three times as the operator (SUDO_USER)" || fail "speech as operator" "$(grep sudo "$CALLS")"
grep -q "XDG_RUNTIME_DIR=/run/user/" "$CALLS" && pass "... in the operator's session (XDG_RUNTIME_DIR)" || fail "operator session env" "$(grep sudo "$CALLS" | head -1)"
grep -q "^apt-evidence $D" "$CALLS" && pass "apt-evidence writes inside the bundle directory" || fail "apt-evidence dir" "$(grep apt-evidence "$CALLS")"
grep -qx "orionx-heal autonomy" "$CALLS" && pass "orionx-heal autonomy is only read (no class or level given)" || fail "heal autonomy read" "$(grep orionx-heal "$CALLS")"

# Nothing that writes: no unit state change, no package change, no model
# change, no install, no healing action, no deletion.
BAD="$(grep -E '^systemctl (start|stop|restart|reload|enable|disable|mask|unmask|kill|isolate|set-property)|^apt-get ([a-z-]+ )*(install|remove|purge|upgrade|dist-upgrade|full-upgrade|autoremove|update)|^ollama (pull|push|rm|create|cp|run)|^orionx-optional (install|uninstall)|^orionx-heal (run|renew|undo|autonomy [a-z])|^orionx-rain --speech (on|off)' "$CALLS" || true)"
[[ -z "$BAD" ]] && pass "no command that changes state was called" || fail "write verbs" "$BAD"
if grep -qE '(^|[;&| ])rm ' "$DC"; then fail "deck-check.sh deletes nothing" "an rm in the script"; else pass "deck-check.sh contains no rm"; fi

run --no-audio
grep -q 'speech-test' "$CALLS" && fail "--no-audio skips the speech test" "$(grep speech-test "$CALLS")" || pass "--no-audio skips the speech test"
grep -q 'orionx-rain --speech-status' "$CALLS" && pass "... and still reads --speech-status" || fail "speech-status" "not read"

OUT="$(PATH="$B:$PATH" bash "$DC" 2>&1)"; RC=$?
if [[ "$(id -u)" -ne 0 ]]; then
    [[ $RC -eq 1 ]] && grep -q "run it with sudo" <<<"$OUT" && pass "refuses without root, saying why" || fail "non-root refusal" "rc=$RC $OUT"
fi
OUT="$(bash "$DC" --bogus 2>&1)"; RC=$?
[[ $RC -eq 2 ]] && pass "an unknown argument is a usage error (2)" || fail "usage error" "rc=$RC"
bash "$DC" --help | grep -q "sudo /opt/orionx/optional/deck-check.sh" && pass "--help prints the usage" || fail "--help"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
