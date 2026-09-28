"""
nebula toolchat — model-in-the-loop tool calling against the confined MCP server.

The on-device model can now decide to run a tool. It still cannot decide *which
tools exist*: the confined server's static registry is the only authority, and
every candidate call crosses two gates that both read from it.

    operator ──> nebula ask ──HTTP──> ollama 127.0.0.1:11434   (this process)
                     │
                     └──AF_UNIX──> /run/nebula-mcp/nebula-mcp.sock
                                   nebula-mcp.service (PrivateNetwork=yes)

Direction is the whole trick. This bridge runs as the operator, so it may talk
to ollama over loopback. The tool server never does — it owns no IP socket at
all — and is reached over a unix socket, which a network namespace cannot
affect. Nothing had to be loosened to make the two halves meet.

Public API:
    build_tool_prompt(tools)            -> the tool-use instructions
    parse_tool_call(text)               -> {"tool":..., "arguments":...} | None
    ToolGate(tools)                     -> .permit(name) -> (bool, reason)
    MCPClient(socket_path)              -> .list_tools() / .call_tool()
    run_agent(prompt, ...)              -> final assistant text
    run_cli(...)                        -> exit code

@decision DEC-PHASE12-025
@title Model-in-the-loop tool calling: a text protocol gated twice by the
  server's static registry
@status accepted
@rationale The model emits a one-line JSON object to request a tool. Two
  reasons not to use ollama's native `tools` parameter: a 3B q4 model's
  tool-call grammar is unreliable enough that we would need this text fallback
  anyway, and the native path would put the tool list in ollama's request
  payload — a second place where "what tools exist" is written down. Here the
  list comes from one `tools/list` round-trip against the server and is used
  for the prompt, for the gate, and for nothing else.

  CONTAINMENT. `ToolGate` is built from that response and refuses any name not
  in it before a byte reaches the socket. The server then refuses unknown names
  again in call_tool() — it is the authority, the gate is an optimisation and a
  clearer error. A model that invents `bash`, `shell_exec` or `curl` gets a
  refusal it can read and retry from, and nothing is executed. Arguments are
  passed through as-is and validated server-side, so the bridge has no
  opportunity to launder a bad path into a good one.

  ACTIVE TOOLS. The bridge never sets params["confirm"], so an active tool is
  refused by the server no matter what the model asks for. Only an operator
  running `nebula ask --allow-active` sets it, and even then only for a tool
  the operator named on the command line — never one the model chose.

  BOUNDED. At most --max-steps tool calls per question (default 4), so a model
  that loops on a failing tool stops instead of grinding a low-power deck.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import json
import re
import socket
import sys
from typing import Any, Callable, Optional

# Default transport. Matches mcp_server.DEFAULT_SOCKET; duplicated as a literal
# only so this module imports standalone (the CLI resolves the real constant).
DEFAULT_SOCKET = "/run/nebula-mcp/nebula-mcp.sock"

# How many tool calls one question may trigger.
DEFAULT_MAX_STEPS = 4

# Cap on how much tool output is fed back into the context. A 3B model with a
# small context window is destroyed by a 100 KB pcap dump; the operator can
# always read the full output from the tool directly.
MAX_TOOL_OUTPUT_CHARS = 4000

# Socket read timeout. artifact_analyze may legitimately run 10 minutes, so
# this must exceed the largest server-side tool timeout (600 s) with margin.
SOCKET_TIMEOUT = 660.0

# "tool" must appear before we bother scanning for a balanced object.
_CALL_HINT = re.compile(r'"tool"\s*:')


class MCPError(RuntimeError):
    """Raised when the MCP tool server cannot be reached or misbehaves."""


# ---------------------------------------------------------------------------
# Prompt + parsing (pure functions — the testable core)
# ---------------------------------------------------------------------------

def build_tool_prompt(tools: list[dict[str, Any]]) -> str:
    """Render the tool-use instructions for the system prompt.

    Only tools the server reports as available AND passive are offered. An
    active tool is never advertised, because advertising it invites the model
    to try something the server will refuse.
    """
    usable = [t for t in tools if t.get("available") and not t.get("active")]
    lines = [
        "",
        "TOOLS. You may run exactly one of the local tools listed below, and "
        "nothing else. There is no shell. To run a tool, reply with a single "
        "line containing only a JSON object:",
        '  {"tool": "<name>", "arguments": {"<arg>": "<value>"}}',
        "Say nothing else on that turn. The result comes back as a TOOL RESULT "
        "message; then answer the operator in plain prose. If no tool fits, "
        "just answer. Never invent a tool name — anything not on this list is "
        "refused.",
        "",
        "Available tools:",
    ]
    for t in usable:
        props = (t.get("inputSchema") or {}).get("properties") or {}
        required = set((t.get("inputSchema") or {}).get("required") or [])
        if props:
            argsig = ", ".join(
                f"{k}{'' if k in required else '?'}" for k in props
            )
        else:
            argsig = "no arguments"
        lines.append(f"  - {t['name']}({argsig}) — {t['description']}")
    if not usable:
        lines.append("  (none are available on this system right now)")
    return "\n".join(lines)


def _balanced_objects(text: str):
    """Yield every balanced {...} substring, brace-counting outside strings.

    A regex cannot do this: the arguments object nests, so any [^{}] class
    stops at the first inner brace and silently misses every real tool call.
    That bug is why this is a scanner.
    """
    depth = 0
    start = -1
    in_str = False
    escaped = False
    for i, ch in enumerate(text):
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start >= 0:
                    yield text[start:i + 1]
                    start = -1


def parse_tool_call(text: str) -> Optional[dict[str, Any]]:
    """Extract a tool-call request from model output, or None.

    Tolerant about what surrounds the JSON (code fences, a stray sentence)
    because a 3B model is, but strict about its shape: a "tool" string and an
    optional object of scalar arguments. Anything else is not a tool call and
    is treated as prose.
    """
    if not text or not _CALL_HINT.search(text):
        return None
    for candidate in _balanced_objects(text):
        try:
            obj = json.loads(candidate)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        name = obj.get("tool")
        if not isinstance(name, str) or not name:
            continue
        args = obj.get("arguments", {})
        if args is None:
            args = {}
        if not isinstance(args, dict):
            continue
        if not all(isinstance(v, (str, int, float)) and not isinstance(v, bool)
                   for v in args.values()):
            continue
        return {"tool": name, "arguments": args}
    return None


class ToolGate:
    """Client-side containment: only names in the server's registry pass.

    The server enforces the same rule and is the authority. This gate exists so
    a hallucinated tool never leaves the process, and so the model gets a
    refusal phrased in terms it can act on.
    """

    def __init__(self, tools: list[dict[str, Any]]) -> None:
        self.registry = {t["name"]: t for t in tools}
        self.allowed = frozenset(
            t["name"] for t in tools if t.get("available") and not t.get("active")
        )

    def permit(self, name: str) -> tuple[bool, str]:
        """Return (allowed, reason). *reason* is empty when allowed."""
        if name not in self.registry:
            return False, (
                f"'{name}' is not a tool on this system. The only tools that "
                f"exist are: {', '.join(sorted(self.registry)) or '(none)'}."
            )
        entry = self.registry[name]
        if entry.get("active"):
            return False, (
                f"'{name}' is an active tool and must be invoked explicitly by "
                "the operator, not by you."
            )
        if not entry.get("available"):
            reason = entry.get("unavailable_reason", "it is not installed")
            return False, f"'{name}' is unavailable: {reason}"
        return True, ""


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

class MCPClient:
    """Newline-delimited JSON-RPC 2.0 over the MCP server's unix socket."""

    def __init__(self, socket_path: str = DEFAULT_SOCKET,
                 timeout: float = SOCKET_TIMEOUT) -> None:
        self.socket_path = socket_path
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self._buf = b""
        self._next_id = 0

    def __enter__(self) -> "MCPClient":
        self.connect()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect(self.socket_path)
        except OSError as exc:
            sock.close()
            raise MCPError(
                f"cannot reach the Nebula tool server at {self.socket_path} ({exc}). "
                "Is nebula-mcp.service running, and are you in the 'sudo' group?"
            ) from exc
        self._sock = sock

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            finally:
                self._sock = None

    def _request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        if self._sock is None:
            raise MCPError("not connected")
        self._next_id += 1
        req = {"jsonrpc": "2.0", "id": self._next_id, "method": method}
        if params is not None:
            req["params"] = params
        try:
            self._sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
        except OSError as exc:
            raise MCPError(f"tool server write failed: {exc}") from exc
        line = self._readline()
        try:
            resp = json.loads(line)
        except ValueError as exc:
            raise MCPError(f"tool server sent malformed JSON: {line[:200]!r}") from exc
        if "error" in resp:
            raise MCPError(str(resp["error"].get("message", resp["error"])))
        return resp.get("result") or {}

    def _readline(self) -> str:
        assert self._sock is not None
        while b"\n" not in self._buf:
            try:
                chunk = self._sock.recv(65536)
            except OSError as exc:
                raise MCPError(f"tool server read failed: {exc}") from exc
            if not chunk:
                raise MCPError("tool server closed the connection")
            self._buf += chunk
        line, _, self._buf = self._buf.partition(b"\n")
        return line.decode("utf-8", errors="replace")

    def initialize(self) -> dict[str, Any]:
        return self._request("initialize", {"protocolVersion": "2024-11-05"})

    def list_tools(self) -> list[dict[str, Any]]:
        return list(self._request("tools/list").get("tools", []))

    def call_tool(self, name: str, arguments: dict[str, Any],
                  confirm: bool = False) -> dict[str, Any]:
        params: dict[str, Any] = {"name": name, "arguments": arguments}
        if confirm:
            # Operator consent only. run_agent never passes confirm=True.
            params["confirm"] = True
        return self._request("tools/call", params)


