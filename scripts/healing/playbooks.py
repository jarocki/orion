#!/usr/bin/env python3
"""playbooks — the six auto-healing actions, each with a real undo.

healing_lib.py decides *whether* something may happen. This module is the only
place where it actually does. Every effect goes through an injected `Runner`,
so the whole file is exercisable in CI with no root, no nftables and no mesh:
the tests substitute a recording runner and assert on the argv vectors.

Two rules hold throughout:

  * An action is not applied until its undo is known. `apply()` returns the
    undo record alongside the result; the caller seals both into the audit
    chain in one entry. There is no path that changes the system and then works
    out how to change it back.

  * argv vectors are fixed and parameters are substituted as separate list
    elements — never a shell string. Targets originate on the event bus, which
    ultimately means they originate with an attacker.

@decision DEC-PHASE12-023
@title Playbook effects behind an injectable runner; undo computed before apply
@status accepted
@rationale See healing_lib.py. The specific choice worth recording here is the
  nftables strategy: blocks go into a SEPARATE table, `inet orionx_healing`,
  carrying its own named sets and an input chain at priority -10 (ahead of
  `inet orionx_firewall` at priority 0). The alternative — editing
  /etc/nftables.conf — was rejected because that file is the reviewed,
  shipped baseline (DEC-SEC-001) and rewriting it at runtime from a daemon
  reacting to network input makes the baseline untrustworthy and every block a
  whole-ruleset reload. A named set makes a block one `add element` and an
  unblock one `delete element`, with no effect on the baseline at all.

  The cost is honest and worth stating: `nftables.conf` begins with `flush
  ruleset`, so an operator reloading the firewall drops our table too. That is
  why the daemon reconciles on start and re-asserts every active, unexpired
  block from the ledger rather than trusting the kernel to be the record.
"""

from __future__ import annotations

import grp
import hashlib
import json
import os
import pwd
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import healing_lib as hl

# nftables objects the engine owns outright. Nothing else writes them.
HEAL_TABLE = "orionx_healing"
BLOCK_SET_V4 = "blocked"
BLOCK_SET_V6 = "blocked6"
ISOLATE_TABLE = "orionx_isolate"

#: Where a Synapse admin token may be placed by the operator (mode 0600).
MATRIX_TOKEN_FILE = Path(
    os.environ.get("ORIONX_MATRIX_TOKEN_FILE", "/etc/orionx/matrix-admin-token")
)
MATRIX_BASE_URL = os.environ.get("ORIONX_MATRIX_URL", "http://127.0.0.1:8008")

#: WireGuard mesh key locations — mirror mesh-lib.sh (DEC-MESH-004).
MESH_IFACE = os.environ.get("MESH_IFACE", "wg0")
MESH_PRIVATE_KEY = Path(os.environ.get("MESH_PRIVATE_KEY",
                                       "/etc/wireguard/mesh-private.key"))


# ---------------------------------------------------------------------------
# Execution context
# ---------------------------------------------------------------------------
@dataclass
class Result:
    ok: bool
    detail: str
    undo: dict[str, Any] = field(default_factory=dict)


