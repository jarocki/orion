#!/usr/bin/env bash
# ci-local.sh — run, on this machine, the gates the CI workflows run.
#
# @decision DEC-PHASE12-123
# @title A local CI-equivalent run for heads that have no CI evidence
# @status accepted
# @rationale release-process §1 requires lint.yml and e2e-test.yml green on
#   the release head, and qemu-test.yml's ISO gates, but the release branch's
#   43 commits were never pushed and lint/e2e only triggered on develop
#   (release-tests F-02). The workflows now also trigger on release/**; until
#   a head is pushed, this script produces the same evidence locally. It calls
#   the same entry points the workflows call (make targets and the
#   tests/integration gates), never a parallel copy of their logic:
#     lint.yml      -> make lint ; make test-unit
#     e2e-test.yml  -> make test-e2e                       (--e2e; needs Docker)
#     qemu-test.yml -> test-iso-hooks-applied.sh BUILD_LOG ; test-iso-content-
#                      presence.sh ISO ; qemu-boot-test.sh --mode both
#                                                          (--iso + --build-log)
#   It does not build the ISO (the lead builds it; one build per volume).
#   Every job runs even after an earlier one fails; the summary lists each
#   job's exit code and the script exits non-zero if any failed. Logs go to
#   tmp/ci-local/<job>.log. Not run: the GitHub-hosted environment itself
#   (ubuntu-latest, Python 3.13 from setup-python), so record the host's tool
#   versions alongside the result; they are printed at the top.
#
# Usage:
#   scripts/release/ci-local.sh [--e2e] [--iso <iso> --build-log <log>] [--no-boot]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$(dirname "$HERE")")"
LOGDIR="$ROOT/tmp/ci-local"
E2E=0; ISO=""; BUILD_LOG=""; BOOT=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --e2e) E2E=1; shift ;;
        --iso) ISO="${2:?--iso needs a path}"; shift 2 ;;
        --build-log) BUILD_LOG="${2:?--build-log needs a path}"; shift 2 ;;
        --no-boot) BOOT=0; shift ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
    esac
done
if [[ -n "$ISO" && -z "$BUILD_LOG" ]] || [[ -z "$ISO" && -n "$BUILD_LOG" ]]; then
    echo "ERROR: --iso and --build-log go together (qemu-test.yml checks both)" >&2; exit 2
fi
mkdir -p "$LOGDIR"
export PYTHONDONTWRITEBYTECODE=1

names=(); codes=()
job() {  # <name> <command...>
    local name="$1"; shift
    echo "=== [$name] $* (log: tmp/ci-local/$name.log)"
    (cd "$ROOT" && "$@") > "$LOGDIR/$name.log" 2>&1
    local rc=$?
    names+=("$name"); codes+=("$rc")
    if [[ $rc -eq 0 ]]; then echo "    ok"; else echo "    FAILED (exit $rc); last lines:"; tail -15 "$LOGDIR/$name.log" | sed 's/^/      /'; fi
}

echo "ci-local: $(cd "$ROOT" && git rev-parse --short=12 HEAD 2>/dev/null || echo no-git)$(cd "$ROOT" && git diff --quiet 2>/dev/null || echo ' (dirty)')"
echo "host: $(uname -sm); $(python3 --version 2>&1); $(shellcheck --version 2>/dev/null | sed -n 2p); ruff $(ruff --version 2>/dev/null | awk '{print $2}')"

job lint            make lint
job test-unit       make test-unit
[[ $E2E -eq 1 ]] && job e2e make test-e2e
if [[ -n "$ISO" ]]; then
    job hooks-applied     env BUILD_LOG="$BUILD_LOG" bash tests/integration/test-iso-hooks-applied.sh
    job content-presence  bash tests/integration/test-iso-content-presence.sh "$ISO"
    [[ $BOOT -eq 1 ]] && job qemu-boot bash scripts/qemu-boot-test.sh --mode both --timeout 900 --iso "$ISO"
fi

echo; echo "=== ci-local summary"
fail=0
for i in "${!names[@]}"; do
    printf '  %-18s %s\n' "${names[$i]}" "$([[ ${codes[$i]} -eq 0 ]] && echo PASS || echo "FAIL (exit ${codes[$i]})")"
    [[ ${codes[$i]} -eq 0 ]] || fail=1
done
[[ $E2E -eq 1 ]] || echo "  e2e                not run (pass --e2e; e2e-test.yml runs it)"
[[ -n "$ISO" ]] || echo "  ISO gates          not run (pass --iso and --build-log; qemu-test.yml runs them)"
exit $fail
