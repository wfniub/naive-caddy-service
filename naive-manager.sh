#!/usr/bin/env bash
# ==============================================================================
# 项目: Naive-Caddy Docker 全自动部署与运维管理面板
# 架构:
#   - 模式 1: Caddy 全托管模式 (独占 80/443, 自动申请证书, 原生 HTTP/3)
#   - 模式 2: 独立高位端口直通模式 (默认 20443, Docker 直出, 零动宝塔/Nginx, 支持 CF DNS 或本地证书)
# 特性:
#   - 线上版本检测与一键在线平滑升级 (更新日志自动获取)
#   - 工作目录自适应/自定义 (数据与配置自包含)
#   - 多用户凭据动态增删改查与内存级无缝热重载 (caddy reload)
#   - 终端原生二维码打印与标准专属链接格式生成 (含服务器归属地与随机标识)
#   - 优雅返回上一级支持，交互通俗美观
# ==============================================================================

# 当前客户端脚本版本
CURRENT_VERSION="v2026.10.21"
GITHUB_REPO="wfniub/naive-caddy-service"

IMAGE_NAME="ghcr.io/wfniub/naive-caddy:latest"
CONTAINER_NAME="naive-caddy"

# 可靠获取脚本自身绝对路径与执行目录
if [[ -n "$BASH_SOURCE" ]]; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
elif [[ -n "$0" ]]; then
    SCRIPT_PATH="$(readlink -f "$0")"
else
    SCRIPT_PATH="$(pwd)/naive-manager.sh"
fi

INITIAL_DIR="$(dirname "$SCRIPT_PATH")"
APP_DIR="${INITIAL_DIR}"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
CADDY_FILE="${APP_DIR}/Caddyfile"
ENV_FILE="${APP_DIR}/.env"

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
BLUE="\033[34m"
MAGENTA="\033[35m"
BOLD="\033[1m"
PLAIN="\033[0m"

log_info() { echo -e "${GREEN}[✔]${PLAIN} $1"; }
log_warn() { echo -e "${YELLOW}[!]${PLAIN} $1"; }
log_err()  { echo -e "${RED}[✘]${PLAIN} $1"; }

update_app_dir() {
    local target_dir=$1
    mkdir -p "${target_dir}"
    APP_DIR="$(readlink -f "${target_dir}")"
    COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
    CADDY_FILE="${APP_DIR}/Caddyfile"
    ENV_FILE="${APP_DIR}/.env"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "必须使用 root 权限执行此脚本！请使用 sudo 或切换至 root 用户。"
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl ss crontab awk sed grep; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    # 尝试自动安装 qrencode 以支持终端直接打印二维码
    if ! command -v qrencode &>/dev/null; then
        missing+=("qrencode")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "正在自动检查并补充系统工具: ${missing[*]}..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y iproute2 curl cron gawk sed grep qrencode || true
        elif command -v yum &>/dev/null; then
            yum install -y epel-release || true
            yum install -y iproute curl cronie gawk sed grep qrencode || true
        elif command -v dnf &>/dev/null; then
            dnf install -y epel-release || true
            dnf install -y iproute curl cronie gawk sed grep qrencode || true
        fi
    fi

    # 检查 Docker
    if ! command -v docker &>/dev/null; then
        log_warn "未检测到 Docker，正在执行官方快速安装..."
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl enable --now docker
    fi

    # 检查 Docker Compose
    if docker compose version &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        log_warn "未检测到 Docker Compose 插件，正在尝试安装..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y docker-compose-plugin || true
        elif command -v yum &>/dev/null; then
            yum install -y docker-compose-plugin || true
        fi
        if docker compose version &>/dev/null; then
            DOCKER_COMPOSE_CMD="docker compose"
        else
            log_err "Docker Compose 安装失败，请手动安装 docker-compose-plugin 后重试！"
            exit 1
        fi
    fi
}

is_port_occupied() {
    local port=$1
    ss -tlun | grep -qE "(:|\])${port}\s"
}

resolve_symlink() {
    local file_path=$1
    if [[ -L "$file_path" ]]; then
        readlink -f "$file_path"
    else
        echo "$file_path"
    fi
}

detect_ssl_certs() {
    local domain=$1
    FOUND_CERT=""
    FOUND_KEY=""

    local candidates=(
        "/www/server/panel/vhost/cert/${domain}/fullchain.pem:/www/server/panel/vhost/cert/${domain}/privkey.pem"
        "/root/.acme.sh/${domain}_ecc/fullchain.cer:/root/.acme.sh/${domain}_ecc/${domain}.key"
        "/root/.acme.sh/${domain}/fullchain.cer:/root/.acme.sh/${domain}/${domain}.key"
        "/etc/letsencrypt/live/${domain}/fullchain.pem:/etc/letsencrypt/live/${domain}/privkey.pem"
        "/etc/nginx/ssl/${domain}.crt:/etc/nginx/ssl/${domain}.key"
        "/etc/nginx/ssl/${domain}.pem:/etc/nginx/ssl/${domain}.key"
    )

    for item in "${candidates[@]}"; do
        local c="${item%%:*}"
        local k="${item##*:}"
        if [[ -s "$c" && -s "$k" ]]; then
            FOUND_CERT=$(resolve_symlink "$c")
            FOUND_KEY=$(resolve_symlink "$k")
            break
        fi
    done
}

