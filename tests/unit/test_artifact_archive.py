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
- archive/ tracks exactly INVENTORY.md and README.md
- INVENTORY.md documents the (local, untracked) archive layout
- .gitignore properly excludes archive/ contents but tracks INVENTORY.md
- No .DS_Store file is tracked anywhere
- docs/images/ exists
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
#
# @decision DEC-PHASE12-110
# @title Archive tests assert TRACKED state, never one developer's local files
# @status accepted
# @rationale archive/* is gitignored: versions/ and artifacts/ exist only on the
#   machine that made them, so the old existence tests failed on every clean
#   clone and CI runner (8 of the 12 failures make test-unit hid, P1-2/F-01).
#   What the repo can promise is what it tracks: archive/ carries exactly
#   INVENTORY.md and README.md, and nothing tracked is a .DS_Store.
#   docs/images/architecture_diagram.png was deleted on purpose in 18a0d06
#   (byte-sized placeholder replaced by real screenshots), so its test is gone.
# ---------------------------------------------------------------------------


def _git_ls_files(*paths):
    result = subprocess.run(
        ["git", "-C", WORKTREE, "ls-files", "--", *paths],
        capture_output=True, text=True, check=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def test_archive_tracks_only_inventory_and_readme():
    """archive/ must track exactly INVENTORY.md and README.md (the rest is local)."""
    assert sorted(_git_ls_files("archive")) == [
        "archive/INVENTORY.md", "archive/README.md",
    ]


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

def test_no_ds_store_tracked():
    """No .DS_Store may be tracked anywhere (local ones are gitignored and harmless)."""
    tracked = [p for p in _git_ls_files() if os.path.basename(p) == ".DS_Store"]
    assert tracked == [], f".DS_Store files tracked in git: {tracked}"


# ---------------------------------------------------------------------------
# docs/images/ architecture images
# ---------------------------------------------------------------------------

def test_docs_images_directory_exists():
    """docs/images/ directory must exist for architecture images."""
    assert os.path.isdir(DOCS_IMAGES_DIR), (
        f"docs/images/ directory missing: {DOCS_IMAGES_DIR}"
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
