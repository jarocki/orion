#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for W1-2: Modernize setup-matrix.sh
#
# Verifies:
#   1. Script exists and is executable
#   2. Has #!/usr/bin/env bash shebang
#   3. Has set -euo pipefail
#   4. Has shellcheck shell=bash directive
#   5. Has @decision DEC-MATRIX-SETUP-001 annotation
#   6. --help prints usage and exits 0
#   7. Missing --mode prints error and exits non-zero
#   8. --mode server without --server-name uses default "orionx.local"
#   9. Accepts all CLI arguments without error
#  10. ShellCheck passes
#  11. No v1.5.5 references remain
#  12. Contains cross-reference to orionx-mesh
#
# Production sequence: An operator provisions a new Orion-X node for team
# collaboration by running `setup-matrix.sh --mode server --server-name ...`
# in a Dockerfile or automated deployment. These tests verify the CLI
# argument pathway works without interactive prompts, which is the primary
# use case in automated/Docker environments.
#
# Usage: bash tests/unit/test_matrix_setup.sh
#   Run from the repository root (or the worktree root).

set -euo pipefail

# Resolve script directory to find repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MATRIX_SCRIPT="$REPO_ROOT/scripts/setup-matrix.sh"

# Test counters
PASS=0
FAIL=0
SKIP=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
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

skip() {
    ((SKIP+=1))
    echo "${YELLOW}  SKIP${NC}: $1 — $2"
}

section() {
    echo ""
    echo "--- $1 ---"
}

# Helper: run the script with ORIONX_MATRIX_DRY_RUN to prevent actual system changes
run_matrix() {
    ORIONX_MATRIX_DRY_RUN=1 bash "$MATRIX_SCRIPT" "$@" 2>&1
}


echo "=== W1-2: setup-matrix.sh Modernization Tests ==="

# ===========================================================================
# File existence and permissions
# ===========================================================================
section "File Structure"

if [[ -f "$MATRIX_SCRIPT" ]]; then
    pass "setup-matrix.sh exists"
else
    fail "setup-matrix.sh exists" "Not found at $MATRIX_SCRIPT"
fi

if [[ -x "$MATRIX_SCRIPT" ]]; then
    pass "setup-matrix.sh is executable"
else
    fail "setup-matrix.sh is executable" "chmod +x $MATRIX_SCRIPT"
fi

# ===========================================================================
# Shell modernization markers
# ===========================================================================
section "Shell Modernization"

if head -1 "$MATRIX_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    pass "Shebang is #!/usr/bin/env bash"
else
    fail "Shebang is #!/usr/bin/env bash" "Got: $(head -1 "$MATRIX_SCRIPT" 2>/dev/null)"
fi

if grep -q '# shellcheck shell=bash' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Has shellcheck shell=bash directive"
else
    fail "Has shellcheck shell=bash directive" "Missing directive"
fi

if grep -q 'set -euo pipefail' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Has set -euo pipefail"
else
    fail "Has set -euo pipefail" "Missing strict mode"
fi

if ! grep -q 'v1\.5\.5' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "No v1.5.5 references remain"
else
    fail "No v1.5.5 references remain" "Found v1.5.5 in script"
fi

# ===========================================================================
# Decision annotation
# ===========================================================================
section "Decision Annotation"

if grep -q '@decision DEC-MATRIX-SETUP-001' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Contains @decision DEC-MATRIX-SETUP-001 annotation"
else
    fail "Contains @decision DEC-MATRIX-SETUP-001 annotation" "Missing annotation"
fi

# ===========================================================================
# Cross-reference to mesh
# ===========================================================================
section "Cross-references"

if grep -q 'orionx-mesh' "$MATRIX_SCRIPT" 2>/dev/null; then
    pass "Contains reference to orionx-mesh"
else
    fail "Contains reference to orionx-mesh" "Missing mesh cross-reference"
fi

# ===========================================================================
# CLI argument parsing: --help
# ===========================================================================
section "CLI: --help"

set +e
output=$(run_matrix --help)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--help' exits 0"
else
    fail "'--help' exits 0" "Exit code: $rc"
