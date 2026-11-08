# Orion-X Suricata

DEC-PHASE11-008 (Layer A skeleton), DEC-PHASE12-038 (capture config),
DEC-PHASE13-043 / DEC-PHASE13-044 (Layer B, W11-6b: vendored ruleset + sizing).

## Layer A — Skeleton + freshen (v2.1.0)

- Package: suricata (Debian)
- Lazy-start: /etc/systemd/system/suricata.service.d/orionx-lazy.conf gates on /var/lib/suricata/orionx-enabled
- Freshen: `sudo orionx-freshen-suricata` fetches the FULL ET-Open feed (BSD / GPLv2 by sid range)

## Layer B (W11-6b) — LANDED in v3.1.5 (issue #125)

- `rules/suricata.rules` — curated ET-Open subset (categories scan,
  attack_response, exploit, dos, shellcode, current_events + Debian's stock
  *-events protocol rules, minus dnp3/modbus which Debian's config cannot
  parse; ~3,200 signatures). VENDORED into the Orion-X source tree
  (iso/config/includes.chroot/var/lib/suricata/rules/) and refreshed by a
  reviewed commit via `make suricata-rules-refresh`, because upstream serves
  one rolling daily tarball: a release therefore always carries the same rules.
- `rules/orionx-rules.provenance.txt` — upstream URL, tarball SHA-256, size and
  Last-Modified, refresh date, categories, counts, bytes, license, the count
  the refresh proved loads, and (appended at ISO build) the build date and the
  count the image's own engine loaded.
- `rules/LICENSE-ET-Open.txt` — the feed's license text (BSD notice).
- Build hook 0530 verifies the three files, checks the provenance count
  against the file, runs `suricata -T` and fails the build on any doubt.
- `/etc/suricata/orionx.yaml` — `detect: profile: low` + memcaps sized for a
  2 GB deck; `suricata.service.d/orionx-memory.conf` — MemoryMax (provisional
  until measured on the Lenovo; see the decision block in the 0530 hook).
- Tier wiring: orionx-postured (DEC-PHASE12-024) creates the enable file,
  starts the engine at Tier 1/2, verifies capture, ingests eve.json.

## Usage

```bash
# Enable Suricata (orionx-postured does this at Tier 1; by hand:)
sudo touch /var/lib/suricata/orionx-enabled
sudo systemctl start suricata

# Confirm the shipped set loaded
sudo journalctl -u suricata -b | grep 'rules successfully loaded'
cat /var/lib/suricata/rules/orionx-rules.provenance.txt

# Optional: the FULL feed (network; ~52,000 signatures; exhausted a 2 GB deck)
sudo orionx-freshen-suricata

# View alerts
sudo journalctl -u suricata -f
```
