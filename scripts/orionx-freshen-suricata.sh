#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE11-008
# @title Orion-X Suricata ET-Open freshen (W11-6 Layer A)
# @status accepted
# @rationale Suricata IDS Layer A ships no bundled ruleset (Layer B deferred to
#   W11-6b). This script is the operator-facing tool to fetch ET-Open rules
#   (BSD-2-Clause) from emergingthreats.net post-boot. Requires network access;
#   fails loudly on air-gap or DNS failure so the operator knows immediately.
#   Root required: writes to /var/lib/suricata/rules (owned by root in Debian
#   packaging). Layer B will automate this at build time and wire the tier
#   selector; until then, this script is the only freshen mechanism.
#
# @decision DEC-PHASE12-039
# @title The freshen reports what Suricata loaded, not what it downloaded
# @status accepted
# @rationale Rev 1 extracted the ET-Open tarball into /var/lib/suricata/rules and
#   printed "Complete. N rule files installed." Suricata loaded none of them.
#
#   Verified on debian:trixie-slim with suricata 7.0.10 (the ISO's version):
#   `default-rule-path: /var/lib/suricata/rules` is correct, but `rule-files:`
#   lists exactly one entry, `suricata.rules`. The ET-Open tarball
#   (emerging.rules.tar.gz, 60 entries) contains no file of that name — it ships
#   botcc.rules, emerging-*.rules and friends. suricata-update normally merges
#   them into suricata.rules; nothing here did. So the operator ran the one
#   documented remedy for "my IDS has no signatures", saw a success line naming
#   55 files, and still had an IDS matching zero threat signatures.
#
#   Worse than useless: orionx-postured's assess_rules() counts non-empty
#   non-anomaly .rules files in this directory to decide whether Tier 1/2 can
#   honestly claim IDS coverage. After rev 1 ran, that check passed, so the
#   daemon STOPPED announcing the coverage gap. The deck went from loudly blind
#   to quietly blind — the exact inversion RESILIENCE.md rule 8 exists to stop.
#
#   This revision owes all five stages of the loop:
#     Plan   — rule_files_from_config() reads what suricata.yaml actually names.
#              Pure, stdin to stdout, no filesystem. We no longer assume.
#     Do     — extract, then merge every ruleset into the file the config names.
#     Check  — re-read reality through Suricata itself: `suricata -T -v` and
#              parse "M rules successfully loaded". Note that `suricata -T`
#              EXITS 0 when it matched no rule files at all (measured), so the
#              exit code cannot be the gate; the count is.
#     Repair — a zero count is a hard failure with the diagnosis named, not a
#              warning buried in a success line.
#     Loop   — a live reload if the service is up, and the exact command if not.
#
#   Sourcing this file defines the functions without running anything, so the
#   unit test exercises the real Plan and Do logic with no root and no network.

set -euo pipefail

# Overridable so the suite can drive the real code paths against a fixture tree.
RULES_DIR="${ORIONX_SURICATA_RULES_DIR:-/var/lib/suricata/rules}"
SURICATA_YAML="${ORIONX_SURICATA_YAML:-/etc/suricata/suricata.yaml}"
ET_URL="${ORIONX_SURICATA_ET_URL:-https://rules.emergingthreats.net/open/suricata-6.0/emerging.rules.tar.gz}"

# Rule actions Suricata accepts at the start of a signature line. Used to count
# signatures in a file without asking Suricata, for the pre-flight check.
RULE_ACTION_RE='^[[:space:]]*(alert|drop|pass|reject|rejectsrc|rejectdst|rejectboth)[[:space:]]'

# ---------------------------------------------------------------------------
# PLAN (pure): what will Suricata actually load?
# ---------------------------------------------------------------------------

