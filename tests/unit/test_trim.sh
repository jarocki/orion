#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_trim.sh — zero-regret image trim (DEC-PHASE12-015) + purge safety
# (DEC-PHASE12-017)
#
# Locks the trim decisions taken from the trixie-dev6 size budget, and — after
# dev8 shipped without a window manager — the purge-safety contract: purges are
# simulated, protected packages are never removed, `cpp` is not a target, and a
# missing critical package fails the build. The hook's library functions are
# exercised with canned `apt-get -s` output (ORIONX_TRIM_LIB_ONLY=1).
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

TRIM="$REPO_ROOT/iso/config/hooks/live/0900-trim.hook.chroot"
EXT="$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot"
PKGS="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
SCRATCH="$REPO_ROOT/tmp/test_trim_$$"; mkdir -p "$SCRATCH"; trap 'rm -rf "$SCRATCH"' EXIT

purge_list() { sed -n '/^PURGE_WANTED=(/,/^)/p' "$TRIM" | grep -v '^[[:space:]]*#' | tr ' ' '\n' | grep -v -E '^(PURGE_WANTED=\(|\))$' | grep -v '^$'; }

section "0500: ollama GPU backends + zeek-core"
grep -q 'for gpu in cuda_v12 cuda_v13 vulkan' "$EXT" && pass "0500 removes ollama cuda_v12/cuda_v13/vulkan after extract" || fail "GPU prune" "missing"
grep -q 'libggml-cpu-\*.so' "$EXT" && pass "0500 verifies CPU backends survive the prune" || fail "CPU backend check" "missing"
grep -qE 'apt-get install -y --no-install-recommends zeek-core' "$EXT" && pass "0500 installs zeek-core (not the zeek metapackage)" || fail "zeek-core" "still installing 'zeek'"
if grep -qE 'apt-get install -y zeek$' "$EXT"; then fail "zeek metapackage gone" "'apt-get install -y zeek' still present"; else pass "zeek metapackage install line gone"; fi
grep -q "DEC-PHASE12-015" "$EXT" && pass "DEC-PHASE12-015 annotated in 0500" || fail "annotation 0500" "missing"

section "0900 trim hook: purge list"
[[ -x "$TRIM" ]] && pass "0900-trim hook present + executable" || fail "0900 hook" "missing/not +x"
bash -n "$TRIM" 2>/dev/null && pass "0900 hook bash syntax" || fail "0900 syntax" "bash -n failed"
for p in zeek-zkg zeek-spicy-dev zeek-btest-data python3-scipy python3-matplotlib python3-pyqtgraph ukui-polkit mesa-vulkan-drivers firmware-nvidia-graphics unhide.rb gcc-14 g++-14; do
    purge_list | grep -qxF -- "$p" && pass "purge list names $p" || fail "purge list: $p" "missing"
done
for p in cpp cpp-14 cpp-14-x86-64-linux-gnu; do
    if purge_list | grep -qxF -- "$p"; then fail "$p NOT a purge target" "x11-xserver-utils (xrdb) hard-depends on cpp → took xfce4-session + xorg down in dev8"; else pass "$p is not a purge target (xrdb needs it)"; fi
done
grep -q 'trim_installed_only > "$WORK/targets"' "$TRIM" && pass "purge targets filtered to INSTALLED packages (rename-proof)" || fail "installed filter" "missing"
grep -q -- "--autoremove" "$TRIM" && pass "purge uses --autoremove (drops orphans like OpenCV/GDAL)" || fail "autoremove" "missing"
grep -qE "grep -E -- '-dev\\$'" "$TRIM" && pass "remaining *-dev packages are candidates (subject to the guard)" || fail "-dev sweep" "missing"
grep -q '|| echo "WARNING: \[trim\] apt purge' "$TRIM" && pass "purge itself is best-effort" || fail "best-effort purge" "purge failure would abort"

section "0900 trim hook: purge safety (DEC-PHASE12-017)"
grep -q "DEC-PHASE12-017" "$TRIM" && pass "DEC-PHASE12-017 annotated" || fail "annotation 017" "missing"
grep -q 'apt-get -s -q purge --autoremove' "$TRIM" && pass "purges are SIMULATED with --autoremove before running" || fail "simulation" "missing"
grep -q 'apt-mark showmanual' "$TRIM" && pass "protected set = apt-mark showmanual ∪ CRITICAL" || fail "protected set" "showmanual not used"
grep -q 'xargs -r apt-mark manual' "$TRIM" && pass "critical packages re-marked manual (autoremove can't orphan them)" || fail "apt-mark manual" "missing"
grep -q 'SKIP \$t — would remove protected' "$TRIM" && pass "per-target fallback skips + logs offending targets" || fail "per-target fallback" "missing"
grep -q 'purging NOTHING' "$TRIM" && pass "still-blocked remainder → purge nothing" || fail "nothing fallback" "missing"
grep -q 'FATAL: \[trim\] critical packages missing after purge' "$TRIM" && grep -q 'refusing to build an ISO without its desktop' "$TRIM" && pass "missing critical package FAILS THE BUILD (exit 1), not a warning" || fail "outcome gate" "missing"
for c in xorg x11-xserver-utils xfce4-session xfwm4 xfce4-panel xfdesktop4 thunar lightdm mate-polkit python3-numpy network-manager; do
    sed -n '/^CRITICAL=(/,/^)/p' "$TRIM" | tr ' ' '\n' | grep -qxF -- "$c" && pass "CRITICAL includes $c" || fail "CRITICAL: $c" "missing"