fi

if echo "$output" | grep -q 'Usage:'; then
    pass "'--help' shows Usage:"
else
    fail "'--help' shows Usage:" "Output: $output"
fi

if echo "$output" | grep -q -- '--mode'; then
    pass "'--help' documents --mode"
else
    fail "'--help' documents --mode" "Output: $output"
fi

# Also test -h
set +e
output_h=$(run_matrix -h)
rc_h=$?
set -e
if [[ $rc_h -eq 0 ]] && echo "$output_h" | grep -q 'Usage:'; then
    pass "'-h' works as alias for --help"
else
    fail "'-h' works as alias for --help" "rc=$rc_h"
fi

# ===========================================================================
# CLI argument parsing: missing --mode
# ===========================================================================
section "CLI: Missing --mode"

set +e
output=$(run_matrix 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "No args exits non-zero"
else
    fail "No args exits non-zero" "Exit code: $rc (expected non-zero)"
fi

if echo "$output" | grep -qi 'mode.*required\|--mode\|usage'; then
    pass "No args shows error about missing --mode"
else
    fail "No args shows error about missing --mode" "Output: $output"
fi

# ===========================================================================
# CLI argument parsing: --mode server defaults
# ===========================================================================
section "CLI: --mode server defaults"

# In dry-run mode, server setup should accept defaults and exit cleanly
# We pass all required server args to avoid interactive prompts
set +e
output=$(run_matrix --mode server --admin-user testadmin)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--mode server' with args exits 0 in dry-run"
else
    fail "'--mode server' with args exits 0 in dry-run" "Exit code: $rc, Output: $output"
fi

# Verify default server-name is used when not provided
if echo "$output" | grep -q 'orionx.local'; then
    pass "Default server-name is orionx.local"
else
    fail "Default server-name is orionx.local" "Output: $output"
fi

# ===========================================================================
# CLI argument parsing: --mode server with custom server-name
# ===========================================================================
section "CLI: --mode server custom args"

set +e
output=$(run_matrix --mode server --server-name myserver.example --admin-user admin1)
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--mode server --server-name myserver.example' exits 0 in dry-run"
else
    fail "'--mode server --server-name myserver.example' exits 0 in dry-run" "Exit code: $rc"
fi

if echo "$output" | grep -q 'myserver.example'; then
    pass "Custom server-name 'myserver.example' is used"
else
    fail "Custom server-name 'myserver.example' is used" "Output: $output"
fi

# ===========================================================================
# CLI argument parsing: --mode client with all args
# ===========================================================================
section "CLI: --mode client args"

set +e
output=$(run_matrix --mode client --homeserver-url https://matrix.example.org --user-id '@test:example.org')
rc=$?
set -e
if [[ $rc -eq 0 ]]; then
    pass "'--mode client' with all args exits 0 in dry-run"
else
    fail "'--mode client' with all args exits 0 in dry-run" "Exit code: $rc, Output: $output"
fi

# ===========================================================================
# CLI argument parsing: invalid mode
# ===========================================================================
section "CLI: Invalid mode"

set +e
output=$(run_matrix --mode invalid 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass "'--mode invalid' exits non-zero"
else
    fail "'--mode invalid' exits non-zero" "Exit code: $rc"
fi

# ===========================================================================
# ShellCheck
# ===========================================================================
section "ShellCheck"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$MATRIX_SCRIPT" 2>&1; then
        pass "ShellCheck passes on setup-matrix.sh"
    else
        fail "ShellCheck passes on setup-matrix.sh" "See errors above"
    fi
else
    skip "ShellCheck" "shellcheck not installed"
fi

# ===========================================================================
# Production sequence: automated deployment
# ===========================================================================
section "Production Sequence"

# Automated deployment: help → server setup → client setup
# This simulates a Docker build where the script is called non-interactively
set +e
r1=$(run_matrix --help); rc1=$?
_r2=$(run_matrix --mode server --server-name deploy.local --admin-user deployer); rc2=$?
_r3=$(run_matrix --mode client --homeserver-url https://deploy.local:8448 --user-id '@responder:deploy.local'); rc3=$?
set -e

if [[ $rc1 -eq 0 ]] && echo "$r1" | grep -q 'Usage:' \
   && [[ $rc2 -eq 0 ]] \
   && [[ $rc3 -eq 0 ]]; then
    pass "Automated deployment: help→server→client (all dry-run)"
else
    fail "Automated deployment sequence" "rc1=$rc1 rc2=$rc2 rc3=$rc3"
fi

# Failure recovery: no mode → error → retry with mode
set +e
r1=$(run_matrix 2>&1); rc1=$?
_r2=$(run_matrix --mode server --admin-user admin); rc2=$?
set -e
if [[ $rc1 -ne 0 ]] && [[ $rc2 -eq 0 ]]; then
    pass "Failure recovery: no-mode-error → retry with --mode succeeds"
else
    fail "Failure recovery" "rc1=$rc1 rc2=$rc2"
fi

# ===========================================================================
# DEC-PHASE12-102: a REAL (non-dry-run) server setup against stubbed system
# commands — exercises the code that used to die with exit 141, open
# registration and put the password on argv.
# ===========================================================================
section "Server mode (non-dry-run, stubbed system)"

MX="$(mktemp -d)"
mkdir -p "$MX/bin" "$MX/etc/conf.d"
export MX
for cmd in systemctl register_new_matrix_user apt-get wget debconf-set-selections; do
    cat > "$MX/bin/$cmd" <<'STUBEOF'
#!/usr/bin/env bash
n="$(basename "$0")"
printf '%s' "$n" >> "$MX/calls"; printf ' %q' "$@" >> "$MX/calls"; echo >> "$MX/calls"
if [[ "$n" == register_new_matrix_user ]]; then
    for ((i=1; i<=$#; i++)); do
        [[ "${!i}" == --password-file ]] && { j=$((i+1)); cp "${!j}" "$MX/pw.seen"; ls -l "${!j}" > "$MX/pw.mode"; }
    done
fi
exit 0
STUBEOF
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$MX/bin/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MX/bin/element-desktop"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MX/bin/synapse_homeserver"
printf '#!/usr/bin/env bash\necho "5: wg0    inet 10.0.99.5/24 scope global wg0"\n' > "$MX/bin/ip"
chmod +x "$MX/bin/"*
printf 'Sup3r-secret pw\n' > "$MX/pw.txt"

run_real() {
    env PATH="$MX/bin:$PATH" ORIONX_SKIP_ROOT_CHECK=1 \
        ORIONX_MATRIX_LOGFILE="$MX/setup.log" ORIONX_MATRIX_CONFIG_DIR="$MX/etc" \
        ORIONX_MATRIX_CLIENT_DIR="$MX/element" ORIONX_MATRIX_DESKTOP_FILE="$MX/orionx-matrix.desktop" \
        ORIONX_INSTALLER_LIB="$REPO_ROOT/iso/config/includes.chroot/opt/orionx/optional/lib/orionx-installer-common.sh" \
        TMPDIR="$MX" bash "$MATRIX_SCRIPT" "$@" </dev/null 2>&1
}

rc=0; out="$(run_real --mode server --server-name orionx.local --admin-user ops --admin-pass-file "$MX/pw.txt")" || rc=$?
if [[ $rc -eq 0 ]]; then pass "server setup completes (old code died with exit 141 at the secret)"; else fail "server setup completes" "rc=$rc: $(tail -3 <<< "$out")"; fi
CONF="$MX/etc/conf.d/orionx.yaml"
if grep -q '^enable_registration: false$' "$CONF" 2>/dev/null; then pass "registration is closed"; else fail "registration is closed" "$(cat "$CONF" 2>/dev/null)"; fi
if grep -Eq "bind_addresses: \['127\.0\.0\.1', '10\.0\.99\.5'\]" "$CONF" 2>/dev/null; then pass "ONE listener bound to loopback + the wg0 address"; else fail "explicit bind addresses" "$(grep bind "$CONF" 2>/dev/null)"; fi
if [[ "$(grep -c '^  - port:' "$CONF" 2>/dev/null)" == "1" ]]; then pass "exactly one listener"; else fail "exactly one listener"; fi
SECRET="$MX/etc/conf.d/orionx-secret.yaml"
if grep -Eq '^registration_shared_secret: "[0-9a-f]{64}"$' "$SECRET" 2>/dev/null && ! grep -q registration_shared_secret "$CONF"; then pass "a 64-hex registration secret is written to orionx-secret.yaml, not the listener file (QA round 2, P2-1)"; else fail "registration secret location"; fi
if [[ "$(stat -c %a "$CONF" 2>/dev/null || stat -f %Lp "$CONF")" == "644" && "$(stat -c %a "$SECRET" 2>/dev/null || stat -f %Lp "$SECRET")" == "640" ]]; then pass "listener file 0644 (the Cockpit reads it as the operator), secret 0640"; else fail "conf.d modes" "$(stat -c %a "$CONF" "$SECRET" 2>/dev/null || stat -f %Lp "$CONF" "$SECRET")"; fi
if grep -q '^systemctl enable matrix-synapse.service' "$MX/calls" && grep -q '^systemctl restart matrix-synapse.service' "$MX/calls"; then
    pass "enables and starts the package unit matrix-synapse.service"
else
    fail "enables and starts matrix-synapse.service" "$(grep systemctl "$MX/calls" 2>/dev/null)"
fi
if grep -q 'matrix-synapse-orionx' "$MX/calls"; then fail "never touches the deleted matrix-synapse-orionx unit"; else pass "never touches the deleted matrix-synapse-orionx unit"; fi
REG="$(grep '^register_new_matrix_user' "$MX/calls" || true)"
if [[ -n "$REG" && "$REG" != *Sup3r* && "$REG" == *--password-file* ]]; then
    pass "admin password reaches register_new_matrix_user via --password-file, not argv"
else
    fail "password never on argv" "$REG"
fi
if [[ "$(cat "$MX/pw.seen" 2>/dev/null)" == "Sup3r-secret pw" ]]; then pass "password file carried the password"; else fail "password file carried the password"; fi
if grep -q '^-rw-------' "$MX/pw.mode" 2>/dev/null; then pass "password file was mode 0600"; else fail "password file mode" "$(cat "$MX/pw.mode" 2>/dev/null)"; fi
if ls "$MX"/orionx-matrix-pw.* >/dev/null 2>&1; then fail "password temp file removed"; else pass "password temp file removed"; fi
if grep -q 'Sup3r' "$MX/setup.log" "$CONF" 2>/dev/null; then fail "password never logged or written to config"; else pass "password never logged or written to config"; fi
if grep -q '"base_url": "http://127.0.0.1:8008"' "$MX/element/config.json" 2>/dev/null; then pass "local Element points at the loopback listener"; else fail "local Element base_url" "$(cat "$MX/element/config.json" 2>/dev/null)"; fi

rc=0; out="$(run_real --mode server --admin-user ops --admin-pass hunter2)" || rc=$?
if [[ $rc -ne 0 && "$out" == *"--admin-pass-file"* ]]; then pass "--admin-pass on argv is refused with the alternative named"; else fail "--admin-pass refused" "rc=$rc $out"; fi
rc=0; out="$(run_real --mode client --homeserver-url https://x.example --password hunter2)" || rc=$?
if [[ $rc -ne 0 ]]; then pass "--password on argv is refused"; else fail "--password refused"; fi
rc=0; out="$(run_real --mode client --homeserver-url 'https://x.example","evil":"1' --user-id '@a:x')" || rc=$?
if [[ $rc -ne 0 && ! -f "$MX/element/config.json.bad" ]] && ! grep -q evil "$MX/element/config.json" 2>/dev/null; then pass "a URL that would break the JSON is rejected"; else fail "URL injection rejected" "rc=$rc"; fi

section "UX-35: preflight before any download"
: > "$MX/calls"
rm -f "$MX/bin/element-desktop" "$MX/bin/synapse_homeserver"
printf '#!/usr/bin/env bash\nexit 2\n' > "$MX/bin/getent"; chmod +x "$MX/bin/getent"
rc=0; out="$(run_real --mode server --admin-user ops)" || rc=$?
if [[ $rc -ne 0 && "$out" == *"unreachable"* && "$out" == *"network"* ]]; then pass "offline: one plain-language network error"; else fail "offline preflight message" "rc=$rc: $out"; fi
if grep -q '^apt-get' "$MX/calls" 2>/dev/null; then fail "offline: apt-get is never run"; else pass "offline: apt-get is never run"; fi
if [[ "$EUID" -ne 0 ]]; then
    rc=0; out="$(env PATH="$MX/bin:$PATH" ORIONX_MATRIX_LOGFILE="$MX/setup.log" bash "$MATRIX_SCRIPT" --mode server </dev/null 2>&1)" || rc=$?
    if [[ $rc -ne 0 && "$out" == *"requires root"* ]]; then pass "non-root: says it needs root, before anything else"; else fail "root preflight" "rc=$rc: $out"; fi
else
    skip "root preflight" "running as root"
fi
section "F11: signing keys are fingerprint-pinned"
: > "$MX/calls"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MX/bin/getent"
# wget writes a dummy key; gpg reports whatever fingerprint $FAKE_FPR says.
printf '#!/usr/bin/env bash\nwhile [[ $# -gt 0 ]]; do [[ "$1" == -qO ]] && { echo key > "$2"; shift; }; shift; done\nexit 0\n' > "$MX/bin/wget"
printf '#!/usr/bin/env bash\necho "fpr:::::::::${FAKE_FPR}:"\n' > "$MX/bin/gpg"
cat > "$MX/bin/apt-get" <<'STUBEOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$MX/calls"
[[ "$*" == *"install -y element-desktop"* ]] && { printf '#!/bin/sh\nexit 0\n' > "$MX/bin/element-desktop"; chmod +x "$MX/bin/element-desktop"; }
exit 0
STUBEOF
chmod +x "$MX/bin/"*
printf '#!/usr/bin/env bash\nexit 0\n' > "$MX/bin/synapse_homeserver"; chmod +x "$MX/bin/synapse_homeserver"
mkdir -p "$MX/apt" "$MX/keys"
rk() { env FAKE_FPR="$1" ORIONX_APT_SOURCES_DIR="$MX/apt" ORIONX_ELEMENT_KEYRING="$MX/keys/element.gpg" ORIONX_MATRIX_KEYRING="$MX/keys/matrix.gpg" \
         PATH="$MX/bin:$PATH" ORIONX_SKIP_ROOT_CHECK=1 ORIONX_MATRIX_LOGFILE="$MX/setup.log" ORIONX_MATRIX_CLIENT_DIR="$MX/element" \
         ORIONX_MATRIX_DESKTOP_FILE="$MX/d.desktop" bash "$MATRIX_SCRIPT" --mode client --homeserver-url https://x.example --user-id '@a:x' </dev/null 2>&1; }
rm -f "$MX/bin/element-desktop"
rc=0; out="$(rk DEADBEEF)" || rc=$?
if [[ $rc -ne 0 && "$out" == *"FINGERPRINT MISMATCH"* ]] && ! grep -q 'install -y element-desktop' "$MX/calls"; then
    pass "a substituted Element key is refused before apt installs anything"
else
    fail "fingerprint mismatch refused" "rc=$rc $(tail -2 <<< "$out")"
fi
if [[ -e "$MX/keys/element.gpg" ]]; then fail "a refused key is not installed"; else pass "a refused key is not installed"; fi
rm -f "$MX/bin/element-desktop"; : > "$MX/calls"
rc=0; out="$(rk 12D4CD600C2240A9F4A82071D7B0B66941D01538)" || rc=$?
if [[ $rc -eq 0 && -f "$MX/keys/element.gpg" ]] && grep -q "signed-by=$MX/keys/element.gpg" "$MX/apt/element-io.list"; then
    pass "the pinned Element key is installed and scoped with signed-by"
else
    fail "pinned key accepted + signed-by" "rc=$rc $(tail -2 <<< "$out")"
fi
rm -rf "$MX"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================="
echo "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
