"""
Unit tests for Python requirements files.

@decision DEC-REQS-001
@title Test suite for requirements.txt and requirements-dev.txt
@status accepted
@rationale Validates that both requirements files exist, are pip-parseable,
  have correct structure (runtime vs dev separation), and that
  requirements-dev.txt includes requirements.txt via -r directive.
  Tests run against real filesystem state, not mocks.

Tests verify:
- requirements.txt exists and is valid pip format
- requirements-dev.txt exists and is valid pip format
- requirements.txt contains only runtime dependencies
- requirements-dev.txt references requirements.txt via -r
- requirements-dev.txt contains dev-only packages (pytest, ruff)
- Neither file contains duplicate packages
- Runtime deps don't include dev-only packages
- Both files have descriptive header comments
"""

import os
import re
import subprocess

import pytest

WORKTREE = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
REQUIREMENTS_TXT = os.path.join(WORKTREE, "requirements.txt")
REQUIREMENTS_DEV_TXT = os.path.join(WORKTREE, "requirements-dev.txt")


def _parse_packages(filepath):
    """Extract package names (lowercase) from a requirements file.

    Ignores comments, blank lines, and -r directives.
    Returns a list of (package_name, full_line) tuples.
    """
    packages = []
    with open(filepath) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("-r"):
                continue
            # Extract package name (before any version specifier)
            match = re.match(r"^([a-zA-Z0-9_-]+)", stripped)
            if match:
                packages.append((match.group(1).lower(), stripped))
    return packages


# ---------------------------------------------------------------------------
# requirements.txt — existence and structure
# ---------------------------------------------------------------------------


def test_requirements_txt_exists():
    """requirements.txt must exist in the project root."""
    assert os.path.isfile(REQUIREMENTS_TXT), (
        f"requirements.txt not found at {REQUIREMENTS_TXT}"
    )


def test_requirements_txt_has_header_comment():
    """requirements.txt must have a descriptive header comment."""
    with open(REQUIREMENTS_TXT) as f:
        content = f.read()
    assert "Runtime" in content or "runtime" in content, (
        "requirements.txt should mention 'runtime' in its header to clarify scope"
    )


def test_requirements_txt_references_dev_file():
    """requirements.txt header should reference requirements-dev.txt."""
    with open(REQUIREMENTS_TXT) as f:
        content = f.read()
    assert "requirements-dev.txt" in content, (
        "requirements.txt should reference requirements-dev.txt for dev deps"
    )


def test_requirements_txt_has_runtime_deps():
    """requirements.txt must contain at least one runtime dependency."""
    packages = _parse_packages(REQUIREMENTS_TXT)
    assert len(packages) > 0, (
        "requirements.txt has no runtime dependencies listed"
    )


def test_requirements_txt_contains_volatility3():
    """volatility3 must be in requirements.txt (installed via pip on ISO)."""
    packages = _parse_packages(REQUIREMENTS_TXT)
    pkg_names = [name for name, _ in packages]
    assert "volatility3" in pkg_names, (
        "volatility3 missing from requirements.txt — it is installed via pip on the ISO"
    )


def test_requirements_txt_contains_scapy():
    """scapy must be in requirements.txt (forensic network analysis)."""
    packages = _parse_packages(REQUIREMENTS_TXT)
    pkg_names = [name for name, _ in packages]
    assert "scapy" in pkg_names, (
        "scapy missing from requirements.txt — used for forensic network analysis"
    )


def test_requirements_txt_no_dev_packages():
    """requirements.txt must NOT contain dev-only packages."""
    dev_only = {"pytest", "pytest-cov", "ruff", "flake8", "mypy", "black"}
    packages = _parse_packages(REQUIREMENTS_TXT)
    pkg_names = {name for name, _ in packages}
    found_dev = pkg_names & dev_only
    assert not found_dev, (
        f"Dev packages found in requirements.txt (should be in requirements-dev.txt): "
        f"{found_dev}"
    )


def test_requirements_txt_no_duplicates():
    """requirements.txt must not contain duplicate package entries."""
    packages = _parse_packages(REQUIREMENTS_TXT)
    pkg_names = [name for name, _ in packages]
    seen = set()
    duplicates = []
    for name in pkg_names:
        if name in seen:
            duplicates.append(name)
        seen.add(name)
    assert not duplicates, (
        f"Duplicate packages in requirements.txt: {duplicates}"
    )


def test_requirements_txt_has_version_specifiers():
    """Each package in requirements.txt should have a version specifier."""
    packages = _parse_packages(REQUIREMENTS_TXT)
    missing_version = []
    for name, line in packages:
        if not re.search(r"[><=!~]", line):
            missing_version.append(name)
    assert not missing_version, (
        f"Packages without version specifiers in requirements.txt: {missing_version}"
    )


