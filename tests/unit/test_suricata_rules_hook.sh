#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_suricata_rules_hook.sh — 0530: the curated, pinned ET-Open subset
# (DEC-PHASE13-043, W11-6b, issue #125).
#
# Behavioural, no network, no root, no suricata. Two layers:
#   1. The curation library (curate_rules / install_rules / write_provenance)
#      is sourced from the hook and run against a tiny fixture tarball built
#      here, with the hook's OWN category list. Assertions are on the file it
#      produces, not on the hook's text.
#   2. The whole hook runs with stub wget / suricata / sha256sum on PATH to
#      prove the fail-closed policy: a hash mismatch, a fetch failure, or an
#      engine that rejects the rules all exit 1 and leave NO rules behind.
#
# Mutation-tested while writing: deleting the STOCK_EXCLUDED_FILES check fails
# T6; dropping the sha verify in install_rules fails T10; making the engine
# check a warning fails T14.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

HOOK="$REPO_ROOT/iso/config/hooks/live/0530-suricata-rules.hook.chroot"
S="$(mktemp -d "$REPO_ROOT/tmp/suricata-rules-hook.XXXXXX")"
trap 'rm -rf "$S"' EXIT

printf "===========================================\n"
printf "  0530-suricata-rules hook (DEC-PHASE13-043)\n"
printf "===========================================\n"

section "Hook sanity"
[[ -f "$HOOK" ]] && pass "hook present" || { fail "hook present" "missing"; exit 1; }
[[ -x "$HOOK" ]] && pass "hook executable" || fail "hook executable"
bash -n "$HOOK" 2>/dev/null && pass "bash -n clean" || fail "bash -n clean"
grep -q '@decision DEC-PHASE13-043' "$HOOK" && pass "DEC-PHASE13-043 annotation" || fail "DEC-PHASE13-043 annotation"
grep -q '@decision DEC-PHASE13-044' "$HOOK" && pass "DEC-PHASE13-044 annotation" || fail "DEC-PHASE13-044 annotation"
PIN="$(sed -n 's/^ET_OPEN_SHA256="\([0-9a-f]*\)".*/\1/p' "$HOOK")"
[[ "$PIN" =~ ^[0-9a-f]{64}$ ]] && pass "tarball pinned to a full SHA-256 ($PIN)" || fail "pin" "'$PIN'"
grep -qE '^ET_OPEN_URL=.*suricata-7\.0/emerging\.rules\.tar\.gz' "$HOOK" && pass "pinned URL is the Suricata 7.0 feed (the ISO runs 7.0.10)" || fail "feed URL" "not the 7.0 feed"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$HOOK" >/dev/null 2>&1 && pass "shellcheck -S warning clean" || fail "shellcheck" "$(shellcheck -S warning "$HOOK" 2>&1 | head -5)"
else
    pass "shellcheck not installed — skipped"
fi

# macOS without coreutils has no sha256sum; the hook (Debian) uses it. A shim,
# only if missing, so the library code under test is unchanged.
mkdir -p "$S/shim"
if ! command -v sha256sum >/dev/null 2>&1; then
    printf '#!/bin/sh\nshasum -a 256 "$@"\n' > "$S/shim/sha256sum"; chmod +x "$S/shim/sha256sum"
fi
export PATH="$S/shim:$PATH"

# shellcheck source=/dev/null
if ORIONX_0530_LIB_ONLY=1 source "$HOOK" && declare -F curate_rules install_rules write_provenance verify_sha256 >/dev/null; then
    pass "sourcing with ORIONX_0530_LIB_ONLY=1 defines the library and runs nothing"
else
    fail "library sourcing" "functions undefined or main ran"; exit 1
fi
set +e +o pipefail   # the hook's set -e must not govern the suite
CATS="$ET_OPEN_CATEGORIES"
[[ "$CATS" == "scan attack_response exploit dos shellcode current_events" ]] \
    && pass "category list is the one the issue specifies" || fail "category list" "'$CATS'"

