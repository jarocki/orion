#!/usr/bin/env bash
# shellcheck shell=bash
#
# Integration test: Nebula AI runtime staging — end-to-end sha256sum integrity proof.
#
# This test extracts the squashfs from the built ISO, then asserts:
#   1. The ollama model store under /opt/orionx/nebula/models/ is the consolidated
#      single-copy layout (DEC-PHASE12-016): exactly one >1 GB blob, a manifest for
#      the tag pinned in iso/config/nebula-model-manifest.json, and MANIFEST.sha256
#      lines of the form `<hex64>  blobs/sha256-<hex64>` whose digest IS the blob's
#      content address.
#   2. sha256sum -c MANIFEST.sha256 passes against the extracted blobs (DEFINITIVE proof
#      that the staging + import + consolidation + integrity pipeline works end-to-end).
#   3. nebula-integrity-check.service is enabled (in multi-user.target.wants/).
#   4. nebula-runtime.service auto-starts; nebula-runtime.socket removed (DEC-PHASE11-033).
#   5. ollama binary present at /usr/local/bin/ollama (tarball install, not dpkg).
#
# @decision DEC-PHASE10-009
# @title nebula-integrity-check: boot-time SHA-256 gate that blocks nebula-runtime on mismatch
# @status accepted
# @rationale MANIFEST.sha256 is the root of the integrity chain: build-time SHA-256
#   verify → ollama import → store consolidation rewrites MANIFEST to the live blobs
#   (DEC-PHASE12-016) → squashfs staging → boot-time re-verify by integrity.py. This
#   test closes the loop by running `sha256sum -c MANIFEST.sha256` against the
#   extracted blobs, proving the chain is intact end-to-end without requiring QEMU
#   boot. A PASS here means the bytes ollama will actually load at runtime are
#   exactly the bytes the build verified. Any truncation, re-compression artefact,
#   or staging bug is detected here.
#
# @decision DEC-PHASE10-008
# @title stage_nebula_model: HF download + SHA-256 verify + MANIFEST generation
# @status accepted
# @rationale stage_nebula_model() is the single authority for model download and
#   SHA-256 verification against nebula-model-manifest.json. Since DEC-PHASE12-016
#   the shipped MANIFEST.sha256 is REWRITTEN by scripts/nebula/store.py after
#   `ollama create` (hook 0510-register-nebula-model.hook.chroot): the bare GGUF is
#   deleted and the manifest lists the ollama layer blob(s) instead, in the
#   sha256sum-compatible two-space format that `sha256sum -c` consumes natively.
#   Comment lines (`# ...`) are permitted at the top; sha256sum ignores them.
#
# Usage:
#   bash tests/integration/test-nebula-runtime.sh [path/to/orionx.iso]
#
# Default ISO path: output/orionx-phoenix-edition-v2.0.0-rc4.iso (positional arg $1 overrides)
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed or prerequisites missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ISO_PATH="${1:-$REPO_ROOT/output/orionx-phoenix-edition-v2.0.0-rc4.iso}"
WORK=""

# ---------------------------------------------------------------------------
# Test counters
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    NC=""
fi

pass() {
    ((PASS+=1))
    echo "${GREEN}  PASS${NC}: $1"
}

fail() {
    ((FAIL+=1))
    echo "${RED}  FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        $2"
    fi
}

section() {
    echo ""
    echo "--- $1 ---"
}

