#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_godseye.sh — the vendored GODSEYE globe (DEC-PHASE12-045)
#
# GODSEYE is the most dishonest-by-default thing on this image, and that is
# not a criticism of GODSEYE. It is a live-API application: it caches
# nothing, so with no network it draws a featureless dark sphere, and a dark
# sphere on an incident-response deck reads as "nothing is happening". That
# is a lie, and it is the exact failure docs/RESILIENCE.md rule 8 exists to
# forbid.
#
# So this file is mostly about four ways this slice could lie:
#
#   * the bundle in the image could be a different build from the one whose
#     provenance is recorded beside it;
#   * an API key could have been compiled into it — Vite bakes VITE_* values
#     into the output, so a key here is a key published inside the ISO;
#   * the disconnected and shields-up paths could render the globe anyway,
#     or refuse it with nothing useful said;
#   * the list of third parties it contacts could have drifted from the
#     bundle that actually ships, which is worse than no list because the
#     list is believed.
#
# The third one is the point of this file, and it is mutation-tested from
# both ends: the gate is broken open and the suite must go red, and the
# refusal is stripped of its remedy and the suite must go red.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }

CH="$REPO_ROOT/iso/config/includes.chroot"
GS="$CH/opt/orionx/osint/godseye"
APPS="$CH/usr/share/applications"
SRC="$REPO_ROOT/scripts/osint"
HOOK="$REPO_ROOT/iso/config/hooks/live/0715-godseye.hook.chroot"
TMP="$REPO_ROOT/tmp/test_godseye.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

if command -v sha256sum >/dev/null 2>&1; then
    SHACHECK="sha256sum -c --quiet"
else
    SHACHECK="shasum -a 256 -c --status"
fi

# The key-shaped-string pattern. The hook greps for the same thing at build
# time; the assertion below proves the two have not drifted, so this is one
# fact with one spelling rather than two that can disagree.
KEYPAT='AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9]{32,}|pk\.ey[A-Za-z0-9._-]{30,}'

section "Structure"
for f in "$GS/index.html" "$GS/gate.js" "$GS/overlay.js" "$GS/HOSTS.txt" \
         "$GS/PROVENANCE.txt" "$GS/MANIFEST.sha256" "$GS/LICENSE.godseye" \
         "$GS/app/index.html" "$GS/app/cesium/Cesium.js" \
         "$SRC/godseye_hosts.py" "$SRC/osint_server.py" \
         "$CH/usr/bin/orionx-osint" \
         "$APPS/orionx-godseye.desktop" "$HOOK"; do
    if [[ -f "$f" ]]; then pass "ships: ${f#"$REPO_ROOT"/}"
    else fail "ships: ${f#"$REPO_ROOT"/}" "missing"; fi
done
[[ -x "$HOOK" ]] && pass "0715 hook is executable" || fail "0715 hook executable"
for f in "$SRC/godseye_hosts.py" "$SRC/osint_server.py" "$HOOK" \
         "$GS/index.html" "$GS/gate.js" "$GS/overlay.js" \
         "$APPS/orionx-godseye.desktop"; do
    if grep -q 'DEC-PHASE12-045' "$f"; then pass "decision annotation: $(basename "$f")"
    else fail "decision annotation: $(basename "$f")" "missing DEC-PHASE12-045"; fi
done

# .gitignore excludes opt/orionx/* and re-admits named subdirectories. A new
# directory there that nobody negated is silently absent from the build.
if git -C "$REPO_ROOT" check-ignore -q "$GS/app/index.html"; then
    fail ".gitignore tracks the vendored bundle" \
         "$(git -C "$REPO_ROOT" check-ignore -v "$GS/app/index.html")"
else
    pass ".gitignore does not drop opt/orionx/osint/godseye/ from the build"
fi
# Tracked, not "has pending changes": the previous form used `git status`,
# which is non-empty only while the tree is uncommitted — it passed while the
# slice was staged and failed the moment it was committed (2026-10-05). The
# invariant is that git TRACKS the bundle, so a clean checkout builds it.
TRACKED="$(git -C "$REPO_ROOT" ls-files -- "$GS" 2>/dev/null | grep -c . || true)"
if [[ "$TRACKED" -ge 400 ]]; then pass "git tracks $TRACKED file(s) under godseye/ (402 in app/ + the preflight files)"
else fail "git tracks the godseye tree" "git ls-files reports $TRACKED file(s) — the bundle would be absent from a clean build"; fi

section "Provenance: the bundle is the build that was pinned"
if grep -q 'eb4b8db218cba9cc4aa1ac700676e8d5bff7b3ef' "$GS/PROVENANCE.txt"; then
    pass "PROVENANCE pins the upstream commit"