load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${ENV_FILE}"
    fi
}

# 获取 VPS 物理所在区域信息 (采用 Cloudflare 官方 Trace，永久不限流且毫秒级响应)
get_server_region() {
    local loc
    loc=$(curl -s --max-time 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2 || true)
    if [[ -z "$loc" ]]; then
        loc=$(curl -s --max-time 3 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2 || true)
    fi
    loc=$(echo "$loc" | tr -d '\r\n' | tr '[:lower:]' '[:upper:]')

    # 常见地区中文名映射
    case "$loc" in
        HK) echo "HK-中国香港" ;;
        TW) echo "TW-中国台湾" ;;
        JP) echo "JP-日本" ;;
        KR) echo "KR-韩国" ;;
        SG) echo "SG-新加坡" ;;
        US) echo "US-美国" ;;
        GB|UK) echo "UK-英国" ;;
        DE) echo "DE-德国" ;;
        FR) echo "FR-法国" ;;
        CA) echo "CA-加拿大" ;;
        AU) echo "AU-澳大利亚" ;;
        RU) echo "RU-俄罗斯" ;;
        NL) echo "NL-荷兰" ;;
        CN) echo "CN-中国大陆" ;;
        "") echo "Node-节点" ;;
        *) echo "${loc}-节点" ;;
    esac
}

