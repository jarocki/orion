#!/usr/bin/env bash
# Security regression checks for the shipped Orion-X drive installer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE="$ROOT/scripts/install.sh"
STAGED="$ROOT/iso/config/includes.chroot/opt/orionx/scripts/install.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$SOURCE"
# The ISO staging tree is generated and gitignored.  When a local build has
# populated it, make sure that copy has not drifted from the tracked source.
if [[ -f "$STAGED" ]]; then
    bash -n "$STAGED"
    cmp -s "$SOURCE" "$STAGED" || fail "source and staged installer copies differ"
fi

if grep -Eq '/tmp/tempkey|--key-file' "$SOURCE"; then
    fail "installer still materialises a predictable LUKS key file"
fi

# These are literal source-code assertions, not shell expressions.
# shellcheck disable=SC2016
[[ "$(grep -c 'setup_encrypted_persistence "${TARGET_DEVICE}3"' "$SOURCE")" -eq 2 ]] \
    || fail "both UEFI and BIOS branches must use the shared LUKS helper"
# shellcheck disable=SC2016
grep -Fq 'cryptsetup luksFormat "$partition"' "$SOURCE" \
    || fail "LUKS format must use cryptsetup's interactive passphrase boundary"
# shellcheck disable=SC2016
grep -Fq 'cryptsetup luksOpen "$partition" orionx_crypt' "$SOURCE" \
    || fail "LUKS open must use the enrolled interactive passphrase"

grep -Fq 'LOGFILE="/var/log/orionx-install.log"' "$SOURCE" \
    || fail "installer log must live under root-owned /var/log"
if grep -Fq 'LOGFILE="/tmp/' "$SOURCE"; then
    fail "installer log must not use a predictable /tmp path"
fi

# shellcheck disable=SC2016
root_check_line="$(grep -n 'if \[ "$(id -u)" -ne 0 \]' "$SOURCE" | head -1 | cut -d: -f1)"
first_log_line="$(grep -n '^log "' "$SOURCE" | head -1 | cut -d: -f1)"
[[ -n "$root_check_line" && -n "$first_log_line" && "$root_check_line" -lt "$first_log_line" ]] \
    || fail "root check must run before the first log write"

echo "PASS: installer uses interactive LUKS enrollment and secure logging"
