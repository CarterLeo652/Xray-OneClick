#!/bin/bash
# shellcheck disable=SC2015

set -o pipefail

IKE_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IKE_LIB_RAW_BASE="${IKE_LIB_RAW_BASE:-https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/lib}"
IKE_LIB_MODULES=(
    "00-bootstrap.sh"
    "01-constants.sh"
    "02-output.sh"
    "20-paths.sh"
    "41-safety.sh"
    "21-config-base.sh"
    "31-service.sh"
    "30-xray-core.sh"
    "50-vless-common.sh"
    "54-ss2022.sh"
    "50-vless-enc.sh"
    "51-reality.sh"
    "52-xhttp.sh"
    "53-advanced.sh"
    "55-socks.sh"
    "63-diag.sh"
    "60-doctor.sh"
    "61-smoke.sh"
    "62-export.sh"
)

ike_ensure_lib_modules() {
    local root_dir="$1"
    local lib_dir="${root_dir}/lib"
    local module missing=()

    [[ -f "${lib_dir}/00-bootstrap.sh" && -f "${lib_dir}/21-config-base.sh" ]] && return 0

    mkdir -p "$lib_dir" || return 1
    for module in "${IKE_LIB_MODULES[@]}"; do
        [[ -f "${lib_dir}/${module}" ]] || missing+=("$module")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "Xray-OneClick: 缺少 lib/ 模块且无法下载（需要 curl 或 wget）。" >&2
        echo "请从完整仓库安装，或将 lib/ 目录与 install.sh 放在同一目录。" >&2
        return 1
    fi

    for module in "${missing[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${IKE_LIB_RAW_BASE}/${module}" -o "${lib_dir}/${module}" || return 1
        else
            wget -qO "${lib_dir}/${module}" "${IKE_LIB_RAW_BASE}/${module}" || return 1
        fi
    done
}

if ! ike_ensure_lib_modules "$IKE_INSTALLER_DIR"; then
    if [[ "$IKE_INSTALLER_DIR" != "/usr/local/share/ike" ]] && ike_ensure_lib_modules "/usr/local/share/ike"; then
        IKE_INSTALLER_DIR="/usr/local/share/ike"
    else
        exit 1
    fi
fi

# shellcheck source=lib/00-bootstrap.sh disable=SC1091
source "${IKE_INSTALLER_DIR}/lib/00-bootstrap.sh"

install_shortcut() {
    local script_source
    script_source="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

    mkdir -p "$(dirname "$SHORTCUT_PATH")" "$INSTALLER_DIR"

    if [[ -f "$script_source" && -r "$script_source" ]]; then
        if [[ "$script_source" != "$INSTALLER_PATH" ]]; then
            cp "$script_source" "$INSTALLER_PATH"
        fi
        if [[ -d "$(dirname "$script_source")/lib" ]]; then
            mkdir -p "${INSTALLER_DIR}/lib"
            cp -a "$(dirname "$script_source")/lib/." "${INSTALLER_DIR}/lib/"
        fi
        chmod +x "$INSTALLER_PATH"
    elif [[ ! -f "$INSTALLER_PATH" ]]; then
        cat >"$INSTALLER_PATH" <<EOF
#!/bin/bash
SCRIPT_URL="${RAW_SCRIPT_URL}"
TMP_SCRIPT="\$(mktemp)"
trap 'rm -f "\$TMP_SCRIPT"' EXIT
curl -fsSL "\$SCRIPT_URL" -o "\$TMP_SCRIPT" || exit 1
bash "\$TMP_SCRIPT" "\$@"
EOF
        chmod +x "$INSTALLER_PATH"
    fi

    cat >"$SHORTCUT_PATH" <<EOF
#!/bin/bash
if [[ ! -f "$INSTALLER_PATH" ]]; then
    echo "未找到安装器脚本 $INSTALLER_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec bash "$INSTALLER_PATH" "\$@"
EOF
    chmod +x "$SHORTCUT_PATH"

    cat >"$LEGACY_SHORTCUT_PATH" <<EOF
#!/bin/bash
echo "提示：快捷命令已更名为 ike，sb 仅作为兼容入口，将转发到 ike。" >&2
if [[ ! -x "$SHORTCUT_PATH" ]]; then
    echo "未找到主快捷命令 $SHORTCUT_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec "$SHORTCUT_PATH" "\$@"
EOF
    chmod +x "$LEGACY_SHORTCUT_PATH"
}

install_dependencies() {
    local missing=()
    local tool

    for tool in bash curl wget jq unzip tar openssl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    [[ ${#missing[@]} -eq 0 ]] && return 0

    info "[系统] 补全依赖: ${missing[*]}"

    case "$OS_TYPE" in
        alpine)
            apk update
            apk add bash curl wget unzip tar openssl ca-certificates jq coreutils iproute2 procps net-tools
            ;;
        ubuntu | debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y bash curl wget unzip tar openssl ca-certificates jq coreutils iproute2 procps
            ;;
        centos | rhel | rocky | almalinux | fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y bash curl wget unzip tar openssl ca-certificates jq coreutils iproute procps-ng
            else
                yum install -y epel-release >/dev/null 2>&1 || true
                yum install -y bash curl wget unzip tar openssl ca-certificates jq coreutils iproute procps-ng
            fi
            ;;
        *)
            err "[系统] 未识别的发行版: $OS_TYPE"
            err "请先手动安装: bash curl wget jq unzip openssl ca-certificates"
            return 1
            ;;
    esac
}

enable_bbr() {
    [[ "$OS_TYPE" == "alpine" ]] && return 0
    command -v sysctl >/dev/null 2>&1 || return 0

    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        return 0
    fi

    info "[系统] 尝试启用 BBR..."
    cat >/etc/sysctl.d/99-xray-installer-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-xray-installer-bbr.conf >/dev/null 2>&1 || true
}

prepare_system() {
    info "[系统] 环境: $OS_TYPE ($INIT_SYSTEM) / 架构: $ARCH / 核心: Xray"
    install_dependencies || return 1
    install_shortcut
    enable_bbr
}

preflight_root() {
    if [[ "${XRAY_ONECLICK_TEST_EUID:-$EUID}" -eq 0 ]]; then
        diag_ok "root 权限"
        return 0
    fi
    diag_fail "非 root：请使用 root 或 sudo 运行。"
    return 1
}

preflight_os() {
    local os_file="${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}"
    local id version pretty

    if [[ ! -f "$os_file" ]]; then
        diag_fail "未找到 os-release: $os_file"
        return 1
    fi
    id="$(grep -E '^ID=' "$os_file" | head -n 1 | cut -d= -f2- | tr -d '"')"
    version="$(grep -E '^VERSION_ID=' "$os_file" | head -n 1 | cut -d= -f2- | tr -d '"')"
    pretty="$(grep -E '^PRETTY_NAME=' "$os_file" | head -n 1 | cut -d= -f2- | tr -d '"')"
    case "$id" in
        debian | ubuntu)
            diag_ok "OS: ${pretty:-$id $version}"
            ;;
        *)
            diag_warn "OS: ${pretty:-${id:-unknown}}；脚本主推 Debian 12 / Ubuntu 22.04+，其它系统请谨慎验证。"
            ;;
    esac
}

preflight_arch() {
    local machine="${XRAY_ONECLICK_UNAME_M:-$(uname -m)}"

    case "$machine" in
        x86_64 | amd64)
            diag_ok "架构: amd64"
            ;;
        aarch64 | arm64)
            diag_ok "架构: arm64"
            ;;
        *)
            diag_fail "不支持的架构: $machine"
            return 1
            ;;
    esac
}

preflight_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        diag_fail "systemctl 不存在，当前脚本无法管理 xray.service。"
        return 1
    fi
    if [[ ! -d "${XRAY_ONECLICK_SYSTEMD_DIR:-/run/systemd/system}" ]]; then
        diag_fail "未检测到 systemd 运行目录 ${XRAY_ONECLICK_SYSTEMD_DIR:-/run/systemd/system}，不要写入不可用 service。"
        return 1
    fi
    diag_ok "systemd 可用"
}

preflight_disk() {
    local free_kb human

    free_kb="${XRAY_ONECLICK_DISK_FREE_KB:-$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')}"
    if [[ -z "$free_kb" || ! "$free_kb" =~ ^[0-9]+$ ]]; then
        diag_warn "无法读取根分区可用空间"
        return 0
    fi
    human="$(awk -v kb="$free_kb" 'BEGIN{if(kb>=1048576) printf "%.1fG", kb/1048576; else printf "%.0fM", kb/1024}')"
    if ((free_kb < MIN_ROOT_FREE_KB)); then
        diag_fail "根分区可用空间不足: ${human}，建议至少 200M；可清理 apt cache 或 journal。"
        return 1
    fi
    diag_ok "根分区可用空间: ${human}"
}

preflight_network_tools() {
    local missing_critical=()
    local missing_optional=()
    local tool

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing_critical+=("curl或wget")
    fi
    for tool in jq unzip openssl; do
        command -v "$tool" >/dev/null 2>&1 || missing_critical+=("$tool")
    done
    for tool in tar systemctl journalctl awk sed grep; do
        command -v "$tool" >/dev/null 2>&1 || missing_optional+=("$tool")
    done
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        missing_optional+=("ss或netstat")
    fi

    if ((${#missing_critical[@]} > 0)); then
        diag_fail "缺少关键依赖: ${missing_critical[*]}"
        return 1
    fi
    diag_ok "关键依赖可用"
    if ((${#missing_optional[@]} > 0)); then
        diag_warn "缺少可选工具: ${missing_optional[*]}"
    else
        diag_ok "常用诊断工具可用"
    fi
}

preflight_ports() {
    if command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1; then
        diag_ok "端口监听检测工具可用"
    else
        diag_warn "ss/netstat 未安装，将跳过监听检测"
    fi
}

print_preflight_summary() {
    echo -e "\n${YELLOW}系统预检${PLAIN}"
    echo "----------------------------------------"
}

preflight_system() {
    local failed="false"

    print_preflight_summary
    preflight_root || failed="true"
    preflight_os || failed="true"
    preflight_systemd || failed="true"
    preflight_arch || failed="true"
    preflight_disk || failed="true"
    preflight_network_tools || failed="true"
    preflight_ports || true
    [[ "$failed" != "true" ]]
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((port >= 1 && port <= 65535)) || return 1
    return 0
}

check_port() {
    local port="$1"

    if env_truthy "${IKE_TEST_MODE:-}"; then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        ss -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 1
    elif [[ "${PORT_CHECK_WARNING_SHOWN:-false}" != "true" ]]; then
        info "[提示] 未找到 ss/netstat，跳过系统监听端口检测，仅检查 config.json。"
        PORT_CHECK_WARNING_SHOWN="true"
    fi
    return 0
}

warn_reserved_port() {
    local port="$1"
    if ((port < 1024)); then
        info "[提示] ${port} 属于系统保留端口，请确认是否有冲突。"
    fi
    case "$port" in
        22 | 53 | 80 | 123 | 443 | 3306 | 5432 | 6379 | 8080)
            info "[提示] ${port} 是常见服务端口，请确认不会影响现有业务。"
            ;;
    esac
}

ask_port() {
    local prompt="$1"
    local default_port="$2"
    local __resultvar="$3"
    local input use_anyway

    while true; do
        read -r -p "${prompt} (默认: ${default_port}): " input
        input="${input:-$default_port}"

        if ! validate_port "$input"; then
            err "端口无效，请输入 1-65535 之间的数字。"
            continue
        fi

        if ! check_port "$input"; then
            info "[提示] 端口 ${input} 当前可能已被占用。"
            read -r -p "仍然写入配置? [y/N]: " use_anyway
            [[ "$use_anyway" =~ ^[yY]$ ]] || continue
        fi

        warn_reserved_port "$input"
        printf -v "$__resultvar" '%s' "$input"
        return 0
    done
}

detect_global_ipv6() {
    if [[ ${XRAY_ONECLICK_TEST_GLOBAL_IPV6+x} ]]; then
        printf '%s' "$XRAY_ONECLICK_TEST_GLOBAL_IPV6"
        [[ -n "$XRAY_ONECLICK_TEST_GLOBAL_IPV6" ]]
        return
    fi
    command -v ip >/dev/null 2>&1 || return 1
    ip -o -6 addr show scope global 2>/dev/null |
        awk '$0 !~ / tentative| dadfailed| deprecated/ {
          for (i = 1; i <= NF; i++) {
            if ($i == "inet6") {
              split($(i + 1), addr, "/")
              print addr[1]
              exit
            }
          }
        }'
}

is_system_ipv6_disabled() {
    local all_value default_value

    if [[ ${XRAY_ONECLICK_TEST_IPV6_DISABLE_ALL+x} ]]; then
        all_value="$XRAY_ONECLICK_TEST_IPV6_DISABLE_ALL"
    else
        all_value="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
    fi
    if [[ ${XRAY_ONECLICK_TEST_IPV6_DISABLE_DEFAULT+x} ]]; then
        default_value="$XRAY_ONECLICK_TEST_IPV6_DISABLE_DEFAULT"
    else
        default_value="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)"
    fi

    [[ "$all_value" == "1" || "$default_value" == "1" ]]
}

check_ipv6_status() {
    local ipv6_global_addr

    ipv6_global_addr="$(detect_global_ipv6 || true)"
    if [[ -n "$ipv6_global_addr" ]]; then
        if is_system_ipv6_disabled; then
            info "[IPv6] sysctl 显示 disable_ipv6=1，但检测到全局 IPv6 地址：${ipv6_global_addr}，按实际地址继续。"
        fi
        ok "[IPv6] 可用，检测到全局地址: ${ipv6_global_addr}"
        return 0
    fi

    if is_system_ipv6_disabled; then
        err "[IPv6] 系统未开启 IPv6，且未检测到全局 IPv6 地址。"
        return 1
    fi

    err "[IPv6] 未检测到全局 IPv6 地址，无法生成可用节点。"
    return 1
}

b64_no_wrap() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w 0
    else
        base64 | tr -d '\n'
    fi
}

b64_url_no_pad() {
    b64_no_wrap | tr '+/' '-_' | sed 's/=*$//'
}

url_encode() {
    MSYS2_ENV_CONV_EXCL="URL_ENCODE_VALUE" URL_ENCODE_VALUE="$1" jq -rn 'env.URL_ENCODE_VALUE|@uri'
}

json_url_encode() {
    jq -crn --argjson v "$1" '$v | tojson | @uri'
}

generate_uuid() {
    local uuid

    if [[ -x "$BIN_PATH" ]]; then
        uuid="$("$BIN_PATH" uuid 2>/dev/null | tr -d '\r\n' || true)"
        if [[ -n "$uuid" ]]; then
            printf '%s' "$uuid"
            return 0
        fi
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        uuid="$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')"
        if [[ -n "$uuid" ]]; then
            printf '%s' "$uuid"
            return 0
        fi
    fi
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        tr -d '\r\n' </proc/sys/kernel/random/uuid
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
        return 0
    fi
    return 1
}

port_used_in_config() {
    local port="$1"

    [[ -f "$CONFIG_FILE" ]] || return 1
    validate_port "$port" || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --argjson port "$port" 'any(.inbounds[]?; (.port? // empty) == $port)' "$CONFIG_FILE" >/dev/null 2>&1
}

random_free_port() {
    local min="$1"
    local max="$2"
    local span port rand attempt

    validate_port "$min" || return 1
    validate_port "$max" || return 1
    ((min <= max)) || return 1
    span=$((max - min + 1))

    for ((attempt = 0; attempt < 200; attempt++)); do
        if command -v openssl >/dev/null 2>&1; then
            rand=$((16#$(openssl rand -hex 2)))
        else
            rand=$RANDOM
        fi
        port=$((min + rand % span))
        if ! port_used_in_config "$port" && check_port "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done

    for ((port = min; port <= max; port++)); do
        if ! port_used_in_config "$port" && check_port "$port"; then
            printf '%s' "$port"
            return 0
        fi
    done

    return 1
}

split_endpoint_for_link() {
    local local_port="$1"
    local preferred_host="${2:-}"
    local custom endpoint host port

    custom="$(endpoint_custom_value)"
    if [[ -n "$custom" ]]; then
        if [[ "$custom" =~ ^(\[[^]]+\]):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        elif [[ "$custom" =~ ^([^:]+):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        else
            host="$custom"
            port="$local_port"
        fi
    elif [[ -n "$preferred_host" ]]; then
        host="$preferred_host"
        port="$local_port"
    elif [[ -n "${IPV4_HOST:-}" ]]; then
        host="$IPV4_HOST"
        port="$local_port"
    elif [[ -n "${IPV6_HOST:-}" ]]; then
        host="$IPV6_HOST"
        port="$local_port"
    else
        endpoint="$(endpoint_auto_value || true)"
        host="${endpoint:-YOUR_SERVER}"
        port="$local_port"
    fi

    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        host="[${host}]"
    fi
    printf '%s\t%s' "$host" "$port"
}

protocol_listen_scope() {
    local listen="${1:-}"

    case "$listen" in
        "")
            printf '%s' "unknown"
            ;;
        "0.0.0.0" | 127.*)
            printf '%s' "ipv4"
            ;;
        "::" | "[::]")
            printf '%s' "dual"
            ;;
        *:*)
            printf '%s' "ipv6"
            ;;
        *.*)
            printf '%s' "ipv4"
            ;;
        *)
            printf '%s' "unknown"
            ;;
    esac
}

config_inbound_listen_scope() {
    local tag="$1"
    local listen

    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "unknown"
        return 0
    }
    listen="$(jq -r --arg tag "$tag" '.inbounds[]? | select(.tag == $tag).listen // empty' "$CONFIG_FILE" 2>/dev/null | head -n 1)"
    protocol_listen_scope "$listen"
}

state_listen_scope() {
    local state_key="$1"
    local scope

    [[ -n "$state_key" && -f "$STATE_FILE" ]] || return 1
    scope="$(jq -r --arg key "$state_key" '.[$key].listen_scope // empty' "$STATE_FILE" 2>/dev/null)"
    [[ -n "$scope" && "$scope" != "null" ]] || return 1
    printf '%s' "$scope"
}

inbound_supports_ipv6() {
    local tag="$1"
    local state_key="${2:-}"
    local scope

    scope="$(state_listen_scope "$state_key" 2>/dev/null || true)"
    [[ -n "$scope" ]] || scope="$(config_inbound_listen_scope "$tag")"
    [[ "$scope" == "ipv6" || "$scope" == "dual" ]]
}

should_print_ipv6_link() {
    local mode="$1"
    local tag="$2"
    local state_key="${3:-}"

    [[ "$mode" == "dual" || "$mode" == "ipv6" ]] || return 1
    [[ -n "${IPV6_HOST:-}" ]] || return 1
    inbound_supports_ipv6 "$tag" "$state_key"
}

print_ipv6_status_hint() {
    local tag="$1"
    local state_key="${2:-}"

    if [[ -z "${IPV6_HOST:-}" ]]; then
        echo "IPv6链接: 未输出（未检测到全局 IPv6 endpoint）"
    elif ! inbound_supports_ipv6 "$tag" "$state_key"; then
        echo "IPv6链接: 未输出（当前协议未监听 IPv6）"
    else
        echo "IPv6链接: 未输出（当前链接显示模式未启用 IPv6）"
    fi
}

link_endpoint_for_tag() {
    local port="$1"
    local tag="$2"
    local state_key="${3:-}"
    local mode="${CURRENT_LINK_VIEW_MODE:-dual}"

    case "$mode" in
        ipv6)
            if should_print_ipv6_link "$mode" "$tag" "$state_key"; then
                split_endpoint_for_link "$port" "$IPV6_HOST"
            else
                printf '%s\t%s' "YOUR_SERVER" "$port"
            fi
            ;;
        ipv4)
            split_endpoint_for_link "$port" "${IPV4_HOST:-}"
            ;;
        *)
            split_endpoint_for_link "$port"
            ;;
    esac
}








get_public_addresses() {
    PUBLIC_IPV4="$(detect_public_ip "4" | awk -F '\t' 'NF{print $1; exit}')"
    PUBLIC_IPV6="$(detect_public_ip "6" | awk -F '\t' 'NF{print $1; exit}')"

    [[ -n "$PUBLIC_IPV6" ]] || PUBLIC_IPV6="$(detect_global_ipv6 || true)"
    if [[ -z "$PUBLIC_IPV4" ]]; then
        PUBLIC_IPV4="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi
}

