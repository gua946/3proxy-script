#!/usr/bin/env bash
# acck 3proxy SOCKS5 installer - game/high-concurrency edition
# Defaults: port 10898, user nb, password nb, maxconn 50000
# Goals:
#   - Avoid broken configs after provider changes public IPs
#   - Support high concurrent connections
#   - Support multi-IP exit mode when the server has many IPv4 addresses
#   - Make most prompts ENTER = yes / default

set -Eeuo pipefail

VERSION="0.9.4"
CONFIG_FILE="/etc/3proxy.cfg"
INSTALL_PATH="/usr/local/bin/3proxy"
SERVICE_NAME="3proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_FILE="/var/log/3proxy.log"
BUILD_DIR="/tmp/3proxy-build"
BUILD_LOG="/tmp/3proxy-build.log"
STATE_DIR="/etc/3proxy-auto"
STATE_FILE="${STATE_DIR}/install.env"

# User defaults
DEFAULT_PORT="10898"
DEFAULT_USER="nb"
DEFAULT_PASS="nb"
DEFAULT_MAXCONN="50000"
DEFAULT_BIND_MODE="auto"   # auto | wildcard | multiip
DEFAULT_ENABLE_LOG="n"      # high concurrency: default no access log
DEFAULT_ENABLE_TUNING="y"
DEFAULT_ENABLE_WATCHDOG="y"
DEFAULT_OPEN_FIREWALL="y"

# High concurrency defaults
NOFILE="524288"
FILEMAX="8388608"
NROPEN="1048576"
PORT_RANGE_START="1024"
PORT_RANGE_END="65535"
SOMAX="65535"
NETDEV_BACKLOG="262144"
SYN_BACKLOG="262144"
RMEM_MAX="134217728"
WMEM_MAX="134217728"
CONNTRACK_MAX="2621440"
SYSCTL_FILE="/etc/sysctl.d/99-${SERVICE_NAME}-tuning.conf"
OVR_DIR="/etc/systemd/system/${SERVICE_NAME}.service.d"
WATCHDOG_SCRIPT="/usr/local/bin/3proxy-ip-watchdog.sh"
WATCHDOG_SERVICE="/etc/systemd/system/3proxy-ip-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/3proxy-ip-watchdog.timer"

PORT="$DEFAULT_PORT"
USER_NAME="$DEFAULT_USER"
USER_PASS="$DEFAULT_PASS"
MAXCONN="$DEFAULT_MAXCONN"
BIND_MODE="$DEFAULT_BIND_MODE"
ENABLE_LOG="$DEFAULT_ENABLE_LOG"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf -- '--> %s\n' "$*"; }

need_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        red "请使用 root 用户运行：sudo bash $0"
        exit 1
    fi
}

pause() {
    echo
    read -r -p "按 [Enter] 键返回主菜单..." _ || true
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

ask_yn() {
    # usage: ask_yn "question" "y|n"
    local q="$1" default="${2:-y}" ans hint
    if [[ "$default" =~ ^[Yy]$ ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    read -r -p "$q $hint: " ans || true
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

pkg_install() {
    local pkgs=("$@")
    if has_cmd apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "${pkgs[@]}"
    elif has_cmd dnf; then
        dnf install -y "${pkgs[@]}"
    elif has_cmd yum; then
        yum install -y "${pkgs[@]}"
    else
        red "未找到 apt-get / dnf / yum，无法自动安装依赖。"
        exit 1
    fi
}

install_dependencies() {
    info "检查并安装依赖..."
    if has_cmd apt-get; then
        pkg_install ca-certificates wget curl tar make gcc build-essential openssl iproute2 procps gawk
    elif has_cmd dnf || has_cmd yum; then
        pkg_install ca-certificates wget curl tar make gcc openssl iproute procps-ng gawk
    else
        red "不支持的系统：找不到包管理器。"
        exit 1
    fi
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_int() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 ))
}

valid_token() {
    # 3proxy users line uses space and colon as separators.
    [[ -n "$1" && ! "$1" =~ [[:space:]:] ]]
}

current_public_ip() {
    curl -4 -sS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true
}

get_ipv4_list_all_global() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u
}

is_private_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
    [[ "$ip" =~ ^169\.254\. ]] && return 0
    return 1
}

