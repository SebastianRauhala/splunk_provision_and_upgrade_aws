#!/bin/bash
#
# Splunk Provisioning & Upgrade Script for AWS EC2
# Author: Sebastian Rauhala
#
# Master script. Version history is tracked in git (see: git log --follow).
# Capabilities: detect | restart | install-splunk | upgrade-splunk |
#               upgrade-itsi | install-java
#   - Versatile service control (init.d + systemd + raw binary), safe upgrades
#   - Single round-trip status gather + colorized, adaptive looping menu
#   - Fresh install flow (RPM + admin seed + systemd boot-start)
#   - Java detect/install (java-11-amazon-corretto-devel)
#
# Run with NO arguments for the interactive menu.
# Non-interactive examples (AI-agent / automation friendly):
#   ./splunk_provisioner.sh --host 3.90.172.45 --action detect
#   ./splunk_provisioner.sh --host 3.90.172.45 --action restart
#   ./splunk_provisioner.sh --host 3.90.172.45 --action install-splunk --version-index 7 --admin-pass 'PW' --yes
#   ./splunk_provisioner.sh --host 3.90.172.45 --action upgrade-splunk --version-index 0 --yes
#   ./splunk_provisioner.sh --host 3.90.172.45 --action upgrade-itsi --package ~/Downloads/itsi.spl --yes
#   ./splunk_provisioner.sh --host 3.90.172.45 --action install-java --yes
#
set -o pipefail

# --- Configuration ---
USER="ec2-user"
DEF_KEY="${DEF_KEY:-$HOME/.ssh/lab_key.pem}"
SPLUNK_DOWNLOADS_PATH="${SPLUNK_DOWNLOADS_PATH:-$HOME/Downloads/}"
SPLUNK_HOME="/opt/splunk"
JAVA_PACKAGE="java-11-amazon-corretto-devel"

