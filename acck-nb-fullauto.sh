#!/usr/bin/env bash
# 3proxy SOCKS5 full-auto installer - generic version
# Defaults: port 10898, user nb, password nb, maxconn 100000
# Generic IP binding is disabled by default. Enable only when you explicitly set a range/prefix/CIDR.

set -Eeuo pipefail

VERSION="${VERSION:-0.9.4}"
SERVICE="3proxy"
CONFIG_FILE="/etc/3proxy.cfg"
INSTALL_PATH="/usr/local/bin/3proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"
LOG_FILE="/var/log/3proxy.log"
BUILD_DIR="/tmp/3proxy-build"
BUILD_LOG="/tmp/3proxy-build.log"
STATE_DIR="/etc/3proxy-auto"
STATE_FILE="${STATE_DIR}/install.env"
SELF_PATH="/root/acck.sh"

# ===== default proxy config =====
DEFAULT_PORT="10898"
DEFAULT_USER="nb"
DEFAULT_PASS="nb"
DEFAULT_MAXCONN="100000"
DEFAULT_MODE="auto"      # auto: multi public IPs => multiip; one public IP => wildcard
ENABLE_LOG="${ENABLE_LOG:-n}"

# ===== optional generic IPv4 bind config =====
# Default is disabled and no IP segment is hard-coded.
# Examples:
#   BIND_ENABLE=y BIND_IPV4_PREFIX=108.187.244 BIND_START=1 BIND_END=254 bash acck.sh --auto
#   BIND_ENABLE=y BIND_IPV4_CIDR=108.187.244.0/24 bash acck.sh --auto
BIND_ENABLE="${BIND_ENABLE:-n}"
BIND_IPV4_PREFIX="${BIND_IPV4_PREFIX:-}"
BIND_IPV4_CIDR="${BIND_IPV4_CIDR:-}"
BIND_START="${BIND_START:-1}"
BIND_END="${BIND_END:-254}"
BIND_DEV="${BIND_DEV:-auto}"
BIND_ONLY_RANGE="${BIND_ONLY_RANGE:-n}"  # y: config uses only bound range; n: config uses all public-like IPv4s
BIND_SCRIPT="/usr/local/sbin/3proxy-bind-ipv4.sh"
BIND_SERVICE="/etc/systemd/system/3proxy-bind-ipv4.service"
BIND_DROPIN="/etc/systemd/system/${SERVICE}.service.d/10-bind-ipv4.conf"

# ===== high concurrency tuning =====
NOFILE="524288"
NROPEN="1048576"
FILEMAX="8388608"
SOMAX="65535"
NETDEV_BACKLOG="262144"
SYN_BACKLOG="262144"
RMEM_MAX="134217728"
WMEM_MAX="134217728"
CONNTRACK_MAX="2621440"
SYSCTL_FILE="/etc/sysctl.d/99-3proxy-tuning.conf"
OVR_DIR="/etc/systemd/system/${SERVICE}.service.d"
WATCHDOG_SCRIPT="/usr/local/bin/3proxy-ip-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/3proxy-ip-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/3proxy-ip-watchdog.timer"

PORT="$DEFAULT_PORT"
USER_NAME="$DEFAULT_USER"
USER_PASS="$DEFAULT_PASS"
MAXCONN="$DEFAULT_MAXCONN"
MODE="$DEFAULT_MODE"

red(){ echo -e "\033[31m$*\033[0m"; }
green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
info(){ echo "--> $*"; }
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

need_root(){
  if [[ ${EUID} -ne 0 ]]; then
    red "Please run as root: sudo bash $0"
    exit 1
  fi
}

pause(){ echo; read -r -p "Press Enter to return to menu..." _ || true; }

