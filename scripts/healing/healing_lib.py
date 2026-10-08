#!/usr/bin/env python3
"""healing_lib — the pure, testable core of the Orion-X auto-healing engine.

Everything here is decision logic: which playbook a bus event maps to, whether
the operator's standing consent permits running it, whether a target is safe to
act on, when an action must auto-revert, and whether the audit chain has been
tampered with. Nothing in this module touches nftables, kills a process, moves a
file or talks to Synapse — those live in playbooks.py behind an injectable
runner, so the reasoning above can be proved in CI on a laptop with no root.

@decision DEC-PHASE12-023
@title Auto-healing engine: static playbook registry, autonomy-gated, reversible,
  hash-chained
@status accepted
@rationale The Control Center has shipped an autonomy grid since W10-6's first
  slice (DEC-PHASE10-004): the operator pre-approves off / propose / confirm /
  autonomous per action class and it persists to ~/.config/orionx/autonomy.json.
  Nothing consumed it. An operator could set block_ip to "autonomous", believe
  the deck would block an attacker unattended, and discover during an incident
  that no engine existed. A control that does not control is worse than an
  absent one, because it is trusted. This module closes that gap.

  Four properties decide the design:

  1. NO DYNAMIC DISPATCH. Events arrive from detectors and ultimately from the
     network. Mapping an event to an action via eval, import-by-name or a
     shell string would make the bus a remote-code-execution surface. The
     registry below is a static tuple of dataclasses reviewed at build time;
     target extraction is a named Python function, and every playbook is a
     fixed argv vector with substituted, validated parameters.

  2. autonomy.json IS THE SINGLE AUTHORITY, AND IT FAILS CLOSED. Absent,
     unreadable, truncated, not-a-dict, or naming a level we do not recognise
     all resolve to "off". A corrupt config must never be read as consent. Note
     this is deliberately stricter than the Control Center's *display* default
     of "propose": the UI shows propose for a class the operator has never
     touched, the engine treats it as off. Both are non-acting, and the engine
     errs downward on purpose.

  3. EVERY ACTION IS REVERSIBLE AND EXPIRES. An automated responder that leaves
     permanent state behind is a self-inflicted outage waiting for the operator
     to go to bed. Each applied action records its own undo and a TTL; the
     daemon reverts it when the TTL passes unless the operator renews it. The
     ledger is on disk, so a daemon restart (or a crash mid-incident) does not
     orphan a block.

  4. THE LEDGER AND THE AUDIT CHAIN ARE THE SAME OBJECT. Two append-only logs
     that must agree is a dual-authority bug (CLAUDE.md #10). One
     hash-chained JSONL file is both the tamper-evident audit record and the
     source of truth for what is currently in force; current state is a replay,
     never a second file that can drift.

@decision DEC-PHASE12-023a
@title Never-lock-out guard is a hard precondition, not a policy knob
@status accepted
@rationale The failure mode that ends the deck's usefulness is not "failed to
  block an attacker", it is "blocked the operator". A responder that firewalls
  off its own admin during an incident has converted a detection into an
  outage. Loopback, every address the operator is currently connected from,
  the deck's own addresses, the default gateway, the mesh subnet and the
  operator's allowlist are refused before consent is even consulted: there is
  no autonomy level, including a manual operator run, that lifts them.
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import pwd
import tempfile
import time
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Paths. Every one is env-overridable so the test suite runs unprivileged and
# leaves nothing outside the repo's tmp/ (CLAUDE.md: no /tmp).
# ---------------------------------------------------------------------------

def operator_config_dir() -> Path:
    """~/.config/orionx for the DESKTOP OPERATOR, not for whoever is running us.

    This is load-bearing, not a convenience. The Control Center writes
    autonomy.json as the desktop user (orionx-operator on the shipped image);
    the daemon runs as root under systemd, where Path.home() is /root. Reading
    /root/.config would give the engine a second, always-empty view of the
    operator's consent — a dual-authority bug (CLAUDE.md #10) whose symptom is
    the worst possible one: the grid says "autonomous" and the engine, reading
    a different file, silently does nothing.

    Resolution order, first hit wins: an explicit override, the unit's
    ORIONX_OPERATOR_USER, SUDO_USER (so `sudo orionx-heal` still sees the
    operator's grid), then — only when we are root — the first regular account
    in /etc/passwd. Falling back to Path.home() is correct for an unprivileged
    invocation by the operator themselves.
    """
    override = os.environ.get("ORIONX_CONFIG_DIR", "").strip()
    if override:
        return Path(override)
    if os.geteuid() != 0:
        return Path.home() / ".config" / "orionx"
    for var in ("ORIONX_OPERATOR_USER", "SUDO_USER"):
        name = os.environ.get(var, "").strip()
        if name and name != "root":
            try:
                return Path(pwd.getpwnam(name).pw_dir) / ".config" / "orionx"
            except KeyError:
                continue
    try:
        with open("/etc/passwd", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.split(":")
                if len(parts) >= 6 and parts[5].startswith("/home/"):
                    try:
                        if 1000 <= int(parts[2]) < 65534:
                            return Path(parts[5]) / ".config" / "orionx"
                    except ValueError:
                        continue
    except OSError:
        pass
    return Path.home() / ".config" / "orionx"


#: Operator's standing consent. Written by the Control Center Auto-Healing tab.
AUTONOMY_FILE = Path(
    os.environ.get("ORIONX_AUTONOMY_FILE", "")
    or (operator_config_dir() / "autonomy.json")
)

#: Engine tuning the operator may edit by hand (never-block list, TTLs).
HEALING_CONFIG_FILE = Path(
    os.environ.get("ORIONX_HEALING_CONFIG", "")
    or (operator_config_dir() / "healing.json")
)

#: Persistent state root. NOT /run: rollback intent must survive a restart.
STATE_DIR = Path(os.environ.get("ORIONX_HEALING_STATE", "/var/lib/orionx/healing"))

#: The hash-chained ledger: audit record and current-state authority in one.
def chain_path() -> Path:
    return STATE_DIR / "chain.jsonl"


def quarantine_dir() -> Path:
    return STATE_DIR / "quarantine"


def backup_dir() -> Path:
    return STATE_DIR / "backups"


#: The world-readable projection of the chain (DEC-PHASE12-085). heald writes
#: it as root; the Cockpit (operator uid) reads it, because the chain itself is
#: root:0600 and must stay that way.
HEALING_STATUS_FILE = Path(os.environ.get("ORIONX_HEALING_STATUS",
                                          "/run/orionx/healing-status.json"))

#: The R.A.I.N. event bus (rain_lib.EVENT_LOG). Read-only from here.
EVENT_LOG = Path(os.environ.get("ORIONX_EVENT_LOG", "/run/orionx/events.jsonl"))

# ---------------------------------------------------------------------------
# Autonomy model
# ---------------------------------------------------------------------------
LEVELS = ("off", "propose", "confirm", "autonomous")
LEVEL_RANK = {name: i for i, name in enumerate(LEVELS)}

#: What the engine does when it has nothing else to go on. Fails closed.
FAILSAFE_LEVEL = "off"

# Disposition of a gating decision. Distinct from the level so the caller
# cannot accidentally compare strings and get "propose" to act.
ACT_SKIP = "skip"            # do nothing at all
ACT_PROPOSE = "propose"      # emit a suggestion event; never touch the system
ACT_AWAIT = "await_confirm"  # record a pending action; wait for `orionx-heal confirm`
ACT_EXECUTE = "execute"      # run it now

_DISPOSITION = {
    "off": ACT_SKIP,
    "propose": ACT_PROPOSE,
    "confirm": ACT_AWAIT,
    "autonomous": ACT_EXECUTE,
}


def load_autonomy(path: Path | None = None) -> dict[str, str]:
    """Read the operator's standing consent. Fails closed, always.

    Any failure — missing file, unreadable, invalid JSON, a JSON scalar or list
    instead of an object, a value that is not one of LEVELS — yields a mapping
    that grants nothing. An empty dict means "off everywhere", never
    "unrestricted": level_for() defaults to FAILSAFE_LEVEL.
    """
    p = Path(path) if path is not None else AUTONOMY_FILE
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {
        str(k): v
        for k, v in data.items()
        if isinstance(v, str) and v in LEVEL_RANK
    }


def level_for(autonomy: dict[str, str], playbook: str) -> str:
    """The pre-approved level for one action class; unset/unknown -> off."""
    lvl = autonomy.get(playbook)
    return lvl if lvl in LEVEL_RANK else FAILSAFE_LEVEL


def disposition(level: str) -> str:
    """Map a consent level to what the engine is permitted to do.

    The only level that returns ACT_EXECUTE is "autonomous". `propose` emits a
    suggestion and stops; `confirm` parks a pending action and stops. Neither
    ever reaches a playbook.
    """
    return _DISPOSITION.get(level, ACT_SKIP)


def may_act_now(autonomy: dict[str, str], playbook: str) -> bool:
    """True only when the operator pre-approved fully autonomous action."""
    return disposition(level_for(autonomy, playbook)) == ACT_EXECUTE


# ---------------------------------------------------------------------------
# Engine config (never-block allowlist, TTL overrides)
# ---------------------------------------------------------------------------
def default_config() -> dict[str, Any]:
    return {
        # Extra addresses/CIDRs the engine must never block, on top of the
        # structural guards (loopback, self, gateway, mesh, live sessions).
        "never_block": [],
        # Mesh subnet — mirrors mesh-lib.sh MESH_SUBNET (DEC-MESH-004).
        "mesh_subnet": "10.0.99.0/24",
        # Per-playbook TTL overrides, seconds. 0 disables auto-revert.
        "ttl": {},
        # Debounce: minimum seconds between two actions on the same target.
        "cooldown_seconds": 300.0,
        # Storm guard: at most this many actions per playbook per window.
        "max_actions_per_window": 5,
        "window_seconds": 300.0,
    }


def load_config(path: Path | None = None) -> dict[str, Any]:
    """Engine config merged over defaults; tolerant of a missing/corrupt file."""
    cfg = default_config()
    p = Path(path) if path is not None else HEALING_CONFIG_FILE
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if isinstance(data, dict):
        for k in cfg:
            if k in data:
                cfg[k] = data[k]
    if not isinstance(cfg.get("never_block"), list):
        cfg["never_block"] = []
    if not isinstance(cfg.get("ttl"), dict):
        cfg["ttl"] = {}
    for num_key, lo in (("cooldown_seconds", 0.0), ("window_seconds", 1.0),
                        ("max_actions_per_window", 1)):
        try:
            cfg[num_key] = max(lo, type(lo)(cfg[num_key]))
        except (TypeError, ValueError):
            cfg[num_key] = default_config()[num_key]
    return cfg


# ---------------------------------------------------------------------------
# Playbook registry — STATIC. Reviewed at build time, never built at runtime.
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Playbook:
    """Metadata for one action class. The implementation lives in playbooks.py."""

    name: str
    summary: str
    #: What reverting it actually restores, in the operator's words.
    undo_summary: str
    #: Name of the single parameter the playbook acts on ("" for host-wide).
    param: str
    #: Seconds until auto-revert. 0 = no timer; manual undo only.
    default_ttl: float
    #: True when undo fully restores the prior state. False means the undo
    #: restores containment but cannot recreate what was destroyed; stated so
    #: the operator is never told a lie about reversibility.
    fully_reversible: bool = True


REGISTRY: tuple[Playbook, ...] = (
    Playbook(
        name="block_ip",
        summary="Drop traffic from a hostile source via the nftables "
                "'inet orionx_healing' blocked set.",
        undo_summary="Delete the address from the set; traffic flows again.",
        param="ip",
        default_ttl=3600.0,
    ),
    Playbook(
        name="kill_process",
        summary="Stop a malicious or runaway process; if it belongs to a "
                "systemd unit, stop the unit so it cannot respawn.",
        undo_summary="Restart the systemd unit. A bare PID cannot be "
                     "resurrected — that part is one-way.",
        param="pid",
        default_ttl=1800.0,
        fully_reversible=False,
    ),
    Playbook(
        name="quarantine_file",
        summary="Move a suspicious file into the sealed vault (mode 0000) and "
                "record its hash, owner and mode.",
        undo_summary="Move it back to its original path and restore mode/owner.",
        param="path",
        default_ttl=86400.0,
    ),
    Playbook(
        name="isolate_node",
        summary="Cut this host off the network with a drop-policy nftables "
                "table, keeping loopback and the operator's live sessions.",
        undo_summary="Delete the isolation table; connectivity returns.",
        param="",
        # Deliberately short. Isolation is the most drastic thing the engine
        # can do to its own host, so it lapses in 15 minutes unless renewed.
        default_ttl=900.0,
    ),
    Playbook(
        name="rotate_mesh_keys",
        summary="Back up the WireGuard mesh private key and install a freshly "
                "generated one on the live interface.",
        undo_summary="Restore the backed-up key and re-apply it to the "
                     "interface.",
        param="",
        # No timer: auto-reverting to a key you rotated away from because you
        # believed it was compromised is the wrong default in every case.
        default_ttl=0.0,
    ),
    Playbook(
        name="revoke_matrix_session",
        summary="Delete the compromised Matrix device (invalidating its access "
                "token) and lock the account via the Synapse admin API.",
        undo_summary="Unlock the account. The deleted device is not recreated "
                     "— the user simply logs in again.",
        param="user",
        default_ttl=3600.0,
        fully_reversible=False,
    ),
)

PLAYBOOKS: dict[str, Playbook] = {p.name: p for p in REGISTRY}
PLAYBOOK_NAMES: tuple[str, ...] = tuple(p.name for p in REGISTRY)


def ttl_for(playbook: str, cfg: dict[str, Any] | None = None) -> float:
    """TTL in seconds for a playbook, honouring a config override."""
    pb = PLAYBOOKS.get(playbook)
    base = pb.default_ttl if pb else 0.0
    if cfg:
        try:
            override = cfg.get("ttl", {}).get(playbook)
            if override is not None:
                return max(0.0, float(override))
        except (TypeError, ValueError, AttributeError):
            pass
    return base


# ---------------------------------------------------------------------------
# Event -> playbook mapping. Named extractors only; no eval, no getattr.
# ---------------------------------------------------------------------------
SEVERITIES = ("info", "notice", "warning", "critical")
_SEV_RANK = {s: i for i, s in enumerate(SEVERITIES)}

#: Events the engine itself published. Consuming them would let one action's
#: own announcement trigger the next — a feedback loop on a shared bus.
SELF_SOURCE = "healing"


def _first_match(text: str, prefixes: tuple[str, ...]) -> str | None:
    """Pull a `key=value` token out of a message. Deliberately dumb: no regex
    backtracking on attacker-influenced text, no group capture surprises."""
    for token in str(text).replace(",", " ").split():
        for pre in prefixes:
            if token.startswith(pre) and len(token) > len(pre):
                return token[len(pre):].strip("\"'")
    return None


def extract_ip(event: dict[str, Any]) -> str | None:
    """Find a source address in an event message ("from 1.2.3.4" or SRC=1.2.3.4)."""
    msg = str(event.get("message", ""))
    cand = _first_match(msg, ("SRC=", "src=", "ip=", "IP="))
    if cand is None:
        words = msg.replace(",", " ").split()
        for i, w in enumerate(words):
            if w.lower() == "from" and i + 1 < len(words):
                cand = words[i + 1].rstrip(".;:")
                break
    if cand is None:
        return None
    try:
        return str(ipaddress.ip_address(cand))
    except ValueError:
        return None


def extract_pid(event: dict[str, Any]) -> str | None:
    cand = _first_match(str(event.get("message", "")), ("pid=", "PID="))
    if cand is None or not cand.isdigit():
        return None
    return cand if 1 < int(cand) < 2**22 else None


def extract_path(event: dict[str, Any]) -> str | None:
    cand = _first_match(str(event.get("message", "")), ("path=", "file=", "PATH="))
    if not cand or not cand.startswith("/") or "\x00" in cand:
        return None
    return cand


def extract_user(event: dict[str, Any]) -> str | None:
    cand = _first_match(str(event.get("message", "")), ("user=", "mxid="))
    if not cand or not cand.startswith("@") or ":" not in cand:
        return None
    return cand


def extract_none(event: dict[str, Any]) -> str | None:
    """Host-wide playbooks take no target."""
    return ""


@dataclass(frozen=True)
class Trigger:
    """One reviewed rule: this kind of event may propose this playbook."""

    playbook: str
    source: str
    category: str
    min_severity: str
    extract: Callable[[dict[str, Any]], str | None]
    why: str


TRIGGERS: tuple[Trigger, ...] = (
    Trigger("block_ip", "firewall", "scan", "critical", extract_ip,
            "a host that swept our ports is scanning us; drop it"),
    Trigger("block_ip", "suricata", "ids", "critical", extract_ip,
            "signature match attributed to a source address"),
    Trigger("block_ip", "nucleotide", "scan", "critical", extract_ip,
            "exploit-template attribution on inbound requests"),
    Trigger("quarantine_file", "yara", "malware", "warning", extract_path,
            "a YARA rule matched a file on disk"),
    Trigger("kill_process", "go-roast", "process", "critical", extract_pid,
            "a process was identified as malicious"),
    Trigger("isolate_node", "health", "compromise", "critical", extract_none,
            "host compromise asserted; contain before it spreads"),
    Trigger("rotate_mesh_keys", "mesh", "keycompromise", "critical", extract_none,
            "mesh key material is suspected exposed"),
    Trigger("revoke_matrix_session", "matrix", "session", "critical", extract_user,
            "a chat session is believed hijacked"),
)


def severity_at_least(sev: str, floor: str) -> bool:
    return _SEV_RANK.get(str(sev).lower().strip(), -1) >= _SEV_RANK.get(floor, 99)


@dataclass(frozen=True)
class Proposal:
    """What the registry says should happen for one event. Not yet permitted."""

    playbook: str
    target: str
    reason: str
    severity: str
    source_event: dict[str, Any] = field(default_factory=dict, repr=False)


def match_event(event: dict[str, Any]) -> Proposal | None:
    """Map one bus event to at most one playbook proposal, or None.

    Returns None for the engine's own events (loop prevention), for anything
    below a trigger's severity floor, and for any event whose target cannot be
    extracted and validated.
    """
    if not isinstance(event, dict):
        return None
    source = str(event.get("source", "")).strip().lower()
    if source == SELF_SOURCE:
        return None
    category = str(event.get("category", "")).strip().lower()
    severity = str(event.get("severity", "")).strip().lower()
    for trig in TRIGGERS:
        if trig.source != source or trig.category != category:
            continue
        if not severity_at_least(severity, trig.min_severity):
            continue
        target = trig.extract(event)
        if target is None:
            continue
        return Proposal(trig.playbook, target, trig.why, severity, event)
    return None


# ---------------------------------------------------------------------------
# Never-lock-out guards
# ---------------------------------------------------------------------------
#: Paths whose contents keep the deck bootable and the operator in control.
#: Quarantining anything under these is refused: moving /usr/bin/bash into a
#: 0000 vault is not containment, it is a brick.
PROTECTED_PATH_PREFIXES: tuple[str, ...] = (
    "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/usr", "/etc",
    "/boot", "/proc", "/sys", "/dev", "/run", "/opt/orionx", "/var/lib/orionx",
)

#: PID 1 and the kernel's pid 0 are never killable; nor is our own process.
UNKILLABLE_PIDS: tuple[int, ...] = (0, 1)


@dataclass
class GuardContext:
    """Everything the guards need, gathered once by the caller.

    Held as plain data so tests can construct an adversarial context (operator
    on the same /24 as the attacker, mesh overlapping, etc.) without a host.
    """

    #: Addresses the operator is currently reaching the deck from.
    operator_addrs: set[str] = field(default_factory=set)
    #: Addresses configured on this host.
    local_addrs: set[str] = field(default_factory=set)
    #: Default gateways. Blocking one takes the deck off the network.
    gateways: set[str] = field(default_factory=set)
    #: Operator's explicit allowlist, addresses or CIDRs.
    never_block: tuple[str, ...] = ()
    #: Mesh subnet; peers here are our own fleet.
    mesh_subnet: str = "10.0.99.0/24"
    #: Our own PID, so the engine cannot kill itself.
    self_pid: int = 0


def _in_any_cidr(addr: ipaddress._BaseAddress, spec: str) -> bool:
    spec = str(spec).strip()
    if not spec:
        return False
    try:
        net = ipaddress.ip_network(spec, strict=False)
    except ValueError:
        try:
            return addr == ipaddress.ip_address(spec)
        except ValueError:
            return False
    return addr.version == net.version and addr in net


def check_block_target(target: str, ctx: GuardContext) -> tuple[bool, str]:
    """May this address be blocked? Returns (allowed, reason-if-not).

    This runs BEFORE consent is consulted and cannot be overridden by any
    autonomy level, including a manual `orionx-heal run`. See DEC-PHASE12-023a.
    """
    raw = str(target).strip()
    if not raw:
        return False, "no address given"
    try:
        addr = ipaddress.ip_address(raw)
    except ValueError:
        return False, f"{raw!r} is not an IP address"

    if addr.is_loopback:
        return False, "loopback — blocking it breaks local services"
    if addr.is_unspecified:
        return False, "unspecified address (0.0.0.0/::) would match everything"
    if addr.is_multicast:
        return False, "multicast address is not a traffic source"
    if addr.is_link_local:
        return False, "link-local — needed for autoconfiguration and discovery"
    if raw in ctx.operator_addrs:
        return False, "the operator is connected from this address right now"
    if raw in ctx.local_addrs:
        return False, "this is one of the deck's own addresses"
    if raw in ctx.gateways:
        return False, "default gateway — blocking it severs all networking"
    if _in_any_cidr(addr, ctx.mesh_subnet):
        return False, f"inside the mesh subnet {ctx.mesh_subnet}"
    for spec in ctx.never_block:
        if _in_any_cidr(addr, spec):
            return False, f"matches the never-block entry {spec}"
    return True, ""


def check_kill_target(target: str, ctx: GuardContext) -> tuple[bool, str]:
    """May this PID be killed? Refuses init, the kernel, and the engine itself."""
    raw = str(target).strip()
    if not raw.isdigit():
        return False, f"{raw!r} is not a PID"
    pid = int(raw)
    if pid in UNKILLABLE_PIDS:
        return False, f"PID {pid} is init/kernel — killing it halts the deck"
    if ctx.self_pid and pid == ctx.self_pid:
        return False, "that is the healing engine's own PID"
    if pid == os.getpid() or pid == os.getppid():
        return False, "that is the healing engine's own process tree"
    return True, ""


def check_quarantine_target(target: str, ctx: GuardContext | None = None) -> tuple[bool, str]:
    """May this file be quarantined? Refuses the system's own tree."""
    raw = str(target).strip()
    if not raw.startswith("/"):
        return False, "quarantine needs an absolute path"
    if "\x00" in raw:
        return False, "path contains a NUL byte"
    try:
        norm = os.path.normpath(raw)
    except ValueError:
        return False, "unparseable path"
    if norm in ("/", ""):
        return False, "refusing to quarantine the filesystem root"
    for prefix in PROTECTED_PATH_PREFIXES:
        if norm == prefix or norm.startswith(prefix + "/"):
            return False, f"{norm} is under the protected system tree {prefix}"
    return True, ""


def check_target(playbook: str, target: str, ctx: GuardContext) -> tuple[bool, str]:
    """Dispatch to the right guard. Unknown playbooks are refused."""
    if playbook not in PLAYBOOKS:
        return False, f"unknown playbook {playbook!r}"
    if playbook == "block_ip":
        return check_block_target(target, ctx)
    if playbook == "kill_process":
        return check_kill_target(target, ctx)
    if playbook == "quarantine_file":
        return check_quarantine_target(target, ctx)
    if playbook == "revoke_matrix_session":
        t = str(target).strip()
        if not t.startswith("@") or ":" not in t:
            return False, "expected a Matrix user id like @user:server"
        return True, ""
    # isolate_node / rotate_mesh_keys act on the host and take no target.
    return True, ""


# ---------------------------------------------------------------------------
# Debounce / storm guard
# ---------------------------------------------------------------------------
class RateLimiter:
    """Two guards in one: a per-target cooldown and a per-playbook storm cap.

    A single noisy detector must not turn into a hundred nftables writes. The
    cooldown stops the same target being re-actioned; the window cap stops a
    spoofed-source flood from producing one action per forged address. Memory
    is bounded — an unbounded table here would be a DoS against the responder.
    """

    def __init__(self, cooldown: float = 300.0, max_per_window: int = 5,
                 window: float = 300.0, max_keys: int = 2048) -> None:
        self.cooldown = float(cooldown)
        self.max_per_window = int(max_per_window)
        self.window = float(window)
        self.max_keys = int(max_keys)
        self._last: OrderedDict[tuple[str, str], float] = OrderedDict()
        self._recent: dict[str, list[float]] = {}

    def allow(self, playbook: str, target: str, now: float) -> tuple[bool, str]:
        key = (playbook, str(target))
        prev = self._last.get(key)
        if prev is not None and (now - prev) < self.cooldown:
            wait = self.cooldown - (now - prev)
            return False, f"debounced: same target actioned {now - prev:.0f}s ago (retry in {wait:.0f}s)"
        hits = [t for t in self._recent.get(playbook, []) if t > now - self.window]
        if len(hits) >= self.max_per_window:
            self._recent[playbook] = hits
            return False, (f"storm guard: {len(hits)} {playbook} actions already "
                           f"in the last {self.window:.0f}s")
        return True, ""

    def record(self, playbook: str, target: str, now: float) -> None:
        key = (playbook, str(target))
        if key not in self._last and len(self._last) >= self.max_keys:
            self._last.popitem(last=False)
        self._last[key] = now
        self._last.move_to_end(key)
        hits = [t for t in self._recent.get(playbook, []) if t > now - self.window]
        hits.append(now)
        self._recent[playbook] = hits[-self.max_per_window * 4:]

    def tracked(self) -> int:
        return len(self._last)


# ---------------------------------------------------------------------------
# Merkle audit chain
# ---------------------------------------------------------------------------
GENESIS_HASH = "0" * 64

#: Entry kinds. Anything else is treated as an unknown record and does not
#: affect replayed state, but still participates in the hash chain.
KIND_PROPOSED = "proposed"
KIND_PENDING = "pending"
KIND_APPLIED = "applied"
KIND_REVERTED = "reverted"
KIND_EXPIRED = "expired"
KIND_RENEWED = "renewed"
KIND_REFUSED = "refused"
KIND_FAILED = "failed"
KIND_DENIED = "denied"


def canonical(entry: dict[str, Any]) -> str:
    """Deterministic serialisation of an entry for hashing.

    Key order, separators and unicode handling are pinned: the same logical
    record must hash identically on every deck and after any round-trip through
    JSON, or verification would report tampering on honest data.
    """
    body = {k: v for k, v in entry.items() if k != "hash"}
    return json.dumps(body, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, default=str)


def entry_hash(entry: dict[str, Any]) -> str:
    """H(prev || canonical(entry)) — each record commits to its predecessor."""
    prev = str(entry.get("prev", GENESIS_HASH))
    return hashlib.sha256((prev + canonical(entry)).encode("utf-8")).hexdigest()


def seal(entry: dict[str, Any], prev_hash: str) -> dict[str, Any]:
    """Return a copy of `entry` linked to prev_hash and sealed with its hash."""
    sealed = dict(entry)
    sealed["prev"] = prev_hash
    sealed["hash"] = entry_hash(sealed)
    return sealed


def verify_chain(entries: list[dict[str, Any]]) -> tuple[bool, int, str]:
    """Walk the chain. Returns (ok, first_bad_index, reason).

    An index of -1 with ok=True means every link holds. Detects three distinct
    tampers: a rewritten record (its own hash no longer matches its content), a
    removed or reordered record (the successor's `prev` no longer matches), and
    a truncated-then-rebuilt prefix (the genesis link is wrong).
    """
    prev = GENESIS_HASH
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            return False, i, "record is not a JSON object"
        got_prev = str(entry.get("prev", ""))
        if got_prev != prev:
            return False, i, (f"broken link: record {i} claims prev={got_prev[:16]}… "
                              f"but the chain is at {prev[:16]}…")
        recorded = str(entry.get("hash", ""))
        recomputed = entry_hash(entry)
        if recorded != recomputed:
            return False, i, (f"record {i} has been altered: stored hash "
                              f"{recorded[:16]}… != recomputed {recomputed[:16]}…")
        prev = recorded
    return True, -1, ""


def read_chain(path: Path | None = None) -> list[dict[str, Any]]:
    """Load the ledger. A malformed line becomes a placeholder so verification
    reports it as a break rather than silently skipping the damage."""
    return read_chain_checked(path)[0]


def read_chain_checked(path: Path | None = None) -> tuple[list[dict[str, Any]], str | None]:
    """(entries, None), or ([], why) when the chain exists but cannot be read.
    An absent chain is an empty one, not an error."""
    p = Path(path) if path is not None else chain_path()
    out: list[dict[str, Any]] = []
    try:
        text = p.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return out, None
    except OSError as exc:
        return out, f"cannot read the audit chain {p}: {exc}"
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            out.append({"prev": "<unparseable>", "hash": "<unparseable>",
                        "raw": line[:200]})
            continue
        out.append(obj if isinstance(obj, dict) else {"prev": "", "hash": "",
                                                      "raw": str(obj)[:200]})
    return out, None


def head_hash(entries: list[dict[str, Any]]) -> str:
    return str(entries[-1].get("hash", GENESIS_HASH)) if entries else GENESIS_HASH


def append_entry(entry: dict[str, Any], path: Path | None = None) -> dict[str, Any]:
    """Seal `entry` onto the chain head and append it atomically.

    O_APPEND with a single write keeps concurrent emitters from interleaving,
    matching the convention rain_lib uses for the event bus. The head is re-read
    immediately before sealing so a second writer cannot fork the chain silently
    — if it does, verification catches it.
    """
    p = Path(path) if path is not None else chain_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    sealed = seal(entry, head_hash(read_chain(p)))
    line = json.dumps(sealed, ensure_ascii=False, default=str) + "\n"
    fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)
    return sealed


