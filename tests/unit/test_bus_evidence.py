"""#189: rejected bus events are counted and evidenced; #190: critical Zeek attacker notices may propose block_ip."""
from __future__ import annotations

import json
import sys
import tempfile
import time
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
for d in ("scripts/rain", "scripts/healing", "scripts/awareness"):
    sys.path.insert(0, str(ROOT / d))
import engine as eng  # noqa: E402
import healing_lib as hl  # noqa: E402
import rain_lib  # noqa: E402

KEY = b"k" * 32


def signed(ev: dict) -> dict:
    ev = dict(ev)
    ev[rain_lib.AUTH_FIELD] = rain_lib.sign_event(ev, KEY)
    return ev


def crit_ids(**detail) -> dict:
    return {"ts": time.time(), "severity": "critical", "source": "suricata", "category": "ids",
            "message": "ET SCAN from 203.0.113.9", "detail": detail}


class Counter(unittest.TestCase):
    def test_reasons_from_the_engine_texts(self):
        R = rain_lib.rejection_reason
        self.assertEqual(R("unsigned event (not written by a root producer)"), "unsigned")
        self.assertEqual(R("signature does not verify (forged or altered)"), "bad_signature")
        self.assertEqual(R("signed event is 900s old (replay window 120s)"), "stale")
        self.assertEqual(R("replayed event (this signature was already acted on)"), "replay")
        self.assertEqual(R("bus key unreadable"), "no_key")

    def test_one_log_line_per_reason_per_interval(self):
        lines = []
        c = rain_lib.RejectCounter("t", interval=300, log=lines.append)
        for i in range(1000):
            c.add("unsigned", now=1000 + i * 0.01)
        c.add("bad_signature", now=1001)
        self.assertEqual(len(lines), 2)              # a flood: one line per reason
        c.add("unsigned", now=1400)
        self.assertEqual(len(lines), 3)
        # everything since the last line is reported together: 999 held + this one
        self.assertIn("rejected 1000 bus event(s) as unsigned (total 1001)", lines[-1])
        self.assertEqual(c.snapshot()["by_reason"], {"unsigned": 1001, "bad_signature": 1})
        self.assertEqual(c.snapshot()["total"], 1002)