# ---------------------------------------------------------------------------
# requirements-dev.txt — existence and structure
# ---------------------------------------------------------------------------


def test_requirements_dev_txt_exists():
    """requirements-dev.txt must exist in the project root."""
    assert os.path.isfile(REQUIREMENTS_DEV_TXT), (
        f"requirements-dev.txt not found at {REQUIREMENTS_DEV_TXT}"
    )


def test_requirements_dev_txt_includes_runtime():
    """requirements-dev.txt must include requirements.txt via -r directive."""
    with open(REQUIREMENTS_DEV_TXT) as f:
        content = f.read()
    assert "-r requirements.txt" in content, (
        "requirements-dev.txt must include '-r requirements.txt' to inherit runtime deps"
    )


def test_requirements_dev_txt_has_header_comment():
    """requirements-dev.txt must have a descriptive header comment."""
    with open(REQUIREMENTS_DEV_TXT) as f:
        content = f.read()
    assert "Development" in content or "development" in content or "dev" in content.lower(), (
        "requirements-dev.txt should mention 'development' in its header"
    )


def test_requirements_dev_txt_has_pytest():
    """requirements-dev.txt must include pytest."""
    packages = _parse_packages(REQUIREMENTS_DEV_TXT)
    pkg_names = [name for name, _ in packages]
    assert "pytest" in pkg_names, (
        "pytest missing from requirements-dev.txt"
    )


def test_requirements_dev_txt_has_pytest_cov():
    """requirements-dev.txt must include pytest-cov."""
    packages = _parse_packages(REQUIREMENTS_DEV_TXT)
    pkg_names = [name for name, _ in packages]
    assert "pytest-cov" in pkg_names, (
        "pytest-cov missing from requirements-dev.txt"
    )


def test_requirements_dev_txt_has_ruff():
    """requirements-dev.txt must include ruff."""
    packages = _parse_packages(REQUIREMENTS_DEV_TXT)
    pkg_names = [name for name, _ in packages]
    assert "ruff" in pkg_names, (
        "ruff missing from requirements-dev.txt"
    )


def test_requirements_dev_txt_no_duplicates():
    """requirements-dev.txt must not contain duplicate package entries."""
    packages = _parse_packages(REQUIREMENTS_DEV_TXT)
    pkg_names = [name for name, _ in packages]
    seen = set()
    duplicates = []
    for name in pkg_names:
        if name in seen:
            duplicates.append(name)
        seen.add(name)
    assert not duplicates, (
        f"Duplicate packages in requirements-dev.txt: {duplicates}"
    )


def test_requirements_dev_txt_has_version_specifiers():
    """Each package in requirements-dev.txt should have a version specifier."""
    packages = _parse_packages(REQUIREMENTS_DEV_TXT)
    missing_version = []
    for name, line in packages:
        if not re.search(r"[><=!~]", line):
            missing_version.append(name)
    assert not missing_version, (
        f"Packages without version specifiers in requirements-dev.txt: {missing_version}"
    )


# ---------------------------------------------------------------------------
# pip syntax validation
# ---------------------------------------------------------------------------


def test_requirements_txt_pip_parseable():
    """requirements.txt must be parseable by pip (no syntax errors)."""
    result = subprocess.run(
        ["python3", "-m", "pip", "install", "--dry-run", "-r", REQUIREMENTS_TXT],
        capture_output=True,
        text=True,
    )
    # pip dry-run may fail for missing packages but should not fail for syntax
    # A syntax error produces "Invalid requirement" in stderr
    assert "Invalid requirement" not in result.stderr, (
        f"requirements.txt has pip syntax errors: {result.stderr}"
    )


def test_requirements_dev_txt_pip_parseable():
    """requirements-dev.txt must be parseable by pip (no syntax errors)."""
    result = subprocess.run(
        ["python3", "-m", "pip", "install", "--dry-run", "-r", REQUIREMENTS_DEV_TXT],
        capture_output=True,
        text=True,
    )
    assert "Invalid requirement" not in result.stderr, (
        f"requirements-dev.txt has pip syntax errors: {result.stderr}"
    )


# ---------------------------------------------------------------------------
# Cross-file consistency
# ---------------------------------------------------------------------------


def test_dev_does_not_duplicate_runtime_deps():
    """Dev file should not re-list packages already in requirements.txt.

    Since requirements-dev.txt includes -r requirements.txt, any package
    already in requirements.txt does not need to be repeated.
    """
    runtime_packages = {name for name, _ in _parse_packages(REQUIREMENTS_TXT)}
    dev_packages = {name for name, _ in _parse_packages(REQUIREMENTS_DEV_TXT)}
    duplicated = runtime_packages & dev_packages
    assert not duplicated, (
        f"Packages listed in both files (remove from requirements-dev.txt, "
        f"they're inherited via -r): {duplicated}"
    )
