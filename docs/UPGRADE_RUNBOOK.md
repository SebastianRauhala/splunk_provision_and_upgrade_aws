# aws_prov_v6.sh — Upgrade Runbook

New version lives at `aws_prov_v6.sh`. The original `aws_prov_v5.sh`
is untouched. Run with **no args** for the interactive menu, or use flags for
automation / AI agents.

## Versatile service control (init.d + systemd + binary)
`detect_service_remote` picks the management method automatically:
1. A real (non-generated) systemd unit `Splunkd|splunkd|splunk.service` -> **systemd**
2. `/etc/init.d/splunk` present (incl. generated-shim hosts) -> **init.d**
3. Fallback -> raw **binary** `/opt/splunk/bin/splunk`

- **Stop**: systemd -> `systemctl stop`; otherwise `splunk stop`. Always followed
  by a `pgrep splunkd` poll (up to 60s) so upgrades never start until splunkd is
  truly down.
- **Start**: systemd -> `systemctl start` (handles migration/accept internally);
  otherwise `splunk start --accept-license --answer-yes --no-prompt`.
- **Health**: waits until `splunk status` reports running.

Lab (3.90.172.45) resolves to `initd|/etc/init.d/splunk`. A `-systemd-managed 1`
box would resolve to `systemd|Splunkd.service` — same script, no changes.

## Actions
| Action | What it does |
|---|---|
| `detect` | Read-only: version, ITSI version, mgmt method, status, disk |
| `restart` | Safe stop (verify) -> start -> health check |
| `upgrade-splunk` | Preflight disk -> download RPM -> stop+verify -> `rpm -U` -> chown -> start(migrate) -> verify |
| `upgrade-itsi` | Preflight disk -> scp .spl -> stop+verify -> untar over etc/apps -> chown -> start(migrate) -> verify (KV backup skipped per lab scope) |

## Examples
```bash
# Read-only status (safe, verified working on lab)
./aws_prov_v6.sh --host 3.90.172.45 --action detect

# Safe restart
./aws_prov_v6.sh --host 3.90.172.45 --action restart

# Upgrade Splunk 9.4.1 -> 9.4.3 (index 7 in catalog), non-interactive
./aws_prov_v6.sh --host 3.90.172.45 --action upgrade-splunk --version-index 7 --yes

# Upgrade Splunk from an arbitrary RPM URL
./aws_prov_v6.sh --host 3.90.172.45 --action upgrade-splunk --rpm-url https://.../splunk-*.rpm --yes

# Upgrade ITSI from a local .spl
./aws_prov_v6.sh --host 3.90.172.45 --action upgrade-itsi --package ~/Downloads/itsi-4.21.x.spl --yes
```

## Catalog version indexes (for --version-index)
0=10.4.3  1=10.4.1  2=10.2.7  3=10.2.0  4=10.0.2  5=10.0.1  6=10.0.0  7=9.4.3  8=9.4.2  9=9.4.1  10=9.3.6  11=9.2.8  12=9.1.10

## Safety notes
- KV Store backup intentionally **skipped** (lab). Re-enable for production:
  `splunk backup kvstore` before stop.
- Disk on the lab is tight (~21G free / 96G). Preflight requires >=3G (Splunk)
  or >=5G (ITSI) free on /opt and will warn/prompt otherwise.
- Splunk upgrades are not cleanly reversible without a config backup; treat as
  forward-only in the lab.
