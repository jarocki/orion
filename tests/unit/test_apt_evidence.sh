#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_apt_evidence.sh — apt on the live overlay (#121, DEC-PHASE13-051)
#
# Two contracts, both EXECUTED against stubs, not just grepped:
#   1. /opt/orionx/optional/apt-evidence.sh is read-only: every apt-get call it
#      makes is a simulation (-s), it never runs apt-get update, and it fails
#      loudly (exit 1, named path, sudo hint) when an input exists but cannot
#      be read. The bundle it writes holds the files the issue asks for.
#   2. The `update` shell command seeded by 0100-create-user.hook.chroot
#      refreshes the lists and SIMULATES the upgrade; it never upgrades.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

CHROOT="$REPO_ROOT/iso/config/includes.chroot"
SCRIPT="$CHROOT/opt/orionx/optional/apt-evidence.sh"
HOOK="$REPO_ROOT/iso/config/hooks/normal/0100-create-user.hook.chroot"
GUIDE="$REPO_ROOT/docs/User_Guide.md"
mkdir -p "$REPO_ROOT/tmp"
WORK="$(mktemp -d "$REPO_ROOT/tmp/apt-evidence.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

section "apt-evidence.sh: structure"
[[ -f "$SCRIPT" ]] && pass "apt-evidence.sh present" || { fail "apt-evidence.sh present" "missing"; exit 1; }
[[ -x "$SCRIPT" ]] && pass "executable" || fail "executable" "chmod +x"
bash -n "$SCRIPT" && pass "parses (bash -n)" || fail "bash -n"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$SCRIPT" >/dev/null 2>&1 && pass "shellcheck clean" || fail "shellcheck" "$(shellcheck "$SCRIPT" 2>&1 | tail -5)"
fi
git -C "$REPO_ROOT" ls-files --error-unmatch "iso/config/includes.chroot/opt/orionx/optional/apt-evidence.sh" >/dev/null 2>&1 \
    && pass "tracked by git" || fail "UNTRACKED" "git add iso/config/includes.chroot/opt/orionx/optional/apt-evidence.sh"
grep -q 'DEC-PHASE13-051' "$SCRIPT" && pass "names DEC-PHASE13-051" || fail "decision ref"
grep -q '#121' "$SCRIPT" && pass "names issue #121" || fail "issue ref"
# Static read-only gate: an apt-get in command position (line start, after
# ; & | ( or as run_cmd's command, optionally via sudo) must carry -s. The
# words "apt-get update" appear only inside messages shown to the operator.
offenders="$(grep -nE '(^[0-9]+:|[;&|(]|run_cmd "[^"]*")[[:space:]]*(sudo[[:space:]]+)?apt-get' "$SCRIPT" \
    | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'apt-get -s' || true)"
[[ -z "$offenders" ]] && pass "every apt-get command line is a simulation (-s)" || fail "non-simulated apt-get" "$offenders"
! grep -qE '^[^#]*dpkg[[:space:]]+(-i|--install|-r|--remove|-P|--purge|--configure)' "$SCRIPT" \
    && pass "no writing dpkg verb" || fail "dpkg writes"

section "apt-evidence.sh: executed against stubs (every call recorded)"
ROOT="$WORK/root"; BIN="$WORK/bin"; OUT="$WORK/out"
mkdir -p "$ROOT/var/log/apt" "$ROOT/var/lib/dpkg" "$ROOT/var/lib/apt/lists" "$ROOT/etc/apt/sources.list.d" "$ROOT/proc" "$BIN" "$OUT"
for t in apt-get apt-cache apt-mark dpkg df findmnt free timedatectl uptime; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "${STUB_CALLS:?}"\necho "stub %s $*"\n' "$t" "$t" > "$BIN/$t"
done
# dpkg -l must yield at least one non-ii row for the filter to be observable.
cat > "$BIN/dpkg" <<'STUB'
#!/usr/bin/env bash
echo "dpkg $*" >> "${STUB_CALLS:?}"
case "$1" in
  -l) printf 'ii  bash  5.2  amd64  shell\nrc  light-locker  1.9  amd64  leftover\n' ;;
  --audit) echo "" ;;
  *) echo "stub dpkg $*" ;;