detect_public_ip() {
    local version="$1"
    local curl_flag="-4"
    local source result
    local sources=(
        "https://api.ipify.org"
        "https://ipinfo.io/ip"
        "https://ifconfig.me"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
    )

    [[ "$version" == "6" ]] && curl_flag="-6"
    command -v curl >/dev/null 2>&1 || return 0

    for source in "${sources[@]}"; do
        result="$(curl -sS "$curl_flag" --max-time 5 "$source" 2>/dev/null | tr -d '\r' | awk 'NF{print; exit}' || true)"
        [[ -n "$result" ]] || continue
        if [[ "$version" == "4" && "$result" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\t%s\n' "$result" "$source"
            continue
        fi
        if [[ "$version" == "6" && "$result" == *:* ]]; then
            printf '%s\t%s\n' "$result" "$source"
            continue
        fi
    done | awk -F '\t' '!seen[$1]++'
}

endpoint_custom_value() {
    [[ -f "$STATE_FILE" ]] || return 0
    jq -r '.endpoint.custom // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

endpoint_updated_at() {
    [[ -f "$STATE_FILE" ]] || return 0
    jq -r '.endpoint.updated_at // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

state_set_endpoint() {
    local endpoint="$1"
    local timestamp tmp

    init_state
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(mktemp)" || return 1
    if ! jq --arg endpoint "$endpoint" --arg timestamp "$timestamp" '
      .endpoint = {
        custom: $endpoint,
        updated_at: $timestamp
      }
    ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [Endpoint] 写入状态文件失败。"
        return 1
    fi
    mv "$tmp" "$STATE_FILE"
    ensure_config_security
}

state_clear_endpoint() {
    local tmp

    init_state
    tmp="$(mktemp)" || return 1
    if ! jq 'del(.endpoint.custom) | .endpoint.updated_at = ""' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [Endpoint] 清理状态文件失败。"
        return 1
    fi
    mv "$tmp" "$STATE_FILE"
    ensure_config_security
}

endpoint_has_explicit_port() {
    local endpoint="$1"

    [[ "$endpoint" =~ ^\[[^]]+\]:[0-9]+$ || "$endpoint" =~ ^[^:]+:[0-9]+$ ]]
}

endpoint_auto_value() {
    local first

    if [[ -n "${ENDPOINT_AUTO_OVERRIDE:-}" ]]; then
        printf '%s' "$ENDPOINT_AUTO_OVERRIDE"
        return 0
    fi
    if [[ -n "${ENDPOINT_AUTO_CACHE:-}" ]]; then
        printf '%s' "$ENDPOINT_AUTO_CACHE"
        return 0
    fi

    first="$(detect_public_ip "4" | awk -F '\t' 'NF{print $1; exit}')"
    if [[ -n "$first" ]]; then
        ENDPOINT_AUTO_CACHE="$first"
        printf '%s' "$first"
        return 0
    fi
    first="$(detect_public_ip "6" | awk -F '\t' 'NF{print $1; exit}')"
    if [[ -n "$first" ]]; then
        ENDPOINT_AUTO_CACHE="[$first]"
        printf '%s' "$ENDPOINT_AUTO_CACHE"
        return 0
    fi
    return 1
}

tunnel_connection_entry() {
    local listen_port="$1"
    local endpoint custom

    custom="$(endpoint_custom_value)"
    if [[ -n "$custom" ]]; then
        if endpoint_has_explicit_port "$custom"; then
            printf '%s%s' "$custom" "（自定义 endpoint 已含端口，请确认 NAT 映射端口）"
        else
            printf '%s:%s' "$custom" "$listen_port"
        fi
        return 0
    fi

    endpoint="$(endpoint_auto_value || true)"
    if [[ -n "$endpoint" ]]; then
        printf '%s:%s' "$endpoint" "$listen_port"
    else
        printf '%s' "请手动设置 ike endpoint set"
    fi
}

endpoint_detect_command() {
    local line ip source found="false"

    echo -e "\n${YELLOW}[Endpoint] IPv4 探测结果${PLAIN}"
    while IFS=$'\t' read -r ip source; do
        [[ -n "$ip" ]] || continue
        found="true"
        echo "- ${ip} (${source})"
    done < <(detect_public_ip "4")
    [[ "$found" == "true" ]] || echo "- 未检测到 IPv4"

    found="false"
    echo -e "\n${YELLOW}[Endpoint] IPv6 探测结果${PLAIN}"
    while IFS=$'\t' read -r ip source; do
        [[ -n "$ip" ]] || continue
        found="true"
        echo "- ${ip} (${source})"
    done < <(detect_public_ip "6")
    [[ "$found" == "true" ]] || echo "- 未检测到 IPv6"
}

endpoint_show_command() {
    local custom updated auto

    init_state
    custom="$(endpoint_custom_value)"
    updated="$(endpoint_updated_at)"
    if [[ -n "$custom" ]]; then
        echo "当前自定义 endpoint: $custom"
        [[ -n "$updated" ]] && echo "更新时间: $updated"
        if endpoint_has_explicit_port "$custom"; then
            echo "提示: 当前 endpoint 已包含端口，Tunnel 列表不会自动拼接本地监听端口。"
        fi
        return 0
    fi

    auto="$(endpoint_auto_value || true)"
    if [[ -n "$auto" ]]; then
        echo "当前未设置自定义 endpoint，自动检测: $auto"
    else
        echo "当前未设置自定义 endpoint，自动检测失败。"
        echo "建议运行: ike endpoint set"
    fi
}

endpoint_set_command() {
    local endpoint

    read -r -p "自定义连接地址，例如 1.2.3.4 / example.com / domain.com:外部端口: " endpoint
    endpoint="${endpoint//$'\r'/}"
    if [[ -z "$endpoint" || "$endpoint" =~ [[:space:]] ]]; then
        err "[失败] [Endpoint] 地址不能为空，且不能包含空白字符。"
        return 1
    fi
    state_set_endpoint "$endpoint" || return 1
    state_set_meta_action "设置 Endpoint" || err "[状态] 最近变更记录失败。"
    ok "[完成] 自定义 endpoint 已设置: $endpoint"
}

endpoint_clear_command() {
    state_clear_endpoint || return 1
    state_set_meta_action "清除 Endpoint" || err "[状态] 最近变更记录失败。"
    ok "[完成] 自定义 endpoint 已清除。"
}

env_truthy() {
    local value="${1:-}"

    case "${value,,}" in
        1 | true | yes | y | on) return 0 ;;
        *) return 1 ;;
    esac
}

tunnel_import_auto_yes_enabled() {
    env_truthy "${XRAY_ONECLICK_YES:-}" || env_truthy "${XRAY_ONECLICK_TUNNEL_IMPORT_YES:-}"
}

apply_env_endpoint_if_needed() {
    local endpoint="${XRAY_ONECLICK_ENDPOINT:-}"

    [[ -n "$endpoint" ]] || return 0
    endpoint="${endpoint//$'\r'/}"
    if [[ -z "$endpoint" || "$endpoint" =~ [[:space:]] ]]; then
        err "[失败] [Endpoint] XRAY_ONECLICK_ENDPOINT 不能为空，且不能包含空白字符。"
        return 1
    fi
    if [[ "$endpoint" == *\"* || "$endpoint" == *\\* ]]; then
        err "[失败] [Endpoint] XRAY_ONECLICK_ENDPOINT 不能包含引号或反斜杠。"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        mkdir -p "$CONFIG_DIR"
        if [[ -s "$STATE_FILE" ]]; then
            info "[Endpoint] 缺少 jq，已保留现有 state，暂不覆盖 endpoint。"
            return 0
        fi
        cat >"$STATE_FILE" <<EOF
{
  "endpoint": {
    "custom": "$endpoint",
    "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
        ensure_config_security
        ok "[Endpoint] 已从环境变量设置连接入口: $endpoint"
        return 0
    fi

    init_state
    if [[ -n "$(endpoint_custom_value)" ]]; then
        return 0
    fi

    state_set_endpoint "$endpoint" || return 1
    state_set_meta_action "设置 Endpoint" || err "[状态] 最近变更记录失败。"
    ok "[Endpoint] 已从环境变量设置连接入口: $endpoint"
}

get_local_addresses() {
    PUBLIC_IPV4="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./{print; exit}')"
    PUBLIC_IPV6="$(detect_global_ipv6 || true)"
}

host_candidates() {
    local mode="${1:-dual}"
    IPV4_HOST=""
    IPV6_HOST=""

    case "$mode" in
        ipv4)
            [[ -n "$PUBLIC_IPV4" ]] && IPV4_HOST="$PUBLIC_IPV4"
            ;;
        ipv6)
            [[ -n "$PUBLIC_IPV6" ]] && IPV6_HOST="[${PUBLIC_IPV6}]"
            ;;
        *)
            [[ -n "$PUBLIC_IPV4" ]] && IPV4_HOST="$PUBLIC_IPV4"
            [[ -n "$PUBLIC_IPV6" ]] && IPV6_HOST="[${PUBLIC_IPV6}]"
            ;;
    esac
}


resource_file_status() {
    if [[ -f "$1" ]]; then
        printf '%s' "存在"
    else
        printf '%s' "不存在"
    fi
}

xray_config_test_status() {
    local log_file

    [[ -x "$BIN_PATH" ]] || {
        printf '%s' "未检测到 xray"
        return 0
    }
    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "失败"
        return 0
    }

    log_file="$(mktemp)" || {
        printf '%s' "失败"
        return 0
    }
    if "$BIN_PATH" run -test -c "$CONFIG_FILE" >"$log_file" 2>&1; then
        rm -f "$log_file"
        printf '%s' "通过"
    else
        rm -f "$log_file"
        printf '%s' "失败"
    fi
}

xray_service_status() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            printf '%s' "运行中"
        else
            printf '%s' "未运行"
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        if rc-service "$SERVICE_NAME" status 2>/dev/null | grep -qiE 'started|running'; then
            printf '%s' "运行中"
        else
            printf '%s' "未运行"
        fi
    else
        printf '%s' "未检测到 systemd/openrc"
    fi
}

print_apply_failure_hint() {
    local scope="${1:-proxy}"

    err "[建议] 可先执行: ike doctor ${scope}"
    err "[建议] 可再执行: ike smoke ${scope}"
    err "[建议] 查看最近日志: journalctl -u xray -n 80 --no-pager"
}

print_finalmask_failure_hint() {
    err "[建议] FinalMask 属于高级兼容功能；如校验或客户端导入失败，优先重试: ike xhttp install --finalmask off"
    err "[建议] 检查当前 Xray-core 版本是否支持所用 XHTTP/FinalMask schema。"
}

print_reality_failure_hint() {
    err "[Reality] 修复建议:"
    err "  - 检查 SNI 是否为纯域名且 DOMAIN:443 可达。"
    err "  - 检查入口端口和 defender 端口是否被占用。"
    print_apply_failure_hint "reality"
}

print_xhttp_failure_hint() {
    err "[XHTTP] 修复建议:"
    err "  - 检查 path 是否以 / 开头，且不含空格、?、# 或反斜杠。"
    err "  - 检查 xray-core 版本是否支持 VLESS Encryption / XHTTP / FinalMask。"
    if [[ "${XHTTP_FINALMASK_ENABLED:-false}" == "true" ]]; then
        print_finalmask_failure_hint
    fi
    print_apply_failure_hint "xhttp"
}

random_short_suffix() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 2
    else
        printf '%04x' "$((RANDOM % 65536))"
    fi
}

port_in_csv() {
    local port="$1"
    local csv="$2"
    local item
    local -a _port_items

    IFS=',' read -ra _port_items <<<"$csv"
    for item in "${_port_items[@]}"; do
        [[ "$port" == "$item" ]] && return 0
    done
    return 1
}

is_private_target_address() {
    local target="${1,,}"
    local ip a b _unused_c _unused_d

    target="${target#[}"
    target="${target%]}"
    ip="${target%%/*}"

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r a b _unused_c _unused_d <<<"$ip"
        a=$((10#$a))
        b=$((10#$b))
        if ((a == 10 || a == 127)); then
            return 0
        fi
        if ((a == 172 && b >= 16 && b <= 31)); then
            return 0
        fi
        if ((a == 192 && b == 168)); then
            return 0
        fi
        if ((a == 169 && b == 254)); then
            return 0
        fi
        if ((a == 100 && b >= 64 && b <= 127)); then
            return 0
        fi
        return 1
    fi

    case "$ip" in
        ::1 | 0:0:0:0:0:0:0:1 | fc*:* | fd*:* | fe80:*)
            return 0
            ;;
    esac

    return 1
}

confirm_yes_no() {
    local prompt="$1"
    local default_answer="${2:-n}"
    local answer normalized suffix

    if [[ "${default_answer,,}" == "y" || "${default_answer,,}" == "yes" ]]; then
        suffix="[Y/n]"
        default_answer="y"
    else
        suffix="[y/N]"
        default_answer="n"
    fi

    while true; do
        read -r -p "${prompt} ${suffix}: " answer
        normalized="${answer,,}"
        if [[ -z "$normalized" ]]; then
            [[ "$default_answer" == "y" ]]
            return $?
        fi
        case "$normalized" in
            y | yes) return 0 ;;
            n | no) return 1 ;;
            *) err "请输入 y/yes 或 n/no。" ;;
        esac
    done
}

confirm_dangerous_action() {
    local prompt="$1"

    confirm_yes_no "${prompt} 输入 y/yes 继续，默认取消" "n"
}

confirm_forward_warning() {
    local message="$1"

    info "[提示] $message"
    confirm_yes_no "是否继续?" "n"
}

confirm_forward_safety_warnings() {
    if [[ "${FORWARD_MODE:-safe}" == "relay" ]]; then
        confirm_forward_relay_warnings
        return $?
    fi

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS"; then
        confirm_forward_warning "目标端口属于默认安全屏蔽范围，转发可能无法工作。" || return 1
    fi

    if port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS"; then
        confirm_forward_warning "目标端口属于增强安全屏蔽范围，如果增强安全屏蔽已启用，转发可能无法工作。" || return 1
    fi

    if is_private_target_address "$FORWARD_TARGET"; then
        confirm_forward_warning "目标地址可能属于私网，当前默认安全屏蔽可能会阻断该转发。" || return 1
    fi

    return 0
}

confirm_forward_relay_warnings() {
    local risky="false"

    info "[提示] 专用中转模式会为该转发规则添加 inboundTag -> direct 放行规则，可能绕过默认安全屏蔽，仅建议用于可信固定目标。"
    confirm_dangerous_action "是否继续?" || return 1

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS" ||
        port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS" ||
        is_private_target_address "$FORWARD_TARGET"; then
        risky="true"
    fi

    if [[ "$risky" == "true" ]]; then
        info "[提示] 目标命中高风险端口或私网地址；relay 模式会为该 forward inbound 使用 direct 放行。"
        confirm_dangerous_action "请再次确认是否继续?" || return 1
    fi

    return 0
}

validate_forward_network() {
    case "$1" in
        tcp | udp | tcp,udp) return 0 ;;
        *) return 1 ;;
    esac
}

validate_forward_mode() {
    case "$1" in
        safe | relay) return 0 ;;
        *) return 1 ;;
    esac
}

is_tunnel_managed_tag() {
    case "$1" in
        "${TUNNEL_TAG_PREFIX}"* | "${LEGACY_FORWARD_TAG_PREFIX}"*) return 0 ;;
        *) return 1 ;;
    esac
}

normalize_tunnel_type() {
    case "${1:-single}" in
        single | portMap) printf '%s' "${1:-single}" ;;
        *) printf '%s' "single" ;;
    esac
}

probe_tunnel_protocol() {
    local tmp

    [[ -x "$BIN_PATH" ]] || return 0
    tmp="$(mktemp)" || return 0
    cat >"$tmp" <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "tunnel-probe",
      "listen": "127.0.0.1",
      "port": 9,
      "protocol": "tunnel",
      "settings": {
        "address": "127.0.0.1",
        "port": 9,
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" }
  ]
}
JSON

    if "$BIN_PATH" run -test -c "$tmp" >/dev/null 2>&1; then
        TUNNEL_PROTOCOL="tunnel"
    else
        TUNNEL_PROTOCOL="dokodemo-door"
    fi
    rm -f "$tmp"
}

forward_scenario_defaults() {
    local scenario="$1"

    case "$scenario" in
        map)
            FORWARD_SCENARIO_TITLE="多端口落地组（portMap / fallback 多条 single）"
            FORWARD_SCENARIO_MODE="relay"
            FORWARD_SCENARIO_NETWORK="tcp,udp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        public)
            FORWARD_SCENARIO_TITLE="普通公网转发（safe/tcp）"
            FORWARD_SCENARIO_MODE="safe"
            FORWARD_SCENARIO_NETWORK="tcp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        landing)
            FORWARD_SCENARIO_TITLE="单端口落地中转（relay/tcp,udp）"
            FORWARD_SCENARIO_MODE="relay"
            FORWARD_SCENARIO_NETWORK="tcp,udp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        lan)
            FORWARD_SCENARIO_TITLE="内网服务暴露（relay/tcp）"
            FORWARD_SCENARIO_MODE="relay"
            FORWARD_SCENARIO_NETWORK="tcp"
            FORWARD_SCENARIO_LOCK_NETWORK="true"
            ;;
        udp)
            FORWARD_SCENARIO_TITLE="UDP 游戏/语音转发"
            FORWARD_SCENARIO_MODE="safe"
            FORWARD_SCENARIO_NETWORK="udp"
            FORWARD_SCENARIO_LOCK_NETWORK="false"
            ;;
        custom)
            FORWARD_SCENARIO_TITLE="自定义高级转发"
            FORWARD_SCENARIO_MODE="safe"
            FORWARD_SCENARIO_NETWORK="tcp,udp"
            FORWARD_SCENARIO_LOCK_NETWORK="false"
            ;;
        *)
            err "[失败] [端口转发] 未知场景: $scenario"
            return 1
            ;;
    esac
}

