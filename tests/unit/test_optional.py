"""orionx-optional (#197, #198): catalogue, status rules, install record, uninstall safety, events.

Pure rules are tested directly. The root flows (do_install / do_uninstall)
run against a fixture tree and stub dpkg-query, apt-get, python3 -m pip,
systemctl and orionx-event on PATH; nothing touches the host's packages.
"""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import xml.dom.minidom
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/optional"))
import optional_lib as O  # noqa: E402

CLI = ROOT / "scripts/optional/orionx-optional"
CATALOGUE = ROOT / "iso/config/includes.chroot/opt/orionx/osint/links.json"
POLICY = ROOT / "iso/config/includes.chroot/usr/share/polkit-1/actions/org.orionx.optional.policy"
OPTIONAL = ROOT / "iso/config/includes.chroot/opt/orionx/optional"


def load_cli():
    loader = importlib.machinery.SourceFileLoader("orionx_optional_cli", str(CLI))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def status(t, **kw):
    base = dict(record=None, live=None, net="ok", exists=lambda p: False, has_module=lambda m: False,
                run=lambda argv: 0, mtime=lambda p: time.time(), unit_active=lambda u: False,
                version_of=lambda t: "1.0", now=time.time())
    base.update(kw)
    return O.tool_status(t, **base)


TOOL = {"id": "demo", "name": "Demo", "group": "network", "runtime_path": "/opt/orionx/optional/install-demo.sh",
        "probe": ["/opt/demo/bin/demo"], "needs_host": "example.org", "owns": ["/opt/demo"],
        "health": [{"run": ["/opt/demo/bin/demo", "--version"], "what": "demo runs"}]}


class Catalogue(unittest.TestCase):
    def test_shipped_catalogue_is_valid_and_grouped_as_decided(self):
        groups, tools = O.load_catalogue(CATALOGUE)
        self.assertEqual([g["name"] for g in groups],
                         ["Network & hunting", "Malware analysis", "Team comms", "Deck: voice & peripherals"])
        by = {g["id"]: sorted(t["id"] for t in tools if t["group"] == g["id"]) for g in groups}
        self.assertEqual(by, {"network": ["duckdb", "geoip", "zeek"],
                              "malware": ["clamav", "floss", "ghidra", "trid"],
                              "comms": ["element", "gomuks"], "deck": ["bluetooth", "piper-voice"]})

    def test_every_tool_names_a_shipped_installer_and_the_helper_command(self):
        _g, tools = O.load_catalogue(CATALOGUE)
        for t in tools:
            with self.subTest(t["id"]):
                self.assertTrue((OPTIONAL / Path(t["runtime_path"]).name).is_file())
                self.assertEqual(t["command"], f"sudo orionx-optional install {t['id']}")

    def test_validation_catches_what_root_relies_on(self):
        g = [{"id": "network", "name": "N"}]
        bad = [dict(TOOL, id="Bad ID"), dict(TOOL, id="x1", group="nope"),
               dict(TOOL, id="x2", runtime_path="/tmp/evil.sh"), dict(TOOL, id="x3", owns=["/etc/passwd"]),
               dict(TOOL, id="x4", probe=[]), dict(TOOL, id="x5", needs_host=""),
               dict(TOOL, id="x6", health=[{"run": ["true"]}]),
               dict(TOOL, id="x7", runtime_path="/opt/orionx/optional/install-../../x.sh")]
        problems = O.validate(g, bad)
        for needle in ("id must match", "group 'nope'", "runtime_path", "/etc/passwd", "probe must",
                       "needs_host", "health check", ):
            self.assertTrue(any(needle in p for p in problems), needle)
        self.assertEqual(sum("runtime_path" in p for p in problems), 2)
        self.assertEqual(O.validate(g, [TOOL]), [])

    def test_removable_prefixes(self):
        for ok in ("/opt/ghidra", "/usr/local/bin/floss", "/var/lib/orionx/geoip", "/usr/bin/zeek"):
            self.assertTrue(O.removable(ok), ok)
        for no in ("/", "/opt", "/opt/", "/etc/passwd", "/opt/../etc", "/usr/bin", "relative/x", "/opt/a/../b"):
            self.assertFalse(O.removable(no), no)

    def test_find_tool_refuses_non_ids(self):
        _g, tools = O.load_catalogue(CATALOGUE)
        self.assertEqual(O.find_tool(tools, "zeek")["id"], "zeek")
        for bad in ("../zeek", "zeek;rm", "", "ZEEK", "nosuch"):
            with self.assertRaises(O.CatalogueError):
                O.find_tool(tools, bad)

    def test_trusted_file_rules(self):
        def fake(uid, mode):
            return lambda p: SimpleNamespace(st_uid=uid, st_mode=mode)
        self.assertEqual(O.trusted_file(Path("/x"), lstat=fake(0, stat.S_IFREG | 0o644)), "")
        self.assertIn("not owned by root", O.trusted_file(Path("/x"), lstat=fake(1000, stat.S_IFREG | 0o644)))
        self.assertIn("writable by group or others", O.trusted_file(Path("/x"), lstat=fake(0, stat.S_IFREG | 0o664)))
        self.assertIn("symlink", O.trusted_file(Path("/x"), lstat=fake(0, stat.S_IFLNK | 0o777)))


