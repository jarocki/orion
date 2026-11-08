#!/usr/bin/env bash
# test_settings_writers.sh — one writer per operator settings file (#95, DEC-PHASE13-048).
#
# 1. The shipped tree: every ~/.config/orionx file has exactly its declared
#    writer (tests/unit/lib/check_settings_writers.py resolves the path
#    constants through modules, imports, defaults and helpers), every file the
#    code names is registered, and nothing ships enabling the Nebula warm-up.
# 2. The checker is proved to bite: in scratch copies under tmp/, a second
#    writer is planted five ways (a cross-module constant, a call through the
#    atomic-write helper, a shell redirection, an unregistered settings file,
#    a hook that enables nebula-warmup.service). Each copy must FAIL, naming
#    the file and the planted writer; the untouched copy must PASS. A checker
#    that passed everything would pass section 1 too, so section 2 is what
#    makes section 1 mean something.
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tests/unit/lib/check_settings_writers.py"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [[ -n "${2:-}" ]] && echo "        $2"; FAIL=$((FAIL+1)); }

echo "[the shipped tree: one writer per settings file]"
if OUT="$(python3 "$CHECK" "$ROOT" 2>&1)"; then
    echo "$OUT"
    pass "every settings file has exactly its declared writer"
else
    echo "$OUT"
    fail "settings writers" "see the FAIL lines above"
fi

echo "[the checker bites: a planted second writer fails it]"
WORK="$ROOT/tmp/settings-writers.$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
fresh() {   # a scratch tree: scripts/ and the hooks, which is where writers live
    rm -rf "$WORK/tree"
    mkdir -p "$WORK/tree/iso/config"
    cp -R "$ROOT/scripts" "$WORK/tree/scripts"
    cp -R "$ROOT/iso/config/hooks" "$WORK/tree/iso/config/hooks"
    find "$WORK/tree" -name __pycache__ -prune -exec rm -rf {} +
}
expect_fail() {   # $1 label, $2 regex the output must match
    local out rc
    out="$(python3 "$CHECK" "$WORK/tree" 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]] && grep -qE "$2" <<<"$out"; then
        pass "$1"
    else
        fail "$1" "rc=$rc; expected /$2/ in: $(grep -E 'FAIL' <<<"$out" | head -3)"
    fi
}

fresh
if python3 "$CHECK" "$WORK/tree" >/dev/null 2>&1; then
    pass "the untouched scratch copy passes (so each failure below is the plant's)"
else
    fail "untouched scratch copy" "$(python3 "$CHECK" "$WORK/tree" 2>&1 | grep FAIL | head -3)"
fi

# (a) a second writer of the posture file, through posture_data's own constant
cat >>"$WORK/tree/scripts/control_center/settings_drawer.py" <<'PY'


def _planted_second_posture_writer() -> None:
    P.REQUEST_FILE.write_text("2\n")
PY
expect_fail "a write through P.REQUEST_FILE in the drawer is a second threat-posture writer" \
    'FAIL: ~/.config/orionx/threat-posture: .*scripts/control_center/settings_drawer.py'

# (b) a second rain.json writer that goes through the atomic helper
fresh
cat >>"$WORK/tree/scripts/control_center/sections/nebula.py" <<'PY'


def _planted_rain_writer() -> None:
    from ..helpers import settings_io as S2
    S2.atomic_write_text(Path.home() / ".config" / "orionx" / "rain.json", "{}\n")
PY
expect_fail "settings_io.atomic_write_text(…/rain.json) in another module is a second rain.json writer" \
    'FAIL: ~/.config/orionx/rain.json: .*scripts/control_center/sections/nebula.py'

# (c) a shell redirection onto autonomy.json
fresh
printf '\nAUT="$HOME/.config/orionx/autonomy.json"\necho "{}" > "$AUT"\n' >>"$WORK/tree/scripts/toggle-theme.sh"
expect_fail "a shell redirection onto autonomy.json (through a variable) is a second writer" \
    'FAIL: ~/.config/orionx/autonomy.json: .*scripts/toggle-theme.sh'

# (d) a new settings file nobody declared
fresh
printf '\n_NEW = Path.home() / ".config" / "orionx" / "new-setting.json"\n' >>"$WORK/tree/scripts/control_center/settings_drawer.py"
expect_fail "a new ~/.config/orionx file without a declared writer fails" \
    'new-setting.json is named in scripts/control_center/settings_drawer.py but has no declared writer'

# (e) a hook that enables the warm-up (the operator's systemctl is its only writer)
fresh
printf '\nsystemctl enable nebula-warmup.service\n' >>"$WORK/tree/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"
expect_fail "a hook enabling nebula-warmup.service fails" \
    'enables nebula-warmup.service'

echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="
[[ $FAIL -eq 0 ]]