# --- Fixture: an ET-Open-shaped tarball (rules/ top dir, like the real one) ---
FX="$S/src/rules"; mkdir -p "$FX"
rule() { printf 'alert tcp any any -> $HOME_NET any (msg:"%s"; sid:%d; rev:1;)\n' "$1" "$2"; }
{ rule "ET SCAN nmap" 2000001; rule "ET SCAN syn" 2000002; printf '# alert tcp any any -> any any (msg:"ET SCAN disabled"; sid:2000003; rev:1;)\n'; } > "$FX/emerging-scan.rules"
rule "ET EXPLOIT x" 2000010 > "$FX/emerging-exploit.rules"
rule "ET DOS x" 2000020 > "$FX/emerging-dos.rules"
rule "ET SHELLCODE x" 2000030 > "$FX/emerging-shellcode.rules"
rule "ET CURRENT_EVENTS x" 2000040 > "$FX/emerging-current_events.rules"
rule "ET ATTACK_RESPONSE x" 2000050 > "$FX/emerging-attack_response.rules"
{ rule "ET MALWARE a" 2000060; rule "ET MALWARE b" 2000061; rule "ET MALWARE c" 2000062; } > "$FX/emerging-malware.rules"
{ rule "ET WEB_SPECIFIC_APPS a" 2000070; rule "ET WEB_SPECIFIC_APPS b" 2000071; } > "$FX/emerging-web_specific_apps.rules"
printf '# Emerging Threats\n# BSD License text (fixture)\n' > "$FX/LICENSE"
printf 'config classification: fixture,Fixture,1\n' > "$FX/classification.config"
tar -czf "$S/fx.tgz" -C "$S/src" rules
FXSHA="$(sha256sum "$S/fx.tgz" | awk '{print $1}')"
# Debian-shaped stock dir: *-events.rules (two loadable, two unparseable under
# Debian's config) and files.rules (stock, but not -events: not merged).
ST="$S/stock"; mkdir -p "$ST"
{ rule "SURICATA decoder a" 2200001; rule "SURICATA decoder b" 2200002; } > "$ST/decoder-events.rules"
rule "SURICATA stream a" 2210001 > "$ST/stream-events.rules"
rule "SURICATA DNP3 flood" 2270000 > "$ST/dnp3-events.rules"
rule "SURICATA Modbus bad" 2250001 > "$ST/modbus-events.rules"
rule "SURICATA files a" 2260001 > "$ST/files.rules"

section "Curation — the file is built from the right pieces and nothing else"
RD="$S/rules"; mkdir -p "$RD"
# shellcheck disable=SC2086
RES="$(curate_rules "$S/src/rules" "$ST" "$RD/suricata.rules" $CATS)"; RC=$?
[[ $RC -eq 0 && -f "$RD/suricata.rules" ]] && pass "T1 curate_rules writes suricata.rules (rc=0)" || fail "T1 curate_rules" "rc=$RC"
# 3 stock (decoder 2 + stream 1) + 7 ET (scan 2, exploit, dos, shellcode, current_events, attack_response)
[[ "$RES" == "10 2" ]] && pass "T2 reports '10 2': 10 live signatures from 2 stock files + 6 categories" || fail "T2 count" "got '$RES', want '10 2'"
grep -q 'ET SCAN nmap' "$RD/suricata.rules" && grep -q 'ET EXPLOIT x' "$RD/suricata.rules" && grep -q 'ET CURRENT_EVENTS x' "$RD/suricata.rules" \
    && pass "T3 every listed category reached the merged file" || fail "T3 categories merged"
! grep -q 'ET MALWARE' "$RD/suricata.rules" && ! grep -q 'WEB_SPECIFIC_APPS' "$RD/suricata.rules" \
    && pass "T4 malware and web_specific_apps are NOT merged (the 2 GB trade)" || fail "T4 exclusions" "heavy categories leaked in"
grep -q 'SURICATA decoder a' "$RD/suricata.rules" && grep -q 'SURICATA stream a' "$RD/suricata.rules" \
    && pass "T5 Debian's stock *-events.rules are merged (they were never loaded before W11-6b)" || fail "T5 stock merged"
! grep -q 'DNP3' "$RD/suricata.rules" && ! grep -q 'Modbus' "$RD/suricata.rules" \
    && pass "T6 dnp3/modbus-events.rules excluded (unparseable under Debian's config; measured)" || fail "T6 stock exclusions" "dnp3/modbus leaked in"
! grep -q 'SURICATA files a' "$RD/suricata.rules" && pass "T7 files.rules (stock, not -events) is not merged" || fail "T7 files.rules" "merged"
grep -q 'ET SCAN disabled' "$RD/suricata.rules" && [[ "$(count_signatures "$RD/suricata.rules")" -eq 10 ]] \
    && pass "T8 ET-disabled (commented) rule is carried verbatim but not counted" || fail "T8 disabled rule" "count $(count_signatures "$RD/suricata.rules")"
