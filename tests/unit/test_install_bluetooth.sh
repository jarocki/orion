#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_install_bluetooth.sh — optional Bluetooth installer (#151, DEC-PHASE13-035)
#
# The installer is EXECUTED here against stubs (dpkg-query, systemctl, rfkill,
# orionx-event) and the repo's real installer library, so the paths an operator
# reaches without root — --check, --dry-run, the idempotence gate, argument
# errors — run for real. The apply path needs root and apt; it is covered by
# shellcheck, bash -n and the deck.
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
INSTALLER="$CHROOT/opt/orionx/optional/install-bluetooth.sh"
LIB="$CHROOT/opt/orionx/optional/lib/orionx-installer-common.sh"
HOOK="$REPO_ROOT/iso/config/hooks/live/0500-install-external-tools.hook.chroot"
LINKS="$CHROOT/opt/orionx/osint/links.json"
WORK="$(mktemp -d "${TMPDIR:-$REPO_ROOT/tmp}/bt.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

section "Structure"
[[ -f "$INSTALLER" ]] && pass "install-bluetooth.sh present" || { fail "install-bluetooth.sh present" "missing"; exit 1; }
[[ -x "$INSTALLER" ]] && pass "installer executable" || fail "installer executable"
bash -n "$INSTALLER" && pass "installer parses (bash -n)" || fail "bash -n"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$INSTALLER" >/dev/null 2>&1 && pass "installer shellcheck clean" || fail "shellcheck" "$(shellcheck "$INSTALLER" 2>&1 | tail -5)"
fi
grep -q '@decision DEC-PHASE13-035' "$INSTALLER" && pass "carries DEC-PHASE13-035" || fail "decision annotation"
grep -qE '^source "\$\{ORIONX_INSTALLER_LIB:-/opt/orionx/optional/lib/orionx-installer-common\.sh\}"' "$INSTALLER" \
    && pass "sources the shared library at its runtime path (test override only)" || fail "library source line"
grep -q 'orionx_require_root' "$INSTALLER" && pass "requires root before changing anything" || fail "require_root"
grep -q 'orionx_require_network deb.debian.org' "$INSTALLER" && pass "network preflight only on the network path" || fail "require_network"
grep -qE '^BLUETOOTH_PACKAGES="bluez blueman pulseaudio-module-bluetooth"$' "$INSTALLER" && pass "package set is bluez + blueman + pulseaudio-module-bluetooth (one line, one authority)" || fail "package set"
grep -q -- '--no-install-recommends' "$INSTALLER" && pass "installs without Recommends (7 MB, not 75 MB)" || fail "no-install-recommends"
grep -q 'systemctl unmask "\$BLUETOOTH_UNIT"' "$INSTALLER" && pass "unmasks bluetooth.service (0620 masks it when present)" || fail "unmask"
grep -q 'rfkill unblock bluetooth' "$INSTALLER" && pass "unblocks the radio" || fail "rfkill unblock"
grep -q 'rfkill block bluetooth' "$INSTALLER" && pass "tells the operator how to turn the radio off again" || fail "radio off guidance"
grep -q 'bluetooth_installed' "$INSTALLER" && grep -q 'blueman-manager' "$INSTALLER" && pass "installed = packages installed AND the manager runs" || fail "truth probe"
git -C "$REPO_ROOT" ls-files --error-unmatch "iso/config/includes.chroot/opt/orionx/optional/install-bluetooth.sh" >/dev/null 2>&1 \
    && pass "installer is tracked by git" || fail "installer UNTRACKED" "git add -f iso/config/includes.chroot/opt/orionx/optional/install-bluetooth.sh"

section "Executed: --check, idempotence, --dry-run (stubs; no root, no apt)"
mkdir -p "$WORK/bin" "$WORK/cache"
# dpkg-query stub: STUB_INSTALLED lists the packages that are "installed".
cat > "$WORK/bin/dpkg-query" <<'STUB'
#!/usr/bin/env bash
pkg="${*: -1}"
for p in ${STUB_INSTALLED:-}; do
  if [[ "$p" == "$pkg" ]]; then
    case "$*" in *Status-Status*) echo installed ;; *Version*) echo 5.82-1.1 ;; esac
    exit 0
  fi
done
exit 1
STUB
for t in systemctl rfkill orionx-event apt-get; do printf '#!/usr/bin/env bash\necho "%s $*" >> "${STUB_CALLS:?}"\nexit 0\n' "$t" > "$WORK/bin/$t"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/blueman-manager"
chmod +x "$WORK/bin/"*
run() {  # run <installed-list> <args...>
    local inst="$1"; shift
    STUB_INSTALLED="$inst" STUB_CALLS="$WORK/calls" PATH="$WORK/bin:$PATH" \
    ORIONX_INSTALLER_LIB="$LIB" ORIONX_BLUETOOTH_CACHE="$WORK/cache" bash "$INSTALLER" "$@" 2>&1
}
: > "$WORK/calls"
out="$(run "" --check)"; rc=$?
[[ $rc -eq 1 ]] && pass "--check exits 1 when absent" || fail "--check absent rc" "rc=$rc $out"
echo "$out" | grep -q 'NOT installed' && pass "--check says plainly that it is absent" || fail "--check absent text" "$out"
out="$(run "bluez blueman pulseaudio-module-bluetooth" --check)"; rc=$?
[[ $rc -eq 0 ]] && pass "--check exits 0 when installed" || fail "--check present rc" "rc=$rc $out"
out="$(run "bluez" --check)"; rc=$?
[[ $rc -eq 1 ]] && pass "bluez without blueman is NOT reported as installed" || fail "partial install detected" "rc=$rc"
out="$(run "" --wat)"; rc=$?
[[ $rc -eq 2 ]] && pass "unknown argument is refused (exit 2)" || fail "unknown arg" "rc=$rc"
out="$(run "" --help)"; rc=$?
[[ $rc -eq 0 ]] && echo "$out" | grep -q -- '--dry-run' && pass "--help exits 0 and lists --dry-run" || fail "--help" "rc=$rc $out"