get_ipv4_list_public_like() {
    local ip
    while read -r ip; do
        [[ -z "$ip" ]] && continue
        if ! is_private_ipv4 "$ip"; then
            echo "$ip"
        fi
    done < <(get_ipv4_list_all_global)
}

get_port_from_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    sed -nE 's/.*socks .* -p *([0-9]+).*/\1/p; s/^socks .* -p([0-9]+).*/\1/p' "$CONFIG_FILE" | head -n1
}

get_user_from_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    awk '/^users /{print $2; exit}' "$CONFIG_FILE" | cut -d: -f1
}

get_pass_from_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    awk '/^users /{print $2; exit}' "$CONFIG_FILE" | cut -d: -f3-
}

save_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF_STATE
PORT='${PORT}'
USER_NAME='${USER_NAME}'
USER_PASS='${USER_PASS}'
MAXCONN='${MAXCONN}'
BIND_MODE='${BIND_MODE}'
ENABLE_LOG='${ENABLE_LOG}'
EOF_STATE
    chmod 600 "$STATE_FILE"
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE" || true
    fi
}

read_config_inputs() {
    local old_port old_user old_pass ans
    old_port="$(get_port_from_config || true)"
    old_user="$(get_user_from_config || true)"
    old_pass="$(get_pass_from_config || true)"

    read -r -p "请输入 SOCKS5 代理端口 [${old_port:-$DEFAULT_PORT}]: " PORT
    PORT="${PORT:-${old_port:-$DEFAULT_PORT}}"
    while ! valid_port "$PORT"; do
        red "端口必须是 1-65535 的数字。"
        read -r -p "请输入 SOCKS5 代理端口 [${DEFAULT_PORT}]: " PORT
        PORT="${PORT:-$DEFAULT_PORT}"
    done

    read -r -p "请输入用户名 [${old_user:-$DEFAULT_USER}]: " USER_NAME
    USER_NAME="${USER_NAME:-${old_user:-$DEFAULT_USER}}"
    while ! valid_token "$USER_NAME"; do
        red "用户名不能为空，且不能包含空格或冒号。"
        read -r -p "请输入用户名 [${DEFAULT_USER}]: " USER_NAME
        USER_NAME="${USER_NAME:-$DEFAULT_USER}"
    done

    read -r -s -p "请输入密码 [${old_pass:-$DEFAULT_PASS}]: " USER_PASS
    echo
    USER_PASS="${USER_PASS:-${old_pass:-$DEFAULT_PASS}}"
    while ! valid_token "$USER_PASS"; do
        red "密码不能为空，且不能包含空格或冒号。"
        read -r -s -p "请重新输入密码 [${DEFAULT_PASS}]: " USER_PASS
        echo
        USER_PASS="${USER_PASS:-$DEFAULT_PASS}"
    done

    read -r -p "最大并发连接 maxconn [${DEFAULT_MAXCONN}]: " MAXCONN
    MAXCONN="${MAXCONN:-$DEFAULT_MAXCONN}"
    while ! valid_int "$MAXCONN"; do
        red "maxconn 必须是正整数。"
        read -r -p "最大并发连接 maxconn [${DEFAULT_MAXCONN}]: " MAXCONN
        MAXCONN="${MAXCONN:-$DEFAULT_MAXCONN}"
    done

    echo
    echo "出口/监听模式："
    echo "  1) auto     自动：检测到多个公网 IPv4 时使用多 IP 出口，否则监听全部 IPv4"
    echo "  2) wildcard 稳定：socks -i0.0.0.0，不写死出口 IP，最抗商家换 IP"
    echo "  3) multiip  多IP：每个公网 IPv4 生成一条 socks -iIP -eIP，适合 200 IP 做独立出口"
    read -r -p "请选择模式 [auto]: " ans
    ans="${ans:-auto}"
    case "$ans" in
        1|auto|AUTO) BIND_MODE="auto" ;;
        2|wildcard|WILDCARD) BIND_MODE="wildcard" ;;
        3|multiip|MULTIIP) BIND_MODE="multiip" ;;
        *) yellow "未知输入，使用 auto。"; BIND_MODE="auto" ;;
    esac

    if ask_yn "是否启用访问日志？高并发/游戏场景建议关闭" "$DEFAULT_ENABLE_LOG"; then
        ENABLE_LOG="y"
    else
        ENABLE_LOG="n"
    fi
}

