#!/usr/bin/env bash
# The shipped training capture (DEC-PHASE12-141): a real, deterministic,
# synthetic pcap — never again a text placeholder named like APT traffic.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; echo "        $2"; FAIL=$((FAIL+1)); }
P="$ROOT/data/samples/pcaps/apt_malware_traffic.pcap"
T="$(mktemp -d "${ROOT}/tmp/pcap-test.XXXXXX" 2>/dev/null || mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PYTHONDONTWRITEBYTECODE=1
python3 "$ROOT/tools/samples/make_training_pcap.py" "$T/regen.pcap" >/dev/null \
  && cmp -s "$P" "$T/regen.pcap" && pass "shipped capture == generator output (byte-identical)" \
  || fail "generator reproducibility" "regenerate: python3 tools/samples/make_training_pcap.py"
out="$(python3 - "$P" <<'PY'
import ipaddress, struct, sys
d = open(sys.argv[1], "rb").read()
assert struct.unpack("<I", d[:4])[0] == 0xA1B2C3D4, "not a libpcap file"
assert struct.unpack("<I", d[20:24])[0] == 1, "linktype is not Ethernet"
off, n, bad, names = 24, 0, [], set()
ok_nets = [ipaddress.ip_network(x) for x in ("10.10.20.0/24", "198.51.100.0/24", "203.0.113.0/24")]
while off < len(d):
    _, _, incl, _ = struct.unpack("<IIII", d[off:off + 16]); pkt = d[off + 16: off + 16 + incl]; off += 16 + incl; n += 1
    ip = pkt[14:34]
    for a in (ip[12:16], ip[16:20]):
        addr = ipaddress.ip_address(a)
        if not any(addr in net for net in ok_nets): bad.append(str(addr))
    if ip[9] == 17 and 53 in struct.unpack("!HH", pkt[34:38]):
        q, i = pkt[54:], 0; labels = []
        while q[i]: labels.append(q[i + 1:i + 1 + q[i]].decode()); i += 1 + q[i]
        names.add(".".join(labels))
assert n >= 200, f"only {n} packets"
assert not bad, f"addresses outside RFC1918/RFC5737: {sorted(set(bad))[:5]}"
assert all(x.endswith(".example") for x in names), f"non-.example DNS names: {names}"
print(f"{n} packets; all addresses reserved; {len(names)} DNS names, all .example")
PY
)" && pass "$out" || fail "capture content" "$out"
grep -q "Placeholder" "$ROOT/data/samples/pcaps/README.txt" && fail "README still calls a sample a placeholder" "" || pass "README describes the synthetic story, not a placeholder"
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