# 100% 本地纯离线终端二维码渲染 (绝不向任何外部服务器发送密码数据)
display_qrcode() {
    local text=$1
    echo -e "\n${CYAN}【📱 客户端扫码一键导入二维码 (100% 本地生成，安全零外传)】${PLAIN}"

    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "${text}" 2>/dev/null || qrencode -t UTF8 "${text}" 2>/dev/null || true
    else
        # 若未安装 qrencode，则尝试使用 python3 本地离线生成
        python3 -c "
import sys
try:
    import qrcode
    qr = qrcode.QRCode(border=1)
    qr.add_data(sys.argv[1])
    qr.print_ascii(invert=True)
except Exception:
    print('提示: 可执行 apt install -y qrencode 或 pip install qrcode 直接在黑屏查看黑白二维码。')
" "${text}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 交互安装与重新配置向导
# ------------------------------------------------------------------------------
install_or_reconfig() {
    clear
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${PLAIN}"
    echo -e "${CYAN}│               🚀 NaiveProxy 快速部署配置向导                │${PLAIN}"
    echo -e "${CYAN}│     (在任意输入步骤中输入 0 或 b 即可随时安全返回主菜单)    │${PLAIN}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${PLAIN}"

    # 1. 确认或自定义工作目录
    echo -e "\n${BOLD}[步骤 1/6] 配置工作与数据存储目录${PLAIN}"
    echo -e "默认使用当前执行路径: ${GREEN}${INITIAL_DIR}${PLAIN}"
    read -rp "请输入工作目录 [直接回车确认默认, 或输入自定义路径]: " input_dir
    if [[ "$input_dir" == "0" || "$input_dir" == "b" ]]; then return; fi
    if [[ -n "$input_dir" ]]; then
        update_app_dir "$input_dir"
    else
        update_app_dir "${INITIAL_DIR}"
    fi
    log_info "工作目录已选定: ${APP_DIR}"
    cd "${APP_DIR}"

    # 2. 节点域名
    echo -e "\n${BOLD}[步骤 2/6] 节点域名设置${PLAIN}"
    read -rp "请输入解析到本服务器的二级域名 (例如: node.yourdomain.com): " DOMAIN
    if [[ "$DOMAIN" == "0" || "$DOMAIN" == "b" ]]; then return; fi
    while [[ -z "$DOMAIN" ]]; do
        read -rp "域名不能为空，请重新输入: " DOMAIN
        if [[ "$DOMAIN" == "0" || "$DOMAIN" == "b" ]]; then return; fi
    done

    # 3. 初始连接账号密码
    echo -e "\n${BOLD}[步骤 3/6] 连接认证凭据设置${PLAIN}"
    local default_user="usr_$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
    local default_pass="$(tr -dc A-Za-z0-9#%_+ </dev/urandom | head -c 16)"

    read -rp "设置初始用户名 [直接回车默认: ${default_user}]: " USERNAME
    if [[ "$USERNAME" == "0" || "$USERNAME" == "b" ]]; then return; fi
    USERNAME="${USERNAME:-$default_user}"

    read -rp "设置初始连接密码 [直接回车默认: ${default_pass}]: " PASSWORD
    if [[ "$PASSWORD" == "0" || "$PASSWORD" == "b" ]]; then return; fi
    PASSWORD="${PASSWORD:-$default_pass}"

    # 4. 架构模式选择 (已优化删除 4 层 SNI，仅保留模式 1 与模式 2)
    echo -e "\n${BOLD}[步骤 4/6] 选择部署架构模式${PLAIN}"
    local p80_used=0
    local p443_used=0
    is_port_occupied 80 && p80_used=1
    is_port_occupied 443 && p443_used=1

    echo -e "${CYAN}宿主机关键端口探测状态:${PLAIN}"
    [[ $p80_used -eq 1 ]] && echo -e " - 80 端口:  ${RED}已被占用 (宿主机已有 Web 业务)${PLAIN}" || echo -e " - 80 端口:  ${GREEN}空闲${PLAIN}"
    [[ $p443_used -eq 1 ]] && echo -e " - 443 端口: ${RED}已被占用 (宿主机已有 SSL 业务)${PLAIN}" || echo -e " - 443 端口: ${GREEN}空闲${PLAIN}"

    echo -e "\n可用模式选择:"
    echo -e " 1. 【Caddy 全托管模式】独占 80/443 端口，由 Caddy 全自动申请证书 (适合纯净全新 VPS)"
    echo -e " 2. 【独立高位端口直通模式】(推荐⭐) 自定义端口直出公网，零改动宝塔/Nginx，完全独立互不影响"
    echo -e " 0. 返回主菜单"

    local def_mode="2"
    [[ $p80_used -eq 0 && $p443_used -eq 0 ]] && def_mode="1"

    read -rp "请选择模式编号 [1-2, 直接回车默认: ${def_mode}]: " mode_choice
    mode_choice="${mode_choice:-$def_mode}"
    if [[ "$mode_choice" == "0" || "$mode_choice" == "b" ]]; then return; fi

    MODE=""
    LISTEN_PORT=""
    if [[ "$mode_choice" == "1" ]]; then
        MODE="standalone"
        LISTEN_PORT=443
    else
        MODE="highport"
        # 默认高位端口 20443，严格循环检测占用
        local def_port=20443
        while true; do
            read -rp "请输入 NaiveProxy 自定义公网端口 [直接回车默认: ${def_port}]: " INPUT_PORT
            if [[ "$INPUT_PORT" == "0" || "$INPUT_PORT" == "b" ]]; then return; fi
            LISTEN_PORT="${INPUT_PORT:-$def_port}"

            if is_port_occupied "$LISTEN_PORT"; then
                log_warn "端口 [${LISTEN_PORT}] 当前已被其他程序占用，无法使用！"
                def_port=$((def_port + 1))
            else
                log_info "端口 [${LISTEN_PORT}] 检查可用！"
                break
            fi
        done
    fi

    # 5. SSL 证书处理方案
    echo -e "\n${BOLD}[步骤 5/6] 配置 SSL 证书方案${PLAIN}"
    CERT_TYPE=""
    CF_API_TOKEN=""
    TARGET_CERT=""
    TARGET_KEY=""
    EMAIL=""

    if [[ "$MODE" == "standalone" ]]; then
        CERT_TYPE="acme_http"
        read -rp "请输入用于接收 Let's Encrypt 证书通知的邮箱: " EMAIL
        if [[ "$EMAIL" == "0" || "$EMAIL" == "b" ]]; then return; fi
        while [[ -z "$EMAIL" ]]; do
            read -rp "邮箱不能为空，请重新输入: " EMAIL
            if [[ "$EMAIL" == "0" || "$EMAIL" == "b" ]]; then return; fi
        done
    else
        echo " 1. 使用 Cloudflare DNS API 自动签发并无感续签 (推荐！域名托管在 CF 即可，无需 80/443)"
        echo " 2. 智能探测并复用本地宝塔/acme.sh 现成证书"
        echo " 3. 手动指定本地 fullchain.pem 与 privkey.pem 路径"
        echo " 0. 返回主菜单"
        read -rp "请选择证书方案 [1-3, 默认 1]: " cert_choice
        cert_choice="${cert_choice:-1}"
        if [[ "$cert_choice" == "0" || "$cert_choice" == "b" ]]; then return; fi

        if [[ "$cert_choice" == "1" ]]; then
            CERT_TYPE="cloudflare"
            echo -e "${YELLOW}提示: 前往 Cloudflare -> My Profile -> API Tokens -> 创建拥有 'Zone - DNS - Edit' 权限的 Token。${PLAIN}"
            read -rp "请输入 Cloudflare API Token: " CF_API_TOKEN
            if [[ "$CF_API_TOKEN" == "0" || "$CF_API_TOKEN" == "b" ]]; then return; fi
            while [[ -z "$CF_API_TOKEN" ]]; do
                read -rp "Token 不能为空，请重新输入: " CF_API_TOKEN
                if [[ "$CF_API_TOKEN" == "0" || "$CF_API_TOKEN" == "b" ]]; then return; fi
            done
        elif [[ "$cert_choice" == "2" ]]; then
            CERT_TYPE="local_file"
            detect_ssl_certs "$DOMAIN"
            if [[ -n "$FOUND_CERT" && -n "$FOUND_KEY" ]]; then
                log_info "智能检测到域名 [${DOMAIN}] 的有效证书！"
                echo "公钥路径: ${FOUND_CERT}"
                echo "私钥路径: ${FOUND_KEY}"
                read -rp "是否直接复用此证书？[Y/n]: " use_auto
                use_auto="${use_auto:-Y}"
                if [[ "$use_auto" =~ ^[Yy]$ ]]; then
                    TARGET_CERT="$FOUND_CERT"
                    TARGET_KEY="$FOUND_KEY"
                fi
            fi
            if [[ -z "$TARGET_CERT" ]]; then
                log_warn "未在常见目录扫描到该域名的证书，请手动输入路径。"
                cert_choice="3"
            fi
        fi

        if [[ "$cert_choice" == "3" ]]; then
            CERT_TYPE="local_file"
            read -rp "请输入证书公钥 (fullchain.pem/cer) 完整绝对路径: " TARGET_CERT
            if [[ "$TARGET_CERT" == "0" || "$TARGET_CERT" == "b" ]]; then return; fi
            while [[ ! -s "$TARGET_CERT" ]]; do
                read -rp "文件不存在或内容为空，请重新输入公钥路径: " TARGET_CERT
                if [[ "$TARGET_CERT" == "0" || "$TARGET_CERT" == "b" ]]; then return; fi
            done
            TARGET_CERT=$(resolve_symlink "$TARGET_CERT")

            read -rp "请输入证书私钥 (privkey.pem/key) 完整绝对路径: " TARGET_KEY
            if [[ "$TARGET_KEY" == "0" || "$TARGET_KEY" == "b" ]]; then return; fi
            while [[ ! -s "$TARGET_KEY" ]]; do
                read -rp "文件不存在或内容为空，请重新输入私钥路径: " TARGET_KEY
                if [[ "$TARGET_KEY" == "0" || "$TARGET_KEY" == "b" ]]; then return; fi
            done
            TARGET_KEY=$(resolve_symlink "$TARGET_KEY")
        fi
    fi

    # 6. 抗主动探测伪装站点设置
    echo -e "\n${BOLD}[步骤 6/6] 抗主动探测伪装站点设置${PLAIN}"
    echo " 1. 使用内置高仿真科技企业边缘网关页面 (推荐，开箱即用，最稳)"
    echo " 2. 反代宿主机本机 80 端口真实网站 (适合已有建站用户，探针看到与真实建站完全一致)"
    echo " 3. 反代任意外部指定网址 (例如: https://example.com)"
    echo " 0. 返回主菜单"
    read -rp "请选择伪装方式 [1-3, 默认 1]: " disguise_choice
    disguise_choice="${disguise_choice:-1}"
    if [[ "$disguise_choice" == "0" || "$disguise_choice" == "b" ]]; then return; fi

    DISGUISE_TYPE="builtin"
    DISGUISE_UPSTREAM=""
    if [[ "$disguise_choice" == "2" ]]; then
        DISGUISE_TYPE="local_80"
        DISGUISE_UPSTREAM="127.0.0.1:80"
    elif [[ "$disguise_choice" == "3" ]]; then
        DISGUISE_TYPE="custom"
        read -rp "请输入要反代的完整网址 (例如: https://www.bing.com): " DISGUISE_UPSTREAM
        if [[ "$DISGUISE_UPSTREAM" == "0" || "$DISGUISE_UPSTREAM" == "b" ]]; then return; fi
        while [[ -z "$DISGUISE_UPSTREAM" ]]; do
            read -rp "反代目标不能为空，请重新输入: " DISGUISE_UPSTREAM
            if [[ "$DISGUISE_UPSTREAM" == "0" || "$DISGUISE_UPSTREAM" == "b" ]]; then return; fi
        done
    fi

    # ---------------- 写入配置与构建 Caddyfile ----------------
    mkdir -p "${APP_DIR}/data" "${APP_DIR}/config" "${APP_DIR}/certs"

    # 全局 options 块 (牢固确立 order 顺序，避免静态服务拦截代理请求)
    local global_block=""
    if [[ "$MODE" == "standalone" ]]; then
        global_block="{
    order forward_proxy before file_server
    order forward_proxy before reverse_proxy
    servers {
        protocols h1 h2 h3
    }
}"
    elif [[ "$CERT_TYPE" == "cloudflare" ]]; then
        global_block="{
    order forward_proxy before file_server
    order forward_proxy before reverse_proxy
    servers {
        protocols h1 h2
    }
}"
    else
        global_block="{
    auto_https off
    order forward_proxy before file_server
    order forward_proxy before reverse_proxy
    servers {
        protocols h1 h2
    }
}"
    fi

    # 站点地址与 TLS 配置
    local site_addr=""
    local tls_directive=""
    if [[ "$MODE" == "standalone" ]]; then
        site_addr=":443, ${DOMAIN}"
        tls_directive="tls ${EMAIL}
    header {
        Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\"
        Alt-Svc 'h3=\":443\"; ma=2592000'
    }"
    else
        # 高位端口双监听，保证全源代理隧道成功
        site_addr=":${LISTEN_PORT}, ${DOMAIN}:${LISTEN_PORT}"
        if [[ "$CERT_TYPE" == "cloudflare" ]]; then
            tls_directive="tls {
        dns cloudflare {$CF_API_TOKEN}
    }"
        else
            tls_directive="tls /etc/caddy/certs/fullchain.pem /etc/caddy/certs/privkey.pem"
        fi
    fi

    # 伪装回落配置
    local backend_directive=""
    if [[ "$DISGUISE_TYPE" == "builtin" ]]; then
        backend_directive="root * /var/www/html
    file_server"
    elif [[ "$DISGUISE_TYPE" == "local_80" ]]; then
        backend_directive="reverse_proxy 127.0.0.1:80 {
        header_up Host {upstream_hostport}
    }"
    elif [[ "$DISGUISE_TYPE" == "custom" ]]; then
        backend_directive="reverse_proxy ${DISGUISE_UPSTREAM} {
        header_up Host {upstream_hostport}
    }"
    fi

    cat <<EOF > "${CADDY_FILE}"
