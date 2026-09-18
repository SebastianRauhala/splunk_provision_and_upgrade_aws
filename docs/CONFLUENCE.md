# Splunk Provisioner — Automated Splunk & ITSI Provisioning and Upgrades on AWS EC2

> **Owner:** Sebastian Rauhala · serauhal@cisco.com
> **Repo:** https://github.com/SebastianRauhala/aws_provision_and_upgrade
> **Version:** v1.0.0 (GA)
> **Applies to:** Amazon Linux 2023 EC2 instances

---

## 1. What it is

`splunk_provisioner.sh` is a single Bash script that provisions, manages, and
safely upgrades **Splunk Enterprise** (and **ITSI**) on AWS EC2 over SSH.

It works two ways from the same script:

- **Interactive** — a guided, status-aware menu for humans.
- **Non-interactive** — flag-driven commands with `--yes` for scripting, CI, and
  **AI agents** (including a `--json` status mode).

> ℹ️ **Why it exists:** stand up a Splunk/ITSI lab (or upgrade one) in minutes,
> reproducibly, without hand-running a dozen SSH commands — and let automation do
> it safely.

---

## 2. Key capabilities

| Capability | Detail |
|---|---|
| Fresh Splunk install | Downloads the chosen RPM on the host, seeds the admin user, enables **systemd boot-start** |
| Version catalog | 13 Splunk releases (9.1.x → 10.4.x) selectable by index, or any RPM URL |
| App / add-on install | Any local `.spl` / `.tgz` — interactive multi-select or single `--package` |
| License install | Any local `.lic` / `.License` — placed in `etc/licenses/enterprise/` |
| Java | Installs Amazon Corretto 11 (for apps that need it, e.g. DB Connect) |
| Safe restart | Graceful stop → verify splunkd is down → start → health check |
| Splunk upgrade | `rpm -U` with safe stop and post-upgrade migration |
| ITSI / app upgrade | Stop-based overlay of the app package while splunkd is down |
| Versatile service control | Auto-detects **systemd**, **init.d**, or raw **binary** management |
| Machine-readable status | `detect --json` for automation / AI agents |

---

## 3. How it works (architecture)

```
  Your laptop / CI / agent                     EC2 instance (Amazon Linux 2023)
  ┌───────────────────────┐   SSH (key)   ┌──────────────────────────────────┐
  │ splunk_provisioner.sh │ ───────────►  │  ec2-user  (passwordless sudo)   │
  │  - actions & flags    │   scp files   │   └─ /opt/splunk  (splunk:splunk)│
  │  - status panel/JSON  │ ◄───────────  │      systemd | init.d | binary   │
  └───────────────────────┘   results     └──────────────────────────────────┘
```

- **Single round-trip status gather** — one SSH call collects Splunk version,
  ITSI version, Java, the service-management method, run status, and disk. This
  drives both the panel and the adaptive menu.
- **Versatile service control** — before any stop/start the script detects how
  Splunk is managed on that host and uses the right mechanism:
  - a real **systemd** unit (`Splunkd.service`), or
  - **init.d** (`/etc/init.d/splunk`, incl. systemd-generated shims), or
  - the raw **binary** (`/opt/splunk/bin/splunk`, run as the `splunk` user).
- **Safe upgrades** — upgrades stop splunkd and **poll `pgrep splunkd`** to
  confirm it is truly down before touching any files, then start and health-check.
- **Runs Splunk as the `splunk` user** — Splunk 10.x refuses to run as root; all
  start/stop/status calls use `sudo -u splunk`.

---

## 4. Prerequisites

- A running **Amazon Linux 2023** EC2 instance and its **public IP**.
- The EC2 SSH **private key** (`.pem`).
- **Passwordless `sudo`** for the SSH user (default for `ec2-user`).
- Local tools: `bash`, `ssh`, `scp`, `wget`.
- Any Splunk apps (`*.spl` / `*.tgz`) or licenses (`*.lic` / `*.License`) placed
  in your local `~/Downloads`.
- Security group: inbound **TCP 22** (SSH) from your IP; **TCP 8000** to reach
  Splunk Web.

---

## 5. Configure the AWS SSH key

The script authenticates with a private key. Default path: `~/.ssh/lab_key.pem`
(override with `--key /path/to/key.pem`).

**Option A — existing EC2 key pair**
```bash
mv ~/Downloads/my-key.pem ~/.ssh/lab_key.pem
chmod 600 ~/.ssh/lab_key.pem
ssh -i ~/.ssh/lab_key.pem ec2-user@<EC2_PUBLIC_IP> 'echo ok'
```

