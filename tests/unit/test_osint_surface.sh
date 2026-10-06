#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_osint_surface.sh — OSINT / investigation surface (DEC-PHASE12-043)
#
# Three things ship here and each has a way of lying:
#
#   * a launcher page can list a tool that is not on the image, or offer an
#     off-deck link as though clicking it would work;
#   * a vendored CyberChef can be a different build from the one whose
#     provenance is recorded beside it;
#   * an attack map can invent a position for an address it cannot locate,
#     which on an incident-response deck is worse than drawing nothing.
#
# The last one is the point of this file. The invariant is mutation-tested:
# the no-coordinates rule is deliberately broken in a copy of the adapter and
# the assertion must go red. A test that passes on broken code is a false
# assurance, and this project has shipped several (docs/RESILIENCE.md).
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
WEB="$CH/opt/orionx/osint"
SRC="$REPO_ROOT/scripts/osint"
HOOK="$REPO_ROOT/iso/config/hooks/live/0710-osint-surface.hook.chroot"
TMP="$REPO_ROOT/tmp/test_osint_surface.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

if command -v sha256sum >/dev/null 2>&1; then SHACHECK="sha256sum -c --quiet"
else SHACHECK="shasum -a 256 -c --status"; fi

section "Structure"
for f in "$WEB/index.html" "$WEB/app.js" "$WEB/links.json" "$WEB/recipes.json" \
         "$WEB/GEOIP.txt" "$WEB/cyberchef/index.html" "$WEB/cyberchef/LICENSE" \
         "$WEB/cyberchef/PROVENANCE.txt" "$WEB/cyberchef/MANIFEST.sha256" \
         "$WEB/pewpew/index.html" "$WEB/pewpew/map.js" "$WEB/pewpew/pew.mp3" \
         "$WEB/pewpew/PROVENANCE.txt" "$WEB/pewpew/LICENSE.ipew" \
         "$SRC/osint_server.py" "$SRC/pewpew_feed.py" \
         "$CH/usr/bin/orionx-osint" \
         "$CH/opt/orionx/optional/install-geoip.sh" "$HOOK"; do
    if [[ -f "$f" ]]; then pass "ships: ${f#"$REPO_ROOT"/}"
    else fail "ships: ${f#"$REPO_ROOT"/}" "missing"; fi
done
[[ -x "$CH/usr/bin/orionx-osint" ]] && pass "/usr/bin/orionx-osint is executable" || fail "/usr/bin/orionx-osint executable"
[[ -x "$CH/opt/orionx/optional/install-geoip.sh" ]] && pass "install-geoip.sh is executable" || fail "install-geoip.sh executable"
[[ -x "$HOOK" ]] && pass "0710 hook is executable" || fail "0710 hook executable"
for f in "$SRC/pewpew_feed.py" "$SRC/osint_server.py" "$HOOK" \
         "$CH/opt/orionx/optional/install-geoip.sh" "$CH/usr/bin/orionx-osint"; do
    if grep -q '@decision DEC-PHASE12-043' "$f"; then pass "decision annotation: $(basename "$f")"
    else fail "decision annotation: $(basename "$f")" "missing @decision DEC-PHASE12-043"; fi
done

section "Launcher page is valid, self-contained HTML"
if python3 - "$WEB/index.html" "$WEB/pewpew/index.html" <<'PY'
import sys
from html.parser import HTMLParser

VOID = {"area","base","br","col","embed","hr","img","input","link","meta",
        "param","source","track","wbr"}
ok = True

class Check(HTMLParser):
    def __init__(self, name):
        super().__init__(convert_charrefs=True)
        self.name = name; self.stack = []; self.errors = []
        self.external = []; self.has_title = False; self.has_charset = False
        self.has_viewport = False
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag not in VOID:
            self.stack.append(tag)
        if tag == "title":
            self.has_title = True
        if tag == "meta":
            if "charset" in a:
                self.has_charset = True
            if a.get("name") == "viewport":
                self.has_viewport = True
        for key in ("src", "href"):
            v = a.get(key) or ""
            if v.startswith(("http://", "https://", "//")):
                self.external.append(tag + " " + key + "=" + v)
    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag in self.stack and tag not in VOID:
            self.stack.pop()
    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack:
            self.errors.append("stray </%s>" % tag); return
        if self.stack[-1] != tag:
            if tag in self.stack:
                while self.stack and self.stack[-1] != tag:
                    self.errors.append("unclosed <%s> before </%s>"
                                       % (self.stack.pop(), tag))
            else:
                self.errors.append("stray </%s>" % tag); return
        self.stack.pop()

for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    p = Check(path)
    p.feed(text); p.close()
    name = path.rsplit("/", 2)[-1]
    def bad(msg):
        global ok
        print("  BAD  %s: %s" % (name, msg)); ok = False
    if not text.lstrip().lower().startswith("<!doctype html>"):
        bad("no <!DOCTYPE html>")
    if '<html lang=' not in text:
        bad("no lang on <html>")
    if not p.has_title: bad("no <title>")
    if not p.has_charset: bad("no <meta charset>")
    if not p.has_viewport: bad("no viewport meta")
    if p.errors: bad("; ".join(p.errors[:4]))
    if p.stack: bad("unclosed at EOF: " + ",".join(p.stack))
    # A page on an offline deck that reaches out to render itself is a page
    # that announces the deck. There must be nothing external at all.
    if p.external: bad("external resource(s): " + "; ".join(p.external[:3]))
    if not p.errors and not p.stack and not p.external:
        print("  ok   %s: well-formed, self-contained" % name)
sys.exit(0 if ok else 1)
PY
then pass "launcher and map pages parse clean and reference nothing external"
else fail "launcher/map HTML validity" "see output above"; fi

for js in "$WEB/app.js" "$WEB/pewpew/map.js"; do
    if grep -nE "https?://[a-z]" "$js" | grep -vE "^\s*[0-9]+:\s*\*|creativecommons|db-ip\.com|github\.com/hrbrmstr" >/dev/null; then
        fail "no network URLs in $(basename "$js")" "$(grep -nE 'https?://[a-z]' "$js" | head -2)"
    else
        pass "no network URLs in $(basename "$js") (comments/attribution aside)"
    fi
done

section "Catalogue: every local entry points at something that actually ships"
if python3 - "$REPO_ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
web = os.path.join(root, "iso/config/includes.chroot/opt/orionx/osint")
chroot = os.path.join(root, "iso/config/includes.chroot")
pkglist = open(os.path.join(root, "iso/config/package-lists/orionx.list.chroot"),
               encoding="utf-8").read().splitlines()