grep -q 'orionx-rules.provenance.txt' "$RD/suricata.rules" && pass "T9 header points at the provenance file" || fail "T9 header"
# A missing category must be fatal, not a quieter file.
RD2="$S/rules2"; mkdir -p "$RD2"
curate_rules "$S/src/rules" "$ST" "$RD2/suricata.rules" scan bogus_category >/dev/null 2>"$S/err"; RC=$?
[[ $RC -ne 0 && ! -f "$RD2/suricata.rules" ]] && grep -q 'bogus_category' "$S/err" \
    && pass "T9b a category absent from the tarball fails curation and names it (no thinner file shipped)" || fail "T9b missing category" "rc=$RC $(cat "$S/err")"

section "install_rules — nothing lands unless the hash matches; provenance is complete"
RD3="$S/rules3"
# shellcheck disable=SC2086
install_rules "$S/fx.tgz" "deadbeef$PIN" "$ST" "$RD3" https://x/et.tgz 2026-01-01 $CATS >"$S/out" 2>"$S/err"; RC=$?
[[ $RC -ne 0 && ! -e "$RD3/suricata.rules" && ! -e "$RD3/orionx-rules.provenance.txt" ]] && grep -q 'SHA-256 MISMATCH' "$S/err" \
    && pass "T10 wrong hash: rc=$RC, MISMATCH named, nothing written to the rules dir" || fail "T10 hash mismatch" "rc=$RC $(ls "$RD3" 2>/dev/null) $(cat "$S/err")"
# shellcheck disable=SC2086
RES="$(install_rules "$S/fx.tgz" "$FXSHA" "$ST" "$RD3" https://x/et.tgz 2026-01-01 $CATS 2>"$S/err" | tail -n1)"; RC=$?
[[ $RC -eq 0 && -s "$RD3/suricata.rules" ]] && pass "T11 right hash: rules installed" || fail "T11 install" "rc=$RC $(cat "$S/err")"
BYTES="$(wc -c < "$RD3/suricata.rules" | tr -d ' ')"
[[ "$RES" == "10 $BYTES 2" ]] && pass "T12 reports '<sigs> <bytes> <stock>' = '$RES'" || fail "T12 result line" "got '$RES', want '10 $BYTES 2'"
PROV="$RD3/orionx-rules.provenance.txt"
if [[ -f "$PROV" ]]; then
    pass "T13 provenance file written beside the rules"
    for want in "source-sha256: $FXSHA" "source-url: https://x/et.tgz" "pinned-on: 2026-01-01" "categories-included: $CATS" \
                "signatures: 10" "bytes: $BYTES" "stock-files-included: 2" "stock-files-excluded: dnp3-events.rules modbus-events.rules" \
                "license: ET-Open rules" "BSD" "malware" "web_specific_apps" "orionx-freshen-suricata" "source-tarball-bytes: $(wc -c < "$S/fx.tgz" | tr -d ' ')"; do
        grep -qF -- "$want" "$PROV" && pass "T13 provenance records: $want" || fail "T13 provenance missing" "$want"
    done
    grep -qE '^baked-on: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$PROV" && pass "T13 provenance has a build timestamp" || fail "T13 baked-on"
else
    fail "T13 provenance" "absent"
fi
[[ -s "$RD3/LICENSE-ET-Open.txt" ]] && grep -q 'BSD' "$RD3/LICENSE-ET-Open.txt" && pass "T13b the tarball's LICENSE is copied beside the rules" || fail "T13b license copy"
# Re-running yields the same file (no accretion), and leaves no scratch behind.
# shellcheck disable=SC2086
install_rules "$S/fx.tgz" "$FXSHA" "$ST" "$RD3" https://x/et.tgz 2026-01-01 $CATS >/dev/null 2>&1
[[ "$(count_signatures "$RD3/suricata.rules")" -eq 10 && -z "$(find "$RD3" -name '.orionx-curate.*')" ]] \
    && pass "T13c idempotent re-run: still 10 signatures, no temp files left" || fail "T13c idempotent" "$(ls -a "$RD3")"

