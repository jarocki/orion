#!/usr/bin/env python3
"""Generate the network_picture Zeek fixtures (#93). Run from the repo root:

    python3 tests/fixtures/zeek/gen_network_picture.py

Writes network_picture/ (every sighting class present) and
network_picture_quiet/ (logs present, nothing sighted). Tabs are real tabs;
headers follow Zeek 8's conn/dns/dhcp logs and the community ssdp package.
Edit the rows here, not the .log files, and re-run.
"""
from pathlib import Path

R = Path(__file__).resolve().parent
CONN_F = "ts uid id.orig_h id.orig_p id.resp_h id.resp_p proto service duration orig_bytes resp_bytes conn_state local_orig local_resp missed_bytes history orig_pkts orig_ip_bytes resp_pkts resp_ip_bytes tunnel_parents ip_proto".split()
CONN_T = "time string addr port addr port enum string interval count count string bool bool count string count count count count set[string] count".split()
DNS_F = "ts uid id.orig_h id.orig_p id.resp_h id.resp_p proto trans_id rtt query qclass qclass_name qtype qtype_name rcode rcode_name AA TC RD RA Z answers TTLs rejected".split()
DNS_T = "time string addr port addr port enum count interval string count string count string count string bool bool bool bool count vector[string] vector[interval] bool".split()
DHCP_F = "ts uids client_addr server_addr mac host_name client_fqdn domain requested_addr assigned_addr lease_time client_message server_message msg_types duration".split()
DHCP_T = "time set[string] addr addr string string string string addr addr interval string string vector[string] interval".split()
SSDP_F = "ts uid id.orig_h id.orig_p id.resp_h id.resp_p method uri user_agent server location".split()
SSDP_T = "time string addr port addr port string string string string string".split()


def header(path, fields, types):
    return ("#separator \\x09\n#set_separator\t,\n#empty_field\t(empty)\n#unset_field\t-\n#path\t%s\n"
            "#open\t2026-11-06-10-00-00\n#fields\t%s\n#types\t%s\n" % (path, "\t".join(fields), "\t".join(types)))


def write(dirname, name, fields, types, rows):
    d = R / dirname
    d.mkdir(parents=True, exist_ok=True)
    body = header(name.split(".")[0], fields, types)
    for r in rows:
        assert len(r) == len(fields), (name, len(r), len(fields), r)
        body += "\t".join(r) + "\n"
    body += "#close\t2026-11-06-10-15-00\n"
    (d / name).write_text(body, encoding="utf-8")


def conn(ts, uid, oh, op, rh, rp, proto, svc, ob, rb, st, opk, rpk):
    local_resp = "T" if rh.startswith(("192.168.", "224.", "239.", "255.")) else "F"
    return [ts, uid, oh, op, rh, rp, proto, svc, "0.5", ob, rb, st, "T", local_resp, "0", "Dd",
            opk, str(int(ob) + 40 * int(opk)), rpk, str(int(rb) + 40 * int(rpk)), "-",
            "17" if proto == "udp" else "6"]


def dns(ts, uid, oh, op, rh, rp, q, qt):
    return [ts, uid, oh, op, rh, rp, "udp", "4242", "0.010000", q, "1", "C_INTERNET",
            "1" if qt == "A" else "12", qt, "0", "NOERROR", "F", "F", "T", "F", "0", "-", "-", "F"]


