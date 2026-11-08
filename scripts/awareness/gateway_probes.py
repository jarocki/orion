#!/usr/bin/env python3
"""gateway_probes — the two ACTIVE things beneath the passive network picture (#94).

network_picture.py (#93) reads tables and logs and transmits nothing. This
module is where the Workbench "This network" page grows its only transmitters,
kept apart because they cross two different trust boundaries:

  Part A  gateway identity  — SSDP M-SEARCH on the LOCAL segment, then the
          gateway's own description XML and two IGD SOAP calls. Local only,
          operator-initiated (a button, never a timer, never on page load).
          Everything it returns is what the gateway SAYS about itself and is
          labelled GATEWAY_CLAIM_LABEL.
  Part B  upstream probes   — DNS rewriting, captive portal, TCP port blocking.
          These reach the INTERNET, so every run passes through
          osint_server.outbound_verdict() first (the GODSEYE gate, DEC-PHASE12-045)
          and at a blocked posture the entry IS the refusal, labelled PROBE_LABEL.

Parsers here are PURE (bytes/text in, dict out) and tested offline against
fixture strings (tests/unit/test_gateway_probes.sh). Transmitters are small,
named and injectable: run_gateway() / run_outbound() take them as keyword
arguments so a test can prove, with fakes, exactly what would be sent and that
nothing is sent when refused. Importing this module has no side effect; the
only thing the passive engine calls is describe(), which opens no socket.

Both runs return ONE entry in the shape network_picture.active_extensions()
promised the page: {id, label, state, gated_by, result, ...}. The page therefore
renders idle descriptors and finished probes with the same code.

# @decision DEC-PHASE13-047
# @title Gateway-reported values are displayed as claims; upstream probes reuse outbound_verdict and are never automatic
# @status accepted
# @rationale Issue #94 asks for two things the passive picture cannot give:
#   who the gateway is, and whether the upstream filters or blocks. Neither is
#   passive and they are not the same kind of active, so this module keeps
#   them apart and fixes the honesty rules in code and in tests:
#     1. SSDP/IGD answers are the gateway's claims. The "external IP" and the
#        link rates come from GetExternalIPAddress / GetCommonLinkProperties;
#        nothing here measured a thing. Every such value carries the fixed
#        label GATEWAY_CLAIM_LABEL ("reported by the gateway, not measured")
#        in the API and on the page, as OBSERVED_LABEL does for the picture.
#        The LOCATION and controlURL the gateway names are fetched only when
#        they are a local (RFC 1918 / link-local / ULA) IP literal: a gateway
#        can name any URL, and following one to the internet from a Tier 2
#        deck would be an outbound request nobody gated.
#     2. The upstream probes do reach the internet. GODSEYE already answers
#        "may this deck reach out right now?" in osint_server.outbound_verdict(),
#        keyed on OUTBOUND_BLOCKED_TIERS and the default route. This module
#        grows no second gate: run_outbound() takes that verdict as its first
#        argument and, when it is not allowed, returns the refusal entry
#        (naming the posture, the parties it would have contacted, what
#        still works and the remedy) before any transmitter is called. The
#        page renders the refusal, never a spinner.
#     3. Nothing here runs by itself. There is no timer, no run on page load,
#        no call from collect(): the engine imports describe() only, and a
#        test imports this module with a socket that raises on creation and
#        then runs collect() and GET /api/network.json to prove no datagram
#        leaves. The operator presses a button; the POST says what was sent.
#     4. The third parties Part B talks to are constants in ONE place below
#        (DIRECT_RESOLVERS, DNS_CANARIES, CAPTIVE_CHECK, PORT_TARGETS) with
#        the reason each was chosen beside it, and the refusal text and the
#        page's "what this sends" line are derived from those constants so
#        they cannot drift from what the code actually does.
"""
from __future__ import annotations

import http.client
import ipaddress
import random
import socket
import struct
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from typing import Any, Callable

DECISION = "DEC-PHASE13-047"
GATEWAY_CLAIM_LABEL = "reported by the gateway, not measured"
PROBE_LABEL = "probe, posture-gated"

# ---------------------------------------------------------------- Part A constants
# SSDP: the UPnP discovery group and the device type an IGD answers to. Both
# versions of the InternetGatewayDevice type are asked for because consumer
# routers ship either; a MiniUPnPd answers :1 or :2 depending on build flags.
SSDP_GROUP = ("239.255.255.250", 1900)
SSDP_TARGETS = ("urn:schemas-upnp-org:device:InternetGatewayDevice:1",
                "urn:schemas-upnp-org:device:InternetGatewayDevice:2")
SSDP_MX = 1                  # seconds the device may wait before answering (spec: 1..5)
SSDP_TIMEOUT = 2.0           # how long this deck listens for answers
SSDP_TTL = 2                 # multicast TTL: this segment and its gateway, not beyond
HTTP_TIMEOUT = 3.0           # description XML and each SOAP call
MAX_XML_BYTES = 256 * 1024   # a device description is a few KiB; cap what the gateway can push
WAN_IP_SERVICES = ("WANIPConnection", "WANPPPConnection")
WAN_LINK_SERVICE = "WANCommonInterfaceConfig"

