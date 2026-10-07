"""Structural checks of the CI workflows (DEC-PHASE12-115, DEC-PHASE12-123).

Workflow YAML is configuration, so these checks parse it rather than run it:
GitHub Actions cannot be executed locally. Invoked by test_release_tooling.sh;
prints one PASS/FAIL line per property and exits 1 if any failed.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
WF = ROOT / ".github" / "workflows"
results = []


def check(name, ok):
    results.append(ok)
    print(("  PASS: " if ok else "  FAIL: ") + name)


def load(name):
    with open(WF / name) as f:
        doc = yaml.safe_load(f)
    # PyYAML (YAML 1.1) reads the bare key `on` as boolean True.
    doc["on"] = doc.get("on", doc.get(True))
    return doc


rel = load("release.yml")
steps = rel["jobs"]["release"]["steps"]
by_name = {s.get("name", ""): s for s in steps}

build = by_name["Build ISO in debian:trixie container"]["run"]
first = [line for line in build.splitlines() if line.strip()][0].strip()
check("release.yml build step starts with `set -o pipefail` (P2-5)", first == "set -o pipefail")

gh = by_name["Create DRAFT GitHub Release"]["with"]
files = [f.strip() for f in gh["files"].splitlines() if f.strip()]
check("release upload never globs a whole ISO (P1-1)", not any(f.endswith(".iso") for f in files))
check("release uploads parts + both sums + both signatures + REASSEMBLE.txt",
      {"output/release/*.iso.part-*", "output/release/SHA256SUMS", "output/release/SHA256SUMS.asc",
       "output/release/SHA512SUMS", "output/release/SHA512SUMS.asc", "output/release/REASSEMBLE.txt"} <= set(files))
check("fail_on_unmatched_files is true (no silently missing asset)", gh.get("fail_on_unmatched_files") is True)
check("release stays a DRAFT", gh.get("draft") is True)
check("release body is the staged RELEASE-NOTES.md", gh.get("body_path") == "output/release/RELEASE-NOTES.md")
stage = by_name.get("Stage signed split release assets", {}).get("run", "")
check("assets are staged by scripts/release/stage-split-release.sh", "scripts/release/stage-split-release.sh" in stage)
check("no step sets continue-on-error (signing is hard-fail)", not any("continue-on-error" in s for s in steps))
check("the unreachable 'Report signing status' step is gone (P3-12)", "Report signing status" not in by_name)
verify = by_name["Verify ISO artifact"]["run"]
check("Verify ISO artifact checks the exact versioned file name", 'orionx-phoenix-edition-${ORIONX_VERSION}.iso' in verify)
check("no `|| true` fallback around release notes (F-20)", "See CHANGELOG.md for full release history" not in yaml.safe_dump(rel))

for wf in ("lint.yml", "e2e-test.yml", "qemu-test.yml"):
    on = load(wf)["on"]
    check(f"{wf} runs on push to release/** (F-02)", "release/**" in on["push"]["branches"])
    check(f"{wf} runs on PRs to release/**", "release/**" in on["pull_request"]["branches"])

lint_steps = [s.get("run", "") for s in load("lint.yml")["jobs"]["lint"]["steps"]]
check("lint.yml runs make lint and make test-unit (what ci-local.sh runs)",
      "make lint" in lint_steps and "make test-unit" in lint_steps)
sys.exit(0 if all(results) else 1)
