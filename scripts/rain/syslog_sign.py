#!/usr/bin/env python3
"""RFC 5848 syslog-sign producer for the local Orion-X event broker.

The JSONL bus remains the live reader interface. This separate RFC 5424 stream
contains one data message and one RFC 5848 Signature Block per accepted event,
plus Certificate Blocks at signer startup. It is not a blockchain or a remote
trust anchor: export/pin the certificate fingerprint outside this host before
using the log as evidence of origin.
"""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
import secrets
import socket
import stat
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import dsa
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.x509.oid import NameOID


VERSION = "0121"  # RFC 5848 v01, SHA-256, OpenPGP DSA signature encoding.
PRI = 110         # local audit facility, informational severity.
MAX_SYSLOG_MESSAGE = 8192


def _timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _b64(raw: bytes) -> str:
    return base64.b64encode(raw).decode("ascii")


def _mpi(value: int) -> bytes:
    """OpenPGP multiprecision integer, RFC 4880 section 3.2."""
    bits = value.bit_length()
    return bits.to_bytes(2, "big") + value.to_bytes((bits + 7) // 8, "big")


def _write_all(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        count = os.write(fd, view)
        if count <= 0:
            raise OSError("short syslog write")
        view = view[count:]


def _secure_regular(path: Path, mode: int, *, create: bool = False) -> int:
    flags = os.O_NOFOLLOW | (os.O_WRONLY | os.O_APPEND if create else os.O_RDONLY)
    if create:
        flags |= os.O_CREAT
    fd = os.open(path, flags, mode)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o022:
            raise PermissionError(f"unsafe owner, type, or write mode: {path}")
        if mode == 0o600 and st.st_mode & 0o077:
            raise PermissionError(f"private key is not private: {path}")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _write_new(path: Path, data: bytes, mode: int) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        _write_all(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


def _certificate_common_name(hostname: str) -> str:
    """Keep the certificate CN within X.509's 64-byte limit without aliasing hosts."""
    raw = hostname.encode("utf-8")
    if not raw:
        return "orionx.local"
    if len(raw) <= 64:
        return hostname
    prefix = raw[:47].decode("utf-8", "ignore")
    return f"{prefix}-{hashlib.sha256(raw).hexdigest()[:16]}"


def _load_or_create_identity(key_path: Path, cert_path: Path, hostname: str):
    try:
        fd = _secure_regular(key_path, 0o600)
    except FileNotFoundError:
        key = dsa.generate_private_key(key_size=2048)
        pem = key.private_bytes(serialization.Encoding.PEM,
                                serialization.PrivateFormat.TraditionalOpenSSL,
                                serialization.NoEncryption())
        try:
            _write_new(key_path, pem, 0o600)
        except FileExistsError:
            pass  # A concurrent broker still has to pass the owner/mode check.
        fd = _secure_regular(key_path, 0o600)
    try:
        pem = os.read(fd, 65536)
    finally:
        os.close(fd)
    key = serialization.load_pem_private_key(pem, password=None)
    if not isinstance(key, dsa.DSAPrivateKey):
        raise ValueError("syslog-sign identity is not a DSA key")

    try:
        fd = _secure_regular(cert_path, 0o644)
    except FileNotFoundError:
        now = dt.datetime.now(dt.timezone.utc)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,
                                            _certificate_common_name(hostname))])
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                .public_key(key.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - dt.timedelta(minutes=5))
                .not_valid_after(now + dt.timedelta(days=3650))
                .sign(key, hashes.SHA256()))
        try:
            _write_new(cert_path, cert.public_bytes(serialization.Encoding.PEM), 0o644)
        except FileExistsError:
            pass
        fd = _secure_regular(cert_path, 0o644)
    try:
        cert = x509.load_pem_x509_certificate(os.read(fd, 65536))
    finally:
        os.close(fd)
    if cert.public_key().public_numbers() != key.public_key().public_numbers():
        raise ValueError("syslog-sign certificate does not match private key")
    return key, cert


