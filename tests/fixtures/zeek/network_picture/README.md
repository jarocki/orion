# network_picture fixtures (#93, DEC-PHASE13-046)

Generated Zeek TSV logs for `tests/unit/test_network_picture.sh`. Unlike the
`conn.log` / `weird.log` one level up (real Zeek 8.1.1 output), these are
written by `gen_network_picture.py` beside them (edit the rows there and re-run): provoking
WPAD, LLMNR, mDNS, LDAP, DHCP and SSDP traffic needs a live segment a build
host does not have. The `#fields` / `#types` headers match what Zeek 8 writes
for `conn`, `dns` and `dhcp`; `ssdp.log` follows the community ssdp package
(there is no ssdp log in base Zeek, which is why the engine also reads SSDP
from conn.log port 1900).

The deck in this scenario is `192.168.4.57`; the window the test uses is
`now=1790658600`, 900 s. One `conn.log` record (`Cb2`, host 192.168.4.99) is
deliberately 1600 s old and must NOT be counted.

- `network_picture/` — every sighting class present once; the test asserts each is `present`.
- `network_picture_quiet/` — the same four logs, in-window, with only ordinary
  traffic; the test asserts each sighting is `absent` (its log was read and showed
  nothing), never `unknown`.

A missing directory is the third scenario (Zeek absent): every Zeek-fed row
must be `unknown` and named in `degraded`.