# ---------------------------------------------------------------- Part B constants
# Everything the upstream probes contact is listed here and nowhere else.
#
# DIRECT_RESOLVERS: the question is "does the local resolver (DHCP-assigned,
#   usually the gateway) answer differently from a resolver reached directly on
#   udp/53?" The direct resolver must therefore be UNFILTERED by policy, or a
#   difference proves nothing: 1.1.1.1 is Cloudflare's unfiltered service
#   (1.1.1.2/1.1.1.3 are the filtering variants) and 9.9.9.10 is Quad9's
#   unfiltered address (9.9.9.9 blocks malware domains by design). Second is
#   tried only if the first gives no answer.
DIRECT_RESOLVERS = (("1.1.1.1", 53), ("9.9.9.10", 53))
# DNS_CANARIES: names whose A records are FIXED and publicly documented, so a
#   different answer is rewriting, not CDN geo-steering (which would make any
#   content site useless as a canary). All three are the resolvers' own
#   service names; they exist to be resolved and carry no content.
DNS_CANARIES = (("dns.google", ("8.8.8.8", "8.8.4.4")),
                ("one.one.one.one", ("1.1.1.1", "1.0.0.1")),
                ("dns.quad9.net", ("9.9.9.9", "149.112.112.112")))
# NXDOMAIN canary: a random label under .invalid (RFC 2606 reserves it; it can
#   never exist). A resolver that answers it with an address is rewriting
#   NXDOMAIN into a search/ad page.
NXDOMAIN_CANARY_SUFFIX = ".invalid"
DNS_TIMEOUT = 2.0
# CAPTIVE_CHECK: plain HTTP on purpose (a portal intercepts http, not https) to
#   an endpoint whose documented answer is an empty 204, so anything else — a
#   redirect, a 200 with a page — is an interception. cp.cloudflare.com is the
#   endpoint Cloudflare's own clients use; it adds no party beyond the one the
#   DNS probe already talks to.
CAPTIVE_CHECK = ("cp.cloudflare.com", "/generate_204", 204)
# PORT_TARGETS: one TCP connect per port, to a host KNOWN to listen there, so a
#   timeout means filtering and not an absent service. 1.1.1.1 serves DNS over
#   tcp/53 and tls/853 and its site on 80/443; github.com is the best-known
#   public SSH listener; portquiz.net is the purpose-built "outgoing port
#   tester" that listens on every TCP port, used only for 8080 where no
#   major service listens. A refused connection (RST) means the path is open.
PORT_TARGETS = ((22, "github.com", "ssh"),
                (53, "1.1.1.1", "dns over tcp"),
                (80, "1.1.1.1", "http"),
                (443, "1.1.1.1", "https"),
                (853, "1.1.1.1", "dns over tls"),
                (8080, "portquiz.net", "http-alt"))
CONNECT_TIMEOUT = 3.0

RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}


# ---------------------------------------------------------------- descriptors (what the page draws idle)

def third_parties() -> list[str]:
    """Every host Part B would contact, derived from the constants above."""
    hosts = {addr for addr, _port in DIRECT_RESOLVERS} | {CAPTIVE_CHECK[0]} | {h for _p, h, _s in PORT_TARGETS}
    return sorted(hosts)


def outbound_sends() -> str:
    """One sentence, derived from the constants, saying what a run transmits."""
    n_q = len(DNS_CANARIES) + 1
    ports = ", ".join("%s:%d" % (h, p) for p, h, _s in PORT_TARGETS)
    return ("DNS: %d A queries via the system resolver and %d via %s (fallback %s). "
            "HTTP GET http://%s%s. TCP connects to %s. IPv4, one attempt each."
            % (n_q, n_q, DIRECT_RESOLVERS[0][0], DIRECT_RESOLVERS[1][0],
               CAPTIVE_CHECK[0], CAPTIVE_CHECK[1], ports))


def gateway_sends() -> str:
    return ("%d UDP multicast M-SEARCH datagrams to %s:%d (TTL %d, one per target type), then an HTTP GET "
            "of the LOCATION the gateway names and up to 2 SOAP POSTs to it — only if that address is on "
            "this segment (RFC 1918 / link-local); a LOCATION elsewhere is refused, not followed."
            % (len(SSDP_TARGETS), SSDP_GROUP[0], SSDP_GROUP[1], SSDP_TTL))


EXTENSIONS: tuple[dict[str, Any], ...] = (
    {"id": "gateway",
     "label": "Gateway identity (SSDP / IGD)",
     "endpoint": "/api/network/gateway",
     "gated_by": "operator — local segment only, never automatic",
     "claim_label": GATEWAY_CLAIM_LABEL,
     "button": "Ask the gateway",
     "what": "Who the gateway says it is (friendly name, manufacturer, model), the WAN address it reports and "
             "the link rates it claims. Every value is " + GATEWAY_CLAIM_LABEL + ".",
     "sends": gateway_sends()},
    {"id": "outbound",
     "label": "Upstream filtering and blocking probes",
     "endpoint": "/api/network/outbound",
     "gated_by": "threat posture — osint_server.outbound_verdict (the GODSEYE gate)",
     "probe_label": PROBE_LABEL,
     "button": "Probe upstream",
     "what": "Is the upstream rewriting DNS, holding a captive portal or blocking TCP ports? A " + PROBE_LABEL
             + ": at a blocked posture this shows the refusal instead of running.",
     "sends": outbound_sends()},
)


