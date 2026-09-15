"""Fetch Nuclei template trees from git or HTTP tarballs."""

from __future__ import annotations

import io
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

PROJECTDISCOVERY_REPO = "https://github.com/projectdiscovery/nuclei-templates"


def _git_available() -> bool:
    return shutil.which("git") is not None


def clone_or_update(repo_url: str, dest: Path, depth: int = 1) -> None:
    if (dest / ".git").exists():
        subprocess.run(
            ["git", "-C", str(dest), "fetch", "--depth", str(depth), "origin"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(dest), "reset", "--hard", "FETCH_HEAD"],
            check=True,
        )
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        shutil.rmtree(dest)
    subprocess.run(
        ["git", "clone", "--depth", str(depth), repo_url, str(dest)],
        check=True,
    )


def download_tarball(repo_url: str, dest: Path, ref: str = "main") -> Path:
    """Fall back to a codeload.github.com tarball when git isn't usable."""
    parts = repo_url.rstrip("/").removesuffix(".git").split("/")
    owner, repo = parts[-2], parts[-1]
    url = f"https://codeload.github.com/{owner}/{repo}/tar.gz/refs/heads/{ref}"
    dest.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as resp:  # nosec - explicit user-supplied repo
        data = resp.read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        tf.extractall(dest)
    extracted = next((p for p in dest.iterdir() if p.is_dir()), None)
    return extracted or dest


def fetch(
    repo_url: str = PROJECTDISCOVERY_REPO,
    dest: Path | None = None,
    *,
    update: bool = True,
    fallback_ref: str = "main",
) -> Path:
    """Materialize a templates directory and return its path.

    Tries `git clone --depth 1` first, then falls back to a GitHub tarball.
    If `update` is False and the destination already exists, it is reused as-is.
    """
    dest = Path(dest) if dest else Path.home() / ".cache" / "nucleotide" / "templates"

    if dest.exists() and any(dest.iterdir()) and not update:
        return dest

    if _git_available():
        try:
            clone_or_update(repo_url, dest)
            return dest
        except subprocess.CalledProcessError:
            pass

    return download_tarball(repo_url, dest, ref=fallback_ref)
