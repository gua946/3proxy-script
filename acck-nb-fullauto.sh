#!/usr/bin/env bash
# 3proxy SOCKS5 full-auto installer for game/high concurrency use
# Defaults: port 10898, user nb, password nb, maxconn 100000

set -Eeuo pipefail

VERSION="0.9.4"
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

# ===== 默认配置 =====
DEFAULT_PORT="10898"
DEFAULT_USER="nb"
DEFAULT_PASS="nb"
DEFAULT_MAXCONN="100000"
DEFAULT_MODE="auto"      # auto: 多公网IP => 多IP出口；单公网IP => -i0.0.0.0
ENABLE_LOG="n"           # 高并发默认关闭访问日志

# ===== 高并发参数 =====
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
    red "请用 root 运行：sudo bash $0"
    exit 1
  fi
}

pause(){ echo; read -r -p "按 Enter 返回菜单..." _ || true; }

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
    red "未找到 apt-get/dnf/yum，无法自动安装依赖。"
    exit 1
  fi
}

install_deps(){
  info "安装依赖..."
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
  return 1
}

get_all_global_ipv4(){
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u
}

get_public_like_ipv4(){
  local ip
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    if ! is_private_ipv4 "$ip"; then echo "$ip"; fi
  done < <(get_all_global_ipv4)
}

current_public_ip(){ curl -4 -sS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true; }

save_state(){
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  cat > "$STATE_FILE" <<EOF_STATE
PORT='$PORT'
USER_NAME='$USER_NAME'
USER_PASS='$USER_PASS'
MAXCONN='$MAXCONN'
MODE='$MODE'
ENABLE_LOG='$ENABLE_LOG'
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
}

effective_mode(){
  local count
  count="$(get_public_like_ipv4 | wc -l | awk '{print $1}')"
  if [[ "$MODE" == "auto" ]]; then
    if (( count >= 2 )); then echo "multiip"; else echo "wildcard"; fi
  else
    echo "$MODE"
  fi
}

write_config(){
  load_state
  local em ip count
  em="$(effective_mode)"
  info "生成配置：PORT=$PORT USER=$USER_NAME MAXCONN=$MAXCONN MODE=$MODE -> $em"
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
      done < <(get_public_like_ipv4)
      if (( count == 0 )); then echo "socks -p${PORT} -i0.0.0.0"; fi
    else
      echo "socks -p${PORT} -i0.0.0.0"
    fi
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  save_state
  green "配置文件已写入：$CONFIG_FILE"
}

build_install_3proxy(){
  info "下载并编译 3proxy $VERSION..."
  rm -rf "$BUILD_DIR" "$BUILD_LOG"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"
  wget -q --show-progress "https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz" -O 3proxy.tar.gz
  tar -xzf 3proxy.tar.gz
  cd "3proxy-${VERSION}"
  if ! make -f Makefile.Linux >"$BUILD_LOG" 2>&1; then
    red "编译失败，日志：$BUILD_LOG"
    tail -n 100 "$BUILD_LOG" || true
    exit 1
  fi
  install -m 0755 ./bin/3proxy "$INSTALL_PATH"
  green "3proxy 已安装到：$INSTALL_PATH"
}

write_service(){
  info "写入 systemd 服务..."
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
  info "应用高并发优化..."
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
  green "高并发优化已启用。"
}