def describe() -> list[dict[str, Any]]:
    """The idle entries the page draws before the operator presses anything. Pure."""
    return [dict(e, state="idle", result=None) for e in EXTENSIONS]


def _entry(ext_id: str, state: str, result: dict | None = None, **extra: Any) -> dict[str, Any]:
    base = next(e for e in EXTENSIONS if e["id"] == ext_id)
    entry = dict(base)
    entry.update({"state": state, "result": result, "generated": time.time(), "decision": DECISION})
    entry.update(extra)
    return entry


# ---------------------------------------------------------------- pure parsers: SSDP

def parse_ssdp_response(data: bytes) -> dict[str, str] | None:
    """One SSDP M-SEARCH answer -> {location, st, usn, server, ...} or None if it is not one."""
    text = data.decode("utf-8", "replace") if isinstance(data, (bytes, bytearray)) else str(data)
    lines = text.split("\r\n") if "\r\n" in text else text.split("\n")
    if not lines or not lines[0].upper().startswith("HTTP/1.1 200"):
        return None
    out: dict[str, str] = {}
    for line in lines[1:]:
        if not line.strip():
            break
        key, sep, value = line.partition(":")
        if sep:
            out[key.strip().lower()] = value.strip()
    if not out.get("location"):
        return None
    return out


def location_is_local(url: str) -> tuple[bool, str]:
    """May this deck fetch the URL a gateway named? Only http to a local IP literal.

    A hostname is refused even if it would resolve locally: resolving it is
    itself a DNS query the operator did not ask for, and the gateway announced
    itself by address in the first place."""
    try:
        parts = urllib.parse.urlsplit(url)
        host = parts.hostname or ""
    except ValueError as exc:
        return False, "unparseable URL (%s)" % exc
    if parts.scheme != "http":
        return False, "scheme %r is not http" % (parts.scheme or "")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False, "host %r is a name, not a local address" % host
    if ip.is_loopback or ip.is_multicast or ip.is_unspecified or ip.is_reserved:
        return False, "%s is not a segment address" % ip
    if not (ip.is_private or ip.is_link_local):
        return False, "%s is not a local (RFC 1918 / link-local / ULA) address — not followed" % ip
    return True, ""


# ---------------------------------------------------------------- pure parsers: UPnP XML

def _local_tag(tag: str) -> str:
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def _parse_xml(text: str) -> ET.Element:
    """ElementTree with the gateway's DTD refused: an entity expansion or an
    external entity in a device description is not something a router sends.
    defusedxml is not on the image (stdlib only), so the whole (size-capped)
    body is scanned for a declaration before expat ever sees it."""
    low = text.lower()
    if "<!doctype" in low or "<!entity" in low:
        raise ValueError("XML with a DTD/ENTITY declaration refused")
    return ET.fromstring(text)


def _child_text(elem: ET.Element, name: str) -> str | None:
    for child in elem:
        if _local_tag(child.tag) == name:
            return (child.text or "").strip() or None
    return None


def parse_device_description(text: str) -> dict[str, Any]:
    """The root device's identity and every service's controlURL, namespace-agnostic."""
    root = _parse_xml(text)
    out: dict[str, Any] = {"friendly_name": None, "manufacturer": None, "model_name": None,
                           "model_number": None, "model_description": None, "device_type": None,
                           "url_base": None, "services": []}
    for elem in root.iter():
        if _local_tag(elem.tag) == "URLBase":
            out["url_base"] = (elem.text or "").strip() or None
            break
    device = next((e for e in root.iter() if _local_tag(e.tag) == "device"), None)
    if device is not None:
        out.update({"friendly_name": _child_text(device, "friendlyName"),
                    "manufacturer": _child_text(device, "manufacturer"),
                    "model_name": _child_text(device, "modelName"),
                    "model_number": _child_text(device, "modelNumber"),
                    "model_description": _child_text(device, "modelDescription"),
                    "device_type": _child_text(device, "deviceType")})
    for svc in root.iter():
        if _local_tag(svc.tag) != "service":
            continue
        out["services"].append({"type": _child_text(svc, "serviceType") or "",
                                "id": _child_text(svc, "serviceId"),
                                "control_url": _child_text(svc, "controlURL")})
    return out


def find_service(services: list[dict], needles: tuple[str, ...]) -> dict | None:
    for svc in services:
        if any(n in (svc.get("type") or "") for n in needles):
            return svc
    return None


