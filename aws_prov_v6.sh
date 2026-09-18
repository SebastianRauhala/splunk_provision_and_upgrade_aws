#!/bin/bash
#
# Splunk Provisioning & Upgrade Script for AWS EC2  (v6)
# Author: Sebastian Rauhala  |  v6 refactor: adds versatile service control
#         (init.d + systemd + raw binary) and safe non-interactive upgrades.
#
# Backward compatible: run with NO arguments for the original interactive menu.
# Non-interactive examples (AI-agent / automation friendly):
#   ./aws_prov_v6.sh --host 3.90.172.45 --action detect
#   ./aws_prov_v6.sh --host 3.90.172.45 --action restart
#   ./aws_prov_v6.sh --host 3.90.172.45 --action upgrade-splunk --version-index 4 --admin-pass 'PW' --yes
#   ./aws_prov_v6.sh --host 3.90.172.45 --action upgrade-splunk --rpm-url <url> --yes
#   ./aws_prov_v6.sh --host 3.90.172.45 --action upgrade-itsi --package ~/Downloads/itsi.spl --yes
#
set -o pipefail

# --- Configuration ---
USER="ec2-user"
DEF_KEY="${DEF_KEY:-$HOME/.ssh/lab_key.pem}"
SPLUNK_DOWNLOADS_PATH="${SPLUNK_DOWNLOADS_PATH:-$HOME/Downloads/}"
SPLUNK_HOME="/opt/splunk"
JAVA_PACKAGE="java-11-amazon-corretto-devel"

SSH_OPTS=(-i "$DEF_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)

# --- Splunk Enterprise release catalog ---
SPLUNK_VERSIONS=( "Splunk Enterprise 10.2.0" "Splunk Enterprise 10.0.2" "Splunk Enterprise 10.0.1" "Splunk Enterprise 10.0.0" "Splunk Enterprise 9.4.3" "Splunk Enterprise 9.4.2" "Splunk Enterprise 9.4.1" "Splunk Enterprise 9.3.6" "Splunk Enterprise 9.2.8" "Splunk Enterprise 9.1.10" )
SPLUNK_FILENAMES=( "splunk-10.2.0-d749cb17ea65.x86_64.rpm" "splunk-10.0.2-e2d18b4767e9.x86_64.rpm" "splunk-10.0.1-c486717c322b.x86_64.rpm" "splunk-10.0.0-e8eb0c4654f8.x86_64.rpm" "splunk-9.4.3-237ebbd22314.x86_64.rpm" "splunk-9.4.2-e9664af3d956.x86_64.rpm" "splunk-9.4.1-e3bdab203ac8.x86_64.rpm" "splunk-9.3.6-8c495c6a1f7d.x86_64.rpm" "splunk-9.2.8-811db24f0af2.x86_64.rpm" "splunk-9.1.10-a6ea9b30f817.x86_64.rpm" )
SPLUNK_URLS=( "https://download.splunk.com/products/splunk/releases/10.2.0/linux/splunk-10.2.0-d749cb17ea65.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.2/linux/splunk-10.0.2-e2d18b4767e9.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.1/linux/splunk-10.0.1-c486717c322b.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.0/linux/splunk-10.0.0-e8eb0c4654f8.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.3/linux/splunk-9.4.3-237ebbd22314.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.2/linux/splunk-9.4.2-e9664af3d956.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.1/linux/splunk-9.4.1-e3bdab203ac8.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.3.6/linux/splunk-9.3.6-8c495c6a1f7d.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.2.8/linux/splunk-9.2.8-811db24f0af2.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.1.10/linux/splunk-9.1.10-a6ea9b30f817.x86_64.rpm" )

# --- Globals populated at runtime ---
HOST=""; ACTION=""; ASSUME_YES=0
SPLUNK_ADMIN_USER="admin"; SPLUNK_ADMIN_PASS=""
VERSION_INDEX=""; RPM_URL=""; ITSI_PACKAGE=""

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

confirm() {
  # $1 = prompt. Auto-yes in non-interactive mode.
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ans; read -p "$1 [y/n] " ans; [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# --- SSH helpers -----------------------------------------------------------
rexec() { ssh "${SSH_OPTS[@]}" "$USER@$HOST" "$@"; }
rcopy() { scp "${SSH_OPTS[@]}" "$@"; }

require_host() { [ -n "$HOST" ] || die "No target host set (use --host or interactive prompt)."; }

# --- Versatile service control --------------------------------------------
# Returns "METHOD|NAME": systemd|<unit> , initd|/etc/init.d/splunk , binary|<path>
detect_service_remote() {
  rexec bash -s <<'REMOTE'
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
for u in Splunkd splunkd splunk; do
  state=$(systemctl list-unit-files --no-legend "${u}.service" 2>/dev/null | awk '{print $2}')
  case "$state" in
    enabled|disabled|static|indirect|enabled-runtime) echo "systemd|${u}.service"; exit 0 ;;
  esac
done
if sudo test -e /etc/init.d/splunk; then echo "initd|/etc/init.d/splunk"; exit 0; fi
echo "binary|${SPLUNK_HOME}/bin/splunk"
REMOTE
}

splunk_installed() { rexec "sudo test -x ${SPLUNK_HOME}/bin/splunk"; }

splunk_version_remote() {
  rexec "sudo ${SPLUNK_HOME}/bin/splunk version 2>/dev/null | awk '{print \$2}'"
}

itsi_version_remote() {
  rexec "sudo awk -F= '/^version[[:space:]]*=/ {gsub(/ /,\"\",\$2); print \$2; exit}' ${SPLUNK_HOME}/etc/apps/itsi/default/app.conf 2>/dev/null"
}

# Stop Splunk gracefully via the detected manager, then VERIFY no splunkd remains.
splunk_stop() {
  local method name; IFS='|' read -r method name <<<"$(detect_service_remote)"
  log "Stopping Splunk via: $method ($name)"
  case "$method" in
    systemd) rexec "sudo systemctl stop $name" ;;
    *)       rexec "sudo ${SPLUNK_HOME}/bin/splunk stop" ;;
  esac
  # Verify - poll for up to ~60s that no splunkd process survives.
  local i
  for i in $(seq 1 30); do
    if ! rexec "pgrep -x splunkd >/dev/null 2>&1"; then
      log "Confirmed: splunkd stopped."; return 0
    fi
    sleep 2
  done
  err "splunkd still running after stop attempt."; return 1
}