# --dry-run, cache absent: plans the network path, changes nothing.
: > "$WORK/calls"
out="$(run "" --dry-run)"; rc=$?
[[ $rc -eq 0 ]] && pass "--dry-run (no cache) exits 0 without root" || fail "--dry-run rc" "rc=$rc $out"
echo "$out" | grep -q 'Source:   network' && pass "--dry-run names the network as the source when the cache is empty" || fail "dry-run network source" "$out"
echo "$out" | grep -q 'apt-get update && apt-get install -y --no-install-recommends bluez blueman pulseaudio-module-bluetooth' \
    && pass "--dry-run prints the exact apt plan" || fail "dry-run apt plan" "$out"
grep -qE '^(apt-get|systemctl|rfkill)' "$WORK/calls" && fail "--dry-run called apt/systemctl/rfkill" "$(cat "$WORK/calls")" || pass "--dry-run calls neither apt nor systemctl nor rfkill"
echo "$out" | grep -q 'turns the Bluetooth radio ON' && pass "banner says this turns a radio on" || fail "radio banner" "$out"
echo "$out" | grep -q 'RAM overlay' && pass "banner states the persistence rule" || fail "persistence banner" "$out"

# --dry-run, cache present: plans the cache path and lists the debs.
touch "$WORK/cache/bluez_5.82-1.1_amd64.deb" "$WORK/cache/blueman_2.4.4-1_amd64.deb" "$WORK/cache/README"
: > "$WORK/calls"
out="$(run "" --dry-run)"; rc=$?
echo "$out" | grep -q 'Source:   on-ISO cache' && echo "$out" | grep -q '(2 debs' && pass "--dry-run prefers the on-ISO cache and counts its debs" || fail "dry-run cache source" "$out"
echo "$out" | grep -q 'bluez_5.82-1.1_amd64.deb' && ! echo "$out" | grep -q 'README' && pass "--dry-run lists the cached .deb files only" || fail "dry-run deb list" "$out"
grep -qE '^apt-get' "$WORK/calls" && fail "--dry-run (cache) called apt" || pass "--dry-run (cache) calls no apt"

# Idempotence without root: an installed deck in dry-run only re-asserts.
out="$(run "bluez blueman pulseaudio-module-bluetooth" --dry-run)"; rc=$?
[[ $rc -eq 0 ]] && echo "$out" | grep -q 'already installed' && echo "$out" | grep -q 're-assert' \
    && pass "installed deck: re-run only re-asserts service + radio (no apt)" || fail "idempotent re-run" "rc=$rc $out"
echo "$out" | grep -q 'apt-get install' && fail "idempotent re-run planned apt" "$out" || pass "idempotent re-run never plans apt"

section "Build wiring: the 0500 hook caches the debs from the installer's package list"
grep -q 'bluetooth_pin BLUETOOTH_PACKAGES' "$HOOK" && pass "0500 reads BLUETOOTH_PACKAGES from the installer (one authority)" || fail "hook pin read"
grep -q -- '--download-only' "$HOOK" && grep -q 'Dir::Cache::archives' "$HOOK" && pass "0500 downloads into a private archives dir (exactly what this chroot lacks)" || fail "hook download-only"
grep -q -- '--no-install-recommends --download-only' "$HOOK" && pass "0500 caches without Recommends" || fail "hook no-recommends"
grep -q 'SOFT-FAIL: Bluetooth deb cache' "$HOOK" && pass "0500 soft-fails loudly (installer falls back to the network)" || fail "hook soft-fail"
grep -q '/opt/orionx/optional/cache/bluetooth' "$HOOK" && grep -q '/opt/orionx/optional/cache/bluetooth' "$INSTALLER" && pass "hook and installer agree on the cache path" || fail "cache path agreement"
# Execute the pin reader exactly as the hook defines it.
pin_fn="$(grep '^bluetooth_pin()' "$HOOK")"
got="$(bash -c "$pin_fn; BLUETOOTH_INSTALLER='$INSTALLER'; bluetooth_pin BLUETOOTH_PACKAGES")"
[[ "$got" == "bluez blueman pulseaudio-module-bluetooth" ]] && pass "hook's pin reader extracts the package list verbatim" || fail "pin reader" "got: $got"

section "Operator surfaces"
python3 - "$LINKS" <<'PY' && pass "links.json: bluetooth installable entry is well-formed (Orion Tools Install button)" || fail "links.json entry"
import json, sys
d = json.load(open(sys.argv[1]))
e = [i for i in d["installable"] if i["id"] == "bluetooth"]
assert len(e) == 1, "no bluetooth entry"
e = e[0]
assert e["command"] == "sudo /opt/orionx/optional/install-bluetooth.sh"
assert e["runtime_path"] == "/opt/orionx/optional/install-bluetooth.sh"
assert e["probe"] == ["/usr/bin/blueman-manager"]
assert "radio" in e["blurb"]
PY
grep -q '`install-bluetooth.sh`' "$REPO_ROOT/README.md" && pass "README lists the installer" || fail "README row"
grep -q '`install-bluetooth.sh`' "$REPO_ROOT/docs/User_Guide.md" && pass "User Guide §15 lists the installer" || fail "User Guide row"

printf "\n  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
