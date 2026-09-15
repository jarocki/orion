#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_nucleotide.sh — nucleotide port (roadmap #89, DEC-PHASE12-012)
#
# Vendored package + launcher, event-bus watcher logic, build-time lookup hook,
# Nebula MCP registration, packaging, and (with Docker) a live run on trixie.
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

N="$REPO_ROOT/scripts/nucleotide"
HOOK="$REPO_ROOT/iso/config/hooks/live/0520-nucleotide-lookup.hook.chroot"
SETUP="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
PKGS="$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"
MCP="$REPO_ROOT/scripts/nebula/mcp_server.py"

section "Vendored package + launcher"
[[ -f "$N/nucleotide/__init__.py" && -f "$N/nucleotide/cli.py" && -f "$N/nucleotide/__main__.py" ]] \
    && pass "nucleotide package vendored (cli + __main__)" || fail "nucleotide package vendored" "missing files"
[[ -f "$N/nucleotide/data/common-words.txt" ]] && pass "package data (common-words.txt) present" || fail "package data" "common-words.txt missing"
if find "$N/nucleotide" -name "__pycache__" | grep -q .; then fail "no __pycache__ vendored" "stale bytecode committed"; else pass "no __pycache__ vendored"; fi
[[ -x "$N/nucleotide-cli" ]] && pass "nucleotide-cli launcher executable" || fail "nucleotide-cli launcher" "missing/not +x"
grep -q 'exec python3 -m nucleotide' "$N/nucleotide-cli" && pass "launcher runs python3 -m nucleotide (no pip/venv)" || fail "launcher form" "expected python3 -m nucleotide"
grep -q 'while \[ -h "\$_SOURCE" \]' "$N/nucleotide-cli" && pass "launcher resolves its /usr/bin symlink" || fail "launcher symlink resolution" "missing readlink loop"
[[ -f "$N/PROVENANCE.txt" && -f "$N/LICENSE.nucleotide" ]] && pass "provenance + upstream licence shipped" || fail "provenance/licence" "missing"
if python3 -m py_compile "$N/orionx-nucleotide-watch" 2>/dev/null; then pass "orionx-nucleotide-watch compiles"; else fail "watch compiles" "py_compile error"; fi
# Third-party surface must stay exactly {yaml}: anything else would need packaging work.
extra=$(grep -rhoE "^(import|from) [a-zA-Z_]+" "$N/nucleotide" | awk '{print $2}' | sort -u \
        | grep -vxE "os|sys|re|json|pathlib|typing|dataclasses|collections|argparse|hashlib|datetime|itertools|functools|enum|logging|time|math|io|subprocess|shutil|textwrap|string|abc|copy|glob|fnmatch|urllib|statistics|__future__|nucleotide|importlib|csv|random|tempfile|contextlib|operator|heapq|bisect|difflib|unicodedata|base64|struct|socket|ipaddress|warnings|tarfile|yaml" || true)
[[ -z "$extra" ]] && pass "only third-party dep is yaml (python3-yaml)" || fail "unexpected third-party imports" "$extra"
grep -qE "^python3-yaml$" "$PKGS" && pass "python3-yaml in package list" || fail "python3-yaml in package list" "missing"

section "Watcher logic (URL → template → event bus)"
if python3 - "$N" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
w = SourceFileLoader("w", sys.argv[1] + "/orionx-nucleotide-watch").load_module()
line = "https://v/wp-content/plugins/akismet/readme.txt\tUNIQUE\twordpress-akismet\takismet\tinfo\tAkismet Anti-spam Detection\tmedium"
h = w.parse_lookup_line(line); assert h and h["verdict"] == "UNIQUE" and h["template_id"] == "wordpress-akismet" and h["quality"] == "medium"
assert w.parse_lookup_line("garbage line") is None and w.parse_lookup_line("") is None
amb = w.parse_lookup_line(line.replace("UNIQUE", "AMBIGUOUS"))
assert amb and not w.should_publish(amb, "medium"), "AMBIGUOUS must never publish"
assert w.should_publish(h, "medium") and w.should_publish(h, "weak") and not w.should_publish(h, "strong")
assert w.bus_severity("info") == "info" and w.bus_severity("low") == "notice"
assert w.bus_severity("medium") == "warning" and w.bus_severity("high") == "critical" and w.bus_severity("critical") == "critical"
assert w.bus_severity("weird") == "notice"
print("ok")
PY
then pass "parse / publish-gate / severity mapping correct"; else fail "watcher logic" "assertion failed"; fi