${global_block}

${site_addr} {
    ${tls_directive}

    forward_proxy {
        basic_auth ${USERNAME} ${PASSWORD}
        hide_ip
        hide_via
        probe_resistance
    }

    ${backend_directive}
}
EOF

    # 生成 docker-compose.yml
    local cert_mounts=""
    if [[ "$CERT_TYPE" == "local_file" ]]; then
        cert_mounts="      - ${TARGET_CERT}:/etc/caddy/certs/fullchain.pem:ro
      - ${TARGET_KEY}:/etc/caddy/certs/privkey.pem:ro"
    fi

    local env_cf=""
    if [[ -n "$CF_API_TOKEN" ]]; then
        env_cf="      - CF_API_TOKEN=${CF_API_TOKEN}"
    fi

    local port_mapping=""
    if [[ "$MODE" == "standalone" ]]; then
        port_mapping="network_mode: host"
    else
        port_mapping="ports:
      - \"${LISTEN_PORT}:${LISTEN_PORT}\""
    fi

    cat <<EOF > "${COMPOSE_FILE}"
services:
  caddy:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    restart: always
    ${port_mapping}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./data:/data
      - ./config:/config
${cert_mounts}
    environment:
      - TZ=Asia/Shanghai
${env_cf}
EOF

    # 保存元数据
    cat <<EOF > "${ENV_FILE}"