use_default_inputs() {
    PORT="$DEFAULT_PORT"
    USER_NAME="$DEFAULT_USER"
    USER_PASS="$DEFAULT_PASS"
    MAXCONN="$DEFAULT_MAXCONN"
    BIND_MODE="$DEFAULT_BIND_MODE"
    ENABLE_LOG="$DEFAULT_ENABLE_LOG"
}

detect_effective_mode() {
    local mode="$1" count
    count="$(get_ipv4_list_public_like | wc -l | awk '{print $1}')"
    if [[ "$mode" == "auto" ]]; then
        if (( count >= 2 )); then
            echo "multiip"
        else
            echo "wildcard"
        fi
    else
        echo "$mode"
    fi
}

write_config_resilient() {
    local effective_mode ip count
    effective_mode="$(detect_effective_mode "$BIND_MODE")"

    info "生成配置：PORT=${PORT}, USER=${USER_NAME}, MAXCONN=${MAXCONN}, MODE=${BIND_MODE} -> ${effective_mode}"
    mkdir -p "$(dirname "$CONFIG_FILE")"
    {
        echo "daemon"
        echo "nscache 65536"
        echo "nserver 1.1.1.1"
        echo "nserver 8.8.8.8"
        echo "maxconn ${MAXCONN}"
        if [[ "$ENABLE_LOG" =~ ^[Yy]$ ]]; then
            echo "log ${LOG_FILE} D"
            echo "rotate 30"
        fi
        echo "users ${USER_NAME}:CL:${USER_PASS}"
        echo "auth strong"
        echo "allow ${USER_NAME}"

        if [[ "$effective_mode" == "multiip" ]]; then
            count=0
            while read -r ip; do
                [[ -z "$ip" ]] && continue
                echo "socks -p${PORT} -i${ip} -e${ip}"
                count=$((count + 1))
            done < <(get_ipv4_list_public_like)
            if (( count == 0 )); then
                echo "socks -p${PORT} -i0.0.0.0"
            fi
        else
            echo "socks -p${PORT} -i0.0.0.0"
        fi
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    save_state
    green "配置文件已写入：${CONFIG_FILE}"
}

build_and_install_3proxy() {
    info "下载并编译 3proxy ${VERSION}..."
    rm -rf "$BUILD_DIR" "$BUILD_LOG"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    wget -q --show-progress "https://github.com/3proxy/3proxy/archive/refs/tags/${VERSION}.tar.gz" -O 3proxy.tar.gz
    tar -xzf 3proxy.tar.gz
    cd "3proxy-${VERSION}"

    if ! make -f Makefile.Linux >"$BUILD_LOG" 2>&1; then
        red "3proxy 编译失败，日志：${BUILD_LOG}"
        tail -n 100 "$BUILD_LOG" || true
        exit 1
    fi

    if [[ ! -x ./bin/3proxy ]]; then
        red "编译完成但未找到 ./bin/3proxy，日志：${BUILD_LOG}"
        exit 1
    fi

    install -m 0755 ./bin/3proxy "$INSTALL_PATH"
    green "3proxy 已安装到：${INSTALL_PATH}"
}

write_service() {
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
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

open_firewall_port() {
    local port="$1"
    if has_cmd ufw && ufw status 2>/dev/null | grep -qi active; then
        info "检测到 UFW 已启用，放行 TCP ${port}..."
        ufw allow "${port}/tcp" || true
    fi

    if has_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        info "检测到 firewalld 已启用，放行 TCP ${port}..."
        firewall-cmd --permanent --add-port="${port}/tcp" || true
        firewall-cmd --reload || true
    fi
}

apply_tuning() {
    info "应用高并发优化：systemd LimitNOFILE + sysctl 网络参数..."

    mkdir -p /etc/sysctl.d "$OVR_DIR"

    cat > "$SYSCTL_FILE" <<EOF_SYSCTL
fs.nr_open = ${NROPEN}
fs.file-max = ${FILEMAX}
net.core.somaxconn = ${SOMAX}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range = ${PORT_RANGE_START} ${PORT_RANGE_END}
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
        cat >> "$SYSCTL_FILE" <<EOF_CONNTRACK
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
EOF_CONNTRACK
    fi

    cat > "${OVR_DIR}/override.conf" <<EOF_OVERRIDE
[Service]
LimitNOFILE=${NOFILE}
TasksMax=infinity
EOF_OVERRIDE

    sysctl -e -p "$SYSCTL_FILE" >/dev/null || true
    systemctl daemon-reload
    green "高并发优化已写入：${SYSCTL_FILE} 和 ${OVR_DIR}/override.conf"
}

verify_limits() {
    echo "[Verify] systemd limits:"
    systemctl show "$SERVICE_NAME" -p LimitNOFILE -p TasksMax || true

    local pid
    pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value 2>/dev/null || true)"
    if [[ -n "$pid" && "$pid" != "0" && -d "/proc/$pid" ]]; then
        echo "[Verify] process limits:"
        awk -v pid="$pid" '/Max open files/ {printf("3proxy[PID=%s] soft=%s hard=%s\n",pid,$4,$5)}' "/proc/$pid/limits" || true
        echo "[Verify] current fd count:"
        ls "/proc/$pid/fd" 2>/dev/null | wc -l || true
    fi
}

restart_service() {
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
}

show_status() {
    local p
    p="${PORT:-$(get_port_from_config || echo 10898)}"
    echo "==== systemd 状态 ===="
    systemctl status "$SERVICE_NAME" --no-pager || true
    echo
    echo "==== 监听端口 ===="
    ss -lntp | grep -E "${SERVICE_NAME}|:${p}" || true
    echo
    echo "==== 最近日志 ===="
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
}

show_proxy_info() {
    clear
    echo "--- 当前代理信息 ---"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        red "未找到配置文件：${CONFIG_FILE}"
        return 0
    fi

    local port user pass pubip ips mode effective count
    port="$(get_port_from_config || true)"
    user="$(get_user_from_config || true)"
    pass="$(get_pass_from_config || true)"
    pubip="$(current_public_ip)"
    ips="$(get_ipv4_list_all_global || true)"
    load_state
    mode="${BIND_MODE:-$DEFAULT_BIND_MODE}"
    effective="$(detect_effective_mode "$mode")"
    count="$(grep -c '^socks ' "$CONFIG_FILE" 2>/dev/null || echo 0)"

    echo "配置文件: ${CONFIG_FILE}"
    echo "程序路径: ${INSTALL_PATH}"
    echo "代理类型: SOCKS5"
    echo "端口:     ${port:-未知}"
    echo "用户名:   ${user:-未知}"
    echo "密码:     ${pass:-未知}"
    echo "maxconn:  $(awk '/^maxconn /{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || echo 未知)"
    echo "模式:     ${mode} -> ${effective}"
    echo "socks数:  ${count}"
    echo "公网出口: ${pubip:-检测失败}"
    echo
    echo "本机 IPv4："
    if [[ -n "$ips" ]]; then
        echo "$ips" | sed 's/^/  - /'
    else
        echo "  - 未检测到"
    fi
    echo
    echo "客户端连接示例："
    if [[ -n "$pubip" && -n "$port" && -n "$user" && -n "$pass" ]]; then
        echo "curl -v --socks5 ${user}:${pass}@${pubip}:${port} http://example.com"
    else
        echo "curl -v --socks5 用户名:密码@服务器公网IP:端口 http://example.com"
    fi
}

test_proxy() {
    clear
    echo "--- 测试 SOCKS5 代理 ---"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        red "未找到配置文件，请先安装或修改配置。"
        return 1
    fi

    local port user pass pubip
    port="$(get_port_from_config || true)"
    user="$(get_user_from_config || true)"
    pass="$(get_pass_from_config || true)"
    pubip="$(current_public_ip)"

    if [[ -z "$port" || -z "$user" || -z "$pass" ]]; then
        red "配置解析失败，请检查 ${CONFIG_FILE}"
        return 1
    fi

    echo "本机测试：127.0.0.1:${port}"
    if curl -4 -sS --connect-timeout 8 --max-time 15 --socks5 "${user}:${pass}@127.0.0.1:${port}" http://ifconfig.me; then
        echo
        green "本机 SOCKS5 测试成功。"
    else
        echo
        red "本机 SOCKS5 测试失败。"
    fi

    if [[ -n "$pubip" ]]; then
        echo
        echo "公网 IP 测试：${pubip}:${port}"
        if curl -4 -sS --connect-timeout 8 --max-time 15 --socks5 "${user}:${pass}@${pubip}:${port}" http://ifconfig.me; then
            echo
            green "公网 SOCKS5 测试成功。"
        else
            echo
            red "公网 SOCKS5 测试失败。请检查安全组 / 防火墙 / 商家端口策略。"
        fi
    fi
}

install_ip_watchdog() {
    info "安装 IP 变动检测定时器。multiip 模式会自动重写配置并重启；wildcard 模式会重启作为保险。"
    cat > "$WATCHDOG_SCRIPT" <<EOF_WATCHDOG
#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE="${SERVICE_NAME}"
CONFIG_FILE="${CONFIG_FILE}"
STATE_DIR="${STATE_DIR}"
STATE_FILE="${STATE_FILE}"
LAST_LIST="/run/3proxy-ip-list.last"

current_ips() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | sort -u | grep -Ev '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|169\.254\.)' || true
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
    # Regenerate config if this script exists and state exists.
    if [[ -x "/root/acck_3proxy_nb_game_optimized.sh" ]]; then
        /root/acck_3proxy_nb_game_optimized.sh --regen >/var/log/3proxy-ip-watchdog.log 2>&1 || true
    elif [[ -x "$0" ]]; then
        "$0" --regen >/var/log/3proxy-ip-watchdog.log 2>&1 || true
    else
        systemctl restart "\$SERVICE" || true
    fi
fi
EOF_WATCHDOG
    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_SERVICE" <<EOF_WATCHDOG_SERVICE
[Unit]
Description=Check public IPv4 list and refresh 3proxy if changed
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_SCRIPT}
EOF_WATCHDOG_SERVICE

    cat > "$WATCHDOG_TIMER" <<'EOF_WATCHDOG_TIMER'
[Unit]
Description=Run 3proxy public IPv4 check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Unit=3proxy-ip-watchdog.service

[Install]
WantedBy=timers.target
EOF_WATCHDOG_TIMER

    systemctl daemon-reload
    systemctl enable --now 3proxy-ip-watchdog.timer
    green "已启用 IP 变动检测：每 5 分钟检查一次。"
}

