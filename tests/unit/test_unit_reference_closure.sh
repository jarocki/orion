#!/usr/bin/env bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — systemd unit reference closure invariant
#
# @decision DEC-PHASE12-041
# @title Every Orion-X unit named by an installed unit must itself be installed
# @status accepted
# @rationale rc4 shipped orionx-mesh-discover.timer with
#   Unit=orionx-mesh-beacon.service while orionx-mesh-beacon.service was
#   absent from UNIT_FILES in 0615-install-systemd-units.hook.chroot. Every
#   boot, a live timer fired every 10 seconds at a unit that did not exist.
#   Outbound peer discovery never ran — and because the timer names the
#   beacon explicitly, orionx-mesh-discover.service (the listener) was never
#   triggered either, so inbound discovery was dead too. One missing array
#   entry, both halves of the feature gone, nothing in any test.
#
#   nebula-integrity-check.service had the same shape:
#   Before=nebula-runtime.socket, a unit DEC-PHASE11-033 deleted.
#
#   This suite closes the CLASS, not the instance. For every unit 0615
#   installs, every orionx-/nebula-/matrix- unit it names in Unit=,
#   Requires=, Wants=, BindsTo=, PartOf=, Before=, After=, Requisite=, Also=
#   or a `systemctl start` inside an Exec* line must itself appear in
#   UNIT_FILES. System units (network.target, apparmor.service, ...) are out
#   of scope: the distribution provides them.
#
#   KNOWN EXCEPTIONS are listed explicitly below, with the exact text the
#   operator must add to 0615. The hook is outside this change's remit, so
#   the gap is recorded rather than hidden: a NEW dangling reference turns
#   this red immediately, and fixing a listed one ALSO turns it red, telling
#   whoever fixed it to delete the exception.
#
# Usage:  bash tests/unit/test_unit_reference_closure.sh

set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; (( PASS_COUNT++ )) || true; }
fail() { echo "  FAIL: $1"; shift; for l in "$@"; do echo "        $l"; done; (( FAIL_COUNT++ )) || true; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"
UNITDIR="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd"

echo "=== systemd unit reference closure (DEC-PHASE12-041) ==="
echo ""

if [[ ! -f "$HOOK" ]]; then
    fail "0615 hook present" "not found at $HOOK"
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $(( PASS_COUNT + FAIL_COUNT )))"
    exit 1
fi

# --- The tracked exceptions -------------------------------------------------
# Format: "<referenced unit>|<what the operator must do>"
# Both DEC-PHASE12-041 gaps are now closed in 0615: orionx-mesh-beacon.service
# is installed and orionx-mesh-discover.service is autostarted. Their
# exceptions are deleted rather than left behind — an exception that outlives
# its defect is a lie the next reader has to disprove. Empty is the correct
# state: any NEW dangling reference now fails immediately with nothing to
# shelter behind.
EXPECTED_DANGLING=()
# Services that are installed, carry [Install], and are deliberately NOT in
# AUTOSTART_UNITS.
EXPECTED_UNENABLED=(
  "nebula-warmup.service|deliberate: DEC-PHASE10-010 keeps warm-up opt-in"
)

# --- Extract the arrays from the hook ---------------------------------------
_array() {
    sed -n "/^$1=(/,/^)/p" "$HOOK" | grep -oE '"[^"]+"' | tr -d '"'
}
# No mapfile: the build hosts run bash 3.2 (macOS).
UNIT_FILES=()
while IFS= read -r _l; do [[ -n "$_l" ]] && UNIT_FILES+=("$_l"); done < <(_array UNIT_FILES)
AUTOSTART=()
while IFS= read -r _l; do [[ -n "$_l" ]] && AUTOSTART+=("$_l"); done < <(_array AUTOSTART_UNITS)