class SignedSyslog:
    """One RFC 5848 signer session; one signature group, one event per block."""

    def __init__(self, log_path: Path, key_path: Path, cert_path: Path,
                 state_path: Path) -> None:
        self.hostname = socket.getfqdn().encode("ascii", "ignore").decode("ascii")
        if not self.hostname or any(c.isspace() for c in self.hostname):
            self.hostname = "orionx.local"
        self.key, self.cert = _load_or_create_identity(key_path, cert_path, self.hostname)
        self.fingerprint = self.cert.fingerprint(hashes.SHA256()).hex().upper()
        self.procid = str(secrets.randbelow(9_000_000_000) + 1_000_000_000)
        # The live overlay cannot guarantee a monotonic counter across reboots.
        # RFC 5848 section 4.2.2 therefore requires RSID=0.
        self.rsid = 0
        self.state_path = Path(state_path)
        parent = self.state_path.parent.stat()
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
            raise PermissionError("unsafe syslog-sign counter directory")
        # /run survives service restarts but resets on reboot.  RFC 5848 GBC
        # and FMN are reboot-session counters, not daemon-process counters.
        self.gbc, self.fmn = self._read_counters()
        self.fd = _secure_regular(log_path, 0o644, create=True)
        try:
            self._certificate_blocks()
        except BaseException:
            os.close(self.fd)
            raise

    def close(self) -> None:
        os.close(self.fd)

    def _read_counters(self) -> tuple[int, int]:
        try:
            fd = _secure_regular(self.state_path, 0o600)
        except FileNotFoundError:
            return 0, 0
        try:
            st = os.fstat(fd)
            if st.st_nlink != 1:
                raise PermissionError("linked syslog-sign counter file")
            parts = os.read(fd, 64).decode("ascii").strip().split(" ")
            if len(parts) != 2 or any(not part.isdigit() for part in parts):
                raise ValueError("invalid syslog-sign counter state")
            gbc, fmn = (int(part) for part in parts)
            if gbc > 9_999_999_999 or fmn > 9_999_999_999:
                raise ValueError("syslog-sign counter out of range")
            return gbc, fmn
        finally:
            os.close(fd)

    def _save_counters(self, gbc: int, fmn: int) -> None:
        temp = self.state_path.with_name(f".syslog-state-{os.getpid()}-{secrets.token_hex(4)}")
        _write_new(temp, f"{gbc} {fmn}\n".encode("ascii"), 0o600)
        os.replace(temp, self.state_path)
        directory = os.open(self.state_path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)

    def _header(self, app: str, msgid: str) -> str:
        return f"<{PRI}>1 {_timestamp()} {self.hostname} {app} {self.procid} {msgid} "

    def _signature(self, message: bytes) -> str:
        der = self.key.sign(message, hashes.SHA256())
        r, s = decode_dss_signature(der)
        return _b64(_mpi(r) + _mpi(s))

    def _block(self, sd_id: str, fields: list[tuple[str, str]], msgid: str) -> bytes:
        sd = "[" + sd_id + " " + " ".join(f'{k}="{v}"' for k, v in fields)
        unsigned = (self._header("orionx-sign", msgid) + sd + "]").encode("ascii")
        signed = (sd + f' SIGN="{self._signature(unsigned)}"').encode("ascii")
        header = unsigned[:-(len(sd) + 1)]
        message = header + signed + b"]"
        if len(message) > 2048:
            raise ValueError("RFC 5848 control block exceeds 2048 octets")
        return message + b"\n"

    def _certificate_blocks(self) -> None:
        payload = (_timestamp() + " C " + _b64(self.cert.public_bytes(serialization.Encoding.DER))).encode("ascii")
        # The fragment is ASCII and never needs RFC 5424 SD escaping.
        for index in range(0, len(payload), 700):
            fragment = payload[index:index + 700]
            fields = [("VER", VERSION), ("RSID", str(self.rsid)), ("SG", "0"),
                      ("SPRI", str(PRI)), ("TPBL", str(len(payload))),
                      ("INDEX", str(index + 1)), ("FLEN", str(len(fragment))),
                      ("FRAG", fragment.decode("ascii"))]
            _write_all(self.fd, self._block("ssign-cert", fields, "CERT"))
        os.fsync(self.fd)

    def append(self, event: dict) -> None:
        body = json.dumps(event, ensure_ascii=True, separators=(",", ":"))
        message = (self._header("orionx-event", "EVENT") + "- " + body).encode("ascii")
        if len(message) > MAX_SYSLOG_MESSAGE:
            raise ValueError("syslog event exceeds bounded message length")
        current_fmn = self.fmn % 9_999_999_999 + 1
        current_gbc = self.gbc
        # GBC counts preceding Signature Blocks; the first block is 0.
        fields = [("VER", VERSION), ("RSID", str(self.rsid)), ("SG", "0"),
                  ("SPRI", str(PRI)), ("GBC", str(current_gbc)),
                  ("FMN", str(current_fmn)), ("CNT", "1"),
                  ("HB", _b64(hashlib.sha256(message).digest()))]
        block = self._block("ssign", fields, "SIGN")
        # Reserve before writing: after a crash, a gap is visible rather than
        # silently reusing a block/message number for different evidence.
        next_gbc = (current_gbc + 1) % 10_000_000_000
        self._save_counters(next_gbc, current_fmn)
        self.gbc, self.fmn = next_gbc, current_fmn
        _write_all(self.fd, message + b"\n" + block)
        os.fsync(self.fd)
