#!/usr/bin/env bash
# shellcheck shell=bash
#
# W7-6: Failure-mode recovery — host-side systemd unit config inspection
#
# Asserts each of the 8 Orion-X systemd units in systemd/ has appropriate
# failure-recovery configuration per its Type= directive:
#
#   - Long-running services (Type=notify, Type=simple) MUST declare
#     Restart= with a meaningful policy (on-failure, always, on-abnormal).
#   - Oneshot services (Type=oneshot) are recovery-irrelevant by design;
#     they run once and exit. Timer-driven re-firing is their recovery path.
#     No Restart= directive is required (absent or Restart=no both pass).
#   - Timer units MUST declare OnUnitActiveSec= or OnBootSec= to provide
#     cadence-driven recovery for node-drop and network-flap failure modes.
#
# @decision DEC-PHASE7-W7-6-001
# @title Host-side static config inspection of systemd unit Restart= directives
# @status accepted
# @rationale Option D (host-side config inspection) was chosen over:
#   - Option A (in-guest active stimulation): feasible but risks a third
#     cascade-fix loop on top of issues #39 and #40 (first-boot/wg0 cascade).
#   - Option B (QEMU monitor): REJECTED per DEC-PHASE7-035 (no new control
#     plane).
#   - Option C (Docker compose): REJECTED per Phase 4 SKIP #21/#22 pattern.
#   Static inspection is deterministic, fast, has no hang risk, and has zero
#   dependency on the #39/#40 first-boot cascade surface. Option A may follow
#   as W7-6-bis if Phase 7 closure (W7-8) requires deeper assurance.
#   (DEC-PHASE7-041: land the simple, working check first.)
#
# Per-Type recovery contract (canonical in this file per MASTER_PLAN.md):
#
#   Unit                               Type      Expected Restart=
#   ─────────────────────────────────  ────────  ────────────────────────────────
#   matrix-synapse-orionx.service      notify    REQUIRED: on-failure|always|on-abnormal
#   orionx-mesh-discover.service       simple    REQUIRED: on-failure|always|on-abnormal
#   orionx-mesh-beacon.service         oneshot   NOT required (recovery-irrelevant)
#   orionx-mesh-health.service         oneshot   NOT required (recovery-irrelevant)
#   orionx-firewall.service            oneshot   NOT required (recovery-irrelevant)
#   orionx-first-boot.service          oneshot   NOT required (recovery-irrelevant)
#   orionx-mesh-discover.timer         timer     MUST have OnUnitActiveSec= or OnBootSec=
#   orionx-mesh-health.timer           timer     MUST have OnUnitActiveSec= or OnBootSec=
#
# Failure modes covered (from goal-contract desired_end_state):
#   - Synapse restart:  matrix-synapse-orionx.service Restart=on-failure
#   - Node drop:        timer cadence re-fires mesh-discover/health to re-add peers
#   - Network flap:     timer cadence re-fires mesh-health to re-establish links
#   - Disk full:        NOT covered — documented gap; routed to W7-6-bis/Phase 8
#
# This test is pure host-side static analysis:
#   - Does NOT boot the ISO
#   - Does NOT invoke QEMU, Docker Compose, or any active stimulation harness
#   - Does NOT call systemctl, systemd-analyze, or any systemd runtime tool
#   - Does NOT reference qemu-boot-test.sh or docker-compose
#   - Reads unit files from systemd/ directory relative to repo root
#
# Usage: bash tests/integration/test-w7-6-failure-resilience.sh
# Exit:  0 on all PASS; non-zero on any FAIL.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SYSTEMD_DIR="${REPO_ROOT}/systemd"

# ---------------------------------------------------------------------------
# Test counters — use ((VAR+=1)) to avoid set -e firing on zero-result
# arithmetic in bash 5+
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

# Color output when running in a terminal
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    NC=$'\033[0m'
else
    RED="" GREEN="" NC=""
fi

pass() { ((PASS+=1)); echo "${GREEN}  [W7-6 PASS]${NC} $1"; }
fail() {
    ((FAIL+=1))
    echo "${RED}  [W7-6 FAIL]${NC} $1"
    [[ -n "${2:-}" ]] && echo "             $2"
}
section() { echo ""; echo "--- $1 ---"; }

echo "=== W7-6: Failure-Mode Recovery — Systemd Config Inspection ==="
echo "    Repo:     ${REPO_ROOT}"
echo "    Units:    ${SYSTEMD_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Pre-flight: all 8 unit files must exist (if any are missing, fail fast)
# ---------------------------------------------------------------------------
section "Pre-flight: unit file presence"

