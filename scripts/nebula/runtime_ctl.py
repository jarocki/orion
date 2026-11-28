"""
Nebula AI — start and stop the model runtime (`nebula stop`, `nebula start`).

@decision DEC-PHASE13-070
@title `nebula stop` unloads the model, then stops the runtime with plain systemctl
@status accepted
@date 2026-11-27
@category NEBULA
@rationale Owner request from the v3.2.0 deck test: "allow it to be stopped
  with 'nebula stop'". The CLI had no way to give the model's RAM back; the
  only path was `sudo systemctl stop nebula-runtime.service`, which the
  operator has to know. Two steps, in this order:
    1. Unload every loaded model through the loopback API (GET /api/ps, then
       POST /api/generate with keep_alive 0 per model). This frees the model's
       RAM even if step 2 is refused, and it lets ollama release the model
       cleanly rather than having it killed mid-load.
    2. `systemctl stop nebula-warmup.service nebula-runtime.service`. Plain
       systemctl, deliberately no sudo or pkexec in the CLI: systemd asks polkit
       itself (org.freedesktop.systemd1.manage-units), with a terminal agent
       when there is a TTY, so the CLI adds no privilege path of its own.
       nebula-warmup is stopped too because it is RemainAfterExit and
       Requires= the runtime; leaving it "active" would claim a warm model
       that is gone.
  Nothing restarts the runtime behind the operator's back: no healing rule
  watches nebula-runtime.service (scripts/healing), and Restart=on-failure
  does not fire on a clean stop. `nebula start` starts the runtime only; the
  warm-up stays opt-in (`nebula warmup`, DEC-PHASE10-010).
  Stdlib only and every effect injectable, so tests/unit/test_nebula_runtime_ctl.sh
  runs without ollama or systemd (DEC-PHASE10-008's lazy-import rule: the
  dispatcher imports this module only for these two subcommands).
"""
from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.request
from typing import Any, Callable

OLLAMA = "http://127.0.0.1:11434"
RUNTIME_UNIT = "nebula-runtime.service"
WARMUP_UNIT = "nebula-warmup.service"
HTTP_TIMEOUT = 5.0
UNLOAD_TIMEOUT = 30.0
MEMINFO = "/proc/meminfo"

Runner = Callable[[list[str]], "subprocess.CompletedProcess[str]"]
Http = Callable[[str, str, "dict[str, Any] | None", float], "dict[str, Any]"]


SYSTEMCTL_TIMEOUT = 300   # nebula-runtime first runs the model integrity check (hashes ~2 GB)


def run(argv: list[str]) -> "subprocess.CompletedProcess[str]":
    """Default runner: capture output, never raise — not on a non-zero exit,
    and not on a timeout either (rc 124, like timeout(1)).

    Measured on the v3.2.0 image in QEMU: `systemctl start nebula-runtime`
    waits for nebula-integrity-check, which took over 120 s under emulation,
    and the old 120 s limit ended `nebula start` in a TimeoutExpired traceback.
    """
    try:
        return subprocess.run(argv, capture_output=True, text=True, check=False, timeout=SYSTEMCTL_TIMEOUT)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(argv, 124, "", f"still waiting after {SYSTEMCTL_TIMEOUT} s")