forward_tag_exists() {
    local tag="$1"

    if [[ -f "$CONFIG_FILE" ]] && jq -e --arg tag "$tag" 'any(.inbounds[]?; .tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi
    if [[ -f "$STATE_FILE" ]] && jq -e --arg tag "$tag" '
      any(((.tunnels // []) + (.forwards // []))[]?; .tag == $tag)
    ' "$STATE_FILE" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

generate_forward_tag() {
    local base first_port

    if [[ "${FORWARD_TYPE:-single}" == "portMap" ]]; then
        first_port="${FORWARD_LISTEN_PORT%%,*}"
        base="${TUNNEL_TAG_PREFIX}map-${first_port}"
    else
        base="${FORWARD_TAG_PREFIX}${FORWARD_LISTEN_PORT}-${FORWARD_TARGET_PORT}"
    fi
    FORWARD_TAG="$(generate_unique_forward_tag_from_base "$base")"
}

generate_unique_forward_tag_from_base() {
    local base="$1"
    local suffix tag

    [[ -n "$base" ]] || {
        err "[失败] [端口转发] 生成 tag 失败：base 为空。"
        return 1
    }
    tag="$base"
    while forward_tag_exists "$tag"; do
        suffix="$(random_short_suffix)"
        tag="${base}-${suffix}"
    done
    printf '%s' "$tag"
}

forward_rule_lines() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
      def managed_tag:
        ((.tag // "") | startswith($tunnel_prefix)) or
        ((.tag // "") | startswith($legacy_prefix));
      def tunnel_protocol: (.protocol == "dokodemo-door" or .protocol == "tunnel");
      .inbounds[]? |
      select(managed_tag) |
      select(tunnel_protocol) |
      [
        .tag,
        (.listen // "0.0.0.0"),
        (.port | tostring),
        (.settings.address // ""),
        (.settings.port | tostring),
        (.settings.network // "tcp"),
        (if (.settings.portMap // null) then "portMap" else "single" end)
      ] | join("\u001f")
    ' "$CONFIG_FILE" 2>/dev/null
}

forward_state_lines() {
    [[ -f "$STATE_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -r '
      [((.tunnels // [])[]?), ((.forwards // [])[]?)] |
      unique_by(.tag)[]? |
      [
        (.tag // ""),
        (.listen // "0.0.0.0"),
        (.listen_port | tostring),
        (.target // ""),
        (.target_port | tostring),
        (.network // "tcp"),
        (.mode // "safe"),
        (.remark // ""),
        ((.enabled // true) | tostring),
        (.type // "single"),
        (.group // ""),
        ((.port_map // {}) | @json)
      ] | join("\u001f")
    ' "$STATE_FILE" 2>/dev/null
}

forward_config_has_tag() {
    local tag="$1"

    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e --arg tag "$tag" '
      any(.inbounds[]?; (.tag == $tag) and (.protocol == "dokodemo-door" or .protocol == "tunnel"))
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

forward_tag_known() {
    local tag="$1"

    forward_config_has_tag "$tag" && return 0
    [[ -f "$STATE_FILE" ]] || return 1
    jq -e --arg tag "$tag" 'any(((.tunnels // []) + (.forwards // []))[]?; .tag == $tag)' "$STATE_FILE" >/dev/null 2>&1
}

forward_state_has_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || return 1
    jq -e --arg tag "$tag" 'any(((.tunnels // []) + (.forwards // []))[]?; .tag == $tag)' "$STATE_FILE" >/dev/null 2>&1
}

forward_state_field_for_tag() {
    local tag="$1"
    local field="$2"

    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg tag "$tag" --arg field "$field" '
      ((.tunnels // []) + (.forwards // []))[]? |
      select(.tag == $tag) |
      .[$field] // empty
    ' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_relay_route_exists() {
    local tag="$1"

    [[ -f "$CONFIG_FILE" ]] || return 1
    jq -e --arg tag "$tag" '
      any(.routing.rules[]?;
        (.type == "field") and
        (.outboundTag == "direct") and
        (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end))
      )
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

forward_rule_count() {
    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "0"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        printf '%s' "0"
        return 0
    }

    jq -r --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
      [ .inbounds[]? |
        select(((.tag // "") | startswith($tunnel_prefix)) or ((.tag // "") | startswith($legacy_prefix))) |
        select(.protocol == "dokodemo-door" or .protocol == "tunnel")
      ] | length
    ' "$CONFIG_FILE" 2>/dev/null
}

forward_remark_for_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg tag "$tag" '((.tunnels // []) + (.forwards // []))[]? | select(.tag == $tag) | .remark // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_group_for_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || return 0
    jq -r --arg tag "$tag" '((.tunnels // []) + (.forwards // []))[]? | select(.tag == $tag) | .group // empty' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_type_for_tag() {
    local tag="$1"

    [[ -f "$STATE_FILE" ]] || {
        printf '%s' "single"
        return 0
    }
    jq -r --arg tag "$tag" '((.tunnels // []) + (.forwards // []))[]? | select(.tag == $tag) | .type // "single"' "$STATE_FILE" 2>/dev/null | head -n 1
}

forward_mode_for_tag() {
    local tag="$1"

    if [[ -f "$CONFIG_FILE" ]] && jq -e --arg tag "$tag" '
      any(.routing.rules[]?;
        (.type == "field") and
        (.outboundTag == "direct") and
        (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end))
      )
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        printf '%s' "relay"
    else
        printf '%s' "safe"
    fi
}

forward_all_lines() {
    local line tag listen listen_port target target_port network mode remark enabled type group port_map seen_tags
    seen_tags="|"

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r tag listen listen_port target target_port network type <<<"$line"
        [[ -n "$tag" ]] || continue
        mode="$(forward_mode_for_tag "$tag")"
        remark="$(forward_remark_for_tag "$tag")"
        group="$(forward_group_for_tag "$tag")"
        if forward_state_has_tag "$tag"; then
            type="$(forward_type_for_tag "$tag")"
        fi
        [[ -n "$type" ]] || type="single"
        printf '启用\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$mode" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network" "$remark" "$type" "$group"
        seen_tags="${seen_tags}${tag}|"
    done < <(forward_rule_lines)

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r tag listen listen_port target target_port network mode remark enabled type group port_map <<<"$line"
        [[ -n "$tag" ]] || continue
        [[ "$seen_tags" == *"|${tag}|"* ]] && continue
        printf '停用\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "${mode:-safe}" "$tag" "$listen" "$listen_port" "$target" "$target_port" "${network:-tcp}" "$remark" "${type:-single}" "$group"
    done < <(forward_state_lines)
}

load_forward_vars_from_tag() {
    local tag="$1"
    local line

    if forward_state_has_tag "$tag"; then
        line="$(jq -r --arg tag "$tag" '
          ((.tunnels // []) + (.forwards // []))[]? |
          select(.tag == $tag) |
          [
            .tag,
            (.listen // "0.0.0.0"),
            (.listen_port | tostring),
            (.target // ""),
            (.target_port | tostring),
            (.network // "tcp"),
            (.mode // "safe"),
            (.remark // ""),
            ((.enabled // false) | tostring),
            (.type // "single"),
            (.group // ""),
            ((.port_map // {}) | @json)
          ] | join("\u001f")
        ' "$STATE_FILE" 2>/dev/null | head -n 1)"
        [[ -n "$line" ]] || return 1
        IFS=$'\037' read -r FORWARD_TAG FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED FORWARD_TYPE FORWARD_GROUP FORWARD_PORT_MAP_JSON <<<"$line"
        if forward_config_has_tag "$FORWARD_TAG"; then
            FORWARD_ENABLED="true"
        fi
        FORWARD_TYPE="$(normalize_tunnel_type "$FORWARD_TYPE")"
        [[ -n "${FORWARD_PORT_MAP_JSON:-}" ]] || FORWARD_PORT_MAP_JSON="{}"
        return 0
    fi

    if forward_config_has_tag "$tag"; then
        line="$(jq -r --arg tag "$tag" '
          .inbounds[]? |
          select((.tag == $tag) and (.protocol == "dokodemo-door" or .protocol == "tunnel")) |
          [
            .tag,
            (.listen // "0.0.0.0"),
            (.port | tostring),
            (.settings.address // ""),
            (.settings.port | tostring),
            (.settings.network // "tcp"),
            (if (.settings.portMap // null) then "portMap" else "single" end),
            ((.settings.portMap // {}) | @json)
          ] | join("\u001f")
        ' "$CONFIG_FILE" 2>/dev/null | head -n 1)"
        [[ -n "$line" ]] || return 1
        IFS=$'\037' read -r FORWARD_TAG FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_TYPE FORWARD_PORT_MAP_JSON <<<"$line"
        FORWARD_MODE="$(forward_mode_for_tag "$FORWARD_TAG")"
        FORWARD_REMARK=""
        FORWARD_GROUP=""
        FORWARD_ENABLED="true"
        FORWARD_TYPE="$(normalize_tunnel_type "$FORWARD_TYPE")"
        [[ -n "${FORWARD_PORT_MAP_JSON:-}" ]] || FORWARD_PORT_MAP_JSON="{}"
        return 0
    fi

    return 1
}

select_forward_tag() {
    local filter="${1:-all}"
    local direct_tag="${2:-}"
    local line status mode tag listen listen_port target target_port network remark type group
    local records=()
    local tags=()
    local idx selected

    if [[ -n "$direct_tag" ]]; then
        if forward_tag_known "$direct_tag"; then
            SELECTED_FORWARD_TAG="$direct_tag"
            return 0
        fi
        err "[失败] 未找到转发规则: $direct_tag"
        return 1
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        case "$filter" in
            enabled) [[ "$status" == "启用" ]] || continue ;;
            disabled) [[ "$status" == "停用" ]] || continue ;;
        esac
        records+=("$line")
        tags+=("$tag")
    done < <(forward_all_lines)

    if [[ ${#records[@]} -eq 0 ]]; then
        err "[失败] 没有可选择的转发规则。"
        return 1
    fi

    echo -e "\n${YELLOW}[端口转发] 选择规则${PLAIN}"
    idx=1
    for line in "${records[@]}"; do
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        group="${group:-未分组}"
        if [[ -n "$remark" ]]; then
            echo " ${idx}) ${status} ${mode} ${type:-single} ${group} ${tag}: ${listen}:${listen_port} -> ${target}:${target_port}/${network} ${remark}"
        else
            echo " ${idx}) ${status} ${mode} ${type:-single} ${group} ${tag}: ${listen}:${listen_port} -> ${target}:${target_port}/${network}"
        fi
        ((idx++))
    done

    read -r -p "请选择规则编号: " selected
    if ! [[ "$selected" =~ ^[0-9]+$ ]] || ((selected < 1 || selected > ${#tags[@]})); then
        err "[失败] [端口转发] 无效编号。"
        return 1
    fi

    SELECTED_FORWARD_TAG="${tags[$((selected - 1))]}"
}

list_forward_rules() {
    local line status tag listen listen_port target target_port network mode remark type group
    local rules=()

    if ! command -v jq >/dev/null 2>&1; then
        err "[失败] [端口转发] 缺少 jq，无法读取配置。"
        return 1
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        info "[端口转发] 未找到配置文件，请先安装 Xray 或协议。"
        return 0
    fi

    mapfile -t rules < <(forward_all_lines)
    if [[ ${#rules[@]} -eq 0 ]]; then
        info "[端口转发] 当前未配置转发规则。"
        return 0
    fi

    echo -e "\n${YELLOW}--- Tunnel 中转 ---${PLAIN}"
    printf '%-6s %-6s %-8s %-14s %s\n' "状态" "模式" "类型" "分组" "规则"
    for line in "${rules[@]}"; do
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        group="${group:-未分组}"
        if [[ -n "$remark" ]]; then
            printf '%-6s %-6s %-8s %-14s %s: %s:%s -> %s:%s/%s %s\n' "$status" "$mode" "${type:-single}" "$group" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network" "$remark"
        else
            printf '%-6s %-6s %-8s %-14s %s: %s:%s -> %s:%s/%s\n' "$status" "$mode" "${type:-single}" "$group" "$tag" "$listen" "$listen_port" "$target" "$target_port" "$network"
        fi
        printf '       连接入口: %s\n' "$(tunnel_connection_entry "$listen_port")"
    done
}

state_sync_forward_rule() {
    local tmp port_map_json

    init_state
    port_map_json="${FORWARD_PORT_MAP_JSON:-}"
    [[ -n "$port_map_json" ]] || port_map_json="{}"
    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建状态临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$FORWARD_TAG" \
        --arg listen "$FORWARD_LISTEN" \
        --arg listen_port "$FORWARD_LISTEN_PORT" \
        --arg target "$FORWARD_TARGET" \
        --arg target_port "$FORWARD_TARGET_PORT" \
        --arg network "$FORWARD_NETWORK" \
        --arg mode "$FORWARD_MODE" \
        --arg enabled "${FORWARD_ENABLED:-true}" \
        --arg remark "$FORWARD_REMARK" \
        --arg type "$(normalize_tunnel_type "${FORWARD_TYPE:-single}")" \
        --arg group "${FORWARD_GROUP:-}" \
        --argjson port_map "$port_map_json" '
        def tunnel_record:
        {
          "tag": $tag,
          "type": $type,
          "group": $group,
          "listen": $listen,
          "listen_port": (if $type == "portMap" then $listen_port else ($listen_port | tonumber) end),
          "target": $target,
          "target_port": ($target_port | tonumber),
          "network": $network,
          "mode": $mode,
          "enabled": ($enabled == "true"),
          "remark": $remark
        } + (if $type == "portMap" then {"port_map": $port_map} else {} end);
        .tunnels = ((.tunnels // []) | map(select(.tag != $tag))) |
        .tunnels += [tunnel_record] |
        .forwards = ((.forwards // []) | map(select(.tag != $tag))) |
        .forwards += [tunnel_record]
      ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入状态文件失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 更新状态文件失败。"
        return 1
    fi
    ensure_config_security
}

state_delete_forward_rule() {
    local tag="$1"
    local tmp

    [[ -f "$STATE_FILE" ]] || return 0
    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建状态临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$tag" '
        .tunnels = ((.tunnels // []) | map(select(.tag != $tag))) |
        .forwards = ((.forwards // []) | map(select(.tag != $tag)))
      ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 删除状态记录失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 更新状态文件失败。"
        return 1
    fi
    ensure_config_security
}

configure_forward_rule() {
    local input default_network lock_network scenario_title

    FORWARD_MODE="${1:-${FORWARD_MODE:-safe}}"
    FORWARD_TYPE="single"
    FORWARD_PORT_MAP_JSON="{}"
    default_network="${2:-tcp}"
    lock_network="${3:-false}"
    scenario_title="${4:-}"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 未知转发模式: $FORWARD_MODE"
        return 1
    }

    if [[ -n "$scenario_title" ]]; then
        echo -e "\n${YELLOW}[Tunnel 中转] ${scenario_title}${PLAIN}"
    else
        echo -e "\n${YELLOW}[Tunnel 中转] 添加单端口 Tunnel (${FORWARD_MODE})${PLAIN}"
    fi
    read -r -p "本机监听地址 (默认: 0.0.0.0): " FORWARD_LISTEN
    FORWARD_LISTEN="${FORWARD_LISTEN:-0.0.0.0}"
    if [[ "$FORWARD_LISTEN" =~ [[:space:]] || -z "$FORWARD_LISTEN" ]]; then
        err "[失败] [端口转发] 本机监听地址无效。"
        return 1
    fi

    ask_port "本机监听端口" "30000" FORWARD_LISTEN_PORT || return 1

    read -r -p "目标地址，例如 1.2.3.4 或 example.com: " FORWARD_TARGET
    if [[ -z "$FORWARD_TARGET" || "$FORWARD_TARGET" =~ [[:space:]] ]]; then
        err "[失败] [端口转发] 目标地址无效。"
        return 1
    fi

    while true; do
        read -r -p "目标端口: " FORWARD_TARGET_PORT
        if validate_port "$FORWARD_TARGET_PORT"; then
            break
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done

    if [[ "$lock_network" == "true" ]]; then
        FORWARD_NETWORK="$default_network"
        info "[端口转发] 网络类型: ${FORWARD_NETWORK}"
    else
        read -r -p "网络类型 tcp / udp / tcp,udp (默认: ${default_network}): " input
        FORWARD_NETWORK="${input:-$default_network}"
    fi
    if ! validate_forward_network "$FORWARD_NETWORK"; then
        err "[失败] [端口转发] 网络类型无效，仅支持 tcp、udp、tcp,udp。"
        return 1
    fi

    read -r -p "分组名称，可选: " FORWARD_GROUP
    read -r -p "备注名称，可选: " FORWARD_REMARK
    confirm_forward_safety_warnings || {
        err "[取消] 已取消添加端口转发。"
        return 1
    }
}

configure_forward_scenario() {
    local scenario="$1"
    local input

    forward_scenario_defaults "$scenario" || return 1
    if [[ "$scenario" == "custom" ]]; then
        echo -e "\n${YELLOW}[中转/端口转发] ${FORWARD_SCENARIO_TITLE}${PLAIN}"
        echo " 1) safe：遵守全局安全规则"
        echo " 2) relay：为该 forward inbound 添加 direct 放行"
        read -r -p "模式 (默认: 1): " input
        case "${input:-1}" in
            1) FORWARD_SCENARIO_MODE="safe" ;;
            2) FORWARD_SCENARIO_MODE="relay" ;;
            *)
                err "[失败] 无效模式。"
                return 1
                ;;
        esac
    elif [[ "$scenario" == "udp" ]]; then
        echo -e "\n${YELLOW}[中转/端口转发] ${FORWARD_SCENARIO_TITLE}${PLAIN}"
        echo " 1) safe：普通 UDP 转发，遵守全局安全规则"
        echo " 2) relay：专用 UDP 中转，仅用于可信固定目标"
        read -r -p "模式 (默认: 1): " input
        case "${input:-1}" in
            1) FORWARD_SCENARIO_MODE="safe" ;;
            2) FORWARD_SCENARIO_MODE="relay" ;;
            *)
                err "[失败] 无效模式。"
                return 1
                ;;
        esac
        read -r -p "网络类型 udp / tcp,udp (默认: udp): " input
        case "${input:-udp}" in
            udp | tcp,udp) FORWARD_SCENARIO_NETWORK="${input:-udp}" ;;
            *)
                err "[失败] 网络类型无效，仅支持 udp 或 tcp,udp。"
                return 1
                ;;
        esac
    fi
    if [[ "$scenario" == "custom" ]]; then
        info "[Tunnel] 自定义模式默认网络类型为 tcp,udp；如只需要 TCP，可在下一步输入 tcp。"
    fi

    configure_forward_rule \
        "$FORWARD_SCENARIO_MODE" \
        "$FORWARD_SCENARIO_NETWORK" \
        "$FORWARD_SCENARIO_LOCK_NETWORK" \
        "$FORWARD_SCENARIO_TITLE"
}

remove_forward_config_by_tag() {
    local tag="$1"
    local tmp

    [[ -f "$CONFIG_FILE" ]] || return 0

    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$tag" \
        --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
        def managed_tag:
          ((. // "") | startswith($tunnel_prefix)) or
          ((. // "") | startswith($legacy_prefix));
        def selected_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end));
        .inbounds = ((.inbounds // []) | map(select((.tag != $tag) or (((.tag // "") | managed_tag) | not)))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((selected_relay_rule) | not)))
      ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入 $CONFIG_FILE 失败。"
        return 1
    fi
}

write_forward_config_from_vars() {
    local tmp port_map_json

    FORWARD_ENABLED="${FORWARD_ENABLED:-true}"
    port_map_json="${FORWARD_PORT_MAP_JSON:-}"
    [[ -n "$port_map_json" ]] || port_map_json="{}"
    tmp="$(mktemp)" || {
        err "[失败] [端口转发] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg tag "$FORWARD_TAG" \
        --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" \
        --arg protocol "$TUNNEL_PROTOCOL" \
        --arg listen "$FORWARD_LISTEN" \
        --arg listen_port "$FORWARD_LISTEN_PORT" \
        --arg target "$FORWARD_TARGET" \
        --arg target_port "$FORWARD_TARGET_PORT" \
        --arg network "$FORWARD_NETWORK" \
        --arg mode "$FORWARD_MODE" \
        --arg enabled "$FORWARD_ENABLED" \
        --arg type "$(normalize_tunnel_type "${FORWARD_TYPE:-single}")" \
        --argjson port_map "$port_map_json" '
        def managed_tag:
          ((. // "") | startswith($tunnel_prefix)) or
          ((. // "") | startswith($legacy_prefix));
        def port_value($p):
          if ($p | test(",")) then $p else ($p | tonumber) end;
        def relay_rule:
          {"type": "field", "inboundTag": [$tag], "outboundTag": "direct"};
        def selected_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $tag) else false end));
        def forward_inbound:
          if $type == "portMap" then
            {
              "tag": $tag,
              "listen": $listen,
              "port": port_value($listen_port),
              "protocol": $protocol,
              "settings": {
                "address": $target,
                "port": ($target_port | tonumber),
                "portMap": $port_map,
                "network": $network
              }
            }
          else
            {
              "tag": $tag,
              "listen": $listen,
              "port": ($listen_port | tonumber),
              "protocol": $protocol,
              "settings": {
                "address": $target,
                "port": ($target_port | tonumber),
                "network": $network
              }
            }
          end;
        .inbounds = ((.inbounds // []) | map(select((.tag != $tag) or (((.tag // "") | managed_tag) | not)))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((selected_relay_rule) | not))) |
        if $enabled == "true" then
          .inbounds += [forward_inbound] |
          if $mode == "relay" then
            .routing.rules = ([relay_rule] + ((.routing.rules // []) | map(select(. != relay_rule))))
          else
            .
          end
        else
          .
        end
      ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [端口转发] 写入 $CONFIG_FILE 失败。"
        return 1
    fi
}

install_forward_rule() {
    FORWARD_MODE="${FORWARD_MODE:-safe}"
    FORWARD_ENABLED="true"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 未知转发模式: $FORWARD_MODE"
        return 1
    }

    install_or_update_xray || {
        err "[失败] [端口转发] Xray 安装/更新失败。"
        return 1
    }
    probe_tunnel_protocol
    generate_forward_tag
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    write_forward_config_from_vars || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 应用配置失败。"
        return 1
    fi

    state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    state_set_meta_action "添加端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已添加: ${FORWARD_TAG}"
}

delete_forward_rule() {
    local selected_tag="${1:-}"

    select_forward_tag "all" "$selected_tag" || return 1
    selected_tag="$SELECTED_FORWARD_TAG"

    if ! forward_config_has_tag "$selected_tag"; then
        state_delete_forward_rule "$selected_tag" || err "[状态] 转发状态记录删除失败。"
        state_set_meta_action "删除端口转发" || err "[状态] 最近变更记录失败。"
        ok "[完成] 已删除停用转发规则: ${selected_tag}"
        return 0
    fi

    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    remove_forward_config_by_tag "$selected_tag" || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 应用删除失败。"
        return 1
    fi

    state_delete_forward_rule "$selected_tag" || err "[状态] 转发状态记录删除失败，但 config.json 已生效。"
    state_set_meta_action "删除端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已删除: ${selected_tag}"
}

set_forward_enabled() {
    local enable="$1"
    local selected_tag="${2:-}"
    local filter action context

    if [[ "$enable" == "true" ]]; then
        filter="disabled"
        action="启用"
    else
        filter="enabled"
        action="停用"
    fi

    select_forward_tag "$filter" "$selected_tag" || return 1
    selected_tag="$SELECTED_FORWARD_TAG"
    load_forward_vars_from_tag "$selected_tag" || {
        err "[失败] [端口转发] 无法读取规则: $selected_tag"
        return 1
    }

    if [[ "$enable" == "true" && "$FORWARD_ENABLED" == "true" ]] && forward_config_has_tag "$FORWARD_TAG"; then
        info "[端口转发] 规则已启用: $FORWARD_TAG"
        return 0
    fi
    if [[ "$enable" == "false" ]] && ! forward_config_has_tag "$FORWARD_TAG"; then
        FORWARD_ENABLED="false"
        state_sync_forward_rule || err "[状态] 转发状态记录失败。"
        info "[端口转发] 规则已停用: $FORWARD_TAG"
        return 0
    fi

    if [[ "$enable" == "true" ]]; then
        install_or_update_xray || return 1
        probe_tunnel_protocol
    fi

    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    FORWARD_ENABLED="$enable"
    if [[ "$enable" == "true" ]]; then
        write_forward_config_from_vars || return 1
    else
        remove_forward_config_by_tag "$FORWARD_TAG" || return 1
    fi

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] ${action}失败。"
        return 1
    fi

    state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    context="${action}端口转发"
    state_set_meta_action "$context" || err "[状态] 最近变更记录失败。"
    ok "[完成] ${context}: ${FORWARD_TAG}"
}

prompt_forward_port_value() {
    local label="$1"
    local current="$2"
    local __resultvar="$3"
    local input

    while true; do
        read -r -p "${label} (当前: ${current}): " input
        input="${input:-$current}"
        if validate_port "$input"; then
            printf -v "$__resultvar" '%s' "$input"
            return 0
        fi
        err "端口无效，请输入 1-65535 之间的数字。"
    done
}

edit_forward_rule() {
    local selected_tag="${1:-}"
    local old_tag old_listen_port old_target_port input regen_tag

    select_forward_tag "all" "$selected_tag" || return 1
    load_forward_vars_from_tag "$SELECTED_FORWARD_TAG" || {
        err "[失败] [端口转发] 无法读取规则: $SELECTED_FORWARD_TAG"
        return 1
    }
    if [[ "${FORWARD_TYPE:-single}" == "portMap" ]]; then
        err "[失败] portMap 规则暂不支持逐项 edit，请导出后修改 JSON 再导入，或删除后重新添加。"
        return 1
    fi

    old_tag="$FORWARD_TAG"
    old_listen_port="$FORWARD_LISTEN_PORT"
    old_target_port="$FORWARD_TARGET_PORT"

    echo -e "\n${YELLOW}[端口转发] 修改规则: ${old_tag}${PLAIN}"
    read -r -p "本机监听地址 (当前: ${FORWARD_LISTEN}): " input
    [[ -n "$input" ]] && FORWARD_LISTEN="$input"
    [[ -z "$FORWARD_LISTEN" || "$FORWARD_LISTEN" =~ [[:space:]] ]] && {
        err "[失败] [端口转发] 本机监听地址无效。"
        return 1
    }

    prompt_forward_port_value "本机监听端口" "$FORWARD_LISTEN_PORT" FORWARD_LISTEN_PORT || return 1

    read -r -p "目标地址 (当前: ${FORWARD_TARGET}): " input
    [[ -n "$input" ]] && FORWARD_TARGET="$input"
    [[ -z "$FORWARD_TARGET" || "$FORWARD_TARGET" =~ [[:space:]] ]] && {
        err "[失败] [端口转发] 目标地址无效。"
        return 1
    }

    prompt_forward_port_value "目标端口" "$FORWARD_TARGET_PORT" FORWARD_TARGET_PORT || return 1

    read -r -p "网络类型 tcp / udp / tcp,udp (当前: ${FORWARD_NETWORK}): " input
    [[ -n "$input" ]] && FORWARD_NETWORK="$input"
    validate_forward_network "$FORWARD_NETWORK" || {
        err "[失败] [端口转发] 网络类型无效。"
        return 1
    }

    read -r -p "模式 safe / relay (当前: ${FORWARD_MODE}): " input
    [[ -n "$input" ]] && FORWARD_MODE="$input"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [端口转发] 模式无效。"
        return 1
    }

    read -r -p "分组名称 (当前: ${FORWARD_GROUP:-无}): " input
    [[ -n "$input" ]] && FORWARD_GROUP="$input"

    read -r -p "备注名称 (当前: ${FORWARD_REMARK:-无}): " input
    [[ -n "$input" ]] && FORWARD_REMARK="$input"

    confirm_forward_safety_warnings || {
        err "[取消] 已取消修改端口转发。"
        return 1
    }

    if [[ "$FORWARD_LISTEN_PORT" != "$old_listen_port" || "$FORWARD_TARGET_PORT" != "$old_target_port" ]]; then
        read -r -p "监听端口或目标端口已改变，是否重新生成 tag? [y/N]: " regen_tag
        if [[ "$regen_tag" =~ ^[yY]$ ]]; then
            generate_forward_tag
        else
            FORWARD_TAG="$old_tag"
        fi
    fi

    FORWARD_ENABLED="true"
    install_or_update_xray || return 1
    probe_tunnel_protocol
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    remove_forward_config_by_tag "$old_tag" || return 1
    write_forward_config_from_vars || return 1

    if ! apply_config "端口转发"; then
        err "[失败] [端口转发] 修改失败。"
        return 1
    fi

    if [[ "$FORWARD_TAG" != "$old_tag" ]]; then
        state_delete_forward_rule "$old_tag" || err "[状态] 旧转发状态删除失败，但 config.json 已生效。"
    fi
    state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    state_set_meta_action "修改端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 端口转发已修改: ${FORWARD_TAG}"
}

forward_target_is_ip_literal() {
    local target="$1"

    [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$target" == *:* ]]
}

forward_security_impact_summary() {
    local impacts=()
    local cn_status

    if port_in_csv "$FORWARD_TARGET_PORT" "$DEFAULT_SAFETY_BLOCK_PORTS"; then
        impacts+=("可能被默认端口屏蔽")
    fi
    if port_in_csv "$FORWARD_TARGET_PORT" "$ENHANCED_SAFETY_BLOCK_PORTS"; then
        impacts+=("可能被增强端口屏蔽")
    fi
    if is_private_target_address "$FORWARD_TARGET"; then
        impacts+=("可能被私网屏蔽")
    fi

    cn_status="$(china_direct_block_status)"
    if [[ "$cn_status" != "未启用" ]]; then
        impacts+=("CN block ${cn_status} 可能影响中国大陆目标")
    fi

    if [[ ${#impacts[@]} -eq 0 ]]; then
        printf '%s' "未发现明显命中项"
    else
        local IFS='；'
        printf '%s' "${impacts[*]}"
    fi
}

forward_local_listen_status() {
    if ! forward_config_has_tag "$FORWARD_TAG"; then
        printf '%s' "失败（规则未启用）"
        return 0
    fi
    if ! command -v ss >/dev/null 2>&1; then
        printf '%s' "未检测（缺少 ss，无法检查本地监听）"
        return 0
    fi
    if ss -tulpn 2>/dev/null | grep -E "[:.]${FORWARD_LISTEN_PORT}[[:space:]]" | grep -q xray; then
        printf '%s' "OK"
    else
        printf '%s' "失败（未看到 xray 监听该端口）"
    fi
}

forward_tcp_connect_status() {
    local nc_bin

    if [[ "$FORWARD_NETWORK" != *tcp* ]]; then
        printf '%s' "跳过（非 TCP 规则）"
        return 0
    fi

    nc_bin="$(command -v nc || true)"
    if [[ -z "$nc_bin" ]]; then
        printf '%s' "跳过（未检测到 nc，请安装 netcat-openbsd）"
        return 0
    fi

    if nc -z -w3 "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" >/dev/null 2>&1; then
        printf '%s' "OK"
    else
        printf '%s' "失败"
    fi
}

forward_relay_route_status() {
    if [[ "$FORWARD_MODE" != "relay" ]]; then
        printf '%s' "不适用"
        return 0
    fi

    if forward_relay_route_exists "$FORWARD_TAG"; then
        printf '%s' "存在"
    else
        printf '%s' "缺失"
    fi
}

forward_state_config_summary() {
    if forward_config_has_tag "$FORWARD_TAG" && forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "config/state 同步"
    elif forward_config_has_tag "$FORWARD_TAG"; then
        printf '%s' "state 缺失，可从 config 解析"
    elif forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "state 存在但 config inbound 不存在"
    else
        printf '%s' "config/state 均缺失"
    fi
}

forward_effective_status() {
    if forward_config_has_tag "$FORWARD_TAG" && forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "启用"
    elif forward_config_has_tag "$FORWARD_TAG"; then
        printf '%s' "config-only"
    elif forward_state_has_tag "$FORWARD_TAG"; then
        printf '%s' "state-only"
    else
        printf '%s' "异常"
    fi
}

print_forward_resolution() {
    if forward_target_is_ip_literal "$FORWARD_TARGET"; then
        echo "目标解析: 跳过（目标是 IP 地址）"
        return 0
    fi

    if ! command -v getent >/dev/null 2>&1; then
        echo "目标解析: 跳过（缺少 getent）"
        return 0
    fi

    echo "目标解析:"
    if ! getent ahosts "$FORWARD_TARGET" | awk '{print "  " $1 " " $2}' | sort -u | head -n 8; then
        echo "  未获得 A/AAAA 结果"
    fi
}

diagnose_forward_rule() {
    local tag="$1"
    local status

    load_forward_vars_from_tag "$tag" || {
        err "[失败] [端口转发] 无法读取规则: $tag"
        return 1
    }

    status="$(forward_effective_status)"

    echo -e "\n${YELLOW}--- Tunnel 诊断 ---${PLAIN}"
    echo "规则: ${FORWARD_TAG}"
    echo "状态: ${status}"
    echo "模式: ${FORWARD_MODE}"
    echo "类型: ${FORWARD_TYPE:-single}"
    echo "分组: ${FORWARD_GROUP:-未分组}"
    echo "监听: ${FORWARD_LISTEN}:${FORWARD_LISTEN_PORT}"
    echo "连接入口: $(tunnel_connection_entry "$FORWARD_LISTEN_PORT")"
    echo "目标: ${FORWARD_TARGET}:${FORWARD_TARGET_PORT}/${FORWARD_NETWORK}"
    [[ -n "$FORWARD_REMARK" ]] && echo "备注: ${FORWARD_REMARK}"
    echo "状态摘要: $(forward_state_config_summary)"
    echo "本地监听: $(forward_local_listen_status)"
    print_forward_resolution
    echo "TCP连通: $(forward_tcp_connect_status)"
    if [[ "$FORWARD_NETWORK" == *udp* ]]; then
        echo "UDP说明: UDP 无法通过简单握手可靠判断"
    else
        echo "UDP说明: 不适用"
    fi
    echo "relay路由: $(forward_relay_route_status)"
    if [[ "$FORWARD_MODE" == "safe" ]]; then
        echo "安全规则影响: $(forward_security_impact_summary)；safe 模式会遵守全局安全规则"
    else
        echo "安全规则影响: $(forward_security_impact_summary)"
    fi
}

test_forward_rule() {
    local selected_tag="${1:-}"

    select_forward_tag "all" "$selected_tag" || return 1
    diagnose_forward_rule "$SELECTED_FORWARD_TAG"
}

doctor_forward_rules() {
    local selected_tag="${1:-}"
    local line status mode tag listen listen_port target target_port network remark
    local rules=()

    if [[ -n "$selected_tag" ]]; then
        forward_tag_known "$selected_tag" || {
            err "[失败] 未找到转发规则: $selected_tag"
            return 1
        }
        diagnose_forward_rule "$selected_tag"
        return $?
    fi

    mapfile -t rules < <(forward_all_lines)
    if [[ ${#rules[@]} -eq 0 ]]; then
        info "[端口转发] 当前没有可诊断的转发规则。"
        return 0
    fi

    for line in "${rules[@]}"; do
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark _type _group <<<"$line"
        diagnose_forward_rule "$tag" || return 1
    done
}

list_tunnel_groups() {
    local line status mode tag listen listen_port target target_port network remark type group key
    local -A totals enabled disabled
    local groups=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        key="${group:-未分组}"
        if [[ -z "${totals[$key]+x}" ]]; then
            groups+=("$key")
            totals[$key]=0
            enabled[$key]=0
            disabled[$key]=0
        fi
        totals[$key]=$((totals[$key] + 1))
        if [[ "$status" == "启用" ]]; then
            enabled[$key]=$((enabled[$key] + 1))
        else
            disabled[$key]=$((disabled[$key] + 1))
        fi
    done < <(forward_all_lines)

    if [[ ${#groups[@]} -eq 0 ]]; then
        info "[Tunnel] 当前没有分组。"
        return 0
    fi

    echo -e "\n${YELLOW}--- Tunnel 分组 ---${PLAIN}"
    printf '%-18s %-8s %-8s %-8s\n' "group" "总数" "启用" "停用"
    for key in "${groups[@]}"; do
        printf '%-18s %-8s %-8s %-8s\n' "$key" "${totals[$key]}" "${enabled[$key]}" "${disabled[$key]}"
    done
}

doctor_tunnel_groups() {
    local line status mode tag listen listen_port target target_port network remark type group key relay_status
    local -A totals enabled disabled abnormal
    local groups=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\037' read -r status mode tag listen listen_port target target_port network remark type group <<<"$line"
        key="${group:-未分组}"
        if [[ -z "${totals[$key]+x}" ]]; then
            groups+=("$key")
            totals[$key]=0
            enabled[$key]=0
            disabled[$key]=0
            abnormal[$key]=0
        fi
        totals[$key]=$((totals[$key] + 1))
        if [[ "$status" == "启用" ]]; then
            enabled[$key]=$((enabled[$key] + 1))
        else
            disabled[$key]=$((disabled[$key] + 1))
        fi
        load_forward_vars_from_tag "$tag" >/dev/null 2>&1 || {
            abnormal[$key]=$((abnormal[$key] + 1))
            continue
        }
        relay_status="$(forward_relay_route_status)"
        if [[ "$FORWARD_MODE" == "relay" && "$relay_status" == "缺失" ]]; then
            abnormal[$key]=$((abnormal[$key] + 1))
        fi
    done < <(forward_all_lines)

    if [[ ${#groups[@]} -eq 0 ]]; then
        info "[Tunnel] 当前没有可诊断的分组。"
        return 0
    fi

    echo -e "\n${YELLOW}--- Tunnel 分组诊断 ---${PLAIN}"
    for key in "${groups[@]}"; do
        echo "group: ${key}"
        echo "总数: ${totals[$key]}"
        echo "启用: ${enabled[$key]}"
        echo "停用: ${disabled[$key]}"
        echo "异常: ${abnormal[$key]}"
        echo
    done
}

export_forward_rules() {
    local timestamp outfile

    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口转发] 缺少 jq，无法导出。"
        return 1
    }

    timestamp="$(date +%Y%m%d%H%M%S)"
    outfile="${FORWARD_EXPORT_DIR:-/root}/xray-tunnels-${timestamp}.json"

    if [[ -f "$STATE_FILE" ]] && jq -e '(((.tunnels // []) + (.forwards // [])) | length) > 0' "$STATE_FILE" >/dev/null 2>&1; then
        jq '{
          version: 1,
          type: "xray-oneclick-tunnels",
          tunnels: ([((.tunnels // [])[]?), ((.forwards // [])[]?)] | unique_by(.tag))
        }' "$STATE_FILE" >"$outfile" || {
            err "[失败] [端口转发] 导出 state 失败。"
            return 1
        }
    elif [[ -f "$CONFIG_FILE" ]]; then
        jq --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
            --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
          def managed_tag:
            ((.tag // "") | startswith($tunnel_prefix)) or
            ((.tag // "") | startswith($legacy_prefix));
          def tunnel_protocol: (.protocol == "dokodemo-door" or .protocol == "tunnel");
          . as $root |
          {
            version: 1,
            type: "xray-oneclick-tunnels",
            tunnels: [
              $root.inbounds[]? |
              select(managed_tag) |
              select(tunnel_protocol) |
              . as $in |
              {
                tag: $in.tag,
                type: (if ($in.settings.portMap // null) then "portMap" else "single" end),
                group: "",
                listen: ($in.listen // "0.0.0.0"),
                listen_port: $in.port,
                target: ($in.settings.address // ""),
                target_port: $in.settings.port,
                network: ($in.settings.network // "tcp"),
                mode: (if any($root.routing.rules[]?; (.type == "field") and (.outboundTag == "direct") and (((.inboundTag // []) | if type == "array" then any(.[]; . == $in.tag) else false end))) then "relay" else "safe" end),
                remark: "",
                enabled: true
              } + (if ($in.settings.portMap // null) then {port_map: $in.settings.portMap} else {} end)
            ]
          }
        ' "$CONFIG_FILE" >"$outfile" || {
            err "[失败] [端口转发] 从 config.json 导出失败。"
            return 1
        }
    else
        printf '{\n  "version": 1,\n  "type": "xray-oneclick-tunnels",\n  "tunnels": []\n}\n' >"$outfile"
    fi

    chmod 600 "$outfile" 2>/dev/null || true
    ok "[完成] Tunnel 规则已导出: $outfile"
}

generate_forward_template() {
    local outfile

    outfile="${FORWARD_EXPORT_DIR:-/root}/xray-tunnels-template.json"
    cat >"$outfile" <<'JSON'
{
  "version": 1,
  "type": "xray-oneclick-tunnels",
  "tunnels": [
    {
      "tag": "tunnel-30000-443",
      "type": "single",
      "group": "landing-us",
      "listen": "0.0.0.0",
      "listen_port": 30000,
      "target": "1.2.3.4",
      "target_port": 443,
      "network": "tcp",
      "mode": "relay",
      "remark": "landing-us",
      "enabled": true
    }
  ]
}
JSON
    chmod 600 "$outfile" 2>/dev/null || true
    ok "[完成] Tunnel 导入模板已生成: $outfile"
}

list_managed_ports() {
    [[ -f "$CONFIG_FILE" ]] || {
        info "[端口] 未找到配置文件: $CONFIG_FILE"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口] 缺少 jq，无法读取配置。"
        return 1
    }

    echo -e "\n${YELLOW}--- 脚本管理的监听端口 ---${PLAIN}"
    printf '%-8s %-12s %s\n' "端口" "类型" "监听"
    jq -r --arg ss "$SS_TAG" \
        --arg vless "$VLESS_TAG" \
        --arg reality "$REALITY_TAG" \
        --arg reality_defender "$REALITY_DEFENDER_TAG" \
        --arg xhttp "$VLESS_XHTTP_FM_TAG" \
        --arg socks "$SOCKS_TAG" \
        --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" '
        def managed_tag:
          ((.tag // "") | startswith($tunnel_prefix)) or
          ((.tag // "") | startswith($legacy_prefix));
        .inbounds[]? |
        select(
          .tag == $ss or
          .tag == $vless or
          .tag == $reality or
          .tag == $reality_defender or
          .tag == $xhttp or
          .tag == $socks or
          managed_tag
        ) |
        [
          (.port | tostring),
          (if .tag == $ss then "SS2022"
           elif .tag == $vless then "VLESS"
           elif .tag == $reality then "Reality"
           elif .tag == $reality_defender then "Reality-Def"
           elif .tag == $xhttp then "XHTTP-FM"
           elif .tag == $socks then "SOCKS5"
           else "Tunnel" end),
          (if managed_tag then .tag else (.listen // "0.0.0.0") end)
        ] | @tsv
    ' "$CONFIG_FILE" 2>/dev/null | while IFS=$'\t' read -r port proto listen; do
        [[ -n "$port" ]] || continue
        printf '%-8s %-12s %s\n' "$port" "$proto" "$listen"
    done
}

resolve_tunnel_import_file() {
    local import_path="$1"
    local candidate

    import_path="${import_path//$'\r'/}"
    if [[ -d "$import_path" ]]; then
        candidate="${import_path%/}/tunnels.json"
        [[ -f "$candidate" ]] || {
            err "[失败] [Tunnel] 部署包目录中未找到 tunnels.json: $candidate"
            return 1
        }
        printf '%s' "$candidate"
        return 0
    fi

    printf '%s' "$import_path"
}

import_forward_rules() {
    local import_file="${1:-}" tmp_records line tag listen listen_port target target_port network mode remark enabled choice imported new_tag type group port_map
    local assume_yes="false" arg
    local import_lines=()

    shift || true
    if tunnel_import_auto_yes_enabled; then
        assume_yes="true"
    fi
    for arg in "$@"; do
        case "$arg" in
            --yes | -y)
                assume_yes="true"
                ;;
            *)
                err "[失败] [Tunnel] 未知 import 参数: $arg"
                echo "用法: ike tunnel import [文件路径] [--yes]"
                return 1
                ;;
        esac
    done

    command -v jq >/dev/null 2>&1 || {
        err "[失败] [端口转发] 缺少 jq，无法导入。"
        return 1
    }

    if [[ -z "$import_file" ]]; then
        read -r -p "导入文件路径: " import_file
    fi
    import_file="$(resolve_tunnel_import_file "$import_file")" || return 1
    [[ -f "$import_file" ]] || {
        err "[失败] [端口转发] 未找到导入文件: $import_file"
        return 1
    }

    jq empty "$import_file" >/dev/null 2>&1 || {
        err "[失败] [端口转发] JSON 格式无效。"
        return 1
    }

    jq -e '
      def src:
        if type == "array" then .
        elif (.tunnels // null) then .tunnels
        else (.forwards // [])
        end;
      def valid_port(p): ((try (p | tonumber) catch 0) >= 1 and (try (p | tonumber) catch 0) <= 65535);
      def valid_listen_port(p; t):
        if t == "portMap" then
          ((p | tostring | split(",") | length) > 0 and all((p | tostring | split(","))[]; valid_port(.)))
        else
          valid_port(p)
        end;
      (src | type) == "array" and
      all(src[]?;
        ((.type // "single") as $t |
        (.tag | type == "string") and ((.tag | startswith("tunnel-")) or (.tag | startswith("forward-"))) and
        (.listen | type == "string") and
        valid_listen_port(.listen_port; $t) and
        (.target | type == "string") and
        valid_port(.target_port) and
        ((.network // "tcp") as $n | ["tcp","udp","tcp,udp"] | index($n)) and
        ((.mode // "safe") as $m | ["safe","relay"] | index($m)) and
        (["single","portMap"] | index($t)) and
        (if (.type // "single") == "portMap" then ((.port_map // {}) | type == "object") else true end)
        )
      )
    ' "$import_file" >/dev/null || {
        err "[失败] [端口转发] 导入文件缺少必要字段或字段非法。"
        return 1
    }

    install_or_update_xray || return 1
    probe_tunnel_protocol
    backup_config || {
        err "[失败] [端口转发] 配置备份失败。"
        return 1
    }

    tmp_records="$(mktemp)" || return 1
    imported=0

    mapfile -t import_lines < <(jq -c '
      def src:
        if type == "array" then .
        elif (.tunnels // null) then .tunnels
        else (.forwards // [])
        end;
      src[]?
    ' "$import_file")

    for line in "${import_lines[@]}"; do
        tag="$(jq -r '.tag' <<<"$line")"
        type="$(jq -r '.type // "single"' <<<"$line")"
        group="$(jq -r '.group // ""' <<<"$line")"
        listen="$(jq -r '.listen' <<<"$line")"
        listen_port="$(jq -r '.listen_port | tostring' <<<"$line")"
        target="$(jq -r '.target' <<<"$line")"
        target_port="$(jq -r '.target_port | tostring' <<<"$line")"
        network="$(jq -r '.network // "tcp"' <<<"$line")"
        mode="$(jq -r '.mode // "safe"' <<<"$line")"
        remark="$(jq -r '.remark // ""' <<<"$line")"
        enabled="$(jq -r '(.enabled // true) | tostring' <<<"$line")"
        port_map="$(jq -c '.port_map // {}' <<<"$line")"
        tag="${tag//$'\r'/}"
        type="${type//$'\r'/}"
        group="${group//$'\r'/}"
        listen="${listen//$'\r'/}"
        listen_port="${listen_port//$'\r'/}"
        target="${target//$'\r'/}"
        target_port="${target_port//$'\r'/}"
        network="${network//$'\r'/}"
        mode="${mode//$'\r'/}"
        remark="${remark//$'\r'/}"
        enabled="${enabled//$'\r'/}"
        port_map="${port_map//$'\r'/}"
        FORWARD_TAG="$tag"
        FORWARD_TYPE="$(normalize_tunnel_type "$type")"
        FORWARD_GROUP="$group"
        FORWARD_LISTEN="$listen"
        FORWARD_LISTEN_PORT="$listen_port"
        FORWARD_TARGET="$target"
        FORWARD_TARGET_PORT="$target_port"
        FORWARD_NETWORK="${network:-tcp}"
        FORWARD_MODE="${mode:-safe}"
        FORWARD_REMARK="$remark"
        FORWARD_ENABLED="${enabled:-true}"
        FORWARD_PORT_MAP_JSON="$port_map"
        [[ -n "$FORWARD_PORT_MAP_JSON" ]] || FORWARD_PORT_MAP_JSON="{}"

        if forward_tag_known "$FORWARD_TAG"; then
            if [[ "$assume_yes" == "true" ]]; then
                choice="3"
                info "[冲突] 已存在 tag: ${FORWARD_TAG}，--yes 模式将自动改名。"
            else
                echo -e "\n[冲突] 已存在 tag: ${FORWARD_TAG}"
                echo " 1) 跳过"
                echo " 2) 覆盖"
                echo " 3) 自动改名"
                read -r -p "选项 (默认: 1): " choice
            fi
            case "${choice:-1}" in
                2)
                    remove_forward_config_by_tag "$FORWARD_TAG" || return 1
                    state_delete_forward_rule "$FORWARD_TAG" || err "[状态] 覆盖导入时删除旧状态记录失败，将继续写入新记录。"
                    ;;
                3)
                    new_tag="$(generate_unique_forward_tag_from_base "$FORWARD_TAG")" || return 1
                    info "[导入] ${FORWARD_TAG} 已自动改名为 ${new_tag}"
                    FORWARD_TAG="$new_tag"
                    ;;
                *)
                    info "[跳过] ${tag}"
                    continue
                    ;;
            esac
        fi

        write_forward_config_from_vars || return 1
        printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$FORWARD_TAG" "$FORWARD_TYPE" "$FORWARD_GROUP" "$FORWARD_LISTEN" "$FORWARD_LISTEN_PORT" "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" "$FORWARD_NETWORK" "$FORWARD_MODE" "$FORWARD_REMARK" "$FORWARD_ENABLED" "$FORWARD_PORT_MAP_JSON" >>"$tmp_records"
        ((imported += 1))
    done

    if ((imported == 0)); then
        rm -f "$tmp_records"
        info "[端口转发] 没有导入任何规则。"
        return 0
    fi

    if ! apply_config "Tunnel 中转"; then
        rm -f "$tmp_records"
        err "[失败] [端口转发] 导入后应用配置失败。"
        return 1
    fi

    while IFS=$'\037' read -r FORWARD_TAG FORWARD_TYPE FORWARD_GROUP FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED FORWARD_PORT_MAP_JSON; do
        state_sync_forward_rule || err "[状态] 转发状态记录失败，但 config.json 已生效。"
    done <"$tmp_records"
    rm -f "$tmp_records"

    state_set_meta_action "导入端口转发" || err "[状态] 最近变更记录失败。"
    ok "[完成] 已导入 ${imported} 条转发规则。"
}

export_tunnel_bundle() {
    local timestamp bundle_dir old_export_dir exported_file

    timestamp="$(date +%Y%m%d%H%M%S)"
    bundle_dir="${TUNNEL_BUNDLE_EXPORT_DIR:-/root}/xray-tunnel-bundle-${timestamp}"
    mkdir -p "$bundle_dir" || {
        err "[失败] [Tunnel] 创建部署包目录失败: $bundle_dir"
        return 1
    }

    old_export_dir="${FORWARD_EXPORT_DIR:-}"
    FORWARD_EXPORT_DIR="$bundle_dir"
    export_forward_rules >/dev/null || {
        FORWARD_EXPORT_DIR="$old_export_dir"
        return 1
    }
    FORWARD_EXPORT_DIR="$old_export_dir"

    exported_file="$(find "$bundle_dir" -maxdepth 1 -type f -name 'xray-tunnels-*.json' | head -n 1)"
    [[ -n "$exported_file" ]] || {
        err "[失败] [Tunnel] 未找到导出的 tunnels.json。"
        return 1
    }
    mv "$exported_file" "$bundle_dir/tunnels.json"
    chmod 600 "$bundle_dir/tunnels.json" 2>/dev/null || true

    cat >"$bundle_dir/README.txt" <<EOF
Xray-OneClick Tunnel 部署包

本目录包含:
- tunnels.json: Tunnel 规则导出文件
- install-tunnels.sh: 可选辅助导入脚本

在另一台 Linux 机器上导入:

curl -fsSL ${RAW_SCRIPT_URL} -o install.sh
XRAY_ONECLICK_YES=1 bash install.sh bootstrap
ike tunnel import /root/tunnels.json

也可以使用非交互导入:

ike tunnel import /root/tunnels.json --yes
ike tunnel bundle import /root/xray-tunnel-bundle-YYYYmmddHHMMSS --yes

说明:
- --yes 遇到 tag 冲突时会自动改名。
- 导入不会覆盖非 Tunnel 协议入站。
EOF

    cat >"$bundle_dir/install-tunnels.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh"
SCRIPT_PATH="/root/install.sh"
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
XRAY_ONECLICK_YES=1 bash "$SCRIPT_PATH" bootstrap
bash "$SCRIPT_PATH" tunnel bundle import "$BUNDLE_DIR" --yes
EOF
    chmod +x "$bundle_dir/install-tunnels.sh"

    ok "[完成] Tunnel 部署包已导出: $bundle_dir"
    ok "[部署包] tunnels.json: $bundle_dir/tunnels.json"
    ok "[部署包] README.txt: $bundle_dir/README.txt"
    ok "[部署包] install-tunnels.sh: $bundle_dir/install-tunnels.sh"
}

generate_tunnel_script_bundle() {
    local label="$1"

    info "[Tunnel] ${label}"
    export_tunnel_bundle
}

import_tunnel_bundle() {
    local import_path="${1:-}"

    if [[ -n "$import_path" ]]; then
        import_path="$(resolve_tunnel_import_file "$import_path")" || return 1
        shift || true
        import_forward_rules "$import_path" "$@"
    else
        import_forward_rules "$@"
    fi
}

configure_tunnel_portmap_rule() {
    local input local_port target target_port map_tmp first_target="" first_target_port="" first_local_port="" local_ports=()

    FORWARD_TYPE="portMap"
    FORWARD_MODE="relay"
    FORWARD_NETWORK="tcp"
    FORWARD_REMARK=""
    FORWARD_GROUP=""
    FORWARD_PORT_MAP_JSON="{}"

    echo -e "\n${YELLOW}[Tunnel 中转] 多端口落地组（portMap）${PLAIN}"
    info "[提示] portMap 会优先生成单个 Tunnel inbound；如果 Xray 校验失败，会自动回退为多条 single Tunnel。"
    read -r -p "分组名称 (建议填写，例如 landing-us): " FORWARD_GROUP
    read -r -p "本机监听地址 (默认: 0.0.0.0): " FORWARD_LISTEN
    FORWARD_LISTEN="${FORWARD_LISTEN:-0.0.0.0}"
    if [[ "$FORWARD_LISTEN" =~ [[:space:]] || -z "$FORWARD_LISTEN" ]]; then
        err "[失败] [Tunnel] 本机监听地址无效。"
        return 1
    fi

    read -r -p "模式 safe / relay (默认: relay): " input
    FORWARD_MODE="${input:-relay}"
    validate_forward_mode "$FORWARD_MODE" || {
        err "[失败] [Tunnel] 模式无效。"
        return 1
    }

    read -r -p "网络类型 tcp / udp / tcp,udp (默认: tcp): " input
    FORWARD_NETWORK="${input:-tcp}"
    validate_forward_network "$FORWARD_NETWORK" || {
        err "[失败] [Tunnel] 网络类型无效。"
        return 1
    }

    map_tmp="$(mktemp)" || return 1
    printf '{}\n' >"$map_tmp"
    while true; do
        read -r -p "本地端口 (留空结束): " local_port
        [[ -z "$local_port" && ${#local_ports[@]} -gt 0 ]] && break
        if ! validate_port "$local_port"; then
            err "端口无效，请输入 1-65535 之间的数字。"
            continue
        fi

        read -r -p "目标地址，例如 1.2.3.4 或 example.com: " target
        if [[ -z "$target" || "$target" =~ [[:space:]] ]]; then
            err "[失败] [Tunnel] 目标地址无效。"
            continue
        fi
        while true; do
            read -r -p "目标端口: " target_port
            validate_port "$target_port" && break
            err "端口无效，请输入 1-65535 之间的数字。"
        done

        if [[ ${#local_ports[@]} -eq 0 ]]; then
            first_local_port="$local_port"
            first_target="$target"
            first_target_port="$target_port"
        fi
        local_ports+=("$local_port")
        if ! jq --arg port "$local_port" --arg value "${target}:${target_port}" '. + {($port): $value}' "$map_tmp" >"${map_tmp}.new" ||
            ! mv "${map_tmp}.new" "$map_tmp"; then
            rm -f "$map_tmp" "${map_tmp}.new"
            err "[失败] [Tunnel] 生成 portMap 失败。"
            return 1
        fi
    done

    read -r -p "备注名称，可选: " FORWARD_REMARK
    FORWARD_LISTEN_PORT="$(
        IFS=,
        printf '%s' "${local_ports[*]}"
    )"
    FORWARD_TARGET="$first_target"
    FORWARD_TARGET_PORT="$first_target_port"
    FORWARD_PORT_MAP_JSON="$(cat "$map_tmp")"
    rm -f "$map_tmp" "${map_tmp}.new"

    [[ -n "$first_local_port" ]] || {
        err "[失败] [Tunnel] 至少需要添加一条端口映射。"
        return 1
    }

    confirm_forward_safety_warnings || {
        err "[取消] 已取消添加 Tunnel portMap。"
        return 1
    }
}

install_tunnel_portmap_rule() {
    local tmp_records line local_port value target target_port

    FORWARD_TYPE="portMap"
    FORWARD_ENABLED="true"
    validate_forward_mode "$FORWARD_MODE" || return 1
    install_or_update_xray || return 1
    probe_tunnel_protocol
    generate_forward_tag
    backup_config || {
        err "[失败] [Tunnel] 配置备份失败。"
        return 1
    }
    write_forward_config_from_vars || return 1

    if apply_config "Tunnel portMap"; then
        state_sync_forward_rule || err "[状态] Tunnel 状态记录失败，但 config.json 已生效。"
        state_set_meta_action "添加 Tunnel portMap" || err "[状态] 最近变更记录失败。"
        ok "[完成] Tunnel portMap 已添加: ${FORWARD_TAG}"
        return 0
    fi

    info "[Tunnel] portMap 配置校验或重启失败，正在回退为多条 single Tunnel。"
    backup_config || {
        err "[失败] [Tunnel] fallback 前配置备份失败。"
        return 1
    }
    tmp_records="$(mktemp)" || return 1
    while IFS=$'\t' read -r local_port value; do
        local_port="${local_port//$'\r'/}"
        value="${value//$'\r'/}"
        target="${value%:*}"
        target_port="${value##*:}"
        FORWARD_TYPE="single"
        FORWARD_LISTEN_PORT="$local_port"
        FORWARD_TARGET="$target"
        FORWARD_TARGET_PORT="$target_port"
        FORWARD_PORT_MAP_JSON="{}"
        generate_forward_tag
        write_forward_config_from_vars || {
            rm -f "$tmp_records"
            return 1
        }
        printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$FORWARD_TAG" "$FORWARD_TYPE" "$FORWARD_GROUP" "$FORWARD_LISTEN" "$FORWARD_LISTEN_PORT" "$FORWARD_TARGET" "$FORWARD_TARGET_PORT" "$FORWARD_NETWORK" "$FORWARD_MODE" "$FORWARD_REMARK" "$FORWARD_ENABLED" "$FORWARD_PORT_MAP_JSON" >>"$tmp_records"
    done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"$FORWARD_PORT_MAP_JSON")

    if ! apply_config "Tunnel portMap fallback"; then
        rm -f "$tmp_records"
        err "[失败] [Tunnel] portMap fallback 应用配置失败。"
        return 1
    fi

    while IFS=$'\037' read -r FORWARD_TAG FORWARD_TYPE FORWARD_GROUP FORWARD_LISTEN FORWARD_LISTEN_PORT FORWARD_TARGET FORWARD_TARGET_PORT FORWARD_NETWORK FORWARD_MODE FORWARD_REMARK FORWARD_ENABLED FORWARD_PORT_MAP_JSON; do
        state_sync_forward_rule || err "[状态] Tunnel fallback 状态记录失败，但 config.json 已生效。"
    done <"$tmp_records"
    rm -f "$tmp_records"
    state_set_meta_action "添加 Tunnel portMap fallback" || err "[状态] 最近变更记录失败。"
    ok "[完成] portMap 已回退为多条 single Tunnel。"
}

configure_forward_menu() {
    local choice

    while true; do
        echo -e "\n${YELLOW}[Tunnel 中转管理]${PLAIN}"
        echo " 1) 单端口落地中转（relay/tcp,udp）"
        echo " 2) 多端口落地组（portMap / fallback 多条 single）"
        echo " 3) 普通公网转发（safe/tcp）"
        echo " 4) 内网服务暴露（relay/tcp）"
        echo " 5) UDP 游戏/语音转发（safe 或 relay，可选 udp/tcp,udp）"
        echo " 6) 自定义 Tunnel"
        echo " 7) 查看 Tunnel 规则"
        echo " 8) 修改 Tunnel 规则"
        echo " 9) 启用/停用 Tunnel 规则"
        echo "10) 删除 Tunnel 规则"
        echo "11) 测试 Tunnel 目标"
        echo "12) 诊断 Tunnel 规则"
        echo "13) Tunnel 分组统计/诊断"
        echo "14) 生成导入模板"
        echo "15) 查看脚本管理端口"
        echo "16) 导出/导入 Tunnel 规则"
        echo "17) 返回主菜单"
        read -r -p "选项 (默认: 17): " choice

        case "${choice:-17}" in
            1)
                if ! { prepare_system && configure_forward_scenario "landing" && install_forward_rule; }; then
                    err "[失败] 添加单端口落地中转未完成，请查看上方错误信息。"
                fi
                ;;
            2)
                if ! { prepare_system && configure_tunnel_portmap_rule && install_tunnel_portmap_rule; }; then
                    err "[失败] 添加多端口落地组未完成，请查看上方错误信息。"
                fi
                ;;
            3)
                if ! { prepare_system && configure_forward_scenario "public" && install_forward_rule; }; then
                    err "[失败] 添加普通公网转发未完成，请查看上方错误信息。"
                fi
                ;;
            4)
                if ! { prepare_system && configure_forward_scenario "lan" && install_forward_rule; }; then
                    err "[失败] 添加内网服务暴露未完成，请查看上方错误信息。"
                fi
                ;;
            5)
                if ! { prepare_system && configure_forward_scenario "udp" && install_forward_rule; }; then
                    err "[失败] 添加 UDP 转发未完成，请查看上方错误信息。"
                fi
                ;;
            6)
                if ! { prepare_system && configure_forward_scenario "custom" && install_forward_rule; }; then
                    err "[失败] 添加自定义 Tunnel 未完成，请查看上方错误信息。"
                fi
                ;;
            7)
                list_forward_rules
                ;;
            8)
                if ! { prepare_system && edit_forward_rule; }; then
                    err "[失败] 修改 Tunnel 规则未完成，请查看上方错误信息。"
                fi
                ;;
            9)
                echo " 1) 启用 Tunnel 规则"
                echo " 2) 停用 Tunnel 规则"
                read -r -p "选项: " choice
                case "$choice" in
                    1) prepare_system && set_forward_enabled "true" ;;
                    2) prepare_system && set_forward_enabled "false" ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            10)
                if ! { prepare_system && delete_forward_rule; }; then
                    err "[失败] 删除 Tunnel 规则未完成，请查看上方错误信息。"
                fi
                ;;
            11)
                test_forward_rule || err "[失败] 测试 Tunnel 目标未完成，请查看上方错误信息。"
                ;;
            12)
                doctor_forward_rules || err "[失败] 诊断 Tunnel 规则未完成，请查看上方错误信息。"
                ;;
            13)
                echo " 1) 分组统计"
                echo " 2) 分组诊断"
                read -r -p "选项: " choice
                case "$choice" in
                    1) list_tunnel_groups ;;
                    2) doctor_tunnel_groups ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            14)
                generate_forward_template || err "[失败] 生成导入模板未完成，请查看上方错误信息。"
                ;;
            15)
                list_managed_ports || err "[失败] 查看脚本管理端口未完成，请查看上方错误信息。"
                ;;
            16)
                echo " 1) 导出 Tunnel 规则"
                echo " 2) 导入 Tunnel 规则"
                read -r -p "选项: " choice
                case "$choice" in
                    1) export_forward_rules ;;
                    2) prepare_system && import_forward_rules ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            17)
                return 0
                ;;
            *)
                err "无效选项。"
                ;;
        esac

        echo
        read -r -p "按回车返回 Tunnel 菜单..." || return 0
    done
}

view_config() {
    local mode="${1:-$LINK_VIEW_MODE}"
    local detail="${2:-quick}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "错误：未找到配置文件，请先安装协议。"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        err "错误：缺少 jq，无法读取配置。"
        return 1
    fi

    init_state
    if [[ "$detail" == "doctor" ]]; then
        get_public_addresses
    else
        get_local_addresses
    fi
    host_candidates "$mode"
    CURRENT_LINK_VIEW_MODE="$mode"

    echo -e "\n${GREEN}========= 当前 Xray 配置信息 =========${PLAIN}"
    if [[ "$detail" == "doctor" ]]; then
        echo -e "查看模式: ${YELLOW}完整诊断${PLAIN}"
    else
        echo -e "查看模式: ${YELLOW}快速${PLAIN} (${GREEN}完整诊断: ike view doctor${PLAIN})"
    fi
    echo -e "链接显示模式: ${YELLOW}${mode}${PLAIN}"
    echo -e "最近变更: ${YELLOW}$(state_meta_value last_action)${PLAIN}"
    echo -e "最近更新时间: ${YELLOW}$(state_meta_value last_updated_at)${PLAIN}"
    if [[ -n "$(endpoint_custom_value)" ]]; then
        echo -e "连接 endpoint: ${YELLOW}$(endpoint_custom_value)${PLAIN}"
    else
        echo -e "连接 endpoint: ${YELLOW}自动检测，Tunnel 可用 ike endpoint set 自定义${PLAIN}"
    fi
    echo -e "默认安全屏蔽: ${YELLOW}$(default_safety_block_status)${PLAIN}"
    echo -e "默认私网规则: ${YELLOW}$(default_private_block_mode)${PLAIN}"
    echo -e "增强安全屏蔽: ${YELLOW}$(enhanced_safety_block_status)${PLAIN}"
    echo -e "中国大陆直连屏蔽: ${YELLOW}$(china_direct_block_status)${PLAIN}"
    echo -e "Tunnel 中转: ${YELLOW}$(forward_rule_count) 条${PLAIN}"
    if [[ "$detail" == "doctor" ]]; then
        echo -e "geoip.dat: ${YELLOW}$(resource_file_status "$ASSET_DIR/geoip.dat")${PLAIN}"
        echo -e "geosite.dat: ${YELLOW}$(resource_file_status "$ASSET_DIR/geosite.dat")${PLAIN}"
        echo -e "Xray 配置校验: ${YELLOW}$(xray_config_test_status)${PLAIN}"
        echo -e "Xray 服务状态: ${YELLOW}$(xray_service_status)${PLAIN}"
        [[ -n "$PUBLIC_IPV4" ]] && echo -e "公网 IPv4: ${PUBLIC_IPV4}"
        [[ -n "$PUBLIC_IPV6" ]] && echo -e "公网 IPv6: ${PUBLIC_IPV6}"
    elif [[ -z "$IPV4_HOST" && -z "$IPV6_HOST" ]]; then
        info "[提示] 快速模式未检测到本机地址，可使用 ike view doctor 探测公网 IP。"
    fi

    local ss_in ssp ssw ssm user_info
    ss_in="$(jq -c --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$ss_in" ]]; then
        ssp="$(echo "$ss_in" | jq -r '.port')"
        ssw="$(echo "$ss_in" | jq -r '.settings.password')"
        ssm="$(echo "$ss_in" | jq -r '.settings.method')"
        user_info="$(printf '%s' "${ssm}:${ssw}" | b64_url_no_pad)"

        echo -e "\n${YELLOW}--- Shadowsocks 2022 ---${PLAIN}"
        echo -e "端口: ${ssp}"
        echo -e "加密: ${ssm}"
        echo -e "密码: ${ssw}"
        [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: ss://${user_info}@${IPV4_HOST}:${ssp}#SS2022-IPv4"
        if should_print_ipv6_link "$mode" "$SS_TAG" "ss2022"; then
            echo -e "IPv6链接: ss://${user_info}@${IPV6_HOST}:${ssp}#SS2022-IPv6"
        elif [[ "$mode" == "ipv6" ]]; then
            print_ipv6_status_hint "$SS_TAG" "ss2022"
        fi
    fi

    local vless_in vp vu venc vmode vmethod vrtt vticket venc_uri
    vless_in="$(jq -c --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$vless_in" ]]; then
        vp="$(echo "$vless_in" | jq -r '.port')"
        vu="$(echo "$vless_in" | jq -r '.settings.clients[0].id')"
        venc="$(jq -r '.vless_encryption.encryption // empty' "$STATE_FILE" 2>/dev/null)"
        vmode="$(jq -r '.vless_encryption.mode // "basic"' "$STATE_FILE" 2>/dev/null)"
        vmethod="$(jq -r '.vless_encryption.enc_method // "native"' "$STATE_FILE" 2>/dev/null)"
        vrtt="$(jq -r '.vless_encryption.client_rtt // "0rtt"' "$STATE_FILE" 2>/dev/null)"
        vticket="$(jq -r '.vless_encryption.server_ticket // "600s"' "$STATE_FILE" 2>/dev/null)"

        echo -e "\n${YELLOW}--- VLESS Encryption ---${PLAIN}"
        echo -e "端口: ${vp}"
        echo -e "UUID: ${vu}"
        echo -e "模式: ${vmode}"
        echo -e "外观混淆: ${vmethod}"
        echo -e "客户端握手: ${vrtt}"
        echo -e "服务端 ticket: ${vticket}"
        if [[ -z "$venc" ]]; then
            err "[提示] 缺少客户端 encryption，无法生成完整 VLESS 链接。请重新安装或重置 VLESS Encryption。"
        else
            echo -e "客户端 encryption: ${venc}"
            venc_uri="$(url_encode "$venc")"
            [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: vless://${vu}@${IPV4_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}#VLESS-ENC-IPv4"
            if should_print_ipv6_link "$mode" "$VLESS_TAG" "vless_encryption"; then
                echo -e "IPv6链接: vless://${vu}@${IPV6_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}#VLESS-ENC-IPv6"
            elif [[ "$mode" == "ipv6" ]]; then
                print_ipv6_status_hint "$VLESS_TAG" "vless_encryption"
            fi
        fi
    fi

    print_reality_result
    print_vless_xhttp_finalmask_result
    print_advanced_profile_result "xhttp-reality"
    print_advanced_profile_result "enc-reality"
    print_advanced_profile_result "fullstack"

    local socks_in sp su sw
    socks_in="$(jq -c --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" 2>/dev/null)"
    if [[ -n "$socks_in" ]]; then
        sp="$(echo "$socks_in" | jq -r '.port')"
        su="$(echo "$socks_in" | jq -r '.settings.accounts[0].user')"
        sw="$(echo "$socks_in" | jq -r '.settings.accounts[0].pass')"

        echo -e "\n${YELLOW}--- SOCKS5 ---${PLAIN}"
        echo -e "端口: ${sp}"
        echo -e "用户: ${su}"
        echo -e "密码: ${sw}"
        [[ -n "$IPV4_HOST" ]] && echo -e "IPv4链接: socks5://${su}:${sw}@${IPV4_HOST}:${sp}"
        if should_print_ipv6_link "$mode" "$SOCKS_TAG" "socks5"; then
            echo -e "IPv6链接: socks5://${su}:${sw}@${IPV6_HOST}:${sp}"
        elif [[ "$mode" == "ipv6" ]]; then
            print_ipv6_status_hint "$SOCKS_TAG" "socks5"
        fi
    fi

    if [[ "$detail" == "doctor" ]]; then
        list_forward_rules
    fi

    show_footer
}

set_link_view_mode() {
    echo -e "\n${YELLOW}[设置] 链接显示模式${PLAIN}"
    echo " 1) 双栈 (IPv4 + IPv6)"
    echo " 2) 仅 IPv4"
    echo " 3) 仅 IPv6"
    read -r -p "选项 (默认: 1): " MODE_OPT

    case "${MODE_OPT:-1}" in
        1) LINK_VIEW_MODE="dual" ;;
        2) LINK_VIEW_MODE="ipv4" ;;
        3) LINK_VIEW_MODE="ipv6" ;;
        *) LINK_VIEW_MODE="dual" ;;
    esac

    ok "[完成] 当前链接显示模式: ${LINK_VIEW_MODE}"
}

reset_secrets() {
    install_or_update_xray || return 1
    [[ -f "$CONFIG_FILE" ]] || {
        err "[错误] 未找到配置文件。"
        return 1
    }

    echo -e "\n${YELLOW}[维护] 重置密钥/密码（端口不变）${PLAIN}"
    echo " 1) 重置 SS2022 密码"
    echo " 2) 重置 VLESS UUID + Encryption"
    echo " 3) 重置 SOCKS5 密码"
    echo " 4) 一键重置全部"
    read -r -p "选项: " R_OPT

    backup_config
    local tmp changed current_method current_port current_auth
    changed="false"

    if [[ "$R_OPT" == "1" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            current_method="$(jq -r --arg tag "$SS_TAG" '.inbounds[] | select(.tag == $tag).settings.method' "$CONFIG_FILE")"
            SS_PASSWORD="$(generate_ss2022_password "$current_method")"
            tmp="$(mktemp)"
            jq --arg tag "$SS_TAG" --arg pass "$SS_PASSWORD" '(.inbounds[] | select(.tag == $tag).settings.password) = $pass' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
            rm -f "$tmp"
            ok "[完成] SS2022 密码已重置。"
            changed="true"
        else
            info "[跳过] 未找到 SS2022 入站。"
        fi
    fi

    if [[ "$R_OPT" == "2" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            current_port="$(jq -r --arg tag "$VLESS_TAG" '.inbounds[] | select(.tag == $tag).port' "$CONFIG_FILE")"
            current_auth="$(jq -r '.vless_encryption.auth // "x25519"' "$STATE_FILE" 2>/dev/null)"
            VLESS_AUTH="$current_auth"
            VLESS_PORT="$current_port"
            VLESS_MODE="$(jq -r '.vless_encryption.mode // "basic"' "$STATE_FILE" 2>/dev/null)"
            VLESS_ENC_METHOD="$(jq -r '.vless_encryption.enc_method // "native"' "$STATE_FILE" 2>/dev/null)"
            VLESS_CLIENT_RTT="$(jq -r '.vless_encryption.client_rtt // "0rtt"' "$STATE_FILE" 2>/dev/null)"
            VLESS_SERVER_TICKET="$(jq -r '.vless_encryption.server_ticket // "600s"' "$STATE_FILE" 2>/dev/null)"
            VLESS_UUID="$("$BIN_PATH" uuid 2>/dev/null | tr -d '\r\n')"
            generate_vless_encryption_pair "$VLESS_AUTH" || return 1
            tmp="$(mktemp)"
            jq --arg tag "$VLESS_TAG" \
                --arg uuid "$VLESS_UUID" \
                --arg decryption "$VLESS_DECRYPTION" '
                (.inbounds[] | select(.tag == $tag).settings.clients[0].id) = $uuid |
                (.inbounds[] | select(.tag == $tag).settings.decryption) = $decryption |
                del(.inbounds[] | select(.tag == $tag).settings.clients[0].flow)
               ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
            rm -f "$tmp"
            state_set_vless
            ok "[完成] VLESS UUID 与 Encryption 已重置。"
            changed="true"
        else
            info "[跳过] 未找到 VLESS Encryption 入站。"
        fi
    fi

    if [[ "$R_OPT" == "3" || "$R_OPT" == "4" ]]; then
        if jq -e --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            S_PASS="$(openssl rand -hex 8)"
            tmp="$(mktemp)"
            jq --arg tag "$SOCKS_TAG" --arg pass "$S_PASS" '(.inbounds[] | select(.tag == $tag).settings.accounts[0].pass) = $pass' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
            rm -f "$tmp"
            ok "[完成] SOCKS5 密码已重置。"
            changed="true"
        else
            info "[跳过] 未找到 SOCKS5 入站。"
        fi
    fi

    if [[ "$changed" == "true" ]]; then
        apply_config || return 1
        state_set_meta_action "重置密钥/密码" || err "[状态] 最近变更记录失败。"
        view_config
    else
        info "[提示] 没有可更新的配置。"
    fi
}

remove_inbound() {
    local tag="$1"
    local tmp
    init_config || return 1
    tmp="$(mktemp)"
    jq --arg tag "$tag" '.inbounds = ((.inbounds // []) | map(select(.tag != $tag)))' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
}

remove_simple_inbound_config() {
    local tag="$1"
    local state_key="$2"
    local label="$3"

    [[ -f "$CONFIG_FILE" ]] || {
        info "[${label}] 未找到配置文件，视为未安装。"
        state_delete_key "$state_key" 2>/dev/null || true
        return 0
    }

    if ! jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
        state_delete_key "$state_key" 2>/dev/null || true
        ok "[完成] ${label} 未安装或已删除。"
        return 0
    fi

    backup_config || {
        err "[失败] [${label}] 配置备份失败。"
        return 1
    }

    remove_inbound "$tag" || return 1

    if ! apply_config "${label} 删除"; then
        err "[失败] [${label}] 应用删除失败，已尝试自动回滚。"
        return 1
    fi

    state_delete_key "$state_key"
    state_set_meta_action "删除 ${label}" || err "[状态] 最近变更记录失败。"
    ok "[完成] ${label} 已删除。"
}

state_delete_key() {
    local key="$1"
    local tmp
    init_state
    tmp="$(mktemp)"
    jq "del(.${key})" "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
}

cleanup_legacy_singbox() {
    read -r -p "确认删除旧 sing-box 服务与 /etc/sing-box、/usr/local/bin/sing-box? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[yY]$ ]] || return 0

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop sing-box >/dev/null 2>&1 || true
        systemctl disable sing-box >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-update del sing-box >/dev/null 2>&1 || true
        rm -f /etc/init.d/sing-box
    fi
    rm -rf /etc/sing-box /usr/local/bin/sing-box
    ok "[完成] 旧 sing-box 残留已清理。"
}

installed_protocols_summary() {
    local protocols=()
    local summary i

    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1 && jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        jq -e --arg tag "$SS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("SS2022")
        jq -e --arg tag "$VLESS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("VLESS Encryption")
        jq -e --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("Reality")
        jq -e --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("XHTTP-FinalMask")
        jq -e --arg tag "$VLESS_XHTTP_REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("XHTTP-Reality")
        jq -e --arg tag "$VLESS_ENC_REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("Enc-Reality")
        jq -e --arg tag "$VLESS_FULLSTACK_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("FullStack")
        jq -e --arg tag "$SOCKS_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 && protocols+=("SOCKS5")
    fi

    if [[ ${#protocols[@]} -eq 0 ]]; then
        printf '%s' "未配置入站协议"
        return 0
    fi

    summary="${protocols[0]}"
    for ((i = 1; i < ${#protocols[@]}; i++)); do
        summary="${summary} + ${protocols[$i]}"
    done
    printf '%s' "$summary"
}

render_uninstall_menu() {
    echo -e "\n${YELLOW}[卸载] 选择:${PLAIN}"
    echo " 1) 删除 SS2022 配置"
    echo " 2) 删除 VLESS Encryption 配置"
    echo " 3) 删除 VLESS TCP REALITY 配置"
    echo " 4) 删除 VLESS Encryption + XHTTP + FinalMask 配置"
    echo " 5) 删除 VLESS XHTTP + REALITY 配置"
    echo " 6) 删除 VLESS Encryption + REALITY 配置"
    echo " 7) 删除 VLESS Encryption + XHTTP + REALITY + FinalMask 配置"
    echo " 8) 删除 SOCKS5 配置"
    echo " 9) 卸载全部 Xray"
    echo "10) 清理旧 sing-box 残留"
    echo "11) 返回主菜单"
}

uninstall() {
    render_uninstall_menu
    read -r -p "选项: " OPT

    case "$OPT" in
        1)
            remove_simple_inbound_config "$SS_TAG" "ss2022" "SS2022"
            ;;
        2)
            remove_simple_inbound_config "$VLESS_TAG" "vless_encryption" "VLESS Encryption"
            ;;
        3)
            remove_reality_config
            ;;
        4)
            remove_vless_xhttp_finalmask_config
            ;;
        5)
            remove_advanced_profile_config "xhttp-reality"
            ;;
        6)
            remove_advanced_profile_config "enc-reality"
            ;;
        7)
            remove_advanced_profile_config "fullstack"
            ;;
        8)
            remove_simple_inbound_config "$SOCKS_TAG" "socks5" "SOCKS5"
            ;;
        9)
            read -r -p "确认卸载 Xray、配置和快捷命令? [y/N]: " CONFIRM
            [[ "$CONFIRM" =~ ^[yY]$ ]] || return 0
            stop_service
            if [[ "$INIT_SYSTEM" == "systemd" ]]; then
                systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
                systemctl daemon-reload >/dev/null 2>&1 || true
            elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update del "$SERVICE_NAME" >/dev/null 2>&1 || true
                rm -f "/etc/init.d/${SERVICE_NAME}"
            fi
            rm -rf "$CONFIG_DIR" "$ASSET_DIR" "$INSTALLER_DIR" "$BIN_PATH" "$SHORTCUT_PATH" "$LEGACY_SHORTCUT_PATH"
            ok "[完成] Xray 已彻底卸载。当前 shell 如仍缓存 ike 路径，可执行 hash -r。"
            exit 0
            ;;
        10)
            cleanup_legacy_singbox
            ;;
        11 | "")
            return 0
            ;;
        *)
            err "无效选项。"
            ;;
    esac
}

show_footer() {
    local protocol_summary
    protocol_summary="$(installed_protocols_summary)"

    echo -e "\n${GREEN}==============================================${PLAIN}"
    echo -e "${YELLOW}   核心: Xray / 协议: ${protocol_summary}${PLAIN}"
    echo -e "${YELLOW}   快捷命令: ${SHORTCUT_PATH} / ike view [ipv4|ipv6]${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}\n"
}

pause_return_menu() {
    echo
    read -r -p "按回车返回主菜单..." || exit 0
}

configure_advanced_profiles_menu() {
    local opt del_opt

    while true; do
        echo -e "\n${YELLOW}[高级协议组合]${PLAIN}"
        echo " 1. 安装 VLESS XHTTP + REALITY"
        echo " 2. 安装 VLESS Encryption + REALITY"
        echo " 3. 安装 VLESS Encryption + XHTTP + REALITY + FinalMask"
        echo " 4. 查看高级协议组合"
        echo " 5. 删除高级协议组合"
        echo " 6. 返回主菜单"
        read -r -p "选项: " opt
        case "$opt" in
            1)
                if ! { prepare_system && configure_advanced_profile "xhttp-reality" "interactive" && install_advanced_profile "xhttp-reality"; }; then
                    err "[失败] VLESS XHTTP + REALITY 安装未完成，请查看上方错误信息。"
                fi
                ;;
            2)
                if ! { prepare_system && configure_advanced_profile "enc-reality" "interactive" && install_advanced_profile "enc-reality"; }; then
                    err "[失败] VLESS Encryption + REALITY 安装未完成，请查看上方错误信息。"
                fi
                ;;
            3)
                if ! { prepare_system && configure_advanced_profile "fullstack" "interactive" && install_advanced_profile "fullstack"; }; then
                    err "[失败] VLESS Encryption + XHTTP + REALITY + FinalMask 安装未完成，请查看上方错误信息。"
                fi
                ;;
            4)
                init_state
                print_advanced_profile_result "xhttp-reality" "show"
                print_advanced_profile_result "enc-reality" "show"
                print_advanced_profile_result "fullstack" "show"
                ;;
            5)
                echo -e "\n${YELLOW}[删除高级协议组合]${PLAIN}"
                echo " 1) 删除 VLESS XHTTP + REALITY"
                echo " 2) 删除 VLESS Encryption + REALITY"
                echo " 3) 删除 VLESS Encryption + XHTTP + REALITY + FinalMask"
                echo " 4) 返回"
                read -r -p "选项: " del_opt
                case "$del_opt" in
                    1) prepare_system && remove_advanced_profile_config "xhttp-reality" ;;
                    2) prepare_system && remove_advanced_profile_config "enc-reality" ;;
                    3) prepare_system && remove_advanced_profile_config "fullstack" ;;
                    4 | "") ;;
                    *) err "无效选项。" ;;
                esac
                ;;
            6 | "") return 0 ;;
            *) err "无效选项。" ;;
        esac
        echo
        read -r -p "按回车继续..." || return 0
    done
}

render_menu() {
    clear 2>/dev/null || true
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}   Xray 多协议一键安装脚本 (ike)             ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "系统: ${YELLOW}$OS_TYPE${PLAIN} | 初始化: ${YELLOW}$INIT_SYSTEM${PLAIN} | 架构: ${YELLOW}$ARCH${PLAIN}"
    echo -e "----------------------------------------------"
    echo -e "${GREEN}1.${PLAIN} 安装/更新 Xray 核心"
    echo -e "${GREEN}2.${PLAIN} 安装 Shadowsocks 2022"
    echo -e "${GREEN}3.${PLAIN} 安装 IPv6 + Shadowsocks 2022"
    echo -e "${GREEN}4.${PLAIN} 安装 VLESS Encryption"
    echo -e "${GREEN}5.${PLAIN} 安装 VLESS TCP REALITY"
    echo -e "${GREEN}6.${PLAIN} 安装 VLESS Encryption + XHTTP + FinalMask"
    echo -e "${GREEN}7.${PLAIN} 安装 VLESS XHTTP + REALITY（高级）"
    echo -e "${GREEN}8.${PLAIN} 安装 VLESS Encryption + REALITY（高级）"
    echo -e "${GREEN}9.${PLAIN} 安装 VLESS Encryption + XHTTP + REALITY + FinalMask（FullStack）"
    echo -e "${GREEN}10.${PLAIN} 安装 SOCKS5 代理"
    echo -e "${GREEN}11.${PLAIN} 查看当前配置链接"
    echo -e "${GREEN}12.${PLAIN} 设置链接显示模式 (IPv4/IPv6/双栈)"
    echo -e "${GREEN}13.${PLAIN} 重置密钥/密码（端口不变）"
    echo -e "${RED}14.${PLAIN} 卸载/清理"
    echo -e "${GREEN}15.${PLAIN} 开启/关闭中国大陆直连屏蔽"
    echo -e "${GREEN}16.${PLAIN} 开启/关闭增强安全屏蔽"
    echo -e "${GREEN}17.${PLAIN} 导出当前配置备份"
    echo -e "${GREEN}18.${PLAIN} Tunnel 中转管理"
    echo -e "${GREEN}19.${PLAIN} 退出"
    echo -e "----------------------------------------------"
}

show_menu() {
    install_shortcut

    while true; do
        render_menu
        read -r -p "请输入选项 [1-19]: " MENU_CHOICE || exit 0

        case "$MENU_CHOICE" in
            1)
                update_xray_core || err "[失败] Xray 核心安装/更新未完成，请查看上方错误信息。"
                ;;
            2)
                if ! { prepare_system && configure_ss2022 "ipv4" && install_ss2022; }; then
                    err "[失败] Shadowsocks 2022 安装未完成，请查看上方错误信息。"
                fi
                ;;
            3)
                if ! prepare_system; then
                    err "[失败] IPv6 + Shadowsocks 2022 安装未完成，请查看上方错误信息。"
                else
                    if check_ipv6_status; then
                        if ! { configure_ss2022 "ipv6" && install_ss2022; }; then
                            err "[失败] IPv6 + Shadowsocks 2022 安装未完成，请查看上方错误信息。"
                        fi
                    else
                        info "[IPv6] 未检测到可用全局 IPv6 地址，请先在服务器开通 IPv6 后重试。"
                        err "[失败] IPv6 + Shadowsocks 2022 安装未完成。"
                    fi
                fi
                ;;
            4)
                if ! { prepare_system && configure_vless_encryption && install_vless_encryption; }; then
                    err "[失败] VLESS Encryption 安装未完成，请查看上方错误信息。"
                fi
                ;;
            5)
                if ! { prepare_system && configure_reality "interactive" && install_reality; }; then
                    err "[失败] VLESS TCP REALITY 安装未完成，请查看上方错误信息。"
                fi
                ;;
            6)
                if ! { prepare_system && configure_vless_xhttp_finalmask "interactive" && install_vless_xhttp_finalmask; }; then
                    err "[失败] VLESS Encryption + XHTTP + FinalMask 安装未完成，请查看上方错误信息。"
                fi
                ;;
            7)
                if ! { prepare_system && configure_advanced_profile "xhttp-reality" "interactive" && install_advanced_profile "xhttp-reality"; }; then
                    err "[失败] VLESS XHTTP + REALITY 安装未完成，请查看上方错误信息。"
                fi
                ;;
            8)
                if ! { prepare_system && configure_advanced_profile "enc-reality" "interactive" && install_advanced_profile "enc-reality"; }; then
                    err "[失败] VLESS Encryption + REALITY 安装未完成，请查看上方错误信息。"
                fi
                ;;
            9)
                if ! { prepare_system && configure_advanced_profile "fullstack" "interactive" && install_advanced_profile "fullstack"; }; then
                    err "[失败] VLESS Encryption + XHTTP + REALITY + FinalMask 安装未完成，请查看上方错误信息。"
                fi
                ;;
            10)
                if ! { prepare_system && install_socks5; }; then
                    err "[失败] SOCKS5 安装未完成，请查看上方错误信息。"
                fi
                ;;
            11)
                view_config || err "[失败] 查看当前配置链接失败，请查看上方错误信息。"
                ;;
            12)
                set_link_view_mode || err "[失败] 设置链接显示模式失败，请查看上方错误信息。"
                ;;
            13)
                if ! { prepare_system && reset_secrets; }; then
                    err "[失败] 重置密钥/密码未完成，请查看上方错误信息。"
                fi
                ;;
            14)
                uninstall || err "[失败] 卸载/清理未完成，请查看上方错误信息。"
                ;;
            15)
                configure_china_direct_block || err "[失败] 中国大陆直连屏蔽设置未完成，请查看上方错误信息。"
                ;;
            16)
                configure_enhanced_safety_block || err "[失败] 增强安全屏蔽设置未完成，请查看上方错误信息。"
                ;;
            17)
                export_current_config_backup || err "[失败] 导出当前配置备份未完成，请查看上方错误信息。"
                ;;
            18)
                configure_forward_menu || err "[失败] Tunnel 中转管理未完成，请查看上方错误信息。"
                ;;
            19) exit 0 ;;
            *) err "错误选项。" ;;
        esac

        pause_return_menu
    done
}

run_view_command() {
    local mode="$LINK_VIEW_MODE"
    local detail="quick"
    local protocol=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            doctor)
                detail="doctor"
                ;;
            ipv4 | ipv6 | dual)
                mode="$1"
                ;;
            reality)
                protocol="reality"
                ;;
            xhttp)
                protocol="xhttp"
                ;;
            xhttp-reality | enc-reality | fullstack)
                protocol="$1"
                ;;
            *)
                err "[失败] 未知 view 参数: $1"
                echo "用法: ike view [ipv4|ipv6|dual] [doctor|reality|xhttp|xhttp-reality|enc-reality|fullstack]"
                return 1
                ;;
        esac
        shift
    done

    if [[ -n "$protocol" ]]; then
        init_state
        if [[ "$detail" == "doctor" ]]; then
            get_public_addresses
        else
            get_local_addresses
        fi
        host_candidates "$mode"
        CURRENT_LINK_VIEW_MODE="$mode"
        case "$protocol" in
            reality)
                print_reality_result "show"
                ;;
            xhttp)
                print_vless_xhttp_finalmask_result "show"
                ;;
            xhttp-reality | enc-reality | fullstack)
                print_advanced_profile_result "$protocol" "show"
                ;;
        esac
        show_footer
        return 0
    fi

    view_config "$mode" "$detail"
}

run_cnblock_command() {
    local mode="${1:-}"

    case "$mode" in
        "" | status)
            echo -e "中国大陆直连屏蔽: ${YELLOW}$(china_direct_block_status)${PLAIN}"
            case "$(china_direct_block_rule_mode)" in
                basic) echo -e "规则模式: ${YELLOW}基础模式${PLAIN}" ;;
                enhanced) echo -e "规则模式: ${YELLOW}增强模式${PLAIN}" ;;
            esac
            echo "可选: basic / enhanced / off"
            echo "用法: ike cnblock basic|enhanced|off"
            ;;
        basic | enhanced | off)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法修改中国大陆直连屏蔽。"
                return 1
            }
            set_china_direct_block "$mode"
            ;;
        *)
            err "[失败] 未知 cnblock 参数: $mode"
            echo "用法: ike cnblock [basic|enhanced|off]"
            return 1
            ;;
    esac
}

run_safety_command() {
    local scope="${1:-}"
    local action="${2:-}"

    if [[ "$scope" != "enhanced" ]]; then
        err "[失败] 未知 safety 参数: ${scope:-空}"
        echo "用法: ike safety enhanced on|off"
        return 1
    fi

    case "$action" in
        on)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法开启增强安全屏蔽。"
                return 1
            }
            set_enhanced_safety_block "true"
            ;;
        off)
            install_or_update_xray || {
                err "[失败] Xray 安装/更新失败，无法关闭增强安全屏蔽。"
                return 1
            }
            set_enhanced_safety_block "false"
            ;;
        "" | status)
            echo -e "增强安全屏蔽: ${YELLOW}$(enhanced_safety_block_status)${PLAIN}"
            echo "用法: ike safety enhanced on|off"
            ;;
        *)
            err "[失败] 未知 safety enhanced 参数: $action"
            echo "用法: ike safety enhanced on|off"
            return 1
            ;;
    esac
}

run_endpoint_command() {
    local action="${1:-show}"

    case "$action" in
        show | "")
            endpoint_show_command
            ;;
        set)
            endpoint_set_command
            ;;
        clear)
            endpoint_clear_command
            ;;
        detect)
            endpoint_detect_command
            ;;
        *)
            err "[失败] 未知 endpoint 参数: $action"
            echo "用法: ike endpoint show|set|clear|detect"
            return 1
            ;;
    esac
}

run_config_command() {
    local action="${1:-path}"
    local editor_cmd restart_answer

    case "$action" in
        path | "")
            echo "$CONFIG_FILE"
            ;;
        test)
            validate_config_file
            ;;
        edit)
            editor_cmd="${EDITOR:-}"
            if [[ -z "$editor_cmd" ]]; then
                editor_cmd="$(command -v nano || command -v vi || true)"
            fi
            [[ -n "$editor_cmd" ]] || {
                err "[失败] 未找到可用编辑器，请设置 EDITOR 或安装 nano/vi。"
                return 1
            }
            backup_config || {
                err "[失败] 配置备份失败，已中止编辑。"
                return 1
            }
            "$editor_cmd" "$CONFIG_FILE" || return 1
            validate_config_file || {
                err "[失败] 配置校验未通过，已跳过重启。"
                return 1
            }
            read -r -p "配置校验通过，是否重启 Xray? [y/N]: " restart_answer
            if [[ "$restart_answer" =~ ^[yY]$ ]]; then
                restart_service
            else
                info "[配置] 已跳过重启。"
            fi
            ;;
        *)
            err "[失败] 未知 config 参数: $action"
            echo "用法: ike config path|test|edit"
            return 1
            ;;
    esac
}

run_service_command() {
    local action="${1:-status}"
    local assume_yes="false"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes | -y)
                assume_yes="true"
                ;;
            *)
                err "[失败] 未知 service 参数: $1"
                echo "用法: ike service install|status|restart|logs|repair [--yes]"
                return 1
                ;;
        esac
        shift
    done

    case "$action" in
        install)
            ensure_xray_service "$assume_yes"
            ;;
        status | "")
            status_xray_service
            ;;
        restart)
            restart_xray_service
            ;;
        logs)
            run_logs_command
            ;;
        repair)
            ensure_xray_service "$assume_yes"
            validate_config_file
            ;;
        *)
            err "[失败] 未知 service 参数: $action"
            echo "用法: ike service install|status|restart|logs|repair"
            return 1
            ;;
    esac
}

run_logs_command() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>&1 | redact_sensitive_stream
        return "${PIPESTATUS[0]}"
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        if [[ -f "$(log_dir_path)/access.log" || -f "$(log_dir_path)/error.log" ]]; then
            tail -n 200 "$(log_dir_path)/access.log" "$(log_dir_path)/error.log" 2>/dev/null || true
        else
            err "[日志] 未找到 $(log_dir_path)/access.log 或 $(log_dir_path)/error.log。"
            return 1
        fi
    else
        err "[日志] 未检测到 systemd/openrc，无法自动读取 Xray 日志。"
        return 1
    fi
}

run_bootstrap_command() {
    local import_file import_args=()

    prepare_system || {
        err "[失败] Bootstrap 系统准备失败。"
        return 1
    }
    install_or_update_xray || {
        err "[失败] Bootstrap 安装/更新 Xray 失败。"
        return 1
    }
    apply_env_endpoint_if_needed || return 1

    if [[ -n "${XRAY_ONECLICK_TUNNEL_IMPORT:-}" ]]; then
        import_file="$(resolve_tunnel_import_file "$XRAY_ONECLICK_TUNNEL_IMPORT")" || return 1
        if tunnel_import_auto_yes_enabled; then
            import_args+=(--yes)
        fi
        import_forward_rules "$import_file" "${import_args[@]}" || {
            err "[失败] Bootstrap 导入 Tunnel 规则失败。"
            return 1
        }
    else
        info "[Bootstrap] 未设置 XRAY_ONECLICK_TUNNEL_IMPORT，跳过 Tunnel 导入。"
    fi

    apply_config "Bootstrap" || {
        err "[失败] Bootstrap 配置应用失败。"
        return 1
    }

    echo
    show_version
    list_forward_rules
    view_config "$LINK_VIEW_MODE" "doctor"
}

run_tunnel_command() {
    local action="${1:-}"
    local mode="${2:-safe}"
    local tag_arg="${2:-}"
    local subaction="${2:-}"

    case "$action" in
        list | "")
            list_forward_rules
            ;;
        add)
            if [[ "$mode" == "map" ]]; then
                prepare_system || {
                    err "[失败] 系统准备失败，无法添加 Tunnel portMap。"
                    return 1
                }
                configure_tunnel_portmap_rule && install_tunnel_portmap_rule
                return $?
            fi
            if ! validate_forward_mode "$mode"; then
                err "[失败] 未知 tunnel add 模式: $mode"
                echo "用法: ike tunnel add [safe|relay|map]"
                return 1
            fi
            prepare_system || {
                err "[失败] 系统准备失败，无法添加 Tunnel。"
                return 1
            }
            if [[ "$mode" == "relay" ]]; then
                configure_forward_rule "$mode" "tcp,udp" "true" "单端口落地中转（relay/tcp,udp）" && install_forward_rule
            else
                configure_forward_rule "$mode" "tcp" "true" "普通公网转发（safe/tcp）" && install_forward_rule
            fi
            ;;
        enable)
            prepare_system || {
                err "[失败] 系统准备失败，无法启用 Tunnel。"
                return 1
            }
            set_forward_enabled "true" "$tag_arg"
            ;;
        disable)
            prepare_system || {
                err "[失败] 系统准备失败，无法停用 Tunnel。"
                return 1
            }
            set_forward_enabled "false" "$tag_arg"
            ;;
        edit)
            prepare_system || {
                err "[失败] 系统准备失败，无法修改 Tunnel。"
                return 1
            }
            edit_forward_rule "$tag_arg"
            ;;
        test)
            test_forward_rule "$tag_arg"
            ;;
        doctor)
            doctor_forward_rules "$tag_arg"
            ;;
        group)
            case "${2:-list}" in
                list | "")
                    list_tunnel_groups
                    ;;
                doctor)
                    doctor_tunnel_groups
                    ;;
                *)
                    err "[失败] 未知 tunnel group 参数: ${2:-}"
                    echo "用法: ike tunnel group list | ike tunnel group doctor"
                    return 1
                    ;;
            esac
            ;;
        template)
            generate_forward_template
            ;;
        ports)
            list_managed_ports
            ;;
        export)
            export_forward_rules
            ;;
        generate-script)
            generate_tunnel_script_bundle "生成 Tunnel 部署包"
            ;;
        generate-relay-script)
            generate_tunnel_script_bundle "生成中转/落地部署脚本包"
            ;;
        generate-client-script)
            generate_tunnel_script_bundle "生成可导入 Tunnel 规则包"
            ;;
        bundle)
            case "$subaction" in
                export)
                    export_tunnel_bundle
                    ;;
                import)
                    prepare_system || {
                        err "[失败] 系统准备失败，无法导入 Tunnel 部署包。"
                        return 1
                    }
                    shift 2
                    import_tunnel_bundle "$@"
                    ;;
                *)
                    err "[失败] 未知 tunnel bundle 参数: $subaction"
                    echo "用法: ike tunnel bundle export | ike tunnel bundle import [文件或目录] [--yes]"
                    return 1
                    ;;
            esac
            ;;
        import)
            prepare_system || {
                err "[失败] 系统准备失败，无法导入 Tunnel。"
                return 1
            }
            shift
            import_forward_rules "$@"
            ;;
        del | delete | remove)
            prepare_system || {
                err "[失败] 系统准备失败，无法删除 Tunnel。"
                return 1
            }
            delete_forward_rule "$tag_arg"
            ;;
        *)
            err "[失败] 未知 tunnel 参数: $action"
            echo "用法: ike tunnel list | ike tunnel add [safe|relay|map] | ike tunnel enable [tag] | ike tunnel disable [tag] | ike tunnel edit [tag] | ike tunnel test [tag] | ike tunnel doctor [tag] | ike tunnel group list|doctor | ike tunnel template | ike tunnel ports | ike tunnel export | ike tunnel bundle export|import | ike tunnel generate-script | ike tunnel import | ike tunnel del [tag]"
            return 1
            ;;
    esac
}