class Heald(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.e = eng.Engine(dry_run=False, state_dir=Path(self.tmp.name), probe_host=False)
        self.e.bus_key = lambda: KEY
        self.e.status_file = Path(self.tmp.name) / "status.json"
        self.lines = []
        self.e.rejected = rain_lib.RejectCounter("orionx-heald", log=self.lines.append)

    def test_each_kind_of_bad_event_is_counted_by_reason(self):
        now = time.time()
        ev = crit_ids(src_ip="203.0.113.9")
        self.assertEqual(self.e.handle_event(dict(ev), now=now), "unverified")                 # unsigned
        forged = signed(ev)
        forged["detail"] = dict(forged["detail"], tampered=True)
        self.assertEqual(self.e.handle_event(forged, now=now), "unverified")                   # bad signature
        old = signed(dict(ev, ts=now - 3600))
        self.assertEqual(self.e.handle_event(old, now=now), "unverified")                      # stale
        good = signed(ev)
        self.e.consider = lambda *a, **k: "considered"
        self.assertEqual(self.e.handle_event(dict(good), now=now), "considered")
        self.assertEqual(self.e.handle_event(dict(good), now=now), "unverified")               # replay
        self.assertEqual(self.e.rejected.snapshot()["by_reason"],
                         {"unsigned": 1, "bad_signature": 1, "stale": 1, "replay": 1})

    def test_rejections_reach_the_published_status_and_orionx_heal_status(self):
        self.e.handle_event(crit_ids(src_ip="203.0.113.9"), now=time.time())
        self.e.autonomy = lambda: {}
        self.assertTrue(self.e.publish_status())
        st = json.loads(self.e.status_file.read_text())
        self.assertEqual(st["rejected_events"]["by_reason"], {"unsigned": 1})
        heal = SourceFileLoader("orionx_heal_t", str(ROOT / "scripts/healing/orionx-heal")).load_module()
        import contextlib
        import io
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            heal._print_rejections(self.e.status_file)
        self.assertIn("Rejected bus events: 1 (unsigned 1)", buf.getvalue())
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            heal._print_rejections(Path(self.tmp.name) / "none.json")
        self.assertIn("unknown", buf.getvalue())

    def test_a_rejection_does_no_other_work(self):
        writes = []
        self.e.record = lambda **k: writes.append(k)
        self.e.publish_status = lambda *a, **k: writes.append("status")
        self.e.handle_event(crit_ids(src_ip="203.0.113.9"), now=time.time())
        self.assertEqual(writes, [])


class Postured(unittest.TestCase):
    def test_scan_source_reader_counts_what_it_refuses(self):
        mod = SourceFileLoader("postured_be", str(ROOT / "scripts/awareness/orionx-postured")).load_module()
        mod.BUS_REJECTED = rain_lib.RejectCounter("orionx-postured", log=lambda _l: None)
        now = time.time()
        ev = {"ts": now, "severity": "warning", "source": "firewall", "category": "scan",
              "message": "port scan from 203.0.113.9"}
        lines = [json.dumps(ev), json.dumps(dict(ev, **{rain_lib.AUTH_FIELD: "nope"}))]
        orig = mod.rain_lib.read_bus_key
        self.addCleanup(setattr, mod.rain_lib, "read_bus_key", orig)   # rain_lib is shared
        mod.rain_lib.read_bus_key = lambda *a, **k: (KEY, "")
        mod.scan_sources_from_bus(lines, now)
        self.assertEqual(mod.BUS_REJECTED.snapshot()["by_reason"], {"unsigned": 1, "bad_signature": 1})


class ZeekTrigger(unittest.TestCase):
    def zeek(self, note, sev="critical", **detail):
        return {"ts": time.time(), "severity": sev, "source": "zeek", "category": "ids",
                "message": f"{note} from 198.51.100.7",
                "detail": dict({"engine": "zeek", "note": note, "src_ip": "198.51.100.7"}, **detail)}

    def test_attacker_notes_propose_block_ip(self):
        for note in ("SSH::Password_Guessing", "FTP::Bruteforcing", "HTTP::SQL_Injection_Attacker",
                     "Heartbleed::SSL_Heartbeat_Attack"):
            with self.subTest(note):
                p = hl.match_event(self.zeek(note))
                self.assertIsNotNone(p)
                self.assertEqual((p.playbook, p.target), ("block_ip", "198.51.100.7"))

    def test_notes_whose_source_is_not_the_attacker_propose_nothing(self):
        for note in ("HTTP::SQL_Injection_Victim", "Intel::Intel", "Heartbleed::SSL_Heartbeat_Odd_Length"):
            with self.subTest(note):
                self.assertIsNone(hl.match_event(self.zeek(note)))

    def test_floor_self_traffic_and_bad_addresses(self):
        self.assertIsNone(hl.match_event(self.zeek("SSH::Password_Guessing", sev="warning")))
        self.assertIsNone(hl.match_event(self.zeek("SSH::Password_Guessing", origin="self")))
        self.assertIsNone(hl.match_event(self.zeek("SSH::Password_Guessing", src_ip="not-an-ip")))
        self.assertIsNone(hl.match_event(self.zeek("Scan::Port_Scan", sev="warning")))

    def test_postured_carries_dest_port_for_zeek(self):
        mod = SourceFileLoader("postured_z", str(ROOT / "scripts/awareness/orionx-postured")).load_module()
        cls = next(c for c in vars(mod).values() if isinstance(c, type) and hasattr(c, "_alert_detail"))
        d = cls._alert_detail(SimpleNamespace(deck_addrs=set()),
                              {"src_ip": "198.51.100.7", "dest_ip": "192.168.4.20", "proto": "tcp",
                               "note": "SSH::Password_Guessing", "msg": "guessing", "dest_port": 22},
                              "zeek", ("", ""))
        self.assertEqual((d["dest_port"], d["note"]), (22, "SSH::Password_Guessing"))


if __name__ == "__main__":
    unittest.main()