class Status(unittest.TestCase):
    def test_not_installed_offline_says_why_and_cannot_install(self):
        s = status(TOOL, net="no network route (air-gapped)")
        self.assertEqual((s["state"], s["can_install"]), ("not_installed", False))
        self.assertIn("needs network: no network route", s["install_reason"])

    def test_installed_healthy_is_installed_and_only_a_record_allows_uninstall(self):
        s = status(TOOL, exists=lambda p: p == "/opt/demo/bin/demo")
        self.assertEqual((s["state"], s["can_uninstall"]), ("installed", False))
        self.assertIn("shipped with the image", s["uninstall_reason"])
        s = status(TOOL, exists=lambda p: True, record={"apt": ["a", "b"], "pip": [], "paths": ["/opt/demo"]})
        self.assertTrue(s["can_uninstall"])
        self.assertEqual(s["record"], {"apt": 2, "pip": 0, "paths": 1})  # what Uninstall would remove

    def test_health_failure_is_degraded_with_reason(self):
        s = status(TOOL, exists=lambda p: True, run=lambda argv: 3)
        self.assertEqual(s["state"], "degraded")
        self.assertEqual(s["reason"], "demo runs: failed (exit 3)")

    def test_active_unit_is_active(self):
        t = dict(TOOL, active={"units": ["demo@*.service"]})
        self.assertEqual(status(t, exists=lambda p: True, unit_active=lambda u: True)["state"], "active")

    def test_running_action_is_working_even_when_pid_belongs_to_root(self):
        live = {"state": "running", "pid": 1, "action": "install", "step": "run installer", "n": 3, "m": 5}
        s = status(TOOL, live=live, alive=O.pid_alive)  # pid 1: EPERM for a user, still alive
        self.assertEqual(s["state"], "working")
        self.assertEqual(s["progress"]["n"], 3)
        dead = status(TOOL, live=dict(live, pid=2 ** 22 + 7), alive=O.pid_alive)
        self.assertEqual(dead["state"], "not_installed")

    def test_failed_install_is_failed_and_partial_record_can_be_cleaned(self):
        live = {"state": "failed", "action": "install", "reason": "installer exited 1: boom", "log": "/l"}
        s = status(TOOL, live=live, record={"apt": ["x"], "pip": [], "paths": []})
        self.assertEqual((s["state"], s["reason"], s["can_uninstall"]),
                         ("failed", "installer exited 1: boom", True))

    def test_blocked_tool_cannot_be_installed_and_says_why(self):
        s = status(dict(TOOL, blocked="owner decision pending"))
        self.assertEqual((s["can_install"], s["install_reason"]), (False, "blocked: owner decision pending"))

    def test_health_checks(self):
        now = time.time()
        kw = dict(run=lambda a: 0, exists=lambda p: True, mtime=lambda p: now - 20 * 86400,
                  unit_active=lambda u: True, now=now)
        self.assertEqual(O.check_health([{"fresh": "/nope/x", "max_days": 30, "what": "sigs"}], **kw), "")
        self.assertEqual(O.check_health([{"fresh": "/nope/x", "max_days": 14, "what": "sigs"}], **kw),
                         "sigs: 20 days old (limit 14)")
        self.assertIn("missing", O.check_health([{"exists": "/x", "what": "defs"}], **dict(kw, exists=lambda p: False)))
        self.assertIn("is not active", O.check_health([{"unit": "b.service", "what": "bt"}],
                                                      **dict(kw, unit_active=lambda u: False)))

    def test_summary_counts(self):
        sts = [{"state": "active"}, {"state": "failed"}, {"state": "failed"}]
        self.assertEqual(O.summary(sts)["failed"], 2)