**Option B — new key added to the instance**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/lab_key.pem -N ""
chmod 600 ~/.ssh/lab_key.pem
cat ~/.ssh/lab_key.pem.pub        # add this to the instance's ~/.ssh/authorized_keys
```

> ⚠️ SSH refuses keys with loose permissions — always `chmod 600` the `.pem`.

---

## 6. Get the tool

```bash
git clone git@github.com:SebastianRauhala/aws_provision_and_upgrade.git
cd aws_provision_and_upgrade
chmod +x splunk_provisioner.sh
```

---

## 7. Usage

### Interactive (guided menu)
```bash
./splunk_provisioner.sh --host <EC2_PUBLIC_IP>
```
The menu prints a status panel, then shows only the actions valid for that host
(e.g. *Install Splunk* on a bare box; *Restart / Upgrade / Install apps / Install
license* on a provisioned one). Add `--key ~/.ssh/your-key.pem` if not using the
default key.

### Non-interactive (automation / AI agents)
```bash
# Read-only status
./splunk_provisioner.sh --host <IP> --action detect

# Fresh install (version-index 0 = newest; see catalog)
./splunk_provisioner.sh --host <IP> --action install-splunk --version-index 0 --admin-pass 'PW' --yes

# Java
./splunk_provisioner.sh --host <IP> --action install-java --yes

# Install an app (Splunk stays up; restart loads it). --no-restart to batch
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/app.spl --yes

# Install a license (applied on restart)
./splunk_provisioner.sh --host <IP> --action install-license --license "~/Downloads/my.License" --yes

# Safe restart
./splunk_provisioner.sh --host <IP> --action restart

# Upgrade Splunk core (rpm -U + migration)
./splunk_provisioner.sh --host <IP> --action upgrade-splunk --version-index 0 --yes

# Upgrade ITSI (stop-based overlay)
./splunk_provisioner.sh --host <IP> --action upgrade-itsi --package ~/Downloads/splunk-it-service-intelligence_502.spl --yes
```

### Actions reference

| Action | Splunk stopped? | Notes |
|--------|:---:|-------|
| `detect` | no | Status panel, or JSON with `--json` |
| `install-splunk` | n/a | Fresh RPM install + admin seed + systemd boot-start |
| `install-app` | no | Multi-select over `~/Downloads` or `--package`; restart loads |
| `install-license` | no | Multi-select or `--license`; applied on restart |
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
--json               detect only: emit machine-readable JSON
--yes, -y            Auto-confirm prompts (non-interactive)
```

### Splunk version catalog (`--version-index`)
```
0=10.4.3  1=10.4.1  2=10.2.7  3=10.2.0  4=10.0.2  5=10.0.1  6=10.0.0
7=9.4.3   8=9.4.2   9=9.4.1  10=9.3.6  11=9.2.8  12=9.1.10
```

---

## 8. Install ITSI (fresh) — recommended order

ITSI is deployed as an app. Install prerequisites first, then ITSI, then one
restart:

```bash
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/python-for-scientific-computing-for-linux-64-bit_420.spl --no-restart --yes
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/splunk-ai-toolkit_610.tgz --no-restart --yes
./splunk_provisioner.sh --host <IP> --action install-app --package ~/Downloads/splunk-it-service-intelligence_502.spl --no-restart --yes
./splunk_provisioner.sh --host <IP> --action restart
```
Then finish ITSI's guided setup at `http://<IP>:8000`.

> ℹ️ The **Splunk AI Toolkit** (formerly MLTK) and **Python for Scientific
> Computing (PSC)** are ITSI prerequisites for ML-based features.

---

## 9. Machine-readable status for AI agents (`--json`)

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
Missing values are `null`. Combined with the script's exit codes, an agent can
decide the next action, guard disk space before an upgrade, and verify
version/status afterwards — no text scraping required.

---

## 10. Safety notes

- Upgrades **stop splunkd and verify** it is down before changing files.
- KV Store backup is **not** performed (lab-oriented). Add one before upgrades in
  production.
- Splunk upgrades are effectively forward-only without a config backup.
- Watch disk headroom — the pre-flight warns below ~3 GB (5 GB for ITSI).

---

## 11. Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `Permission denied (publickey)` | Wrong/again missing key — pass `--key`, `chmod 600` the `.pem` |
| `splunkd still running after stop` | Another process holds it; re-run, check `pgrep splunkd` |
| Non-interactive install refuses | Provide `--admin-pass` (required with `--yes`) |
| App copied but not loaded | Apps load on **restart** — run `--action restart` |
| ITSI shows `UNCONFIGURED` | Normal on fresh install; finish setup in the UI |
| Insufficient disk warning | Free space on `/opt` or resize the volume |

---

## 12. Support

Questions / issues: **Sebastian Rauhala — serauhal@cisco.com**, or open an issue
on the GitHub repo.
