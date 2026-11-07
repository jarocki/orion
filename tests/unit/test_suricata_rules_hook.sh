#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_suricata_rules_hook.sh — the vendored, curated ET-Open subset
# (DEC-PHASE13-043, W11-6b, issue #125): refresh script, vendored files, hook.
#
# Behavioural, no network, no root, no suricata. Three layers:
#   1. scripts/suricata-rules-refresh.sh's curation library is sourced and run
#      against a tiny fixture tarball with the script's OWN category list.
#      Assertions are on the file it produces, not on the script's text.
#   2. The VENDORED files in iso/config/includes.chroot/var/lib/suricata/rules
#      agree with each other: the provenance's `signatures:` and `bytes:` equal
#      a fresh count of suricata.rules, the pin is a real SHA-256, the license
#      copy is there. A refresh cannot forget the provenance.
#   3. Hook 0530 runs whole, with a stub suricata on PATH, against a fixture
#      rules dir: good path appends engine-loaded; a missing file, a count
#      mismatch, an engine rejection or a missing engine exit 1.
#
# Mutation-tested while writing: deleting the STOCK_EXCLUDED_FILES check fails
# T6; dropping the provenance/count comparison in the hook fails T16; making
# the engine check a warning fails T17.
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
REFRESH="$REPO_ROOT/scripts/suricata-rules-refresh.sh"
FRESHEN="$REPO_ROOT/scripts/orionx-freshen-suricata.sh"
VENDORED="$REPO_ROOT/iso/config/includes.chroot/var/lib/suricata/rules"
S="$(mktemp -d "$REPO_ROOT/tmp/suricata-rules-hook.XXXXXX")"
trap 'rm -rf "$S"' EXIT

printf "===========================================\n"
printf "  vendored ET-Open subset (DEC-PHASE13-043)\n"
printf "===========================================\n"

section "Scripts sanity"
[[ -f "$HOOK" ]] && pass "hook present" || { fail "hook present" "missing"; exit 1; }
[[ -x "$HOOK" ]] && pass "hook executable" || fail "hook executable"
[[ -x "$REFRESH" ]] && pass "refresh script present + executable" || { fail "refresh script" "missing or not +x"; exit 1; }
bash -n "$HOOK" 2>/dev/null && pass "hook bash -n clean" || fail "hook bash -n"
bash -n "$REFRESH" 2>/dev/null && pass "refresh bash -n clean" || fail "refresh bash -n"
grep -q '@decision DEC-PHASE13-043' "$HOOK" && pass "DEC-PHASE13-043 annotation in the hook" || fail "DEC-PHASE13-043 annotation"
grep -q '@decision DEC-PHASE13-044' "$HOOK" && pass "DEC-PHASE13-044 annotation in the hook" || fail "DEC-PHASE13-044 annotation"
grep -qiE 'rolling' "$HOOK" && pass "hook rationale states WHY the output is vendored (rolling upstream URL)" || fail "rationale" "no 'rolling' explanation"
! grep -qE '^[^#]*\b(wget|curl)\b' "$HOOK" && pass "hook performs no network fetch (no wget/curl outside comments)" || fail "hook fetches" "wget/curl in hook code"
grep -q '^suricata-rules-refresh:' "$REPO_ROOT/Makefile" && pass "make suricata-rules-refresh target exists" || fail "Makefile target" "missing"
# One counting regex, three tools.
R1="$(sed -n "s/^RULE_ACTION_RE=\(.*\)$/\1/p" "$HOOK" | head -1)"
R2="$(sed -n "s/^RULE_ACTION_RE=\(.*\)$/\1/p" "$REFRESH" | head -1)"
R3="$(sed -n "s/^RULE_ACTION_RE=\(.*\)$/\1/p" "$FRESHEN" | head -1)"
[[ -n "$R1" && "$R1" == "$R2" && "$R2" == "$R3" ]] && pass "hook, refresh and freshen share one RULE_ACTION_RE" || fail "RULE_ACTION_RE drift" "hook='$R1' refresh='$R2' freshen='$R3'"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$HOOK" "$REFRESH" >/dev/null 2>&1 && pass "shellcheck -S warning clean (hook + refresh)" || fail "shellcheck" "$(shellcheck -S warning "$HOOK" "$REFRESH" 2>&1 | head -5)"
else
    pass "shellcheck not installed — skipped"
