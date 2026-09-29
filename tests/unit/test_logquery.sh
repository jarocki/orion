#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_logquery.sh — orionx-logquery forensic correlation (DEC-PHASE12-027)
#
# scanwatch (DEC-PHASE12-022) can tell the operator that one host touched 900
# ports. It cannot tell them whether that host is singling this deck out.
# logquery answers that from the operator's own history. These tests cover the
# four sources, the credential-free local path, intel freshness and its stale
# warning, the targeted-vs-widespread correlation on fixtures, graceful
# degradation when an optional dependency is missing, that no secret material
# reaches any output, and the build wiring.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

GREEN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'; NC='\033[0m'
PASS=0; FAIL=0; PEND=0
PENDING_NOTES=()
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
# pending() marks a check that this slice cannot satisfy on its own because it
# asserts an entry in a centrally-integrated build hook. It is reported loudly
# and listed again at the end, but it does not fail the suite: a red suite for
# work that belongs to the integrator teaches people to ignore red.
pending() {
    PEND=$((PEND+1))
    PENDING_NOTES+=("$1 — $2")
    printf "  ${YEL}PEND${NC}: %s — %s\n" "$1" "$2"
}
section() { printf "\n[%s]\n" "$1"; }

LQ_DIR="$REPO_ROOT/scripts/logquery"
LQ="$LQ_DIR/orionx-logquery"
FRESHEN="$LQ_DIR/orionx-freshen-intel"
CHROOT="$REPO_ROOT/iso/config/includes.chroot"

# Never /tmp: fixtures live under the repo's own tmp/ and are cleaned up.
WORK="$REPO_ROOT/tmp/test_logquery.$$"
mkdir -p "$WORK/intel" "$WORK/evidence"
trap 'rm -rf "$WORK"' EXIT

export ORIONX_LOGQUERY_INTEL_DIR="$WORK/intel"
export NO_COLOR=1

# --- fixtures ---------------------------------------------------------------
# 198.51.100.7 is the TARGETED source: it browsed real pages on one day, came
# back on another to probe, and the path it probed is one almost nothing else
# here asked for. The four 203.0.113.5x hosts are WIDESPREAD: each hit the same
# very common path once. 192.0.2.9 is a research scanner and must be
# downweighted, not hidden.
cat > "$WORK/evidence/access.log" <<'EOF'
198.51.100.7 - - [20/Sep/2026:08:00:01 +0000] "GET /index.html HTTP/1.1" 200 5120 "-" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
198.51.100.7 - - [20/Sep/2026:08:00:09 +0000] "GET /about.html HTTP/1.1" 200 2048 "http://example.org/" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
198.51.100.7 - - [22/Sep/2026:03:14:00 +0000] "GET /remote/fgt_lang HTTP/1.1" 404 0 "-" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
198.51.100.7 - - [22/Sep/2026:03:14:30 +0000] "GET /.env HTTP/1.1" 404 0 "-" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
203.0.113.50 - - [21/Sep/2026:11:00:00 +0000] "GET /.env HTTP/1.1" 404 0 "-" "curl/8.5.0"
203.0.113.51 - - [21/Sep/2026:11:00:05 +0000] "GET /.env HTTP/1.1" 404 0 "-" "curl/8.5.0"
203.0.113.52 - - [21/Sep/2026:11:00:10 +0000] "GET /.env HTTP/1.1" 404 0 "-" "curl/8.5.0"
203.0.113.53 - - [21/Sep/2026:11:00:15 +0000] "GET /.env HTTP/1.1" 404 0 "-" "curl/8.5.0"
192.0.2.9 - - [21/Sep/2026:12:00:00 +0000] "GET /wp-login.php HTTP/1.1" 404 0 "-" "CensysInspect/1.1"
EOF

# Mixed evidence in the same directory: an nftables drop log and a bus spool.
{
  for p in $(seq 4000 4029); do
    echo "Sep 22 03:20:00 orionx kernel: [ORIONX-DROP] IN=eth0 SRC=198.51.100.7 DST=10.0.0.1 LEN=44 PROTO=TCP SPT=40000 DPT=$p SYN URGP=0"
  done
} > "$WORK/evidence/kern.log"

cat > "$WORK/evidence/events.jsonl" <<'EOF'
{"ts": 1790000000, "iso": "2026-09-22T03:21:00+0000", "severity": "warning", "source": "firewall", "category": "scan", "message": "port scan from 198.51.100.7 — 30 ports in 12s"}
EOF

section "Structure"
for f in orionx-logquery logquery_sources.py logquery_intel.py \
         logquery_correlate.py logquery_engine.py orionx-freshen-intel \
         intel-base.json; do
    if [[ -f "$LQ_DIR/$f" ]]; then pass "$f present"; else fail "$f present" "missing"; fi
done
if [[ -x "$LQ" ]]; then pass "orionx-logquery executable"; else fail "orionx-logquery executable"; fi
if [[ -x "$FRESHEN" ]]; then pass "orionx-freshen-intel executable"; else fail "orionx-freshen-intel executable"; fi
if head -1 "$LQ" | grep -q python3; then pass "python3 shebang"; else fail "python3 shebang"; fi
MISSING_DEC=""
for f in "$LQ_DIR"/*.py "$LQ" "$FRESHEN" "$LQ_DIR/intel-base.json" \
         "$CHROOT/opt/orionx/optional/install-duckdb.sh"; do
    grep -q 'DEC-PHASE12-027' "$f" || MISSING_DEC="$MISSING_DEC $(basename "$f")"
done
if [[ -z "$MISSING_DEC" ]]; then pass "every new file carries DEC-PHASE12-027"
else fail "every new file carries DEC-PHASE12-027" "missing in:$MISSING_DEC"; fi
if python3 -c "import json,sys; json.load(open('$LQ_DIR/intel-base.json'))" 2>/dev/null
then pass "intel-base.json is valid JSON"; else fail "intel-base.json is valid JSON"; fi
if ! grep -qE '"kev"|knownRansomware' "$LQ_DIR/intel-base.json"; then
    pass "no KEV snapshot committed (the volatile half is fetched, not shipped)"
else fail "no KEV snapshot committed" "a committed catalog would rot silently"; fi

section "Sources — all four selectable, local needs nothing"
HELP="$(python3 "$LQ" --help 2>&1)"
for s in local r2 s3 api; do
    if echo "$HELP" | grep -q "$s"; then pass "--source $s offered"; else fail "--source $s offered"; fi
done
if echo "$HELP" | grep -q 'default: local'; then pass "local is the default source"
else fail "local is the default source" "the credential-free path must be the default"; fi

# The load-bearing one: a real report off a real file with NOTHING configured.
CLEANENV=(env -u R2_ACCOUNT_ID -u R2_ACCESS_KEY_ID -u R2_SECRET_ACCESS_KEY
          -u R2_BUCKET -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY
          -u S3_BUCKET -u HOME NO_COLOR=1
          "ORIONX_LOGQUERY_INTEL_DIR=$ORIONX_LOGQUERY_INTEL_DIR")
OUT="$("${CLEANENV[@]}" python3 "$LQ" --path "$WORK/evidence/access.log" \
        --report sources --format csv 2>"$WORK/err.txt")"
if [[ $? -eq 0 ]] && echo "$OUT" | grep -q '198.51.100.7'; then
    pass "local file reports with zero credentials and no HOME"
else fail "local file reports with zero credentials" "$(cat "$WORK/err.txt")"; fi

OUT="$(python3 "$LQ" --path "$WORK/evidence" --report summary --format csv 2>/dev/null)"
if echo "$OUT" | grep -q 'firewall_drop'; then
    pass "a directory of mixed evidence is read (CLF + drop log + bus)"
else fail "directory of mixed evidence" "$OUT"; fi
if echo "$OUT" | grep -q 'normal'; then pass "access-log records parsed from the same directory"
else fail "access-log records parsed from the same directory" "$OUT"; fi

OUT="$(cat "$WORK/evidence/access.log" | python3 "$LQ" --path - --report sources --format csv 2>/dev/null)"
if echo "$OUT" | grep -q '198.51.100.7'; then pass "stdin is a local source"
else fail "stdin is a local source" "$OUT"; fi

for s in r2 s3; do
    ERR="$("${CLEANENV[@]}" python3 "$LQ" --source "$s" --report summary 2>&1)"
    if echo "$ERR" | grep -qi 'missing credential'; then
        pass "$s without credentials fails with a named-variable message"
    else fail "$s without credentials names the variables" "$ERR"; fi
    if echo "$ERR" | grep -q -- '--path'; then
        pass "$s failure points the operator back at the local path"
    else fail "$s failure points at the local path" "$ERR"; fi
done
ERR="$(python3 "$LQ" --source api --report summary 2>&1)"
if echo "$ERR" | grep -q -- '--api-url'; then pass "api source requires --api-url"
else fail "api source requires --api-url" "$ERR"; fi

section "Intel freshness — age is always stated, staleness is never silent"
if python3 - "$LQ_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import logquery_intel as I

ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

NOW = 1_800_000_000.0
DAY = 86400.0

f = I.intel_freshness(None, NOW)
check(f["state"] == "missing" and f["warn"], f"never fetched -> missing+warn ({f['state']})")

f = I.intel_freshness(NOW - 2 * DAY, NOW)
check(f["state"] == "fresh" and not f["warn"], f"2 days old -> fresh, no warning ({f['state']})")

f = I.intel_freshness(NOW - 14 * DAY, NOW)
check(f["state"] == "aging" and not f["warn"], f"14 days old -> aging ({f['state']})")

# The load-bearing assertion: old intel MUST be classed stale and MUST warn.
f = I.intel_freshness(NOW - 45 * DAY, NOW)
check(f["state"] == "stale", f"45 days old -> stale ({f['state']})")
check(f["warn"] is True, "a stale cache sets warn=True")
check(abs(f["age_days"] - 45.0) < 0.01, f"age is reported in days ({f['age_days']})")

# Boundaries, so the thresholds are the documented ones and not off by a day.
check(I.intel_freshness(NOW - 7 * DAY, NOW)["state"] == "fresh", "7 days is still fresh")
check(I.intel_freshness(NOW - 7.5 * DAY, NOW)["state"] == "aging", "just over 7 days is aging")
check(I.intel_freshness(NOW - 30 * DAY, NOW)["state"] == "aging", "30 days is aging")
check(I.intel_freshness(NOW - 31 * DAY, NOW)["state"] == "stale", "31 days is stale")

# A skewed clock must not be able to make old intel look current.
f = I.intel_freshness(NOW + 10 * DAY, NOW)
check(f["state"] == "undated" and f["warn"], f"future fetch time -> undated+warn ({f['state']})")

# The banner an operator actually reads has to say the word.
banner = I.freshness_banner(I.intel_freshness(NOW - 45 * DAY, NOW), 1300)
check("STALE" in banner, f"stale banner says STALE: {banner[:60]}")
check("45.0" in banner, "stale banner states the age in days")
check("orionx-freshen-intel" in banner, "stale banner names the fix")
banner = I.freshness_banner(I.intel_freshness(None, NOW))
check("NONE FETCHED" in banner, "missing banner says NONE FETCHED")
sys.exit(0 if ok else 1)
PY
then pass "freshness classification and banners"; else fail "freshness classification and banners" "see above"; fi

# A catalog on disk with no recorded fetch time must be UNDATED, not assumed
# current. This is the silent-degradation case the whole design exists for.
printf '{"CVE-2018-13379": {"ransomware": true}}\n' > "$WORK/intel/kev.json"
STATUS="$(python3 "$LQ" --intel-status 2>&1)"
if echo "$STATUS" | grep -qi 'undated\|age unknown'; then
    pass "catalog with no recorded fetch time is reported UNDATED"
else fail "catalog with no fetch time is UNDATED" "$STATUS"; fi

# Now record a fetch 95 days ago and confirm it surfaces everywhere.
python3 - "$LQ_DIR" "$WORK/intel" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import logquery_intel as I
d = sys.argv[2]
I.write_metadata(d, "https://example.invalid/kev.json",
                 I.sha256_file(d + "/kev.json"), 1, "test",
                 now=time.time() - 95 * 86400)
PY
STATUS="$(python3 "$LQ" --intel-status 2>&1)"
if echo "$STATUS" | grep -q 'STALE'; then pass "--intel-status reports a 95-day cache as STALE"
else fail "--intel-status reports STALE" "$STATUS"; fi
python3 "$LQ" --intel-status >/dev/null 2>&1
if [[ $? -ne 0 ]]; then pass "--intel-status exits non-zero when intel is degraded"
else fail "--intel-status exits non-zero when degraded" "a script must be able to detect this"; fi

RUN="$(python3 "$LQ" --path "$WORK/evidence/access.log" --report threats 2>&1 >/dev/null)"
if echo "$RUN" | grep -q 'STALE'; then pass "every run's banner states the stale intel"
else fail "run banner states stale intel" "$RUN"; fi
if echo "$RUN" | grep -qi "report 'threats'"; then
    pass "an intel-dependent report warns again at the point of use"
else fail "intel-dependent report warns at point of use" "$RUN"; fi

JSON="$(python3 "$LQ" --path "$WORK/evidence/access.log" --report targeted --format json 2>/dev/null)"
if echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['intel']['state']=='stale' else 1)"
then pass "machine-readable output carries the intel state"
else fail "JSON output carries the intel state" "a script consuming this must see staleness too"; fi

DRY="$(python3 "$LQ" --path "$WORK/evidence/access.log" --report targeted --dry-run 2>&1 >/dev/null)"
if echo "$DRY" | grep -q 'bus:warning/intel'; then
    pass "stale intel is published to the R.A.I.N. bus as a warning"
else fail "stale intel published to the bus" "$DRY"; fi

# Fresh intel must NOT warn — a tool that cries wolf every run gets ignored.
python3 - "$LQ_DIR" "$WORK/intel" <<'PY'
import sys, time
sys.path.insert(0, sys.argv[1])
import logquery_intel as I
d = sys.argv[2]
I.write_metadata(d, "https://example.invalid/kev.json",
                 I.sha256_file(d + "/kev.json"), 1, "test",
                 now=time.time() - 2 * 86400)
PY
RUN="$(python3 "$LQ" --path "$WORK/evidence/access.log" --report summary 2>&1 >/dev/null)"
if echo "$RUN" | grep -q 'intel: fresh'; then pass "a fresh cache reports 'fresh' with its age"
else fail "fresh cache reports fresh" "$RUN"; fi
if ! echo "$RUN" | grep -q 'STALE'; then pass "a fresh cache does not cry wolf"
else fail "fresh cache does not cry wolf" "$RUN"; fi
DRY="$(python3 "$LQ" --path "$WORK/evidence/access.log" --report targeted --dry-run 2>&1 >/dev/null)"
if ! echo "$DRY" | grep -q 'bus:warning/intel'; then
    pass "a fresh cache publishes no staleness warning"
else fail "fresh cache publishes no staleness warning" "$DRY"; fi

# Enrichment must actually use the fetched catalog, or freshness is theatre.
OUT="$(python3 "$LQ" --path "$WORK/evidence/access.log" --report threats --format csv 2>/dev/null)"
if echo "$OUT" | grep -q 'KEV+RANSOMWARE'; then
    pass "the fetched catalog is applied (CVE-2018-13379 -> KEV+RANSOMWARE)"
else fail "fetched catalog is applied" "$OUT"; fi

section "Correlation — targeted vs widespread from the operator's own history"
if python3 - "$LQ_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import logquery_correlate as C
import logquery_intel as I

ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

BROWSER = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
           "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")

def rec(ip, ts, path, status, ua="", reason=None):
    return {"ip": ip, "ts": ts, "path": path, "status": status,
            "userAgent": ua, "referer": "", "method": "GET",
            "reason": reason or ("error" if status >= 400 else "normal"),
            "tier": 1 if status >= 400 else 0, "port": None, "asn": None,
            "asOrganization": None, "country": None, "proto": "http"}

records = [
    # The targeted one: browsed real pages, came back another day, probed a
    # path nothing else here asked for.
    rec("198.51.100.7", "2026-09-20T08:00:01+00:00", "/index.html", 200, BROWSER),
    rec("198.51.100.7", "2026-09-20T08:00:09+00:00", "/about.html", 200, BROWSER),
    rec("198.51.100.7", "2026-09-22T03:14:00+00:00", "/remote/fgt_lang", 404, BROWSER),
    rec("198.51.100.7", "2026-09-22T03:14:30+00:00", "/.env", 404, BROWSER),
    # Widespread background: four hosts, one very common path, one day each.
    rec("203.0.113.50", "2026-09-21T11:00:00+00:00", "/.env", 404, "curl/8.5.0"),
    rec("203.0.113.51", "2026-09-21T11:00:05+00:00", "/.env", 404, "curl/8.5.0"),
    rec("203.0.113.52", "2026-09-21T11:00:10+00:00", "/.env", 404, "curl/8.5.0"),
    rec("203.0.113.53", "2026-09-21T11:00:15+00:00", "/.env", 404, "curl/8.5.0"),
    # A research scanner probing a rare path: must be downweighted.
    rec("192.0.2.9", "2026-09-21T12:00:00+00:00", "/wp-login.php", 404,
        "CensysInspect/1.1"),
]
intel = I.load_intel()  # curated base only; no fetched catalog in play
I.enrich_all(records, intel)
result = C.correlate(records)
by_ip = {r["ip"]: r for r in result["rows"]}

# --- the headline judgement -------------------------------------------------
check(by_ip["198.51.100.7"]["verdict"] == "targeted",
      f"the recurring browse-and-probe source is TARGETED ({by_ip['198.51.100.7']['verdict']})")
for ip in ("203.0.113.50", "203.0.113.51", "203.0.113.52", "203.0.113.53"):
    check(by_ip[ip]["verdict"] == "widespread",
          f"{ip} (one common path, one day) is widespread")
check(by_ip["192.0.2.9"]["verdict"] == "research-scanner",
      f"Censys is identified and downweighted ({by_ip['192.0.2.9']['verdict']})")
check(by_ip["198.51.100.7"]["signal"] > by_ip["203.0.113.50"]["signal"],
      "the targeted source outranks the background noise")
check(result["rows"][0]["ip"] == "198.51.100.7",
      "the targeted source sorts first")

# --- each preserved signal, individually ------------------------------------
t = by_ip["198.51.100.7"]
check(t["browsed_real"] == 1 and t["probed"] == 1,
      "signal: browsed real pages AND probed")
check(t["active_days"] == 2, f"signal: recurrence across days ({t['active_days']})")
check(t["local_rare"] == 1,
      "signal: probed a path rare in THIS corpus (/remote/fgt_lang)")
check(t["intel_uncommon"] == 1, "signal: intel rates a probed path uncommon")
check(by_ip["203.0.113.50"]["local_rare"] == 0,
      "/.env is common here, so it is NOT a local-rarity signal")
check(any("browsed real pages AND probed" in r for r in t["reasons"]),
      "the verdict shows its reasons")
check(any("2 separate days" in r for r in t["reasons"]),
      "recurrence appears in the reasons")

# Corpus rarity is comparative: the SAME path flips from rare to common as the
# corpus grows. This is the thing no external feed can tell the operator.
small = [rec("10.0.0.1", "2026-09-20T00:00:00+00:00", "/odd", 404)]
check(C.correlate(small)["rows"][0]["local_rare"] == 1,
      "a path only one source ever asked for is locally rare")
crowd = [rec(f"10.0.{i//250}.{i%250}", "2026-09-20T00:00:00+00:00", "/odd", 404)
         for i in range(60)]
check(C.correlate(crowd)["rows"][0]["local_rare"] == 0,
      "the same path is NOT rare once 60 sources have asked for it")
check(C.correlate(crowd)["rare_threshold"] >= 6,
      "the rarity cutoff scales with the corpus, not a fixed constant")

# Each weight must be LOAD-BEARING, not merely recorded. Mutation testing
# caught this: zeroing the browsed-real-AND-probed term left every verdict
# unchanged, because the fixture above also scored on rarity and recurrence.
# This source scores on that ONE signal and nothing else, so the weight itself
# is what the assertion is about.
solo = []
for i in range(20):
    solo.append(rec(f"172.16.0.{i}", "2026-09-20T09:00:00+00:00", "/crowded",
                    404, "curl/8.5.0"))
# 172.16.0.0 ALSO browsed a real page: browse-and-probe, and nothing else.
solo.append(rec("172.16.0.0", "2026-09-20T09:00:10+00:00", "/home", 200,
                "curl/8.5.0"))
I.enrich_all(solo, intel)
solo_rows = {r["ip"]: r for r in C.correlate(solo)["rows"]}
bp = solo_rows["172.16.0.0"]
check(bp["local_rare"] == 0 and bp["intel_uncommon"] == 0 and bp["active_days"] == 1,
      "isolating fixture: no rarity, no intel flag, no recurrence")
check(bp["signal"] == 3,
      f"browse-and-probe alone is worth exactly 3 signal ({bp['signal']})")
check(bp["verdict"] == "worth-a-look",
      f"browse-and-probe alone lifts a source above background ({bp['verdict']})")
check(solo_rows["172.16.0.1"]["signal"] == 0,
      "a neighbour that only probed the crowded path scores 0")

# A single drive-by must never reach 'targeted'.
drive_by = [rec("10.9.9.9", "2026-09-20T00:00:00+00:00", "/.env", 404, "curl/8")]
check(C.correlate(drive_by)["rows"][0]["verdict"] != "targeted",
      "one probe from one host on one day is not 'targeted'")

# Port-scan evidence (what scanwatch sees) folds into the same judgement.
scan = [{"ip": "198.51.100.7", "ts": f"2026-09-22T03:20:{i%60:02d}+00:00",
         "path": f"port:{4000+i}", "port": 4000 + i, "status": None,
         "reason": "firewall_drop", "tier": 2, "userAgent": None,
         "referer": None, "method": "DROP", "asn": None,
         "asOrganization": None, "country": None, "proto": "tcp"}
        for i in range(30)]
I.enrich_all(scan, intel)
scan_row = C.correlate(records + scan)["rows"][0]
check(scan_row["ip"] == "198.51.100.7" and scan_row["ports"] == 30,
      f"firewall drops attach to the same source ({scan_row['ports']} ports)")
check(any("distinct blocked ports" in r for r in scan_row["reasons"]),
      "the port sweep is named among the reasons")

# --- similarity + cadence ---------------------------------------------------
sim = C.similarity(records, "203.0.113.50")
check(sim["found"] and len(sim["matches"]) >= 3,
      f"similarity clusters the four background hosts ({len(sim['matches'])})")
check(any("user-agent" in f for m in sim["matches"] for f in m["features"]),
      "similarity says WHICH behaviours matched")
check(len(sim["inactive_axes"]) == 2,
      "similarity declares its inactive axes every run")
check(C.similarity(records, "10.255.255.1")["found"] is False,
      "an unseen seed is reported as unseen, not as 'no cluster'")

regular = [rec("10.1.1.1", f"2026-09-20T00:{i:02d}:00+00:00", "/x", 200)
           for i in range(10)]
rows = {r["ip"]: r for r in C.cadence(regular)}
check(rows["10.1.1.1"]["machine_regular"] is True,
      "perfectly even spacing is flagged machine-regular")
sys.exit(0 if ok else 1)
PY
then pass "correlation assertions"; else fail "correlation assertions" "see output above"; fi

OUT="$(python3 "$LQ" --path "$WORK/evidence" --report targeted 2>/dev/null)"
if echo "$OUT" | grep -q 'targeted .*198.51.100.7'; then
    pass "end-to-end: the targeted verdict reaches the operator's screen"
else fail "end-to-end targeted verdict" "$OUT"; fi
if echo "$OUT" | grep -q 'not that you are safe'; then
    pass "the report states that 'widespread' is not a clean bill of health"
else fail "report states absence-of-evidence caveat" "$OUT"; fi

section "Focus"
OUT="$(python3 "$LQ" --path "$WORK/evidence/access.log" --focus 203.0.113.0/24 --report sources --format csv 2>/dev/null)"
if echo "$OUT" | grep -q '203.0.113.5' && ! echo "$OUT" | grep -q '198.51.100.7'; then
    pass "--focus CIDR narrows the corpus"
else fail "--focus CIDR narrows the corpus" "$OUT"; fi
OUT="$(python3 "$LQ" --path "$WORK/evidence/access.log" --focus path:/.env --report sources --format csv 2>/dev/null)"
if [[ "$(echo "$OUT" | grep -c '^[0-9]')" -eq 5 ]]; then pass "--focus path selects the five .env requesters"
else fail "--focus path" "$OUT"; fi
ERR="$(python3 "$LQ" --path "$WORK/evidence/access.log" --focus 'not-an-ioc!' --report summary 2>&1 >/dev/null)"
if echo "$ERR" | grep -q 'unrecognized --focus token'; then
    pass "an unparseable focus token warns rather than silently matching all"
else fail "unparseable focus token warns" "$ERR"; fi

section "Graceful degradation when an optional dependency is missing"
# The default engine is stdlib, so a report must never depend on an install.
if grep -q 'DEFAULT_ENGINE = "sqlite"' "$LQ_DIR/logquery_engine.py"; then
    pass "the default engine is stdlib sqlite"
else fail "default engine is stdlib sqlite" "an IR tool must not need a package"; fi
if ! grep -q '"auto"' "$LQ_DIR/logquery_engine.py"; then
    pass "no silent 'auto' engine (which engine ran is always known)"
else fail "no silent auto engine"; fi

# Every preset SQL report must run on the stdlib engine alone.
if python3 - "$LQ_DIR" "$WORK/evidence" <<'PY'
import subprocess, sys
sys.path.insert(0, sys.argv[1])
import logquery_engine as E
bad = []
for report in sorted(E.SQL_REPORTS):
    r = subprocess.run(["python3", sys.argv[1] + "/orionx-logquery",
                        "--path", sys.argv[2], "--report", report,
                        "--engine", "sqlite", "--format", "csv"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        bad.append((report, r.stderr.strip().splitlines()[-1:]))
print(f"  {len(E.SQL_REPORTS) - len(bad)}/{len(E.SQL_REPORTS)} SQL reports run on sqlite alone")
for b in bad:
    print("  BAD  ", b)
sys.exit(1 if bad else 0)
PY
then pass "every preset SQL report runs on stdlib sqlite"; else fail "all SQL reports run on sqlite" "see above"; fi

# The correlation must not need a SQL engine at all.
if python3 - "$LQ_DIR" <<'PY'
import builtins, sys
sys.path.insert(0, sys.argv[1])
real = builtins.__import__
def blocked(name, *a, **k):
    if name.split(".")[0] in ("duckdb", "sqlite3", "boto3", "botocore",
                              "cryptography", "numpy", "pandas"):
        raise ImportError(f"blocked: {name}")
    return real(name, *a, **k)
builtins.__import__ = blocked
for mod in ("logquery_sources", "logquery_intel", "logquery_correlate"):
    __import__(mod)
import logquery_correlate as C
rows = C.correlate([
    {"ip": "1.2.3.4", "ts": "2026-09-20T00:00:00+00:00", "path": "/a",
     "status": 200, "reason": "normal", "userAgent": "x", "referer": "",
     "tier": 0, "port": None, "asn": None, "asOrganization": None,
     "country": None, "method": "GET", "proto": "http"}])["rows"]
print(f"  correlation ran with duckdb/sqlite3/boto3/cryptography unimportable "
      f"-> {len(rows)} row(s)")
sys.exit(0 if len(rows) == 1 else 1)
PY
then pass "correlation works with every optional dependency unimportable"
else fail "correlation without optional deps" "see above"; fi

# Asking for a missing engine must give a sentence, not a traceback.
cat > "$WORK/block_duckdb.py" <<'PY'
import runpy
import sys


class Blocker:
    def find_module(self, name, path=None):
        return self if name == "duckdb" else None

    def load_module(self, name):
        raise ImportError("no module named duckdb")

    def find_spec(self, name, path=None, target=None):
        if name == "duckdb":
            raise ImportError("no module named duckdb")
        return None


sys.meta_path.insert(0, Blocker())
cli, evidence = sys.argv[1], sys.argv[2]
sys.argv = ["orionx-logquery", "--path", evidence, "--report", "summary",
            "--engine", "duckdb"]
try:
    runpy.run_path(cli, run_name="__main__")
except SystemExit:
    pass
PY
ERR="$(python3 "$WORK/block_duckdb.py" "$LQ" "$WORK/evidence/access.log" 2>&1)"
if echo "$ERR" | grep -q 'install-duckdb.sh'; then
    pass "a missing duckdb names the optional installer"
else fail "missing duckdb names the installer" "$ERR"; fi
if echo "$ERR" | grep -qi 'sqlite'; then
    pass "a missing duckdb points at the stdlib engine that already works"
else fail "missing duckdb points at sqlite" "$ERR"; fi
if ! echo "$ERR" | grep -q 'Traceback'; then pass "a missing duckdb produces no traceback"
else fail "missing duckdb produces no traceback" "$ERR"; fi

ERR="$(python3 "$LQ" --source r2 --report summary --env "$WORK/nonexistent.env" 2>&1)"
if ! echo "$ERR" | grep -q 'Traceback'; then pass "a missing credentials file produces no traceback"
else fail "missing credentials file produces no traceback" "$ERR"; fi

if grep -q 'regex_available' "$LQ_DIR/logquery_engine.py" && \
   grep -q 'SQL_NEEDS_REGEX' "$LQ_DIR/logquery_engine.py"; then
    pass "an engine that cannot register re_match refuses rather than answering wrongly"
else fail "re_match availability is tracked" "a dropped WHERE clause is a wrong answer"; fi

section "Secrets — nothing sensitive reaches output, logs, or the repo"
SECRET="S3CRETACCESSKEYDONOTLEAK"
TOKEN="BEARERTOKENDONOTLEAK"
mkdir -p "$WORK/creds"
cat > "$WORK/creds/r2.env" <<EOF
R2_ACCOUNT_ID=acct123
R2_ACCESS_KEY_ID=AKIADONOTLEAK
R2_SECRET_ACCESS_KEY=$SECRET
R2_BUCKET=sealed
EOF
chmod 600 "$WORK/creds/r2.env"
printf '%s\n' "$TOKEN" > "$WORK/creds/token.txt"
chmod 600 "$WORK/creds/token.txt"

ALL="$(python3 "$LQ" --source r2 --env "$WORK/creds/r2.env" --report summary 2>&1)
$(python3 "$LQ" --source api --api-url http://127.0.0.1:1/none \
    --api-token-file "$WORK/creds/token.txt" --report summary 2>&1)"
if ! echo "$ALL" | grep -q "$SECRET"; then pass "the R2 secret never appears in output"
else fail "R2 secret never appears in output" "LEAKED"; fi
if ! echo "$ALL" | grep -q "$TOKEN"; then pass "the API bearer token never appears in output"
else fail "API token never appears in output" "LEAKED"; fi
if ! echo "$ALL" | grep -q 'AKIADONOTLEAK'; then pass "the access key id never appears in output"
else fail "access key id never appears in output" "LEAKED"; fi

chmod 644 "$WORK/creds/r2.env"
ERR="$(python3 "$LQ" --source r2 --env "$WORK/creds/r2.env" --report summary 2>&1)"
if echo "$ERR" | grep -q 'group/world accessible'; then pass "a world-readable credentials file is flagged"
else fail "world-readable credentials file is flagged" "$ERR"; fi
chmod 600 "$WORK/creds/r2.env"

if ! grep -rIqE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' "$LQ_DIR"; then
    pass "no key material committed under scripts/logquery/"
else fail "no key material committed" "a key is in the repo"; fi
if grep -q 'load_pem_private_key' "$LQ"; then
    pass "key-based decryption is preserved, not weakened"
else fail "key-based decryption preserved" "the sealed-archive path lost its crypto"; fi
if grep -q 'KEY_PASSPHRASE' "$LQ"; then pass "the key passphrase is still read from the environment"
else fail "key passphrase still supported"; fi
if grep -q 'Never echo the object body' "$LQ_DIR/logquery_sources.py"; then
    pass "decrypt failures are counted, not echoed"
else fail "decrypt failures are counted, not echoed" "an exception can carry ciphertext"; fi
python3 "$LQ" --path "$WORK/evidence/access.log" --keep "$WORK/kept.ndjson" \
    --report summary >/dev/null 2>&1
MODE="$(python3 -c "import os,stat;print(oct(stat.S_IMODE(os.stat('$WORK/kept.ndjson').st_mode)))" 2>/dev/null)"
if [[ "$MODE" == "0o600" ]]; then pass "--keep writes the corpus 0600"
else fail "--keep writes 0600" "got $MODE — retained plaintext must not be world-readable"; fi

section "Sealed archive — the key-based decryption is unchanged"
if python3 -c "import cryptography" 2>/dev/null; then
    if python3 - "$LQ" "$WORK" <<'CRYPTOPY'
import base64, json, os, sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

cli_path, work = sys.argv[1], Path(sys.argv[2])
ok = True
def check(cond, label):
    global ok
    print(("  ok   " if cond else "  BAD  ") + label)
    ok = ok and bool(cond)

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
kp = work / "priv.pem"
kp.write_bytes(key.private_bytes(serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
os.chmod(kp, 0o600)

# Seal a record the way the edge Worker does: AES-256-GCM with the key wrapped
# under RSA-OAEP/SHA-256. If the port had weakened either primitive, or changed
# the envelope field names, this would not round-trip.
record = {"ts": "2026-09-22T03:14:00Z", "ip": "198.51.100.7", "path": "/.env",
          "status": 404, "userAgent": "curl/8.5.0", "reason": "decoy_path",
          "tier": 3}
aes = AESGCM.generate_key(bit_length=256)
iv = os.urandom(12)
ciphertext = AESGCM(aes).encrypt(iv, json.dumps(record).encode(), None)
wrapped = key.public_key().encrypt(aes, padding.OAEP(
    mgf=padding.MGF1(algorithm=hashes.SHA256()),
    algorithm=hashes.SHA256(), label=None))
envelope = {"iv": base64.b64encode(iv).decode(),
            "wrappedKey": base64.b64encode(wrapped).decode(),
            "ciphertext": base64.b64encode(ciphertext).decode()}

cli = SourceFileLoader("lqcli", cli_path).load_module()
check(cli.make_unsealer(kp)(envelope) == record,
      "a sealed record round-trips through the ported unsealer")

other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
op = work / "other.pem"
op.write_bytes(other.private_bytes(serialization.Encoding.PEM,
    serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
os.chmod(op, 0o600)
try:
    cli.make_unsealer(op)(envelope)
    check(False, "the WRONG key decrypted the record")
except Exception as exc:
    check(True, f"the wrong key is rejected ({type(exc).__name__})")

try:
    cli.make_unsealer(work / "no-such-key.pem")
    check(False, "a missing key was accepted")
except Exception as exc:
    check("private key not found" in str(exc),
          "a missing key fails with an actionable message")
sys.exit(0 if ok else 1)
CRYPTOPY
    then pass "sealed-archive crypto assertions"; else fail "sealed-archive crypto" "see above"; fi
else
    pass "python3-cryptography absent — sealed-archive crypto skipped"
fi

section "Bus + build wiring"
if grep -q '"orionx-event"' "$LQ"; then pass "publishes via the orionx-event CLI (same as scanwatch)"
else fail "publishes via the orionx-event CLI"; fi
if grep -q '"--source", "logquery"' "$LQ"; then pass "events are attributed to logquery"
else fail "events are attributed to logquery"; fi
DRY="$(python3 "$LQ" --path "$WORK/evidence" --report targeted --dry-run 2>&1 >/dev/null)"
if echo "$DRY" | grep -q 'bus:.*forensics.*198.51.100.7'; then
    pass "a targeted verdict is published to the bus"
else fail "targeted verdict published to the bus" "$DRY"; fi
QUIET="$(python3 "$LQ" --path "$WORK/evidence" --report targeted 2>&1 >/dev/null)"
if ! echo "$QUIET" | grep -q 'bus:'; then
    pass "nothing is published unless --publish or --dry-run is given"
else fail "no publishing without --publish" "$QUIET"; fi

if echo "$DRY" | grep -q 'detail={'; then
    pass "findings carry structured --detail evidence for the Cockpit drill-down"
else fail "findings carry --detail evidence" "$DRY"; fi
if echo "$DRY" | grep -qE '"recurring": (true|false)' && \
   echo "$DRY" | grep -q '"locally_uncommon_probe"'; then
    pass "the detail carries recurrence and probe-uncommonness"
else fail "detail carries recurrence and uncommonness" "$DRY"; fi
if grep -q '"--detail"' "$LQ"; then pass "uses the orionx-event --detail flag"
else fail "uses the orionx-event --detail flag"; fi
if grep -q -- '--detail' "$REPO_ROOT/scripts/rain/orionx-event"; then
    pass "orionx-event still accepts --detail (the contract holds)"
else fail "orionx-event accepts --detail" "the bus schema changed under us"; fi
if python3 - "$LQ" <<'DETAILPY'
import json, sys
from importlib.machinery import SourceFileLoader
cli = SourceFileLoader("lqcli", sys.argv[1]).load_module()
row = {"ip": "198.51.100.7", "verdict": "targeted", "signal": 8, "hits": 4,
       "active_days": 2, "browsed_real": 1, "probed": 1, "local_rare": 1,
       "rare_paths": ["/remote/fgt_lang"], "intel_uncommon": 1, "spoofed": 0,
       "distinct_paths": 4, "ports": 0, "tools": [], "research_org": "",
       "first_seen": "a", "last_seen": "b", "reasons": ["r1"]}
detail = cli.finding_detail(row)
json.dumps(detail)  # must be serialisable to pass through --detail
missing = [k for k in ("recurring", "browsed_real", "locally_uncommon_probe",
                       "active_days", "signal", "reasons") if k not in detail]
print(f"  detail: recurring={detail['recurring']}, "
      f"locally_uncommon_probe={detail['locally_uncommon_probe']}, "
      f"missing={missing}")
sys.exit(1 if missing else 0)
DETAILPY
then pass "finding_detail() is JSON-serialisable and carries the correlation evidence"
else fail "finding_detail() shape" "see above"; fi

if grep -q 'orionx-scanwatch' "$LQ_DIR/logquery_sources.py"; then
    pass "the drop-line parser is delegated to scanwatch (single authority)"
else fail "drop-line parser delegated to scanwatch"; fi
if ! grep -q "'ORIONX-DROP'\|\"ORIONX-DROP\"" "$LQ_DIR/logquery_sources.py"; then
    pass "no second [ORIONX-DROP] regex in logquery"
else fail "no second ORIONX-DROP regex" "two authorities over one grammar"; fi

INSTALLER="$CHROOT/opt/orionx/optional/install-duckdb.sh"
if [[ -x "$INSTALLER" ]]; then pass "optional DuckDB installer staged and executable"
else fail "optional DuckDB installer staged" "missing $INSTALLER"; fi
if grep -q 'orionx-installer-common.sh' "$INSTALLER"; then
    pass "the installer uses the DEC-PHASE11-011 shared library"
else fail "installer uses the shared library"; fi

# Intel refresh ships as a script on PATH, like orionx-freshen-yara and
# orionx-freshen-suricata — deliberately NOT a systemd unit. A unit that
# pulls network-online.target stalls a disconnected boot (test_offline_boot.sh
# forbids it outright), and a timer would decide on the operator's behalf when
# the deck reaches out, which is the Shields Up decision to make.
UNITDIR="$CHROOT/usr/share/orionx/systemd"
if ! ls "$UNITDIR"/*freshen-intel* >/dev/null 2>&1; then
    pass "no freshen-intel systemd unit (refresh stays operator-invoked)"
else fail "no freshen-intel systemd unit" "a unit reintroduces the boot-stall risk"; fi
# The network-online invariant itself belongs to test_offline_boot.sh, which
# is its single authority. Asserting it again here would be a second copy free
# to drift from the first — so this slice asserts only what is its own: that
# it contributes no unit for that invariant to judge.
if grep -q 'Intel refresh is operator-invoked' "$FRESHEN"; then
    pass "the freshen script records why it is not a unit"
else fail "freshen script records why it is not a unit"; fi
for peer in orionx-freshen-yara.sh orionx-freshen-suricata.sh; do
    if [[ -f "$REPO_ROOT/scripts/$peer" ]]; then
        pass "mirrors the existing $peer convention"
    else fail "peer freshen script $peer present"; fi
done

# The hook files below are integrated centrally and are deliberately NOT
# edited by this slice. These checks are the WIRING contract: they flip from
# PEND to PASS the moment the integrator adds the entries.
H700="$REPO_ROOT/iso/config/hooks/live/0700-orionx-setup.hook.chroot"
H615="$REPO_ROOT/iso/config/hooks/live/0615-install-systemd-units.hook.chroot"
if grep -q 'orionx-logquery' "$H700"; then pass "orionx-logquery symlink registered in 0700 hook"
else pending "orionx-logquery symlink in 0700 hook" \
      '["orionx-logquery"]="/opt/orionx/scripts/logquery/orionx-logquery"'; fi
if grep -q 'orionx-freshen-intel' "$H700"; then pass "orionx-freshen-intel symlink registered in 0700 hook"
else pending "orionx-freshen-intel symlink in 0700 hook" \
      '["orionx-freshen-intel"]="/opt/orionx/scripts/logquery/orionx-freshen-intel"'; fi
# 0615 installs systemd units. This slice ships none, so it needs no entry
# there — and must not acquire one: see the freshen script's annotation.
if ! grep -q 'logquery\|freshen-intel' "$H615"; then
    pass "0615 needs no entry (this slice ships no systemd unit)"
else fail "0615 has a logquery entry" "this slice deliberately ships no unit"; fi

section "Lint"
if command -v ruff >/dev/null 2>&1; then
    cp "$LQ" "$WORK/_cli_lint.py"
    if ruff check "$WORK/_cli_lint.py" "$LQ_DIR"/*.py >/dev/null 2>&1; then pass "ruff clean"
    else fail "ruff clean" "$(ruff check "$WORK/_cli_lint.py" "$LQ_DIR"/*.py 2>&1 | tail -5)"; fi
else
    pass "ruff not installed — skipped"
fi
for s in "$FRESHEN" "$CHROOT/opt/orionx/optional/install-duckdb.sh"; do
    if bash -n "$s" 2>/dev/null; then pass "bash -n: $(basename "$s")"
    else fail "bash -n: $(basename "$s")"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning "$FRESHEN" "$CHROOT/opt/orionx/optional/install-duckdb.sh" \
         "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        pass "shellcheck -S warning clean"
    else fail "shellcheck clean" "$(shellcheck -S warning "$FRESHEN" "$CHROOT/opt/orionx/optional/install-duckdb.sh" "${BASH_SOURCE[0]}" 2>&1 | head -8)"; fi
else
    pass "shellcheck not installed — skipped"
fi

if [[ $PEND -gt 0 ]]; then
    printf "\n[WIRING — pending central integration, not a failure of this slice]\n"
    for note in "${PENDING_NOTES[@]}"; do printf "  ${YEL}PEND${NC}: %s\n" "$note"; done
fi

printf "\n===========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
if [[ $PEND -gt 0 ]]; then
    printf "  (${YEL}%s pending${NC} central hook wiring — see WIRING above)\n" "$PEND"
fi
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
