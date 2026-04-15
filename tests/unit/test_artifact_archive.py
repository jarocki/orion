"""
Unit tests for artifact archive integration.

@decision DEC-ARCHIVE-001
@title Test suite for legacy artifact archive structure and gitignore rules
@status accepted
@rationale Validates that legacy artifacts are properly organized in archive/,
  .gitignore correctly excludes archive contents while tracking INVENTORY.md,
  no .DS_Store files leak in, and architecture images and sample PCAPs are
  placed in their tracked directories. Tests run against real filesystem
  state, not mocks.

Tests verify:
- Archive directory structure exists with version subdirectories
- INVENTORY.md exists in archive/ and is the only tracked file there
- .gitignore properly excludes archive/ contents but tracks INVENTORY.md
- No .DS_Store files in archive directories
- docs/images/ contains architecture images from v1.4
- data/samples/pcaps/ contains sample PCAP data
- Legacy artifacts are organized by version
"""

import os
import subprocess

import pytest

WORKTREE = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
ARCHIVE_DIR = os.path.join(WORKTREE, "archive")
INVENTORY_PATH = os.path.join(ARCHIVE_DIR, "INVENTORY.md")
GITIGNORE_PATH = os.path.join(WORKTREE, ".gitignore")
DOCS_IMAGES_DIR = os.path.join(WORKTREE, "docs", "images")
PCAP_DIR = os.path.join(WORKTREE, "data", "samples", "pcaps")


# ---------------------------------------------------------------------------
# Archive directory structure
# ---------------------------------------------------------------------------

VERSION_DIRS = ["v1.2", "v1.3", "v1.4"]


@pytest.mark.parametrize("version", VERSION_DIRS)
def test_archive_version_directory_exists(version):
    """Each legacy version must have its own subdirectory in archive/versions/."""
    version_path = os.path.join(ARCHIVE_DIR, "versions", version)
    assert os.path.isdir(version_path), (
        f"Archive version directory missing: {version_path}"
    )


@pytest.mark.parametrize("version", VERSION_DIRS)
def test_archive_version_has_content(version):
    """Each version directory must contain at least one file."""
    version_path = os.path.join(ARCHIVE_DIR, "versions", version)
    if not os.path.isdir(version_path):
        pytest.skip(f"Version directory {version} does not exist yet")
    entries = os.listdir(version_path)
    # Filter out .DS_Store
    entries = [e for e in entries if e != ".DS_Store"]
    assert len(entries) > 0, (
        f"Archive version directory is empty: {version_path}"
    )


def test_archive_artifacts_directory_exists():
    """archive/artifacts/ directory must exist."""
    artifacts_path = os.path.join(ARCHIVE_DIR, "artifacts")
    assert os.path.isdir(artifacts_path), (
        f"Archive artifacts directory missing: {artifacts_path}"
    )


def test_archive_artifacts_has_structure_txt():
    """orionx-phoenix-structure.txt must be present in archive/artifacts/."""
    structure_path = os.path.join(
        ARCHIVE_DIR, "artifacts", "orionx-phoenix-structure.txt"
    )
    assert os.path.isfile(structure_path), (
        f"Structure file missing: {structure_path}"
    )


def test_archive_artifacts_has_orion_artifacts():
    """orion_artifacts subdirectory must exist in archive/artifacts/."""
    oa_path = os.path.join(ARCHIVE_DIR, "artifacts", "orion_artifacts")
    assert os.path.isdir(oa_path), (
        f"orion_artifacts directory missing: {oa_path}"
    )


# ---------------------------------------------------------------------------
# INVENTORY.md
# ---------------------------------------------------------------------------

def test_inventory_md_exists():
    """archive/INVENTORY.md must exist."""
    assert os.path.isfile(INVENTORY_PATH), (
        f"INVENTORY.md not found at {INVENTORY_PATH}"
    )


def test_inventory_md_has_version_table():
    """INVENTORY.md must contain a version progression table."""
    with open(INVENTORY_PATH) as f:
        content = f.read()
    assert "Version Progression" in content, (
        "INVENTORY.md missing 'Version Progression' section"
    )
    assert "v1.2.0" in content, "INVENTORY.md missing v1.2.0 entry"
    assert "v1.4.0" in content, "INVENTORY.md missing v1.4.0 entry"


def test_inventory_md_has_directory_structure():
    """INVENTORY.md must document the archive directory layout."""
    with open(INVENTORY_PATH) as f:
        content = f.read()
    assert "Directory Structure" in content, (
        "INVENTORY.md missing 'Directory Structure' section"
    )
    assert "versions/" in content, "INVENTORY.md missing versions/ reference"
    assert "artifacts/" in content, "INVENTORY.md missing artifacts/ reference"


def test_inventory_md_has_ideas_section():
    """INVENTORY.md must document ideas worth revisiting from legacy versions."""
    with open(INVENTORY_PATH) as f:
        content = f.read()
    assert "Ideas Worth Revisiting" in content, (
        "INVENTORY.md missing 'Ideas Worth Revisiting' section"
    )


# ---------------------------------------------------------------------------
# .gitignore configuration
# ---------------------------------------------------------------------------

