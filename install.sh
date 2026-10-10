#!/usr/bin/env bash
#
# miku-gatevpn — One-click VPS installer
# Combines VPN Gate exit-node management with Xray/sing-box inbound configuration
# Inspired by fanout (netns isolation), aimili-vpngate (unified proxy), and
# Free-Residential-IP-Proxy-Controller (IP quality auditing)
#
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/miku-gatevpn"
STATE_DIR="/var/lib/miku-gatevpn"
SERVICE_NAME="miku-gatevpn"
PYTHON_MIN="3.8"
readonly SCRIPT_DIR INSTALL_DIR STATE_DIR SERVICE_NAME PYTHON_MIN

# Color helpers (disabled if not a TTY)
if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RST='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RST=''
fi

info()  { printf "${C_CYAN}[INFO]${C_RST}  %s\n" "$*"; }
ok()    { printf "${C_GREEN}[OK]${C_RST}    %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[WARN]${C_RST}  %s\n" "$*"; }
err()   { printf "${C_RED}[ERROR]${C_RST} %s\n" "$*" >&2; }
die()   { err "$*"; exit 1; }

ask_yn() { # ask_yn "question" [default: n]
    local prompt="$1" default="${2:-n}" reply
    if [[ "$default" == "y" ]]; then
        read -rp "$(printf "${C_BOLD}%s${C_RST} [Y/n] " "$prompt")" reply
        [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
    else
        read -rp "$(printf "${C_BOLD}%s${C_RST} [y/N] " "$prompt")" reply
        [[ "$reply" =~ ^[Yy]$ ]]
    fi
}

ask_input() { # ask_input "question" [default]
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -rp "$(printf "${C_BOLD}%s${C_RST} [%s]: " "$prompt" "$default")" reply
        echo "${reply:-$default}"
    else
        read -rp "$(printf "${C_BOLD}%s${C_RST}: " "$prompt")" reply
        echo "$reply"
    fi
}

ask_choice() { # ask_choice "question" option1 option2 ... → prints selected number
    local prompt="$1"; shift
    local i=1
    printf "${C_BOLD}%s${C_RST}\n" "$prompt"
    for opt in "$@"; do
        printf "  ${C_CYAN}%d${C_RST}) %s\n" "$i" "$opt"
        ((i++))
    done
    local sel
    while true; do
        read -rp "$(printf "${C_BOLD}请选择 [1-%d]${C_RST}: " "$#")" sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= $# )); then
            echo "$sel"; return
        fi
        warn "无效选择，请重试"
    done
}

# ── Banner ──────────────────────────────────────────────────────────────────
show_banner() {
    cat <<'BANNER'
  ╦ ╦┌─┐┌┬┐┌─┐  ┌─┐┌┬┐┌─┐┬─┐┌┬┐┬┌┬┐
  ║║║├─┤ ││├┤   ├─┤ ││├┤ ├┬┘ │││ │
  ╚╩╝┴ ┴─┴┘└─┘  ┴ ┴─┴┘└─┘┴└──┴┘┴ ┴
  Gate-VPN: VPN Gate exit nodes + Xray/sing-box inbound management
BANNER
}

# ── Pre-flight checks ───────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || die "此脚本需要 root 权限，请用 sudo 运行"
}

detect_os() {
    # Detect package manager and OS family
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"; PKG_INSTALL="apt-get install -y"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"; PKG_INSTALL="dnf install -y"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"; PKG_INSTALL="yum install -y"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"; PKG_INSTALL="pacman -S --noconfirm"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"; PKG_INSTALL="apk add --no-cache"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"; PKG_INSTALL="zypper install -y"
    else
        die "无法检测包管理器，请手动安装依赖"
    fi
    # Detect distro name
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="${PRETTY_NAME:-unknown}"
    else
        DISTRO="unknown"
    fi
    ARCH=$(uname -m)
    KERNEL=$(uname -r)
    info "系统: $DISTRO ($ARCH) — kernel $KERNEL — 包管理器: $PKG_MGR"
    readonly PKG_MGR PKG_INSTALL DISTRO ARCH KERNEL
}