# Start Splunk. On first start after an upgrade this performs config migration;
# we pass accept/answer flags for init.d/binary. systemd path handles this itself.
splunk_start() {
  local method name; IFS='|' read -r method name <<<"$(detect_service_remote)"
  log "Starting Splunk via: $method ($name)"
  case "$method" in
    systemd) rexec "sudo systemctl start $name" ;;
    *)       rexec "sudo ${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt" ;;
  esac
}

# Wait until management port 8089 answers (splunkd fully up).
wait_for_splunkd() {
  local i
  for i in $(seq 1 60); do
    if rexec "sudo ${SPLUNK_HOME}/bin/splunk status 2>/dev/null | grep -qi 'is running'"; then
      log "splunkd is running."; return 0
    fi
    sleep 5
  done
  err "splunkd did not report running within timeout."; return 1
}

restart_splunk() {
  require_host
  splunk_stop && splunk_start && wait_for_splunkd
}

# --- Pre-flight for upgrades ----------------------------------------------
# Ensure enough free disk for the download + unpacked install.
preflight_disk() {
  local need_mb="${1:-3000}"
  local avail_mb
  avail_mb=$(rexec "df -Pm /opt | awk 'NR==2{print \$4}'")
  log "Free space on /opt: ${avail_mb} MB (need >= ${need_mb} MB)"
  if [ "${avail_mb:-0}" -lt "$need_mb" ]; then
    err "Insufficient disk space on /opt (${avail_mb} MB < ${need_mb} MB)."
    confirm "Continue anyway (NOT recommended)?" || return 1
  fi
  return 0
}