packages = {ln.strip() for ln in pkglist
            if ln.strip() and not ln.strip().startswith("#")}
data = json.load(open(os.path.join(web, "links.json"), encoding="utf-8"))
ok = True

def bad(msg):
    global ok
    print("  BAD  " + msg); ok = False

def resolve(rp):
    """Map a runtime path on the booted deck back to the file in this repo.

    This is the whole point of the section: the catalogue claims a tool is on
    the image, and the only honest way to check that from here is to find the
    thing the build will stage.
    """
    if rp.startswith("pkg:"):
        name = rp[4:]
        return ("package", name in packages, name)
    if rp.startswith("/opt/orionx/scripts/"):
        return ("file", os.path.exists(
            os.path.join(root, "scripts", rp[len("/opt/orionx/scripts/"):])), rp)
    if rp.startswith("/opt/orionx/"):
        return ("file", os.path.exists(
            os.path.join(chroot, "opt/orionx", rp[len("/opt/orionx/"):])), rp)
    if rp.startswith("/usr/bin/"):
        return ("file", os.path.exists(os.path.join(chroot, rp.lstrip("/"))), rp)
    return ("unknown", False, rp)

local = data.get("local") or []
if len(local) < 10:
    bad("only %d local entries; the launcher is meant to be the deck's index" % len(local))
seen = set()
for item in local:
    for key in ("id", "name", "category", "blurb", "runtime_path", "kind"):
        if not item.get(key):
            bad("local entry %r missing %s" % (item.get("name"), key))
    if item.get("id") in seen:
        bad("duplicate local id %r" % item.get("id"))
    seen.add(item.get("id"))
    kind, found, what = resolve(item.get("runtime_path", ""))
    if kind == "unknown":
        bad("local %r: runtime_path %r is not a path this test can verify"
            % (item["name"], item.get("runtime_path")))
    elif not found:
        bad("local %r: %s %r does NOT ship" % (item["name"], kind, what))
    if item["kind"] == "page" and not item.get("launch"):
        bad("local %r is a page with no launch path" % item["name"])
    if item["kind"] == "command" and not item.get("command"):
        bad("local %r is a command with no command" % item["name"])
print("  ok   %d local entries, all resolved to a shipped file or package" % len(local))

inst = data.get("installable") or []
for item in inst:
    kind, found, what = resolve(item.get("runtime_path", ""))
    if not found:
        bad("installable %r: %r does NOT ship" % (item.get("name"), what))
    cmd = item.get("command", "")
    if item.get("runtime_path", "") not in cmd:
        bad("installable %r: command %r does not name its own installer"
            % (item.get("name"), cmd))
    if not cmd.startswith("sudo "):
        bad("installable %r: command is not copy-pasteable as root" % item.get("name"))
print("  ok   %d installable entries, each a one-line command at a real installer"
      % len(inst))

online = data.get("online") or []
if len(online) < 25:
    bad("only %d online entries" % len(online))
urls = set()
cats = set()
for item in online:
    for key in ("name", "url", "category", "note", "verified"):
        if not item.get(key):
            bad("online entry %r missing %s" % (item.get("name"), key))
    u = item.get("url", "")
    if not u.startswith("https://"):
        bad("online %r is not https: %s" % (item.get("name"), u))
    if u in urls:
        bad("duplicate online URL %s" % u)
    urls.add(u)
    cats.add(item.get("category"))
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", str(item.get("verified"))):
        bad("online %r has no ISO verification date" % item.get("name"))
need = {"methodology", "verification", "geolocation", "image-video-forensics",
        "corporate-records", "archives", "infrastructure", "malware-intel"}
missing = need - cats
if missing:
    bad("online catalogue has no entries for: " + ", ".join(sorted(missing)))
if not any("bellingcat" in i["url"] for i in online):
    bad("no Bellingcat resource in the catalogue")
print("  ok   %d online entries across %d categories, all https, all dated"
      % (len(online), len(cats)))
sys.exit(0 if ok else 1)
PY
then pass "links.json: local entries ship, installables are real, online entries are well-formed"
else fail "links.json integrity" "see output above"; fi

section "CyberChef: the vendored build is the one that was pinned"
CCDIR="$WEB/cyberchef"
if grep -q 'SHA-256:   f6478925d3eaa16ec08626a85f5b85eed10d531a5e18700615fed7ecb024cccf' "$CCDIR/PROVENANCE.txt"; then
    pass "PROVENANCE records the upstream release-zip SHA-256"
else fail "PROVENANCE records the upstream zip SHA-256" "pin missing or changed"; fi
if grep -q 'Release:   v11.5.0' "$CCDIR/PROVENANCE.txt"; then pass "PROVENANCE pins v11.5.0"
else fail "PROVENANCE pins a version"; fi
if grep -q 'License:   Apache-2.0' "$CCDIR/PROVENANCE.txt" && head -5 "$CCDIR/LICENSE" | grep -q 'Apache License'; then
    pass "licence recorded as Apache-2.0 and the text ships"
else fail "CyberChef licence" "PROVENANCE/LICENSE mismatch"; fi
MANIFEST_N="$(wc -l < "$CCDIR/MANIFEST.sha256" | tr -d ' ')"
TREE_N="$(find "$CCDIR" -type f ! -name MANIFEST.sha256 ! -name PROVENANCE.txt | wc -l | tr -d ' ')"
if [[ "$MANIFEST_N" == "$TREE_N" ]]; then
    pass "MANIFEST.sha256 covers every vendored file ($MANIFEST_N)"
else fail "MANIFEST covers the tree" "manifest $MANIFEST_N vs tree $TREE_N — a file was added or removed without re-pinning"; fi
if (cd "$CCDIR" && $SHACHECK MANIFEST.sha256 >/dev/null 2>&1); then
    pass "all $MANIFEST_N vendored CyberChef files match their recorded checksums"
else
    fail "vendored CyberChef checksums" "$(cd "$CCDIR" && $SHACHECK MANIFEST.sha256 2>&1 | head -3)"
fi
# Mutation: corrupt one byte in a copy and prove the check notices.
cp -R "$CCDIR" "$TMP/cc-mut" 2>/dev/null
printf 'x' >> "$TMP/cc-mut/assets/main.css"
if (cd "$TMP/cc-mut" && $SHACHECK MANIFEST.sha256 >/dev/null 2>&1); then
    fail "checksum check is load-bearing" "a corrupted file still verified"
