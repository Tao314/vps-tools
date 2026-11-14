#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Trojan-GFW 管理脚本
# 官方预编译版本
# 默认端口：10443
# ============================================================

VERSION="1.16.0"
ARCHIVE="trojan-${VERSION}-linux-amd64.tar.xz"
DOWNLOAD_URL="https://github.com/trojan-gfw/trojan/releases/download/v${VERSION}/${ARCHIVE}"

BIN="/usr/local/bin/trojan"
CONFIG="/etc/trojan/config.json"
SERVICE="/etc/systemd/system/trojan.service"
INSTALL_DIR="/etc/trojan"

DEFAULT_PORT="10443"
DEFAULT_FALLBACK_ADDR="127.0.0.1"
DEFAULT_FALLBACK_PORT="80"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

info() { echo -e "${GREEN}[信息]${RESET} $*"; }
warn() { echo -e "${YELLOW}[注意]${RESET} $*"; }
error() { echo -e "${RED}[错误]${RESET} $*" >&2; }
pause() { echo; read -rp "按回车键继续..." _; }

# ============================================================
# 基础检查
# ============================================================

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "请使用 root 用户运行。"
        exit 1
    fi
}

check_system() {
    if ! command -v systemctl >/dev/null 2>&1; then
        error "未检测到 systemd。"
        exit 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        error "此脚本仅支持 Debian / Ubuntu。"
        exit 1
    fi

    if [[ "$(uname -m)" != "x86_64" ]]; then
        error "当前系统架构不是 x86_64，无法使用此预编译包。"
        exit 1
    fi
}

is_installed() {
    [[ -x "$BIN" && -f "$CONFIG" && -f "$SERVICE" ]]
}

is_running() {
    systemctl is-active --quiet trojan.service
}

check_port_format() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# ============================================================
# 安装依赖
# ============================================================

install_dependencies() {
    info "安装必要运行工具..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        xz-utils \
        openssl \
        python3 \
        qrencode \
        iproute2

    info "依赖安装完成。"
}

# ============================================================
# 下载官方预编译程序
# ============================================================

download_trojan() {
    local workdir
    local binary

    workdir="$(mktemp -d /tmp/trojan-install.XXXXXX)"

    info "下载 Trojan-GFW 官方 v${VERSION} 预编译版本..."

    if ! curl -fL --retry 3 --connect-timeout 15 \
        --progress-bar "$DOWNLOAD_URL" \
        -o "$workdir/$ARCHIVE"; then

        rm -rf "$workdir"
        error "下载失败。"
        return 1
    fi

    info "检查压缩包完整性..."

    if ! tar -tJf "$workdir/$ARCHIVE" >/dev/null 2>&1; then
        rm -rf "$workdir"
        error "压缩包损坏或格式不正确。"
        return 1
    fi

    info "解压官方程序..."

    if ! tar -xJf "$workdir/$ARCHIVE" -C "$workdir"; then
        rm -rf "$workdir"
        error "解压失败。"
        return 1
    fi

    binary="$workdir/trojan/trojan"

    if [[ ! -x "$binary" ]]; then
        rm -rf "$workdir"
        error "压缩包中没有找到官方 Trojan 可执行文件。"
        return 1
    fi

    install -Dm755 "$binary" "$BIN"

    rm -rf "$workdir"

    if ! "$BIN" -v; then
        error "Trojan 程序无法正常运行。"
        rm -f "$BIN"
        return 1
    fi

    info "官方预编译程序安装完成。"
}

# ============================================================
# SSL 证书检测
# ============================================================

validate_cert_pair() {
    local domain="$1"
    local cert="$2"
    local key="$3"

    [[ -s "$cert" && -s "$key" ]] || return 1

    openssl x509 -in "$cert" -noout -checkhost "$domain" \
        >/dev/null 2>&1 || return 1

    openssl x509 -in "$cert" -noout -checkend 0 \
        >/dev/null 2>&1 || return 1

    local cert_pub key_pub

    cert_pub="$(
        openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
    )" || return 1

    key_pub="$(
        openssl pkey -in "$key" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
    )" || return 1

    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

