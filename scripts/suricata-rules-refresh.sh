#!/usr/bin/env bash
# shellcheck shell=bash
#
# suricata-rules-refresh.sh — refresh the VENDORED curated ET-Open subset that
# the ISO ships at /var/lib/suricata/rules (DEC-PHASE13-043, W11-6b, #125).
#
# The three vendored files live in the tree, like the go-roast binary and its
# provenance (DEC-PHASE12-002):
#   iso/config/includes.chroot/var/lib/suricata/rules/suricata.rules
#   iso/config/includes.chroot/var/lib/suricata/rules/orionx-rules.provenance.txt
#   iso/config/includes.chroot/var/lib/suricata/rules/LICENSE-ET-Open.txt
# This script rewrites them from a fresh (or given) ET-Open tarball; the
# maintainer reviews the diff and commits. Hook 0530 verifies them at build
# time and never touches the network. See the decision block in
# iso/config/hooks/live/0530-suricata-rules.hook.chroot for why: the upstream
# URL is a ROLLING daily object, so a build-time SHA-256 pin would fail every
# build after the day it was taken.
#
# What it needs: the Debian suricata package's stock /etc/suricata/rules
# (merged in) and the suricata binary (to prove the result loads). Where this
# host has neither, it re-runs itself inside a debian:trixie-slim container
# (the same image tests/unit/test_suricata_resilience.sh uses) when docker is
# present, and refuses otherwise unless --no-check AND --stock-dir are given.
#
# Usage:
#   make suricata-rules-refresh
#   scripts/suricata-rules-refresh.sh [--tarball FILE] [--url URL]
#       [--last-modified 'HTTP date'] [--stock-dir DIR] [--out-dir DIR]
#       [--no-check]
#
# Sourcing with ORIONX_RULES_REFRESH_LIB_ONLY=1 defines the functions and runs
# nothing (tests/unit/test_suricata_rules_hook.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Suricata 7.0 feed: the ISO's engine is 7.0.10 (trixie).
ET_OPEN_URL="${ET_OPEN_URL:-https://rules.emergingthreats.net/open/suricata-7.0/emerging.rules.tar.gz}"
# One emerging-<name>.rules per entry, in this order. A missing one is fatal.
ET_OPEN_CATEGORIES="scan attack_response exploit dos shellcode current_events"
# Named in the provenance so the exclusion is a recorded choice, not an omission.
ET_OPEN_EXCLUDED_NOTE="malware (19,392 sigs / 17.8 MB) and web_specific_apps (6,097 sigs / 5.8 MB) excluded by size; every other category excluded as out of scope for a segment sensor"
# Stock files the engine rejects under Debian's config (app-layer detection for
# these protocols is off: "protocol dnp3 cannot be used in a signature").
STOCK_EXCLUDED_FILES="dnp3-events.rules modbus-events.rules"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/iso/config/includes.chroot/var/lib/suricata/rules}"
STOCK_RULES_DIR="${STOCK_RULES_DIR:-/etc/suricata/rules}"
TARGET_RULES="suricata.rules"                      # the one name Debian's rule-files: loads
PROVENANCE_FILE="orionx-rules.provenance.txt"
LICENSE_COPY="LICENSE-ET-Open.txt"
PROBE_IMAGE="orionx-suricata-probe:trixie"
LOG_PREFIX="[suricata-rules-refresh]"

# Rule actions Suricata accepts at the start of a signature line. The SAME
# regex is in hook 0530 and orionx-freshen-suricata (a unit test asserts it),
# so the three tools count alike.
RULE_ACTION_RE='^[[:space:]]*(alert|drop|pass|reject|rejectsrc|rejectdst|rejectboth)[[:space:]]'

die() { echo "$LOG_PREFIX ERROR: $*" >&2; exit 1; }

# --- Library ---------------------------------------------------------------------

