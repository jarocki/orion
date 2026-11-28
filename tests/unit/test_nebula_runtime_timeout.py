"""`nebula start` when the runtime takes longer than the systemctl limit.

Measured on the v3.2.0 image in QEMU (2026-11-27): nebula-runtime waits for
nebula-integrity-check, which hashed the model for over 120 s, and `nebula
start` died with a TimeoutExpired traceback.
"""
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from nebula import runtime_ctl as R  # noqa: E402


def test_run_turns_a_timeout_into_rc_124(monkeypatch):
    def slow(argv, **kw):
        raise subprocess.TimeoutExpired(argv, kw.get("timeout"))
    monkeypatch.setattr(R.subprocess, "run", slow)
    r = R.run(["systemctl", "start", R.RUNTIME_UNIT])
    assert r.returncode == 124 and "still waiting" in r.stderr


def test_start_that_is_still_starting_says_so_without_a_traceback():
    said = []

    def runner(argv):
        if argv[1] == "is-active":
            return subprocess.CompletedProcess(argv, 3, "activating\n", "")
        return subprocess.CompletedProcess(argv, 124, "", "still waiting after 300 s")

    assert R.start(runner=runner, say=said.append) == 1
    assert "still starting" in said[-1] and "integrity" in said[-1] and "nebula status" in said[-1]
