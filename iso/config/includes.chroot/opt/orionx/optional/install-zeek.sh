#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE12-028
# @title Zeek post-boot installer — the recovery path for a build-time soft-fail
# @status accepted
# @rationale Zeek is NOT in Debian 13 main. The build already tries to install
#   it: iso/config/hooks/live/0500-install-external-tools.hook.chroot adds the
#   OpenSUSE Build Service repo (security:zeek / Debian_13, DEC-PHASE12-003)
#   and installs zeek-core (DEC-PHASE12-015). That block is deliberately
#   SOFT-FAIL, so a build whose network or repo hiccupped produces an ISO with
#   no Zeek and no error the operator ever sees.
#
#   That is not hypothetical. `grep -c zeek iso/chroot.files` (a build listing,
#   untracked since QA round 1; see `git show f7c75ec:iso/chroot.files`) on the
#   2026-09-27 image listing returns 0: the shipped ISO has no /opt/zeek at
#   all, while iso/config/hooks/live/0700-orionx-setup.hook.chroot cheerfully
#   skips the /usr/bin/zeek symlink and scripts/artifact-analyzer.py keeps
#   advertising zeek as a wrapped tool. A soft-fail with no recovery path is
#   how a capability goes missing quietly — the same class of bug as an IDS
#   with no rules (DEC-PHASE12-024).
#
#   This script is that recovery path. It is the POST-BOOT twin of the 0500
#   block, not a second authority for anything: it installs the same package
#   (zeek-core) from the same repo, and everything downstream — the PATH
#   symlinks in 0700, the Zeek ingest in orionx-postured — discovers Zeek at
#   runtime rather than being told about it at build time. Install it today
#   or in six months; nothing needs rebuilding or reconfiguring.
#
#   What this adds over the 0500 block, because a post-boot install is run by
#   an operator on a deck that may already be compromised:
#
#     1. The signing key's FINGERPRINT is pinned and verified before the key
#        is trusted. 0500 pipes Release.key straight into
#        /etc/apt/trusted.gpg.d/, which trusts whatever the network hands
#        back. Here the fetched key must present
#        F9FA0223B56B116C363737EF5DA57BDD6DD785CA or nothing is written.
#        A fingerprint is the right pin for an apt repo: package digests move
#        with every upstream release, the repo key does not.
#     2. The keyring is scoped with signed-by= to this one source, so trusting
#        the OBS key does not mean trusting it for Debian's own archive.
#     3. It is IDEMPOTENT and says which path it took. Re-running on a deck
#        that already has Zeek reports the version and exits 0 without
#        touching apt. --force reinstalls anyway.
#
#   Verification is not "the command exited 0": the script runs the installed
#   binary and requires a version string, because an apt success with a
#   half-unpacked /opt/zeek is exactly the state that would otherwise be
#   reported as a win.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-zeek.sh
#   sudo /opt/orionx/optional/install-zeek.sh --force     # reinstall
#   sudo /opt/orionx/optional/install-zeek.sh --check     # report only, no changes
#
# What this installs:
#   zeek-core 9.x (Zeek Project, BSD-3-Clause)  ~180 MB installed
#   Destination: /opt/zeek/  (bin/zeek, bin/zeek-cut)
#   Repo:        download.opensuse.org/repositories/security:/zeek/Debian_13/
#   Requires:    network, gnupg, wget, ca-certificates
#   Mission verb: analyze — network protocol analysis and connection records
#
#   NOT the `zeek` metapackage: it pulls zeek-zkg -> zeek-spicy-dev (194 MB)
#   + btest-data + a gcc toolchain, a plugin-building kit this deck never
#   uses (DEC-PHASE12-015). zeek-core is the analyzer itself.

set -euo pipefail

# SC1091: library lives at runtime path /opt/orionx/optional/lib/ on the target
# system; shellcheck cannot follow the absolute source path on the build host.
#
# ORIONX_INSTALLER_LIB overrides the path for tests ONLY. The default is the
# production path, so runtime behaviour is byte-identical to the other
# installers; the override exists so tests/unit/test_zeek_pcap.sh can execute
# THIS script rather than grepping it and hoping. An installer whose only
# verification is "the source file contains the right words" is not tested.
# shellcheck disable=SC1090,SC1091
source "${ORIONX_INSTALLER_LIB:-/opt/orionx/optional/lib/orionx-installer-common.sh}"

# ---------------------------------------------------------------------------
# Pins and paths — single authority for this installer
# ---------------------------------------------------------------------------

