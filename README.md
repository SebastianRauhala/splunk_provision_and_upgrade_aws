# splunk_provision_and_upgrade_aws

Automated provisioning **and safe upgrades** of Splunk Enterprise (and ITSI) on
AWS EC2 (Amazon Linux 2023) over SSH.

**Author:** Sebastian Rauhala | serauhal@cisco.com

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
- **Automation friendly** – flag-driven, non-interactive mode with `--yes`.

---

## 1. Prerequisites
- A running **Amazon Linux 2023** EC2 instance and its **public IP**.
- The EC2 SSH **private key** (`.pem`) — see the setup section below.
- **Passwordless `sudo`** for the SSH user (default on Amazon Linux for `ec2-user`).
- Local tooling: `bash`, `ssh`, `scp`, `wget` (installs pull RPMs on the host).
- Any Splunk apps (`*.spl` / `*.tgz`) or licenses (`*.lic` / `*.License`) you
  want to install placed in your local `~/Downloads` directory.

## 2. Configure the AWS SSH key
The script authenticates to EC2 with a private key. By default it looks for
`~/.ssh/lab_key.pem`; override with `--key /path/to/key.pem`.

### Option A — use an existing EC2 key pair
1. In the **AWS Console → EC2 → Key Pairs**, download (or locate) the `.pem`
   file for the key pair your instance was launched with.
2. Move it into `~/.ssh` and lock down permissions (SSH refuses loose perms):
   ```bash
   mv ~/Downloads/my-key.pem ~/.ssh/lab_key.pem
   chmod 600 ~/.ssh/lab_key.pem
   ```
3. Confirm you can reach the box:
   ```bash
   ssh -i ~/.ssh/lab_key.pem ec2-user@<EC2_PUBLIC_IP> 'echo ok'
   ```

### Option B — create a new key and add it to the instance
1. Generate a key locally:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/lab_key.pem -N ""
   chmod 600 ~/.ssh/lab_key.pem
   ```
2. Add the public key to the instance (via existing access or the EC2 serial /
   user-data console):
   ```bash
   cat ~/.ssh/lab_key.pem.pub   # copy this line
   # on the instance:
   echo '<paste-public-key>' >> ~/.ssh/authorized_keys
   chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
   ```

### Optional — an SSH config alias
Handy for manual access (the script itself always uses `-i <key>` so an alias is
not required):
```
# ~/.ssh/config
Host my-splunk
  HostName <EC2_PUBLIC_IP>
  User ec2-user
  IdentityFile ~/.ssh/lab_key.pem
```

> Security group: ensure inbound **TCP 22** (SSH) is open from your IP. To reach
> Splunk Web afterwards, also open **TCP 8000**.

## 3. Usage

### Interactive (guided menu)
```bash
./splunk_provisioner.sh --host <EC2_PUBLIC_IP>
# or fully interactive (it will prompt for the IP):
./splunk_provisioner.sh
```
The menu is **adaptive**: it first prints a status panel (Splunk / ITSI / Java /
service manager / disk), then shows only the actions that make sense for that
host (e.g. *Install Splunk* on a bare box; *Restart / Upgrade / Install apps /
Install license* on a provisioned one).

If your key is not the default, add `--key ~/.ssh/your-key.pem`.

### Non-interactive (automation / AI agents)
Every capability is a flag-driven `--action`. Add `--yes` to auto-confirm.

```bash
# Read-only status
./splunk_provisioner.sh --host <IP> --action detect

# Fresh install (see catalog indexes below; 0 = newest)
./splunk_provisioner.sh --host <IP> --action install-splunk --version-index 0 --admin-pass 'PW' --yes

# Install Java (Amazon Corretto 11)
./splunk_provisioner.sh --host <IP> --action install-java --yes

# Install an app/add-on (Splunk stays up; restart loads it). --no-restart to batch
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/app.spl --yes

# Install a license (placed in etc/licenses/enterprise/, applied on restart)
./splunk_provisioner.sh --host <IP> --action install-license --license "~/Downloads/my.License" --yes

# Safe restart (stop + verify + start + health check)
./splunk_provisioner.sh --host <IP> --action restart

