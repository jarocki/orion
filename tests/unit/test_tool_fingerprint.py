"""tool_fingerprint: one tool-attribution authority for the producers (#128, DEC-PHASE13-040).

Positive fixtures per tool the issue names, and negative cases that must stay
None — an unattributed scan is a true answer, a guessed one is not.
"""
from __future__ import annotations

import random
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/rain"))
import tool_fingerprint as T  # noqa: E402


def test_patterns_come_from_intel_base_not_a_second_list():
    assert T.INTEL_BASE_FILE == ROOT / "scripts/logquery/intel-base.json"
    assert T.SIGNATURES_ORIGIN == "intel-base.json"
    # Every tool the issue names is in the loaded set.
    tools = {tool for _rx, tool, _c in T.SIGNATURES}
    assert {"nmap", "masscan", "zmap/zgrab", "nuclei", "nikto", "sqlmap"} <= tools
    # Anchored User-Agent prefixes (^curl/, ^Wget/, ...) are not applied to rule text.
    assert "curl" not in tools and "wget" not in tools


def test_fallback_is_used_only_when_the_file_is_absent(tmp_path):
    sigs, origin = T._load_signatures(tmp_path / "missing.json")
    assert origin == "fallback"
    assert {tool for _rx, tool, _c in sigs} == {"nmap", "masscan", "zmap/zgrab", "nuclei", "nikto", "sqlmap"}


@pytest.mark.parametrize("signature, tool", [
    ("ET SCAN Nmap Scripting Engine User-Agent Detected (Nmap Scripting Engine)", "nmap"),
    ("ET SCAN NMAP OS Detection Probe", "nmap"),
    ("ET SCAN Masscan Scan", "masscan"),
    ("ET SCAN Zmap User-Agent (Inbound)", "zmap/zgrab"),
    ("ET SCAN ZGrab Scanner User-Agent", "zmap/zgrab"),
    ("ET SCAN Nuclei Scanner User-Agent", "nuclei"),
    ("ET SCAN Nikto Web App Scan in Progress", "nikto"),
    ("ET WEB_SERVER sqlmap SQL Injection Scan", "sqlmap"),
])
def test_suricata_signature_names_the_tool_at_high(signature, tool):
    assert T.fingerprint_suricata(signature) == (tool, "high")


@pytest.mark.parametrize("signature", [
    "ET SCAN Potential SSH Scan",
    "ET SCAN Suspicious inbound to mySQL port 3306",
    "ET POLICY curl User-Agent Outbound",       # anchored UA prefix: not rule-text evidence
    "ET DROP Dshield Block Listed Source group 1",
    "",
    None,
])
def test_suricata_signature_without_a_tool_is_none(signature):
    assert T.fingerprint_suricata(signature) == (None, None)


def test_zeek_is_capped_at_medium_and_port_scan_notice_is_none():
    assert T.fingerprint_zeek("HTTP::Suspicious_UA", "User-Agent: Nmap Scripting Engine") == ("nmap", "medium")
    assert T.fingerprint_zeek("Scan::Port_Scan",
                              "10.0.0.9 scanned at least 15 unique ports of host 10.0.0.1 in 0m3s") == (None, None)
    assert T.fingerprint_zeek("Scan::Address_Scan", "") == (None, None)
    assert T.fingerprint_zeek(None, None) == (None, None)


def _random_ports(n: int, seed: int = 7) -> list[int]:
    return random.Random(seed).sample(range(1, 1025), n)


def test_port_order():
    assert T.port_order(list(range(20, 60))) == "sequential"
    assert T.port_order([20, 21, 22, 22, 23, 25, 26, 27, 28, 29]) == "sequential"  # retransmit + a gap
    assert T.port_order(_random_ports(40)) == "random"
    assert T.port_order(sorted(_random_ports(40))) is None  # ascending with gaps: no claim
    assert T.port_order(list(range(1, 5))) is None  # too few to say
    assert T.port_order(None) is None and T.port_order([]) is None
    assert T.port_order(["x", 2, 3, 4, 5, 6, 7, 8]) is None


def test_scan_profile_nmap_random_order_at_drop_policy_rate_is_low():
    ports = _random_ports(60)
    assert T.NMAP_DROP_POLICY_PPS == 4.3
    assert T.fingerprint_scan(ports, 60 / 4.3, 60) == ("nmap", "low")
    assert T.fingerprint_scan(ports, None, None, rate_pps=4.3) == ("nmap", "low")


@pytest.mark.parametrize("ports, window, distinct", [
    (list(range(20, 80)), 60 / 4.3, 60),          # sequential walk: nmap -r, nc, a loop — tool-agnostic
    (_random_ports(60), 0.2, 60),                  # 300 pps: not the DROP-policy profile
    (_random_ports(60), 900.0, 60),                # slow window: 0.07 pps
    (sorted(_random_ports(60)), 60 / 4.3, 60),     # sorted list: order unknown, no claim
    (_random_ports(5), 5 / 4.3, 5),                # too few ports
    (_random_ports(60), 0, 60),                    # degenerate window
])
def test_scan_profile_negative_cases_stay_none(ports, window, distinct):
    assert T.fingerprint_scan(ports, window, distinct) == (None, None)


def test_attribute_sets_tool_only_when_confident_and_never_overwrites():
    d = T.attribute({"engine": "suricata", "signature": "ET SCAN Masscan Scan", "src_ip": "1.2.3.4"})
    assert (d["tool"], d["tool_conf"]) == ("masscan", "high")

    kept = T.attribute({"engine": "suricata", "signature": "ET SCAN Masscan Scan", "tool": "custom"})
    assert kept["tool"] == "custom" and "tool_conf" not in kept

    none = T.attribute({"engine": "suricata", "signature": "ET SCAN Potential SSH Scan"})
    assert "tool" not in none and "tool_conf" not in none

    zeek = T.attribute({"engine": "zeek", "note": "HTTP::Suspicious_UA", "msg": "nikto/2.1.6"})
    assert (zeek["tool"], zeek["tool_conf"]) == ("nikto", "medium")

    ports = _random_ports(60)
    scan = T.attribute({"distinct_ports": 60, "window_seconds": round(60 / 4.3, 1),
                        "ports_seen": sorted(ports)}, ports_order=ports)
    assert (scan["tool"], scan["tool_conf"], scan["scan_order"]) == ("nmap", "low", "random")

    seq = T.attribute({"distinct_ports": 40, "window_seconds": 9.3, "ports_seen": list(range(20, 60))},
                      ports_order=list(range(20, 60)))
    assert seq["scan_order"] == "sequential" and "tool" not in seq

    no_order = T.attribute({"distinct_ports": 40, "window_seconds": 9.3, "ports_seen": sorted(ports)})
    assert "tool" not in no_order and "scan_order" not in no_order

    assert T.attribute("not-a-dict") == "not-a-dict"


def test_confidence_vocabulary_matches_intel_base():
    assert T.CONFIDENCE_LEVELS == ("low", "medium", "high")
    assert all(conf in T.CONFIDENCE_LEVELS for _rx, _tool, conf in T.SIGNATURES)