# LogLevel=ERROR suppresses the "Permanently added ..." + post-quantum warnings
# that otherwise print on every single SSH connection.
SSH_OPTS=(-i "$DEF_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=15 -o LogLevel=ERROR)

# --- Splunk Enterprise release catalog ---
SPLUNK_VERSIONS=( "Splunk Enterprise 10.4.3" "Splunk Enterprise 10.4.1" "Splunk Enterprise 10.2.7" "Splunk Enterprise 10.2.0" "Splunk Enterprise 10.0.2" "Splunk Enterprise 10.0.1" "Splunk Enterprise 10.0.0" "Splunk Enterprise 9.4.3" "Splunk Enterprise 9.4.2" "Splunk Enterprise 9.4.1" "Splunk Enterprise 9.3.6" "Splunk Enterprise 9.2.8" "Splunk Enterprise 9.1.10" )
SPLUNK_FILENAMES=( "splunk-10.4.3-4174a2deda5d.x86_64.rpm" "splunk-10.4.1-5a009d941268.x86_64.rpm" "splunk-10.2.7-c0bff5b0fac3.x86_64.rpm" "splunk-10.2.0-d749cb17ea65.x86_64.rpm" "splunk-10.0.2-e2d18b4767e9.x86_64.rpm" "splunk-10.0.1-c486717c322b.x86_64.rpm" "splunk-10.0.0-e8eb0c4654f8.x86_64.rpm" "splunk-9.4.3-237ebbd22314.x86_64.rpm" "splunk-9.4.2-e9664af3d956.x86_64.rpm" "splunk-9.4.1-e3bdab203ac8.x86_64.rpm" "splunk-9.3.6-8c495c6a1f7d.x86_64.rpm" "splunk-9.2.8-811db24f0af2.x86_64.rpm" "splunk-9.1.10-a6ea9b30f817.x86_64.rpm" )
SPLUNK_URLS=( "https://download.splunk.com/products/splunk/releases/10.4.3/linux/splunk-10.4.3-4174a2deda5d.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.4.1/linux/splunk-10.4.1-5a009d941268.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.2.7/linux/splunk-10.2.7-c0bff5b0fac3.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.2.0/linux/splunk-10.2.0-d749cb17ea65.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.2/linux/splunk-10.0.2-e2d18b4767e9.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.1/linux/splunk-10.0.1-c486717c322b.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/10.0.0/linux/splunk-10.0.0-e8eb0c4654f8.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.3/linux/splunk-9.4.3-237ebbd22314.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.2/linux/splunk-9.4.2-e9664af3d956.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.4.1/linux/splunk-9.4.1-e3bdab203ac8.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.3.6/linux/splunk-9.3.6-8c495c6a1f7d.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.2.8/linux/splunk-9.2.8-811db24f0af2.x86_64.rpm" "https://download.splunk.com/products/splunk/releases/9.1.10/linux/splunk-9.1.10-a6ea9b30f817.x86_64.rpm" )

# --- Globals populated at runtime ---
HOST=""; ACTION=""; ASSUME_YES=0
SPLUNK_ADMIN_USER="admin"; SPLUNK_ADMIN_PASS=""
VERSION_INDEX=""; RPM_URL=""; ITSI_PACKAGE=""
NO_RESTART=0

# Detection cache (filled by gather_status)
ST_SPLUNK_INSTALLED=0; ST_SPLUNK_VERSION=""; ST_ITSI_VERSION=""
ST_JAVA_VERSION=""; ST_SERVICE=""; ST_STATUS=""; ST_DISK=""

# --- Colors (disabled when not a TTY or NO_COLOR set) ----------------------
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_CYN=""
fi

log()  { echo "${C_DIM}[$(date +%H:%M:%S)]${C_RESET} $*"; }
ok()   { echo "${C_GRN}[$(date +%H:%M:%S)] OK:${C_RESET} $*"; }
warn() { echo "${C_YLW}[$(date +%H:%M:%S)] WARN:${C_RESET} $*"; }
err()  { echo "${C_RED}[$(date +%H:%M:%S)] ERROR:${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

confirm() {
  # $1 = prompt. Auto-yes in non-interactive mode.
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local ans; read -p "$(printf '%s%s%s [y/n] ' "$C_YLW" "$1" "$C_RESET")" ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# --- SSH helpers -----------------------------------------------------------
rexec() { ssh "${SSH_OPTS[@]}" "$USER@$HOST" "$@"; }
rcopy() { scp "${SSH_OPTS[@]}" "$@"; }

require_host() { [ -n "$HOST" ] || die "No target host set (use --host or interactive prompt)."; }

# --- Single round-trip status gather --------------------------------------
# Populates all ST_* variables in one SSH connection.
gather_status() {
  require_host
  local raw script
  # NOTE: build the remote script via `read` (not a heredoc inside $(...)),
  # because bash 3.2 (macOS default) mis-parses heredocs nested in command
  # substitution. `read -r -d ''` returns non-zero at EOF; that is expected.
  IFS='' read -r -d '' script <<'REMOTE'
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
if sudo test -x "$SPLUNK_HOME/bin/splunk"; then
  echo "SPLUNK_INSTALLED=1"
  echo "SPLUNK_VERSION=$(sudo -u splunk "$SPLUNK_HOME/bin/splunk" version 2>/dev/null | awk '{print $2}')"
  itsi=$(sudo awk -F= '/^version[[:space:]]*=/{gsub(/ /,"",$2);print $2;exit}' "$SPLUNK_HOME/etc/apps/itsi/default/app.conf" 2>/dev/null)
  echo "ITSI_VERSION=$itsi"
  if sudo -u splunk "$SPLUNK_HOME/bin/splunk" status 2>/dev/null | grep -qi 'is running'; then
    echo "STATUS=running"; else echo "STATUS=stopped"; fi
else
  echo "SPLUNK_INSTALLED=0"
fi
if command -v java >/dev/null 2>&1; then
  echo "JAVA_VERSION=$(java -version 2>&1 | head -1 | sed 's/.*version //; s/\"//g')"
else
  echo "JAVA_VERSION="
fi
svc=""
for u in Splunkd splunkd splunk; do
  state=$(systemctl list-unit-files --no-legend "${u}.service" 2>/dev/null | awk '{print $2}')
  case "$state" in enabled|disabled|static|indirect|enabled-runtime) svc="systemd|${u}.service"; break;; esac
done
[ -z "$svc" ] && { sudo test -e /etc/init.d/splunk && svc="initd|/etc/init.d/splunk"; }
[ -z "$svc" ] && svc="binary|$SPLUNK_HOME/bin/splunk"
echo "SERVICE=$svc"
echo "DISK=$(df -h /opt | awk 'NR==2{print $4" free of "$2" ("$5" used)"}')"
REMOTE
  raw=$(printf '%s' "$script" | rexec 'bash -s') \
    || { err "Could not reach $HOST over SSH."; return 1; }

  # reset
  ST_SPLUNK_INSTALLED=0; ST_SPLUNK_VERSION=""; ST_ITSI_VERSION=""
  ST_JAVA_VERSION=""; ST_SERVICE=""; ST_STATUS=""; ST_DISK=""
  local line key val
  while IFS= read -r line; do
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      SPLUNK_INSTALLED) ST_SPLUNK_INSTALLED="$val" ;;
      SPLUNK_VERSION)   ST_SPLUNK_VERSION="$val" ;;
      ITSI_VERSION)     ST_ITSI_VERSION="$val" ;;
      JAVA_VERSION)     ST_JAVA_VERSION="$val" ;;
      SERVICE)          ST_SERVICE="$val" ;;
      STATUS)           ST_STATUS="$val" ;;
      DISK)             ST_DISK="$val" ;;
    esac
  done <<<"$raw"
  return 0
}

