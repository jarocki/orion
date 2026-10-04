#!/usr/bin/env bash
# shellcheck shell=bash
#
# @decision DEC-PHASE12-043
# @title Orion-X optional installer: DB-IP Lite country + ASN labels
# @status accepted
# @rationale The attack map (/opt/orionx/osint/pewpew) shows every source it
#   has, and labels the ones it cannot locate UNLOCATED. This installer is the
#   only way it ever gains a country or ASN label, and it is optional on
#   purpose:
#
#     - MaxMind GeoLite2 cannot be redistributed inside an image, so it was
#       never a candidate for the ISO.
#     - DB-IP Lite CAN be redistributed (CC BY 4.0), but it is republished
#       monthly. Baking a snapshot into an ISO that is built once and run for
#       months means shipping data that silently rots. An operator-fetched
#       database has a date they can see.
#
#   Nothing degrades if this is never run. The map works, shows every source,
#   and says plainly that it has no geolocation (docs/RESILIENCE.md rule 8).
#   What it will NOT do, with or without this database, is invent a position:
#   this installer adds LABELS, not coordinates. See /opt/orionx/osint/GEOIP.txt.
#
# @decision DEC-PHASE11-011
# @title Orion-X optional-installer framework
# @status accepted
# @rationale Sources the shared installer library for DRY preflight checks,
#   log helpers, and install helpers.
#
# Usage (as root on a network-connected node):
#   sudo /opt/orionx/optional/install-geoip.sh
#
# What this installs:
#   /var/lib/orionx/geoip/dbip-country-lite.mmdb   (~10 MB on disk)
#   /var/lib/orionx/geoip/dbip-asn-lite.mmdb       (~12 MB on disk)
#   python3-maxminddb (Debian main) if it is not already present
#   Licence:      CC BY 4.0 — "IP Geolocation by DB-IP" (https://db-ip.com)
#   Requires:     network access to download.db-ip.com
#   Refresh:      monthly; re-run this script
#   Mission verb: analyze (attribution context for observed sources)
#
# Verify afterwards with:
#   orionx-osint --check        # the "GeoIP (optional)" row flips to ok

set -euo pipefail

# SC1091: library lives at runtime path /opt/orionx/optional/lib/ on the
# target system; shellcheck cannot follow the absolute path on the build host.
# shellcheck disable=SC1091
source /opt/orionx/optional/lib/orionx-installer-common.sh

GEOIP_DIR="/var/lib/orionx/geoip"
BASE_URL="https://download.db-ip.com/free"

orionx_require_root
orionx_require_network download.db-ip.com

orionx_log_info "=== Orion-X optional installer: DB-IP Lite geolocation ==="
orionx_log_info "  Size:    ~9 MB download, ~22 MB on disk"
orionx_log_info "  License: CC BY 4.0 — IP Geolocation by DB-IP (https://db-ip.com)"
orionx_log_info "  Network: download.db-ip.com"
orionx_log_info "  Mission: analyze — country and ASN LABELS on map sources"
orionx_log_info ""
orionx_log_info "  This adds labels, NOT coordinates. The attack map still"
orionx_log_info "  places nothing on a world outline, because country-level"
orionx_log_info "  IP data is routing metadata, not an attacker's location."
orionx_log_info "  See /opt/orionx/osint/GEOIP.txt."

orionx_log_info "Ensuring python3-maxminddb is installed..."
orionx_apt_install python3-maxminddb

mkdir -p "$GEOIP_DIR"

# DB-IP publishes one file per month at a predictable path. The current month
# can be a day or two late, so the previous month is tried as a fallback — and
# whichever month actually lands is recorded, because a database with no
# visible date is a database nobody can judge.
fetch_db() {
    local kind="$1" dest="$2" month url tmp got=""
    for offset in 0 1; do
        month="$(date -u -d "-${offset} month" +%Y-%m 2>/dev/null || true)"
        [[ -n "$month" ]] || continue
        url="${BASE_URL}/dbip-${kind}-lite-${month}.mmdb.gz"
        tmp="$(mktemp)"
        orionx_log_info "Trying ${url}"
        if wget -q -O "$tmp" "$url" && [[ -s "$tmp" ]]; then
            if gunzip -c "$tmp" > "${dest}.new" 2>/dev/null && [[ -s "${dest}.new" ]]; then
                mv "${dest}.new" "$dest"
                got="$month"
                rm -f "$tmp"
                break
            fi
            orionx_log_info "  downloaded but not a valid gzip; trying the previous month"
            rm -f "${dest}.new"
        fi
        rm -f "$tmp"
    done
    if [[ -z "$got" ]]; then
        orionx_log_error "Could not fetch the DB-IP ${kind} database." \
            "The map keeps working and keeps saying it has no geolocation." \
            "Check connectivity to download.db-ip.com and re-run this script."
        return 1
    fi
    printf '%s\n' "$got" > "${dest}.month"
    orionx_log_info "  ${dest} <- DB-IP ${kind} lite, ${got}"
    return 0
}

country_ok=0
asn_ok=0
fetch_db country "${GEOIP_DIR}/dbip-country-lite.mmdb" && country_ok=1
fetch_db asn "${GEOIP_DIR}/dbip-asn-lite.mmdb" && asn_ok=1

cat > "${GEOIP_DIR}/ATTRIBUTION.txt" <<'ATTR'
IP Geolocation by DB-IP — https://db-ip.com
Licensed under the Creative Commons Attribution 4.0 International License
(CC BY 4.0): https://creativecommons.org/licenses/by/4.0/

This attribution is required wherever the data is displayed. The Orion-X
attack map renders it in its footer whenever a database is loaded.
ATTR

if [[ "$country_ok" -eq 0 ]]; then
    orionx_log_error "No country database installed." \
        "orionx-osint --check will keep reporting GeoIP as absent." \
        "Nothing else is broken; the map labels sources UNLOCATED as before."
    exit 1
fi

if ! python3 -c "
import maxminddb, sys
with maxminddb.open_database('${GEOIP_DIR}/dbip-country-lite.mmdb') as r:
    rec = r.get('8.8.8.8')
sys.exit(0 if rec else 1)
" >/dev/null 2>&1; then
    orionx_log_error "The database installed but python3-maxminddb cannot read it." \
        "The map will keep reporting 'geoip-lookup-failed' rather than guessing." \
        "Re-run this installer; if it persists, delete ${GEOIP_DIR} and try again."
    exit 1
fi

orionx_log_info "Country database installed and readable."
if [[ "$asn_ok" -eq 0 ]]; then
    orionx_log_info "ASN database NOT installed — sources get a country label but no AS number."
fi
orionx_log_info "Verify with: orionx-osint --check"
