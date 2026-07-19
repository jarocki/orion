# Orion-X Suricata (Layer A)

DEC-PHASE11-008 IDS integration.

## Layer A — Skeleton + freshen

- Package: suricata (Debian)
- Lazy-start: /etc/systemd/system/suricata.service.d/orionx-lazy.conf gates on /var/lib/suricata/orionx-enabled
- Freshen: `sudo orionx-freshen-suricata` fetches ET-Open rules (BSD-2-Clause)

## Layer B (W11-6b) — DEFERRED

- Bundled ET-Open ruleset snapshot at build time (~15 MB)
- Nebula tier selector wiring: Tier 0 passive -> Tier 1 Suricata -> Tier 2 deception (extends W10-5)
- eve.log -> Nebula MCP adapter

## Usage

```bash
# Fetch rules first (network required)
sudo orionx-freshen-suricata

# Enable Suricata (creates the ConditionPathExists sentinel)
sudo touch /var/lib/suricata/orionx-enabled
sudo systemctl start suricata

# View alerts
sudo journalctl -u suricata -f
```