disable_ip_watchdog() {
    systemctl disable --now 3proxy-ip-watchdog.timer >/dev/null 2>&1 || true
    rm -f "$WATCHDOG_SCRIPT" "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
    systemctl daemon-reload
    green "已关闭 IP 变动检测。"
}

regen_config_noninteractive() {
    need_root
    load_state
    PORT="${PORT:-$DEFAULT_PORT}"
    USER_NAME="${USER_NAME:-$DEFAULT_USER}"
    USER_PASS="${USER_PASS:-$DEFAULT_PASS}"
    MAXCONN="${MAXCONN:-$DEFAULT_MAXCONN}"
    BIND_MODE="${BIND_MODE:-$DEFAULT_BIND_MODE}"
    ENABLE_LOG="${ENABLE_LOG:-$DEFAULT_ENABLE_LOG}"
    write_config_resilient
    restart_service || true
}

first_install() {
    clear
    echo "--- 3proxy 首次安装 / 重新编译安装 ---"
    if ask_yn "是否直接使用默认配置：端口 ${DEFAULT_PORT}，账号/密码 ${DEFAULT_USER}/${DEFAULT_PASS}，maxconn ${DEFAULT_MAXCONN}，auto模式，关闭日志" "y"; then
        use_default_inputs
    else
        read_config_inputs
    fi

    install_dependencies
    build_and_install_3proxy
    write_config_resilient
    write_service

    if ask_yn "是否应用高并发优化" "$DEFAULT_ENABLE_TUNING"; then
        apply_tuning
    fi

    if ask_yn "是否自动放行本机防火墙端口 ${PORT}" "$DEFAULT_OPEN_FIREWALL"; then
        open_firewall_port "$PORT"
    fi

    restart_service

    if ask_yn "是否启用 IP 变动检测自动刷新/重启" "$DEFAULT_ENABLE_WATCHDOG"; then
        install_ip_watchdog
    fi

    show_status
    verify_limits
    echo
    green "安装完成。"
    show_proxy_info
}