run_preflight_command() {
    preflight_system
}

run_xray_command() {
    local action="${1:-version}"
    local version="${XRAY_VERSION_REQUEST:-${XRAY_VERSION:-latest}}"
    local channel="${XRAY_CHANNEL_REQUEST:-${XRAY_CHANNEL:-stable}}"
    local dry_run="false"
    local restart="false"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                version="${2:-}"
                [[ -n "$version" ]] || {
                    err "[Xray] --version 需要版本号，例如 v25.1.1"
                    return 1
                }
                shift 2
                ;;
            --xray-version)
                version="${2:-}"
                [[ -n "$version" ]] || {
                    err "[Xray] --xray-version 需要版本号，例如 v25.1.1"
                    return 1
                }
                shift 2
                ;;
            --xray-channel)
                channel="${2:-}"
                [[ -n "$channel" ]] || {
                    err "[Xray] --xray-channel 需要 stable 或 prerelease"
                    return 1
                }
                channel="$(normalize_xray_channel "$channel")" || {
                    err "[Xray] --xray-channel 仅支持 stable 或 prerelease"
                    return 1
                }
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --restart)
                restart="true"
                shift
                ;;
        *)
            err "[失败] 未知 xray 参数: $1"
            show_xray_usage
            return 1
            ;;
        esac
    done

    case "$action" in
        version | "")
            print_xray_version_summary
            ;;
        upgrade)
            XRAY_VERSION_REQUEST="$version"
            XRAY_CHANNEL_REQUEST="$channel"
            upgrade_xray_core "$version" "$channel" "$dry_run" "$restart"
            ;;
        *)
            err "[失败] 未知 xray 命令: $action"
            show_xray_usage
            return 1
            ;;
    esac
}