def new_action_id(playbook: str, target: str, now: float) -> str:
    """Short, stable, collision-resistant handle the operator can type."""
    raw = f"{playbook}|{target}|{now:.6f}|{os.getpid()}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]


# ---------------------------------------------------------------------------
# State replay — the ledger is the only authority for what is in force
# ---------------------------------------------------------------------------
@dataclass
class ActionState:
    action_id: str
    playbook: str
    target: str
    applied_at: float
    expires_at: float          # 0.0 == no auto-revert
    undo: dict[str, Any]
    level: str
    status: str                # "active" | "reverted" | "expired" | "pending"


def replay(entries: list[dict[str, Any]]) -> dict[str, ActionState]:
    """Rebuild current state from the chain. Pure: same input, same answer."""
    state: dict[str, ActionState] = {}
    for e in entries:
        kind = str(e.get("kind", ""))
        aid = str(e.get("action_id", ""))
        if not aid:
            continue
        if kind in (KIND_APPLIED, KIND_PENDING):
            state[aid] = ActionState(
                action_id=aid,
                playbook=str(e.get("playbook", "")),
                target=str(e.get("target", "")),
                applied_at=float(e.get("ts", 0.0) or 0.0),
                expires_at=float(e.get("expires_at", 0.0) or 0.0),
                undo=e.get("undo") if isinstance(e.get("undo"), dict) else {},
                level=str(e.get("level", "")),
                status="pending" if kind == KIND_PENDING else "active",
            )
        elif kind in (KIND_REVERTED, KIND_EXPIRED, KIND_DENIED) and aid in state:
            state[aid].status = "reverted" if kind == KIND_REVERTED else (
                "expired" if kind == KIND_EXPIRED else "denied")
        elif kind == KIND_RENEWED and aid in state:
            try:
                state[aid].expires_at = float(e.get("expires_at", 0.0) or 0.0)
            except (TypeError, ValueError):
                pass
    return state