# Upgrade Splunk core (rpm -U, with safe stop and post-upgrade migration)
./splunk_provisioner.sh --host <IP> --action upgrade-splunk --version-index 0 --yes

# Upgrade ITSI (stop-based overlay of the ITSI package)
./splunk_provisioner.sh --host <IP> --action upgrade-itsi --package ~/Downloads/splunk-it-service-intelligence_502.spl --yes

# Upgrade any app (stop-based)
./splunk_provisioner.sh --host <IP> --action upgrade-app --package ~/Downloads/app.spl --yes
```

### Actions reference
| Action | Splunk stopped? | Notes |
|--------|:---------------:|-------|
| `detect` | no | Read-only status panel |
| `install-splunk` | n/a | Fresh RPM install + admin seed + systemd boot-start |
| `install-app` | no | Interactive multi-select over `~/Downloads` or `--package`; restart loads |
| `install-license` | no | Interactive multi-select or `--license`; applied on restart |
| `install-java` | no | Amazon Corretto 11 |
| `restart` | yes | Graceful stop + verify + start + health check |
| `upgrade-app` | **yes** | Stop → overlay package → start |
| `upgrade-itsi` | **yes** | Same engine, ITSI-only package filter |
| `upgrade-splunk` | **yes** | `rpm -U` core upgrade + migration |

### Options
```
--host IP            Target EC2 public IP (skips the interactive prompt)
--action ACTION      One of the actions above
--version-index N    Splunk release to install/upgrade (see catalog)
--rpm-url URL        Install/upgrade from an arbitrary Splunk RPM URL
--package PATH       Local .spl/.tgz for install-app / upgrade-app / upgrade-itsi
--license PATH       Local license file for install-license
--admin-user U       Splunk admin username (default: admin)
--admin-pass P       Splunk admin password (required for non-interactive install)
--key PATH           SSH private key (default: ~/.ssh/lab_key.pem)
--no-restart         Skip the restart after install-app / install-license (batch)
--json               detect only: emit machine-readable JSON instead of the panel
--yes, -y            Auto-confirm prompts (non-interactive)
```

### Machine-readable status (`--json`) — for automation / AI agents
`detect --json` prints the host state as a JSON object (instead of the panel) so
an agent or script can branch on it without scraping text:
```bash
./splunk_provisioner.sh --host <IP> --action detect --json | jq .
```
```json
{
  "host": "<IP>",
  "splunk_installed": true,
  "splunk_version": "10.4.3",
  "itsi_version": "5.0.2",
  "java_version": "11.0.28 2025-07-15 LTS",
  "service_method": "binary",
  "service_name": "/opt/splunk/bin/splunk",
  "status": "running",
  "disk_free": "69G",
  "disk_size": "80G",
  "disk_used_pct": 14
}
```
Missing values are `null` (e.g. `itsi_version` when ITSI is absent). Combined
with the script's exit codes, an agent can decide the next action, guard disk
space before upgrades, and verify version/status after an action.

### Splunk version catalog (for `--version-index`)
```
0=10.4.3  1=10.4.1  2=10.2.7  3=10.2.0  4=10.0.2  5=10.0.1  6=10.0.0
7=9.4.3   8=9.4.2   9=9.4.1  10=9.3.6  11=9.2.8  12=9.1.10
```

## 4. Installing ITSI (fresh) — recommended order
ITSI is deployed as an app. Install its prerequisites first, then ITSI, then one
restart:
```bash
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/python-for-scientific-computing-for-linux-64-bit_420.spl --no-restart --yes
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/splunk-ai-toolkit_610.tgz --no-restart --yes
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/splunk-it-service-intelligence_502.spl --no-restart --yes
./splunk_provisioner.sh --host <IP> --action restart
```
Then finish ITSI's guided setup at `http://<IP>:8000`.

## Requirements recap
- SSH access with a private key (default `~/.ssh/lab_key.pem`, override `--key`).
- Passwordless `sudo` for the SSH user on the instance.

## Security
Keys, licenses, and Splunk packages are git-ignored — never commit `*.pem`,
`*.lic`, `*.rpm`, or `*.spl`.