# security OBS Project <security@build.opensuse.org>, 4096R.
# Verified 2026-09-29 against
# https://download.opensuse.org/repositories/security:zeek/Debian_13/Release.key
ZEEK_REPO_KEY_FPR="F9FA0223B56B116C363737EF5DA57BDD6DD785CA"
ZEEK_REPO_BASE="https://download.opensuse.org/repositories/security:/zeek/Debian_13"
ZEEK_REPO_KEY_URL="https://download.opensuse.org/repositories/security:zeek/Debian_13/Release.key"
ZEEK_KEYRING="/usr/share/keyrings/orionx-zeek-obs-archive-keyring.gpg"
ZEEK_SOURCE_LIST="/etc/apt/sources.list.d/orionx-zeek.list"
# ORIONX_ZEEK_PREFIX lets a test point the idempotence check at a scratch
# tree, and lets an operator who installed Zeek somewhere else still use the
# --check verb. Default is the OBS package's real prefix.
ZEEK_PREFIX="${ORIONX_ZEEK_PREFIX:-/opt/zeek}"
ZEEK_BIN="${ZEEK_PREFIX}/bin/zeek"

FORCE=0
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --force)  FORCE=1 ;;
        --check)  CHECK_ONLY=1 ;;
        -h|--help)
            sed -n '/^# Usage/,/^#   NOT the/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            orionx_log_error "unknown argument: $arg (see --help)"
            exit 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# orionx_zeek_installed — true if a Zeek binary is present AND runs.
# "dpkg says yes" is not the question; a half-unpacked /opt/zeek would pass
# that and fail the operator at the moment they needed it.
# ---------------------------------------------------------------------------
orionx_zeek_installed() {
    [[ -x "$ZEEK_BIN" ]] && "$ZEEK_BIN" --version >/dev/null 2>&1
}

