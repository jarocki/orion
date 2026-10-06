#!/usr/bin/env python3
"""tuning_lib — operator tuning of IDS alerts: squelch for a while, or tune for good.

@decision DEC-PHASE12-050
@title One tuning authority (tuning.json); Suricata's threshold file is derived
@status accepted
@rationale On the reference deck (2026-10-05) Suricata flagged the deck's own
  traffic to archive.ph, and the operator had no way to say "I know, stop" —
  short of editing rule files as root on a live system. Two verbs cover what
  an operator actually needs at the console: SQUELCH (this signature, maybe
  from this source, for an hour) and TUNE (keep it off).

  The authority is ~/.config/orionx/tuning.json, written by the operator via
  `orionx-tune` (no root), found by orionx-postured the same way the posture
  file is. Postured applies it on the BUS SIDE for both engines — that is the
  outcome the operator sees — and, being root, DERIVES Suricata's threshold
  file from it and reloads the ruleset over the command socket, so Suricata
  stops spending cycles on it too. Zeek notices are filtered bus-side only.
  Nothing edits the derived file by hand; nothing else writes tuning.json.

  Honesty rule: on a live USB with no persistence partition, "tune" lasts
  until reboot. The CLI and the Cockpit SAY which, every time, because an
  operator who believes a rule is permanent and loses it at the next boot
  has been lied to by the deck.

  Pure functions take text/dicts and a clock; the two thin I/O helpers never
  raise. stdlib only.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any

SCHEMA = 1
TUNING_RELPATH = Path(".config") / "orionx" / "tuning.json"
DEFAULT_SQUELCH_SECONDS = 3600.0
THRESHOLD_FILE = Path("/etc/suricata/orionx-threshold.config")
PERSISTENCE_ROOT = Path("/run/live/persistence")
ENGINES = ("suricata", "zeek", "any")
MODES = ("squelch", "tune")


# ------------------------------------------------------------------ rules

def load_rules(text: str | None) -> list[dict[str, Any]]:
    """tuning.json text -> rule list. Corrupt or missing -> []: a broken file
    tunes NOTHING (the paranoid default; it never silences an alert by accident)."""
    if not text or not str(text).strip():
        return []
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return []
    rules = data.get("rules") if isinstance(data, dict) else None
    out = []
    for r in rules if isinstance(rules, list) else []:
        if not isinstance(r, dict):
            continue
        if r.get("engine") not in ENGINES or r.get("mode") not in MODES:
            continue
        if r.get("sid") is None and not r.get("note"):
            continue          # a rule that matches nothing specific matches nothing
        out.append(r)
    return out


def dump_rules(rules: list[dict[str, Any]]) -> str:
    return json.dumps({"schema": SCHEMA, "rules": rules}, indent=2, sort_keys=True) + "\n"


def rule_id(engine: str, sid: int | None, note: str | None, src_ip: str | None,
            mode: str, created: float) -> str:
    h = hashlib.sha256(f"{engine}|{sid}|{note}|{src_ip}|{mode}|{created:.3f}".encode()).hexdigest()
    return h[:10]


def make_rule(engine: str, mode: str, sid: int | None = None, note: str | None = None,
              src_ip: str | None = None, signature: str = "", reason: str = "",
              ttl: float | None = None, now: float | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    if engine not in ENGINES:
        raise ValueError(f"engine must be one of {ENGINES}")
    if mode not in MODES:
        raise ValueError(f"mode must be one of {MODES}")
    if sid is None and not note:
        raise ValueError("a rule needs a Suricata sid or a Zeek note")
    expires = None
    if mode == "squelch":
        expires = now + (DEFAULT_SQUELCH_SECONDS if ttl is None else float(ttl))
    return {
        "id": rule_id(engine, sid, note, src_ip, mode, now),
        "engine": engine, "mode": mode,
        "sid": int(sid) if sid is not None else None,
        "note": note or None,
        "src_ip": src_ip or None,
        "signature": signature or "",
        "reason": reason or "",
        "created": now, "expires": expires,
    }


def is_active(rule: dict[str, Any], now: float) -> bool:
    exp = rule.get("expires")
    return exp is None or float(exp) > now


def active_rules(rules: list[dict[str, Any]], now: float) -> list[dict[str, Any]]:
    return [r for r in rules if is_active(r, now)]


def prune(rules: list[dict[str, Any]], now: float) -> list[dict[str, Any]]:
    """Drop expired squelches. Tunes never expire."""
    return active_rules(rules, now)


def matches(rule: dict[str, Any], engine: str, sid: int | None, note: str | None,
            src_ip: str | None, now: float) -> bool:
    """Does this rule silence this alert right now? Pure."""
    if not is_active(rule, now):
        return False
    if rule.get("engine") not in ("any", engine):
        return False
    if rule.get("sid") is not None:
        if sid is None or int(rule["sid"]) != int(sid):
            return False
    if rule.get("note"):
        if not note or str(rule["note"]) != str(note):
            return False
    if rule.get("src_ip"):
        if not src_ip or str(rule["src_ip"]) != str(src_ip):
            return False
    return True


def suppressed_by(rules: list[dict[str, Any]], engine: str, sid: int | None,
                  note: str | None, src_ip: str | None, now: float) -> dict[str, Any] | None:
    """The first rule that silences this alert, or None."""
    for r in rules:
        if matches(r, engine, sid, note, src_ip, now):
            return r
    return None


# ------------------------------------------------- derived: Suricata threshold

def suricata_threshold_text(rules: list[dict[str, Any]], now: float) -> str:
    """The DERIVED /etc/suricata/orionx-threshold.config. Never hand-edited.

    Only rules Suricata can express: a sid, optionally tracked by source.
    Squelches are included while they are active — Suricata is reloaded when
    the derived text changes, so an expired squelch drops out at the next
    refresh. Zeek-only rules have no representation here.
    """
    lines = ["# GENERATED by orionx-postured from ~/.config/orionx/tuning.json",
             "# (DEC-PHASE12-050). Edit with `orionx-tune`, not here.", ""]
    seen = set()
    for r in active_rules(rules, now):
        if r.get("engine") not in ("suricata", "any") or r.get("sid") is None:
            continue
        key = (int(r["sid"]), r.get("src_ip") or "")
        if key in seen:
            continue
        seen.add(key)
        tag = f"  # {r.get('mode')} {r.get('id')} {r.get('signature', '')}".rstrip()
        if r.get("src_ip"):
            lines.append(f"suppress gen_id 1, sig_id {key[0]}, track by_src, ip {key[1]}{tag}")
        else:
            lines.append(f"suppress gen_id 1, sig_id {key[0]}{tag}")
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------- persistence

def persistence_present(root: Path | str = PERSISTENCE_ROOT) -> tuple[bool, str]:
    """(True, where) when live-boot mounted a persistence volume, else (False, why).

    live-boot mounts each persistence partition under /run/live/persistence/<dev>.
    A directory that exists but has no mounted child is NOT persistence.
    """
    root = Path(root)
    try:
        if not root.is_dir():
            return False, "no /run/live/persistence directory — this boot has no persistence volume"
        for child in sorted(root.iterdir()):
            if child.is_dir() and (os.path.ismount(child) or any(child.iterdir())):
                return True, str(child)
        return False, "/run/live/persistence exists but nothing is mounted under it"
    except OSError as exc:
        return False, f"cannot inspect {root}: {exc}"


def survives_reboot_line(present: bool, where: str) -> str:
    if present:
        return f"survives reboot: YES (persistence at {where})"
    return ("survives reboot: NO — " + where + ". The rule lasts until this deck "
            "reboots; set up persistence (User Guide §3) to keep it.")


# -------------------------------------------------------------- file I/O

def default_path(home: Path | None = None, env: dict | None = None) -> Path:
    env = os.environ if env is None else env
    if env.get("ORIONX_TUNING_FILE"):
        return Path(env["ORIONX_TUNING_FILE"])
    return (home or Path.home()) / TUNING_RELPATH


def candidates(explicit: str | os.PathLike | None = None, home_root: Path | str = "/home",
               desktop_user: str = "orionx-operator", env: dict | None = None) -> list[Path]:
    """Where tuning.json may live, for a root daemon reading operator homes.
    Mirrors orionx-postured's posture_candidates (same operator, same reason)."""
    env = os.environ if env is None else env
    out: list[Path] = []

    def add(p: Path) -> None:
        if p not in out:
            out.append(p)
    if explicit:
        add(Path(explicit))
    if env.get("ORIONX_TUNING_FILE"):
        add(Path(env["ORIONX_TUNING_FILE"]))
    add(Path(home_root) / desktop_user / TUNING_RELPATH)
    try:
        for home in sorted(Path(home_root).iterdir()):
            if home.is_dir():
                add(home / TUNING_RELPATH)
    except OSError:
        pass
    add(Path.home() / TUNING_RELPATH)
    return out


