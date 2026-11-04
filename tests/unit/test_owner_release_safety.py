"""Owner-release provenance regressions: disposable fixtures and deny-by-default tools.

Never run the vulnerable baseline. No GitHub, git mutation, signing, or real
release staging is invoked; every such executable is replaced in the fixture.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TAG = "v9.9.9"
SHA = "b" * 40
OLD_SHA = "a" * 40
ISO_NAME = f"orionx-phoenix-edition-{TAG}.iso"
ISO_BYTES = b"fixture ISO, not a bootable image\n"
ISO_HASH = hashlib.sha256(ISO_BYTES).hexdigest()

# Absolute interpreter path avoids PATH recursion. Unknown commands fail closed.
TOOL = r'''
import hashlib, json, os, pathlib, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"]).resolve()
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps([name] + args) + "\n")
sha = "b" * 40
tag = "v9.9.9"
scenario = os.environ.get("SCENARIO", "normal")
if name == "sleep":
    sys.exit(0)
if name == "git":
    if args == ["status", "--porcelain", "--untracked-files=no"]:
        if scenario == "status-failure":
            sys.exit(73)
        sys.exit(0)
    if args[:1] == ["ls-remote"]:
        count_file = root / "tag-read-count"
        count = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(count))
        if scenario == "retag-during-wait" and count > 1:
            sha = "a" * 40
        if scenario != "missing-tag":
            if scenario == "lightweight":
                print(sha + "\trefs/tags/" + tag)
            else:
                print("c" * 40 + "\trefs/tags/" + tag)
                print(sha + "\trefs/tags/" + tag + "^{}")
        sys.exit(0)
    if args[:1] == ["rev-parse"] or args == ["rev-list", "-n", "1", tag]:
        changed = (scenario == "retag-during-wait"
                   and int((root / "tag-read-count").read_text()) > 1)
        print("a" * 40 if scenario == "stale-local" or changed else sha)
        sys.exit(0)
    if args[:1] == ["describe"]:
        print(tag)
        sys.exit(0)
if name == "gh":
    if scenario in ("published-restage", "unknown-restage", "draft-restage"):
        if args == ["release", "view", tag]:
            sys.exit(0)
        if args == ["release", "view", tag, "--json", "isDraft", "--jq", ".isDraft"]:
            if scenario == "unknown-restage":
                sys.exit(74)
            print("true" if scenario == "draft-restage" else "false")
            sys.exit(0)
        if args[:2] == ["api", "repos/jarocki/orion/releases?per_page=100"]:
            print("42")
            sys.exit(0)
        if args[:3] == ["api", "--paginate", "repos/jarocki/orion/releases/42/assets?per_page=100"]:
            # No actual assets, but recording this call proves draft-only
            # cleanup was reached. All mutation commands remain forbidden.
            sys.exit(0)
    if scenario in ("draft-assets", "draft-assets-failure", "draft-id-failure"):
        if args[:2] == ["api", "repos/fixture/repo/releases?per_page=100"]:
            if scenario == "draft-id-failure":
                sys.exit(74)
            print("42")
            sys.exit(0)
        if args[:3] == ["api", "--paginate", "repos/fixture/repo/releases/42/assets?per_page=100"]:
            if scenario == "draft-assets-failure":
                print("simulated draft lookup failure", file=sys.stderr)
                sys.exit(74)
            print("123 starter 987\n456 uploaded 988")
            sys.exit(0)
    if args[:2] == ["auth", "status"]:
        sys.exit(0)
    if args[:2] == ["run", "list"]:
        count_file = root / "poll-count"
        count = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(count))
        # Old A is always available. Only the exact filter can exclude it.
        correct_filter = ("--commit" in args and args[args.index("--commit") + 1] == sha
                          and "headSha" in args[args.index("--json") + 1]
                          and '.headSha=="' + sha + '"' in args[args.index("--jq") + 1])
        if not correct_filter:
            print("101")
        elif scenario != "no-new-run" and not (scenario == "delayed" and count == 1):
            print("202")
        sys.exit(0)
    if args[:2] == ["run", "watch"]:
        sys.exit(0 if args[2] == "202" else 96)
    if args[:2] == ["run", "view"]:
        status = "in_progress" if scenario == "running" else "completed"
        conclusion = "failure" if scenario == "failed" else "success"
        run_sha = "a" * 40 if scenario == "wrong-run-sha" else sha
        print(f"{run_sha} {tag} push {status} {conclusion}")
        sys.exit(0)
    if args[:2] == ["run", "download"]:
        target = (pathlib.Path.cwd() / args[args.index("-D") + 1]).resolve()
        # No stub may write outside its validated fixture root.
        if root not in target.parents or args[2] != "202":
            sys.exit(95)
        output = target / "output"
        output.mkdir(parents=True)
        iso_name = "orionx-phoenix-edition-v9.9.9.iso"
        data = b"fixture ISO, not a bootable image\n"
        (output / iso_name).write_bytes(data)
        (output / (iso_name + ".sha256")).write_text(hashlib.sha256(data).hexdigest() + "  " + iso_name + "\n")
        sys.exit(0)
if name == "gpg" and args[:1] == ["--verify"]:
    sys.exit(0)
# Executable presence is enough for unused required tools. Calls are forbidden.
print("unexpected stub call: " + name + " " + " ".join(args), file=sys.stderr)
sys.exit(97)
'''


class OwnerReleaseSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="owner-release-safety-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        release = self.repo / "scripts/release"
        release.mkdir(parents=True)
        self.script = release / "owner-release.sh"
        shutil.copyfile(ROOT / "scripts/release/owner-release.sh", self.script)
        # Intentional sentinel: reaching staging proves provenance validation
        # succeeded, but never executes the real signing/staging program.
        (release / "stage-split-release.sh").write_text(
            '#!/usr/bin/env bash\necho "MOCK_STAGE_REACHED" >&2\nexit 88\n'
        )
        bins = self.root / "bin"
        bins.mkdir()
        for name in ("git", "gh", "gpg", "xorriso", "unsquashfs", "dpkg", "caffeinate", "sleep"):
            tool = bins / name
            tool.write_text(f"#!{sys.executable}\n" + TOOL)
            tool.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bins}:{Path(sys.executable).parent}:/usr/bin:/bin",
                        FIXTURE_ROOT=str(self.root), ORIONX_REPO_ROOT=str(self.repo),
                        HOME=str(self.root), GH_TOKEN="", GITHUB_TOKEN="")
        self.ci = self.repo / f"tmp/release-{TAG}-ci"
        self.stage = self.repo / f"tmp/release-{TAG}"

    def run_helper(self, step="download", scenario="normal", dry=False, extra=()):
        args = ["bash", str(self.script), "--tag", TAG, "--from", step]
        args.extend(extra)
        if dry:
            args.append("--dry-run")
        return subprocess.run(args, cwd=self.repo, env=dict(self.env, SCENARIO=scenario),
                              capture_output=True, text=True, timeout=20, check=False)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def run_asset_lookup_harness(self, scenario):
        # Extract just the asset lookup definitions, never the upload flow.
        # All external calls remain routed through the deny-by-default gh stub.
        source = self.script.read_text()
        definitions = source[source.index('RELEASE_ID=""'):source.index('local_size()')]
        harness = self.root / "lookup-harness.sh"
        harness.write_text("set -euo pipefail\nTAG=v9.9.9\nREPO=fixture/repo\n" + definitions + "\n"
                           'state="$(asset_state sample.iso)"\n'
                           'printf "state=<%s>\\nlookup survived\\n" "$state"\n')
        return subprocess.run(["bash", str(harness)], cwd=self.repo,
                              env=dict(self.env, SCENARIO=scenario), capture_output=True,
                              text=True, timeout=20, check=False)

    def test_draft_asset_lookups_include_starter_assets_by_release_id(self):
        result = self.run_asset_lookup_harness("draft-assets")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("state=<123 starter 987>", result.stdout)
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][:3], ["gh", "api", "repos/fixture/repo/releases?per_page=100"])
        self.assertIn('select(.tag_name=="v9.9.9")', calls[0][-1])
        self.assertEqual(calls[1][:4], ["gh", "api", "--paginate",
                                      "repos/fixture/repo/releases/42/assets?per_page=100"])
        self.assertIn('select(.name=="sample.iso")', calls[1][-1])

    def test_failed_draft_lookup_is_empty_success_under_errexit(self):
        result = self.run_asset_lookup_harness("draft-assets-failure")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "state=<>\nlookup survived\n")
        self.assertEqual(result.stderr, "")
        self.assertEqual(len(self.calls()), 2)

    def test_failed_release_id_lookup_is_empty_success_under_errexit(self):
        result = self.run_asset_lookup_harness("draft-id-failure")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "state=<>\nlookup survived\n")
        self.assertEqual(len(self.calls()), 1)

    def test_unexpected_command_failure_reports_error_and_resume(self):
        result = self.run_helper(scenario="status-failure", extra=("--pr", "42", "--retag"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected failure (exit 73) at line", result.stdout)
        self.assertIn("git status --porcelain --untracked-files=no", result.stdout)
        self.assertIn("resume with (one line):", result.stdout)
        self.assertIn("--pr 42 --retag", result.stdout)
        self.assertIn(f"ORIONX_REPO_ROOT={self.repo}", result.stdout)
        self.assert_no_publication()

    def seed_cache(self, sha=SHA, run="202", hash_value=ISO_HASH, marker=True):
        output = self.ci / "output"
        output.mkdir(parents=True)
        (output / ISO_NAME).write_bytes(ISO_BYTES)
        (output / f"{ISO_NAME}.sha256").write_text(f"{ISO_HASH}  {ISO_NAME}\n")
        if marker:
            (self.ci / ".owner-release-source").write_text(f"{sha} {run} {hash_value}\n")

    def seed_stage(self, sha=SHA, run="202", hash_value=ISO_HASH, marker=True):
        self.stage.mkdir(parents=True)
        if marker:
            (self.stage / ".owner-release-source").write_text(f"{sha} {run} {hash_value}\n")
        (self.stage / "SHA256SUMS").write_text(f"{hash_value}  {ISO_NAME}\n")

    def assert_no_publication(self):
        self.assertFalse(any(c[0] == "gh" and c[1] in ("release", "api") for c in self.calls()))
        self.assertFalse(any(c[0] == "gpg" and "--detach-sign" in c for c in self.calls()))

    def test_waits_for_new_commit_run_not_old_tag_run(self):
        result = self.run_helper("ci", "delayed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MOCK_STAGE_REACHED", result.stdout + result.stderr)
        self.assertGreaterEqual(int((self.root / "poll-count").read_text()), 2)
        self.assertIn(["gh", "run", "watch", "202", "--exit-status"], self.calls())
        self.assertFalse(any(c[:3] == ["gh", "run", "watch"] and c[3] == "101" for c in self.calls()))
        self.assertEqual((self.ci / ".owner-release-source").read_text(), f"{SHA} 202 {ISO_HASH}\n")
        self.assert_no_publication()

    def test_old_run_only_times_out_without_download(self):
        result = self.run_helper("ci", "no-new-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no release.yml run", result.stdout)
        self.assertFalse(any(c[:3] == ["gh", "run", "download"] for c in self.calls()))
        self.assert_no_publication()

    def test_retag_during_wait_stops_before_staging(self):
        result = self.run_helper("ci", "retag-during-wait")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed during this release", result.stdout)
        self.assertNotIn("MOCK_STAGE_REACHED", result.stdout + result.stderr)
        self.assert_no_publication()

    def test_run_identity_and_success_required_on_resume(self):
        for scenario in ("wrong-run-sha", "running", "failed", "stale-local", "missing-tag"):
            with self.subTest(scenario=scenario):
                result = self.run_helper(scenario=scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.ci.exists())
                self.assert_no_publication()

    def test_unproven_cache_is_preserved(self):
        self.seed_cache(marker=False)
        before = (self.ci / "output" / ISO_NAME).read_bytes()
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unproven cache", result.stdout)
        self.assertEqual((self.ci / "output" / ISO_NAME).read_bytes(), before)
        self.assertFalse(any(c[:3] == ["gh", "run", "download"] for c in self.calls()))

    def test_stale_cache_identity_is_rejected(self):
        self.seed_cache(sha=OLD_SHA)
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale or invalid cache provenance", result.stdout)
        self.assertEqual((self.ci / "output" / ISO_NAME).read_bytes(), ISO_BYTES)

    def test_wrong_run_cache_is_rejected_at_same_commit(self):
        self.seed_cache(run="101")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale or invalid cache provenance", result.stdout)
        self.assertEqual((self.ci / "output" / ISO_NAME).read_bytes(), ISO_BYTES)

    def test_symlink_cache_is_rejected_and_preserved(self):
        self.seed_cache()
        preserved = self.root / "preserved-cache"
        self.ci.rename(preserved)
        self.ci.symlink_to(preserved, target_is_directory=True)
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe cache directory", result.stdout)
        self.assertTrue(self.ci.is_symlink())
        self.assertEqual((preserved / "output" / ISO_NAME).read_bytes(), ISO_BYTES)

    def test_cached_iso_hash_is_checked(self):
        self.seed_cache(hash_value="0" * 64)
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cached ISO differs", result.stdout)

    def test_matching_cached_iso_reaches_mock_stage_without_download(self):
        self.seed_cache()
        result = self.run_helper()
        self.assertIn("MOCK_STAGE_REACHED", result.stdout + result.stderr)
        self.assertFalse(any(c[:3] == ["gh", "run", "download"] for c in self.calls()))
        self.assert_no_publication()

    def test_resume_rejects_unproven_staging(self):
        self.seed_cache()
        self.seed_stage(marker=False)
        result = self.run_helper("publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unproven cache", result.stdout)
        self.assert_no_publication()

    def test_resume_rejects_staging_from_old_commit(self):
        self.seed_cache()
        self.seed_stage(sha=OLD_SHA)
        result = self.run_helper("publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale or invalid cache provenance", result.stdout)
        self.assert_no_publication()

    def test_resume_rejects_changed_staged_checksum(self):
        self.seed_cache()
        self.seed_stage()
        (self.stage / "SHA256SUMS").write_text(f"{'0' * 64}  {ISO_NAME}\n")
        result = self.run_helper("publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("staged checksum does not match", result.stdout)
        self.assert_no_publication()

    def test_stage_marker_must_match_downloaded_iso_hash(self):
        self.seed_cache()
        self.seed_stage(hash_value="0" * 64)
        result = self.run_helper("publish")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("staging and downloaded ISO have different provenance", result.stdout)
        self.assert_no_publication()

    def test_matching_provenance_can_resume_without_publishing(self):
        self.seed_cache()
        self.seed_stage()
        result = self.run_helper("publish")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("left as DRAFT", result.stdout)
        self.assertIn(["git", "status", "--porcelain", "--untracked-files=no"], self.calls())
        self.assert_no_publication()

    def test_restage_preserves_unproven_staging(self):
        self.seed_cache()
        self.seed_stage(marker=False)
        result = self.run_helper("stage", extra=("--restage", "--part-size", "32m"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unproven cache", result.stdout)
        self.assertTrue((self.stage / "SHA256SUMS").exists())
        self.assertNotIn("MOCK_STAGE_REACHED", result.stdout + result.stderr)
        self.assert_no_publication()

    def test_restage_preserves_stale_staging(self):
        self.seed_cache()
        self.seed_stage(sha=OLD_SHA)
        result = self.run_helper("stage", extra=("--restage",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stale or invalid cache provenance", result.stdout)
        self.assertTrue((self.stage / "SHA256SUMS").exists())
        self.assert_no_publication()

    def test_restage_preserves_symlink_staging(self):
        self.seed_cache()
        self.seed_stage()
        preserved = self.root / "preserved-stage"
        self.stage.rename(preserved)
        self.stage.symlink_to(preserved, target_is_directory=True)
        result = self.run_helper("stage", extra=("--restage",))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe cache directory", result.stdout)
        self.assertTrue(self.stage.is_symlink())
        self.assertTrue((preserved / "SHA256SUMS").exists())
        self.assert_no_publication()

    def test_restage_replaces_verified_staging_and_copies_provenance(self):
        self.seed_cache()
        self.seed_stage()
        (self.stage / "old-part").write_text("old split")
        stage_script = self.repo / "scripts/release/stage-split-release.sh"
        # Mock staging writes only inside this fixture, then the helper checks
        # all six outputs and the new source marker without executing signing.
        stage_script.write_text(
            '#!/usr/bin/env bash\nset -eu\n'
            '[ "$3" = --out ] && [ "$7" = --part-size ] && [ "$8" = 32m ]\n'
            'mkdir -p "$4"\n'
            f'printf "%s  %s\\n" {ISO_HASH} {ISO_NAME} > "$4/SHA256SUMS"\n'
            'for f in SHA256SUMS.asc SHA512SUMS SHA512SUMS.asc REASSEMBLE.txt RELEASE-NOTES.md; '
            'do echo fixture > "$4/$f"; done\n')
        result = self.run_helper("stage", extra=("--restage", "--part-size", "32m"))
        # Later release creation is denied by the gh stub, so stop after proving
        # the mock stage succeeded and the correct source marker was installed.
        self.assertIn("staged:", result.stdout)
        self.assertFalse((self.stage / "old-part").exists())
        self.assertEqual((self.stage / ".owner-release-source").read_text(),
                         f"{SHA} 202 {ISO_HASH}\n")

    def test_restage_never_deletes_published_or_unconfirmed_release_assets(self):
        self.seed_cache()
        self.seed_stage()
        for scenario in ("published-restage", "unknown-restage"):
            with self.subTest(scenario=scenario):
                result = self.run_helper("release", scenario, extra=("--restage",))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refuses to delete assets", result.stdout)
                self.assertFalse(any(c[:3] == ["gh", "api", "--paginate"] for c in self.calls()))
                self.assertFalse(any(c[0] == "gh" and ("DELETE" in c or "upload" in c)
                                     for c in self.calls()))

    def test_confirmed_draft_restaging_reaches_asset_enumeration(self):
        self.seed_cache()
        self.seed_stage()
        result = self.run_helper("release", "draft-restage", extra=("--restage",))
        self.assertIn("removing every asset already on the draft", result.stdout)
        self.assertTrue(any(c[:4] == ["gh", "api", "--paginate",
                                     "repos/jarocki/orion/releases/42/assets?per_page=100"]
                            for c in self.calls()))

    def test_resume_hint_preserves_owner_flags(self):
        # Missing tag stops before any release step. --publish only exercises
        # the hint formatter; publication remains forbidden by the gh stub.
        result = self.run_helper(scenario="missing-tag", extra=(
            "--pr", "42", "--retag", "--publish", "--key", "TEST_FINGERPRINT",
            "--part-size", "32m"))
        self.assertNotEqual(result.returncode, 0)
        hint = next(line for line in result.stdout.splitlines() if "resume with" in line)
        for expected in ("--pr 42", "--retag", "--publish", "--key TEST_FINGERPRINT", "--part-size 32m",
                         f"ORIONX_REPO_ROOT={self.repo}"):
            self.assertIn(expected, hint)
        self.assert_no_publication()

    def test_lightweight_tag_matching_provenance_can_resume(self):
        self.seed_cache()
        self.seed_stage()
        result = self.run_helper("publish", "lightweight")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("left as DRAFT", result.stdout)
        self.assert_no_publication()

    def test_dry_run_preserves_partial_artifacts_and_skips_fetch(self):
        self.ci.mkdir(parents=True)
        sentinel = self.ci / "recovery.log"
        sentinel.write_bytes(b"valuable partial download\n")
        self.seed_stage(marker=False)
        staged_before = (self.stage / "SHA256SUMS").read_bytes()
        result = self.run_helper("tag", dry=True, extra=("--restage", "--part-size", "32m"))
        self.assertEqual((self.stage / "SHA256SUMS").read_bytes(), staged_before)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sentinel.read_bytes(), b"valuable partial download\n")
        self.assertFalse(any(c[0] == "git" and c[1] in ("fetch", "push", "tag", "checkout") for c in self.calls()))
        self.assertFalse(any(c[0] == "gh" for c in self.calls()))


if __name__ == "__main__":
    unittest.main()
