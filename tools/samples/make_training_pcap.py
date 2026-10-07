#!/usr/bin/env python3
"""
make_training_pcap.py — build data/samples/pcaps/apt_malware_traffic.pcap.

A deterministic, SYNTHETIC capture of an intrusion story for practice with
tshark, Wireshark, Zeek, pcap-analyzer.py and the Cockpit. It contains no
malware and no real infrastructure:

  * the victim network is RFC 1918 (10.10.20.0/24),
  * every "attacker" address is in the RFC 5737 documentation ranges
    (198.51.100.0/24, 203.0.113.0/24),
  * every domain is under .example (RFC 2606),
  * every payload is plain, labelled text.

The story, in order (times are seconds from the first packet):
  0     DNS lookup of update-cdn-sync.example -> 203.0.113.45
  1     HTTP GET /stage1.bin from 203.0.113.45 (a labelled text "payload")
  10..  ten TLS beacons to 198.51.100.23:443, SNI cdn-telemetry.example,
        every ~60 s with jitter (the C2 pattern pcap-analyzer looks for)
  120.. DNS TXT queries with hex labels under exfil.example (DNS tunnelling)
  300   SYN sweep of 10.10.20.0/24 on 445 and 3389 (internal recon)
  330   SMB session to 10.10.20.30:445 (lateral movement)

    python3 tools/samples/make_training_pcap.py [OUT]   # default: the data/ path

Re-running produces a byte-identical file (fixed seed, fixed epoch); a unit
test regenerates it and compares.

@decision DEC-PHASE12-066
@title The APT training capture is synthesised from a script, not shipped as a placeholder
@status accepted
@rationale Through v2.2.0-rc9 the file named apt_malware_traffic.pcap was a
  42-byte text file ("# Placeholder for ..."), which tshark misread as an
  empty SocketCAN capture. The User Guide's sample-data section and the
  release video both use it, so the deck taught analysis on nothing. A real
  capture of real malware cannot ship on a USB image we hand to responders;
  a generated story over reserved address space can, and the generator makes
  every byte reviewable.
"""
from __future__ import annotations

import random
import struct
import sys
from pathlib import Path

EPOCH = 1768470000          # 2026-01-15T09:40:00Z, fixed
SEED = 20260115

VICTIM = "10.10.20.15"
GATEWAY = "10.10.20.1"
DNS = "10.10.20.53"
FILESERVER = "10.10.20.30"
STAGER = "203.0.113.45"
C2 = "198.51.100.23"
MAC = {VICTIM: "02:00:0a:0a:14:0f", GATEWAY: "02:00:0a:0a:14:01", DNS: "02:00:0a:0a:14:35",
       FILESERVER: "02:00:0a:0a:14:1e"}


def mac_bytes(m: str) -> bytes:
    return bytes(int(x, 16) for x in m.split(":"))


def ip_bytes(a: str) -> bytes:
    return bytes(int(x) for x in a.split("."))


def csum(data: bytes) -> int:
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


class Writer:
    def __init__(self) -> None:
        self.records: list[bytes] = []
        self.ip_id = 1000

    def _l2_mac(self, ip: str) -> str:
        # Off-subnet addresses are reached through the gateway's MAC.
        return MAC.get(ip, MAC[GATEWAY])

    def frame(self, t: float, src: str, dst: str, proto: int, l4: bytes) -> None:
        self.ip_id = (self.ip_id + 1) & 0xFFFF
        hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(l4), self.ip_id, 0x4000, 64, proto, 0,
                          ip_bytes(src), ip_bytes(dst))
        hdr = hdr[:10] + struct.pack("!H", csum(hdr)) + hdr[12:]
        eth = mac_bytes(self._l2_mac(dst)) + mac_bytes(self._l2_mac(src)) + b"\x08\x00"
        pkt = eth + hdr + l4
        sec = int(EPOCH + t)
        usec = int(round((EPOCH + t - sec) * 1_000_000))
        self.records.append(struct.pack("<IIII", sec, usec, len(pkt), len(pkt)) + pkt)

    def udp(self, t, src, sport, dst, dport, payload: bytes) -> None:
        ln = 8 + len(payload)
        pseudo = ip_bytes(src) + ip_bytes(dst) + struct.pack("!BBH", 0, 17, ln)
        seg = struct.pack("!HHHH", sport, dport, ln, 0) + payload
        seg = seg[:6] + struct.pack("!H", csum(pseudo + seg) or 0xFFFF) + seg[8:]
        self.frame(t, src, dst, 17, seg)

    def tcp(self, t, src, sport, dst, dport, seq, ack, flags: str, payload: bytes = b"") -> None:
        fl = sum({"F": 1, "S": 2, "R": 4, "P": 8, "A": 16}[c] for c in flags)
        seg = struct.pack("!HHIIBBHHH", sport, dport, seq & 0xFFFFFFFF, ack & 0xFFFFFFFF, 5 << 4, fl, 64240, 0, 0) + payload
        pseudo = ip_bytes(src) + ip_bytes(dst) + struct.pack("!BBH", 0, 6, len(seg))
        seg = seg[:16] + struct.pack("!H", csum(pseudo + seg)) + seg[18:]
        self.frame(t, src, dst, 6, seg)

    def write(self, path: Path) -> None:
        g = struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)
        path.write_bytes(g + b"".join(self.records))


