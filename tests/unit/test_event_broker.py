"""Live Unix-socket and RFC 5848 regression tests for the event boundary."""

import json
import multiprocessing
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/rain"))
import rain_lib  # noqa: E402
import rain_broker  # noqa: E402
from rain_broker import EventBroker  # noqa: E402
from verify_syslog_sign import verify_log  # noqa: E402


def _drop_privileges_and_emit(socket_path: str) -> None:
    os.setgroups([])
    os.setgid(65534)
    os.setuid(65534)
    rain_lib.EVENT_SOCKET = Path(socket_path)
    if not rain_lib.emit_event("critical", "health", "compromise", "untrusted kernel peer"):
        raise RuntimeError("unprivileged socket publish failed")


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.socket = self.base / "events.sock"
        self.spool = self.base / "events.jsonl"
        self.signed = self.base / "events.rfc5848.log"
        self.old_socket = rain_lib.EVENT_SOCKET
        rain_lib.EVENT_SOCKET = self.socket
        self.role = [1000]
        self.broker = EventBroker(socket_path=self.socket, event_log=self.spool,
                                  detail_dir=self.base / "details",
                                  signed_log=self.signed,
                                  sign_key=self.base / "sign.key",
                                  sign_cert=self.base / "sign.crt",
                                  bus_key=self.base / "bus.key",
                                  peer_uid=lambda _conn: self.role[0])
        self.stop = threading.Event()

    def tearDown(self):
        self.stop.set()
        if hasattr(self, "thread"):
            self.thread.join(timeout=2)
        self.broker.close()
        rain_lib.EVENT_SOCKET = self.old_socket
        self.temp.cleanup()

    def start(self):
        self.broker.start()
        self.thread = threading.Thread(target=self.broker.serve_forever,
                                       args=(self.stop,), daemon=True)
        self.thread.start()

    def rows(self):
        return [json.loads(line) for line in self.spool.read_text().splitlines()]

    def raw(self, payload):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(2)
            sock.connect(str(self.socket))
            sock.sendall(payload)
            return sock.recv(16)

    def test_migration_replaces_open_world_writable_inode(self):
        self.spool.write_text("old untrusted row\n")
        self.spool.chmod(0o666)
        old_fd = os.open(self.spool, os.O_WRONLY | os.O_APPEND)
        try:
            old_inode = self.spool.stat().st_ino
            self.start()
            self.assertEqual(stat.S_IMODE(self.spool.stat().st_mode), 0o644)
            self.assertNotEqual(old_inode, self.spool.stat().st_ino)
            os.write(old_fd, b"forged after migration\n")
            self.assertEqual(self.spool.read_bytes(), b"")
        finally:
            os.close(old_fd)

    def test_protected_spool_restores_reader_permissions(self):
        self.spool.write_bytes(b"")
        self.spool.chmod(0o600)
        original_inode = self.spool.stat().st_ino
        self.start()
        self.assertEqual(self.spool.stat().st_ino, original_inode)
        self.assertEqual(stat.S_IMODE(self.spool.stat().st_mode), 0o644)

    def test_peer_trust_and_rfc5848_validation(self):
        self.start()
        self.assertEqual(stat.S_IMODE(self.socket.stat().st_mode), 0o666)
        self.assertTrue(rain_lib.emit_event("critical", "health", "compromise", "untrusted claim"))
        self.assertNotIn("auth", self.rows()[0])
        self.assertFalse(rain_lib.verify_event(self.rows()[0], self.broker.bus_key))
        self.role[0] = 0
        self.assertTrue(rain_lib.emit_event("critical", "firewall", "scan", "trusted scan"))
        self.assertTrue(rain_lib.verify_event(self.rows()[1], self.broker.bus_key))
        self.assertEqual(verify_log(self.signed, self.broker.signer.fingerprint), 2)
        self.assertIn(b'GBC="0"', self.signed.read_bytes())
        self.assertEqual(stat.S_IMODE((self.base / "sign.key").stat().st_mode), 0o600)

    @unittest.skipUnless(hasattr(socket, "SO_PEERCRED") and os.geteuid() == 0,
                         "requires Linux root and SO_PEERCRED")
    def test_linux_kernel_peer_credentials(self):
        self.base.chmod(0o755)
        self.broker.peer_uid = rain_broker._peer_uid
        self.start()
        child = multiprocessing.get_context("spawn").Process(
            target=_drop_privileges_and_emit, args=(str(self.socket),))
        child.start()
        child.join(timeout=5)
        self.assertEqual(child.exitcode, 0)
        self.assertNotIn("auth", self.rows()[0])
        self.assertTrue(rain_lib.emit_event("critical", "firewall", "scan", "root kernel peer"))
        self.assertTrue(rain_lib.verify_event(self.rows()[1], self.broker.bus_key))

    def test_untrusted_cannot_supply_auth_or_timestamp(self):
        self.start()
        request = {"severity": "critical", "source": "health", "category": "compromise",
                   "message": "spoofed", "detail": None, "auth": "forged"}
        self.assertEqual(self.raw(json.dumps(request).encode() + b"\n"), b"ERR\n")
        del request["auth"]
        request["ts"] = 123
        self.assertEqual(self.raw(json.dumps(request).encode() + b"\n"), b"ERR\n")
        self.assertEqual(self.rows(), [])

    def test_detail_sidecar_is_broker_written_and_bounded(self):
        self.start()
        self.assertTrue(rain_lib.emit_event("warning", "cli", "general", "detail",
                                            detail={"payload": "x" * 90_000}))
        row = self.rows()[0]
        self.assertLess(len(self.spool.read_bytes()), 4096)
        self.assertEqual(len(json.loads(Path(row["detail"]["_full"]).read_text())["payload"]), 90_000)
        self.assertFalse(rain_lib.emit_event("warning", "cli", "general", "too large",
                                             detail={"payload": "x" * 200_000}))
        self.assertEqual(len(self.rows()), 1)

    def test_idle_clients_and_deep_json_cannot_stop_root_alerts(self):
        self.start()
        idle = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) for _ in range(2)]
        try:
            for conn in idle:
                conn.connect(str(self.socket))
            self.role[0] = 0
            started = time.monotonic()
            self.assertTrue(rain_lib.emit_event("critical", "firewall", "scan", "while clients idle"))
            self.assertLess(time.monotonic() - started, 1.5)
            self.role[0] = 1000
            prefix = b'{"severity":"notice","source":"cli","category":"general","message":"deep","detail":{"x":'
            payload = prefix + b"[" * 30000 + b"0" + b"]" * 30000 + b"}}\n"
            self.assertEqual(self.raw(payload), b"ERR\n")
            self.role[0] = 0
            self.assertTrue(rain_lib.emit_event("critical", "firewall", "scan", "after malformed"))
            self.assertEqual(len(self.rows()), 2)
        finally:
            for conn in idle:
                conn.close()

    def test_untrusted_storage_budget_preserves_root_events(self):
        old_limit = rain_broker.UNTRUSTED_BYTES_LIMIT
        rain_broker.UNTRUSTED_BYTES_LIMIT = 200_000
        try:
            self.start()
            detail = {"payload": "x" * 90_000}
            self.assertTrue(rain_lib.emit_event("warning", "cli", "general", "one", detail))
            self.assertTrue(rain_lib.emit_event("warning", "cli", "general", "two", detail))
            self.assertFalse(rain_lib.emit_event("warning", "cli", "general", "three", detail))
            self.role[0] = 0
            self.assertTrue(rain_lib.emit_event("critical", "firewall", "scan", "root reserve"))
            self.assertEqual(len(self.rows()), 3)
        finally:
            rain_broker.UNTRUSTED_BYTES_LIMIT = old_limit

    def test_restart_preserves_signed_log_and_untrusted_quota(self):
        self.start()
        self.assertTrue(rain_lib.emit_event("notice", "cli", "general", "before restart"))
        used = self.broker.untrusted_bytes
        pin = self.broker.signer.fingerprint
        self.stop.set()
        self.thread.join(timeout=2)
        self.broker.close()
        self.stop = threading.Event()
        self.broker = EventBroker(socket_path=self.socket, event_log=self.spool,
                                  detail_dir=self.base / "details", signed_log=self.signed,
                                  sign_key=self.base / "sign.key", sign_cert=self.base / "sign.crt",
                                  bus_key=self.base / "bus.key",
                                  peer_uid=lambda _conn: self.role[0])
        self.start()
        self.assertEqual(self.broker.untrusted_bytes, used)
        self.assertTrue(rain_lib.emit_event("notice", "cli", "general", "after restart"))
        self.assertGreater(self.broker.untrusted_bytes, used)
        self.assertEqual(verify_log(self.signed, pin), 2)

    def test_boot_wiring_and_protected_modes(self):
        tmpfiles = (ROOT / "iso/config/includes.chroot/usr/lib/tmpfiles.d/orionx.conf").read_text()
        units = (ROOT / "iso/config/hooks/live/0615-install-systemd-units.hook.chroot").read_text()
        service = (ROOT / "iso/config/includes.chroot/usr/share/orionx/systemd/orionx-event-broker.service").read_text()
        packages = (ROOT / "iso/config/package-lists/orionx.list.chroot").read_text()
        self.assertIn("f /run/orionx/events.jsonl 0644 root root", tmpfiles)
        self.assertNotIn("f /run/orionx/events.jsonl 0666", tmpfiles)
        self.assertIn('"orionx-event-broker.service"', units)
        self.assertIn("Type=notify", service)
        self.assertIn("User=root", service)
        self.assertIn("python3-cryptography\n", packages)

    def test_signed_log_detects_change_loss_order_and_bad_pin(self):
        self.start()
        for n in range(3):
            self.assertTrue(rain_lib.emit_event("notice", "cli", "general", f"event {n}"))
        pin = self.broker.signer.fingerprint
        self.assertEqual(verify_log(self.signed, pin), 3)
        original = self.signed.read_bytes()
        self.signed.write_bytes(original.replace(b'"message":"event 1"', b'"message":"event X"', 1))
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            verify_log(self.signed, pin)
        records = original.splitlines(keepends=True)
        self.signed.write_bytes(b"".join(r for r in records if b'FMN="2"' not in r))
        with self.assertRaises(ValueError):
            verify_log(self.signed, pin)
        self.signed.write_bytes(original)
        with self.assertRaisesRegex(ValueError, "fingerprint"):
            verify_log(self.signed, "0" * 64)

    def test_down_broker_fails_closed(self):
        self.assertFalse(rain_lib.emit_event("notice", "cli", "general", "not delivered"))
        self.assertFalse(self.spool.exists())


if __name__ == "__main__":
    unittest.main()