def result_text(result: dict[str, Any]) -> str:
    """Flatten an MCP result's content blocks to text."""
    parts = [
        str(block.get("text", ""))
        for block in (result.get("content") or [])
        if isinstance(block, dict)
    ]
    return "\n".join(p for p in parts if p)


# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------

def run_agent(
    prompt: str,
    client: MCPClient,
    chat_fn: Callable[[list[dict[str, str]]], str],
    system_prompt: str = "",
    max_steps: int = DEFAULT_MAX_STEPS,
    on_event: Optional[Callable[[str, dict[str, Any]], None]] = None,
) -> str:
    """Answer *prompt*, letting the model call tools through *client*.

    *chat_fn* takes the message list and returns the assistant's text; it is
    injected so the loop can be tested without ollama, and so the streaming
    callback stays a CLI concern.

    Returns the model's final prose answer.
    """
    tools = client.list_tools()
    gate = ToolGate(tools)
    messages: list[dict[str, str]] = [
        {"role": "system", "content": system_prompt + build_tool_prompt(tools)},
        {"role": "user", "content": prompt},
    ]

    def emit(kind: str, detail: dict[str, Any]) -> None:
        if on_event is not None:
            on_event(kind, detail)

    for _step in range(max_steps):
        reply = chat_fn(messages)
        messages.append({"role": "assistant", "content": reply})
        call = parse_tool_call(reply)
        if call is None:
            return reply

        name = call["tool"]
        allowed, reason = gate.permit(name)
        if not allowed:
            emit("refused", {"tool": name, "reason": reason})
            messages.append({
                "role": "user",
                "content": f"TOOL REFUSED: {reason} Answer without it, or pick a listed tool.",
            })
            continue

        emit("calling", {"tool": name, "arguments": call["arguments"]})
        try:
            # confirm is deliberately absent: an active tool cannot be reached
            # from here, whatever the model asks for.
            result = client.call_tool(name, call["arguments"])
        except MCPError as exc:
            emit("error", {"tool": name, "error": str(exc)})
            messages.append({
                "role": "user",
                "content": f"TOOL ERROR for {name}: {exc}. Answer without it.",
            })
            continue

        text = result_text(result)[:MAX_TOOL_OUTPUT_CHARS]
        emit("result", {"tool": name, "isError": bool(result.get("isError")), "chars": len(text)})
        messages.append({
            "role": "user",
            "content": f"TOOL RESULT ({name}):\n{text}\n\nNow answer the operator.",
        })

    # Out of steps: ask for a plain answer with what is already in context.
    messages.append({
        "role": "user",
        "content": "No more tool calls are allowed. Answer now in plain prose.",
    })
    return chat_fn(messages)


# ---------------------------------------------------------------------------
# CLI (`nebula ask`)
# ---------------------------------------------------------------------------

def run_cli(
    prompt: str,
    socket_path: str = DEFAULT_SOCKET,
    max_steps: int = DEFAULT_MAX_STEPS,
    tool: Optional[str] = None,
    tool_args: Optional[dict[str, Any]] = None,
    allow_active: bool = False,
) -> int:
    """Run one tool-assisted question, or one operator-invoked tool directly."""
    from .chat import SYSTEM_PROMPT, resolve_model  # noqa: PLC0415
    from .helpers import runtime_client  # noqa: PLC0415

    try:
        with MCPClient(socket_path) as client:
            client.initialize()

            # Operator-invoked tool: this is the ONLY path that may confirm an
            # active tool, and the operator named it, not the model.
            if tool:
                result = client.call_tool(tool, tool_args or {}, confirm=allow_active)
                print(result_text(result))
                return 1 if result.get("isError") else 0

            model = resolve_model()

            def chat_fn(messages: list[dict[str, str]]) -> str:
                return runtime_client.chat_stream(messages, model=model)

            def on_event(kind: str, detail: dict[str, Any]) -> None:
                if kind == "calling":
                    print(f"  [tool] {detail['tool']} {detail['arguments']}",
                          file=sys.stderr, flush=True)
                elif kind in ("refused", "error"):
                    print(f"  [tool {kind}] {detail.get('reason') or detail.get('error')}",
                          file=sys.stderr, flush=True)

            answer = run_agent(
                prompt, client, chat_fn,
                system_prompt=SYSTEM_PROMPT,
                max_steps=max_steps,
                on_event=on_event,
            )
            print(answer)
            return 0
    except MCPError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1
    except runtime_client.InferenceError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1