fi

# macOS without coreutils has no sha256sum; the scripts (Debian) use it. A shim,
# only if missing, so the library code under test is unchanged.
mkdir -p "$S/shim"
if ! command -v sha256sum >/dev/null 2>&1; then
    printf '#!/bin/sh\nshasum -a 256 "$@"\n' > "$S/shim/sha256sum"; chmod +x "$S/shim/sha256sum"
fi
export PATH="$S/shim:$PATH"

# shellcheck source=/dev/null
if ORIONX_RULES_REFRESH_LIB_ONLY=1 source "$REFRESH" && declare -F curate_rules vendor_from_tarball write_provenance count_signatures >/dev/null; then
    pass "sourcing the refresh script with LIB_ONLY defines the library and runs nothing"
else
    fail "library sourcing" "functions undefined or main ran"; exit 1
fi
set +e +o pipefail   # the script's set -e must not govern the suite
CATS="$ET_OPEN_CATEGORIES"
[[ "$CATS" == "scan attack_response exploit dos shellcode current_events" ]] \
    && pass "category list is the one the issue specifies" || fail "category list" "'$CATS'"
[[ "$ET_OPEN_URL" == *suricata-7.0/emerging.rules.tar.gz ]] && pass "refresh fetches the Suricata 7.0 feed (the ISO runs 7.0.10)" || fail "feed URL" "$ET_OPEN_URL"

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

section "Curation (refresh library) — the file is built from the right pieces and nothing else"
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
grep -q 'orionx-rules.provenance.txt' "$RD/suricata.rules" && grep -q 'VENDORED' "$RD/suricata.rules" \
    && pass "T9 header says the file is vendored and points at the provenance" || fail "T9 header"
RD2="$S/rules2"; mkdir -p "$RD2"
curate_rules "$S/src/rules" "$ST" "$RD2/suricata.rules" scan bogus_category >/dev/null 2>"$S/err"; RC=$?
[[ $RC -ne 0 && ! -f "$RD2/suricata.rules" ]] && grep -q 'bogus_category' "$S/err" \
    && pass "T9b a category absent from the tarball fails curation and names it (no thinner file vendored)" || fail "T9b missing category" "rc=$RC $(cat "$S/err")"

section "vendor_from_tarball — three files, complete provenance, recorded upstream hash"
RD3="$S/rules3"
# shellcheck disable=SC2086
RES="$(vendor_from_tarball "$S/fx.tgz" "$ST" "$RD3" https://x/et.tgz "Fri, 06 Nov 2026 21:47:10 GMT" $CATS 2>"$S/err" | tail -n1)"; RC=$?
[[ $RC -eq 0 && -s "$RD3/suricata.rules" ]] && pass "T10 vendored suricata.rules written" || fail "T10 vendor" "rc=$RC $(cat "$S/err")"
BYTES="$(wc -c < "$RD3/suricata.rules" | tr -d ' ')"
[[ "$RES" == "10 $BYTES 2 $FXSHA" ]] && pass "T11 reports '<sigs> <bytes> <stock> <sha256>' = '$RES'" || fail "T11 result line" "got '$RES', want '10 $BYTES 2 $FXSHA'"
PROV="$RD3/orionx-rules.provenance.txt"
if [[ -f "$PROV" ]]; then
    pass "T12 provenance file written beside the rules"
    for want in "source-sha256: $FXSHA" "source-url: https://x/et.tgz" "source-last-modified: Fri, 06 Nov 2026 21:47:10 GMT" \
                "source-tarball-bytes: $(wc -c < "$S/fx.tgz" | tr -d ' ')" "ROLLING" "categories-included: $CATS" \
                "signatures: 10" "bytes: $BYTES" "stock-files-included: 2" "stock-files-excluded: dnp3-events.rules modbus-events.rules" \
                "license: ET-Open rules" "BSD" "malware" "web_specific_apps" "make suricata-rules-refresh" "orionx-freshen-suricata"; do
        grep -qF -- "$want" "$PROV" && pass "T12 provenance records: $want" || fail "T12 provenance missing" "$want"
    done
    grep -qE '^refreshed-on: [0-9]{4}-[0-9]{2}-[0-9]{2}T' "$PROV" && pass "T12 provenance has a refresh timestamp" || fail "T12 refreshed-on"
