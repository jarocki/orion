#!/usr/bin/env bash
# shellcheck shell=bash
#
# orionx-trust-launchers.sh — mark the Desktop's shipped launchers trusted so
# XFCE 4.20 opens them on the first double-click (#149, DEC-PHASE13-034)
#
# @decision DEC-PHASE13-034
# @canonical
# @category UX
# @title The Desktop launchers are marked trusted per user at every XFCE
#   session start, by setting the gvfs checksum attribute xfdesktop/Thunar
#   require; the image cannot pre-seed it
# @status accepted
# @rationale On the Pavilion (2026-10-31) every desktop icon — Cockpit, Attack
#   Map, GODSEYE, OSINT, the Guide — asked "untrusted application launcher" on
#   its first double-click. Not the clock. xfdesktop 4.20 hands the launch to
#   Thunar over D-Bus, and Thunar launches a .desktop file silently only when
#   libxfce4util's xfce_g_file_is_trusted() says so: the gvfs metadata
#   attribute `metadata::xfce-exe-checksum` must equal the SHA-256 of the
#   file's contents (libxfce4util/xfce-gio-extensions.c; it recomputes and
#   compares, nothing else). Accepting the dialog once stores that attribute,
#   per file, per user, in ~/.local/share/gvfs-metadata — a binary database
#   the live user does not have until live-config creates the account at
#   boot, so /etc/skel cannot carry it and the 0700 hook's `install -m 0755`
#   (the executable bit) is necessary but not sufficient.
#
#   So the attribute is set where it can be: in the user's session, by this
#   script, from an XDG autostart entry (orionx-trust-launchers.desktop), the
#   same shape as orionx-wallpaper.desktop (DEC-PHASE11-017). It uses the
#   same tool Thunar does (`gio set`, GIO -> gvfsd-metadata), computes the
#   same SHA-256, and only writes when the stored value differs, so a second
#   run is a handful of reads. It also keeps the executable bit, because
#   Thunar's classification looks at that too and the skel copy is the only
#   thing that set it. Scope: regular, non-symlink Desktop launchers whose
#   basename and contents match the root-owned /etc/skel/Desktop reference.
#   Added or modified launchers are never made executable or auto-trusted.
#
#   Why not trust the whole directory or patch Thunar's setting: Thunar has
#   no "trust everything" switch in 4.20, and a desktop that silently runs
#   any .desktop file dropped on it is the thing the dialog exists to stop.
#   Trusting exactly the files the image shipped, by content hash, keeps
#   that protection for anything that arrives later.
#
#   --check reports without writing (exit 1 when anything is untrusted), so
#   the User Guide can say "verify with orionx-trust-launchers --check" and
#   the v3.2.0 Pavilion boot can prove it. Idempotent; never exits non-zero
#   from the autostart path (a trust failure must not break the session).
#
# Usage:
#   orionx-trust-launchers.sh [--desktop-dir DIR] [--check] [--dry-run] [-h]
#
# Environment (tests):
#   ORIONX_DESKTOP_DIR   Desktop directory (default: $XDG_DESKTOP_DIR or ~/Desktop)
#   ORIONX_GIO_BIN       gio binary (default: gio on PATH)
#   ORIONX_LAUNCHER_REFERENCE_DIR  Test-only shipped reference directory
#
#   Decision Log entry as hand-written on 2026-11-01 (merged into this block
#   by #97, which made the block the authority): The Desktop's shipped
#   `.desktop` launchers are marked trusted per user at every XFCE session
#   start: `orionx-trust-launchers.sh` (XDG autostart
#   `orionx-trust-launchers.desktop`, also on PATH) sets the gvfs attribute
#   `metadata::xfce-exe-checksum` to the file's SHA-256 with `gio set`, keeps
#   `+x`, writes only on a difference, skips symlinks and non-launchers;
#   `--check` is the verdict (exit 1 when untrusted). Pavilion #149: every
#   desktop icon asked "untrusted application launcher" once. xfdesktop 4.20
#   delegates launching to Thunar, which trusts a launcher only when
#   libxfce4util's `xfce_g_file_is_trusted` finds that attribute equal to the
#   content hash; the attribute is per-user gvfs metadata that does not exist
#   before live-config creates the account, so neither `/etc/skel` nor a build
#   hook can carry it, and the 0700 hook's `install -m 0755` was necessary but
#   not sufficient. Trusting exactly the shipped files by content hash keeps
#   the dialog for anything dropped on the Desktop later. Headless xfdesktop
#   is not testable; the stub-gio suite proves the write, the v3.2.0 boot
#   proves the dialog is gone

set -euo pipefail

ATTR="metadata::xfce-exe-checksum"
DESKTOP_DIR="${ORIONX_DESKTOP_DIR:-${XDG_DESKTOP_DIR:-$HOME/Desktop}}"
GIO_BIN="${ORIONX_GIO_BIN:-gio}"
# The image hooks generate these root-owned files before live-config copies
# them into the user's home. Never derive the trust authority from that home.
REFERENCE_DIR="${ORIONX_LAUNCHER_REFERENCE_DIR:-/etc/skel/Desktop}"
MODE="apply"   # apply | check | dry-run