def test_gitignore_excludes_archive():
    """.gitignore must have a rule to exclude archive/ directory."""
    with open(GITIGNORE_PATH) as f:
        content = f.read()
    assert "archive/" in content, (
        ".gitignore does not exclude archive/ directory"
    )


def test_gitignore_tracks_inventory_md():
    """.gitignore must have a negation rule for archive/INVENTORY.md."""
    with open(GITIGNORE_PATH) as f:
        content = f.read()
    assert "!archive/INVENTORY.md" in content, (
        ".gitignore missing negation rule for archive/INVENTORY.md"
    )


def test_inventory_md_is_not_gitignored():
    """Git must NOT ignore archive/INVENTORY.md (negation rule must work).

    Note: git check-ignore -v returns 0 for both ignored and negated files.
    For negated files, the output pattern starts with '!'. We verify the
    effective behavior by checking that INVENTORY.md appears in git status
    as untracked (not hidden by .gitignore).
    """
    # Approach: use git status --ignored to check if the file is truly ignored.
    # An un-ignored file shows as '??' (untracked) or tracked; an ignored file
    # shows as '!!' in --ignored --short output.
    result = subprocess.run(
        [
            "git", "-C", WORKTREE, "status", "--porcelain",
            "--ignored", "--", "archive/INVENTORY.md",
        ],
        capture_output=True,
        text=True,
    )
    # The file should NOT have '!!' prefix (ignored). It should be '??' or
    # tracked (empty output if already committed).
    for line in result.stdout.strip().splitlines():
        assert not line.startswith("!!"), (
            f"archive/INVENTORY.md is being gitignored! "
            f"git status output: {line}"
        )


def test_archive_contents_are_gitignored():
    """Files inside archive/ (except INVENTORY.md) must be gitignored."""
    # Test with a hypothetical file path
    test_path = os.path.join(ARCHIVE_DIR, "versions", "v1.4", "test.txt")
    result = subprocess.run(
        ["git", "-C", WORKTREE, "check-ignore", "-v", test_path],
        capture_output=True,
        text=True,
    )
    # check-ignore returns 0 if the file IS ignored
    assert result.returncode == 0, (
        "Files inside archive/versions/ are NOT being gitignored"
    )


# ---------------------------------------------------------------------------
# No .DS_Store files
# ---------------------------------------------------------------------------

def test_no_ds_store_in_archive():
    """No .DS_Store files should exist anywhere in the archive directory."""
    if not os.path.isdir(ARCHIVE_DIR):
        pytest.skip("Archive directory does not exist yet")
    ds_store_files = []
    for root, dirs, files in os.walk(ARCHIVE_DIR):
        for f in files:
            if f == ".DS_Store":
                ds_store_files.append(os.path.join(root, f))
    assert len(ds_store_files) == 0, (
        f".DS_Store files found in archive: {ds_store_files}"
    )


# ---------------------------------------------------------------------------
# docs/images/ architecture images
# ---------------------------------------------------------------------------

def test_docs_images_directory_exists():
    """docs/images/ directory must exist for architecture images."""
    assert os.path.isdir(DOCS_IMAGES_DIR), (
        f"docs/images/ directory missing: {DOCS_IMAGES_DIR}"
    )


def test_docs_images_has_architecture_diagram():
    """docs/images/ must contain architecture_diagram.png from v1.4."""
    arch_path = os.path.join(DOCS_IMAGES_DIR, "architecture_diagram.png")
    assert os.path.isfile(arch_path), (
        f"Architecture diagram missing: {arch_path}"
    )


# ---------------------------------------------------------------------------
# data/samples/pcaps/ sample data
# ---------------------------------------------------------------------------

def test_pcap_directory_exists():
    """data/samples/pcaps/ directory must exist."""
    assert os.path.isdir(PCAP_DIR), (
        f"PCAP sample directory missing: {PCAP_DIR}"
    )


def test_pcap_has_sample_data():
    """data/samples/pcaps/ must contain at least one .pcap file."""
    if not os.path.isdir(PCAP_DIR):
        pytest.skip("PCAP directory does not exist yet")
    pcap_files = [f for f in os.listdir(PCAP_DIR) if f.endswith(".pcap")]
    assert len(pcap_files) > 0, (
        f"No .pcap files found in {PCAP_DIR}"
    )


# ---------------------------------------------------------------------------
# Legacy .gitignore rule update
# ---------------------------------------------------------------------------

def test_gitignore_replaces_legacy_rule():
    """Old 'archive/legacy-orionx/' rule should be replaced with 'archive/*'.

    We use 'archive/*' (not 'archive/') so git enters the directory and
    the negation rule for INVENTORY.md can take effect.
    """
    with open(GITIGNORE_PATH) as f:
        content = f.read()
    lines = [line.strip() for line in content.splitlines()]
    # archive/* must be present (glob form so negation works)
    assert "archive/*" in lines, ".gitignore missing 'archive/*' rule"
    # The old specific rule is redundant and should be removed
    assert "archive/legacy-orionx/" not in lines, (
        ".gitignore still has obsolete 'archive/legacy-orionx/' rule — "
        "should be replaced by broader 'archive/*' rule"
    )