else
    fail "T12 provenance" "absent"
fi
[[ -s "$RD3/LICENSE-ET-Open.txt" ]] && grep -q 'BSD' "$RD3/LICENSE-ET-Open.txt" && pass "T12b the tarball's LICENSE is copied beside the rules" || fail "T12b license copy"
# A tarball without LICENSE must not be vendored (the BSD notice has to travel).
mkdir -p "$S/nolic/rules"; cp "$FX"/emerging-*.rules "$S/nolic/rules/"; tar -czf "$S/nolic.tgz" -C "$S/nolic" rules
RD4="$S/rules4"
# shellcheck disable=SC2086
vendor_from_tarball "$S/nolic.tgz" "$ST" "$RD4" https://x/et.tgz x $CATS >/dev/null 2>"$S/err"; RC=$?
[[ $RC -ne 0 && ! -e "$RD4/suricata.rules" ]] && grep -q 'LICENSE' "$S/err" && pass "T12c a tarball without LICENSE is refused, nothing vendored" || fail "T12c license required" "rc=$RC $(ls "$RD4" 2>/dev/null)"

section "Vendored files in the tree agree with their provenance (a refresh cannot forget it)"
VR="$VENDORED/suricata.rules"; VP="$VENDORED/orionx-rules.provenance.txt"; VL="$VENDORED/LICENSE-ET-Open.txt"
if [[ -s "$VR" && -s "$VP" && -s "$VL" ]]; then
    pass "T13 suricata.rules, orionx-rules.provenance.txt and LICENSE-ET-Open.txt are vendored"
    VSIGS="$(count_signatures "$VR")"; PSIGS="$(sed -n 's/^signatures: \([0-9]*\)$/\1/p' "$VP" | head -1)"
    [[ -n "$PSIGS" && "$VSIGS" -eq "$PSIGS" ]] && pass "T13b provenance signatures ($PSIGS) == fresh count of suricata.rules ($VSIGS)" || fail "T13b count drift" "provenance '$PSIGS' vs file '$VSIGS' — run make suricata-rules-refresh"
    VB="$(wc -c < "$VR" | tr -d ' ')"; PB="$(sed -n 's/^bytes: \([0-9]*\)$/\1/p' "$VP" | head -1)"
    [[ -n "$PB" && "$VB" -eq "$PB" ]] && pass "T13c provenance bytes ($PB) == size of suricata.rules" || fail "T13c bytes drift" "provenance '$PB' vs file '$VB'"
    [[ "$VSIGS" -ge 1000 ]] && pass "T13d vendored set carries >= 1,000 live signatures ($VSIGS)" || fail "T13d too thin" "$VSIGS"
    grep -qE '^source-sha256: [0-9a-f]{64}$' "$VP" && pass "T13e provenance records a full SHA-256 of the upstream tarball" || fail "T13e pin" "$(grep source-sha256 "$VP")"
    grep -qE '^source-last-modified: .*GMT' "$VP" && pass "T13f provenance records the upstream Last-Modified (the rolling object's version evidence)" || fail "T13f last-modified" "$(grep last-modified "$VP")"
    grep -q '^refresh-check: [0-9]* rules loaded, 0 failed' "$VP" && pass "T13g provenance records that the refresh proved the file loads (0 failed)" || fail "T13g refresh-check" "$(grep refresh-check "$VP")"
    ! grep -q '^engine-loaded:\|^baked-on:' "$VP" && pass "T13h vendored provenance carries no build-time lines (the hook appends those on the image)" || fail "T13h" "build lines committed"
    ! grep -qE 'alert dnp3 |alert modbus ' "$VR" && pass "T13i no dnp3/modbus signatures in the vendored file" || fail "T13i" "unparseable stock rules vendored"
    grep -q 'Emerging Threats' "$VL" && pass "T13j license copy is the ET text" || fail "T13j" "not the ET license"
else
    fail "T13 vendored files present" "missing under $VENDORED — run make suricata-rules-refresh and commit"
fi

