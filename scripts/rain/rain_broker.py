#!/usr/bin/env python3
"""Root-owned local event broker. The JSONL spool has exactly one writer."""

from __future__ import annotations

import json
import os
import secrets
import selectors
import socket
import stat
import struct
import time
from pathlib import Path
from typing import Callable

import rain_lib
from syslog_sign import SignedSyslog, _write_all


SIGNED_LOG = Path("/var/log/orionx/events.rfc5848.log")
SIGN_KEY = Path("/var/lib/orionx/syslog-sign.key")
SIGN_CERT = Path("/var/lib/orionx/syslog-sign.crt")
PRODUCTION_SOCKET = Path("/run/orionx/events.sock")
UNTRUSTED_BYTES_LIMIT = 16 * 1024 * 1024


def _peer_uid(conn: socket.socket) -> int:
    if hasattr(socket, "SO_PEERCRED"):
        raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", raw)
        return uid
    if hasattr(conn, "getpeereid"):
        return conn.getpeereid()[0]
    raise RuntimeError("Unix peer credentials unavailable")


def _check_json_depth(data: bytes, limit: int = 32) -> None:
    """Reject pathological nesting before the JSON parser can recurse."""
    depth = 0
    quoted = False
    escaped = False
    for byte in data:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:  # backslash
                escaped = True
            elif byte == 34:  # double quote
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):  # [ {
            depth += 1
            if depth > limit:
                raise ValueError("event JSON nesting limit")
        elif byte in (93, 125):  # ] }
            depth -= 1
            if depth < 0:
                raise ValueError("invalid event JSON structure")


def _protected_spool(path: Path) -> int:
    parent = path.parent.stat()
    if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
        raise PermissionError(f"unsafe event directory: {path.parent}")
    try:
        st = path.lstat()
    except FileNotFoundError:
        st = None
    if st is not None and not stat.S_ISREG(st.st_mode):
        raise PermissionError(f"event spool is not a regular file: {path}")
    if st is not None and (st.st_uid != os.geteuid() or st.st_mode & 0o022 or st.st_nlink != 1):
        # Replace the old 0666 inode. chmod alone would leave an attacker with
        # an already-open writable file descriptor to the live bus.
        st = None
    if st is None:
        temp = path.parent / f".events-{os.getpid()}-{secrets.token_hex(6)}"
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        os.close(fd)
        os.replace(temp, path)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    actual = os.fstat(fd)
    if not stat.S_ISREG(actual.st_mode) or actual.st_uid != os.geteuid() or actual.st_mode & 0o022:
        os.close(fd)
        raise PermissionError(f"event spool not protected: {path}")
    # A protected but overly restrictive spool can survive an upgrade. Keep
    # the established unprivileged-reader contract without reopening writes.
    if stat.S_IMODE(actual.st_mode) != 0o644:
        os.fchmod(fd, 0o644)
    return fd