esac
STUB
chmod +x "$BIN"/*
printf 'Start-Date: 2026-10-26  15:00:01\nCommandline: apt-get install brightnessctl\nInstall: brightnessctl:amd64 (0.5.1-3)\nEnd-Date: 2026-10-26  15:00:04\n' > "$ROOT/var/log/apt/history.log"
echo "Log started: 2026-10-26" > "$ROOT/var/log/apt/term.log"
echo "2026-10-26 15:00:02 install brightnessctl:amd64" > "$ROOT/var/log/dpkg.log"
echo "Package: bash" > "$ROOT/var/lib/dpkg/status"
echo "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" > "$ROOT/etc/apt/sources.list"
echo "ISO_VERSION=v3.1.4" > "$ROOT/etc/orionx-version"
echo "boot=live components persistence" > "$ROOT/proc/cmdline"

run_ev() {  # run_ev <root> <outdir> [args...]
    local root="$1" out="$2"; shift 2
    STUB_CALLS="$WORK/calls" ORIONX_APT_EVIDENCE_ROOT="$root" ORIONX_APT_EVIDENCE_DIR="$out" \
        PATH="$BIN:$PATH" bash "$SCRIPT" "$@"
}
: > "$WORK/calls"
run_ev "$ROOT" "$OUT" > "$WORK/stdout" 2> "$WORK/stderr"; rc=$?
[[ $rc -eq 0 ]] && pass "exits 0 with every input present" || fail "exit code" "rc=$rc $(tail -3 "$WORK/stderr" | tr '\n' ' ')"
TARBALL="$(tail -1 "$WORK/stdout")"
[[ "$TARBALL" == "$OUT"/orionx-apt-evidence-*.tar.gz && -f "$TARBALL" ]] && pass "last stdout line is the tarball path, and it exists" || fail "tarball path" "$TARBALL"
if grep -E '^apt-get' "$WORK/calls" | grep -vqE '^apt-get -s '; then
    fail "every recorded apt-get call is a simulation" "$(grep -E '^apt-get' "$WORK/calls" | grep -vE '^apt-get -s ')"
else
    pass "every recorded apt-get call is a simulation ($(grep -cE '^apt-get -s ' "$WORK/calls") calls)"
fi
grep -qE '^apt-get -s install brightnessctl$' "$WORK/calls" && pass "simulates apt-get install brightnessctl" || fail "probe simulation"
grep -qE '^apt-get -s upgrade$' "$WORK/calls" && pass "simulates apt-get upgrade (what the old alias would have done)" || fail "upgrade simulation"
! grep -qE '^apt-get (update|install|remove|purge|upgrade|autoremove)' "$WORK/calls" && pass "no apt-get update/install/remove/purge/upgrade without -s" || fail "mutating call recorded"
grep -qE '^apt-cache policy$' "$WORK/calls" && pass "apt-cache policy" || fail "apt-cache policy"
grep -qE '^apt-mark showmanual$' "$WORK/calls" && pass "apt-mark showmanual" || fail "apt-mark"
grep -qE '^dpkg --audit$' "$WORK/calls" && pass "dpkg --audit" || fail "dpkg --audit"
grep -qE '^df -h / /run/live/overlay' "$WORK/calls" && pass "df on / and the live overlay" || fail "df"
grep -qE '^timedatectl ?$' "$WORK/calls" && pass "timedatectl (the #148 clock suspect)" || fail "timedatectl"
mkdir -p "$WORK/x" && tar -C "$WORK/x" -xzf "$TARBALL"
B="$(find "$WORK/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
for want in files/var/log/apt/history.log files/var/log/apt/term.log files/var/log/dpkg.log files/etc/orionx-version \
            files/etc/apt/sources.list apt-get-s-install-brightnessctl.txt apt-get-s-upgrade.txt apt-cache-policy.txt \
            dpkg-l-not-ii.txt dpkg-audit.txt apt-mark-showmanual.txt apt-mark-showmanual-count.txt df-h.txt \
            timedatectl.txt proc-cmdline.txt apt-lists-listing.txt MISSING.txt README.txt; do
    [[ -f "$B/$want" ]] && pass "bundle has $want" || fail "bundle missing $want"
done
cmp -s "$B/files/var/log/apt/history.log" "$ROOT/var/log/apt/history.log" && pass "history.log copied byte-identical" || fail "history.log copy"
grep -q '^rc  light-locker' "$B/dpkg-l-not-ii.txt" && ! grep -q '^ii  bash' "$B/dpkg-l-not-ii.txt" \
    && pass "dpkg-l-not-ii.txt keeps the rc row and drops the ii row" || fail "not-ii filter"
grep -q '\[exit 0\]' "$B/apt-get-s-upgrade.txt" && pass "each capture records the command's exit code" || fail "exit code capture"
[[ ! -s "$B/MISSING.txt" ]] && pass "MISSING.txt empty when nothing is missing" || fail "MISSING.txt" "$(cat "$B/MISSING.txt")"
grep -q 'no package lists' "$WORK/stderr" && pass "empty /var/lib/apt/lists is shouted (--apt-indices false) with the apt-get update hint" || fail "empty lists warning"

section "apt-evidence.sh: failure modes are loud"
ROOT2="$WORK/root2"; cp -R "$ROOT" "$ROOT2"; rm -f "$ROOT2/var/log/apt/history.log" "$ROOT2/var/log/apt/term.log"
: > "$WORK/calls"
run_ev "$ROOT2" "$OUT" > "$WORK/stdout2" 2> "$WORK/stderr2"; rc=$?
[[ $rc -eq 0 ]] && pass "absent history/term logs (fresh boot) still produce a bundle" || fail "fresh-boot rc" "rc=$rc"
grep -q 'MISSING: /var/log/apt/history.log' "$WORK/stderr2" && pass "absent history.log named on stderr" || fail "missing named" "$(cat "$WORK/stderr2")"
T2="$(tail -1 "$WORK/stdout2")"; mkdir -p "$WORK/x2" && tar -C "$WORK/x2" -xzf "$T2"
grep -q '^/var/log/apt/term.log$' "$(find "$WORK/x2" -name MISSING.txt)" && pass "MISSING.txt lists term.log" || fail "MISSING.txt content"
if [[ $EUID -ne 0 ]]; then
    ROOT3="$WORK/root3"; cp -R "$ROOT" "$ROOT3"; chmod 000 "$ROOT3/var/log/apt/term.log"
    run_ev "$ROOT3" "$OUT" > "$WORK/stdout3" 2> "$WORK/stderr3"; rc=$?
    [[ $rc -eq 1 ]] && pass "an unreadable term.log is a hard failure (exit 1), not a silent skip" || fail "unreadable rc" "rc=$rc"
    grep -q 'term.log' "$WORK/stderr3" && grep -q 'sudo /opt/orionx/optional/apt-evidence.sh' "$WORK/stderr3" \
        && pass "names the unreadable file and the sudo fix" || fail "unreadable message" "$(cat "$WORK/stderr3")"
    [[ ! -s "$WORK/stdout3" || "$(tail -1 "$WORK/stdout3")" != *.tar.gz ]] && pass "no tarball path printed on failure" || fail "tarball on failure"
    chmod 644 "$ROOT3/var/log/apt/term.log"
fi
run_ev "$ROOT" "$OUT" --bogus > /dev/null 2> "$WORK/stderr4"; rc=$?
[[ $rc -eq 2 ]] && grep -q 'unknown argument' "$WORK/stderr4" && pass "unknown argument exits 2 with usage" || fail "arg error" "rc=$rc"
ROOT5="$WORK/root5"; mkdir -p "$ROOT5/etc"
run_ev "$ROOT5" "$OUT" > /dev/null 2> "$WORK/stderr5"; rc=$?
[[ $rc -eq 1 ]] && grep -q 'etc/apt is missing' "$WORK/stderr5" && pass "no /etc/apt: exit 1, named" || fail "no etc/apt" "rc=$rc"

section "0100-create-user: the 'update' command never upgrades the live overlay (DEC-PHASE13-051)"
grep -q '@decision DEC-PHASE13-051' "$HOOK" && pass "hook carries DEC-PHASE13-051" || fail "decision block"
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qE "alias update=.*apt-get upgrade"; then
    fail "old alias present" "alias update='... && sudo apt-get upgrade' is still seeded"
else
    pass "the old alias (update && upgrade) is gone from the seeded .bashrc"
fi
UPDATE_FN="$(awk '/^update\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HOOK")"
[[ -n "$UPDATE_FN" ]] && pass "update() is defined in the .bashrc heredoc" || fail "update() missing"
# The heredoc is unquoted (`<< EOF`), so `$` reaches .bashrc only when written `\$`.
# Resolve the escapes the way the hook's shell would, then execute with stubs.
printf '%s\n' "$UPDATE_FN" | sed 's/\\\$/$/g' > "$WORK/update.sh"
bash -n "$WORK/update.sh" && pass "update() parses after heredoc unescaping" || fail "update() syntax" "$(bash -n "$WORK/update.sh" 2>&1)"
mkdir -p "$WORK/ubin"
printf '#!/usr/bin/env bash\necho "sudo $*" >> "${STUB_CALLS:?}"\n"$@"\n' > "$WORK/ubin/sudo"
printf '#!/usr/bin/env bash\necho "apt-get $*" >> "${STUB_CALLS:?}"\necho "stub apt-get $*"\n' > "$WORK/ubin/apt-get"
chmod +x "$WORK/ubin"/*
: > "$WORK/calls"
U_OUT="$(STUB_CALLS="$WORK/calls" PATH="$WORK/ubin:$PATH" bash -c "source '$WORK/update.sh'; update" 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && pass "update runs (rc=0)" || fail "update rc" "rc=$rc $U_OUT"
grep -qE '^sudo apt-get update$' "$WORK/calls" && pass "update refreshes the lists via sudo apt-get update" || fail "no apt-get update" "$(cat "$WORK/calls")"
grep -qE '^apt-get -s upgrade$' "$WORK/calls" && pass "update SIMULATES the upgrade (apt-get -s upgrade)" || fail "no simulation" "$(cat "$WORK/calls")"
! grep -qE '^(sudo )?apt-get (upgrade|dist-upgrade|full-upgrade)' "$WORK/calls" && pass "update never runs a real upgrade" || fail "real upgrade ran" "$(cat "$WORK/calls")"
[[ "$U_OUT" == *overlay* && "$U_OUT" == *"sudo apt-get upgrade"* ]] && pass "tells the operator about the live overlay and how to upgrade deliberately" || fail "update guidance" "$U_OUT"
[[ "$U_OUT" == *"apt-evidence.sh"* && "$U_OUT" == *"/opt/orionx/optional/install-"* ]] && pass "points at the optional installers and apt-evidence.sh" || fail "pointers" "$U_OUT"
# A failed refresh stops there: no simulation against stale lists.
printf '#!/usr/bin/env bash\necho "apt-get $*" >> "${STUB_CALLS:?}"\n[ "$1" = update ] && exit 100\necho "stub apt-get $*"\n' > "$WORK/ubin/apt-get"
: > "$WORK/calls"
STUB_CALLS="$WORK/calls" PATH="$WORK/ubin:$PATH" bash -c "source '$WORK/update.sh'; update" > /dev/null 2>&1; rc=$?
[[ $rc -eq 100 ]] && ! grep -q -- '-s upgrade' "$WORK/calls" && pass "a failed apt-get update returns its code and skips the simulation" || fail "failed update handling" "rc=$rc $(cat "$WORK/calls")"

section "User Guide reconciles with DEC-PHASE11-011"
grep -q 'apt-evidence.sh' "$GUIDE" && pass "User Guide names apt-evidence.sh" || fail "guide: apt-evidence.sh"
grep -q 'orionx_apt_install' "$GUIDE" && pass "User Guide names orionx_apt_install" || fail "guide: orionx_apt_install"
grep -qi 'brightnessctl' "$GUIDE" && grep -q 'xfce4-power-manager' "$GUIDE" && pass "User Guide says brightness is xfce4-power-manager's, brightnessctl unnecessary" || fail "guide: brightness note"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
