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

import contextlib
import fcntl
import hashlib
import ipaddress
import json
import math
import os
import pwd
import re
import stat
import tempfile
import time
from pathlib import Path
from typing import Any, Iterator

SCHEMA = 1
TUNING_RELPATH = Path(".config") / "orionx" / "tuning.json"
DEFAULT_SQUELCH_SECONDS = 3600.0
# Under /var/lib/suricata, not /etc: orionx-postured runs with ProtectSystem=strict
# and may write only /run/orionx, /var/lib/suricata and /var/lib/orionx. On rc8 the
# /etc path failed every time ("tuning: cannot write …" on the bus).
THRESHOLD_FILE = Path("/var/lib/suricata/orionx-threshold.config")
PERSISTENCE_ROOT = Path("/run/live/persistence")
ENGINES = ("suricata", "zeek", "any")
MODES = ("squelch", "tune")

# @decision DEC-PHASE12-081
# @title The root daemons read operator files from ONE home, owned by that operator
# @status accepted
# @rationale QA round 1 (python P2-6, security F18): tuning.json and the posture
#   file were chosen as "newest across every /home/*", read as root, following
#   symlinks. Any second local account could touch its own file and silence the
#   deck's IDS for everyone. The single authority for WHO the operator is, is
#   the unit's ORIONX_OPERATOR_USER (orionx-heald.service already sets it),
#   defaulting to the live-config username in iso/auto/config. Root readers look
#   only in that user's home (plus an explicit --file / env path chosen by
#   whoever started the daemon), open with O_NOFOLLOW, and refuse a file that is
#   not a regular file, not owned by the operator (or root, or the running uid),
#   or writable by group/other. A refused file is reported, never silently
#   treated as "no rules".
OPERATOR_USER_DEFAULT = "orionx-operator"     # iso/auto/config live-config.username
MAX_OPERATOR_FILE_BYTES = 1 << 20
SID_MAX = 2 ** 32 - 1


# ------------------------------------------------------------------ rules

# @decision DEC-PHASE12-080
# @title Every tuning rule is validated and normalised on load; one bad rule is
#   dropped and REPORTED, never allowed to raise in the alert path
# @status accepted
# @rationale QA round 1 (python P1-3): load_rules checked only engine/mode, so
#   {"sid":"2210000x"} or {"expires":"later"} reached matches(), which raised on
#   EVERY alert; postured's tail swallowed it and the IDS went silently blind.
#   Security F4: src_ip and signature were written verbatim into the Suricata
#   threshold file root reloads, so a newline injected `suppress gen_id 0,
#   sig_id 0` (silence everything). Now: sid is an int in 1..2^32-1, src_ip
#   parses with ipaddress (address or CIDR) and is re-rendered by ipaddress,
#   note/id match a strict charset, expires/created are finite floats, and
#   free text (signature, reason) is reduced to a safe single-line charset.
#   validate_rule() is the one gate: load_rules, make_rule and the derived
#   threshold text all go through it. matches() is total besides.
_NOTE_RE = re.compile(r"^[A-Za-z0-9_:.\-]{1,80}$")
_ID_RE = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")
_UNSAFE_TEXT = re.compile(r"[^A-Za-z0-9 ._:/()\[\]@%+,=\-]")


def safe_text(value: Any, limit: int = 160) -> str:
    """One line of inert text: anything outside a small charset becomes '_'
    (so no newline, '#', quote or control byte survives), whitespace collapsed."""
    text = "" if value is None else str(value)
    text = _UNSAFE_TEXT.sub("_", " ".join(text.split()))
    return text[:limit]


def _finite(value: Any, what: str) -> float:
    if isinstance(value, bool):
        raise ValueError(f"{what} must be a number, not {value!r}")
    try:
        out = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{what} must be a number, not {value!r}") from None
    if not math.isfinite(out):
        raise ValueError(f"{what} must be finite, not {value!r}")
    return out