def soap_envelope(service_type: str, action: str) -> str:
    return ('<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            '<s:Body><u:%s xmlns:u="%s"></u:%s></s:Body></s:Envelope>' % (action, service_type, action))


def parse_soap_response(text: str, action: str) -> dict[str, Any]:
    """{<ActionResponse children>} on success, {"fault": {code, description}} on a UPnP fault."""
    root = _parse_xml(text)
    for elem in root.iter():
        if _local_tag(elem.tag) == action + "Response":
            return {_local_tag(c.tag): (c.text or "").strip() for c in elem}
    for elem in root.iter():
        if _local_tag(elem.tag) == "UPnPError":
            return {"fault": {"code": _child_text(elem, "errorCode"),
                              "description": _child_text(elem, "errorDescription")}}
    for elem in root.iter():
        if _local_tag(elem.tag) == "Fault":
            return {"fault": {"code": _child_text(elem, "faultcode"),
                              "description": _child_text(elem, "faultstring")}}
    raise ValueError("no %sResponse and no fault in the SOAP body" % action)


_NAT_NETS = tuple(ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7"))


def classify_external_ip(addr: str | None) -> str:
    """What the gateway's claimed WAN address implies — a classification, not a location."""
    if not addr:
        return "none reported"
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return "not an IP address"
    if isinstance(ip, ipaddress.IPv4Address) and ip in ipaddress.ip_network("100.64.0.0/10"):
        return "shared address space (100.64/10): carrier-grade NAT upstream"
    if ip.is_unspecified:
        return "unspecified (0.0.0.0): the gateway reports no WAN address"
    # Python's is_private also covers documentation/benchmark ranges (TEST-NET,
    # 198.18/15); only RFC 1918 and ULA mean "a NAT upstream of this one".
    if any(ip in net for net in _NAT_NETS if net.version == ip.version):
        return "private address: this gateway sits behind another NAT"
    if not ip.is_global:
        return "not a routable address"
    return "public address (as claimed by the gateway)"


def fmt_bitrate(value: str | None) -> str | None:
    try:
        bps = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    if bps <= 0:
        return None
    if bps >= 1_000_000_000:
        return "%.1f Gbit/s" % (bps / 1e9)
    if bps >= 1_000_000:
        return "%d Mbit/s" % round(bps / 1e6)
    if bps >= 1_000:
        return "%d kbit/s" % round(bps / 1e3)
    return "%d bit/s" % bps


# ---------------------------------------------------------------- pure parsers: DNS wire format

def build_dns_query(name: str, txid: int) -> bytes:
    labels = [part.encode("idna") for part in name.rstrip(".").split(".") if part]
    qname = b"".join(bytes([len(part)]) + part for part in labels) + b"\x00"
    header = struct.pack(">HHHHHH", txid & 0xFFFF, 0x0100, 1, 0, 0, 0)   # RD=1, one question
    return header + qname + struct.pack(">HH", 1, 1)                      # A, IN


def _skip_name(data: bytes, off: int) -> int:
    while True:
        if off >= len(data):
            raise ValueError("truncated name")
        n = data[off]
        if n == 0:
            return off + 1
        if n & 0xC0 == 0xC0:
            return off + 2
        off += 1 + n


def parse_dns_response(data: bytes, txid: int) -> dict[str, Any]:
    """{rcode, rcode_name, answers:[dotted A records], cnames, truncated}; raises ValueError on garbage."""
    if len(data) < 12:
        raise ValueError("short DNS message (%d bytes)" % len(data))
    rid, flags, qd, an, _ns, _ar = struct.unpack(">HHHHHH", data[:12])
    if rid != (txid & 0xFFFF):
        raise ValueError("transaction id mismatch")
    if not flags & 0x8000:
        raise ValueError("not a response")
    off = 12
    for _ in range(qd):
        off = _skip_name(data, off) + 4
    answers: list[str] = []
    cnames = 0
    for _ in range(an):
        off = _skip_name(data, off)
        if off + 10 > len(data):
            raise ValueError("truncated answer")
        rtype, _rclass, _ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
        off += 10
        rdata = data[off:off + rdlen]
        off += rdlen
        if rtype == 1 and rdlen == 4:
            answers.append(str(ipaddress.IPv4Address(rdata)))
        elif rtype == 5:
            cnames += 1
    rcode = flags & 0xF
    return {"rcode": rcode, "rcode_name": RCODES.get(rcode, str(rcode)), "answers": answers,
            "cnames": cnames, "truncated": bool(flags & 0x0200)}


# ---------------------------------------------------------------- transmitters (small, named, injectable)
# Each of these is the ONLY place its kind of packet leaves the deck. Tests
# replace them through the keyword arguments of run_gateway()/run_outbound().

def ssdp_discover(targets: tuple[str, ...] = SSDP_TARGETS, timeout: float = SSDP_TIMEOUT,
                  group: tuple[str, int] = SSDP_GROUP) -> list[dict[str, str]]:
    """Send one M-SEARCH per target, listen `timeout` seconds, return the distinct answers."""
    seen: dict[str, dict[str, str]] = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, SSDP_TTL)
        sock.settimeout(0.5)
        for st in targets:
            msg = ("M-SEARCH * HTTP/1.1\r\nHOST: %s:%d\r\nMAN: \"ssdp:discover\"\r\nMX: %d\r\nST: %s\r\n\r\n"
                   % (group[0], group[1], SSDP_MX, st)).encode("ascii")
            sock.sendto(msg, group)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                data, peer = sock.recvfrom(4096)
            except socket.timeout:
                continue
            parsed = parse_ssdp_response(data)
            if parsed and parsed["location"] not in seen:
                parsed["peer"] = peer[0]
                seen[parsed["location"]] = parsed
    finally:
        sock.close()
    return list(seen.values())


def http_get_local(url: str, timeout: float = HTTP_TIMEOUT, max_bytes: int = MAX_XML_BYTES) -> tuple[int, str]:
    """GET a URL location_is_local() already approved. (status, body text)."""
    parts = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=timeout)
    try:
        conn.request("GET", parts.path or "/", headers={"Host": parts.netloc, "User-Agent": "orionx-osint"})
        resp = conn.getresponse()
        body = resp.read(max_bytes + 1)
        if len(body) > max_bytes:
            raise ValueError("description larger than %d bytes refused" % max_bytes)
        return resp.status, body.decode("utf-8", "replace")
    finally:
        conn.close()


