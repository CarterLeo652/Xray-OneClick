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
    "40-network.sh"
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
    "56-tunnel.sh"
    "70-view.sh"
    "71-cli-view.sh"
    "80-menu.sh"
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