class EventBroker:
    def __init__(self, *, socket_path: Path = rain_lib.EVENT_SOCKET,
                 event_log: Path = rain_lib.EVENT_LOG,
                 detail_dir: Path = rain_lib.DETAIL_DIR,
                 signed_log: Path = SIGNED_LOG,
                 sign_key: Path = SIGN_KEY, sign_cert: Path = SIGN_CERT,
                 bus_key: Path | None = None,
                 peer_uid: Callable[[socket.socket], int] = _peer_uid,
                 trusted_uid: int = 0) -> None:
        self.socket_path, self.event_log = Path(socket_path), Path(event_log)
        self.detail_dir = Path(detail_dir)
        self.signed_log = Path(signed_log)
        self.sign_key, self.sign_cert = Path(sign_key), Path(sign_cert)
        self.bus_key_path = Path(bus_key) if bus_key is not None else rain_lib.BUS_KEY
        self.peer_uid, self.trusted_uid = peer_uid, trusted_uid
        self.socket: socket.socket | None = None
        self.spool_fd: int | None = None
        self.signer: SignedSyslog | None = None
        self.bus_key: bytes | None = None
        self._tokens: dict[int, tuple[float, float]] = {}
        self.quota_path = self.socket_path.parent / ".events-untrusted-budget"
        self.untrusted_bytes = 0

    def _read_quota(self) -> int:
        try:
            fd = os.open(self.quota_path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return 0
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077:
                raise PermissionError("unsafe event quota file")
            raw = os.read(fd, 64)
            if not raw.isdigit():
                raise ValueError("invalid event quota file")
            return int(raw)
        finally:
            os.close(fd)

    def _reserve_untrusted_bytes(self, count: int) -> None:
        if self.untrusted_bytes + count > UNTRUSTED_BYTES_LIMIT:
            raise ValueError("untrusted event storage budget exhausted")
        new_count = self.untrusted_bytes + count
        temp = self.quota_path.with_name(f".quota-{os.getpid()}-{secrets.token_hex(4)}")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            _write_all(fd, str(new_count).encode("ascii"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temp, self.quota_path)
        self.untrusted_bytes = new_count

    def start(self) -> None:
        if self.socket_path == PRODUCTION_SOCKET and os.geteuid() != 0:
            raise PermissionError("production event broker must run as root")
        self.spool_fd = _protected_spool(self.event_log)
        self.untrusted_bytes = self._read_quota()
        self.bus_key, why = rain_lib.ensure_bus_key(self.bus_key_path)
        if self.bus_key is None:
            raise RuntimeError(why or "bus key unavailable")
        self.signer = SignedSyslog(self.signed_log, self.sign_key, self.sign_cert)
        if self.socket_path.parent.resolve() != self.event_log.parent.resolve():
            raise ValueError("event socket and spool must share a protected directory")
        try:
            st = self.socket_path.lstat()
        except FileNotFoundError:
            st = None
        if st is not None:
            if not stat.S_ISSOCK(st.st_mode) or st.st_uid != os.geteuid():
                raise PermissionError("unsafe existing event socket")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                probe.settimeout(0.1)
                try:
                    probe.connect(str(self.socket_path))
                except OSError:
                    self.socket_path.unlink()
                else:
                    raise RuntimeError("event broker already listening")
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.bind(str(self.socket_path))
        os.chmod(self.socket_path, 0o666)
        self.socket.listen(64)
        self.socket.setblocking(False)

    def close(self) -> None:
        if self.socket is not None:
            self.socket.close()
            self.socket = None
            try:
                self.socket_path.unlink()
            except FileNotFoundError:
                pass
        if self.signer is not None:
            self.signer.close()
            self.signer = None
        if self.spool_fd is not None:
            os.close(self.spool_fd)
            self.spool_fd = None

    def _allow(self, uid: int) -> bool:
        if uid == self.trusted_uid:
            return True
        now = time.monotonic()
        tokens, previous = self._tokens.get(uid, (20.0, now))
        tokens = min(20.0, tokens + (now - previous) * 10.0)
        if tokens < 1.0:
            self._tokens[uid] = (tokens, now)
            return False
        self._tokens[uid] = (tokens - 1.0, now)
        return True

    def _handle(self, conn: socket.socket, uid: int, data: bytes) -> None:
        conn.settimeout(0.5)
        try:
            if data.count(b"\n") != 1 or not data.endswith(b"\n"):
                raise ValueError("one request per connection")
            _check_json_depth(data)
            request = json.loads(data[:-1], parse_constant=lambda _x: (_ for _ in ()).throw(ValueError("invalid number")))
            if not isinstance(request, dict) or set(request) != {"severity", "source", "category", "message", "detail"}:
                raise ValueError("invalid event fields")
            if any(not isinstance(request[k], str) for k in ("severity", "source", "category", "message")):
                raise ValueError("invalid event value")
            if request["detail"] is not None and not isinstance(request["detail"], dict):
                raise ValueError("invalid detail")
            if uid != self.trusted_uid:
                # Charge the wire size (including any sidecar) plus a
                # conservative upper bound for the signed syslog pair. A
                # root-only counter survives broker restarts during this boot.
                self._reserve_untrusted_bytes(len(data) + 2048)
            event = rain_lib.build_event(**request, trusted=(uid == self.trusted_uid),
                                         detail_dir=self.detail_dir,
                                         attestation_key=self.bus_key)
            line = json.dumps(event, ensure_ascii=False).encode("utf-8") + b"\n"
            if len(line) > rain_lib.LINE_BUDGET + 512:
                raise ValueError("event exceeds line budget")
            assert self.signer is not None and self.spool_fd is not None
            self.signer.append(event)
            _write_all(self.spool_fd, line)
            conn.sendall(b"OK\n")
        except (OSError, ValueError, TypeError, RuntimeError, RecursionError) as exc:
            try:
                conn.sendall(b"ERR\n")
            except OSError:
                pass
            print(f"orionx-event-broker: event rejected: {exc}", flush=True)

    def serve_forever(self, stop=None) -> None:
        assert self.socket is not None
        pending: dict[socket.socket, tuple[int, bytearray, float]] = {}
        with selectors.DefaultSelector() as selector:
            selector.register(self.socket, selectors.EVENT_READ)
            try:
                while stop is None or not stop.is_set():
                    for key, _mask in selector.select(0.1):
                        if key.fileobj is self.socket:
                            while True:
                                try:
                                    conn, _ = self.socket.accept()
                                except BlockingIOError:
                                    break
                                try:
                                    uid = self.peer_uid(conn)
                                    # An idle client never occupies the writer loop;
                                    # each unprivileged uid gets at most two slots.
                                    idle = sum(1 for p in pending.values() if p[0] == uid)
                                    if not self._allow(uid) or (uid != self.trusted_uid and idle >= 2):
                                        conn.sendall(b"ERR\n")
                                        conn.close()
                                        continue
                                    conn.setblocking(False)
                                    pending[conn] = (uid, bytearray(), time.monotonic() + 0.5)
                                    selector.register(conn, selectors.EVENT_READ)
                                except (OSError, RuntimeError):
                                    conn.close()
                        else:
                            conn = key.fileobj
                            uid, data, deadline = pending[conn]
                            try:
                                chunk = conn.recv(min(8192, rain_lib.MAX_REQUEST_BYTES + 1 - len(data)))
                            except OSError:
                                chunk = b""
                            if not chunk:
                                selector.unregister(conn)
                                pending.pop(conn)
                                conn.close()
                                continue
                            data.extend(chunk)
                            if len(data) > rain_lib.MAX_REQUEST_BYTES:
                                selector.unregister(conn)
                                pending.pop(conn)
                                conn.close()
                                continue
                            if b"\n" in data:
                                selector.unregister(conn)
                                pending.pop(conn)
                                conn.setblocking(True)
                                with conn:
                                    self._handle(conn, uid, bytes(data))
                    for conn, (_uid, _data, deadline) in list(pending.items()):
                        if time.monotonic() > deadline:
                            selector.unregister(conn)
                            pending.pop(conn)
                            conn.close()
            finally:
                for conn in pending:
                    conn.close()