_rule() { printf '%s' "$C_CYN"; printf '─%.0s' $(seq 1 60); printf '%s\n' "$C_RESET"; }
_row()  { printf '%s│%s %-8s %s%b%s\n' "$C_CYN" "$C_RESET" "$1" "$C_RESET" "$2" "$C_RESET"; }

print_status_panel() {
  _rule
  printf '%s│%s %sSplunk Lab Provisioner%s  ─  %s%s%s\n' \
    "$C_CYN" "$C_RESET" "$C_BOLD" "$C_RESET" "$C_BLU" "$HOST" "$C_RESET"
  _rule
  if [ "$ST_SPLUNK_INSTALLED" = "1" ]; then
    local st_col="$C_GRN"; [ "$ST_STATUS" = "running" ] || st_col="$C_RED"
    _row "Splunk"  "${C_GRN}${ST_SPLUNK_VERSION:-?}${C_RESET}  (${st_col}${ST_STATUS:-?}${C_RESET})"
    if [ -n "$ST_ITSI_VERSION" ]; then _row "ITSI" "${C_GRN}v${ST_ITSI_VERSION}${C_RESET}"
    else _row "ITSI" "${C_DIM}not installed${C_RESET}"; fi
    _row "Service" "$ST_SERVICE"
  else
    _row "Splunk"  "${C_RED}NOT installed${C_RESET}"
  fi
  if [ -n "$ST_JAVA_VERSION" ]; then _row "Java" "${C_GRN}${ST_JAVA_VERSION}${C_RESET}"
  else _row "Java" "${C_YLW}not installed${C_RESET}"; fi
  _row "Disk" "$ST_DISK"
  _rule
}

# --- Versatile service control --------------------------------------------
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
splunk_version_remote() { rexec "sudo -u splunk ${SPLUNK_HOME}/bin/splunk version 2>/dev/null | awk '{print \$2}'"; }
itsi_version_remote() { rexec "sudo awk -F= '/^version[[:space:]]*=/ {gsub(/ /,\"\",\$2); print \$2; exit}' ${SPLUNK_HOME}/etc/apps/itsi/default/app.conf 2>/dev/null"; }
java_installed() { rexec "command -v java >/dev/null 2>&1"; }