# shellcheck disable=SC2329  # cleanup is invoked indirectly via trap EXIT
cleanup() {
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

echo "=== W11-1 Nebula Runtime: End-to-End Integrity Integration Test (Qwen2.5-3B-Instruct Q4_K_M) ==="
echo "    ISO: $ISO_PATH"

# ===========================================================================
# 0. Prerequisites
# ===========================================================================
section "Prerequisites"

if [[ ! -f "$ISO_PATH" ]]; then
    echo "${RED}FATAL${NC}: ISO not found at $ISO_PATH"
    echo "       Build the ISO first: bash scripts/build-iso.sh"
    echo "       Or pass the ISO path as an argument: $0 /path/to/orionx.iso"
    exit 1
fi
echo "  ISO found: $ISO_PATH ($(du -sh "$ISO_PATH" | cut -f1))"

for tool in xorriso unsquashfs sha256sum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "${RED}FATAL${NC}: Required tool not found: $tool"
        echo "       Install with: sudo apt-get install -y xorriso squashfs-tools coreutils"
        exit 1
    fi
done
echo "  Tools available: xorriso, unsquashfs, sha256sum"

# ===========================================================================
# 1. Extract squashfs from ISO
#    Uses full extraction (DEC-PHASE9-012) so every assertion below works
#    without a per-path extraction list.
# ===========================================================================
section "Extracting squashfs from ISO"

WORK="$(mktemp -d)"
echo "  Working directory: $WORK"

echo "  Extracting /live/filesystem.squashfs from ISO..."
xorriso -osirrox on -indev "$ISO_PATH" \
    -extract /live/filesystem.squashfs "$WORK/squashfs.img" \
    2>/dev/null

if [[ ! -f "$WORK/squashfs.img" ]]; then
    echo "${RED}FATAL${NC}: squashfs extraction failed — $WORK/squashfs.img not created"
    exit 1
fi
echo "  squashfs.img extracted: $(du -sh "$WORK/squashfs.img" | cut -f1)"

echo "  Extracting full squashfs filesystem..."
# @decision DEC-PHASE9-012
# @title Full squashfs extraction replaces selective path extraction
# @status accepted
# @rationale See test-iso-content-presence.sh section 1 for full rationale.
#   Full extraction prevents "path not in extract list" bugs and makes every
#   future assertion work automatically. The || true guards unsquashfs minor
#   warnings under set -euo pipefail.
unsquashfs -d "$WORK/sqfs" "$WORK/squashfs.img" \
    2>/dev/null || true  # unsquashfs may exit non-zero on minor warnings; we assert individually

echo "  Full extraction complete."

SQF="$WORK/sqfs"
MODELS_DIR="$SQF/opt/orionx/nebula/models"
MANIFEST="$MODELS_DIR/MANIFEST.sha256"
MULTI_USER_WANTS="$SQF/etc/systemd/system/multi-user.target.wants"

# ===========================================================================
# 2. Model store layout (DEC-PHASE12-016) + DEFINITIVE sha256sum -c proof
#
#    Authority: scripts/nebula/store.py (consolidate) invoked by
#    iso/config/hooks/live/0510-register-nebula-model.hook.chroot. After
#    `ollama create` the hook (1) verifies every blob referenced by ollama's
#    manifests hashes to its own content-addressed name, (2) deletes orphan
#    blobs AND the source GGUF, (3) rewrites MANIFEST.sha256 to list the live
#    blob(s), model layer first. So the shipped image has:
#      /opt/orionx/nebula/models/blobs/sha256-<hex64>       (exactly ONE >1 GB blob)
#      /opt/orionx/nebula/models/manifests/registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M
#      /opt/orionx/nebula/models/MANIFEST.sha256   lines: "<hex64>  blobs/sha256-<hex64>"
#    and NO bare Qwen2.5-3B-Instruct-Q4_K_M.gguf.
#
#    The pipeline this proves end-to-end:
#      build-iso.sh stage_nebula_model()
#        → download Qwen2.5-3B-Instruct Q4_K_M GGUF (DEC-PHASE11-002)
#        → sha256sum verify against nebula-model-manifest.json
#      hook 0510 → ollama create (DEC-PHASE11-021) → store.py consolidate
#        → MANIFEST.sha256 rewritten to the live ollama layer (DEC-PHASE12-016)
#      live-build squashfs sealing
#        → blobs/ + manifests/ + MANIFEST byte-for-byte copied into squashfs
#      THIS TEST: extract squashfs, run sha256sum -c MANIFEST.sha256
#        → PASS = every byte ollama will load at runtime is what the build verified
# ===========================================================================
section "Model store layout (DEC-PHASE12-016)"

BLOBS_DIR="$MODELS_DIR/blobs"
# Tag is pinned in iso/config/nebula-model-manifest.json ("ollama_model_tag":
# "qwen2.5:3b-instruct-q4_K_M"); ollama lays it out as library/<name>/<tag>.
OLLAMA_MANIFEST="$MODELS_DIR/manifests/registry.ollama.ai/library/qwen2.5/3b-instruct-q4_K_M"
SOURCE_GGUF="$MODELS_DIR/Qwen2.5-3B-Instruct-Q4_K_M.gguf"

# (a) exactly one blob larger than 1 GB (the Q4_K_M model layer is ~1.93 GB;
#     a second one would mean the orphan-blob purge of DEC-PHASE12-016 regressed)
LARGE_BLOB_COUNT=0
if [[ -d "$BLOBS_DIR" ]]; then
    LARGE_BLOB_COUNT="$(find "$BLOBS_DIR" -maxdepth 1 -type f -name 'sha256-*' -size +1G 2>/dev/null | wc -l | tr -d ' ')"
fi
if [[ "$LARGE_BLOB_COUNT" -eq 1 ]]; then
    pass "blobs/ contains exactly one blob > 1 GB (single-copy store — DEC-PHASE12-016)"
else
    fail "blobs/ contains exactly one blob > 1 GB" \
         "Found $LARGE_BLOB_COUNT blob(s) > 1 GB under $BLOBS_DIR — 0 means the model was never imported (DEC-PHASE11-021); 2+ means store.py consolidate did not purge the orphan (DEC-PHASE12-016)"
fi

# (b) ollama manifest for the pinned tag exists
if [[ -f "$OLLAMA_MANIFEST" ]]; then
    pass "ollama manifest present for qwen2.5:3b-instruct-q4_K_M (hook 0510 registration)"
else
    fail "ollama manifest present for qwen2.5:3b-instruct-q4_K_M" \
         "Missing: ${OLLAMA_MANIFEST#"$SQF"} — 'ollama create' did not register the tag pinned in nebula-model-manifest.json"
fi

# (c) the bare GGUF must be GONE (store.py deletes it; hook 0510 hard-fails if it survives)
if [[ ! -e "$SOURCE_GGUF" ]]; then
    pass "bare source GGUF absent (ollama blob store is the single copy — DEC-PHASE12-016)"
else
    fail "bare source GGUF absent" \
         "Qwen2.5-3B-Instruct-Q4_K_M.gguf still present next to blobs/ — two ~1.9 GB copies in the squashfs (DEC-PHASE12-016 regression)"
fi

section "DEFINITIVE: sha256sum -c MANIFEST.sha256 (end-to-end integrity proof)"

if [[ ! -f "$MANIFEST" ]]; then
    fail "MANIFEST.sha256 present in squashfs" \
         "store.py consolidate must write MANIFEST.sha256 into the models dir (DEC-PHASE12-016)"
else
    pass "MANIFEST.sha256 present at $MODELS_DIR/MANIFEST.sha256"

    # (d) every non-comment line has the store.py shape "<hex64>  blobs/sha256-<hex64>"
    #     and the digest of each entry equals its filename suffix (content address).
    # || true: grep exits 1 on no match (DEC-PHASE9-014 pipefail guard).
    MANIFEST_ENTRIES="$(grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$' || true)"
    ENTRY_COUNT="$(printf '%s\n' "$MANIFEST_ENTRIES" | grep -c . || true)"
    BAD_ENTRIES="$(printf '%s\n' "$MANIFEST_ENTRIES" | grep -vE '^[0-9a-f]{64}  blobs/sha256-[0-9a-f]{64}$' || true)"
    if [[ "$ENTRY_COUNT" -ge 1 && -z "$BAD_ENTRIES" ]]; then
        pass "MANIFEST.sha256 has $ENTRY_COUNT entry(ies), all of the form '<hex64>  blobs/sha256-<hex64>' (DEC-PHASE12-016)"
    else
        fail "MANIFEST.sha256 entries have the form '<hex64>  blobs/sha256-<hex64>'" \
             "entries=$ENTRY_COUNT; malformed: ${BAD_ENTRIES:-<none>} — MANIFEST was not rewritten by store.py (still the bare-GGUF format?)"
    fi

    FIRST_DIGEST="$(printf '%s\n' "$MANIFEST_ENTRIES" | head -1 | awk '{print $1}')"
    FIRST_PATH="$(printf '%s\n' "$MANIFEST_ENTRIES" | head -1 | awk '{print $2}')"
    if [[ -n "$FIRST_DIGEST" && "$FIRST_PATH" == "blobs/sha256-${FIRST_DIGEST}" ]]; then
        pass "first MANIFEST entry (model layer) digest equals its blob filename suffix (content-addressed)"
    else
        fail "first MANIFEST entry digest equals its blob filename suffix" \
             "digest='${FIRST_DIGEST:-<none>}' path='${FIRST_PATH:-<none>}' — the hash must BE the blob's content address (store.py invariant)"
    fi

    # (e) sha256sum -c runs from the models dir (MANIFEST paths are relative:
    #     blobs/sha256-...). Comment lines are ignored by sha256sum.
    #     Capture stderr+stdout for diagnostic output on failure.
    SHA_OUTPUT=""
    SHA_RC=0
    SHA_OUTPUT="$(cd "$MODELS_DIR" && sha256sum -c MANIFEST.sha256 2>&1)" || SHA_RC=$?

    if [[ "$SHA_RC" -eq 0 ]]; then
        pass "sha256sum -c MANIFEST.sha256 PASSED — live model blob integrity confirmed end-to-end (DEC-PHASE10-009, DEC-PHASE12-016)"
        echo "        sha256sum output: $SHA_OUTPUT"
    else
        # Expected vs actual SHA of the first (model-layer) entry for diagnostic clarity
        ACTUAL_SHA=""
        if [[ -n "$FIRST_PATH" && -f "$MODELS_DIR/$FIRST_PATH" ]]; then
            ACTUAL_SHA="$(sha256sum "$MODELS_DIR/$FIRST_PATH" 2>/dev/null | awk '{print $1}' || true)"
        fi
        fail "sha256sum -c MANIFEST.sha256 PASSED" \
             "INTEGRITY MISMATCH — expected: ${FIRST_DIGEST:-unknown}  got: ${ACTUAL_SHA:-unknown}"
        echo "        sha256sum output: $SHA_OUTPUT"
        echo "        This means a blob was corrupted, truncated, or staged incorrectly."
        echo "        Rebuild the ISO and inspect hook 0510 / scripts/nebula/store.py output."
    fi
fi

# ===========================================================================
# 3. Boot-time gate: nebula-integrity-check.service enabled (DEC-PHASE10-009)
# ===========================================================================
section "Boot-time gate: nebula-integrity-check.service in multi-user.target.wants/"

if [[ -L "$MULTI_USER_WANTS/nebula-integrity-check.service" ]] || \
   [[ -f "$MULTI_USER_WANTS/nebula-integrity-check.service" ]]; then
    pass "nebula-integrity-check.service in multi-user.target.wants/ (boot gate enabled — DEC-PHASE10-009)"
else
    fail "nebula-integrity-check.service in multi-user.target.wants/" \
         "systemctl enable nebula-integrity-check.service must run in 0615 hook — boot gate not active"
fi

# ===========================================================================
# 4. nebula-runtime.service auto-starts; the socket unit is REMOVED
#    (DEC-PHASE11-033: ollama serve binds :11434 itself and cannot accept a
#    systemd socket fd — the old socket caused an EADDRINUSE restart loop)
# ===========================================================================
section "nebula-runtime.service auto-starts; socket removed (DEC-PHASE11-033)"

if [[ ! -f "$SQF/lib/systemd/system/nebula-runtime.socket" ]]; then
    pass "nebula-runtime.socket is absent from the squashfs (socket activation removed, DEC-PHASE11-033)"
else
    fail "nebula-runtime.socket must NOT be installed" \
         "Socket activation is incompatible with ollama serve; unit deleted (DEC-PHASE11-033)"
fi

# The service itself must be auto-enabled (multi-user.target.wants/) now.
# -L, not -e: the wants/ entry is a symlink to an ABSOLUTE target
# (/lib/systemd/system/...) which does not resolve inside the extracted tree,
# so -e reports a present symlink as missing (false negative).
if [[ -L "$MULTI_USER_WANTS/nebula-runtime.service" ]]; then
    pass "nebula-runtime.service IS in multi-user.target.wants/ (auto-started — DEC-PHASE11-033)"
else
    fail "nebula-runtime.service in multi-user.target.wants/" \
         "0615 hook must 'systemctl enable nebula-runtime.service' (ollama no longer socket-activated)"
fi

# ===========================================================================
# 5. ollama binary present at /usr/local/bin/ollama (DEC-PHASE10-007 iter-8)
#    Hook 0500-install-external-tools.hook.chroot extracts the upstream
#    .tar.zst to /usr/local/ — ollama is NOT a dpkg package and there is no
#    /usr/bin/ollama, so neither dpkg/status nor /usr/bin is an acceptable proxy.
# ===========================================================================
section "ollama binary present at /usr/local/bin/ollama (DEC-PHASE10-007)"

if [[ -x "$SQF/usr/local/bin/ollama" ]]; then
    pass "ollama binary present + executable at /usr/local/bin/ollama (tar.zst install — DEC-PHASE10-007)"
else
    fail "ollama binary present at /usr/local/bin/ollama" \
         "0500-install-external-tools.hook.chroot must extract the ollama .tar.zst to /usr/local/ (DEC-PHASE10-007)"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL ))
echo "Results: $PASS passed, $FAIL failed (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    echo "${RED}FAIL${NC}: Nebula runtime integration test failed — $FAIL assertion(s) failed"
    exit 1
fi
echo "${GREEN}PASS${NC}: Nebula runtime integration test passed — all $PASS assertions passed"
echo ""
echo "NOTE: The sha256sum PASS above is DEFINITIVE proof that:"
echo "  - The Qwen2.5-3B-Instruct Q4_K_M model was imported into ollama's store and shipped as a single blob (DEC-PHASE11-002, DEC-PHASE12-016)"
echo "  - MANIFEST.sha256 records the live blob's content address for integrity.py to verify at boot"
echo "  - The full staging + import + consolidation + integrity chain (DEC-PHASE10-008/009, DEC-PHASE11-021, DEC-PHASE12-016) is functional"
exit 0