def pick_file(cands: list[Path]) -> Path | None:
    """The newest existing candidate, or None (newest deliberate edit wins)."""
    best, best_m = None, -1.0
    for p in cands:
        try:
            m = p.stat().st_mtime
        except OSError:
            continue
        if m > best_m:
            best, best_m = p, m
    return best


def read_text(path: Path | None) -> str | None:
    if path is None:
        return None
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError:
        return None


def write_rules(path: Path, rules: list[dict[str, Any]]) -> None:
    """Atomic, operator-owned, 0600 — a tuning file is a statement of what
    the deck will NOT tell you, and nobody else should be able to edit it."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(dump_rules(rules))
    os.replace(tmp, path)


class TuningState:
    """What orionx-postured holds: the rules, where they came from, when they changed."""

    def __init__(self, explicit: str | os.PathLike | None = None):
        self.explicit = explicit
        self.path: Path | None = None
        self.rules: list[dict[str, Any]] = []
        self._mtime: float = -1.0
        self.derived_text: str = ""

    def refresh(self, now: float, home_root: Path | str = "/home",
                desktop_user: str = "orionx-operator") -> bool:
        """Re-read if the file changed. Returns True when the DERIVED Suricata
        text changed (the caller then rewrites the threshold file and reloads)."""
        path = pick_file(candidates(self.explicit, home_root, desktop_user))
        mtime = -1.0
        if path is not None:
            try:
                mtime = path.stat().st_mtime
            except OSError:
                path = None
        if path != self.path or mtime != self._mtime:
            self.path, self._mtime = path, mtime
            self.rules = load_rules(read_text(path))
        derived = suricata_threshold_text(self.rules, now)
        changed = derived != self.derived_text
        self.derived_text = derived
        return changed

    def suppressed_by(self, engine: str, sid: int | None, note: str | None,
                      src_ip: str | None, now: float) -> dict[str, Any] | None:
        return suppressed_by(self.rules, engine, sid, note, src_ip, now)

    def status(self, now: float) -> dict[str, Any]:
        present, where = persistence_present()
        return {"file": str(self.path or ""), "rules": len(self.rules),
                "active": len(active_rules(self.rules, now)),
                "persistent": present, "persistence": where}
