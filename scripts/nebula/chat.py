"""
nebula chat — local, private forensic-assistant chat (W10-2).

Streams completions from the on-box ollama model (Qwen2.5-3B) via
helpers.runtime_client.chat_stream. stdlib-only; nothing leaves the host
(DEC-006 LOCAL-ONLY). Per-session history is persisted as JSON under
helpers.paths.SESSIONS_DIR so a conversation survives across invocations and
is shared between the CLI and the Control Center "Ask Nebula" pane.

Public API (used by the CLI dispatcher and the Control Center):
    SYSTEM_PROMPT
    resolve_model()             -> model tag or None
    new_session_id()            -> timestamped id
    load_session(session_id)    -> list[messages]
    save_session(session_id, messages)
    stream_reply(messages, on_token=None) -> assistant text
    run_cli(prompt, pcap, session_id) -> exit code   (interactive/one-shot REPL)

@decision DEC-PHASE10-005
@title W10-2 Nebula chat: CLI + Control Center pane share one chat core
@status accepted
@rationale The chat logic (system persona, streaming, session persistence,
  model resolution) lives here once; both the `nebula chat` CLI and the GTK
  "Ask Nebula" pane import it. No inference logic is duplicated in the UI.

@decision DEC-PHASE9-019
@title from __future__ import annotations required in all Phase 10 Python modules
@status accepted
"""
from __future__ import annotations

import datetime
import json
import sys
from pathlib import Path
from typing import Any, Callable, Optional

from .helpers import runtime_client
from .helpers.paths import SESSIONS_DIR

# The default forensic-assistant persona. Kept terse and local-minded: this
# model is small (3B) and runs on modest CPU, so we steer it toward concise,
# practical DFIR answers and honest uncertainty rather than long essays.
SYSTEM_PROMPT = (
    "You are Nebula, the on-device AI assistant inside Orion-X Phoenix Edition, "
    "a forensics and incident-response cyberdeck. You run entirely locally; no "
    "data leaves this machine. Help the operator with digital forensics, "
    "incident response, network/packet analysis, and using the Orion-X tools "
    "(orionx-mesh, pcap-analyzer, artifact-analyzer, storyboard-gen, tshark, "
    "volatility, lynis). Be concise and practical. Give exact commands when "
    "useful. If you are unsure, say so plainly rather than guessing. This is "
    "for authorized defensive and investigative work."
)

# Fallback model tag if ollama has not registered one yet (matches the model
# staged by the build's Modelfile).
_DEFAULT_MODEL = "qwen2.5:3b-instruct-q4_K_M"


def resolve_model() -> Optional[str]:
    """Return the model tag to use: whatever ollama has registered, else the
    known default. Returns None only when ollama is down AND we want callers to
    surface that (they can still try the default)."""
    name = runtime_client.get_loaded_model_name()
    return name or _DEFAULT_MODEL


def new_session_id() -> str:
    """Return a filesystem-safe, sortable session id."""
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def _session_path(session_id: str) -> Path:
    return SESSIONS_DIR / f"{session_id}.json"


def load_session(session_id: str) -> list[dict[str, str]]:
    """Load a saved session's message list, or [] if none/unreadable."""
    path = _session_path(session_id)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        msgs = data.get("messages", []) if isinstance(data, dict) else data
        return [m for m in msgs if isinstance(m, dict) and "role" in m and "content" in m]
    except (OSError, ValueError):
        return []


def save_session(session_id: str, messages: list[dict[str, str]]) -> None:
    """Persist *messages* for *session_id* (best-effort; never raises)."""
    try:
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        payload: dict[str, Any] = {
            "session_id": session_id,
            "updated": datetime.datetime.now().isoformat(timespec="seconds"),
            "messages": messages,
        }
        _session_path(session_id).write_text(
            json.dumps(payload, indent=2), encoding="utf-8"
        )
    except OSError:
        pass


def _seed_history() -> list[dict[str, str]]:
    """A fresh history seeded with the system persona."""
    return [{"role": "system", "content": SYSTEM_PROMPT}]


def stream_reply(
    messages: list[dict[str, str]],
    on_token: Optional[Callable[[str], None]] = None,
) -> str:
    """Stream one assistant reply for the given *messages* (which must already
    include the trailing user turn). Returns the full assistant text.

    Raises runtime_client.InferenceError on failure."""
    model = resolve_model()
    if model is None:
        raise runtime_client.InferenceError("No model available and ollama is down.")
    return runtime_client.chat_stream(messages, model=model, on_token=on_token)


# ---------------------------------------------------------------------------
# CLI REPL
# ---------------------------------------------------------------------------

def _pcap_context(pcap: str) -> Optional[dict[str, str]]:
    """Return a user-role context message describing a pcap the operator wants
    to discuss, or None if the path is unusable."""
    p = Path(pcap)
    if not p.exists():
        print(f"warning: --pcap file not found: {pcap}", file=sys.stderr)
        return None
    size = p.stat().st_size
    return {
        "role": "user",
        "content": (
            f"[context] I am analyzing the packet capture at {p} "
            f"({size} bytes). For a full breakdown I can run "
            f"'pcap-analyzer.py {p}'. Keep this file in mind for my questions."
        ),
    }


def run_cli(
    prompt: Optional[str] = None,
    pcap: Optional[str] = None,
    session_id: Optional[str] = None,
) -> int:
    """Run the chat REPL (interactive) or a single turn (if *prompt* given).

    Returns a process exit code.
    """
    sid = session_id or new_session_id()
    messages = load_session(sid) or _seed_history()

    if pcap:
        ctx = _pcap_context(pcap)
        if ctx:
            messages.append(ctx)

    def _one_turn(user_text: str) -> bool:
        """Run a single user→assistant turn, streaming to stdout. Returns
        False on inference error (so the REPL can keep going)."""
        messages.append({"role": "user", "content": user_text})
        print("\nnebula> ", end="", flush=True)
        try:
            reply = stream_reply(messages, on_token=lambda t: print(t, end="", flush=True))
        except runtime_client.InferenceError as exc:
            print(f"\n[error] {exc}", flush=True)
            messages.pop()  # drop the user turn that got no reply
            return False
        print(flush=True)
        messages.append({"role": "assistant", "content": reply})
        save_session(sid, messages)
        return True

    # One-shot mode
    if prompt:
        ok = _one_turn(prompt)
        return 0 if ok else 1

    # Interactive REPL
    print(f"Nebula chat  (session {sid})  — local, private.  Model: {resolve_model()}")
    print("Type your question. Commands: /exit  /clear  /save  /help")
    while True:
        try:
            user_text = input("\nyou> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not user_text:
            continue
        if user_text in ("/exit", "/quit"):
            break
        if user_text == "/help":
            print("Commands: /exit quit · /clear reset conversation · /save write session · /help")
            continue
        if user_text == "/clear":
            messages = _seed_history()
            print("(conversation cleared)")
            continue
        if user_text == "/save":
            save_session(sid, messages)
            print(f"(saved session {sid})")
            continue
        _one_turn(user_text)

    save_session(sid, messages)
    print(f"Session saved: {_session_path(sid)}")
    return 0
