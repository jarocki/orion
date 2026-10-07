#!/bin/bash
# shellcheck shell=bash
#
# Orion-X Phoenix Edition — Unit Tests for 0620-service-hardening.hook.chroot
#
# Tests the hook file structurally (no root/chroot needed):
# validates file existence, permissions, shebang, strict mode,
# shellcheck directive, @decision annotation, and all hardening
# content (service disable, SSH hardening, sysctl, systemd).
#
# @decision DEC-SEC-SVC-TEST-001
# @title Structural unit tests for service hardening hook
# @status accepted
# @rationale Live-build hooks run inside chroot as root during ISO build.
#   We cannot exercise them directly on macOS/dev machines.  Instead we
#   validate the hook file structurally: correct shebang, strict mode,
#   required hardening directives present, and ShellCheck clean.  This
#   catches regressions (accidentally deleted stanza, broken syntax)
#   without requiring a full ISO build cycle.
#
# Usage:  bash tests/unit/test_service_hardening.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Test framework (same pattern as test_filesystem_hardening.sh)
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

assert_eq() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected: '$expected'"
        echo "        actual:   '$actual'"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_match() {
    local description="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected pattern: '$pattern'"
        echo "        actual:           '$actual'"
        (( FAIL_COUNT++ )) || true
    fi
}

assert_contains() {
    local description="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $description"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $description"
        echo "        expected to contain: '$needle'"
        (( FAIL_COUNT++ )) || true
    fi
}

# ---------------------------------------------------------------------------
# Locate the hook file under test
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK_FILE="$REPO_ROOT/iso/config/hooks/live/0620-service-hardening.hook.chroot"

echo "=== Service Hardening Hook — Structural Tests ==="
echo ""

# ---------------------------------------------------------------------------
# 1. File existence and permissions
# ---------------------------------------------------------------------------
echo "--- File existence & permissions ---"

if [[ -f "$HOOK_FILE" ]]; then
    echo "  PASS: hook file exists"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: hook file not found at $HOOK_FILE"
    (( FAIL_COUNT++ )) || true
    echo ""
    echo "==========================================="
    echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $(( PASS_COUNT + FAIL_COUNT )))"
    echo "==========================================="
    exit 1
fi

if [[ -x "$HOOK_FILE" ]]; then
    echo "  PASS: hook file is executable"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: hook file is not executable"
    (( FAIL_COUNT++ )) || true
fi
echo ""

# ---------------------------------------------------------------------------
# Read the hook file content once for all subsequent checks
# ---------------------------------------------------------------------------
HOOK_CONTENT="$(cat "$HOOK_FILE")"
FIRST_LINE="$(head -n1 "$HOOK_FILE")"

# ---------------------------------------------------------------------------
# 2. Shebang, strict mode, shellcheck directive
# ---------------------------------------------------------------------------
echo "--- Shebang, strict mode, shellcheck ---"

assert_eq "shebang is #!/usr/bin/env bash" "#!/usr/bin/env bash" "$FIRST_LINE"

assert_contains "has shellcheck directive" "# shellcheck shell=bash" "$HOOK_CONTENT"

assert_contains "has set -euo pipefail" "set -euo pipefail" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 3. @decision annotation
# ---------------------------------------------------------------------------
echo "--- @decision annotation ---"

assert_contains "has @decision DEC-SEC-SVC-001" "@decision DEC-SEC-SVC-001" "$HOOK_CONTENT"
assert_contains "has @title annotation" "@title" "$HOOK_CONTENT"
assert_contains "has @status accepted" "@status accepted" "$HOOK_CONTENT"
assert_contains "has @rationale annotation" "@rationale" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 4. Disables unnecessary services
# ---------------------------------------------------------------------------
echo "--- Service disabling ---"

assert_contains "disables avahi-daemon" "avahi-daemon" "$HOOK_CONTENT"
assert_contains "disables cups" "cups" "$HOOK_CONTENT"
assert_contains "disables bluetooth" "bluetooth" "$HOOK_CONTENT"
assert_contains "disables ModemManager" "ModemManager" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 5. SSH hardening — PermitRootLogin
# ---------------------------------------------------------------------------
echo "--- SSH hardening ---"

assert_contains "SSH: PermitRootLogin no" "PermitRootLogin no" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 6. SSH hardening — PasswordAuthentication
# ---------------------------------------------------------------------------
assert_contains "SSH: PasswordAuthentication no" "PasswordAuthentication no" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 7. SSH hardening — MaxAuthTries
# ---------------------------------------------------------------------------
assert_contains "SSH: MaxAuthTries 3" "MaxAuthTries 3" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 8. Sysctl hardening — rp_filter
# ---------------------------------------------------------------------------
echo "--- Sysctl hardening ---"

assert_contains "sysctl: rp_filter = 1" "net.ipv4.conf.all.rp_filter = 1" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 9. Sysctl hardening — randomize_va_space
# ---------------------------------------------------------------------------
assert_contains "sysctl: randomize_va_space = 2" "kernel.randomize_va_space = 2" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 10. Sysctl hardening — kptr_restrict
# ---------------------------------------------------------------------------
assert_contains "sysctl: kptr_restrict = 2" "kernel.kptr_restrict = 2" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 11. Sysctl hardening — tcp_syncookies
# ---------------------------------------------------------------------------
assert_contains "sysctl: tcp_syncookies = 1" "net.ipv4.tcp_syncookies = 1" "$HOOK_CONTENT"

