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
# Signed staging runs xorriso and unsquashfs ON THE RUNNER (not in the build
# container); the v3.1.1 run failed with "xorriso is required" because nothing
# installed them. The install step must exist and come before staging.
names = [s.get("name", "") for s in steps]
tools = [s for s in steps if "xorriso" in s.get("run", "") and "squashfs-tools" in s.get("run", "")
         and "apt-get install" in s.get("run", "") and "docker run" not in s.get("run", "")]
check("release.yml installs xorriso + squashfs-tools on the runner (v3.1.1 staging failure)", bool(tools))
check("the runner tooling step precedes signed staging",
      bool(tools) and names.index(tools[0].get("name", "")) < names.index("Stage signed split release assets"))
# DEC-PHASE13-029: CI builds and gates; the owner signs. The passphrase is never
# a repository secret, so a tag run decides up front whether it can sign, and
# when it cannot it skips signing/staging/draft and hands off to §10 — green,
# with the gated ISO as the run artifact. An unsigned draft stays impossible.
decide = by_name.get("Decide whether this run can sign (DEC-PHASE13-029)", {})
decide_env = decide.get("env", {})
check("release.yml decides can_sign from both secrets before the build (DEC-PHASE13-029)",
      decide.get("id") == "signing"
      and "secrets.GPG_PRIVATE_KEY" in str(decide_env.get("HAVE_KEY", ""))
      and "secrets.GPG_PASSPHRASE" in str(decide_env.get("HAVE_PASSPHRASE", ""))
      and "can_sign=false" in decide.get("run", "") and "can_sign=true" in decide.get("run", "")
      and bool(decide) and names.index(decide["name"]) < names.index("Build ISO in debian:trixie container"))
signing_steps = ["Install release tooling on the runner (xorriso, squashfs-tools)", "Import GPG signing key",
                 "Stage signed split release assets", "Assert every release asset is under GitHub's 2 GiB cap",
                 "Create DRAFT GitHub Release"]
check("every signing/staging/draft step runs only when can_sign is true (no unsigned draft, DEC-PHASE12-026)",
      all("steps.signing.outputs.can_sign == 'true'" in str(by_name.get(n, {}).get("if", "")) for n in signing_steps))
handoff = by_name.get("Hand off to the owner for signing (release-process §10)", {})
check("a tag run that cannot sign hands off to release-process §10 instead of failing",
      "can_sign != 'true'" in str(handoff.get("if", ""))
      and "release-artifacts-" in handoff.get("run", "") and "stage-split-release.sh" in handoff.get("run", "")
      and "GITHUB_STEP_SUMMARY" in handoff.get("run", ""))
check("the ISO artifact upload still runs on every outcome", str(by_name["Upload build artifacts to Actions"].get("if", "")) == "always()")
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
