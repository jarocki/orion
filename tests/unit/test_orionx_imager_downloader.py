#!/usr/bin/env python3
"""
tests/unit/test_orionx_imager_downloader.py — orionx-imager downloader:
split-release (.iso.part-*) reassembly and pre-release resolution
(DEC-PHASE12-019).

Real files, real hashes, no network: `download()` and the GitHub API are
replaced by fakes that serve bytes from a temp directory. Run:

    python3 tests/unit/test_orionx_imager_downloader.py
"""
from __future__ import annotations

import hashlib
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts" / "orionx-imager" / "lib"))
import downloader  # noqa: E402


def _sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


class FakeRelease:
    """Builds a GitHub release dict + the bytes each asset URL serves."""

    def __init__(self, tag: str, prerelease: bool = False):
        self.tag = tag
        self.prerelease = prerelease
        self.assets: list[dict] = []
        self.blobs: dict[str, bytes] = {}

    def add(self, name: str, data: bytes) -> None:
        url = f"https://example.invalid/{self.tag}/{name}"
        self.assets.append({"name": name, "size": len(data), "browser_download_url": url})
        self.blobs[url] = data

    def dict(self) -> dict:
        return {"tag_name": self.tag, "prerelease": self.prerelease, "draft": False,
                "assets": list(self.assets)}


def make_split_release(tag="v9.9.9-beta", iso_size=10_000, part_size=3_000, prerelease=True):
    iso = os.urandom(iso_size)
    rel = FakeRelease(tag, prerelease)
    parts = [iso[i:i + part_size] for i in range(0, iso_size, part_size)]
    names = []
    seq = downloader._part_sequence(len(parts))
    for s, chunk in zip(seq, parts):
        n = f"orionx-{tag}.iso.part-{s}"
        names.append(n)
        rel.add(n, chunk)
    sums = f"{_sha(iso)}  orionx-{tag}.iso\n" + "".join(f"{_sha(c)}  {n}\n" for n, c in zip(names, parts))
    rel.add("SHA256SUMS", sums.encode())
    rel.add("REASSEMBLE.txt", b"cat parts > iso\n")
    return rel, iso


class DownloaderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = pathlib.Path(self.tmp.name) / "cache"
        self.cache.mkdir()
        self._p_cache = mock.patch.object(downloader, "get_cache_dir", return_value=self.cache)
        self._p_cache.start()
        self.served: dict[str, bytes] = {}
        self.downloads: list[str] = []

        def fake_download(url, dest, progress_cb=None):
            self.downloads.append(url)
            data = self.served[url]
            pathlib.Path(dest).parent.mkdir(parents=True, exist_ok=True)
            pathlib.Path(dest).write_bytes(data)
            if progress_cb:
                progress_cb(len(data), len(data))

        self._p_dl = mock.patch.object(downloader, "download", side_effect=fake_download)
        self._p_dl.start()

    def tearDown(self):
        self._p_dl.stop()
        self._p_cache.stop()
        self.tmp.cleanup()

    # --- asset resolution -------------------------------------------------
    def test_whole_iso_asset_still_preferred(self):
        rel = FakeRelease("v1.0.0")
        rel.add("orionx-v1.0.0.iso", b"x" * 10)
        rel.add("orionx-v1.0.0.iso.part-aa", b"x" * 5)
        a = downloader.find_iso_asset(rel.dict())
        self.assertEqual(a["name"], "orionx-v1.0.0.iso")
        self.assertNotIn("parts", a)

    def test_split_release_resolves_to_ordered_parts(self):
        rel, iso = make_split_release()
        a = downloader.find_iso_asset(rel.dict())
        self.assertEqual(a["name"], f"orionx-{rel.tag}.iso")
        self.assertIsNone(a["browser_download_url"])
        self.assertEqual([p["name"][-2:] for p in a["parts"]], ["aa", "ab", "ac", "ad"])
        self.assertEqual(a["size"], len(iso))

    def test_split_release_with_gap_is_refused(self):
        rel, _ = make_split_release()
        rel.assets = [x for x in rel.assets if not x["name"].endswith("part-ab")]
        with self.assertRaisesRegex(RuntimeError, "broken part set"):
            downloader.find_iso_asset(rel.dict())

    def test_no_iso_at_all_is_an_error_naming_assets(self):
        rel = FakeRelease("v0")
        rel.add("SHA256SUMS", b"")
        with self.assertRaisesRegex(RuntimeError, r"No \.iso \(or \.iso\.part-\*\)"):
            downloader.find_iso_asset(rel.dict())

    def test_part_sequence_matches_split(self):
        self.assertEqual(downloader._part_sequence(3), ["aa", "ab", "ac"])
        self.assertEqual(downloader._part_sequence(28)[25:], ["az", "ba", "bb"])

    # --- download + reassembly -------------------------------------------
    def test_split_download_reassembles_and_verifies(self):
        rel, iso = make_split_release()
        self.served.update(rel.blobs)
        progress = []
        out = downloader.download_and_verify(rel.dict(), progress_cb=lambda d, t: progress.append((d, t)))
        self.assertEqual(out.name, f"orionx-{rel.tag}.iso")
        self.assertEqual(out.read_bytes(), iso, "reassembled ISO must be byte-identical")
        self.assertEqual(progress[-1], (len(iso), len(iso)), "progress reaches total of all parts")
        self.assertFalse(list(self.cache.glob("*.assembling")), "no temp file left behind")

    def test_corrupt_part_is_reported_by_name(self):
        rel, iso = make_split_release()
        self.served.update(rel.blobs)
        bad = [u for u in self.served if u.endswith("part-ac")][0]
        self.served[bad] = b"corrupt" * 100
        with self.assertRaisesRegex(RuntimeError, r"SHA256 mismatch for part .*part-ac"):
            downloader.download_and_verify(rel.dict())
        self.assertFalse((self.cache / f"orionx-{rel.tag}.iso").exists(), "no ISO written from bad parts")

    def test_valid_cached_parts_are_not_redownloaded(self):
        rel, iso = make_split_release()
        self.served.update(rel.blobs)
        downloader.download_and_verify(rel.dict())
        # Remove the assembled ISO but keep parts: second run must only fetch SHA256SUMS.
        (self.cache / f"orionx-{rel.tag}.iso").unlink()
        self.downloads.clear()
        out = downloader.download_and_verify(rel.dict())
        self.assertEqual(out.read_bytes(), iso)
        self.assertEqual([u.rsplit("/", 1)[1] for u in self.downloads], ["SHA256SUMS"])

    def test_cached_whole_iso_hit_skips_everything(self):
        rel, iso = make_split_release()
        self.served.update(rel.blobs)
        downloader.download_and_verify(rel.dict())
        self.downloads.clear()
        downloader.download_and_verify(rel.dict())
        self.assertEqual([u.rsplit("/", 1)[1] for u in self.downloads], ["SHA256SUMS"])

    def test_whole_iso_mismatch_still_refuses(self):
        rel, iso = make_split_release()
        # SHA256SUMS lists a wrong whole-ISO hash but correct parts.
        sums_url = [u for u in rel.blobs if u.endswith("SHA256SUMS")][0]
        text = rel.blobs[sums_url].decode().splitlines()
        text[0] = "0" * 64 + f"  orionx-{rel.tag}.iso"
        rel.blobs[sums_url] = ("\n".join(text) + "\n").encode()
        self.served.update(rel.blobs)
        with self.assertRaisesRegex(RuntimeError, "SHA256 mismatch for orionx-"):
            downloader.download_and_verify(rel.dict())

    # --- release selection ----------------------------------------------
    def test_latest_uses_github_latest_endpoint_by_default(self):
        with mock.patch.object(downloader, "_api_get", return_value={"tag_name": "v1"}) as api:
            downloader.get_release("latest")
            self.assertTrue(api.call_args[0][0].endswith("/releases/latest"))

    def test_latest_with_prerelease_picks_newest_non_draft(self):
        rels = [{"tag_name": "v3-draft", "draft": True, "prerelease": True},
                {"tag_name": "v2.2.0-beta", "draft": False, "prerelease": True},
                {"tag_name": "v2.1.0", "draft": False, "prerelease": False}]
        with mock.patch.object(downloader, "list_releases", return_value=rels):
            self.assertEqual(downloader.get_release("latest", allow_prerelease=True)["tag_name"], "v2.2.0-beta")

    def test_tag_request_unchanged(self):
        with mock.patch.object(downloader, "_api_get", return_value={"tag_name": "v2.2.0-beta"}) as api:
            downloader.get_release("v2.2.0-beta", allow_prerelease=True)
            self.assertTrue(api.call_args[0][0].endswith("/releases/tags/v2.2.0-beta"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
