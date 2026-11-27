"""#202(b): trends, tasks, network changes and the deck verdict (DEC-PHASE13-064). Pure; no GTK."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/cockpit"))
sys.path.insert(0, str(ROOT / "scripts/awareness"))
import cockpit_lib as L  # noqa: E402


class TrendTest(unittest.TestCase):
    def test_samples_coalesce_prune_and_give_a_delta_after_a_minute(self):
        t = L.Trend()
        t.add(0, 10)
        t.add(5, 12)                     # same step: replaces
        self.assertEqual(t.values(), [12])
        t.add(30, 20)
        self.assertIsNone(t.delta())     # under a minute of history
        t.add(70, 40)
        self.assertEqual(t.delta(), 28)
        for s in range(80, 1200, 10):
            t.add(s, 40)
        self.assertLessEqual(t.points[-1][0] - t.points[0][0], L.TREND_WINDOW)
        self.assertEqual(t.delta(), 0)

    def test_words(self):
        self.assertEqual(L.trend_text(31.2), "↑ +31 in 15 min")
        self.assertEqual(L.trend_text(-12), "↓ -12 in 15 min")
        self.assertEqual(L.trend_text(0.1), "→ steady")
        self.assertEqual(L.trend_text(None), "")


class SourcesAndNetwork(unittest.TestCase):
    def test_active_and_new_sources(self):
        seen = {}
        rows = [{"ip": "203.0.113.4", "last_seen": 1000, "events": 40}, {"ip": "198.51.100.7", "last_seen": 990, "events": 3},
                {"ip": "192.0.2.1", "last_seen": 0, "events": 9}]
        c = L.source_counts(rows, seen, 1000)
        self.assertEqual(c, {"active": 2, "new": 2, "top": "203.0.113.4"})
        c2 = L.source_counts(rows[:1], seen, 1000 + L.TREND_WINDOW + 5)
        self.assertEqual(c2["new"], 0)   # seen over 15 min ago: active, not new

    def test_new_hosts_only_after_the_baseline_and_gateway_change(self):
        seen, gw = {}, {}
        r = L.network_changes({"aa", "bb"}, seen, "192.168.4.1", gw, 100)
        self.assertEqual(r, {"new_hosts": [], "gateway_change": None})     # what was there at start is not new
        r = L.network_changes({"aa", "bb", "cc"}, seen, "192.168.4.1", gw, 200)
        self.assertEqual(r["new_hosts"], ["cc"])
        r = L.network_changes({"aa"}, seen, "10.0.0.1", gw, 300)
        self.assertEqual(r["gateway_change"], "gateway 192.168.4.1 → 10.0.0.1")
        r = L.network_changes({"aa"}, seen, "10.0.0.1", gw, 300 + L.TREND_WINDOW + 1)
        self.assertEqual(r, {"new_hosts": [], "gateway_change": None})


class Tasks(unittest.TestCase):
    def test_only_running_work_becomes_a_task(self):
        states = [{"id": "zeek", "state": "running", "action": "install", "n": 3, "m": 5, "line": "apt-get install"},
                  {"id": "floss", "state": "ok", "action": "install", "n": 5, "m": 5}]
        out = L.tasks_from(states, 0)
        self.assertEqual([(t["name"], t["step"], t["frac"]) for t in out], [("install zeek", "apt-get install", 0.6)])

    def test_state_files_with_a_dead_pid_are_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "zeek.json").write_text(json.dumps({"state": "running", "pid": os.getpid(), "n": 1, "m": 5}))
            Path(d, "ghost.json").write_text(json.dumps({"state": "running", "pid": 2 ** 22 + 9, "n": 1, "m": 5}))
            Path(d, "done.json").write_text(json.dumps({"state": "ok", "pid": os.getpid()}))
            Path(d, "junk.json").write_text("{")
            self.assertEqual([s["id"] for s in L.read_task_states(d)], ["zeek"])
        self.assertEqual(L.read_task_states("/nonexistent/dir"), [])


class Verdict(unittest.TestCase):
    calm = {"mem": {"pct": 40.0, "level": "ok"}}

    def test_nominal_busy_watch_degraded_attack(self):
        self.assertEqual(L.deck_verdict(5, self.calm, {}, [])[:2], ("NOMINAL", ""))
        self.assertEqual(L.deck_verdict(5, self.calm, {}, [{"name": "x"}])[:2], ("BUSY", "1 task running"))
        w = L.deck_verdict(5, {"mem": {"pct": 83.0, "level": "amber"}}, {}, [])
        self.assertEqual(w[:2], ("WATCH", "mem 83%"))
        d = L.deck_verdict(5, {"disk": {"pct": 96.0, "level": "red"}}, {}, [])
        self.assertEqual((d[0], d[2]), ("DEGRADED", L.RED))
        a = L.deck_verdict(72, {"disk": {"pct": 96.0, "level": "red"}}, {"active": 3, "new": 2}, [], 31)
        self.assertEqual(a[0], "UNDER ATTACK")
        self.assertEqual(a[1], "threat 72 (+31) · 3 sources, 2 new · disk 96%")

    def test_rising_new_sources_alone_mean_attack(self):
        self.assertEqual(L.deck_verdict(30, self.calm, {"active": 4, "new": 3}, [], 15)[0], "UNDER ATTACK")
        self.assertEqual(L.deck_verdict(30, self.calm, {"active": 4, "new": 3}, [], 0)[0], "WATCH")

    def test_battery_reads_as_charge_left(self):
        v = L.deck_verdict(0, {"battery": {"pct": 92.0, "level": "red"}}, {}, [])
        self.assertEqual(v[:2], ("DEGRADED", "battery 8% left"))


class Layout(unittest.TestCase):
    def test_no_tasks_is_the_old_layout_and_tasks_add_a_strip_on_top(self):
        base = L.live_layout(1524, 641)
        self.assertNotIn("tasks", base)
        lay = L.live_layout(1524, 641, tasks_h=L.TASKS_H)
        self.assertEqual(lay["tasks"], (16, 16, 1524 - 32, L.TASKS_H))
        for name in ("events", "actions"):
            self.assertEqual(lay[name][1], 16 + L.TASKS_H + 16)
        self.assertGreaterEqual(lay["systems"][3], L.SYSTEMS_MIN_H)
        bottoms = [y + h for (_x, y, _w, h) in lay.values()]
        self.assertLessEqual(max(bottoms), 641 - 16 + 0.5)

    def test_attack_sources_lists_every_source(self):
        ev = [{"ts": 1000.0 + i, "severity": "warning", "source": "suricata", "category": "ids", "message": "m",
               "detail": {"src_ip": f"203.0.113.{i}"}} for i in range(12)]
        s = L.attack_sources(ev, now=1020.0)
        self.assertEqual((s["total"], len(s["all"])), (12, 12))
        self.assertLessEqual(len(s["rows"]), len(s["all"]))


if __name__ == "__main__":
    unittest.main()
