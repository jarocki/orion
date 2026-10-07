#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_godseye_cesium.sh — no shared Cesium ion token ships, and CesiumJS's
# licence does (DEC-PHASE12-124, security F23). The property is the bytes of
# the vendored bundle, so the checks read those bytes; the MANIFEST check
# proves the edit is the pinned state, not a drift.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
GS="$REPO_ROOT/iso/config/includes.chroot/opt/orionx/osint/godseye"
JWT='eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
N="$(grep -rEo "$JWT" "$GS/app" | wc -l | tr -d ' ')"
[[ "$N" == 0 ]] && pass "no JWT-shaped token anywhere in the vendored bundle" || fail "token" "$N JWT(s) found"
grep -qF 'jse="",gU={};gU.defaultAccessToken=jse' "$GS/app/cesium/Cesium.js" \
    && pass "Cesium ion defaultAccessToken is the empty string" || fail "defaultAccessToken" "not blanked"
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum -c); else SHA=(shasum -a 256 -c); fi
T="$(mktemp)"; grep '  app/cesium/Cesium.js$' "$GS/MANIFEST.sha256" > "$T"
(cd "$GS" && "${SHA[@]}" "$T" >/dev/null 2>&1); MRC=$?; rm -f "$T"
[[ $MRC -eq 0 ]] \
    && pass "MANIFEST.sha256 pins the edited Cesium.js" || fail "manifest" "Cesium.js does not match its pin"
head -3 "$GS/LICENSE.cesium" 2>/dev/null | grep -q 'CesiumJS Contributors' && grep -q 'Apache License' "$GS/LICENSE.cesium" \
    && pass "LICENSE.cesium ships (CesiumJS copyright + Apache-2.0)" || fail "LICENSE.cesium" "missing"
grep -qF 'need "$ROOT/LICENSE.cesium"' "$REPO_ROOT/iso/config/hooks/live/0715-godseye.hook.chroot" \
    && pass "0715 refuses an image without the Cesium licence" || fail "0715 need" "LICENSE.cesium not required"
grep -q 'DEC-PHASE12-124' "$GS/PROVENANCE.txt" && pass "PROVENANCE records the third edit" || fail "PROVENANCE" "edit not recorded"
echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