def soap_call(control_url: str, service_type: str, action: str, timeout: float = HTTP_TIMEOUT) -> tuple[int, str]:
    """POST one IGD SOAP action to a controlURL location_is_local() approved. (status, body)."""
    parts = urllib.parse.urlsplit(control_url)
    body = soap_envelope(service_type, action).encode("utf-8")
    conn = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=timeout)
    try:
        conn.request("POST", parts.path or "/", body=body, headers={
            "Host": parts.netloc, "User-Agent": "orionx-osint",
            "Content-Type": 'text/xml; charset="utf-8"',
            "SOAPACTION": '"%s#%s"' % (service_type, action)})
        resp = conn.getresponse()
        data = resp.read(MAX_XML_BYTES + 1)
        if len(data) > MAX_XML_BYTES:
            raise ValueError("SOAP response larger than %d bytes refused" % MAX_XML_BYTES)
        return resp.status, data.decode("utf-8", "replace")
    finally:
        conn.close()


def dns_query_direct(name: str, server: tuple[str, int], timeout: float = DNS_TIMEOUT) -> dict[str, Any]:
    """One A query on udp/53 straight to `server`, bypassing the system resolver."""
    txid = random.getrandbits(16)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.settimeout(timeout)
        sock.sendto(build_dns_query(name, txid), server)
        data, _peer = sock.recvfrom(4096)
    except socket.timeout:
        return {"error": "no answer within %.0f s" % timeout}
    except OSError as exc:
        return {"error": str(exc)}
    finally:
        sock.close()
    try:
        return parse_dns_response(data, txid)
    except ValueError as exc:
        return {"error": "unparseable answer: %s" % exc}


def dns_query_system(name: str) -> dict[str, Any]:
    """The same name through the system resolver (what every program on this deck uses)."""
    try:
        infos = socket.getaddrinfo(name, None, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror as exc:
        if exc.errno in (socket.EAI_NONAME, getattr(socket, "EAI_NODATA", -5)):
            return {"rcode_name": "NXDOMAIN", "answers": []}
        return {"error": str(exc)}
    except OSError as exc:
        return {"error": str(exc)}
    return {"rcode_name": "NOERROR", "answers": sorted({i[4][0] for i in infos})}


def captive_check(host: str = CAPTIVE_CHECK[0], path: str = CAPTIVE_CHECK[1],
                  timeout: float = HTTP_TIMEOUT) -> dict[str, Any]:
    """Plain-HTTP GET; a portal answers this itself. {status, location, body_head} or {error}."""
    conn = http.client.HTTPConnection(host, 80, timeout=timeout)
    try:
        conn.request("GET", path, headers={"Host": host, "User-Agent": "orionx-osint", "Connection": "close"})
        resp = conn.getresponse()
        head = resp.read(512).decode("utf-8", "replace")
        return {"status": resp.status, "location": resp.getheader("Location"), "body_head": head}
    except (OSError, http.client.HTTPException) as exc:
        return {"error": str(exc) or exc.__class__.__name__}
    finally:
        conn.close()


def tcp_connect(host: str, port: int, timeout: float = CONNECT_TIMEOUT) -> str:
    """'connected' | 'refused' | 'timeout' | 'unresolved' | 'error: ...' for one IPv4 connect."""
    try:
        addr = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)[0][4]
    except (socket.gaierror, IndexError, OSError):
        return "unresolved"
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect(addr)
        return "connected"
    except socket.timeout:
        return "timeout"
    except ConnectionRefusedError:
        return "refused"
    except OSError as exc:
        return "error: %s" % (exc.strerror or exc)
    finally:
        sock.close()


# ---------------------------------------------------------------- Part A: run_gateway

