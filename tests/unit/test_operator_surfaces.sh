#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2015  # `test && pass || fail`: pass() always returns 0
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
section "MOTD and orionx-help: one command list, every command exists (UX-32, docs F37/F38)"
# ---------------------------------------------------------------------------
CMDS="$INC/usr/share/orionx/orionx-commands.txt"
MOTD_SH="$WORK/10-orionx-welcome"; HELP_SH="$WORK/orionx-help.sh"
heredoc_body "$H0700" /etc/update-motd.d/10-orionx-welcome > "$MOTD_SH" || fail "MOTD heredoc" "not found in 0700"
heredoc_body "$H0700" /etc/profile.d/orionx-help.sh > "$HELP_SH" || fail "orionx-help heredoc" "not found in 0700"
if [[ -f "$CMDS" ]]; then
    pass "command list ships at /usr/share/orionx/orionx-commands.txt"
    # Every usage's first word (after sudo) must be something the image installs.
    CMD_REPORT="$(python3 - "$CMDS" "$HOOKS/live" "$INC" <<'PY'
import os, re, sys
cmds, hookdir, inc = sys.argv[1:4]
names = {"orionx-help"}  # the profile.d function itself
for h in os.listdir(hookdir):
    p = os.path.join(hookdir, h)
    if os.path.isfile(p):
        names |= set(re.findall(r'\["([^"]+)"\]="', open(p, encoding="utf-8", errors="replace").read()))
for d in ("usr/bin", "usr/local/bin"):
    if os.path.isdir(os.path.join(inc, d)):
        names |= set(os.listdir(os.path.join(inc, d)))
bad, n = [], 0
for line in open(cmds, encoding="utf-8"):
    if not line.strip() or line.startswith("#"):
        continue
    parts = [p.strip() for p in line.split(" :: ")]
    if len(parts) != 3 or parts[0] not in ("quick", "help"):
        bad.append(f"malformed line: {line.strip()}")
        continue
    words = parts[1].split()
    first = words[1] if words[0] == "sudo" else words[0]
    n += 1
    if first not in names:
        bad.append(f"{first} is not installed by any hook or includes.chroot")
print("\n".join(bad) if bad else f"OK {n}")
PY
)"
    if [[ "$CMD_REPORT" == OK* ]]; then pass "all ${CMD_REPORT#OK } listed commands are installed by the image"
    else while IFS= read -r l; do fail "command list" "$l"; done <<<"$CMD_REPORT"; fi
else
    fail "command list" "$CMDS missing — MOTD and orionx-help each carry their own hand-written copy"
fi
printf 'ISO_VERSION=v9.9.9-test\nGIT_HEAD_SHA=abc\n' > "$WORK/orionx-version"
MOTD_OUT="$(ORIONX_VERSION_FILE="$WORK/orionx-version" ORIONX_COMMANDS_FILE="$CMDS" bash "$MOTD_SH" 2>&1)"
HELP_OUT="$(ORIONX_VERSION_FILE="$WORK/orionx-version" ORIONX_COMMANDS_FILE="$CMDS" bash -c ". '$HELP_SH'; orionx-help" 2>&1)"
if grep -qx 'Orion-X Phoenix Edition v9.9.9-test' <<<"$MOTD_OUT"; then
    pass "MOTD prints the release from the version file, on its own line"
else
    fail "MOTD version line" "no line 'Orion-X Phoenix Edition v9.9.9-test' (wordmark backslash glued it?)"
fi
WIDE="$(printf '%s\n%s\n' "$MOTD_OUT" "$HELP_OUT" | python3 -c 'import sys; print(sum(len(l.rstrip("\n")) > 80 for l in sys.stdin))')"
[[ "$WIDE" == 0 ]] && pass "MOTD and orionx-help fit an 80-column console" \
    || fail "80 columns" "$WIDE line(s) wider than 80 characters"
NOVER_OUT="$(ORIONX_VERSION_FILE="$WORK/absent" ORIONX_COMMANDS_FILE="$CMDS" bash "$MOTD_SH" 2>&1)"
if [[ "$NOVER_OUT" == *"unknown-build"* && "$NOVER_OUT" != *"v2.0.0"* ]]; then
    pass "MOTD without a version file says unknown-build, not a plausible old release"
else
    fail "MOTD fallback" "$(head -6 <<<"$NOVER_OUT" | tail -1)"
fi
for want in "User_Guide.html" "orionx-cockpit" "orionx-osint" "orionx-diag"; do
    [[ "$MOTD_OUT" == *"$want"* ]] && pass "MOTD mentions $want" || fail "MOTD mentions $want" "missing"
done
missing=0
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    usage="$(awk -F' :: ' '{print $2}' <<<"$line")"
    [[ "$HELP_OUT" == *"$usage"* ]] || { missing=$((missing+1)); fail "orionx-help lists" "$usage"; }
done < "$CMDS"
[[ $missing -eq 0 ]] && pass "orionx-help prints every command in the list"
[[ "$HELP_OUT" == *"User_Guide.html"* ]] && pass "orionx-help points at the rendered guide" \
    || fail "orionx-help docs pointer" "does not name User_Guide.html"