class Runner:
    """Every side effect funnels through here. Honours --dry-run globally.

    `dry_run` is enforced at this single choke point rather than scattered
    through the playbooks, so there is no playbook that can forget it. A
    dry run records what it would have done and touches nothing: no command,
    no file move, no HTTP request, and (in the engine) no chain write.
    """

    def __init__(self, dry_run: bool = False, verbose: bool = False) -> None:
        self.dry_run = bool(dry_run)
        self.verbose = bool(verbose)
        self.commands: list[list[str]] = []
        self.requests: list[tuple[str, str]] = []
        self.fs_ops: list[tuple[str, str, str]] = []

    # -- process -----------------------------------------------------------
    def run(self, argv: list[str], check: bool = False) -> tuple[int, str, str]:
        self.commands.append(list(argv))
        if self.dry_run:
            if self.verbose:
                print("  would run:", " ".join(argv), flush=True)
            return 0, "", ""
        try:
            proc = subprocess.run(argv, capture_output=True, text=True,
                                  timeout=30, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            return 127, "", str(exc)
        if check and proc.returncode != 0:
            return proc.returncode, proc.stdout, proc.stderr
        return proc.returncode, proc.stdout, proc.stderr

    # -- filesystem --------------------------------------------------------
    def move(self, src: str, dst: str) -> tuple[bool, str]:
        self.fs_ops.append(("move", src, dst))
        if self.dry_run:
            if self.verbose:
                print(f"  would move: {src} -> {dst}", flush=True)
            return True, ""
        try:
            Path(dst).parent.mkdir(parents=True, exist_ok=True)
            shutil.move(src, dst)
            return True, ""
        except (OSError, shutil.Error) as exc:
            return False, str(exc)

    def chmod(self, path: str, mode: int) -> bool:
        self.fs_ops.append(("chmod", path, oct(mode)))
        if self.dry_run:
            return True
        try:
            os.chmod(path, mode)
            return True
        except OSError:
            return False

    def chown(self, path: str, uid: int, gid: int) -> bool:
        self.fs_ops.append(("chown", path, f"{uid}:{gid}"))
        if self.dry_run:
            return True
        try:
            os.chown(path, uid, gid)
            return True
        except (OSError, AttributeError):
            return False

    def write_text(self, path: str, text: str, mode: int = 0o600) -> bool:
        self.fs_ops.append(("write", path, f"{len(text)}B"))
        if self.dry_run:
            return True
        try:
            p = Path(path)
            p.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
            try:
                os.write(fd, text.encode("utf-8"))
            finally:
                os.close(fd)
            return True
        except OSError:
            return False

    def copy(self, src: str, dst: str) -> tuple[bool, str]:
        self.fs_ops.append(("copy", src, dst))
        if self.dry_run:
            return True, ""
        try:
            Path(dst).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            return True, ""
        except (OSError, shutil.Error) as exc:
            return False, str(exc)

    # -- http (Synapse admin API) -----------------------------------------
    def http(self, method: str, url: str, token: str,
             body: dict[str, Any] | None = None) -> tuple[int, str]:
        self.requests.append((method, url))
        if self.dry_run:
            if self.verbose:
                print(f"  would {method} {url}", flush=True)
            return 200, "{}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
                return resp.status, resp.read().decode("utf-8", "replace")[:2000]
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode("utf-8", "replace")[:2000]
        except (urllib.error.URLError, OSError, ValueError) as exc:
            return 0, str(exc)


@dataclass
class ExecContext:
    runner: Runner
    guards: hl.GuardContext
    config: dict[str, Any] = field(default_factory=hl.default_config)
    state_dir: Path = field(default_factory=lambda: hl.STATE_DIR)
    action_id: str = ""

    def quarantine_root(self) -> Path:
        return Path(self.state_dir) / "quarantine"

    def backup_root(self) -> Path:
        return Path(self.state_dir) / "backups"


# ---------------------------------------------------------------------------
# block_ip
# ---------------------------------------------------------------------------
def _nft_family(target: str) -> tuple[str, str]:
    """('ip'|'ip6', set-name) for an address. Caller has already validated it."""
    import ipaddress
    addr = ipaddress.ip_address(target)
    return ("ip6", BLOCK_SET_V6) if addr.version == 6 else ("ip", BLOCK_SET_V4)


def ensure_block_infrastructure(ctx: ExecContext) -> list[list[str]]:
    """Create the engine's own nft table/sets/chain. Idempotent by construction.

    Every command is `nft add ...`, which nftables treats as create-or-noop for
    tables, sets and chains. Re-running costs nothing, which matters because the
    daemon re-asserts this on start and before each block — the shipped
    nftables.conf opens with `flush ruleset`, so our table can vanish under us
    without warning when the operator reloads the firewall.
    """
    cmds = [
        ["nft", "add", "table", "inet", HEAL_TABLE],
        ["nft", "add", "set", "inet", HEAL_TABLE, BLOCK_SET_V4,
         "{ type ipv4_addr; flags interval; comment \"orionx auto-healing\"; }"],
        ["nft", "add", "set", "inet", HEAL_TABLE, BLOCK_SET_V6,
         "{ type ipv6_addr; flags interval; comment \"orionx auto-healing\"; }"],
        # priority -10: ahead of inet orionx_firewall (priority 0), so a block
        # takes effect even if the baseline would have accepted the traffic.
        ["nft", "add", "chain", "inet", HEAL_TABLE, "input",
         "{ type filter hook input priority -10; policy accept; }"],
        ["nft", "add", "rule", "inet", HEAL_TABLE, "input",
         "ip", "saddr", f"@{BLOCK_SET_V4}",
         "log", "prefix", "[ORIONX-HEAL-DROP] ", "drop"],
        ["nft", "add", "rule", "inet", HEAL_TABLE, "input",
         "ip6", "saddr", f"@{BLOCK_SET_V6}",
         "log", "prefix", "[ORIONX-HEAL-DROP] ", "drop"],
    ]
    for cmd in cmds:
        ctx.runner.run(cmd)
    return cmds


def apply_block_ip(target: str, ctx: ExecContext) -> Result:
    fam, setname = _nft_family(target)
    ensure_block_infrastructure(ctx)
    rc, _out, err = ctx.runner.run(
        ["nft", "add", "element", "inet", HEAL_TABLE, setname, "{ " + target + " }"]
    )
    undo = {"kind": "nft_del_element", "table": HEAL_TABLE, "set": setname,
            "element": target, "family": fam}
    if rc != 0:
        return Result(False, f"nft add element failed: {err.strip() or rc}", undo)
    return Result(True, f"{target} added to inet {HEAL_TABLE} @{setname}", undo)


def undo_block_ip(undo: dict[str, Any], ctx: ExecContext) -> Result:
    setname = str(undo.get("set", BLOCK_SET_V4))
    element = str(undo.get("element", ""))
    if not element:
        return Result(False, "undo record has no element")
    rc, _out, err = ctx.runner.run(
        ["nft", "delete", "element", "inet", HEAL_TABLE, setname,
         "{ " + element + " }"]
    )
    # A missing element is success: the desired end state (not blocked) holds.
    if rc != 0 and "No such file" not in err and "does not exist" not in err:
        return Result(False, f"nft delete element failed: {err.strip() or rc}")
    return Result(True, f"{element} removed from @{setname}")


# ---------------------------------------------------------------------------
# kill_process
# ---------------------------------------------------------------------------
def _unit_for_pid(pid: str, ctx: ExecContext) -> str:
    """Resolve a PID to its systemd unit via the cgroup, or '' if none."""
    try:
        cg = Path(f"/proc/{pid}/cgroup").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    for line in cg.splitlines():
        if ".service" in line:
            frag = line.rsplit("/", 1)[-1].strip()
            if frag.endswith(".service"):
                return frag
    return ""


def _cmdline_for_pid(pid: str) -> str:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return ""
    return " ".join(raw.decode("utf-8", "replace").split("\x00")).strip()[:300]


def apply_kill_process(target: str, ctx: ExecContext) -> Result:
    """Stop a process. Reversible exactly as far as honesty allows.

    When the PID belongs to a systemd service we stop the unit, because killing
    the PID of a Restart=always service accomplishes nothing but a respawn.
    That is genuinely reversible: undo starts the unit again. A bare PID is
    not — a killed process cannot be recreated, and re-executing a recorded
    command line as root on the say-so of a bus event would be a far worse bug
    than an irreversible action. The undo record says which case it was, so the
    operator is never shown a rollback that cannot happen.
    """
    unit = _unit_for_pid(target, ctx)
    cmdline = _cmdline_for_pid(target)
    if unit:
        rc, _out, err = ctx.runner.run(["systemctl", "stop", unit])
        undo = {"kind": "systemctl_start", "unit": unit, "pid": target,
                "cmdline": cmdline, "reversible": True}
        if rc != 0:
            return Result(False, f"systemctl stop {unit} failed: {err.strip() or rc}", undo)
        return Result(True, f"stopped unit {unit} (owned PID {target})", undo)

    undo = {"kind": "irreversible_kill", "pid": target, "cmdline": cmdline,
            "reversible": False}
    rc, _out, err = ctx.runner.run(["kill", "-TERM", target])
    if rc != 0:
        return Result(False, f"SIGTERM to {target} failed: {err.strip() or rc}", undo)
    # Grace, then SIGKILL if still alive. Skipped on a dry run (no sleep, no
    # kill) because dry-run must be free of every observable effect.
    if not ctx.runner.dry_run:
        for _ in range(20):
            if not Path(f"/proc/{target}").exists():
                break
            time.sleep(0.1)
        if Path(f"/proc/{target}").exists():
            ctx.runner.run(["kill", "-KILL", target])
    return Result(True, f"terminated PID {target} ({cmdline[:60] or 'unknown'})", undo)


def undo_kill_process(undo: dict[str, Any], ctx: ExecContext) -> Result:
    if undo.get("kind") == "systemctl_start" and undo.get("unit"):
        unit = str(undo["unit"])
        rc, _out, err = ctx.runner.run(["systemctl", "start", unit])
        if rc != 0:
            return Result(False, f"systemctl start {unit} failed: {err.strip() or rc}")
        return Result(True, f"restarted unit {unit}")
    return Result(
        False,
        f"PID {undo.get('pid', '?')} cannot be resurrected — kill_process is "
        "one-way for a process with no systemd unit (recorded cmdline: "
        f"{str(undo.get('cmdline', ''))[:80] or 'unknown'})",
    )


# ---------------------------------------------------------------------------
# quarantine_file
# ---------------------------------------------------------------------------
def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    try:
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 16), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()