DOMAIN=${DOMAIN}
MODE=${MODE}
LISTEN_PORT=${LISTEN_PORT}
CERT_TYPE=${CERT_TYPE}
CONTAINER_NAME=${CONTAINER_NAME}
IMAGE_NAME=${IMAGE_NAME}
APP_DIR=${APP_DIR}
EOF

    # 本地证书模式注入每日凌晨平滑重载
    if [[ "$CERT_TYPE" == "local_file" ]]; then
        local cron_cmd="0 3 * * * docker exec ${CONTAINER_NAME} caddy reload --config /etc/caddy/Caddyfile > /dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -F "${CONTAINER_NAME}") || (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    fi

    log_info "正在启动 NaiveProxy Caddy 容器服务..."
    $DOCKER_COMPOSE_CMD pull || true
    $DOCKER_COMPOSE_CMD up -d

    # 展示完整凭据与二维码
    show_user_credentials "${USERNAME}" "${PASSWORD}"
}

# ------------------------------------------------------------------------------
# 凭据与专属链接展示
# ------------------------------------------------------------------------------
show_user_credentials() {
    local target_user=$1
    local target_pass=$2

    load_env
    local ext_port="${LISTEN_PORT}"
    [[ "$MODE" == "standalone" ]] && ext_port=443

    # 生成优雅的节点备注 (归属国家-4位随机哈希)
    local region
    region=$(get_server_region)
    local rand_hash
    rand_hash=$(tr -dc a-z0-9 </dev/urandom | head -c 4)
    local node_remark="${region}-${rand_hash}"

    # 生成标准的全平台专属通用链接
    local standard_link="naive+https://${target_user}:${target_pass}@${DOMAIN}:${ext_port}?security=tls&sni=${DOMAIN}&type=tcp&headerType=none&padding=true#${node_remark}"

    echo -e "\n${GREEN}==================================================================${PLAIN}"
    echo -e "${GREEN}                  🎉 节点配置与连接信息展示                       ${PLAIN}"
    echo -e "${GREEN}==================================================================${PLAIN}"
    echo -e " 节点域名 (SNI)    : ${CYAN}${DOMAIN}${PLAIN}"
    echo -e " 认证用户 (User)   : ${CYAN}${target_user}${PLAIN}"
    echo -e " 认证密码 (Pass)   : ${CYAN}${target_pass}${PLAIN}"
    echo -e " 外部连接端口      : ${CYAN}${ext_port}${PLAIN}"
    echo -e " 节点备注名称      : ${CYAN}${node_remark}${PLAIN}"
    echo -e "${GREEN}------------------------------------------------------------------${PLAIN}"
    echo -e "${BOLD}【全平台导入专用链接 (一键复制到剪贴板直接导入客户端)】:${PLAIN}"
    echo -e "${YELLOW}${standard_link}${PLAIN}"

    # 渲染二维码
    display_qrcode "${standard_link}"

    echo -e "\n${GREEN}==================================================================${PLAIN}"

    read -rp "按任意键继续..." -n 1 -r
    echo ""
}

