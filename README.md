# aws_provision_and_upgrade

Automated provisioning **and safe upgrades** of Splunk Enterprise (and ITSI) on
AWS EC2 (Amazon Linux 2023) over SSH.

A single master script — `splunk_provisioner.sh`. Version history lives in git
(`git log --follow splunk_provisioner.sh`); earlier standalone versions
(`aws_prov_v5/v6/v7.sh`) remain in the history rather than as files.

## Contents
| Path | Description |
|------|-------------|
| `splunk_provisioner.sh` | Master script. Interactive menu **and** non-interactive CLI for automation / AI agents. |
| `docs/UPGRADE_RUNBOOK.md` | Upgrade runbook, action reference, and safety notes. |

## Highlights
- **Versatile service control** – auto-detects and drives Splunk via **systemd**,
  **init.d**, or the raw **binary**, so the same script works across host setups.
- **Adaptive status-aware menu** – one SSH round-trip gathers state (Splunk /
  ITSI / Java / service / disk) and renders a menu offering only valid actions.
- **Fresh install** – RPM install + admin `user-seed.conf` bootstrap + systemd
  boot-start.
- **Safe upgrades** – graceful stop with a `pgrep splunkd` verification poll
  before any package change, then start + health check.
  - `upgrade-splunk` uses `rpm -U` (true upgrade) and runs post-upgrade migration.
  - `upgrade-itsi` lays the new app over `etc/apps` while splunkd is stopped.
- **Automation friendly** – flag-driven, non-interactive mode with `--yes`.

## Actions
`detect | restart | install-splunk | install-app | upgrade-splunk | upgrade-itsi | install-java`

## Quick start
```bash
# Read-only status
./splunk_provisioner.sh --host <EC2_IP> --action detect

# Fresh install (catalog index 7 = 9.4.3)
./splunk_provisioner.sh --host <EC2_IP> --action install-splunk --version-index 7 --admin-pass 'PW' --yes

# Install Java
./splunk_provisioner.sh --host <EC2_IP> --action install-java --yes

# Install any app / add-on from a local package (.spl/.tgz); --no-restart to batch
./splunk_provisioner.sh --host <EC2_IP> --action install-app --package ~/Downloads/app.spl --yes

# Safe restart
./splunk_provisioner.sh --host <EC2_IP> --action restart

# Upgrade Splunk (catalog index 0 = 10.4.3)
./splunk_provisioner.sh --host <EC2_IP> --action upgrade-splunk --version-index 0 --yes

# Upgrade ITSI from a local package
./splunk_provisioner.sh --host <EC2_IP> --action upgrade-itsi --package ~/Downloads/itsi.spl --yes
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