def dns_name(name: str) -> bytes:
    return b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"


def dns_query(qid: int, name: str, qtype: int) -> bytes:
    return struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0) + dns_name(name) + struct.pack("!HH", qtype, 1)


def dns_answer_a(qid: int, name: str, addr: str) -> bytes:
    q = dns_name(name) + struct.pack("!HH", 1, 1)
    ans = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 300, 4) + ip_bytes(addr)
    return struct.pack("!HHHHHH", qid, 0x8180, 1, 1, 0, 0) + q + ans


def dns_answer_txt(qid: int, name: str, text: str) -> bytes:
    q = dns_name(name) + struct.pack("!HH", 16, 1)
    rd = bytes([len(text)]) + text.encode()
    ans = b"\xc0\x0c" + struct.pack("!HHIH", 16, 1, 60, len(rd)) + rd
    return struct.pack("!HHHHHH", qid, 0x8180, 1, 1, 0, 0) + q + ans


def tls_client_hello(sni: str, rnd: random.Random) -> bytes:
    name = sni.encode()
    sni_ext = struct.pack("!HHHBH", 0, len(name) + 5, len(name) + 3, 0, len(name)) + name
    suites = struct.pack("!H", 6) + struct.pack("!HHH", 0x1301, 0x1302, 0xC02F)
    body = (struct.pack("!H", 0x0303) + bytes(rnd.getrandbits(8) for _ in range(32)) + b"\x00" + suites
            + b"\x01\x00" + struct.pack("!H", len(sni_ext)) + sni_ext)
    hs = b"\x01" + struct.pack("!I", len(body))[1:] + body
    return b"\x16\x03\x01" + struct.pack("!H", len(hs)) + hs


def tls_server_hello(rnd: random.Random) -> bytes:
    ext = struct.pack("!HHH", 0x002B, 2, 0x0304)                # supported_versions: TLS 1.3
    body = (struct.pack("!H", 0x0303) + bytes(rnd.getrandbits(8) for _ in range(32)) + b"\x00"
            + struct.pack("!H", 0x1301) + b"\x00" + struct.pack("!H", len(ext)) + ext)
    hs = b"\x02" + struct.pack("!I", len(body))[1:] + body
    return b"\x16\x03\x03" + struct.pack("!H", len(hs)) + hs


def smb2_negotiate_request() -> bytes:
    hdr = (b"\xfeSMB" + struct.pack("<HHIHHIIQIIQ", 64, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0) + b"\x00" * 16)
    dialects = (0x0202, 0x0210, 0x0300, 0x0302, 0x0311)
    body = (struct.pack("<HHHHI", 36, len(dialects), 1, 0, 0) + b"ORIONX-SYNTHETIC"  # ClientGuid (16)
            + b"\x00" * 8 + b"".join(struct.pack("<H", d) for d in dialects))
    msg = hdr + body
    return struct.pack("!I", len(msg)) + msg                    # NetBIOS session length


