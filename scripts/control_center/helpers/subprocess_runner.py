"""
Orion-X Control Center — safe subprocess wrappers.

Rules enforced here:
  - shell=True is NEVER used (DEC-PHASE9-019 / security hygiene).
  - All commands are passed as a list of strings.
  - Timeouts are mandatory so a stalled tool cannot hang the UI event loop.
  - Stdout/stderr are captured; the caller decides what to display.

@decision DEC-PHASE9-019
@title Bullseye Python 3.9 + PEP-563 (from __future__ import annotations)
@status accepted
@rationale All shipped Python in Phase 9 / Phase 10 must start with
  `from __future__ import annotations` immediately after any shebang/docstring
  to guarantee forward-compatible annotation evaluation under Python 3.9
  (Debian Bullseye's default interpreter). This also enables ruff to enforce
  PEP 563 consistently (DEC-PHASE9-020).
"""
from __future__ import annotations

import subprocess
from typing import Optional


def run(
    args: list[str],
    timeout: int = 10,
    input_text: Optional[str] = None,
) -> tuple[int, str, str]:
    """Run *args* safely (no shell=True) and return (returncode, stdout, stderr).

    Parameters
    ----------
    args:
        Command and arguments as a list; the first element is the executable.
    timeout:
        Seconds before the subprocess is killed.  Defaults to 10 s.
    input_text:
        Optional string piped to the process stdin.

    Returns
    -------
    (returncode, stdout, stderr)
        returncode is the process exit code; stdout and stderr are decoded
        strings (empty string when nothing was written).
    """
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            input=input_text,
        )
        return result.returncode, result.stdout, result.stderr
    except FileNotFoundError:
        return 127, "", f"command not found: {args[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", f"command timed out after {timeout}s: {' '.join(args)}"
    except OSError as exc:
        return 1, "", f"OS error running {args[0]}: {exc}"


def run_ok(args: list[str], timeout: int = 10) -> bool:
    """Return True when *args* exits 0, False otherwise."""
    rc, _out, _err = run(args, timeout=timeout)
    return rc == 0


def run_stdout(args: list[str], timeout: int = 10) -> str:
    """Return stripped stdout of *args*, or empty string on failure."""
    _rc, out, _err = run(args, timeout=timeout)
    return out.strip()