backup_before_migration() {
    local timestamp backup_dir

    timestamp="$(date +%Y%m%d%H%M%S)"
    backup_dir="${CONFIG_DIR}/migration-backup-${timestamp}"
    mkdir -p "$backup_dir"
    [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "$backup_dir/config.json"
    [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "$backup_dir/installer-state.json"
    chmod 700 "$backup_dir" 2>/dev/null || true
    info "[迁移] 已备份到: $backup_dir"
}

migrate_old_state() {
    local dry_run="${1:-false}"
    local tmp changed="false" reality_link="" xhttp_link=""
    local old_reality_flow old_reality_link old_xhttp_enabled old_xhttp_link
    local inferred_reality_flow="" inferred_xhttp_enabled="" inferred_xhttp_finalmask_json="null"
    local inferred_xhttp_reality_flow="" inferred_enc_reality_flow="" inferred_fullstack_flow=""
    local old_xhttp_finalmask_json
    local ss_scope="" vless_scope="" reality_scope="" xhttp_scope="" socks_scope=""
    local xhttp_reality_scope="" enc_reality_scope="" fullstack_scope=""
    local xhttp_fm_mode="" xhttp_fm_preset="" xhttp_fm_summary=""
    local fullstack_fm_mode="" fullstack_fm_preset="" fullstack_fm_summary=""
    local fullstack_enabled fullstack_json

    if [[ "$dry_run" == "true" ]]; then
        [[ -f "$STATE_FILE" ]] || {
            diag_info "dry-run：installer-state.json 不存在，无需迁移"
            return 0
        }
        jq empty "$STATE_FILE" >/dev/null || return 1
    else
        init_state
    fi
    old_reality_flow="$(jq -r ".${REALITY_STATE_KEY}.flow // empty" "$STATE_FILE" 2>/dev/null)"
    old_reality_link="$(jq -r ".${REALITY_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    old_xhttp_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // empty" "$STATE_FILE" 2>/dev/null)"
    old_xhttp_link="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    old_xhttp_finalmask_json="$(jq -c ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"

    if jq -e ".${VLESS_XHTTP_FM_STATE_KEY}? and (((.${VLESS_XHTTP_FM_STATE_KEY}.finalmask_mode // \"\") == \"\") or ((.${VLESS_XHTTP_FM_STATE_KEY}.finalmask_preset // \"\") == \"\") or ((.${VLESS_XHTTP_FM_STATE_KEY}.finalmask_summary // \"\") == \"\"))" "$STATE_FILE" >/dev/null 2>&1; then
        if [[ "${old_xhttp_enabled:-false}" == "true" ]]; then
            [[ -n "$old_xhttp_finalmask_json" && "$old_xhttp_finalmask_json" != "null" ]] || old_xhttp_finalmask_json="$(jq -c --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag).streamSettings.finalmask // null' "$CONFIG_FILE" 2>/dev/null)"
            if validate_finalmask_json "$old_xhttp_finalmask_json"; then
                set_finalmask_metadata_from_json "$old_xhttp_finalmask_json"
                xhttp_fm_mode="$FINALMASK_MODE"
                xhttp_fm_preset="$FINALMASK_PRESET"
                xhttp_fm_summary="$FINALMASK_SUMMARY"
                changed="true"
            else
                diag_warn "无法推导 vless_xhttp_finalmask FinalMask 元数据"
            fi
        else
            xhttp_fm_mode="off"
            xhttp_fm_preset="none"
            xhttp_fm_summary="off"
            changed="true"
        fi
    fi

    if jq -e ".${VLESS_FULLSTACK_STATE_KEY}? and (((.${VLESS_FULLSTACK_STATE_KEY}.finalmask_mode // \"\") == \"\") or ((.${VLESS_FULLSTACK_STATE_KEY}.finalmask_preset // \"\") == \"\") or ((.${VLESS_FULLSTACK_STATE_KEY}.finalmask_summary // \"\") == \"\"))" "$STATE_FILE" >/dev/null 2>&1; then
        fullstack_enabled="$(jq -r ".${VLESS_FULLSTACK_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        if [[ "$fullstack_enabled" == "true" ]]; then
            fullstack_json="$(jq -c ".${VLESS_FULLSTACK_STATE_KEY}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
            [[ -n "$fullstack_json" && "$fullstack_json" != "null" ]] || fullstack_json="$(jq -c --arg tag "$VLESS_FULLSTACK_TAG" '.inbounds[]? | select(.tag == $tag).streamSettings.finalmask // null' "$CONFIG_FILE" 2>/dev/null)"
            if validate_finalmask_json "$fullstack_json"; then
                set_finalmask_metadata_from_json "$fullstack_json"
                fullstack_fm_mode="$FINALMASK_MODE"
                fullstack_fm_preset="$FINALMASK_PRESET"
                fullstack_fm_summary="$FINALMASK_SUMMARY"
                changed="true"
            else
                diag_warn "无法推导 vless_fullstack FinalMask 元数据"
            fi
        else
            fullstack_fm_mode="off"
            fullstack_fm_preset="none"
            fullstack_fm_summary="off"
            changed="true"
        fi
    fi

    if jq -e ".${VLESS_XHTTP_REALITY_STATE_KEY}? and ((.${VLESS_XHTTP_REALITY_STATE_KEY}.flow // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
        inferred_xhttp_reality_flow="$REALITY_FLOW_NONE"
        diag_info "将补齐 vless_xhttp_reality.flow=none"
        changed="true"
    fi
    if jq -e ".${VLESS_ENC_REALITY_STATE_KEY}? and ((.${VLESS_ENC_REALITY_STATE_KEY}.flow // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
        inferred_enc_reality_flow="$REALITY_FLOW_NONE"
        diag_info "将补齐 vless_enc_reality.flow=none"
        changed="true"
    fi
    if jq -e ".${VLESS_FULLSTACK_STATE_KEY}? and ((.${VLESS_FULLSTACK_STATE_KEY}.flow // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
        inferred_fullstack_flow="$REALITY_FLOW_NONE"
        diag_info "将补齐 vless_fullstack.flow=none"
        changed="true"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        if jq -e '.ss2022? and ((.ss2022.listen_scope // "") == "")' "$STATE_FILE" >/dev/null 2>&1; then
            ss_scope="$(config_inbound_listen_scope "$SS_TAG")"
            [[ "$ss_scope" == "unknown" ]] && diag_warn "无法从 config 推导 ss2022.listen_scope" || changed="true"
        fi
        if jq -e '.vless_encryption? and ((.vless_encryption.listen_scope // "") == "")' "$STATE_FILE" >/dev/null 2>&1; then
            vless_scope="$(config_inbound_listen_scope "$VLESS_TAG")"
            [[ "$vless_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_encryption.listen_scope" || changed="true"
        fi
        if jq -e ".${REALITY_STATE_KEY}? and ((.${REALITY_STATE_KEY}.listen_scope // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
            reality_scope="$(config_inbound_listen_scope "$REALITY_TAG")"
            [[ "$reality_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_reality.listen_scope" || changed="true"
        fi
        if jq -e ".${VLESS_XHTTP_FM_STATE_KEY}? and ((.${VLESS_XHTTP_FM_STATE_KEY}.listen_scope // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
            xhttp_scope="$(config_inbound_listen_scope "$VLESS_XHTTP_FM_TAG")"
            [[ "$xhttp_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_xhttp_finalmask.listen_scope" || changed="true"
        fi
        if jq -e '.socks5? and ((.socks5.listen_scope // "") == "")' "$STATE_FILE" >/dev/null 2>&1; then
            socks_scope="$(config_inbound_listen_scope "$SOCKS_TAG")"
            [[ "$socks_scope" == "unknown" ]] && diag_warn "无法从 config 推导 socks5.listen_scope" || changed="true"
        fi
        if jq -e ".${VLESS_XHTTP_REALITY_STATE_KEY}? and ((.${VLESS_XHTTP_REALITY_STATE_KEY}.listen_scope // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
            xhttp_reality_scope="$(config_inbound_listen_scope "$VLESS_XHTTP_REALITY_TAG")"
            [[ "$xhttp_reality_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_xhttp_reality.listen_scope" || changed="true"
        fi
        if jq -e ".${VLESS_ENC_REALITY_STATE_KEY}? and ((.${VLESS_ENC_REALITY_STATE_KEY}.listen_scope // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
            enc_reality_scope="$(config_inbound_listen_scope "$VLESS_ENC_REALITY_TAG")"
            [[ "$enc_reality_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_enc_reality.listen_scope" || changed="true"
        fi
        if jq -e ".${VLESS_FULLSTACK_STATE_KEY}? and ((.${VLESS_FULLSTACK_STATE_KEY}.listen_scope // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
            fullstack_scope="$(config_inbound_listen_scope "$VLESS_FULLSTACK_TAG")"
            [[ "$fullstack_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_fullstack.listen_scope" || changed="true"
        fi
    fi

    if jq -e ".${REALITY_STATE_KEY}" "$STATE_FILE" >/dev/null 2>&1; then
        if [[ -z "$old_reality_flow" ]]; then
            inferred_reality_flow="$REALITY_FLOW_DEFAULT"
            diag_info "将补齐 vless_reality.flow=${REALITY_FLOW_DEFAULT}"
            changed="true"
        fi
        if [[ -z "$old_reality_link" ]]; then
            REALITY_PORT="$(jq -r ".${REALITY_STATE_KEY}.port // empty" "$STATE_FILE")"
            REALITY_UUID="$(jq -r ".${REALITY_STATE_KEY}.uuid // empty" "$STATE_FILE")"
            REALITY_PUBLIC_KEY="$(jq -r ".${REALITY_STATE_KEY}.public_key // empty" "$STATE_FILE")"
            REALITY_DEFAULT_SHORT_ID="$(jq -r ".${REALITY_STATE_KEY}.default_short_id // empty" "$STATE_FILE")"
            REALITY_SERVER_NAME="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE")"
            REALITY_SPIDER_X="$(jq -r ".${REALITY_STATE_KEY}.spider_x // \"/\"" "$STATE_FILE")"
            REALITY_FLOW="${old_reality_flow:-$inferred_reality_flow}"
            if [[ -n "$REALITY_FLOW" ]] && reality_link="$(build_reality_share_link 2>/dev/null)"; then
                diag_info "将补齐 vless_reality.link"
                changed="true"
            else
                diag_warn "无法推导 Reality link，缺少 public_key/short_id/server_name/flow 等字段"
            fi
        fi
    fi

    if jq -e ".${VLESS_XHTTP_FM_STATE_KEY}" "$STATE_FILE" >/dev/null 2>&1; then
        if [[ -z "$old_xhttp_enabled" ]]; then
            if [[ -f "$CONFIG_FILE" ]]; then
                inferred_xhttp_enabled="$(jq -r --arg tag "$VLESS_XHTTP_FM_TAG" 'if any(.inbounds[]?; .tag == $tag) then ([.inbounds[]? | select(.tag == $tag).streamSettings | has("finalmask")][0] | tostring) else empty end' "$CONFIG_FILE" 2>/dev/null)"
            fi
            if [[ -n "$inferred_xhttp_enabled" && "$inferred_xhttp_enabled" != "null" ]]; then
                diag_info "将从 config 补齐 vless_xhttp_finalmask.finalmask_enabled"
                changed="true"
            else
                diag_warn "无法推导 vless_xhttp_finalmask.finalmask_enabled"
            fi
        fi
        if [[ "${old_xhttp_enabled:-$inferred_xhttp_enabled}" == "true" && (-z "$old_xhttp_finalmask_json" || "$old_xhttp_finalmask_json" == "null") ]]; then
            if [[ -f "$CONFIG_FILE" ]]; then
                inferred_xhttp_finalmask_json="$(jq -c --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag).streamSettings.finalmask // null' "$CONFIG_FILE" 2>/dev/null)"
            fi
            if [[ -n "$inferred_xhttp_finalmask_json" && "$inferred_xhttp_finalmask_json" != "null" ]]; then
                diag_info "将从 config 补齐 vless_xhttp_finalmask.finalmask_json"
                changed="true"
            else
                diag_warn "无法推导 vless_xhttp_finalmask.finalmask_json"
            fi
        fi
        if [[ -z "$old_xhttp_link" ]]; then
            XHTTP_PORT="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.port // empty" "$STATE_FILE")"
            XHTTP_PATH="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.path // empty" "$STATE_FILE")"
            VLESS_UUID="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.uuid // empty" "$STATE_FILE")"
            VLESS_ENCRYPTION="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.encryption // empty" "$STATE_FILE")"
            XHTTP_FINALMASK_ENABLED="${old_xhttp_enabled:-$inferred_xhttp_enabled}"
            XHTTP_FINALMASK_JSON="${old_xhttp_finalmask_json:-$inferred_xhttp_finalmask_json}"
            [[ -n "$XHTTP_FINALMASK_JSON" ]] || XHTTP_FINALMASK_JSON="null"
            if [[ -n "$XHTTP_FINALMASK_ENABLED" ]] && xhttp_link="$(build_vless_xhttp_finalmask_share_link 2>/dev/null)"; then
                diag_info "将补齐 vless_xhttp_finalmask.link"
                changed="true"
            else
                diag_warn "无法推导 XHTTP link，缺少 path/encryption/uuid/finalmask_enabled 等字段"
            fi
        fi
    fi

    if [[ "$(china_direct_block_rule_mode)" != "off" ]]; then
        if [[ "$(jq -r '.cnblock_user_set // empty' "$STATE_FILE" 2>/dev/null)" != "true" ]]; then
            diag_warn "检测到旧版中国大陆直连屏蔽规则，可能来自旧默认策略。1.1.6 起默认关闭；如不需要请执行 ike cnblock off。"
        fi
    fi

    [[ "$changed" == "true" ]] || {
        diag_ok "未发现需要迁移的 state 字段"
        return 0
    }
    [[ "$dry_run" == "true" ]] && {
        diag_info "dry-run：未修改 config/state"
        return 0
    }

    tmp="$(mktemp)" || return 1
    jq --arg reality_flow "$inferred_reality_flow" \
        --arg reality_link "$reality_link" \
        --arg xhttp_enabled "${inferred_xhttp_enabled}" \
        --arg xhttp_link "$xhttp_link" \
        --argjson xhttp_finalmask_json "$inferred_xhttp_finalmask_json" \
        --arg reality_key "$REALITY_STATE_KEY" \
        --arg xhttp_key "$VLESS_XHTTP_FM_STATE_KEY" \
        --arg ss_scope "$ss_scope" \
        --arg vless_scope "$vless_scope" \
        --arg reality_scope "$reality_scope" \
        --arg xhttp_scope "$xhttp_scope" \
        --arg socks_scope "$socks_scope" \
        --arg xhttp_reality_scope "$xhttp_reality_scope" \
        --arg enc_reality_scope "$enc_reality_scope" \
        --arg fullstack_scope "$fullstack_scope" \
        --arg xhttp_fm_mode "$xhttp_fm_mode" \
        --arg xhttp_fm_preset "$xhttp_fm_preset" \
        --arg xhttp_fm_summary "$xhttp_fm_summary" \
        --arg fullstack_fm_mode "$fullstack_fm_mode" \
        --arg fullstack_fm_preset "$fullstack_fm_preset" \
        --arg fullstack_fm_summary "$fullstack_fm_summary" \
        --arg xhttp_reality_flow "$inferred_xhttp_reality_flow" \
        --arg enc_reality_flow "$inferred_enc_reality_flow" \
        --arg fullstack_flow "$inferred_fullstack_flow" \
        --arg xhttp_reality_key "$VLESS_XHTTP_REALITY_STATE_KEY" \
        --arg enc_reality_key "$VLESS_ENC_REALITY_STATE_KEY" \
        --arg fullstack_key "$VLESS_FULLSTACK_STATE_KEY" '
        def fill_scope($key; $scope):
          if .[$key]? and ((.[$key].listen_scope // "") == "") and $scope != "" and $scope != "unknown"
          then .[$key].listen_scope = $scope
          else .
          end;
        def fill_flow($key; $flow):
          if .[$key]? and ((.[$key].flow // "") == "") and $flow != ""
          then .[$key].flow = $flow
          else .
          end;
        if .[$reality_key]? then
          (if ((.[$reality_key].flow // "") == "" and $reality_flow != "") then .[$reality_key].flow = $reality_flow else . end) |
          (if ($reality_link != "") then .[$reality_key].link = (.[$reality_key].link // $reality_link) else . end)
        else . end |
        if .[$xhttp_key]? then
          (if ((.[$xhttp_key] | has("finalmask_enabled") | not) and $xhttp_enabled != "") then .[$xhttp_key].finalmask_enabled = ($xhttp_enabled == "true") else . end) |
          (if ((.[$xhttp_key].finalmask_mode // "") == "" and $xhttp_fm_mode != "") then .[$xhttp_key].finalmask_mode = $xhttp_fm_mode else . end) |
          (if ((.[$xhttp_key].finalmask_preset // "") == "" and $xhttp_fm_preset != "") then .[$xhttp_key].finalmask_preset = $xhttp_fm_preset else . end) |
          (if ((.[$xhttp_key].finalmask_summary // "") == "" and $xhttp_fm_summary != "") then .[$xhttp_key].finalmask_summary = $xhttp_fm_summary else . end) |
          (if ((.[$xhttp_key].finalmask_json // null) == null and $xhttp_finalmask_json != null) then .[$xhttp_key].finalmask_json = $xhttp_finalmask_json else . end) |
          (if ($xhttp_link != "") then .[$xhttp_key].link = (.[$xhttp_key].link // $xhttp_link) else . end)
        else . end |
        fill_scope("ss2022"; $ss_scope) |
        fill_scope("vless_encryption"; $vless_scope) |
        fill_scope($reality_key; $reality_scope) |
        fill_scope($xhttp_key; $xhttp_scope) |
        fill_scope("socks5"; $socks_scope) |
        fill_scope($xhttp_reality_key; $xhttp_reality_scope) |
        fill_scope($enc_reality_key; $enc_reality_scope) |
        fill_scope($fullstack_key; $fullstack_scope) |
        fill_flow($xhttp_reality_key; $xhttp_reality_flow) |
        fill_flow($enc_reality_key; $enc_reality_flow) |
        fill_flow($fullstack_key; $fullstack_flow) |
        (if .[$fullstack_key]? then
          (if ((.[$fullstack_key].finalmask_mode // "") == "" and $fullstack_fm_mode != "") then .[$fullstack_key].finalmask_mode = $fullstack_fm_mode else . end) |
          (if ((.[$fullstack_key].finalmask_preset // "") == "" and $fullstack_fm_preset != "") then .[$fullstack_key].finalmask_preset = $fullstack_fm_preset else . end) |
          (if ((.[$fullstack_key].finalmask_summary // "") == "" and $fullstack_fm_summary != "") then .[$fullstack_key].finalmask_summary = $fullstack_fm_summary else . end)
        else . end)
      ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
    ok "[迁移] state 兼容字段已补齐。"
}

migrate_old_config() {
    normalize_config_schema
}

detect_legacy_tags() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    jq -r '.inbounds[]?.tag // empty' "$CONFIG_FILE" 2>/dev/null | grep -E '^(forward-|tunnel-)' || true
}

normalize_config_schema() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local tmp

    command -v jq >/dev/null 2>&1 || return 1
    tmp="$(mktemp)" || return 1
    if ! jq '
      def normalize_reality_target:
        if (.streamSettings? | type) == "object" and .streamSettings.security == "reality" and (.streamSettings.realitySettings? | type) == "object" then
          .streamSettings.realitySettings.target = (.streamSettings.realitySettings.target // .streamSettings.realitySettings.dest // empty) |
          del(.streamSettings.realitySettings.dest)
        else
          .
        end;
      if (.inbounds? | type) == "array" then
        .inbounds = [.inbounds[] | normalize_reality_target]
      else
        .
      end
    ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

run_migrate_command() {
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run="true"
                ;;
            *)
                err "[失败] 未知 migrate 参数: $1"
                echo "用法: ike migrate [--dry-run]"
                return 1
                ;;
        esac
        shift
    done

    echo -e "\n${YELLOW}旧配置迁移检查${PLAIN}"
    echo "----------------------------------------"
    [[ "$dry_run" == "true" ]] || backup_before_migration
    migrate_old_config
    migrate_old_state "$dry_run"
}

create_purge_backup() {
    local backup_dir timestamp archive

    backup_dir="${XRAY_PURGE_BACKUP_DIR:-/var/backups/xray-oneclick}"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    archive="${backup_dir}/xray-oneclick-purge-${timestamp}.tar.gz"
    mkdir -p "$backup_dir"
    tar -czf "$archive" "$CONFIG_DIR" "$(service_file_path)" "$BIN_PATH" 2>/dev/null || true
    chmod 600 "$archive" 2>/dev/null || true
    echo "$archive"
}

run_uninstall_command() {
    local mode="keep-config"
    local dry_run="false"
    local yes="false"
    local service_file
    local -a remove_paths=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keep-config)
                mode="keep-config"
                ;;
            --purge)
                mode="purge"
                ;;
            --dry-run)
                dry_run="true"
                ;;
            --yes | -y)
                yes="true"
                ;;
            *)
                err "[失败] 未知 uninstall 参数: $1"
                echo "用法: ike uninstall [--keep-config|--purge] [--dry-run] [--yes]"
                return 1
                ;;
        esac
        shift
    done

    service_file="$(service_file_path)"
    remove_paths=("$BIN_PATH" "$SHORTCUT_PATH" "$LEGACY_SHORTCUT_PATH" "$INSTALLER_PATH")
    if [[ -f "$service_file" ]]; then
        if grep -q "Managed by Xray-OneClick" "$service_file"; then
            remove_paths+=("$service_file")
        else
            diag_warn "检测到非本项目 service，默认不删除: $service_file"
        fi
    fi
    if [[ "$mode" == "purge" ]]; then
        if [[ "$yes" != "true" ]] && ! env_truthy "${XRAY_ONECLICK_YES:-}"; then
            if [[ -t 0 ]]; then
                confirm_yes_no "purge 会删除配置、state 和日志，是否继续?" "n" || return 1
            else
                err "[卸载] purge 会删除配置和日志，非交互模式必须添加 --yes。"
                return 1
            fi
        fi
        remove_paths+=("$CONFIG_DIR" "$(log_dir_path)" "$INSTALLER_DIR")
    else
        diag_info "keep-config: 保留 $CONFIG_FILE 和 $STATE_FILE"
    fi

    echo -e "\n${YELLOW}卸载预览${PLAIN}"
    printf '将删除: %s\n' "${remove_paths[@]}"
    [[ "$dry_run" == "true" ]] && {
        diag_info "dry-run：未删除任何文件"
        return 0
    }

    if [[ "$mode" == "purge" ]]; then
        diag_info "最终备份包: $(create_purge_backup)"
    fi
    stop_service
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    for path in "${remove_paths[@]}"; do
        [[ -e "$path" ]] || continue
        rm -rf "$path"
    done
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
    ok "[卸载] 完成。"
}

show_reality_usage() {
    cat <<'EOF'
用法:
  ike reality install [--port PORT] [--defender-port PORT] [--sni DOMAIN] [--flow vision|none] [--dry-run] [--yes] [--empty-clients]
  ike reality show
  ike reality remove
  ike view reality
EOF
}

show_xray_usage() {
    cat <<'EOF'
用法:
  ike xray version
  ike xray upgrade [--version vX.Y.Z] [--xray-channel stable|prerelease] [--dry-run] [--restart]

环境变量:
  XRAY_VERSION=vX.Y.Z
  XRAY_CHANNEL=stable|prerelease
EOF
}

show_xhttp_usage() {
    cat <<'EOF'
用法:
  ike xhttp install [--port PORT] [--path /path] [--finalmask on|off] [--finalmask-preset conservative|balanced|aggressive] [--fm-length 100-200] [--fm-delay 10-20] [--fm-max-split 3-6] [--finalmask-json JSON] [--dry-run] [--auth x25519|mlkem768]
  ike xhttp show
  ike xhttp remove
  ike view xhttp
EOF
}

run_reality_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_reality_usage
            ;;
        install)
            shift
            REALITY_PORT_REQUEST=""
            REALITY_DEFENDER_PORT_REQUEST=""
            REALITY_SNI_REQUEST=""
            REALITY_EMPTY_CLIENTS="false"
            REALITY_ASSUME_YES="false"
            REALITY_FLOW="$REALITY_FLOW_DEFAULT"
            REALITY_DRY_RUN="false"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        REALITY_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --defender-port)
                        REALITY_DEFENDER_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --sni)
                        REALITY_SNI_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --flow)
                        if [[ -z "${2:-}" ]] || ! REALITY_FLOW="$(normalize_reality_flow "$2")"; then
                            err "[Reality] --flow 仅支持 none 或 vision。"
                            return 1
                        fi
                        shift 2
                        ;;
                    --empty-clients)
                        REALITY_EMPTY_CLIENTS="true"
                        shift
                        ;;
                    --yes | -y)
                        REALITY_ASSUME_YES="true"
                        shift
                        ;;
                    --dry-run)
                        REALITY_DRY_RUN="true"
                        REALITY_SKIP_TLS_TEST="${REALITY_SKIP_TLS_TEST:-1}"
                        shift
                        ;;
                    help | -h | --help)
                        show_reality_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 reality install 参数: $1"
                        show_reality_usage
                        return 1
                        ;;
                esac
            done
            if [[ "$REALITY_DRY_RUN" == "true" ]]; then
                configure_reality "dry-run" && install_reality
            else
                prepare_system || return 1
                configure_reality "cli" && install_reality
            fi
            ;;
        show | "")
            init_state
            print_reality_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_reality_config
            ;;
        *)
            err "[失败] 未知 reality 参数: $action"
            show_reality_usage
            return 1
            ;;
    esac
}

run_xhttp_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_xhttp_usage
            ;;
        install)
            shift
            XHTTP_PORT_REQUEST=""
            XHTTP_PATH_REQUEST=""
            XHTTP_FINALMASK_REQUEST="false"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            XHTTP_DRY_RUN="false"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        XHTTP_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --path)
                        XHTTP_PATH_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --finalmask)
                        XHTTP_FINALMASK_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --finalmask-preset | --fm-packets | --fm-length | --fm-delay | --fm-max-split | --finalmask-json)
                        if ! parse_finalmask_args "$1" "${2:-}"; then
                            return 1
                        fi
                        shift "$FINALMASK_ARG_SHIFT"
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        shift 2
                        ;;
                    --enc-method)
                        VLESS_ENC_METHOD="${2:-}"
                        VLESS_MODE="advanced"
                        shift 2
                        ;;
                    --rtt)
                        VLESS_CLIENT_RTT="${2:-}"
                        VLESS_MODE="advanced"
                        shift 2
                        ;;
                    --ticket)
                        VLESS_SERVER_TICKET="${2:-}"
                        VLESS_MODE="advanced"
                        shift 2
                        ;;
                    --dry-run)
                        XHTTP_DRY_RUN="true"
                        shift
                        ;;
                    help | -h | --help)
                        show_xhttp_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 xhttp install 参数: $1"
                        show_xhttp_usage
                        return 1
                        ;;
                esac
            done
            case "$VLESS_AUTH" in
                x25519 | mlkem768) ;;
                *)
                    err "[XHTTP] --auth 仅支持 x25519 或 mlkem768。"
                    return 1
                    ;;
            esac
            if [[ "$XHTTP_DRY_RUN" == "true" ]]; then
                configure_vless_xhttp_finalmask "dry-run" && install_vless_xhttp_finalmask
            else
                prepare_system || return 1
                configure_vless_xhttp_finalmask "cli" && install_vless_xhttp_finalmask
            fi
            ;;
        show | "")
            init_state
            print_vless_xhttp_finalmask_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_vless_xhttp_finalmask_config
            ;;
        *)
            err "[失败] 未知 xhttp 参数: $action"
            show_xhttp_usage
            return 1
            ;;
    esac
}

show_advanced_profile_usage() {
    local kind="$1"

    case "$kind" in
        xhttp-reality)
            cat <<'EOF'
用法:
  ike xhttp-reality install [--port PORT] [--path /path] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--dry-run] [--yes]
  ike xhttp-reality show
  ike xhttp-reality remove
  ike view xhttp-reality
EOF
            ;;
        enc-reality)
            cat <<'EOF'
用法:
  ike enc-reality install [--port PORT] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--dry-run] [--yes] [--auth x25519|mlkem768]
  ike enc-reality show
  ike enc-reality remove
  ike view enc-reality
EOF
            ;;
        fullstack)
            cat <<'EOF'
用法:
  ike fullstack install [--port PORT] [--path /path] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--finalmask on|off] [--finalmask-preset conservative|balanced|aggressive] [--fm-length 100-200] [--fm-delay 10-20] [--fm-max-split 3-6] [--finalmask-json JSON] [--dry-run] [--yes] [--auth x25519|mlkem768]
  ike fullstack show
  ike fullstack remove
  ike view fullstack
EOF
            ;;
    esac
}

run_advanced_profile_command() {
    local kind="$1"
    local action="${2:-show}"

    case "$action" in
        help | -h | --help)
            show_advanced_profile_usage "$kind"
            ;;
        install)
            shift 2
            ADVANCED_PORT_REQUEST=""
            ADVANCED_PATH_REQUEST=""
            ADVANCED_SNI_REQUEST=""
            ADVANCED_FINALMASK_REQUEST="false"
            ADVANCED_FINALMASK_SPECIFIED="false"
            ADVANCED_FLOW="$REALITY_FLOW_NONE"
            ADVANCED_FALLBACK_LIMIT_REQUEST="off"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            ADVANCED_AUTH_SPECIFIED="false"
            ADVANCED_ASSUME_YES="false"
            ADVANCED_DRY_RUN="false"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        ADVANCED_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --path)
                        ADVANCED_PATH_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --sni)
                        ADVANCED_SNI_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --flow)
                        if [[ -z "${2:-}" ]] || ! ADVANCED_FLOW="$(normalize_reality_flow "$2")"; then
                            err "[高级组合] --flow 仅支持 none 或 vision。"
                            return 1
                        fi
                        shift 2
                        ;;
                    --fallback-limit)
                        ADVANCED_FALLBACK_LIMIT_REQUEST="${2:-}"
                        case "${ADVANCED_FALLBACK_LIMIT_REQUEST}" in
                            off | conservative) ;;
                            *)
                                err "[高级组合] --fallback-limit 仅支持 off 或 conservative。"
                                return 1
                                ;;
                        esac
                        shift 2
                        ;;
                    --finalmask)
                        ADVANCED_FINALMASK_REQUEST="${2:-}"
                        ADVANCED_FINALMASK_SPECIFIED="true"
                        shift 2
                        ;;
                    --finalmask-preset | --fm-packets | --fm-length | --fm-delay | --fm-max-split | --finalmask-json)
                        if ! parse_finalmask_args "$1" "${2:-}"; then
                            return 1
                        fi
                        ADVANCED_FINALMASK_SPECIFIED="true"
                        shift "$FINALMASK_ARG_SHIFT"
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --enc-method)
                        VLESS_ENC_METHOD="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --rtt)
                        VLESS_CLIENT_RTT="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --ticket)
                        VLESS_SERVER_TICKET="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --yes | -y)
                        ADVANCED_ASSUME_YES="true"
                        shift
                        ;;
                    --dry-run)
                        ADVANCED_DRY_RUN="true"
                        REALITY_SKIP_TLS_TEST="${REALITY_SKIP_TLS_TEST:-1}"
                        shift
                        ;;
                    help | -h | --help)
                        show_advanced_profile_usage "$kind"
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 ${kind} install 参数: $1"
                        show_advanced_profile_usage "$kind"
                        return 1
                        ;;
                esac
            done
            if [[ -n "$ADVANCED_PATH_REQUEST" ]] && ! advanced_profile_has_xhttp "$kind"; then
                err "[高级组合] ${kind} 不支持 --path。"
                return 1
            fi
            if [[ "$ADVANCED_FINALMASK_SPECIFIED" == "true" ]] && ! advanced_profile_has_finalmask "$kind"; then
                err "[高级组合] ${kind} 不支持 --finalmask。"
                return 1
            fi
            if [[ "$ADVANCED_AUTH_SPECIFIED" == "true" ]] && ! advanced_profile_has_encryption "$kind"; then
                err "[高级组合] ${kind} 不支持 VLESS Encryption 参数。"
                return 1
            fi
            if advanced_profile_has_encryption "$kind"; then
                case "$VLESS_AUTH" in
                    x25519 | mlkem768) ;;
                    *)
                        err "[高级组合] --auth 仅支持 x25519 或 mlkem768。"
                        return 1
                        ;;
                esac
            fi
            if [[ "$ADVANCED_DRY_RUN" == "true" ]]; then
                configure_advanced_profile "$kind" "dry-run" && install_advanced_profile "$kind"
            else
                prepare_system || return 1
                configure_advanced_profile "$kind" "cli" && install_advanced_profile "$kind"
            fi
            ;;
        show | "")
            init_state
            print_advanced_profile_result "$kind" "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_advanced_profile_config "$kind"
            ;;
        *)
            err "[失败] 未知 ${kind} 参数: $action"
            show_advanced_profile_usage "$kind"
            return 1
            ;;
    esac
}