else fail "PROVENANCE pins the upstream commit" "no 40-char SHA recorded"; fi
if grep -q 'github.com/VrushankPatel/godseye' "$GS/PROVENANCE.txt"; then
    pass "PROVENANCE names the upstream repository"
else fail "PROVENANCE names the upstream repository"; fi
if grep -q 'License:.*Apache-2.0' "$GS/PROVENANCE.txt" \
   && head -5 "$GS/LICENSE.godseye" | grep -q 'Apache License'; then
    pass "licence recorded as Apache-2.0 and the text ships"
else fail "GODSEYE licence" "PROVENANCE/LICENSE mismatch"; fi
if grep -q 'package-lock.json sha256 [0-9a-f]\{64\}' "$GS/PROVENANCE.txt"; then
    pass "PROVENANCE pins the dependency lock file by SHA-256"
else fail "PROVENANCE pins the dependency tree" "a rebuild is not reproducible"; fi
if grep -q 'vite build --base=\./' "$GS/PROVENANCE.txt"; then
    pass "PROVENANCE records the exact build command"
else fail "PROVENANCE records the build command"; fi

MANIFEST_N="$(grep -c . "$GS/MANIFEST.sha256" | tr -d ' ')"
TREE_N="$(find "$GS/app" -type f | wc -l | tr -d ' ')"
if [[ "$MANIFEST_N" == "$TREE_N" ]]; then
    pass "MANIFEST.sha256 covers every vendored file ($MANIFEST_N)"
else
    fail "MANIFEST covers the bundle" \
         "manifest $MANIFEST_N vs tree $TREE_N — a file moved without re-pinning"
fi
if (cd "$GS" && $SHACHECK MANIFEST.sha256 >/dev/null 2>&1); then
    pass "all $MANIFEST_N vendored files match their recorded checksums"
else
    fail "vendored GODSEYE checksums" "$(cd "$GS" && $SHACHECK MANIFEST.sha256 2>&1 | head -3)"
fi

# Mutation: one byte, in a copy, and the check must notice.
mkdir -p "$TMP/mut-manifest/app/assets"
cp "$GS/MANIFEST.sha256" "$TMP/mut-manifest/"
(cd "$GS" && find app -type f -print0) | (cd "$GS" && xargs -0 -I{} \
    sh -c 'mkdir -p "$1/$(dirname "$2")" && cp "$2" "$1/$2"' _ "$TMP/mut-manifest" {}) \
    2>/dev/null
printf 'x' >> "$TMP/mut-manifest/app/index.html"
if (cd "$TMP/mut-manifest" && $SHACHECK MANIFEST.sha256 >/dev/null 2>&1); then
    fail "checksum check is load-bearing" "a corrupted bundle still verified"
else
    pass "mutation: one appended byte in app/index.html fails the manifest check"
fi
if grep -q 'sha256sum -c' "$HOOK"; then pass "0715 verifies the manifest at build time"
else fail "0715 verifies the manifest"; fi
if grep -q 'exit 1' "$HOOK"; then pass "0715 fails the build rather than shipping a dead globe"
else fail "0715 fails the build on a missing component"; fi

# The ISO is already a seven-part split publish. A re-vendor that balloons the
# bundle is a budget decision, not a detail, and must not pass unremarked.
RAW_BYTES="$(find "$GS" -type f -exec wc -c {} + | tail -1 | awk '{print $1}')"
if [[ "$RAW_BYTES" -gt 0 && "$RAW_BYTES" -lt 62914560 ]]; then
    pass "godseye/ raw size is $RAW_BYTES bytes ($((RAW_BYTES/1048576)) MiB), under the 60 MiB budget"
else
    fail "godseye/ size budget" "$RAW_BYTES bytes — re-measure the compressed cost before shipping"
fi

section "No API key ships, and none can"
if grep -rlE "$KEYPAT" "$GS" >/dev/null 2>&1; then
    fail "no API key in the tree" "$(grep -rlE "$KEYPAT" "$GS" | head -3)"
else
    pass "no API-key-shaped string anywhere under godseye/"
fi
if find "$GS" -name '.env*' | grep -q .; then
    fail "no .env in the tree" "$(find "$GS" -name '.env*' | head -3)"
else pass "no .env file vendored alongside the bundle"; fi
if grep -qF "$KEYPAT" "$HOOK"; then
    pass "0715 greps for the same key pattern this test does (one spelling)"
else fail "0715 key check matches this test" "the hook and the test disagree on what a key looks like"; fi
# Mutation: plant a key and prove the pattern fires.
printf 'const k="AIzaSyD-0123456789abcdefghijklmnopqrstuv";\n' > "$TMP/planted.js"
if grep -qE "$KEYPAT" "$TMP/planted.js"; then
    pass "mutation: a planted Google-shaped key is detected by the pattern"