# Read a suricata.yaml on stdin, print one rule-file entry per line.
# The block is a flat YAML list; blank lines and comments inside it are skipped,
# and the first other unindented key ends it.
rule_files_from_config() {
    awk '
        /^rule-files:/ { inlist = 1; next }
        inlist {
            if ($0 ~ /^[[:space:]]*(#|$)/) next
            if ($0 ~ /^[[:space:]]*-[[:space:]]*/) {
                sub(/^[[:space:]]*-[[:space:]]*/, "")
                sub(/[[:space:]]+#.*$/, "")
                gsub(/^"|"$/, ""); gsub(/^'\''|'\''$/, "")
                if (length($0)) print
                next
            }
            inlist = 0
        }
    '
}

# Read a suricata.yaml on stdin, print the basename the merge must produce:
# the first rule-files entry. Empty output means the config loads nothing, which
# the caller must treat as fatal rather than merging into a guessed name.
#
# This exists as its own function so the suite can prove the target is DERIVED.
# When it was inlined in main() as `target="${want[0]}"`, a mutation that
# hardcoded "suricata.rules" was invisible to the suite — the test could only
# reach merge_rules, which honours whatever argument it is handed. Pulling the
# decision out is what makes it checkable.
merge_target_for_config() {
    rule_files_from_config | head -n1
}

# Read a suricata.yaml on stdin, print default-rule-path (empty if unset).
default_rule_path_from_config() {
    awk '/^default-rule-path:/ { sub(/^default-rule-path:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit }'
}

# Count signature lines in a rules file. Commented-out rules do not count.
# Note `grep -c` prints the count AND exits 1 when that count is zero, so the
# exit status must be discarded rather than branched on — branching on it would
# emit a second "0" and turn the caller's numeric test into a syntax error.
count_signatures() {
    [[ -f "$1" ]] || { echo 0; return 0; }
    local n
    n="$(grep -cE "$RULE_ACTION_RE" "$1" 2>/dev/null || true)"
    echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# DO: merge every downloaded ruleset into the file the config names
# ---------------------------------------------------------------------------

# merge_rules <rules_dir> <target_basename>
# Concatenates every *.rules in the directory except the target into the target,
# the way suricata-update would. Prints the resulting signature count.
merge_rules() {
    local dir="$1" target="$2" out="$1/$2" tmp
    tmp="$(mktemp "${dir}/.orionx-merge.XXXXXX")"
    {
        printf '# Generated by orionx-freshen-suricata (DEC-PHASE12-039).\n'
        printf '# Merged from the ET-Open tarball because suricata.yaml rule-files\n'
        printf '# names this file and nothing else. Do not hand-edit.\n'
    } > "$tmp"
    local f
    # Sorted for a reproducible result; the target itself is never an input.
    while IFS= read -r f; do
        [[ "$(basename "$f")" == "$target" ]] && continue
        printf '\n# --- %s ---\n' "$(basename "$f")" >> "$tmp"
        cat "$f" >> "$tmp"
    done < <(find "$dir" -maxdepth 1 -type f -name '*.rules' | sort)
    mv "$tmp" "$out"
    chmod 0644 "$out"
    count_signatures "$out"
}

# ---------------------------------------------------------------------------
# CHECK: ask Suricata what it loaded. Its exit code is not the answer.
# ---------------------------------------------------------------------------

# Prints the number of rules Suricata reports loading, or empty if it could
# not be determined. Never fails the script — the caller decides.
suricata_loaded_count() {
    local yaml="$1" logdir out
    command -v suricata >/dev/null 2>&1 || return 0
    logdir="$(mktemp -d)"
    out="$(suricata -T -v -c "$yaml" -l "$logdir" 2>&1 || true)"
    rm -rf "$logdir"
    printf '%s\n' "$out" \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\) rules successfully loaded.*/\1/p' \
        | tail -n1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: orionx-freshen-suricata requires root" >&2
        exit 1
    fi

    if [[ ! -r "$SURICATA_YAML" ]]; then
        echo "ERROR: cannot read $SURICATA_YAML — is suricata installed?" >&2
        echo "       Remedy: sudo apt-get install suricata" >&2
        exit 1
    fi

    if ! getent hosts rules.emergingthreats.net >/dev/null 2>&1; then
        echo "ERROR: rules.emergingthreats.net unreachable (air-gap or DNS)" >&2
        echo "       Orion-X runs offline by design; this is the one command that" >&2
        echo "       needs the network. Run it on a connected node, or copy" >&2
        echo "       $RULES_DIR from one." >&2
        exit 1
    fi

    # --- Plan ---------------------------------------------------------------
    # A read loop, not mapfile: the suite that drives these functions runs on
    # the maintainer's macOS bash 3.2 as well as on the deck's bash 5.
    local -a want=()
    local _line
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && want+=("$_line")
    done < <(rule_files_from_config < "$SURICATA_YAML")
    if [[ ${#want[@]} -eq 0 ]]; then
        echo "ERROR: $SURICATA_YAML has no rule-files: entries." >&2
        echo "       Suricata would load nothing no matter what this script" >&2
        echo "       downloads. Add 'rule-files:' with '- suricata.rules' and" >&2
        echo "       re-run. Inspect: grep -A4 '^rule-files:' $SURICATA_YAML" >&2
        exit 1
    fi
    local target
    target="$(merge_target_for_config < "$SURICATA_YAML")"

    local cfg_path
    cfg_path="$(default_rule_path_from_config < "$SURICATA_YAML")"
    if [[ -n "$cfg_path" && "$cfg_path" != "$RULES_DIR" ]]; then
        echo "ERROR: suricata.yaml default-rule-path is '$cfg_path' but this" >&2
        echo "       script installs into '$RULES_DIR'. Suricata would not read" >&2
        echo "       what we wrote. Re-run with:" >&2
        echo "         sudo ORIONX_SURICATA_RULES_DIR=$cfg_path orionx-freshen-suricata" >&2
        exit 1
    fi

    echo "[orionx-freshen-suricata] suricata.yaml loads: ${want[*]}"
    echo "[orionx-freshen-suricata] merging into: $RULES_DIR/$target"

    # --- Do -----------------------------------------------------------------
    mkdir -p "$RULES_DIR"
    local tmp
    tmp="$(mktemp)"
    echo "[orionx-freshen-suricata] Downloading ET-Open rules..."
    wget -q -O "$tmp" "$ET_URL"
    tar -xzf "$tmp" -C "$RULES_DIR" --strip-components=1
    rm -f "$tmp"

    local merged
    merged="$(merge_rules "$RULES_DIR" "$target")"

    # --- Check --------------------------------------------------------------
    if [[ "$merged" -eq 0 ]]; then
        echo "ERROR: merged 0 signatures into $RULES_DIR/$target." >&2
        echo "       The deck has NO IDS signatures and will report nothing." >&2
        echo "       Diagnose: ls -la $RULES_DIR ; head $RULES_DIR/$target" >&2
        exit 1
    fi

    local loaded
    loaded="$(suricata_loaded_count "$SURICATA_YAML")"
    if [[ -z "$loaded" ]]; then
        echo "WARNING: could not confirm the load with 'suricata -T -v'." >&2
        echo "         $merged signatures were written to $RULES_DIR/$target," >&2
        echo "         but Suricata has not confirmed it reads them." >&2
        echo "         Verify by hand: sudo suricata -T -v -c $SURICATA_YAML" >&2
    elif [[ "$loaded" -eq 0 ]]; then
        echo "ERROR: Suricata loaded 0 rules despite $merged signatures in" >&2
        echo "       $RULES_DIR/$target. The deck is BLIND: it will see no" >&2
        echo "       exploit, no malware, no C2 and no scan." >&2
        echo "       Diagnose: sudo suricata -T -v -c $SURICATA_YAML" >&2
        echo "                 grep -A4 '^rule-files:' $SURICATA_YAML" >&2
        exit 1
    else
        echo "[orionx-freshen-suricata] Suricata confirms $loaded rules loaded."
    fi

    # --- Loop ---------------------------------------------------------------
    # Rules on disk are not rules in memory. Say which one the operator has.
    if systemctl is-active --quiet suricata.service 2>/dev/null; then
        if systemctl reload suricata.service 2>/dev/null \
           && systemctl is-active --quiet suricata.service 2>/dev/null; then
            echo "[orionx-freshen-suricata] suricata.service reloaded; rules are live."
        else
            echo "WARNING: reload failed — the NEW rules are on disk but the" >&2
            echo "         running engine still has the OLD set." >&2
            echo "         Remedy: sudo systemctl restart suricata" >&2
        fi
    else
        echo "[orionx-freshen-suricata] suricata.service is not running — rules are"
        echo "  staged, not active. Raise the posture tier (orionx-postured starts"
        echo "  it) or: sudo systemctl start suricata"
    fi
}

# Sourced by the test suite to reach the pure functions; executed by operators.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
