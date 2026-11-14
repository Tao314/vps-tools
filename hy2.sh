#!/bin/bash
# ============================================================
# Hysteria 2 综合管理工具 V6
# 安装/卸载、启动/停止、UDP优化、客户端二维码
# ============================================================

set -Eeuo pipefail

BIN="/usr/local/bin/hysteria"
SERVICE="hysteria-server"
CONFIG_DIR="/etc/hysteria"
CONFIG="/etc/hysteria/config.yaml"
QR_DIR="/root/hysteria2-client"
URI_FILE="$QR_DIR/client-uri.txt"
PNG_FILE="$QR_DIR/client-qr.png"
UDP_CONF="/etc/sysctl.d/99-hysteria-udp.conf"
DROPIN_DIR="/etc/systemd/system/${SERVICE}.service.d"
DROPIN_FILE="${DROPIN_DIR}/20-cert-access.conf"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行此脚本。"
    exit 1
fi

pause() {
    echo
    read -r -p "按回车返回主菜单..." _
}

refresh_status() {
    if [[ -x "$BIN" ]] || systemctl cat "$SERVICE" >/dev/null 2>&1; then
        INSTALLED=1
    else
        INSTALLED=0
    fi

    if systemctl is-active --quiet "$SERVICE"; then
        RUNNING=1
    else
        RUNNING=0
    fi
}

install_dependencies() {
    echo "正在检查并安装必要组件..."
    apt-get update
    apt-get install -y curl ca-certificates openssl qrencode
}

# ============================================================
# 生成客户端 URI 和二维码
# ============================================================

generate_client_qr() {
    local auth="$1"
    local domain="$2"
    local port="$3"
    local client_name="Hysteria2-${domain}"
    local uri

    mkdir -p "$QR_DIR"
    chmod 700 "$QR_DIR"

    # 注意：名称由 URI 最后的 #fragment 决定
    uri="hysteria2://${auth}@${domain}:${port}/?sni=${domain}&insecure=0#${client_name}"

    printf '%s\n' "$uri" > "$URI_FILE"
    chmod 600 "$URI_FILE"

    qrencode -o "$PNG_FILE" -s 8 -m 2 "$uri"
    chmod 600 "$PNG_FILE"

    echo
    echo "客户端名称：$client_name"
    echo "客户端 URI：$URI_FILE"
    echo "二维码文件：$PNG_FILE"
}

# ============================================================
# 搜索证书和私钥
# ============================================================

find_certificate() {
    local domain="$1"
    local cert=""
    local key=""
    local candidate_cert
    local candidate_key
    local candidate_domain
    local possible_key
    local cert_hash
    local key_hash
    local dir
    local key_name

    local search_dirs=(
        "/www/server/panel/vhost/cert"
        "/etc/letsencrypt/live"
        "/root/.acme.sh"
        "/etc/ssl"
    )

    echo
    echo "正在搜索域名 ${domain} 对应的证书和私钥..."

    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue

        while IFS= read -r -d '' candidate_cert; do
            case "$(basename "$candidate_cert")" in
                fullchain.pem|cert.pem|certificate.pem) ;;
                *) continue ;;
            esac

            candidate_domain="$(
                openssl x509 -in "$candidate_cert" \
                    -noout -ext subjectAltName 2>/dev/null |
                grep -oE 'DNS:[^, ]+' |
                sed 's/^DNS://' |
                grep -Fx "$domain" || true
            )"

            [[ "$candidate_domain" == "$domain" ]] || continue

            if ! openssl x509 -in "$candidate_cert" \
                -noout -checkend 86400 >/dev/null 2>&1; then
                continue
            fi

            candidate_key=""

            for key_name in privkey.pem key.pem; do
                possible_key="$(dirname "$candidate_cert")/$key_name"
                [[ -f "$possible_key" ]] || continue

                cert_hash="$(
                    openssl x509 -in "$candidate_cert" -pubkey -noout 2>/dev/null |
                    openssl pkey -pubin -outform DER 2>/dev/null |
                    sha256sum | awk '{print $1}'
                )"

                key_hash="$(
                    openssl pkey -in "$possible_key" -pubout -outform DER 2>/dev/null |
                    sha256sum | awk '{print $1}'
                )"

                if [[ -n "$cert_hash" && "$cert_hash" == "$key_hash" ]]; then
                    candidate_key="$possible_key"
                    break
                fi
            done

            if [[ -n "$candidate_key" ]]; then
                cert="$candidate_cert"
                key="$candidate_key"
                break
            fi

        done < <(
            find "$dir" -type f \
                \( -name "fullchain.pem" -o -name "cert.pem" -o -name "certificate.pem" \) \
                -print0 2>/dev/null
        )

        [[ -n "$cert" ]] && break
    done

    if [[ -z "$cert" || -z "$key" ]]; then
        echo "没有找到与域名匹配且有效的证书和私钥。"
        return 1
    fi

    CERT_FILE="$cert"
    KEY_FILE="$key"

    echo "证书：$CERT_FILE"
    echo "私钥：$KEY_FILE"
    echo "证书与私钥匹配检查通过。"

    return 0
}

