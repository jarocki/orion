"""#201: engine state for both surfaces, the commands that change it, and the events each writer publishes."""
from __future__ import annotations

import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
HEAL = ROOT / "scripts/healing"


class EngineView(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.auto = Path(self.tmp.name) / "autonomy.json"
        os.environ["ORIONX_AUTONOMY_FILE"] = str(self.auto)
        self.addCleanup(os.environ.pop, "ORIONX_AUTONOMY_FILE", None)
        sys.path.insert(0, str(HEAL))
        import healing_lib
        importlib.reload(healing_lib)
        import engine_view
        self.EV = importlib.reload(engine_view)
        self.hl = healing_lib

    def test_unset_classes_are_off_and_set_ones_are_read(self):
        self.auto.write_text(json.dumps({"block_ip": "confirm"}))
        st = self.EV.engine_state(wants=Path(self.tmp.name) / "nope", log=Path(self.tmp.name) / "nolog")
        lv = {c["id"]: (c["level"], c["set"]) for c in st["autonomy"]["classes"]}
        self.assertEqual(lv["block_ip"], ("confirm", True))
        self.assertEqual(lv["kill_process"], ("off", False))
        self.assertEqual((st["warmup"]["enabled_at_boot"], st["warmup"]["last_run"]), (False, None))
        self.assertEqual(st["warmup"]["enable"], "systemctl enable nebula-warmup.service")

    def test_argv_refuses_unknown_classes_and_levels(self):
        self.assertEqual(self.EV.autonomy_argv("block_ip", "propose"), ["orionx-heal", "autonomy", "block_ip", "propose"])
        for bad in (("rm_rf", "off"), ("block_ip", "always")):
            with self.assertRaises(ValueError):
                self.EV.autonomy_argv(*bad)
        self.assertEqual(self.EV.boot_argv(True), ["systemctl", "enable", "nebula-warmup.service"])
        self.assertEqual(self.EV.boot_argv(False), ["systemctl", "disable", "nebula-warmup.service"])

    def test_event_wording_and_severity(self):
        self.assertEqual(self.EV.consent_event("block_ip", "off", "confirm"),
                         ("notice", "Auto-healing consent: block_ip off → confirm"))
        sev, msg = self.EV.consent_event("kill_process", "confirm", "autonomous")
        self.assertEqual(sev, "warning")
        self.assertIn("WITHOUT asking", msg)
        self.assertEqual(self.EV.boot_event(True, 0)[0], "notice")
        self.assertEqual(self.EV.boot_event(False, 1), ("warning", "Nebula warm-up at boot NOT disabled: systemctl exited 1"))


class Writers(unittest.TestCase):
    """The writers publish: orionx-heal autonomy (consent) and nebula's warm-up (outcome)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        d = Path(self.tmp.name)
        (d / "bin").mkdir()
        ev = d / "bin/orionx-event"
        ev.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$EVLOG"\n')
        ev.chmod(0o755)
        self.events = d / "events.log"
        self.env = dict(os.environ, PATH=f"{d / 'bin'}:{os.environ['PATH']}", EVLOG=str(self.events),
                        ORIONX_AUTONOMY_FILE=str(d / "autonomy.json"), HOME=str(d))

    def heal(self, *args):
        return subprocess.run([sys.executable, str(HEAL / "orionx-heal"), "autonomy", *args], env=self.env,
                              capture_output=True, text=True, timeout=30)

    def lines(self):
        return self.events.read_text().splitlines() if self.events.exists() else []

    def test_consent_change_is_published_once_per_real_change(self):
        r = self.heal("block_ip", "confirm")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.lines(), ["--severity notice --source heal --category heal "
                                        "Auto-healing consent: block_ip off → confirm"])
        self.heal("block_ip", "confirm")            # no change, no event
        self.assertEqual(len(self.lines()), 1)
        self.heal("kill_process", "autonomous")
        self.assertTrue(self.lines()[-1].startswith("--severity warning"))
        self.assertIn("kill_process off → autonomous (acts WITHOUT asking)", self.lines()[-1])

    def test_a_refused_change_publishes_nothing(self):
        r = self.heal("block_ip", "always")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.lines(), [])

    def test_warmup_outcome_is_published(self):
        sys.path.insert(0, str(ROOT / "scripts"))
        from nebula import warmup as W
        seen = []
        W.publish_outcome(True, run=lambda argv, **k: (seen.append(argv), SimpleNamespace(returncode=0))[1])
        W.publish_outcome(False, run=lambda argv, **k: (seen.append(argv), SimpleNamespace(returncode=0))[1])
        self.assertEqual(seen[0][:7], ["orionx-event", "--severity", "notice", "--source", "nebula", "--category", "service"])
        self.assertEqual(seen[1][2], "warning")
        self.assertIn("FAILED", seen[1][-1])
        W.run_warmup = lambda: False
        calls = []
        W.publish_outcome = lambda ok, run=None: calls.append(ok)
        self.assertEqual(W.main([]), 1)
        self.assertEqual(calls, [False])          # the boot unit's path publishes too


if __name__ == "__main__":
    unittest.main()