run_forward_command() {
    run_tunnel_command "$@"
}

setup_test_config_generation_env() {
    local root="${IKE_TEST_ROOT:-}"
    local root_parent
    local detected_xray=""

    if [[ -z "$root" ]]; then
        root_parent="${IKE_TEST_TMP_PARENT:-${PWD:-.}/.tmp}"
        mkdir -p "$root_parent" || return 1
        root="$(mktemp -d "${root_parent}/config-generation.XXXXXX")" || return 1
        IKE_TEST_ROOT="$root"
    fi
    mkdir -p "$root" || return 1

    CONFIG_DIR="${root}/etc/xray"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    ASSET_DIR="${root}/share/xray"
    INSTALLER_DIR="${root}/share/ike"
    INSTALLER_PATH="${INSTALLER_DIR}/install.sh"
    SHORTCUT_PATH="${root}/bin/ike"
    LEGACY_SHORTCUT_PATH="${root}/bin/sb"
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR" "$INSTALLER_DIR" "${root}/bin" || return 1
    mkdir -p "${root}/tmp" || return 1
    export TMPDIR="${root}/tmp"

    if [[ -n "${XRAY_BIN:-}" ]]; then
        BIN_PATH="$XRAY_BIN"
    elif detected_xray="$(command -v xray 2>/dev/null)"; then
        BIN_PATH="$detected_xray"
    else
        BIN_PATH="${root}/bin/xray-missing"
    fi

    IKE_CONFIG_OUT="${IKE_CONFIG_OUT:-${root}/config.json}"
    IKE_TEST_MODE="1"
    REALITY_SKIP_TLS_TEST="1"
    XRAY_ONECLICK_YES="1"
    CURRENT_LINK_VIEW_MODE="ipv4"
    IPV4_HOST="${IPV4_HOST:-203.0.113.10}"
    init_config || return 1
    init_state || return 1
}