class RecordAndPlan(unittest.TestCase):
    def test_record_holds_only_what_the_install_added(self):
        rec = O.make_record(TOOL, before_pkgs={"a:amd64"}, after_pkgs={"a:amd64", "b:amd64"},
                            before_pip={"numpy"}, after_pip={"numpy", "duckdb"},
                            created=["/opt/demo", "/etc/shadow"], version="1", ok=True, now=0)
        self.assertEqual((rec["apt"], rec["pip"], rec["paths"]), (["b:amd64"], ["duckdb"], ["/opt/demo"]))

    def test_dpkg_and_pip_parsers(self):
        self.assertEqual(O.parse_dpkg_installed("a:amd64 installed\nb:all config-files\nc:amd64 installed\n"),
                         {"a:amd64", "c:amd64"})
        self.assertEqual(O.parse_pip_list('[{"name":"DuckDB","version":"1"}]'), {"duckdb"})
        self.assertEqual(O.parse_pip_list("not json"), set())

    def test_apt_simulation_collateral_is_found_by_name(self):
        sim = "NOTE: x\nPurg zeek-core [9.0.1]\nRemv libfoo1 [2]\nPurg pulseaudio [17]\n"
        self.assertEqual(O.parse_apt_simulation(sim), {"zeek-core", "libfoo1", "pulseaudio"})
        self.assertEqual(O.collateral({"zeek-core", "libfoo1", "pulseaudio"}, ["zeek-core:amd64", "libfoo1:amd64"]),
                         ["pulseaudio"])

    def test_units_matching(self):
        listed = "orionx-zeek@eth0.service loaded active running x\norionx-zeek@wlan0.service loaded inactive dead y\nssh.service loaded"
        self.assertEqual(O.units_matching(["orionx-zeek@*.service"], listed),
                         ["orionx-zeek@eth0.service", "orionx-zeek@wlan0.service"])


class Events(unittest.TestCase):
    def test_start_success_failure_and_integrity_severities(self):
        self.assertEqual(O.event_for(TOOL, "install", "start", who="op")[:2], ("info", "Install Demo started by op"))
        sev, msg, det = O.event_for(TOOL, "install", "end", ok=True, version="1.2", seconds=41.6)
        self.assertEqual((sev, msg, det["ok"]), ("notice", "Demo installed (1.2) in 42 s", True))
        sev, msg, det = O.event_for(TOOL, "uninstall", "end", ok=False, reason="refused: x")
        self.assertEqual((sev, msg), ("warning", "Uninstall Demo FAILED: refused: x"))
        sev, msg, det = O.event_for(TOOL, "install", "end", ok=False, reason="key", integrity=True)
        self.assertEqual((sev, det["integrity"]), ("critical", True))

    def test_installer_error_takes_the_headline_and_flags_mismatch(self):
        lines = ["[install-zeek.sh] Fetching the OBS signing key...",
                 "ERROR: [install-zeek.sh] SIGNING KEY FINGERPRINT MISMATCH — refusing to trust this repo.",
                 "ERROR: [install-zeek.sh]   expected: F9FA", "ERROR: [install-zeek.sh] Do not work around this"]
        self.assertEqual(O.installer_error(lines),
                         ("SIGNING KEY FINGERPRINT MISMATCH — refusing to trust this repo.", True))
        self.assertEqual(O.installer_error(["E: Unable to locate package openjdk-17-jdk"]),
                         ("E: Unable to locate package openjdk-17-jdk", False))


