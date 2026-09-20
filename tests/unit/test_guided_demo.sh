#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_guided_demo.sh — guided walkthrough tooling + artefacts (DEC-PHASE12-018)
#
# scenes.yaml is the single source for narration/captions/transcript; the
# builder derives the MP4 + VTT + transcript + poster from it. This locks the
# contract (every scene maps to a recorder, narration is honest about beta and
# synthetic feeds), the tooling compiles, and the published artefacts for the
# current version exist, agree with each other, and are embedded in the README.
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
python3 -m py_compile "$D/build_demo.py" "$D/fake-ollama.py" 2>/dev/null && pass "python tooling compiles" || fail "py_compile" "failed"
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
if "beta" not in text: errs.append("narration never says 'beta'")
if "synthetic" not in text and "demo" not in text: errs.append("cockpit feed not disclosed as synthetic/demo")
if not cfg.get("version", "").startswith("v"): errs.append("version must start with v")
if not cfg.get("release_url", "").startswith("https://github.com/jarocki/orion/releases/tag/"): errs.append("release_url wrong")
print("\n".join(errs) if errs else cfg["version"])
PY
)"
if [[ "$VERSION" == v* && "$VERSION" != *$'\n'* ]]; then pass "every scene has id/visual/heading/narration, a recorder exists, narration says 'beta' and discloses the demo feed ($VERSION)"; else fail "scenes.yaml contract" "$VERSION"; fi

section "published artefacts (docs/media)"
BASE="$M/orionx-guided-demo-$VERSION"
for ext in .mp4 .vtt -transcript.md -poster.png; do
    [[ -s "$BASE$ext" ]] && pass "$(basename "$BASE$ext") exists" || fail "$(basename "$BASE$ext")" "missing/empty"
done
if [[ -s "$BASE.mp4" ]]; then
    SZ=$(stat -f %z "$BASE.mp4" 2>/dev/null || stat -c %s "$BASE.mp4")
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
# Transcript text must be the scenes.yaml narration (derived, not hand-edited).
python3 - "$D/scenes.yaml" "$BASE-transcript.md" <<'PY' && pass "transcript narration == scenes.yaml narration" || fail "transcript drift" "transcript text differs from scenes.yaml"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])); md = open(sys.argv[2]).read()
missing = [s["id"] for s in cfg["scenes"] if s["narration"].strip() not in md]
sys.exit(1 if missing else 0)
PY

section "README embed"
grep -q "orionx-guided-demo-$VERSION-poster.png" "$REPO_ROOT/README.md" && grep -q "orionx-guided-demo-$VERSION.mp4" "$REPO_ROOT/README.md" \
    && pass "README links poster → MP4 for $VERSION" || fail "README embed" "poster/mp4 links missing"
grep -q "orionx-guided-demo-$VERSION.vtt" "$REPO_ROOT/README.md" && grep -q "orionx-guided-demo-$VERSION-transcript.md" "$REPO_ROOT/README.md" \
    && pass "README links captions + transcript" || fail "README links" "vtt/transcript missing"

printf "\n===========================================\n"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -eq 0 ]]