check_tun() {
    if [[ -c /dev/net/tun ]]; then
        ok "/dev/net/tun 可用"
    else
        warn "/dev/net/tun 不存在 — LXC/OpenVZ 容器可能不支持 TUN/TAP"
        ask_yn "继续安装吗？(隧道功能可能不可用)" "n" || die "已取消"
    fi
}

check_python() {
    local py=""
    for candidate in python3 python3.12 python3.11 python3.10 python3.9 python3.8; do
        if command -v "$candidate" &>/dev/null; then
            local ver
            ver=$("$candidate" -c 'import sys;print(".".join(map(str,sys.version_info[:2])))' 2>/dev/null || echo "0.0")
            # Simple version comparison without bc
            local major minor
            IFS='.' read -r major minor <<< "$ver"
            if [[ "$major" -ge 3 && "$minor" -ge 8 ]]; then
                py="$candidate"; break
            fi
        fi
    done
    if [[ -z "$py" ]]; then
        warn "未找到 Python >= $PYTHON_MIN"
        echo "$py"
    else
        ok "Python: $($py --version 2>&1) → $py"
        echo "$py"
    fi
}

# ── Dependency management ──────────────────────────────────────────────────

# System packages required for core operation
DEPS_SYSTEM=(openvpn iptables iproute2 curl wget unzip jq python3 python3-pip python3-venv)
# Python packages (pip)
DEPS_PY=(aiohttp aiofiles pydantic uvicorn fastapi websockets python-dotenv)
# Optional but strongly recommended
DEPS_OPT=(certbot socat)

check_missing_deps() {
    local missing_sys=() missing_py=() py="$1"
    for dep in "${DEPS_SYSTEM[@]}"; do
        command -v "$dep" &>/dev/null || missing_sys+=("$dep")
    done
    if [[ -n "$py" ]]; then
        for dep in "${DEPS_PY[@]}"; do
            "$py" -c "import ${dep//-/_}" &>/dev/null 2>&1 || missing_py+=("$dep")
        done
    fi
    printf '%s\n' "${missing_sys[@]+"${missing_sys[@]}"}"
    echo "---PY---"
    printf '%s\n' "${missing_py[@]+"${missing_py[@]}"}"
}