def _short_type(urn: str) -> str:
    """'urn:schemas-upnp-org:service:WANIPConnection:1' -> 'WANIPConnection:1'."""
    parts = urn.split(":")
    return ":".join(parts[-2:]) if len(parts) >= 2 else urn


def run_gateway(verdict: dict | None = None, discover: Callable[..., list] | None = None,
                get: Callable[..., tuple[int, str]] | None = None,
                soap: Callable[..., tuple[int, str]] | None = None) -> dict[str, Any]:
    """Operator pressed the button. One SSDP search, one description, two SOAP calls. Never raises.

    `verdict` is NOT a gate for this part (the segment is local); it is passed
    so the result can say, at a raised posture, that the operator chose to
    transmit on a segment they declared hostile."""
    discover = discover or ssdp_discover
    get = get or http_get_local
    soap = soap or soap_call
    t0 = time.monotonic()
    sent: list[str] = ["%d × SSDP M-SEARCH → %s:%d (TTL %d): %s" % (
        len(SSDP_TARGETS), SSDP_GROUP[0], SSDP_GROUP[1], SSDP_TTL, ", ".join(_short_type(t) for t in SSDP_TARGETS))]
    result: dict[str, Any] = {"answered": False, "responses": 0, "device": None, "wan": None,
                              "skipped": [], "errors": [], "sent": sent, "claim_label": GATEWAY_CLAIM_LABEL,
                              "listen_seconds": SSDP_TIMEOUT}
    try:
        responses = discover()
        result["responses"] = len(responses)
        chosen = None
        for resp in responses:
            ok, why = location_is_local(resp.get("location", ""))
            if ok and chosen is None:
                chosen = resp
            else:
                result["skipped"].append({"location": resp.get("location"),
                                          "why": why or "a second answer; the first was used"})
        if chosen is None:
            if responses:
                result["note"] = ("%d device(s) answered but none named a local LOCATION; nothing was fetched."
                                  % len(responses))
            else:
                result["note"] = ("No gateway answered the SSDP M-SEARCH within %.0f s. Either there is no UPnP "
                                  "IGD on this segment, the gateway has UPnP off, or multicast does not reach it. "
                                  "That is an absence of an answer, not evidence about the gateway." % SSDP_TIMEOUT)
            return _finish_gateway(result, "no-answer", t0, verdict)

        result["answered"] = True
        location = chosen["location"]
        device: dict[str, Any] = {"location": location, "peer": chosen.get("peer"), "server": chosen.get("server"),
                                  "st": chosen.get("st"), "usn": chosen.get("usn"),
                                  "claim_label": GATEWAY_CLAIM_LABEL}
        result["device"] = device
        sent.append("HTTP GET %s" % location)
        try:
            status, body = get(location)
            if status != 200:
                raise ValueError("HTTP %d for the device description" % status)
            desc = parse_device_description(body)
        except (OSError, ValueError, http.client.HTTPException, ET.ParseError) as exc:
            result["errors"].append("device description: %s" % exc)
            return _finish_gateway(result, "done", t0, verdict)
        device.update({k: desc.get(k) for k in ("friendly_name", "manufacturer", "model_name", "model_number",
                                                   "model_description", "device_type")})
        base = desc.get("url_base") or location
        wan: dict[str, Any] = {"claim_label": GATEWAY_CLAIM_LABEL}
        result["wan"] = wan
        plan = ((WAN_IP_SERVICES, "GetExternalIPAddress", {"NewExternalIPAddress": "external_ip"}),
                ((WAN_LINK_SERVICE,), "GetCommonLinkProperties",
                 {"NewWANAccessType": "access_type", "NewLayer1UpstreamMaxBitRate": "upstream_bps",
                  "NewLayer1DownstreamMaxBitRate": "downstream_bps", "NewPhysicalLinkStatus": "link_status"}))
        for needles, action, keys in plan:
            svc = find_service(desc["services"], needles)
            if svc is None or not svc.get("control_url"):
                result["errors"].append("%s: the gateway lists no %s service" % (action, " / ".join(needles)))
                continue
            control = urllib.parse.urljoin(base, svc["control_url"])
            ok, why = location_is_local(control)
            if not ok:
                result["errors"].append("%s: controlURL %s refused (%s)" % (action, control, why))
                continue
            sent.append("SOAP POST %s %s#%s" % (control, _short_type(svc["type"]), action))
            try:
                _status, body = soap(control, svc["type"], action)
                parsed = parse_soap_response(body, action)
            except (OSError, ValueError, http.client.HTTPException, ET.ParseError) as exc:
                result["errors"].append("%s: %s" % (action, exc))
                continue
            if "fault" in parsed:
                f = parsed["fault"]
                result["errors"].append("%s: UPnP fault %s %s" % (action, f.get("code"), f.get("description")))
                continue
            wan["service_%s" % action] = _short_type(svc["type"])
            for src, dst in keys.items():
                wan[dst] = parsed.get(src) or None
        if "external_ip" in wan:
            wan["external_ip_class"] = classify_external_ip(wan["external_ip"])
        for k in ("upstream_bps", "downstream_bps"):
            if wan.get(k):
                wan[k.replace("_bps", "_label")] = fmt_bitrate(wan[k])
        return _finish_gateway(result, "done", t0, verdict)
    except Exception as exc:  # noqa: BLE001  — a button handler must answer, never 500
        result["errors"].append("unexpected: %s: %s" % (exc.__class__.__name__, exc))
        return _finish_gateway(result, "error", t0, verdict)