open_firewall(){
  local port="$1"
  info "自动放行本机防火墙端口 $port，如未启用防火墙则跳过..."
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
  info "启用 IP 变动检测自动刷新/重启..."
  cat > "$WATCHDOG_SCRIPT" <<EOF_WD
#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE="$SERVICE"
SELF_PATH="$SELF_PATH"
LAST_LIST="/run/3proxy-ip-list.last"
current_ips(){
  ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | sort -u | grep -Ev '^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[0-1])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.|169\\.254\\.)' || true
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
  green "IP 变动检测已启用。"
}

disable_watchdog(){
  systemctl disable --now 3proxy-ip-watchdog.timer >/dev/null 2>&1 || true
  rm -f "$WATCHDOG_SCRIPT" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
  systemctl daemon-reload
  green "IP 变动检测已关闭。"
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
  echo "==== 3proxy 状态 ===="
  systemctl status "$SERVICE" --no-pager || true
  echo
  echo "==== 监听端口 ===="
  ss -lntp | grep -E "3proxy|:${PORT}" || true
  echo
  echo "==== IP 变动检测 ===="
  systemctl list-timers --all 2>/dev/null | grep 3proxy-ip-watchdog || true
}

show_info(){
  load_state
  local pub count em
  pub="$(current_public_ip)"
  count="$(grep -c '^socks ' "$CONFIG_FILE" 2>/dev/null || echo 0)"
  em="$(effective_mode)"
  echo "配置文件: $CONFIG_FILE"
  echo "程序路径: $INSTALL_PATH"
  echo "代理类型: SOCKS5"
  echo "端口: $PORT"
  echo "账号/密码: $USER_NAME/$USER_PASS"
  echo "maxconn: $MAXCONN"
  echo "模式: $MODE -> $em"
  echo "socks监听条数: $count"
  echo "公网IP: ${pub:-检测失败}"
  echo "本机IPv4:"
  get_all_global_ipv4 | sed 's/^/  - /' || true
  echo
  echo "测试命令:"
  echo "curl -v --socks5 ${USER_NAME}:${USER_PASS}@${pub:-服务器公网IP}:${PORT} http://example.com"
}

test_proxy(){
  load_state
  local pub
  pub="$(current_public_ip)"
  echo "本机测试 127.0.0.1:${PORT}"
  curl -4 -sS --connect-timeout 8 --max-time 15 --socks5 "${USER_NAME}:${USER_PASS}@127.0.0.1:${PORT}" http://ifconfig.me && echo || red "本机测试失败"
  if [[ -n "$pub" ]]; then
    echo "公网测试 ${pub}:${PORT}"
    curl -4 -sS --connect-timeout 8 --max-time 15 --socks5 "${USER_NAME}:${USER_PASS}@${pub}:${PORT}" http://ifconfig.me && echo || red "公网测试失败：请检查安全组/防火墙"
  fi
}

full_auto_install(){
  clear
  echo "--- 3proxy 全默认自动安装 ---"
  echo "端口=${DEFAULT_PORT} 账号/密码=${DEFAULT_USER}/${DEFAULT_PASS} maxconn=${DEFAULT_MAXCONN} 模式=${DEFAULT_MODE}"
  echo "自动启用：高并发优化、本机防火墙放行、IP变动检测自动刷新/重启。"

  PORT="$DEFAULT_PORT"
  USER_NAME="$DEFAULT_USER"
  USER_PASS="$DEFAULT_PASS"
  MAXCONN="$DEFAULT_MAXCONN"
  MODE="$DEFAULT_MODE"
  ENABLE_LOG="n"
  save_state

  install_deps
  build_install_3proxy
  write_config
  write_service
  apply_tuning
  open_firewall "$PORT"
  restart_service
  install_watchdog

  green "全部完成。"
  show_info
  echo
  show_status
  echo
  verify_limits
}

regen_config(){
  need_root
  load_state
  write_config
  restart_service || true
}

modify_config(){
  load_state
  echo "当前默认：端口=$PORT 用户=$USER_NAME 密码=$USER_PASS maxconn=$MAXCONN mode=$MODE"
  read -r -p "端口 [$PORT]: " x; PORT="${x:-$PORT}"
  read -r -p "用户名 [$USER_NAME]: " x; USER_NAME="${x:-$USER_NAME}"
  read -r -p "密码 [$USER_PASS]: " x; USER_PASS="${x:-$USER_PASS}"
  read -r -p "maxconn [$MAXCONN]: " x; MAXCONN="${x:-$MAXCONN}"
  echo "模式：auto / wildcard / multiip"
  read -r -p "模式 [$MODE]: " x; MODE="${x:-$MODE}"
  ENABLE_LOG="n"
  save_state
  write_config
  open_firewall "$PORT"
  restart_service
  show_status
}

uninstall_all(){
  read -r -p "确认卸载3proxy？默认不卸载 [y/N]: " ans
  ans="${ans:-n}"
  [[ "$ans" =~ ^[Yy]$ ]] || { yellow "已取消"; return 0; }
  disable_watchdog || true
  systemctl stop "$SERVICE" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE" "$CONFIG_FILE" "$INSTALL_PATH" "$LOG_FILE" "$SYSCTL_FILE"
  rm -rf "$OVR_DIR" "$STATE_DIR"
  systemctl daemon-reload
  green "卸载完成。"
}

show_menu(){
  clear
  echo "=========================================="
  echo "      3proxy SOCKS5 一键脚本 - 全默认版"
  echo "=========================================="
  echo "默认端口: ${DEFAULT_PORT}"
  echo "默认账号/密码: ${DEFAULT_USER}/${DEFAULT_PASS}"
  echo "默认 maxconn: ${DEFAULT_MAXCONN}"
  echo "默认模式: auto，多IP自动独立出口，单IP自动 -i0.0.0.0"
  echo "默认自动启用: 高并发优化 / 防火墙放行 / IP变动检测"
  echo "------------------------------------------"
  echo "1. 一键安装 / 重新编译安装（全默认自动启用）"
  echo "2. 修改配置"
  echo "3. 查看代理信息"
  echo "4. 测试代理"
  echo "5. 重启服务"
  echo "6. 查看服务状态"
  echo "7. 应用高并发优化"
  echo "8. 启用 IP 变动检测"
  echo "9. 关闭 IP 变动检测"
  echo "10. 卸载"
  echo "0. 退出"
  echo "------------------------------------------"
}

main(){
  if [[ "${1:-}" == "--regen" ]]; then regen_config; exit 0; fi
  need_root

  # 下载为 /root/acck.sh 时不会产生第二个脚本；从其他路径运行时才复制一份给 watchdog 使用。
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
    read -r -p "请输入选择 [0-10]: " choice
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
      10) uninstall_all; pause ;;
      0) exit 0 ;;
      *) red "无效输入"; sleep 1 ;;
    esac
  done
}

main "$@"