def http_json(method: str, url: str, body: dict[str, Any] | None = None,
              timeout: float = HTTP_TIMEOUT) -> dict[str, Any]:
    """Default HTTP: one JSON request on the loopback. Raises OSError/ValueError."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310  (loopback only)
        raw = resp.read().decode("utf-8", "replace")
    return json.loads(raw) if raw.strip() else {}


def mem_available(path: str = MEMINFO) -> int | None:
    """MemAvailable in bytes, or None."""
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return None


def fmt_bytes(n: int) -> str:
    v = float(abs(n))
    for unit in ("B", "KiB", "MiB", "GiB"):
        if v < 1024 or unit == "GiB":
            return f"{v:.0f} {unit}" if unit in ("B", "KiB") else f"{v:.1f} {unit}"
        v /= 1024
    return f"{n} B"


def unit_active(unit: str, runner: Runner = run) -> bool:
    return runner(["systemctl", "is-active", "--quiet", unit]).returncode == 0


def loaded_models(http: Http = http_json, base: str = OLLAMA) -> list[str] | None:
    """Names of the models ollama has in memory; None when the server does not answer."""
    try:
        d = http("GET", f"{base}/api/ps", None, HTTP_TIMEOUT)
    except (OSError, ValueError, urllib.error.URLError):
        return None
    out = []
    for m in d.get("models") or []:
        name = m.get("name") or m.get("model") if isinstance(m, dict) else None
        if name:
            out.append(str(name))
    return out


def unload(models: list[str], http: Http = http_json, base: str = OLLAMA) -> list[tuple[str, str | None]]:
    """[(model, error or None)] after asking ollama to drop each one now."""
    res = []
    for name in models:
        try:
            http("POST", f"{base}/api/generate", {"model": name, "keep_alive": 0}, UNLOAD_TIMEOUT)
            res.append((name, None))
        except (OSError, ValueError, urllib.error.URLError) as exc:
            res.append((name, str(exc)))
    return res


def stop(runner: Runner = run, http: Http = http_json, meminfo: str = MEMINFO,
         say: Callable[[str], None] = print) -> int:
    """`nebula stop`. 0 when the runtime is stopped afterwards (or already was)."""
    before = mem_available(meminfo)
    was_active = unit_active(RUNTIME_UNIT, runner)
    if not was_active:
        say(f"Nebula is already stopped ({RUNTIME_UNIT} is not running).")
        return 0
    models = loaded_models(http)
    if models is None:
        say("The model server did not answer on 127.0.0.1:11434; stopping the runtime anyway.")
    elif not models:
        say("No model is loaded in memory.")
    else:
        for name, err in unload(models, http):
            say(f"Unloaded {name} from memory." if err is None else f"Could not unload {name}: {err}")
    r = runner(["systemctl", "stop", WARMUP_UNIT, RUNTIME_UNIT])
    if r.returncode != 0 or unit_active(RUNTIME_UNIT, runner):
        detail = (r.stderr or r.stdout or "").strip()
        say(f"FAILED to stop {RUNTIME_UNIT}" + (f": {detail}" if detail else "")
            + f" — try: sudo systemctl stop {RUNTIME_UNIT}")
        return 1
    after = mem_available(meminfo)
    freed = f" Memory available: {fmt_bytes(after - before)} more than before." \
        if before is not None and after is not None and after > before else ""
    say(f"Nebula stopped ({RUNTIME_UNIT}).{freed} Start it again with: nebula start")
    return 0


def start(runner: Runner = run, say: Callable[[str], None] = print) -> int:
    """`nebula start`. 0 when the runtime is running afterwards."""
    if unit_active(RUNTIME_UNIT, runner):
        say(f"Nebula is already running ({RUNTIME_UNIT}).")
        return 0
    r = runner(["systemctl", "start", RUNTIME_UNIT])
    if r.returncode == 124:
        say(f"{RUNTIME_UNIT} is still starting after {SYSTEMCTL_TIMEOUT} s (the model integrity "
            f"check runs first). Check again with: nebula status, or systemctl status {RUNTIME_UNIT}")
        return 1
    if r.returncode != 0 or not unit_active(RUNTIME_UNIT, runner):
        detail = (r.stderr or r.stdout or "").strip()
        say(f"FAILED to start {RUNTIME_UNIT}" + (f": {detail}" if detail else "")
            + f" — see: journalctl -u {RUNTIME_UNIT}")
        return 1
    say(f"Nebula started ({RUNTIME_UNIT}). The model loads on the first question; "
        "to load it now: nebula warmup")
    return 0