# --- rich: every sighting class present; one record out of the window; deck = 192.168.4.57
RICH_CONN = [
    conn("1790658010.000000", "Ca1", "192.168.4.57", "50000", "93.184.216.34", "443", "tcp", "ssl", "1200", "54000", "SF", "20", "45"),
    conn("1790658020.000000", "Ca2", "192.168.4.23", "51000", "192.168.4.57", "22", "tcp", "ssh", "3000", "8000", "SF", "30", "28"),
    conn("1790658030.000000", "Ca3", "192.168.4.23", "137", "192.168.4.255", "137", "udp", "dns", "50", "0", "S0", "1", "0"),
    conn("1790658040.000000", "Ca4", "192.168.4.44", "5355", "224.0.0.252", "5355", "udp", "dns", "40", "0", "S0", "1", "0"),
    conn("1790658050.000000", "Ca5", "192.168.4.44", "5353", "224.0.0.251", "5353", "udp", "dns", "90", "0", "S0", "2", "0"),
    conn("1790658060.000000", "Ca6", "192.168.4.23", "52000", "192.168.4.10", "389", "tcp", "-", "400", "900", "SF", "6", "5"),
    conn("1790658070.000000", "Ca7", "192.168.4.44", "1900", "239.255.255.250", "1900", "udp", "-", "120", "0", "S0", "1", "0"),
    conn("1790658080.000000", "Ca8", "0.0.0.0", "68", "255.255.255.255", "67", "udp", "dhcp", "300", "0", "S0", "1", "0"),
    conn("1790658090.000000", "Ca9", "192.168.4.88", "53000", "192.168.4.10", "445", "tcp", "smb", "2000", "7000", "SF", "12", "14"),
    conn("1790658100.000000", "Cb1", "192.168.4.44", "54000", "142.250.74.14", "443", "tcp", "ssl", "500", "2500", "SF", "8", "9"),
    conn("1790657000.000000", "Cb2", "192.168.4.99", "55000", "192.168.4.57", "22", "tcp", "ssh", "100", "100", "SF", "3", "3"),  # OUT OF WINDOW
    conn("1790658110.000000", "Cb3", "192.168.4.23", "52001", "192.168.4.10", "636", "tcp", "-", "0", "0", "S0", "1", "0"),
]
RICH_DNS = [
    dns("1790658015.000000", "Cd1", "192.168.4.23", "53211", "192.168.4.1", "53", "wpad.lan", "A"),
    dns("1790658016.000000", "Cd2", "192.168.4.44", "5353", "224.0.0.251", "5353", "_googlecast._tcp.local", "PTR"),
    dns("1790658017.000000", "Cd3", "192.168.4.44", "5355", "224.0.0.252", "5355", "FILESERVER", "A"),
    dns("1790658018.000000", "Cd4", "192.168.4.23", "137", "192.168.4.255", "137", "WORKGROUP", "A"),
    dns("1790658019.000000", "Cd5", "192.168.4.88", "40000", "192.168.4.1", "53", "example.com", "A"),
    dns("1790658021.000000", "Cd6", "192.168.4.44", "5353", "224.0.0.251", "5353", "_hap._tcp.local", "PTR"),
]
RICH_DHCP = [["1790658085.000000", "Ca8", "192.168.4.88", "192.168.4.1", "b8:27:eb:44:55:66", "pi-sensor", "-", "lan",
              "192.168.4.88", "192.168.4.88", "86400.000000", "-", "-", "DISCOVER,OFFER,REQUEST,ACK", "0.123000"]]
RICH_SSDP = [["1790658075.000000", "Ca7", "192.168.4.44", "1900", "239.255.255.250", "1900", "M-SEARCH", "*",
              "Sonos/80.1 UPnP/1.0", "-", "-"]]

# --- quiet: the same four logs, in-window, nothing sighted
QUIET_CONN = [
    conn("1790658010.000000", "Cq1", "192.168.4.57", "50000", "93.184.216.34", "443", "tcp", "ssl", "1200", "54000", "SF", "20", "45"),
    conn("1790658020.000000", "Cq2", "192.168.4.23", "51000", "192.168.4.57", "22", "tcp", "ssh", "3000", "8000", "SF", "30", "28"),
]
QUIET_DNS = [dns("1790658019.000000", "Cq3", "192.168.4.23", "40000", "192.168.4.1", "53", "example.com", "A")]


def main() -> None:
    write("network_picture", "conn.log", CONN_F, CONN_T, RICH_CONN)
    write("network_picture", "dns.log", DNS_F, DNS_T, RICH_DNS)
    write("network_picture", "dhcp.log", DHCP_F, DHCP_T, RICH_DHCP)
    write("network_picture", "ssdp.log", SSDP_F, SSDP_T, RICH_SSDP)
    write("network_picture_quiet", "conn.log", CONN_F, CONN_T, QUIET_CONN)
    write("network_picture_quiet", "dns.log", DNS_F, DNS_T, QUIET_DNS)
    write("network_picture_quiet", "dhcp.log", DHCP_F, DHCP_T, [])
    write("network_picture_quiet", "ssdp.log", SSDP_F, SSDP_T, [])
    print("network_picture fixtures written under", R)


if __name__ == "__main__":
    main()