# --- Upgrade: Splunk Enterprise -------------------------------------------
upgrade_splunk() {
  require_host
  if ! splunk_installed; then
    die "Splunk is not installed on $HOST. Use install action instead."
  fi
  local cur; cur=$(splunk_version_remote)
  log "Current Splunk version: ${cur:-unknown}"

  # Resolve target RPM (filename + url) from --rpm-url or --version-index.
  local fn url
  if [ -n "$RPM_URL" ]; then
    url="$RPM_URL"; fn="${RPM_URL##*/}"
  elif [ -n "$VERSION_INDEX" ]; then
    [[ "$VERSION_INDEX" =~ ^[0-9]+$ ]] && [ "$VERSION_INDEX" -lt "${#SPLUNK_URLS[@]}" ] \
      || die "Invalid --version-index."
    url="${SPLUNK_URLS[$VERSION_INDEX]}"; fn="${SPLUNK_FILENAMES[$VERSION_INDEX]}"
  else
    # interactive pick
    local i; for i in "${!SPLUNK_VERSIONS[@]}"; do echo "  $i) ${SPLUNK_VERSIONS[$i]}"; done
    read -p "Select target version: " VERSION_INDEX
    [[ "$VERSION_INDEX" =~ ^[0-9]+$ ]] && [ "$VERSION_INDEX" -lt "${#SPLUNK_URLS[@]}" ] \
      || die "Invalid selection."
    url="${SPLUNK_URLS[$VERSION_INDEX]}"; fn="${SPLUNK_FILENAMES[$VERSION_INDEX]}"
  fi
  log "Target package: $fn"

  local itsi; itsi=$(itsi_version_remote)
  [ -n "$itsi" ] && log "ITSI detected (v$itsi) - it will move with the core upgrade."

  confirm "Proceed to upgrade Splunk on $HOST from ${cur:-?} using $fn?" || { log "Aborted."; return 1; }

  preflight_disk 3000 || return 1

  log "1/6 Downloading RPM..."
  rexec "wget -q -O ~/$fn '$url'" || die "Download failed."
  log "2/6 Stopping Splunk (safe stop + verify)..."
  splunk_stop || die "Could not stop Splunk cleanly; aborting before upgrade."
  log "3/6 Upgrading package (rpm -U)..."
  rexec "sudo rpm -U ~/$fn" || die "rpm -U failed."
  log "4/6 Restoring ownership..."
  rexec "sudo chown -R splunk:splunk ${SPLUNK_HOME}"
  log "5/6 Starting Splunk (runs migration)..."
  splunk_start || die "Start failed after upgrade."
  wait_for_splunkd || die "splunkd did not come up."
  log "6/6 Verifying..."
  local newv; newv=$(splunk_version_remote)
  log "Splunk version now: ${newv:-unknown}"
  [ -n "$itsi" ] && log "ITSI version now: $(itsi_version_remote)"
  log "Splunk upgrade complete."
}

