#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_orionx_diag_model.sh — orionx-diag check 7c verifies the blobs that
# MANIFEST.sha256 names (DEC-PHASE12-121, shell P2-7).
#
# Behavioural: builds a fake models dir in the 0510 layout (blobs/sha256-*,
# MANIFEST.sha256 with paths relative to the models dir), runs the real
# `orionx-diag --json --category nebula` against it, and reads 7c's result.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1 — ${2:-}"; }
DIAG="$REPO_ROOT/scripts/orionx-diag"
S="$REPO_ROOT/tmp/test_diag_model_$$"; trap 'rm -rf "$S"' EXIT
mkdir -p "$S/m/blobs"
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

LABEL="model blobs match MANIFEST.sha256 (what ollama loads)"
status_of() {  # prints "STATUS<TAB>detail" for 7c, or NOT-FOUND / NOT-JSON
    ORIONX_NEBULA_MODELS_DIR="$S/m" bash "$DIAG" --json --category nebula 2>/dev/null > "$S/out.json"
    python3 - "$S/out.json" "$LABEL" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOT-JSON\t%s" % e); sys.exit(0)
def walk(o):
    if isinstance(o, dict):
        if o.get("name") == sys.argv[2]:
            print("%s\t%s" % (o.get("status"), o.get("detail", ""))); sys.exit(0)
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(doc); print("NOT-FOUND\t")
PY
}

head -c 65536 /dev/urandom > "$S/m/blobs/sha256-model"
head -c 512 /dev/urandom > "$S/m/blobs/sha256-params"
(cd "$S/m" && sha256 blobs/sha256-model blobs/sha256-params > MANIFEST.sha256)
R="$(status_of)"
[[ "$R" == PASS* ]] && pass "intact blobs listed in MANIFEST.sha256 -> PASS ($R)" || fail "intact blobs" "$R"
[[ "$R" != NOT-JSON* ]] && pass "--json output stays valid JSON (no stray ollama --version line)" || fail "json" "$R"

printf 'x' >> "$S/m/blobs/sha256-model"
R="$(status_of)"
[[ "$R" == FAIL* && "$R" == *"sha256-model"* ]] && pass "a corrupted blob -> FAIL naming it" || fail "corrupt blob" "$R"

rm -f "$S/m/blobs/sha256-model"
R="$(status_of)"
[[ "$R" == FAIL* ]] && pass "a missing blob -> FAIL (not SKIP)" || fail "missing blob" "$R"

rm -f "$S/m/MANIFEST.sha256"
R="$(status_of)"
[[ "$R" == FAIL* ]] && pass "no MANIFEST.sha256 -> FAIL (the model cannot be verified)" || fail "missing manifest" "$R"

echo "TBD-VERIFY-AT-DOWNLOAD  blobs/sha256-params" > "$S/m/MANIFEST.sha256"
R="$(status_of)"
[[ "$R" == FAIL* ]] && pass "TBD sentinel -> FAIL" || fail "sentinel" "$R"

LIST="$(sed -n 's/^ORIONX_OPTIONAL_INSTALLERS=(\(.*\))$/\1/p' "$DIAG" | tr ' ' '\n' | sort | tr '\n' ' ')"
DIR="$(ls "$REPO_ROOT/iso/config/includes.chroot/opt/orionx/optional/" | sed -n 's/^install-\(.*\)\.sh$/\1/p' | sort | tr '\n' ' ')"
[[ -n "$LIST" && "$LIST" == "$DIR" ]] && pass "diag checks exactly the installers the image ships ($LIST)" || fail "installer list" "diag: '$LIST' vs optional/: '$DIR'"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