usage(){
  cat <<EOF_USAGE
Usage:
  bash acck.sh --auto
  bash acck.sh --regen
  bash acck.sh --bind
  bash acck.sh --bindfix
  bash acck.sh --status
  bash acck.sh --info

Generic IP binding is disabled by default.
Enable binding with environment variables:

  BIND_ENABLE=y BIND_IPV4_PREFIX=108.187.244 BIND_START=1 BIND_END=254 bash acck.sh --auto
  BIND_ENABLE=y BIND_IPV4_CIDR=108.187.244.0/24 bash acck.sh --auto

Optional variables:
  BIND_DEV=eno1              # default: auto
  BIND_ONLY_RANGE=y          # config uses only the configured bind range
  PORT=10898 USER_NAME=nb USER_PASS=nb MAXCONN=100000 MODE=auto bash acck.sh --auto

Modes:
  auto      multi public IPs => per-IP socks lines; single public IP => wildcard
  multiip   force per-IP socks lines
  wildcard  one socks line, bind on 0.0.0.0
EOF_USAGE
}

pkg_install(){
  if has_cmd apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$@"
  elif has_cmd dnf; then
    dnf install -y "$@"
  elif has_cmd yum; then
    yum install -y "$@"
  else
    red "No apt-get/dnf/yum found. Cannot install dependencies automatically."
    exit 1
  fi
}

install_deps(){
  info "Installing dependencies..."
  if has_cmd apt-get; then
    pkg_install ca-certificates wget curl tar make gcc build-essential openssl iproute2 procps gawk
  else
    pkg_install ca-certificates wget curl tar make gcc openssl iproute procps-ng gawk
  fi
}

is_private_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^169\.254\. ]] && return 0
  [[ "$ip" =~ ^127\. ]] && return 0
  return 1
}

get_all_global_ipv4(){
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -V -u
}

get_public_like_ipv4(){
  local ip
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    if ! is_private_ipv4 "$ip"; then echo "$ip"; fi
  done < <(get_all_global_ipv4)
}

current_public_ip(){ curl -4 -sS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true; }

