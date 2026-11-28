#!/usr/bin/env bash
# shellcheck shell=bash
#
# Unit tests for scripts/nebula/runtime_ctl.py (`nebula stop` / `nebula start`).
#
# Checks DEC-PHASE13-070 (scripts/nebula/runtime_ctl.py). Every effect in runtime_ctl is injectable (runner, http, meminfo),
#   so the order and outcome are checked without ollama or systemd: a loaded
#   model is unloaded with keep_alive 0 BEFORE systemctl stop; a dead server
#   still stops the runtime; a refused systemctl exits 1 and says so; an
#   already-stopped runtime is exit 0 with no systemctl stop; start reports.
#
# Usage: bash tests/unit/test_nebula_runtime_ctl.sh
# Exit:  0 all tests passed, 1 one or more failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

out="$(PYTHONPATH="$REPO_ROOT/scripts" python3 - "$REPO_ROOT" <<'PY'
from __future__ import annotations
import subprocess, sys, tempfile, os
from nebula import runtime_ctl as R

results = []
def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))

class Sys:
    """systemctl stub: `active` is the runtime's state; stop/start flip it unless refused."""
    def __init__(self, active, refuse=False):
        self.active, self.refuse, self.calls = active, refuse, []
    def __call__(self, argv):
        self.calls.append(argv)
        rc, err = 0, ""
        if argv[1] == "is-active":
            rc = 0 if self.active else 3
        elif argv[1] in ("stop", "start"):
            if self.refuse:
                rc, err = 1, "Failed to stop: Access denied"
            else:
                self.active = argv[1] == "start"
        return subprocess.CompletedProcess(argv, rc, "", err)

def http_with(models, down=False):
    calls = []
    def http(method, url, body, timeout):
        calls.append((method, url, body))
        if down:
            raise OSError("connection refused")
        if url.endswith("/api/ps"):
            return {"models": [{"name": m} for m in models]}
        return {}
    return http, calls

base = os.path.join(sys.argv[1], "tmp")          # project tmp/, never /tmp
os.makedirs(base, exist_ok=True)
d = tempfile.mkdtemp(prefix="nebula-rt-", dir=base)
mi = os.path.join(d, "meminfo")
with open(mi, "w") as fh:
    fh.write("MemTotal: 8000000 kB\nMemAvailable: 1000000 kB\n")

# 1. stop with a loaded model: unload (keep_alive 0) happens before systemctl stop.
s = Sys(active=True); http, hc = http_with(["qwen2.5:3b"]); said = []
order = []
def sys_log(argv):
    order.append(("sys", argv[1])); return s(argv)
def http_log(m, u, b, t):
    order.append(("http", u.rsplit("/", 1)[-1])); return http(m, u, b, t)
rc = R.stop(runner=sys_log, http=http_log, meminfo=mi, say=said.append)
check("stop with loaded model exits 0", rc == 0, f"rc={rc} said={said}")
check("unload POST carries keep_alive 0",
      any(c[0] == "POST" and c[2] == {"model": "qwen2.5:3b", "keep_alive": 0} for c in hc), str(hc))
gen = order.index(("http", "generate")); stp = order.index(("sys", "stop"))
check("model unloaded before systemctl stop", gen < stp, str(order))
check("stop stops warm-up and runtime",
      ["systemctl", "stop", "nebula-warmup.service", "nebula-runtime.service"] in s.calls, str(s.calls))
check("stop reports the unload and the stop", any("Unloaded qwen2.5:3b" in x for x in said)
      and any(x.startswith("Nebula stopped") for x in said), str(said))
check("no sudo/pkexec in any argv", all(a[0] == "systemctl" for a in s.calls), str(s.calls))

# 2. server down: still stops the runtime, exit 0.
s = Sys(active=True); http, _ = http_with([], down=True); said = []
rc = R.stop(runner=s, http=http, meminfo=mi, say=said.append)
check("server down: stop still exits 0", rc == 0 and not s.active, f"rc={rc} said={said}")
check("server down: says it did not answer", any("did not answer" in x for x in said), str(said))

# 3. systemctl refused: exit 1 and say so.
s = Sys(active=True, refuse=True); http, _ = http_with([]); said = []
rc = R.stop(runner=s, http=http, meminfo=mi, say=said.append)
check("refused stop exits 1", rc == 1, f"rc={rc}")
check("refused stop names the failure", any("FAILED to stop" in x and "Access denied" in x for x in said), str(said))

# 4. already stopped: exit 0, no stop call.
s = Sys(active=False); http, hc = http_with([]); said = []
rc = R.stop(runner=s, http=http, meminfo=mi, say=said.append)
check("already stopped exits 0", rc == 0, f"rc={rc}")
check("already stopped issues no stop and no HTTP", not any(a[1] == "stop" for a in s.calls) and not hc, str(s.calls))

# 5. start.
s = Sys(active=False); said = []
rc = R.start(runner=s, say=said.append)
check("start exits 0 and runtime is active", rc == 0 and s.active, f"rc={rc}")
check("start points at nebula warmup", any("nebula warmup" in x for x in said), str(said))
s = Sys(active=False, refuse=True); said = []
rc = R.start(runner=s, say=said.append)
check("refused start exits 1", rc == 1 and any("FAILED to start" in x for x in said), str(said))

# 6. meminfo parse.
check("mem_available parses kB", R.mem_available(mi) == 1000000 * 1024)
check("mem_available missing file is None", R.mem_available(os.path.join(d, "nope")) is None)

import shutil
shutil.rmtree(d, ignore_errors=True)
for n, ok, det in results:
    print(("PASS" if ok else "FAIL") + ": " + n + ("" if ok else " — " + det))
PY
)"

echo "$out"
pass=$(grep -c '^PASS' <<<"$out" || true)
fail=$(grep -c '^FAIL' <<<"$out" || true)

# The dispatcher wires both subcommands (lazy import, DEC-PHASE10-008).
HELP="$(python3 "$REPO_ROOT/scripts/nebula/nebula" --help 2>&1)"
for sub in stop start; do
    if grep -qE "^ +$sub " <<<"$HELP"; then echo "PASS: nebula --help lists $sub"; pass=$((pass+1))
    else echo "FAIL: nebula --help lists $sub"; fail=$((fail+1)); fi
done

echo "test_nebula_runtime_ctl: $pass passed, $fail failed"
[[ $fail -eq 0 && $pass -gt 0 ]]