done

section "0900 library functions (canned apt-get -s output)"
# Source only the functions (the hook returns early with ORIONX_TRIM_LIB_ONLY=1).
# shellcheck disable=SC1090
if ( set -e; ORIONX_TRIM_LIB_ONLY=1 source "$TRIM" ); then pass "hook sources as a library without side effects" ; else fail "lib source" "sourcing ran the main body or failed"; fi
ORIONX_TRIM_LIB_ONLY=1 source "$TRIM" 2>/dev/null
cat > "$SCRATCH/plan" <<'EOF'
NOTE: This is only a simulation!
Reading package lists...
Building dependency tree...
The following packages will be REMOVED:
  cpp* x11-xserver-utils* xfce4-session* xfce4* xorg* python3-scipy*
Purg python3-scipy [1.14.1-4]
Purg cpp [4:14.2.0-1]
Remv x11-xserver-utils [7.7+11]
Remv xfce4-session [4.20.0-1]
Remv xfce4 [4.20]
Remv xorg [1:7.7+24]
Inst nothing
EOF
trim_plan_removals < "$SCRATCH/plan" > "$SCRATCH/removals"
[[ "$(tr '\n' ' ' < "$SCRATCH/removals")" == "cpp python3-scipy x11-xserver-utils xfce4 xfce4-session xorg " ]] \
    && pass "trim_plan_removals extracts Purg+Remv packages (sorted, unique)" || fail "plan parse" "$(cat "$SCRATCH/removals")"
printf '%s\n' xfce4 xfce4-session xorg x11-xserver-utils lightdm python3-scipy > "$SCRATCH/protected"
printf '%s\n' cpp python3-scipy > "$SCRATCH/targets"
blocked="$(trim_blocked "$SCRATCH/removals" "$SCRATCH/protected" "$SCRATCH/targets" | tr '\n' ' ')"
[[ "$blocked" == "x11-xserver-utils xfce4 xfce4-session xorg " ]] \
    && pass "trim_blocked = protected ∩ removals − explicit targets (dev8 cascade would have been caught)" || fail "trim_blocked" "got: '$blocked'"
printf 'Purg python3-scipy [1]\nRemv python3-fonttools [1]\n' > "$SCRATCH/plan2"
trim_plan_removals < "$SCRATCH/plan2" > "$SCRATCH/removals2"
[[ -z "$(trim_blocked "$SCRATCH/removals2" "$SCRATCH/protected" "$SCRATCH/targets")" ]] \
    && pass "a plan that only removes targets + unprotected orphans is not blocked" || fail "clean plan" "blocked unexpectedly"
[[ -z "$(printf '' | trim_plan_removals)" ]] && pass "empty simulation → no removals" || fail "empty plan" "non-empty"

section "0900 safety: filesystem prunes"
grep -q "/opt/orionx" "$TRIM" && ! grep -qE "rm -rf [^#]*\/opt\/orionx" "$TRIM" && pass "hook never rm's under /opt/orionx" || fail "opt/orionx safety" "hook touches /opt/orionx"
grep -q "not -name copyright" "$TRIM" && pass "doc prune keeps every copyright file" || fail "copyright kept" "missing"
grep -q "not -path '/usr/share/doc/orionx/\*'" "$TRIM" && pass "doc prune keeps /usr/share/doc/orionx (User Guide + images)" || fail "orionx docs kept" "missing"
grep -qE 'en\|en_\*\|en@\*\|locale.alias' "$TRIM" && pass "locale prune keeps en, en_*, en@*, locale.alias" || fail "locale keep set" "wrong"
if grep -qE "usr/share/man" "$TRIM"; then fail "man pages untouched" "hook references usr/share/man"; else pass "man pages untouched (3am operator keeps man)"; fi
grep -q "rm -rf /root/.cache/pip" "$TRIM" && pass "pip wheel cache removed (49 MB leaked into dev7)" || fail "pip cache" "not removed"
grep -q "DEC-PHASE12-015" "$TRIM" && pass "DEC-PHASE12-015 annotated in 0900" || fail "annotation 0900" "missing"
for g in "zeek-core still present" "ollama still present" "CPU backends"; do grep -q "$g" "$TRIM" && pass "post-purge guard: $g" || fail "guard: $g" "missing"; done

section "Package list: polkit agent pinned (no more ukui-polkit)"
if grep -qE "^mate-polkit$" "$PKGS"; then
    pass "mate-polkit (xfce4's recommended agent) is pinned in the package list"
else
    fail "polkit agent pinned" "nm-applet needs 'policykit-1-gnome | polkit-1-auth-agent'; unpinned, apt also pulled ukui-polkit (+OpenCV+GDAL)"
fi
if grep -qE "^ukui-polkit$" "$PKGS"; then fail "ukui-polkit not listed" "listed"; else pass "ukui-polkit not in the package list"; fi

section "Hook ordering"
ls "$REPO_ROOT/iso/config/hooks/live/" | sort | awk '/0900-trim/{t=NR} /0810-render/{r=NR} /0700-orionx/{s=NR} END{exit !(t>r && t>s)}' \
    && pass "0900-trim runs after 0700 (symlinks) and 0810 (guide render)" || fail "hook ordering" "trim must be last"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