class Policy(unittest.TestCase):
    def test_policy_pins_the_helper_and_caches_only_for_active_sessions(self):
        doc = xml.dom.minidom.parse(str(POLICY))
        actions = doc.getElementsByTagName("action")
        self.assertEqual([a.getAttribute("id") for a in actions], ["org.orionx.optional.manage"])
        d = {n.tagName: n.firstChild.data for n in actions[0].getElementsByTagName("defaults")[0].childNodes
             if n.nodeType == n.ELEMENT_NODE}
        self.assertEqual(d, {"allow_any": "no", "allow_inactive": "no", "allow_active": "auth_admin_keep"})
        ann = {a.getAttribute("key"): a.firstChild.data for a in actions[0].getElementsByTagName("annotate")}
        self.assertEqual(ann, {"org.freedesktop.policykit.exec.path": "/opt/orionx/scripts/optional/orionx-optional"})

    def test_hook_links_the_same_path(self):
        hook = (ROOT / "iso/config/hooks/live/0700-orionx-setup.hook.chroot").read_text()
        self.assertIn('["orionx-optional"]="/opt/orionx/scripts/optional/orionx-optional"', hook)


class Installers(unittest.TestCase):
    def test_known_breakages_are_fixed(self):
        ghidra = (OPTIONAL / "install-ghidra.sh").read_text()
        self.assertNotIn("orionx_apt_install openjdk-17", ghidra)
        self.assertIn("orionx_apt_install openjdk-21-jdk", ghidra)
        gomuks = (OPTIONAL / "install-gomuks.sh").read_text()
        self.assertIn('GOMUKS_SHA256=""', gomuks)  # refuses until the owner picks the artifact
        _g, tools = O.load_catalogue(CATALOGUE)
        self.assertIn("owner decision", O.find_tool(tools, "gomuks")["blocked"])
        trid = (OPTIONAL / "install-trid.sh").read_text()
        self.assertNotIn("TRID_DEF_SHA256", trid)
        self.assertIn('TRID_BIN_SHA256="3fb9ccfed650123f7bb5fc5a93ccbfcbc6ff98876cc659c8958c03a582467aa9"', trid)
        self.assertIn('"$def_entries" != "triddefs.trd"', trid)

    def test_one_bus_writer_for_installs(self):
        for f in sorted(OPTIONAL.glob("install-*.sh")):
            with self.subTest(f.name):
                self.assertNotIn("orionx-event", f.read_text().replace("orionx-event:", ""))


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="orionx-optional-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_cli(self, *args, env=None):
        e = dict(os.environ, ORIONX_OPTIONAL_ROOT=str(self.root), **(env or {}))
        return subprocess.run([sys.executable, str(CLI), *args], capture_output=True, text=True, env=e,
                              timeout=60, check=False)

    def test_status_json_from_a_fixture_catalogue(self):
        (self.root / "links.json").write_text(CATALOGUE.read_text())
        r = self.run_cli("status", "--json", "zeek", "trid")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual([t["id"] for t in d["tools"]], ["zeek", "trid"])
        self.assertEqual(len(d["groups"]), 4)
        for t in d["tools"]:
            self.assertIn(t["state"], ("not_installed", "installed", "active", "degraded"))

    def test_actions_refuse_without_root_and_on_bad_usage(self):
        if os.geteuid() == 0:
            self.skipTest("runs as a user")
        r = self.run_cli("install", "zeek")
        self.assertEqual(r.returncode, 4)
        self.assertIn("needs root", r.stderr)
        self.assertEqual(self.run_cli("install").returncode, 2)
        self.assertEqual(self.run_cli("install", "zeek", "--force").returncode, 2)
        self.assertEqual(self.run_cli("frobnicate").returncode, 2)


