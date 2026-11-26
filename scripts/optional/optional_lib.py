"""optional_lib — the logic behind `orionx-optional` (#197). No GTK, no root.

Every decision the helper makes is a function here that takes its inputs as
arguments (paths, probes, command runners), so the tests exercise the real
rules on fixtures and the CLI only wires them to the system.

@decision DEC-PHASE13-057
@category TOOLING
@title One helper owns optional tools: status, install and uninstall, with an install record, bus events and functional groups
@status accepted
@rationale #197 (owner, 2026-11-25): optional tools must show their state and
  install or uninstall from the same interface, every change must reach the
  event bus, and the tools must be grouped by function. Before this, 11
  installers could only install, state was file presence read by the
  Workbench alone, and only Zeek and Bluetooth published events. Now
  `orionx-optional` is the single authority. links.json (`installable`) holds
  each tool's metadata (group, network host, probe, owned paths, units,
  version and health checks), so the Cockpit and the Workbench read one list.
  Install snapshots dpkg, pip and the owned paths, runs the tool's installer,
  verifies it and writes a record of exactly what was added. Uninstall removes
  only what a record says this helper added, after `apt-get -s purge` shows
  nothing else would go; a tool shipped in the image or installed by other
  means is never removed (Zeek ships in the image). Run as root, the helper
  trusts only a root-owned, not group/other-writable catalogue and installer,
  and ignores environment overrides, so a user cannot choose what root runs.
  Every action publishes start, success or failure on the bus (category
  `tooling`, a status category, so threat pressure is unaffected); the two
  per-installer emitters were removed (one writer).
"""
from __future__ import annotations

import fnmatch
import glob
import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
ACTIONS = ("install", "uninstall")

# Steps each action reports as PROGRESS n/m (the Cockpit's bar).
STEPS = {
    "install": ("preflight", "snapshot", "run installer", "verify", "record"),
    "uninstall": ("preflight", "plan", "stop services", "remove", "verify"),
}

# Only these prefixes may be removed on uninstall, whatever a record says.
REMOVABLE_PREFIXES = ("/opt/", "/usr/local/", "/usr/share/orionx/", "/var/lib/orionx/",
                      "/etc/apt/sources.list.d/", "/usr/share/keyrings/",
                      "/usr/share/applications/", "/usr/bin/")


@dataclass(frozen=True)
class Paths:
    catalogue: Path
    state_dir: Path      # /run/orionx/optional: <id>.json live state + lock
    record_dir: Path     # /var/lib/orionx/optional: <id>.json install records
    log_dir: Path        # /var/log/orionx/optional

    @property
    def lock(self) -> Path:
        return self.state_dir / "lock"


SYSTEM = Paths(Path("/opt/orionx/osint/links.json"), Path("/run/orionx/optional"),
               Path("/var/lib/orionx/optional"), Path("/var/log/orionx/optional"))


# --- catalogue ---------------------------------------------------------------

class CatalogueError(ValueError):
    pass


