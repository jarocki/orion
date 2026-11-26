"""#202(a): one resource threshold table; each crossing announced once (DEC-PHASE13-063)."""
from __future__ import annotations

import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/awareness"))
import deck_vitals as V  # noqa: E402


class Grading(unittest.TestCase):
    def test_one_table_grades_every_resource(self):
        self.assertEqual([V.grade("mem", p) for p in (79.9, 80, 89.9, 90)], ["ok", "amber", "amber", "red"])
        self.assertEqual([V.grade("disk", p) for p in (84, 85, 95)], ["ok", "amber", "red"])
        self.assertEqual(V.grade("mem", None), "unknown")
        self.assertEqual(V.grade("nope", 50), "unknown")

    def test_battery_counts_only_when_discharging(self):
        on_ac = {"battery": {"pct": 5.0, "status": "Charging"}}
        self.assertIsNone(V.resource_pcts(on_ac)["battery"])
        low = {"battery": {"pct": 8.0, "status": "Discharging"}}
        self.assertEqual(V.resource_levels(low)["battery"], {"pct": 92.0, "level": "red"})
        self.assertEqual(V.resource_levels({"battery": {"pct": 15.0, "status": "Discharging"}})["battery"]["level"], "amber")

    def test_battery_reader(self):
        with tempfile.TemporaryDirectory() as d:
            for name, typ in (("AC", "Mains"), ("BAT0", "Battery")):
                Path(d, name).mkdir()
                Path(d, name, "type").write_text(typ + "\n")
            Path(d, "BAT0", "capacity").write_text("64\n")
            Path(d, "BAT0", "status").write_text("Discharging\n")
            self.assertEqual(V.battery(read=lambda p: Path(p).read_text() if Path(p).exists() else "", root=d),
                             {"pct": 64.0, "status": "Discharging"})
        self.assertIsNone(V.battery(root="/nonexistent/power_supply"))

    def test_collect_never_raises_with_a_failing_reader(self):
        def boom(_p):
            raise OSError("unreadable")
        v = V.collect(read=boom, run=lambda *a, **k: "")
        self.assertIn("battery", v)


class CrossingsTest(unittest.TestCase):
    def test_up_crossings_are_announced_once(self):
        c = V.Crossings()
        self.assertEqual(c.update({"mem": 70}, 0), [])
        self.assertEqual(c.update({"mem": 82}, 10), [("mem", "ok", "amber", 82)])
        self.assertEqual(c.update({"mem": 85}, 20), [])            # still amber: silent
        self.assertEqual(c.update({"mem": 93}, 30), [("mem", "amber", "red", 93)])
        self.assertEqual(c.update({"mem": 96}, 40), [])

    def test_hysteresis_prevents_flapping(self):
        c = V.Crossings()
        c.update({"mem": 91}, 0)
        self.assertEqual(c.update({"mem": 89.5}, 10), [])           # within 5 points of red: stays red
        self.assertEqual(c.update({"mem": 90.2}, 20), [])
        self.assertEqual(c.update({"mem": 84}, 30), [("mem", "red", "amber", 84)])
        self.assertEqual(c.update({"mem": 76}, 40), [])             # within 5 of amber: stays amber
        self.assertEqual(c.update({"mem": 74}, 50), [("mem", "amber", "ok", 74)])

    def test_cpu_must_be_sustained(self):
        c = V.Crossings()
        self.assertEqual(c.update({"cpu": 99}, 0), [])
        self.assertEqual(c.update({"cpu": 99}, 30), [])
        self.assertEqual(c.update({"cpu": 20}, 40), [])             # a spike: never announced
        self.assertEqual(c.update({"cpu": 99}, 50), [])
        self.assertEqual(c.update({"cpu": 99}, 111), [("cpu", "ok", "red", 99)])

    def test_unknown_values_are_ignored(self):
        self.assertEqual(V.Crossings().update({"mem": None, "battery": None}, 0), [])


class Messages(unittest.TestCase):
    def test_wording_and_severity(self):
        v = {"disk": {"free_bytes": 900 * 1024 * 1024}}
        sev, msg = V.crossing_event("disk", "amber", "red", 96.0, v)
        self.assertEqual(sev, "critical")
        self.assertTrue(msg.startswith("Deck disk / RED: 96% used, "))
        self.assertIn("this is RAM", msg)
        self.assertEqual(V.crossing_event("mem", "ok", "amber", 82.0, {})[0], "warning")
        self.assertEqual(V.crossing_event("mem", "amber", "ok", 70.0, {}), ("notice", "Deck memory back to normal (70%)"))
        self.assertIn("8% left", V.crossing_event("battery", "amber", "red", 92.0, {})[1])


class Postured(unittest.TestCase):
    """orionx-postured feeds the tracker and publishes each crossing (signed: it runs as root)."""

    def test_check_resources_publishes_each_crossing_once(self):
        mod = SourceFileLoader("postured_ra", str(ROOT / "scripts/awareness/orionx-postured")).load_module()
        emitted = []
        fake = SimpleNamespace(resources=V.Crossings(), _cpu_prev=None,
                               emit=lambda *a, **k: emitted.append((a, k)))
        snap = {"mem": {"used_pct": 92.0}, "disk": {"used_pct": 40.0, "free_bytes": 1}, "cpu_pct": 10.0,
                "cpu_sample": (1, 2), "battery": None}
        cls = next(c for c in vars(mod).values() if isinstance(c, type) and hasattr(c, "check_resources"))
        cls.check_resources(fake, 0.0, collect=lambda prev: snap)
        self.assertEqual(len(emitted), 1)
        args, kw = emitted[0]
        self.assertEqual((args[0], args[1]), ("critical", "health"))
        self.assertEqual(kw["source"], "deck")
        self.assertEqual(kw["detail"], {"resource": "mem", "level": "red", "pct": 92.0})
        self.assertEqual(fake._cpu_prev, (1, 2))

    def test_a_failing_collect_does_not_stop_enforcement(self):
        mod = SourceFileLoader("postured_rb", str(ROOT / "scripts/awareness/orionx-postured")).load_module()
        cls = next(c for c in vars(mod).values() if isinstance(c, type) and hasattr(c, "check_resources"))
        fake = SimpleNamespace(resources=V.Crossings(), _cpu_prev=None, emit=lambda *a, **k: None)

        def boom(prev):
            raise RuntimeError("no /proc")
        self.assertEqual(cls.check_resources(fake, 0.0, collect=boom), [])


if __name__ == "__main__":
    unittest.main()