splunk_stop() {
  local method name; IFS='|' read -r method name <<<"$(detect_service_remote)"
  log "Stopping Splunk via: $method ($name)"
  case "$method" in
    systemd) rexec "sudo systemctl stop $name" ;;
    *)       rexec "sudo -u splunk ${SPLUNK_HOME}/bin/splunk stop" ;;
  esac
  local i
  for i in $(seq 1 30); do
    if ! rexec "pgrep -x splunkd >/dev/null 2>&1"; then ok "splunkd stopped."; return 0; fi
    sleep 2
  done
  err "splunkd still running after stop attempt."; return 1
}

splunk_start() {
  local method name; IFS='|' read -r method name <<<"$(detect_service_remote)"
  log "Starting Splunk via: $method ($name)"
  case "$method" in
    systemd) rexec "sudo systemctl start $name" ;;
    *)       rexec "sudo -u splunk ${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt" ;;
  esac
}

wait_for_splunkd() {
  local i
  for i in $(seq 1 60); do
    if rexec "sudo -u splunk ${SPLUNK_HOME}/bin/splunk status 2>/dev/null | grep -qi 'is running'"; then
      ok "splunkd is running."; return 0
    fi
    sleep 5
  done
  err "splunkd did not report running within timeout."; return 1
}

restart_splunk() {
  require_host
  splunk_stop && splunk_start && wait_for_splunkd
}

preflight_disk() {
  local need_mb="${1:-3000}" avail_mb
  avail_mb=$(rexec "df -Pm /opt | awk 'NR==2{print \$4}'")
  log "Free space on /opt: ${avail_mb} MB (need >= ${need_mb} MB)"
  if [ "${avail_mb:-0}" -lt "$need_mb" ]; then
    err "Insufficient disk space on /opt (${avail_mb} MB < ${need_mb} MB)."
    confirm "Continue anyway (NOT recommended)?" || return 1
  fi
  return 0
}

# Resolve target RPM (filename + url) from --rpm-url / --version-index / prompt.
# Echoes "FILENAME|URL" on stdout.
resolve_target_rpm() {
  local fn url
  if [ -n "$RPM_URL" ]; then
    url="$RPM_URL"; fn="${RPM_URL##*/}"
  elif [ -n "$VERSION_INDEX" ]; then
    [[ "$VERSION_INDEX" =~ ^[0-9]+$ ]] && [ "$VERSION_INDEX" -lt "${#SPLUNK_URLS[@]}" ] \
      || { err "Invalid --version-index."; return 1; }
    url="${SPLUNK_URLS[$VERSION_INDEX]}"; fn="${SPLUNK_FILENAMES[$VERSION_INDEX]}"
  else
    local i; for i in "${!SPLUNK_VERSIONS[@]}"; do
      printf '  %s%2d)%s %s\n' "$C_CYN" "$i" "$C_RESET" "${SPLUNK_VERSIONS[$i]}" >&2
    done
    read -p "$(printf 'Select target version: ')" VERSION_INDEX
    [[ "$VERSION_INDEX" =~ ^[0-9]+$ ]] && [ "$VERSION_INDEX" -lt "${#SPLUNK_URLS[@]}" ] \
      || { err "Invalid selection."; return 1; }
    url="${SPLUNK_URLS[$VERSION_INDEX]}"; fn="${SPLUNK_FILENAMES[$VERSION_INDEX]}"
  fi
  echo "${fn}|${url}"
}