else fail "key pattern is load-bearing" "a planted key was not detected"; fi
# The key-gated code paths must still be present and simply inert, so the
# preflight's "no key" claim describes real code rather than a removed feature.
if grep -qa 'VITE_AISSTREAM_API_KEY' "$GS"/app/assets/index-*.js; then
    pass "key-gated code paths are present in the bundle and compiled inert"
else fail "key-gated code paths present" "cannot confirm the layers are key-disabled rather than absent"; fi
if grep -q 'NO API KEY WAS SET AT BUILD TIME' "$GS/PROVENANCE.txt"; then
    pass "PROVENANCE states, in terms, that no key was set at build time"
else fail "PROVENANCE states the key position"; fi

section "The gate: a blocked deck is told what it cannot do, not shown a globe"
cat > "$TMP/gatecheck.py" <<'PY'
"""Assert the gate's four answers and that every refusal is actionable.

Imported from a directory argument so the same checks can be run against a
mutated copy of the server — which is the only way to know they are
load-bearing.
"""
import sys
sys.path.insert(0, sys.argv[1])
import osint_server as S                                       # noqa: E402

ok = True


def check(cond, label):
    global ok
    print(("    ok   " if cond else "    BAD  ") + label)
    ok = ok and bool(cond)


APP = "/godseye/app/"
ASSET = "/godseye/app/assets/index-abc.js"

allowed = {"allowed": True, "state": "ok", "headline": "h", "detail": "d", "remedy": ""}
noroute = S.outbound_verdict(S.read_posture('{"tier": "0"}'),
                             {"default_route": False, "interface": None})
shields = S.outbound_verdict(S.read_posture('{"tier": "2", "label": "Tier 2"}'),
                             {"default_route": True, "interface": "eth0"})
unknown = S.outbound_verdict(S.read_posture(None),
                             {"default_route": True, "interface": "eth0"})

# 1. A permitted deck is not obstructed.
check(S.godseye_gate(APP, allowed) is None, "allowed deck: the globe is served")

# 2. Everything else is refused, and every refusal is complete.
for name, verdict in (("no route", noroute), ("shields up", shields),
                      ("posture unknown", unknown)):
    r = S.godseye_gate(APP, verdict)
    check(r is not None, "%s: the globe is REFUSED" % name)
    if not r:
        continue
    for field in ("headline", "what", "so_what", "still_works", "remedy"):
        value = str(r.get(field) or "").strip()
        check(len(value) >= 12,
              "%s: refusal names %s (%r)" % (name, field, value[:52]))
    html = S.godseye_refusal_html(r)
    check(str(r["headline"])[:24] in html, "%s: the page carries the headline" % name)
    check(str(r["remedy"])[:18] in html, "%s: the page carries the remedy" % name)
    # The refusal page must not itself reach out to render.
    check("http://" not in html and "https://" not in html,
          "%s: refusal page fetches nothing external" % name)
    check("<html" in html and "</html>" in html, "%s: refusal page is a document" % name)

# 3. The refusals say the specific true thing, not a generic one.
nr = S.godseye_gate(APP, noroute)
check("default route" in nr["headline"].lower(), "no route: headline names the route")
check("featureless" in nr["what"] or "no imagery" in nr["what"],
      "no route: explains the globe would be blank, not empty-of-events")
check("asked nobody" in nr["so_what"] or "not evidence" in nr["so_what"],
      "no route: refuses the 'nothing is happening' reading")
su = S.godseye_gate(APP, shields)
check("allorigins" in su["what"] and "jina" in su["what"],
      "shields up: names the anonymous relays by host")
check("posture" in su["remedy"].lower() or "Control Center" in su["remedy"],
      "shields up: remedy points at the posture control")

# 4. Scope. The gate governs the entry documents of this bundle and nothing else.
check(S.godseye_gate(ASSET, noroute) is None, "static assets are not gated")
check(S.godseye_gate("/", noroute) is None, "the investigation surface is not gated")
check(S.godseye_gate("/godseye/", noroute) is None, "the preflight page is never gated")
check(S.godseye_gate("/cyberchef/", noroute) is None, "CyberChef is never gated")
check(S.godseye_gate("/godseye/app", noroute) is not None, "the bare app path is gated")
check(S.godseye_gate("/godseye/app/index.html", noroute) is not None,
      "app/index.html is gated")

# 5. The dead backend routes name themselves rather than 404ing.
for route, expect in (("/api/flights", True), ("/api/flights?lamin=1", False),
                      ("/api/cctv/sources", True), ("/api/radio/stations", True),
                      ("/api/traffic/status", True), ("/api/overpass", True),
                      ("/api/status.json", False), ("/api/pewpew.json", False),
                      ("/godseye/app/", False)):
    got = S.godseye_backend_route(route.split("?")[0])
    check(bool(got) is (expect or route.startswith("/api/flights")),
          "backend route %s -> %r" % (route, got))
