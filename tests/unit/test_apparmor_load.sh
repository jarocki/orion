#!/usr/bin/env bash
# shellcheck shell=bash
#
# AppArmor loading and the confinement claims (DEC-PHASE12-100/101/103)
#
# Executes /usr/lib/orionx/orionx-apparmor-load against stubbed
# apparmor_parser / kernel profile list / orionx-event, and checks the
# ollama profile + nebula-runtime unit make the "local only" claim true.
# If docker is available, every shipped profile is also parsed with the real
# apparmor_parser in debian:trixie-slim (ORIONX_SKIP_DOCKER=1 skips it).
#
# Usage: bash tests/unit/test_apparmor_load.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INC="$ROOT/iso/config/includes.chroot"
LOADER="$INC/usr/lib/orionx/orionx-apparmor-load"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; return 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/profiles" "$T/bin"
for p in a b broken; do echo "profile $p {}" > "$T/profiles/$p"; done
cat > "$T/bin/parser" <<'EOF'
#!/usr/bin/env bash
[[ "$2" == *broken ]] && exit 1
exit 0
EOF
cat > "$T/bin/orionx-event" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$EVENTS"
EOF
chmod +x "$T/bin/"*
export EVENTS="$T/events"
run() {  # run <kernel-list-content>
    printf '%s' "$1" > "$T/kernel"; : > "$EVENTS"
    PATH="$T/bin:$PATH" ORIONX_AA_PROFILE_DIR="$T/profiles" ORIONX_AA_PARSER="$T/bin/parser" \
        ORIONX_AA_KERNEL_PROFILES="$T/kernel" bash "$LOADER" >"$T/out" 2>&1
}
ALL=$'ollama (enforce)\nnebula-mcp (enforce)\nwireguard (enforce)\ntshark (enforce)\n'

echo "=== orionx-apparmor-load ==="
if [[ -x "$LOADER" ]]; then pass "loader script exists and is executable"; else fail "loader exists" "$LOADER"; fi
run "$ALL"; rc=$?
if [[ $rc -eq 0 ]]; then pass "one broken third-party profile does not fail the unit (required ones enforced)"; else fail "partial load exit 0" "rc=$rc $(cat "$T/out")"; fi
if grep -q -- '--severity warning --source apparmor --category health' "$EVENTS" && grep -q 'broken' "$EVENTS"; then
    pass "the partial load is published on the bus naming the failed profile"
else
    fail "partial load published" "$(cat "$EVENTS")"
fi
run $'ollama (complain)\nnebula-mcp (enforce)\nwireguard (enforce)\n'; rc=$?
if [[ $rc -eq 1 ]]; then pass "a required profile not enforced fails the unit (nebula-runtime then stays down)"; else fail "required missing -> exit 1" "rc=$rc"; fi
if grep -q -- '--severity critical' "$EVENTS" && grep -q 'ollama' "$EVENTS" && grep -q 'tshark' "$EVENTS"; then
    pass "the event names each required profile that is not enforced"
else
    fail "required-missing event" "$(cat "$EVENTS")"
fi
rm -f "$T/profiles/broken"
run "$ALL"; rc=$?
if [[ $rc -eq 0 && ! -s "$EVENTS" ]]; then pass "clean load: exit 0, nothing published"; else fail "clean load" "rc=$rc $(cat "$EVENTS")"; fi
UNIT="$INC/usr/share/orionx/systemd/orionx-apparmor-load.service"
if grep -q '^ExecStart=/usr/lib/orionx/orionx-apparmor-load$' "$UNIT"; then pass "the unit runs the loader script"; else fail "unit ExecStart"; fi

echo "=== ollama: exec of its own runner, egress enforced by systemd ==="
OP="$INC/etc/apparmor.d/usr.bin.ollama"
if grep -qE '^[[:space:]]*/usr/local/bin/ollama [a-z]*ix,' "$OP"; then pass "ollama may re-exec itself as its runner (P1-4)"; else fail "ollama self-exec permission"; fi
if grep -qE '^[[:space:]]*/usr/bin/ollama ' "$OP"; then fail "no rule for the nonexistent /usr/bin/ollama"; else pass "no rule for the nonexistent /usr/bin/ollama"; fi
if grep -qE '^[[:space:]]*deny /root/\*\* w' "$OP"; then fail "HOME=/root/.ollama is not denied"; else pass "HOME=/root/.ollama is not denied"; fi
NR="$INC/usr/share/orionx/systemd/nebula-runtime.service"
if grep -q '^IPAddressDeny=any$' "$NR" && grep -q '^IPAddressAllow=localhost$' "$NR"; then pass "nebula-runtime: kernel-enforced localhost-only (F8)"; else fail "IPAddressDeny/Allow"; fi
if grep -q '^ProtectHome=' "$NR"; then fail "ProtectHome would make ollama's HOME (/root) read-only"; else pass "no ProtectHome on a unit whose HOME is /root"; fi
if grep -q '^Requires=orionx-apparmor-load.service$' "$NR"; then pass "nebula-runtime requires the AppArmor load"; else fail "Requires=orionx-apparmor-load"; fi

echo "=== volatility3 follows vol into the venv; reads removable media ==="
VP="$INC/etc/apparmor.d/usr.bin.volatility3"
if grep -q '^profile volatility3 /{usr/,usr/local/,opt/orionx/venv/forensics/}bin/vol {' "$VP"; then pass "attaches at all three vol homes"; else fail "volatility3 attachment"; fi
if grep -q '/media/\*\* r,' "$VP"; then pass "/media is readable (P3-9)"; else fail "/media readable"; fi

echo "=== real apparmor_parser (trixie container) ==="
if [[ "${ORIONX_SKIP_DOCKER:-0}" != 1 ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    out="$(docker run --rm -v "$INC/etc/apparmor.d:/p:ro" debian:trixie-slim bash -c \
        'apt-get update -qq >/dev/null && apt-get install -y -qq apparmor >/dev/null 2>&1; rc=0; for f in /p/*; do apparmor_parser -QTK -I /etc/apparmor.d "$f" || { echo "BAD $f"; rc=1; }; done; exit $rc' 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then pass "every shipped Orion-X profile parses (apparmor_parser -QTK)"; else fail "profiles parse" "$out"; fi
else
    SKIP=$((SKIP+1)); echo "  SKIP: docker unavailable"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ $FAIL -eq 0 ]]