section "Hook 0530 — verify-only, fail-closed (stub suricata on PATH)"
# scenario <name> <rules: ok|missing|mismatch|nolic> <suricata: ok|reject|absent>
scenario() {
    local d="$S/h_$1"; rm -rf "$d"; mkdir -p "$d/bin" "$d/rules" "$d/etc"
    printf 'include: []\n' > "$d/etc/orionx.yaml"
    if [[ "$2" != missing ]]; then
        cp "$RD3/suricata.rules" "$RD3/orionx-rules.provenance.txt" "$d/rules/"
        [[ "$2" == nolic ]] || cp "$RD3/LICENSE-ET-Open.txt" "$d/rules/"
        [[ "$2" == mismatch ]] && sed -i.bak 's/^signatures: 10$/signatures: 9/' "$d/rules/orionx-rules.provenance.txt" && rm -f "$d/rules/orionx-rules.provenance.txt.bak"
    fi
    case "$3" in
        ok)     printf '#!/bin/sh\necho "Info: detect: 1 rule files processed. 10 rules successfully loaded, 0 rules failed, 0"\nexit 0\n' > "$d/bin/suricata" ;;
        reject) printf '#!/bin/sh\necho "Error: detect: error parsing signature"\necho "Info: detect: 1 rule files processed. 0 rules successfully loaded, 10 rules failed, 0"\nexit 1\n' > "$d/bin/suricata" ;;
        absent) ;;
    esac
    chmod +x "$d/bin/"* 2>/dev/null
    PATH="$d/bin:$PATH" RULES_DIR="$d/rules" SURICATA_CONFIG="$d/etc/orionx.yaml" bash "$HOOK" > "$d/log" 2>&1
    echo $? > "$d/rc"
}

scenario good ok ok
if [[ "$(cat "$S/h_good/rc")" == 0 ]] && grep -q '^engine-loaded: 10$' "$S/h_good/rules/orionx-rules.provenance.txt" \
   && grep -qE '^baked-on: [0-9]{4}-' "$S/h_good/rules/orionx-rules.provenance.txt"; then
    pass "T14 good path: exit 0; baked-on + engine-loaded appended to the provenance from suricata -T"
else
    fail "T14 good path" "rc=$(cat "$S/h_good/rc") $(tail -5 "$S/h_good/log")"
fi
scenario missing missing ok
[[ "$(cat "$S/h_missing/rc")" == 1 ]] && grep -q 'make suricata-rules-refresh' "$S/h_missing/log" \
    && pass "T15 vendored rules missing: build fails (exit 1) and names the refresh command" || fail "T15 missing rules" "rc=$(cat "$S/h_missing/rc") $(tail -3 "$S/h_missing/log")"
scenario mismatch mismatch ok
[[ "$(cat "$S/h_mismatch/rc")" == 1 ]] && grep -q 'provenance says 9 signatures but suricata.rules has 10' "$S/h_mismatch/log" \
    && pass "T16 provenance/count mismatch: build fails naming both numbers" || fail "T16 mismatch" "rc=$(cat "$S/h_mismatch/rc") $(tail -3 "$S/h_mismatch/log")"
scenario rejected ok reject
[[ "$(cat "$S/h_rejected/rc")" == 1 ]] && grep -q 'does not accept the vendored rules' "$S/h_rejected/log" \
    && ! grep -q '^engine-loaded:' "$S/h_rejected/rules/orionx-rules.provenance.txt" \
    && pass "T17 engine rejects the file: build fails, no engine-loaded claim written" || fail "T17 engine reject" "rc=$(cat "$S/h_rejected/rc") $(tail -3 "$S/h_rejected/log")"
scenario noengine ok absent
[[ "$(cat "$S/h_noengine/rc")" == 1 ]] && grep -q 'suricata is not installed' "$S/h_noengine/log" \
    && pass "T18 no suricata in the chroot: build fails" || fail "T18 missing engine" "rc=$(cat "$S/h_noengine/rc")"
scenario nolic nolic ok
[[ "$(cat "$S/h_nolic/rc")" == 1 ]] && grep -q 'LICENSE-ET-Open.txt missing' "$S/h_nolic/log" \
    && pass "T19 license copy missing: build fails (the BSD notice must ship)" || fail "T19 license" "rc=$(cat "$S/h_nolic/rc")"
ok=1
for d in missing mismatch rejected noengine nolic; do
    grep -q '=== done ===' "$S/h_$d/log" && { ok=0; fail "T20 $d claims success" "'=== done ===' in log"; }
done
[[ $ok -eq 1 ]] && pass "T20 only the good path prints '=== done ==='"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
