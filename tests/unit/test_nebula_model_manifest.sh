#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for iso/config/nebula-model-manifest.json
#
# @decision DEC-PHASE10-008
# @title test_nebula_model_manifest: validates the single model manifest authority
# @status accepted
# @rationale iso/config/nebula-model-manifest.json is the single source of truth
#   for the bundled model URL + SHA-256 + filename. Every downstream consumer
#   (stage_nebula_model, integrity.py) reads this file. These tests prove it is
#   structurally correct and contains all required fields.
#
# Usage: bash tests/unit/test_nebula_model_manifest.sh
# Exit:  0 all tests passed, 1 one or more failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/iso/config/nebula-model-manifest.json"

PASS=0
FAIL=0
ERRORS=()

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; NC=$'\033[0m'
else
    GREEN="" RED="" NC=""
fi

pass() { ((PASS+=1)); echo "${GREEN}  PASS${NC}: $1"; }
fail() {
    ((FAIL+=1))
    ERRORS+=("FAIL: $1${2:+ — $2}")
    echo "${RED}  FAIL${NC}: $1${2:+ — $2}"
}

echo "================================================================"
echo "test_nebula_model_manifest.sh — W11-1 manifest structural tests (Qwen2.5-3B-Instruct Q4_K_M)"
echo "Manifest: $MANIFEST"
echo "================================================================"
echo ""

# ===========================================================================
# T1: File existence and JSON parseability
# ===========================================================================
echo "[T1] Manifest file exists and parses as valid JSON"
if [[ -f "$MANIFEST" ]]; then
    pass "iso/config/nebula-model-manifest.json exists"
else
    fail "iso/config/nebula-model-manifest.json exists" \
         "Not found at $MANIFEST"
    echo "================================================================"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if python3 -c "import json; json.load(open('$MANIFEST'))" 2>/dev/null; then
    pass "manifest parses as valid JSON"
else
    fail "manifest parses as valid JSON" \
         "python3 json.load failed — malformed JSON in $MANIFEST"
    echo "================================================================"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
echo ""

# ===========================================================================
# T2: Required keys present
# ===========================================================================
echo "[T2] Required keys present in manifest"
REQUIRED_KEYS=(
    "manifest_schema_version"
    "model_filename"
    "model_url_primary"
    "model_url_fallback"
    "model_sha256"
    "model_size_bytes"
    "model_quantization"
    "model_license"
)
for key in "${REQUIRED_KEYS[@]}"; do
    VALUE="$(python3 -c "import json,sys; d=json.load(open('$MANIFEST')); print(d.get('$key','__MISSING__'))" 2>/dev/null)"
    if [[ "$VALUE" != "__MISSING__" ]]; then
        pass "manifest contains required key: $key"
    else
        fail "manifest contains required key: $key" \
             "Key '$key' not found in $MANIFEST"
    fi
done
echo ""

# ===========================================================================
# T3: model_filename matches expected name (DEC-PHASE11-002 invariant)
# ===========================================================================
echo "[T3] model_filename is Qwen2.5-3B-Instruct-Q4_K_M.gguf (DEC-PHASE11-002)"
MODEL_FILENAME="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_filename'])" 2>/dev/null)"
EXPECTED_FILENAME="Qwen2.5-3B-Instruct-Q4_K_M.gguf"
if [[ "$MODEL_FILENAME" == "$EXPECTED_FILENAME" ]]; then
    pass "model_filename == $EXPECTED_FILENAME"
else
    fail "model_filename == $EXPECTED_FILENAME" \
         "Got: $MODEL_FILENAME (DEC-PHASE11-002 mandates Qwen2.5-3B-Instruct Q4_K_M)"
fi
echo ""

# ===========================================================================
# T4: model_sha256 is a 64-char lowercase hex string OR the allowed sentinel
# ===========================================================================
echo "[T4] model_sha256 is 64-char lowercase hex or TBD sentinel"
SHA256="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_sha256'])" 2>/dev/null)"
SENTINEL="TBD-VERIFY-AT-DOWNLOAD"
if [[ "$SHA256" == "$SENTINEL" ]]; then
    pass "model_sha256 is the trust-on-first-use sentinel ($SENTINEL)"
    echo "  NOTE: Pin the real SHA-256 after the first successful build (DEC-PHASE10-008)."
