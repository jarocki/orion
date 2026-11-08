"""Fake transmitters for gateway_probes (#94), shared by test_gateway_probes.sh
and test_osint_surface.sh so both suites drive the same gateway.

install(GP) replaces every transmitter in the module with a fake that records
its call in the returned log and answers from the fixture files beside this
one. Nothing here opens a socket.
"""
from __future__ import annotations

from pathlib import Path

HERE = Path(__file__).resolve().parent


def fixture(name: str) -> str:
    return (HERE / name).read_text(encoding="utf-8")


def install(GP, ssdp_answers: bool = True) -> list[tuple]:
    log: list[tuple] = []
    ssdp = (HERE / "ssdp_response.txt").read_bytes()

    def discover(*a, **k):
        log.append(("ssdp",))
        if not ssdp_answers:
            return []
        return [dict(GP.parse_ssdp_response(ssdp), peer="192.168.4.1")]

    def get(url, *a, **k):
        log.append(("get", url))
        return 200, fixture("rootDesc.xml")

    def soap(control, stype, action, *a, **k):
        log.append(("soap", control, action))
        return 200, fixture("soap_external_ip.xml" if action == "GetExternalIPAddress" else "soap_link.xml")

    expected = {name: list(addrs) for name, addrs in GP.DNS_CANARIES}

    def system_q(name):
        log.append(("dns-system", name))
        return {"rcode_name": "NOERROR", "answers": expected[name][:1]} if name in expected \
            else {"rcode_name": "NXDOMAIN", "answers": []}

    def direct_q(name, server, *a, **k):
        log.append(("dns-direct", name, server[0]))
        return {"rcode_name": "NOERROR", "answers": expected[name]} if name in expected \
            else {"rcode_name": "NXDOMAIN", "answers": []}

    def captive(host, path, *a, **k):
        log.append(("captive", host, path))
        return {"status": 204, "location": None, "body_head": ""}

    def connect(host, port, *a, **k):
        log.append(("tcp", host, port))
        return "timeout" if port == 8080 else "connected"

    GP.ssdp_discover, GP.http_get_local, GP.soap_call = discover, get, soap
    GP.dns_query_system, GP.dns_query_direct = system_q, direct_q
    GP.captive_check, GP.tcp_connect = captive, connect
    return log
