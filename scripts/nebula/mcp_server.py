"""
nebula MCP tool server (W10-3 working core).

A local, stdlib-only Model Context Protocol server (JSON-RPC 2.0 over stdio) that
exposes a curated set of Orion-X forensic/IR tools to the on-device Nebula model
(or any MCP client). Each tool has a semantic description, a validated argument
schema, and is executed as a plain argv subprocess (never a shell) with a
timeout. Every call is written to the audit log at /var/log/orionx/nebula-mcp.log.

Protocol methods implemented:
    initialize          -> server capabilities
    tools/list          -> the registered tools + JSON schemas
    tools/call          -> run one tool, return its output

Curated tools (read/analysis-first; "active" classes are flagged and default to
requiring explicit invocation):
    nebula_status, systemctl_status, list_connections,
    pcap_analyze, artifact_analyze, tshark_summary, wg_show

SANDBOX STATUS: the DEC-007 confinement is now enforced (DEC-PHASE12-025).
The server runs as the dedicated `nebula-mcp` system user under
nebula-mcp.service with PrivateNetwork=yes, ProtectSystem=strict and the
AppArmor profile `nebula-mcp` (/etc/apparmor.d/usr.bin.nebula-mcp), which
permits AF_UNIX only — no IP networking of any kind. The transport under
confinement is a unix-domain socket (`--socket`); stdio remains for direct
`nebula tools --serve` use. Model-in-the-loop tool calling is
scripts/nebula/toolchat.py.

@decision DEC-PHASE12-025
@title W10-3 confinement: nebula-mcp runs unprivileged, networkless, and
  argument-validated; the model reaches it over a unix socket
@status accepted
@rationale Three properties had to hold at once and only one of them held.

  (1) NO OUTBOUND NETWORK. Every one of the twelve tools is local by
  construction — they read a pcap, a log, a systemd unit, a NetworkManager
  state. None needs an IP socket. So the profile does not repeat issue #53's
  mistake of allowing `network inet stream` and hoping a deny rule narrows it:
  it allows `network unix` and nothing else, and the unit sets
  PrivateNetwork=yes so even loopback to ollama's 127.0.0.1:11434 is absent
  from the namespace. That is a kernel guarantee, not a policy hope.

  (2) THE MODEL STILL HAS TO REACH THE TOOLS. JSON-RPC over stdio requires the
  client to be the parent process, and under PrivateNetwork a TCP port is not
  an option. A unix socket is: AF_UNIX is a filesystem object, entirely
  unaffected by network-namespace isolation, and it is the one address family
  the profile permits. The socket lives at /run/nebula-mcp/nebula-mcp.sock
  (RuntimeDirectory=, so systemd creates and reaps it). Direction matters: the
  *client* — `nebula ask`, running as the operator — talks to ollama on
  127.0.0.1 and to this server over the socket. The server never talks to
  ollama, so it never needs a network. Socket activation was rejected: ollama's
  EADDRINUSE restart loop (DEC-PHASE11-033) is the house lesson, and a
  self-bound socket is testable off-box, which sd_listen_fds is not.

  (3) CONFINEMENT MUST NOT MAKE TOOLS LIE. Two tools genuinely depend on what
  confinement removes: `wg show` needs the host network namespace, and
  `nebula status` probes ollama over loopback. Silently returning empty output
  or "Runtime: down" would be worse than refusing. Under NEBULA_MCP_CONFINED=1
  (set by the unit) `wg_show` is reported unavailable with the reason, and
  `nebula_status` runs with --offline so it reports the file-derived facts and
  says the daemon probe was skipped.

  Argument validation is tightened from "must be a scalar" to a typed check:
  path arguments must resolve inside an allowlist of evidence roots and may not
  begin with '-' (argv-option injection into tshark/roast is a real path even
  with no shell), token arguments must match a conservative character class.
  Rejecting shell metacharacters is belt-and-braces — there is still no shell —
  but it makes the invariant greppable and testable.

  Rejected: running the server as root with only AppArmor (a profile is one
  authority; a uid boundary and a namespace are two more, and DEC-007 asks for
  all three). Rejected: relaxing to IPAddressAllow=localhost so `nebula status`
  keeps its ollama probe (that hands a compromised tool server a lateral path
  to the model — the exact thing MASTER_PLAN's W10-3 row calls "no network at
  all").

@decision DEC-PHASE10-005
@title W10-3 Nebula MCP server: curated local tools over JSON-RPC/stdio
@status accepted
@rationale The MCP server is the single authority for which tools the local model
  may invoke and how. Tools are a static, reviewed registry (no dynamic exec);
  arguments are validated and passed as argv (no shell); every call is audited.
  Full sandbox hardening (DEC-007) is a follow-up; this lands the server + registry.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Iterable

# The DEC-007 audit record. Every call, refusal, timeout and result lands here.
# The path is overridable only so the test suite can assert the record exists
# without writing to /var/log on a build host; the unit does not set it, so on
# the image the path is the documented one.
_AUDIT_LOG = Path(os.environ.get("NEBULA_MCP_AUDIT_LOG", "/var/log/orionx/nebula-mcp.log"))
_SERVER_NAME = "orionx-nebula-mcp"
_SERVER_VERSION = "0.2.0"
_PROTOCOL_VERSION = "2024-11-05"

# Per-tool execution timeout (seconds). Analysis tools can be slow.
_DEFAULT_TIMEOUT = 120

# Default socket path when running confined under nebula-mcp.service. The
# directory is systemd's RuntimeDirectory=nebula-mcp, so it is created 0755 and
# removed when the unit stops; the socket itself is chmod'ed below.
DEFAULT_SOCKET = "/run/nebula-mcp/nebula-mcp.sock"

# Group allowed to connect to the socket. The operator (orionx-operator) is a
# member of `sudo` by live-config default, and no chroot-time step can add a
# user that does not exist until boot — so `sudo` is the group that actually
# describes "the human at the deck". Overridable for other deployments.
SOCKET_GROUP = os.environ.get("NEBULA_MCP_SOCKET_GROUP", "sudo")

# Cap on one JSON-RPC line. A client that never sends a newline must not be
# able to grow the server without bound.
_MAX_LINE_BYTES = 1 << 20

# ---------------------------------------------------------------------------
# Argument validation (DEC-PHASE12-025)
# ---------------------------------------------------------------------------

# Evidence roots a path argument may resolve inside. Everything the twelve
# tools legitimately read lives under one of these; the AppArmor profile and
# the unit's ProtectHome=tmpfs + BindReadOnlyPaths grant exactly the same set,
# so the check here and the kernel's agree rather than diverge.
_DEFAULT_READ_ROOTS = (
    "/opt/orionx/data",
    "/opt/orionx/nucleotide",
    "/var/lib/orionx",
    "/var/log/orionx",
    "/run/orionx",
    "/home/*/Analysis",
    "/srv/orionx",
)

# Characters that must never appear in an argument. There is no shell in this
# server — argv is passed straight to execve — so none of these is exploitable
# today. They are rejected anyway so that the invariant survives a future
# refactor that does reach for a shell, and so a test can prove it.
_SHELL_META = set(";|&$`<>(){}[]!*?\\\"'\n\r\t\v\f\0")

# Non-path scalars (unit names, actor labels). Deliberately narrow.
_TOKEN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@:+-]{0,63}$")


class ArgumentError(ValueError):
    """Raised when a tool argument fails validation."""


def read_roots() -> tuple[str, ...]:
    """The allowlist of roots a path argument may resolve inside.

    NEBULA_MCP_READ_ROOTS (colon-separated) overrides the default set; the
    tests use it, and an operator with evidence on an external mount can too.
    """
    override = os.environ.get("NEBULA_MCP_READ_ROOTS", "").strip()
    if override:
        return tuple(p for p in override.split(":") if p)
    return _DEFAULT_READ_ROOTS


def is_confined() -> bool:
    """True when running under nebula-mcp.service (Environment=...CONFINED=1).

    Confinement is declared, not sniffed: a tool that cannot work inside the
    sandbox must say so, and guessing from /proc would be one more thing to be
    wrong about.
    """
    return os.environ.get("NEBULA_MCP_CONFINED", "") == "1"


def validate_token(name: str, value: str) -> str:
    """Validate a non-path scalar argument. Returns it, or raises."""
    if not isinstance(value, str) or not value:
        raise ArgumentError(f"{name}: must be a non-empty string")
    bad = _SHELL_META.intersection(value)
    if bad:
        raise ArgumentError(f"{name}: illegal character(s) {''.join(sorted(bad))!r}")
    if value.startswith("-"):
        raise ArgumentError(f"{name}: may not begin with '-' (option injection)")
    if not _TOKEN_RE.match(value):
        raise ArgumentError(f"{name}: not a permitted token")
    return value


def validate_path(name: str, value: str, roots: Iterable[str] | None = None) -> str:
    """Validate a filesystem-path argument against the evidence allowlist.

    Returns the resolved absolute path, or raises ArgumentError. Resolution
    happens before the prefix check, so '..' traversal and a symlink pointing
    out of an evidence root are both caught.
    """
    if not isinstance(value, str) or not value:
        raise ArgumentError(f"{name}: must be a non-empty path")
    bad = _SHELL_META.intersection(value)
    if bad:
        raise ArgumentError(f"{name}: illegal character(s) {''.join(sorted(bad))!r}")
    if value.startswith("-"):
        raise ArgumentError(f"{name}: may not begin with '-' (option injection)")
    resolved = os.path.realpath(value)
    allowed = tuple(roots) if roots is not None else read_roots()
    for root in allowed:
        root = root.rstrip("/")
        if resolved == root or fnmatch.fnmatch(resolved, root + "/*"):
            return resolved
    raise ArgumentError(
        f"{name}: {resolved} is outside the permitted evidence roots "
        f"({', '.join(allowed)})"
    )


def validate_arguments(tool: "Tool", arguments: dict[str, Any]) -> dict[str, Any]:
    """Type- and value-check every argument for *tool*. Returns a clean dict.

    Required arguments must be present; unknown arguments are rejected outright
    rather than silently dropped, because an unknown key is a sign the caller
    and the registry disagree about what this tool is.
    """
    props = tool.schema.get("properties", {})
    for req in tool.schema.get("required", []):
        if req not in arguments:
            raise ArgumentError(f"missing required argument: {req}")
    clean: dict[str, Any] = {}
    for key, value in arguments.items():
        if key not in props:
            raise ArgumentError(f"unknown argument: {key}")
        if not isinstance(value, (str, int, float)) or isinstance(value, bool):
            raise ArgumentError(f"argument {key!r} must be a scalar")
        text = str(value)
        if key in tool.path_args:
            clean[key] = validate_path(key, text)
        else:
            clean[key] = validate_token(key, text)
    return clean


class Tool:
    """A single MCP tool: metadata + a safe argv builder."""

    def __init__(
        self,
        name: str,
        description: str,
        build_argv: Callable[[dict[str, Any]], list[str]],
        needs: str,
        schema: dict[str, Any],
        active: bool = False,
        timeout: int = _DEFAULT_TIMEOUT,
        path_args: tuple[str, ...] = (),
        requires_host_netns: bool = False,
    ) -> None:
        self.name = name
        self.description = description
        self.build_argv = build_argv
        self.needs = needs          # executable to preflight with which()
        self.schema = schema        # JSON schema for arguments
        self.active = active        # True = mutates/probes (not pure read)
        self.timeout = timeout
        self.path_args = path_args  # args validated as evidence-root paths
        # True when the tool reads live kernel network state, which
        # PrivateNetwork=yes removes. Reported, never faked.
        self.requires_host_netns = requires_host_netns

    def blocked_reason(self) -> str | None:
        """Why this tool cannot run right now, or None if it can."""
        if self.requires_host_netns and is_confined():
            return (
                "requires the host network namespace, which the DEC-PHASE12-025 "
                "confinement (PrivateNetwork=yes) removes; run it directly on the deck"
            )
        return None


def _str_prop(desc: str) -> dict[str, Any]:
    return {"type": "string", "description": desc}


# ---------------------------------------------------------------------------
# Curated tool registry — reviewed, static. No dynamic command construction.
# ---------------------------------------------------------------------------

def _registry() -> list[Tool]:
    return [
        Tool(
            "nebula_status",
            "Report Nebula AI runtime status (ollama daemon, model, integrity).",
            # Under confinement there is no loopback to 127.0.0.1:11434, so the
            # daemon probe would report "Runtime: down" — false. --offline makes
            # the answer file-derived and says the probe was skipped.
            lambda a: ["nebula", "status", "--json"] + (["--offline"] if is_confined() else []),
            needs="nebula",
            schema={"type": "object", "properties": {}, "required": []},
        ),
        Tool(
            "systemctl_status",
            "Show the status of a systemd unit (read-only).",
            lambda a: ["systemctl", "status", "--no-pager", "-n", "20", str(a["unit"])],
            needs="systemctl",
            schema={"type": "object",
                    "properties": {"unit": _str_prop("systemd unit name, e.g. nebula-runtime.service")},
                    "required": ["unit"]},
        ),
        Tool(
            "list_connections",
            "List active NetworkManager connections.",
            lambda a: ["nmcli", "-t", "-f", "NAME,TYPE,STATE", "connection", "show", "--active"],
            needs="nmcli",
            schema={"type": "object", "properties": {}, "required": []},
        ),
        Tool(
            "wg_show",
            "Show WireGuard mesh interface state (peers, handshakes).",
            lambda a: ["wg", "show"],
            needs="wg",
            schema={"type": "object", "properties": {}, "required": []},
            requires_host_netns=True,
        ),
        Tool(
            "tshark_summary",
            "Protocol-hierarchy summary of a pcap file (tshark -qz io,phs).",
            lambda a: ["tshark", "-r", str(a["pcap"]), "-q", "-z", "io,phs"],
            needs="tshark",
            schema={"type": "object",
                    "properties": {"pcap": _str_prop("path to a .pcap/.pcapng file")},
                    "required": ["pcap"]},
            path_args=("pcap",),
        ),
        Tool(
            "pcap_analyze",
            "Run the full Orion-X pcap analyzer on a capture file.",
            lambda a: ["pcap-analyzer.py", str(a["pcap"])],
            needs="pcap-analyzer.py",
            schema={"type": "object",
                    "properties": {"pcap": _str_prop("path to a .pcap/.pcapng file")},
                    "required": ["pcap"]},
            path_args=("pcap",),
            timeout=300,
        ),
        Tool(
            "artifact_analyze",
            "Run the Orion-X artifact analyzer on a forensic artifact file.",
            lambda a: ["artifact-analyzer.py", str(a["artifact"])],
            needs="artifact-analyzer.py",
            schema={"type": "object",
                    "properties": {"artifact": _str_prop("path to a memory/disk/log/pcap artifact")},
                    "required": ["artifact"]},
            path_args=("artifact",),
            timeout=600,
        ),
        # --- go-roast: Interactsh OAST metadata decoding (roadmap #91) -------
        # A static Go binary at /usr/local/bin/roast (DEC-PHASE12-002). These
        # give the local model first-class OAST triage: find, decode, and
        # cluster out-of-band callback domains in a log/text file. All read a
        # file (argv-only, no shell/stdin) and emit JSON, matching the tshark/
        # pcap file-tool pattern above.
        Tool(
            "oast_extract",
            "Extract Interactsh OAST callback domains from a log or text file (go-roast).",
            lambda a: ["roast", "extract", "-f", str(a["file"]), "-o", "json"],
            needs="roast",
            schema={"type": "object",
                    "properties": {"file": _str_prop("path to a log/text file to scan for OAST domains")},
                    "required": ["file"]},
            path_args=("file",),
        ),
        Tool(
            "oast_decode",
            "Decode Interactsh OAST domains (one per line in a file) into machine-id/pid/timestamp metadata (go-roast).",
            lambda a: ["roast", "decode", "-f", str(a["file"]), "-o", "json"],
            needs="roast",
            schema={"type": "object",
                    "properties": {"file": _str_prop("path to a file of OAST domains, one per line")},
                    "required": ["file"]},
            path_args=("file",),
        ),
        Tool(
            "oast_analyze",
            "Cluster OAST domains from a file into campaign statistics (go-roast).",
            lambda a: ["roast", "analyze", "-f", str(a["file"]), "-o", "json"],
            needs="roast",
            schema={"type": "object",
                    "properties": {"file": _str_prop("path to a file of OAST domains to cluster")},
                    "required": ["file"]},
            path_args=("file",),
        ),
        # --- nucleotide: Nuclei-scan attribution + actor fingerprinting (#89) --
        # Vendored package + launcher on PATH as `nucleotide` (DEC-PHASE12-012).
        # The lookup table is built at ISO-build time; both tools read a FILE and
        # pass it as argv (no shell/stdin), matching the roast/tshark pattern.
        Tool(
            "nucleotide_lookup",
            "Attribute observed URLs (one per line in a file) to Nuclei scanner templates — "
            "which template produced each request, with template severity and a quality grade. "
            "Reports UNIQUE attributions of medium+ quality (nucleotide).",
            # `nucleotide lookup` reads URLs from argv/stdin only, and this server
            # is argv-only (no shell/stdin) — so use the file-reading watcher in
            # --dry-run mode, which prints attributions instead of publishing them.
            lambda a: ["orionx-nucleotide-watch", "--dry-run", str(a["file"])],
            needs="orionx-nucleotide-watch",
            schema={"type": "object",
                    "properties": {"file": _str_prop("path to a file of URLs/paths, one per line")},
                    "required": ["file"]},
            path_args=("file",),
        ),
        Tool(
            "nucleotide_fingerprint",
            "Build a portable threat-actor behaviour fingerprint (YAML) from a JSONL file of "
            "observed HTTP events, using the on-device Nuclei lookup table (nucleotide).",
            lambda a: ["nucleotide", "fingerprint", str(a["file"]),
                       "--lookup", "/opt/orionx/nucleotide/lookup.json",
                       "--actor-id", str(a.get("actor_id", "orionx-observed"))],
            needs="nucleotide",
            schema={"type": "object",
                    "properties": {
                        "file": _str_prop("path to a JSONL file of observed HTTP events"),
                        "actor_id": _str_prop("label for the fingerprint (default: orionx-observed)"),
                    },
                    "required": ["file"]},
            path_args=("file",),
            timeout=300,
        ),
    ]


_TOOLS: dict[str, Tool] = {t.name: t for t in _registry()}


def list_tools() -> list[dict[str, Any]]:
    """Return the public tool list (name/description/schema/flags).

    This list IS the contract: a client may call a name that appears here and
    nothing else. `available` is false — with a reason — for a tool the
    confinement genuinely prevents, so the model is never handed a tool that
    would answer with silence.
    """
    out: list[dict[str, Any]] = []
    for t in _TOOLS.values():
        blocked = t.blocked_reason()
        entry: dict[str, Any] = {
            "name": t.name,
            "description": t.description,
            "inputSchema": t.schema,
            "active": t.active,
            "available": blocked is None and shutil.which(t.needs) is not None,
        }
        if blocked is not None:
            entry["unavailable_reason"] = blocked
        out.append(entry)
    return out


def _audit(event: str, detail: dict[str, Any]) -> None:
    try:
        _AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event, **detail})
        with _AUDIT_LOG.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def call_tool(
    name: str,
    arguments: dict[str, Any],
    allow_active: bool = False,
) -> dict[str, Any]:
    """Execute one registered tool with validated args. Returns an MCP result
    dict ({"content": [...], "isError": bool}). Never raises.

    *allow_active* is the operator's explicit consent for an "active" tool (one
    that probes or mutates rather than reads). It is never derived from model
    output: the JSON-RPC layer takes it from params["confirm"], and the
    model-in-the-loop bridge (toolchat.py) never sets that field.
    """
    tool = _TOOLS.get(name)
    if tool is None:
        # The static registry is the authority. An unknown name is refused here
        # even if a client somehow offered it to the model.
        _audit("tool_call_rejected", {"tool": name, "reason": "unknown"})
        return _err(f"unknown tool: {name}")

    if tool.active and not allow_active:
        _audit("tool_call_rejected", {"tool": name, "reason": "active_requires_confirmation"})
        return _err(
            f"{name} is an active tool: it must be invoked explicitly by the "
            "operator (confirm=true), not on the model's initiative"
        )

    blocked = tool.blocked_reason()
    if blocked is not None:
        _audit("tool_call_rejected", {"tool": name, "reason": "blocked", "detail": blocked})
        return _err(f"{name} is unavailable: {blocked}")

    # Typed validation: paths must resolve inside an evidence root, tokens must
    # match a narrow character class, and nothing may start with '-' or carry a
    # shell metacharacter (DEC-PHASE12-025).
    try:
        arguments = validate_arguments(tool, arguments)
    except ArgumentError as exc:
        _audit("tool_call_rejected", {"tool": name, "reason": "bad_argument", "detail": str(exc)})
        return _err(str(exc))

    if shutil.which(tool.needs) is None:
        _audit("tool_call_skipped", {"tool": name, "reason": "not installed"})
        return _err(f"{tool.needs} is not installed on this system")

    try:
        argv = tool.build_argv(arguments)
    except (KeyError, TypeError, ValueError) as exc:
        return _err(f"bad arguments: {exc}")

    _audit("tool_call", {"tool": name, "argv": argv})
    try:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=tool.timeout,
        )
    except subprocess.TimeoutExpired:
        _audit("tool_timeout", {"tool": name})
        return _err(f"{name} timed out after {tool.timeout}s")
    except OSError as exc:
        return _err(f"failed to run {name}: {exc}")

    out = (proc.stdout or "") + (("\n[stderr]\n" + proc.stderr) if proc.stderr else "")
    _audit("tool_result", {"tool": name, "rc": proc.returncode, "bytes": len(out)})
    return {
        "content": [{"type": "text", "text": out[:100_000]}],
        "isError": proc.returncode != 0,
    }


def _err(msg: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": msg}], "isError": True}


# ---------------------------------------------------------------------------
# JSON-RPC 2.0 over stdio or a unix-domain socket
# ---------------------------------------------------------------------------

def _handle(req: dict[str, Any]) -> dict[str, Any] | None:
    method = req.get("method")
    rid = req.get("id")
    if method == "initialize":
        return _ok(rid, {
            "protocolVersion": _PROTOCOL_VERSION,
            "serverInfo": {"name": _SERVER_NAME, "version": _SERVER_VERSION},
            "capabilities": {"tools": {}},
        })
    if method == "tools/list":
        return _ok(rid, {"tools": list_tools()})
    if method == "tools/call":
        params = req.get("params") or {}
        # "confirm" is operator consent for an active tool. toolchat.py never
        # sets it from model output; only an explicit `nebula ask --allow-active`
        # (or a hand-written client) can.
        result = call_tool(
            params.get("name", ""),
            params.get("arguments") or {},
            allow_active=params.get("confirm") is True,
        )
        return _ok(rid, result)
    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no response
    return _rpc_err(rid, -32601, f"method not found: {method}")


def _ok(rid: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _rpc_err(rid: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle_line(raw: str) -> str | None:
    """Process one JSON-RPC line; return the reply line, or None for a
    notification. Shared by both transports so they cannot diverge."""
    raw = raw.strip()
    if not raw:
        return None
    try:
        req = json.loads(raw)
    except ValueError:
        return json.dumps(_rpc_err(None, -32700, "parse error"))
    if not isinstance(req, dict):
        return json.dumps(_rpc_err(None, -32600, "invalid request"))
    resp = _handle(req)
    return None if resp is None else json.dumps(resp)


def serve_stdio() -> int:
    """Run the MCP server loop over stdin/stdout (one JSON object per line)."""
    _audit("server_start", {"transport": "stdio", "tools": list(_TOOLS)})
    for raw in sys.stdin:
        reply = handle_line(raw)
        if reply is not None:
            sys.stdout.write(reply + "\n")
            sys.stdout.flush()
    _audit("server_stop", {"transport": "stdio"})
    return 0


def _prepare_socket_path(path: str) -> None:
    """Create the parent directory and clear any stale socket at *path*."""
    parent = Path(path).parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass
    try:
        if Path(path).exists():
            Path(path).unlink()
    except OSError:
        pass


def _grant_socket_access(path: str, group: str = SOCKET_GROUP) -> str:
    """Make the socket reachable by the operator. Returns what was applied.

    @decision DEC-PHASE12-033
    @title Access control lives on the runtime directory, not the socket
    @status accepted
    @rationale This used to chmod 0660 and then chgrp the socket to `sudo`,
      wrapped in try/except as "best-effort". Two things were wrong with that,
      and the first killed the service.

      1. The chgrp is syscall 92 (chown), which the unit's
         SystemCallFilter=~@privileged blocks. Seccomp does not raise OSError —
         it delivers SIGSYS and the process dies. The except clause could never
         run. Observed on v2.2.0-rc4: status=31/SYS, core-dump, three restarts
         in thirty seconds. A defensive handler written for a failure mode that
         cannot occur is worse than none, because it reads as handled.

      2. Even permitted, it could not have worked. The service runs as
         nebula-mcp with SupplementaryGroups= deliberately empty, so it is not
         a member of `sudo`; chgrp to a group you do not belong to is EPERM for
         a non-root uid. The "best-effort" path would always have degraded to
         0660 nebula-mcp:nebula-mcp — unreachable by orionx-operator — so
         `nebula ask` could never have connected.

      So the socket does no privileged work at all. The unit's ExecStartPre
      (prefixed `+`, therefore outside the sandbox) sets the runtime directory
      to 0770 nebula-mcp:sudo, and the socket is created world-rw inside it.
      The directory is the gate: only root can change it, traversal requires
      membership of `sudo`, and a mode on the socket cannot widen that. This
      is strictly less privilege than before — no chown syscall, no extra group
      membership — and unlike before, it works.
    """
    try:
        os.chmod(path, 0o666)
    except OSError:
        return "unchanged"
    return "0666 inside 0770 dir (directory-gated)"


def serve_unix(
    socket_path: str = DEFAULT_SOCKET,
    max_connections: int | None = None,
) -> int:
    """Serve JSON-RPC over an AF_UNIX stream socket.

    This is the transport used under confinement. AF_UNIX is a filesystem
    object, so it is untouched by PrivateNetwork=yes — the model's client
    reaches the server without the server owning a single IP socket.

    Connections are served one at a time on purpose: these tools run
    subprocesses with 2–10 minute timeouts, and a parallel accept loop would
    turn "the model got enthusiastic" into a fork bomb on a low-power deck.

    *max_connections* bounds the accept loop (tests use it); None = forever.
    """
    _prepare_socket_path(socket_path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(socket_path)
    except OSError as exc:
        print(f"nebula-mcp: cannot bind {socket_path}: {exc}", file=sys.stderr)
        return 1
    perms = _grant_socket_access(socket_path)
    srv.listen(8)
    _audit("server_start", {
        "transport": "unix", "socket": socket_path,
        "perms": perms, "confined": is_confined(), "tools": list(_TOOLS),
    })
    served = 0
    try:
        while max_connections is None or served < max_connections:
            try:
                conn, _ = srv.accept()
            except OSError:
                break
            served += 1
            with conn:
                _serve_connection(conn)
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
        try:
            Path(socket_path).unlink()
        except OSError:
            pass
        _audit("server_stop", {"transport": "unix", "connections": served})
    return 0


def _serve_connection(conn: socket.socket) -> None:
    """Read newline-delimited JSON-RPC from one client until it disconnects."""
    buf = b""
    while True:
        try:
            chunk = conn.recv(65536)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        if len(buf) > _MAX_LINE_BYTES:
            # A client that never sends a newline is not a client.
            _audit("request_rejected", {"reason": "line_too_long", "bytes": len(buf)})
            try:
                conn.sendall(
                    (json.dumps(_rpc_err(None, -32600, "request too large")) + "\n").encode()
                )
            except OSError:
                pass
            return
        while b"\n" in buf:
            line, _, buf = buf.partition(b"\n")
            reply = handle_line(line.decode("utf-8", errors="replace"))
            if reply is None:
                continue
            try:
                conn.sendall((reply + "\n").encode("utf-8"))
            except OSError:
                return


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="nebula-mcp",
        description=(
            "Orion-X Nebula MCP tool server — curated local forensic tools over "
            "JSON-RPC 2.0. Confined by nebula-mcp.service (DEC-PHASE12-025)."
        ),
    )
    ap.add_argument(
        "--socket", metavar="PATH", nargs="?", const=DEFAULT_SOCKET, default=None,
        help=f"serve on a unix socket instead of stdio (default: {DEFAULT_SOCKET})",
    )
    ap.add_argument(
        "--max-connections", type=int, default=None,
        help="exit after serving this many connections (testing)",
    )
    args = ap.parse_args(argv)
    if args.socket:
        return serve_unix(args.socket, max_connections=args.max_connections)
    return serve_stdio()


if __name__ == "__main__":
    sys.exit(main())