orionx_zeek_version() {
    "$ZEEK_BIN" --version 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# orionx_zeek_emit <severity> <message…> — best-effort bus event.
# The running orionx-postured discovers Zeek on its own poll, so this is
# narration, not signalling. Never fail the install because the bus is absent.
# ---------------------------------------------------------------------------
orionx_zeek_emit() {
    local sev="$1"; shift
    command -v orionx-event >/dev/null 2>&1 || return 0
    # source=installer / category=tooling deliberately: the Control Center's
    # scans-count widget counts any event whose source is suricata/zeek/
    # nucleotide or whose category is ids/scan/recon/probe. An install
    # notification is not a detection and must not inflate that gauge.
    orionx-event --severity "$sev" --source installer --category tooling "$*" \
        >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Idempotence gate — checked BEFORE the root/network preflight, so `--check`
# and a re-run on an already-provisioned air-gapped deck both work offline.
# ---------------------------------------------------------------------------
if orionx_zeek_installed; then
    orionx_log_info "Zeek already installed: $(orionx_zeek_version)"
    orionx_log_info "  Binary:  $ZEEK_BIN"
    if [[ $FORCE -eq 0 ]]; then
        orionx_log_info "Nothing to do. Re-run with --force to reinstall."
        exit 0
    fi
    orionx_log_info "--force given; reinstalling over the existing install."
elif [[ $CHECK_ONLY -eq 1 ]]; then
    orionx_log_info "Zeek is NOT installed (no working $ZEEK_BIN)."
    orionx_log_info "  Install with: sudo $0"
    exit 1
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    exit 0
fi

orionx_require_root
orionx_require_network download.opensuse.org

# ---------------------------------------------------------------------------
# Preflight banner (DEC-PHASE11-011: name / size / license / network / mission)
# ---------------------------------------------------------------------------
orionx_log_info "=== Orion-X optional installer: Zeek ==="
orionx_log_info "  Size:    ~180 MB installed (zeek-core, no plugin toolchain)"
orionx_log_info "  License: BSD-3-Clause (The Zeek Project)"
orionx_log_info "  Network: download.opensuse.org (security:zeek / Debian_13)"
orionx_log_info "  Mission: analyze — protocol analysis, connection records, notices"
orionx_log_info "  Key pin: ${ZEEK_REPO_KEY_FPR}"

# ---------------------------------------------------------------------------
# Trust anchor: fetch the repo key and REFUSE it unless the fingerprint matches
# ---------------------------------------------------------------------------
orionx_apt_install gnupg ca-certificates wget

key_armored="$(mktemp)"
key_ring="$(mktemp)"
cleanup() { rm -f "$key_armored" "$key_ring"; }
trap cleanup EXIT

orionx_log_info "Fetching the OBS signing key..."
if ! wget -q -O "$key_armored" "$ZEEK_REPO_KEY_URL"; then
    orionx_log_error "Could not download $ZEEK_REPO_KEY_URL"
    orionx_log_error "Zeek NOT installed. Nothing was changed."
    orionx_zeek_emit warning "Zeek install FAILED — could not fetch the OBS signing key. Zeek remains absent; Suricata and orionx-scanwatch are unaffected."
    exit 1
fi

if ! gpg --dearmor --output "$key_ring" < "$key_armored" 2>/dev/null; then
    orionx_log_error "Downloaded key is not a valid PGP key block."
    orionx_log_error "Zeek NOT installed. Nothing was changed."
    exit 1
fi

# --with-colons output: the fpr record's 10th field is the full fingerprint.
actual_fpr="$(gpg --show-keys --with-colons --with-fingerprint "$key_armored" 2>/dev/null \
    | awk -F: '$1=="fpr" {print $10; exit}')"

if [[ "$actual_fpr" != "$ZEEK_REPO_KEY_FPR" ]]; then
    orionx_log_error "SIGNING KEY FINGERPRINT MISMATCH — refusing to trust this repo."
    orionx_log_error "  expected: $ZEEK_REPO_KEY_FPR"
    orionx_log_error "  actual:   ${actual_fpr:-<none found>}"
    orionx_log_error "Zeek NOT installed. No apt source or keyring was written."
    orionx_log_error "Either upstream rotated the key (check the OBS project page"
    orionx_log_error "and update ZEEK_REPO_KEY_FPR in this script) or this download"
    orionx_log_error "was tampered with. Do not work around this by deleting the check."
    orionx_zeek_emit critical "Zeek install REFUSED — OBS repo signing key fingerprint mismatch (expected ${ZEEK_REPO_KEY_FPR}, got ${actual_fpr:-none}). No apt source was written."
    exit 1
fi
orionx_log_info "Signing key fingerprint verified: $actual_fpr"

# Idempotent: install -m 0644 overwrites cleanly and fixes permissions if a
# previous run or a hand-edit left them wrong.
install -m 0644 "$key_ring" "$ZEEK_KEYRING"
orionx_log_info "Keyring installed: $ZEEK_KEYRING"

# ---------------------------------------------------------------------------
# apt source, scoped to this keyring with signed-by=
# ---------------------------------------------------------------------------
# Rewritten every run rather than appended to: this file has exactly one
# correct content, so writing it is idempotent and a stale hand-edit is
# corrected rather than compounded.
cat > "$ZEEK_SOURCE_LIST" <<EOF
# Managed by /opt/orionx/optional/install-zeek.sh (DEC-PHASE12-028).
# signed-by= scopes the OBS key to this repo only.
deb [signed-by=${ZEEK_KEYRING}] ${ZEEK_REPO_BASE}/ /
EOF
orionx_log_info "apt source written: $ZEEK_SOURCE_LIST"

# ---------------------------------------------------------------------------
# Install — and on failure leave NOTHING dangling (the 0500 lesson: a stale
# sources.list.d entry breaks every later apt-get update on the deck).
# ---------------------------------------------------------------------------
if ! orionx_apt_install zeek-core; then
    orionx_log_error "apt failed to install zeek-core."
    rm -f "$ZEEK_SOURCE_LIST" "$ZEEK_KEYRING"
    apt-get update >/dev/null 2>&1 || true
    orionx_log_error "Rolled back the apt source and keyring so later updates still work."
    orionx_zeek_emit warning "Zeek install FAILED — apt could not install zeek-core. The apt source was rolled back; Zeek remains absent."
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify the thing actually runs. apt success is not installation success.
# ---------------------------------------------------------------------------
if ! orionx_zeek_installed; then
    orionx_log_error "apt reported success but $ZEEK_BIN does not run."
    orionx_log_error "This is the failure mode this check exists for: a package"
    orionx_log_error "that unpacked into an unusable state would otherwise be"
    orionx_log_error "reported as a successful install."
    orionx_zeek_emit critical "Zeek install BROKEN — apt succeeded but ${ZEEK_BIN} does not execute. Zeek ingest will stay dark."
    exit 1
fi

# ---------------------------------------------------------------------------
# PATH symlinks — mirrors the 0700 hook's SCRIPT_MAP entries so a post-boot
# install lands in exactly the same place a build-time install would have.
# ---------------------------------------------------------------------------
ln -sf "${ZEEK_PREFIX}/bin/zeek" /usr/bin/zeek
[[ -x "${ZEEK_PREFIX}/bin/zeek-cut" ]] && ln -sf "${ZEEK_PREFIX}/bin/zeek-cut" /usr/bin/zeek-cut

ZEEK_VERSION_STR="$(orionx_zeek_version)"
orionx_log_info "=== Installed: ${ZEEK_VERSION_STR} ==="
orionx_log_info ""
orionx_log_info "Nothing needs restarting. orionx-postured polls for Zeek and will"
orionx_log_info "begin ingesting notice.log / weird.log / conn.log on its next cycle,"
orionx_log_info "announcing the change on the R.A.I.N. bus."
orionx_log_info ""
orionx_log_info "To give it something to read:"
orionx_log_info "  sudo orionx-capture list                 # what can be captured"
orionx_log_info "  sudo orionx-capture start <iface>        # bounded PCAP capture"
orionx_log_info "  sudo mkdir -p /var/log/zeek/current && cd /var/log/zeek/current"
orionx_log_info "  sudo zeek -i <iface>                     # live analysis"
orionx_log_info "  zeek -r capture.pcap                     # offline analysis"

orionx_zeek_emit notice "Zeek installed post-boot: ${ZEEK_VERSION_STR}. orionx-postured will pick it up on its next poll — no reboot, no rebuild."