# /etc/orionx-version fallback when the build env is missing (F38): evaluate
# the hook's heredoc with ORIONX_VERSION unset.
VERSION_BODY="$(awk '/^cat > \/etc\/orionx-version << VERSION_EOF/{f=1;next} /^VERSION_EOF$/{f=0} f' "$H0700")"
FALLBACK="$(env -u ORIONX_VERSION -u ORIONX_GIT_SHA bash -c "cat <<VERSION_EOF
$VERSION_BODY
VERSION_EOF" | grep '^ISO_VERSION=')"
[[ "$FALLBACK" == "ISO_VERSION=unknown-build" ]] && pass "/etc/orionx-version fallback is unknown-build" \
    || fail "/etc/orionx-version fallback" "$FALLBACK (a stale literal reads like a real release)"

# ---------------------------------------------------------------------------
section "Rendered User Guide names the release the image actually is (UX-07, UX-33)"
# ---------------------------------------------------------------------------
H0810="$HOOKS/live/0810-render-user-guide.hook.chroot"
GUIDE="$REPO_ROOT/docs/User_Guide.md"
n_slots="$(grep -o '<!--orionx:release-->[^<]*<!--/orionx:release-->' "$GUIDE" | wc -l | tr -d ' ')"
[[ "$n_slots" -ge 2 ]] && pass "User Guide marks its release string in $n_slots places (header + footer)" \
    || fail "User Guide release slots" "found $n_slots <!--orionx:release--> slots; the header and footer need one each"
cp "$GUIDE" "$WORK/User_Guide.md"
printf 'ISO_VERSION=v9.9.9-test\nGIT_HEAD_SHA=abc\n' > "$WORK/orionx-version"
if ORIONX_GUIDE_MD="$WORK/User_Guide.md" ORIONX_GUIDE_HTML="$WORK/User_Guide.html" \
   ORIONX_VERSION_FILE="$WORK/orionx-version" bash "$H0810" > "$WORK/0810.log" 2>&1; then
    pass "0810 renders against a scratch copy"
else
    fail "0810 run" "$(tail -3 "$WORK/0810.log" | tr '\n' ' ')"
fi
RENDERED="$(python3 - "$WORK/User_Guide.html" <<'PY'
import re, sys
h = open(sys.argv[1], encoding="utf-8").read()
slots = re.findall(r"<!--orionx:release-->([^<]*)<!--/orionx:release-->", h)
title = re.search(r"<title>([^<]*)</title>", h).group(1)
print(f"{len(slots)}|{','.join(sorted(set(slots)))}|{title}")
PY
)"
IFS='|' read -r r_n r_vals r_title <<<"$RENDERED"
if [[ "$r_n" -ge 2 && "$r_vals" == "v9.9.9-test" ]]; then
    pass "every release slot in the HTML carries the baked ISO_VERSION ($r_n slots)"
else
    fail "HTML release slots" "slots=$r_n values=$r_vals (want v9.9.9-test from the version file)"
fi
[[ "$r_title" == *"v9.9.9-test"* ]] && pass "HTML <title> names the release ($r_title)" \
    || fail "HTML title" "$r_title"
cmp -s "$GUIDE" "$WORK/User_Guide.md" && pass "the baked .md is left byte-identical to the repo (release diff gate)" \
    || fail "0810 modified the .md" "the release check diffs the baked .md against the repository"

# ---------------------------------------------------------------------------
section "Operator docs: current release, current UI, links resolve (docs F04-F07/F11-F20/F27-F34, UX-07, release-tests F-07/F-09)"
# ---------------------------------------------------------------------------
# The release this branch documents. When it changes, change it here and in
# README.md / the guide's release slots together.
RELEASE="v3.0.0"
DOCS_REPORT="$(python3 "$SCRIPT_DIR/lib/check_docs_current.py" "$REPO_ROOT" "$RELEASE")"
if [[ "$DOCS_REPORT" == OK* ]]; then pass "${DOCS_REPORT#OK }"
else while IFS= read -r l; do fail "docs" "${l#FAIL }"; done <<<"$DOCS_REPORT"; fi
for doc in docs/User_Guide.md README.md docs/SUPPORT.md docs/orionx-imager.md docs/orionx-diag.md; do
    TOC_REPORT="$(python3 "$SCRIPT_DIR/lib/check_toc_anchors.py" "$REPO_ROOT/$doc")"
    if [[ "$TOC_REPORT" == OK* ]]; then pass "$doc: ${TOC_REPORT#OK } in-page links resolve (GitHub + rendered HTML)"
    else while IFS= read -r l; do fail "$doc anchors" "${l#FAIL }"; done <<<"$TOC_REPORT"; fi
done
# Every docs/images file the image ships is referenced by a doc (docs F23, UX-38):
# build-iso.sh rsyncs docs/ into /usr/share/doc/orionx/ wholesale.
orphans=0
for img in "$REPO_ROOT"/docs/images/*; do
    b="$(basename "$img")"
    if ! grep -rqF "images/$b" "$REPO_ROOT/README.md" "$REPO_ROOT/docs"/*.md; then
        orphans=$((orphans+1)); fail "orphaned image ships in the image" "docs/images/$b is referenced by no doc"
    fi
done
[[ $orphans -eq 0 ]] && pass "every docs/images file is referenced by a doc"

# ---------------------------------------------------------------------------
printf "\nResults: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
