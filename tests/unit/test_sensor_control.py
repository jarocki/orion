"""Suricata/Zeek control on the v3.2.0 deck (DEC-PHASE13-071/072/073).

Found on the v3.2.0 image in QEMU, 2026-11-27:
  * the config test ran inside orionx-postured's sandbox, could not write
    /var/log/suricata, and published a false CRITICAL on every tier raise;
  * a quiet but connected interface was never captured, so Tier 2 ran
    neither sensor and a running Suricata was stopped when the link went quiet;
  * the operator had no way to start or stop either sensor by hand.
No Suricata, Zeek or systemd needed: sysfs is a temp tree, the runner is a stub.
"""

import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/awareness"))
sys.path.insert(0, str(ROOT / "scripts"))
LOADER = SourceFileLoader("postured_sensor_control", str(ROOT / "scripts/awareness/orionx-postured"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
PD = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(PD)

import suricata_capture as capture  # noqa: E402
from control_center.helpers import posture_data as PDATA  # noqa: E402


# ---------------------------------------------------------------- DEC-072
def test_config_test_writes_logs_to_a_private_dir_and_removes_it():
    seen = {}

    class R:
        returncode = 0
        stdout = "Configuration provided was successfully loaded."
        stderr = ""

    def runner(argv, **_kw):
        seen["argv"] = argv
        seen["dir_existed"] = os.path.isdir(argv[argv.index("-l") + 1])
        return R()

    v = capture.check_config(Path("/etc/suricata/orionx.yaml"), runner=runner, binary="suricata", isolate=False)
    assert v["verdict"] == "ok"
    assert seen["argv"][:5] == ["suricata", "-T", "-v", "-c", "/etc/suricata/orionx.yaml"]
    assert "-l" in seen["argv"] and seen["dir_existed"]
    assert not os.path.exists(seen["argv"][seen["argv"].index("-l") + 1]), "scratch log dir left behind"


def test_on_a_deck_the_config_test_runs_in_its_own_capped_unit():
    argv = capture.config_test_argv("suricata", Path("/etc/suricata/orionx.yaml"), True, None, "805306368")
    assert argv[:5] == ["systemd-run", "--quiet", "--wait", "--pipe", "--collect"]
    assert "MemoryMax=805306368" in argv and "RuntimeDirectory=orionx-suricata-test" in argv
    assert argv[-2:] == ["-l", "/run/orionx-suricata-test"], "logs go where the unit can write, not the daemon's /var/log"


def test_isolated_test_takes_the_engine_memory_cap_and_reports_its_verdict(monkeypatch):
    calls = []

    class R:
        def __init__(self, rc, out):
            self.returncode, self.stdout, self.stderr = rc, out, ""

    def runner(argv, **_kw):
        calls.append(argv)
        if argv[0] == "systemctl":
            return R(0, "805306368\n")
        return R(0, "Configuration provided was successfully loaded.")

    monkeypatch.setattr(capture.shutil, "which", lambda name: "/usr/bin/" + name)
    v = capture.check_config(Path("/etc/suricata/orionx.yaml"), runner=runner, binary="suricata", isolate=True)
    assert v["verdict"] == "ok"
    assert calls[0][:3] == ["systemctl", "show", "suricata.service"]
    assert "MemoryMax=805306368" in calls[1]


def test_isolated_test_with_no_engine_is_absent_not_rejected(monkeypatch):
    monkeypatch.setattr(capture.shutil, "which", lambda name: None)
    v = capture.check_config(Path("x.yaml"), runner=lambda *a, **k: 1 / 0, binary="suricata", isolate=True)
    assert v["verdict"] == "absent"


def test_config_test_keeps_a_caller_supplied_log_dir(tmp_path):
    class R:
        returncode = 0
        stdout = "successfully loaded"
        stderr = ""

    capture.check_config(Path("x.yaml"), runner=lambda argv, **_k: R(), binary="suricata", log_dir=str(tmp_path), isolate=False)
    assert tmp_path.is_dir()


# ---------------------------------------------------------------- DEC-071
def _sysfs(root: Path, ifaces: dict) -> Path:
    """ifaces: name -> (operstate, rx_packets, arphrd type)."""
    for name, (state, rx, kind) in ifaces.items():
        d = root / name / "statistics"
        d.mkdir(parents=True)
        (d / "rx_packets").write_text(f"{rx}\n")
        (root / name / "operstate").write_text(f"{state}\n")
        (root / name / "type").write_text(f"{kind}\n")
    return root


def test_up_interfaces_are_sampled_and_loopback_is_not(tmp_path):
    s = _sysfs(tmp_path, {"lo": ("unknown", 9, 772), "wlan0": ("up", 3, 1), "eth0": ("down", 0, 1),
                          "wg0": ("unknown", 50, 65534)})
    assert capture.sample_up(s) == {"wlan0"}


def test_a_quiet_up_interface_is_selected_at_once():
    hb = capture.InterfaceHeartbeat()
    hb.observe({"wlan0": 100}, 1000.0, up={"wlan0"})
    assert not hb.warming_up(1000.0), "an up interface ends warm-up: the answer is known"
    hb.observe({"wlan0": 101}, 1035.0, up={"wlan0"})   # 1 packet in 35 s: below the live threshold
    assert hb.live(1035.0) == set()
    assert hb.selected(1035.0) == ("wlan0",)


def test_a_quiet_interface_stays_selected_past_the_demote_time_while_up():
    hb = capture.InterfaceHeartbeat(quiet_demote=300.0)
    hb.observe({"eth0": 0}, 0.0, up={"eth0"})
    hb.observe({"eth0": 50}, 30.0, up={"eth0"})        # live once
    assert hb.selected(30.0) == ("eth0",)
    for t in range(60, 1200, 30):
        hb.observe({"eth0": 50}, float(t), up={"eth0"})
    assert hb.selected(1190.0) == ("eth0",), "a running IDS must not be stopped because the link went quiet"


def test_down_quiet_interfaces_are_still_judged_by_rate():
    hb = capture.InterfaceHeartbeat()
    hb.observe({"eth1": 0}, 0.0, up=set())
    hb.observe({"eth1": 1}, 30.0, up=set())
    assert hb.selected(30.0) == ()


def test_without_an_up_set_behaviour_is_unchanged():
    hb = capture.InterfaceHeartbeat()
    hb.observe({"eth0": 0}, 0.0)
    hb.observe({"eth0": 1}, 30.0)
    assert hb.selected(30.0) == ()


def test_a_vanished_up_interface_is_dropped():
    hb = capture.InterfaceHeartbeat()
    hb.observe({"usb0": 0}, 0.0, up={"usb0"})
    assert hb.selected(0.0) == ("usb0",)
    hb.observe({}, 5.0, up={"usb0"})                     # stale up set naming a device that is gone
    assert hb.selected(5.0) == ()


def test_the_cap_prefers_live_interfaces_over_merely_up_ones():
    hb = capture.InterfaceHeartbeat(max_ifaces=1)
    hb.observe({"veth1": 0, "eth0": 0}, 0.0, up={"veth1", "eth0"})
    hb.observe({"veth1": 0, "eth0": 500}, 30.0, up={"veth1", "eth0"})
    assert hb.selected(30.0) == ("eth0",)


# ---------------------------------------------------------------- DEC-073
def test_overrides_parse_known_sensors_only():
    assert PD.parse_sensor_overrides("suricata=on\nzeek=OFF\nnmap=on\ngarbage\n") == {"suricata": True, "zeek": False}
    assert PD.parse_sensor_overrides(None) == {}


def test_tier0_with_suricata_started_by_hand():
    p = PD.tier_plan("0", True, live_ifaces=("wlan0",), overrides={"suricata": True})
    assert p["gate_file"] and p["suricata"] and p["eve_ingest"]
    assert not p["zeek"] and not p["deception"]
    assert p["capture_ifaces"] == ("wlan0",)
    assert p["sensor_source"] == {"suricata": "manual", "zeek": "tier"}


def test_tier2_with_zeek_stopped_by_hand():
    p = PD.tier_plan("2", True, live_ifaces=("wlan0",), overrides={"zeek": False})
    assert p["suricata"] and not p["zeek"] and p["deception"]
    acts = PD.plan_actions(PD.tier_plan("2", True, live_ifaces=("wlan0",)), p)
    assert ("service", "stop", "orionx-zeek@wlan0.service") in acts
    assert ("service", "stop", "suricata.service") not in acts


def test_tier2_with_both_stopped_tears_capture_down():
    p = PD.tier_plan("2", True, live_ifaces=("wlan0",), overrides={"suricata": False, "zeek": False})
    assert not p["gate_file"] and not p["suricata"] and not p["zeek"] and p["capture_ifaces"] == ()
    assert not p["warn_no_capture"]


def test_no_overrides_is_exactly_the_tier():
    for tier in ("0", "1", "2"):
        a = PD.tier_plan(tier, True, live_ifaces=("eth0",))
        b = PD.tier_plan(tier, True, live_ifaces=("eth0",), overrides={})
        assert a == b
        assert a["suricata"] == a["zeek"] == (tier != "0")


def test_manual_start_with_nothing_to_capture_says_so():
    p = PD.tier_plan("0", True, live_ifaces=(), overrides={"zeek": True})
    assert not p["zeek"] and p["warn_no_capture"]


def test_untrusted_sensors_file_means_no_overrides(tmp_path):
    f = tmp_path / "sensors"
    f.write_text("suricata=on\n")
    os.chmod(f, 0o666)
    o, refusal = PD.read_sensor_overrides(f)
    assert o == {} and refusal
    assert PD.read_sensor_overrides(tmp_path / "absent") == ({}, None)


# ---------------------------------------------------------------- the writer
def test_request_sensor_round_trip_and_follow_tier(tmp_path):
    f = tmp_path / "sensors"
    assert PDATA.request_sensor("suricata", True, f) == (True, "")
    assert PDATA.request_sensor("zeek", False, f) == (True, "")
    assert PD.parse_sensor_overrides(f.read_text()) == {"suricata": True, "zeek": False}
    assert PDATA.request_sensor("suricata", None, f) == (True, "")
    assert PDATA.load_sensor_overrides(f) == {"zeek": False}
    PDATA.request_sensor("zeek", None, f)
    assert not f.exists(), "no overrides left: the file goes, the tier decides"
    ok, why = PDATA.request_sensor("nmap", True, f)
    assert not ok and "unknown sensor" in why


def test_a_tier_change_clears_manual_overrides(tmp_path):
    posture = tmp_path / "threat-posture"
    PDATA.request_sensor("suricata", False, tmp_path / "sensors")
    assert PDATA.request_tier("2", posture) == (True, "")
    assert posture.read_text() == "2\n"
    assert not (tmp_path / "sensors").exists()


def _status(now, suri=None, zeek=None, tier="2"):
    return {"ts": now, "tier": tier, "sensors": {"suricata": suri or {}, "zeek": zeek or {}}}


def test_sensor_view_words():
    now = 1000.0
    run = PDATA.sensor_view("suricata", _status(now, {"wanted": True, "active": True, "capture_ifaces": ["wlan0"]}), now)
    assert run["word"] == "RUNNING" and run["stop"] and not run["start"] and "wlan0" in run["line"]
    off = PDATA.sensor_view("zeek", _status(now, zeek={"wanted": False, "active": False}, tier="0"), now)
    assert off["word"] == "STOPPED" and off["start"] and not off["follow"]
    manual = PDATA.sensor_view("zeek", _status(now, zeek={"wanted": False, "active": False}), now, {"zeek": False})
    assert manual["word"] == "STOPPED" and manual["follow"] and "stopped by you" in manual["line"]
    wait = PDATA.sensor_view("suricata", _status(now, {"wanted": True, "active": False, "capture_ifaces": []}), now)
    assert wait["word"] == "WAITING" and wait["level"] == "error"
    stale = PDATA.sensor_view("suricata", _status(now - 120, {"wanted": True, "active": True}), now)
    assert stale["word"] == "UNKNOWN"


# ---------------------------------------------------------------- DEC-075
def test_a_deliberate_stop_is_not_drawn_as_down():
    import cockpit_lib as L
    assert L.stopped_or_up("active") is True
    assert L.stopped_or_up("inactive") == "stopped"       # after `nebula stop`
    assert L.stopped_or_up("failed") is False             # a crash stays red
    assert L.stopped_or_up("unknown") is False