modify_config() {
    clear
    echo "--- 修改 3proxy 配置 ---"
    if [[ ! -x "$INSTALL_PATH" ]]; then
        red "未找到 ${INSTALL_PATH}，请先执行首次安装。"
        return 1
    fi
    read_config_inputs
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    write_config_resilient
    if ask_yn "是否自动放行本机防火墙端口 ${PORT}" "$DEFAULT_OPEN_FIREWALL"; then
        open_firewall_port "$PORT"
    fi
    restart_service
    show_status
}

uninstall_all() {
    clear
    read -r -p "确定要卸载 3proxy 和相关配置吗？危险操作，默认不卸载 [y/N]: " ans
    ans="${ans:-n}"
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        yellow "已取消。"
        return 0
    fi

    disable_ip_watchdog || true
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE" "$CONFIG_FILE" "$INSTALL_PATH" "$LOG_FILE"
    rm -rf "$OVR_DIR" "$STATE_DIR"
    rm -f "$SYSCTL_FILE"
    systemctl daemon-reload
    green "卸载完成。"
}

show_menu() {
    clear
    echo "=========================================="
    echo "      3proxy SOCKS5 一键脚本 - 游戏高并发版"
    echo "=========================================="
    echo "配置文件: ${CONFIG_FILE}"
    echo "程序路径: ${INSTALL_PATH}"
    echo "默认端口: ${DEFAULT_PORT}；默认账号/密码: ${DEFAULT_USER}/${DEFAULT_PASS}"
    echo "默认 maxconn: ${DEFAULT_MAXCONN}"
    echo "默认模式: auto（多个公网IP时自动多IP出口，否则 -i0.0.0.0）"
    echo "------------------------------------------"
    echo "1. 一键安装 / 重新编译安装"
    echo "2. 修改配置（端口 / 用户 / 密码 / maxconn / 模式）"
    echo "3. 查看当前代理信息"
    echo "4. 测试代理可用性"
    echo "5. 重启 3proxy 服务"
    echo "6. 查看服务状态 / 端口 / 日志"
    echo "7. 应用高并发优化"
    echo "8. 启用 IP 变动检测自动刷新/重启"
    echo "9. 关闭 IP 变动检测"
    echo "10. 卸载代理服务"
    echo "0. 退出"
    echo "------------------------------------------"
}