def load_catalogue(path: Path) -> tuple[list[dict], list[dict]]:
    """(groups, tools) from links.json, validated. Raises CatalogueError."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CatalogueError(f"cannot read the tool catalogue {path}: {exc}") from exc
    groups = data.get("groups") or []
    tools = data.get("installable") or []
    problems = validate(groups, tools)
    if problems:
        raise CatalogueError("tool catalogue is invalid: " + "; ".join(problems))
    return groups, tools


def validate(groups: list, tools: list) -> list[str]:
    """Every rule the helper relies on, as a list of problems (empty = valid)."""
    out: list[str] = []
    gids = [g.get("id") for g in groups if isinstance(g, dict)]
    if not gids or len(set(gids)) != len(gids):
        out.append("groups must be a non-empty list with unique ids")
    seen: set[str] = set()
    for t in tools:
        if not isinstance(t, dict):
            out.append("an installable entry is not an object")
            continue
        tid = str(t.get("id", ""))
        where = f"installable {tid or '?'}"
        if not ID_RE.match(tid) or tid in seen:
            out.append(f"{where}: id must match {ID_RE.pattern} and be unique")
        seen.add(tid)
        if t.get("group") not in gids:
            out.append(f"{where}: group {t.get('group')!r} is not one of {gids}")
        rp = str(t.get("runtime_path", ""))
        if not (rp.startswith("/opt/orionx/optional/install-") and rp.endswith(".sh") and "/../" not in rp):
            out.append(f"{where}: runtime_path must be /opt/orionx/optional/install-*.sh")
        if not t.get("probe") or not all(isinstance(p, str) for p in t["probe"]):
            out.append(f"{where}: probe must be a non-empty list of paths or python:<module>")
        for p in t.get("owns") or []:
            if not removable(p):
                out.append(f"{where}: owns {p!r} is outside {REMOVABLE_PREFIXES}")
        if "blocked" in t and not (isinstance(t["blocked"], str) and t["blocked"]):
            out.append(f"{where}: blocked must be a non-empty reason")
        if not isinstance(t.get("needs_host"), str) or not t["needs_host"]:
            out.append(f"{where}: needs_host must name the host its installer needs")
        for h in t.get("health") or []:
            if not isinstance(h, dict) or not h.get("what") or not ({"run", "fresh", "exists", "unit"} & set(h)):
                out.append(f"{where}: each health check needs 'what' and one of run/fresh/exists/unit")
    return out


def removable(path: str) -> bool:
    p = os.path.normpath(str(path))
    return p == str(path).rstrip("/") and p.startswith("/") and any(p.startswith(x) and len(p) > len(x)
                                                                    for x in REMOVABLE_PREFIXES)


def find_tool(tools: list[dict], tool_id: str) -> dict:
    if not ID_RE.match(tool_id or ""):
        raise CatalogueError(f"not a tool id: {tool_id!r}")
    for t in tools:
        if t.get("id") == tool_id:
            return t
    raise CatalogueError(f"no optional tool called {tool_id!r} (see: orionx-optional status)")


def trusted_file(path: Path, lstat=os.lstat) -> str:
    """'' when root may rely on `path`; else why not (owner, mode, symlink)."""
    try:
        st = lstat(path)
    except OSError as exc:
        return f"{path}: {exc.strerror or exc}"
    import stat as S  # noqa: PLC0415
    if S.S_ISLNK(st.st_mode):
        return f"{path} is a symlink"
    if st.st_uid != 0:
        return f"{path} is not owned by root"
    if st.st_mode & 0o022:
        return f"{path} is writable by group or others"
    return ""


# --- status ------------------------------------------------------------------

def probe_hit(probe: Iterable[str], exists: Callable[[str], bool], has_module: Callable[[str], bool]) -> str:
    for p in probe:
        p = str(p)
        if p.startswith("python:"):
            if has_module(p[7:]):
                return p
        elif exists(p):
            return p
    return ""


def check_health(checks: list[dict], *, run: Callable, exists: Callable[[str], bool],
                 mtime: Callable[[str], float | None], unit_active: Callable[[str], bool],
                 now: float) -> str:
    """'' when every check passes, else the first failure as one line."""
    for h in checks or []:
        what = h.get("what", "check")
        if "run" in h:
            rc = run(list(h["run"]))
            if rc != 0:
                return f"{what}: failed (exit {rc})"
        elif "exists" in h:
            if not exists(h["exists"]):
                return f"{what}: missing ({h['exists']})"
        elif "fresh" in h:
            times = [t for t in (mtime(p) for p in glob.glob(h["fresh"]) or [h["fresh"]]) if t is not None]
            if not times:
                return f"{what}: missing ({h['fresh']})"
            age = (now - max(times)) / 86400
            if age > float(h.get("max_days", 30)):
                return f"{what}: {int(age)} days old (limit {h.get('max_days', 30)})"
        elif "unit" in h:
            if not unit_active(h["unit"]):
                return f"{what}: {h['unit']} is not active"
    return ""


def pid_alive(pid) -> bool:
    """Is the process there? EPERM means it exists but is root's (the usual case
    when the Cockpit, as the desktop user, asks about the helper)."""
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, ValueError, TypeError):
        return False


def tool_status(t: dict, *, record: dict | None, live: dict | None, net: str,
                exists, has_module, run, mtime, unit_active, version_of, now: float,
                alive=pid_alive) -> dict:
    """One tool's state for the Cockpit and the Workbench. Pure given its probes.

    state: working | active | installed | degraded | failed | not_installed
    """
    tid = t["id"]
    out = {"id": tid, "name": t.get("name", tid), "group": t.get("group"), "blurb": t.get("blurb", ""),
           "size": t.get("size", ""), "state": "not_installed", "reason": "", "version": "",
           "evidence": "", "managed": record is not None, "can_install": False, "can_uninstall": False,
           "uninstall_reason": "", "install_reason": "", "progress": None, "last": None}
    running = bool(live and live.get("state") == "running" and alive(live.get("pid")))
    if live and live.get("state") in ("ok", "failed"):
        out["last"] = {k: live.get(k) for k in ("action", "state", "reason", "log", "finished")}
    hit = probe_hit(t.get("probe") or [], exists, has_module)
    out["evidence"] = hit or ("none of: " + ", ".join(map(str, t.get("probe") or [])))
    if running:
        out["state"] = "working"
        out["progress"] = {k: live.get(k) for k in ("action", "step", "n", "m", "line", "started", "log")}
        out["reason"] = f"{live.get('action')} {live.get('n')}/{live.get('m')}: {live.get('step')}"
        return out
    if hit:
        out["version"] = version_of(t)
        bad = check_health(t.get("health") or [], run=run, exists=exists, mtime=mtime,
                           unit_active=unit_active, now=now)
        if bad:
            out["state"], out["reason"] = "degraded", bad
        elif any(unit_active(u) for u in (t.get("active") or {}).get("units", [])):
            out["state"] = "active"
        else:
            out["state"] = "installed"
        if record is not None:
            out["can_uninstall"] = True
        else:
            out["uninstall_reason"] = ("shipped with the image or installed outside orionx-optional; "
                                       "nothing it can safely remove")
        if out["last"] and out["last"]["state"] == "failed" and out["last"]["action"] == "uninstall":
            out["reason"] = out["reason"] or f"last uninstall failed: {out['last']['reason']}"
        return out
    # not installed
    if out["last"] and out["last"]["state"] == "failed" and out["last"]["action"] == "install":
        out["state"], out["reason"] = "failed", out["last"]["reason"] or "install failed"
    if record is not None:  # partial leftovers from a failed install can be cleaned up
        out["can_uninstall"] = True
    if t.get("blocked"):
        out["install_reason"] = f"blocked: {t['blocked']}"
    elif net == "ok":
        out["can_install"] = True
    else:
        out["install_reason"] = f"needs network: {net}"
    return out


def summary(statuses: list[dict]) -> dict:
    keys = ("active", "installed", "degraded", "failed", "working", "not_installed")
    return {k: sum(1 for s in statuses if s["state"] == k) for k in keys}


# --- snapshots and the install record -----------------------------------------

def parse_dpkg_installed(text: str) -> set[str]:
    """`dpkg-query -W -f='${Package}:${Architecture} ${db:Status-Status}\\n'` -> installed names."""
    out = set()
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "installed":
            out.add(parts[0])
    return out


def parse_pip_list(text: str) -> set[str]:
    try:
        return {str(d["name"]).lower() for d in json.loads(text or "[]")}
    except (ValueError, TypeError, KeyError):
        return set()


def make_record(t: dict, *, before_pkgs: set, after_pkgs: set, before_pip: set, after_pip: set,
                created: list[str], version: str, ok: bool, now: float) -> dict:
    return {"id": t["id"], "version": version, "installed_at": int(now), "complete": ok,
            "apt": sorted(after_pkgs - before_pkgs), "pip": sorted(after_pip - before_pip),
            "paths": sorted(p for p in created if p in (t.get("owns") or []) and removable(p))}


def record_is_empty(rec: dict) -> bool:
    return not (rec.get("apt") or rec.get("pip") or rec.get("paths"))


def parse_apt_simulation(text: str) -> set[str]:
    """Package names `apt-get -s purge` would remove ("Purg pkg [...]" / "Remv pkg [...]")."""
    out = set()
    for line in text.splitlines():
        m = re.match(r"^(?:Purg|Remv) (\S+)", line)
        if m:
            out.add(m.group(1))
    return out


def strip_arch(name: str) -> str:
    return name.split(":", 1)[0]


def collateral(simulated: set[str], ours: Iterable[str]) -> list[str]:
    """Packages a purge would take that the record did not add (by name, arch-agnostic)."""
    mine = {strip_arch(p) for p in ours}
    return sorted(p for p in simulated if strip_arch(p) not in mine)


def units_matching(patterns: Iterable[str], listed: str) -> list[str]:
    """Unit names from `systemctl list-units --all --plain --no-legend` matching any pattern."""
    names = [line.split()[0] for line in listed.splitlines() if line.split()]
    return sorted({n for n in names for p in patterns if fnmatch.fnmatch(n, p)})


# --- live state, progress, events ----------------------------------------------

def progress_line(action: str, n: int, label: str) -> str:
    return f"PROGRESS {n}/{len(STEPS[action])} {label}"


def parse_progress(line: str) -> tuple[int, int, str] | None:
    m = re.match(r"^PROGRESS (\d+)/(\d+) (.*)$", line.strip())
    return (int(m.group(1)), int(m.group(2)), m.group(3)) if m else None


def installer_error(lines: list[str]) -> tuple[str, bool]:
    """(headline, integrity) from an installer's output lines (without the '| ').

    The headline is the FIRST error line: installers print the cause first and
    the advice after it. `integrity` is True when any line says MISMATCH, the
    word every pin and key-fingerprint refusal uses (orionx-installer-common.sh,
    install-zeek.sh, install-element.sh): a possible tampering signal, so the
    failure event is raised to critical.
    """
    body = [ln.strip() for ln in lines if ln.strip()]
    errs = [ln for ln in body if ln.startswith("ERROR") or ln.startswith("E: ")]
    head = (errs or body or [""])[0]
    head = re.sub(r"^ERROR: (\[[^]]+\] )?", "", head).strip()
    return head[:160], any("MISMATCH" in ln for ln in body)


def event_for(t: dict, action: str, phase: str, *, ok: bool = True, reason: str = "",
              version: str = "", seconds: float = 0.0, log: str = "", who: str = "",
              integrity: bool = False) -> tuple[str, str, dict]:
    """(severity, message, detail) for the bus. phase: start | end."""
    name = t.get("name", t["id"])
    verb = {"install": "Install", "uninstall": "Uninstall"}[action]
    detail = {"tool": t["id"], "action": action, "phase": phase, "log": log}
    if phase == "start":
        return "info", f"{verb} {name} started" + (f" by {who}" if who else ""), detail
    detail.update(ok=ok, seconds=round(seconds), version=version)
    if ok:
        done = "installed" if action == "install" else "uninstalled"
        return "notice", f"{name} {done}" + (f" ({version})" if version else "") + f" in {round(seconds)} s", detail
    detail["reason"] = reason
    if integrity:
        detail["integrity"] = True
        return "critical", f"{verb} {name} REFUSED (integrity check): {reason}", detail
    return "warning", f"{verb} {name} FAILED: {reason}", detail


def now_stamp(now: float | None = None) -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now if now is not None else time.time()))