else
    pass "mutation: one appended byte in assets/main.css fails the manifest check"
fi
if grep -q 'sha256sum -c' "$HOOK"; then pass "0710 hook verifies the manifest at build time"
else fail "0710 verifies the manifest"; fi
if grep -q 'exit 1' "$HOOK"; then pass "0710 fails the build rather than shipping a dead menu entry"
else fail "0710 fails the build on a missing component"; fi
if find "$CCDIR" -name '*.gz' -o -name '*.br' | grep -q .; then
    fail "pre-compressed duplicates removed" "$(find "$CCDIR" \( -name '*.gz' -o -name '*.br' \) | wc -l) remain"
else pass "pre-compressed .gz/.br duplicates removed (unreachable over http.server)"; fi

section "CyberChef recipes: every operation exists in the shipped build"
if python3 - "$WEB" <<'PY'
import base64, json, os, re, sys
web = sys.argv[1]
recipes = json.load(open(os.path.join(web, "recipes.json"), encoding="utf-8"))
main = open(os.path.join(web, "cyberchef/assets/main.js"),
            encoding="utf-8", errors="replace").read()
ops = set(re.findall(r'"([^"\\]{2,60})":\{"module":"[A-Za-z0-9]+","description"', main))


def op_names(recipe):
    """Top-level operation names from a CyberChef recipe fragment.

    A regex cannot do this: Decode_text('UTF-16LE (1200)') has a parenthesis
    inside a quoted argument, and a naive scan reads "16LE" as an operation.
    Walk it instead, tracking quote and paren depth.
    """
    out, buf, depth, quote = [], "", 0, None
    for ch in recipe:
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            continue
        if ch == "(":
            if depth == 0 and buf.strip():
                out.append(buf.strip().replace("_", " "))
            depth += 1
            buf = ""
            continue
        if ch == ")":
            depth = max(0, depth - 1)
            buf = ""
            continue
        if depth == 0:
            buf += ch
    return out

if len(ops) < 300:
    print("  BAD  only %d operations parsed out of the build" % len(ops)); sys.exit(1)
ok = True
for r in recipes["recipes"]:
    for key in ("id", "name", "group", "recipe", "why"):
        if not r.get(key):
            print("  BAD  recipe %r missing %s" % (r.get("id"), key)); ok = False
    for name in op_names(r["recipe"]):
        if name not in ops:
            print("  BAD  recipe %r uses operation %r, which is not in CyberChef "
                  "11.5.0 — it would load as an empty recipe" % (r["id"], name))
            ok = False
# CyberChef refuses a recipe whose parentheses do not balance outside quotes
# (Utils._validatePrettyRecipe in the shipped bundle). Reimplemented here
# because a recipe that fails it loads as an EMPTY recipe with no error the
# operator would notice — the quietest possible way for this feature to be
# decoration.
def validates(recipe):
    i = 0
    while i < len(recipe):
        j = recipe.find("(", i)
        if j == -1 or j == i:
            return False
        i = j + 1
        quoted = escaped = closed = False
        while i < len(recipe):
            ch = recipe[i]
            if quoted:
                if escaped:
                    escaped = False
                elif ch == "\\":
                    escaped = True
                elif ch == "'":
                    quoted = False
            elif ch == "'":
                quoted = True
            elif ch == ")":
                closed = True
                i += 1
                break
            i += 1
        if not closed or quoted or escaped:
            return False
    return True


for r in recipes["recipes"]:
    if not validates(r["recipe"]):
        print("  BAD  recipe %r would be rejected by CyberChef's own "
              "validator and load as an empty recipe" % r["id"])
        ok = False

# The worked examples must actually work, or "fully configured" is decoration.
import gzip, zlib
checks = {
    "b64-gunzip": lambda s: gzip.decompress(base64.b64decode(s)),
    "magic":      lambda s: gzip.decompress(base64.b64decode(s)),
    "b64-inflate": lambda s: zlib.decompressobj(-15).decompress(base64.b64decode(s)),
    "ps-encodedcommand": lambda s: base64.b64decode(s).decode("utf-16-le"),
}
by_id = {r["id"]: r for r in recipes["recipes"]}
for rid, fn in checks.items():
    if rid not in by_id:
        print("  BAD  expected recipe %r is missing" % rid); ok = False; continue
    try:
        out = fn(by_id[rid]["input"])
        if not out:
            raise ValueError("empty")
    except Exception as exc:                                    # noqa: BLE001
        print("  BAD  recipe %r ships an example its own chain cannot decode: %s"
              % (rid, exc))
        ok = False
if ok:
    print("  ok   %d recipes, all operations present in the shipped build, "
          "worked examples decode" % len(recipes["recipes"]))
sys.exit(0 if ok else 1)
PY
then pass "recipes reference only operations CyberChef 11.5.0 actually has"
else fail "CyberChef recipes" "see output above"; fi

section "IPew provenance"
if grep -q 'CC BY-SA 4.0' "$WEB/pewpew/PROVENANCE.txt" && grep -q '76606906acf346b81b8d1671f70ad97c1b443172' "$WEB/pewpew/PROVENANCE.txt"; then
    pass "IPew pinned by commit with its CC BY-SA 4.0 licence recorded"
else fail "IPew provenance" "no pinned commit or no licence"; fi
if command -v sha256sum >/dev/null 2>&1; then
    PEWSHA="$(sha256sum "$WEB/pewpew/pew.mp3" | cut -d' ' -f1)"
else PEWSHA="$(shasum -a 256 "$WEB/pewpew/pew.mp3" | cut -d' ' -f1)"; fi
if grep -q "$PEWSHA" "$WEB/pewpew/PROVENANCE.txt"; then
    pass "vendored pew.mp3 matches the SHA-256 in its provenance"
else fail "pew.mp3 checksum" "on disk $PEWSHA is not recorded in PROVENANCE.txt"; fi

