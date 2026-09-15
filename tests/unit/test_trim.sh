#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_trim.sh — zero-regret image trim (DEC-PHASE12-015)
#
# Locks the trim decisions taken from the trixie-dev6 size budget: ollama GPU
# backends dropped, zeek-core instead of the zeek metapackage, the 0900 purge
# list + its safety properties, English-only locales, doc pruning that keeps
# copyright files and the Orion-X User Guide, and the polkit-agent pin.
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

section "0500: ollama GPU backends + zeek-core"
grep -q 'for gpu in cuda_v12 cuda_v13 vulkan' "$EXT" && pass "0500 removes ollama cuda_v12/cuda_v13/vulkan after extract" || fail "GPU prune" "missing"
grep -q 'libggml-cpu-\*.so' "$EXT" && pass "0500 verifies CPU backends survive the prune" || fail "CPU backend check" "missing"
grep -qE 'apt-get install -y --no-install-recommends zeek-core' "$EXT" && pass "0500 installs zeek-core (not the zeek metapackage)" || fail "zeek-core" "still installing 'zeek'"
if grep -qE 'apt-get install -y zeek$' "$EXT"; then fail "zeek metapackage gone" "'apt-get install -y zeek' still present"; else pass "zeek metapackage install line gone"; fi
grep -q "DEC-PHASE12-015" "$EXT" && pass "DEC-PHASE12-015 annotated in 0500" || fail "annotation 0500" "missing"

section "0900 trim hook"
[[ -x "$TRIM" ]] && pass "0900-trim hook present + executable" || fail "0900 hook" "missing/not +x"
bash -n "$TRIM" 2>/dev/null && pass "0900 hook bash syntax" || fail "0900 syntax" "bash -n failed"
for p in zeek-zkg zeek-spicy-dev zeek-btest-data python3-scipy python3-matplotlib python3-pyqtgraph ukui-polkit mesa-vulkan-drivers firmware-nvidia-graphics unhide.rb gcc-14 g++-14; do
    sed -n '/^PURGE_WANTED=(/,/^)/p' "$TRIM" | tr ' ' '\n' | grep -qxF -- "$p" && pass "purge list names $p" || fail "purge list: $p" "missing"
done
grep -q 'dpkg-query -W -f=.\${Status}' "$TRIM" && pass "purge list is filtered to INSTALLED packages (a rename can't abort the build)" || fail "installed filter" "missing"
grep -q -- "--autoremove" "$TRIM" && pass "purge uses --autoremove (drops orphans like OpenCV/GDAL)" || fail "autoremove" "missing"
grep -qE "grep -E -- '-dev\\$'" "$TRIM" && pass "all remaining *-dev packages purged" || fail "-dev sweep" "missing"
grep -q '|| echo "WARNING: \[trim\] apt purge' "$TRIM" && pass "purge is best-effort (never aborts the ISO)" || fail "best-effort purge" "purge failure would abort"
# Safety: never touch /opt/orionx; keep copyright + orionx docs; English locales stay.
grep -q "/opt/orionx" "$TRIM" && ! grep -qE "rm -rf [^#]*\/opt\/orionx" "$TRIM" && pass "hook never rm's under /opt/orionx" || fail "opt/orionx safety" "hook touches /opt/orionx"
grep -q "not -name copyright" "$TRIM" && pass "doc prune keeps every copyright file" || fail "copyright kept" "missing"
grep -q "not -path '/usr/share/doc/orionx/\*'" "$TRIM" && pass "doc prune keeps /usr/share/doc/orionx (User Guide + images)" || fail "orionx docs kept" "missing"
grep -qE 'en\|en_\*\|en@\*\|locale.alias' "$TRIM" && pass "locale prune keeps en, en_*, en@*, locale.alias" || fail "locale keep set" "wrong"
if grep -qE "usr/share/man" "$TRIM"; then fail "man pages untouched" "hook references usr/share/man"; else pass "man pages untouched (3am operator keeps man)"; fi
grep -q "DEC-PHASE12-015" "$TRIM" && pass "DEC-PHASE12-015 annotated in 0900" || fail "annotation 0900" "missing"
# Guards after purge
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