if (( ${#UNIT_FILES[@]} > 0 )); then
    pass "parsed UNIT_FILES from 0615 (${#UNIT_FILES[@]} units)"
else
    fail "parse UNIT_FILES from 0615" "the array could not be read — this suite proves nothing"
fi
if (( ${#AUTOSTART[@]} > 0 )); then
    pass "parsed AUTOSTART_UNITS from 0615 (${#AUTOSTART[@]} units)"
else
    fail "parse AUTOSTART_UNITS from 0615" "the array could not be read"
fi

_installed() {
    local needle="$1" u
    for u in "${UNIT_FILES[@]}"; do [[ "$u" == "$needle" ]] && return 0; done
    return 1
}
_enabled() {
    local needle="$1" u
    for u in "${AUTOSTART[@]}"; do [[ "$u" == "$needle" ]] && return 0; done
    return 1
}
_expected_dangling() {
    local needle="$1" e
    for e in ${EXPECTED_DANGLING[@]+"${EXPECTED_DANGLING[@]}"}; do [[ "${e%%|*}" == "$needle" ]] && return 0; done
    return 1
}
_remedy() {
    local needle="$1" e
    for e in ${EXPECTED_DANGLING[@]+"${EXPECTED_DANGLING[@]}"} ${EXPECTED_UNENABLED[@]+"${EXPECTED_UNENABLED[@]}"}; do
        [[ "${e%%|*}" == "$needle" ]] && { echo "${e#*|}"; return 0; }
    done
    echo "unknown"
}

echo ""
echo "--- Every staged unit file exists ---"
for u in "${UNIT_FILES[@]}"; do
    if [[ -f "$UNITDIR/$u" ]]; then
        pass "$u is staged in includes.chroot"
    else
        fail "$u is staged in includes.chroot" "0615 would exit 1 on this: $UNITDIR/$u"
    fi
done

echo ""
echo "--- Reference closure: no installed unit may name an uninstalled one ---"

REF_KEYS='Unit|Requires|Requisite|Wants|BindsTo|PartOf|Before|After|Also|Upholds'
DANGLING=()          # "<ref>|<naming unit>|<key>"
for u in "${UNIT_FILES[@]}"; do
    f="$UNITDIR/$u"
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        refs=""
        if [[ "$key" =~ ^(${REF_KEYS})$ ]]; then
            refs="$val"
        elif [[ "$key" == Exec* ]]; then
            refs="$(grep -oE 'systemctl +(start|stop|restart|reload|enable) +[^ ]+' <<< "$val" | awk '{print $NF}' || true)"
        fi
        for r in $refs; do
            case "$r" in
                orionx-*|nebula-*|matrix-*) ;;
                *) continue ;;
            esac
            case "$r" in
                *.service|*.timer|*.socket|*.path|*.target) ;;
                *) continue ;;
            esac
            _installed "$r" || DANGLING+=("$r|$u|$key")
        done
    done < <(grep -vE '^[[:space:]]*#' "$f" | grep -E '^[A-Za-z]+=')
done

# Every dangling reference must be a KNOWN one, and it must be reported.
# ${ARR[@]} on an EMPTY array trips `set -u`. That made this loop crash in
# exactly the state it exists to reward — no dangling references — so the
# test only worked while the defect was present. Guarded expansion.
for d in ${DANGLING[@]+"${DANGLING[@]}"}; do
    ref="${d%%|*}"; rest="${d#*|}"; src="${rest%%|*}"; key="${rest#*|}"
    if _expected_dangling "$ref"; then
        pass "known gap: $src has $key=$ref, which 0615 does not install"
        echo "        → $(_remedy "$ref")"
    else
        fail "NEW dangling unit reference: $src has $key=$ref" \
             "$ref is not in UNIT_FILES, so systemd will never find it." \
             "Add it to UNIT_FILES in 0615, or stop referencing it."
    fi
done

# And every KNOWN gap must still be a gap — when it is fixed, say so loudly
# so this exception list does not outlive the defect it records.
for e in ${EXPECTED_DANGLING[@]+"${EXPECTED_DANGLING[@]}"}; do
    ref="${e%%|*}"
    if _installed "$ref"; then
        fail "tracked gap '$ref' is FIXED — good" \
             "Delete it from EXPECTED_DANGLING in this file."
    else
        pass "tracked gap '$ref' is still recorded, not hidden"
    fi
done

echo ""
echo "--- Timers must activate a unit that exists ---"
for u in "${UNIT_FILES[@]}"; do
    [[ "$u" == *.timer ]] || continue
    f="$UNITDIR/$u"
    target="$(grep -E '^Unit=' "$f" | tail -1 | cut -d= -f2 || true)"
    [[ -n "$target" ]] || target="${u%.timer}.service"
    if _installed "$target"; then
        pass "$u activates $target, which is installed"
    elif _expected_dangling "$target"; then
        pass "known gap: $u activates $target, which 0615 does not install"
        echo "        → $(_remedy "$target")"
        echo "        → consequence: the timer fires into nothing on every"
        echo "          interval, and because Unit= names it explicitly the"
        echo "          similarly-named .service is never triggered either."
    else
        fail "$u activates $target, which is NOT installed" \
             "An enabled timer firing at a nonexistent unit is silent breakage."
    fi
done

echo ""
echo "--- An enabled timer's target must not be separately enabled ---"
# Enabling both the .timer and its .service would start the oneshot at boot
# AND on the interval. Not fatal, but it is two authorities for one fact.
for u in "${AUTOSTART[@]}"; do
    [[ "$u" == *.timer ]] || continue
    f="$UNITDIR/$u"
    target="$(grep -E '^Unit=' "$f" | tail -1 | cut -d= -f2 || true)"
    [[ -n "$target" ]] || target="${u%.timer}.service"
    if _enabled "$target"; then
        fail "$u and its target $target are BOTH in AUTOSTART_UNITS" \
             "Enable the timer only (0615's own comment says so)."
    else
        pass "$u is enabled without separately enabling $target"
    fi
done

echo ""
echo "--- Installed services with [Install] are either enabled or explained ---"
for u in "${UNIT_FILES[@]}"; do
    [[ "$u" == *.service ]] || continue
    [[ "$u" == *@* ]] && continue          # templates cannot be enabled bare
    f="$UNITDIR/$u"
    grep -qE '^WantedBy=' "$f" || continue
    if _enabled "$u"; then
        pass "$u is installed and enabled"
        continue
    fi
    known=0
    for e in ${EXPECTED_UNENABLED[@]+"${EXPECTED_UNENABLED[@]}"}; do
        [[ "${e%%|*}" == "$u" ]] && known=1
    done
    if (( known )); then
        pass "$u is installed but not enabled — recorded"
        echo "        → $(_remedy "$u")"
    else
        fail "$u has [Install] WantedBy= but is in neither AUTOSTART_UNITS nor" \
             "the EXPECTED_UNENABLED list. It will be installed and never run." \
             "Either enable it in 0615 or record why not."
    fi
done

echo ""
echo "--- The specific rc4 dead references must stay dead ---"
if grep -qE '^Before=.*nebula-runtime\.socket' "$UNITDIR/nebula-integrity-check.service"; then
    fail "nebula-integrity-check.service still orders on nebula-runtime.socket" \
         "DEC-PHASE11-033 deleted that unit."
else
    pass "nebula-integrity-check.service no longer names the deleted socket unit"
fi

echo ""
echo "==========================================="
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $TOTAL)"
echo "==========================================="
[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