EXPECTED_UNITS=(
    "matrix-synapse-orionx.service"
    "orionx-mesh-discover.service"
    "orionx-mesh-beacon.service"
    "orionx-mesh-health.service"
    "orionx-firewall.service"
    "orionx-first-boot.service"
    "orionx-mesh-discover.timer"
    "orionx-mesh-health.timer"
)

PREFLIGHT_FAIL=0
for unit in "${EXPECTED_UNITS[@]}"; do
    if [[ -f "${SYSTEMD_DIR}/${unit}" ]]; then
        pass "${unit}: file present"
    else
        fail "${unit}: file present" "Not found: ${SYSTEMD_DIR}/${unit}"
        ((PREFLIGHT_FAIL+=1)) || true
    fi
done

if [[ ${PREFLIGHT_FAIL} -gt 0 ]]; then
    echo ""
    echo "FATAL: ${PREFLIGHT_FAIL} unit file(s) missing — cannot inspect recovery config."
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: extract directive value from a unit file (last match wins, as
# systemd processes duplicate directives). Strips leading/trailing whitespace.
# Returns empty string if directive not found.
# ---------------------------------------------------------------------------
get_directive() {
    local file="$1"
    local directive="$2"
    # Match lines like: Restart=on-failure  or  OnBootSec=5s
    # Use tail -1 so that if the directive appears multiple times, last wins.
    grep -iE "^[[:space:]]*${directive}[[:space:]]*=" "${file}" \
        | tail -1 \
        | sed 's/^[^=]*=[[:space:]]*//' \
        | sed 's/[[:space:]]*$//' \
        || true
}

# ---------------------------------------------------------------------------
# Assertion 1: matrix-synapse-orionx.service — Type=notify, long-running daemon
#   MUST declare Restart= with on-failure | always | on-abnormal
#   SHOULD declare RestartSec= (belt-and-suspenders)
# ---------------------------------------------------------------------------
section "matrix-synapse-orionx.service (Type=notify, long-running daemon)"

UNIT_FILE="${SYSTEMD_DIR}/matrix-synapse-orionx.service"

ACTUAL_TYPE="$(get_directive "${UNIT_FILE}" "Type")"
ACTUAL_RESTART="$(get_directive "${UNIT_FILE}" "Restart")"
ACTUAL_RESTART_SEC="$(get_directive "${UNIT_FILE}" "RestartSec")"

# Assert Type= is not oneshot (it must be a long-running daemon type)
if [[ "${ACTUAL_TYPE}" == "notify" || "${ACTUAL_TYPE}" == "simple" \
    || "${ACTUAL_TYPE}" == "forking" || "${ACTUAL_TYPE}" == "exec" ]]; then
    pass "matrix-synapse-orionx.service: Type=${ACTUAL_TYPE} (long-running daemon)"
else
    fail "matrix-synapse-orionx.service: unexpected Type=" \
         "Got Type=${ACTUAL_TYPE:-<absent>}; expected notify/simple/forking/exec for long-running daemon"
fi

# Assert meaningful Restart= policy
case "${ACTUAL_RESTART}" in
    on-failure|always|on-abnormal)
        pass "matrix-synapse-orionx.service: Restart=${ACTUAL_RESTART} (meaningful recovery policy)"
        ;;
    no|"")
        fail "matrix-synapse-orionx.service: Restart= missing or 'no'" \
             "Got Restart=${ACTUAL_RESTART:-<absent>}; Type=${ACTUAL_TYPE} daemon MUST declare Restart=on-failure|always|on-abnormal"
        ;;
    *)
        fail "matrix-synapse-orionx.service: Restart= unrecognized value" \
             "Got Restart=${ACTUAL_RESTART}; expected on-failure|always|on-abnormal"
        ;;
esac

# RestartSec= is a belt-and-suspenders check — PASS if present, no FAIL if absent
if [[ -n "${ACTUAL_RESTART_SEC}" ]]; then
    pass "matrix-synapse-orionx.service: RestartSec=${ACTUAL_RESTART_SEC} (back-off configured)"
else
    # Only fail if Restart= is non-trivial (no point checking RestartSec if no restart)
    if [[ "${ACTUAL_RESTART}" == "on-failure" || "${ACTUAL_RESTART}" == "always" || "${ACTUAL_RESTART}" == "on-abnormal" ]]; then
        pass "matrix-synapse-orionx.service: RestartSec= absent (systemd default applies; not required)"
    fi
fi