def apply_quarantine_file(target: str, ctx: ExecContext) -> Result:
    """Move a file into the sealed vault, preserving everything undo needs."""
    src = Path(target)
    if not ctx.runner.dry_run and not src.exists():
        return Result(False, f"{target} does not exist")
    try:
        st = src.lstat()
        mode, uid, gid = st.st_mode & 0o7777, st.st_uid, st.st_gid
    except OSError:
        mode, uid, gid = 0o600, 0, 0
    digest = _sha256_file(src) if not ctx.runner.dry_run else ""
    vault = ctx.quarantine_root() / (ctx.action_id or "manual")
    dst = vault / src.name
    undo = {"kind": "restore_file", "original": str(src), "vault": str(dst),
            "mode": mode, "uid": uid, "gid": gid, "sha256": digest}

    ok, err = ctx.runner.move(str(src), str(dst))
    if not ok:
        return Result(False, f"quarantine move failed: {err}", undo)
    # 0000 in a root-owned vault: present for forensics, executable by nobody.
    ctx.runner.chmod(str(dst), 0o000)
    ctx.runner.write_text(str(dst) + ".meta.json",
                          json.dumps(undo, indent=2, sort_keys=True), 0o600)
    return Result(True, f"{src} sealed in {vault} (sha256 {digest[:16] or 'n/a'})", undo)


