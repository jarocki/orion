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

import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from queue import Empty, Full, Queue
from typing import Any, Callable

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
    the one thing the operator most needs to hear correctly.
    """
    flat = " ".join(str(text).split())
    flat = "".join(c for c in flat if c == " " or c.isprintable())
    flat = _IP_RE.sub(lambda m: " dot ".join(m.group(0).split(".")), flat)
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

PIPER_VOICE_PATHS = (
    os.environ.get("ORIONX_PIPER_VOICE", ""),
    "/usr/share/orionx/voices/en_US-lessac-medium.onnx",
    "/opt/orionx/voices/en_US-lessac-medium.onnx",
)
SPEECH_SCRATCH = Path("/run/orionx/speech")
SPEECH_SOURCE = "rain"          # the daemon must never narrate its own events

# Sentinel for "use the module default" in Narrator, distinct from None.
_DEFAULT = object()


def piper_voice() -> str | None:
    """Path to an installed piper voice model, or None."""
    for cand in PIPER_VOICE_PATHS:
        if cand and Path(cand).is_file():
            return cand
    return None


def tts_backend() -> str | None:
    """'piper', 'espeak-ng', or None when the deck cannot speak at all."""
    if shutil.which("piper") and piper_voice():
        return "piper"
    if shutil.which("espeak-ng"):
        return "espeak-ng"
    return None


def speak(text: str, cfg: dict[str, Any] | None = None,
          backend: str | None = None) -> bool:
    """Say one line. Returns True only if a TTS process actually ran."""
    cfg = cfg or rain_lib.default_config()
    line = speakable(text)
    if not line:
        return False
    backend = backend or tts_backend()
    vol = max(0.0, min(1.0, float(cfg.get("volume", 0.8))))

    if backend == "piper":
        voice = piper_voice()
        if not voice:
            return False
        try:
            SPEECH_SCRATCH.mkdir(parents=True, exist_ok=True)
            scratch = str(SPEECH_SCRATCH)
        except OSError:
            scratch = None
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", dir=scratch,
                                             delete=False) as fh:
                wav = fh.name
        except OSError:
            return False
        try:
            proc = subprocess.run(
                ["piper", "-m", voice, "-f", wav,
                 "--length-scale", "1.04", "--sentence-silence", "0.25"],
                input=line, text=True, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, check=False, timeout=TTS_TIMEOUT)
            if proc.returncode != 0 or not os.path.getsize(wav):
                return False
            if shutil.which("paplay"):
                return rain_lib._run(
                    ["paplay", f"--volume={int(vol * 65536)}", wav])
            if shutil.which("aplay"):
                return rain_lib._run(["aplay", "-q", wav])
            return False
        except (OSError, subprocess.SubprocessError):
            return False
        finally:
            try:
                os.unlink(wav)
            except OSError:
                pass

    if backend == "espeak-ng":
        # -a 0..200 amplitude, -s words/min. 160 is a touch slower than
        # default, which matters for an address read out as digits.
        return rain_lib._run(
            ["espeak-ng", "-a", str(int(vol * 200)), "-s", "160", "--", line])

    return False


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
                 backend_probe: Any = _DEFAULT,
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
        self._q: Queue = Queue(maxsize=maxsize)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_spoken = 0.0
        self._no_tts_announced = False
        self._no_model_announced = False
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
        ok = False
        # Hold the music for as long as this line will take (DEC-PHASE12-044).
        # espeak-ng runs near 175 wpm; 2.5 words/s plus a 1s tail is generous
        # without being open-ended. A narration is capped at 24 words by
        # validate_line(), so this cannot exceed ~11s. Best-effort: duck_music
        # never raises, and a failure here costs music, never the alert.
        try:
            rain_lib.duck_music(min(12.0, len(text.split()) / 2.5 + 1.0))
        except Exception:                            # noqa: BLE001
            pass
        try:
            ok = bool(self.speaker(text, rain_lib.load_config()))
        except Exception:                            # noqa: BLE001
            ok = False
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
            return "stale"
        if not self._gap_ok(now):
            self.dropped_rate += 1       # drop, never sleep
            return "rate"
        return "spoken" if self.narrate(event) else "silent"

    def _run(self) -> None:
        while not self._stop.is_set():
            if self.pump_one() == "stop":
                break