# ------------------------------------------------------------------------------
# 账号管理子系统
# ------------------------------------------------------------------------------
account_management_menu() {
    load_env
    if [[ ! -f "${CADDY_FILE}" ]]; then
        log_err "未在当前目录 [${APP_DIR}] 检测到 Caddyfile，请先完成安装！"
        read -rp "按回车键返回..."
        return
    fi

    while true; do
        clear
        echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${PLAIN}"
        echo -e "${CYAN}│              👤 NaiveProxy 用户账号与凭据管理               │${PLAIN}"
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${PLAIN}"
        echo -e "工作目录: ${GREEN}${APP_DIR}${PLAIN} | 容器: ${GREEN}${CONTAINER_NAME}${PLAIN}"
        echo ""
        echo " 1. 查看当前所有账号及连接链接 (含二维码)"
        echo " 2. 添加新用户账号 (即刻生效，长连接无中断)"
        echo " 3. 删除指定用户账号 (平滑生效，保留其他用户)"
        echo " 4. 修改现有用户密码"
        echo " 0. 返回主菜单"
        echo -e "${CYAN}─────────────────────────────────────────────────────────────${PLAIN}"
        read -rp "请输入操作编号 [0-4]: " sub_num

        case "$sub_num" in
            1) list_all_accounts ;;
            2) add_user_account ;;
            3) delete_user_account ;;
            4) modify_user_password ;;
            0|b) break ;;
            *) log_err "无效的输入编号！"; sleep 1 ;;
        esac
    done
}

