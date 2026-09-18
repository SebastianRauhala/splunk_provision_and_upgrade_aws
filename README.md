# aws_provision_and_upgrade

Automated provisioning **and safe upgrades** of Splunk Enterprise (and ITSI) on
AWS EC2 (Amazon Linux 2023) over SSH.

## Contents
| Path | Description |
|------|-------------|
| `aws_prov_v6.sh` | Main script. Interactive menu **and** non-interactive CLI for automation / AI agents. |
| `docs/UPGRADE_RUNBOOK.md` | Upgrade runbook, action reference, and safety notes. |
| `legacy/aws_prov_v5.sh` | Previous provision-only version (kept for reference). |

## Highlights
- **Versatile service control** – auto-detects and drives Splunk via **systemd**,
  **init.d**, or the raw **binary**, so the same script works across host setups.
- **Safe upgrades** – graceful stop with a `pgrep splunkd` verification poll
  before any package change, then start + health check.
  - `upgrade-splunk` uses `rpm -U` (true upgrade) and runs post-upgrade migration.
  - `upgrade-itsi` lays the new app over `etc/apps` while splunkd is stopped.
- **Automation friendly** – flag-driven, non-interactive mode with `--yes`.

## Quick start
```bash
# Read-only status
./aws_prov_v6.sh --host <EC2_IP> --action detect

# Safe restart
./aws_prov_v6.sh --host <EC2_IP> --action restart

# Upgrade Splunk (catalog index 4 = 9.4.3)
./aws_prov_v6.sh --host <EC2_IP> --action upgrade-splunk --version-index 4 --yes

# Upgrade ITSI from a local package
./aws_prov_v6.sh --host <EC2_IP> --action upgrade-itsi --package ~/Downloads/itsi.spl --yes
```

Run with no arguments for the guided interactive menu. See
`docs/UPGRADE_RUNBOOK.md` for full details.

## Requirements
- SSH access to the EC2 instance with a private key (default `~/.ssh/lab_key.pem`,
  override with `--key`).
- Passwordless `sudo` for the SSH user on the instance.

## Security
Keys, licenses, and Splunk packages are git-ignored — never commit `*.pem`,
`*.lic`, `*.rpm`, or `*.spl`.