detect_default_dev(){
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

normalize_bind_settings(){
  BIND_ENABLE="${BIND_ENABLE:-n}"
  BIND_IPV4_PREFIX="${BIND_IPV4_PREFIX:-}"
  BIND_IPV4_CIDR="${BIND_IPV4_CIDR:-}"
  BIND_START="${BIND_START:-1}"
  BIND_END="${BIND_END:-254}"
  BIND_DEV="${BIND_DEV:-auto}"
  BIND_ONLY_RANGE="${BIND_ONLY_RANGE:-n}"

  if [[ -n "$BIND_IPV4_CIDR" && -z "$BIND_IPV4_PREFIX" ]]; then
    if [[ "$BIND_IPV4_CIDR" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.0/24$ ]]; then
      BIND_IPV4_PREFIX="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
      BIND_START="1"
      BIND_END="254"
    else
      red "Only /24 CIDR in x.y.z.0/24 format is supported by this script. Given: $BIND_IPV4_CIDR"
      exit 1
    fi
  fi

  if [[ "$BIND_ENABLE" =~ ^[Yy]$ ]]; then
    if [[ -z "$BIND_IPV4_PREFIX" ]]; then
      red "BIND_ENABLE=y requires BIND_IPV4_PREFIX=x.y.z or BIND_IPV4_CIDR=x.y.z.0/24"
      exit 1
    fi
    if ! [[ "$BIND_START" =~ ^[0-9]+$ && "$BIND_END" =~ ^[0-9]+$ ]]; then
      red "BIND_START and BIND_END must be numbers."
      exit 1
    fi
    if (( BIND_START < 0 || BIND_END > 255 || BIND_START > BIND_END )); then
      red "Invalid range: BIND_START=$BIND_START BIND_END=$BIND_END"
      exit 1
    fi
  fi
}

save_state(){
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  normalize_bind_settings
  cat > "$STATE_FILE" <<EOF_STATE
PORT='$PORT'
USER_NAME='$USER_NAME'
USER_PASS='$USER_PASS'
MAXCONN='$MAXCONN'
MODE='$MODE'
ENABLE_LOG='$ENABLE_LOG'
BIND_ENABLE='$BIND_ENABLE'
BIND_IPV4_PREFIX='$BIND_IPV4_PREFIX'
BIND_IPV4_CIDR='$BIND_IPV4_CIDR'
BIND_START='$BIND_START'
BIND_END='$BIND_END'
BIND_DEV='$BIND_DEV'
BIND_ONLY_RANGE='$BIND_ONLY_RANGE'
EOF_STATE
  chmod 600 "$STATE_FILE"
}

load_state(){
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
  fi
  PORT="${PORT:-$DEFAULT_PORT}"
  USER_NAME="${USER_NAME:-$DEFAULT_USER}"
  USER_PASS="${USER_PASS:-$DEFAULT_PASS}"
  MAXCONN="${MAXCONN:-$DEFAULT_MAXCONN}"
  MODE="${MODE:-$DEFAULT_MODE}"
  ENABLE_LOG="${ENABLE_LOG:-n}"
  normalize_bind_settings
}

effective_mode(){
  local count
  count="$(get_config_ipv4_list | wc -l | awk '{print $1}')"
  if [[ "$MODE" == "auto" ]]; then
    if (( count >= 2 )); then echo "multiip"; else echo "wildcard"; fi
  else
    echo "$MODE"
  fi
}

get_bound_range_ipv4(){
  normalize_bind_settings
  [[ -n "$BIND_IPV4_PREFIX" ]] || return 0
  local pattern="^${BIND_IPV4_PREFIX//./\\.}\."
  get_public_like_ipv4 | grep -E "$pattern" | sort -V -u || true
}

get_config_ipv4_list(){
  load_state >/dev/null 2>&1 || true
  if [[ "$BIND_ONLY_RANGE" =~ ^[Yy]$ && -n "$BIND_IPV4_PREFIX" ]]; then
    get_bound_range_ipv4
  else
    get_public_like_ipv4
  fi
}

write_bind_script(){
  load_state
  if ! [[ "$BIND_ENABLE" =~ ^[Yy]$ ]]; then
    yellow "IP binding is disabled. Set BIND_ENABLE=y and BIND_IPV4_PREFIX or BIND_IPV4_CIDR to enable."
    return 0
  fi

  local dev="$BIND_DEV"
  if [[ "$dev" == "auto" || -z "$dev" ]]; then
    dev="$(detect_default_dev)"
  fi
  [[ -n "$dev" ]] || { red "Cannot detect default network device. Set BIND_DEV=your_device."; exit 1; }

  info "Writing generic IPv4 binding script: prefix=$BIND_IPV4_PREFIX range=$BIND_START-$BIND_END dev=$dev"

  cat > "$BIND_SCRIPT" <<EOF_BIND
#!/usr/bin/env bash
set -Eeuo pipefail
PREFIX="$BIND_IPV4_PREFIX"
START="$BIND_START"
END="$BIND_END"
DEV="$dev"

for i in \$(seq "\$START" "\$END"); do
  ip addr add "\${PREFIX}.\${i}/32" dev "\$DEV" 2>/dev/null || true
done

ip -4 -o addr show dev "\$DEV" scope global 2>/dev/null \
| awk '{print \$4}' \
| cut -d/ -f1 \
| grep -E "^${BIND_IPV4_PREFIX//./\\.}\\." \
| sort -V -u \
| wc -l \
| awk '{print "bound_count="\$1}'
EOF_BIND
  chmod +x "$BIND_SCRIPT"

  cat > "$BIND_SERVICE" <<EOF_SERVICE
[Unit]
Description=Bind generic IPv4 range for 3proxy
After=network-online.target
Wants=network-online.target
Before=3proxy.service

[Service]
Type=oneshot
ExecStart=$BIND_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  mkdir -p "$OVR_DIR"
  cat > "$BIND_DROPIN" <<EOF_DROPIN
[Unit]
Requires=3proxy-bind-ipv4.service
After=3proxy-bind-ipv4.service
EOF_DROPIN

  systemctl daemon-reload
  systemctl enable 3proxy-bind-ipv4.service >/dev/null 2>&1 || true
  save_state
  green "IP bind service written: 3proxy-bind-ipv4.service"
}

bind_ipv4_now(){
  load_state
  if ! [[ "$BIND_ENABLE" =~ ^[Yy]$ ]]; then
    yellow "IP binding is disabled. Nothing to bind."
    return 0
  fi
  write_bind_script
  info "Binding IPv4 range now..."
  systemctl restart 3proxy-bind-ipv4.service || "$BIND_SCRIPT"
}

remove_bind_service(){
  systemctl disable --now 3proxy-bind-ipv4.service >/dev/null 2>&1 || true
  rm -f "$BIND_SCRIPT" "$BIND_SERVICE" "$BIND_DROPIN"
  systemctl daemon-reload
  green "Generic IP bind service removed. Existing runtime IP addresses are not deleted."
}

write_config(){
  load_state
  local em ip count
  em="$(effective_mode)"
  info "Generating config: PORT=$PORT USER=$USER_NAME MAXCONN=$MAXCONN MODE=$MODE -> $em"
  {
    echo "daemon"
    echo "nscache 65536"
    echo "nserver 1.1.1.1"
    echo "nserver 8.8.8.8"
    echo "maxconn $MAXCONN"
    if [[ "$ENABLE_LOG" =~ ^[Yy]$ ]]; then
      echo "log $LOG_FILE D"
      echo "rotate 30"
    fi
    echo "users ${USER_NAME}:CL:${USER_PASS}"
    echo "auth strong"
    echo "allow ${USER_NAME}"
    if [[ "$em" == "multiip" ]]; then
      count=0
      while read -r ip; do
        [[ -z "$ip" ]] && continue
        echo "socks -p${PORT} -i${ip} -e${ip}"
        count=$((count+1))
      done < <(get_config_ipv4_list)
      if (( count == 0 )); then echo "socks -p${PORT} -i0.0.0.0"; fi
    else
      echo "socks -p${PORT} -i0.0.0.0"
    fi
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  save_state
  green "Config written: $CONFIG_FILE"
}

build_install_3proxy(){
  info "Downloading and compiling 3proxy $VERSION..."
  rm -rf "$BUILD_DIR" "$BUILD_LOG"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  wget -q --show-progress "https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz" -O 3proxy.tar.gz
  tar -xzf 3proxy.tar.gz
  cd "3proxy-${VERSION}"
  if ! make -f Makefile.Linux >"$BUILD_LOG" 2>&1; then
    red "Build failed. Log: $BUILD_LOG"
    tail -n 100 "$BUILD_LOG" || true
    exit 1
  fi
  install -m 0755 ./bin/3proxy "$INSTALL_PATH"
  green "3proxy installed: $INSTALL_PATH"
}

write_service(){
  info "Writing systemd service..."
  cat > "$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=3proxy Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=${INSTALL_PATH} ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=${NOFILE}
TasksMax=infinity
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
}

apply_tuning(){
  info "Applying high concurrency tuning..."
  mkdir -p /etc/sysctl.d "$OVR_DIR"
  cat > "$SYSCTL_FILE" <<EOF_SYSCTL
fs.nr_open = ${NROPEN}
fs.file-max = ${FILEMAX}
net.core.somaxconn = ${SOMAX}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
EOF_SYSCTL
  if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    echo "net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}" >> "$SYSCTL_FILE"
  fi
  cat > "${OVR_DIR}/override.conf" <<EOF_OVR
[Service]
LimitNOFILE=${NOFILE}
TasksMax=infinity
EOF_OVR
  sysctl -e -p "$SYSCTL_FILE" >/dev/null || true
  systemctl daemon-reload
  green "High concurrency tuning enabled."
}

open_firewall(){
  local port="$1"
  info "Opening local firewall port $port when supported..."
  if has_cmd ufw && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${port}/tcp" || true
  fi
  if has_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" || true
    firewall-cmd --reload || true
  fi
}

restart_service(){
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE"
}

install_watchdog(){
  info "Enabling IP-change watchdog..."
  cat > "$WATCHDOG_SCRIPT" <<EOF_WD
#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE="$SERVICE"
SELF_PATH="$SELF_PATH"
LAST_LIST="/run/3proxy-ip-list.last"
current_ips(){
  ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | sort -V -u | grep -Ev '^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.|169\\.254\\.|127\\.)' || true
}
CUR="\$(current_ips | tr '\n' ' ')"
[[ -n "\$CUR" ]] || exit 0
if [[ ! -f "\$LAST_LIST" ]]; then
  echo "\$CUR" > "\$LAST_LIST"
  exit 0
fi
LAST="\$(cat "\$LAST_LIST" 2>/dev/null || true)"
if [[ "\$CUR" != "\$LAST" ]]; then
  echo "\$CUR" > "\$LAST_LIST"
  if [[ -x "\$SELF_PATH" ]]; then
    "\$SELF_PATH" --regen >/var/log/3proxy-ip-watchdog.log 2>&1 || true
  else
    systemctl restart "\$SERVICE" || true
  fi
fi
EOF_WD
  chmod +x "$WATCHDOG_SCRIPT"
  cat > "$WATCHDOG_SERVICE" <<EOF_WDS
[Unit]
Description=Check IPv4 changes and refresh 3proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF_WDS
  cat > "$WATCHDOG_TIMER" <<EOF_WDT
[Unit]
Description=Run 3proxy IP check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=3proxy-ip-watchdog.service

[Install]
WantedBy=timers.target
EOF_WDT
  systemctl daemon-reload
  systemctl enable --now 3proxy-ip-watchdog.timer >/dev/null 2>&1 || true
  green "IP-change watchdog enabled."
}

disable_watchdog(){
  systemctl disable --now 3proxy-ip-watchdog.timer >/dev/null 2>&1 || true
  rm -f "$WATCHDOG_SCRIPT" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
  systemctl daemon-reload
  green "IP-change watchdog disabled."
}

verify_limits(){
  echo "[Verify] systemd limits:"
  systemctl show "$SERVICE" -p LimitNOFILE -p TasksMax || true
  local pid
  pid="$(systemctl show "$SERVICE" -p MainPID --value 2>/dev/null || true)"
  if [[ -n "$pid" && "$pid" != "0" && -d "/proc/$pid" ]]; then
    echo "[Verify] process limits:"
    awk -v pid="$pid" '/Max open files/ {printf("3proxy[PID=%s] soft=%s hard=%s\n",pid,$4,$5)}' "/proc/$pid/limits" || true
    echo "[Verify] current fd count:"
    ls "/proc/$pid/fd" 2>/dev/null | wc -l || true
  fi
}

show_status(){
  load_state
  echo "==== 3proxy status ===="
  systemctl status "$SERVICE" --no-pager || true
  echo
  echo "==== listening ports ===="
  ss -lntp | grep -E "3proxy|:${PORT}" || true
  echo
  echo "==== bind service ===="
  systemctl status 3proxy-bind-ipv4.service --no-pager -l 2>/dev/null | sed -n '1,40p' || true
  echo
  echo "==== IP-change watchdog ===="
  systemctl list-timers --all 2>/dev/null | grep 3proxy-ip-watchdog || true
}

show_info(){
  load_state
  local pub count em cfg_count
  pub="$(current_public_ip)"
  count="$(grep -c '^socks ' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  cfg_count="$(get_config_ipv4_list | wc -l | awk '{print $1}')"
  em="$(effective_mode)"
  echo "config file: $CONFIG_FILE"
  echo "program path: $INSTALL_PATH"
  echo "proxy type: SOCKS5"
  echo "port: $PORT"
  echo "username/password: $USER_NAME/$USER_PASS"
  echo "maxconn: $MAXCONN"
  echo "mode: $MODE -> $em"
  echo "socks lines: $count"
  echo "public IP from outside: ${pub:-failed}"
  echo "config IPv4 count: $cfg_count"
  echo "bind enable: $BIND_ENABLE"
  echo "bind prefix/cidr: ${BIND_IPV4_PREFIX:-none} ${BIND_IPV4_CIDR:-}"
  echo "bind range/dev: $BIND_START-$BIND_END / $BIND_DEV"
  echo "bind only range: $BIND_ONLY_RANGE"
  echo "local global IPv4:"
  get_all_global_ipv4 | sed 's/^/  - /' || true
  echo
  echo "test command:"
  echo "curl -v --socks5 ${USER_NAME}:${USER_PASS}@${pub:-server_public_ip}:${PORT} http://example.com"
}

test_proxy(){
  load_state
  local pub
  pub="$(current_public_ip)"
  echo "Local test 127.0.0.1:${PORT}"
  curl -4 -sS --connect-timeout 8 --max-time 15 --socks5 "${USER_NAME}:${USER_PASS}@127.0.0.1:${PORT}" http://ifconfig.me && echo || red "Local test failed"
  if [[ -n "$pub" ]]; then
    echo "Public test ${pub}:${PORT}"
    curl -4 -sS --connect-timeout 8 --max-time 15 --socks5 "${USER_NAME}:${USER_PASS}@${pub}:${PORT}" http://ifconfig.me && echo || red "Public test failed. Check security group/firewall."
  fi
}

full_auto_install(){
  clear || true
  echo "--- 3proxy full-auto install - generic version ---"
  echo "port=${PORT:-$DEFAULT_PORT} user/pass=${USER_NAME:-$DEFAULT_USER}/${USER_PASS:-$DEFAULT_PASS} maxconn=${MAXCONN:-$DEFAULT_MAXCONN} mode=${MODE:-$DEFAULT_MODE}"
  echo "IP binding default: disabled. Enable with BIND_ENABLE=y plus BIND_IPV4_PREFIX or BIND_IPV4_CIDR."

  PORT="${PORT:-$DEFAULT_PORT}"
  USER_NAME="${USER_NAME:-$DEFAULT_USER}"
  USER_PASS="${USER_PASS:-$DEFAULT_PASS}"
  MAXCONN="${MAXCONN:-$DEFAULT_MAXCONN}"
  MODE="${MODE:-$DEFAULT_MODE}"
  ENABLE_LOG="${ENABLE_LOG:-n}"
  normalize_bind_settings
  save_state

  install_deps
  build_install_3proxy
  if [[ "$BIND_ENABLE" =~ ^[Yy]$ ]]; then
    bind_ipv4_now
  fi
  write_config
  write_service
  apply_tuning
  open_firewall "$PORT"
  restart_service
  install_watchdog

  green "All done."
  show_info
  echo
  show_status
  echo
  verify_limits
}

regen_config(){
  need_root
  load_state
  if [[ "$BIND_ENABLE" =~ ^[Yy]$ ]]; then
    bind_ipv4_now || true
  fi
  write_config
  restart_service || true
}

modify_config(){
  load_state
  echo "Current: port=$PORT user=$USER_NAME pass=$USER_PASS maxconn=$MAXCONN mode=$MODE"
  read -r -p "Port [$PORT]: " x; PORT="${x:-$PORT}"
  read -r -p "Username [$USER_NAME]: " x; USER_NAME="${x:-$USER_NAME}"
  read -r -p "Password [$USER_PASS]: " x; USER_PASS="${x:-$USER_PASS}"
  read -r -p "maxconn [$MAXCONN]: " x; MAXCONN="${x:-$MAXCONN}"
  echo "Mode: auto / wildcard / multiip"
  read -r -p "Mode [$MODE]: " x; MODE="${x:-$MODE}"
  read -r -p "Enable generic IP binding? y/n [$BIND_ENABLE]: " x; BIND_ENABLE="${x:-$BIND_ENABLE}"
  if [[ "$BIND_ENABLE" =~ ^[Yy]$ ]]; then
    read -r -p "Bind IPv4 prefix, for example 108.187.244 [$BIND_IPV4_PREFIX]: " x; BIND_IPV4_PREFIX="${x:-$BIND_IPV4_PREFIX}"
    BIND_IPV4_CIDR=""
    read -r -p "Bind start [$BIND_START]: " x; BIND_START="${x:-$BIND_START}"
    read -r -p "Bind end [$BIND_END]: " x; BIND_END="${x:-$BIND_END}"
    read -r -p "Bind device, auto or interface name [$BIND_DEV]: " x; BIND_DEV="${x:-$BIND_DEV}"
    read -r -p "Only use this bind range in config? y/n [$BIND_ONLY_RANGE]: " x; BIND_ONLY_RANGE="${x:-$BIND_ONLY_RANGE}"
  fi
  ENABLE_LOG="n"
  normalize_bind_settings
  save_state
  if [[ "$BIND_ENABLE" =~ ^[Yy]$ ]]; then bind_ipv4_now; fi
  write_config
  open_firewall "$PORT"
  restart_service
  show_status
}

uninstall_all(){
  read -r -p "Confirm uninstall 3proxy? Default no [y/N]: " ans
  ans="${ans:-n}"
  [[ "$ans" =~ ^[Yy]$ ]] || { yellow "Cancelled"; return 0; }
  disable_watchdog || true
  remove_bind_service || true
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$CONFIG_FILE" "$INSTALL_PATH" "$LOG_FILE" "$SYSCTL_FILE"
  rm -rf "$OVR_DIR" "$STATE_DIR"
  systemctl daemon-reload
  green "Uninstalled."
}

show_menu(){
  clear || true
  echo "=========================================="
  echo "      3proxy SOCKS5 one-click script"
  echo "      generic version, no hard-coded IP"
  echo "=========================================="
  echo "Default port: ${DEFAULT_PORT}"
  echo "Default user/pass: ${DEFAULT_USER}/${DEFAULT_PASS}"
  echo "Default maxconn: ${DEFAULT_MAXCONN}"
  echo "Default mode: auto"
  echo "Generic IP binding: disabled unless configured"
  echo "------------------------------------------"
  echo "1. Install / rebuild install"
  echo "2. Modify config"
  echo "3. Show proxy info"
  echo "4. Test proxy"
  echo "5. Restart service"
  echo "6. Show service status"
  echo "7. Apply high concurrency tuning"
  echo "8. Enable IP-change watchdog"
  echo "9. Disable IP-change watchdog"
  echo "10. Bind configured IPv4 range now"
  echo "11. Remove generic bind service"
  echo "12. Uninstall"
  echo "0. Exit"
  echo "------------------------------------------"
}

main(){
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --regen) regen_config; exit 0 ;;
    --bind|--bindfix) need_root; load_state; bind_ipv4_now; write_config; restart_service || true; show_info; exit 0 ;;
    --status) need_root; show_status; verify_limits; exit 0 ;;
    --info) need_root; show_info; exit 0 ;;
  esac

  need_root

  if [[ "$(readlink -f "$0")" != "$SELF_PATH" ]]; then
    cp -f "$(readlink -f "$0")" "$SELF_PATH" 2>/dev/null || true
    chmod +x "$SELF_PATH" 2>/dev/null || true
  fi

  if [[ "${1:-}" == "--auto" || "${1:-}" == "--install" ]]; then
    full_auto_install
    exit 0
  fi

  while true; do
    show_menu
    read -r -p "Choose [0-12]: " choice
    case "$choice" in
      1) full_auto_install; pause ;;
      2) modify_config; pause ;;
      3) show_info; pause ;;
      4) test_proxy; pause ;;
      5) load_state; restart_service; show_status; verify_limits; pause ;;
      6) load_state; show_status; verify_limits; pause ;;
      7) apply_tuning; restart_service; verify_limits; pause ;;
      8) install_watchdog; pause ;;
      9) disable_watchdog; pause ;;
      10) load_state; bind_ipv4_now; write_config; restart_service || true; show_info; pause ;;
      11) remove_bind_service; pause ;;
      12) uninstall_all; pause ;;
      0) exit 0 ;;
      *) red "Invalid input"; sleep 1 ;;
    esac
  done
}

main "$@"
