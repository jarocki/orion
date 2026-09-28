#!/usr/bin/env python3
"""engine — orchestration shared by the orionx-heald daemon and the orionx-heal CLI.

healing_lib decides, playbooks act, and this is the thin layer that puts them in
the right order and writes down what happened. It is the only place that:

  * re-reads autonomy.json before every single decision (the operator may
    revoke consent mid-incident and must not have to restart a daemon for that
    to take effect),
  * applies the never-lock-out guards BEFORE consent is consulted,
  * seals every outcome — including refusals and failures — into the
    hash-chained ledger,
  * announces itself on the R.A.I.N. bus so the Cockpit shows what the engine
    did, not just what the detectors saw.

@decision DEC-PHASE12-023
@title Guards first, consent second, ledger always
@status accepted
@rationale The ordering is the safety property. Checking consent first and
  guards second would mean an "autonomous" block_ip briefly looks permitted
  against the operator's own address, and any later refactor that forgets the
  guard turns a warning into a lockout. Guards are unconditional preconditions
  and run first, so no level — not even a manual operator run — reaches a
  playbook with a forbidden target.

  Every outcome is written, not just the successes. A responder whose audit
  chain only records what it did cannot answer the question that actually
  matters after an incident: what did it decline to do, and why.
"""

from __future__ import annotations

import ipaddress
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import healing_lib as hl  # noqa: E402
import playbooks as pb  # noqa: E402

#: How long a confirm-level proposal waits for an operator answer before it
#: lapses. Unanswered is "no" — a question nobody answered must never escalate.
CONFIRM_GRACE_SECONDS = 3600.0


# ---------------------------------------------------------------------------
# Host probing (impure; the pure guards consume its output)
# ---------------------------------------------------------------------------
def _cmd(argv: list[str]) -> str:
    try:
        proc = subprocess.run(argv, capture_output=True, text=True,
                              timeout=10, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return proc.stdout if proc.returncode == 0 else ""


_IP_RE = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3}|[0-9a-fA-F:]{2,}:[0-9a-fA-F:]*)\b")


def detect_operator_addresses() -> set[str]:
    """Every address a human is currently reaching this deck from.

    Three independent sources, unioned rather than ranked, because each one
    misses a case the others catch: SSH_CONNECTION only sees our own inherited
    session, `who` misses X/console logins without a remote host, and `ss` only
    sees sockets that exist right now. Over-collecting here is the safe error:
    the worst outcome is declining to block one extra address.
    """
    found: set[str] = set()
    for var in ("SSH_CONNECTION", "SSH_CLIENT"):
        val = os.environ.get(var, "").split()
        if val:
            found.add(val[0])
    for line in _cmd(["who"]).splitlines():
        if "(" in line and ")" in line:
            inner = line[line.rfind("(") + 1:line.rfind(")")]
            m = _IP_RE.search(inner)
            if m:
                found.add(m.group(1))
    for line in _cmd(["ss", "-Htn", "state", "established"]).splitlines():
        for token in line.split():
            if ":" in token:
                host = token.rsplit(":", 1)[0].strip("[]")
                try:
                    addr = ipaddress.ip_address(host)
                except ValueError:
                    continue
                if not addr.is_loopback:
                    found.add(str(addr))
    return {a for a in found if a}


def detect_local_addresses() -> set[str]:
    out: set[str] = set()
    for line in _cmd(["ip", "-o", "addr", "show"]).splitlines():
        parts = line.split()
        for i, p in enumerate(parts):
            if p in ("inet", "inet6") and i + 1 < len(parts):
                out.add(parts[i + 1].split("/")[0])
    return out


def detect_gateways() -> set[str]:
    out: set[str] = set()
    for family in ("-4", "-6"):
        for line in _cmd(["ip", family, "route", "show", "default"]).splitlines():
            parts = line.split()
            if "via" in parts:
                out.add(parts[parts.index("via") + 1])
    return out


