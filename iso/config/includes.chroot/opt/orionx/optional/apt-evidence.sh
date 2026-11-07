#!/usr/bin/env bash
# shellcheck shell=bash
#
# apt-evidence.sh — collect, read-only, what apt did and would do on this
# booted Orion-X deck, into one tarball the operator can attach to an issue
# (#121; decision DEC-PHASE13-051 in iso/config/hooks/normal/0100-create-user.hook.chroot).
#
# It is a diagnostic, not an installer: it NEVER runs apt-get update, install,
# remove, purge, upgrade or autoremove, and never calls dpkg with a verb that
# writes. Every apt-get call here carries -s (simulate). tests/unit/test_apt_evidence.sh
# executes it against stubs and asserts exactly that.
#
# Usage (on the deck; sudo is needed because /var/log/apt/term.log* is root:adm 0640):
#   sudo apt-get update                           # optional, see "Package lists" below
#   sudo /opt/orionx/optional/apt-evidence.sh     # prints the tarball path last
#   sudo /opt/orionx/optional/apt-evidence.sh --help
#
# Exit codes: 0 bundle written; 1 hard failure (tool missing, input unreadable,
# tarball not writable); 2 argument error. Absent /var/log/apt/* files are
# recorded in MISSING.txt and shouted on stderr but do not fail the run: on a
# fresh amnesic boot "nothing has been logged since boot" is itself the fact.
#
# ---------------------------------------------------------------------------
# What the tree says (#121: `apt install brightnessctl` on the booted v3.1.0
# image "seemed to mess up other packages"). Facts, then suspects ranked by
# how well they fit the report, each with what in this bundle confirms or
# clears it. The evidence has to come from the deck; nothing below is proven.
#
# FACTS
#  F1 iso/auto/config:132 — `--apt-indices false`: the image ships NO package
#     lists. On a fresh boot `apt-get install anything` says "Unable to locate
#     package" until the operator runs `apt-get update`; the lists then come
#     from the mirror AS OF THAT DAY, not as of the build.
#  F2 iso/auto/config:147-148 — `--security true --updates true`: the booted
#     sources.list carries trixie, trixie-security and trixie-updates. No
#     preferences/pins ship (nothing under includes.chroot/etc/apt; the only
#     archive config is config/archives/debian-nonfree.list.chroot, build-time).
#  F3 iso/config/hooks/live/0890-security-updates.hook.chroot:10-11 — the
#     chroot is fully upgraded (`apt-get upgrade --with-new-pkgs`) right before
#     sealing, so a post-boot `apt-get -s upgrade` lists exactly what the
#     mirror published AFTER the build date.
#  F4 iso/config/hooks/live/0900-trim.hook.chroot:107-197 — the trim purge is
#     simulated first and skips any target whose plan would remove a protected
#     (apt-mark manual + CRITICAL) package; the real purge is best-effort
#     (`|| echo WARNING`, line 191-192), then `apt-get autoremove --purge`.
#     0500 also purges gcc/g++ and build-essential/dpkg-dev/make/python3-dev
#     (0500-install-external-tools.hook.chroot:382, 538). Dependencies pulled
#     by purged packages are therefore `auto` and already autoremoved at build
#     time; a leftover would show up in `dpkg -l | grep -v ^ii` or
#     `dpkg --audit` on a fresh boot, before any apt command.
#  F5 iso/config/hooks/normal/0100-create-user.hook.chroot (bashrc heredoc) —
#     until DEC-PHASE13-051 the shipped alias was
#     `update='sudo apt-get update && sudo apt-get upgrade'`: one word
#     refreshed the lists AND upgraded every package the mirror had moved since
#     the build, into the RAM overlay, under the running desktop.
#  F6 iso/config/hooks/live/0620-service-hardening.hook.chroot:67 — apt-daily
#     and apt-daily-upgrade are MASKED: nothing on the deck runs apt by itself.
#     Ruled out as a cause.
#  F7 brightnessctl 0.5.1 (trixie) Depends: libc6 (>= 2.34); Recommends:
#     brightness-udev → udev. `--apt-recommends true` is the image default and
#     the booted apt keeps the Debian default (install Recommends), so a plain
#     install is 2 packages and cannot cascade on its own.
#  F8 #148 / DEC-PHASE13-032 — on the same Pavilion the RTC was read as UTC
#     and apt rejected every Release file ("not valid yet") on v3.1.0/v3.1.1.
#     Fixed in the wizard since v3.1.2; v3.1.4 (the deck now) asks for the
#     timezone, RTC mode and NTP.
#
# SUSPECTS, ranked
#  S1 The `update` alias (F5) was run before or after the install and upgraded
#     the live overlay: a long "The following packages will be upgraded" list,
#     libraries replaced under xfce4/dbus/polkit in the running session, and
#     the RAM overlay filling — all read as "messed up other packages".
#     Confirms: history.log shows an `apt-get upgrade` transaction with
#     Commandline: apt-get upgrade (sudo's `Requested-By:` line names the
#     operator) near the brightnessctl install. Clears: no Upgrade: stanza.
#  S2 Clock skew (F8) on v3.1.0: `apt update` rejected security/updates, so the
#     lists were partial or stale; a later retry with a corrected clock then
#     pulled a different set. Confirms: term.log "Release file ... is not
#     valid yet" / "E: ... InRelease" lines; `timedatectl` in this bundle
#     showing RTC in local TZ: yes. Clears: clean `apt-get update` in term.log.
#  S3 Build-time leftovers (F4): a half-configured or `rc` package from the
#     purge, shown as "The following packages were automatically installed and
#     are no longer required" or an unmet-Recommends line at every apt run,
#     misread as damage from the install. Confirms: non-`ii` rows in
#     dpkg-l-not-ii.txt and `dpkg --audit` output on a FRESH boot (before any
#     apt command). Clears: both empty.
#  S4 brightnessctl itself (F7): expected to be the weakest; the simulation
#     apt-get-s-install-brightnessctl.txt lists exactly what it would touch.
#     Confirms: more than brightnessctl + brightness-udev in the plan.
#
# Note on the fixed problem: xfce4-power-manager ships since v3.1.1 (#119,
# DEC-PHASE13-023) and owns the brightness keys, so brightnessctl is not
# needed on current images; the question left is why apt behaved as it did.
# ---------------------------------------------------------------------------