find_certificate() {
    local domain="$1"
    local cert key file dir

    local -a cert_candidates=()
    local -a key_candidates=()

    local -a search_dirs=(
        "/www/server/panel/vhost/cert"
        "/etc/letsencrypt/live"
        "/root/.acme.sh"
        "/etc/ssl"
    )

    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue

        while IFS= read -r -d '' file; do
            cert_candidates+=("$file")
        done < <(
            find -L "$dir" -maxdepth 5 -type f \
                \( -name "fullchain.pem" \
                -o -name "fullchain.cer" \
                -o -name "cert.pem" \
                -o -name "${domain}.cer" \
                -o -name "${domain}.crt" \
                -o -name "certificate.crt" \) \
                -print0 2>/dev/null
        )

        while IFS= read -r -d '' file; do
            key_candidates+=("$file")
        done < <(
            find -L "$dir" -maxdepth 5 -type f \
                \( -name "privkey.pem" \
                -o -name "key.pem" \
                -o -name "${domain}.key" \
                -o -name "private.key" \) \
                -print0 2>/dev/null
        )
    done

    for cert in "${cert_candidates[@]}"; do
        local cert_dir
        cert_dir="$(dirname "$cert")"

        for key in "${key_candidates[@]}"; do
            [[ "$(dirname "$key")" == "$cert_dir" ]] || continue

            if validate_cert_pair "$domain" "$cert" "$key"; then
                printf '%s\n%s\n' "$cert" "$key"
                return 0
            fi
        done
    done

    return 1
}

select_certificate() {
    local domain="$1"
    local result=""
    local cert=""
    local key=""
    local answer

    info "搜索域名 ${domain} 的 SSL 证书..."

    if result="$(find_certificate "$domain")"; then
        cert="$(printf '%s\n' "$result" | sed -n '1p')"
        key="$(printf '%s\n' "$result" | sed -n '2p')"

        echo
        info "找到可用证书："
        echo "证书：$cert"
        echo "私钥：$key"

        read -rp "使用这组证书？[Y/n] " answer

        if [[ "$answer" =~ ^[Nn]$ ]]; then
            cert=""
            key=""
        fi
    fi

    if [[ -z "$cert" || -z "$key" ]]; then
        echo
        warn "请手动指定证书路径。"

        read -rp "请输入证书文件完整路径: " cert
        read -rp "请输入私钥文件完整路径: " key
    fi

    cert="${cert/#\~/$HOME}"
    key="${key/#\~/$HOME}"

    if ! validate_cert_pair "$domain" "$cert" "$key"; then
        error "证书检查失败。"
        error "请检查域名、有效期以及证书与私钥是否匹配。"
        return 1
    fi

    CERT_PATH="$cert"
    KEY_PATH="$key"

    info "证书检查通过。"

    openssl x509 -in "$CERT_PATH" -noout -dates
}

# ============================================================
# 防火墙
# ============================================================

open_firewall_port() {
    local port="$1"

    echo
    info "检查防火墙..."

    if command -v ufw >/dev/null 2>&1 &&
       ufw status 2>/dev/null | grep -q "Status: active"; then

        ufw allow "${port}/tcp" >/dev/null
        info "UFW 已放行 TCP ${port}。"

    elif command -v firewall-cmd >/dev/null 2>&1 &&
         systemctl is-active --quiet firewalld 2>/dev/null; then

        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
        firewall-cmd --reload >/dev/null

        info "firewalld 已放行 TCP ${port}。"

    else
        warn "没有检测到正在运行的 UFW / firewalld。"
        warn "请确认 VPS 服务商安全组已放行 TCP ${port}。"
    fi
}

# ============================================================
# 生成配置文件
# ============================================================

generate_password() {
    openssl rand -hex 24
}

write_config() {
    local domain="$1"
    local port="$2"
    local password="$3"
    local cert="$4"
    local key="$5"
    local fallback_addr="$6"
    local fallback_port="$7"

    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"

    python3 - "$CONFIG" "$port" "$password" "$cert" "$key" \
        "$fallback_addr" "$fallback_port" <<'PY'
import json
import sys

config_path, port, password, cert, key, fallback_addr, fallback_port = sys.argv[1:]

config = {
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": int(port),
    "remote_addr": fallback_addr,
    "remote_port": int(fallback_port),
    "password": [password],
    "log_level": 1,
    "ssl": {
        "cert": cert,
        "key": key,
        "key_password": "",
        "cipher": (
            "ECDHE-ECDSA-AES128-GCM-SHA256:"
            "ECDHE-RSA-AES128-GCM-SHA256:"
            "ECDHE-ECDSA-AES256-GCM-SHA384:"
            "ECDHE-RSA-AES256-GCM-SHA384:"
            "ECDHE-ECDSA-CHACHA20-POLY1305:"
            "ECDHE-RSA-CHACHA20-POLY1305:"
            "DHE-RSA-AES128-GCM-SHA256:"
            "DHE-RSA-AES256-GCM-SHA384"
        ),
        "cipher_tls13": (
            "TLS_AES_128_GCM_SHA256:"
            "TLS_CHACHA20_POLY1305_SHA256:"
            "TLS_AES_256_GCM_SHA384"
        ),
        "prefer_server_cipher": True,
        "alpn": ["http/1.1"],
        "reuse_session": True,
        "session_ticket": False,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "prefer_ipv4": False,
        "no_delay": True,
        "keep_alive": True,
        "reuse_port": False,
        "fast_open": False,
        "fast_open_qlen": 20
    },
    "mysql": {
        "enabled": False,
        "server_addr": "127.0.0.1",
        "server_port": 3306,
        "database": "trojan",
        "username": "trojan",
        "password": "",
        "key": "",
        "cert": "",
        "ca": ""
    }
}

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(config, f, indent=4, ensure_ascii=False)
    f.write("\n")
PY

    chmod 600 "$CONFIG"
}