section "Map adapter: real bus fixtures, including scanwatch detail"
cat > "$TMP/bus.jsonl" <<'BUS'
{"ts": 1000.0, "iso": "x", "severity": "critical", "source": "firewall", "category": "scan", "message": "port scan from 8.8.4.4 — 42 ports in 9.6s", "id": "aa11", "detail": {"src_ip": "8.8.4.4", "distinct_ports": 42, "window_seconds": 9.6, "protocols": "tcp", "latest_dport": 445, "ports_seen": [22, 80, 445], "detector": "orionx-scanwatch", "evidence": "nftables drop log", "triggering_rule": "log prefix \"[ORIONX-DROP] \" drop  (inet orionx_firewall/input)", "scan_kind": "port scan"}}
{"ts": 1010.0, "iso": "x", "severity": "warning", "source": "firewall", "category": "scan", "message": "slow port scan from 192.168.4.77", "detail": {"src_ip": "192.168.4.77", "distinct_ports": 18, "protocols": "tcp/udp", "latest_dport": 22, "detector": "orionx-scanwatch", "scan_kind": "slow port scan"}}
{"ts": 1020.0, "iso": "x", "severity": "warning", "source": "suricata", "category": "ids", "message": "ET SCAN Potential SSH Scan", "detail": {"src": "100.100.5.9", "sid": 2001219, "dport": 22}}
{"ts": 1030.0, "iso": "x", "severity": "notice", "source": "zeek", "category": "alert", "message": "weird: bad_TCP_checksum", "detail": {"src_ip": "203.0.113.9"}}
{"ts": 1040.0, "iso": "x", "severity": "notice", "source": "postured", "category": "health", "message": "Suricata is running with no threat rules"}
{"ts": 1050.0, "iso": "x", "severity": "info", "source": "firewall", "category": "scan", "message": "drop", "detail": {"src_ip": "not-an-address", "distinct_ports": 3}}
{ this line is not json
BUS
if python3 - "$SRC" "$TMP/bus.jsonl" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import pewpew_feed as F
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

lines = open(sys.argv[2], encoding="utf-8").read().splitlines()
feed = F.build_feed(lines, now=1100.0, window=900.0)
by = {s["ip"]: s for s in feed["sources"]}

check(feed["counts"]["events_parsed"] == 6, "6 well-formed events parsed (%d)" % feed["counts"]["events_parsed"])
check(feed["counts"]["malformed_lines"] == 1, "the malformed line is counted, not crashed on")
check(feed["unattributed"] == 2,
      "the health event (no detail) and the event with an unparseable src_ip "
      "are both counted as unattributable rather than dropped (%d)"
      % feed["unattributed"])
check(set(by) == {"8.8.4.4", "192.168.4.77", "100.100.5.9", "203.0.113.9"},
      "four sources, and 'not-an-address' is rejected -> %s" % sorted(by))

s = by["8.8.4.4"]
check(s["distinct_ports"] == 42, "scanwatch detail.distinct_ports read (%s)" % s["distinct_ports"])
check(s["protocols"] == ["tcp"], "scanwatch detail.protocols read (%s)" % s["protocols"])
check("orionx-scanwatch" in s["detectors"], "scanwatch detail.detector read")
check("port scan" in s["kinds"], "scanwatch detail.scan_kind read")
check(s["max_severity"] == "critical", "severity carried through")
check(by["192.168.4.77"]["protocols"] == ["tcp", "udp"],
      "scanwatch's slash-joined protocols (\"tcp/udp\") split correctly -> %s"
      % by["192.168.4.77"]["protocols"])
check(by["100.100.5.9"]["events"] == 1, "suricata 'src' key is read as well as 'src_ip'")

check(by["8.8.4.4"]["scope"] == "public", "8.8.4.4 is public")
check(by["192.168.4.77"]["scope"] == "private", "192.168.4.77 is RFC1918 private")
check(by["100.100.5.9"]["scope"] == "cgnat", "100.100.5.9 is CGNAT, not private")
check(by["203.0.113.9"]["scope"] == "reserved",
      "203.0.113.9 is RFC5737 documentation space -> reserved, not 'private'")

check(feed["sources"][0]["ip"] == "8.8.4.4", "most severe source sorts first")
check(len(feed["tracers"]) == 4,
      "one tracer per ATTRIBUTABLE event, and none for the other two (%d)"
      % len(feed["tracers"]))
check(all(t["ts"] <= 1100.0 for t in feed["tracers"]), "no tracer from the future")

# A message string full of addresses must not become a source: only
# structured detail is trusted.
msgonly = ['{"ts": 1000.0, "severity": "warning", "source": "x", "category": "scan",'
           ' "message": "blocked 203.0.113.9 reaching 10.0.0.1"}']
check(F.build_feed(msgonly, now=1001.0)["counts"]["sources"] == 0,
      "addresses in a message string are NOT scraped into sources")

# Bounded, like ScanTracker: a spoofed flood must not grow the feed forever.
flood = ['{"ts": 1000.0, "severity": "info", "source": "f", "category": "scan",'
         ' "message": "d", "detail": {"src_ip": "10.%d.%d.%d"}}' % (i // 65536 % 250, i // 256 % 250, i % 250)
         for i in range(400)]
big = F.build_feed(flood, now=1001.0)
check(big["counts"]["sources"] == F.MAX_SOURCES,
      "source table is bounded at %d (%d)" % (F.MAX_SOURCES, big["counts"]["sources"]))
check(big["counts"]["sources_capped"] and big["counts"]["sources_dropped"] > 0,
      "the truncation is reported rather than silently showing a sample")

# Window: anything older than the look-back is excluded.
narrow = F.build_feed(lines, now=1100.0, window=90.0)
check(narrow["counts"]["sources"] == 3 and
      "8.8.4.4" not in {s["ip"] for s in narrow["sources"]},
      "a 90s look-back drops the 100s-old source and keeps the rest (%d left)"
      % narrow["counts"]["sources"])
sys.exit(0 if ok else 1)
PY
then pass "adapter parses real bus fixtures including scanwatch detail"
else fail "adapter parsing" "see output above"; fi

# Drift invariant, by effect rather than by grep: build a detail blob with
# orionx-scanwatch's OWN build_detail(), push it through the bus format, and
# require the adapter to read every field back. A hand-written fixture cannot
# catch the case this is here for — scanwatch joins protocols with "/" and an
# adapter that split only on "," turned "tcp/udp" into one nonsense label
# (found exactly this way, 2026-10-03).
if python3 - "$SRC" "$REPO_ROOT/scripts/rain/orionx-scanwatch" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader

sys.path.insert(0, sys.argv[1])
import pewpew_feed as F
sw = SourceFileLoader("sw", sys.argv[2]).load_module()

ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

tracker = sw.ScanTracker()
alerts = [a for a in (tracker.observe(1000.0 + i / 4.3, "8.8.4.4", 20 + i,
                                      "tcp" if i % 2 else "udp")
                      for i in range(60)) if a]
check(bool(alerts), "scanwatch produced an alert to derive a detail from")
detail = sw.build_detail(alerts[-1])
event = {"ts": 2000.0, "severity": alerts[-1]["severity"], "source": "firewall",
         "category": "scan", "message": sw.format_message(alerts[-1]),
         "detail": detail}
feed = F.build_feed([json.dumps(event)], now=2001.0)
check(feed["counts"]["sources"] == 1, "the adapter accepts scanwatch's own detail")
s = feed["sources"][0]
check(s["ip"] == detail["src_ip"], "src_ip round-trips")
check(s["distinct_ports"] == detail["distinct_ports"],
      "distinct_ports round-trips (%s)" % s["distinct_ports"])
check(sorted(s["protocols"]) == ["tcp", "udp"],
      "scanwatch's %r is read as %r, not one label"
      % (detail["protocols"], s["protocols"]))
check(detail["detector"] in s["detectors"], "detector round-trips")
check(detail["scan_kind"] in s["kinds"], "scan_kind round-trips")
check(s["location"]["located"] is False,
      "and it is still unlocated, because nothing told the map where it is")
sys.exit(0 if ok else 1)
PY
then pass "scanwatch's own build_detail() feeds the map with nothing lost"
else fail "scanwatch -> map detail round-trip" "see output above"; fi

section "THE INVARIANT: an unlocatable address is never given a position"
cat > "$TMP/invariant.py" <<'PY'
"""Assert the no-invented-coordinates rule against a given pewpew_feed module.

Run as: invariant.py <dir containing pewpew_feed.py>
Exit 0 if the rule holds, 1 if it is violated. The mutation test below runs
this against a deliberately broken copy and requires exit 1.
"""
import json
import sys

sys.path.insert(0, sys.argv[1])
import pewpew_feed as F                                        # noqa: E402

COORD_KEYS = ("lat", "lon", "latitude", "longitude", "coords", "coordinates",
              "x", "y", "position", "centroid", "geo_point")
ok = True


def check(cond, label):
    global ok
    print(("    ok   " if cond else "    VIOLATION  ") + label)
    ok = ok and bool(cond)


def no_coords(blob, label):
    text = json.dumps(blob)
    loaded = json.loads(text)

    def walk(node, path):
        global ok
        if isinstance(node, dict):
            for k, v in node.items():
                if k.lower() in COORD_KEYS:
                    print("    VIOLATION  %s: coordinate key %r at %s = %r"
                          % (label, k, path, v))
                    ok = False
                walk(v, path + "." + k)
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, "%s[%d]" % (path, i))
    walk(loaded, "$")


# 1. No database at all.
for ip in ("8.8.4.4", "1.1.1.1", "2606:4700::1111"):
    loc = F.locate(ip, reader=None)
    check(loc["located"] is False, "%s with no database -> located False" % ip)
    check(loc.get("reason") == "no-geoip-database", "%s names why" % ip)
    check(bool(loc.get("remedy")), "%s names the remedy" % ip)
    no_coords(loc, "locate(%s, no db)" % ip)

# 2. Non-routable addresses are a complete answer, not a degraded one.
for ip, why in (("192.168.4.77", "address-is-private"),
                ("127.0.0.1", "address-is-loopback"),
                ("100.100.5.9", "address-is-cgnat"),
                ("203.0.113.9", "address-is-reserved")):
    loc = F.locate(ip, reader=None)
    check(loc["located"] is False and loc.get("reason") == why,
          "%s -> %s" % (ip, why))
    no_coords(loc, "locate(%s)" % ip)


class Reader:
    """A database that answers for one address and shrugs at the rest."""

    def __init__(self, known):
        self.known = known

    def country(self, ip):
        return self.known.get(ip)


# 3. The database answers: a label, and still no coordinates. Note the record
#    deliberately CONTAINS a lat/lon, as real MaxMind-format city records do.
rec = {"country": {"iso_code": "DE", "names": {"en": "Germany"}},
       "location": {"latitude": 51.2993, "longitude": 9.491}}
loc = F.locate("8.8.4.4", reader=Reader({"8.8.4.4": rec}))
check(loc["located"] is True, "a real answer sets located True")
check(loc.get("country") == "DE", "country code carried")
check(loc.get("country_name") == "Germany", "country name carried")
no_coords(loc, "locate(8.8.4.4, db with lat/lon in the record)")

# 4. The database answers "I do not know". That is unlocated, distinctly.
loc = F.locate("1.1.1.1", reader=Reader({}))
check(loc["located"] is False and loc.get("reason") == "not-in-geoip-database",
      "a database gap is distinguished from an absent database")
no_coords(loc, "locate(gap)")


class Broken:
    def country(self, ip):
        raise RuntimeError("truncated mmdb")


loc = F.locate("1.1.1.1", reader=Broken())
check(loc["located"] is False and loc.get("reason") == "geoip-lookup-failed",
      "a corrupt database reports failure rather than looking unlocated")
no_coords(loc, "locate(corrupt db)")

# 5. The whole feed, end to end, with and without a database.
lines = ['{"ts": 1000.0, "severity": "warning", "source": "firewall",'
         ' "category": "scan", "message": "scan",'
         ' "detail": {"src_ip": "%s", "distinct_ports": 9}}' % ip
         for ip in ("8.8.4.4", "1.1.1.1", "192.168.4.77")]
feed = F.build_feed(lines, now=1001.0)
no_coords(feed, "whole feed, no database")
check(feed["counts"]["located"] == 0 and feed["counts"]["unlocated"] == 3,
      "feed counts 0 located / 3 unlocated with no database")
check(all(s["location"]["located"] is False for s in feed["sources"]),
      "every source is explicitly marked unlocated")

feed = F.build_feed(lines, now=1001.0, reader=Reader({"8.8.4.4": rec}))
no_coords(feed, "whole feed, partial database")
check(feed["counts"]["located"] == 1 and feed["counts"]["unlocated"] == 2,
      "feed counts 1 located / 2 unlocated with a partial database")
for s in feed["sources"]:
    if not s["location"]["located"]:
        check(bool(s["location"].get("reason")),
              "%s carries a reason for being unlocated" % s["ip"])

sys.exit(0 if ok else 1)
PY
if python3 "$TMP/invariant.py" "$SRC"; then
    pass "no address is ever given a coordinate it was not told"
else
    fail "no-invented-coordinates invariant" "see violations above"
fi

section "Mutation: break the rule deliberately and the suite must go red"
mutate() {   # <label> <sed expression>
    local label="$1" expr="$2" dir="$TMP/mut"
    rm -rf "$dir"; mkdir -p "$dir"
    sed "$expr" "$SRC/pewpew_feed.py" > "$dir/pewpew_feed.py"
    if cmp -s "$dir/pewpew_feed.py" "$SRC/pewpew_feed.py"; then
        fail "mutation applied: $label" "sed changed nothing — the mutation test is vacuous"
        return
    fi
    if python3 "$TMP/invariant.py" "$dir" >"$TMP/mut.log" 2>&1; then
        fail "mutation caught: $label" "the invariant check PASSED on broken code"
    else
        pass "mutation caught: $label"
    fi
}
# M1: the unlocated shape itself starts carrying coordinates.
mutate "_unlocated() returns located=true with 0,0" \
       's/"located": False, "reason": reason/"located": True, "lat": 0.0, "lon": 0.0, "reason": reason/'
# M2: a "harmless" fallback when no database is installed.
mutate "locate() invents a position when no database is installed" \
       's/return _unlocated("no-geoip-database")/return {"located": True, "country": "XX", "latitude": 0.0, "longitude": 0.0}/'
# M3: the classic one — the database shrugs, so the code uses a centroid.
mutate "locate() falls back to a country centroid on a database gap" \
       's/return _unlocated("not-in-geoip-database")/return {"located": True, "country": "XX", "coordinates": [0.0, 0.0]}/'
# M4: private addresses are quietly treated as geolocatable.
mutate "a corrupt database is reported as a position instead of a failure" \
       's/return _unlocated("geoip-lookup-failed")/return {"located": True, "country": "XX", "lat": 1.0, "lon": 1.0}/'
if python3 "$TMP/invariant.py" "$SRC" >/dev/null 2>&1; then
    pass "the unmutated adapter still passes (the mutations were the only break)"
else
    fail "unmutated adapter" "something above left the source modified"
fi

section "Server honesty: it fails closed, and every refusal names a remedy"
cat > "$TMP/honesty.py" <<'PY'
import json
import sys

sys.path.insert(0, sys.argv[1])
import osint_server as S                                       # noqa: E402

ok = True


def check(cond, label):
    global ok
    print(("    ok   " if cond else "    BAD  ") + label)
    ok = ok and bool(cond)


ROUTE4 = ("Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\n"
          "eth0\t00000000\t0104A8C0\t0003\t0\t0\t100\t00000000\n"
          "eth0\t0004A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\n")
NOROUTE4 = ("Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\n"
            "eth0\t0004A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\n")

r = S.read_default_route(ROUTE4)
check(r["default_route"] is True and r["interface"] == "eth0",
      "a default route in /proc/net/route is found (%s)" % r)
check(S.read_default_route(NOROUTE4)["default_route"] is False,
      "no default route is reported as none")
check(S.read_default_route("")["default_route"] is False,
      "an empty /proc/net/route is not read as 'connected'")
check("online" not in json.dumps(r),
      "the key is default_route, not 'online' — a route is not reachability")

for text, why in ((None, "missing"), ("", "empty"), ("{garbage", "corrupt"),
                  ('{"tier": "9"}', "unknown tier"), ('{}', "no tier")):
    p = S.read_posture(text)
    check(p["known"] is False and p["outbound_allowed"] is False,
          "%s posture -> unknown, outbound refused (fail closed)" % why)
    check(bool(p["reason"]), "%s posture names why" % why)

p0 = S.read_posture('{"tier": "0", "label": "Tier 0 \\u00b7 Passive"}')
check(p0["known"] and p0["tier"] == "0" and p0["outbound_allowed"] is True,
      "Tier 0 allows outbound")
p1 = S.read_posture('{"tier": "1", "label": "Tier 1"}')
check(p1["outbound_allowed"] is True, "Tier 1 allows outbound")
p2 = S.read_posture('{"tier": "2", "label": "Tier 2 \\u00b7 Deception"}')
check(p2["known"] and p2["outbound_allowed"] is False,
      "Tier 2 (Deception) refuses outbound — decoys are live on a hostile network")

up = {"default_route": True, "interface": "eth0"}
down = {"default_route": False, "interface": None}

v = S.outbound_verdict(p0, up)
check(v["allowed"] is True and v["state"] == "ok", "Tier 0 + route -> links live")
check("not proof" in v["detail"],
      "even the happy path refuses to claim the internet is reachable")

for posture, route, state in ((p2, up, "shields-up"),
                              (p0, down, "no-route"),
                              (S.read_posture(None), up, "posture-unknown"),
                              (S.read_posture(None), down, "posture-unknown")):
    v = S.outbound_verdict(posture, route)
    check(v["allowed"] is False and v["state"] == state,
          "%s -> refused (%s)" % (state, v["state"]))
    # Rule 8: what is not working, the consequence, and the exact remedy.
    check(bool(v["headline"]) and bool(v["detail"]) and bool(v["remedy"]),
          "%s refusal names headline, consequence and remedy" % state)

from pathlib import Path                                        # noqa: E402
g = S.geoip_state(Path("/nonexistent/country.mmdb"), Path("/nonexistent/asn.mmdb"))
check(g["available"] is False, "absent GeoIP reports unavailable")
check(bool(g["reason"]) and bool(g["remedy"]), "absent GeoIP names why and the fix")
check("CC BY 4.0" in g["license"], "the DB-IP attribution requirement is carried in the status")
sys.exit(0 if ok else 1)
PY
if python3 "$TMP/honesty.py" "$SRC"; then
    pass "posture/route/outbound logic fails closed and always names a remedy"
else
    fail "server honesty" "see output above"
fi

rm -rf "$TMP/mut2"; mkdir -p "$TMP/mut2"
cp "$SRC/pewpew_feed.py" "$TMP/mut2/"
sed 's/return {"allowed": False, "state": "posture-unknown",/return {"allowed": True, "state": "posture-unknown",/' \
    "$SRC/osint_server.py" > "$TMP/mut2/osint_server.py"
if cmp -s "$TMP/mut2/osint_server.py" "$SRC/osint_server.py"; then
    fail "mutation applied: unknown posture fails open" "sed changed nothing"
elif python3 "$TMP/honesty.py" "$TMP/mut2" >/dev/null 2>&1; then
    fail "mutation caught: unknown posture fails open" "the honesty check PASSED on broken code"
else
    pass "mutation caught: unknown posture would fail OPEN and enable off-deck links"
fi

section "End to end: the server actually serves all three pages"
cat > "$TMP/posture.json" <<'PJ'
{"tier": "0", "label": "Tier 0 · Passive", "ids_expected": false}
PJ
# The adapter fixture above uses fixed timestamps on purpose (a pure function
# deserves a deterministic input). The server reads the real clock, so the
# HTTP fixture is the same events rebased onto now.
python3 - "$TMP/bus.jsonl" "$TMP/live-bus.jsonl" <<'REBASE'
import json, sys, time
now = time.time()
src = [json.loads(ln) for ln in open(sys.argv[1], encoding="utf-8")
       if ln.strip().startswith("{") and "not json" not in ln]
base = max(e["ts"] for e in src)
with open(sys.argv[2], "w", encoding="utf-8") as out:
    for e in src:
        # Gaps scaled x10 so the narrow-window check below has room:
        # orionx-osint clamps the look-back to a 60s minimum on purpose.
        e["ts"] = now - (base - e["ts"]) * 10.0 - 5.0
        out.write(json.dumps(e) + "\n")
    out.write("{ this line is not json\n")
REBASE

E2E_PORT=$(( 8900 + ($$ % 90) ))
(
  ORIONX_EVENT_LOG="$TMP/live-bus.jsonl" \
  ORIONX_POSTURE_STATUS="$TMP/posture.json" \
  ORIONX_PROC_ROUTE="/dev/null" ORIONX_PROC_ROUTE6="/dev/null" \
  python3 "$SRC/osint_server.py" --root "$WEB" --port "$E2E_PORT" \
          --no-browser >"$TMP/srv.log" 2>&1
) &
E2E_PID=$!
for _ in $(seq 1 40); do grep -q "serving" "$TMP/srv.log" 2>/dev/null && break; sleep 0.25; done
E2E_URL="$(sed -n 's|.*at \(http://127.0.0.1:[0-9]*\)/.*|\1|p' "$TMP/srv.log" | head -1)"
if [[ -n "$E2E_URL" ]]; then pass "server bound loopback at $E2E_URL"
else fail "server bound" "$(head -5 "$TMP/srv.log")"; fi
if grep -q "loopback only" "$TMP/srv.log"; then pass "server states it is loopback-only"
else fail "loopback-only statement"; fi

if [[ -n "$E2E_URL" ]] && python3 - "$E2E_URL" <<'PY'
import json, sys, urllib.request
base = sys.argv[1]
ok = True
def check(cond, label):
    global ok
    print(("    ok   " if cond else "    BAD  ") + label)
    ok = ok and bool(cond)

def get(path):
    with urllib.request.urlopen(base + path, timeout=10) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()

for path, needle in (("/", b"Workbench"),
                     ("/app.js", b"DEC-PHASE12-043"),
                     ("/links.json", b"bellingcat"),
                     ("/recipes.json", b"Defang"),
                     ("/cyberchef/", b"CyberChef"),
                     ("/cyberchef/assets/main.js", b"module"),
                     ("/pewpew/", b"Attack Map"),
                     ("/pewpew/map.js", b"SCOPE_SECTORS"),
                     ("/pewpew/pew.mp3", b"")):
    try:
        status, ctype, body = get(path)
    except Exception as exc:                                   # noqa: BLE001
        check(False, "%s -> %s" % (path, exc)); continue
    check(status == 200 and (not needle or needle.lower() in body.lower()),
          "%s -> 200, %d bytes" % (path, len(body)))

status, ctype, body = get("/api/status.json")
st = json.loads(body)
check(status == 200 and ctype.startswith("application/json"), "/api/status.json is JSON")
check(st["posture"]["tier"] == "0" and st["posture"]["known"] is True,
      "status reports the posture it was given")
check(st["route"]["default_route"] is False,
      "an empty /proc/net/route yields default_route false")
check(st["outbound"]["allowed"] is False and st["outbound"]["state"] == "no-route",
      "with no route the server refuses to enable off-deck links")
check(bool(st["outbound"]["remedy"]), "the refusal carries a remedy")
check("deck" in st and "hostname" in st["deck"] and "cpu_pct" in st["deck"] and "interfaces" in st["deck"],
      "status carries deck vitals from the shared module (DEC-PHASE12-049)")

status, ctype, body = get("/api/pewpew.json?window=900")
feed = json.loads(body)
check(feed["bus_readable"] is True, "the fixture bus is read over HTTP")
check(feed["counts"]["sources"] == 4, "4 sources served (%d)" % feed["counts"]["sources"])
raw = body.decode("utf-8")
for key in ('"lat"', '"lon"', '"latitude"', '"longitude"', '"coordinates"'):
    check(key not in raw, "served feed contains no %s key" % key)
check('"located": false' in raw.replace(", ", ", ") or '"located":false' in raw,
      "served feed marks sources unlocated explicitly")

status, _, body = get("/api/pewpew.json?window=300")
narrow = json.loads(body)
check(narrow["counts"]["sources"] == 1,
      "the window query parameter is honoured: 300s leaves %d of the 4 sources"
      % narrow["counts"]["sources"])
status, _, body = get("/api/pewpew.json?window=1")
check(json.loads(body)["window_seconds"] == 60.0,
      "an absurd window is clamped, not obeyed")
sys.exit(0 if ok else 1)
PY
then pass "all three pages, both APIs and the vendored assets serve over loopback"
else fail "end-to-end serve" "see output above"; fi
kill "$E2E_PID" 2>/dev/null; wait "$E2E_PID" 2>/dev/null

section "Wiring: menu, desktop launcher, hook, package list"
APPS="$CH/usr/share/applications"
for d in orionx-osint orionx-cyberchef orionx-attack-map; do
    f="$APPS/$d.desktop"
    if [[ -f "$f" ]] && grep -q '^Categories=X-Orion;$' "$f"; then
        pass "$d.desktop is in the Orion menu group (Categories=X-Orion;)"
    else fail "$d.desktop Categories" "missing or not X-Orion"; fi
    if grep -q '^Exec=/usr/bin/orionx-osint' "$f" 2>/dev/null; then
        pass "$d.desktop launches the shipped entrypoint"
    else fail "$d.desktop Exec" "does not launch /usr/bin/orionx-osint"; fi
done
if grep -q -- '--page cyberchef' "$APPS/orionx-cyberchef.desktop" && \
   grep -q -- '--page pewpew' "$APPS/orionx-attack-map.desktop"; then
    pass "the CyberChef and map entries open their own page directly"
else fail "page-specific .desktop Exec flags"; fi
if grep -q 'etc/skel/Desktop' "$HOOK" && grep -q 'chmod 0755 "\$SKEL' "$HOOK"; then
    pass "0710 derives an executable desktop launcher into /etc/skel/Desktop"
else fail "desktop launcher" "0710 does not derive /etc/skel/Desktop/orionx-osint.desktop"; fi
if [[ -e "$CH/etc/skel/Desktop/orionx-osint.desktop" ]]; then
    fail "desktop launcher is derived, not duplicated" \
         "a second copy is checked in; it will drift from the menu entry"
else
    pass "desktop launcher is derived at build time, not a checked-in duplicate"
fi
if grep -qE 'ln -sf.*/usr/bin/' "$HOOK"; then
    fail "single authority: 0710 does not create /usr/bin symlinks" \
         "0700-orionx-setup owns PATH symlinks"
else
    pass "single authority: 0710 creates no /usr/bin symlink (0700 owns those)"
fi
if printf '%s\n%s\n%s\n' 0700-orionx-setup.hook.chroot 0710-osint-surface.hook.chroot 0800-orionx-branding.hook.chroot | sort -c 2>/dev/null; then
    pass "0710 sorts after 0700 and before 0800"
else fail "hook ordering"; fi
if grep -qx 'python3-maxminddb' "$REPO_ROOT/iso/config/package-lists/orionx.list.chroot"; then
    pass "python3-maxminddb (the reader) is on the image; the database is not"
else fail "python3-maxminddb in the package list"; fi

section "No drift between the authorities"
if python3 - "$REPO_ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts/osint"))
sys.path.insert(0, os.path.join(root, "scripts/rain"))
import pewpew_feed as F                                        # noqa: E402
import rain_lib                                                # noqa: E402
web = os.path.join(root, "iso/config/includes.chroot/opt/orionx/osint")
inst = open(os.path.join(root, "iso/config/includes.chroot/opt/orionx/optional/install-geoip.sh"),
            encoding="utf-8").read()
