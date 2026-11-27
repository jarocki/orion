"""The Cockpit Tools tab's optional-tool rules (#199): words, colours, buttons, progress, outcomes. No GTK."""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from control_center.helpers import optional_view as V  # noqa: E402


def tool(**kw):
    base = {"id": "zeek", "name": "Zeek", "group": "network", "state": "not_installed", "reason": "",
            "version": "", "can_install": True, "can_uninstall": False, "install_reason": "",
            "uninstall_reason": "", "size": "~180 MB", "progress": None, "record": None}
    base.update(kw)
    return base


class Tiles(unittest.TestCase):
    def test_not_installed_offers_install_with_size(self):
        t = V.tile(tool())
        self.assertEqual((t["word"], t["button"], t["action"], t["enabled"]), ("NOT INSTALLED", "Install", "install", True))
        self.assertEqual(t["line"], "~180 MB")

    def test_offline_install_is_disabled_and_says_why(self):
        t = V.tile(tool(can_install=False, install_reason="needs network: no network route (air-gapped)"))
        self.assertFalse(t["enabled"])
        self.assertEqual(t["line"], "needs network: no network route (air-gapped)")
        self.assertEqual(t["tip"], t["line"])

    def test_active_with_record_offers_uninstall(self):
        t = V.tile(tool(state="active", version="9.0.1", can_uninstall=True))
        self.assertEqual((t["word"], t["color"], t["line"], t["button"], t["enabled"]),
                         ("ACTIVE", V.GREEN, "9.0.1", "Uninstall", True))

    def test_shipped_tool_cannot_be_uninstalled_and_says_so(self):
        t = V.tile(tool(state="installed", version="9.0.1", can_uninstall=False,
                        uninstall_reason="shipped with the image or installed outside orionx-optional"))
        self.assertFalse(t["enabled"])
        self.assertEqual(t["line"], "9.0.1 · shipped with the image")
        self.assertIn("shipped with the image", t["tip"])

    def test_degraded_shows_the_failing_check_in_amber(self):
        t = V.tile(tool(state="degraded", reason="virus signatures: 41 days old (limit 14)", can_uninstall=True))
        self.assertEqual((t["word"], t["color"], t["line"]), ("DEGRADED", V.AMBER, "virus signatures: 41 days old (limit 14)"))

    def test_failed_offers_retry_with_the_reason_in_red(self):
        t = V.tile(tool(state="failed", reason="installer exited 100: E: Unable to locate package x"))
        self.assertEqual((t["word"], t["color"], t["button"], t["action"]), ("FAILED", V.RED, "Retry", "install"))
        self.assertIn("Unable to locate", t["line"])

    def test_working_pulses_with_step_and_offers_details(self):
        t = V.tile(tool(state="working", progress={"action": "install", "n": 3, "m": 5, "step": "run installer",
                                                     "line": "apt-get install zeek-core"}))
        self.assertEqual((t["word"], t["pulse"], t["button"], t["action"], t["line"]),
                         ("INSTALLING 3/5", True, "Details", None, "apt-get install zeek-core"))
        self.assertEqual(V.tile(tool(state="working", progress={"action": "uninstall", "n": 2, "m": 5}))["word"],
                         "REMOVING 2/5")

    def test_blocked_tool(self):
        t = V.tile(tool(can_install=False, install_reason="blocked: owner decision"))
        self.assertFalse(t["enabled"])
        self.assertEqual(t["line"], "blocked: owner decision")


class Summary(unittest.TestCase):
    STATUS = {"groups": [{"id": "network", "name": "Network & hunting"}, {"id": "comms", "name": "Team comms"},
                         {"id": "deck", "name": "Deck"}],
              "tools": [tool(), tool(id="geoip", state="active"), tool(id="element", group="comms", state="failed")],
              "summary": {"active": 1, "installed": 0, "degraded": 0, "failed": 1, "working": 0, "not_installed": 1}}

    def test_grouped_keeps_catalogue_order_and_drops_empty_groups(self):
        g = V.grouped(self.STATUS)
        self.assertEqual([x[0]["id"] for x in g], ["network", "comms"])
        self.assertEqual([t["id"] for t in g[0][1]], ["zeek", "geoip"])

    def test_summary_line(self):
        self.assertEqual(V.summary_line(self.STATUS), "3 optional · 1 ready · 1 failed")

    def test_network_line(self):
        self.assertEqual(V.network_line(self.STATUS)[1], V.GREEN)
        off = dict(self.STATUS, tools=[tool(can_install=False, install_reason="needs network: no network route (air-gapped)")])
        self.assertEqual(V.network_line(off), ("network OFFLINE (no route): installs wait for a connection", V.RED))
        dns = dict(self.STATUS, tools=[tool(install_reason="needs network: pypi.org does not resolve")])
        self.assertEqual(V.network_line(dns)[1], V.AMBER)


