#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_nebula_model_store.sh — scripts/nebula/store.py (DEC-PHASE12-016)
#
# Functional tests against a fake ollama store (real files, real hashes):
# consolidate keeps exactly the manifest-referenced blobs, deletes orphans and
# the source GGUF, writes a MANIFEST.sha256 that integrity.py accepts, and
# REFUSES (deleting nothing) when the store cannot be verified.  Plus static
# checks that the 0510 hook actually calls it.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
STORE_PY="$REPO_ROOT/scripts/nebula/store.py"
INTEGRITY_PY="$REPO_ROOT/scripts/nebula/integrity.py"
HOOK="$REPO_ROOT/iso/config/hooks/live/0510-register-nebula-model.hook.chroot"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

SCRATCH="$REPO_ROOT/tmp/test_nebula_model_store_$$"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT
export PYTHONPYCACHEPREFIX="$SCRATCH/pyc"

# Build a fake ollama store. Returns nothing; sets LIVE, CFG, ORPHAN hashes.
make_store() {
    local d="$1"
    rm -rf "$d"; mkdir -p "$d/blobs" "$d/manifests/registry.ollama.ai/library/qwen2.5"
    printf 'RE-SERIALISED LIVE MODEL LAYER' > "$d/live.tmp"
    LIVE="$(shasum -a 256 "$d/live.tmp" | awk '{print $1}')"; mv "$d/live.tmp" "$d/blobs/sha256-$LIVE"
    printf '{"model_format":"gguf","model_type":"3B"}' > "$d/cfg.tmp"
    CFG="$(shasum -a 256 "$d/cfg.tmp" | awk '{print $1}')"; mv "$d/cfg.tmp" "$d/blobs/sha256-$CFG"
    # The source GGUF and ollama's orphaned first copy are byte-identical (as on dev7).
    printf 'ORIGINAL SOURCE GGUF BYTES' > "$d/Qwen.gguf"
    ORPHAN="$(shasum -a 256 "$d/Qwen.gguf" | awk '{print $1}')"; cp "$d/Qwen.gguf" "$d/blobs/sha256-$ORPHAN"
    # Legacy manifest (what stage_nebula_model wrote) points at the bare GGUF.
    printf '%s  Qwen.gguf\n' "$ORPHAN" > "$d/MANIFEST.sha256"
    local live_size cfg_size
    live_size=$(stat -f %z "$d/blobs/sha256-$LIVE" 2>/dev/null || stat -c %s "$d/blobs/sha256-$LIVE")
    cfg_size=$(stat -f %z "$d/blobs/sha256-$CFG" 2>/dev/null || stat -c %s "$d/blobs/sha256-$CFG")
    cat > "$d/manifests/registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M" <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.docker.distribution.manifest.v2+json",
 "config":{"mediaType":"application/vnd.docker.container.image.v1+json","digest":"sha256:$CFG","size":$cfg_size},
 "layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:$LIVE","size":$live_size}]}
EOF
}

section "module + CLI"
[[ -f "$STORE_PY" ]] && pass "store.py present" || { fail "store.py" "missing"; exit 1; }
PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/orionx-pycache" python3 -m py_compile "$STORE_PY" && pass "store.py compiles" || fail "compile" "py_compile failed"
python3 "$STORE_PY" --help >/dev/null 2>&1 && pass "--help works" || fail "--help" "non-zero"
python3 "$STORE_PY" consolidate >/dev/null 2>&1; [[ $? -eq 2 ]] && pass "missing --models-dir → usage error 2" || fail "usage error" "expected 2"
grep -q "DEC-PHASE12-016" "$STORE_PY" && pass "DEC-PHASE12-016 annotated" || fail "annotation" "missing"

section "consolidate: happy path"
S="$SCRATCH/store"; make_store "$S"
OUT="$(python3 "$STORE_PY" consolidate --models-dir "$S" --source-gguf "$S/Qwen.gguf" 2>&1)"; RC=$?
[[ $RC -eq 0 ]] && pass "exit 0" || fail "exit 0" "rc=$RC: $OUT"
[[ -f "$S/blobs/sha256-$LIVE" ]] && pass "live model layer kept" || fail "live layer" "deleted!"
[[ -f "$S/blobs/sha256-$CFG" ]] && pass "config blob kept" || fail "config blob" "deleted!"
[[ ! -e "$S/blobs/sha256-$ORPHAN" ]] && pass "orphan blob (ollama's first copy) removed" || fail "orphan" "still present"
[[ ! -e "$S/Qwen.gguf" ]] && pass "source GGUF removed" || fail "source gguf" "still present"
[[ -f "$S/manifests/registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M" ]] && pass "ollama manifest untouched" || fail "manifest" "gone"
FIRST="$(grep -v '^#' "$S/MANIFEST.sha256" | head -1)"
[[ "$FIRST" == "$LIVE  blobs/sha256-$LIVE" ]] && pass "MANIFEST.sha256 first line = live model layer (status.py sizes it)" || fail "manifest line 1" "$FIRST"
[[ "$(grep -c -v '^#' "$S/MANIFEST.sha256")" == "2" ]] && pass "MANIFEST.sha256 lists exactly the 2 referenced blobs" || fail "manifest count" "$(cat "$S/MANIFEST.sha256")"
! grep -q "Qwen.gguf" "$S/MANIFEST.sha256" && pass "legacy bare-GGUF line gone" || fail "legacy line" "present"
echo "$OUT" | python3 -c "import json,sys; r=json.load(sys.stdin); assert r['removed_bytes']>0 and r['removed_source'] and len(r['removed_orphans'])==1; print('ok')" >/dev/null 2>&1 \
    && pass "JSON report: removed_bytes>0, 1 orphan, source recorded" || fail "report" "$OUT"
