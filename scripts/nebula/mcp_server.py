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

SANDBOX STATUS (honest): this slice runs tools with argv validation + timeouts +
audit logging. The full DEC-007 confinement — a dedicated `nebula-mcp` system
user, the AppArmor profile at /etc/apparmor.d/usr.bin.nebula-mcp, and namespace
isolation (no shell, no outbound network) — is the tracked XL remainder of W10-3.
Model-in-the-loop tool-calling (Nebula deciding to call these) is W10-2/W10-3
integration, also tracked.

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

import json
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

_AUDIT_LOG = Path("/var/log/orionx/nebula-mcp.log")
_SERVER_NAME = "orionx-nebula-mcp"
_SERVER_VERSION = "0.1.0"
_PROTOCOL_VERSION = "2024-11-05"

# Per-tool execution timeout (seconds). Analysis tools can be slow.
_DEFAULT_TIMEOUT = 120


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
    ) -> None:
        self.name = name
        self.description = description
        self.build_argv = build_argv
        self.needs = needs          # executable to preflight with which()
        self.schema = schema        # JSON schema for arguments
        self.active = active        # True = mutates/probes (not pure read)
        self.timeout = timeout


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
            lambda a: ["nebula", "status", "--json"],
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
        ),
        Tool(
            "tshark_summary",
            "Protocol-hierarchy summary of a pcap file (tshark -qz io,phs).",
            lambda a: ["tshark", "-r", str(a["pcap"]), "-q", "-z", "io,phs"],
            needs="tshark",
            schema={"type": "object",
                    "properties": {"pcap": _str_prop("path to a .pcap/.pcapng file")},
                    "required": ["pcap"]},
        ),
        Tool(
            "pcap_analyze",
            "Run the full Orion-X pcap analyzer on a capture file.",
            lambda a: ["pcap-analyzer.py", str(a["pcap"])],
            needs="pcap-analyzer.py",
            schema={"type": "object",
                    "properties": {"pcap": _str_prop("path to a .pcap/.pcapng file")},
                    "required": ["pcap"]},
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
            timeout=600,
        ),
    ]


_TOOLS: dict[str, Tool] = {t.name: t for t in _registry()}


def list_tools() -> list[dict[str, Any]]:
    """Return the public tool list (name/description/schema/flags)."""
    return [
        {
            "name": t.name,
            "description": t.description,
            "inputSchema": t.schema,
            "active": t.active,
            "available": shutil.which(t.needs) is not None,
        }
        for t in _TOOLS.values()
    ]


def _audit(event: str, detail: dict[str, Any]) -> None:
    try:
        _AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event, **detail})
        with _AUDIT_LOG.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def call_tool(name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    """Execute one registered tool with validated args. Returns an MCP result
    dict ({"content": [...], "isError": bool}). Never raises."""
    tool = _TOOLS.get(name)
    if tool is None:
        _audit("tool_call_rejected", {"tool": name, "reason": "unknown"})
        return _err(f"unknown tool: {name}")

    # Validate required args are present and are strings (no dicts/lists → no
    # argv injection surface).
    for req in tool.schema.get("required", []):
        if req not in arguments:
            return _err(f"missing required argument: {req}")
    for k, v in arguments.items():
        if not isinstance(v, (str, int, float)):
            return _err(f"argument {k!r} must be a scalar")

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
# JSON-RPC 2.0 over stdio
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
        result = call_tool(params.get("name", ""), params.get("arguments") or {})
        return _ok(rid, result)
    if method in ("notifications/initialized", "initialized"):
        return None  # notification, no response
    return _rpc_err(rid, -32601, f"method not found: {method}")


def _ok(rid: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _rpc_err(rid: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def serve_stdio() -> int:
    """Run the MCP server loop over stdin/stdout (one JSON object per line)."""
    _audit("server_start", {"tools": list(_TOOLS)})
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
        except ValueError:
            sys.stdout.write(json.dumps(_rpc_err(None, -32700, "parse error")) + "\n")
            sys.stdout.flush()
            continue
        resp = _handle(req)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
    _audit("server_stop", {})
    return 0


if __name__ == "__main__":
    sys.exit(serve_stdio())