# --- Java detect / install -------------------------------------------------
ensure_java() {
  require_host
  if java_installed; then
    ok "Java present: $(rexec "java -version 2>&1 | head -1")"
    return 0
  fi
  warn "Java not found on $HOST."
  warn "Note: modern Splunk bundles its own JRE; Java is only needed for some apps (e.g. DB Connect)."
  confirm "Install ${JAVA_PACKAGE} via yum?" || { log "Skipped Java install."; return 0; }
  log "Installing ${JAVA_PACKAGE}..."
  rexec "sudo yum install -y ${JAVA_PACKAGE}" || { err "Java install failed."; return 1; }
  if java_installed; then ok "Java installed: $(rexec "java -version 2>&1 | head -1")"; else
    err "Java still not detected after install."; return 1; fi
}

# --- Install: Splunk Enterprise (bare host) --------------------------------
install_splunk() {
  require_host
  if splunk_installed; then
    warn "Splunk is already installed on $HOST (v$(splunk_version_remote))."
    confirm "Run the UPGRADE flow instead?" && { upgrade_splunk; return $?; }
    return 0
  fi

  local sel fn url
  sel=$(resolve_target_rpm) || return 1
  fn="${sel%%|*}"; url="${sel#*|}"
  log "Target package: $fn"

  # Admin password
  local pw="$SPLUNK_ADMIN_PASS"
  if [ -z "$pw" ]; then
    if [ "$ASSUME_YES" -eq 1 ]; then die "Non-interactive install requires --admin-pass."; fi
    local pw2
    read -s -p "Set Splunk admin password (min 8 chars): " pw;  echo
    read -s -p "Confirm password: " pw2; echo
    [ "$pw" = "$pw2" ] || die "Passwords do not match."
  fi
  [ "${#pw}" -ge 8 ] || die "Admin password must be at least 8 characters."

  confirm "Install $fn on $HOST as a fresh Splunk instance?" || { log "Aborted."; return 1; }
  preflight_disk 3000 || return 1

  log "1/6 Downloading RPM..."
  rexec "wget -q -O ~/$fn '$url'" || die "Download failed."
  log "2/6 Installing package (rpm -i)..."
  rexec "sudo rpm -i ~/$fn" || die "rpm -i failed."
  log "3/6 Seeding admin credentials..."
  printf '[user_info]\nUSERNAME=%s\nPASSWORD=%s\n' "$SPLUNK_ADMIN_USER" "$pw" \
    | rexec "sudo tee ${SPLUNK_HOME}/etc/system/local/user-seed.conf >/dev/null" \
    || die "Failed to write user-seed.conf."
  rexec "sudo chown -R splunk:splunk ${SPLUNK_HOME}"
  log "4/6 First start (accepts license, applies admin seed)..."
  rexec "sudo -u splunk ${SPLUNK_HOME}/bin/splunk start --accept-license --answer-yes --no-prompt" \
    || die "Initial start failed."
  log "5/6 Enabling boot-start (systemd)..."
  if confirm "Enable boot-start via systemd (recommended)?"; then
    rexec "sudo ${SPLUNK_HOME}/bin/splunk enable boot-start -user splunk -systemd-managed 1 --accept-license --answer-yes --no-prompt" \
      || warn "enable boot-start returned non-zero (continuing)."
  fi
  log "6/6 Verifying..."
  wait_for_splunkd || die "splunkd did not come up."
  ok "Splunk installed: v$(splunk_version_remote)"
  log "Web UI: http://$HOST:8000  (user: ${SPLUNK_ADMIN_USER})"
}

# --- Upgrade: Splunk Enterprise -------------------------------------------
upgrade_splunk() {
  require_host
  splunk_installed || die "Splunk is not installed on $HOST. Use the Install action instead."
  local cur; cur=$(splunk_version_remote)
  log "Current Splunk version: ${cur:-unknown}"

  local sel fn url
  sel=$(resolve_target_rpm) || return 1
  fn="${sel%%|*}"; url="${sel#*|}"
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
  ok "Splunk version now: $(splunk_version_remote)"
  [ -n "$itsi" ] && log "ITSI version now: $(itsi_version_remote)"
  ok "Splunk upgrade complete."
}