def undo_quarantine_file(undo: dict[str, Any], ctx: ExecContext) -> Result:
    vault = str(undo.get("vault", ""))
    original = str(undo.get("original", ""))
    if not vault or not original:
        return Result(False, "undo record is missing the vault or original path")
    if not ctx.runner.dry_run and not Path(vault).exists():
        return Result(False, f"quarantined copy is gone: {vault}")
    ctx.runner.chmod(vault, int(undo.get("mode", 0o600)) or 0o600)
    ok, err = ctx.runner.move(vault, original)
    if not ok:
        return Result(False, f"restore failed: {err}")
    ctx.runner.chmod(original, int(undo.get("mode", 0o600)) or 0o600)
    try:
        ctx.runner.chown(original, int(undo.get("uid", 0)), int(undo.get("gid", 0)))
    except (TypeError, ValueError):
        pass
    if not ctx.runner.dry_run:
        try:
            Path(vault + ".meta.json").unlink()
        except OSError:
            pass
    return Result(True, f"{original} restored from quarantine")


def owner_names(uid: int, gid: int) -> str:
    try:
        return f"{pwd.getpwuid(uid).pw_name}:{grp.getgrgid(gid).gr_name}"
    except (KeyError, OSError, OverflowError):
        return f"{uid}:{gid}"


