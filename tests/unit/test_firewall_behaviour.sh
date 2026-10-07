#!/usr/bin/env bash
# shellcheck shell=bash
#
# Firewall BEHAVIOUR (DEC-PHASE12-104): load the shipped nftables.conf into a
# network namespace and send real packets at it from a "LAN" and from "wg0".
#
# Topology inside a privileged debian:trixie-slim container:
#   ns "lan" --veth lan0/lanB-- ns "deck" (firewall) --veth wgA/wg0-- ns "peer"
# Asserts: 22 and 8008 refused from the LAN, accepted from wg0; 51820/udp
# accepted on the LAN; a foreign nft table survives a reload and `ExecStop`;
# `nft -c -f` passes. Skips (not passes) without docker.
# Usage: bash tests/unit/test_firewall_behaviour.sh  (ORIONX_SKIP_DOCKER=1 skips)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="$ROOT/iso/config/includes.chroot/etc/nftables.conf"

if [[ "${ORIONX_SKIP_DOCKER:-0}" == 1 ]] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "  SKIP: docker unavailable — firewall behaviour not exercised"
    echo "Results: 0 passed, 0 failed, 1 skipped"
    exit 0
fi

read -r -d '' INNER <<'INNER_EOF'
set -u
apt-get update -qq >/dev/null && apt-get install -y -qq nftables socat iproute2 iputils-ping >/dev/null 2>&1 || { echo "FAIL: apt"; exit 1; }
P=0; F=0
ok() { P=$((P+1)); echo "  PASS: $1"; }
no() { F=$((F+1)); echo "  FAIL: $1"; }
nft -c -f /conf/nftables.conf && ok "nft -c -f accepts the ruleset" || no "nft -c -f accepts the ruleset"
for n in lan deck peer; do ip netns add $n; done
ip link add lan0 type veth peer name lanB; ip link set lan0 netns lan; ip link set lanB netns deck
ip link add wgA type veth peer name wg0;  ip link set wgA netns peer; ip link set wg0 netns deck
ip -n lan  addr add 192.168.50.2/24 dev lan0; ip -n deck addr add 192.168.50.1/24 dev lanB
ip -n peer addr add 10.0.99.2/24 dev wgA;    ip -n deck addr add 10.0.99.1/24 dev wg0
for n in lan deck peer; do ip -n $n link set lo up; done
ip -n lan link set lan0 up; ip -n deck link set lanB up; ip -n deck link set wg0 up; ip -n peer link set wgA up
D="ip netns exec deck"
$D nft add table inet heald_test
$D nft add chain inet heald_test c
$D nft -f /conf/nftables.conf && ok "ruleset loads" || no "ruleset loads"
$D nft -f /conf/nftables.conf && ok "ruleset reloads (idempotent)" || no "ruleset reloads"
$D nft list tables | grep -q heald_test && ok "a foreign table survives load + reload (F15)" || no "foreign table survives reload"
for port in 22 8008; do
  $D socat TCP-LISTEN:$port,fork,reuseaddr SYSTEM:'echo hi' & sleep 0.3
done
$D socat -u UDP-RECV:51820 OPEN:/tmp/wg.rx,creat,append & sleep 0.3
tcp() { ip netns exec "$1" timeout 3 socat -T2 - TCP:"$2":"$3",connect-timeout=2 </dev/null 2>/dev/null | grep -q hi; }
tcp lan 192.168.50.1 22   && no "SSH refused from the LAN" || ok "SSH refused from the LAN"
tcp lan 192.168.50.1 8008 && no "Matrix 8008 refused from the LAN" || ok "Matrix 8008 refused from the LAN"
tcp peer 10.0.99.1 22     && ok "SSH accepted from wg0" || no "SSH accepted from wg0"
tcp peer 10.0.99.1 8008   && ok "Matrix 8008 accepted from wg0" || no "Matrix 8008 accepted from wg0"
echo ping | ip netns exec lan socat - UDP-DATAGRAM:192.168.50.1:51820; sleep 0.5
grep -q ping /tmp/wg.rx 2>/dev/null && ok "WireGuard 51820/udp accepted from the LAN" || no "WireGuard 51820/udp accepted from the LAN"
command -v ping >/dev/null || no "ping is installed (else the ICMP checks are vacuous)"
ip netns exec lan ping -c1 -W1 192.168.50.1 >/dev/null 2>&1 && no "echo-request dropped on the LAN (F26)" || ok "echo-request dropped on the LAN (F26)"
ip netns exec peer ping -c1 -W1 10.0.99.1 >/dev/null 2>&1 && ok "echo-request answered on wg0 (mesh health checks)" || no "echo-request answered on wg0"
$D nft delete table inet orionx_firewall && $D nft list tables | grep -q heald_test && ok "ExecStop's delete leaves the foreign table" || no "ExecStop leaves the foreign table"
echo "Results: $P passed, $F failed"
[ $F -eq 0 ]
INNER_EOF

docker run --rm --privileged -v "$CONF:/conf/nftables.conf:ro" debian:trixie-slim bash -c "$INNER"