def session(w: Writer, t: float, src: str, sport: int, dst: str, dport: int,
            req: bytes, resp: bytes, rnd: random.Random) -> float:
    """3-way handshake, one request, one response, FIN. Returns the end time."""
    cs, ss = rnd.getrandbits(32), rnd.getrandbits(32)
    rtt = 0.040 if not dst.startswith("10.") else 0.002
    w.tcp(t, src, sport, dst, dport, cs, 0, "S")
    w.tcp(t + rtt, dst, dport, src, sport, ss, cs + 1, "SA")
    w.tcp(t + rtt * 1.5, src, sport, dst, dport, cs + 1, ss + 1, "A")
    t2 = t + rtt * 2
    w.tcp(t2, src, sport, dst, dport, cs + 1, ss + 1, "PA", req)
    w.tcp(t2 + rtt, dst, dport, src, sport, ss + 1, cs + 1 + len(req), "PA" if resp else "A", resp)
    w.tcp(t2 + rtt * 1.5, src, sport, dst, dport, cs + 1 + len(req), ss + 1 + len(resp), "FA")
    w.tcp(t2 + rtt * 2.5, dst, dport, src, sport, ss + 1 + len(resp), cs + 2 + len(req), "FA")
    w.tcp(t2 + rtt * 3, src, sport, dst, dport, cs + 2 + len(req), ss + 2 + len(resp), "A")
    return t2 + rtt * 3


def build() -> Writer:
    rnd = random.Random(SEED)
    w = Writer()
    eport = iter(range(49152, 65535))

    # 1. resolve and fetch the stager
    w.udp(0.000, VICTIM, next(eport), DNS, 53, dns_query(0x1a01, "update-cdn-sync.example", 1))
    w.udp(0.012, DNS, 53, VICTIM, 49152, dns_answer_a(0x1a01, "update-cdn-sync.example", STAGER))
    req = (b"GET /stage1.bin HTTP/1.1\r\nHost: update-cdn-sync.example\r\n"
           b"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) SyncAgent/2.1\r\nAccept: */*\r\n\r\n")
    body = b"ORION-X TRAINING SAMPLE - SYNTHETIC STAGE1 PLACEHOLDER - NOT EXECUTABLE\n" * 8
    resp = (b"HTTP/1.1 200 OK\r\nServer: nginx\r\nContent-Type: application/octet-stream\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    session(w, 1.0, VICTIM, next(eport), STAGER, 80, req, resp, rnd)

    # 2. C2 beacons: ~60 s with +/-12% jitter, TLS ClientHello with a fixed SNI
    t = 10.0
    for _ in range(10):
        ch = tls_client_hello("cdn-telemetry.example", rnd)
        session(w, t, VICTIM, next(eport), C2, 443, ch, tls_server_hello(rnd), rnd)
        t += 60.0 * (1 + rnd.uniform(-0.12, 0.12))

    # 3. DNS tunnelling: hex chunks in TXT queries under exfil.example
    secret = b"training-only: host inventory 10.10.20.0/24 (synthetic)"
    for i in range(0, len(secret), 9):
        label = secret[i:i + 9].hex()
        name = f"{label}.s{i // 9}.exfil.example"
        tq = 120.0 + i * 1.7
        qid = 0x2b00 + i
        sp = next(eport)
        w.udp(tq, VICTIM, sp, DNS, 53, dns_query(qid, name, 16))
        w.udp(tq + 0.03, DNS, 53, VICTIM, sp, dns_answer_txt(qid, name, "ok"))

    # 4. internal recon: SYN sweep on 445/3389; a few hosts answer
    alive = {"10.10.20.30", "10.10.20.41", "10.10.20.77"}
    ts = 300.0
    for host in range(20, 80):
        dst = f"10.10.20.{host}"
        for port in (445, 3389):
            sp = next(eport)
            seq = rnd.getrandbits(32)
            w.tcp(ts, VICTIM, sp, dst, port, seq, 0, "S")
            if dst in alive and port == 445:
                w.tcp(ts + 0.001, dst, port, VICTIM, sp, rnd.getrandbits(32), seq + 1, "SA")
                w.tcp(ts + 0.0015, VICTIM, sp, dst, port, seq + 1, 0, "R")
            elif dst in alive:
                w.tcp(ts + 0.001, dst, port, VICTIM, sp, 0, seq + 1, "RA")
            ts += 0.05

    # 5. lateral movement: SMB2 negotiate to the file server
    session(w, 330.0, VICTIM, next(eport), FILESERVER, 445, smb2_negotiate_request(), b"", rnd)

    # keep records in time order (sessions interleave nothing, but be explicit)
    w.records.sort(key=lambda r: struct.unpack("<II", r[:8]))
    return w


def main() -> int:
    repo = Path(__file__).resolve().parents[2]
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / "data/samples/pcaps/apt_malware_traffic.pcap"
    w = build()
    w.write(out)
    print(f"wrote {out}: {len(w.records)} packets, {out.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
