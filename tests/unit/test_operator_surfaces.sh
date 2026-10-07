#!/usr/bin/env bash
# shellcheck shell=bash
# ---------------------------------------------------------------------------
# test_operator_surfaces.sh — what the operator reads on the deck is true.
#
# Every surface checked here is text the image hands the operator: the
# ~/Analysis README, menu entries, the desktop icons and panel, the MOTD and
# orionx-help, the rendered User Guide. The checks EXECUTE what those surfaces
# tell the operator to run (or the hook code that writes them) wherever that is
# possible on a dev host, and parse the generated files otherwise.
#
# @decision DEC-PHASE12-125
# @title Operator-facing text is tested by running it, not by grepping source
# @status accepted
# @rationale QA round 1 (docs.md F01) found the shipped ~/Analysis/README
#   telling operators to run `download-samples.sh --output`, a flag the script
#   rejects. A grep test cannot catch that class of drift; running the
#   documented command can. Heredoc bodies are extracted from the hooks with
#   the same delimiter rules bash uses, so the test sees exactly the bytes the
#   hook writes into the image.
#
# Usage: bash tests/unit/test_operator_surfaces.sh
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

HOOKS="$REPO_ROOT/iso/config/hooks"
H0200="$HOOKS/live/0200-copy-samples.hook.chroot"

mkdir -p "$REPO_ROOT/tmp"
WORK="$(mktemp -d "$REPO_ROOT/tmp/operator-surfaces.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# heredoc_body HOOK TARGET — print the body of `cat > TARGET << 'DELIM'` in HOOK.
# TARGET is matched literally against the redirect target (quotes stripped).
heredoc_body() {
    python3 - "$1" "$2" <<'PY'
import re, sys
hook, target = sys.argv[1], sys.argv[2]
lines = open(hook, encoding="utf-8").read().split("\n")
pat = re.compile(r'cat\s+>\s*"?([^"\s]+)"?\s*<<-?\s*[\'"]?(\w+)[\'"]?')
for i, line in enumerate(lines):
    m = pat.search(line)
    if m and m.group(1) == target:
        delim = m.group(2)
        out = []
        for body in lines[i + 1:]:
            if body.strip() == delim:
                print("\n".join(out))
                sys.exit(0)
            out.append(body)
sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
section "Analysis README: every download-samples.sh line it prints runs (docs F01)"
# ---------------------------------------------------------------------------
README_TXT="$WORK/analysis-readme.txt"
# shellcheck disable=SC2016  # the target is the literal string in the hook
if heredoc_body "$H0200" '${SKEL_ANALYSIS_DIR}/README.txt' > "$README_TXT"; then
    pass "0200 writes the ~/Analysis README from a heredoc"
else
    fail "0200 README heredoc" "could not locate cat > \${SKEL_ANALYSIS_DIR}/README.txt"
fi
n_cmds=0
while IFS= read -r line; do
    # strip leading whitespace, an optional sudo, and a trailing "— comment"
    cmd="$(sed -E 's/^[[:space:]]*//; s/[[:space:]]+—.*$//' <<<"$line")"
    if [[ "$cmd" == sudo\ * ]]; then
        fail "README runs download-samples.sh without sudo" "$cmd (it writes into the operator's home; sudo would leave root-owned files there)"
        cmd="${cmd#sudo }"
    fi
    n_cmds=$((n_cmds+1))
    # The operator's home is $WORK/home; --offline keeps the test off the network
    # and exercises the same argument parser the real run uses.
    cmd="${cmd//\~/$WORK/home}"
    read -r -a argv <<<"$cmd"
    if bash "$REPO_ROOT/scripts/${argv[0]}" "${argv[@]:1}" --offline >"$WORK/ds.log" 2>&1; then
        pass "README command parses and runs: ${line#"${line%%[![:space:]]*}"}"
    else
        fail "README command runs" "$cmd --offline → $(tail -3 "$WORK/ds.log" | tr '\n' ' ')"
    fi
done < <(grep -E 'download-samples\.sh' "$README_TXT")
if [[ $n_cmds -ge 1 ]]; then pass "README names download-samples.sh ($n_cmds line(s) executed)"
else fail "README names download-samples.sh" "no command found to execute"; fi

# ---------------------------------------------------------------------------
printf "\nResults: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