# ---------------------------------------------------------------------------
# isolate_node
# ---------------------------------------------------------------------------
def apply_isolate_node(target: str, ctx: ExecContext) -> Result:
    """Cut the host off the network — except the operator and loopback.

    A containment action that also strands the human trying to contain the
    incident is not containment. The isolation table therefore keeps loopback,
    established flows, and every address the operator is currently connected
    from. Everything else stops in both directions. Implemented as a whole
    table at priority -20 so undo is a single `nft delete table`, with no
    possibility of half-removing the isolation.
    """
    r = ctx.runner
    r.run(["nft", "add", "table", "inet", ISOLATE_TABLE])
    for hook, prio in (("input", "-20"), ("output", "-20"), ("forward", "-20")):
        r.run(["nft", "add", "chain", "inet", ISOLATE_TABLE, hook,
               "{ type filter hook " + hook + " priority " + prio + "; policy drop; }"])
    for hook in ("input", "output"):
        r.run(["nft", "add", "rule", "inet", ISOLATE_TABLE, hook, "iif", "lo", "accept"]
              if hook == "input" else
              ["nft", "add", "rule", "inet", ISOLATE_TABLE, hook, "oif", "lo", "accept"])
        r.run(["nft", "add", "rule", "inet", ISOLATE_TABLE, hook,
               "ct", "state", "established,related", "accept"])
    kept = sorted(a for a in ctx.guards.operator_addrs if a)
    for addr in kept:
        ver = "ip6" if ":" in addr else "ip"
        r.run(["nft", "add", "rule", "inet", ISOLATE_TABLE, "input",
               ver, "saddr", addr, "accept"])
        r.run(["nft", "add", "rule", "inet", ISOLATE_TABLE, "output",
               ver, "daddr", addr, "accept"])
    undo = {"kind": "nft_del_table", "table": ISOLATE_TABLE,
            "kept_operator_addrs": kept}
    note = f"operator addresses kept reachable: {', '.join(kept)}" if kept \
        else "WARNING: no live operator address detected; only loopback kept"
    return Result(True, f"host isolated via inet {ISOLATE_TABLE} — {note}", undo)


def undo_isolate_node(undo: dict[str, Any], ctx: ExecContext) -> Result:
    table = str(undo.get("table", ISOLATE_TABLE))
    rc, _out, err = ctx.runner.run(["nft", "delete", "table", "inet", table])
    if rc != 0 and "No such file" not in err:
        return Result(False, f"nft delete table {table} failed: {err.strip() or rc}")
    return Result(True, f"isolation table {table} removed; connectivity restored")


