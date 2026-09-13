#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_go_roast.sh — go-roast OAST tool port (roadmap #91)
#
# Verifies the vendored static `roast` binary is staged and portable, that it is
# registered into the Nebula MCP registry, and (when Docker is available) that it
# actually runs and decodes OAST domains. DEC-PHASE12-002.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf "  ${YELLOW}SKIP${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

BIN="$REPO_ROOT/iso/config/includes.chroot/usr/local/bin/roast"
MCP="$REPO_ROOT/scripts/nebula/mcp_server.py"

section "Binary: staged, executable, portable"
if [[ -f "$BIN" ]]; then pass "roast binary staged at includes.chroot/usr/local/bin/roast"; else fail "roast binary staged" "missing"; fi
if [[ -x "$BIN" ]]; then pass "roast binary is executable"; else fail "roast binary executable" "not +x"; fi
# Static linux/amd64 ELF — must be portable across the base-distro migration.
if file "$BIN" 2>/dev/null | grep -q "ELF 64-bit.*x86-64"; then
    pass "roast is an x86-64 ELF"
else
    fail "roast is an x86-64 ELF" "file type unexpected: $(file "$BIN" 2>/dev/null | cut -d: -f2-)"
fi
if file "$BIN" 2>/dev/null | grep -qi "statically linked"; then
    pass "roast is statically linked (no libc/Python dep — distro-independent)"
else
    fail "roast statically linked" "dynamic binary would risk breaking across distro upgrades"
fi
if [[ -f "$REPO_ROOT/iso/config/includes.chroot/usr/local/share/orionx/roast.provenance.txt" ]]; then
    pass "provenance recorded (source repo + commit + build flags)"
else
    fail "provenance recorded" "roast.provenance.txt missing"
fi

section "MCP: registered into the Nebula tool registry"
for tool in oast_extract oast_decode oast_analyze; do
    if grep -q "\"$tool\"" "$MCP"; then pass "MCP tool $tool registered"; else fail "MCP tool $tool registered" "not in mcp_server.py"; fi
done
if grep -q 'needs="roast"' "$MCP"; then
    pass "OAST tools preflight the roast binary (needs=\"roast\")"
else
    fail "OAST tools preflight roast" 'no needs="roast" in mcp_server.py'
fi
if grep -q "DEC-PHASE12-002" "$MCP"; then pass "DEC-PHASE12-002 annotation present"; else fail "DEC-PHASE12-002 annotation" "missing"; fi
# Registry must still import and expose the three tools with file schemas.
if python3 - "$MCP" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("mcp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tools = {t["name"]: t for t in m.list_tools()}
for name in ("oast_extract", "oast_decode", "oast_analyze"):
    assert name in tools, f"{name} missing from list_tools()"
    props = tools[name]["inputSchema"]["properties"]
    assert "file" in props, f"{name} missing 'file' arg"
# argv builders must call roast with the file, no shell
t = m._TOOLS["oast_decode"]
argv = t.build_argv({"file": "/tmp/x"})
assert argv[0] == "roast" and "/tmp/x" in argv, argv
print("MCP_OK")
PY
then
    pass "list_tools() exposes the 3 OAST tools with a file arg + safe argv"
else
    fail "list_tools() OAST tools" "registry import/schema check failed"
fi

section "Functional: roast runs and decodes (needs Docker linux/amd64)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    OUT=$(docker run --rm --platform linux/amd64 -v "$BIN:/usr/local/bin/roast:ro" debian:trixie-slim \
        sh -c 'printf "abcdefghijklmnopqrstuvwxyz012345.oast.fun\n" | roast decode -o json' 2>&1)
    if printf '%s' "$OUT" | grep -q '"original"'; then
        pass "roast decode runs on trixie/amd64 and emits JSON"
    else
        fail "roast decode runs" "unexpected output: $(printf '%s' "$OUT" | head -c 200)"
    fi
else
    skip "roast decode functional run" "Docker not available"
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, ${YELLOW}%d skipped${NC}\n" "$PASS" "$FAIL" "$SKIP"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