def _sid(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError(f"sid must be an integer, not {value!r}")
    if isinstance(value, str) and not value.strip().isdigit():
        raise ValueError(f"sid must be an integer, not {value!r}")
    sid = int(value)
    if not 1 <= sid <= SID_MAX:
        raise ValueError(f"sid {sid} is outside 1..{SID_MAX}")
    return sid


def _src(value: Any) -> str | None:
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        raise ValueError(f"src_ip must be an address or CIDR, not {value!r}")
    try:
        if "/" in value:
            return str(ipaddress.ip_network(value.strip(), strict=False))
        return str(ipaddress.ip_address(value.strip()))
    except ValueError:
        raise ValueError(f"src_ip {value!r} is not an IP address or CIDR") from None


def validate_rule(r: Any) -> dict[str, Any]:
    """A normalised copy of one rule, or ValueError naming what is wrong."""
    if not isinstance(r, dict):
        raise ValueError(f"rule is not an object: {r!r}"[:120])
    engine, mode = r.get("engine"), r.get("mode")
    if engine not in ENGINES:
        raise ValueError(f"engine must be one of {ENGINES}, not {engine!r}")
    if mode not in MODES:
        raise ValueError(f"mode must be one of {MODES}, not {mode!r}")
    sid = _sid(r.get("sid"))
    note = r.get("note") or None
    if note is not None and (not isinstance(note, str) or not _NOTE_RE.match(note)):
        raise ValueError(f"note {note!r} is not a Zeek notice name")
    if sid is None and note is None:
        raise ValueError("a rule needs a Suricata sid or a Zeek note")
    src_ip = _src(r.get("src_ip"))
    created = _finite(r.get("created", 0.0) or 0.0, "created")
    expires = r.get("expires")
    expires = None if expires is None else _finite(expires, "expires")
    rid = r.get("id")
    if rid is None or rid == "":
        rid = rule_id(engine, sid, note, src_ip, mode, created)
    elif not isinstance(rid, str) or not _ID_RE.match(rid):
        raise ValueError(f"id {rid!r} is not a rule id")
    return {"id": rid, "engine": engine, "mode": mode, "sid": sid, "note": note,
            "src_ip": src_ip, "signature": safe_text(r.get("signature")),
            "reason": safe_text(r.get("reason")), "created": created, "expires": expires}


def load_rules_report(text: str | None) -> tuple[list[dict[str, Any]], list[str]]:
    """tuning.json text -> (valid rules, one error string per rejected entry).

    Corrupt or missing -> no rules: a broken file tunes NOTHING (the paranoid
    default; it never silences an alert by accident). A corrupt file is an
    error worth reporting; an absent or empty one is not."""
    if not text or not str(text).strip():
        return [], []
    try:
        data = json.loads(text)
    except (json.JSONDecodeError, TypeError) as exc:
        return [], [f"not valid JSON ({exc})"]
    rules = data.get("rules") if isinstance(data, dict) else None
    if not isinstance(rules, list):
        return [], ['no "rules" list']
    out, errors = [], []
    for n, r in enumerate(rules):
        try:
            out.append(validate_rule(r))
        except ValueError as exc:
            errors.append(f"rule #{n + 1}: {exc}")
    return out, errors


def load_rules(text: str | None) -> list[dict[str, Any]]:
    """The valid rules only (see load_rules_report for what was rejected)."""
    return load_rules_report(text)[0]


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
    expires = None
    if mode == "squelch":
        expires = now + (DEFAULT_SQUELCH_SECONDS if ttl is None else _finite(ttl, "ttl"))
    raw = {"engine": engine, "mode": mode, "sid": sid, "note": note or None,
           "src_ip": src_ip or None, "signature": signature or "",
           "reason": reason or "", "created": now, "expires": expires}
    rule = validate_rule(raw)                 # raises ValueError with the reason
    rule["id"] = rule_id(rule["engine"], rule["sid"], rule["note"], rule["src_ip"],
                         rule["mode"], now)
    return rule


def is_active(rule: dict[str, Any], now: float) -> bool:
    exp = rule.get("expires")
    try:
        return exp is None or float(exp) > now
    except (TypeError, ValueError):
        return False          # an expiry nobody can read silences nothing


def active_rules(rules: list[dict[str, Any]], now: float) -> list[dict[str, Any]]:
    return [r for r in rules if is_active(r, now)]


def prune(rules: list[dict[str, Any]], now: float) -> list[dict[str, Any]]:
    """Drop expired squelches. Tunes never expire."""
    return active_rules(rules, now)


def _src_matches(rule_src: str, src_ip: str | None) -> bool:
    if not src_ip:
        return False
    try:
        if "/" in rule_src:
            return ipaddress.ip_address(str(src_ip)) in ipaddress.ip_network(rule_src, strict=False)
        return ipaddress.ip_address(str(src_ip)) == ipaddress.ip_address(rule_src)
    except ValueError:
        return str(src_ip) == rule_src


def matches(rule: dict[str, Any], engine: str, sid: int | None, note: str | None,
            src_ip: str | None, now: float) -> bool:
    """Does this rule silence this alert right now? Pure and TOTAL: a rule or
    an alert field it cannot interpret means "no match", never an exception in
    the alert path (DEC-PHASE12-080)."""
    try:
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
            if not _src_matches(str(rule["src_ip"]), src_ip):
                return False
        return True
    except (TypeError, ValueError, AttributeError):
        return False


def suppressed_by(rules: list[dict[str, Any]], engine: str, sid: int | None,
                  note: str | None, src_ip: str | None, now: float) -> dict[str, Any] | None:
    """The first rule that silences this alert, or None."""
    for r in rules:
        if matches(r, engine, sid, note, src_ip, now):
            return r
    return None


# ------------------------------------------------- derived: Suricata threshold

def suricata_threshold_text(rules: list[dict[str, Any]], now: float) -> str:
    """The DERIVED /var/lib/suricata/orionx-threshold.config. Never hand-edited.

    Only rules Suricata can express: a sid, optionally tracked by source.
    Squelches are included while they are active — Suricata is reloaded when
    the derived text changes, so an expired squelch drops out at the next
    refresh. Zeek-only rules have no representation here. Every rule is
    re-validated here (DEC-PHASE12-080): this text is reloaded by root, so
    nothing reaches it that validate_rule() did not render itself.
    """
    lines = ["# GENERATED by orionx-postured from ~/.config/orionx/tuning.json",
             "# (DEC-PHASE12-050). Edit with `orionx-tune`, not here.", ""]
    seen = set()
    for raw in active_rules(rules, now):
        try:
            r = validate_rule(raw)
        except ValueError:
            continue
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


def operator_user(env: dict | None = None) -> str:
    """WHO the deck's operator is, for root daemons (DEC-PHASE12-081). One value:
    the unit's ORIONX_OPERATOR_USER, else the live-config username."""
    env = os.environ if env is None else env
    name = str(env.get("ORIONX_OPERATOR_USER", "") or "").strip()
    return name if name and name != "root" else OPERATOR_USER_DEFAULT


def trusted_uids(user: str | None = None) -> set[int]:
    """Owners a root reader accepts: root, the running uid, and the operator."""
    uids = {0, os.geteuid()}
    try:
        uids.add(pwd.getpwnam(user or operator_user()).pw_uid)
    except KeyError:
        pass
    return uids


def read_trusted(path: Path | str | None, uids: set[int] | None = None,
                 limit: int = MAX_OPERATOR_FILE_BYTES) -> tuple[str | None, str | None]:
    """(text, None) for a file a root daemon may believe, else (None, why).

    Absent -> (None, None): no file is not an error. Never follows a symlink;
    refuses a non-regular file, an owner outside `uids`, or group/other write."""
    if path is None:
        return None, None
    uids = trusted_uids() if uids is None else uids
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None, None
    except OSError as exc:
        return None, f"refused {path}: cannot open without following links ({exc.strerror})"
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, f"refused {path}: not a regular file"
        if st.st_uid not in uids:
            return None, (f"refused {path}: owned by uid {st.st_uid}, not the operator "
                          f"({operator_user()}) or root")
        if st.st_mode & 0o022:
            return None, (f"refused {path}: writable by group/other "
                          f"(mode {oct(st.st_mode & 0o777)}); chmod go-w it")
        data = os.read(fd, limit + 1)
        if len(data) > limit:
            return None, f"refused {path}: larger than {limit} bytes"
        return data.decode("utf-8", errors="replace"), None
    except OSError as exc:
        return None, f"cannot read {path}: {exc}"
    finally:
        os.close(fd)


def candidates(explicit: str | os.PathLike | None = None, home_root: Path | str = "/home",
               desktop_user: str | None = None, env: dict | None = None) -> list[Path]:
    """Where tuning.json may live, for a root daemon (DEC-PHASE12-081): an
    explicit path, $ORIONX_TUNING_FILE, and the operator's home. Nothing else -
    no scan of every /home/*, no root's own ~/.config."""
    env = os.environ if env is None else env
    out: list[Path] = []

    def add(p: Path) -> None:
        if p not in out:
            out.append(p)
    if explicit:
        add(Path(explicit))
    if env.get("ORIONX_TUNING_FILE"):
        add(Path(env["ORIONX_TUNING_FILE"]))
    add(Path(home_root) / (desktop_user or operator_user(env)) / TUNING_RELPATH)
    return out


def pick_file(cands: list[Path]) -> Path | None:
    """The newest existing candidate, or None (newest deliberate edit wins).
    lstat: a symlink candidate is still picked, so read_trusted can REFUSE it
    out loud rather than it vanishing silently."""
    best, best_m = None, -1.0
    for p in cands:
        try:
            m = os.lstat(p).st_mtime
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


def atomic_write_text(path: Path | str, text: str, mode: int = 0o644) -> None:
    """Write via a UNIQUE temp file in the same directory, then os.replace.
    A fixed temp name let two writers interleave (python P3-3)."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def locked(path: Path | str) -> Iterator[None]:
    """Exclusive advisory lock for a read-modify-write of `path` (orionx-tune)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path.with_name(path.name + ".lock")), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def write_rules(path: Path, rules: list[dict[str, Any]]) -> None:
    """Atomic, operator-owned, 0600 - a tuning file is a statement of what
    the deck will NOT tell you, and nobody else should be able to edit it."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(path, dump_rules(rules), 0o600)


class TuningState:
    """What orionx-postured holds: the rules, where they came from, when they
    changed, and what was REJECTED (so the daemon can say so on the bus)."""

    def __init__(self, explicit: str | os.PathLike | None = None,
                 uids: set[int] | None = None):
        self.explicit = explicit
        self.uids = uids
        self.path: Path | None = None
        self.rules: list[dict[str, Any]] = []
        self.errors: list[str] = []
        self.errors_changed = False
        self._mtime: float = -1.0
        self.derived_text: str = ""

    def refresh(self, now: float, home_root: Path | str = "/home",
                desktop_user: str | None = None) -> bool:
        """Re-read if the file changed. Returns True when the DERIVED Suricata
        text changed (the caller then rewrites the threshold file and reloads).
        Sets errors_changed when the set of rejected rules/refusals changed."""
        self.errors_changed = False
        path = pick_file(candidates(self.explicit, home_root, desktop_user))
        mtime = -1.0
        if path is not None:
            try:
                mtime = os.lstat(path).st_mtime
            except OSError:
                path = None
        if path != self.path or mtime != self._mtime:
            self.path, self._mtime = path, mtime
            text, refusal = read_trusted(path, self.uids)
            rules, errors = load_rules_report(text)
            errors = ([refusal] if refusal else []) + [f"{path}: {e}" for e in errors]
            self.rules = rules
            self.errors_changed = errors != self.errors
            self.errors = errors
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
                "rejected": list(self.errors),
                "persistent": present, "persistence": where}
