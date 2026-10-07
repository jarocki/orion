#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_nucleotide_hook.sh — 0520: pinned templates commit, and a failed build
# ships nothing and says so (DEC-PHASE12-118; security F22, shell P2-2).
#
# Behavioural: runs the real hook with stub git / launcher / timeout on PATH
# and scratch OUT_DIR/CACHE_DIR. No network.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
HOOK="$REPO_ROOT/iso/config/hooks/live/0520-nucleotide-lookup.hook.chroot"
S="$REPO_ROOT/tmp/test_nuc_hook_$$"; trap 'rm -rf "$S"' EXIT
PIN="$(sed -n 's/^NUCLEI_TEMPLATES_COMMIT="\([0-9a-f]*\)".*/\1/p' "$HOOK")"

[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] && pass "templates pinned to a full 40-hex commit ($PIN)" || fail "pin" "'$PIN'"

# scenario <name> <git fetch rc> <rev-parse output> <launcher mode: ok|fail|empty>
scenario() {
    local d="$S/$1"; rm -rf "$d"; mkdir -p "$d/bin" "$d/out"
    cat > "$d/bin/git" <<EOF
#!/bin/sh
case "\$*" in
  *" fetch "*) echo "\$*" >> "$d/git.calls"; exit $2 ;;
  *"rev-parse HEAD"*) echo "$3"; exit 0 ;;
  init*) mkdir -p "\$3"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
    printf '#!/bin/sh\nshift; exec "$@"\n' > "$d/bin/timeout"
    case "$4" in
        ok)    printf '#!/bin/sh\nmkdir -p "%s/out/snort"; echo "{\\"x\\": 1}" > "%s/out/lookup.json"; echo r > "%s/out/snort/a.rules"\n' "$d" "$d" "$d" > "$d/launcher" ;;
        empty) printf '#!/bin/sh\n: > "%s/out/lookup.json"\n' "$d" > "$d/launcher" ;;
        fail)  printf '#!/bin/sh\necho "{}" > "%s/out/lookup.json"; exit 3\n' "$d" > "$d/launcher" ;;
    esac
    chmod +x "$d/bin/"* "$d/launcher"
    PATH="$d/bin:$PATH" LAUNCHER="$d/launcher" OUT_DIR="$d/out" CACHE_DIR="$d/cache" bash "$HOOK" > "$d/log" 2>&1
    echo $? > "$d/rc"
}

scenario good 0 "$PIN" ok
[[ "$(cat "$S/good/rc")" == 0 && -s "$S/good/out/lookup.json" ]] && pass "success: lookup.json shipped" || fail "success" "$(cat "$S/good/log")"
grep -qx "templates_commit=$PIN" "$S/good/out/BUILD_INFO" 2>/dev/null && pass "BUILD_INFO records the pinned commit" || fail "BUILD_INFO" "$(cat "$S/good/out/BUILD_INFO" 2>/dev/null)"
grep -q "origin $PIN" "$S/good/git.calls" && pass "fetch asks for exactly the pinned commit" || fail "fetch ref" "$(cat "$S/good/git.calls")"
[[ ! -e "$S/good/cache" ]] && pass "the template clone is not shipped" || fail "clone cleanup" "cache left"

for case in "fetchfail 1 $PIN ok" "wrongcommit 0 deadbeef ok" "launcherfail 0 $PIN fail" "emptylookup 0 $PIN empty"; do
    # shellcheck disable=SC2086
    set -- $case; scenario "$@"
    d="$S/$1"
    [[ "$(cat "$d/rc")" == 0 ]] && pass "$1: hook stays soft-fail (exit 0)" || fail "$1 exit" "$(cat "$d/rc")"
    [[ ! -e "$d/out/lookup.json" && ! -e "$d/out/BUILD_INFO" && ! -e "$d/out/snort" ]] \
        && pass "$1: no lookup.json, no snort rules, no BUILD_INFO claiming success" || fail "$1 outputs" "$(ls "$d/out")"
    grep -q "SOFT-FAIL: nucleotide lookup.json absent" "$d/log" && pass "$1: logs SOFT-FAIL" || fail "$1 log" "$(cat "$d/log")"
    grep -q "nucleotide lookup built" "$d/log" && fail "$1" "claimed 'lookup built'" || pass "$1: never claims the lookup was built"
done
[[ -z "$(ls "$S/fetchfail/out" 2>/dev/null)" ]] && pass "fetch failure: the build step never ran" || fail "fetch failure" "build ran"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