def collect_guards(cfg: dict[str, Any]) -> hl.GuardContext:
    never = tuple(str(x) for x in cfg.get("never_block", []) if str(x).strip())
    return hl.GuardContext(
        operator_addrs=detect_operator_addresses(),
        local_addrs=detect_local_addresses(),
        gateways=detect_gateways(),
        never_block=never,
        mesh_subnet=str(cfg.get("mesh_subnet", "10.0.99.0/24")),
        self_pid=os.getpid(),
    )


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------
class Engine:
    def __init__(self, dry_run: bool = False, verbose: bool = False,
                 state_dir: Path | None = None, probe_host: bool = True) -> None:
        self.dry_run = bool(dry_run)
        self.verbose = bool(verbose)
        self.state_dir = Path(state_dir) if state_dir else hl.STATE_DIR
        self.config = hl.load_config()
        self.guards = collect_guards(self.config) if probe_host else hl.GuardContext(
            never_block=tuple(str(x) for x in self.config.get("never_block", [])),
            mesh_subnet=str(self.config.get("mesh_subnet", "10.0.99.0/24")),
            self_pid=os.getpid(),
        )
        self.limiter = hl.RateLimiter(
            cooldown=float(self.config.get("cooldown_seconds", 300.0)),
            max_per_window=int(self.config.get("max_actions_per_window", 5)),
            window=float(self.config.get("window_seconds", 300.0)),
        )
        self.runner = pb.Runner(dry_run=self.dry_run, verbose=self.verbose)

    # -- plumbing ---------------------------------------------------------
    def chain_file(self) -> Path:
        return self.state_dir / "chain.jsonl"

    def entries(self) -> list[dict[str, Any]]:
        return hl.read_chain(self.chain_file())

    def autonomy(self) -> dict[str, str]:
        """Re-read every time. Consent is live state, not a startup snapshot."""
        return hl.load_autonomy()

    def _ctx(self, action_id: str = "") -> pb.ExecContext:
        return pb.ExecContext(runner=self.runner, guards=self.guards,
                              config=self.config, state_dir=self.state_dir,
                              action_id=action_id)

    def record(self, **fields: Any) -> dict[str, Any]:
        """Seal one entry onto the ledger. A dry run records nothing on disk."""
        entry = {"ts": time.time(), "iso": hl.now_iso(), **fields}
        if self.dry_run:
            entry["prev"] = "(dry-run)"
            entry["hash"] = "(dry-run)"
            if self.verbose:
                print(f"  would append to the audit chain: {entry.get('kind')} "
                      f"{entry.get('playbook', '')} {entry.get('target', '')}",
                      flush=True)
            return entry
        return hl.append_entry(entry, self.chain_file())

    def publish(self, severity: str, message: str, category: str = "heal") -> None:
        """Announce on the R.A.I.N. bus via the orionx-event CLI.

        Fire-and-forget subprocess, exactly as scanwatch and nucleotide do, so
        the engine never blocks on the bus and a missing CLI is not fatal.
        Source is always 'healing', which is also what match_event() refuses to
        act on — that is the loop break.
        """
        if self.dry_run:
            print(f"  would emit [{severity}] {message}", flush=True)
            return
        try:
            subprocess.Popen(
                ["orionx-event", "--severity", severity, "--source", hl.SELF_SOURCE,
                 "--category", category, message],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except OSError:
            pass

    def say(self, text: str) -> None:
        if self.verbose or self.dry_run:
            print(text, flush=True)

    # -- the decision path -------------------------------------------------
    def handle_event(self, event: dict[str, Any], now: float | None = None) -> str:
        """Process one bus event end to end. Returns a short outcome token."""
        now = time.time() if now is None else now
        proposal = hl.match_event(event)
        if proposal is None:
            return "no-match"
        return self.consider(proposal.playbook, proposal.target, proposal.reason,
                             now=now)

    def consider(self, playbook: str, target: str, reason: str,
                 now: float | None = None) -> str:
        """Guards, then consent, then rate limit, then act. In that order."""
        now = time.time() if now is None else now

        # 1. Guards. Unconditional; no level lifts them (DEC-PHASE12-023a).
        allowed, why_not = hl.check_target(playbook, target, self.guards)
        if not allowed:
            self.record(kind=hl.KIND_REFUSED, playbook=playbook, target=target,
                        reason=why_not)
            self.publish("warning",
                         f"refused {playbook} on {target or 'this host'}: {why_not}")
            self.say(f"REFUSED {playbook} {target}: {why_not}")
            return "refused"

        # 2. Consent, re-read from the single authority.
        level = hl.level_for(self.autonomy(), playbook)
        disp = hl.disposition(level)

        if disp == hl.ACT_SKIP:
            self.say(f"off: {playbook} not pre-approved (level={level})")
            return "off"

        if disp == hl.ACT_PROPOSE:
            self.record(kind=hl.KIND_PROPOSED, playbook=playbook, target=target,
                        level=level, reason=reason)
            self.publish("notice",
                         f"suggestion: {playbook} on {target or 'this host'} — "
                         f"{reason}. Run: orionx-heal run {playbook}"
                         + (f" --target {target}" if target else ""))
            self.say(f"PROPOSE {playbook} {target}")
            return "proposed"

        # 3. Debounce / storm guard — only for things that will actually run.
        ok, limit_why = self.limiter.allow(playbook, target, now)
        if not ok:
            self.record(kind=hl.KIND_REFUSED, playbook=playbook, target=target,
                        level=level, reason=limit_why)
            self.say(f"RATE-LIMITED {playbook} {target}: {limit_why}")
            return "rate-limited"

        if disp == hl.ACT_AWAIT:
            action_id = hl.new_action_id(playbook, target, now)
            self.limiter.record(playbook, target, now)
            self.record(kind=hl.KIND_PENDING, action_id=action_id,
                        playbook=playbook, target=target, level=level,
                        reason=reason, expires_at=0.0, undo={})
            self.publish("warning",
                         f"awaiting your confirmation: {playbook} on "
                         f"{target or 'this host'} — {reason}. "
                         f"Run: orionx-heal confirm {action_id}")
            self.say(f"PENDING {action_id} {playbook} {target}")
            return "pending"

        self.limiter.record(playbook, target, now)
        return "applied" if self.execute(playbook, target, level, reason,
                                         now=now) else "failed"

    # -- effects -----------------------------------------------------------
    def execute(self, playbook: str, target: str, level: str, reason: str,
                now: float | None = None, action_id: str = "") -> bool:
        """Run a playbook that has already cleared guards and consent."""
        now = time.time() if now is None else now
        action_id = action_id or hl.new_action_id(playbook, target, now)
        ctx = self._ctx(action_id)
        result = pb.apply_playbook(playbook, target, ctx)
        if not result.ok:
            self.record(kind=hl.KIND_FAILED, action_id=action_id,
                        playbook=playbook, target=target, level=level,
                        reason=result.detail)
            self.publish("warning",
                         f"{playbook} on {target or 'this host'} FAILED: {result.detail}")
            self.say(f"FAILED {playbook} {target}: {result.detail}")
            return False

        ttl = hl.ttl_for(playbook, self.config)
        expires_at = (now + ttl) if ttl else 0.0
        self.record(kind=hl.KIND_APPLIED, action_id=action_id, playbook=playbook,
                    target=target, level=level, reason=reason,
                    detail=result.detail, undo=result.undo,
                    expires_at=expires_at, ttl=ttl)
        when = (f"auto-reverts in {ttl / 60:.0f}m" if ttl
                else "no rollback timer — undo manually")
        self.publish("critical" if playbook in ("isolate_node", "rotate_mesh_keys")
                     else "warning",
                     f"{playbook} applied to {target or 'this host'} "
                     f"[{action_id}]: {result.detail} ({when})")
        self.say(f"APPLIED {action_id} {playbook} {target}: {result.detail}")
        return True

    def revert(self, action: hl.ActionState, kind: str = hl.KIND_REVERTED,
               note: str = "") -> bool:
        ctx = self._ctx(action.action_id)
        result = pb.undo_playbook(action.playbook, action.undo, ctx)
        self.record(kind=kind if result.ok else hl.KIND_FAILED,
                    action_id=action.action_id, playbook=action.playbook,
                    target=action.target, reason=note or result.detail,
                    detail=result.detail, reverted_ok=result.ok)
        self.publish("notice" if result.ok else "warning",
                     f"{action.playbook} on {action.target or 'this host'} "
                     f"[{action.action_id}] "
                     f"{'reverted' if result.ok else 'REVERT FAILED'}: {result.detail}")
        self.say(f"{'REVERTED' if result.ok else 'REVERT FAILED'} "
                 f"{action.action_id}: {result.detail}")
        return result.ok

    # -- operator paths ----------------------------------------------------
    def confirm(self, action_id: str, now: float | None = None) -> tuple[bool, str]:
        """The explicit acknowledgement path for confirm-level actions."""
        now = time.time() if now is None else now
        state = hl.replay(self.entries())
        action = state.get(action_id)
        if action is None:
            return False, f"no action {action_id} in the ledger"
        if action.status != "pending":
            return False, f"action {action_id} is {action.status}, not pending"
        if (now - action.applied_at) > CONFIRM_GRACE_SECONDS:
            self.record(kind=hl.KIND_DENIED, action_id=action_id,
                        playbook=action.playbook, target=action.target,
                        reason="confirmation window lapsed")
            return False, (f"action {action_id} lapsed after "
                           f"{CONFIRM_GRACE_SECONDS / 60:.0f} minutes; raise it again")
        # Guards are re-checked at confirmation time: the operator's address may
        # have changed between the proposal and the answer.
        allowed, why_not = hl.check_target(action.playbook, action.target, self.guards)
        if not allowed:
            self.record(kind=hl.KIND_REFUSED, action_id=action_id,
                        playbook=action.playbook, target=action.target,
                        reason=why_not)
            return False, f"refused at confirmation: {why_not}"
        ok = self.execute(action.playbook, action.target, "confirm",
                          "operator confirmed", now=now, action_id=action_id)
        return ok, ("applied" if ok else "playbook failed; see the ledger")

    def deny(self, action_id: str) -> tuple[bool, str]:
        state = hl.replay(self.entries())
        action = state.get(action_id)
        if action is None or action.status != "pending":
            return False, f"no pending action {action_id}"
        self.record(kind=hl.KIND_DENIED, action_id=action_id,
                    playbook=action.playbook, target=action.target,
                    reason="operator declined")
        self.publish("info", f"operator declined {action.playbook} on "
                             f"{action.target or 'this host'} [{action_id}]")
        return True, "declined"

    def undo(self, action_id: str) -> tuple[bool, str]:
        state = hl.replay(self.entries())
        action = state.get(action_id)
        if action is None:
            return False, f"no action {action_id} in the ledger"
        if action.status != "active":
            return False, f"action {action_id} is {action.status}; nothing to undo"
        ok = self.revert(action, note="operator undo")
        return ok, ("reverted" if ok else "undo failed; see the ledger")

    def renew(self, action_id: str, ttl: float | None = None,
              now: float | None = None) -> tuple[bool, str]:
        now = time.time() if now is None else now
        state = hl.replay(self.entries())
        action = state.get(action_id)
        if action is None or action.status != "active":
            return False, f"no active action {action_id}"
        extra = hl.ttl_for(action.playbook, self.config) if ttl is None else max(0.0, ttl)
        expires_at = (now + extra) if extra else 0.0
        self.record(kind=hl.KIND_RENEWED, action_id=action_id,
                    playbook=action.playbook, target=action.target,
                    expires_at=expires_at, reason="operator renewed")
        return True, ("renewed indefinitely (no timer)" if not extra
                      else f"renewed for {extra / 60:.0f} minutes")

    # -- periodic ----------------------------------------------------------
    def sweep(self, now: float | None = None) -> int:
        """Revert everything whose rollback timer has elapsed; lapse stale
        proposals. Called on a timer AND at daemon start, so an action does not
        outlive its TTL merely because the daemon was restarted."""
        now = time.time() if now is None else now
        entries = self.entries()
        n = 0
        for action in hl.due_for_rollback(entries, now):
            self.revert(action, kind=hl.KIND_EXPIRED, note="rollback timer elapsed")
            n += 1
        for stale in hl.expired_pending(entries, now, CONFIRM_GRACE_SECONDS):
            self.record(kind=hl.KIND_DENIED, action_id=stale.action_id,
                        playbook=stale.playbook, target=stale.target,
                        reason="confirmation window lapsed without an answer")
            n += 1
        return n

    def reconcile(self) -> int:
        """Re-assert active blocks against the live kernel ruleset.

        /etc/nftables.conf begins with `flush ruleset`, so reloading the
        firewall silently deletes the healing table and every block in it. The
        ledger, not the kernel, is the record of what should be in force, so on
        start we push the ledger's view back into nftables. `nft add element` is
        idempotent, making this safe to run whether or not anything was lost.
        """
        actions = [a for a in hl.active_actions(self.entries())
                   if a.playbook == "block_ip"]
        if not actions:
            return 0
        ctx = self._ctx()
        pb.ensure_block_infrastructure(ctx)
        for a in actions:
            setname = str(a.undo.get("set", pb.BLOCK_SET_V4))
            self.runner.run(["nft", "add", "element", "inet", pb.HEAL_TABLE,
                             setname, "{ " + a.target + " }"])
        self.say(f"reconciled {len(actions)} active block(s) into nftables")
        return len(actions)