run_test_config_generate_command() {
    local profile="${1:-}"
    local port="" defender_port="" path="" sni="www.microsoft.com"
    local finalmask="" finalmask_preset="balanced" fallback_limit="off"
    local kind=""

    [[ -n "$profile" ]] || {
        err "[test] usage: test-config-generate PROFILE [--output FILE]"
        return 1
    }
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                IKE_CONFIG_OUT="${2:-}"
                [[ -n "$IKE_CONFIG_OUT" ]] || {
                    err "[test] --output requires a file path"
                    return 1
                }
                shift 2
                ;;
            --port)
                port="${2:-}"
                shift 2
                ;;
            --defender-port)
                defender_port="${2:-}"
                shift 2
                ;;
            --path)
                path="${2:-}"
                shift 2
                ;;
            --sni)
                sni="${2:-}"
                shift 2
                ;;
            --finalmask)
                finalmask="${2:-}"
                shift 2
                ;;
            --finalmask-preset)
                finalmask_preset="${2:-balanced}"
                shift 2
                ;;
            --fallback-limit)
                fallback_limit="${2:-off}"
                shift 2
                ;;
            *)
                err "[test] unknown test-config-generate option: $1"
                return 1
                ;;
        esac
    done

    setup_test_config_generation_env || return 1

    case "$profile" in
        reality)
            REALITY_PORT_REQUEST="${port:-30004}"
            REALITY_DEFENDER_PORT_REQUEST="${defender_port:-40004}"
            REALITY_SNI_REQUEST="$sni"
            REALITY_EMPTY_CLIENTS="false"
            REALITY_ASSUME_YES="true"
            REALITY_FLOW="$REALITY_FLOW_DEFAULT"
            REALITY_DRY_RUN="true"
            configure_reality "dry-run" && install_reality
            ;;
        xhttp-off | xhttp)
            XHTTP_PORT_REQUEST="${port:-30005}"
            XHTTP_PATH_REQUEST="${path:-/api/offline}"
            XHTTP_FINALMASK_REQUEST="${finalmask:-off}"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            XHTTP_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_vless_xhttp_finalmask "dry-run" && install_vless_xhttp_finalmask
            ;;
        xhttp-balanced | xhttp-finalmask-balanced)
            XHTTP_PORT_REQUEST="${port:-30005}"
            XHTTP_PATH_REQUEST="${path:-/api/balanced}"
            XHTTP_FINALMASK_REQUEST="${finalmask:-on}"
            FINALMASK_PRESET_REQUEST="${finalmask_preset:-balanced}"
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            XHTTP_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_vless_xhttp_finalmask "dry-run" && install_vless_xhttp_finalmask
            ;;
        xhttp-reality | enc-reality | fullstack)
            case "$profile" in
                xhttp-reality)
                    kind="xhttp-reality"
                    port="${port:-30006}"
                    path="${path:-/api/xhttp-reality}"
                    finalmask="off"
                    ;;
                enc-reality)
                    kind="enc-reality"
                    port="${port:-30007}"
                    path=""
                    finalmask="off"
                    ;;
                fullstack)
                    kind="fullstack"
                    port="${port:-30008}"
                    path="${path:-/api/fullstack}"
                    finalmask="${finalmask:-off}"
                    ;;
            esac
            ADVANCED_PORT_REQUEST="$port"
            ADVANCED_PATH_REQUEST="$path"
            ADVANCED_SNI_REQUEST="$sni"
            ADVANCED_FINALMASK_REQUEST="$finalmask"
            ADVANCED_FINALMASK_SPECIFIED="true"
            ADVANCED_FLOW="$REALITY_FLOW_NONE"
            ADVANCED_FALLBACK_LIMIT_REQUEST="$fallback_limit"
            FINALMASK_PRESET_REQUEST="${finalmask_preset:-balanced}"
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            ADVANCED_AUTH_SPECIFIED="false"
            ADVANCED_ASSUME_YES="true"
            ADVANCED_DRY_RUN="true"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            configure_advanced_profile "$kind" "dry-run" && install_advanced_profile "$kind"
            ;;
        *)
            err "[test] unknown profile: $profile"
            return 1
            ;;
    esac

    [[ -s "$IKE_CONFIG_OUT" ]] || {
        err "[test] offline config was not written: $IKE_CONFIG_OUT"
        return 1
    }
}