# ============================================================
# 安装 Hysteria 2
# ============================================================

install_hysteria() {
    echo
    echo "========== 安装 Hysteria 2 =========="

    if [[ ! -x "$BIN" ]]; then
        install_dependencies
        echo "正在安装 Hysteria 官方发行版..."
        HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)
    fi

    install_dependencies

    if [[ ! -x "$BIN" ]]; then
        echo "安装失败：未找到 $BIN"
        return 1
    fi

    echo
    read -r -p "请输入 Hysteria 监听端口 [30443]：" PORT
    PORT="${PORT:-30443}"

    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        echo "端口格式不正确。"
        return 1
    fi

    read -r -p "请输入服务器域名：" DOMAIN

    if [[ -z "$DOMAIN" ]]; then
        echo "域名不能为空。"
        return 1
    fi

    if ! find_certificate "$DOMAIN"; then
        return 1
    fi

    AUTH="$(openssl rand -hex 24)"

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    cat > "$CONFIG" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: ${AUTH}

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
EOF

    chmod 600 "$CONFIG"

    mkdir -p "$DROPIN_DIR"

    cat > "$DROPIN_FILE" <<'EOF'
[Service]
User=root
Group=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_DAC_READ_SEARCH
EOF

    chmod 644 "$DROPIN_FILE"

    # 每次安装都重新生成客户端 URI 和二维码
    generate_client_qr "$AUTH" "$DOMAIN" "$PORT"

    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"

    echo
    echo "========== 安装结果 =========="

    if systemctl is-active --quiet "$SERVICE"; then
        echo "Hysteria 2 已成功启动。"
        echo "监听端口：UDP $PORT"
        echo "域名：$DOMAIN"
        echo "客户端名称：Hysteria2-${DOMAIN}"

        echo
        echo "客户端连接 URI："
        cat "$URI_FILE"

        echo
        echo "二维码文件：$PNG_FILE"
        echo "提示：还需要在云服务器安全组中放行 UDP $PORT。"
    else
        echo "服务启动失败，查看日志："
        journalctl -u "$SERVICE" -n 60 --no-pager
        return 1
    fi
}

# ============================================================
# 卸载 Hysteria 2
# ============================================================

uninstall_hysteria() {
    echo
    echo "========== 卸载 Hysteria 2 =========="

    read -r -p "确定卸载 Hysteria 2？输入 yes 确认：" CONFIRM

    if [[ "$CONFIRM" != "yes" ]]; then
        echo "已取消卸载。"
        return 0
    fi

    systemctl disable --now "$SERVICE" 2>/dev/null || true

    rm -f "/etc/systemd/system/${SERVICE}.service"
    rm -f "$DROPIN_FILE"
    rmdir "$DROPIN_DIR" 2>/dev/null || true

    rm -f "$BIN"
    rm -rf "$CONFIG_DIR"
    rm -rf "$QR_DIR"

    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true

    echo "Hysteria 2 已卸载。"
    echo "证书文件和 UDP 优化配置未删除。"
}

# ============================================================
# 启动 / 停止
# ============================================================

start_hysteria() {
    echo "正在启动 Hysteria 2..."
    systemctl start "$SERVICE"
    sleep 1

    if systemctl is-active --quiet "$SERVICE"; then
        echo "Hysteria 2 启动成功。"
    else
        echo "启动失败，最近日志："
        journalctl -u "$SERVICE" -n 40 --no-pager
    fi
}

stop_hysteria() {
    echo "正在停止 Hysteria 2..."
    systemctl stop "$SERVICE"
    echo "Hysteria 2 已停止。"
}

# ============================================================
# UDP 缓冲区优化
# ============================================================