main() {
    if [[ "${1:-}" == "--regen" ]]; then
        regen_config_noninteractive
        exit 0
    fi

    need_root

    # Copy itself to /root so watchdog can call it after IP list changes.
    if [[ "$(readlink -f "$0")" != "/root/acck_3proxy_nb_game_optimized.sh" ]]; then
        cp -f "$(readlink -f "$0")" /root/acck_3proxy_nb_game_optimized.sh 2>/dev/null || true
        chmod +x /root/acck_3proxy_nb_game_optimized.sh 2>/dev/null || true
    fi

    while true; do
        show_menu
        read -r -p "请输入选择 [0-10]: " choice
        case "$choice" in
            1) first_install; pause ;;
            2) modify_config; pause ;;
            3) show_proxy_info; pause ;;
            4) test_proxy; pause ;;
            5) restart_service; show_status; verify_limits; pause ;;
            6) PORT="$(get_port_from_config || echo 10898)"; show_status; verify_limits; pause ;;
            7) apply_tuning; restart_service; verify_limits; pause ;;
            8) install_ip_watchdog; pause ;;
            9) disable_ip_watchdog; pause ;;
            10) uninstall_all; pause ;;
            0) echo "退出。"; exit 0 ;;
            *) red "无效输入。"; sleep 1 ;;
        esac
    done
}

main "$@"
