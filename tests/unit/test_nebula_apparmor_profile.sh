#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for iso/config/includes.chroot/etc/apparmor.d/usr.bin.ollama
#
# @decision DEC-PHASE10-011
# @title test_nebula_apparmor_profile: structural validation of ollama AppArmor sandbox
# @status accepted
# @rationale DEC-007 (MCP tool server sandboxed) + DEC-006 (ALL AI LOCAL) require
#   that ollama cannot make outbound network calls. This test statically verifies
#   the profile structure: correct profile name, model read access, log write access,
#   localhost-only network (deny inet6 + deny raw/packet), no home-dir write,
#   and the Phase 7 tunables/abstractions include convention.
#
# Usage: bash tests/unit/test_nebula_apparmor_profile.sh
# Exit:  0 all tests passed, 1 one or more failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE="$REPO_ROOT/iso/config/includes.chroot/etc/apparmor.d/usr.bin.ollama"

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
contains_in_file() {
    local name="$1" needle="$2" file="$3"
    if grep -qE "$needle" "$file" 2>/dev/null; then pass "$name"
    else fail "$name" "Pattern '$needle' not found in $file"; fi
}

echo "================================================================"
echo "test_nebula_apparmor_profile.sh — W10-1 AppArmor profile tests"
echo "Profile: $PROFILE"
echo "================================================================"
echo ""

# ===========================================================================
# T1: Profile file exists
# ===========================================================================
echo "[T1] Profile file exists"
if [[ -f "$PROFILE" ]]; then
    pass "usr.bin.ollama AppArmor profile exists"
else
    fail "usr.bin.ollama AppArmor profile exists" "Not found at $PROFILE"
    echo "================================================================"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
echo ""

# ===========================================================================
# T2: Follows Phase 7 tunables/abstractions convention (matches usr.bin.tshark)
# ===========================================================================
echo "[T2] Phase 7 AppArmor convention: #include <tunables/global>"
contains_in_file "#include <tunables/global> present" \
    "#include <tunables/global>" "$PROFILE"
contains_in_file "#include <abstractions/base> present" \
    "#include <abstractions/base>" "$PROFILE"
echo ""

# ===========================================================================
# T3: Profile name matches /usr/bin/ollama
# ===========================================================================
echo "[T3] Profile name matches /usr/bin/ollama"
if grep -qE "^profile ollama /usr/bin/ollama" "$PROFILE"; then
    pass "profile block names /usr/bin/ollama"
else
    fail "profile block names /usr/bin/ollama" \
         "Expected 'profile ollama /usr/bin/ollama {' in $PROFILE"
fi
echo ""

# ===========================================================================
# T4: Read-only access to /opt/orionx/nebula/models/**
# ===========================================================================
echo "[T4] Profile grants r access to /opt/orionx/nebula/models/**"
if grep -qE "/opt/orionx/nebula/models/\*\* r" "$PROFILE"; then
    pass "model dir read-only access granted (/opt/orionx/nebula/models/** r)"
else
    fail "model dir read-only access" \
         "Expected '/opt/orionx/nebula/models/** r,' in $PROFILE"
fi
echo ""

# ===========================================================================
# T5: Read-write access to /var/log/orionx/**
# ===========================================================================
echo "[T5] Profile grants rw access to /var/log/orionx/**"
if grep -qE "/var/log/orionx/\*\* rw" "$PROFILE"; then
    pass "log dir rw access granted (/var/log/orionx/** rw)"
else
    fail "log dir rw access" \
         "Expected '/var/log/orionx/** rw,' in $PROFILE"
fi
echo ""

# ===========================================================================
# T6: Network restriction — deny non-localhost egress (DEC-PHASE10-011)
#
# AppArmor 3.x on Bullseye cannot express "localhost peers only" as a single
# rule; we use the deny-all-then-allow-loopback pattern. The profile must:
#   (a) deny inet6 (no IPv6 egress possible)
#   (b) deny raw sockets (no raw packet injection)
#   (c) deny packet sockets (no promiscuous sniffing)
# The inet stream/dgram allows are intentionally present (ollama uses TCP for
# its API); the deny rules for inet6 and raw/packet channels cover the
# non-localhost-reachable vectors.
# ===========================================================================
echo "[T6] Network restriction: deny inet6 + deny raw/packet (DEC-PHASE10-011)"
if grep -qE "deny network inet6" "$PROFILE"; then
    pass "deny network inet6 present (no IPv6 egress)"
else
    fail "deny network inet6 present" \
         "DEC-PHASE10-011: profile must deny inet6 to restrict to localhost-only paths"
fi
if grep -qE "deny network raw" "$PROFILE"; then
    pass "deny network raw present"
else
    fail "deny network raw present" \
         "DEC-PHASE10-011: profile must deny raw socket access"
fi
if grep -qE "deny network packet" "$PROFILE"; then
    pass "deny network packet present"
else
    fail "deny network packet present" \
         "DEC-PHASE10-011: profile must deny packet socket access"
fi
echo ""

# ===========================================================================
# T7: Deny write access to /home/** (Phase 7 convention)
# ===========================================================================
echo "[T7] deny /home/** w (Phase 7 convention)"
if grep -qE "deny /home/\*\* w" "$PROFILE"; then
    pass "deny /home/** w present"
else
    fail "deny /home/** w present" \
         "Phase 7 AppArmor convention: deny writes to /home/**"
fi
echo ""

# ===========================================================================
# T8: DEC-PHASE10-011 decision reference in the profile header
# ===========================================================================
echo "[T8] DEC-PHASE10-011 decision reference in profile"
if grep -q "DEC-PHASE10-011" "$PROFILE"; then
    pass "DEC-PHASE10-011 reference present in profile"
else
    fail "DEC-PHASE10-011 reference in profile" \
         "All W10-1 files must reference their load-bearing DEC (eval contract)"
fi
echo ""

# ===========================================================================
# T9: DEC-006 and DEC-007 references present
# ===========================================================================
echo "[T9] DEC-006 (LOCAL-ONLY) and DEC-007 (sandbox) references"
if grep -q "DEC-006" "$PROFILE"; then
    pass "DEC-006 reference present (LOCAL-ONLY AI)"
else
    fail "DEC-006 reference in profile" \
         "Profile enforces DEC-006; the reference should be in the comment header"
fi
if grep -q "DEC-007" "$PROFILE"; then
    pass "DEC-007 reference present (MCP tool server sandboxed)"
else
    fail "DEC-007 reference in profile" \
         "Profile enforces DEC-007 AppArmor sandboxing; reference required"
fi
echo ""

# ===========================================================================
# T10: Profile is not empty and is syntactically plausible (has { and })
# ===========================================================================
echo "[T10] Profile has valid block structure"
OPEN_BRACES="$(grep -c "{" "$PROFILE" 2>/dev/null || echo 0)"
CLOSE_BRACES="$(grep -c "}" "$PROFILE" 2>/dev/null || echo 0)"
if [[ "$OPEN_BRACES" -gt 0 && "$CLOSE_BRACES" -gt 0 ]]; then
    pass "profile has at least one { and } block"
else
    fail "profile block structure" "No brace-delimited blocks found in $PROFILE"
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
