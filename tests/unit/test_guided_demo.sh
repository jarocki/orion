#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_guided_demo.sh — guided walkthrough tooling + artefacts (DEC-PHASE12-018)
#
# scenes.yaml is the single source for narration/captions/transcript; the
# builder derives the MP4 + VTT + transcript + poster from it. This locks the
# contract (every scene maps to a recorder, narration names the version, is
# honest about synthetic feeds, never says "air-gapped" or sends the viewer to
# a retired surface), the tooling compiles, and the published artefacts the
# README embeds exist and agree with each other.
#
# DEC-PHASE12-132: scenes.yaml may run ahead of the published recording (it is
# the script for the next re-cut). The media checks therefore follow the
# version the README EMBEDS; the transcript must equal scenes.yaml only when
# that version is the scenes.yaml version, and otherwise the README must label
# the embedded video as recorded on its own version (QA round 1 docs F10/F35).
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }
D="$REPO_ROOT/tools/guided-demo"; M="$REPO_ROOT/docs/media"
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/orionx-pyc-$$"

section "tooling"
for f in build.sh container-setup.sh session-start.sh build_demo.py fake-ollama.py; do
    [[ -x "$D/$f" ]] && pass "$f present + executable" || fail "$f" "missing or not executable"
done
[[ -f "$D/scenes.yaml" ]] && pass "scenes.yaml present" || fail "scenes.yaml" "missing"
PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/orionx-pycache" python3 -m py_compile "$D/build_demo.py" "$D/fake-ollama.py" 2>/dev/null && pass "python tooling compiles" || fail "py_compile" "failed"
for f in build.sh container-setup.sh session-start.sh; do bash -n "$D/$f" && pass "$f bash syntax" || fail "$f syntax" "bash -n failed"; done
grep -q "DEC-PHASE12-018" "$D/build_demo.py" && pass "DEC-PHASE12-018 annotated" || fail "annotation" "missing"

section "scenes.yaml contract"
VERSION="$(python3 - "$D/scenes.yaml" "$D/build_demo.py" <<'PY'
import re, sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
src = open(sys.argv[2]).read()
recorders = set(re.findall(r'"([a-z-]+)": scene_', src))
errs = []
ids = [s["id"] for s in cfg["scenes"]]
if len(ids) != len(set(ids)): errs.append("duplicate scene ids")
for s in cfg["scenes"]:
    for k in ("id", "visual", "heading", "narration"):
        if k not in s: errs.append(f"{s.get('id','?')}: missing {k}")
    if s.get("visual") not in recorders: errs.append(f"{s['id']}: no recorder for visual {s.get('visual')!r}")
    if len(s.get("narration", "")) < 80: errs.append(f"{s['id']}: narration too short")
text = " ".join(s["narration"] for s in cfg["scenes"]).lower()
ver = cfg.get("version", "")
spoken = ver.lstrip("v").split("-")[0]
if spoken not in text: errs.append(f"narration never says the version ({spoken})")
for bad in ("air-gapped", "airgapped", "control center", "nothing leaves the deck"):
    if bad in text: errs.append(f"narration says {bad!r} (overstated or retired)")
if "-beta" not in ver and "beta" in text: errs.append("narration calls a final release 'beta'")
if "synthetic" not in text and "demo" not in text: errs.append("cockpit feed not disclosed as synthetic/demo")
if not cfg.get("version", "").startswith("v"): errs.append("version must start with v")
if not cfg.get("release_url", "").startswith("https://github.com/jarocki/orion/releases/tag/"): errs.append("release_url wrong")
print("\n".join(errs) if errs else cfg["version"])
PY
)"
if [[ "$VERSION" == v* && "$VERSION" != *$'\n'* ]]; then pass "every scene has id/visual/heading/narration, a recorder exists, narration names the version, discloses the demo feed, no air-gapped/retired names ($VERSION)"; else fail "scenes.yaml contract" "$VERSION"; fi