prov = open(os.path.join(web, "cyberchef/PROVENANCE.txt"), encoding="utf-8").read()
recipes = json.load(open(os.path.join(web, "recipes.json"), encoding="utf-8"))
links = json.load(open(os.path.join(web, "links.json"), encoding="utf-8"))
geotxt = open(os.path.join(web, "GEOIP.txt"), encoding="utf-8").read()
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

check(F.EVENT_LOG == str(rain_lib.EVENT_LOG),
      "the map reads the same bus rain_lib declares (%s)" % F.EVENT_LOG)
check(F.SEVERITIES == rain_lib.SEVERITIES,
      "severity vocabulary matches rain_lib exactly")
check(os.path.dirname(F.GEOIP_COUNTRY_DB) in inst,
      "install-geoip.sh writes where the adapter looks (%s)" % F.GEOIP_DIR)
check(os.path.basename(F.GEOIP_COUNTRY_DB) in inst,
      "the country database filename matches")
check(os.path.basename(F.GEOIP_ASN_DB) in inst, "the ASN database filename matches")
check(F.GEOIP_REMEDY.split()[-1] in inst or "install-geoip.sh" in F.GEOIP_REMEDY,
      "the remedy string names the installer that exists")
check(F.GEOIP_REMEDY in geotxt, "GEOIP.txt quotes the same remedy command")
geo_entry = [i for i in links["installable"] if i["id"] == "geoip"]
check(bool(geo_entry) and geo_entry[0]["command"] == F.GEOIP_REMEDY,
      "links.json offers the same command the adapter tells people to run")