install_deps() {
    local py="$1"
    info "检测缺失依赖中..."
    local raw; raw=$(check_missing_deps "$py")
    local missing_sys; mapfile -t missing_sys < <(echo "$raw" | sed '/^---PY---$/,$d')
    local missing_py;  mapfile -t missing_py  < <(echo "$raw" | sed '1,/^---PY---$/d')

    if [[ ${#missing_sys[@]} -gt 0 ]]; then
        warn "缺少系统依赖: ${missing_sys[*]}"
        ask_yn "自动安装以上系统依赖？" "y" || die "请手动安装后重试"
        # Refresh package index once
        case "$PKG_MGR" in
            apt)    apt-get update -qq ;;
            dnf|yum) "$PKG_MGR" makecache -q ;;
        esac
        $PKG_INSTALL "${missing_sys[@]}" || die "系统依赖安装失败"
        ok "系统依赖安装完成"
    else
        ok "系统依赖已满足"
    fi

    if [[ ${#missing_py[@]} -gt 0 && -n "$py" ]]; then
        warn "缺少 Python 包: ${missing_py[*]}"
        ask_yn "用 pip 安装以上 Python 包？" "y" || die "请手动安装后重试"
        "$py" -m pip install --quiet "${missing_py[@]}" || die "Python 依赖安装失败"
        ok "Python 依赖安装完成"
    fi

    # Optional deps — just inform
    local missing_opt=()
    for dep in "${DEPS_OPT[@]}"; do
        command -v "$dep" &>/dev/null || missing_opt+=("$dep")
    done
    [[ ${#missing_opt[@]} -gt 0 ]] && \
        info "可选依赖未安装 (TLS 自动续期需要): ${missing_opt[*]}"
}

# ── Domain setup ────────────────────────────────────────────────────────────

setup_domain() {
    # Returns: sets globals DOMAIN, USE_DOMAIN, CERT_PATH, KEY_PATH
    USE_DOMAIN=false; DOMAIN=""; CERT_PATH=""; KEY_PATH=""

    ask_yn "是否绑定域名访问面板和入站节点？" "n" || return 0
    USE_DOMAIN=true
    DOMAIN=$(ask_input "请输入域名 (例: gate.example.com)")
    [[ -z "$DOMAIN" ]] && { warn "域名为空，跳过域名绑定"; USE_DOMAIN=false; return; }

    # Validate DNS resolution
    info "验证域名解析..."
    local resolved
    resolved=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
    local vps_ip; vps_ip=$(curl -sf --max-time 5 https://api.ipify.org || echo "")
    if [[ -z "$resolved" ]]; then
        warn "域名 $DOMAIN 无法解析，请确认 DNS A 记录指向本机 IP"
    elif [[ -n "$vps_ip" && "$resolved" != "$vps_ip" ]]; then
        warn "域名解析到 $resolved，本机 IP 为 $vps_ip — 可能解析有误"
        ask_yn "仍然继续？" "y" || { USE_DOMAIN=false; return; }
    else
        ok "域名 $DOMAIN → $resolved"
    fi

    # Try to find existing certs
    for dir in \
        "/etc/letsencrypt/live/$DOMAIN" \
        "/root/.acme.sh/${DOMAIN}_ecc" \
        "/root/.acme.sh/${DOMAIN}"
    do
        if [[ -f "$dir/fullchain.pem" && -f "$dir/privkey.pem" ]]; then
            CERT_PATH="$dir/fullchain.pem"; KEY_PATH="$dir/privkey.pem"
            ok "找到现有证书: $CERT_PATH"; break
        fi
        if [[ -f "$dir/${DOMAIN}.cer" && -f "$dir/${DOMAIN}.key" ]]; then
            CERT_PATH="$dir/${DOMAIN}.cer"; KEY_PATH="$dir/${DOMAIN}.key"
            ok "找到现有证书 (acme.sh): $CERT_PATH"; break
        fi
    done

    if [[ -z "$CERT_PATH" ]]; then
        warn "未找到 $DOMAIN 的 TLS 证书"
        if command -v certbot &>/dev/null; then
            ask_yn "用 certbot 自动申请 Let's Encrypt 证书？" "y" && {
                certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos \
                    -m "admin@${DOMAIN}" --no-eff-email || warn "certbot 申请失败，继续但 TLS 不可用"
                CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
                KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
            }
        else
            warn "certbot 未安装，跳过自动申请证书。可先安装后重新运行安装脚本"
        fi
    fi
    readonly USE_DOMAIN DOMAIN CERT_PATH KEY_PATH
}

# ── Existing panel detection ─────────────────────────────────────────────────

detect_existing_panels() {
    # Returns: sets PANEL_TYPE (3xui|xray|singbox|none), PANEL_PORT, PANEL_API_URL
    PANEL_TYPE="none"; PANEL_PORT=""; PANEL_API_URL=""

    info "检测已安装的节点管理面板..."

    # 3x-ui: default port 2053, binary at /usr/local/x-ui/x-ui
    if command -v x-ui &>/dev/null || [[ -f /usr/local/x-ui/x-ui ]]; then
        PANEL_TYPE="3xui"
        PANEL_PORT=$(x-ui setting 2>/dev/null | grep -oP '(?<=port: )\d+' | head -1 || echo "2053")
        PANEL_API_URL="http://127.0.0.1:${PANEL_PORT}"
        ok "检测到 3x-ui 面板 (端口 $PANEL_PORT)"
        return
    fi

    # Standalone xray-core
    if command -v xray &>/dev/null && [[ -f /usr/local/etc/xray/config.json ]]; then
        PANEL_TYPE="xray"; ok "检测到独立 Xray 实例"
        return
    fi

    # sing-box
    if command -v sing-box &>/dev/null || [[ -f /usr/local/bin/sing-box ]]; then
        PANEL_TYPE="singbox"; ok "检测到 sing-box"
        return
    fi

    info "未检测到已安装的节点工具"
    readonly PANEL_TYPE PANEL_PORT PANEL_API_URL
}

# ── Inbound protocol selection ───────────────────────────────────────────────

REALITY_DOMAINS=(
    "www.microsoft.com"
    "www.apple.com"
    "addons.mozilla.org"
    "store.steampowered.com"
    "www.cloudflare.com"
    "dl.google.com"
    "www.swift.org"
    "www.tesla.com"
    "www.lovelive-anime.jp"
    "www.amazon.com"
)

setup_inbound() {
    # Returns: sets INBOUND_BACKEND, INBOUND_PROTO, INBOUND_PORT,
    #          INBOUND_REALITY_SNI, TLS_MODE (tls|reality|none)
    INBOUND_BACKEND="builtin"; INBOUND_PROTO="vless-tcp-reality"
    INBOUND_PORT=443; INBOUND_REALITY_SNI=""; TLS_MODE="reality"

    if [[ "$PANEL_TYPE" != "none" ]]; then
        ask_yn "检测到 $PANEL_TYPE，是否使用其现有节点作为入口？" "y" && {
            INBOUND_BACKEND="$PANEL_TYPE"
            info "将对接 $PANEL_TYPE 现有节点，跳过新建入站"
            return
        }
    fi

    printf '\n%s\n' "──── 入站节点协议选择 ────"
    local choice
    choice=$(ask_choice "请选择入站协议方案" \
        "VLESS + TCP + TLS + Vision (推荐，需域名+证书)" \
        "VLESS + TCP + REALITY (推荐，无需证书)" \
        "VLESS + WS + TLS (CDN 友好，需域名+证书)" \
        "VLESS + gRPC + TLS (低延迟多路复用，需域名+证书)" \
        "VMess + TCP + TLS (兼容旧客户端)" \
        "Trojan + TCP + TLS (伪装 HTTPS 流量)" \
        "Shadowsocks 2022 + TCP (简单快速，无需证书)" \
    )

    case "$choice" in
        1) INBOUND_PROTO="vless-tcp-tls-vision"; TLS_MODE="tls" ;;
        2) INBOUND_PROTO="vless-tcp-reality";    TLS_MODE="reality" ;;
        3) INBOUND_PROTO="vless-ws-tls";         TLS_MODE="tls" ;;
        4) INBOUND_PROTO="vless-grpc-tls";       TLS_MODE="tls" ;;
        5) INBOUND_PROTO="vmess-tcp-tls";        TLS_MODE="tls" ;;
        6) INBOUND_PROTO="trojan-tcp-tls";       TLS_MODE="tls" ;;
        7) INBOUND_PROTO="ss2022-tcp";           TLS_MODE="none" ;;
    esac

    INBOUND_PORT=$(ask_input "入站监听端口" "443")

    if [[ "$TLS_MODE" == "tls" ]]; then
        if [[ -z "$CERT_PATH" ]]; then
            warn "所选协议需要 TLS 证书，但未找到证书"
            ask_yn "改为 REALITY 方案（无需证书）？" "y" && {
                INBOUND_PROTO="vless-tcp-reality"; TLS_MODE="reality"
            }
        else
            ok "将使用证书: $CERT_PATH"
        fi
    fi

    if [[ "$TLS_MODE" == "reality" ]]; then
        printf '\n推荐 REALITY SNI 域名（选择一个高流量境外网站）:\n'
        local i=1
        for d in "${REALITY_DOMAINS[@]}"; do
            printf "  %2d) %s\n" "$i" "$d"; ((i++))
        done
        printf "  %2d) 自定义\n" "$i"
        local sel
        read -rp "$(printf "${C_BOLD}请选择 [1-%d]${C_RST}: " "$i")" sel
        if [[ "$sel" -eq "$i" ]] 2>/dev/null; then
            INBOUND_REALITY_SNI=$(ask_input "请输入自定义 SNI 域名")
        elif [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
            INBOUND_REALITY_SNI="${REALITY_DOMAINS[$((sel-1))]}"
        else
            INBOUND_REALITY_SNI="www.microsoft.com"
        fi
        ok "REALITY SNI: $INBOUND_REALITY_SNI"
    fi

    readonly INBOUND_BACKEND INBOUND_PROTO INBOUND_PORT INBOUND_REALITY_SNI TLS_MODE
}

# ── Project install ──────────────────────────────────────────────────────────

install_project() {
    local py="$1"
    info "安装 miku-gatevpn 到 $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR" "$STATE_DIR"/{vpn-configs,certs,logs}

    # Copy project files
    cp -r "$SCRIPT_DIR"/* "$INSTALL_DIR"/
    chmod +x "$INSTALL_DIR/install.sh"

    # Write runtime config
    local web_path; web_path="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
    local web_pass; web_pass="$(tr -dc 'A-Za-z0-9@#' </dev/urandom | head -c 16)"

    cat > "$STATE_DIR/runtime.env" <<EOF
DOMAIN=${DOMAIN:-}
USE_DOMAIN=${USE_DOMAIN}
CERT_PATH=${CERT_PATH:-}
KEY_PATH=${KEY_PATH:-}
INBOUND_PROTO=${INBOUND_PROTO}
INBOUND_PORT=${INBOUND_PORT}
INBOUND_BACKEND=${INBOUND_BACKEND}
TLS_MODE=${TLS_MODE}
REALITY_SNI=${INBOUND_REALITY_SNI:-}
PANEL_TYPE=${PANEL_TYPE}
WEB_PATH=${web_path}
WEB_PASS=${web_pass}
WEB_PORT=8787
PROXY_BASE_PORT=10000
STATE_DIR=${STATE_DIR}
EOF
    chmod 600 "$STATE_DIR/runtime.env"

    # systemd service
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Miku Gate VPN — VPN Gate proxy with Xray inbound
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=${STATE_DIR}/runtime.env
WorkingDirectory=${INSTALL_DIR}
ExecStart=${py} -m service.manager
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME" && ok "服务已启动" || warn "服务启动失败，请检查 journalctl -u $SERVICE_NAME"

    local access_addr="${DOMAIN:-$(curl -sf --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')}"
    printf '\n'
    ok "安装完成！"
    printf "${C_BOLD}面板地址:${C_RST} http://${access_addr}:8787${web_path}\n"
    printf "${C_BOLD}面板密码:${C_RST} ${web_pass}\n"
    printf "${C_BOLD}配置文件:${C_RST} ${STATE_DIR}/runtime.env\n"
    printf "${C_BOLD}查看日志:${C_RST} journalctl -u %s -f\n" "$SERVICE_NAME"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    show_banner
    check_root
    detect_os
    check_tun

    local py; py=$(check_python)
    [[ -z "$py" ]] && {
        warn "未找到合适的 Python，尝试安装..."
        case "$PKG_MGR" in
            apt)    $PKG_INSTALL python3 python3-pip ;;
            dnf|yum) $PKG_INSTALL python3 python3-pip ;;
            pacman) $PKG_INSTALL python python-pip ;;
            apk)    $PKG_INSTALL python3 py3-pip ;;
            zypper) $PKG_INSTALL python3 python3-pip ;;
        esac
        py=$(check_python)
        [[ -z "$py" ]] && die "Python 安装失败，请手动安装"
    }

    install_deps "$py"
    setup_domain
    detect_existing_panels
    setup_inbound
    install_project "$py"
}

main "$@"