check(len(S.GODSEYE_BACKEND_ROUTES) == 5,
      "all five upstream Node route families are declared")

sys.exit(0 if ok else 1)
PY
if python3 "$TMP/gatecheck.py" "$SRC"; then
    pass "gate refuses the globe on every blocked path and names what/why/remedy"
else
    fail "gate honesty" "see output above"
fi

# ---------------------------------------------------------------------------
# Mutation 1: break the gate open. If these assertions are not load-bearing,
# a server that serves the globe to a shields-up deck still passes them.
# ---------------------------------------------------------------------------
rm -rf "$TMP/mut-open"; mkdir -p "$TMP/mut-open"
cp "$SRC/pewpew_feed.py" "$TMP/mut-open/"
sed 's/^    if outbound.get("allowed"):$/    if True:/' \
    "$SRC/osint_server.py" > "$TMP/mut-open/osint_server.py"
if cmp -s "$TMP/mut-open/osint_server.py" "$SRC/osint_server.py"; then
    fail "mutation applied: gate always allows" "sed changed nothing"
elif python3 "$TMP/gatecheck.py" "$TMP/mut-open" >/dev/null 2>&1; then
    fail "mutation caught: gate always allows" "the gate check PASSED on broken code"
else
    pass "mutation caught: a gate that always allows would serve a blank globe"
fi

# ---------------------------------------------------------------------------
# Mutation 2: keep the refusal but strip the remedy. This is the subtler lie
# and the one rule 8 is actually about — refusing without saying what to do.
# ---------------------------------------------------------------------------
rm -rf "$TMP/mut-mute"; mkdir -p "$TMP/mut-mute"
cp "$SRC/pewpew_feed.py" "$TMP/mut-mute/"
sed 's|^            "remedy": str(outbound.get("remedy") or "nmcli device status   # or: ip route"),$|            "remedy": "",|' \
    "$SRC/osint_server.py" > "$TMP/mut-mute/osint_server.py"
if cmp -s "$TMP/mut-mute/osint_server.py" "$SRC/osint_server.py"; then
    fail "mutation applied: refusal without a remedy" "sed changed nothing"
elif python3 "$TMP/gatecheck.py" "$TMP/mut-mute" >/dev/null 2>&1; then
    fail "mutation caught: refusal without a remedy" "the gate check PASSED on a silent refusal"
else
    pass "mutation caught: a refusal with no remedy fails the suite (rule 8)"
fi

# ---------------------------------------------------------------------------
# Mutation 3: make the no-route refusal generic. "Not available right now"
# is the sentence that teaches an operator the deck's messages mean nothing.
# ---------------------------------------------------------------------------
rm -rf "$TMP/mut-vague"; mkdir -p "$TMP/mut-vague"
cp "$SRC/pewpew_feed.py" "$TMP/mut-vague/"
sed 's|"headline": "No default route — GODSEYE has nothing to draw",|"headline": "GODSEYE is not available right now",|' \
    "$SRC/osint_server.py" > "$TMP/mut-vague/osint_server.py"
if cmp -s "$TMP/mut-vague/osint_server.py" "$SRC/osint_server.py"; then
    fail "mutation applied: vague headline" "sed changed nothing"
elif python3 "$TMP/gatecheck.py" "$TMP/mut-vague" >/dev/null 2>&1; then
    fail "mutation caught: vague headline" "the gate check PASSED on a headline that names nothing"
else
    pass "mutation caught: a headline that does not name the cause fails the suite"
fi

section "End to end over HTTP: the server, not just the page, refuses"
printf 'Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n' \
    > "$TMP/route-up"
printf 'eth0\t00000000\t0102040A\t0003\t0\t0\t100\t00000000\t0\t0\t0\n' >> "$TMP/route-up"
: > "$TMP/route-down"
printf '{"tier": "0", "label": "Tier 0 \xc2\xb7 Passive"}\n' > "$TMP/posture0.json"
printf '{"tier": "2", "label": "Tier 2 \xc2\xb7 Deception"}\n' > "$TMP/posture2.json"
printf 'not json at all\n' > "$TMP/posture-bad.json"