def _finish_gateway(result: dict, state: str, t0: float, verdict: dict | None) -> dict[str, Any]:
    result["elapsed_ms"] = round((time.monotonic() - t0) * 1000.0, 1)
    if verdict and verdict.get("state") == "shields-up":
        result["caution"] = ("Posture is %s. You chose to transmit a multicast search on a segment you declared "
                             "hostile; the gateway and anything listening on this segment saw it."
                             % str(verdict.get("headline", "")).split(" — ")[0])
    return _entry("gateway", state, result)


# ---------------------------------------------------------------- Part B: run_outbound

def probe_refusal(verdict: dict) -> dict[str, Any]:
    """GODSEYE-style refusal for the upstream probes, from the outbound verdict. Pure.

    Names the posture (the verdict's headline carries the tier label), the
    exact parties this run would have contacted, what still works, the remedy."""
    state = str(verdict.get("state") or "blocked")
    parties = ", ".join(third_parties())
    base = {"state": state, "headline": str(verdict.get("headline") or "Outbound refused — upstream probes not run"),
            "label": PROBE_LABEL, "remedy": str(verdict.get("remedy") or "")}
    if state == "shields-up":
        base.update({
            "what": "The upstream probes would have contacted %s: %s" % (parties, outbound_sends()),
            "so_what": "On a network you have declared hostile, each of those packets announces this deck and "
                       "what it is checking. Decoys are live; this would undo them. The probes were not run.",
            "still_works": "The passive picture above, and the gateway identity check (it transmits on this "
                           "segment only).",
        })
    elif state == "no-route":
        base.update({
            "what": "This deck has no default route, so none of the probes (%s) could leave the segment." % parties,
            "so_what": "Every probe would time out, and a page of timeouts looks exactly like a blocked upstream. "
                       "Not running them is the honest answer: there is no upstream to measure.",
            "still_works": "The passive picture above, and the gateway identity check.",
        })
    else:
        base.update({
            "what": "This server could not establish what threat posture the deck is in. "
                    + str(verdict.get("detail") or ""),
            "so_what": "Contacting %s on an unknown posture is a decision this deck is not entitled to make on "
                       "your behalf. It fails closed." % parties,
            "still_works": "The passive picture above, and the gateway identity check.",
        })
    return base


def _dns_rows(system_q: Callable[[str], dict], direct_q: Callable[..., dict]) -> dict[str, Any]:
    rows = []
    direct_dead = 0
    for name, expected in DNS_CANARIES:
        exp = set(expected)
        sys_r = system_q(name)
        dir_r = direct_q(name, DIRECT_RESOLVERS[0])
        resolver_used = DIRECT_RESOLVERS[0][0]
        if "error" in dir_r:
            alt = direct_q(name, DIRECT_RESOLVERS[1])
            if "error" not in alt:
                dir_r, resolver_used = alt, DIRECT_RESOLVERS[1][0]
        row = {"name": name, "expected": sorted(exp), "system": sys_r.get("answers"),
               "system_error": sys_r.get("error"), "direct": dir_r.get("answers"),
               "direct_error": dir_r.get("error"), "direct_resolver": resolver_used}
        if sys_r.get("error") or not sys_r.get("answers"):
            row["system_verdict"] = "failed: %s" % (sys_r.get("error") or sys_r.get("rcode_name") or "no answer")
        elif set(sys_r["answers"]) <= exp:
            row["system_verdict"] = "clean"
        else:
            row["system_verdict"] = "rewritten: the local resolver answered with addresses that are not this name's"
        if dir_r.get("error"):
            row["direct_verdict"] = "no answer: udp/53 to %s dropped or blocked" % DIRECT_RESOLVERS[0][0]
            direct_dead += 1
        elif not dir_r.get("answers"):
            row["direct_verdict"] = "%s with no A records" % dir_r.get("rcode_name", "empty")
        elif set(dir_r["answers"]) <= exp:
            row["direct_verdict"] = "clean"
        else:
            row["direct_verdict"] = "intercepted: something answered as the direct resolver with other addresses"
        rows.append(row)
    canary = "orionx-canary-%08x%s" % (random.getrandbits(32), NXDOMAIN_CANARY_SUFFIX)
    sys_nx = system_q(canary)
    dir_nx = direct_q(canary, DIRECT_RESOLVERS[0])
    nx = {"name": canary, "system": sys_nx.get("answers"), "system_rcode": sys_nx.get("rcode_name"),
          "system_error": sys_nx.get("error"), "direct": dir_nx.get("answers"),
          "direct_rcode": dir_nx.get("rcode_name"), "direct_error": dir_nx.get("error")}
    if sys_nx.get("answers"):
        nx["verdict"] = "NXDOMAIN rewriting: the local resolver answered a name that cannot exist"
    elif sys_nx.get("error"):
        nx["verdict"] = "failed: %s" % sys_nx["error"]
    else:
        nx["verdict"] = "clean (NXDOMAIN as it must be)"
    flags = [r["system_verdict"] for r in rows if r["system_verdict"] != "clean"]
    flags += [r["direct_verdict"] for r in rows if r["direct_verdict"].startswith("intercepted")]
    if nx["verdict"].startswith("NXDOMAIN rewriting"):
        flags.append(nx["verdict"])
    if flags:
        verdict = "filtering or rewriting seen (%d finding%s)" % (len(flags), "" if len(flags) == 1 else "s")
    elif direct_dead == len(rows):
        verdict = "local resolver clean; a direct resolver cannot be reached — DNS is forced through the local one"
    else:
        verdict = "no filtering seen on %d canaries" % len(rows)
    return {"rows": rows, "nxdomain": nx, "verdict": verdict, "direct_unreachable": direct_dead,
            "resolvers": ["%s:%d" % r for r in DIRECT_RESOLVERS]}


