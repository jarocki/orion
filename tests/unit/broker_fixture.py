"""Temporary socket broker for R.A.I.N. unit tests (no production paths)."""

import os
import sys
import threading
from pathlib import Path


class BrokerFixture:
    def __init__(self, root: Path, rain_lib):
        self.root = Path(root)
        self.rl = rain_lib
        self.old_socket = rain_lib.EVENT_SOCKET
        self.stop = threading.Event()

    def __enter__(self):
        sys.path.insert(0, str(Path(self.rl.__file__).resolve().parent))
        from rain_broker import EventBroker
        self.rl.EVENT_SOCKET = self.root / "events.sock"
        self.broker = EventBroker(socket_path=self.rl.EVENT_SOCKET,
                                  event_log=self.rl.EVENT_LOG,
                                  detail_dir=self.rl.DETAIL_DIR,
                                  signed_log=self.root / "signed.log",
                                  sign_key=self.root / "sign.key",
                                  sign_cert=self.root / "sign.crt",
                                  bus_key=self.root / "bus.key",
                                  peer_uid=lambda _conn: os.geteuid(),
                                  trusted_uid=-1)
        self.broker.start()
        self.thread = threading.Thread(target=self.broker.serve_forever,
                                       args=(self.stop,), daemon=True)
        self.thread.start()
        return self.broker

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join(timeout=2)
        self.broker.close()
        self.rl.EVENT_SOCKET = self.old_socket