class Actions(unittest.TestCase):
    def test_action_argv_is_pkexec_on_the_pinned_helper(self):
        self.assertEqual(V.action_argv("install", "zeek"),
                         ["pkexec", "/opt/orionx/scripts/optional/orionx-optional", "install", "zeek"])
        with self.assertRaises(ValueError):
            V.action_argv("purge", "zeek")

    def test_pinned_path_matches_the_polkit_policy(self):
        policy = (ROOT / "iso/config/includes.chroot/usr/share/polkit-1/actions/org.orionx.optional.policy").read_text()
        self.assertIn(f">{V.HELPER}</annotate>", policy)

    def test_parse_line(self):
        self.assertEqual(V.parse_line("PROGRESS 3/5 run installer\n"), ("progress", 3, 5, "run installer"))
        self.assertEqual(V.parse_line("RESULT ok Zeek installed"), ("result", True, "Zeek installed"))
        self.assertEqual(V.parse_line("RESULT failed needs network: x"), ("result", False, "needs network: x"))
        self.assertEqual(V.parse_line("| apt-get install zeek-core"), ("log", "apt-get install zeek-core"))
        self.assertEqual(V.parse_line("PROGRESS garbage"), ("log", "PROGRESS garbage"))

    def test_outcomes(self):
        self.assertEqual(V.outcome("Zeek", "install", 0, ("result", True, "Zeek installed")),
                         ("✓ Zeek installed", "ok", True))
        self.assertEqual(V.outcome("Zeek", "install", 1, ("result", False, "needs network: x"))[:2],
                         ("✗ Zeek install failed: needs network: x", "error"))
        self.assertEqual(V.outcome("Zeek", "uninstall", 126, None),
                         ("Zeek: uninstall not started, authentication was dismissed", "info", False))
        self.assertEqual(V.outcome("Zeek", "install", 127, None)[2], False)
        self.assertEqual(V.outcome("Zeek", "install", 3, None)[1], "error")

    def test_confirm_text_says_what_goes(self):
        txt = V.confirm_text(tool(name="Ghidra", record={"apt": 41, "pip": 0, "paths": 2}))
        self.assertIn("Uninstall Ghidra?", txt)
        self.assertIn("41 Debian packages, 2 files or folders", txt)
        self.assertNotIn("pip", txt)
        self.assertIn("refused if it would take anything else", txt)


class Collect(unittest.TestCase):
    def test_collect_reads_json_and_reports_errors(self):
        good = {"groups": [], "tools": [], "summary": {}}
        ok = V.collect(run=lambda *a, **k: SimpleNamespace(returncode=0, stdout=json.dumps(good), stderr=""), helper="x")
        self.assertEqual(ok, good)
        bad = V.collect(run=lambda *a, **k: SimpleNamespace(returncode=2, stdout="", stderr="catalogue invalid"), helper="x")
        self.assertIn("exited 2: catalogue invalid", bad["error"])

        def missing(*a, **k):
            raise FileNotFoundError

        self.assertIn("not on this deck", V.collect(run=missing, helper="x")["error"])

    def test_collect_against_the_real_helper(self):
        import os
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            shutil.copy(ROOT / "iso/config/includes.chroot/opt/orionx/osint/links.json", Path(td) / "links.json")
            env = dict(os.environ, ORIONX_OPTIONAL_ROOT=td)
            r = V.collect(helper=str(ROOT / "scripts/optional/orionx-optional"),
                          run=lambda argv, **k: subprocess.run([sys.executable] + argv, env=env, **k))
        self.assertNotIn("error", r, r)
        self.assertEqual(len(V.grouped(r)), 4)


if __name__ == "__main__":
    unittest.main()