optimize_udp() {
    echo
    echo "========== UDP 缓冲区优化 =========="

    declare -A TARGETS=(
        ["net.core.rmem_max"]=16777216
        ["net.core.wmem_max"]=16777216
        ["net.ipv4.udp_rmem_min"]=8192
        ["net.ipv4.udp_wmem_min"]=8192
    )

    mkdir -p /etc/sysctl.d

    {
        echo "# Hysteria 2 UDP optimization"

        for key in "${!TARGETS[@]}"; do
            current="$(sysctl -n "$key" 2>/dev/null || echo 0)"
            target="${TARGETS[$key]}"

            if (( current < target )); then
                echo "$key = $target"
            else
                echo "$key = $current"
            fi
        done
    } > "$UDP_CONF"

    chmod 644 "$UDP_CONF"

    if sysctl -p "$UDP_CONF"; then
        echo
        echo "UDP 优化配置已应用。"
    else
        echo "UDP 优化应用失败，请检查 sysctl 输出。"
    fi

    echo
    echo "当前 UDP 参数："

    for key in \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.udp_rmem_min \
        net.ipv4.udp_wmem_min
    do
        printf "%-30s %s\n" "$key" "$(sysctl -n "$key")"
    done
}

# ============================================================
# 显示客户端二维码
# ============================================================

show_client_qr() {
    echo
    echo "========== Hysteria 2 客户端二维码 =========="

    if [[ ! -s "$URI_FILE" ]]; then
        echo "没有找到客户端连接信息，请先安装 Hysteria 2。"
        return 0
    fi

    if ! command -v qrencode >/dev/null 2>&1; then
        echo "正在安装二维码组件..."
        apt-get update
        apt-get install -y qrencode
    fi

    local uri
    local old_name
    local new_uri

    uri="$(cat "$URI_FILE")"

    if [[ "$uri" != hysteria2://* ]]; then
        echo "客户端 URI 格式不正确。"
        return 0
    fi

    # 从 URI 的 # 后提取客户端名称
    old_name="${uri##*#}"

    # 旧版本名称统一改为 Hysteria2-域名
    if [[ "$old_name" == "Debian13-Hysteria2" ]]; then
        local authority
        local domain

        authority="${uri#*@}"
        domain="${authority%%:*}"

        new_uri="${uri%#*}#Hysteria2-${domain}"
        uri="$new_uri"

        printf '%s\n' "$uri" > "$URI_FILE"
        chmod 600 "$URI_FILE"

        echo "已修正旧版客户端名称。"
    fi

    qrencode -o "$PNG_FILE" -s 8 -m 2 "$uri"
    chmod 600 "$PNG_FILE"

    echo
    echo "请扫描下面的二维码："
    echo

    qrencode -t ANSIUTF8 -m 2 "$uri"

    echo
    echo "客户端名称：${uri##*#}"
    echo "二维码 PNG：$PNG_FILE"
    echo
    echo "客户端 URI："
    echo "$uri"
}

# ============================================================
# 主菜单
# ============================================================

while true; do
    refresh_status
    clear

    echo "================================================"
    echo "             Hysteria 2 综合管理工具"
    echo "                       V6.0"
    echo "================================================"

    if (( INSTALLED )); then
        echo "Hysteria 2 状态：已安装"
    else
        echo "Hysteria 2 状态：未安装"
    fi

    if (( RUNNING )); then
        echo "运行状态：运行中"
    else
        echo "运行状态：已停止"
    fi

    echo "------------------------------------------------"

    if (( INSTALLED )); then
        echo "1. 卸载 Hysteria 2"
    else
        echo "1. 安装 Hysteria 2"
    fi

    if (( RUNNING )); then
        echo "2. 停止 Hysteria 2"
    else
        echo "2. 启动 Hysteria 2"
    fi

    echo "3. UDP 缓冲区优化"
    echo "4. 显示客户端二维码"
    echo "0. 退出脚本"

    echo "------------------------------------------------"

    read -r -p "请输入选项：" CHOICE

    case "$CHOICE" in
        1)
            if (( INSTALLED )); then
                uninstall_hysteria
            else
                install_hysteria
            fi
            pause
            ;;
        2)
            if (( RUNNING )); then
                stop_hysteria
            elif (( INSTALLED )); then
                start_hysteria
            else
                echo "请先安装 Hysteria 2。"
            fi
            pause
            ;;
        3)
            optimize_udp
            pause
            ;;
        4)
            show_client_qr
            pause
            ;;
        0)
            echo "退出。"
            exit 0
            ;;
        *)
            echo "无效选项。"
            pause
            ;;
    esac
done