# count_signatures <file>: live signature lines; commented-out rules do not count.
# `grep -c` prints the count AND exits 1 when it is zero, so the status is dropped.
count_signatures() {
    [[ -f "$1" ]] || { echo 0; return 0; }
    local n
    n="$(grep -cE "$RULE_ACTION_RE" "$1" 2>/dev/null || true)"
    echo "${n:-0}"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# curate_rules <extracted_rules_dir> <stock_rules_dir> <out_file> <categories...>
# Writes the merged file: Debian's stock *-events.rules first (sorted, minus
# STOCK_EXCLUDED_FILES), then emerging-<category>.rules in the order given.
# Prints "<signatures> <stock_file_count>". A category whose file is absent is a
# hard failure (return 1) and out_file is not produced: a feed that changed
# shape must be noticed, not absorbed.
curate_rules() {
    local src="$1" stock="$2" out="$3"; shift 3
    local tmp cat f n_stock=0
    for cat in "$@"; do
        if [[ ! -f "$src/emerging-$cat.rules" ]]; then
            echo "$LOG_PREFIX FATAL: category '$cat' not in the tarball (no $src/emerging-$cat.rules)" >&2
            echo "$LOG_PREFIX        ET-Open changed shape; fix ET_OPEN_CATEGORIES, do not vendor a thinner set quietly." >&2
            return 1
        fi
    done
    tmp="$(mktemp "$(dirname "$out")/.orionx-curate.XXXXXX")"
    {
        # shellcheck disable=SC2016  # the backticks are literal Markdown-style quoting
        printf '# Orion-X curated Suricata ruleset (DEC-PHASE13-043, #125). VENDORED: refreshed by\n'
        # shellcheck disable=SC2016
        printf '# `make suricata-rules-refresh` (scripts/suricata-rules-refresh.sh) and committed.\n'
        printf '# ET-Open subset for Suricata 7 + Debian stock protocol-event rules. Provenance, upstream\n'
        printf '# SHA-256 and license: %s beside this file. Do not hand-edit;\n' "$PROVENANCE_FILE"
        # shellcheck disable=SC2016
        printf '# on a deck, `sudo orionx-freshen-suricata` replaces this file with the FULL ET-Open feed.\n'
    } > "$tmp"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        case " $STOCK_EXCLUDED_FILES " in
            *" $(basename "$f") "*) continue ;;
        esac
        printf '\n# --- stock %s ---\n' "$(basename "$f")" >> "$tmp"
        cat "$f" >> "$tmp"
        n_stock=$((n_stock + 1))
    done < <(find "$stock" -maxdepth 1 -type f -name '*-events.rules' 2>/dev/null | sort)
    for cat in "$@"; do
        printf '\n# --- ET-Open emerging-%s.rules ---\n' "$cat" >> "$tmp"
        cat "$src/emerging-$cat.rules" >> "$tmp"
    done
    chmod 0644 "$tmp"
    mv "$tmp" "$out"
    printf '%s %s\n' "$(count_signatures "$out")" "$n_stock"
}