# ---------------------------------------------------------------------------
# Assertion 2: orionx-mesh-discover.service — Type=simple, persistent listener
#   MUST declare Restart= with on-failure | always | on-abnormal
# ---------------------------------------------------------------------------
section "orionx-mesh-discover.service (Type=simple, persistent listener)"

UNIT_FILE="${SYSTEMD_DIR}/orionx-mesh-discover.service"

ACTUAL_TYPE="$(get_directive "${UNIT_FILE}" "Type")"
ACTUAL_RESTART="$(get_directive "${UNIT_FILE}" "Restart")"
ACTUAL_RESTART_SEC="$(get_directive "${UNIT_FILE}" "RestartSec")"

# Assert Type= — mesh-discover listener is Type=simple (persistent daemon)
if [[ "${ACTUAL_TYPE}" == "simple" || "${ACTUAL_TYPE}" == "notify" || "${ACTUAL_TYPE}" == "forking" || "${ACTUAL_TYPE}" == "exec" ]]; then
    pass "orionx-mesh-discover.service: Type=${ACTUAL_TYPE} (long-running daemon type)"
elif [[ "${ACTUAL_TYPE}" == "oneshot" ]]; then
    fail "orionx-mesh-discover.service: Type=oneshot (unexpected for persistent listener)" \
         "mesh-discover is a long-running listener; it must be Type=simple (or notify/forking)"
else
    pass "orionx-mesh-discover.service: Type=${ACTUAL_TYPE:-simple (implicit default)}"
fi

# Assert meaningful Restart= policy
case "${ACTUAL_RESTART}" in
    on-failure|always|on-abnormal)
        pass "orionx-mesh-discover.service: Restart=${ACTUAL_RESTART} (meaningful recovery policy)"
        ;;
    no|"")
        fail "orionx-mesh-discover.service: Restart= missing or 'no'" \
             "Got Restart=${ACTUAL_RESTART:-<absent>}; persistent listener MUST declare Restart=on-failure|always|on-abnormal"
        ;;
    *)
        fail "orionx-mesh-discover.service: Restart= unrecognized value" \
             "Got Restart=${ACTUAL_RESTART}; expected on-failure|always|on-abnormal"
        ;;
esac

if [[ -n "${ACTUAL_RESTART_SEC}" ]]; then
    pass "orionx-mesh-discover.service: RestartSec=${ACTUAL_RESTART_SEC} (back-off configured)"
else
    if [[ "${ACTUAL_RESTART}" == "on-failure" || "${ACTUAL_RESTART}" == "always" || "${ACTUAL_RESTART}" == "on-abnormal" ]]; then
        pass "orionx-mesh-discover.service: RestartSec= absent (systemd default applies; not required)"
    fi
fi

# ---------------------------------------------------------------------------
# Assertion 3: orionx-mesh-beacon.service — Type=oneshot
#   Recovery-irrelevant: MAY omit Restart= or declare Restart=no
#   Timer (orionx-mesh-discover.timer) drives re-firing
# ---------------------------------------------------------------------------
section "orionx-mesh-beacon.service (Type=oneshot, timer-driven)"

UNIT_FILE="${SYSTEMD_DIR}/orionx-mesh-beacon.service"

ACTUAL_TYPE="$(get_directive "${UNIT_FILE}" "Type")"
ACTUAL_RESTART="$(get_directive "${UNIT_FILE}" "Restart")"

if [[ "${ACTUAL_TYPE}" == "oneshot" ]]; then
    pass "orionx-mesh-beacon.service: Type=oneshot (recovery-irrelevant by design)"
else
    fail "orionx-mesh-beacon.service: expected Type=oneshot" \
         "Got Type=${ACTUAL_TYPE:-<absent (defaults to simple)>}; mesh-beacon should be oneshot"
fi

case "${ACTUAL_RESTART}" in
    no|"")
        pass "orionx-mesh-beacon.service: Restart=${ACTUAL_RESTART:-<absent>} (correct for oneshot; timer drives recovery)"
        ;;
    on-failure|always|on-abnormal|on-success|on-watchdog|on-abort)
        # Restart= on oneshot is semantically odd but not a hard error per systemd
        # We assert it should NOT be set for clarity and spec compliance
        fail "orionx-mesh-beacon.service: Restart=${ACTUAL_RESTART} on oneshot service" \
             "Oneshot units are recovery-irrelevant; Restart= should be omitted or 'no'"
        ;;
esac

# ---------------------------------------------------------------------------
# Assertion 4: orionx-mesh-health.service — Type=oneshot
#   Recovery-irrelevant: MAY omit Restart= or declare Restart=no
# ---------------------------------------------------------------------------
section "orionx-mesh-health.service (Type=oneshot, timer-driven)"