STUBS = {
    # dpkg-query: the installed set lives in $FIX/dpkg
    "dpkg-query": '#!/bin/sh\ncat "$FIX/dpkg"\n',
    # apt-get -s purge P...: prints what would go ($FIX/apt-extra adds collateral); purge -y removes
    "apt-get": ('#!/bin/sh\nif [ "$1" = "-s" ]; then shift 2; for p in "$@"; do echo "Purg ${p%%:*} [1]"; done;'
                ' [ -f "$FIX/apt-extra" ] && cat "$FIX/apt-extra"; exit 0; fi\n'
                'if [ "$1" = "purge" ]; then shift 2; for p in "$@"; do grep -v "^$p " "$FIX/dpkg" > "$FIX/d2";'
                ' mv "$FIX/d2" "$FIX/dpkg"; done; echo "purged $*"; exit 0; fi\nexit 9\n'),
    "systemctl": ('#!/bin/sh\necho "systemctl $*" >> "$FIX/systemctl.log"\n'
                  'if [ "$1" = list-units ]; then printf "demo@eth0.service loaded active running d\\n'
                  'demo@wlan0.service loaded inactive dead d\\nssh.service loaded active running s\\n"; fi\nexit 0\n'),
    "orionx-event": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIX/events.log"\nexit 0\n',
    "getent": '#!/bin/sh\nexit 0\n',
}