section "Build-time lookup hook (0520)"
[[ -x "$HOOK" ]] && pass "0520 hook present + executable" || fail "0520 hook" "missing/not +x"
bash -n "$HOOK" 2>/dev/null && pass "0520 hook bash syntax" || fail "0520 hook syntax" "bash -n failed"
grep -q "projectdiscovery/nuclei-templates" "$HOOK" && grep -q -- "--templates-dir" "$HOOK" && pass "hook clones nuclei-templates and builds from it" || fail "hook build step" "missing clone/--templates-dir"
grep -q "|| {" "$HOOK" && grep -q "WARNING: nucleotide lookup build failed" "$HOOK" && pass "hook is soft-fail (GitHub outage cannot abort the ISO)" || fail "hook soft-fail" "no warn-and-continue block"
grep -qE 'rm -rf "\$CACHE_DIR"' "$HOOK" && pass "hook deletes the ~100 MB template clone (not shipped)" || fail "hook cleanup" "clone would ship in the image"
grep -q -- "--snort-out-dir" "$HOOK" && ! grep -q -- "--sigma-out-dir" "$HOOK" && pass "ships Snort rules, skips Sigma (no SIEM on the deck)" || fail "rule outputs" "expected snort yes / sigma no"
grep -qE "timeout [0-9]+ git clone|timeout [0-9]+ \"\\\$LAUNCHER\"" "$HOOK" && pass "clone + build are timeboxed" || fail "timebox" "no timeout on clone/build"
grep -q "DEC-PHASE12-012" "$HOOK" && pass "DEC-PHASE12-012 annotation" || fail "annotation" "missing"

section "PATH + Nebula MCP registration"
grep -qE '\["nucleotide"\]="/opt/orionx/scripts/nucleotide/nucleotide-cli"' "$SETUP" && pass "SCRIPT_MAP: nucleotide → launcher" || fail "SCRIPT_MAP nucleotide" "missing"
grep -qE '\["orionx-nucleotide-watch"\]=' "$SETUP" && pass "SCRIPT_MAP: orionx-nucleotide-watch" || fail "SCRIPT_MAP watch" "missing"
if python3 - "$MCP" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("mcp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
t = {x["name"]: x for x in m.list_tools()}
assert "nucleotide_lookup" in t and "nucleotide_fingerprint" in t, list(t)
assert "file" in t["nucleotide_lookup"]["inputSchema"]["properties"]
a = m._TOOLS["nucleotide_lookup"].build_argv({"file": "/tmp/u.txt"}); assert a[0] == "orionx-nucleotide-watch" and "--dry-run" in a and "/tmp/u.txt" in a, a
b = m._TOOLS["nucleotide_fingerprint"].build_argv({"file": "/tmp/e.jsonl"}); assert b[:2] == ["nucleotide", "fingerprint"] and "--lookup" in b and "/opt/orionx/nucleotide/lookup.json" in b, b
assert "sh" not in a and "sh" not in b, "no shell in argv"
print("tools:", len(t))
PY
then pass "MCP: nucleotide_lookup + nucleotide_fingerprint registered, argv-only"; else fail "MCP registration" "import/schema/argv check failed"; fi
grep -q "nucleotide" "$REPO_ROOT/docs/User_Guide.md" && pass "User Guide documents nucleotide" || fail "User Guide" "no nucleotide section"

section "Live run on trixie / Python 3.13 (needs Docker)"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    OUT=$(docker run --rm --platform linux/amd64 -v "$N:/opt/orionx/scripts/nucleotide:ro" -e PYTHONPYCACHEPREFIX=/tmp/pyc debian:trixie-slim bash -c '
        apt-get update -q >/dev/null 2>&1 && apt-get install -y -q --no-install-recommends python3 python3-yaml >/dev/null 2>&1
        ln -s /opt/orionx/scripts/nucleotide/nucleotide-cli /usr/bin/nucleotide
        nucleotide --help 2>&1 | head -1
        echo "https://x/wp-login.php" | nucleotide lookup /nonexistent.json 2>&1 | head -1' 2>&1)
    if printf '%s' "$OUT" | grep -q "usage: nucleotide"; then pass "launcher runs via /usr/bin symlink on trixie 3.13 (system python3-yaml)"; else fail "launcher on trixie" "$(printf '%s' "$OUT" | head -c 200)"; fi
else
    skip "launcher live run" "Docker not available"
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, ${YELLOW}%d skipped${NC}\n" "$PASS" "$FAIL" "$SKIP"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