# --- Upgrade: ITSI ---------------------------------------------------------
# --- App deployment helpers ------------------------------------------------
# Fills global array PKGS with matching files in the Downloads dir.
# Args: one or more find -iname patterns (OR-combined).
_scan_downloads() {
  PKGS=()
  local expr=() p first=1 f
  for p in "$@"; do
    if [ $first -eq 1 ]; then expr+=( -iname "$p" ); first=0
    else expr+=( -o -iname "$p" ); fi
  done
  while IFS= read -r -d $'\0' f; do PKGS+=("$f"); done \
    < <(find "$SPLUNK_DOWNLOADS_PATH" -maxdepth 1 \( "${expr[@]}" \) -print0 | sort -z)
}

# scp a package to the host and extract it into etc/apps (no service action).
_deploy_app_files() {
  local pkg="$1"; local base="${pkg##*/}"
  log "Copying $base (large apps can take a while)..."
  rcopy "$pkg" "$USER@$HOST:/home/$USER/" || { err "scp failed."; return 1; }
  log "Extracting into etc/apps..."
  rexec "sudo tar --warning=no-unknown-keyword -xzf /home/$USER/$(printf %q "$base") -C ${SPLUNK_HOME}/etc/apps/" \
    || { err "Extraction failed."; return 1; }
  rexec "sudo chown -R splunk:splunk ${SPLUNK_HOME}/etc/apps/"
  ok "Deployed $base."
}

# --- Install apps/add-ons (Splunk stays running; restart to load) ----------
# Non-interactive: --package PATH (single). Interactive: multi-install loop
# over every *.spl / *.tgz in the Downloads dir (v5-style).
install_app() {
  require_host
  splunk_installed || die "Splunk not installed on $HOST."

  # Non-interactive single-package path
  if [ -n "$ITSI_PACKAGE" ]; then
    [ -f "$ITSI_PACKAGE" ] || die "Package not found: $ITSI_PACKAGE"
    confirm "Install app '${ITSI_PACKAGE##*/}' onto $HOST?" || { log "Aborted."; return 1; }
    _deploy_app_files "$ITSI_PACKAGE" || return 1
    if [ "$NO_RESTART" -eq 1 ]; then
      warn "Skipping restart (--no-restart). A restart is required to load the app."
    else
      log "Restarting Splunk to load the app..."; restart_splunk
    fi
    return 0
  fi

  # Interactive multi-install picker
  [ "$ASSUME_YES" -eq 1 ] && die "install-app in non-interactive mode requires --package."
  local PKGS; _scan_downloads "*.spl" "*.tgz"
  [ ${#PKGS[@]} -gt 0 ] || { warn "No .spl/.tgz packages found in $SPLUNK_DOWNLOADS_PATH."; return 0; }
  local deployed=0 i sel
  while true; do
    echo; echo "Apps in $SPLUNK_DOWNLOADS_PATH:"
    for i in "${!PKGS[@]}"; do printf '  %s%2d)%s %s\n' "$C_CYN" "$i" "$C_RESET" "${PKGS[$i]##*/}"; done
    printf '   %sr)%s restart & finish    %sq)%s finish\n' "$C_BOLD" "$C_RESET" "$C_BOLD" "$C_RESET"
    read -p "$(printf '%sInstall which app? %s' "$C_CYN" "$C_RESET")" sel
    case "$sel" in
      q|Q) break ;;
      r|R) restart_splunk; deployed=0; break ;;
      *) if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "${#PKGS[@]}" ]; then
           _deploy_app_files "${PKGS[$sel]}" && deployed=1
         else warn "Invalid selection."; fi ;;
    esac
  done
  if [ "$deployed" -eq 1 ]; then
    confirm "Restart Splunk now to load newly installed apps?" \
      && restart_splunk || warn "Apps deployed; they load on the next restart."
  fi
}

