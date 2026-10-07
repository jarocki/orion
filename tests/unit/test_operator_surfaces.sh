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
section "Menu entries: named for what they open, no retired names, icons resolve (UX-09/41/42/44, docs F21/F22)"
# ---------------------------------------------------------------------------
# Collect every .desktop the image ships in /usr/share/applications: the
# heredocs 0700 writes plus the static files in includes.chroot.
APPS_DIR="$WORK/applications"; mkdir -p "$APPS_DIR"
INC="$REPO_ROOT/iso/config/includes.chroot"
H0700="$HOOKS/live/0700-orionx-setup.hook.chroot"
while IFS= read -r target; do
    heredoc_body "$H0700" "$target" > "$APPS_DIR/$(basename "$target")" \
        || fail "extract $target" "heredoc not found"
done < <(grep -oE 'cat > /usr/share/applications/[A-Za-z0-9._-]+\.desktop' "$H0700" | awk '{print $3}')
cp "$INC"/usr/share/applications/*.desktop "$APPS_DIR/"
# orionx-mesh's own command list (it refuses to run without root, so the
# menu must use sudo and a real subcommand — a bare call prints an error).
MESH_CMDS="$(ORIONX_SKIP_ROOT_CHECK=1 bash "$REPO_ROOT/scripts/mesh/orionx-mesh" help 2>/dev/null \
    | awk '/^Commands:/{f=1;next} /^$/{f=0} f{print $1}' | tr '\n' ' ')"
DESKTOP_REPORT="$(python3 "$SCRIPT_DIR/lib/check_desktop_entries.py" "$APPS_DIR" "$INC" "$H0700" \
    "$REPO_ROOT/scripts/control_center/app.py" "$MESH_CMDS" "$INC/etc/xdg/autostart")"
if [[ "$DESKTOP_REPORT" == OK* ]]; then
    pass "menu + autostart entries: unique names, no retired names or jargon, Exec/Icon resolve (${DESKTOP_REPORT#OK })"
else
    while IFS= read -r l; do fail "menu entry" "${l#FAIL }"; done <<<"$DESKTOP_REPORT"
fi

# ---------------------------------------------------------------------------
section "Cockpit reachable from the desktop and the panel; widgets separated (UX-08, UX-31)"
# ---------------------------------------------------------------------------
H0100="$HOOKS/normal/0100-create-user.hook.chroot"
PANEL_XML="$WORK/xfce4-panel.xml"
if heredoc_body "$H0100" /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml > "$PANEL_XML"; then
    PANEL_REPORT="$(python3 "$SCRIPT_DIR/lib/check_panel.py" "$PANEL_XML" "$H0100" "$H0700" 2>&1)"
    if [[ "$PANEL_REPORT" == OK* ]]; then
        pass "${PANEL_REPORT#OK }"
    else
        while IFS= read -r l; do fail "panel/desktop" "${l#FAIL }"; done <<<"$PANEL_REPORT"
    fi
else
    fail "0100 panel heredoc" "xfce4-panel.xml heredoc not found"
fi
# Execute the derivation block 0700 uses, against a scratch root, and check
# that each derived copy is byte-identical to the menu entry and executable
# (xfdesktop shows non-executable .desktop files as plain files).
DERIVE="$(awk '/^# BEGIN derive-cockpit-surfaces/{f=1;next} /^# END derive-cockpit-surfaces/{f=0} f' "$H0700")"
if [[ -n "$DERIVE" ]]; then
    ROOTFS="$WORK/rootfs"; mkdir -p "$ROOTFS/usr/share/applications"
    cp "$APPS_DIR/orionx-cockpit.desktop" "$ROOTFS/usr/share/applications/"
    if ORIONX_CHROOT_PREFIX="$ROOTFS" bash -euo pipefail -c "$DERIVE" >/dev/null 2>&1; then
        for d in etc/skel/Desktop etc/skel/.config/xfce4/panel/launcher-11; do
            f="$ROOTFS/$d/orionx-cockpit.desktop"
            if cmp -s "$f" "$ROOTFS/usr/share/applications/orionx-cockpit.desktop" && [[ -x "$f" ]]; then
                pass "derived $d/orionx-cockpit.desktop == menu entry, executable"
            else
                fail "derived $d/orionx-cockpit.desktop" "missing, different from the menu entry, or not +x"
            fi
        done
    else
        fail "0700 derive-cockpit-surfaces block" "did not run cleanly against a scratch root"
    fi
else
    fail "0700 derive-cockpit-surfaces block" "no '# BEGIN derive-cockpit-surfaces' block in 0700"
fi

# ---------------------------------------------------------------------------
printf "\nResults: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