m = re.search(r"Release:\s+v([0-9.]+)", prov)
check(bool(m) and recipes["cyberchef_version"] == m.group(1),
      "recipes.json and PROVENANCE agree on the CyberChef version")
app = open(os.path.join(web, "app.js"), encoding="utf-8").read()
check(("CyberChef " + recipes["cyberchef_version"]) in app,
      "the launcher footer states the version that is actually vendored")
cc = [i for i in links["local"] if i["id"] == "cyberchef"]
check(bool(cc) and recipes["cyberchef_version"] in cc[0]["name"],
      "links.json names the vendored CyberChef version")
check("CC BY 4.0" in inst and "db-ip.com" in inst,
      "the installer carries the DB-IP attribution the licence requires")
check("creativecommons.org/licenses/by/4.0" in inst or "CC BY 4.0" in inst,
      "CC BY 4.0 is named in the installer")
sys.exit(0 if ok else 1)
PY
then pass "no drift between adapter, installer, catalogue, provenance and rain_lib"
else fail "drift between authorities" "see output above"; fi

section "Lint"
if command -v ruff >/dev/null 2>&1; then
    if ruff check --no-cache "$SRC" "$CH/usr/bin/orionx-osint" >"$TMP/ruff.log" 2>&1; then
        pass "ruff check clean"
    else fail "ruff check" "$(head -5 "$TMP/ruff.log")"; fi
else
    pass "ruff not installed on this host (skipped)"
fi
for f in "$HOOK" "$CH/opt/orionx/optional/install-geoip.sh" "${BASH_SOURCE[0]}"; do
    if bash -n "$f" 2>"$TMP/bashn.log"; then pass "bash -n: $(basename "$f")"
    else fail "bash -n: $(basename "$f")" "$(head -3 "$TMP/bashn.log")"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$HOOK" "$CH/opt/orionx/optional/install-geoip.sh" "${BASH_SOURCE[0]}" >"$TMP/sc.log" 2>&1; then
        pass "shellcheck -S warning clean"
    else fail "shellcheck -S warning" "$(head -8 "$TMP/sc.log")"; fi
else
    pass "shellcheck not installed on this host (skipped)"
fi
if python3 -c "import ast,sys; [ast.parse(open(p,encoding='utf-8').read()) for p in sys.argv[1:]]" \
     "$SRC/pewpew_feed.py" "$SRC/osint_server.py" "$CH/usr/bin/orionx-osint"; then
    pass "python sources parse"
else fail "python sources parse"; fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