WEB="$CH/opt/orionx/osint"
serve_and_probe() {
    # $1 posture file, $2 route file, $3 label, $4.. "path=expected_status[:needle]"
    local posture="$1" route="$2" label="$3"; shift 3
    local port=$(( 9100 + (RANDOM % 300) ))
    local log="$TMP/srv.$port.log"
    (
      ORIONX_POSTURE_STATUS="$posture" \
      ORIONX_PROC_ROUTE="$route" ORIONX_PROC_ROUTE6="/dev/null" \
      ORIONX_EVENT_LOG="$TMP/nonexistent-bus.jsonl" \
      python3 "$SRC/osint_server.py" --root "$WEB" --port "$port" \
              --no-browser >"$log" 2>&1
    ) &
    local pid=$!
    local url=""
    for _ in $(seq 1 60); do
        url="$(sed -n 's|.*at \(http://127.0.0.1:[0-9]*\)/.*|\1|p' "$log" 2>/dev/null | head -1)"
        [[ -n "$url" ]] && break
        sleep 0.25
    done
    if [[ -z "$url" ]]; then
        fail "$label: server bound" "$(head -5 "$log" 2>/dev/null)"
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        return
    fi
    local spec path want needle code body
    for spec in "$@"; do
        path="${spec%%=*}"; want="${spec#*=}"
        needle=""
        case "$want" in *:*) needle="${want#*:}"; want="${want%%:*}";; esac
        body="$TMP/body.$$"
        code="$(curl -s -o "$body" -w '%{http_code}' --max-time 20 "$url$path" || echo 000)"
        if [[ "$code" != "$want" ]]; then
            fail "$label: GET $path -> HTTP $want" "got $code"
        elif [[ -n "$needle" ]] && ! grep -qi -- "$needle" "$body"; then
            fail "$label: GET $path body mentions '$needle'" "$(head -c 200 "$body")"
        else
            pass "$label: GET $path -> HTTP $code${needle:+ (says '$needle')}"
        fi
        rm -f "$body"
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

if ! command -v curl >/dev/null 2>&1; then
    fail "curl available" "the HTTP end-to-end section cannot run"
else
    serve_and_probe "$TMP/posture0.json" "$TMP/route-up" "route up, Tier 0" \
        "/godseye/=200:preflight" \
        "/godseye/app/=200:overlay.js" \
        "/godseye/HOSTS.txt=200:INVENTORY BEGIN" \
        "/api/flights=501:no-node-backend" \
        "/api/cctv/sources=501:Orion-X runs no Node" \
        "/api/status.json=200:outbound"
    serve_and_probe "$TMP/posture0.json" "$TMP/route-down" "no default route" \
        "/godseye/=200:preflight" \
        "/godseye/app/=503:No default route" \
        "/godseye/app/index.html=503:asked nobody" \
        "/godseye/app/assets/index-CzhDypiF.css=200:" \
        "/api/flights=501:no-node-backend"
    serve_and_probe "$TMP/posture2.json" "$TMP/route-up" "Tier 2 shields up" \
        "/godseye/=200:preflight" \
        "/godseye/app/=503:allorigins" \
        "/godseye/app/=503:Control Center"
    serve_and_probe "$TMP/posture-bad.json" "$TMP/route-up" "posture unparseable" \
        "/godseye/app/=503:posture" \
        "/godseye/app/=503:systemctl status orionx-postured"
fi

section "Hosts: every third party is enumerated, and the list cannot drift"
if python3 "$SRC/godseye_hosts.py" --root "$GS" --check >"$TMP/hosts.out" 2>&1; then
    pass "HOSTS.txt matches the hosts in the bundle that ships ($(grep -o '[0-9]* hosts' "$TMP/hosts.out" | head -1))"
else
    fail "HOSTS.txt matches the bundle" "$(head -6 "$TMP/hosts.out")"
fi
if python3 - "$SRC" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import godseye_hosts as G                                      # noqa: E402
ok = True
def check(cond, label):
    global ok
    print(("    ok   " if cond else "    BAD  ") + label)
    ok = ok and bool(cond)

got = G.extract_hosts(b'fetch("https://api.allorigins.win/raw?url=x");'
                      b'new URL("http://Example.COM.")')
check(got == {"api.allorigins.win", "example.com"},
      "extracts hosts, case-folded and dot-stripped -> %s" % sorted(got))
check(G.extract_hosts(b"https://${base}/x https://' http://localhost/y") == set(),
      "template fragments and bare localhost are not reported as hosts")
check(G.extract_hosts(b"https://1.2.3.4/x") == set(),
      "a bare IPv4 literal is not reported as a name")
check(G.extract_hosts(b"https://kathy.torontocast.com:2860/s") ==
      {"kathy.torontocast.com:2860"}, "a non-default port is preserved")
check(G.parse_inventory("x\n%s\na.com\nb.com\n%s\ny" %
                        (G.INVENTORY_BEGIN, G.INVENTORY_END)) == ["a.com", "b.com"],
      "parses the generated block and ignores the prose around it")
check(G.parse_inventory("no markers here") == [],
      "a HOSTS.txt with no markers yields no inventory (and so fails --check)")
sys.exit(0 if ok else 1)
PY
then pass "host extraction is pure and rejects template junk"
else fail "host extraction assertions" "see output above"; fi

