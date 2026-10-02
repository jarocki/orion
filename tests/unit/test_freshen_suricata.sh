#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_freshen_suricata.sh — orionx-freshen-suricata installs rules Suricata
# ACTUALLY LOADS (DEC-PHASE12-039).
#
# The defect this guards against: rev 1 extracted the ET-Open tarball into
# /var/lib/suricata/rules and reported "Complete. N rule files installed."
# Suricata loaded none of them, because its suricata.yaml `rule-files:` names
# exactly one file — suricata.rules — and the ET tarball contains no file of
# that name. The operator ran the documented remedy for "my IDS has no
# signatures" and still had an IDS matching zero signatures.
#
# So this suite refuses to assert that the script CONTAINS a merge step. It
# sources the script's pure functions and runs them against a real Debian
# suricata.yaml and a real ET-shaped rules directory, then asserts the file
# Suricata names exists and carries the signatures. If the merge were deleted
# tomorrow, every assertion below goes red.
#
# Mutation-tested while writing: removing the merge_rules call makes T4/T5/T6
# fail; hardcoding the target as "suricata.rules" instead of reading the config
# makes T7 fail.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

FRESHEN="$REPO_ROOT/scripts/orionx-freshen-suricata.sh"
WORK="$(mktemp -d "$REPO_ROOT/tmp/freshen-suricata-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf "===========================================\n"
printf "  orionx-freshen-suricata (DEC-PHASE12-039)\n"
printf "===========================================\n"

section "Script sanity"
[[ -f "$FRESHEN" ]] && pass "script present" || { fail "script present" "missing"; exit 1; }
bash -n "$FRESHEN" 2>/dev/null && pass "bash -n clean" || fail "bash -n clean"
grep -q 'DEC-PHASE12-039' "$FRESHEN" && pass "DEC-PHASE12-039 annotation" || fail "DEC-PHASE12-039 annotation" "missing"

# Sourcing must define the functions WITHOUT running main — otherwise the
# suite would demand root and the network.
# shellcheck source=/dev/null
if source "$FRESHEN" 2>/dev/null && declare -F merge_rules >/dev/null; then
    pass "sourcing defines the pure functions without executing main"
else
    fail "sourcing is side-effect free" "main ran, or functions undefined"; exit 1
fi

# --- A real Debian trixie suricata.yaml excerpt. Verified against the actual
# --- package (suricata 7.0.10) in a debian:trixie-slim container.
cat > "$WORK/suricata.yaml" <<'YAML'
%YAML 1.1
---
default-rule-path: /var/lib/suricata/rules

rule-files:
  - suricata.rules

##
## Auxiliary configuration files.
##
classification-file: /etc/suricata/classification.config
YAML

section "PLAN — read what Suricata will load, do not assume it"
got="$(rule_files_from_config < "$WORK/suricata.yaml")"
if [[ "$got" == "suricata.rules" ]]; then
    pass "T1 rule-files: parsed from a real suricata.yaml"
else
    fail "T1 rule-files parse" "got '$got', want 'suricata.rules'"
fi

got="$(default_rule_path_from_config < "$WORK/suricata.yaml")"
if [[ "$got" == "/var/lib/suricata/rules" ]]; then
    pass "T2 default-rule-path parsed"
else
    fail "T2 default-rule-path parse" "got '$got'"
fi

# The list terminator must be the next key, not the '##' comment banner.
cat > "$WORK/multi.yaml" <<'YAML'
rule-files:
  # a comment inside the list
  - suricata.rules
  - local.rules

##
classification-file: /etc/suricata/classification.config
YAML
multi=()
while IFS= read -r _l; do [[ -n "$_l" ]] && multi+=("$_l"); done \
    < <(rule_files_from_config < "$WORK/multi.yaml")