set -euo pipefail

# Test seam only: a prefix for the files this script reads (never set on the
# deck). Commands are found on PATH, so tests stub apt-get/dpkg/... there.
ROOT="${ORIONX_APT_EVIDENCE_ROOT:-}"
OUT_DIR="${ORIONX_APT_EVIDENCE_DIR:-}"

PROBE_PKG="brightnessctl"

usage() {
    cat <<'EOF'
Usage: sudo /opt/orionx/optional/apt-evidence.sh [--help]

Collects apt/dpkg evidence from this booted deck into
~/orionx-apt-evidence-<UTC timestamp>.tar.gz (read-only: every apt-get call is
a simulation; nothing is installed, removed, upgraded or refreshed).

Contents: /var/log/apt/history.log* term.log* and /var/log/dpkg.log*,
apt-get -s install brightnessctl, apt-get -s upgrade, apt-cache policy,
dpkg -l rows that are not "ii", dpkg --audit, apt-mark showmanual (+ count),
the live overlay's free space (df, findmnt), the apt sources/pins/conf,
/etc/orionx-version, the clock (timedatectl) and the package-list state.

Run `sudo apt-get update` first if you want the simulations to resolve
against current lists: the image ships none (--apt-indices false).
EOF
}

case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

die()  { echo "ERROR: [apt-evidence] $*" >&2; exit 1; }
warn() { echo "WARNING: [apt-evidence] $*" >&2; }
info() { echo "[apt-evidence] $*"; }

# --- preflight: tools and readable inputs; LOUD, never silent -----------------
for tool in apt-get apt-cache apt-mark dpkg df tar date; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH — this is not a Debian apt system?"
done
[[ -d "$ROOT/etc/apt" ]]            || die "$ROOT/etc/apt is missing — cannot describe the apt sources"
[[ -r "$ROOT/var/lib/dpkg/status" ]] || die "$ROOT/var/lib/dpkg/status is not readable — dpkg state is the core of this bundle"