# Mutation: a re-vendor that introduces a new host must turn the suite red.
rm -rf "$TMP/mut-host"; mkdir -p "$TMP/mut-host/app"
cp "$GS/HOSTS.txt" "$TMP/mut-host/"
cp "$GS/app/index.html" "$TMP/mut-host/app/"
printf '<!-- https://exfil.example.net/collect -->\n' >> "$TMP/mut-host/app/index.html"
if python3 "$SRC/godseye_hosts.py" --root "$TMP/mut-host" --check \
        >"$TMP/mut-host.out" 2>&1; then
    fail "mutation caught: a new host in the bundle" "--check PASSED with an unrecorded host"
elif grep -q 'exfil.example.net' "$TMP/mut-host.out"; then
    pass "mutation caught: an unrecorded host is named, with the remedy"
else
    fail "mutation caught: a new host in the bundle" \
         "--check failed but did not name the host: $(head -3 "$TMP/mut-host.out")"
fi
if grep -q 'godseye_hosts.py --write' "$TMP/mut-host.out"; then
    pass "the drift failure names the command that fixes it"
else fail "drift failure names its remedy" "$(tail -3 "$TMP/mut-host.out")"; fi

# The prose must classify the hosts that matter, and every host it names must
# really be in the bundle — a section that names a host the bundle does not
# contain is the same drift in the other direction.
if python3 - "$GS" "$SRC" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[2])
import godseye_hosts as G                                      # noqa: E402
text = open(sys.argv[1] + "/HOSTS.txt", encoding="utf-8").read()
prose = text.split(G.INVENTORY_BEGIN)[0]
inventory = set(G.parse_inventory(text))
ok = True
def check(cond, label):
    global ok
    print(("    ok   " if cond else "    BAD  ") + label)
    ok = ok and bool(cond)

for section in ("A. CONTACTED THE MOMENT THE GLOBE OPENS",
                "B. CONTACTED WHEN A LAYER IS ENABLED",
                "C. RELAYS", "D. CONTACTED ONLY WHEN YOU OPEN",
                "E. REQUIRES AN API KEY", "F. DEAD IN THIS BUILD",
                "G. PRESENT IN THE BYTES"):
    check(section in prose, "HOSTS.txt has section %r" % section.split(".")[0])

for host in ("api.allorigins.win", "r.jina.ai", "server.arcgisonline.com",
             "terrain.reearth.land", "opensky-network.org", "celestrak.org",
             "earthquake.usgs.gov", "generativelanguage.googleapis.com"):
    check(host in prose, "classified in the prose: %s" % host)
    check(host in inventory, "present in the bundle: %s" % host)

# Every bare host named in the prose must exist in the bundle, unless the
# line that names it says it does not. An unmarked host the bundle lacks is
# the same drift as an unrecorded host, in the other direction: a reviewer
# greps for it, finds nothing, and stops trusting the file.
MARK = "[not in this build's bytes]"
lines = prose.splitlines()
marked = set()
for i, line in enumerate(lines):
    if MARK not in line:
        continue
    # the marker may sit on the host's line or on a continuation beneath it
    for probe in lines[max(0, i - 4):i + 1]:
        marked |= set(re.findall(r"\b((?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,})\b", probe))
check(len(marked) >= 3, "hosts absent from this build are explicitly marked: %s"
      % sorted(marked))
for host in ("api.tomtom.com", "content.guardianapis.com", "dns.google"):
    check(host in marked, "marked as absent from this build: %s" % host)
    check(host not in inventory, "really absent from the bundle: %s" % host)

named = set(re.findall(r"\b((?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,})\b", prose))
ignore = {"hosts.txt", "index.html", "provenance.txt", "manifest.sha256",
          "cesium.js", "overlay.js", "gate.js", "package.json",
          "package-lock.json", "cctv-verified.json", "godseye_hosts.py",
          "test_godseye.sh", "osint_server.py", "satellite.js", "hls.js",
          "traffic.mjs", "licence.godseye", "license.godseye", "e.g",
          "earthcam.net"}
stray = sorted(h for h in named - inventory - ignore - marked if "." in h)
check(not stray, "no host is named in the prose that the bundle lacks: %s" % stray)

check("plaintext HTTP" in prose, "the r.jina.ai plaintext downgrade is stated")
check("sees this deck" in prose or "this deck's address" in prose,
      "the relays' visibility into this deck is stated")
check("no offline mode" in prose, "the absence of an offline mode is stated")
for route in ("/api/flights", "/api/cctv/", "/api/radio/", "/api/traffic/",
              "/api/overpass"):
    check(route in prose, "section F names the dead route %s" % route)