# write_provenance <out_file> <sha> <url> <last_modified> <tarball_bytes> <categories> <signatures> <bytes> <stock_count>
write_provenance() {
    local out="$1" sha="$2" url="$3" lastmod="$4" tbytes="$5" cats="$6" sigs="$7" bytes="$8" n_stock="$9"
    cat > "$out" <<EOF
# Orion-X Suricata ruleset provenance — DEC-PHASE13-043 (W11-6b, issue #125)
# VENDORED into iso/config/includes.chroot/var/lib/suricata/rules/ by scripts/suricata-rules-refresh.sh
# (make suricata-rules-refresh). Hook 0530 verifies this file against suricata.rules at build time
# and appends the build date and the count the engine loaded. Refresh = a reviewed commit.
target: /var/lib/suricata/rules/$TARGET_RULES
source-feed: Emerging Threats Open (ET-Open) for Suricata 7.0
source-url: $url
source-note: the URL is a ROLLING daily object (no dated archives); the hash below identifies the version vendored here
source-sha256: $sha
source-tarball-bytes: $tbytes
source-last-modified: $lastmod
refreshed-on: $(date -u +%Y-%m-%dT%H:%M:%SZ)
categories-included: $cats
categories-excluded: $ET_OPEN_EXCLUDED_NOTE
stock-files-included: $n_stock ($STOCK_RULES_DIR/*-events.rules, Debian suricata package)
stock-files-excluded: $STOCK_EXCLUDED_FILES (app-layer detection for dnp3/modbus is disabled in Debian's suricata.yaml; the engine rejects their signatures)
signatures: $sigs
bytes: $bytes
license: ET-Open rules (sids 2000000-2799999) are BSD-licensed, Copyright (c) 2003-2026 Emerging Threats; sids 1-3464 and 100000000-100000908 are GPLv2. Full text: /var/lib/suricata/rules/$LICENSE_COPY
refresh: make suricata-rules-refresh  (maintainer, network); on a deck, sudo orionx-freshen-suricata REPLACES this subset with the full feed (~52,000 signatures — measured to exhaust a 2 GB deck)
EOF
    chmod 0644 "$out"
}

# vendor_from_tarball <tarball> <stock_dir> <out_dir> <url> <last_modified> <categories...>
# Extract to scratch, curate, copy LICENSE, write provenance into <out_dir>.
# Prints "<signatures> <bytes> <stock_count> <sha256>". Returns 1 (and leaves
# <out_dir> untouched) when curation fails.
vendor_from_tarball() {
    local tarball="$1" stock="$2" out_dir="$3" url="$4" lastmod="$5"; shift 5
    local scratch result sigs n_stock bytes tbytes sha
    sha="$(sha256_of "$tarball")"
    tbytes="$(wc -c < "$tarball" | tr -d ' ')"
    scratch="$(mktemp -d "${TMPDIR:-$REPO_ROOT/tmp}/suricata-refresh.XXXXXX")"
    # shellcheck disable=SC2064  # expand now: scratch is fixed for this call
    trap "rm -rf '$scratch'" RETURN
    tar -xzf "$tarball" -C "$scratch" --strip-components=1 || { echo "$LOG_PREFIX FATAL: could not extract $tarball" >&2; return 1; }
    [[ -f "$scratch/LICENSE" ]] || { echo "$LOG_PREFIX FATAL: tarball carries no LICENSE file; the BSD notice must ship with the rules" >&2; return 1; }
    mkdir -p "$scratch/out"
    result="$(curate_rules "$scratch" "$stock" "$scratch/out/$TARGET_RULES" "$@")" || return 1
    sigs="${result% *}"; n_stock="${result#* }"
    [[ "$sigs" -gt 0 ]] || { echo "$LOG_PREFIX FATAL: curated file has 0 signatures" >&2; return 1; }
    bytes="$(wc -c < "$scratch/out/$TARGET_RULES" | tr -d ' ')"
    mkdir -p "$out_dir"
    cp "$scratch/out/$TARGET_RULES" "$out_dir/$TARGET_RULES"
    cp "$scratch/LICENSE" "$out_dir/$LICENSE_COPY"
    chmod 0644 "$out_dir/$TARGET_RULES" "$out_dir/$LICENSE_COPY"
    write_provenance "$out_dir/$PROVENANCE_FILE" "$sha" "$url" "$lastmod" "$tbytes" "$*" "$sigs" "$bytes" "$n_stock"
    printf '%s %s %s %s\n' "$sigs" "$bytes" "$n_stock" "$sha"
}

# engine_check <rules_dir>: run `suricata -T -v` against <rules_dir>/suricata.rules
# through a scratch config that includes the image's orionx.yaml when this host
# has it (a deck, or the container after install_image_config) and Debian's
# suricata.yaml otherwise. Sets ENGINE_RC, ENGINE_LOADED, ENGINE_FAILED, ENGINE_OUT.
engine_check() {
    local dir="$1" scratch base cfg
    scratch="$(mktemp -d "${TMPDIR:-$REPO_ROOT/tmp}/suricata-check.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$scratch'" RETURN
    base=/etc/suricata/orionx.yaml; [[ -r "$base" ]] || base=/etc/suricata/suricata.yaml
    cfg="$scratch/check.yaml"
    printf '%%YAML 1.1\n---\ninclude:\n  - %s\ndefault-rule-path: %s\nrule-files:\n  - %s\n' "$base" "$dir" "$TARGET_RULES" > "$cfg"
    mkdir -p "$scratch/log"
    ENGINE_RC=0
    ENGINE_OUT="$(suricata -T -v -c "$cfg" -l "$scratch/log" 2>&1)" || ENGINE_RC=$?
    ENGINE_LOADED="$(printf '%s\n' "$ENGINE_OUT" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) rules successfully loaded.*/\1/p' | tail -n1)"
    ENGINE_FAILED="$(printf '%s\n' "$ENGINE_OUT" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) rules failed.*/\1/p' | tail -n1)"
    ENGINE_BASE="$base"
    return 0
}

if [[ "${ORIONX_RULES_REFRESH_LIB_ONLY:-}" == "1" ]]; then
    # shellcheck disable=SC2317  # reachable when sourced
    return 0 2>/dev/null || exit 0
fi

# --- Container re-exec ------------------------------------------------------------
# The image's own config is installed at its absolute paths inside the
# container so the engine check runs the way the build hook and the deck do.
install_image_config() {
    local inc="$REPO_ROOT/iso/config/includes.chroot"
    mkdir -p /etc/suricata /var/lib/suricata
    cp "$inc/etc/suricata/orionx.yaml" /etc/suricata/orionx.yaml
    cp "$inc/var/lib/suricata/orionx-interfaces.yaml" "$inc/var/lib/suricata/orionx-threshold.config" /var/lib/suricata/
}

run_in_container() {
    local build
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        die "this host has no suricata (+ /etc/suricata/rules) and no docker. Install suricata, or docker, or pass --stock-dir DIR --no-check."
    fi
    build="$(mktemp -d "$REPO_ROOT/tmp/suricata-refresh-img.XXXXXX")"
    printf 'FROM debian:trixie-slim\nENV DEBIAN_FRONTEND=noninteractive\nRUN apt-get update -qq && apt-get install -y -qq --no-install-recommends suricata iproute2 ca-certificates curl && rm -rf /var/lib/apt/lists/*\n' > "$build/Dockerfile"
    echo "$LOG_PREFIX no local suricata; running inside $PROBE_IMAGE (debian:trixie-slim + suricata) ..."
    docker build -q -t "$PROBE_IMAGE" "$build" >/dev/null || { rm -rf "$build"; die "docker build of $PROBE_IMAGE failed (offline?)"; }
    rm -rf "$build"
    docker run --rm -v "$REPO_ROOT:/repo" -w /repo -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
        "$PROBE_IMAGE" bash scripts/suricata-rules-refresh.sh --in-container "$@"
}

# --- Main ---------------------------------------------------------------------------
TARBALL=""; LASTMOD=""; NO_CHECK=0; IN_CONTAINER=0
ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tarball)       TARBALL="$2"; shift 2 ;;
        --url)           ET_OPEN_URL="$2"; shift 2 ;;
        --last-modified) LASTMOD="$2"; shift 2 ;;
        --stock-dir)     STOCK_RULES_DIR="$2"; shift 2 ;;
        --out-dir)       OUT_DIR="$2"; shift 2 ;;
        --no-check)      NO_CHECK=1; shift ;;
        --in-container)  IN_CONTAINER=1; shift ;;
        -h|--help)       sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