# --- Upgrade an app (stop-based: safe overlay while splunkd is down) --------
# Shared engine for generic app upgrades and the ITSI upgrade wrapper.
# Args: $1 = package path, $2 = human label, $3 = disk MB needed.
_upgrade_app_engine() {
  local pkg="$1" label="$2" need="${3:-3000}"; local base="${pkg##*/}"
  confirm "Upgrade ${label} on $HOST using $base? (splunkd will be stopped)" \
    || { log "Aborted."; return 1; }
  preflight_disk "$need" || return 1
  log "Stopping Splunk (safe stop + verify)..."
  splunk_stop || die "Could not stop Splunk cleanly; aborting before upgrade."
  _deploy_app_files "$pkg" || die "Deploy failed."
  log "Starting Splunk (runs app migration)..."
  splunk_start || die "Start failed after upgrade."
  wait_for_splunkd || die "splunkd did not come up."
}

# Generic app upgrade (any *.spl / *.tgz).
upgrade_app() {
  require_host
  splunk_installed || die "Splunk not installed on $HOST."
  local pkg="$ITSI_PACKAGE" i sel
  if [ -z "$pkg" ]; then
    [ "$ASSUME_YES" -eq 1 ] && die "upgrade-app in non-interactive mode requires --package."
    local PKGS; _scan_downloads "*.spl" "*.tgz"
    [ ${#PKGS[@]} -gt 0 ] || die "No .spl/.tgz packages found in $SPLUNK_DOWNLOADS_PATH."
    echo "Apps in $SPLUNK_DOWNLOADS_PATH:"
    for i in "${!PKGS[@]}"; do printf '  %s%2d)%s %s\n' "$C_CYN" "$i" "$C_RESET" "${PKGS[$i]##*/}"; done
    read -p "Select app package to upgrade: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "${#PKGS[@]}" ] || die "Invalid selection."
    pkg="${PKGS[$sel]}"
  fi
  [ -f "$pkg" ] || die "Package not found: $pkg"
  _upgrade_app_engine "$pkg" "app '${pkg##*/}'" 3000 || return 1
  ok "App upgrade complete: ${pkg##*/}"
}

# --- Upgrade: ITSI (specialised app upgrade) -------------------------------
upgrade_itsi() {
  require_host
  splunk_installed || die "Splunk not installed on $HOST."
  local cur; cur=$(itsi_version_remote)
  [ -n "$cur" ] || die "ITSI not installed (no itsi/default/app.conf). Use install-app for a fresh install."
  log "Current ITSI version: $cur"

  local pkg="$ITSI_PACKAGE" i sel
  if [ -z "$pkg" ]; then
    [ "$ASSUME_YES" -eq 1 ] && die "upgrade-itsi in non-interactive mode requires --package."
    # Match only real ITSI installer packages, not SA-/DA-/helper apps.
    local PKGS; _scan_downloads "splunk-it-service-intelligence_*.spl" "itsi-[0-9]*.spl"
    [ ${#PKGS[@]} -gt 0 ] \
      || die "No ITSI installer (splunk-it-service-intelligence_*.spl) in $SPLUNK_DOWNLOADS_PATH (use --package)."
    echo "ITSI packages in $SPLUNK_DOWNLOADS_PATH:"
    for i in "${!PKGS[@]}"; do printf '  %s%2d)%s %s\n' "$C_CYN" "$i" "$C_RESET" "${PKGS[$i]##*/}"; done
    read -p "Select ITSI package: " sel
    [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -lt "${#PKGS[@]}" ] || die "Invalid selection."
    pkg="${PKGS[$sel]}"
  fi
  [ -f "$pkg" ] || die "Package not found: $pkg"
  _upgrade_app_engine "$pkg" "ITSI (from v$cur)" 5000 || return 1
  ok "ITSI version now: $(itsi_version_remote)"
  log "Allow a few minutes for KV/migration jobs to settle."
}

# --- Detect action (read-only summary) ------------------------------------
action_detect() {
  gather_status || return 1
  print_status_panel
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
      --no-restart)    NO_RESTART=1; shift ;;
      --yes|-y)        ASSUME_YES=1; shift ;;
      -h|--help)       ACTION="help"; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

usage() {
  cat <<USG
Usage: $0 [--host IP] [--action ACTION] [options]
Actions: detect | restart | install-splunk | install-app | upgrade-app | upgrade-splunk | upgrade-itsi | install-java
Options: --version-index N | --rpm-url URL | --package PATH
         --admin-user U | --admin-pass P | --key PATH | --yes
Run with no arguments for the interactive menu.
USG
}

# --- Interactive menu (adaptive + looping) ---------------------------------
interactive_menu() {
  echo "Enter target EC2 public IP:"; read -r HOST
  require_host
  while true; do
    echo
    gather_status || { confirm "Retry?" && continue || break; }
    print_status_panel
    echo
    # Build the adaptive menu.
    local -a keys=() labels=()
    if [ "$ST_SPLUNK_INSTALLED" = "1" ]; then
      keys+=("r"); labels+=("Restart Splunk")
      keys+=("u"); labels+=("Upgrade Splunk")
      [ -n "$ST_ITSI_VERSION" ] && { keys+=("i"); labels+=("Upgrade ITSI"); }
      keys+=("a"); labels+=("Install apps (from ~/Downloads)")
      keys+=("p"); labels+=("Upgrade an app (stop-based)")
    else
      keys+=("s"); labels+=("Install Splunk ${C_DIM}(fresh)${C_RESET}")
    fi
    if [ -z "$ST_JAVA_VERSION" ]; then
      keys+=("j"); labels+=("Install Java ${C_DIM}(${JAVA_PACKAGE})${C_RESET}")
    else
      keys+=("j"); labels+=("Re-check / verify Java")
    fi
    keys+=("d"); labels+=("Re-detect")
    keys+=("q"); labels+=("Quit")

    local n
    for n in "${!keys[@]}"; do
      printf '  %s(%s)%s %b\n' "$C_BOLD" "${keys[$n]}" "$C_RESET" "${labels[$n]}"
    done
    local c; read -p "$(printf '%s> %s' "$C_CYN" "$C_RESET")" c
    case "$c" in
      r|R) [ "$ST_SPLUNK_INSTALLED" = "1" ] && restart_splunk || warn "Not available." ;;
      u|U) [ "$ST_SPLUNK_INSTALLED" = "1" ] && upgrade_splunk || warn "Not available." ;;
      i|I) [ -n "$ST_ITSI_VERSION" ] && upgrade_itsi || warn "Not available." ;;
      a|A) [ "$ST_SPLUNK_INSTALLED" = "1" ] && install_app || warn "Not available." ;;
      p|P) [ "$ST_SPLUNK_INSTALLED" = "1" ] && upgrade_app || warn "Not available." ;;
      s|S) [ "$ST_SPLUNK_INSTALLED" = "1" ] || install_splunk ;;
      j|J) ensure_java ;;
      d|D) : ;;  # loop re-detects
      q|Q) echo "Bye."; break ;;
      *)   warn "Unknown choice: $c" ;;
    esac
  done
}

# --- Dispatch --------------------------------------------------------------
main() {
  parse_args "$@"
  if [ -n "$ACTION" ]; then
    case "$ACTION" in
      help)            usage ;;
      detect)          action_detect ;;
      restart)         restart_splunk ;;
      install-splunk)  install_splunk ;;
      upgrade-splunk)  upgrade_splunk ;;
      upgrade-itsi)    upgrade_itsi ;;
      upgrade-app)     upgrade_app ;;
      install-app)     install_app ;;
      install-java)    ensure_java ;;
      *) die "Unknown action: $ACTION" ;;
    esac
    exit $?
  fi
  interactive_menu
}

main "$@"