sys.exit(0 if ok else 1)
PY
then pass "HOSTS.txt classifies the relays, the key-gated hosts and the dead routes"
else fail "HOSTS.txt prose integrity" "see output above"; fi

section "The two edits to the vendored page, and nothing else external"
APPIDX="$GS/app/index.html"
if grep -q 'fonts\.googleapis\.com\|fonts\.gstatic\.com' "$APPIDX"; then
    fail "Google Fonts stripped from app/index.html" \
         "the globe would contact Google merely to render itself"
else pass "Google Fonts link removed from the vendored page (edit 1)"; fi
if grep -q '\.\./overlay\.js' "$APPIDX"; then
    pass "the vendored page loads ../overlay.js (edit 2)"
else fail "vendored page loads the honesty overlay" "the globe would never be covered"; fi
if grep -qE '(src|href)="/[^/]' "$APPIDX"; then
    fail "vendored page uses relative asset paths" \
         "$(grep -oE '(src|href)="/[^"]*"' "$APPIDX" | head -2) — would 404 under /godseye/app/"
else pass "vendored page references its assets relatively (built with --base=./)"; fi
if grep -qE 'https?://' "$APPIDX"; then
    fail "no external URL left in the vendored page" "$(grep -oE 'https?://[^"]*' "$APPIDX" | head -2)"
else pass "no external URL anywhere in the vendored page"; fi
if grep -q 'googleapis' "$HOOK" && grep -q 'overlay' "$HOOK"; then
    pass "0715 re-checks both edits at build time, so a careless re-vendor fails"
else fail "0715 re-checks the two edits" "a re-vendor could silently drop them"; fi

for f in "$GS/index.html" "$GS/gate.js" "$GS/overlay.js"; do
    if grep -nE "https?://[a-z]" "$f" | grep -vE "^[0-9]+: *\*|^[0-9]+: *#|creativecommons" >/dev/null; then
        fail "no network URL in $(basename "$f")" "$(grep -nE 'https?://[a-z]' "$f" | head -2)"
    else pass "no network URL in $(basename "$f")"; fi
done
if python3 - "$GS/index.html" <<'PY'
import sys
from html.parser import HTMLParser
VOID = {"area","base","br","col","embed","hr","img","input","link","meta",
        "param","source","track","wbr"}
