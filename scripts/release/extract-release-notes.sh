#!/usr/bin/env bash
# extract-release-notes.sh — parse CHANGELOG.md and emit the section for a given version.
#
# @decision DEC-PHASE8-002
# @title Release notes extraction from CHANGELOG.md for targeted GitHub Release body
# @status accepted
# @rationale Sending the full CHANGELOG.md as the GitHub Release body is noisy for users
#   browsing releases. This helper extracts only the current version's section so the
#   release body is focused. It is called by release.yml (Step 6) with the git tag name.
#   Falls back to an empty string — caller handles the empty-notes case.
#
# Usage:
#   extract-release-notes.sh <version>
#   extract-release-notes.sh v2.0.0-rc1
#
# Output:
#   The Markdown lines belonging to the version section, written to stdout.
#   If the version is not found, outputs nothing (exit 0).
#
# The script matches both ## [2.0.0-rc1] and ## [v2.0.0-rc1] headings so it
# works regardless of whether CHANGELOG.md uses a bare or v-prefixed version tag.

set -euo pipefail

VERSION="${1:?Usage: $0 <version>  (e.g. v2.0.0-rc1)}"

# Strip leading 'v' for CHANGELOG heading match.
# CHANGELOG.md headings may use either ## [2.0.0-rc1] or ## [v2.0.0-rc1].
# We pass both forms to awk and match whichever is present.
VERSION_BARE="${VERSION#v}"    # "2.0.0-rc1"
VERSION_WITH_V="v${VERSION_BARE}"  # "v2.0.0-rc1" (idempotent if VERSION already has v)

# Resolve CHANGELOG.md relative to the repository root.
# When called from release.yml the CWD is the workspace root (checkout).
CHANGELOG="${CHANGELOG_PATH:-CHANGELOG.md}"

if [[ ! -f "${CHANGELOG}" ]]; then
  echo "WARNING: ${CHANGELOG} not found — no release notes extracted." >&2
  exit 0
fi

# awk logic:
#   - When we encounter a ## [...] heading that matches our version (bare or v-prefixed),
#     set in_section=1.
#   - When we encounter any OTHER ## [...] heading while in_section=1, stop (set in_section=0).
#   - Print lines while in_section=1 (skip the section heading line itself via 'next').
#   - Trim trailing blank lines by buffering: flush the buffer on non-blank lines,
#     discard trailing blanks at end of section.
awk -v bare="${VERSION_BARE}" -v withv="${VERSION_WITH_V}" '
  /^## \[/ {
    if (in_section) {
      # Hit the next version heading; we are done
      in_section = 0
      exit
    }
    # Match either ## [2.0.0-rc1] or ## [v2.0.0-rc1]
    if (index($0, "[" bare "]") > 0 || index($0, "[" withv "]") > 0) {
      in_section = 1
    }
    next
  }
  in_section {
    # Buffer lines to suppress trailing blank lines at section end
    if (/^[[:space:]]*$/) {
      pending_blanks++
    } else {
      # Flush buffered blanks before this non-blank line
      for (i = 0; i < pending_blanks; i++) {
        print ""
      }
      pending_blanks = 0
      print
    }
  }
' "${CHANGELOG}"