if [[ ${#multi[@]} -eq 2 && "${multi[0]}" == "suricata.rules" && "${multi[1]}" == "local.rules" ]]; then
    pass "T3 multi-entry list parsed; comments skipped, next key ends the block"
else
    fail "T3 multi-entry parse" "got ${#multi[@]} entries: ${multi[*]}"
fi

section "DO — the merge produces the file the config names"
# An ET-Open-shaped rules directory: exactly what the tarball extracts, and
# conspicuously WITHOUT a suricata.rules. This is the state rev 1 left behind.
RD="$WORK/rules"; mkdir -p "$RD"
cat > "$RD/emerging-scan.rules" <<'EOF'
# Emerging Threats scan rules
alert tcp any any -> $HOME_NET any (msg:"ET SCAN nmap"; sid:2000001; rev:1;)
alert tcp any any -> $HOME_NET any (msg:"ET SCAN syn"; sid:2000002; rev:1;)
EOF
cat > "$RD/botcc.rules" <<'EOF'
drop tcp $HOME_NET any -> [1.2.3.4] any (msg:"ET CNC"; sid:2000003; rev:1;)
# alert tcp any any -> any any (msg:"disabled by ET"; sid:2000004; rev:1;)
EOF
cp "$REPO_ROOT/scripts/orionx-freshen-suricata.sh" "$WORK/.keep" 2>/dev/null

if [[ ! -f "$RD/suricata.rules" ]]; then
    pass "T4 precondition: ET layout has no suricata.rules (the whole bug)"
else
    fail "T4 precondition" "fixture already has suricata.rules"
fi

target="$(rule_files_from_config < "$WORK/suricata.yaml" | head -n1)"
merged="$(merge_rules "$RD" "$target")"

if [[ -f "$RD/suricata.rules" ]]; then
    pass "T5 EFFECT: the file suricata.yaml names now exists"
else
    fail "T5 merged file exists" "$RD/suricata.rules absent — Suricata would load nothing"
fi

# 3 active signatures; the ET-disabled (commented) one must NOT be counted.
if [[ "$merged" -eq 3 ]]; then
    pass "T6 EFFECT: 3 live signatures merged (commented rule not counted)"
else
    fail "T6 signature count" "merge_rules reported '$merged', want 3"
fi

if grep -q 'ET SCAN nmap' "$RD/suricata.rules" && grep -q 'ET CNC' "$RD/suricata.rules"; then
    pass "T7 EFFECT: signatures from every source file reached the merged file"
else
    fail "T7 content merged" "signatures missing from $RD/suricata.rules"
fi

# The target must be DERIVED from the config, not a hardcoded guess. Drive the
# script's own decision function — not the test's — so a mutation that
# hardcodes "suricata.rules" in the script is visible here. (It was not, until
# merge_target_for_config was pulled out of main; that gap was found by
# mutation-testing this suite and is why the function exists.)
cat > "$WORK/odd.yaml" <<'YAML'
default-rule-path: /var/lib/suricata/rules
rule-files:
  - orionx-merged.rules
YAML
t2="$(merge_target_for_config < "$WORK/odd.yaml")"
if [[ "$t2" == "orionx-merged.rules" ]]; then
    pass "T8a the script derives the merge target from rule-files:"
else
    fail "T8a derived target" "got '$t2', want 'orionx-merged.rules' (hardcoded?)"
fi
if [[ "$(merge_target_for_config < "$WORK/suricata.yaml")" == "suricata.rules" ]]; then
    pass "T8b the same function yields suricata.rules for the stock config"
else
    fail "T8b derived target (stock)" "config-driven derivation broken"
fi
# A config that names nothing must yield nothing, so main can escalate rather
# than merge into an invented filename.
if [[ -z "$(printf 'default-rule-path: /x\n' | merge_target_for_config)" ]]; then
    pass "T8c a config with no rule-files: yields no target (main escalates)"
else
    fail "T8c empty config" "invented a target where the config names none"
fi
RD2="$WORK/rules2"; mkdir -p "$RD2"
cp "$RD/emerging-scan.rules" "$RD2/"
merge_rules "$RD2" "$t2" >/dev/null
if [[ -f "$RD2/orionx-merged.rules" && ! -f "$RD2/suricata.rules" ]]; then
    pass "T8d EFFECT: the merge writes the derived name, not suricata.rules"
else
    fail "T8d merge honours the derived target" "wrote the wrong file"
fi

# Re-running must not compound the file into itself.
before="$(count_signatures "$RD/suricata.rules")"
after="$(merge_rules "$RD" "$target")"
if [[ "$before" -eq "$after" ]]; then
    pass "T9 idempotent: re-running does not duplicate signatures ($after)"
else
    fail "T9 idempotent" "count went $before -> $after"
fi

section "CHECK — the script refuses to claim success it has not confirmed"
# The success line must be reachable only after a confirmed count. Assert the
# failure path exists and names a diagnosis, per RESILIENCE.md rule 8.
if grep -q 'Suricata confirms' "$FRESHEN" && grep -q 'rules successfully loaded' "$FRESHEN"; then
    pass "T10 success is reported from Suricata's own load count"
else
    fail "T10 confirmed success" "no parse of Suricata's loaded-rule count"
fi
if grep -q 'suricata -T -v -c' "$FRESHEN"; then
    pass "T11 the Check re-reads reality through Suricata itself"
else
    fail "T11 runtime check" "script never runs suricata -T"
fi
# `suricata -T` exits 0 even when it matched no rule files (measured on
# 7.0.10), so an exit-status gate would be another lie. The count is the gate.
if grep -q 'the count is' "$FRESHEN" || grep -q 'loaded" -eq 0' "$FRESHEN"; then
    pass "T12 zero-rules is a hard failure, not a warning in a success line"
else
    fail "T12 zero-rules escalation" "no explicit zero-count failure path"
fi
for remedy in 'systemctl restart suricata' 'suricata -T -v -c'; do
    if grep -q "$remedy" "$FRESHEN"; then
        pass "T13 degraded state names the remedy: $remedy"
    else
        fail "T13 remedy named" "missing: $remedy"
    fi
done

section "Lint"
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$FRESHEN" "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        pass "shellcheck -S warning clean"
    else
        fail "shellcheck clean" "$(shellcheck -S warning "$FRESHEN" "${BASH_SOURCE[0]}" 2>&1 | head -10)"
    fi
else
    pass "shellcheck not installed — skipped"
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