mkdir -p "$REPO_ROOT/tmp"

if [[ $IN_CONTAINER -eq 1 ]]; then
    install_image_config
    # Paths given on the host are re-rooted at /repo by the bind mount.
    [[ -n "$TARBALL" && "$TARBALL" != /repo/* ]] && TARBALL="/repo/${TARBALL#"$REPO_ROOT"/}"
    [[ "$OUT_DIR" != /repo/* ]] && OUT_DIR="/repo/${OUT_DIR#"$REPO_ROOT"/}"
fi

have_engine=0
command -v suricata >/dev/null 2>&1 && [[ -d "$STOCK_RULES_DIR" ]] && have_engine=1
if [[ $have_engine -eq 0 && $IN_CONTAINER -eq 0 ]]; then
    if [[ $NO_CHECK -eq 1 && -d "$STOCK_RULES_DIR" ]]; then
        echo "$LOG_PREFIX WARNING: --no-check: the result will NOT be proven to load; hook 0530 will refuse a bad file at build time." >&2
    else
        run_in_container "${ORIG_ARGS[@]}"
        exit $?
    fi
fi
[[ -d "$STOCK_RULES_DIR" ]] || die "stock rules dir $STOCK_RULES_DIR missing (Debian suricata package not installed?)"

# --- Fetch (or take the given tarball) ----------------------------------------------
if [[ -z "$TARBALL" ]]; then
    TARBALL="$(mktemp "$REPO_ROOT/tmp/emerging.rules.XXXXXX.tar.gz")"
    HDRS="$TARBALL.headers"
    echo "$LOG_PREFIX fetching $ET_OPEN_URL"
    curl -fsSL --retry 3 -D "$HDRS" -o "$TARBALL" "$ET_OPEN_URL" || die "fetch failed: $ET_OPEN_URL"
    LASTMOD="$(sed -n 's/^[Ll]ast-[Mm]odified: *//p' "$HDRS" | tr -d '\r' | tail -n1)"
    rm -f "$HDRS"
    CLEAN_TARBALL=1
else
    [[ -s "$TARBALL" ]] || die "tarball $TARBALL missing or empty"
    CLEAN_TARBALL=0
fi
[[ -n "$LASTMOD" ]] || LASTMOD="not recorded (local tarball; pass --last-modified)"

# --- Curate into a scratch dir first; the vendored files change only after the check ---
STAGE="$(mktemp -d "$REPO_ROOT/tmp/suricata-refresh-stage.XXXXXX")"
trap 'rm -rf "$STAGE"; [[ "${CLEAN_TARBALL:-0}" -eq 1 ]] && rm -f "$TARBALL"' EXIT
# shellcheck disable=SC2086  # the category list is a deliberate word list
RESULT="$(vendor_from_tarball "$TARBALL" "$STOCK_RULES_DIR" "$STAGE" "$ET_OPEN_URL" "$LASTMOD" $ET_OPEN_CATEGORIES)" \
    || die "curation failed; vendored files left unchanged"
read -r SIGS BYTES N_STOCK SHA <<< "$RESULT"
echo "$LOG_PREFIX tarball sha256 $SHA ($(wc -c < "$TARBALL" | tr -d ' ') bytes, Last-Modified: $LASTMOD)"
echo "$LOG_PREFIX curated: $SIGS signatures, $BYTES bytes, $N_STOCK stock -events files, categories: $ET_OPEN_CATEGORIES"

if [[ $NO_CHECK -eq 0 ]]; then
    echo "$LOG_PREFIX suricata -T against the curated file ..."
    engine_check "$STAGE"
    if [[ "$ENGINE_RC" -ne 0 || -z "$ENGINE_LOADED" || "$ENGINE_LOADED" -eq 0 ]]; then
        printf '%s\n' "$ENGINE_OUT" | tail -40 | sed 's/^/    /' >&2
        die "engine rejected the curated file (rc=$ENGINE_RC loaded='${ENGINE_LOADED:-none}'); vendored files left unchanged"
    fi
    if [[ -n "$ENGINE_FAILED" && "$ENGINE_FAILED" -gt 0 ]]; then
        printf '%s\n' "$ENGINE_OUT" | grep -iE 'error|rejected|failed' | head -20 | sed 's/^/    /' >&2
        die "engine rejected $ENGINE_FAILED rule(s); fix STOCK_EXCLUDED_FILES / categories; vendored files left unchanged"
    fi
    echo "$LOG_PREFIX engine ($(suricata -V 2>/dev/null | head -1 | sed 's/This is //')) loaded $ENGINE_LOADED rules, 0 failed, via $ENGINE_BASE"
    printf 'refresh-check: %s rules loaded, 0 failed (%s, config %s)\n' "$ENGINE_LOADED" "$(suricata -V 2>/dev/null | head -1 | sed 's/This is //')" "$ENGINE_BASE" >> "$STAGE/$PROVENANCE_FILE"
else
    printf 'refresh-check: SKIPPED (--no-check)\n' >> "$STAGE/$PROVENANCE_FILE"
fi

mkdir -p "$OUT_DIR"
cp "$STAGE/$TARGET_RULES" "$STAGE/$PROVENANCE_FILE" "$STAGE/$LICENSE_COPY" "$OUT_DIR/"
if [[ $IN_CONTAINER -eq 1 && -n "${HOST_UID:-}" ]]; then
    chown -R "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUT_DIR" "$REPO_ROOT/tmp" 2>/dev/null || true
fi
echo "$LOG_PREFIX vendored into $OUT_DIR:"
for f in "$OUT_DIR/$TARGET_RULES" "$OUT_DIR/$PROVENANCE_FILE" "$OUT_DIR/$LICENSE_COPY"; do
    printf '    %10s bytes  %s\n' "$(wc -c < "$f" | tr -d ' ')" "$f"
done
echo "$LOG_PREFIX provenance:"
sed 's/^/    /' "$OUT_DIR/$PROVENANCE_FILE"
echo "$LOG_PREFIX next: review 'git diff --stat iso/config/includes.chroot/var/lib/suricata/rules' and commit."
