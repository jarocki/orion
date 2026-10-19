#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test_guided_demo.sh — the two release videos and their one pipeline
# (DEC-PHASE12-018 → DEC-PHASE12-064, DEC-PHASE13-012 amended).
#
# tools/guided-demo/cinematic/ is the single authority: walkthrough.yaml and
# trailer.yaml hold narration + shots; build_trailer.py derives MP4 + VTT +
# transcript + poster; record_scenes.py / qemu_capture.py record the SHIPPED
# ISO. This suite locks the contract: both scripts parse and name the current
# release, every capture shot names a scene the recorder plan can produce,
# narration is honest (synthetic feed labelled, no "air-gapped", no retired
# surface names, spoken names spelled as pronounced), the tooling compiles,
# and the media the README embeds exist and agree with their scripts.
# ---------------------------------------------------------------------------
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf "  ${GREEN}PASS${NC}: %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "  ${RED}FAIL${NC}: %s — %s\n" "$1" "${2:-}"; }
section() { printf "\n[%s]\n" "$1"; }
C="$REPO_ROOT/tools/guided-demo/cinematic"; M="$REPO_ROOT/docs/media"
export PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/orionx-pyc-$$"
PY=python3
if [[ -x "$REPO_ROOT/tmp/video-venv/bin/python" ]]; then PY="$REPO_ROOT/tmp/video-venv/bin/python"; fi
$PY -c "import yaml" 2>/dev/null || { echo "  SKIP: python yaml module missing — contract checks need it"; exit 0; }

section "tooling"
for f in build_trailer.py record_scenes.py render_music.py; do
    [[ -f "$C/$f" ]] && pass "$f present" || fail "$f" "missing"
done
[[ -f "$REPO_ROOT/tools/guided-demo/qemu_capture.py" ]] && pass "qemu_capture.py present" || fail "qemu_capture.py" "missing"
$PY -m py_compile "$C/build_trailer.py" "$C/record_scenes.py" "$C/render_music.py" "$REPO_ROOT/tools/guided-demo/qemu_capture.py" 2>/dev/null \
    && pass "pipeline compiles" || fail "py_compile" "failed"
for old in build_demo.py build.sh container-setup.sh session-start.sh fake-ollama.py scenes.yaml; do
    [[ -e "$REPO_ROOT/tools/guided-demo/$old" ]] && fail "old recorder removed" "$old is back (DEC-PHASE13-012 amended)" || true
done
pass "old container recorder is gone (one pipeline)"

section "script contracts"
OUT="$($PY - "$C" "$REPO_ROOT" <<'PY'
import re, sys, yaml, pathlib
C, ROOT = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
plan = yaml.safe_load((C / "scenes-rootfs.yaml").read_text())
scenes = {s["id"] for s in plan["scenes"]} | {"boot", "config", "desktop"}   # qemu_capture plan scenes
bad = []
versions = set()
for name in ("walkthrough.yaml", "trailer.yaml"):
    cfg = yaml.safe_load((C / name).read_text())
    versions.add(cfg["version"])
    if not cfg.get("basename"): bad.append(f"{name}: no basename")
    if not re.match(r"^v\d+\.\d+\.\d+", cfg["version"]): bad.append(f"{name}: version {cfg['version']!r}")
    for s in cfg["shots"]:
        k = s["kind"]
        if k == "capture" and s["scene"] not in scenes: bad.append(f"{name}:{s['id']} scene {s['scene']!r} not recorded by any plan")
        if k == "montage":
            for sc in s["scenes"]:
                if sc not in scenes: bad.append(f"{name}:{s['id']} montage scene {sc!r} unknown")
        n = s.get("narration", "")
        low = n.lower()
        for word in ("air-gapped", "control center", "ir tools", "investigation surface"):
            if word in low: bad.append(f"{name}:{s['id']} narration says {word!r}")
        if "orion-x" in low: bad.append(f"{name}:{s['id']} narration spells Orion-X (speak it as 'Orion X')")
        if "r.a.i.n" in low or "godseye" in low: bad.append(f"{name}:{s['id']} narration spells an acronym the voice would misread")
        if re.search(r"\b\d+(\.\d+)?\s*(GB|MB|minutes|seconds)\b", n): bad.append(f"{name}:{s['id']} narration quotes a number ({n[:60]}…)")
    live = [s for s in cfg["shots"] if s.get("scene") == "cockpit-live" and s.get("chapter")]
    if live and not any("demo" in str(s.get("tag", "")).lower() for s in live): bad.append(f"{name}: Cockpit LIVE shot not labelled as the demo feed")
if len(versions) != 1: bad.append(f"scripts disagree on version: {versions}")
print("\n".join(bad) if bad else "ok " + versions.pop())
PY
)"
if [[ "$OUT" == ok* ]]; then pass "both scripts parse, name one version (${OUT#ok }), map to recorded scenes, speak honestly"; VERSION="${OUT#ok }"
else fail "script contract" "$OUT"; VERSION=""; fi

section "media the README embeds"
for base in orionx-trailer orionx-guided-demo; do
    EMB="$(grep -oE "docs/media/${base}-v[0-9][^)/ ]*\.mp4" "$REPO_ROOT/README.md" | head -1)"
    if [[ -z "$EMB" ]]; then fail "README embeds ${base}" "no ${base}-v*.mp4 link"; continue; fi
    V="$(sed -E "s#docs/media/${base}-(v[^.]*\.[^.]*\.[^.]*(-[a-z0-9]+)?)\.mp4#\1#" <<< "$EMB")"
    for ext in .mp4 .vtt -transcript.md -poster.png; do
        [[ -s "$M/${base}-${V}${ext}" ]] && pass "${base}-${V}${ext} exists" || fail "${base}-${V}${ext}" "missing or empty"
    done
    if [[ -n "$VERSION" && "$V" != "$VERSION" ]]; then
        grep -q "recorded on ${V}" "$REPO_ROOT/README.md" && pass "README labels ${base} as recorded on ${V} (script is ${VERSION})" \
            || fail "README video version label" "embeds ${base}-${V} while the script is ${VERSION}, without saying so"
    fi
    if [[ -s "$M/${base}-${V}.mp4" ]] && command -v ffprobe >/dev/null 2>&1; then
        H="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$M/${base}-${V}.mp4" 2>/dev/null | head -1)"
        SZ="$(stat -c %s "$M/${base}-${V}.mp4" 2>/dev/null || stat -f %z "$M/${base}-${V}.mp4")"
        [[ "${H:-0}" -ge 720 ]] && pass "${base}-${V}.mp4 is at least 720p (${H})" || fail "${base} resolution" "height ${H:-unknown}"
        [[ "${SZ:-0}" -le 60000000 ]] && pass "${base}-${V}.mp4 is under 60 MB in the repo (${SZ} bytes)" || fail "${base} size" "${SZ} bytes"
    fi
done

printf "\n==========================================\n"
printf "  Results: ${GREEN}%s passed${NC}, ${RED}%s failed${NC}\n" "$PASS" "$FAIL"
printf "===========================================\n"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
