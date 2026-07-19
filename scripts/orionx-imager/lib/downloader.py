"""
lib/downloader.py — GitHub Releases client + SHA256 verifier for orionx-imager.

Single-authority for ISO download and integrity verification.
Uses only stdlib: urllib.request, hashlib, json, pathlib, os.

release_download_source_authority:
  GitHub Releases REST API v3 for jarocki/orion is the ONLY canonical source.
  SHA256SUMS asset (emitted by .github/workflows/release.yml lines 108-114)
  is the ONLY canonical integrity manifest. No ad-hoc mirror lists.

@decision DEC-PHASE11-015
@title    Orion-X imager — GitHub Releases client + SHA256 verify (Layer A)
@status   accepted
@rationale
    Stdlib urllib.request keeps supply-chain audit surface at zero.
    Mandatory SHA256 verification (skip-verify is CLI-only two-flag opt-out;
    GUI never exposes it). XDG cache avoids re-downloading the same release tag.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
from typing import Callable, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GITHUB_REPO = "jarocki/orion"
RELEASES_API = f"https://api.github.com/repos/{GITHUB_REPO}/releases"
_ISO_ASSET_SUFFIXES = (".iso",)
_SHA256_ASSET_NAMES = ("SHA256SUMS", "sha256sums", "SHA256SUMS.txt")
_CHUNK_SIZE = 65536  # 64 KiB streaming chunks

# XDG cache location for downloaded ISOs and checksum files.
_CACHE_ROOT = pathlib.Path(
    os.environ.get("XDG_CACHE_HOME", str(pathlib.Path.home() / ".cache"))
) / "orionx-imager"

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

ProgressCallback = Optional[Callable[[int, int], None]]
# progress_cb(bytes_read: int, total_bytes: int) — total_bytes may be 0 if unknown.


def get_cache_dir() -> pathlib.Path:
    """Return (and create) the XDG cache directory for orionx-imager."""
    _CACHE_ROOT.mkdir(parents=True, exist_ok=True)
    return _CACHE_ROOT


def list_releases() -> list[dict]:
    """Return all releases for jarocki/orion from GitHub Releases API v3.

    Returns a list of release dicts (raw GitHub API shape).
    Raises RuntimeError on network or API errors.
    """
    return _api_get(RELEASES_API)


def get_release(tag: str = "latest") -> dict:
    """Fetch a single release by tag name, or the latest release.

    Args:
        tag: Release tag (e.g. "v2.0.0") or the special string "latest".

    Returns:
        Release dict (raw GitHub API shape with 'assets', 'tag_name', etc.).

    Raises:
        RuntimeError: on network error, 404 (tag not found), or rate-limit (403).
    """
    if tag == "latest":
        url = RELEASES_API + "/latest"
    else:
        url = RELEASES_API + f"/tags/{tag}"
    return _api_get(url)


def find_iso_asset(release: dict) -> dict:
    """Find the ISO asset in a release dict.

    Picks the first asset whose name ends with '.iso'.
    If multiple ISO assets exist, picks the first (sorted by name for
    determinism). Raises RuntimeError if no ISO asset is found.
    """
    candidates = [
        a for a in release.get("assets", [])
        if any(a["name"].lower().endswith(s) for s in _ISO_ASSET_SUFFIXES)
    ]
    if not candidates:
        raise RuntimeError(
            f"No .iso asset found in release {release.get('tag_name', '?')}. "
            "Available assets: " + ", ".join(a["name"] for a in release.get("assets", []))
        )
    # Deterministic: sort by name, take first
    candidates.sort(key=lambda a: a["name"])
    return candidates[0]


def find_sha256sums_asset(release: dict) -> Optional[dict]:
    """Find the SHA256SUMS asset in a release dict.

    Returns None if not found (caller should warn; do not hard-fail on missing
    SHA256SUMS — that would break legacy releases that predate the manifest).
    """
    for asset in release.get("assets", []):
        if asset["name"] in _SHA256_ASSET_NAMES:
            return asset
    # Fallback: any asset whose name contains 'SHA256'
    for asset in release.get("assets", []):
        if "sha256" in asset["name"].lower():
            return asset
    return None


def download(
    url: str,
    dest: pathlib.Path,
    progress_cb: ProgressCallback = None,
) -> None:
    """Stream-download *url* to *dest* with optional progress callback.

    Creates parent directories as needed. Overwrites *dest* if it exists.
    progress_cb receives (bytes_read: int, total_bytes: int); total_bytes
    may be 0 if the server does not send Content-Length.

    Raises RuntimeError on HTTP or network errors.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    req = Request(url, headers={"User-Agent": "orionx-imager/1.0"})
    try:
        with urlopen(req, timeout=120) as resp:
            total = int(resp.headers.get("Content-Length") or 0)
            downloaded = 0
            with open(dest, "wb") as fh:
                while True:
                    chunk = resp.read(_CHUNK_SIZE)
                    if not chunk:
                        break
                    fh.write(chunk)
                    downloaded += len(chunk)
                    if progress_cb:
                        progress_cb(downloaded, total)
    except HTTPError as exc:
        raise RuntimeError(
            f"HTTP {exc.code} downloading {url}: {exc.reason}"
        ) from exc
    except URLError as exc:
        raise RuntimeError(f"Network error downloading {url}: {exc.reason}") from exc