UNIT_FILE="${SYSTEMD_DIR}/orionx-mesh-health.service"

ACTUAL_TYPE="$(get_directive "${UNIT_FILE}" "Type")"
ACTUAL_RESTART="$(get_directive "${UNIT_FILE}" "Restart")"

if [[ "${ACTUAL_TYPE}" == "oneshot" ]]; then
    pass "orionx-mesh-health.service: Type=oneshot (recovery-irrelevant by design)"
else
    fail "orionx-mesh-health.service: expected Type=oneshot" \
         "Got Type=${ACTUAL_TYPE:-<absent>}; mesh-health should be oneshot"
fi

case "${ACTUAL_RESTART}" in
    no|"")
        pass "orionx-mesh-health.service: Restart=${ACTUAL_RESTART:-<absent>} (correct for oneshot; timer drives recovery)"
        ;;
    on-failure|always|on-abnormal|on-success|on-watchdog|on-abort)
        fail "orionx-mesh-health.service: Restart=${ACTUAL_RESTART} on oneshot service" \
             "Oneshot units are recovery-irrelevant; Restart= should be omitted or 'no'"
        ;;
esac

# ---------------------------------------------------------------------------
# Assertion 5: orionx-firewall.service — Type=oneshot
#   Recovery-irrelevant: setup-once unit, MAY omit Restart= or declare Restart=no
# ---------------------------------------------------------------------------
section "orionx-firewall.service (Type=oneshot, setup-once)"

UNIT_FILE="${SYSTEMD_DIR}/orionx-firewall.service"

ACTUAL_TYPE="$(get_directive "${UNIT_FILE}" "Type")"
ACTUAL_RESTART="$(get_directive "${UNIT_FILE}" "Restart")"

if [[ "${ACTUAL_TYPE}" == "oneshot" ]]; then
    pass "orionx-firewall.service: Type=oneshot (setup-once, recovery-irrelevant by design)"
else
    fail "orionx-firewall.service: expected Type=oneshot" \
         "Got Type=${ACTUAL_TYPE:-<absent>}; firewall setup unit should be oneshot"
fi

case "${ACTUAL_RESTART}" in
    no|"")
        pass "orionx-firewall.service: Restart=${ACTUAL_RESTART:-<absent>} (correct for oneshot setup unit)"
        ;;
    on-failure|always|on-abnormal|on-success|on-watchdog|on-abort)
        fail "orionx-firewall.service: Restart=${ACTUAL_RESTART} on oneshot service" \
             "Oneshot units are recovery-irrelevant; Restart= should be omitted or 'no'"
        ;;
esac

# ---------------------------------------------------------------------------
# Assertion 6: orionx-first-boot.service — Type=oneshot
#   Runs exactly once via ConditionPathExists guard; no recovery needed
# ---------------------------------------------------------------------------
section "orionx-first-boot.service (Type=oneshot, runs-once guard)"

UNIT_FILE="${SYSTEMD_DIR}/orionx-first-boot.service"

ACTUAL_TYPE="$(get_directive "${UNIT_FILE}" "Type")"
ACTUAL_RESTART="$(get_directive "${UNIT_FILE}" "Restart")"

if [[ "${ACTUAL_TYPE}" == "oneshot" ]]; then
    pass "orionx-first-boot.service: Type=oneshot (runs-once by design)"
else
    fail "orionx-first-boot.service: expected Type=oneshot" \
         "Got Type=${ACTUAL_TYPE:-<absent>}; first-boot wizard should be oneshot"
fi

# Also assert ConditionPathExists guard is present (belt-and-suspenders: one-shot semantics)
if grep -q "ConditionPathExists" "${UNIT_FILE}"; then
    pass "orionx-first-boot.service: ConditionPathExists guard present (runs exactly once)"
else
    fail "orionx-first-boot.service: ConditionPathExists guard missing" \
         "First-boot wizard must guard against re-running on subsequent boots"
fi

case "${ACTUAL_RESTART}" in
    no|"")
        pass "orionx-first-boot.service: Restart=${ACTUAL_RESTART:-<absent>} (correct for runs-once unit)"
        ;;
    on-failure|always|on-abnormal|on-success|on-watchdog|on-abort)
        fail "orionx-first-boot.service: Restart=${ACTUAL_RESTART} on oneshot service" \
             "First-boot wizard must NOT restart; it is idempotency-guarded by ConditionPathExists"
        ;;
esac