def _captive_row(check: Callable[..., dict]) -> dict[str, Any]:
    host, path, want = CAPTIVE_CHECK
    r = check(host, path)
    row = {"url": "http://%s%s" % (host, path), "expected": want}
    row.update(r)
    status = int(r.get("status") or 0)
    if r.get("error"):
        row["verdict"] = "unreachable: %s (tcp/80 blocked, or no internet)" % r["error"]
    elif status == want:
        row["verdict"] = "none seen (%d as expected)" % want
    elif 300 <= status < 400:
        where = urllib.parse.urlsplit(r.get("location") or "").hostname or r.get("location") or "?"
        row["verdict"] = "captive portal likely: redirected to %s" % where
    else:
        row["verdict"] = "intercepted: HTTP %s returned instead of %d" % (r.get("status"), want)
    return row


def _port_rows(connect: Callable[..., str]) -> dict[str, Any]:
    results: dict[int, str] = {}

    def one(port: int, host: str) -> None:
        try:
            results[port] = connect(host, port)
        except Exception as exc:  # noqa: BLE001  — an exception is an error row, never a fake "timeout"
            results[port] = "error: %s" % exc

    threads = [threading.Thread(target=one, args=(p, h), daemon=True) for p, h, _s in PORT_TARGETS]
    for t in threads:
        t.start()
    for t in threads:
        t.join(CONNECT_TIMEOUT + 2.0)
    rows = [{"port": p, "host": h, "service": s, "result": results.get(p, "timeout")} for p, h, s in PORT_TARGETS]
    connected = [r["port"] for r in rows if r["result"] == "connected"]
    timed_out = [r["port"] for r in rows if r["result"] == "timeout"]
    unresolved = [r["port"] for r in rows if r["result"] == "unresolved"]
    if not connected:
        verdict = ("names did not resolve: DNS failed before any port was tried" if unresolved else
                   "nothing connected: no internet path, or everything filtered — not evidence of per-port blocking")
    elif timed_out:
        verdict = "possible blocking: %s timed out while %s connected" % (
            ", ".join(map(str, timed_out)), ", ".join(map(str, connected)))
    else:
        verdict = "no port blocking seen on %d ports" % len(rows)
    return {"rows": rows, "verdict": verdict,
            "note": "a refused connection means the path is open and the host did not listen; "
                    "a timeout means filtered or dropped"}


def run_outbound(verdict: dict, system_q: Callable[[str], dict] | None = None,
                 direct_q: Callable[..., dict] | None = None, captive: Callable[..., dict] | None = None,
                 connect: Callable[..., str] | None = None) -> dict[str, Any]:
    """Operator pressed the button. The verdict comes FIRST and is checked before any transmitter.

    Returns the refusal entry (state "refused") when outbound is not allowed;
    otherwise the three probes' rows under one entry. Never raises."""
    if not verdict.get("allowed"):
        return _entry("outbound", "refused", None, refusal=probe_refusal(verdict))
    system_q = system_q or dns_query_system
    direct_q = direct_q or dns_query_direct
    captive = captive or captive_check
    connect = connect or tcp_connect
    t0 = time.monotonic()
    result: dict[str, Any] = {"label": PROBE_LABEL, "sent": outbound_sends(), "parties": third_parties(),
                              "route_headline": verdict.get("headline"), "errors": []}
    for key, fn in (("dns", lambda: _dns_rows(system_q, direct_q)),
                    ("captive", lambda: _captive_row(captive)),
                    ("ports", lambda: _port_rows(connect))):
        try:
            result[key] = fn()
        except Exception as exc:  # noqa: BLE001  — one probe failing must not hide the other two
            result["errors"].append("%s: %s: %s" % (key, exc.__class__.__name__, exc))
    result["elapsed_ms"] = round((time.monotonic() - t0) * 1000.0, 1)
    return _entry("outbound", "done" if not result["errors"] else "error", result)