elif [[ ${#SHA256} -eq 64 ]] && echo "$SHA256" | grep -qE '^[0-9a-f]{64}$'; then
    pass "model_sha256 is a 64-char lowercase hex string"
else
    fail "model_sha256 is 64-char hex or TBD sentinel" \
         "Got: '$SHA256' (len=${#SHA256}) — expected 64-char hex or '$SENTINEL'"
fi
echo ""

# ===========================================================================
# T5: model_license is Apache-2.0
# ===========================================================================
echo "[T5] model_license is Apache-2.0"
LICENSE="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_license'])" 2>/dev/null)"
if [[ "$LICENSE" == "Apache-2.0" ]]; then
    pass "model_license == Apache-2.0"
else
    fail "model_license == Apache-2.0" \
         "Got: $LICENSE — Qwen2.5-3B-Instruct is Apache-2.0 (DEC-PHASE11-002)"
fi
echo ""

# ===========================================================================
# T6: manifest_schema_version is 1
# ===========================================================================
echo "[T6] manifest_schema_version == 1"
SCHEMA_VER="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['manifest_schema_version'])" 2>/dev/null)"
if [[ "$SCHEMA_VER" == "1" ]]; then
    pass "manifest_schema_version == 1"
else
    fail "manifest_schema_version == 1" "Got: $SCHEMA_VER"
fi
echo ""

# ===========================================================================
# T7: model_url_primary and model_url_fallback are HTTPS HuggingFace URLs
# ===========================================================================
echo "[T7] model_url_primary and model_url_fallback are HuggingFace HTTPS URLs"
URL_PRIMARY="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_url_primary'])" 2>/dev/null)"
URL_FALLBACK="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_url_fallback'])" 2>/dev/null)"
for url_label_pair in "model_url_primary:$URL_PRIMARY" "model_url_fallback:$URL_FALLBACK"; do
    label="${url_label_pair%%:*}"
    url="${url_label_pair#*:}"
    if echo "$url" | grep -qE '^https://huggingface.co/'; then
        pass "$label is a HuggingFace HTTPS URL"
    else
        fail "$label is a HuggingFace HTTPS URL" "Got: $url"
    fi
    if echo "$url" | grep -qi "qwen"; then
        pass "$label URL references qwen model"
    else
        fail "$label URL references qwen model" "Got: $url — expected Qwen2.5-3B-Instruct (DEC-PHASE11-002)"
    fi
done
echo ""

# ===========================================================================
# T8: model_size_bytes is a positive integer in the expected range
#     (~1.9 GB; accept 1.5–2.5 GB as valid range for Qwen2.5-3B Q4_K_M)
# ===========================================================================
echo "[T8] model_size_bytes is in expected range for Q4_K_M (~1.9 GB)"
SIZE_BYTES="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_size_bytes'])" 2>/dev/null)"
LOWER=1500000000   # ~1.4 GB lower bound
UPPER=2500000000   # ~2.3 GB upper bound
if python3 -c "assert $LOWER < $SIZE_BYTES < $UPPER" 2>/dev/null; then
    SIZE_GB="$(python3 -c "print(f'{$SIZE_BYTES/1024/1024/1024:.2f}')")"
    pass "model_size_bytes=$SIZE_BYTES (~${SIZE_GB} GB) is in expected range"
else
    fail "model_size_bytes in range [$LOWER, $UPPER]" \
         "Got: $SIZE_BYTES — unexpected size for Qwen2.5-3B Q4_K_M (DEC-PHASE11-002)"
fi
echo ""

# ===========================================================================
# T9: DEC decision references present in the manifest
# ===========================================================================
echo "[T9] DEC decision references present in manifest"
MANIFEST_TEXT="$(cat "$MANIFEST")"
for dec_ref in "DEC-PHASE11-002" "DEC-PHASE10-008"; do
    if echo "$MANIFEST_TEXT" | grep -q "$dec_ref"; then
        pass "manifest references $dec_ref"
    else
        fail "manifest references $dec_ref" \
             "Decision reference '$dec_ref' not found in $MANIFEST"
    fi
done
echo ""

# ===========================================================================
# T10: primary URL is bartowski mirror, fallback is Qwen upstream mirror
#      (DEC-PHASE11-002: bartowski primary / Qwen team upstream fallback)
# ===========================================================================
echo "[T10] URL mirrors are non-gated bartowski (primary) and Qwen upstream (fallback)"
URL_PRIMARY="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_url_primary'])" 2>/dev/null)"
URL_FALLBACK="$(python3 -c "import json; print(json.load(open('$MANIFEST'))['model_url_fallback'])" 2>/dev/null)"
if echo "$URL_PRIMARY" | grep -q "bartowski"; then
    pass "model_url_primary uses bartowski mirror (non-gated)"
else
    fail "model_url_primary uses bartowski mirror" \
         "Got: $URL_PRIMARY — expected bartowski/Qwen2.5-3B-Instruct-GGUF (DEC-PHASE11-002)"
fi
if echo "$URL_FALLBACK" | grep -qi "Qwen/Qwen"; then
    pass "model_url_fallback uses Qwen upstream mirror (non-gated)"
else
    fail "model_url_fallback uses Qwen upstream mirror" \
         "Got: $URL_FALLBACK — expected Qwen/Qwen2.5-3B-Instruct-GGUF upstream (DEC-PHASE11-002)"
fi
echo ""

# ===========================================================================
# T11: No Mistral or TheBloke references remain in any URL (model-swap guard)
# ===========================================================================
echo "[T11] No Mistral or TheBloke URL references remain in manifest (model-swap guard)"
if python3 -c "
import json, sys
d = json.load(open('$MANIFEST'))
urls = [d.get('model_url_primary',''), d.get('model_url_fallback','')]
for u in urls:
    if 'TheBloke' in u or 'mistral' in u.lower():
        sys.exit(1)
sys.exit(0)
" 2>/dev/null; then
    pass "No Mistral or TheBloke URL references in manifest (model-swap guard, DEC-PHASE11-002)"
else
    fail "No Mistral or TheBloke URL references in manifest" \
         "Mistral/TheBloke URLs must be replaced with Qwen2.5-3B-Instruct mirrors (DEC-PHASE11-002)"
fi
echo ""

# ===========================================================================
# Summary
# ===========================================================================
echo "================================================================"
echo "Results: $PASS passed, $FAIL failed"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do echo "  $err"; done
fi
echo "================================================================"

[[ $FAIL -eq 0 ]]