list_all_accounts() {
    clear
    echo -e "\n${CYAN}---------------- 当前已配置的用户列表 ----------------${PLAIN}"
    local users=()
    local passes=()
    while read -r line; do
        if [[ "$line" =~ basic_auth[[:space:]]+([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]]; then
            users+=("${BASH_REMATCH[1]}")
            passes+=("${BASH_REMATCH[2]}")
        fi
    done < <(grep -E 'basic_auth[[:space:]]+' "${CADDY_FILE}")

    if [[ ${#users[@]} -eq 0 ]]; then
        log_warn "暂未查询到任何有效账号！"
        read -rp "按回车返回..."
        return
    fi

    for i in "${!users[@]}"; do
        echo -e "序号 $((i+1)) -> 用户名: ${GREEN}${users[$i]}${PLAIN} | 密码: ${YELLOW}${passes[$i]}${PLAIN}"
    done
    echo -e "${CYAN}-------------------------------------------------------${PLAIN}"

    read -rp "输入序号输出该用户的专属链接与二维码 [输入 0 或直接回车跳过]: " pick
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#users[@]} )); then
        local idx=$((pick-1))
        show_user_credentials "${users[$idx]}" "${passes[$idx]}"
    fi
}

add_user_account() {
    echo -e "\n${BOLD}【添加新用户账号】${PLAIN} (输入 0 或 b 随时取消)"
    local default_new_user="usr_$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
    local default_new_pass="$(tr -dc A-Za-z0-9#%_+ </dev/urandom | head -c 16)"

    read -rp "请输入新用户名 [回车默认: ${default_new_user}]: " new_user
    if [[ "$new_user" == "0" || "$new_user" == "b" ]]; then return; fi
    new_user="${new_user:-$default_new_user}"

    if grep -qE "basic_auth[[:space:]]+${new_user}[[:space:]]+" "${CADDY_FILE}"; then
        log_err "用户 [${new_user}] 已存在，无法重复添加！"
        read -rp "按回车返回..."
        return
    fi

    read -rp "请输入新用户密码 [回车默认: ${default_new_pass}]: " new_pass
    if [[ "$new_pass" == "0" || "$new_pass" == "b" ]]; then return; fi
    new_pass="${new_pass:-$default_new_pass}"

    sed -i "/forward_proxy {/a \        basic_auth ${new_user} ${new_pass}" "${CADDY_FILE}"
    docker exec "${CONTAINER_NAME}" caddy reload --config /etc/caddy/Caddyfile
    log_info "新用户 [${new_user}] 添加成功并已无损热重载生效！"

    show_user_credentials "${new_user}" "${new_pass}"
}

delete_user_account() {
    echo -e "\n${BOLD}【删除指定用户账号】${PLAIN} (输入 0 或 b 随时取消)"
    local users=()
    while read -r line; do
        if [[ "$line" =~ basic_auth[[:space:]]+([^[:space:]]+)[[:space:]]+ ]]; then
            users+=("${BASH_REMATCH[1]}")
        fi
    done < <(grep -E 'basic_auth[[:space:]]+' "${CADDY_FILE}")

    if [[ ${#users[@]} -le 1 ]]; then
        log_err "当前仅剩 1 个账号，为保证代理正常运作，禁止删除最后一个账号！"
        read -rp "按回车返回..."
        return
    fi

    echo "现有用户列表:"
    for i in "${!users[@]}"; do
        echo " $((i+1)). ${users[$i]}"
    done

    read -rp "请输入要删除的用户序号或用户名: " del_target
    if [[ "$del_target" == "0" || "$del_target" == "b" ]]; then return; fi

    local user_to_del=""
    if [[ "$del_target" =~ ^[0-9]+$ ]] && (( del_target >= 1 && del_target <= ${#users[@]} )); then
        user_to_del="${users[$((del_target-1))]}"
    else
        user_to_del="$del_target"
    fi

    if ! grep -qE "basic_auth[[:space:]]+${user_to_del}[[:space:]]+" "${CADDY_FILE}"; then
        log_err "未找到用户 [${user_to_del}]！"
        read -rp "按回车返回..."
        return
    fi

    sed -i "/basic_auth[[:space:]]\+${user_to_del}[[:space:]]\+/d" "${CADDY_FILE}"
    docker exec "${CONTAINER_NAME}" caddy reload --config /etc/caddy/Caddyfile
    log_info "用户 [${user_to_del}] 已成功删除并平滑生效！"
    sleep 1
}

modify_user_password() {
    echo -e "\n${BOLD}【修改现有用户密码】${PLAIN} (输入 0 或 b 随时取消)"
    local users=()
    while read -r line; do
        if [[ "$line" =~ basic_auth[[:space:]]+([^[:space:]]+)[[:space:]]+ ]]; then
            users+=("${BASH_REMATCH[1]}")
        fi
    done < <(grep -E 'basic_auth[[:space:]]+' "${CADDY_FILE}")

    echo "现有用户列表:"
    for i in "${!users[@]}"; do
        echo " $((i+1)). ${users[$i]}"
    done

    read -rp "请输入要修改密码的用户名或序号: " edit_target
    if [[ "$edit_target" == "0" || "$edit_target" == "b" ]]; then return; fi

    local edit_user=""
    if [[ "$edit_target" =~ ^[0-9]+$ ]] && (( edit_target >= 1 && edit_target <= ${#users[@]} )); then
        edit_user="${users[$((edit_target-1))]}"
    else
        edit_user="$edit_target"
    fi

    if ! grep -qE "basic_auth[[:space:]]+${edit_user}[[:space:]]+" "${CADDY_FILE}"; then
        log_err "未找到指定用户 [${edit_user}]！"
        read -rp "按回车返回..."
        return
    fi

    local gen_pass="$(tr -dc A-Za-z0-9#%_+ </dev/urandom | head -c 16)"
    read -rp "请输入新密码 [直接回车随机生成: ${gen_pass}]: " edit_pass
    if [[ "$edit_pass" == "0" || "$edit_pass" == "b" ]]; then return; fi
    edit_pass="${edit_pass:-$gen_pass}"

    sed -i "s/basic_auth[[:space:]]\+${edit_user}[[:space:]]\+[^[:space:]]\+/basic_auth ${edit_user} ${edit_pass}/" "${CADDY_FILE}"
    docker exec "${CONTAINER_NAME}" caddy reload --config /etc/caddy/Caddyfile
    log_info "用户 [${edit_user}] 密码已成功更新并热重载！"

    show_user_credentials "${edit_user}" "${edit_pass}"
}

# ------------------------------------------------------------------------------
# 运维主控制台
# ------------------------------------------------------------------------------
view_logs() {
    cd "${APP_DIR}"
    $DOCKER_COMPOSE_CMD logs -f
}

restart_service() {
    cd "${APP_DIR}"
    $DOCKER_COMPOSE_CMD restart
    log_info "NaiveProxy Caddy 容器已重启成功！"
    sleep 1
}

reload_caddy() {
    log_info "正在向 Caddy 注入平滑热重载指令..."
    docker exec "${CONTAINER_NAME}" caddy reload --config /etc/caddy/Caddyfile
    log_info "平滑热重载成功完成，现有长连接无中断！"
    sleep 1
}

# ------------------------------------------------------------------------------
# 版本检测与在线平滑升级模块
# ------------------------------------------------------------------------------
check_version_and_update() {
    echo -e "\n${CYAN}---------------- 正在检测线上最新发布版本 ----------------${PLAIN}"
    local latest_info
    latest_info=$(curl -s --max-time 5 "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)
    local latest_tag
    latest_tag=$(echo "$latest_info" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)

    if [[ -z "$latest_tag" ]]; then
        log_warn "未能获取到 GitHub 最新版本信息 (可能是网络波动或未发布 Release)。"
        echo -e "当前本地脚本版本: ${GREEN}${CURRENT_VERSION}${PLAIN}"
        read -rp "按回车键返回..."
        return
    fi

    echo -e " 本地脚本版本 : ${CYAN}${CURRENT_VERSION}${PLAIN}"
    echo -e " 线上最新版本 : ${GREEN}${latest_tag}${PLAIN}"

    # 精确版本大小比较引擎 (比较点分数字数组: 如 2026.10.21.1800 > 2026.10.21.1630)
    local has_update
    has_update=$(python3 -c "
import sys
def to_list(v):
    v = v.lstrip('v')
    res = []
    for s in v.replace('-', '.').split('.'):
        if s.isdigit():
            res.append(int(s))
        else:
            break
    return res

l_local = to_list(sys.argv[1])
l_remote = to_list(sys.argv[2])
# 如果两者前缀相同且长度相等，判定无更新
print('true' if l_remote > l_local else 'false')
" "${CURRENT_VERSION}" "${latest_tag}" 2>/dev/null || echo "false")

    if [[ "$has_update" != "true" || "${CURRENT_VERSION}" == "${latest_tag}" ]]; then
        log_info "当前已是最新版本，无需更新！"
        read -rp "按回车键返回..."
        return
    fi

    echo -e "\n${YELLOW}🔔 检测到有新版本发布 [${latest_tag}]！${PLAIN}"
    local body_log
    body_log=$(echo "$latest_info" | grep -A 10 '"body":' | head -n 8 | sed 's/\\r\\n/\n/g' | sed 's/\"body\": \"//' || true)
    if [[ -n "$body_log" ]]; then
        echo -e "${CYAN}【更新摘要】:${PLAIN}\n${body_log}\n"
    fi

    read -rp "是否立即执行在线平滑更新？[Y/n]: " do_update
    do_update="${do_update:-Y}"
    if [[ "$do_update" =~ ^[Yy]$ ]]; then
        local target_script="${SCRIPT_PATH}"
        if [[ -z "$target_script" || "$target_script" == "." || "$target_script" == "/" ]]; then
            target_script="${APP_DIR}/naive-manager.sh"
        fi

        log_info "正在下载最新脚本 [${target_script}]..."
        curl -fsSL "https://raw.githubusercontent.com/${GITHUB_REPO}/main/naive-manager.sh" -o "${target_script}"
        chmod +x "${target_script}"

        if [[ -f "${COMPOSE_FILE}" ]]; then
            log_info "正在拉取最新 Docker 镜像并平滑重启容器..."
            cd "${APP_DIR}"
            $DOCKER_COMPOSE_CMD pull || true
            $DOCKER_COMPOSE_CMD up -d --remove-orphans || true
        fi
        log_info "🎉 平滑升级完成！现有配置、证书及用户凭据完全保持不变。"
        read -rp "按回车键重新载入新版本..."
        exec bash "${target_script}"
    else
        log_info "已取消更新。"
        read -rp "按回车键返回..."
    fi
}

upgrade_image() {
    cd "${APP_DIR}"
    log_info "正在拉取最新底座镜像 [${IMAGE_NAME}]..."
    $DOCKER_COMPOSE_CMD pull
    log_info "正在平滑原地重建容器..."
    $DOCKER_COMPOSE_CMD up -d --remove-orphans
    log_info "镜像升级完成，配置、证书及账号信息保持不变！"
    sleep 1
}

uninstall_service() {
    read -rp "确定彻底停止并删除 Naive-Caddy 服务与当前目录配置数据？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        cd "${APP_DIR}"
        $DOCKER_COMPOSE_CMD down -v 2>/dev/null || true
        crontab -l 2>/dev/null | grep -v "${CONTAINER_NAME}" | crontab - || true
        rm -rf "${APP_DIR}/data" "${APP_DIR}/config" "${APP_DIR}/Caddyfile" "${APP_DIR}/docker-compose.yml" "${APP_DIR}/.env"
        log_info "Naive-Caddy 服务与本地配置已彻底清理卸载！"
        sleep 2
    else
        log_info "已取消卸载操作。"
        sleep 1
    fi
}

main_menu() {
    check_root
    check_dependencies

    while true; do
        clear
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${PLAIN}"
        echo -e "${CYAN}║                 🛡️  Naive-Caddy 服务管理面板                 ║${PLAIN}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${PLAIN}"
        echo -e " 📂 当前工作目录 : ${GREEN}${APP_DIR}${PLAIN}"
        echo -e " 🏷️  当前脚本版本 : ${CYAN}${CURRENT_VERSION}${PLAIN}"
        echo -e " 🐳 容器运行状态 : $(docker ps --format '{{.Names}} ({{.Status}})' | grep "${CONTAINER_NAME}" || echo -e "${RED}未运行${PLAIN}")"
        echo -e "${CYAN}──────────────────────────────────────────────────────────────${PLAIN}"
        echo -e "  ${BOLD}1.${PLAIN} 安装 / 重新配置节点 (全托管模式 / 独立高位端口模式)"
        echo -e "  ${BOLD}2.${PLAIN} 👤 节点账号与凭据管理 (查看链接/扫码二维码/增删改用户)"
        echo -e "  ${BOLD}3.${PLAIN} 🔔 检查版本与在线平滑更新 (检测 GitHub Release 与新镜像)"
        echo -e "  ${BOLD}4.${PLAIN} 查看实时连接与访问日志"
        echo -e "  ${BOLD}5.${PLAIN} 重启容器服务"
        echo -e "  ${BOLD}6.${PLAIN} 平滑热重载 Caddy 配置与证书 (内存级重载，长连接不断流)"
        echo -e "  ${BOLD}7.${PLAIN} 彻底卸载与清理服务"
        echo -e "  ${BOLD}0.${PLAIN} 退出控制台"
        echo -e "${CYAN}──────────────────────────────────────────────────────────────${PLAIN}"
        read -rp "请输入操作编号 [0-7]: " num

        case "$num" in
            1) install_or_reconfig ;;
            2) account_management_menu ;;
            3) check_version_and_update ;;
            4) view_logs ;;
            5) restart_service ;;
            6) reload_caddy ;;
            7) uninstall_service ;;
            0|q) clear; exit 0 ;;
            *) log_err "无效的输入编号！"; sleep 1 ;;
        esac
    done
}

main_menu