# ---------------------------------------------------------------------------
# 12. Sysctl hardening — ptrace_scope
# ---------------------------------------------------------------------------
assert_contains "sysctl: ptrace_scope = 1" "kernel.yama.ptrace_scope = 1" "$HOOK_CONTENT"

echo ""

# ---------------------------------------------------------------------------
# 13. Systemd unit hardening — asserted on the UNITS, not on this hook's text
#
# @decision DEC-PHASE12-039
# This used to be:
#     assert_contains "references ProtectSystem=strict" \
#                     "ProtectSystem=strict" "$HOOK_CONTENT"
# i.e. "the string ProtectSystem=strict appears somewhere in the hook." It
# passed for the life of the project while the mesh units ran completely
# unconfined, because the hook's injection loop globbed
# /etc/systemd/system/orionx-mesh-*.service and 0615 installs to
# /lib/systemd/system. The glob matched nothing, every build. Same shape as
# the AppArmor defect: a test that verified a write, not a state.
#
# The injector is now deleted, so the only place a directive can come from is
# the unit file 0615 copies verbatim. Assert it there.
# ---------------------------------------------------------------------------
echo "--- Systemd unit hardening ---"

UNITDIR="$REPO_ROOT/iso/config/includes.chroot/usr/share/orionx/systemd"

# The dead authority must not come back.
if grep -qE '^\s*for unit in /etc/systemd/system/orionx-' "$HOOK_FILE"; then
    echo "  FAIL: hook re-introduces the dead /etc/systemd/system injection loop"
    echo "        0615 installs to /lib/systemd/system; that glob matches nothing"
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: no build-time unit injection (units are the single authority)"
    (( PASS_COUNT++ )) || true
fi

# Units that ARE hardened must really carry the directives. If someone strips
# NoNewPrivileges from nebula-mcp.service tomorrow, this goes red.
for _u in nebula-mcp.service orionx-heald.service orionx-postured.service \
          orionx-scanwatch.service "orionx-capture@.service"; do
    _f="$UNITDIR/$_u"
    if [[ ! -f "$_f" ]]; then
        echo "  FAIL: $_u not staged at $UNITDIR"
        (( FAIL_COUNT++ )) || true
        continue
    fi
    _missing=""
    for _d in NoNewPrivileges ProtectSystem ProtectHome; do
        grep -qE "^${_d}=" "$_f" || _missing="$_missing $_d"
    done
    if [[ -z "$_missing" ]]; then
        echo "  PASS: $_u carries its hardening directives in the unit file"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $_u is missing:$_missing"
        (( FAIL_COUNT++ )) || true
    fi
done

# The DEC-PHASE12-039 tracked gap is CLOSED (DEC-PHASE12-041). The mesh units
# now carry their own confinement, which was only scopeable once the wg-quick
# calls came out of mesh-health.sh — wg-quick runs sysctl, iptables and
# resolvconf, and none of that can be bounded off-box.
#
# This block replaces the old "assert they are still unhardened" expectation.
# If someone strips these directives, this goes red.
for _u in orionx-mesh-discover.service orionx-mesh-health.service \
          orionx-mesh-beacon.service; do
    _f="$UNITDIR/$_u"
    if [[ ! -f "$_f" ]]; then
        echo "  FAIL: $_u not staged at $UNITDIR"
        (( FAIL_COUNT++ )) || true
        continue
    fi
    _missing=""
    for _d in NoNewPrivileges ProtectSystem ProtectHome CapabilityBoundingSet \
              RestrictAddressFamilies LockPersonality RestrictSUIDSGID; do
        grep -qE "^${_d}=" "$_f" || _missing="$_missing $_d"
    done
    if [[ -z "$_missing" ]]; then
        echo "  PASS: $_u carries its hardening directives in the unit file"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: $_u is missing:$_missing"
        (( FAIL_COUNT++ )) || true
    fi
done

# Each bounding set must be the MINIMUM the script needs, not a copy-paste of
# the next unit's. The beacon only reads interface addresses and sends a UDP
# datagram; granting it CAP_NET_ADMIN would be unjustified, so assert the
# difference rather than the presence.
if grep -qE '^CapabilityBoundingSet=.*CAP_NET_ADMIN' "$UNITDIR/orionx-mesh-beacon.service"; then
    echo "  FAIL: orionx-mesh-beacon.service has CAP_NET_ADMIN — the send path"
    echo "        only READS addresses and sends a datagram; it configures nothing."
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: beacon bounding set excludes CAP_NET_ADMIN (it administers nothing)"
    (( PASS_COUNT++ )) || true
fi