def active_actions(entries: list[dict[str, Any]]) -> list[ActionState]:
    return [a for a in replay(entries).values() if a.status == "active"]


def pending_actions(entries: list[dict[str, Any]]) -> list[ActionState]:
    return [a for a in replay(entries).values() if a.status == "pending"]


def due_for_rollback(entries: list[dict[str, Any]], now: float) -> list[ActionState]:
    """Active actions whose rollback timer has elapsed. TTL 0 never expires."""
    return [a for a in active_actions(entries)
            if a.expires_at and a.expires_at <= now]


def expired_pending(entries: list[dict[str, Any]], now: float,
                    grace: float = 3600.0) -> list[ActionState]:
    """Confirm-level proposals the operator never answered. They lapse, never
    escalate: an unanswered question is a 'no'."""
    return [a for a in replay(entries).values()
            if a.status == "pending" and a.applied_at and
            (now - a.applied_at) > grace]


# ---------------------------------------------------------------------------
# The published projection (contract with the Cockpit)
# ---------------------------------------------------------------------------
# @decision DEC-PHASE12-085
# @title heald publishes /run/orionx/healing-status.json; the chain stays root:0600
# @status accepted
# @rationale QA round 1 (python P1-1, P1-2). The chain is root:0600 so the
#   Cockpit (operator uid) could not read it on the deck, and its own replay
#   looked for a "status":"active" the engine never writes - IN FORCE was
#   always empty while the deck was blocking a host. Loosening the chain mode
#   would expose undo data (vault paths, nft handles) and invite a second
#   replay implementation. Instead the ONE replay (replay()/active_actions()/
#   pending_actions()) is projected by root into a 0644 file, atomically
#   (temp + rename in the same directory), on every chain append and at least
#   every 10 s by the daemon loop. Schema (agreed with the Cockpit owner):
#     {"ts": float, "chain_ok": bool|null,
#      "in_force": [{"id","action","target","applied_ts","expires_ts"|null}],
#      "pending":  [{"id","action","target","proposed_ts"}],
#      "error": str|null}
#   chain_ok is null when the chain could not be read (error says why);
#   false when verification failed (error carries the break). An unreadable
#   chain yields empty lists AND the error, never silently empty lists.
def status_snapshot(path: Path | None = None, now: float | None = None,
                    extra_error: str | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    entries, err = read_chain_checked(path)
    if err is not None:
        return {"ts": now, "chain_ok": None, "in_force": [], "pending": [],
                "error": "; ".join(x for x in (err, extra_error) if x)}
    ok, idx, why = verify_chain(entries)
    errors = [] if ok else [f"audit chain broken at record {idx}: {why}"]
    if extra_error:
        errors.append(extra_error)
    state = replay(entries).values()
    return {
        "ts": now,
        "chain_ok": ok,
        "in_force": [{"id": a.action_id, "action": a.playbook, "target": a.target,
                      "applied_ts": float(a.applied_at),
                      "expires_ts": float(a.expires_at) if a.expires_at else None}
                     for a in state if a.status == "active"],
        "pending": [{"id": a.action_id, "action": a.playbook, "target": a.target,
                     "proposed_ts": float(a.applied_at)}
                    for a in state if a.status == "pending"],
        "error": "; ".join(errors) or None,
    }


def write_status(payload: dict[str, Any], path: Path | None = None) -> None:
    """Atomic 0644 write: unique temp file in the target directory, then rename.
    Raises OSError; the caller decides how to report it."""
    p = Path(path) if path is not None else HEALING_STATUS_FILE
    fd, tmp = tempfile.mkstemp(prefix=".healing-status.", suffix=".tmp", dir=str(p.parent))
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, sort_keys=True)
        os.replace(tmp, p)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def describe_remaining(action: ActionState, now: float) -> str:
    if not action.expires_at:
        return "no timer (manual undo only)"
    left = action.expires_at - now
    if left <= 0:
        return "expired — reverting"
    if left < 120:
        return f"{left:.0f}s left"
    return f"{left / 60:.0f}m left"


def now_iso(ts: float | None = None) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(ts or time.time()))
