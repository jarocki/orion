"""
Unit tests for Orion-X Phase 3 mesh CLI skeleton (orionx-mesh).

Tests verify:
- CLI script exists and is executable
- ShellCheck passes on all mesh scripts
- Help output matches expected format
- Subcommand routing works correctly
- Root check is present (tested via grep, not by running as root)
- Status command shows "Mesh: inactive" when no mesh is active
- Unknown commands produce error + usage and exit non-zero
- Global flags are parsed (--help, --verbose, --config)
- mesh-lib.sh stub exists and is ShellCheck clean

Production sequence: An incident responder boots Orion-X, opens a terminal,
and runs `orionx-mesh status` to check if a mesh is active, then
`orionx-mesh join` to create or join one. These tests exercise that
real-world sequence: help → status (inactive) → join (stub) → unknown cmd.
"""

import os
import stat
import subprocess

import pytest

WORKTREE = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
CLI_SCRIPT = os.path.join(WORKTREE, "scripts", "mesh", "orionx-mesh")
MESH_LIB = os.path.join(WORKTREE, "scripts", "mesh", "mesh-lib.sh")
SCRIPTS_MESH_DIR = os.path.join(WORKTREE, "scripts", "mesh")


def _shellcheck_binary():
    """Return the shellcheck binary path."""
    result = subprocess.run(
        ["which", "shellcheck"],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def _run_cli(*args, env_override=None):
    """Run the CLI script with bash (bypasses root check via ORIONX_SKIP_ROOT_CHECK).

    We run with bash explicitly so we don't need the script to be on PATH.
    We set ORIONX_SKIP_ROOT_CHECK=1 so tests can run as non-root user.
    """
    env = os.environ.copy()
    env["ORIONX_SKIP_ROOT_CHECK"] = "1"
    if env_override:
        env.update(env_override)
    result = subprocess.run(
        ["bash", CLI_SCRIPT] + list(args),
        capture_output=True,
        text=True,
        env=env,
        cwd=WORKTREE,
    )
    return result


# ---------------------------------------------------------------------------
# File existence and permissions
# ---------------------------------------------------------------------------


class TestFileStructure:
    """Verify mesh CLI files exist with correct properties."""

    def test_cli_script_exists(self):
        """orionx-mesh CLI script must exist."""
        assert os.path.isfile(CLI_SCRIPT), (
            f"CLI script not found at {CLI_SCRIPT}"
        )

    def test_cli_script_is_executable(self):
        """orionx-mesh must be executable."""
        mode = os.stat(CLI_SCRIPT).st_mode
        assert mode & stat.S_IXUSR, (
            f"{CLI_SCRIPT} is not executable. Run: chmod +x {CLI_SCRIPT}"
        )

    def test_cli_script_has_bash_shebang(self):
        """orionx-mesh must start with bash shebang."""
        with open(CLI_SCRIPT) as f:
            first_line = f.readline().strip()
        assert first_line == "#!/usr/bin/env bash", (
            f"Expected '#!/usr/bin/env bash' shebang, got: {first_line!r}"
        )

    def test_mesh_lib_exists(self):
        """mesh-lib.sh stub must exist."""
        assert os.path.isfile(MESH_LIB), (
            f"mesh-lib.sh not found at {MESH_LIB}"
        )

    def test_cli_has_set_euo_pipefail(self):
        """Script must use strict mode: set -euo pipefail."""
        with open(CLI_SCRIPT) as f:
            content = f.read()
        assert "set -euo pipefail" in content, (
            "CLI script missing 'set -euo pipefail'"
        )

    def test_cli_has_shellcheck_directive(self):
        """Script must have shellcheck shell=bash directive."""
        with open(CLI_SCRIPT) as f:
            content = f.read()
        assert "# shellcheck shell=bash" in content, (
            "CLI script missing '# shellcheck shell=bash' directive"
        )

    def test_cli_has_decision_annotation(self):
        """Script must have @decision DEC-MESH-004 annotation."""
        with open(CLI_SCRIPT) as f:
            content = f.read()
        assert "@decision DEC-MESH-004" in content, (
            "CLI script missing @decision DEC-MESH-004 annotation"
        )

    def test_cli_sources_mesh_lib(self):
        """Script must source mesh-lib.sh."""
        with open(CLI_SCRIPT) as f:
            content = f.read()
        assert "mesh-lib.sh" in content, (
            "CLI script does not source mesh-lib.sh"
        )


# ---------------------------------------------------------------------------
# ShellCheck
# ---------------------------------------------------------------------------


class TestShellCheck:
    """Verify all mesh scripts pass ShellCheck."""

    def test_shellcheck_available(self):
        """ShellCheck must be installed."""
        assert _shellcheck_binary() is not None, (
            "shellcheck not found"
        )

    def test_shellcheck_cli_script(self):
        """orionx-mesh must pass ShellCheck."""
        sc = _shellcheck_binary()
        if sc is None:
            pytest.skip("shellcheck not installed")
        result = subprocess.run(
            [sc, CLI_SCRIPT],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, (
            f"ShellCheck errors in orionx-mesh:\n{result.stdout}\n{result.stderr}"
        )

    def test_shellcheck_mesh_lib(self):
        """mesh-lib.sh must pass ShellCheck."""
        sc = _shellcheck_binary()
        if sc is None:
            pytest.skip("shellcheck not installed")
        result = subprocess.run(
            [sc, MESH_LIB],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, (
            f"ShellCheck errors in mesh-lib.sh:\n{result.stdout}\n{result.stderr}"
        )


# ---------------------------------------------------------------------------
# Help / Usage output
# ---------------------------------------------------------------------------


class TestHelpOutput:
    """Verify help and usage output format."""

    def test_help_subcommand(self):
        """'orionx-mesh help' must print usage and exit 0."""
        result = _run_cli("help")
        assert result.returncode == 0, (
            f"'help' exited {result.returncode}: {result.stderr}"
        )
        assert "Usage: orionx-mesh" in result.stdout

    def test_help_flag(self):
        """'orionx-mesh --help' must print usage and exit 0."""
        result = _run_cli("--help")
        assert result.returncode == 0
        assert "Usage: orionx-mesh" in result.stdout

    def test_help_short_flag(self):
        """'orionx-mesh -h' must print usage and exit 0."""
        result = _run_cli("-h")
        assert result.returncode == 0
        assert "Usage: orionx-mesh" in result.stdout

    def test_no_args_shows_help(self):
        """'orionx-mesh' with no args must show usage and exit 0."""
        result = _run_cli()
        assert result.returncode == 0
        assert "Usage: orionx-mesh" in result.stdout

    def test_help_contains_version(self):
        """Help must include version string."""
        result = _run_cli("help")
        assert "v2.0.0" in result.stdout

    def test_help_lists_all_commands(self):
        """Help must list all subcommands."""
        result = _run_cli("help")
        for cmd in ["join", "status", "peers", "leave", "help"]:
            assert cmd in result.stdout, (
                f"Help output missing '{cmd}' command"
            )

    def test_help_lists_global_options(self):
        """Help must list global options."""
        result = _run_cli("help")
        assert "--config" in result.stdout
        assert "--verbose" in result.stdout
        assert "--help" in result.stdout

    def test_help_has_examples(self):
        """Help must include usage examples."""
        result = _run_cli("help")
        assert "Examples:" in result.stdout


# ---------------------------------------------------------------------------
# Subcommand routing
# ---------------------------------------------------------------------------


class TestSubcommandRouting:
    """Verify subcommands are routed correctly."""

    def test_status_inactive(self):
        """'orionx-mesh status' must show 'Mesh: inactive' when no mesh."""
        result = _run_cli("status")
        assert result.returncode == 0
        assert "inactive" in result.stdout.lower(), (
            f"Expected 'inactive' in status output, got: {result.stdout}"
        )

    def test_join_stub(self):
        """'orionx-mesh join' must print stub message and exit 0."""
        result = _run_cli("join")
        assert result.returncode == 0
        assert "not yet implemented" in result.stdout.lower(), (
            f"Expected stub message, got: {result.stdout}"
        )

    def test_leave_stub(self):
        """'orionx-mesh leave' must print stub message and exit 0."""
        result = _run_cli("leave")
        assert result.returncode == 0
        assert "not yet implemented" in result.stdout.lower(), (
            f"Expected stub message, got: {result.stdout}"
        )

    def test_peers_not_in_mesh(self):
        """'orionx-mesh peers' with no mesh must exit non-zero."""
        result = _run_cli("peers")
        assert result.returncode != 0, (
            "'peers' should exit non-zero when no mesh is active"
        )
        # Should indicate not in a mesh
        combined = result.stdout + result.stderr
        assert "not in a mesh" in combined.lower() or "not active" in combined.lower(), (
            f"Expected 'not in a mesh' message, got: {combined}"
        )

    def test_unknown_command_exits_nonzero(self):
        """Unknown command must exit non-zero."""
        result = _run_cli("unknown-cmd")
        assert result.returncode != 0, (
            "Unknown command should exit non-zero"
        )

    def test_unknown_command_shows_error(self):
        """Unknown command must show error message."""
        result = _run_cli("unknown-cmd")
        combined = result.stdout + result.stderr
        assert "unknown" in combined.lower() or "unknown-cmd" in combined.lower(), (
            f"Expected error about unknown command, got: {combined}"
        )

    def test_unknown_command_shows_usage(self):
        """Unknown command must also show usage."""
        result = _run_cli("unknown-cmd")
        combined = result.stdout + result.stderr
        assert "Usage:" in combined, (
            f"Expected usage info after unknown command, got: {combined}"
        )


# ---------------------------------------------------------------------------
# Global flags
# ---------------------------------------------------------------------------


class TestGlobalFlags:
    """Verify global flag parsing."""

    def test_verbose_flag_accepted(self):
        """'--verbose' flag must be accepted without error."""
        result = _run_cli("--verbose", "status")
        assert result.returncode == 0

    def test_verbose_short_flag_accepted(self):
        """'-v' flag must be accepted without error."""
        result = _run_cli("-v", "status")
        assert result.returncode == 0

    def test_config_flag_accepted(self):
        """'--config <file>' flag must be accepted without error."""
        result = _run_cli("--config", "/tmp/test.conf", "status")
        assert result.returncode == 0

    def test_help_flag_before_command(self):
        """'--help' before a command should show help, not run command."""
        result = _run_cli("--help", "status")
        assert result.returncode == 0
        assert "Usage:" in result.stdout


# ---------------------------------------------------------------------------
# Root check (structural)
# ---------------------------------------------------------------------------


class TestRootCheck:
    """Verify the root permission check is present in the script."""

    def test_root_check_present(self):
        """Script must check for root/EUID."""
        with open(CLI_SCRIPT) as f:
            content = f.read()
        assert "EUID" in content or "id -u" in content, (
            "CLI script missing root permission check"
        )

    def test_root_check_skip_env_var(self):
        """Script must support ORIONX_SKIP_ROOT_CHECK for testing."""
        with open(CLI_SCRIPT) as f:
            content = f.read()
        assert "ORIONX_SKIP_ROOT_CHECK" in content, (
            "CLI script missing ORIONX_SKIP_ROOT_CHECK bypass for testing"
        )


# ---------------------------------------------------------------------------
# Production sequence: responder workflow
# ---------------------------------------------------------------------------


class TestProductionSequence:
    """Test the actual production sequence an incident responder follows.

    Sequence: check status (inactive) → try help → join (stub) → status again.
    This exercises the common workflow where a responder boots up, checks
    mesh state, reads help, then attempts to join.
    """

    def test_responder_workflow(self):
        """Full responder workflow: status → help → join → status."""
        # Step 1: Responder checks if mesh is active
        r1 = _run_cli("status")
        assert r1.returncode == 0
        assert "inactive" in r1.stdout.lower()

        # Step 2: Responder reads help to learn commands
        r2 = _run_cli("help")
        assert r2.returncode == 0
        assert "join" in r2.stdout

        # Step 3: Responder tries to join mesh
        r3 = _run_cli("join")
        assert r3.returncode == 0
        # For now it's a stub
        assert "not yet implemented" in r3.stdout.lower()

        # Step 4: Check status again (still inactive since join is stub)
        r4 = _run_cli("status")
        assert r4.returncode == 0
        assert "inactive" in r4.stdout.lower()

    def test_responder_typo_recovery(self):
        """Responder types wrong command, sees help, then corrects."""
        # Step 1: Typo
        r1 = _run_cli("joinn")
        assert r1.returncode != 0
        combined = r1.stdout + r1.stderr
        assert "Usage:" in combined

        # Step 2: Corrects to proper command
        r2 = _run_cli("join")
        assert r2.returncode == 0