# --- Upgrade: ITSI (app upgrade over an existing install) ------------------
# ITSI is upgraded by laying the new app package over etc/apps while splunkd is
# stopped, then starting (first start runs app/KV migration). KV backup skipped
# per lab scope.
upgrade_itsi() {
  require_host
  splunk_installed || die "Splunk not installed on $HOST."
  local cur; cur=$(itsi_version_remote)
  [ -n "$cur" ] || die "ITSI does not appear to be installed (no itsi/default/app.conf)."
  log "Current ITSI version: $cur"

  local pkg="$ITSI_PACKAGE"
  if [ -z "$pkg" ]; then
    # interactive discovery in Downloads
    local found=(); while IFS= read -r -d $'\0' f; do found+=("$f"); done \
      < <(find "$SPLUNK_DOWNLOADS_PATH" -maxdepth 1 -iname "*itsi*.spl" -print0 | sort -z)
    [ ${#found[@]} -gt 0 ] || die "No ITSI .spl package found in $SPLUNK_DOWNLOADS_PATH (use --package)."
    local i; for i in "${!found[@]}"; do echo "  $i) ${found[$i]##*/}"; done
    read -p "Select ITSI package: " i
    [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -lt "${#found[@]}" ] || die "Invalid selection."
    pkg="${found[$i]}"
  fi
  [ -f "$pkg" ] || die "Package not found: $pkg"
  local base="${pkg##*/}"
  log "Target ITSI package: $base"

  confirm "Upgrade ITSI on $HOST from v$cur using $base? (splunkd will be stopped)" \
    || { log "Aborted."; return 1; }

  preflight_disk 5000 || return 1

  log "1/6 Copying package..."
  rcopy "$pkg" "$USER@$HOST:/home/$USER/" || die "scp failed."
  log "2/6 Stopping Splunk (safe stop + verify)..."
  splunk_stop || die "Could not stop Splunk cleanly; aborting."
  log "3/6 Extracting app over etc/apps..."
  rexec "sudo tar -xzf /home/$USER/$(printf %q "$base") -C ${SPLUNK_HOME}/etc/apps/" \
    || die "Extraction failed."
  log "4/6 Restoring ownership..."
  rexec "sudo chown -R splunk:splunk ${SPLUNK_HOME}/etc/apps/"
  log "5/6 Starting Splunk (runs ITSI migration)..."
  splunk_start || die "Start failed after ITSI upgrade."
  wait_for_splunkd || die "splunkd did not come up."
  log "6/6 Verifying..."
  log "ITSI version now: $(itsi_version_remote)"
  log "ITSI upgrade complete. Allow a few minutes for KV/migration jobs to settle."
}

# --- Detect action (read-only summary) ------------------------------------
action_detect() {
  require_host
  log "Host: $HOST"
  if splunk_installed; then
    log "Splunk: installed, version $(splunk_version_remote)"
  else
    log "Splunk: NOT installed"; return 0
  fi
  local itsi; itsi=$(itsi_version_remote); [ -n "$itsi" ] && log "ITSI: v$itsi"
  log "Service management: $(detect_service_remote)"
  rexec "sudo ${SPLUNK_HOME}/bin/splunk status 2>/dev/null | head -1"
  rexec "df -h /opt | awk 'NR==2{print \"Disk /opt: \"\$4\" free of \"\$2\" (\"\$5\" used)\"}'"
}

# --- Arg parsing -----------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)          HOST="$2"; shift 2 ;;
      --action)        ACTION="$2"; shift 2 ;;
      --version-index) VERSION_INDEX="$2"; shift 2 ;;
      --rpm-url)       RPM_URL="$2"; shift 2 ;;
      --package)       ITSI_PACKAGE="$2"; shift 2 ;;
      --admin-user)    SPLUNK_ADMIN_USER="$2"; shift 2 ;;
      --admin-pass)    SPLUNK_ADMIN_PASS="$2"; shift 2 ;;
      --key)           DEF_KEY="$2"; SSH_OPTS[1]="$2"; shift 2 ;;
      --yes|-y)        ASSUME_YES=1; shift ;;
      -h|--help)       ACTION="help"; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

usage() {
  cat <<USG
Usage: $0 [--host IP] [--action ACTION] [options]
Actions: detect | restart | upgrade-splunk | upgrade-itsi
Options: --version-index N | --rpm-url URL | --package PATH
         --admin-user U | --admin-pass P | --key PATH | --yes
Run with no arguments for the interactive menu.
USG
}

# --- Dispatch --------------------------------------------------------------
main() {
  parse_args "$@"
  if [ -n "$ACTION" ]; then
    case "$ACTION" in
      help)            usage ;;
      detect)          action_detect ;;
      restart)         restart_splunk ;;
      upgrade-splunk)  upgrade_splunk ;;
      upgrade-itsi)    upgrade_itsi ;;
      *) die "Unknown action: $ACTION" ;;
    esac
    exit $?
  fi
  # No action -> fall back to interactive (prompt for host + restart/upgrade menu)
  echo "Interactive mode. Enter target EC2 public IP:"; read HOST
  require_host
  action_detect
  echo ""
  echo "Choose: (r) restart  (u) upgrade Splunk  (i) upgrade ITSI  (q) quit"
  read -p "> " c
  case "$c" in
    r|R) restart_splunk ;;
    u|U) upgrade_splunk ;;
    i|I) upgrade_itsi ;;
    *) echo "Bye." ;;
  esac
}

main "$@"