section "Whole hook — fail-closed (stub wget / suricata / sha256sum on PATH)"
# scenario <name> <wget mode: ok|fail> <sha mode: real|pin> <suricata mode: ok|reject|absent>
scenario() {
    local d="$S/h_$1"; rm -rf "$d"; mkdir -p "$d/bin" "$d/rules" "$d/etc"
    cp "$S/fx.tgz" "$d/fx.tgz"; printf 'include: []\n' > "$d/etc/orionx.yaml"
    case "$2" in
        ok)   printf '#!/bin/sh\nwhile [ $# -gt 1 ]; do [ "$1" = -O ] && out="$2"; shift; done\ncp "%s" "$out"\n' "$d/fx.tgz" > "$d/bin/wget" ;;
        fail) printf '#!/bin/sh\nexit 4\n' > "$d/bin/wget" ;;
    esac
    case "$3" in
        pin)  printf '#!/bin/sh\necho "%s  $1"\n' "$PIN" > "$d/bin/sha256sum" ;;
        real) ;;
    esac
    case "$4" in
        ok)     printf '#!/bin/sh\necho "Info: detect: 1 rule files processed. 10 rules successfully loaded, 0 rules failed, 0"\nexit 0\n' > "$d/bin/suricata" ;;
        reject) printf '#!/bin/sh\necho "Error: detect: error parsing signature"\necho "Info: detect: 1 rule files processed. 0 rules successfully loaded, 10 rules failed, 0"\nexit 1\n' > "$d/bin/suricata" ;;
        absent) ;;
    esac
    chmod +x "$d/bin/"* 2>/dev/null
    PATH="$d/bin:$PATH" RULES_DIR="$d/rules" STOCK_RULES_DIR="$ST" SURICATA_CONFIG="$d/etc/orionx.yaml" \
        bash "$HOOK" > "$d/log" 2>&1
    echo $? > "$d/rc"
}

scenario good ok pin ok
if [[ "$(cat "$S/h_good/rc")" == 0 && -s "$S/h_good/rules/suricata.rules" ]] \
   && grep -q '^engine-loaded: 10$' "$S/h_good/rules/orionx-rules.provenance.txt"; then
    pass "T14 good path: exit 0, rules + provenance written, engine-loaded count recorded from suricata -T"
else
    fail "T14 good path" "rc=$(cat "$S/h_good/rc") $(tail -5 "$S/h_good/log")"
fi

scenario badsha ok real ok
[[ "$(cat "$S/h_badsha/rc")" == 1 ]] && grep -q 'SHA-256 MISMATCH' "$S/h_badsha/log" && [[ ! -e "$S/h_badsha/rules/suricata.rules" ]] \
    && pass "T15 hash mismatch against the REAL pin: build fails (exit 1), mismatch named, no rules shipped" \
    || fail "T15 fail-closed on hash" "rc=$(cat "$S/h_badsha/rc") $(tail -3 "$S/h_badsha/log")"

scenario nofetch fail pin ok
[[ "$(cat "$S/h_nofetch/rc")" == 1 ]] && grep -q 'fetch failed' "$S/h_nofetch/log" && [[ ! -e "$S/h_nofetch/rules/suricata.rules" ]] \
    && pass "T16 fetch failure: build fails (exit 1), no rules shipped" || fail "T16 fail-closed on fetch" "rc=$(cat "$S/h_nofetch/rc")"

scenario rejected ok pin reject
[[ "$(cat "$S/h_rejected/rc")" == 1 ]] && [[ ! -e "$S/h_rejected/rules/suricata.rules" && ! -e "$S/h_rejected/rules/orionx-rules.provenance.txt" ]] \
    && pass "T17 engine rejects the merged file: build fails and the rejected rules are REMOVED (no half-shipped set)" \
    || fail "T17 fail-closed on engine" "rc=$(cat "$S/h_rejected/rc") $(ls "$S/h_rejected/rules")"

scenario nosuricata ok pin absent
[[ "$(cat "$S/h_nosuricata/rc")" == 1 ]] && grep -q 'suricata is not installed' "$S/h_nosuricata/log" \
    && pass "T18 no suricata in the chroot: build fails before fetching" || fail "T18 missing engine" "rc=$(cat "$S/h_nosuricata/rc")"
[[ ! -e "$S/h_nosuricata/rules/suricata.rules" ]] && pass "T18b ...and nothing was written" || fail "T18b" "rules written"

for d in good badsha nofetch rejected; do
    if grep -q '=== done ===' "$S/h_$d/log" && [[ "$d" != good ]]; then fail "T19 $d claims success" "'=== done ===' in log"; fi
done
pass "T19 only the good path prints '=== done ==='"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