class Check(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack=[]; self.errors=[]; self.external=[]
        self.title=False; self.charset=False; self.viewport=False
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if tag not in VOID: self.stack.append(tag)
        if tag=="title": self.title=True
        if tag=="meta":
            if "charset" in a: self.charset=True
            if a.get("name")=="viewport": self.viewport=True
        for k in ("src","href"):
            v=a.get(k) or ""
            if v.startswith(("http://","https://","//")): self.external.append(v)
    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag in self.stack and tag not in VOID: self.stack.pop()
    def handle_endtag(self, tag):
        if tag in VOID: return
        if not self.stack or self.stack[-1]!=tag:
            if tag in self.stack:
                while self.stack and self.stack[-1]!=tag:
                    self.errors.append("unclosed <%s>" % self.stack.pop())
            else:
                self.errors.append("stray </%s>" % tag); return
        self.stack.pop()
text=open(sys.argv[1],encoding="utf-8").read()
p=Check(); p.feed(text); p.close()
bad=[]
if not text.lstrip().lower().startswith("<!doctype html>"): bad.append("no doctype")
if "<html lang=" not in text: bad.append("no lang")
for name,flag in (("title",p.title),("charset",p.charset),("viewport",p.viewport)):
    if not flag: bad.append("no "+name)
bad += p.errors + (["unclosed at EOF: "+",".join(p.stack)] if p.stack else [])
bad += (["external: "+";".join(p.external)] if p.external else [])
print("  " + ("; ".join(bad) if bad else "well-formed, self-contained"))
sys.exit(1 if bad else 0)
PY
then pass "the preflight page is well-formed and self-contained"
else fail "preflight page validity" "see above"; fi

section "Wiring"
if python3 - "$REPO_ROOT" <<'PY'
import json, os, sys
root = sys.argv[1]
web = os.path.join(root, "iso/config/includes.chroot/opt/orionx/osint")
chroot = os.path.join(root, "iso/config/includes.chroot")
data = json.load(open(os.path.join(web, "links.json"), encoding="utf-8"))
ok = True
def check(cond, label):
    global ok
    print(("    ok   " if cond else "    BAD  ") + label)
    ok = ok and bool(cond)
entries = [i for i in data.get("local", []) if i.get("id") == "godseye"]
check(len(entries) == 1, "exactly one godseye entry in links.json")
if entries:
    e = entries[0]
    check(e.get("kind") == "page" and e.get("launch") == "/godseye/",
          "launches the PREFLIGHT, not app/ (%r)" % e.get("launch"))
    rp = e.get("runtime_path", "")
    check(rp == "/opt/orionx/osint/godseye/index.html", "runtime_path is the preflight")
    check(os.path.exists(os.path.join(chroot, rp.lstrip("/"))),
          "the runtime_path really ships")
    blurb = (e.get("blurb") or "").lower()
    check("internet" in blurb or "network" in blurb,
          "the catalogue entry warns that it needs the internet")
    check("refus" in blurb or "posture" in blurb,
          "the catalogue entry warns that it can be refused")
sys.exit(0 if ok else 1)
PY
then pass "links.json lists GODSEYE honestly and points at the preflight"
else fail "links.json godseye entry" "see output above"; fi

DESK="$APPS/orionx-godseye.desktop"
if grep -q -- 'Exec=/usr/bin/orionx-osint --page godseye' "$DESK"; then
    pass ".desktop launches orionx-osint --page godseye"
else fail ".desktop Exec line" "$(grep '^Exec' "$DESK")"; fi
if grep -q '^Categories=X-Orion;' "$DESK"; then pass ".desktop grouped under the Orion menu"
else fail ".desktop Orion menu grouping"; fi
if grep -q -- '"godseye": "godseye/"' "$SRC/osint_server.py" \
   && grep -q -- '"pewpew", "godseye"' "$SRC/osint_server.py"; then
    pass "orionx-osint --page godseye is wired to /godseye/"
else fail "--page godseye wiring" "the .desktop would fail with an argparse error"; fi
if python3 "$SRC/osint_server.py" --page godseye --help >/dev/null 2>&1; then
    pass "argparse accepts --page godseye"
else fail "argparse accepts --page godseye" "the menu entry would exit non-zero"; fi

CHECKOUT="$TMP/selfcheck.txt"
ORIONX_POSTURE_STATUS="$TMP/posture0.json" ORIONX_PROC_ROUTE="/dev/null" \
ORIONX_PROC_ROUTE6="/dev/null" ORIONX_EVENT_LOG="$TMP/none.jsonl" \
    python3 "$SRC/osint_server.py" --root "$WEB" --check > "$CHECKOUT" 2>&1
CHECK_RC=$?
for row in "GODSEYE preflight" "GODSEYE bundle" "GODSEYE host list" "GODSEYE manifest"; do
    if grep -q "\[ ok \] $row" "$CHECKOUT"; then pass "orionx-osint --check reports: $row"
    else fail "orionx-osint --check reports: $row" "$(grep -i godseye "$CHECKOUT" | head -2)"; fi
done
if [[ "$CHECK_RC" -eq 0 ]]; then pass "orionx-osint --check exits 0 with GODSEYE installed"
else fail "orionx-osint --check exit code" "rc=$CHECK_RC: $(grep MISS "$CHECKOUT" | head -3)"; fi

# The overlay is the Loop stage: it must re-ask, and it must fail closed.
if grep -q 'setInterval' "$GS/overlay.js" && grep -q '/api/status.json' "$GS/overlay.js"; then
    pass "overlay re-asks the single posture authority on a cycle"
else fail "overlay polls /api/status.json" "a posture change mid-session would go unnoticed"; fi
if grep -q 'catch' "$GS/overlay.js" && grep -q 'Not knowing is not permission' "$GS/overlay.js"; then
    pass "overlay fails closed when it cannot read the deck's status"
else fail "overlay fails closed"; fi
if grep -q 'failClosed' "$GS/gate.js" && grep -q '/api/status.json' "$GS/gate.js"; then
    pass "preflight reads the same single authority and fails closed"
else fail "preflight fails closed"; fi
if grep -c 'outbound_verdict\|OUTBOUND_BLOCKED_TIERS' "$SRC/osint_server.py" >/dev/null \
   && ! grep -q 'OUTBOUND_BLOCKED_TIERS' "$GS/gate.js" "$GS/overlay.js"; then
    pass "no second posture authority: the pages ask, they do not decide"
else fail "single posture authority" "a tier list is duplicated in the browser"; fi
DEADN="$(sed -n '/^  var DEAD = \[/,/^  \];/p' "$GS/overlay.js" | grep -c '^    "')"
if [[ "$DEADN" -eq 5 ]]; then
    pass "overlay names all five dead backend route families"
else fail "overlay names the dead layers" "found $DEADN entries, expected 5"; fi

# This slice must not have edited the hooks it does not own.
for owned in 0615-install-systemd-units.hook.chroot 0700-orionx-setup.hook.chroot; do
    if grep -q 'godseye' "$REPO_ROOT/iso/config/hooks/live/$owned"; then
        fail "0715 is the only hook that knows about GODSEYE" "$owned mentions godseye"
    else pass "did not edit $owned (0700 stays the single PATH authority)"; fi
done

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
