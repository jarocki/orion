#!/usr/bin/env python3
"""Verify Orion-X's RFC 5848 profile against an independently pinned cert hash."""

from __future__ import annotations

import base64
import hashlib
import json
import re
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import dsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from syslog_sign import VERSION


_HEADER = re.compile(rb"^(<110>1 \S+ \S+ \S+ (\S+) \S+ )(.*)$")
_FIELD = re.compile(rb'([A-Z]+)="([^"]*)"')
_CERT_FIELDS = (b"VER", b"RSID", b"SG", b"SPRI", b"TPBL", b"INDEX", b"FLEN", b"FRAG", b"SIGN")
_SIGN_FIELDS = (b"VER", b"RSID", b"SG", b"SPRI", b"GBC", b"FMN", b"CNT", b"HB", b"SIGN")


def _parse_control(message: bytes, prefix: bytes, expected: tuple[bytes, ...]) -> dict[bytes, bytes]:
    m = _HEADER.fullmatch(message)
    if m is None or not m.group(3).startswith(prefix) or not m.group(3).endswith(b"]"):
        raise ValueError("malformed syslog-sign control message")
    inside = m.group(3)[len(prefix):-1]
    found = _FIELD.findall(inside)
    if tuple(k for k, _ in found) != expected or b" ".join(k + b'="' + v + b'"' for k, v in found) != inside:
        raise ValueError("malformed or out-of-order syslog-sign fields")
    result = dict(found)
    if result[b"VER"] != VERSION.encode() or result[b"RSID"] != b"0" or result[b"SG"] != b"0" or result[b"SPRI"] != b"110":
        raise ValueError("unsupported syslog-sign version or group")
    return result


def _decode_mpi(raw: bytes, offset: int) -> tuple[int, int]:
    if offset + 2 > len(raw):
        raise ValueError("short OpenPGP MPI")
    bits = int.from_bytes(raw[offset:offset + 2], "big")
    count = (bits + 7) // 8
    if not bits or offset + 2 + count > len(raw):
        raise ValueError("invalid OpenPGP MPI")
    value = int.from_bytes(raw[offset + 2:offset + 2 + count], "big")
    if value.bit_length() != bits:
        raise ValueError("noncanonical OpenPGP MPI")
    return value, offset + 2 + count


def _verify_control(message: bytes, fields: dict[bytes, bytes], cert: x509.Certificate) -> None:
    marker = b' SIGN="' + fields[b"SIGN"] + b'"'
    if message.count(marker) != 1:
        raise ValueError("ambiguous signature field")
    unsigned = message.replace(marker, b"", 1)
    raw = base64.b64decode(fields[b"SIGN"], validate=True)
    r, pos = _decode_mpi(raw, 0)
    s, pos = _decode_mpi(raw, pos)
    if pos != len(raw):
        raise ValueError("trailing signature bytes")
    try:
        cert.public_key().verify(encode_dss_signature(r, s), unsigned, hashes.SHA256())
    except InvalidSignature as exc:
        raise ValueError("invalid RFC 5848 signature") from exc


def verify_log(path: Path, fingerprint: str) -> int:
    """Return verified event count; raise on any changed, missing or reordered line.

    The supplied certificate fingerprint must come from a separate trusted
    channel. An entirely deleted tail cannot be detected without an external
    final-count checkpoint or remote collector.
    """
    pin = fingerprint.replace(":", "").replace(" ", "").upper()
    if not re.fullmatch(r"[0-9A-F]{64}", pin):
        raise ValueError("expected SHA-256 certificate fingerprint is required")
    blob = Path(path).read_bytes()
    if blob and not blob.endswith(b"\n"):
        raise ValueError("unterminated syslog record")
    records = blob.splitlines()
    sessions: dict[bytes, dict] = {}
    parsed = []
    for message in records:
        m = _HEADER.fullmatch(message)
        if m is None:
            raise ValueError("malformed RFC 5424 message")
        procid, body = m.group(2), m.group(3)
        if body.startswith(b"[ssign-cert "):
            fields = _parse_control(message, b"[ssign-cert ", _CERT_FIELDS)
            sessions.setdefault(procid, {"fragments": [], "cert_messages": []})["fragments"].append(fields)
            sessions[procid]["cert_messages"].append((message, fields))
            parsed.append(("cert", procid, message, fields))
        elif body.startswith(b"[ssign "):
            fields = _parse_control(message, b"[ssign ", _SIGN_FIELDS)
            parsed.append(("sign", procid, message, fields))
        elif body.startswith(b"- "):
            event = json.loads(body[2:])
            if not isinstance(event, dict):
                raise ValueError("non-object event")
            parsed.append(("event", procid, message, None))
        else:
            raise ValueError("unexpected syslog message")

    for procid, session in sessions.items():
        fragments = session["fragments"]
        total = int(fragments[0][b"TPBL"])
        if total < 1 or total > 65536:
            raise ValueError("invalid certificate payload length")
        payload = bytearray(total)
        covered = bytearray(total)
        for fields in fragments:
            if int(fields[b"TPBL"]) != total:
                raise ValueError("certificate payload length changed")
            frag = fields[b"FRAG"]
            index = int(fields[b"INDEX"]) - 1
            if int(fields[b"FLEN"]) != len(frag) or index < 0 or index + len(frag) > total:
                raise ValueError("certificate fragment bounds invalid")
            if any(covered[index:index + len(frag)]):
                raise ValueError("overlapping certificate fragments")
            payload[index:index + len(frag)] = frag
            covered[index:index + len(frag)] = b"\x01" * len(frag)
        if not all(covered):
            raise ValueError("missing certificate fragment")
        _timestamp, kind, encoded = bytes(payload).split(b" ", 2)
        if kind != b"C":
            raise ValueError("certificate payload is not X.509")
        cert = x509.load_der_x509_certificate(base64.b64decode(encoded, validate=True))
        if not isinstance(cert.public_key(), dsa.DSAPublicKey):
            raise ValueError("certificate does not contain DSA public key")
        if cert.fingerprint(hashes.SHA256()).hex().upper() != pin:
            raise ValueError("certificate fingerprint does not match independent pin")
        for message, fields in session["cert_messages"]:
            _verify_control(message, fields, cert)
        session.update({"cert": cert, "gbc": -1, "fmn": 0})

    pending = None
    count = 0
    for kind, procid, message, fields in parsed:
        if procid not in sessions:
            raise ValueError("event or signature lacks certificate")
        if kind == "cert":
            if pending is not None:
                raise ValueError("certificate block interrupted an unsigned event")
            continue
        session = sessions[procid]
        if kind == "event":
            if pending is not None:
                raise ValueError("missing signature block")
            pending = (procid, message)
            continue
        if pending is None or pending[0] != procid or fields is None:
            raise ValueError("orphaned or reordered signature block")
        if fields[b"CNT"] != b"1" or int(fields[b"GBC"]) != session["gbc"] + 1 or int(fields[b"FMN"]) != session["fmn"] + 1:
            raise ValueError("missing or reordered signed message")
        digest = base64.b64decode(fields[b"HB"], validate=True)
        if digest != hashlib.sha256(pending[1]).digest():
            raise ValueError("event hash mismatch")
        _verify_control(message, fields, session["cert"])
        session["gbc"] += 1
        session["fmn"] += 1
        count += 1
        pending = None
    if pending is not None:
        raise ValueError("unsigned final event")
    return count