# CAP_NET_RAW is for `ping`, which only mesh-health.sh runs.
if grep -qE '^CapabilityBoundingSet=.*CAP_NET_RAW' "$UNITDIR/orionx-mesh-health.service"; then
    echo "  PASS: health bounding set includes CAP_NET_RAW (it pings peers)"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: orionx-mesh-health.service needs CAP_NET_RAW for its ping check"
    (( FAIL_COUNT++ )) || true
fi
for _u in orionx-mesh-discover.service orionx-mesh-beacon.service; do
    if grep -qE '^CapabilityBoundingSet=.*CAP_NET_RAW' "$UNITDIR/$_u"; then
        echo "  FAIL: $_u has CAP_NET_RAW but never opens a raw socket"
        (( FAIL_COUNT++ )) || true
    else
        echo "  PASS: $_u excludes CAP_NET_RAW (no raw socket in its path)"
        (( PASS_COUNT++ )) || true
    fi
done

# The one directive that MUST NOT appear: health_check_interface restores a
# missing wg0 with `ip link add type wireguard`, which needs module autoload.
if grep -qE '^ProtectKernelModules=yes' "$UNITDIR/orionx-mesh-health.service"; then
    echo "  FAIL: ProtectKernelModules=yes blocks the wireguard module autoload"
    echo "        that interface restore depends on — a recoverable outage"
    echo "        would become a permanent one."
    (( FAIL_COUNT++ )) || true
else
    echo "  PASS: ProtectKernelModules absent (wg0 restore can autoload the module)"
    (( PASS_COUNT++ )) || true
fi

# The heal budget lives in the RuntimeDirectory. Without Preserve=yes systemd
# deletes it when the oneshot exits and the bound silently stops bounding.
if grep -qE '^RuntimeDirectoryPreserve=yes' "$UNITDIR/orionx-mesh-health.service"; then
    echo "  PASS: heal-budget RuntimeDirectory survives the oneshot exit"
    (( PASS_COUNT++ )) || true
else
    echo "  FAIL: orionx-mesh-health.service needs RuntimeDirectoryPreserve=yes,"
    echo "        or the DEC-PHASE12-041 heal budget resets every 60 seconds"
    (( FAIL_COUNT++ )) || true
fi

echo ""

# ---------------------------------------------------------------------------
# 14. ShellCheck passes
# ---------------------------------------------------------------------------
echo "--- ShellCheck ---"

if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "$HOOK_FILE" 2>&1; then
        echo "  PASS: ShellCheck passes clean"
        (( PASS_COUNT++ )) || true
    else
        echo "  FAIL: ShellCheck reported issues"
        (( FAIL_COUNT++ )) || true
    fi
else
    echo "  SKIP: shellcheck not installed"
fi

echo ""

# =========================================================================
# DEC-PHASE12-104: EXECUTE the hook (in a throwaway trixie container, with a
# recording systemctl) and check what it actually disables and masks.
# =========================================================================
echo "--- Hook execution: sshd off at boot, apt timers and exim masked ---"
if [[ "${ORIONX_SKIP_DOCKER:-0}" != 1 ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CALLS="$(docker run --rm -v "$HOOK_FILE:/hook:ro" debian:trixie-slim bash -c '
        mkdir -p /stub /etc/ssh/sshd_config.d /etc/sysctl.d; touch /etc/ssh/sshd_config
        printf "#!/bin/sh\necho \"\$*\" >> /tmp/calls\nexit 0\n" > /stub/systemctl; chmod +x /stub/systemctl
        PATH=/stub:$PATH bash /hook >/dev/null 2>&1; echo "rc=$?"; cat /tmp/calls; echo "--conf"; cat /etc/ssh/sshd_config.d/orionx-hardening.conf' 2>&1)"
    assert_contains "hook exits 0" "rc=0" "$CALLS"
    assert_contains "ssh.service is disabled at boot" "disable ssh.service" "$CALLS"
    for u in apt-daily.timer apt-daily-upgrade.timer exim4.service exim4-base.timer; do
        assert_contains "$u is masked" "mask $u" "$CALLS"
    done
    assert_contains "root login stays refused" "PermitRootLogin no" "$CALLS"
    assert_contains "password auth stays off" "PasswordAuthentication no" "$CALLS"
    if [[ "$CALLS" == *"enable ssh"* ]]; then
        echo "  FAIL: nothing enables ssh"; (( FAIL_COUNT++ )) || true
    else
        echo "  PASS: nothing enables ssh"; (( PASS_COUNT++ )) || true
    fi
else
    echo "  SKIP: docker unavailable — hook not executed"
fi
NMCONF="$REPO_ROOT/iso/config/includes.chroot/etc/NetworkManager/conf.d/90-orionx-no-hostname.conf"
assert_contains "NetworkManager does not send the hostname in DHCPv4 (F14)" "ipv4.dhcp-send-hostname=false" "$(cat "$NMCONF" 2>/dev/null)"
assert_contains "NetworkManager does not send the hostname in DHCPv6 (F14)" "ipv6.dhcp-send-hostname=false" "$(cat "$NMCONF" 2>/dev/null)"
echo ""

# =========================================================================
# Summary
# =========================================================================
echo "==========================================="
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed (total: $TOTAL)"
echo "==========================================="

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