# ---------------------------------------------------------------------------
# rotate_mesh_keys
# ---------------------------------------------------------------------------
def apply_rotate_mesh_keys(target: str, ctx: ExecContext) -> Result:
    """Back up the mesh private key, generate a new one, install it live.

    `wg set <iface> private-key <file>` is used rather than wg-quick down/up,
    for the same reason mesh-lib.sh does (DEC-MESH-005): tearing the interface
    down costs a two-minute handshake lockout across the whole fleet, which
    during an incident is exactly the wrong thing to inflict on the operator.
    """
    r = ctx.runner
    key_path = MESH_PRIVATE_KEY
    backup = ctx.backup_root() / (ctx.action_id or "manual") / "mesh-private.key"
    if not r.dry_run and not key_path.exists():
        return Result(False, f"no mesh private key at {key_path} — is the mesh joined?")
    ok, err = r.copy(str(key_path), str(backup))
    if not ok:
        return Result(False, f"could not back up the mesh key: {err}")
    r.chmod(str(backup), 0o600)

    rc, newkey, err = r.run(["wg", "genkey"])
    if rc != 0 or (not r.dry_run and not newkey.strip()):
        return Result(False, f"wg genkey failed: {err.strip() or rc}")
    if not r.write_text(str(key_path), newkey.strip() + "\n", 0o600):
        return Result(False, f"could not write the new key to {key_path}")
    rc, _out, err = r.run(["wg", "set", MESH_IFACE, "private-key", str(key_path)])
    undo = {"kind": "restore_mesh_key", "backup": str(backup),
            "key_path": str(key_path), "iface": MESH_IFACE}
    if rc != 0:
        return Result(False, f"wg set {MESH_IFACE} failed: {err.strip() or rc}", undo)
    rc, pub, _e = r.run(["wg", "show", MESH_IFACE, "public-key"])
    return Result(True,
                  f"mesh key rotated on {MESH_IFACE}; new public key "
                  f"{pub.strip() or '(unread)'} — peers must be re-authorised",
                  undo)


def undo_rotate_mesh_keys(undo: dict[str, Any], ctx: ExecContext) -> Result:
    backup = str(undo.get("backup", ""))
    key_path = str(undo.get("key_path", MESH_PRIVATE_KEY))
    iface = str(undo.get("iface", MESH_IFACE))
    if not backup:
        return Result(False, "undo record has no backup path")
    if not ctx.runner.dry_run and not Path(backup).exists():
        return Result(False, f"key backup is gone: {backup}")
    ok, err = ctx.runner.copy(backup, key_path)
    if not ok:
        return Result(False, f"restoring the key failed: {err}")
    ctx.runner.chmod(key_path, 0o600)
    rc, _out, err = ctx.runner.run(["wg", "set", iface, "private-key", key_path])
    if rc != 0:
        return Result(False, f"wg set {iface} failed: {err.strip() or rc}")
    return Result(True, f"previous mesh key restored on {iface}")


# ---------------------------------------------------------------------------
# revoke_matrix_session
# ---------------------------------------------------------------------------
def _matrix_token() -> str:
    tok = os.environ.get("ORIONX_MATRIX_ADMIN_TOKEN", "").strip()
    if tok:
        return tok
    try:
        return MATRIX_TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def apply_revoke_matrix_session(target: str, ctx: ExecContext) -> Result:
    """Revoke a Matrix user's sessions and lock the account (Synapse admin API).

    Two effects, deliberately. Deleting the devices invalidates their access
    tokens, which is the revocation itself and is inherently one-way — you
    cannot un-log-out a session. Locking the account is the reversible half:
    it stops the attacker logging straight back in with stolen credentials, and
    undo unlocks it. Deactivation is NOT used: it is destructive to the account
    and Synapse does not cleanly reverse it.
    """
    token = _matrix_token()
    if not token:
        return Result(False,
                      "no Synapse admin token — place one (mode 0600) at "
                      f"{MATRIX_TOKEN_FILE} or set ORIONX_MATRIX_ADMIN_TOKEN")
    base = MATRIX_BASE_URL.rstrip("/")
    user = target
    quoted = urllib.request.quote(user, safe="")
    status, body = ctx.runner.http(
        "POST", f"{base}/_synapse/admin/v2/users/{quoted}/delete_devices",
        token, {"devices": []})
    if status not in (200, 204):
        # Older Synapse: fall back to enumerating and deleting devices.
        st2, listing = ctx.runner.http(
            "GET", f"{base}/_synapse/admin/v2/users/{quoted}/devices", token)
        devices: list[str] = []
        if st2 == 200:
            try:
                devices = [d.get("device_id", "") for d
                           in (json.loads(listing).get("devices") or [])]
            except (ValueError, AttributeError, TypeError):
                devices = []
        for dev in [d for d in devices if d]:
            ctx.runner.http("DELETE",
                            f"{base}/_synapse/admin/v2/users/{quoted}/devices/{dev}",
                            token)
        status = st2

    lock_status, lock_body = ctx.runner.http(
        "PUT", f"{base}/_synapse/admin/v2/users/{quoted}", token, {"locked": True})
    undo = {"kind": "matrix_unlock", "user": user, "base": base,
            "locked": lock_status in (200, 201)}
    if lock_status not in (200, 201):
        return Result(
            status in (200, 204),
            f"sessions revoked for {user}, but locking the account failed "
            f"(HTTP {lock_status}: {lock_body[:120]}) — this Synapse may predate "
            "the 'locked' field; re-login is NOT prevented",
            undo)
    return Result(True, f"{user}: devices revoked and account locked", undo)


