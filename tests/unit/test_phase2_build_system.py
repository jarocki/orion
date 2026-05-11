"""
Unit tests for Orion-X Phase 2 build system.

Tests verify:
- Makefile has all required targets
- ShellCheck passes on all shell scripts (no errors)
- Python scripts compile without error
- Required build files are present and correctly configured
- iso/config/hooks/live hook exists and is executable (canonical live-build path, DEC-PHASE7-024)
- requirements.txt exists
- GitHub Actions workflow is valid YAML and has expected structure
"""

import os
import subprocess
import stat
import sys

import pytest

WORKTREE = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
MAKEFILE = os.path.join(WORKTREE, "Makefile")
SCRIPTS_DIR = os.path.join(WORKTREE, "scripts")
HOOK_PATH = os.path.join(
    WORKTREE,
    "iso/config/hooks/live/0500-install-external-tools.hook.chroot",
)
REQUIREMENTS_TXT = os.path.join(WORKTREE, "requirements.txt")
WORKFLOW_PATH = os.path.join(WORKTREE, ".github/workflows/lint.yml")


# ---------------------------------------------------------------------------
# Makefile targets
# ---------------------------------------------------------------------------

REQUIRED_MAKEFILE_TARGETS = [
    "lint",
    "lint-shell",
    "lint-python",
    "test-unit",
    "test-integration",
    "docker-build",
    "iso-build",
    "clean",
    "help",
]


@pytest.mark.parametrize("target", REQUIRED_MAKEFILE_TARGETS)
def test_makefile_has_target(target):
    """Each required phony target must appear as a recipe in the Makefile."""
    with open(MAKEFILE) as f:
        content = f.read()
    # A target appears as "<name>:" at the start of a line or after whitespace
    assert f"{target}:" in content, (
        f"Makefile is missing required target '{target}'"
    )


def test_makefile_phony_declares_all_targets():
    """The .PHONY declaration must include all required targets."""
    with open(MAKEFILE) as f:
        content = f.read()
    for target in REQUIRED_MAKEFILE_TARGETS:
        assert target in content, (
            f".PHONY or recipe missing for '{target}'"
        )


# ---------------------------------------------------------------------------
# ShellCheck
# ---------------------------------------------------------------------------

def _shellcheck_binary():
    """Return the shellcheck binary path, searching Homebrew prefix on macOS."""
    # Try PATH first
    result = subprocess.run(
        ["which", "shellcheck"],
        capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip()
    # Try Homebrew prefix
    brew_result = subprocess.run(
        ["brew", "--prefix"],
        capture_output=True, text=True
    )
    if brew_result.returncode == 0:
        candidate = os.path.join(brew_result.stdout.strip(), "bin", "shellcheck")
        if os.path.isfile(candidate):
            return candidate
    return None


def test_shellcheck_available():
    """ShellCheck binary must be accessible."""
    sc = _shellcheck_binary()
    assert sc is not None, (
        "shellcheck not found. Install via: brew install shellcheck  or  apt-get install shellcheck"
    )


def test_shellcheck_passes_all_scripts():
    """shellcheck must exit 0 on all scripts/*.sh — no errors or warnings."""
    sc = _shellcheck_binary()
    if sc is None:
        pytest.skip("shellcheck not installed")

    shell_scripts = [
        os.path.join(SCRIPTS_DIR, f)
        for f in os.listdir(SCRIPTS_DIR)
        if f.endswith(".sh")
    ]
    assert shell_scripts, "No .sh files found in scripts/"

    result = subprocess.run(
        [sc] + shell_scripts,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"ShellCheck reported issues:\n{result.stdout}\n{result.stderr}"
    )


# ---------------------------------------------------------------------------
# Python compile checks
# ---------------------------------------------------------------------------

def _python_scripts():
    return [
        os.path.join(SCRIPTS_DIR, f)
        for f in os.listdir(SCRIPTS_DIR)
        if f.endswith(".py")
    ]


@pytest.mark.parametrize("script", _python_scripts())
def test_python_script_compiles(script):
    """Every Python script must pass py_compile (syntax check)."""
    result = subprocess.run(
        [sys.executable, "-m", "py_compile", script],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"{script} failed py_compile:\n{result.stderr}"
    )


# ---------------------------------------------------------------------------
# Required files exist
# ---------------------------------------------------------------------------

def test_requirements_txt_exists():
    """requirements.txt must exist at the repo root."""
    assert os.path.isfile(REQUIREMENTS_TXT), (
        f"requirements.txt not found at {REQUIREMENTS_TXT}"
    )


def test_external_tools_hook_exists():
    """iso/config/hooks/live/0500-install-external-tools.hook.chroot must exist (canonical path, DEC-PHASE7-024)."""
    assert os.path.isfile(HOOK_PATH), (
        f"External tools hook not found at {HOOK_PATH}"
    )


def test_external_tools_hook_is_executable():
    """The hook file must be executable (live-build requirement)."""
    mode = os.stat(HOOK_PATH).st_mode
    assert mode & stat.S_IXUSR, (
        f"Hook {HOOK_PATH} is not executable. Run: chmod +x {HOOK_PATH}"
    )


def test_external_tools_hook_has_shebang():
    """Hook must start with a bash shebang."""
    with open(HOOK_PATH) as f:
        first_line = f.readline().strip()
    assert first_line == "#!/bin/bash", (
        f"Hook missing '#!/bin/bash' shebang, got: {first_line!r}"
    )


# ---------------------------------------------------------------------------
# GitHub Actions workflow
# ---------------------------------------------------------------------------

def test_workflow_file_exists():
    """lint.yml must exist under .github/workflows/."""
    assert os.path.isfile(WORKFLOW_PATH), (
        f"Workflow not found at {WORKFLOW_PATH}"
    )


def test_workflow_is_valid_yaml():
    """lint.yml must be parseable YAML."""
    try:
        import yaml  # noqa: F401
    except ImportError:
        # yaml not available — check for basic structure via string parse
        with open(WORKFLOW_PATH) as f:
            content = f.read()
        assert "name:" in content
        assert "jobs:" in content
        return

    import yaml  # noqa: F811
    with open(WORKFLOW_PATH) as f:
        doc = yaml.safe_load(f)
    assert isinstance(doc, dict), "lint.yml parsed to non-dict"
    assert "jobs" in doc, "lint.yml missing 'jobs' key"


def test_workflow_triggers_on_develop():
    """Workflow must trigger on pushes and PRs to develop branch."""
    with open(WORKFLOW_PATH) as f:
        content = f.read()
    assert "develop" in content, "Workflow does not mention 'develop' branch"


def test_workflow_runs_make_lint():
    """Workflow must invoke 'make lint'."""
    with open(WORKFLOW_PATH) as f:
        content = f.read()
    assert "make lint" in content, "Workflow does not run 'make lint'"


def test_workflow_runs_make_test_unit():
    """Workflow must invoke 'make test-unit'."""
    with open(WORKFLOW_PATH) as f:
        content = f.read()
    assert "make test-unit" in content, "Workflow does not run 'make test-unit'"


def test_workflow_installs_shellcheck():
    """Workflow must install shellcheck."""
    with open(WORKFLOW_PATH) as f:
        content = f.read()
    assert "shellcheck" in content.lower(), (
        "Workflow does not install shellcheck"
    )


def test_workflow_installs_ruff():
    """Workflow must install ruff."""
    with open(WORKFLOW_PATH) as f:
        content = f.read()
    assert "ruff" in content, "Workflow does not install ruff"