def verify_sha256(
    iso_path: pathlib.Path,
    sha256sums_path: pathlib.Path,
) -> Tuple[bool, str]:
    """Verify *iso_path* SHA256 against the SHA256SUMS manifest.

    SHA256SUMS format: ``<hex_digest>  <filename>`` per line (two spaces;
    standard sha256sum output). Matches on basename of *iso_path*.

    Returns:
        (matched: bool, expected_sha: str)
        If the filename is not found in the manifest, returns (False, "").
        If found and digest matches, returns (True, expected_sha).
        If found but digest mismatches, returns (False, expected_sha).

    Raises:
        RuntimeError: if the SHA256SUMS file cannot be read or parsed.
        FileNotFoundError: if iso_path does not exist.
    """
    iso_name = iso_path.name
    expected_sha = _find_expected_sha(sha256sums_path, iso_name)
    if not expected_sha:
        return False, ""

    actual_sha = _sha256_file(iso_path)
    return (actual_sha == expected_sha), expected_sha


def download_and_verify(
    release: dict,
    progress_cb: ProgressCallback = None,
    skip_verify: bool = False,
) -> pathlib.Path:
    """High-level helper: download the ISO for *release*, verify SHA256.

    Uses XDG cache: if the ISO already exists at the cache path AND its SHA256
    matches the manifest, skips the download.  Always downloads SHA256SUMS fresh
    (it's tiny and ensures we have the latest manifest).

    Args:
        release:      Release dict from get_release().
        progress_cb:  Optional progress callback.
        skip_verify:  If True, skip SHA256 verification. NOT RECOMMENDED.

    Returns:
        pathlib.Path to the downloaded (and verified) ISO.

    Raises:
        RuntimeError: on download failure, SHA256 mismatch, or missing ISO asset.
    """
    cache = get_cache_dir()
    iso_asset = find_iso_asset(release)
    iso_path = cache / iso_asset["name"]

    # Download SHA256SUMS first (always refresh)
    sha_path: Optional[pathlib.Path] = None
    if not skip_verify:
        sha_asset = find_sha256sums_asset(release)
        if sha_asset:
            sha_path = cache / sha_asset["name"]
            download(sha_asset["browser_download_url"], sha_path)
        else:
            # No SHA256SUMS in this release; warn but do not abort
            sha_path = None

    # Check if cached ISO is already valid
    if iso_path.exists() and sha_path and not skip_verify:
        matched, expected = verify_sha256(iso_path, sha_path)
        if matched:
            return iso_path  # Cache hit — skip re-download

    # Download ISO
    download(iso_asset["browser_download_url"], iso_path, progress_cb=progress_cb)

    # Verify
    if not skip_verify:
        if sha_path:
            matched, expected = verify_sha256(iso_path, sha_path)
            if not matched:
                actual = _sha256_file(iso_path)
                raise RuntimeError(
                    f"SHA256 mismatch for {iso_asset['name']}:\n"
                    f"  expected: {expected}\n"
                    f"  actual:   {actual}\n"
                    "Download may be corrupt or tampered. Refusing to write."
                )
        else:
            # No manifest available — flag prominently but do not hard-fail
            # (Layer B may add a stricter mode that refuses without manifest)
            print(
                "WARNING: SHA256SUMS not found in release assets. "
                "Integrity cannot be verified. Proceed with caution.",
                flush=True,
            )

    return iso_path


def clear_cache() -> None:
    """Remove all files from the XDG cache directory."""
    import shutil
    if _CACHE_ROOT.exists():
        shutil.rmtree(_CACHE_ROOT)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _api_get(url: str) -> dict | list:
    """Perform a GET request to the GitHub API and return parsed JSON."""
    req = Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "orionx-imager/1.0",
        },
    )
    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except HTTPError as exc:
        if exc.code == 403:
            raise RuntimeError(
                "GitHub API rate limit exceeded (60 req/hr for unauthenticated requests). "
                "Wait ~60 minutes and retry, or use --iso <local-file> to bypass the API."
            ) from exc
        if exc.code == 404:
            raise RuntimeError(
                f"Release not found at {url}. "
                "Check the tag name or use --iso-release latest."
            ) from exc
        raise RuntimeError(f"GitHub API error {exc.code}: {exc.reason}") from exc
    except URLError as exc:
        raise RuntimeError(
            f"Network error reaching GitHub API ({url}): {exc.reason}. "
            "Check your internet connection."
        ) from exc


def _sha256_file(path: pathlib.Path) -> str:
    """Compute hex SHA256 digest of a file."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(_CHUNK_SIZE)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _find_expected_sha(sha256sums_path: pathlib.Path, filename: str) -> str:
    """Parse SHA256SUMS file and return the expected digest for *filename*.

    SHA256SUMS lines: ``<sha256hex>  <filename>`` (two spaces) or
    ``<sha256hex> *<filename>`` (BSD style with asterisk).
    Returns empty string if *filename* is not found.
    """
    try:
        content = sha256sums_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise RuntimeError(f"Cannot read SHA256SUMS at {sha256sums_path}: {exc}") from exc

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 1)  # split on first whitespace
        if len(parts) < 2:
            continue
        digest, name_field = parts[0], parts[1].lstrip("* ")
        # name_field may be "orionx-v2.0.0.iso" or "./orionx-v2.0.0.iso"
        if os.path.basename(name_field) == filename or name_field == filename:
            return digest.lower()
    return ""