usage() {
    cat <<EOF
Usage: $(basename "$0") [--desktop-dir DIR] [--check] [--dry-run]

Marks only unchanged shipped Desktop launchers trusted for XFCE 4.20
(gvfs attribute $ATTR = SHA-256 of the shipped reference) and keeps them executable,
so xfdesktop/Thunar open it without the "untrusted application launcher"
dialog. Idempotent: only differing attributes are written.

  --desktop-dir DIR   Directory to process (default: $DESKTOP_DIR)
  --check             Report shipped launchers; exit 1 if untrusted or not executable
  --dry-run           Say what would be written; write nothing
  -h, --help          This text
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --desktop-dir) [[ -n "${2:-}" ]] || { echo "--desktop-dir needs a value" >&2; exit 2; }
                       DESKTOP_DIR="$2"; shift 2 ;;
        --check)       MODE="check"; shift ;;
        --dry-run)     MODE="dry-run"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log() { printf 'orionx-trust-launchers: %s\n' "$*"; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

stored_checksum() {
    # `gio info -a ATTR FILE` prints "  ATTR: value" when set, nothing otherwise.
    "$GIO_BIN" info -a "$ATTR" "$1" 2>/dev/null | sed -n "s/^[[:space:]]*${ATTR}: //p" | head -n1
}

if [[ ! -d "$DESKTOP_DIR" ]]; then
    log "no Desktop directory at $DESKTOP_DIR — nothing to do"
    exit 0
fi
if ! command -v "$GIO_BIN" >/dev/null 2>&1; then
    log "WARNING: gio not found ($GIO_BIN); cannot set $ATTR — launchers will ask on first use"
    [[ "$MODE" == "check" ]] && exit 2
    exit 0
fi

if [[ ! -d "$REFERENCE_DIR" || -L "$REFERENCE_DIR" ]]; then
    log "WARNING: shipped launcher reference unavailable at $REFERENCE_DIR; nothing will be trusted"
    [[ "$MODE" == "check" ]] && exit 2
    exit 0
fi

total=0; trusted=0; marked=0; untrusted=0; failed=0; made_exec=0; skipped=0; rejected=0
shopt -s nullglob
for f in "$DESKTOP_DIR"/*.desktop; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    total=$((total + 1))
    reference="$REFERENCE_DIR/${f##*/}"
    if [[ ! -e "$reference" && ! -L "$reference" ]]; then
        skipped=$((skipped + 1))
        log "SKIPPED: $f (not a shipped launcher)"
        continue
    fi
    # Compare before any chmod or metadata access. Always write the reference
    # hash, not a fresh hash of mutable Desktop bytes: a concurrent edit must
    # still invalidate trust rather than being blessed by a second read.
    if [[ ! -f "$reference" || -L "$reference" ]] ||
       ! want="$(sha256_of "$reference")" ||
       ! actual="$(sha256_of "$f")" || [[ "$actual" != "$want" ]]; then
        untrusted=$((untrusted + 1))
        rejected=$((rejected + 1))
        log "UNTRUSTED: $f (missing/unsafe reference or modified shipped content; left unchanged)"
        continue
    fi
    have="$(stored_checksum "$f" || true)"
    if [[ ! -x "$f" ]]; then
        case "$MODE" in
            apply)
                if chmod +x "$f" 2>/dev/null; then
                    made_exec=$((made_exec + 1))
                else
                    log "could not chmod +x $f"
                fi
                ;;
            dry-run) log "would chmod +x $f" ;;
            check)   ;;
        esac
    fi
    if [[ "$have" == "$want" && -x "$f" ]]; then
        trusted=$((trusted + 1))
        continue
    fi
    case "$MODE" in
        check)
            untrusted=$((untrusted + 1))
            log "UNTRUSTED: $f (stored: ${have:-none}; executable: $(if [[ -x "$f" ]]; then echo yes; else echo no; fi))"
            ;;
        dry-run)
            untrusted=$((untrusted + 1))
            log "would set $ATTR=$want on $f"
            ;;
        apply)
            if "$GIO_BIN" set -t string "$f" "$ATTR" "$want" 2>/dev/null; then
                marked=$((marked + 1))
            else
                failed=$((failed + 1))
                log "FAILED to set $ATTR on $f (is gvfsd-metadata reachable in this session?)"
            fi
            ;;
    esac
done
shopt -u nullglob

case "$MODE" in
    check)
        log "$DESKTOP_DIR: $total launcher(s), $trusted trusted, $untrusted untrusted, $skipped non-shipped skipped"
        # The only non-zero exit on purpose: --check is a verdict.
        [[ $untrusted -eq 0 ]] || exit 1
        ;;
    dry-run)
        log "$DESKTOP_DIR: $total launcher(s), $trusted already trusted, $((untrusted - rejected)) need trust/permission repair, $rejected unsafe/modified left unchanged, $skipped non-shipped skipped (dry-run)"
        ;;
    apply)
        log "$DESKTOP_DIR: $total launcher(s), $trusted already trusted, $marked marked, $made_exec made executable, $failed failed, $untrusted unsafe/modified, $skipped non-shipped skipped"
        ;;
esac
exit 0