# The boot gate must accept what consolidate wrote.
STATUS="$SCRATCH/st.status"
PYTHONPATH="$REPO_ROOT/scripts" TEST_NEBULA_MODELS_DIR="$S" python3 "$INTEGRITY_PY" --models-dir "$S" --manifest "$S/MANIFEST.sha256" --status-file "$STATUS" >/dev/null 2>&1; RC=$?
[[ $RC -eq 0 ]] && grep -q 'NEBULA_INTEGRITY=OK' "$STATUS" && pass "integrity.py verifies the consolidated store (exit 0, OK)" || fail "integrity on store" "rc=$RC $(cat "$STATUS" 2>/dev/null)"
# Idempotent: second run is a no-op that still succeeds.
python3 "$STORE_PY" consolidate --models-dir "$S" --source-gguf "$S/Qwen.gguf" >/dev/null 2>&1 && [[ -f "$S/blobs/sha256-$LIVE" ]] \
    && pass "second run idempotent (source already gone, nothing else removed)" || fail "idempotent" "second run failed or deleted a live blob"

section "consolidate: --dry-run deletes nothing"
S2="$SCRATCH/store2"; make_store "$S2"
python3 "$STORE_PY" consolidate --models-dir "$S2" --source-gguf "$S2/Qwen.gguf" --dry-run >/dev/null 2>&1; RC=$?
[[ $RC -eq 0 && -f "$S2/Qwen.gguf" && -f "$S2/blobs/sha256-$ORPHAN" ]] && pass "dry-run: exit 0, source + orphan still present" || fail "dry-run" "rc=$RC"
grep -q "Qwen.gguf" "$S2/MANIFEST.sha256" && pass "dry-run: MANIFEST.sha256 not rewritten" || fail "dry-run manifest" "rewritten"

section "consolidate: refuses and keeps everything when the store is doubtful"
S3="$SCRATCH/store3"; make_store "$S3"; printf 'X' >> "$S3/blobs/sha256-$LIVE"
python3 "$STORE_PY" consolidate --models-dir "$S3" --source-gguf "$S3/Qwen.gguf" >/dev/null 2>"$SCRATCH/err3"; RC=$?
[[ $RC -eq 1 ]] && grep -q "REFUSED" "$SCRATCH/err3" && pass "tampered live blob → exit 1 REFUSED" || fail "tampered refuse" "rc=$RC $(cat "$SCRATCH/err3")"
[[ -f "$S3/Qwen.gguf" && -f "$S3/blobs/sha256-$ORPHAN" ]] && pass "refusal deleted nothing (source + orphan intact)" || fail "refusal safety" "files deleted"
grep -q "Qwen.gguf" "$S3/MANIFEST.sha256" && pass "refusal left MANIFEST.sha256 alone" || fail "refusal manifest" "rewritten"
S4="$SCRATCH/store4"; make_store "$S4"; rm "$S4/blobs/sha256-$LIVE"
python3 "$STORE_PY" consolidate --models-dir "$S4" --source-gguf "$S4/Qwen.gguf" >/dev/null 2>&1; RC=$?
[[ $RC -eq 1 && -f "$S4/Qwen.gguf" ]] && pass "missing referenced blob → refuse, source kept" || fail "missing blob" "rc=$RC"
S5="$SCRATCH/store5"; make_store "$S5"; rm -rf "$S5/manifests"
python3 "$STORE_PY" consolidate --models-dir "$S5" --source-gguf "$S5/Qwen.gguf" >/dev/null 2>&1; RC=$?
[[ $RC -eq 1 && -f "$S5/Qwen.gguf" && -f "$S5/blobs/sha256-$ORPHAN" ]] && pass "no ollama manifests → refuse, nothing deleted" || fail "no manifests" "rc=$RC"
S6="$SCRATCH/store6"; make_store "$S6"
python3 - "$S6/manifests/registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["layers"][0]["size"]+=7; json.dump(d,open(p,"w"))
PY
python3 "$STORE_PY" consolidate --models-dir "$S6" --source-gguf "$S6/Qwen.gguf" >/dev/null 2>&1; RC=$?
[[ $RC -eq 1 && -f "$S6/Qwen.gguf" ]] && pass "manifest size ≠ file size → refuse" || fail "size mismatch" "rc=$RC"

section "0510 hook wiring"
grep -q 'python3 "\$STORE_PY" consolidate --models-dir "\$MODELS_DIR" --source-gguf "\$GGUF"' "$HOOK" && pass "0510 runs store.py consolidate with --source-gguf" || fail "hook call" "missing"
grep -q 'STORE_PY="/opt/orionx/scripts/nebula/store.py"' "$HOOK" && pass "0510 uses the staged /opt/orionx/scripts copy (single authority = scripts/)" || fail "hook path" "wrong"
grep -q 'FATAL: store consolidation refused' "$HOOK" && pass "0510 hard-fails when consolidation refuses (DEC-PHASE10-007)" || fail "hook hard-fail" "missing"
grep -q 'FATAL: source GGUF still present after consolidation' "$HOOK" && pass "0510 asserts the source GGUF is gone" || fail "hook gguf assert" "missing"
awk '/^cleanup$/{c=NR} /STORE_PY.*consolidate/{s=NR} END{exit !(c && s && c<s)}' "$HOOK" && pass "0510 stops the throwaway ollama server BEFORE deleting blobs" || fail "hook ordering" "server not stopped first"
! grep -q "retained on purpose" "$HOOK" && pass "stale 'GGUF retained on purpose' note removed" || fail "stale note" "present"
grep -q "DEC-PHASE12-016" "$HOOK" && pass "DEC-PHASE12-016 annotated in 0510" || fail "hook annotation" "missing"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