# Files to bundle verbatim. A file that exists but cannot be read is a hard
# failure with the fix (sudo); a file that does not exist is recorded.
EVIDENCE_FILES=()
MISSING=()
unreadable=()
for pattern in "$ROOT/var/log/apt/history.log" "$ROOT/var/log/apt/history.log.*" \
               "$ROOT/var/log/apt/term.log"    "$ROOT/var/log/apt/term.log.*" \
               "$ROOT/var/log/dpkg.log"        "$ROOT/var/log/dpkg.log.*" \
               "$ROOT/etc/orionx-version"; do
    found=0
    # shellcheck disable=SC2086  # unquoted on purpose: glob expansion
    for f in $pattern; do
        [[ -e "$f" ]] || continue
        found=1
        if [[ -r "$f" ]]; then EVIDENCE_FILES+=("$f"); else unreadable+=("$f"); fi
    done
    # A literal (non-glob) pattern that matched nothing is a missing input.
    if [[ $found -eq 0 && "$pattern" != *'*'* ]]; then MISSING+=("${pattern#"$ROOT"}"); fi
done
if [[ ${#unreadable[@]} -gt 0 ]]; then
    printf 'ERROR: [apt-evidence] not readable as %s:\n' "$(id -un)" >&2
    printf '    %s\n' "${unreadable[@]}" >&2
    die "re-run with sudo: sudo /opt/orionx/optional/apt-evidence.sh"
fi
for m in "${MISSING[@]+"${MISSING[@]}"}"; do
    warn "MISSING: $m — no such file on this deck (recorded in MISSING.txt)"
done

# --- where the tarball goes: the invoking operator's home, even under sudo ----
if [[ -z "$OUT_DIR" ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
        OUT_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
        [[ -n "$OUT_DIR" ]] || die "cannot resolve the home directory of SUDO_USER=$SUDO_USER"
    else
        OUT_DIR="${HOME:?HOME is unset}"
    fi
fi
[[ -d "$OUT_DIR" && -w "$OUT_DIR" ]] || die "output directory $OUT_DIR is not a writable directory"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="orionx-apt-evidence-$STAMP"
TARBALL="$OUT_DIR/$NAME.tar.gz"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/apt-evidence.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
B="$WORK/$NAME"
mkdir -p "$B/files"

# run_cmd <outfile> <cmd...> — capture stdout+stderr and the exit code; a
# failing simulation (e.g. "Unable to locate package") IS evidence, not an abort.
run_cmd() {
    local name="$1"; shift
    local rc=0
    {
        printf '$ %s\n' "$*"
        "$@" 2>&1 || rc=$?
        printf '\n[exit %d]\n' "$rc"
    } > "$B/$name" 2>&1 || true
    info "$(printf '%-44s exit %d' "$name" "$rc")"
}

info "collecting into $B"

# 1. Logs and identity, verbatim (paths kept relative under files/)
for f in "${EVIDENCE_FILES[@]+"${EVIDENCE_FILES[@]}"}"; do
    rel="${f#"$ROOT"}"
    mkdir -p "$B/files/$(dirname "$rel")"
    cp -p "$f" "$B/files/$rel"
done
: > "$B/MISSING.txt"
for m in "${MISSING[@]+"${MISSING[@]}"}"; do echo "$m" >> "$B/MISSING.txt"; done

# 2. apt configuration as the booted system sees it (sources, pins, conf)
mkdir -p "$B/files/etc/apt"
for d in sources.list sources.list.d preferences preferences.d apt.conf.d; do
    if [[ -e "$ROOT/etc/apt/$d" ]]; then cp -rp "$ROOT/etc/apt/$d" "$B/files/etc/apt/"; fi
done
ls -la "$ROOT/etc/apt" "$ROOT/etc/apt/trusted.gpg.d" > "$B/etc-apt-listing.txt" 2>&1 || true

# 3. Package-list state: with --apt-indices false this is empty until the
#    operator runs apt-get update, and the simulations below then cannot resolve.
LISTS="$ROOT/var/lib/apt/lists"
ls -la "$LISTS" > "$B/apt-lists-listing.txt" 2>&1 || true
n_lists=$(find "$LISTS" -maxdepth 1 -type f ! -name lock 2>/dev/null | wc -l | tr -d ' ')
if [[ "$n_lists" -eq 0 ]]; then
    warn "/var/lib/apt/lists holds no package lists (the image ships none: --apt-indices false)."
    warn "The apt-get -s simulations below will say 'Unable to locate package'."
    warn "For a resolvable plan: sudo apt-get update, then re-run this script (both runs are useful)."
fi

# 4. Simulations and read-only queries. Every apt-get call is -s.
run_cmd "apt-get-s-install-$PROBE_PKG.txt" apt-get -s install "$PROBE_PKG"
run_cmd "apt-get-s-upgrade.txt"           apt-get -s upgrade
run_cmd "apt-cache-policy.txt"            apt-cache policy
run_cmd "apt-cache-policy-probe.txt"      apt-cache policy "$PROBE_PKG" brightness-udev xfce4-power-manager libc6
run_cmd "apt-mark-showmanual.txt"         apt-mark showmanual
run_cmd "dpkg-audit.txt"                  dpkg --audit
run_cmd "dpkg-l.txt"                      dpkg -l
{
    printf '$ dpkg -l | grep -v "^ii"   (every package whose state is not "installed ok")\n'
    dpkg -l 2>&1 | grep -v '^ii' || true
} > "$B/dpkg-l-not-ii.txt"
{
    printf 'apt-mark showmanual | wc -l = '
    apt-mark showmanual 2>/dev/null | wc -l | tr -d ' '
} > "$B/apt-mark-showmanual-count.txt" || true

# 5. The live overlay: where an install actually lands, and how full it is.
run_cmd "df-h.txt"  df -h / /run/live/overlay /run/live/medium /tmp
if command -v findmnt >/dev/null 2>&1; then
    run_cmd "findmnt.txt" findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,OPTIONS
fi
if command -v free >/dev/null 2>&1; then run_cmd "free-h.txt" free -h; fi
if [[ -r "$ROOT/proc/cmdline" ]]; then cp "$ROOT/proc/cmdline" "$B/proc-cmdline.txt"; fi

# 6. Clock (S2) and boot context.
if command -v timedatectl >/dev/null 2>&1; then run_cmd "timedatectl.txt" timedatectl; fi
if command -v uptime >/dev/null 2>&1; then run_cmd "uptime.txt" uptime; fi
run_cmd "date-u.txt" date -u

# 7. Manifest of the bundle.
{
    echo "orionx apt evidence bundle — $STAMP (UTC)"
    echo "collected by: $(id -un) (SUDO_USER=${SUDO_USER:-none}) on $(hostname 2>/dev/null || echo '?')"
    echo "issue: jarocki/orion#121; decision: DEC-PHASE13-051"
    echo "probe package: $PROBE_PKG"
    echo "package lists present: $n_lists"
    echo "missing inputs: ${#MISSING[@]}"
    echo
    echo "Read the files in this order: files/var/log/apt/history.log, files/var/log/apt/term.log,"
    echo "apt-get-s-install-$PROBE_PKG.txt, apt-get-s-upgrade.txt, dpkg-l-not-ii.txt, dpkg-audit.txt,"
    echo "timedatectl.txt, df-h.txt. The suspects are ranked in the header of apt-evidence.sh."
    echo
    (cd "$WORK" && find "$NAME" -type f | sort)
} > "$B/README.txt"

tar -C "$WORK" -czf "$TARBALL" "$NAME" || die "could not write $TARBALL"
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root && -z "${ORIONX_APT_EVIDENCE_DIR:-}" ]]; then
    chown "$SUDO_USER" "$TARBALL" 2>/dev/null || warn "could not chown $TARBALL to $SUDO_USER"
fi

info "nothing was installed, removed, upgraded or refreshed."
if [[ ${#MISSING[@]} -gt 0 ]]; then
    warn "${#MISSING[@]} expected file(s) were absent; see MISSING.txt inside the bundle."
fi
info "attach this to the issue:"
echo "$TARBALL"