section "published artefacts (docs/media) — the recording the README embeds"
# The version whose recording the README embeds (DEC-PHASE12-132).
MEDIA_VERSION="$(grep -oE 'orionx-guided-demo-v[0-9A-Za-z.-]+-poster\.png' "$REPO_ROOT/README.md" | head -1 \
    | sed -E 's/^orionx-guided-demo-//; s/-poster\.png$//')"
if [[ -n "$MEDIA_VERSION" ]]; then pass "README embeds the $MEDIA_VERSION recording"
else fail "README embed" "no orionx-guided-demo-<version>-poster.png link"; MEDIA_VERSION="$VERSION"; fi
BASE="$M/orionx-guided-demo-$MEDIA_VERSION"
for ext in .mp4 .vtt -transcript.md -poster.png; do
    [[ -s "$BASE$ext" ]] && pass "$(basename "$BASE$ext") exists" || fail "$(basename "$BASE$ext")" "missing/empty"
done
if [[ -s "$BASE.mp4" ]]; then
    SZ=$(stat -c %s "$BASE.mp4" 2>/dev/null || stat -f %z "$BASE.mp4")
    [[ $SZ -lt 26214400 ]] && pass "MP4 under 25 MB ($((SZ/1048576)) MB — README-embeddable)" || fail "MP4 size" "$SZ bytes"
    if command -v ffprobe >/dev/null; then
        DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$BASE.mp4" | cut -d. -f1)
        [[ $DUR -ge 90 && $DUR -le 240 ]] && pass "runtime ${DUR}s within 1.5–4 min" || fail "runtime" "${DUR}s"
        LAST=$(grep -E -- '-->' "$BASE.vtt" | tail -1 | awk '{print $3}' | cut -d: -f2,3 | awk -F: '{print int($1*60+$2)}')
        [[ $LAST -le $((DUR+2)) ]] && pass "last caption (${LAST}s) ends within the video" || fail "captions vs video" "last cue ${LAST}s > ${DUR}s"
        [[ "$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$BASE.mp4")" == "audio" ]] && pass "MP4 has a narration track" || fail "audio" "no audio stream"
    fi
fi
head -1 "$BASE.vtt" 2>/dev/null | grep -q '^WEBVTT' && pass "VTT header valid" || fail "VTT" "no WEBVTT header"
grep -q "^# " "$BASE-transcript.md" 2>/dev/null && grep -q "Runtime:" "$BASE-transcript.md" && pass "transcript has title + runtime" || fail "transcript" "format"
if [[ "$MEDIA_VERSION" == "$VERSION" ]]; then
    # Transcript text must be the scenes.yaml narration (derived, not hand-edited).
    python3 - "$D/scenes.yaml" "$BASE-transcript.md" <<'PY' && pass "transcript narration == scenes.yaml narration" || fail "transcript drift" "transcript text differs from scenes.yaml"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])); md = open(sys.argv[2]).read()
missing = [s["id"] for s in cfg["scenes"] if s["narration"].strip() not in md]
sys.exit(1 if missing else 0)
PY
else
    # scenes.yaml is the script for the next re-cut; the embedded recording is
    # an older release and the README must say so rather than pass it off as current.
    if grep -qF "recorded on $MEDIA_VERSION" "$REPO_ROOT/README.md"; then
        pass "README labels the embedded walkthrough as recorded on $MEDIA_VERSION (scenes.yaml is the $VERSION script)"
    else
        fail "README demo label" "embeds the $MEDIA_VERSION recording while scenes.yaml is $VERSION, without saying 'recorded on $MEDIA_VERSION'"
    fi
fi

section "README embed"
grep -q "orionx-guided-demo-$MEDIA_VERSION-poster.png" "$REPO_ROOT/README.md" && grep -q "orionx-guided-demo-$MEDIA_VERSION.mp4" "$REPO_ROOT/README.md" \
    && pass "README links poster → MP4 for $MEDIA_VERSION" || fail "README embed" "poster/mp4 links missing"
grep -q "orionx-guided-demo-$MEDIA_VERSION.vtt" "$REPO_ROOT/README.md" && grep -q "orionx-guided-demo-$MEDIA_VERSION-transcript.md" "$REPO_ROOT/README.md" \
    && pass "README links captions + transcript" || fail "README links" "vtt/transcript missing"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