class RootFlows(unittest.TestCase):
    """do_install / do_uninstall on a fixture tree with stub system tools."""

    def setUp(self):
        self.cli = load_cli()
        self.tmp = tempfile.TemporaryDirectory(prefix="orionx-optional-root-")
        self.addCleanup(self.tmp.cleanup)
        self.fix = Path(self.tmp.name)
        self.opt = self.fix / "opt"
        bins = self.fix / "bin"
        bins.mkdir()
        for name, body in STUBS.items():
            (bins / name).write_text(body)
            (bins / name).chmod(0o755)
        (self.fix / "dpkg").write_text("base:amd64 installed\n")
        self.P = O.Paths(self.fix / "links.json", self.fix / "run", self.fix / "lib", self.fix / "log")
        self.tool = dict(TOOL, probe=[str(self.opt / "demo/bin/demo")], owns=[str(self.opt / "demo")],
                         health=[{"exists": str(self.opt / "demo/bin/demo"), "what": "demo binary"}])
        self.installer = self.fix / "install-demo.sh"
        self.tool["runtime_path"] = str(self.installer)
        self.env = {"PATH": f"{bins}:/usr/bin:/bin", "FIX": str(self.fix)}
        self.old_env = dict(os.environ)
        os.environ.update(self.env)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(self.old_env)))
        self.prefixes = O.REMOVABLE_PREFIXES
        O.REMOVABLE_PREFIXES = self.prefixes + (str(self.opt) + "/",)
        self.addCleanup(lambda: setattr(O, "REMOVABLE_PREFIXES", self.prefixes))
        self.cli.has_route = lambda: True

    def write_installer(self, body):
        self.installer.write_text("#!/bin/bash\nset -e\n" + body)

    def action(self, kind):
        return self.cli.Action(self.P, self.tool, kind)

    def events(self):
        f = self.fix / "events.log"
        return f.read_text().splitlines() if f.exists() else []

    def good_install(self):
        self.write_installer(f'echo "[install-demo.sh] adding demo"\nmkdir -p "{self.opt}/demo/bin"\n'
                             f'touch "{self.opt}/demo/bin/demo"\necho "demo-pkg:amd64 installed" >> "$FIX/dpkg"\n')
        a = self.action("install")
        a.emit("start")
        return self.cli.do_install(a, dict(os.environ))

    def test_install_records_exactly_what_it_added_and_publishes_start_and_success(self):
        self.assertEqual(self.good_install(), 0)
        rec = json.loads((self.P.record_dir / "demo.json").read_text())
        self.assertEqual((rec["apt"], rec["paths"], rec["complete"]), (["demo-pkg:amd64"], [str(self.opt / "demo")], True))
        ev = self.events()
        self.assertTrue(ev[0].startswith("--severity info --source optional --category tooling"))
        self.assertIn("--severity notice", ev[-1])
        self.assertIn("Demo installed", ev[-1])
        live = json.loads((self.P.state_dir / "demo.json").read_text())
        self.assertEqual((live["state"], live["n"], live["m"]), ("ok", 5, 5))

    def test_uninstall_removes_only_the_record_and_publishes(self):
        self.good_install()
        (self.fix / "events.log").unlink()
        a = self.action("uninstall")
        self.assertEqual(self.cli.do_uninstall(a, dict(os.environ)), 0)
        self.assertFalse((self.opt / "demo").exists())
        self.assertEqual((self.fix / "dpkg").read_text(), "base:amd64 installed\n")
        self.assertFalse((self.P.record_dir / "demo.json").exists())
        self.assertIn("Demo uninstalled", self.events()[-1])

    def test_uninstall_stops_the_tool_units_and_nothing_else(self):
        self.tool["units"] = ["demo@*.service"]
        self.good_install()
        self.assertEqual(self.cli.do_uninstall(self.action("uninstall"), dict(os.environ)), 0)
        calls = (self.fix / "systemctl.log").read_text().splitlines()
        self.assertIn("systemctl disable --now demo@eth0.service", calls)
        self.assertIn("systemctl disable --now demo@wlan0.service", calls)
        self.assertFalse(any("ssh.service" in c and "disable" in c for c in calls))

    def test_uninstall_refused_when_apt_would_take_other_packages(self):
        self.good_install()
        (self.fix / "apt-extra").write_text("Remv pulseaudio [17]\n")
        rc = self.cli.do_uninstall(self.action("uninstall"), dict(os.environ))
        self.assertEqual(rc, 1)
        self.assertTrue((self.opt / "demo/bin/demo").exists())
        self.assertIn("demo-pkg:amd64", (self.fix / "dpkg").read_text())
        self.assertIn("would also remove pulseaudio", self.events()[-1])

    def test_uninstall_without_record_removes_nothing(self):
        (self.opt / "demo/bin").mkdir(parents=True)
        (self.opt / "demo/bin/demo").touch()
        rc = self.cli.do_uninstall(self.action("uninstall"), dict(os.environ))
        self.assertEqual(rc, 1)
        self.assertTrue((self.opt / "demo/bin/demo").exists())
        self.assertIn("no install record", self.events()[-1])

    def test_failed_install_records_leftovers_and_reports_the_first_error(self):
        self.write_installer('echo "demo-half:amd64 installed" >> "$FIX/dpkg"\n'
                             'echo "ERROR: [install-demo.sh] apt failed to install demo-core." >&2\n'
                             'echo "ERROR: [install-demo.sh] Rolled back." >&2\nexit 1\n')
        a = self.action("install")
        self.assertEqual(self.cli.do_install(a, dict(os.environ)), 1)
        rec = json.loads((self.P.record_dir / "demo.json").read_text())
        self.assertEqual((rec["apt"], rec["complete"]), (["demo-half:amd64"], False))
        self.assertIn("--severity warning", self.events()[-1])
        self.assertIn("installer exited 1: apt failed to install demo-core.", self.events()[-1])
        live = json.loads((self.P.state_dir / "demo.json").read_text())
        self.assertEqual(live["state"], "failed")

    def test_integrity_refusal_is_critical(self):
        self.write_installer('echo "ERROR: [install-demo.sh] SHA-256 MISMATCH for https://x — refusing to install." >&2\nexit 1\n')
        self.assertEqual(self.cli.do_install(self.action("install"), dict(os.environ)), 1)
        self.assertIn("--severity critical", self.events()[-1])
        self.assertIn("REFUSED (integrity check)", self.events()[-1])

    def test_offline_install_fails_before_running_the_installer(self):
        self.cli.has_route = lambda: False
        self.write_installer(f'touch "{self.fix}/ran"\n')
        self.assertEqual(self.cli.do_install(self.action("install"), dict(os.environ)), 1)
        self.assertFalse((self.fix / "ran").exists())
        self.assertIn("needs network: no network route", self.events()[-1])

    def test_blocked_install_runs_nothing(self):
        self.tool["blocked"] = "owner decision pending"
        self.write_installer(f'touch "{self.fix}/ran"\n')
        self.assertEqual(self.cli.do_install(self.action("install"), dict(os.environ)), 1)
        self.assertFalse((self.fix / "ran").exists())
        self.assertIn("blocked: owner decision pending", self.events()[-1])

    def test_installed_tool_is_a_no_op_success(self):
        (self.opt / "demo/bin").mkdir(parents=True)
        (self.opt / "demo/bin/demo").touch()
        self.write_installer(f'touch "{self.fix}/ran"\n')
        self.assertEqual(self.cli.do_install(self.action("install"), dict(os.environ)), 0)
        self.assertFalse((self.fix / "ran").exists())


if __name__ == "__main__":
    unittest.main()