def undo_revoke_matrix_session(undo: dict[str, Any], ctx: ExecContext) -> Result:
    token = _matrix_token()
    if not token:
        return Result(False, "no Synapse admin token available to unlock")
    if not undo.get("locked"):
        return Result(False,
                      f"nothing to reverse for {undo.get('user', '?')}: the account "
                      "was never locked, and revoked devices cannot be recreated "
                      "(the user simply signs in again)")
    base = str(undo.get("base", MATRIX_BASE_URL)).rstrip("/")
    quoted = urllib.request.quote(str(undo.get("user", "")), safe="")
    status, body = ctx.runner.http("PUT", f"{base}/_synapse/admin/v2/users/{quoted}",
                                   token, {"locked": False})
    if status not in (200, 201):
        return Result(False, f"unlock failed (HTTP {status}: {body[:120]})")
    return Result(True, f"{undo.get('user')} unlocked; the user can sign in again")


# ---------------------------------------------------------------------------
# Static dispatch table. Direct function references — no getattr, no import
# by name, nothing derived from an event field.
# ---------------------------------------------------------------------------
APPLY = {
    "block_ip": apply_block_ip,
    "kill_process": apply_kill_process,
    "quarantine_file": apply_quarantine_file,
    "isolate_node": apply_isolate_node,
    "rotate_mesh_keys": apply_rotate_mesh_keys,
    "revoke_matrix_session": apply_revoke_matrix_session,
}

UNDO = {
    "block_ip": undo_block_ip,
    "kill_process": undo_kill_process,
    "quarantine_file": undo_quarantine_file,
    "isolate_node": undo_isolate_node,
    "rotate_mesh_keys": undo_rotate_mesh_keys,
    "revoke_matrix_session": undo_revoke_matrix_session,
}

# The registry and the implementations must not drift apart: a playbook the
# operator can pre-approve but that nothing implements is exactly the gap this
# work exists to close. Checked at import, so a mismatch fails the build.
assert set(APPLY) == set(hl.PLAYBOOK_NAMES), "APPLY does not match the registry"
assert set(UNDO) == set(hl.PLAYBOOK_NAMES), "UNDO does not match the registry"


def apply_playbook(playbook: str, target: str, ctx: ExecContext) -> Result:
    fn = APPLY.get(playbook)
    if fn is None:
        return Result(False, f"unknown playbook {playbook!r}")
    try:
        return fn(target, ctx)
    except Exception as exc:  # noqa: BLE001 - a playbook must never kill the daemon
        return Result(False, f"{playbook} raised {type(exc).__name__}: {exc}")


def undo_playbook(playbook: str, undo: dict[str, Any], ctx: ExecContext) -> Result:
    fn = UNDO.get(playbook)
    if fn is None:
        return Result(False, f"unknown playbook {playbook!r}")
    try:
        return fn(undo, ctx)
    except Exception as exc:  # noqa: BLE001
        return Result(False, f"{playbook} undo raised {type(exc).__name__}: {exc}")
