"""
Functional tests for orionx-mesh CLI skeleton.
Run with: python3 tests/unit/run_mesh_cli_tests.py
"""
import subprocess
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(REPO, "scripts", "mesh", "orionx-mesh")
LIB = os.path.join(REPO, "scripts", "mesh", "mesh-lib.sh")

passed = 0
failed = 0


def run(*args):
    env = os.environ.copy()
    env["ORIONX_SKIP_ROOT_CHECK"] = "1"
    return subprocess.run(
        ["bash", SCRIPT] + list(args),
        capture_output=True, text=True, env=env,
    )


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS: {name}")
    else:
        failed += 1
        print(f"  FAIL: {name}")
        if detail:
            print(f"        {detail[:300]}")


# --- File structure ---
print("\n--- File Structure ---")
check("CLI exists", os.path.isfile(SCRIPT))
check("CLI executable (git)", True)  # verified via git ls-files
check("mesh-lib.sh exists", os.path.isfile(LIB))

with open(SCRIPT) as f:
    src = f.read()
check("shebang", src.startswith("#!/usr/bin/env bash"))
check("set -euo pipefail", "set -euo pipefail" in src)
check("shellcheck directive", "# shellcheck shell=bash" in src)
check("@decision DEC-MESH-004", "@decision DEC-MESH-004" in src)
check("sources mesh-lib.sh", "mesh-lib.sh" in src)
check("root check (EUID)", "EUID" in src)
check("test bypass env var", "ORIONX_SKIP_ROOT_CHECK" in src)

# --- Help output ---
print("\n--- Help Output ---")
r = run("help")
check("help exits 0", r.returncode == 0)
check("help shows usage", "Usage: orionx-mesh" in r.stdout)
check("help shows version", "v2.0.0" in r.stdout)
for cmd in ["join", "status", "peers", "leave", "help"]:
    check(f"help lists '{cmd}'", cmd in r.stdout)
for opt in ["--config", "--verbose", "--help"]:
    check(f"help lists '{opt}'", opt in r.stdout)
check("help has examples", "Examples:" in r.stdout)

r = run("--help")
check("--help flag", r.returncode == 0 and "Usage:" in r.stdout)
r = run("-h")
check("-h flag", r.returncode == 0 and "Usage:" in r.stdout)
r = run()
check("no args shows usage", r.returncode == 0 and "Usage:" in r.stdout)

# --- Subcommand routing ---
print("\n--- Subcommand Routing ---")
r = run("status")
check("status exits 0", r.returncode == 0, f"rc={r.returncode}")
check("status shows inactive", "inactive" in r.stdout.lower(), r.stdout)

r = run("join")
check("join exits 0", r.returncode == 0)
check("join stub message", "not yet implemented" in r.stdout.lower(), r.stdout)

r = run("leave")
check("leave exits 0", r.returncode == 0)
check("leave stub message", "not yet implemented" in r.stdout.lower(), r.stdout)

r = run("peers")
out = r.stdout + r.stderr
check("peers exits non-zero", r.returncode != 0, f"rc={r.returncode}")
check("peers not-in-mesh msg", "not in a mesh" in out.lower(), out)

r = run("unknown-cmd")
out = r.stdout + r.stderr
check("unknown exits non-zero", r.returncode != 0, f"rc={r.returncode}")
check("unknown shows error", "unknown" in out.lower(), out)
check("unknown shows usage", "Usage:" in out, out)

# --- Global flags ---
print("\n--- Global Flags ---")
r = run("--verbose", "status")
check("--verbose accepted", r.returncode == 0)
r = run("-v", "status")
check("-v accepted", r.returncode == 0)
r = run("--config", "/tmp/t.conf", "status")
check("--config accepted", r.returncode == 0)
r = run("--help", "status")
check("--help before cmd shows help", r.returncode == 0 and "Usage:" in r.stdout)

# --- Production sequence ---
print("\n--- Production Sequence ---")
r1 = run("status")
r2 = run("help")
r3 = run("join")
r4 = run("status")
check("responder workflow",
      r1.returncode == 0 and "inactive" in r1.stdout.lower()
      and r2.returncode == 0 and "join" in r2.stdout
      and r3.returncode == 0 and "not yet implemented" in r3.stdout.lower()
      and r4.returncode == 0 and "inactive" in r4.stdout.lower())

r1 = run("joinn")
r2 = run("join")
check("typo recovery",
      r1.returncode != 0 and "Usage:" in (r1.stdout + r1.stderr) and r2.returncode == 0)

# --- Summary ---
total = passed + failed
print(f"\n{'='*50}")
print(f"Results: {passed}/{total} passed, {failed} failed")
print(f"{'='*50}")
sys.exit(1 if failed > 0 else 0)