# ============================================================
# 创建 systemd 服务
# ============================================================

write_service() {
    python3 - "$SERVICE" "$BIN" "$CONFIG" <<'PY'
import sys

path, binary, config = sys.argv[1:]

content = f"""[Unit]
Description=Trojan-GFW Server
Documentation=https://trojan-gfw.github.io/trojan/
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart={binary} {config}
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=51200
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PY

    chmod 644 "$SERVICE"
    systemctl daemon-reload
}

# ============================================================
# 配置检查
# ============================================================

test_config() {
    info "检查 Trojan 配置文件..."

    if ! "$BIN" -t "$CONFIG"; then
        error "配置检查失败，暂不启动服务。"
        return 1
    fi

    info "配置检查通过。"
}

# ============================================================
# 二维码与连接信息
# ============================================================

show_connection() {
    local domain="$1"
    local port="$2"
    local password="$3"

    local uri="trojan://${password}@${domain}:${port}#Trojan-${domain}"

    echo
    echo "============================================================"
    echo -e "${GREEN}Trojan 安装完成${RESET}"
    echo "============================================================"
    echo
    echo "服务器地址：${domain}"
    echo "服务器端口：${port}"
    echo "密码：${password}"
    echo "传输协议：TCP"
    echo "TLS：启用"
    echo
    echo "Trojan 分享链接："
    echo "$uri"
    echo

    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$uri" || true
        qrencode -o /root/trojan-qr.png -s 8 "$uri"

        echo
        info "二维码图片已保存：/root/trojan-qr.png"
    else
        warn "未检测到 qrencode，无法生成二维码。"
    fi

    echo
    echo "配置文件：$CONFIG"
    echo "服务名称：trojan.service"
    echo "============================================================"
}

# ============================================================
# 安装流程
# ============================================================

install_flow() {
    local domain port password
    local fallback_addr fallback_port

    echo
    echo "========== Trojan 安装 =========="
    echo

    read -rp "请输入服务器域名: " domain

    if [[ -z "$domain" || "$domain" == *"/"* || "$domain" == *" "* ]]; then
        error "域名格式不正确。"
        return 1
    fi

    read -rp "请输入 Trojan 端口 [默认 ${DEFAULT_PORT}]: " port
    port="${port:-$DEFAULT_PORT}"

    if ! check_port_format "$port"; then
        error "端口必须在 1-65535 之间。"
        return 1
    fi

    port="$((10#$port))"

    if ss -lnt 2>/dev/null | awk '{print $4}' |
        grep -Eq "(:|\\])${port}$"; then
        error "TCP ${port} 端口已被占用，请更换端口。"
        return 1
    fi

    echo
    info "设置非 Trojan 流量的回落目标。"
    echo "默认回落到本机网站 127.0.0.1:80。"

    read -rp "回落地址 [默认 ${DEFAULT_FALLBACK_ADDR}]: " fallback_addr
    fallback_addr="${fallback_addr:-$DEFAULT_FALLBACK_ADDR}"

    read -rp "回落端口 [默认 ${DEFAULT_FALLBACK_PORT}]: " fallback_port
    fallback_port="${fallback_port:-$DEFAULT_FALLBACK_PORT}"

    if ! check_port_format "$fallback_port"; then
        error "回落端口格式不正确。"
        return 1
    fi

    fallback_port="$((10#$fallback_port))"

    echo
    warn "请确认回落目标有 Web 服务监听。"
    warn "宝塔 Nginx 通常可以使用 127.0.0.1:80。"
    echo

    if ! install_dependencies; then
        error "依赖安装失败。"
        return 1
    fi

    if [[ ! -x "$BIN" ]]; then
        if ! download_trojan; then
            error "Trojan 下载或安装失败。"
            return 1
        fi
    else
        info "检测到 Trojan 程序已存在，跳过下载。"
    fi

    local CERT_PATH=""
    local KEY_PATH=""

    if ! select_certificate "$domain"; then
        return 1
    fi

    password="$(generate_password)"

    info "生成 Trojan 配置文件..."

    write_config \
        "$domain" "$port" "$password" \
        "$CERT_PATH" "$KEY_PATH" \
        "$fallback_addr" "$fallback_port"

    write_service

    if ! test_config; then
        return 1
    fi

    open_firewall_port "$port"

    info "启动 Trojan 服务..."

    systemctl enable trojan.service >/dev/null
    systemctl restart trojan.service

    sleep 2

    if ! is_running; then
        error "Trojan 启动失败。"
        journalctl -u trojan.service -n 50 --no-pager
        return 1
    fi

    info "Trojan 已成功运行。"

    show_connection "$domain" "$port" "$password"
}

# ============================================================
# 启动 / 停止
# ============================================================

start_trojan() {
    if ! is_installed; then
        error "Trojan 尚未安装。"
        return 1
    fi

    if ! test_config; then
        return 1
    fi

    systemctl start trojan.service
    sleep 1

    if is_running; then
        info "Trojan 已启动。"
    else
        error "启动失败，最近日志如下："
        journalctl -u trojan.service -n 30 --no-pager
        return 1
    fi
}

stop_trojan() {
    systemctl stop trojan.service
    info "Trojan 已停止。"
}

# ============================================================
# 卸载
# ============================================================

uninstall_trojan() {
    echo
    warn "即将卸载 Trojan。"

    echo "将删除："
    echo "  - Trojan 程序"
    echo "  - Trojan 配置文件"
    echo "  - systemd 服务文件"

    echo
    echo "不会删除："
    echo "  - SSL 证书和私钥"
    echo "  - 宝塔面板"
    echo "  - Nginx / 网站文件"
    echo "  - 其他服务"
    echo "  - 防火墙规则"
    echo

    read -rp "确认卸载？输入 yes 继续: " confirm

    [[ "$confirm" == "yes" ]] || {
        info "已取消卸载。"
        return 0
    }

    systemctl disable --now trojan.service >/dev/null 2>&1 || true

    rm -f "$SERVICE"
    rm -f "$BIN"
    rm -rf "$INSTALL_DIR"

    systemctl daemon-reload
    systemctl reset-failed trojan.service >/dev/null 2>&1 || true

    info "Trojan 已卸载。"
    warn "SSL 证书和私钥未作任何修改。"
    warn "防火墙规则未自动删除。"
}

# ============================================================
# 状态查看
# ============================================================

show_status() {
    echo
    echo "========== Trojan 运行状态 =========="

    if ! is_installed; then
        warn "Trojan 尚未完整安装。"
        return
    fi

    systemctl status trojan.service --no-pager -l || true

    echo
    echo "========== 监听端口 =========="
    ss -lntp | grep -E 'trojan|:10443' || true

    echo
    echo "========== 最近日志 =========="
    journalctl -u trojan.service -n 15 --no-pager || true
}

# ============================================================
# 主菜单
# ============================================================

main_menu() {
    while true; do
        clear 2>/dev/null || true

        echo "================================================"
        echo "              Trojan-GFW 管理脚本"
        echo "================================================"
        echo

        if is_installed; then
            if is_running; then
                echo -e "当前状态：${GREEN}运行中${RESET}"
                echo
                echo "  1. 停止 Trojan"
            else
                echo -e "当前状态：${YELLOW}已安装，未运行${RESET}"
                echo
                echo "  1. 启动 Trojan"
            fi

            echo "  2. 卸载 Trojan"
            echo "  3. 查看运行状态"
            echo "  0. 退出"

        else
            echo -e "当前状态：${YELLOW}未安装${RESET}"
            echo
            echo "  1. 安装 Trojan"
            echo "  0. 退出"
        fi

        echo
        echo "================================================"

        read -rp "请选择操作 [0-3]: " choice

        if ! is_installed; then
            case "$choice" in
                1)
                    install_flow
                    pause
                    ;;
                0)
                    exit 0
                    ;;
                *)
                    warn "无效选项。"
                    pause
                    ;;
            esac
        else
            case "$choice" in
                1)
                    if is_running; then
                        stop_trojan
                    else
                        start_trojan
                    fi
                    pause
                    ;;
                2)
                    uninstall_trojan
                    pause
                    ;;
                3)
                    show_status
                    pause
                    ;;
                0)
                    exit 0
                    ;;
                *)
                    warn "无效选项。"
                    pause
                    ;;
            esac
        fi
    done
}

# ============================================================
# 主程序
# ============================================================

check_root
check_system
main_menu