show_help() {
    cat <<'EOF'
Xray-OneClick 命令帮助

常用命令:
  ike
  ike preflight
  ike view
  ike view doctor
  ike xray version
  ike xray upgrade --dry-run
  ike xray upgrade --version vX.Y.Z --restart
  ike xray upgrade --xray-channel prerelease --restart
  env: XRAY_VERSION=vX.Y.Z / XRAY_CHANNEL=stable|prerelease
  ike doctor all
  ike doctor preflight
  ike doctor proxy
  ike doctor reality-key
  ike doctor reality
  ike doctor xhttp
  ike doctor xhttp-reality
  ike doctor enc-reality
  ike doctor fullstack
  ike smoke reality
  ike smoke xhttp --restart
  ike smoke xhttp-reality
  ike smoke enc-reality --restart
  ike smoke fullstack --restart
  ike smoke all
  ike export report --output /root/xray-report.txt
  ike export clients --output /root/xray-clients.txt
  ike update
  ike backup
  ike endpoint show
  ike endpoint set
  ike endpoint clear
  ike endpoint detect
  ike config path
  ike config test
  ike config edit
  ike service status
  ike service install
  ike service restart
  ike service logs
  ike service repair
  ike logs
  ike migrate --dry-run
  ike migrate
  ike uninstall --dry-run
  ike uninstall --keep-config
  ike uninstall --purge --yes
  ike cnblock
  ike cnblock basic
  ike cnblock enhanced
  ike cnblock off
  说明：中国大陆直连屏蔽默认关闭，只在手动启用后生效。
  ike safety enhanced on
  ike safety enhanced off
  ike reality install
  ike reality install --dry-run
  ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com
  ike reality install --port 30004 --defender-port 40004 --sni www.abmindustriesgroup.com --dry-run
  ike reality show
  ike reality remove
  ike xhttp install
  ike xhttp install --dry-run
  ike xhttp install --port 30005 --path /api/demo --finalmask on
  ike xhttp install --finalmask on --finalmask-preset balanced
  ike xhttp install --finalmask on --fm-packets tlshello --fm-length 80-160 --fm-delay 10-30 --fm-max-split 4-8
  ike xhttp install --port 30005 --path /api/demo --finalmask off
  ike xhttp install --port 30005 --path /api/demo --finalmask on --dry-run
  ike xhttp show
  ike xhttp remove
  ike view reality
  ike view xhttp
  ike xhttp-reality install
  ike xhttp-reality install --dry-run
  ike xhttp-reality install --port 30006 --path /api/test --sni www.abmindustriesgroup.com
  ike xhttp-reality install --flow vision
  ike xhttp-reality show
  ike xhttp-reality remove
  ike enc-reality install
  ike enc-reality install --dry-run
  ike enc-reality install --port 30007 --sni www.abmindustriesgroup.com
  ike enc-reality install --flow vision
  ike enc-reality show
  ike enc-reality remove
  ike fullstack install
  ike fullstack install --dry-run
  ike fullstack install --port 30008 --path /api/test --sni www.abmindustriesgroup.com --finalmask on
  ike fullstack install --finalmask on --finalmask-preset balanced
  ike fullstack install --flow vision --finalmask off
  ike fullstack install --port 30008 --path /api/test --sni www.abmindustriesgroup.com --finalmask off
  ike fullstack show
  ike fullstack remove
  ike view xhttp-reality
  ike view enc-reality
  ike view fullstack
  ike tunnel list
  ike tunnel add
  ike tunnel add safe
  ike tunnel add relay
  ike tunnel add map
  ike tunnel edit
  ike tunnel enable
  ike tunnel disable
  ike tunnel del
  ike tunnel doctor
  ike tunnel group list
  ike tunnel group doctor
  ike tunnel template
  ike tunnel ports
  ike tunnel export
  ike tunnel import
  ike tunnel import /path/to/tunnels.json --yes
  ike tunnel bundle export
  ike tunnel bundle import /path/to/tunnels.json --yes
  ike tunnel generate-script
  ike tunnel generate-relay-script
  ike tunnel generate-client-script
  ike bootstrap
  ike forward list
  ike forward add
  ike forward add safe
  ike forward add relay
  ike forward edit
  ike forward enable
  ike forward disable
  ike forward del
  ike forward doctor
  ike forward template
  ike forward ports
  ike forward export
  ike forward import
  ike version

说明：ike forward ... 是兼容别名，新用户建议使用 ike tunnel ...
EOF
}

show_version() {
    echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"
    echo "Repository: ${REPO_URL}"
    if [[ -x "$BIN_PATH" ]]; then
        echo
        echo "Xray: $(detect_xray_version 2>/dev/null || printf '%s' '版本信息读取失败')"
    else
        echo "Xray: 未安装 (${BIN_PATH})"
    fi
}

main() {
    case "${1:-}" in
        help | -h | --help)
            show_help
            return 0
            ;;
        version | --version)
            show_version
            return 0
            ;;
        "" | preflight | view | doctor | smoke | export | xray | migrate | uninstall | update | backup | endpoint | config | service | logs | cnblock | safety | tunnel | forward | reality | xhttp | xhttp-reality | enc-reality | fullstack | bootstrap | test-config-generate) ;;
        *)
            err "[失败] 未知命令: $1"
            echo "运行 ike help 查看可用命令。"
            return 1
            ;;
    esac

    if [[ "${1:-}" == "preflight" ]]; then
        shift
        run_preflight_command "$@"
        return $?
    fi

    if [[ "${1:-}" == "test-config-generate" ]]; then
        shift
        run_test_config_generate_command "$@"
        return $?
    fi

    ensure_root
    check_os
    detect_arch
    apply_env_endpoint_if_needed || return 1

    case "${1:-}" in
        "")
            show_menu
            ;;
        preflight)
            shift
            run_preflight_command "$@"
            ;;
        view)
            shift
            run_view_command "$@"
            ;;
        xray)
            shift
            run_xray_command "$@"
            ;;
        migrate)
            shift
            run_migrate_command "$@"
            ;;
        uninstall)
            shift
            run_uninstall_command "$@"
            ;;
        doctor)
            shift
            run_doctor_command "$@"
            ;;
        smoke)
            shift
            run_smoke_command "$@"
            ;;
        export)
            shift
            run_export_command "$@"
            ;;
        update)
            update_xray_core
            ;;
        backup)
            export_current_config_backup
            ;;
        endpoint)
            run_endpoint_command "${2:-show}"
            ;;
        config)
            run_config_command "${2:-path}"
            ;;
        service)
            shift
            run_service_command "$@"
            ;;
        logs)
            run_logs_command
            ;;
        cnblock)
            run_cnblock_command "${2:-}"
            ;;
        safety)
            run_safety_command "${2:-}" "${3:-}"
            ;;
        tunnel)
            shift
            run_tunnel_command "$@"
            ;;
        forward)
            shift
            run_forward_command "$@"
            ;;
        reality)
            shift
            run_reality_command "$@"
            ;;
        xhttp)
            shift
            run_xhttp_command "$@"
            ;;
        xhttp-reality)
            run_advanced_profile_command "xhttp-reality" "${2:-show}" "${@:3}"
            ;;
        enc-reality)
            run_advanced_profile_command "enc-reality" "${2:-show}" "${@:3}"
            ;;
        fullstack)
            run_advanced_profile_command "fullstack" "${2:-show}" "${@:3}"
            ;;
        bootstrap)
            run_bootstrap_command
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi


