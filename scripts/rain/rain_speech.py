#!/usr/bin/env python3
"""rain_speech — R.A.I.N. spoken narration: Nebula writes the sentence, TTS says it.

R.A.I.N. plays four fixed tones. A tone tells the operator's 3am self that
SOMETHING happened. It cannot say *what*. "Port scan from 192.168.4.77, 900
distinct ports in 11 seconds" is a different product from a warning beep.

Nebula is Qwen2.5-3B-Instruct. It is a TEXT model: it cannot synthesise audio,
and nothing in this module pretends otherwise. The split is:

    event  ->  Nebula writes one sentence  ->  validator  ->  TTS speaks it

@decision DEC-PHASE12-046
@title R.A.I.N. speaks: model-authored, fact-constrained spoken alerts
@status accepted
@rationale Three non-negotiables shaped every line of this file.

  1. THE MODEL NEVER GATES THE ALERT. orionx-rain plays the cue first and
     synchronously, exactly as it does today, and only then hands the event to
     this module's Narrator, which is a bounded non-blocking queue on a daemon
     thread. If Nebula is slow, absent, or wrong, or no TTS exists, the deck
     behaves byte-for-byte as it did before this decision. This is the same
     contract orionx-postured's Contextualizer established (DEC-PHASE12-034)
     and it is copied here deliberately rather than reinvented.

  2. THE MODEL MAY NOT INVENT FACTS. A fabricated security claim spoken aloud
     with a calm synthetic voice at 3am is worse than silence — the operator
     cannot see the hedge they would see in text. So what is spoken is NEVER
     trusted model output. It is either:

       (a) a deterministic template rendered from the event's own structured
           detail (see orionx-scanwatch:build_detail), or
       (b) a model sentence that survived validate_line(), which admits only
           closed-class English function words plus words the event itself
           contains, only numbers the event itself contains, and only the
           event's own src_ip.

     Rejection is not a failure mode, it is the normal path: the template is
     always there. The model's job is to phrase well, never to supply facts.

  3. A FLOOD DEGRADES TO TONES, NOT TO A BACKLOG. Every bound in this file
     exists so that narration about an event from four minutes ago can never
     be spoken. See the constants block for the arithmetic.

  Off by default. Speech is intelligible to everyone in the room; a tone is
  not. On a deck used during an engagement, narrating "port scan from
  192.168.4.77" out loud is an operational-security change the operator must
  opt into, not inherit from an upgrade. `orionx-rain --speech on`.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from queue import Empty, Full, Queue
from typing import Any, Callable

try:
    import fcntl
except ImportError:                      # pragma: no cover - not a POSIX host
    fcntl = None  # type: ignore[assignment]

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rain_lib  # noqa: E402

# ---------------------------------------------------------------------------
# Bounds. Every number here is load-bearing; the comment is the justification.
# ---------------------------------------------------------------------------

# Model generation budget. Qwen2.5-3B on CPU emits roughly 15-25 tok/s; the
# prompt caps output at NEBULA_NUM_PREDICT tokens, so a healthy call lands well
# inside this. Past ~6s the operator has already looked at the screen and the
# sentence is narrating something they can see, so a slower answer is worth
# less than no answer. postured uses 20s because its output is written to the
# bus and read later; spoken output has a much shorter shelf life.
SPEECH_TIMEOUT = 6.0
NEBULA_PROBE_TIMEOUT = 2.0      # /api/tags reachability probe
NEBULA_NUM_PREDICT = 48         # hard cap on generated tokens

# Queue depth. Worst-case service time per item is SPEECH_TIMEOUT (6s) plus
# TTS_TIMEOUT (15s), but a real TTS render of one short sentence is ~1-2s, so
# ~8s typical. Depth 2 therefore holds at most ~16s of work, which is inside
# SPEECH_MAX_AGE_SECONDS. A deeper queue could only ever hold items that will
# be discarded as stale on dequeue — i.e. it would be backlog by construction.
# The "~1-2s" is a build-host estimate, not a deck measurement; SpeechStats
# (#96, DEC-PHASE13-050) records what the deck actually takes so the bound
# can be checked against evidence with `orionx-rain --speech-status`.
SPEECH_QUEUE_MAX = 2

# At most one spoken line per this many seconds, regardless of severity. A
# line is 3-5s of audio. Two overlapping narrations are unintelligible AND
# they mask the tone, which is the safety-critical signal. Enforced by
# DROPPING, never by sleeping: sleeping is how a queue becomes a backlog.
SPEECH_MIN_GAP_SECONDS = 20.0

# Narration older than this is not spoken at all. Checked at dequeue, against
# the event's own `ts`, so a stall anywhere in the pipeline self-heals into
# silence rather than into a monologue about the past.
SPEECH_MAX_AGE_SECONDS = 20.0

# Hard caps on what may ever reach the speaker.
SPEECH_MAX_WORDS = 24
SPEECH_MAX_CHARS = 240
# What may actually be SPOKEN. Larger than the model-validation budget above
# because speakable() expands every dotted quad to "192 dot 168 dot 4 dot 77"
# (about double) and the template prefixes the severity. ~20 s at espeak's
# default rate. Shaping cuts at a sentence or word boundary, never mid-word:
# "port scan from 192 dot 168 dot" is worse than saying less (reference
# deck, 2026-10-05: narration audibly cut off mid-message).
SPEAK_MAX_CHARS = 360
TTS_TIMEOUT = 15.0

# DEC-006: localhost only, always. Mirrors orionx-postured's NEBULA_URL; the
# drift invariant in tests/unit/test_rain_speech.sh asserts they stay equal.
NEBULA_URL = "http://127.0.0.1:11434"

SPEECH_SYSTEM = (
    "You rewrite one security event as a single spoken sentence for an "
    "operator who cannot look at the screen. Use ONLY the facts given. Invent "
    "nothing: no attacker identity, no motive, no tool name, no advice, no "
    "number that is not in the facts. Write every number as digits, never as "
    "words. At most 20 words. One sentence. Plain text, no markdown, no "
    "preamble, no quotes."
)

# ---------------------------------------------------------------------------
# The lexicon: closed-class English function words, and nothing else.
#
# This list is the whole anti-fabrication design in one object. It contains no
# noun, no verb of action, no adjective, no number word. "hosts", "malware",
# "credentials", "nine", "hundred", "likely" are all absent, so the model
# cannot assemble a claim out of generic vocabulary — every content word it
# speaks must appear in the event itself. Number words are excluded on purpose:
# "nine hundred ports" cannot be checked against `900`, but "900" can.
# ---------------------------------------------------------------------------
_GENERIC_LEXICON = frozenset("""
a an and are as at be been being but by can could did do does during each for
from had has have if in into is it its may might must no not of on or over
should so that the their them then there these they this those to was were
when where which while will with within would
info notice warning critical
""".split())

_IP_RE = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")

# ---------------------------------------------------------------------------
# Pronunciation: how the engines should SAY tokens that are spelled for the
# screen (#123, DEC-PHASE13-025). Both piper and espeak-ng read "IDS" as a
# word ("eye-dees", HP Pavilion 2026-10-26), "→" as nothing or "arrow",
# "10.0.0.5:22" as a time of day, "SSH::Password_Guessing" as one mangled
# word. Applied inside speakable(), which runs AFTER validate_line(), so a
# spoken form can never widen what the model is allowed to claim: the guard
# sees the screen spelling, the speaker gets the spoken one. Word-boundary
# and case-sensitive on purpose: "IDS" is the acronym, "ids" in prose is not.
# Letters to be spoken one at a time are written spaced ("I D S").
# ---------------------------------------------------------------------------
_SPOKEN_FORMS: dict[str, str] = {
    # detection
    "IDS": "I D S", "IPS": "I P S", "C2": "C two", "ET": "E T", "SID": "S I D",
    "IOC": "I O C", "CVE": "C V E", "YARA": "yara", "OSINT": "oh sint",
    # protocols and addressing
    "IP": "I P", "IPv4": "I P v 4", "IPv6": "I P v 6", "TCP": "T C P",
    "tcp": "T C P", "UDP": "U D P", "udp": "U D P", "ICMP": "I C M P",
    "icmp": "I C M P", "DNS": "D N S", "SSH": "S S H", "HTTP": "H T T P",
    "HTTPS": "H T T P S", "TLS": "T L S", "SMB": "S M B", "RDP": "R D P",
    "SQL": "sequel", "FTP": "F T P", "SMTP": "S M T P", "NTP": "N T P",
    "ARP": "arp", "MAC": "mack", "VPN": "V P N", "URL": "U R L", "API": "A P I",
    "src": "source", "dst": "destination", "sport": "source port",
    "dport": "destination port", "pcap": "P cap",
    # tools and components
    "nmap": "en map", "Nmap": "en map", "NMAP": "en map", "Nuclei": "new clee eye",
    "nuclei": "new clee eye", "nftables": "N F tables", "WireGuard": "wire guard",
    "wireguard": "wire guard", "nmcli": "N M C L I", "sudo": "sue doo",
    "TTS": "T T S", "LLM": "L L M", "GPU": "G P U", "CPU": "C P U",
    "USB": "U S B", "ISO": "I S O", "UEFI": "U E F I", "BIOS": "bye oss",
    "XFCE": "X F C E", "QEMU": "kemu",
}
# Spellings that are not single words: replaced literally, first.
_SPOKEN_LITERALS: tuple[tuple[str, str], ...] = (
    ("R.A.I.N.", "Rain"), ("ATT&CK", "attack"), ("→", " to "), ("::", " "),
)
_SPOKEN_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    # 10 dot 0 dot 0 dot 5:22 is a time of day to an engine; say the port.
    (re.compile(r"\b(\d{1,3} dot \d{1,3} dot \d{1,3} dot \d{1,3}):(\d{1,5})\b"),
     r"\1 port \2"),
    (re.compile(r"\bsid:(\d+)\b"), r"S I D \1"),
    # ATT&CK technique ids: T1595, T1595.001.
    (re.compile(r"\bT(\d{4})(?:\.(\d{3}))?\b"),
     lambda m: f"T {m.group(1)}" + (f" point {m.group(2)}" if m.group(2) else "")),
    # Zeek notice names: Password_Guessing -> Password Guessing.
    (re.compile(r"(?<=[A-Za-z])_(?=[A-Za-z])"), " "),
)
_SPOKEN_WORD_RE = re.compile(
    r"(?<![A-Za-z0-9])(" + "|".join(
        re.escape(k) for k in sorted(_SPOKEN_FORMS, key=len, reverse=True))
    + r")(?![A-Za-z0-9])")


def spoken_forms(text: str) -> str:
    """Rewrite screen spellings into what the engine should say. Pure."""
    out = str(text)
    for literal, said in _SPOKEN_LITERALS:
        out = out.replace(literal, said)
    for pat, repl in _SPOKEN_PATTERNS:
        out = pat.sub(repl, out)
    return _SPOKEN_WORD_RE.sub(lambda m: _SPOKEN_FORMS[m.group(1)], out)

_NUM_RE = re.compile(r"\d+(?:\.\d+)?")
_WORD_RE = re.compile(r"[A-Za-z][A-Za-z']*")
# Characters a spoken line may contain. Anything else (markdown, brackets,
# backticks, pipes, asterisks, angle brackets) is a rejection, not a strip.
_ALLOWED_CHARS = re.compile(r"^[A-Za-z0-9 .,:;'\-/?!()%_]*$")
_SENTENCE_END = re.compile(r"[.!?]+(?:\s|$)")


# ---------------------------------------------------------------------------
# PURE: facts, prompt, template, validation
# ---------------------------------------------------------------------------

def _flatten(value: Any, out: list[str]) -> None:
    """Collect every scalar in a possibly-nested detail value as a string."""
    if isinstance(value, dict):
        for k, v in value.items():
            out.append(str(k))
            _flatten(v, out)
    elif isinstance(value, (list, tuple, set)):
        for v in value:
            _flatten(v, out)
    elif value is not None and not isinstance(value, bool):
        out.append(str(value))
    elif isinstance(value, bool):
        out.append(str(value))


def _norm_num(tok: str) -> str:
    """'11.0' and '11' are the same number; compare on a canonical form."""
    try:
        f = float(tok)
    except (TypeError, ValueError):
        return tok
    return str(int(f)) if f == int(f) else repr(f)


def event_facts(event: dict[str, Any]) -> dict[str, Any]:
    """Everything the event itself asserts: its words, numbers and addresses.

    This is the ONLY source of truth a spoken line may draw on. It is built
    from the message, the severity/source/category, and every key AND value of
    the structured `detail` — which is exactly what orionx-scanwatch's
    build_detail() publishes, so the narration is anchored to the same
    evidence the Cockpit drill-down shows.
    """
    parts: list[str] = []
    for key in ("message", "severity", "source", "category"):
        v = event.get(key)
        if v is not None:
            parts.append(str(v))
    detail = event.get("detail")
    if isinstance(detail, dict):
        _flatten(detail, parts)
    blob = " ".join(parts)

    words = {w.lower() for w in _WORD_RE.findall(blob)}
    # Split snake_case / kebab-case keys so `distinct_ports` licenses both.
    for chunk in re.split(r"[^A-Za-z]+", blob):
        if chunk:
            words.add(chunk.lower())
    ips = set(_IP_RE.findall(blob))
    nums = {_norm_num(n) for n in _NUM_RE.findall(_IP_RE.sub(" ", blob))}
    # Octets of an event IP are not independently speakable numbers, but the
    # IP itself is; nums deliberately excludes them (the _IP_RE.sub above).
    src_ip = None
    if isinstance(detail, dict) and isinstance(detail.get("src_ip"), str):
        if _IP_RE.fullmatch(detail["src_ip"].strip()):
            src_ip = detail["src_ip"].strip()
    return {"words": words, "numbers": nums, "ips": ips, "src_ip": src_ip}


def build_prompt(event: dict[str, Any]) -> str:
    """The facts, listed. Nothing is asked for that the event does not supply."""
    lines = [
        f"Severity: {rain_lib.normalize_severity(event.get('severity', 'notice'))}",
        f"Source: {event.get('source', 'unknown')}",
        f"Category: {event.get('category', 'general')}",
        f"Message: {event.get('message', '')}",
    ]
    detail = event.get("detail")
    if isinstance(detail, dict):
        for k in sorted(detail):
            if str(k).startswith("_"):
                continue
            v = detail[k]
            if isinstance(v, (list, tuple)):
                v = ", ".join(str(x) for x in list(v)[:8])
            lines.append(f"{k}: {v}")
    lines.append("")
    lines.append("Say this as one spoken sentence using only the facts above.")
    return "\n".join(lines)


def _plural(n: float, word: str) -> str:
    return word if _norm_num(str(n)) == "1" else word + "s"


def template_line(event: dict[str, Any]) -> str:
    """The deterministic narration: event fields in, sentence out, no model.

    This is what gets spoken whenever the model is absent, slow, or rejected —
    which is the common case by design. It is therefore not a stub: it is the
    product. Every token in it is copied from the event; nothing is inferred.
    """
    sev = rain_lib.normalize_severity(event.get("severity", "notice"))
    detail = event.get("detail") if isinstance(event.get("detail"), dict) else {}
    msg = " ".join(str(event.get("message", "")).split())

    src = detail.get("src_ip")
    ports = detail.get("distinct_ports")
    span = detail.get("window_seconds")
    kind = str(detail.get("scan_kind") or "").strip()

    if src and ports is not None:
        head = kind if kind else "scan"
        out = f"{head.capitalize()} from {src}."
        try:
            n = int(ports)
            out += f" {n} {_plural(n, 'port')}"
            if span is not None:
                s = float(span)
                shown = int(s) if s == int(s) else round(s, 1)
                out += f" in {shown} {_plural(shown, 'second')}"
            out += "."
        except (TypeError, ValueError):
            pass
        return out

    sig = detail.get("signature")
    if sig:
        out = f"{sev.capitalize()}. {str(sig).strip()}"
        if src:
            out += f" from {src}"
        return out.rstrip(".") + "."

    if msg:
        return f"{sev.capitalize()}. {msg}"
    return f"{sev.capitalize()}."


def validate_line(text: str | None, event: dict[str, Any]) -> tuple[str | None, str]:
    """The no-fabrication guard. Returns (accepted_text, reason).

    A returned text is one that CANNOT contain a fact the event does not
    already assert. Rejection returns (None, reason) and the caller speaks the
    template instead, so being strict costs nothing and being lax costs an
    operator acting on a sentence the deck invented.

    Checks, in order (each one exists because it closes a specific hole):

      charset   markdown/URLs/brackets are a rejection, not a strip — a model
                that is formatting is a model that is not following the brief.
      length    <= SPEECH_MAX_WORDS words, <= 2 sentences, <= SPEECH_MAX_CHARS.
      ip        every dotted quad must be the event's own src_ip (or, when the
                event has no src_ip, an address the event mentions). This is
                what stops the model re-attributing a scan to the destination
                address, which is the deck itself.
      number    every remaining numeric token must be a number the event
                asserts. Spelled-out numbers cannot be checked against digits,
                so the lexicon contains no number words and "nine hundred" is
                a rejection.
      word      every alphabetic token must be a closed-class function word or
                a word the event itself contains. No generic security noun is
                licensed, so "900 hosts" fails where "900 ports" passes.
    """
    if not text or not str(text).strip():
        return None, "empty"
    flat = " ".join(str(text).split())
    if len(flat) > SPEECH_MAX_CHARS:
        return None, f"too long ({len(flat)} chars)"
    if not _ALLOWED_CHARS.match(flat):
        bad = sorted({c for c in flat if not _ALLOWED_CHARS.match(c)})
        return None, f"disallowed characters {bad}"
    if len(flat.split()) > SPEECH_MAX_WORDS:
        return None, f"too many words ({len(flat.split())})"
    if len(_SENTENCE_END.findall(flat)) > 2:
        return None, "more than two sentences"

    facts = event_facts(event)

    for ip in _IP_RE.findall(flat):
        if facts["src_ip"] is not None:
            if ip != facts["src_ip"]:
                return None, f"address {ip} is not the event source {facts['src_ip']}"
        elif ip not in facts["ips"]:
            return None, f"address {ip} is not in the event"

    stripped = _IP_RE.sub(" ", flat)
    for num in _NUM_RE.findall(stripped):
        if _norm_num(num) not in facts["numbers"]:
            return None, f"number {num} is not in the event"

    allowed_words = facts["words"] | _GENERIC_LEXICON
    for word in _WORD_RE.findall(stripped):
        # A possessive SUFFIX ('s or a bare trailing '), never a character set:
        # rstrip("'s") turned "address" into "addre" and rejected every word
        # ending in s (QA round 1 python P2-9).
        w = re.sub(r"'s?$", "", word.lower())
        if w in allowed_words:
            continue
        if w.endswith("s") and w[:-1] in allowed_words:
            continue        # event says "port", model says "ports"
        if w + "s" in allowed_words:
            continue        # event says "ports", model says "port"
        return None, f"word '{word}' is not in the event or the lexicon"

    return flat, "ok"


def speakable(text: str) -> str:
    """Final shaping for a TTS engine. Applied to template AND model output.

    Dotted quads are expanded ("192 dot 168 dot 4 dot 77") because both piper
    and espeak-ng otherwise read 192.168.4.77 as a decimal number, which is
    the one thing the operator most needs to hear correctly. Acronyms,
    arrows, ports and notice names get their spoken forms (_SPOKEN_FORMS).
    """
    flat = " ".join(str(text).split())
    flat = "".join(c for c in flat if c == " " or c.isprintable())
    flat = _IP_RE.sub(lambda m: " dot ".join(m.group(0).split(".")), flat)
    flat = spoken_forms(flat)                      # #123: after the guard, before the engine
    flat = flat.replace("—", ", ").replace("–", ", ").replace("…", ".")
    flat = " ".join(flat.split())
    if len(flat) <= SPEAK_MAX_CHARS:
        return flat
    cut = flat[:SPEAK_MAX_CHARS]
    end = max(cut.rfind(". "), cut.rfind("; "), cut.rfind(", "))
    if end < SPEAK_MAX_CHARS // 2:
        end = cut.rfind(" ")
    if end <= 0:
        end = SPEAK_MAX_CHARS
    return cut[:end].rstrip(" ,;.") + "."


def narration_for(event: dict[str, Any],
                  transport: Callable[[str], str | None] | None = None,
                  ) -> tuple[str, str, str]:
    """Decide what to say. Returns (spoken_text, provenance, reason).

    provenance is "model" or "template" — never anything else, because those
    are the only two sources of words this subsystem has.
    """
    fallback = speakable(template_line(event))
    if transport is None:
        return fallback, "template", "no transport"
    try:
        raw = transport(build_prompt(event))
    except Exception as exc:                        # noqa: BLE001
        return fallback, "template", f"transport error: {type(exc).__name__}"
    accepted, reason = validate_line(raw, event)
    if accepted is None:
        return fallback, "template", reason
    return speakable(accepted), "model", "ok"


# ---------------------------------------------------------------------------
# EFFECTS: Nebula transport (best-effort, never gates anything)
# ---------------------------------------------------------------------------

def ollama_generate(prompt: str, base_url: str = NEBULA_URL,
                    timeout: float = SPEECH_TIMEOUT) -> str | None:
    """One non-streaming completion from the on-box model. None on any failure.

    Deliberately a separate implementation from orionx-postured's: different
    system prompt, a 6s budget instead of 20s, and a 48-token cap. The only
    fact shared with postured is the URL, and a drift test asserts it.
    """
    import urllib.error  # noqa: PLC0415
    import urllib.request  # noqa: PLC0415
    import json as _json  # noqa: PLC0415
    try:
        with urllib.request.urlopen(  # noqa: S310 - fixed localhost URL
            urllib.request.Request(f"{base_url}/api/tags", method="GET"),
            timeout=NEBULA_PROBE_TIMEOUT,
        ) as resp:
            models = (_json.loads(resp.read().decode("utf-8")).get("models") or [])
        if not models:
            return None
        model = str(models[0].get("name", ""))
        if not model:
            return None
        payload = _json.dumps({
            "model": model, "prompt": prompt, "system": SPEECH_SYSTEM,
            "stream": False,
            "options": {"temperature": 0.1, "num_predict": NEBULA_NUM_PREDICT},
        }).encode("utf-8")
        req = urllib.request.Request(
            f"{base_url}/api/generate", data=payload, method="POST",
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            obj = _json.loads(resp.read().decode("utf-8", errors="replace"))
        text = obj.get("response") if isinstance(obj, dict) else None
        return text.strip() if isinstance(text, str) and text.strip() else None
    except (urllib.error.URLError, urllib.error.HTTPError, OSError,
            ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# EFFECTS: text to sound
#
# Piper is NOT on the image. It is a build-time dependency of the guided demo
# (tools/guided-demo/container-setup.sh pip-installs piper-tts into the build
# container). Shipping it would cost the en_US-lessac-medium voice model plus
# onnxruntime and numpy. espeak-ng is ALREADY in
# iso/config/package-lists/orionx.list.chroot and costs zero additional bytes,
# so it is the shipped backend; piper is detected and preferred when an
# operator has installed it via /opt/orionx/optional/install-piper-voice.sh.
# ---------------------------------------------------------------------------

VOICE_BASENAME = "en_US-lessac-medium.onnx"
# Same precedence as install-piper-voice.sh: ORIONX_VOICE_DIR is the
# installer's override (a voice on a persistence volume is then found by both
# sides, #122 root cause 3); ORIONX_PIPER_VOICE names one file for tests and
# experiments. A voice is only a voice WITH its .json sidecar: piper refuses
# to load the .onnx alone, so finding the model by itself used to select piper
# and then fail every line.
PIPER_VOICE_PATHS = (
    os.environ.get("ORIONX_PIPER_VOICE", ""),
    (os.path.join(os.environ["ORIONX_VOICE_DIR"], VOICE_BASENAME)
     if os.environ.get("ORIONX_VOICE_DIR") else ""),
    "/usr/share/orionx/voices/" + VOICE_BASENAME,
    "/opt/orionx/voices/" + VOICE_BASENAME,
)
SPEECH_SCRATCH = Path("/run/orionx/speech")
SPEECH_SOURCE = "rain"          # the daemon must never narrate its own events

# Sentinel for "use the module default" in Narrator, distinct from None.
_DEFAULT = object()


def piper_voice() -> str | None:
    """Path to an installed piper voice model (with its .json sidecar), or None."""
    for cand in PIPER_VOICE_PATHS:
        if cand and Path(cand).is_file() and Path(cand + ".json").is_file():
            return cand
    return None


def tts_backend() -> str | None:
    """'piper', 'espeak-ng', or None when the deck cannot speak at all."""
    if shutil.which("piper") and piper_voice():
        return "piper"
    if shutil.which("espeak-ng"):
        return "espeak-ng"
    return None


# The flags piper is RUN with. The installer's synthesis check uses the same
# ones (install-piper-voice.sh PIPER_ARGS), so "verified" means verified with
# the flags that will be used, not with piper's defaults (#122 root cause 5).
PIPER_ARGS = ("--length-scale", "1.04", "--sentence-silence", "0.25")
# espeak-ng words per minute. 160 is a touch slower than default, which matters
# for an address read out as digits. Also the basis of the spoken-time estimate.
ESPEAK_WPM = 160
# How long after the audio should end we wait before killing the player.
PLAYBACK_MARGIN_SECONDS = 3.0
# Narrations are short by construction (SPEAK_MAX_CHARS); no legitimate one
# plays for a minute. A cap keeps a wedged player from holding the thread.
PLAYBACK_MAX_SECONDS = 60.0


def wav_seconds(path: str) -> float | None:
    """Duration of a WAV file in seconds, or None if it is not a playable WAV."""
    try:
        with wave.open(path, "rb") as w:
            frames, rate = w.getnframes(), w.getframerate()
        if frames <= 0 or rate <= 0:
            return None
        return frames / float(rate)
    except (OSError, EOFError, wave.Error):
        return None


def estimated_seconds(text: str) -> float:
    """Spoken length of `text` at ESPEAK_WPM, plus a one-second tail."""
    return len(str(text).split()) / (ESPEAK_WPM / 60.0) + 1.0


def playback_timeout(wav: str | None, text: str) -> float:
    """How long the player may run: measured from the WAV when there is one.

    #122 root cause 2: rain_lib._run used to kill every player after 10 s while
    SPEAK_MAX_CHARS allows ~20 s of speech, so long narrations were cut
    mid-sentence and counted as not spoken. The timeout now follows the audio.
    """
    secs = wav_seconds(wav) if wav else None
    if secs is None:
        secs = estimated_seconds(text)
    return max(5.0, min(PLAYBACK_MAX_SECONDS, secs + PLAYBACK_MARGIN_SECONDS))


def synthesize_piper(line: str, voice: str, wav: str) -> str | None:
    """Run piper into `wav`. Returns None on success, else one sentence of why."""
    try:
        proc = subprocess.run(
            ["piper", "-m", voice, "-f", wav, *PIPER_ARGS],
            input=line, text=True, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, check=False, timeout=TTS_TIMEOUT)
    except subprocess.TimeoutExpired:
        return f"piper timed out after {TTS_TIMEOUT:.0f}s"
    except OSError as exc:
        return f"piper could not be run ({exc.strerror or exc})"
    if proc.returncode != 0:
        tail = (proc.stderr or "").strip().splitlines()
        why = f"piper exited {proc.returncode}"
        return f"{why}: {tail[-1][:120]}" if tail else why
    if wav_seconds(wav) is None:
        return "piper wrote no audio"
    return None


def synthesize_espeak(line: str, wav: str) -> str | None:
    """Run espeak-ng into `wav`. Returns None on success, else one sentence of why.

    The one espeak-ng render path (probe, --speech-test and the live fallback
    all use it), so the time it is measured at is the time the deck pays.
    """
    try:
        proc = subprocess.run(
            ["espeak-ng", "-w", wav, "-s", str(ESPEAK_WPM), "--", line],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False, timeout=TTS_TIMEOUT)
    except subprocess.TimeoutExpired:
        return f"espeak-ng timed out after {TTS_TIMEOUT:.0f}s"
    except (OSError, subprocess.SubprocessError) as exc:
        return f"espeak-ng could not be run ({exc})"
    if proc.returncode != 0:
        return f"espeak-ng exited {proc.returncode}"
    if wav_seconds(wav) is None:
        return "espeak-ng wrote no audio"
    return None


def voice_name(voice: str | None) -> str | None:
    """'/usr/share/orionx/voices/en_US-lessac-medium.onnx' -> 'en_US-lessac-medium'."""
    if not voice:
        return None
    base = os.path.basename(str(voice))
    return base[:-5] if base.endswith(".onnx") else base


def piper_voices_present() -> list[str]:
    """Every installed piper voice (an .onnx WITH its .json sidecar), by name.

    Looks in the same places piper_voice() does, plus the directory of an
    explicitly named voice, so the step-3 choice in #96 (medium vs low) can be
    made from `--speech-test` output on the deck rather than guessed from the
    build host. Sorted, de-duplicated; empty when piper has nothing to load.
    """
    dirs: list[Path] = []
    named = os.environ.get("ORIONX_PIPER_VOICE", "")
    if named:
        dirs.append(Path(named).parent)
    for cand in PIPER_VOICE_PATHS[1:]:
        if cand:
            dirs.append(Path(cand).parent)
    found: set[str] = set()
    for d in dirs:
        try:
            for onnx in d.glob("*.onnx"):
                if onnx.is_file() and (onnx.parent / (onnx.name + ".json")).is_file():
                    found.add(voice_name(str(onnx)) or onnx.name)
        except OSError:
            continue
    return sorted(found)


def timing_sample(engine: str, voice: str | None, chars: int, synth_s: float,
                  audio_s: float | None, ok: bool, reason: str | None = None,
                  kind: str = "alert", ts: float | None = None) -> dict[str, Any]:
    """The one shape a synthesis measurement has, wherever it was taken.

    `kind` says who measured it: "alert" (the daemon, a real narration),
    "test" (--speech-test), "probe" (--speech-status). All three are the same
    engine doing the same work on the same hardware, so they pool into one
    history; the kind is kept so the operator can see the mix.
    """
    return {
        "ts": float(time.time() if ts is None else ts),
        "kind": kind, "engine": engine, "voice": voice_name(voice),
        "chars": int(chars), "synth_s": round(float(synth_s), 3),
        "audio_s": (round(float(audio_s), 3) if audio_s is not None else None),
        "ok": bool(ok), "reason": reason,
    }


def format_timing(sample: dict[str, Any], **extra: Any) -> str:
    """One fixed, grep-able line per measurement (paste-able into #96).

    SPEECH_TIMING engine=piper voice=en_US-lessac-medium chars=62 synth_s=1.84 audio_s=4.10 ok=true
    """
    parts = [
        "SPEECH_TIMING",
        f"engine={sample.get('engine') or '-'}",
        f"voice={sample.get('voice') or '-'}",
        f"chars={int(sample.get('chars') or 0)}",
        f"synth_s={float(sample.get('synth_s') or 0.0):.2f}",
    ]
    audio = sample.get("audio_s")
    parts.append(f"audio_s={float(audio):.2f}" if audio is not None else "audio_s=-")
    parts.append(f"ok={'true' if sample.get('ok') else 'false'}")
    for k, v in extra.items():
        parts.append(f"{k}={v}")
    if not sample.get("ok") and sample.get("reason"):
        parts.append(f"reason={json.dumps(str(sample['reason']))}")
    return " ".join(parts)


def format_voices(present: list[str], active: str | None) -> str:
    """PIPER_VOICES present=en_US-lessac-medium active=en_US-lessac-medium medium=yes low=no"""
    names = ",".join(present) if present else "-"
    has = {q: any(n.endswith("-" + q) for n in present) for q in ("medium", "low")}
    return (f"PIPER_VOICES present={names} active={voice_name(active) or '-'} "
            f"medium={'yes' if has['medium'] else 'no'} low={'yes' if has['low'] else 'no'}")


PROBE_LINE = "Port scan from 192 dot 168 dot 4 dot 77, 900 ports in 11 seconds."
# A line with (almost) nothing to say. Its synth time is the engine's fixed
# per-utterance cost (process start, model load); the difference between it
# and PROBE_LINE is the per-character cost. Those two numbers are what decide
# between the #96 mitigations (see DEC-PHASE13-050).
PROBE_LINE_SHORT = "Critical."


def probe_synthesis(backend: str | None = None, line: str = PROBE_LINE,
                    kind: str = "probe") -> dict[str, Any]:
    """Time one real synthesis without playing it (--speech-status, --speech-test).

    Presence of a binary and a model file is not evidence that the deck can
    speak (#122, RESILIENCE rule 3); a WAV with audio in it is. The result
    carries a `sample` (timing_sample) so the caller can record it.
    """
    backend = backend or tts_backend()
    out: dict[str, Any] = {"backend": backend, "ok": False, "seconds": 0.0,
                           "audio_seconds": 0.0, "reason": None, "voice": None,
                           "chars": len(line), "sample": None}
    if backend is None:
        out["reason"] = "no text-to-speech engine installed"
        return out
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as fh:
            wav = fh.name
    except OSError as exc:
        out["reason"] = f"cannot create a scratch WAV ({exc.strerror or exc})"
        return out
    try:
        voice = None
        if backend == "piper":
            voice = piper_voice()
            if not voice:
                out["reason"] = ("piper is installed but no voice model with its "
                                 ".json sidecar was found")
                return out
            out["voice"] = voice
        t0 = time.monotonic()
        why = (synthesize_piper(line, voice, wav) if backend == "piper"
               else synthesize_espeak(line, wav))
        out["seconds"] = time.monotonic() - t0
        out["ok"] = why is None
        out["reason"] = why
        if why is None:
            out["audio_seconds"] = wav_seconds(wav) or 0.0
        out["sample"] = timing_sample(
            backend, voice, len(line), out["seconds"],
            out["audio_seconds"] if why is None else None, why is None, why, kind)
        return out
    finally:
        try:
            os.unlink(wav)
        except OSError:
            pass


def _scratch_wav() -> str | None:
    try:
        SPEECH_SCRATCH.mkdir(parents=True, exist_ok=True)
        scratch = str(SPEECH_SCRATCH)
    except OSError:
        scratch = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".wav", dir=scratch,
                                         delete=False) as fh:
            return fh.name
    except OSError:
        return None


def _play_wav(wav: str, vol: float, timeout: float) -> bool:
    if shutil.which("paplay"):
        return rain_lib._run(["paplay", f"--volume={int(vol * 65536)}", wav],
                             timeout=timeout)
    if shutil.which("aplay"):
        return rain_lib._run(["aplay", "-q", wav], timeout=timeout)
    return False


def _speak_espeak(line: str, vol: float) -> bool:
    # -a 0..200 amplitude, -s words/min.
    return rain_lib._run(
        ["espeak-ng", "-a", str(int(vol * 200)), "-s", str(ESPEAK_WPM), "--", line],
        timeout=playback_timeout(None, line))


def _speak_espeak_measured(line: str, vol: float, samples: list[dict[str, Any]]) -> bool:
    """espeak-ng, rendered to a WAV first so its synth time is measured (#96).

    Render-then-play is the path piper already takes, so this is one playback
    path (_play_wav, WAV-derived timeout) for both engines rather than two.
    Without a WAV player, or if the render fails, espeak-ng speaks directly
    as before — unmeasured, but never silent for want of a number.
    """
    if shutil.which("paplay") or shutil.which("aplay"):
        wav = _scratch_wav()
        if wav is not None:
            try:
                t0 = time.monotonic()
                why = synthesize_espeak(line, wav)
                dt = time.monotonic() - t0
                samples.append(timing_sample(
                    "espeak-ng", None, len(line), dt,
                    wav_seconds(wav) if why is None else None, why is None, why))
                if why is None:
                    return _play_wav(wav, vol, playback_timeout(wav, line))
            finally:
                try:
                    os.unlink(wav)
                except OSError:
                    pass
    return _speak_espeak(line, vol)


def speak_measured(text: str, cfg: dict[str, Any] | None = None,
                   backend: str | None = None,
                   ) -> tuple[bool, str | None, list[dict[str, Any]]]:
    """Say one line. Returns (spoken, degradation, timing_samples).

    `spoken` is True only if a player actually ran. `degradation` is None when
    the chosen engine did the work, otherwise one sentence saying what piper
    did wrong so the Narrator can tell the operator once (#122 root cause 1:
    a failing piper used to cost the line silently and never reach espeak-ng).
    `timing_samples` holds one timing_sample() per engine that was RUN —
    a piper that timed out AND the espeak-ng that then spoke are both
    evidence for #96, so both are returned.
    """
    cfg = cfg or rain_lib.default_config()
    samples: list[dict[str, Any]] = []
    line = speakable(text)
    if not line:
        return False, None, samples
    backend = backend or tts_backend()
    vol = max(0.0, min(1.0, float(cfg.get("volume", 0.8))))

    if backend == "piper":
        voice = piper_voice()
        if not voice:
            why: str | None = ("piper is installed but no voice model with its "
                               ".json sidecar was found")
        else:
            wav = _scratch_wav()
            if wav is None:
                why = f"cannot write a scratch WAV under {SPEECH_SCRATCH}"
            else:
                try:
                    t0 = time.monotonic()
                    why = synthesize_piper(line, voice, wav)
                    dt = time.monotonic() - t0
                    samples.append(timing_sample(
                        "piper", voice, len(line), dt,
                        wav_seconds(wav) if why is None else None, why is None, why))
                    if why is None:
                        return _play_wav(wav, vol, playback_timeout(wav, line)), None, samples
                finally:
                    try:
                        os.unlink(wav)
                    except OSError:
                        pass
        if shutil.which("espeak-ng"):
            return _speak_espeak_measured(line, vol, samples), why, samples
        return False, f"{why}; espeak-ng is not installed, so the line was lost", samples

    if backend == "espeak-ng":
        return _speak_espeak_measured(line, vol, samples), None, samples

    return False, None, samples


def speak_with_fallback(text: str, cfg: dict[str, Any] | None = None,
                        backend: str | None = None) -> tuple[bool, str | None]:
    """Say one line. Returns (spoken, degradation); see speak_measured()."""
    spoken, why, _samples = speak_measured(text, cfg, backend)
    return spoken, why


class SpeakResult(int):
    """What speak() returns: truthy when a player ran, like the bool it used to
    be, plus `.why` naming the degradation when piper failed and espeak-ng
    spoke instead (None otherwise) and `.timing`, the timing_sample() list of
    every engine that ran (#96). An int subclass so every existing caller and
    test double that treats the result as a bool keeps working."""
    why: str | None
    timing: list[dict[str, Any]]

    def __new__(cls, spoken: bool, why: str | None = None,
                timing: list[dict[str, Any]] | None = None) -> "SpeakResult":
        obj = super().__new__(cls, 1 if spoken else 0)
        obj.why = why
        obj.timing = list(timing or [])
        return obj

    def __repr__(self) -> str:
        return f"SpeakResult({bool(self)}, why={self.why!r}, timing={self.timing!r})"


def speak(text: str, cfg: dict[str, Any] | None = None,
          backend: str | None = None) -> SpeakResult:
    """Say one line. Truthy only if a TTS process actually ran; see SpeakResult."""
    return SpeakResult(*speak_measured(text, cfg, backend))


# ---------------------------------------------------------------------------
# Synthesis timing history (#96)
#
# @decision DEC-PHASE13-050
# @title Measure narration synth time on the deck before choosing a latency fix
# @status proposed
# @rationale The reference deck (Lenovo, Bay Trail Atom) narrates slowly and
#   sometimes not at all. Items that take too long are dropped as stale by
#   design (SPEECH_MAX_AGE_SECONDS, DEC-PHASE12-046 rule 3), so "sometimes
#   silent" is the designed failure mode when synthesis is too slow -- but
#   synthesis time was never measured on the hardware we ship for; the "~1-2s"
#   in the SPEECH_QUEUE_MAX comment is a build-host estimate. This decision
#   instruments first and defers the mitigation choice to the numbers:
#   SpeechStats keeps the last SPEECH_HISTORY_MAX synth samples (engine, voice,
#   chars, wall-clock synth seconds, kind) and every stale drop with the age
#   that caused it, in ONE per-session file ($XDG_RUNTIME_DIR/orionx/
#   speech-timing.json -- /run/orionx is 0755 root:root, DEC-PHASE11-022, so
#   the session daemon cannot write there), read back by
#   `orionx-rain --speech-status` and fed by the daemon, --speech-test and the
#   status probe alike. `--speech-test --all-engines` times piper and espeak-ng
#   on a one-word line and the full probe line, which separates the fixed
#   per-utterance cost (process start, ONNX model load) from the per-character
#   cost. The three candidate mitigations from #96, and the deck numbers that
#   would pick each (all medians over three --all-engines runs):
#     (a) en_US-lessac-low voice (roughly 4x fewer parameters): piper FULL-line
#         median > ~6s with the SHORT line well under half of it, i.e. the
#         per-character (model) cost dominates; espeak-ng under 1s is the
#         fallback if a low voice is still projected over ~6s. Verdict "TIGHT"
#         or "OVER BUDGET" with a small short/full ratio points here.
#     (b) pre-warm / keep the ONNX session resident: SHORT-line median is the
#         bulk of the FULL-line median (fixed cost dominates), so model load
#         per spawned `piper` process is what is being paid. Keep medium.
#     (c) pre-rendered WAV for the fixed template fragments (severity word,
#         "from", digits): both costs are moderate but FULL-line synth plus
#         SPEECH_TIMEOUT exceeds SPEECH_MAX_AGE_SECONDS only on long lines --
#         chars-per-second from the two lines projects a shortened variable
#         part back inside the budget.
#   If the piper medium median is already inside ~3s with zero stale drops,
#   no mitigation is taken and this decision is closed as "measured, within
#   budget". Status stays "proposed" until the deck numbers are pasted into
#   #96 and the choice is recorded here as accepted.
# ---------------------------------------------------------------------------

# Bounded history: enough to take a median that is not one cold start, small
# enough that the file is a few KB and a read is instant.
SPEECH_HISTORY_MAX = 20
STATE_VERSION = 1


def speech_state_path() -> Path:
    """Where the synth-timing history lives. ONE resolution for writer and reader.

    ORIONX_SPEECH_STATE (tests, experiments) > $XDG_RUNTIME_DIR/orionx (the
    per-session tmpfs the daemon itself lives in) > ~/.cache/orionx (no
    session manager). Resolved at call time, never at import, so a test that
    sets the environment before constructing a Narrator is honoured.
    """
    override = os.environ.get("ORIONX_SPEECH_STATE", "")
    if override:
        return Path(override)
    run = os.environ.get("XDG_RUNTIME_DIR", "")
    if run:
        return Path(run) / "orionx" / "speech-timing.json"
    try:
        home = Path.home()
    except (RuntimeError, KeyError):
        home = Path(tempfile.gettempdir())
    return home / ".cache" / "orionx" / "speech-timing.json"


def _empty_state() -> dict[str, Any]:
    return {"version": STATE_VERSION, "updated": 0.0, "synth": [],
            "stale": {"count": 0, "max_age_s": None, "recent": []}}


def _coerce_state(obj: Any) -> dict[str, Any]:
    """Whatever was on disk, shaped so every reader can index it safely."""
    state = _empty_state()
    if not isinstance(obj, dict):
        return state
    synth = obj.get("synth")
    if isinstance(synth, list):
        state["synth"] = [s for s in synth if isinstance(s, dict)][-SPEECH_HISTORY_MAX:]
    stale = obj.get("stale")
    if isinstance(stale, dict):
        try:
            state["stale"]["count"] = max(0, int(stale.get("count", 0)))
        except (TypeError, ValueError):
            pass
        mx = stale.get("max_age_s")
        state["stale"]["max_age_s"] = float(mx) if isinstance(mx, (int, float)) else None
        recent = stale.get("recent")
        if isinstance(recent, list):
            state["stale"]["recent"] = [r for r in recent if isinstance(r, dict)][-SPEECH_HISTORY_MAX:]
    try:
        state["updated"] = float(obj.get("updated", 0.0))
    except (TypeError, ValueError):
        pass
    return state


class SpeechStats:
    """The synth-timing history: one file, rewritten in place under flock.

    Never raises: a missing directory, a read-only filesystem or a torn file
    costs a measurement, never a narration (the same contract as duck_music).
    In-place rewrite under an exclusive lock (not write-tmp-then-rename) so a
    concurrent --speech-test and the daemon serialise on one inode and neither
    overwrites the other's sample with a stale read.
    """

    def __init__(self, path: Path | str | None = None):
        self.path = Path(path) if path is not None else speech_state_path()

    @staticmethod
    def _lock(fd: int, flag: int) -> None:
        if fcntl is not None:
            fcntl.flock(fd, flag)

    def load(self) -> dict[str, Any]:
        try:
            fd = os.open(str(self.path), os.O_RDONLY)
        except OSError:
            return _empty_state()
        try:
            self._lock(fd, fcntl.LOCK_SH if fcntl else 0)
            raw = b""
            while True:
                chunk = os.read(fd, 1 << 16)
                if not chunk:
                    break
                raw += chunk
        except OSError:
            return _empty_state()
        finally:
            os.close(fd)
        try:
            return _coerce_state(json.loads(raw.decode("utf-8")))
        except (ValueError, UnicodeDecodeError):
            return _empty_state()

    def _update(self, mutate: Callable[[dict[str, Any]], None]) -> bool:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o644)
        except OSError:
            return False
        try:
            self._lock(fd, fcntl.LOCK_EX if fcntl else 0)
            raw = b""
            while True:
                chunk = os.read(fd, 1 << 16)
                if not chunk:
                    break
                raw += chunk
            try:
                state = _coerce_state(json.loads(raw.decode("utf-8"))) if raw else _empty_state()
            except (ValueError, UnicodeDecodeError):
                state = _empty_state()
            mutate(state)
            state["version"] = STATE_VERSION
            state["updated"] = time.time()
            data = json.dumps(state, ensure_ascii=False, indent=1).encode("utf-8")
            os.lseek(fd, 0, os.SEEK_SET)
            written = os.write(fd, data)
            os.ftruncate(fd, written)
            return True
        except (OSError, TypeError, ValueError):
            return False
        finally:
            os.close(fd)

    def record_synth(self, sample: dict[str, Any]) -> bool:
        """Append one timing_sample(); the history keeps the last SPEECH_HISTORY_MAX."""
        if not isinstance(sample, dict) or not sample.get("engine"):
            return False

        def mutate(state: dict[str, Any]) -> None:
            state["synth"] = (state["synth"] + [dict(sample)])[-SPEECH_HISTORY_MAX:]
        return self._update(mutate)

    def record_stale(self, age_s: float, ts: float | None = None) -> bool:
        """Count a drop-as-stale and keep the age that caused it."""
        try:
            age = float(age_s)
        except (TypeError, ValueError):
            return False

        def mutate(state: dict[str, Any]) -> None:
            st = state["stale"]
            st["count"] = int(st.get("count", 0)) + 1
            mx = st.get("max_age_s")
            st["max_age_s"] = age if mx is None else max(float(mx), age)
            st["recent"] = (st.get("recent", []) + [
                {"ts": float(time.time() if ts is None else ts), "age_s": round(age, 3)}
            ])[-SPEECH_HISTORY_MAX:]
        return self._update(mutate)


def timing_verdict(median_s: float | None) -> dict[str, Any]:
    """Is a median synth time inside the budgets? Pure; the numbers are the module's.

    inside_tts_timeout  median <= TTS_TIMEOUT (a render that long is killed)
    inside_max_age      median <= SPEECH_MAX_AGE_SECONDS (dropped as stale)
    tight               inside both, but a model answer that uses its whole
                        SPEECH_TIMEOUT plus this render would miss the shelf
                        life -- the "sometimes silent" zone of #96.
    verdict             "NO DATA" | "OK" | "TIGHT" | "OVER BUDGET"
    """
    if median_s is None:
        return {"verdict": "NO DATA", "inside_tts_timeout": None,
                "inside_max_age": None, "tight": None}
    m = float(median_s)
    inside_tts = m <= TTS_TIMEOUT
    inside_age = m <= SPEECH_MAX_AGE_SECONDS
    tight = inside_tts and inside_age and (SPEECH_TIMEOUT + m) > SPEECH_MAX_AGE_SECONDS
    verdict = "OK" if (inside_tts and inside_age) else "OVER BUDGET"
    if tight:
        verdict = "TIGHT"
    return {"verdict": verdict, "inside_tts_timeout": inside_tts,
            "inside_max_age": inside_age, "tight": tight}


def summarize_timing(state: dict[str, Any], engine: str | None = None) -> dict[str, Any]:
    """Reduce the history to what --speech-status prints. Pure.

    The median and verdict are per engine (`engine`, else the engine of the
    most recent sample): a piper deck's history may also hold espeak-ng
    probes, and mixing the two would make both numbers meaningless. Failed
    samples (timeouts, crashes) are counted but excluded from the median; a
    timeout is already the strongest possible evidence and is reported as such.
    """
    samples = [s for s in state.get("synth", []) if isinstance(s, dict)]
    good = [s for s in samples
            if s.get("ok") and isinstance(s.get("synth_s"), (int, float)) and s.get("engine")]
    by_engine: dict[str, list[dict[str, Any]]] = {}
    for s in good:
        by_engine.setdefault(str(s["engine"]), []).append(s)
    if engine is None and samples:
        engine = str(samples[-1].get("engine") or "") or None
    mine = by_engine.get(engine or "", [])
    median = statistics.median([float(s["synth_s"]) for s in mine]) if mine else None
    kinds: dict[str, int] = {}
    for s in samples:
        k = str(s.get("kind") or "alert")
        kinds[k] = kinds.get(k, 0) + 1
    failed = [s for s in samples if not s.get("ok")]
    stale = state.get("stale") or {}
    out = {
        "engine": engine,
        "count": len(samples),
        "ok_count": len(mine),
        "failed": len(failed),
        "timeouts": sum(1 for s in failed if "timed out" in str(s.get("reason") or "")),
        "kinds": kinds,
        "last": mine[-1] if mine else None,
        "median_s": median,
        "engines": {
            e: {"n": len(v), "last_s": float(v[-1]["synth_s"]),
                "median_s": statistics.median([float(s["synth_s"]) for s in v]),
                "voice": v[-1].get("voice")}
            for e, v in sorted(by_engine.items())
        },
        "stale_count": int(stale.get("count", 0) or 0),
        "stale_max_age_s": stale.get("max_age_s"),
        "stale_recent": list(stale.get("recent", []) or []),
    }
    out.update(timing_verdict(median))
    return out


# ---------------------------------------------------------------------------
# EFFECTS: the Narrator — bounded, non-blocking, drop-don't-queue
# ---------------------------------------------------------------------------

NO_TTS_MESSAGE = (
    "R.A.I.N. speech is ON but this deck has no text-to-speech engine, so "
    "alerts are TONE-ONLY. Detection and the cues are unaffected. Fix: "
    "sudo apt-get install -y espeak-ng  (or, for the natural voice, "
    "sudo /opt/orionx/optional/install-piper-voice.sh). "
    "Check with: orionx-rain --speech-status"
)
PIPER_FALLBACK_MESSAGE = (
    "R.A.I.N. speech: the piper voice failed ({why}). Alerts are spoken by "
    "espeak-ng instead; detection and the cues are unaffected. Check with: "
    "orionx-rain --speech-status  Repair: "
    "sudo /opt/orionx/optional/install-piper-voice.sh --force"
)
NO_MODEL_MESSAGE = (
    "R.A.I.N. speech is using built-in phrasing: Nebula did not answer within "
    f"{SPEECH_TIMEOUT:.0f}s. Alerts are still spoken from the event's own "
    "fields. Check with: nebula status"
)


class Narrator:
    """Speaks events on a worker thread. Subordinate to one rule: the cue wins.

    offer() is called by orionx-rain AFTER rain_lib.play_cue() has already
    returned, and is a single non-blocking put. There is no path by which this
    class can delay, suppress or replace a tone.
    """

    def __init__(self, transport: Any = _DEFAULT, speaker: Any = _DEFAULT,
                 emitter: Any = _DEFAULT, clock: Any = _DEFAULT,
                 backend_probe: Any = _DEFAULT, stats: Any = _DEFAULT,
                 maxsize: int = SPEECH_QUEUE_MAX):
        # Collaborators are resolved HERE, not in the signature: a default
        # bound at def-time cannot be monkeypatched, and every claim this
        # subsystem makes has to be testable with a fake model and a fake
        # speaker. _DEFAULT (not None) is the sentinel because `transport=None`
        # is a meaningful value — it means "no model, template only".
        self.transport = ollama_generate if transport is _DEFAULT else transport
        self.speaker = speak if speaker is _DEFAULT else speaker
        self.emitter = rain_lib.emit_event if emitter is _DEFAULT else emitter
        self.clock = time.time if clock is _DEFAULT else clock
        self.backend_probe = tts_backend if backend_probe is _DEFAULT else backend_probe
        # Synth-timing history (#96, DEC-PHASE13-050). None disables recording.
        self.stats = SpeechStats() if stats is _DEFAULT else stats
        self._q: Queue = Queue(maxsize=maxsize)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_spoken = 0.0
        self._no_tts_announced = False
        self._no_model_announced = False
        self._piper_fallback_announced = False
        # Counters, so a storm is provable rather than asserted.
        self.spoken = 0
        self.dropped_rate = 0
        self.dropped_full = 0
        self.dropped_stale = 0
        self.dropped_self = 0
        self.from_model = 0
        self.from_template = 0

    # -- rate limit: one authority, two call sites ---------------------------
    def _gap_ok(self, now: float) -> bool:
        return (now - self._last_spoken) >= SPEECH_MIN_GAP_SECONDS

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="rain-speech",
                                        daemon=True)
        self._thread.start()

    def stop(self, join: float = 0.0) -> None:
        self._stop.set()
        try:
            self._q.put_nowait(None)
        except Full:
            pass
        t, self._thread = self._thread, None
        if t is not None and join:
            t.join(timeout=join)

    def offer(self, event: dict[str, Any]) -> bool:
        """Queue an event for narration. NEVER blocks. False if dropped."""
        if str(event.get("source", "")) == SPEECH_SOURCE:
            self.dropped_self += 1       # no self-narration feedback loop
            return False
        if not self._gap_ok(self.clock()):
            self.dropped_rate += 1
            return False
        try:
            self._q.put_nowait(event)
            return True
        except Full:
            self.dropped_full += 1
            return False

    def _announce_once(self, flag: str, severity: str, message: str) -> None:
        if getattr(self, flag):
            return
        setattr(self, flag, True)
        try:
            # `tooling`: this is the deck describing itself, not a threat
            # (rain_lib.STATUS_CATEGORIES / DEC-PHASE12-040).
            self.emitter(severity, SPEECH_SOURCE, "tooling", message)
        except Exception:                            # noqa: BLE001
            pass

    def narrate(self, event: dict[str, Any]) -> bool:
        """Produce and say one line. Returns True if something was spoken."""
        if self.backend_probe() is None:
            self._announce_once("_no_tts_announced", "notice", NO_TTS_MESSAGE)
            return False
        text, provenance, reason = narration_for(event, self.transport)
        if provenance == "model":
            self.from_model += 1
        else:
            self.from_template += 1
            if reason in ("empty", "no transport") or reason.startswith("transport error"):
                self._announce_once("_no_model_announced", "info", NO_MODEL_MESSAGE)
        ok, why = False, None
        # Hold the music for as long as this line will take (DEC-PHASE12-044):
        # the same ESPEAK_WPM estimate the playback timeout uses, capped at
        # PLAYBACK_MAX_SECONDS. Best-effort: duck_music never raises, and a
        # failure here costs music, never the alert.
        try:
            rain_lib.duck_music(min(PLAYBACK_MAX_SECONDS, estimated_seconds(text)))
        except Exception:                            # noqa: BLE001
            pass
        try:
            result = self.speaker(text, rain_lib.load_config())
        except Exception:                            # noqa: BLE001
            result = False
        # A speaker returns a SpeakResult (speak), the (spoken, degradation)
        # pair of speak_with_fallback, or a bare bool (test doubles).
        if isinstance(result, tuple):
            ok, why = bool(result[0]), (result[1] if len(result) > 1 else None)
        else:
            ok, why = bool(result), getattr(result, "why", None)
        if why:
            self._announce_once("_piper_fallback_announced", "notice",
                                PIPER_FALLBACK_MESSAGE.format(why=why))
        # Every engine that ran is a measurement (#96). Best-effort: a failed
        # write costs a number, never the alert.
        if self.stats is not None:
            for sample in getattr(result, "timing", None) or []:
                try:
                    self.stats.record_synth(sample)
                except Exception:                    # noqa: BLE001
                    pass
        if ok:
            self.spoken += 1
            self._last_spoken = self.clock()
        return ok

    def pump_one(self, block: float = 0.5) -> str:
        """Process at most one queued event. Returns what happened.

        Split out of _run so the bounds can be tested deterministically with
        an injected clock instead of by sleeping and hoping. _run is then a
        three-line loop with nothing in it worth testing.
        """
        try:
            event = self._q.get(timeout=block) if block else self._q.get_nowait()
        except Empty:
            return "idle"
        if event is None:
            return "stop"
        now = self.clock()
        try:
            age = now - float(event.get("ts", now))
        except (TypeError, ValueError):
            age = 0.0
        if age > SPEECH_MAX_AGE_SECONDS:
            self.dropped_stale += 1      # narrating the past is worse than silence
            if self.stats is not None:   # ...and the age that caused it is evidence (#96)
                try:
                    self.stats.record_stale(age, now)
                except Exception:                    # noqa: BLE001
                    pass
            return "stale"
        if not self._gap_ok(now):
            self.dropped_rate += 1       # drop, never sleep
            return "rate"
        return "spoken" if self.narrate(event) else "silent"

    def _run(self) -> None:
        while not self._stop.is_set():
            if self.pump_one() == "stop":
                break
