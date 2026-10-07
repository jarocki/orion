#!/usr/bin/env bash
# shellcheck shell=bash
#
# Firefox enterprise policy (security F16)
#
# @decision DEC-PHASE12-104
# @title Firefox ships an enterprise policy that keeps the browser quiet on a
#   hostile network
# @status accepted
# @rationale No policies.json shipped, so Firefox phoned Mozilla (telemetry,
#   studies/Normandy, captive-portal probe), its DoH behaviour followed the
#   rollout, and WebRTC could reveal LAN addresses to visited sites.
#   /usr/lib/firefox-esr/distribution/policies.json (JSON has no comments,
#   so the decision lives here) locks: telemetry and studies off, no
#   default-browser check, Pocket off, captive-portal probe off, network
#   prediction and link prefetch off, DoH OFF and locked (DNS follows the
#   system resolver; the trade-off — a hostile DHCP resolver sees lookups —
#   is explicit rather than left to a rollout), and WebRTC limited to the
#   default address with no host candidates and no non-proxied UDP when a
#   proxy is set. Verified only as policy content; Firefox's own
#   about:policies on a deck is the runtime check.
#
# Usage: bash tests/unit/test_firefox_policies.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P="$ROOT/iso/config/includes.chroot/usr/lib/firefox-esr/distribution/policies.json"
PYTHONDONTWRITEBYTECODE=1 python3 - "$P" <<'PY'
import json, sys
fails = 0
def check(desc, ok):
    global fails
    print(("  PASS: " if ok else "  FAIL: ") + desc)
    fails += 0 if ok else 1
try:
    pol = json.load(open(sys.argv[1]))["policies"]
except Exception as e:  # noqa: BLE001 - report the real error
    print(f"  FAIL: policies.json parses ({e})"); sys.exit(1)
check("policies.json parses", True)
check("telemetry disabled", pol.get("DisableTelemetry") is True)
check("studies (Normandy) disabled", pol.get("DisableFirefoxStudies") is True)
check("no default-browser check", pol.get("DontCheckDefaultBrowser") is True)
check("captive-portal probe off", pol.get("CaptivePortal") is False)
check("network prediction off", pol.get("NetworkPrediction") is False)
doh = pol.get("DNSOverHTTPS", {})
check("DoH explicitly off and locked", doh.get("Enabled") is False and doh.get("Locked") is True)
prefs = pol.get("Preferences", {})
for k in ("media.peerconnection.ice.default_address_only",
          "media.peerconnection.ice.no_host",
          "media.peerconnection.ice.proxy_only_if_behind_proxy"):
    v = prefs.get(k, {})
    check(f"WebRTC: {k} locked true", v.get("Value") is True and v.get("Status") == "locked")
print(f"\nResults: {fails} failed")
sys.exit(1 if fails else 0)
PY