# ---------------------------------------------------------------------------
# Assertion 7: orionx-mesh-discover.timer — timer unit
#   MUST declare OnUnitActiveSec= or OnBootSec= (cadence-driven recovery)
#   Covers node-drop failure mode (mesh peers re-added after drop)
# ---------------------------------------------------------------------------
section "orionx-mesh-discover.timer (cadence-driven recovery — node drop)"

UNIT_FILE="${SYSTEMD_DIR}/orionx-mesh-discover.timer"

# Verify it's actually a .timer unit (has [Timer] section)
if grep -q "^\[Timer\]" "${UNIT_FILE}"; then
    pass "orionx-mesh-discover.timer: [Timer] section present"
else
    fail "orionx-mesh-discover.timer: [Timer] section missing" \
         "File does not appear to be a valid systemd timer unit"
fi

ACTUAL_ON_ACTIVE="$(get_directive "${UNIT_FILE}" "OnUnitActiveSec")"
ACTUAL_ON_BOOT="$(get_directive "${UNIT_FILE}" "OnBootSec")"

if [[ -n "${ACTUAL_ON_ACTIVE}" ]]; then
    pass "orionx-mesh-discover.timer: OnUnitActiveSec=${ACTUAL_ON_ACTIVE} (periodic cadence configured)"
elif [[ -n "${ACTUAL_ON_BOOT}" ]]; then
    pass "orionx-mesh-discover.timer: OnBootSec=${ACTUAL_ON_BOOT} (boot cadence configured)"
else
    fail "orionx-mesh-discover.timer: neither OnUnitActiveSec= nor OnBootSec= found" \
         "Timer must declare periodic cadence to provide node-drop recovery"
fi

# If both are present, that's fine (belt-and-suspenders)
if [[ -n "${ACTUAL_ON_ACTIVE}" && -n "${ACTUAL_ON_BOOT}" ]]; then
    pass "orionx-mesh-discover.timer: both OnBootSec=${ACTUAL_ON_BOOT} and OnUnitActiveSec=${ACTUAL_ON_ACTIVE} (belt-and-suspenders)"
fi

# ---------------------------------------------------------------------------
# Assertion 8: orionx-mesh-health.timer — timer unit
#   MUST declare OnUnitActiveSec= or OnBootSec= (cadence-driven recovery)
#   Covers network-flap failure mode (mesh links re-established after flap)
# ---------------------------------------------------------------------------
section "orionx-mesh-health.timer (cadence-driven recovery — network flap)"

UNIT_FILE="${SYSTEMD_DIR}/orionx-mesh-health.timer"

# Verify it's actually a .timer unit (has [Timer] section)
if grep -q "^\[Timer\]" "${UNIT_FILE}"; then
    pass "orionx-mesh-health.timer: [Timer] section present"
else
    fail "orionx-mesh-health.timer: [Timer] section missing" \
         "File does not appear to be a valid systemd timer unit"
fi

ACTUAL_ON_ACTIVE="$(get_directive "${UNIT_FILE}" "OnUnitActiveSec")"
ACTUAL_ON_BOOT="$(get_directive "${UNIT_FILE}" "OnBootSec")"

if [[ -n "${ACTUAL_ON_ACTIVE}" ]]; then
    pass "orionx-mesh-health.timer: OnUnitActiveSec=${ACTUAL_ON_ACTIVE} (periodic cadence configured)"
elif [[ -n "${ACTUAL_ON_BOOT}" ]]; then
    pass "orionx-mesh-health.timer: OnBootSec=${ACTUAL_ON_BOOT} (boot cadence configured)"
else
    fail "orionx-mesh-health.timer: neither OnUnitActiveSec= nor OnBootSec= found" \
         "Timer must declare periodic cadence to provide network-flap recovery"
fi

if [[ -n "${ACTUAL_ON_ACTIVE}" && -n "${ACTUAL_ON_BOOT}" ]]; then
    pass "orionx-mesh-health.timer: both OnBootSec=${ACTUAL_ON_BOOT} and OnUnitActiveSec=${ACTUAL_ON_ACTIVE} (belt-and-suspenders)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
TOTAL=$(( PASS + FAIL ))
echo "Results: ${PASS} passed, ${FAIL} failed (total: ${TOTAL})"
echo "==========================================="

if [[ ${FAIL} -gt 0 ]]; then
    echo ""
    echo "Coverage note: 'Disk full' failure mode is not covered by Restart= or"
    echo "timer config alone — documented gap, routed to W7-6-bis or Phase 8."
    exit 1
fi

echo ""
echo "Coverage note: 'Disk full' failure mode is not covered by Restart= or"
echo "timer config alone — documented gap, routed to W7-6-bis or Phase 8."
exit 0
