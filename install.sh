#!/bin/bash
# shellcheck disable=SC2015

set -o pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

SERVICE_NAME="xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
STATE_FILE="${CONFIG_DIR}/installer-state.json"
ASSET_DIR="/usr/local/share/xray"
BIN_PATH="/usr/local/bin/xray"
SHORTCUT_PATH="/usr/local/bin/ike"
LEGACY_SHORTCUT_PATH="/usr/local/bin/sb"
INSTALLER_DIR="/usr/local/share/ike"
INSTALLER_PATH="${INSTALLER_DIR}/install.sh"
SCRIPT_NAME="Xray-OneClick"
SCRIPT_VERSION="0.2.0-beta.3"
REPO_URL="https://github.com/ike-sh/Xray-OneClick"
RAW_SCRIPT_URL="https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/install.sh"
XRAY_RELEASE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download"
MIN_ROOT_FREE_KB="204800"

SS_TAG="ss2022-in"
VLESS_TAG="vless-enc-in"
REALITY_TAG="vless+tcp+reality"
REALITY_DEFENDER_TAG="reality-defender"
REALITY_STATE_KEY="vless_reality"
REALITY_PORT_MIN="20000"
REALITY_PORT_MAX="50000"
REALITY_DEFENDER_PORT_MIN="39000"
REALITY_DEFENDER_PORT_MAX="49999"
REALITY_FLOW_DEFAULT="xtls-rprx-vision"
VLESS_XHTTP_FM_TAG="vless-enc-xhttp-finalmask-in"
VLESS_XHTTP_FM_STATE_KEY="vless_xhttp_finalmask"
SOCKS_TAG="socks-in"
TUNNEL_TAG_PREFIX="tunnel-"
LEGACY_FORWARD_TAG_PREFIX="forward-"
FORWARD_TAG_PREFIX="$TUNNEL_TAG_PREFIX"
TUNNEL_PROTOCOL="${TUNNEL_PROTOCOL:-dokodemo-door}"
BLOCK_OUTBOUND_TAG="BLOCK"
DEFAULT_SAFETY_BLOCK_PORTS="25,135,137,138,139,445,465,587"
ENHANCED_SAFETY_BLOCK_PORTS="69,161,162,389,636,1900,5353,5355,11211"

LINK_VIEW_MODE="dual"
OS_TYPE=""
INIT_SYSTEM=""
ARCH=""
XRAY_ASSET=""

REALITY_SNI_CANDIDATES=(
    "www.abmindustriesgroup.com"
    "www.microsoft.com"
    "www.oracle.com"
    "www.ibm.com"
    "www.amazon.com"
    "www.samsung.com"
    "www.nvidia.com"
    "www.cloudflare.com"
)

info() { echo -e "${YELLOW}$*${PLAIN}"; }
ok() { echo -e "${GREEN}$*${PLAIN}"; }
err() { echo -e "${RED}$*${PLAIN}"; }

die() {
    err "$*"
    exit 1
}

ensure_root() {
    [[ "${XRAY_ONECLICK_TEST_EUID:-$EUID}" -eq 0 ]] || die "错误：请使用 root 或 sudo 运行。"
}

check_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
    elif [[ -f "${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}" ]]; then
        # shellcheck disable=SC1090
        . "${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}"
        OS_TYPE="${ID:-linux}"
        if command -v systemctl >/dev/null 2>&1; then
            INIT_SYSTEM="systemd"
        else
            INIT_SYSTEM="unknown"
        fi
    else
        die "无法识别系统类型。"
    fi
}

detect_arch() {
    ARCH="${XRAY_ONECLICK_UNAME_M:-$(uname -m)}"
    case "$ARCH" in
        x86_64 | amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
        i386 | i686) XRAY_ASSET="Xray-linux-32.zip" ;;
        aarch64 | arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        armv7l | armv7*) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
        armv6l | armv6*) XRAY_ASSET="Xray-linux-arm32-v6.zip" ;;
        armv5l | armv5*) XRAY_ASSET="Xray-linux-arm32-v5.zip" ;;
        riscv64) XRAY_ASSET="Xray-linux-riscv64.zip" ;;
        s390x) XRAY_ASSET="Xray-linux-s390x.zip" ;;
        ppc64le) XRAY_ASSET="Xray-linux-ppc64le.zip" ;;
        ppc64) XRAY_ASSET="Xray-linux-ppc64.zip" ;;
        loongarch64 | loong64) XRAY_ASSET="Xray-linux-loong64.zip" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac
}

install_shortcut() {
    local script_source
    script_source="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

    mkdir -p "$(dirname "$SHORTCUT_PATH")" "$INSTALLER_DIR"

    if [[ -f "$script_source" && -r "$script_source" ]]; then
        if [[ "$script_source" != "$INSTALLER_PATH" ]]; then
            cp "$script_source" "$INSTALLER_PATH"
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

ensure_config_security() {
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR"
    chmod 700 "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] && chmod 600 "$CONFIG_FILE"
    [[ -f "$STATE_FILE" ]] && chmod 600 "$STATE_FILE"
    chown root:root "$CONFIG_DIR" "$CONFIG_FILE" "$STATE_FILE" 2>/dev/null || true
}

init_config() {
    mkdir -p "$CONFIG_DIR"

    if [[ -f "$CONFIG_FILE" ]] && ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        local broken
        broken="${CONFIG_FILE}.broken.$(date +%Y%m%d%H%M%S)"
        mv "$CONFIG_FILE" "$broken"
        err "[配置] 发现无效 JSON，已备份到: $broken"
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
JSON
    fi

    local tmp
    tmp="$(mktemp)"
    jq '
      .log //= {"loglevel":"warning"} |
      .inbounds //= [] |
      .outbounds //= [{"tag":"direct","protocol":"freedom"}]
    ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"
    ensure_default_safety_blocks || return 1
    ensure_config_security
}

init_state() {
    mkdir -p "$CONFIG_DIR"
    [[ -f "$STATE_FILE" ]] || echo '{}' >"$STATE_FILE"
    if ! jq empty "$STATE_FILE" >/dev/null 2>&1; then
        mv "$STATE_FILE" "${STATE_FILE}.broken.$(date +%Y%m%d%H%M%S)"
        echo '{}' >"$STATE_FILE"
    fi

    local tmp
    tmp="$(mktemp)"
    jq '
      (if (.vless_encryption? | type) == "object" then
        .vless_encryption |= del(.flow)
      else
        .
      end) |
      .meta = (.meta // {}) |
      .endpoint = (if (.endpoint? | type) == "object" then .endpoint else {} end) |
      .forwards = (if (.forwards? | type) == "array" then .forwards else [] end) |
      .tunnels = (if (.tunnels? | type) == "array" then .tunnels else .forwards end)
    ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"

    ensure_config_security
}

state_set_meta_action() {
    local action="$1"
    local timestamp tmp

    [[ -n "$action" ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        err "[失败] [状态] 缺少 jq，无法更新最近变更。"
        return 1
    }
    init_state
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %z')"
    tmp="$(mktemp)" || {
        err "[失败] [状态] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg action "$action" --arg updated_at "$timestamp" '
      .meta = ((.meta // {}) + {
        "last_action": $action,
        "last_updated_at": $updated_at
      })
    ' "$STATE_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [状态] 更新 installer-state.json 失败。"
        return 1
    fi

    if ! mv "$tmp" "$STATE_FILE"; then
        rm -f "$tmp"
        err "[失败] [状态] 写入 installer-state.json 失败。"
        return 1
    fi
    ensure_config_security
}

state_meta_value() {
    local key="$1"
    local fallback="${2:-无}"

    [[ -f "$STATE_FILE" ]] || {
        printf '%s' "$fallback"
        return 0
    }
    jq -r --arg key "$key" --arg fallback "$fallback" '.meta[$key] // $fallback' "$STATE_FILE" 2>/dev/null
}

backup_config() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
}

restore_latest_config_backup() {
    local latest_backup candidate

    latest_backup=""
    for candidate in "${CONFIG_FILE}.bak."*; do
        [[ -f "$candidate" ]] || continue
        if [[ -z "$latest_backup" || "$candidate" -nt "$latest_backup" ]]; then
            latest_backup="$candidate"
        fi
    done
    if [[ -z "$latest_backup" || ! -f "$latest_backup" ]]; then
        err "[回滚] 未找到可恢复的配置备份: ${CONFIG_FILE}.bak.*"
        return 1
    fi

    info "[回滚] 正在恢复最近备份: $latest_backup"
    if ! cp -a "$latest_backup" "$CONFIG_FILE"; then
        err "[回滚] 恢复配置文件失败。"
        return 1
    fi
    ensure_config_security

    if ! validate_config_file; then
        err "[回滚] 恢复失败：备份配置校验未通过。"
        return 1
    fi

    ok "[回滚] 恢复成功，备份配置校验通过。"
}

export_current_config_backup() {
    local timestamp config_backup state_backup

    [[ -f "$CONFIG_FILE" ]] || {
        err "[失败] 未找到配置文件: $CONFIG_FILE"
        return 1
    }

    timestamp="$(date +%Y%m%d%H%M%S)"
    config_backup="/root/xray-config-backup-${timestamp}.json"
    state_backup="/root/xray-state-backup-${timestamp}.json"

    if ! cp -a "$CONFIG_FILE" "$config_backup"; then
        err "[失败] 导出配置备份失败: $config_backup"
        return 1
    fi
    chmod 600 "$config_backup" 2>/dev/null || true

    ok "[备份] config.json: $config_backup"

    if [[ -f "$STATE_FILE" ]]; then
        state_set_meta_action "导出配置备份" || err "[状态] 记录备份动作失败，配置备份已继续导出。"
        if ! cp -a "$STATE_FILE" "$state_backup"; then
            err "[失败] 导出状态备份失败: $state_backup"
            return 1
        fi
        chmod 600 "$state_backup" 2>/dev/null || true
        ok "[备份] installer-state.json: $state_backup"
    else
        info "[备份] 未找到状态文件，已跳过: $STATE_FILE"
    fi
}

validate_config_file() {
    local log_file

    if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
        err "[错误] 配置文件 JSON 无效: $CONFIG_FILE"
        return 1
    fi

    if [[ -x "$BIN_PATH" ]]; then
        log_file="$(mktemp)"
        if ! "$BIN_PATH" run -test -c "$CONFIG_FILE" >"$log_file" 2>&1; then
            err "[错误] Xray 校验配置失败:"
            cat "$log_file"
            rm -f "$log_file"
            return 1
        fi
        rm -f "$log_file"
    fi

    return 0
}

service_file_path() {
    printf '%s' "${XRAY_SERVICE_FILE:-/etc/systemd/system/${SERVICE_NAME}.service}"
}

log_dir_path() {
    printf '%s' "${XRAY_LOG_DIR:-/var/log/xray}"
}

validate_service_file() {
    local service_file="${1:-$(service_file_path)}"

    [[ -f "$service_file" ]] || return 1
    grep -q "ExecStart=$BIN_PATH run -c $CONFIG_FILE" "$service_file"
}

write_xray_service() {
    local service_file="${1:-$(service_file_path)}"
    local assume_yes="${2:-false}"
    local backup_path

    mkdir -p "$(dirname "$service_file")" "$ASSET_DIR" "$(log_dir_path)"
    if [[ -f "$service_file" ]]; then
        backup_path="${service_file}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$service_file" "$backup_path" || {
            err "[服务] 备份旧 service 失败: $backup_path"
            return 1
        }
        if ! grep -q "Managed by Xray-OneClick" "$service_file"; then
            info "[服务] 检测到非本项目生成的 service，已备份到: $backup_path"
            if [[ "$assume_yes" != "true" ]] && ! env_truthy "${XRAY_ONECLICK_YES:-}"; then
                err "[服务] 非交互模式未确认覆盖 service；如需覆盖请添加 --yes 或设置 XRAY_ONECLICK_YES=1。"
                return 1
            fi
        fi
    fi

    cat >"$service_file" <<EOF
# Managed by Xray-OneClick
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$ASSET_DIR
ExecStart=$BIN_PATH run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=$CONFIG_DIR $(log_dir_path)

[Install]
WantedBy=multi-user.target
EOF
    validate_service_file "$service_file" || {
        err "[服务] service 文件校验失败: $service_file"
        return 1
    }
}

enable_xray_service() {
    if ! command -v systemctl >/dev/null 2>&1; then
        err "[服务] systemctl 不存在，无法启用服务。"
        return 1
    fi
    systemctl daemon-reload || {
        err "[服务] systemctl daemon-reload 失败。"
        return 1
    }
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || {
        err "[服务] systemctl enable ${SERVICE_NAME} 失败。"
        return 1
    }
}

ensure_xray_service() {
    local assume_yes="${1:-false}"

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        if [[ ! -d "${XRAY_ONECLICK_SYSTEMD_DIR:-/run/systemd/system}" && "${XRAY_ONECLICK_ALLOW_FAKE_SYSTEMD:-false}" != "true" ]]; then
            err "[服务] 未检测到 systemd 运行目录，已跳过写入不可用 service。"
            return 1
        fi
        write_xray_service "$(service_file_path)" "$assume_yes" || return 1
        enable_xray_service || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        cat >"/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="xray"
command="$BIN_PATH"
command_args="run -c $CONFIG_FILE"
command_background=true
pidfile="/run/xray.pid"
depend() { need net; }
EOF
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    else
        err "[服务] 未检测到 systemd/openrc，已跳过服务文件写入。"
        return 1
    fi
}

create_service() {
    ensure_xray_service "${XRAY_ONECLICK_YES:-false}"
}

restart_xray_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl daemon-reload || {
            err "[服务] systemctl daemon-reload 失败。"
            return 1
        }
        systemctl restart "$SERVICE_NAME" || {
            err "[服务] xray restart 失败，最近日志如下:"
            if command -v journalctl >/dev/null 2>&1; then
                journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>&1 | redact_sensitive_stream || true
            fi
            return 1
        }
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$SERVICE_NAME" restart
    else
        err "[服务] 无法自动重启，请手动运行: $BIN_PATH run -c $CONFIG_FILE"
        return 1
    fi
}

restart_service() {
    restart_xray_service
}

status_xray_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl status "$SERVICE_NAME" --no-pager 2>&1 | redact_sensitive_stream
        return "${PIPESTATUS[0]}"
    elif [[ "$INIT_SYSTEM" == "openrc" ]] && command -v rc-service >/dev/null 2>&1; then
        rc-service "$SERVICE_NAME" status
    else
        err "[服务] 未检测到 systemd/openrc，无法读取服务状态。"
        return 1
    fi
}

stop_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    fi
}

stop_service_for_update() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        info "[服务] 停止 ${SERVICE_NAME}.service 以替换 Xray 核心..."
        if ! systemctl stop "$SERVICE_NAME"; then
            err "[服务] 停止 ${SERVICE_NAME}.service 失败，已中止更新。"
            return 1
        fi
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        info "[服务] 停止 ${SERVICE_NAME} 以替换 Xray 核心..."
        if ! rc-service "$SERVICE_NAME" stop; then
            err "[服务] 停止 ${SERVICE_NAME} 失败，已中止更新。"
            return 1
        fi
    else
        err "[服务] 未检测到 systemd/openrc，无法安全停止服务，已中止更新。"
        return 1
    fi
}

replace_xray_binary() {
    local new_binary="$1"
    local backup_path=""
    local staging_path

    staging_path="${BIN_PATH}.new.$$"

    if ! install -m 755 "$new_binary" "$staging_path"; then
        rm -f "$staging_path"
        err "[核心] 写入临时二进制失败: $staging_path"
        return 1
    fi

    if [[ -e "$BIN_PATH" ]]; then
        backup_path="${BIN_PATH}.bak.$(date +%Y%m%d%H%M%S)"
        if ! mv "$BIN_PATH" "$backup_path"; then
            rm -f "$staging_path"
            err "[核心] 备份旧 Xray 二进制失败，已中止更新。"
            return 1
        fi
    fi

    if ! mv "$staging_path" "$BIN_PATH"; then
        rm -f "$staging_path"
        if [[ -n "$backup_path" && -e "$backup_path" ]]; then
            mv "$backup_path" "$BIN_PATH" >/dev/null 2>&1 || true
        fi
        err "[核心] 替换 $BIN_PATH 失败，已中止更新。"
        return 1
    fi

    chmod +x "$BIN_PATH" || {
        err "[核心] 设置 $BIN_PATH 可执行权限失败。"
        return 1
    }
}

detect_xray_version() {
    local version_output version

    if [[ ! -x "$BIN_PATH" ]]; then
        printf '%s' "未安装"
        return 1
    fi
    version_output="$("$BIN_PATH" version 2>/dev/null)" || return 1
    version="$(printf '%s\n' "$version_output" | sed -nE 's/^Xray[[:space:]]+([0-9][^[:space:]]*).*/\1/p; s/^v?([0-9]+(\.[0-9]+)+).*/\1/p' | head -n 1)"
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

detect_xray_feature_support() {
    local version

    version="$(detect_xray_version 2>/dev/null || true)"
    if [[ -z "$version" || "$version" == "未安装" ]]; then
        diag_warn "Xray 未安装，无法判断 Reality/XHTTP/FinalMask 兼容性"
        return 0
    fi
    diag_info "Xray 当前版本: $version"
    diag_info "Reality 通常需要较新的 Xray-core；最终以 xray run -test 和客户端实测为准。"
    diag_info "XHTTP/FinalMask 仍是实验能力，建议保持 Xray-core 为最新版本。"
}

print_xray_version_summary() {
    echo -e "\n${YELLOW}Xray 版本信息${PLAIN}"
    echo "----------------------------------------"
    echo "Binary: $BIN_PATH"
    echo "Version: $(detect_xray_version 2>/dev/null || printf '%s' '未安装')"
    detect_xray_feature_support
}

github_mirror_urls() {
    local original="$1"
    local mirrors="${XRAY_GITHUB_MIRRORS:-}"
    local mirror
    local -a mirror_list

    printf '%s\n' "$original"
    IFS=',' read -r -a mirror_list <<<"$mirrors"
    for mirror in "${mirror_list[@]}"; do
        mirror="${mirror//[[:space:]]/}"
        [[ -n "$mirror" ]] || continue
        printf '%s%s\n' "$mirror" "$original"
    done
}

download_one_url() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 10 --max-time 120 -H "User-Agent: xray-installer" -o "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -T 120 -O "$output" "$url"
    else
        err "[核心] 缺少 curl 或 wget，无法下载。"
        return 1
    fi
}

download_with_mirrors() {
    local original_url="$1"
    local output="$2"
    local url last_error=""
    local -a urls=()

    mapfile -t urls < <(github_mirror_urls "$original_url")
    for url in "${urls[@]}"; do
        info "[核心] 尝试下载: $url"
        if download_one_url "$url" "$output"; then
            [[ -s "$output" ]] && return 0
            last_error="下载文件为空"
        else
            last_error="下载失败"
        fi
        rm -f "$output"
        info "[核心] 当前 URL 失败，尝试下一个镜像..."
    done
    err "[核心] 所有下载 URL 均失败: ${last_error}"
    err "[核心] 可手动下载 ${XRAY_ASSET} 后放置到服务器，或设置 XRAY_GITHUB_MIRRORS 后重试。"
    return 1
}

xray_release_asset_url() {
    local version="${1:-latest}"
    local release_json latest_url

    if [[ "$version" != "latest" ]]; then
        printf '%s/%s/%s' "$XRAY_RELEASE_BASE" "$version" "$XRAY_ASSET"
        return 0
    fi

    release_json="$(download_release_metadata)" || return 1
    latest_url="$(echo "$release_json" | jq -r --arg asset "$XRAY_ASSET" '.assets[]? | select(.name == $asset) | .browser_download_url' | head -n 1)"
    XRAY_DOWNLOAD_VERSION="$(echo "$release_json" | jq -r '.tag_name // "latest"')"
    [[ -n "$latest_url" && "$latest_url" != "null" ]] || return 1
    printf '%s' "$latest_url"
}

download_release_metadata() {
    local tmp

    tmp="$(mktemp)" || return 1
    if download_one_url "$XRAY_RELEASE_API" "$tmp" >/dev/null 2>&1; then
        cat "$tmp"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    err "[核心] 无法访问 GitHub Releases API；可使用 --xray-version 指定版本。"
    return 1
}

verify_xray_archive() {
    local zip_path="$1"
    local extract_dir="$2"
    local xray_bin

    [[ -s "$zip_path" ]] || {
        err "[核心] Xray 压缩包不存在或为空。"
        return 1
    }
    unzip -t "$zip_path" >/dev/null || {
        err "[核心] unzip -t 校验失败。"
        return 1
    }
    unzip -qo "$zip_path" -d "$extract_dir" || {
        err "[核心] 解压失败。"
        return 1
    }
    xray_bin="${extract_dir}/xray"
    [[ -f "$xray_bin" ]] || xray_bin="$(find "$extract_dir" -type f -name xray | head -n 1)"
    [[ -n "$xray_bin" && -f "$xray_bin" ]] || {
        err "[核心] 压缩包中未找到 xray 二进制。"
        return 1
    }
    chmod +x "$xray_bin"
    "$xray_bin" version >/dev/null 2>&1 || {
        err "[核心] 解压后的 xray 无法运行 version。"
        return 1
    }
    XRAY_EXTRACTED_BINARY="$xray_bin"
}

download_xray_core() {
    local version="${1:-latest}"
    local tmpdir="${2:-}"
    local url zip_path

    [[ -n "$tmpdir" ]] || tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir"
    XRAY_DOWNLOAD_VERSION="$version"
    url="$(xray_release_asset_url "$version")" || {
        err "[核心] 无法解析 Xray 下载地址。"
        return 1
    }
    zip_path="${tmpdir}/${XRAY_ASSET}"
    download_with_mirrors "$url" "$zip_path" || return 1
    verify_xray_archive "$zip_path" "$tmpdir" || return 1
}

install_xray_binary() {
    local xray_bin="$1"

    mkdir -p "$(dirname "$BIN_PATH")" "$ASSET_DIR" || return 1
    replace_xray_binary "$xray_bin"
}

upgrade_xray_core() {
    local version="${1:-latest}"
    local dry_run="${2:-false}"
    local restart="${3:-false}"
    local tmpdir backup_path=""

    detect_arch
    tmpdir="$(mktemp -d)" || return 1
    download_xray_core "$version" "$tmpdir" || {
        rm -rf "$tmpdir"
        return 1
    }
    if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] 将安装 Xray: $("$XRAY_EXTRACTED_BINARY" version 2>/dev/null | head -n 1)"
        echo "[dry-run] 不修改当前二进制: $BIN_PATH"
        rm -rf "$tmpdir"
        return 0
    fi

    [[ -e "$BIN_PATH" ]] && backup_path="${BIN_PATH}.bak.$(date +%Y%m%d%H%M%S)" && cp -a "$BIN_PATH" "$backup_path"
    install_xray_binary "$XRAY_EXTRACTED_BINARY" || {
        [[ -n "$backup_path" && -f "$backup_path" ]] && cp -a "$backup_path" "$BIN_PATH"
        rm -rf "$tmpdir"
        return 1
    }
    if [[ -f "$CONFIG_FILE" ]] && ! validate_config_file; then
        err "[核心] 升级后配置校验失败，正在回滚 xray binary。"
        [[ -n "$backup_path" && -f "$backup_path" ]] && cp -a "$backup_path" "$BIN_PATH"
        rm -rf "$tmpdir"
        return 1
    fi
    info "[核心] Xray 已升级: $(detect_xray_version 2>/dev/null || printf '%s' '版本未知')"
    [[ "$restart" == "true" ]] && restart_xray_service
    rm -rf "$tmpdir"
}

apply_config() {
    local context="${1:-}"

    ensure_default_safety_blocks || return 1
    ensure_config_security
    [[ -n "$context" ]] && info "[${context}] 正在校验 Xray 配置..."
    if ! validate_config_file; then
        [[ -n "$context" ]] && err "[失败] [${context}] Xray 配置校验失败。"
        err "[回滚] 已检测到配置应用失败，正在恢复最近备份。"
        if restore_latest_config_backup; then
            info "[回滚] 正在重启服务以加载恢复后的配置..."
            if restart_service; then
                ok "[回滚] 恢复成功，服务已重新加载最近备份。"
            else
                err "[回滚] 恢复后的配置校验通过，但服务重启失败。"
            fi
        else
            err "[回滚] 恢复失败，请手动检查 $CONFIG_FILE 和 ${CONFIG_FILE}.bak.*。"
        fi
        return 1
    fi

    [[ -n "$context" ]] && info "[${context}] 正在重启服务..."
    if ! restart_service; then
        [[ -n "$context" ]] && err "[失败] [${context}] 服务重启失败。"
        err "[回滚] 已检测到配置应用失败，正在恢复最近备份。"
        if restore_latest_config_backup; then
            info "[回滚] 正在重启服务以加载恢复后的配置..."
            if restart_service; then
                ok "[回滚] 恢复成功，服务已重新加载最近备份。"
            else
                err "[回滚] 恢复后的配置校验通过，但服务重启仍失败。"
            fi
        else
            err "[回滚] 恢复失败，请手动检查 $CONFIG_FILE 和 ${CONFIG_FILE}.bak.*。"
        fi
        return 1
    fi
}

install_or_update_xray() {
    local force="${1:-false}"
    local version="${XRAY_VERSION_REQUEST:-latest}"
    local tmpdir replacing_existing

    install_dependencies || return 1
    init_config || return 1
    init_state || return 1

    if [[ -x "$BIN_PATH" && "$force" != "true" ]]; then
        info "[核心] Xray 已安装: $(detect_xray_version 2>/dev/null || printf '%s' '版本未知')"
        create_service || return 1
        return 0
    fi

    tmpdir="$(mktemp -d)"
    info "[核心] 下载 Xray ${version} (${XRAY_ASSET})..."
    if ! download_xray_core "$version" "$tmpdir"; then
        rm -rf "$tmpdir"
        return 1
    fi

    mkdir -p "$(dirname "$BIN_PATH")" "$ASSET_DIR" || {
        rm -rf "$tmpdir"
        err "[核心] 创建安装目录失败。"
        return 1
    }

    replacing_existing="false"
    [[ -e "$BIN_PATH" ]] && replacing_existing="true"

    if [[ "$replacing_existing" == "true" ]]; then
        if ! create_service; then
            rm -rf "$tmpdir"
            err "[服务] 创建或刷新服务文件失败，已中止更新。"
            return 1
        fi
        if ! stop_service_for_update; then
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    if ! replace_xray_binary "$XRAY_EXTRACTED_BINARY"; then
        rm -rf "$tmpdir"
        return 1
    fi

    if [[ -f "${tmpdir}/geoip.dat" ]] && ! cp "${tmpdir}/geoip.dat" "$ASSET_DIR/"; then
        rm -rf "$tmpdir"
        err "[核心] 更新 geoip.dat 失败。"
        return 1
    fi
    if [[ -f "${tmpdir}/geosite.dat" ]] && ! cp "${tmpdir}/geosite.dat" "$ASSET_DIR/"; then
        rm -rf "$tmpdir"
        err "[核心] 更新 geosite.dat 失败。"
        return 1
    fi

    rm -rf "$tmpdir"

    ensure_default_safety_blocks || return 1

    if ! create_service; then
        err "[服务] 创建或刷新服务文件失败。"
        return 1
    fi

    ok "[核心] Xray ${XRAY_DOWNLOAD_VERSION:-$version} 安装/更新完成。"
}

update_xray_core() {
    prepare_system || return 1
    install_or_update_xray true || return 1
    validate_config_file || return 1
    restart_service || return 1
    ok "[核心] Xray 已更新并重启。"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((port >= 1 && port <= 65535)) || return 1
    return 0
}

check_port() {
    local port="$1"
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

check_ipv6_status() {
    local ipv6_disabled ipv6_global_addr
    ipv6_disabled="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)"
    ipv6_global_addr="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n 1 | cut -d'/' -f1)"

    if [[ "$ipv6_disabled" != "0" ]]; then
        err "[IPv6] 系统未开启 IPv6 (net.ipv6.conf.all.disable_ipv6=${ipv6_disabled})"
        return 1
    fi

    if [[ -z "$ipv6_global_addr" ]]; then
        err "[IPv6] 未检测到全局 IPv6 地址，无法生成可用节点。"
        return 1
    fi

    ok "[IPv6] 可用，检测到地址: ${ipv6_global_addr}"
    return 0
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

generate_ss2022_password() {
    local method="$1"
    local bytes="32"
    [[ "$method" == "2022-blake3-aes-128-gcm" ]] && bytes="16"
    openssl rand -base64 "$bytes"
}

configure_ss2022() {
    local listen_mode="${1:-ipv4}"

    echo -e "\n${YELLOW}[配置] Shadowsocks 2022 加密协议:${PLAIN}"
    echo -e "  1) 2022-blake3-aes-128-gcm ${GREEN}(推荐，兼容性好)${PLAIN}"
    echo "  2) 2022-blake3-aes-256-gcm"
    echo "  3) 2022-blake3-chacha20-poly1305"
    read -r -p "选项 (默认: 1): " M_OPT

    case "${M_OPT:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac

    ask_port "SS2022 端口" "9000" SS_PORT || {
        err "[失败] [SS2022] 端口配置失败。"
        return 1
    }
    SS_PASSWORD="$(generate_ss2022_password "$SS_METHOD")"
    if [[ -z "$SS_PASSWORD" ]]; then
        err "[失败] [SS2022] 密码生成失败。"
        return 1
    fi

    case "$listen_mode" in
        ipv4) SS_LISTEN="0.0.0.0" ;;
        ipv6) SS_LISTEN="::" ;;
        *)
            err "[失败] [SS2022] 未知监听模式: $listen_mode"
            return 1
            ;;
    esac

    info "[SS2022] 监听模式: ${listen_mode} (${SS_LISTEN})"
    return 0
}

install_ss2022() {
    info "[SS2022] 正在生成配置..."
    if ! install_or_update_xray; then
        err "[失败] [SS2022] Xray 安装/更新失败。"
        return 1
    fi

    if ! backup_config; then
        err "[失败] [SS2022] 配置备份失败。"
        return 1
    fi

    local tmp
    tmp="$(mktemp)" || {
        err "[失败] [SS2022] 创建临时文件失败。"
        return 1
    }

    info "[SS2022] 正在写入 config.json..."
    if ! jq --arg tag "$SS_TAG" \
        --arg listen "$SS_LISTEN" \
        --arg port "$SS_PORT" \
        --arg method "$SS_METHOD" \
        --arg pass "$SS_PASSWORD" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": $listen,
          "port": ($port|tonumber),
          "protocol": "shadowsocks",
          "settings": {
            "network": "tcp,udp",
            "method": $method,
            "password": $pass,
            "level": 0
          }
        }]
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [SS2022] jq 生成配置失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [SS2022] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    if ! apply_config "SS2022"; then
        err "[失败] [SS2022] 应用配置失败。"
        return 1
    fi
    state_set_meta_action "安装 SS2022" || err "[状态] 最近变更记录失败。"
    ok "[完成] SS2022 已写入 Xray 配置。"
    view_config
}

generate_vless_encryption_pair() {
    local auth="$1"
    local output dec_line enc_line

    output="$("$BIN_PATH" vlessenc 2>/dev/null)" || {
        err "[VLESS] xray vlessenc 执行失败，请确认 Xray 版本支持 VLESS Encryption。"
        return 1
    }

    if [[ "$auth" == "mlkem768" ]]; then
        dec_line="$(echo "$output" | grep '"decryption"' | tail -n 1)"
        enc_line="$(echo "$output" | grep '"encryption"' | tail -n 1)"
    else
        dec_line="$(echo "$output" | grep '"decryption"' | head -n 1)"
        enc_line="$(echo "$output" | grep '"encryption"' | head -n 1)"
    fi

    VLESS_DECRYPTION="$(echo "$dec_line" | sed -n 's/.*"decryption": "\([^"]*\)".*/\1/p')"
    VLESS_ENCRYPTION="$(echo "$enc_line" | sed -n 's/.*"encryption": "\([^"]*\)".*/\1/p')"

    if [[ -z "$VLESS_DECRYPTION" || -z "$VLESS_ENCRYPTION" ]]; then
        err "[VLESS] 无法解析 xray vlessenc 输出。"
        return 1
    fi

    VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
    VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
    VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"

    VLESS_DECRYPTION="$(rewrite_vlessenc_blocks "server" "$VLESS_DECRYPTION" "$VLESS_ENC_METHOD" "$VLESS_SERVER_TICKET")" || return 1
    VLESS_ENCRYPTION="$(rewrite_vlessenc_blocks "client" "$VLESS_ENCRYPTION" "$VLESS_ENC_METHOD" "$VLESS_CLIENT_RTT")" || return 1
}

rewrite_vlessenc_blocks() {
    local side="$1"
    local value="$2"
    local method="$3"
    local third_block="$4"
    local old_ifs auth_block result i
    local -a VLESS_BLOCKS

    case "$method" in
        native | xorpub | random) ;;
        *)
            err "[VLESS] 不支持的外观混淆方法: $method"
            return 1
            ;;
    esac

    case "$side" in
        server)
            if [[ ! "$third_block" =~ ^[0-9]+s$ && ! "$third_block" =~ ^[0-9]+-[0-9]+s$ ]]; then
                err "[VLESS] 服务端 ticket 有效期格式无效: $third_block"
                return 1
            fi
            ;;
        client)
            if [[ "$third_block" != "0rtt" && "$third_block" != "1rtt" ]]; then
                err "[VLESS] 客户端握手模式无效: $third_block"
                return 1
            fi
            ;;
        *)
            err "[VLESS] 内部错误：未知 VLESS Encryption 侧别: $side"
            return 1
            ;;
    esac

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        err "[VLESS] vlessenc 字符串包含非法换行。"
        return 1
    fi

    old_ifs="$IFS"
    IFS='.'
    read -r -a VLESS_BLOCKS <<<"$value"
    IFS="$old_ifs"

    if ((${#VLESS_BLOCKS[@]} < 4)); then
        err "[VLESS] vlessenc 字符串 block 数不足，无法安全改写。"
        return 1
    fi

    if [[ "${VLESS_BLOCKS[0]}" != "mlkem768x25519plus" ]]; then
        err "[VLESS] 未识别的握手方法: ${VLESS_BLOCKS[0]}"
        return 1
    fi

    case "${VLESS_BLOCKS[1]}" in
        native | xorpub | random) ;;
        *)
            err "[VLESS] 未识别的原始外观混淆方法: ${VLESS_BLOCKS[1]}"
            return 1
            ;;
    esac

    auth_block="${VLESS_BLOCKS[$((${#VLESS_BLOCKS[@]} - 1))]}"
    if [[ -z "$auth_block" || ! "$auth_block" =~ ^[A-Za-z0-9_-]+$ ]]; then
        err "[VLESS] 认证参数 block 无效，已中止改写。"
        return 1
    fi

    VLESS_BLOCKS[1]="$method"
    VLESS_BLOCKS[2]="$third_block"

    result="${VLESS_BLOCKS[0]}"
    for ((i = 1; i < ${#VLESS_BLOCKS[@]}; i++)); do
        result="${result}.${VLESS_BLOCKS[$i]}"
    done

    printf '%s' "$result"
}

ask_vless_auth() {
    echo -e "\n${YELLOW}[配置] VLESS Encryption 认证方式:${PLAIN}"
    echo -e "  1) X25519 ${GREEN}(推荐，链接更短)${PLAIN}"
    echo "  2) ML-KEM-768 (后量子认证，链接很长)"
    read -r -p "选项 (默认: 1): " V_AUTH_OPT
    case "${V_AUTH_OPT:-1}" in
        2) VLESS_AUTH="mlkem768" ;;
        *) VLESS_AUTH="x25519" ;;
    esac
}

configure_vless_advanced_options() {
    local enc_opt rtt_opt ticket_opt custom_ticket

    VLESS_MODE="advanced"

    # VLESS reverse/relay needs coordinated routing on both ends; do not fake one-click support here.
    echo -e "\n${YELLOW}[高级] VLESS Encryption 外观混淆方法:${PLAIN}"
    echo -e "  1) native ${GREEN}(默认，原始格式)${PLAIN}"
    echo "  2) xorpub (混淆公钥部分)"
    echo "  3) random (完整随机外观)"
    read -r -p "选项 (默认: 1): " enc_opt
    case "${enc_opt:-1}" in
        2) VLESS_ENC_METHOD="xorpub" ;;
        3) VLESS_ENC_METHOD="random" ;;
        *) VLESS_ENC_METHOD="native" ;;
    esac

    echo -e "\n${YELLOW}[高级] 客户端会话恢复:${PLAIN}"
    echo -e "  1) 0rtt ${GREEN}(默认，尝试快速恢复)${PLAIN}"
    echo "  2) 1rtt (强制完整握手)"
    read -r -p "选项 (默认: 1): " rtt_opt
    case "${rtt_opt:-1}" in
        2) VLESS_CLIENT_RTT="1rtt" ;;
        *) VLESS_CLIENT_RTT="0rtt" ;;
    esac

    echo -e "\n${YELLOW}[高级] 服务端 ticket 有效期:${PLAIN}"
    echo -e "  1) 600s ${GREEN}(默认)${PLAIN}"
    echo "  2) 300s"
    echo "  3) 自定义，例如 100-500s 或 900s"
    read -r -p "选项 (默认: 1): " ticket_opt
    case "${ticket_opt:-1}" in
        2) VLESS_SERVER_TICKET="300s" ;;
        3)
            read -r -p "请输入 ticket 有效期: " custom_ticket
            if [[ "$custom_ticket" =~ ^[0-9]+s$ || "$custom_ticket" =~ ^[0-9]+-[0-9]+s$ ]]; then
                VLESS_SERVER_TICKET="$custom_ticket"
            else
                info "[提示] 格式无效，使用默认 600s。"
                VLESS_SERVER_TICKET="600s"
            fi
            ;;
        *) VLESS_SERVER_TICKET="600s" ;;
    esac

    info "[提示] VLESS reverse/relay 等协议层能力当前脚本暂未暴露，请手动编辑 Xray 配置实现。"
}

configure_vless_encryption() {
    install_or_update_xray || return 1

    VLESS_MODE="basic"
    VLESS_ENC_METHOD="native"
    VLESS_CLIENT_RTT="0rtt"
    VLESS_SERVER_TICKET="600s"

    echo -e "\n${YELLOW}[配置] VLESS Encryption 配置模式:${PLAIN}"
    echo -e "  1) 基础模式 ${GREEN}(推荐，保持当前简单体验)${PLAIN}"
    echo "  2) 高级模式 (外观混淆、0-RTT/1-RTT、ticket 有效期)"
    read -r -p "选项 (默认: 1): " V_MODE_OPT
    [[ "${V_MODE_OPT:-1}" == "2" ]] && configure_vless_advanced_options

    ask_vless_auth

    ask_port "VLESS Encryption 端口" "8443" VLESS_PORT
    VLESS_LISTEN="0.0.0.0"
    VLESS_UUID="$("$BIN_PATH" uuid 2>/dev/null | tr -d '\r\n')"
    [[ -n "$VLESS_UUID" ]] || VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"

    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
}

state_set_vless() {
    init_state
    local tmp
    tmp="$(mktemp)"
    jq --arg tag "$VLESS_TAG" \
        --arg uuid "$VLESS_UUID" \
        --arg encryption "$VLESS_ENCRYPTION" \
        --arg auth "$VLESS_AUTH" \
        --arg mode "$VLESS_MODE" \
        --arg enc_method "$VLESS_ENC_METHOD" \
        --arg client_rtt "$VLESS_CLIENT_RTT" \
        --arg server_ticket "$VLESS_SERVER_TICKET" \
        --arg port "$VLESS_PORT" '
        .vless_encryption = {
          "tag": $tag,
          "uuid": $uuid,
          "encryption": $encryption,
          "auth": $auth,
          "mode": $mode,
          "enc_method": $enc_method,
          "client_rtt": $client_rtt,
          "server_ticket": $server_ticket,
          "port": ($port|tonumber)
        }
       ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
}

install_vless_encryption() {
    backup_config

    local tmp
    tmp="$(mktemp)"
    jq --arg tag "$VLESS_TAG" \
        --arg listen "$VLESS_LISTEN" \
        --arg port "$VLESS_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg decryption "$VLESS_DECRYPTION" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": $listen,
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid,
                "email": "vless@xray"
              }
            ],
            "decryption": $decryption
          },
          "streamSettings": {
            "network": "tcp",
            "security": "none"
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        }]
       ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"

    state_set_vless
    apply_config || return 1
    state_set_meta_action "安装 VLESS Encryption" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption 已写入 Xray 配置。"
    view_config
}

validate_reality_sni() {
    local domain="$1"
    local label
    local -a labels

    [[ -n "$domain" && ${#domain} -le 253 ]] || return 1
    [[ "$domain" != *"://"* && "$domain" != *"/"* && "$domain" != *":"* ]] || return 1
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" == *.* ]] || return 1
    [[ "$domain" != .* && "$domain" != *. ]] || return 1
    [[ "$domain" != *..* ]] || return 1

    IFS='.' read -r -a labels <<<"$domain"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

generate_reality_short_ids() {
    local len id
    local -a lengths=(2 4 6 8 10 12 14 16)

    REALITY_SHORT_IDS=()
    for len in "${lengths[@]}"; do
        id="$(openssl rand -hex "$((len / 2))" | cut -c "1-${len}")" || return 1
        REALITY_SHORT_IDS+=("$id")
    done
    REALITY_DEFAULT_SHORT_ID="${REALITY_SHORT_IDS[0]}"
    REALITY_SHORT_IDS_JSON="$(printf '%s\n' "${REALITY_SHORT_IDS[@]}" | jq -R . | jq -s -c .)" || return 1
}

normalize_x25519_key_name() {
    local key="$1"

    key="${key//$'\r'/}"
    key="${key//[[:space:]]/}"
    key="${key//_/}"
    key="${key//-/}"
    key="${key//(/}"
    key="${key//)/}"
    printf '%s' "${key,,}"
}

trim_x25519_value() {
    local value="$1"

    value="${value//$'\r'/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

mask_x25519_value() {
    local value="$1"
    local len="${#value}"

    if [[ -z "$value" ]]; then
        printf '%s' "(空)"
    elif ((len <= 8)); then
        printf '%s' "****"
    else
        printf '%s...%s' "${value:0:4}" "${value: -4}"
    fi
}

print_masked_x25519_output() {
    local output="$1"
    local line key value

    while IFS= read -r line; do
        line="${line//$'\r'/}"
        [[ -n "$line" ]] || continue
        if [[ "$line" == *:* ]]; then
            key="$(trim_x25519_value "${line%%:*}")"
            value="$(trim_x25519_value "${line#*:}")"
            if [[ -n "$value" ]]; then
                printf '  %s: %s\n' "$key" "$(mask_x25519_value "$value")"
            else
                printf '  %s:\n' "$key"
            fi
        else
            printf '  %s\n' "$line"
        fi
    done <<<"$output"
}

parse_xray_x25519_output() {
    local output="$1"
    local line raw_key key key_base key_full value private="" public="" hash32=""

    REALITY_X25519_HASH32=""

    while IFS= read -r line; do
        line="${line//$'\r'/}"
        [[ "$line" == *:* ]] || continue
        raw_key="$(trim_x25519_value "${line%%:*}")"
        value="$(trim_x25519_value "${line#*:}")"
        key_base="$(printf '%s' "$raw_key" | sed -E 's/[[:space:]]*\([^)]*\)//g')"
        key="$(normalize_x25519_key_name "$key_base")"
        key_full="$(normalize_x25519_key_name "$raw_key")"
        [[ -n "$value" ]] || continue
        if [[ "$key_full" == *privatekey* || "$key" == "private" ]]; then
            private="$value"
        elif [[ "$key_full" == *publickey* ]]; then
            public="$value"
        elif [[ "$key" == "password" || "$key_full" == password* ]]; then
            public="$value"
        elif [[ "$key_full" == *hash32* ]]; then
            hash32="$value"
        fi
    done <<<"$output"

    [[ -n "$private" && -n "$public" ]] || return 1
    REALITY_PRIVATE_KEY="$private"
    REALITY_PUBLIC_KEY="$public"
    REALITY_X25519_HASH32="$hash32"
}

generate_reality_keys() {
    local output status

    output="$("$BIN_PATH" x25519 2>&1)"
    status=$?
    if ((status != 0)); then
        err "[Reality] xray x25519 执行失败，退出码: ${status}"
        err "[Reality] 脱敏输出:"
        print_masked_x25519_output "$output" >&2
        err "[Reality] 请确认 Xray 版本支持 REALITY。"
        return 1
    fi

    if ! parse_xray_x25519_output "$output"; then
        err "[Reality] 当前 Xray x25519 输出格式未被识别。"
        err "[Reality] 脱敏输出:"
        print_masked_x25519_output "$output" >&2
        return 1
    fi
}

test_reality_target_tls() {
    local domain="$1"

    if env_truthy "${REALITY_SKIP_TLS_TEST:-}"; then
        return 0
    fi
    command -v openssl >/dev/null 2>&1 || {
        info "[Reality] 未找到 openssl，已跳过 DOMAIN:443 可达性检测。"
        return 0
    }

    if command -v timeout >/dev/null 2>&1; then
        timeout 8 openssl s_client -servername "$domain" -connect "${domain}:443" </dev/null >/dev/null 2>&1
    else
        openssl s_client -servername "$domain" -connect "${domain}:443" </dev/null >/dev/null 2>&1
    fi
}

ask_or_random_reality_port() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local requested="$4"
    local __resultvar="$5"
    local input port

    if [[ -n "$requested" ]]; then
        validate_port "$requested" || {
            err "[Reality] 端口无效: $requested"
            return 1
        }
        if port_used_in_config "$requested" || ! check_port "$requested"; then
            err "[Reality] 端口已被占用或已存在于 config.json: $requested"
            return 1
        fi
        printf -v "$__resultvar" '%s' "$requested"
        return 0
    fi

    if [[ "${REALITY_CONFIG_MODE:-interactive}" != "interactive" ]]; then
        port="$(random_free_port "$min" "$max")" || {
            err "[Reality] 无法在 ${min}-${max} 中找到可用端口。"
            return 1
        }
        printf -v "$__resultvar" '%s' "$port"
        return 0
    fi

    while true; do
        read -r -p "${prompt} (回车随机 ${min}-${max}): " input
        if [[ -z "$input" ]]; then
            port="$(random_free_port "$min" "$max")" || {
                err "[Reality] 无法在 ${min}-${max} 中找到可用端口。"
                return 1
            }
            info "[Reality] 随机选择端口: ${port}"
            printf -v "$__resultvar" '%s' "$port"
            return 0
        fi
        if ! validate_port "$input"; then
            err "[Reality] 端口无效，请输入 1-65535。"
            continue
        fi
        if port_used_in_config "$input" || ! check_port "$input"; then
            err "[Reality] 端口 ${input} 已被占用或已存在于 config.json。"
            continue
        fi
        warn_reserved_port "$input"
        printf -v "$__resultvar" '%s' "$input"
        return 0
    done
}

ask_or_random_reality_sni() {
    local requested="${1:-}"
    local __resultvar="$2"
    local input index domain

    if [[ -n "$requested" ]]; then
        validate_reality_sni "$requested" || {
            err "[Reality] SNI 域名格式无效: $requested"
            return 1
        }
        printf -v "$__resultvar" '%s' "$requested"
        return 0
    fi

    if [[ "${REALITY_CONFIG_MODE:-interactive}" != "interactive" ]]; then
        index=$((RANDOM % ${#REALITY_SNI_CANDIDATES[@]}))
        domain="${REALITY_SNI_CANDIDATES[$index]}"
        printf -v "$__resultvar" '%s' "$domain"
        return 0
    fi

    while true; do
        read -r -p "Reality 伪装域名 SNI (回车随机): " input
        if [[ -z "$input" ]]; then
            index=$((RANDOM % ${#REALITY_SNI_CANDIDATES[@]}))
            domain="${REALITY_SNI_CANDIDATES[$index]}"
            info "[Reality] 随机选择 SNI: ${domain}"
            printf -v "$__resultvar" '%s' "$domain"
            return 0
        fi
        if validate_reality_sni "$input"; then
            printf -v "$__resultvar" '%s' "$input"
            return 0
        fi
        err "[Reality] SNI 域名格式无效，请输入类似 www.example.com 的域名。"
    done
}

configure_reality() {
    local mode="${1:-interactive}"
    local retry_port

    REALITY_CONFIG_MODE="$mode"
    if [[ "$mode" != "dry-run" ]]; then
        install_or_update_xray || return 1
    fi

    ask_or_random_reality_port "Reality 入口端口" "$REALITY_PORT_MIN" "$REALITY_PORT_MAX" "${REALITY_PORT_REQUEST:-}" REALITY_PORT || return 1
    ask_or_random_reality_port "Reality defender 本地端口" "$REALITY_DEFENDER_PORT_MIN" "$REALITY_DEFENDER_PORT_MAX" "${REALITY_DEFENDER_PORT_REQUEST:-}" REALITY_DEFENDER_PORT || return 1
    if [[ "$REALITY_PORT" == "$REALITY_DEFENDER_PORT" ]]; then
        if [[ -z "${REALITY_DEFENDER_PORT_REQUEST:-}" ]]; then
            for _ in {1..20}; do
                retry_port="$(random_free_port "$REALITY_DEFENDER_PORT_MIN" "$REALITY_DEFENDER_PORT_MAX" || true)"
                [[ -n "$retry_port" && "$retry_port" != "$REALITY_PORT" ]] || continue
                REALITY_DEFENDER_PORT="$retry_port"
                break
            done
        elif [[ -z "${REALITY_PORT_REQUEST:-}" ]]; then
            for _ in {1..20}; do
                retry_port="$(random_free_port "$REALITY_PORT_MIN" "$REALITY_PORT_MAX" || true)"
                [[ -n "$retry_port" && "$retry_port" != "$REALITY_DEFENDER_PORT" ]] || continue
                REALITY_PORT="$retry_port"
                break
            done
        fi
    fi
    if [[ "$REALITY_PORT" == "$REALITY_DEFENDER_PORT" ]]; then
        err "[Reality] 入口端口和 defender 端口不能相同。"
        return 1
    fi

    ask_or_random_reality_sni "${REALITY_SNI_REQUEST:-}" REALITY_SERVER_NAME || return 1
    info "[Reality] 建议 target 使用 ${REALITY_SERVER_NAME}:443；入口端口可随机，defender 始终转发到 443。"
    if ! test_reality_target_tls "$REALITY_SERVER_NAME"; then
        err "[Reality] ${REALITY_SERVER_NAME}:443 TLS 探测失败。"
        if [[ "$mode" == "interactive" ]]; then
            confirm_yes_no "仍然继续写入 Reality 配置?" "n" || return 1
        elif ! { env_truthy "${XRAY_ONECLICK_YES:-}" || env_truthy "${REALITY_ASSUME_YES:-}"; }; then
            err "[Reality] 非交互模式默认取消；确认目标可用后可设置 XRAY_ONECLICK_YES=1 重试。"
            return 1
        fi
    fi

    REALITY_UUID="$(generate_uuid)" || {
        err "[Reality] UUID 生成失败。"
        return 1
    }
    REALITY_SPIDER_X="/"
    REALITY_EMPTY_CLIENTS="${REALITY_EMPTY_CLIENTS:-false}"
    if [[ "$REALITY_EMPTY_CLIENTS" == "true" ]]; then
        REALITY_FLOW=""
    else
        REALITY_FLOW="${REALITY_FLOW:-$REALITY_FLOW_DEFAULT}"
    fi
    generate_reality_keys || return 1
    generate_reality_short_ids || return 1
}

build_reality_share_link() {
    local port="${REALITY_PORT:-}"
    local uuid="${REALITY_UUID:-}"
    local public_key="${REALITY_PUBLIC_KEY:-}"
    local short_id="${REALITY_DEFAULT_SHORT_ID:-}"
    local server_name="${REALITY_SERVER_NAME:-}"
    local spider_x="${REALITY_SPIDER_X:-/}"
    local flow="$REALITY_FLOW_DEFAULT"
    local host link_port endpoint_pair
    local pbk_uri sni_uri sid_uri spx_uri flow_uri name_uri

    [[ ${REALITY_FLOW+x} ]] && flow="$REALITY_FLOW"

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${REALITY_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        uuid="$(jq -r ".${REALITY_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
        public_key="$(jq -r ".${REALITY_STATE_KEY}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
        short_id="$(jq -r ".${REALITY_STATE_KEY}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
        server_name="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
        spider_x="$(jq -r ".${REALITY_STATE_KEY}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
        flow="$(jq -r ".${REALITY_STATE_KEY}.flow // \"$REALITY_FLOW_DEFAULT\"" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$uuid" && -n "$public_key" && -n "$short_id" && -n "$server_name" ]] || return 1
    endpoint_pair="$(split_endpoint_for_link "$port")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    pbk_uri="$(url_encode "$public_key")"
    sni_uri="$(url_encode "$server_name")"
    sid_uri="$(url_encode "$short_id")"
    spx_uri="$(url_encode "$spider_x")"
    flow_uri="$(url_encode "$flow")"
    name_uri="$(url_encode "Xray-Reality")"

    printf 'vless://%s@%s:%s?type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s' \
        "$uuid" "$host" "$link_port" "$pbk_uri" "$sni_uri" "$sid_uri"
    [[ -n "$flow" ]] && printf '&flow=%s' "$flow_uri"
    printf '&spx=%s#%s' "$spx_uri" "$name_uri"
}

state_set_reality() {
    init_state
    local tmp link timestamp clients_empty flow
    local hash32

    flow="$REALITY_FLOW_DEFAULT"
    [[ ${REALITY_FLOW+x} ]] && flow="$REALITY_FLOW"
    hash32="${REALITY_X25519_HASH32:-}"
    link="$(build_reality_share_link || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    clients_empty="false"
    [[ "${REALITY_EMPTY_CLIENTS:-false}" == "true" ]] && clients_empty="true"
    tmp="$(mktemp)" || return 1
    MSYS2_ENV_CONV_EXCL="REALITY_JQ_SPIDER_X" REALITY_JQ_SPIDER_X="$REALITY_SPIDER_X" jq --argjson short_ids "$REALITY_SHORT_IDS_JSON" \
        --arg port "$REALITY_PORT" \
        --arg defender_port "$REALITY_DEFENDER_PORT" \
        --arg uuid "$REALITY_UUID" \
        --arg private_key "$REALITY_PRIVATE_KEY" \
        --arg public_key "$REALITY_PUBLIC_KEY" \
        --arg default_short_id "$REALITY_DEFAULT_SHORT_ID" \
        --arg server_name "$REALITY_SERVER_NAME" \
        --arg flow "$flow" \
        --arg hash32 "$hash32" \
        --arg created_at "$timestamp" \
        --arg link "$link" \
        --arg clients_empty "$clients_empty" '
        .vless_reality = {
          "port": ($port|tonumber),
          "defender_port": ($defender_port|tonumber),
          "uuid": $uuid,
          "private_key": $private_key,
          "public_key": $public_key,
          "short_ids": $short_ids,
          "default_short_id": $default_short_id,
          "server_name": $server_name,
          "flow": $flow,
          "spider_x": env.REALITY_JQ_SPIDER_X,
          "empty_clients": ($clients_empty == "true"),
          "created_at": $created_at,
          "link": $link
        } |
        if $hash32 != "" then .vless_reality.hash32 = $hash32 else . end
       ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
}

mask_value() {
    local value="${1:-}"
    local keep="${2:-4}"
    local len

    len="${#value}"
    if [[ -z "$value" ]]; then
        printf '%s' "(空)"
    elif ((len <= keep)); then
        printf '%s' "****"
    else
        printf '%s****' "${value:0:keep}"
    fi
}

mask_share_link() {
    local link="$1"

    printf '%s' "$link" |
        sed -E 's/(pbk=)[^&#]+/\1****/g; s/(sid=)[^&#]+/\1****/g; s/(encryption=)[^&#]+/\1****/g; s/(fm=)[^&#]+/\1****/g'
}

xray_test_temp_config() {
    local config_path="$1"
    local log_file

    [[ -x "$BIN_PATH" ]] || {
        echo "[i] 未检测到 xray，已跳过临时配置 xray run -test。"
        return 0
    }
    log_file="$(mktemp)" || return 1
    if "$BIN_PATH" run -test -c "$config_path" >"$log_file" 2>&1; then
        rm -f "$log_file"
        echo "[✓] 临时配置 xray run -test 通过"
        return 0
    fi
    echo "[!] 临时配置 xray run -test 未通过，真实配置未被修改。"
    sed -n '1,80p' "$log_file"
    rm -f "$log_file"
    return 0
}

print_reality_dry_run() {
    local temp_config="$1"
    local link

    link="$(build_reality_share_link || true)"
    echo -e "\n${YELLOW}Reality dry-run 预览${PLAIN}"
    echo "----------------------------------------"
    echo "入口端口: ${REALITY_PORT}"
    echo "Defender: 127.0.0.1:${REALITY_DEFENDER_PORT}"
    echo "SNI: ${REALITY_SERVER_NAME}"
    echo "Flow: ${REALITY_FLOW:-无}"
    echo "ShortID: $(mask_value "$REALITY_DEFAULT_SHORT_ID" 2)"
    echo "PublicKey: $(mask_value "$REALITY_PUBLIC_KEY" 6)"
    [[ -n "$link" ]] && echo "Masked Link: $(mask_share_link "$link")"
    echo "将写入 inbound:"
    echo "- ${REALITY_TAG}"
    echo "- ${REALITY_DEFENDER_TAG}"
    echo "将写入 routing:"
    echo "- ${REALITY_DEFENDER_TAG} + full:${REALITY_SERVER_NAME} -> direct"
    echo "- ${REALITY_DEFENDER_TAG} -> ${BLOCK_OUTBOUND_TAG}"
    jq empty "$temp_config" >/dev/null && echo "[✓] 临时 JSON 结构有效"
    xray_test_temp_config "$temp_config"
    echo "不会修改真实配置。"
}

install_reality() {
    local tmp clients_json flow config_source base_tmp

    config_source="$CONFIG_FILE"
    if [[ "${REALITY_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${REALITY_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[Reality] 配置备份失败。"
            return 1
        }
    fi

    flow="$REALITY_FLOW_DEFAULT"
    [[ ${REALITY_FLOW+x} ]] && flow="$REALITY_FLOW"
    if [[ "${REALITY_EMPTY_CLIENTS:-false}" == "true" ]]; then
        clients_json='[]'
    elif [[ -n "$flow" ]]; then
        clients_json="$(jq -cn --arg uuid "$REALITY_UUID" --arg flow "$flow" '[{"id": $uuid, "flow": $flow, "email": "reality@xray"}]')" || return 1
    else
        clients_json="$(jq -cn --arg uuid "$REALITY_UUID" '[{"id": $uuid, "email": "reality@xray"}]')" || return 1
    fi

    tmp="$(mktemp)" || return 1
    if ! MSYS2_ENV_CONV_EXCL="REALITY_JQ_SPIDER_X" REALITY_JQ_SPIDER_X="$REALITY_SPIDER_X" jq --arg tag "$REALITY_TAG" \
        --arg defender_tag "$REALITY_DEFENDER_TAG" \
        --arg block "$BLOCK_OUTBOUND_TAG" \
        --arg port "$REALITY_PORT" \
        --arg defender_port "$REALITY_DEFENDER_PORT" \
        --arg sni "$REALITY_SERVER_NAME" \
        --arg private_key "$REALITY_PRIVATE_KEY" \
        --argjson short_ids "$REALITY_SHORT_IDS_JSON" \
        --argjson clients "$clients_json" '
        def has_defender_tag:
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $defender_tag) else . == $defender_tag end));
        def reality_rule:
          (.type == "field") and has_defender_tag;
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag and .tag != $defender_tag))) |
        .inbounds += [
          {
            "tag": $tag,
            "listen": "0.0.0.0",
            "port": ($port|tonumber),
            "protocol": "vless",
            "settings": {
              "clients": $clients,
              "decryption": "none"
            },
            "streamSettings": {
              "network": "tcp",
              "security": "reality",
              "realitySettings": {
                "dest": ("127.0.0.1:" + $defender_port),
                "show": false,
                "xver": 0,
                "spiderX": env.REALITY_JQ_SPIDER_X,
                "shortIds": $short_ids,
                "privateKey": $private_key,
                "serverNames": [$sni]
              }
            },
            "sniffing": {
              "enabled": true,
              "destOverride": ["http", "tls"]
            }
          },
          {
            "tag": $defender_tag,
            "listen": "127.0.0.1",
            "port": ($defender_port|tonumber),
            "protocol": "dokodemo-door",
            "settings": {
              "port": 443,
              "address": $sni,
              "network": "tcp"
            },
            "sniffing": {
              "enabled": true,
              "routeOnly": true,
              "destOverride": ["tls"]
            }
          }
        ] |
        .routing = (.routing // {}) |
        .routing.rules = ([
          {"type": "field", "inboundTag": [$defender_tag], "domain": ["full:" + $sni], "outboundTag": "direct"},
          {"type": "field", "inboundTag": [$defender_tag], "outboundTag": $block}
        ] + ((.routing.rules // []) | map(select((reality_rule) | not))))
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[Reality] jq 生成配置失败。"
        return 1
    fi

    if [[ "${REALITY_DRY_RUN:-false}" == "true" ]]; then
        print_reality_dry_run "$tmp"
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        return 0
    fi
    [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"

    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[Reality] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "VLESS TCP REALITY"; then
        err "[Reality] 应用配置失败，已尝试自动回滚。"
        print_reality_failure_hint
        return 1
    fi
    state_set_reality || err "[状态] Reality 状态写入失败，但 config.json 已生效。"
    state_set_meta_action "安装 VLESS TCP REALITY" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS TCP REALITY 已写入 Xray 配置。"
    print_reality_result
}

print_reality_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port defender_port uuid server_name public_key short_id spider_x private_hint flow
    local endpoint_pair address link_port

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Reality] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${REALITY_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Reality] 未安装。"
        return 0
    fi

    link="$(build_reality_share_link || jq -r ".${REALITY_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    port="$(jq -r ".${REALITY_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    defender_port="$(jq -r ".${REALITY_STATE_KEY}.defender_port // empty" "$STATE_FILE" 2>/dev/null)"
    uuid="$(jq -r ".${REALITY_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    server_name="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
    public_key="$(jq -r ".${REALITY_STATE_KEY}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
    short_id="$(jq -r ".${REALITY_STATE_KEY}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
    spider_x="$(jq -r ".${REALITY_STATE_KEY}.spider_x // \"/\"" "$STATE_FILE" 2>/dev/null)"
    private_hint="$(jq -r ".${REALITY_STATE_KEY}.private_key // empty" "$STATE_FILE" 2>/dev/null)"
    flow="$(jq -r ".${REALITY_STATE_KEY}.flow // \"$REALITY_FLOW_DEFAULT\"" "$STATE_FILE" 2>/dev/null)"
    endpoint_pair="$(split_endpoint_for_link "$port")"
    IFS=$'\t' read -r address link_port <<<"$endpoint_pair"

    echo -e "\n${YELLOW}--- VLESS TCP REALITY ---${PLAIN}"
    echo -e "入口端口: ${port}"
    echo -e "Defender: 127.0.0.1:${defender_port} -> ${server_name}:443"
    [[ -n "$link" ]] && echo -e "VLESS URL / v2rayN / sing-box 通用链接: ${link}"
    echo "手动参数:"
    echo "  Protocol: VLESS"
    echo "  Transport: TCP"
    echo "  Security: REALITY"
    echo "  Address: ${address}"
    echo "  Port: ${link_port}"
    echo "  UUID: ${uuid}"
    echo "  Flow: ${flow:-无}"
    echo "  SNI: ${server_name}"
    echo "  PublicKey: ${public_key} (客户端字段)"
    echo "  ShortID: ${short_id}"
    echo "  Fingerprint: chrome"
    echo "  SpiderX: ${spider_x}"
    [[ -n "$private_hint" ]] && echo "  服务端 privateKey 已保存到 installer-state.json，请妥善保护，默认不显示。"
    echo "兼容提示:"
    echo "  - privateKey 是服务端字段，不需要填到客户端。"
    echo "  - publicKey 是客户端字段。"
    echo "  - 如果客户端没有 Reality/Vision 选项，说明客户端内核可能太旧。"
}

remove_reality_config() {
    local tmp

    [[ -f "$CONFIG_FILE" ]] || {
        info "[Reality] 未找到配置文件，视为未安装。"
        state_delete_key "$REALITY_STATE_KEY" 2>/dev/null || true
        return 0
    }
    backup_config || {
        err "[Reality] 配置备份失败。"
        return 1
    }

    tmp="$(mktemp)" || return 1
    if ! jq --arg tag "$REALITY_TAG" --arg defender_tag "$REALITY_DEFENDER_TAG" '
        def has_defender_tag:
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $defender_tag) else . == $defender_tag end));
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag and .tag != $defender_tag))) |
        .routing = (.routing // {}) |
        .routing.rules = ((.routing.rules // []) | map(select((has_defender_tag) | not)))
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[Reality] jq 删除配置失败。"
        return 1
    fi
    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[Reality] 写入 $CONFIG_FILE 失败。"
        return 1
    }
    apply_config "VLESS TCP REALITY 删除" || return 1
    state_delete_key "$REALITY_STATE_KEY"
    state_set_meta_action "删除 VLESS TCP REALITY" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS TCP REALITY 已删除。"
}

random_xhttp_path() {
    printf '/api/%s' "$(openssl rand -hex 8)"
}

validate_xhttp_path() {
    local path="$1"

    [[ "$path" == /* ]] || return 1
    [[ "$path" != *" "* && "$path" != *"?"* && "$path" != *"#"* && "$path" != *"\\"* ]] || return 1
    [[ ${#path} -ge 2 && ${#path} -le 128 ]] || return 1
}

default_finalmask_json() {
    jq -cn '{
      tcp: [
        {
          type: "fragment",
          settings: {
            packets: "tlshello",
            length: "100-200",
            delay: "10-20",
            maxSplit: "3-6"
          }
        }
      ]
    }'
}

configure_vless_xhttp_finalmask() {
    local mode="${1:-interactive}"
    local input port

    if [[ "$mode" != "dry-run" ]]; then
        install_or_update_xray || return 1
    fi

    VLESS_MODE="${VLESS_MODE:-basic}"
    VLESS_ENC_METHOD="${VLESS_ENC_METHOD:-native}"
    VLESS_CLIENT_RTT="${VLESS_CLIENT_RTT:-0rtt}"
    VLESS_SERVER_TICKET="${VLESS_SERVER_TICKET:-600s}"
    VLESS_AUTH="${VLESS_AUTH:-x25519}"

    if [[ "$mode" == "interactive" ]]; then
        echo -e "\n${YELLOW}[配置] VLESS Encryption + XHTTP + FinalMask${PLAIN}"
        echo -e "  1) 基础模式 ${GREEN}(X25519/native/0rtt/600s)${PLAIN}"
        echo "  2) 高级模式 (认证、外观混淆、RTT、ticket)"
        read -r -p "选项 (默认: 1): " input
        if [[ "${input:-1}" == "2" ]]; then
            VLESS_MODE="advanced"
            configure_vless_advanced_options
        fi
        ask_vless_auth

        while true; do
            read -r -p "XHTTP 入口端口 (回车随机 20000-50000): " input
            if [[ -z "$input" ]]; then
                port="$(random_free_port 20000 50000)" || return 1
                info "[XHTTP] 随机选择端口: ${port}"
                XHTTP_PORT="$port"
                break
            fi
            if validate_port "$input" && ! port_used_in_config "$input" && check_port "$input"; then
                XHTTP_PORT="$input"
                break
            fi
            err "[XHTTP] 端口无效、被占用或已存在于 config.json。"
        done

        read -r -p "XHTTP path (回车随机): " input
        XHTTP_PATH="${input:-$(random_xhttp_path)}"
        read -r -p "开启 FinalMask? [Y/n]: " input
        case "${input,,}" in
            n | no) XHTTP_FINALMASK_ENABLED="false" ;;
            *) XHTTP_FINALMASK_ENABLED="true" ;;
        esac
    else
        if [[ -n "${XHTTP_PORT_REQUEST:-}" ]]; then
            validate_port "$XHTTP_PORT_REQUEST" || {
                err "[XHTTP] 端口无效: $XHTTP_PORT_REQUEST"
                return 1
            }
            if port_used_in_config "$XHTTP_PORT_REQUEST" || ! check_port "$XHTTP_PORT_REQUEST"; then
                err "[XHTTP] 端口已被占用或已存在于 config.json: $XHTTP_PORT_REQUEST"
                return 1
            fi
            XHTTP_PORT="$XHTTP_PORT_REQUEST"
        else
            XHTTP_PORT="$(random_free_port 20000 50000)" || return 1
        fi
        XHTTP_PATH="${XHTTP_PATH_REQUEST:-$(random_xhttp_path)}"
        XHTTP_FINALMASK_ENABLED="${XHTTP_FINALMASK_REQUEST:-true}"
    fi

    validate_xhttp_path "$XHTTP_PATH" || {
        err "[XHTTP] path 无效，必须以 / 开头，长度不超过 128，且不能包含空格、?、# 或反斜杠。"
        return 1
    }
    case "${XHTTP_FINALMASK_ENABLED,,}" in
        true | on | yes | y | 1) XHTTP_FINALMASK_ENABLED="true" ;;
        false | off | no | n | 0) XHTTP_FINALMASK_ENABLED="false" ;;
        *)
            err "[XHTTP] finalmask 参数必须为 on/off。"
            return 1
            ;;
    esac

    XHTTP_FINALMASK_JSON="$(default_finalmask_json)" || return 1
    VLESS_UUID="$(generate_uuid)" || return 1
    generate_vless_encryption_pair "$VLESS_AUTH" || return 1
}

encode_finalmask_for_share_link() {
    local finalmask_json="$1"

    json_url_encode "$finalmask_json"
}

build_vless_xhttp_finalmask_share_link() {
    local port="${XHTTP_PORT:-}"
    local path="${XHTTP_PATH:-}"
    local uuid="${VLESS_UUID:-}"
    local encryption="${VLESS_ENCRYPTION:-}"
    local finalmask_enabled="${XHTTP_FINALMASK_ENABLED:-}"
    local finalmask_json="${XHTTP_FINALMASK_JSON:-}"
    local host link_port endpoint_pair enc_uri path_uri fm_uri name_uri

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        path="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
        uuid="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
        encryption="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
        finalmask_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        finalmask_json="$(jq -c ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$path" && -n "$uuid" && -n "$encryption" ]] || return 1
    endpoint_pair="$(split_endpoint_for_link "$port")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    enc_uri="$(url_encode "$encryption")"
    path_uri="$(url_encode "$path")"
    name_uri="$(url_encode "Xray-XHTTP-FinalMask")"

    printf 'vless://%s@%s:%s?type=xhttp&security=none&path=%s&encryption=%s' \
        "$uuid" "$host" "$link_port" "$path_uri" "$enc_uri"
    if [[ "${finalmask_enabled,,}" == "true" && -n "$finalmask_json" && "$finalmask_json" != "null" ]]; then
        fm_uri="$(encode_finalmask_for_share_link "$finalmask_json")" || return 1
        printf '&fm=%s' "$fm_uri"
    fi
    printf '#%s' "$name_uri"
}

state_set_vless_xhttp_finalmask() {
    init_state
    local tmp link timestamp finalmask_json

    link="$(build_vless_xhttp_finalmask_share_link || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    finalmask_json="null"
    if [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]]; then
        finalmask_json="$XHTTP_FINALMASK_JSON"
    fi

    tmp="$(mktemp)" || return 1
    MSYS2_ENV_CONV_EXCL="XHTTP_JQ_VALUE" XHTTP_JQ_VALUE="$XHTTP_PATH" jq --arg port "$XHTTP_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg decryption "$VLESS_DECRYPTION" \
        --arg encryption "$VLESS_ENCRYPTION" \
        --arg auth "$VLESS_AUTH" \
        --arg enc_method "$VLESS_ENC_METHOD" \
        --arg client_rtt "$VLESS_CLIENT_RTT" \
        --arg server_ticket "$VLESS_SERVER_TICKET" \
        --arg finalmask_enabled "$XHTTP_FINALMASK_ENABLED" \
        --argjson finalmask_json "$finalmask_json" \
        --arg created_at "$timestamp" \
        --arg link "$link" '
        .vless_xhttp_finalmask = {
          "port": ($port|tonumber),
          "path": env.XHTTP_JQ_VALUE,
          "uuid": $uuid,
          "decryption": $decryption,
          "encryption": $encryption,
          "auth": $auth,
          "enc_method": $enc_method,
          "client_rtt": $client_rtt,
          "server_ticket": $server_ticket,
          "finalmask_enabled": ($finalmask_enabled == "true"),
          "finalmask_json": $finalmask_json,
          "created_at": $created_at,
          "link": $link
        }
       ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
}

print_xhttp_dry_run() {
    local temp_config="$1"
    local link fm_state

    link="$(build_vless_xhttp_finalmask_share_link || true)"
    fm_state="off"
    [[ "${XHTTP_FINALMASK_ENABLED:-false}" == "true" ]] && fm_state="on"
    echo -e "\n${YELLOW}XHTTP-FinalMask dry-run 预览${PLAIN}"
    echo "----------------------------------------"
    echo "入口端口: ${XHTTP_PORT}"
    echo "Path: ${XHTTP_PATH}"
    echo "FinalMask: ${fm_state}"
    [[ -n "$link" ]] && echo "Masked Link: $(mask_share_link "$link")"
    echo "将写入 inbound:"
    echo "- ${VLESS_XHTTP_FM_TAG}"
    jq empty "$temp_config" >/dev/null && echo "[✓] 临时 JSON 结构有效"
    xray_test_temp_config "$temp_config"
    echo "不会修改真实配置。"
}

install_vless_xhttp_finalmask() {
    local tmp finalmask_json config_source base_tmp

    config_source="$CONFIG_FILE"
    if [[ "${XHTTP_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${XHTTP_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[XHTTP] 配置备份失败。"
            return 1
        }
    fi
    finalmask_json="null"
    [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]] && finalmask_json="$XHTTP_FINALMASK_JSON"

    tmp="$(mktemp)" || return 1
    if ! MSYS2_ENV_CONV_EXCL="XHTTP_JQ_VALUE" XHTTP_JQ_VALUE="$XHTTP_PATH" jq --arg tag "$VLESS_XHTTP_FM_TAG" \
        --arg port "$XHTTP_PORT" \
        --arg uuid "$VLESS_UUID" \
        --arg decryption "$VLESS_DECRYPTION" \
        --argjson finalmask_json "$finalmask_json" \
        --arg finalmask_enabled "$XHTTP_FINALMASK_ENABLED" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [({
          "tag": $tag,
          "listen": "0.0.0.0",
          "port": ($port|tonumber),
          "protocol": "vless",
          "settings": {
            "clients": [
              {
                "id": $uuid,
                "email": "xhttp-finalmask@xray"
              }
            ],
            "decryption": $decryption
          },
          "streamSettings": {
            "network": "xhttp",
            "security": "none",
            "xhttpSettings": {
              "path": env.XHTTP_JQ_VALUE
            }
          },
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
          }
        } | if $finalmask_enabled == "true" then
          .streamSettings.finalmask = $finalmask_json
        else
          .
        end)]
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[XHTTP] jq 生成配置失败。"
        return 1
    fi

    if [[ "${XHTTP_DRY_RUN:-false}" == "true" ]]; then
        print_xhttp_dry_run "$tmp"
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        return 0
    fi
    [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"

    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[XHTTP] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "VLESS Encryption + XHTTP + FinalMask"; then
        if [[ "$XHTTP_FINALMASK_ENABLED" == "true" ]]; then
            err "[XHTTP] FinalMask 模板未通过 Xray 校验，可使用 --finalmask off 重试。"
        fi
        print_xhttp_failure_hint
        return 1
    fi
    state_set_vless_xhttp_finalmask || err "[状态] XHTTP-FinalMask 状态写入失败，但 config.json 已生效。"
    state_set_meta_action "安装 VLESS Encryption + XHTTP + FinalMask" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption + XHTTP + FinalMask 已写入 Xray 配置。"
    print_vless_xhttp_finalmask_result
}

print_vless_xhttp_finalmask_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port path uuid encryption auth enc_method rtt ticket fm_enabled fm_json endpoint_pair
    local address link_port

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[XHTTP-FinalMask] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[XHTTP-FinalMask] 未安装。"
        return 0
    fi

    link="$(build_vless_xhttp_finalmask_share_link || jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    port="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    path="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.path // empty" "$STATE_FILE" 2>/dev/null)"
    uuid="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.uuid // empty" "$STATE_FILE" 2>/dev/null)"
    encryption="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
    auth="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
    enc_method="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.enc_method // empty" "$STATE_FILE" 2>/dev/null)"
    rtt="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.client_rtt // empty" "$STATE_FILE" 2>/dev/null)"
    ticket="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.server_ticket // empty" "$STATE_FILE" 2>/dev/null)"
    fm_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
    fm_json="$(jq -c ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json // empty" "$STATE_FILE" 2>/dev/null)"
    endpoint_pair="$(split_endpoint_for_link "$port")"
    IFS=$'\t' read -r address link_port <<<"$endpoint_pair"

    echo -e "\n${YELLOW}--- VLESS Encryption + XHTTP + FinalMask ---${PLAIN}"
    echo -e "入口端口: ${port}"
    echo -e "Path: ${path}"
    if [[ "$fm_enabled" == "true" ]]; then
        echo -e "FinalMask: on"
    else
        echo -e "FinalMask: off（未启用 FinalMask）"
    fi
    [[ -n "$link" ]] && echo -e "VLESS URL: ${link}"
    if [[ ${#link} -gt 1800 ]]; then
        info "[XHTTP] FinalMask 链接较长，部分客户端可能需要手动填写参数。"
    fi
    echo "手动参数:"
    echo "  Protocol: VLESS"
    echo "  Transport: XHTTP"
    echo "  Security: none"
    echo "  Address: ${address}"
    echo "  Port: ${link_port}"
    echo "  UUID: ${uuid}"
    echo "  VLESS Encryption: ${encryption}"
    echo "  Path: ${path}"
    echo "  FinalMask: ${fm_enabled}"
    echo "  Auth: ${auth}"
    echo "  EncMethod: ${enc_method}"
    echo "  ClientRTT: ${rtt}"
    echo "  ServerTicket: ${ticket}"
    if [[ "$fm_enabled" == "true" && -n "$fm_json" && "$fm_json" != "null" ]]; then
        if [[ ${#fm_json} -gt 1200 ]]; then
            echo "  FinalMask JSON: 内容较长，可用 ike export clients 查看。"
        else
            echo "  FinalMask JSON: ${fm_json}"
        fi
    fi
    echo "兼容提示:"
    echo "  - XHTTP + FinalMask 需要较新的客户端核心。"
    echo "  - 如果导入失败，先尝试: ike xhttp install --finalmask off"
}

remove_vless_xhttp_finalmask_config() {
    local tmp

    [[ -f "$CONFIG_FILE" ]] || {
        info "[XHTTP] 未找到配置文件，视为未安装。"
        state_delete_key "$VLESS_XHTTP_FM_STATE_KEY" 2>/dev/null || true
        return 0
    }
    backup_config || {
        err "[XHTTP] 配置备份失败。"
        return 1
    }

    tmp="$(mktemp)" || return 1
    if ! jq --arg tag "$VLESS_XHTTP_FM_TAG" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag)))
       ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[XHTTP] jq 删除配置失败。"
        return 1
    fi
    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[XHTTP] 写入 $CONFIG_FILE 失败。"
        return 1
    }
    apply_config "VLESS XHTTP-FinalMask 删除" || return 1
    state_delete_key "$VLESS_XHTTP_FM_STATE_KEY"
    state_set_meta_action "删除 VLESS Encryption + XHTTP + FinalMask" || err "[状态] 最近变更记录失败。"
    ok "[完成] VLESS Encryption + XHTTP + FinalMask 已删除。"
}

install_socks5() {
    echo -e "\n${YELLOW}[配置] SOCKS5 参数:${PLAIN}"
    ask_port "SOCKS5 端口" "1080" S_PORT
    read -r -p "用户 (默认: admin): " S_USER
    S_USER="${S_USER:-admin}"
    read -r -p "密码 (默认: 随机): " S_PASS
    S_PASS="${S_PASS:-$(openssl rand -hex 8)}"

    install_or_update_xray || return 1
    backup_config

    local tmp
    tmp="$(mktemp)"
    jq --arg tag "$SOCKS_TAG" \
        --arg port "$S_PORT" \
        --arg user "$S_USER" \
        --arg pass "$S_PASS" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": "0.0.0.0",
          "port": ($port|tonumber),
          "protocol": "socks",
          "settings": {
            "auth": "password",
            "accounts": [{"user": $user, "pass": $pass}],
            "udp": true
          }
        }]
       ' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
    rm -f "$tmp"

    apply_config || return 1
    state_set_meta_action "安装 SOCKS5" || err "[状态] 最近变更记录失败。"
    ok "[完成] SOCKS5 已写入 Xray 配置。"
    view_config
}

get_public_addresses() {
    PUBLIC_IPV4="$(detect_public_ip "4" | awk -F '\t' 'NF{print $1; exit}')"
    PUBLIC_IPV6="$(detect_public_ip "6" | awk -F '\t' 'NF{print $1; exit}')"

    if [[ -z "$PUBLIC_IPV6" ]]; then
        PUBLIC_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n 1 | cut -d'/' -f1)"
    fi
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
    PUBLIC_IPV6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | head -n 1 | cut -d'/' -f1)"
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

default_private_block_mode() {
    if [[ -f "$ASSET_DIR/geoip.dat" ]]; then
        printf '%s' "geoip:private"
    else
        printf '%s' "CIDR fallback"
    fi
}

default_private_block_mode_arg() {
    if [[ -f "$ASSET_DIR/geoip.dat" ]]; then
        printf '%s' "geoip"
    else
        printf '%s' "cidr"
    fi
}

ensure_default_safety_blocks() {
    local tmp
    local private_mode

    [[ -f "$CONFIG_FILE" ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        err "[错误] 缺少 jq，无法写入默认安全屏蔽规则。"
        return 1
    }

    private_mode="$(default_private_block_mode_arg)"
    info "[安全] 默认私网屏蔽模式: $(default_private_block_mode)"

    tmp="$(mktemp)" || {
        err "[失败] [安全] 创建临时文件失败。"
        return 1
    }

    if ! jq --arg block "$BLOCK_OUTBOUND_TAG" \
        --arg reality_defender "$REALITY_DEFENDER_TAG" \
        --arg tunnel_prefix "$TUNNEL_TAG_PREFIX" \
        --arg legacy_prefix "$LEGACY_FORWARD_TAG_PREFIX" \
        --arg ports "$DEFAULT_SAFETY_BLOCK_PORTS" \
        --arg private_mode "$private_mode" '
        def private_fallback_ips:
          ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"];
        def private_ips:
          if $private_mode == "geoip" then ["geoip:private"] else private_fallback_ips end;
        def private_rule:
          {"type": "field", "ip": private_ips, "outboundTag": $block};
        def default_safety_rule:
          . == {"type": "field", "protocol": ["bittorrent"], "outboundTag": $block} or
          . == {"type": "field", "ip": ["geoip:private"], "outboundTag": $block} or
          . == {"type": "field", "ip": private_fallback_ips, "outboundTag": $block} or
          . == {"type": "field", "port": $ports, "outboundTag": $block};
        def forward_relay_rule:
          (.type == "field") and
          (.outboundTag == "direct") and
          (((.inboundTag // []) | if type == "array" then any(.[]; startswith($tunnel_prefix) or startswith($legacy_prefix)) else false end));
        def reality_defender_rule:
          (.type == "field") and
          (((.inboundTag // []) | if type == "array" then any(.[]; . == $reality_defender) else . == $reality_defender end));

        .outbounds = (.outbounds // []) |
        if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
          .
        else
          .outbounds += [{"tag": $block, "protocol": "blackhole"}]
        end |
        .routing = (.routing // {}) |
        .routing.rules = (
        ((.routing.rules // []) | map(select(forward_relay_rule or reality_defender_rule))) + [
          {"type": "field", "protocol": ["bittorrent"], "outboundTag": $block},
          private_rule,
          {"type": "field", "port": $ports, "outboundTag": $block}
        ] + ((.routing.rules // []) | map(select((default_safety_rule or forward_relay_rule or reality_defender_rule) | not))))
      ' "$CONFIG_FILE" >"$tmp"; then
        rm -f "$tmp"
        err "[失败] [安全] 写入默认安全屏蔽规则失败。"
        return 1
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [安全] 更新 $CONFIG_FILE 失败。"
        return 1
    fi
}

default_safety_block_enabled() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg block "$BLOCK_OUTBOUND_TAG" \
        --arg ports "$DEFAULT_SAFETY_BLOCK_PORTS" \
        --arg private_mode "$(default_private_block_mode_arg)" '
      def private_fallback_ips:
        ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"];
      def private_ips:
        if $private_mode == "geoip" then ["geoip:private"] else private_fallback_ips end;
      any(.routing.rules[]?; . == {"type": "field", "protocol": ["bittorrent"], "outboundTag": $block}) and
      any(.routing.rules[]?; . == {"type": "field", "ip": private_ips, "outboundTag": $block}) and
      any(.routing.rules[]?; . == {"type": "field", "port": $ports, "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

default_safety_block_status() {
    if default_safety_block_enabled; then
        printf '%s' "已启用"
    else
        printf '%s' "未启用"
    fi
}

enhanced_safety_block_enabled() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    jq -e --arg block "$BLOCK_OUTBOUND_TAG" \
        --arg ports "$ENHANCED_SAFETY_BLOCK_PORTS" '
      .routing.rules[]? |
      select(. == {"type": "field", "port": $ports, "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1
}

enhanced_safety_block_status() {
    if enhanced_safety_block_enabled; then
        printf '%s' "已启用"
    else
        printf '%s' "未启用"
    fi
}

set_enhanced_safety_block() {
    local enable="$1"
    local tmp action

    init_config || return 1
    backup_config || {
        err "[失败] [安全] 配置备份失败。"
        return 1
    }

    tmp="$(mktemp)" || {
        err "[失败] [安全] 创建临时文件失败。"
        return 1
    }

    if [[ "$enable" == "true" ]]; then
        info "[安全] 正在开启增强安全屏蔽..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" \
            --arg ports "$ENHANCED_SAFETY_BLOCK_PORTS" '
          def enhanced_safety_rule:
            . == {"type": "field", "port": $ports, "outboundTag": $block};

          .outbounds = (.outbounds // []) |
          if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
            .
          else
            .outbounds += [{"tag": $block, "protocol": "blackhole"}]
          end |
          .routing = (.routing // {}) |
          .routing.rules = ([
            {"type": "field", "port": $ports, "outboundTag": $block}
          ] + ((.routing.rules // []) | map(select((enhanced_safety_rule) | not))))
        ' "$CONFIG_FILE" >"$tmp"; then
            rm -f "$tmp"
            err "[失败] [安全] 生成增强安全屏蔽规则失败。"
            return 1
        fi
    else
        info "[安全] 正在关闭增强安全屏蔽..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" \
            --arg ports "$ENHANCED_SAFETY_BLOCK_PORTS" '
          def enhanced_safety_rule:
            . == {"type": "field", "port": $ports, "outboundTag": $block};

          .routing = (.routing // {}) |
          .routing.rules = ((.routing.rules // []) | map(select((enhanced_safety_rule) | not)))
        ' "$CONFIG_FILE" >"$tmp"; then
            rm -f "$tmp"
            err "[失败] [安全] 移除增强安全屏蔽规则失败。"
            return 1
        fi
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [安全] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    if ! apply_config "安全"; then
        err "[失败] [安全] 应用增强安全屏蔽设置失败。"
        return 1
    fi

    action="关闭"
    [[ "$enable" == "true" ]] && action="启用"
    state_set_meta_action "增强安全屏蔽: ${action}" || err "[状态] 最近变更记录失败。"
    ok "[完成] 增强安全屏蔽已${action}。"
}

configure_enhanced_safety_block() {
    local current choice

    install_or_update_xray || {
        err "[失败] [安全] Xray 安装/更新失败，无法修改增强安全屏蔽。"
        return 1
    }

    current="$(enhanced_safety_block_status)"
    echo -e "\n${YELLOW}[安全] 增强安全屏蔽:${PLAIN} ${current}"

    if enhanced_safety_block_enabled; then
        echo " 1) 关闭增强安全屏蔽"
        echo " 2) 保持开启"
        read -r -p "选项 (默认: 2): " choice
        case "${choice:-2}" in
            1) set_enhanced_safety_block "false" ;;
            2) info "[安全] 保持开启。" ;;
            *)
                err "无效选项。"
                return 1
                ;;
        esac
    else
        echo " 1) 开启增强安全屏蔽"
        echo " 2) 保持关闭"
        read -r -p "选项 (默认: 2): " choice
        case "${choice:-2}" in
            1) set_enhanced_safety_block "true" ;;
            2) info "[安全] 保持关闭。" ;;
            *)
                err "无效选项。"
                return 1
                ;;
        esac
    fi
}

china_direct_block_enabled() {
    [[ "$(china_direct_block_status)" != "未启用" ]]
}

china_direct_block_status() {
    local has_ip="false"
    local has_domain="false"

    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "未启用"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        printf '%s' "未启用"
        return 0
    }

    if jq -e --arg block "$BLOCK_OUTBOUND_TAG" '
      any(.routing.rules[]?; . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        has_ip="true"
    fi

    if jq -e --arg block "$BLOCK_OUTBOUND_TAG" '
      any(.routing.rules[]?; . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block})
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        has_domain="true"
    fi

    if [[ "$has_ip" == "true" && "$has_domain" == "true" ]]; then
        printf '%s' "增强模式"
    elif [[ "$has_ip" == "true" ]]; then
        printf '%s' "基础模式"
    else
        printf '%s' "未启用"
    fi
}

check_china_direct_block_assets() {
    local mode="${1:-basic}"
    local missing=()

    [[ -f "$ASSET_DIR/geoip.dat" ]] || missing+=("$ASSET_DIR/geoip.dat")
    if [[ "$mode" == "enhanced" ]]; then
        [[ -f "$ASSET_DIR/geosite.dat" ]] || missing+=("$ASSET_DIR/geosite.dat")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "[错误] 缺少 Xray 路由资源: ${missing[*]}"
        if [[ "$mode" == "enhanced" ]]; then
            err "[提示] 增强模式需要 geoip.dat 和 geosite.dat；基础模式只需要 geoip.dat。"
        else
            err "[提示] 中国大陆直连屏蔽基础模式需要 geoip.dat。"
        fi
        err "[提示] 请先执行 1) 安装/更新 Xray 核心 或 ike update，确保路由资源存在。"
        return 1
    fi

    return 0
}

set_china_direct_block() {
    local mode="$1"
    local tmp action

    init_config || return 1

    case "$mode" in
        off | basic | enhanced) ;;
        *)
            err "[失败] [路由] 未知中国大陆直连屏蔽模式: $mode"
            return 1
            ;;
    esac

    if [[ "$mode" != "off" ]]; then
        check_china_direct_block_assets "$mode" || return 1
    fi

    backup_config || {
        err "[失败] [路由] 配置备份失败。"
        return 1
    }

    tmp="$(mktemp)" || {
        err "[失败] [路由] 创建临时文件失败。"
        return 1
    }

    if [[ "$mode" == "basic" ]]; then
        info "[路由] 正在开启中国大陆直连屏蔽基础模式..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" '
          def cn_block_rule:
            . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block} or
            . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block};

          .outbounds = (.outbounds // []) |
          if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
            .
          else
            .outbounds += [{"tag": $block, "protocol": "blackhole"}]
          end |
          .routing = (.routing // {}) |
          .routing.rules = ([
            {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block}
          ] + ((.routing.rules // []) | map(select((cn_block_rule) | not))))
        ' "$CONFIG_FILE" >"$tmp"; then
            rm -f "$tmp"
            err "[失败] [路由] 生成中国大陆直连屏蔽规则失败。"
            return 1
        fi
    elif [[ "$mode" == "enhanced" ]]; then
        info "[路由] 正在开启中国大陆直连屏蔽增强模式..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" '
          def cn_block_rule:
            . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block} or
            . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block};

          .outbounds = (.outbounds // []) |
          if ((.outbounds | map(select(.tag == $block)) | length) > 0) then
            .
          else
            .outbounds += [{"tag": $block, "protocol": "blackhole"}]
          end |
          .routing = (.routing // {}) |
          .routing.rules = ([
            {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block},
            {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block}
          ] + ((.routing.rules // []) | map(select((cn_block_rule) | not))))
        ' "$CONFIG_FILE" >"$tmp"; then
            rm -f "$tmp"
            err "[失败] [路由] 生成中国大陆直连屏蔽规则失败。"
            return 1
        fi
    else
        info "[路由] 正在关闭中国大陆直连屏蔽..."
        if ! jq --arg block "$BLOCK_OUTBOUND_TAG" '
          def cn_block_rule:
            . == {"type": "field", "ip": ["geoip:cn"], "outboundTag": $block} or
            . == {"type": "field", "domain": ["geosite:cn"], "outboundTag": $block};

          .routing = (.routing // {}) |
          .routing.rules = ((.routing.rules // []) | map(select((cn_block_rule) | not)))
        ' "$CONFIG_FILE" >"$tmp"; then
            rm -f "$tmp"
            err "[失败] [路由] 移除中国大陆直连屏蔽规则失败。"
            return 1
        fi
    fi

    if ! mv "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
        err "[失败] [路由] 写入 $CONFIG_FILE 失败。"
        return 1
    fi

    if ! apply_config "路由"; then
        err "[失败] [路由] 应用中国大陆直连屏蔽设置失败。"
        return 1
    fi

    case "$mode" in
        basic) action="基础模式" ;;
        enhanced) action="增强模式" ;;
        *) action="关闭" ;;
    esac
    state_set_meta_action "中国大陆直连屏蔽: ${action}" || err "[状态] 最近变更记录失败。"
    ok "[完成] 中国大陆直连屏蔽已设置为${action}。"
}

configure_china_direct_block() {
    local current choice

    install_or_update_xray || {
        err "[失败] [路由] Xray 安装/更新失败，无法修改路由设置。"
        return 1
    }

    current="$(china_direct_block_status)"
    echo -e "\n${YELLOW}[路由] 中国大陆直连屏蔽:${PLAIN} ${current}"

    echo " 1) 开启基础模式 (仅 geoip:cn IP)"
    echo " 2) 开启增强模式 (geoip:cn IP + geosite:cn 域名)"
    echo " 3) 关闭中国大陆直连屏蔽"
    echo " 4) 保持当前状态"
    read -r -p "选项 (默认: 4): " choice
    case "${choice:-4}" in
        1) set_china_direct_block "basic" ;;
        2) set_china_direct_block "enhanced" ;;
        3) set_china_direct_block "off" ;;
        4) info "[路由] 保持当前状态。" ;;
        *)
            err "无效选项。"
            return 1
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
    err "[建议] FinalMask 仍属实验能力；如校验或客户端导入失败，优先重试: ike xhttp install --finalmask off"
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
            FORWARD_SCENARIO_TITLE="多端口落地组（portMap 实验 / fallback 多条 single）"
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
bash install.sh
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
bash "$SCRIPT_PATH"
ike tunnel bundle import "$BUNDLE_DIR" --yes
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

    echo -e "\n${YELLOW}[Tunnel 中转] 多端口落地组（portMap 实验）${PLAIN}"
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
        echo " 2) 多端口落地组（portMap 实验 / fallback 多条 single）"
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
        [[ -n "$IPV6_HOST" ]] && echo -e "IPv6链接: ss://${user_info}@${IPV6_HOST}:${ssp}#SS2022-IPv6"
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
            [[ -n "$IPV6_HOST" ]] && echo -e "IPv6链接: vless://${vu}@${IPV6_HOST}:${vp}?type=tcp&security=none&encryption=${venc_uri}#VLESS-ENC-IPv6"
        fi
    fi

    print_reality_result
    print_vless_xhttp_finalmask_result

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
        [[ -n "$IPV6_HOST" ]] && echo -e "IPv6链接: socks5://${su}:${sw}@${IPV6_HOST}:${sp}"
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

uninstall() {
    echo -e "\n${YELLOW}[卸载] 选择:${PLAIN}"
    echo " 1) 删除 SS2022 配置"
    echo " 2) 删除 VLESS Encryption 配置"
    echo " 3) 删除 VLESS TCP REALITY 配置"
    echo " 4) 删除 VLESS Encryption + XHTTP + FinalMask 配置"
    echo " 5) 删除 SOCKS5 配置"
    echo " 6) 卸载全部 Xray"
    echo " 7) 清理旧 sing-box 残留"
    read -r -p "选项: " OPT

    case "$OPT" in
        1)
            remove_inbound "$SS_TAG"
            apply_config
            ok "[完成] SS2022 已删除。"
            ;;
        2)
            remove_inbound "$VLESS_TAG"
            state_delete_key "vless_encryption"
            apply_config
            ok "[完成] VLESS Encryption 已删除。"
            ;;
        3)
            remove_reality_config
            ;;
        4)
            remove_vless_xhttp_finalmask_config
            ;;
        5)
            remove_inbound "$SOCKS_TAG"
            apply_config
            ok "[完成] SOCKS5 已删除。"
            ;;
        6)
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
            ok "[完成] Xray 已彻底卸载。"
            exit 0
            ;;
        7)
            cleanup_legacy_singbox
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
    echo -e "${GREEN}7.${PLAIN} 安装 SOCKS5 代理"
    echo -e "${GREEN}8.${PLAIN} 查看当前配置链接"
    echo -e "${GREEN}9.${PLAIN} 设置链接显示模式 (IPv4/IPv6/双栈)"
    echo -e "${GREEN}10.${PLAIN} 重置密钥/密码（端口不变）"
    echo -e "${RED}11.${PLAIN} 卸载/清理"
    echo -e "${GREEN}12.${PLAIN} 开启/关闭中国大陆直连屏蔽"
    echo -e "${GREEN}13.${PLAIN} 开启/关闭增强安全屏蔽"
    echo -e "${GREEN}14.${PLAIN} 导出当前配置备份"
    echo -e "${GREEN}15.${PLAIN} Tunnel 中转管理"
    echo -e "${GREEN}16.${PLAIN} 退出"
    echo -e "----------------------------------------------"
}

show_menu() {
    install_shortcut

    while true; do
        render_menu
        read -r -p "请输入选项 [1-16]: " MENU_CHOICE || exit 0

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
                        info "[IPv6] 请先在服务器开通 IPv6 后重试。"
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
                if ! { prepare_system && install_socks5; }; then
                    err "[失败] SOCKS5 安装未完成，请查看上方错误信息。"
                fi
                ;;
            8)
                view_config || err "[失败] 查看当前配置链接失败，请查看上方错误信息。"
                ;;
            9)
                set_link_view_mode || err "[失败] 设置链接显示模式失败，请查看上方错误信息。"
                ;;
            10)
                if ! { prepare_system && reset_secrets; }; then
                    err "[失败] 重置密钥/密码未完成，请查看上方错误信息。"
                fi
                ;;
            11)
                uninstall || err "[失败] 卸载/清理未完成，请查看上方错误信息。"
                ;;
            12)
                configure_china_direct_block || err "[失败] 中国大陆直连屏蔽设置未完成，请查看上方错误信息。"
                ;;
            13)
                configure_enhanced_safety_block || err "[失败] 增强安全屏蔽设置未完成，请查看上方错误信息。"
                ;;
            14)
                export_current_config_backup || err "[失败] 导出当前配置备份未完成，请查看上方错误信息。"
                ;;
            15)
                configure_forward_menu || err "[失败] Tunnel 中转管理未完成，请查看上方错误信息。"
                ;;
            16) exit 0 ;;
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
            *)
                err "[失败] 未知 view 参数: $1"
                echo "用法: ike view [ipv4|ipv6|dual] [doctor]"
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
        case "$protocol" in
            reality)
                print_reality_result "show"
                ;;
            xhttp)
                print_vless_xhttp_finalmask_result "show"
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

diag_ok() { echo "[✓] $*"; }
diag_warn() { echo "[!] $*"; }
diag_fail() { echo "[✗] $*"; }
diag_info() { echo "[i] $*"; }

redact_sensitive_stream() {
    sed -E \
        -e 's/("(privateKey|private_key|decryption|password|pass|token|secret)"[[:space:]]*:[[:space:]]*")[^"]*/\1***REDACTED***/Ig' \
        -e 's/((privateKey|private_key|decryption|password|pass|token|secret|method secret)[[:space:]]*[=:][[:space:]]*)[^[:space:],;]+/\1***REDACTED***/Ig'
}

inbound_exists() {
    local tag="$1"
    [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1 &&
        jq -e --arg tag "$tag" 'any(.inbounds[]?; .tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1
}

port_listening() {
    local port="$1"

    command -v ss >/dev/null 2>&1 || return 2
    ss -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

port_listening_localhost() {
    local port="$1"

    command -v ss >/dev/null 2>&1 || return 2
    ss -tulpn 2>/dev/null | grep -qE "(127\.0\.0\.1|::1|\[::1\])[:.]${port}[[:space:]]"
}

doctor_reality_config() {
    [[ -f "$CONFIG_FILE" ]] && diag_ok "config.json 存在" || diag_fail "config.json 不存在"
    [[ -x "$BIN_PATH" ]] && diag_ok "xray 二进制存在" || diag_warn "xray 二进制不存在: $BIN_PATH"
    command -v systemctl >/dev/null 2>&1 && diag_ok "systemctl 存在" || diag_warn "systemctl 不存在或当前系统未使用 systemd"
    command -v ss >/dev/null 2>&1 && diag_ok "ss 存在" || diag_warn "ss 不存在，端口监听检查将降级"
    command -v jq >/dev/null 2>&1 && diag_ok "jq 存在" || diag_fail "jq 不存在"
    command -v openssl >/dev/null 2>&1 && diag_ok "openssl 存在" || diag_warn "openssl 不存在，SNI TLS 探测不可用"
}

doctor_xray_x25519() {
    local output status old_private old_public old_hash

    echo -e "\n${YELLOW}Xray x25519 诊断${PLAIN}"
    echo "----------------------------------------"
    if [[ ! -x "$BIN_PATH" ]]; then
        diag_warn "xray 二进制不存在，跳过 x25519 检查: $BIN_PATH"
        return 0
    fi

    output="$("$BIN_PATH" x25519 2>&1)"
    status=$?
    if ((status != 0)); then
        diag_fail "xray x25519 执行失败，退出码: ${status}"
        print_masked_x25519_output "$output"
        return 0
    fi

    old_private="${REALITY_PRIVATE_KEY:-}"
    old_public="${REALITY_PUBLIC_KEY:-}"
    old_hash="${REALITY_X25519_HASH32:-}"
    if parse_xray_x25519_output "$output"; then
        diag_ok "xray x25519 输出可解析"
        diag_ok "privateKey 已识别（脱敏）: $(mask_x25519_value "$REALITY_PRIVATE_KEY")"
        diag_ok "publicKey/pbk 已识别（脱敏）: $(mask_x25519_value "$REALITY_PUBLIC_KEY")"
        [[ -n "${REALITY_X25519_HASH32:-}" ]] && diag_info "Hash32: $(mask_x25519_value "$REALITY_X25519_HASH32")"
    else
        diag_fail "当前 Xray x25519 输出格式未被识别"
        print_masked_x25519_output "$output"
    fi
    REALITY_PRIVATE_KEY="$old_private"
    REALITY_PUBLIC_KEY="$old_public"
    REALITY_X25519_HASH32="$old_hash"
}

doctor_reality_routing() {
    local sni="$1"

    if jq -e --arg defender "$REALITY_DEFENDER_TAG" --arg sni "$sni" --arg block "$BLOCK_OUTBOUND_TAG" '
      .routing.rules as $rules |
      ($rules | map((.inboundTag // []) == [$defender] and (.domain // []) == ["full:" + $sni] and (.outboundTag == "direct" or .outboundTag == "DIRECT")) | index(true)) as $direct |
      ($rules | map((.inboundTag // []) == [$defender] and .outboundTag == $block) | index(true)) as $block_idx |
      ($direct != null and $block_idx != null and $direct < $block_idx)
    ' "$CONFIG_FILE" >/dev/null 2>&1; then
        diag_ok "Reality routing 顺序正确"
    else
        diag_fail "Reality routing 顺序异常，full:SNI -> direct 必须在 defender -> BLOCK 前面"
    fi
}

doctor_reality_port() {
    local port="$1"
    local defender_port="$2"

    if port_listening "$port"; then
        diag_ok "Reality 主端口正在监听: ${port}"
    elif [[ $? -eq 2 ]]; then
        diag_warn "未找到 ss，跳过 Reality 主端口监听检查"
    else
        diag_warn "Reality 主端口未监听: ${port}；如服务未运行，请执行 systemctl restart xray"
    fi

    if port_listening_localhost "$defender_port"; then
        diag_ok "Reality defender 端口仅本地监听: 127.0.0.1:${defender_port}"
    elif [[ $? -eq 2 ]]; then
        diag_warn "未找到 ss，跳过 defender 端口监听检查"
    else
        diag_warn "Reality defender 端口未检测到 127.0.0.1 监听: ${defender_port}"
    fi
}

doctor_reality_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        diag_warn "installer-state.json 不存在"
        return 0
    fi
    jq -e ".${REALITY_STATE_KEY}.port and .${REALITY_STATE_KEY}.defender_port and .${REALITY_STATE_KEY}.uuid and .${REALITY_STATE_KEY}.public_key and .${REALITY_STATE_KEY}.default_short_id and .${REALITY_STATE_KEY}.server_name and .${REALITY_STATE_KEY}.flow and .${REALITY_STATE_KEY}.link" "$STATE_FILE" >/dev/null 2>&1 &&
        diag_ok "Reality state 字段完整" ||
        diag_warn "Reality state 字段不完整，可重新执行 ike reality install"
}

doctor_reality_sni() {
    local sni="$1"

    if validate_reality_sni "$sni"; then
        diag_ok "SNI 格式合理"
    else
        diag_fail "SNI 格式异常: ${sni}"
    fi
    if env_truthy "${XRAY_ONECLICK_DOCTOR_TLS:-}"; then
        if test_reality_target_tls "$sni"; then
            diag_ok "SNI TLS 探测通过: ${sni}:443"
        else
            diag_warn "SNI TLS 探测失败，建议更换域名或稍后重试"
        fi
    else
        diag_info "如需探测 SNI TLS，可执行: XRAY_ONECLICK_DOCTOR_TLS=1 ike doctor reality"
    fi
}

doctor_reality_output() {
    local public_key short_id sni

    public_key="$(jq -r ".${REALITY_STATE_KEY}.public_key // empty" "$STATE_FILE" 2>/dev/null)"
    short_id="$(jq -r ".${REALITY_STATE_KEY}.default_short_id // empty" "$STATE_FILE" 2>/dev/null)"
    sni="$(jq -r ".${REALITY_STATE_KEY}.server_name // empty" "$STATE_FILE" 2>/dev/null)"
    [[ -n "$sni" ]] && diag_info "SNI: ${sni}"
    [[ -n "$public_key" ]] && diag_info "PublicKey: ${public_key}"
    [[ -n "$short_id" ]] && diag_info "ShortID: ${short_id}"
}

doctor_reality() {
    local r_in d_in port defender_port sni flow dest short_count

    echo -e "\n${YELLOW}Reality 诊断${PLAIN}"
    echo "----------------------------------------"
    doctor_reality_config
    doctor_xray_x25519
    if ! inbound_exists "$REALITY_TAG"; then
        diag_info "Reality 未安装，跳过 Reality 专项检查"
        return 0
    fi
    inbound_exists "$REALITY_DEFENDER_TAG" && diag_ok "Reality defender 已安装" || diag_fail "Reality defender 未安装"
    diag_ok "Reality inbound 已安装"

    r_in="$(jq -c --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE")"
    d_in="$(jq -c --arg tag "$REALITY_DEFENDER_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE")"
    port="$(echo "$r_in" | jq -r '.port // empty')"
    defender_port="$(echo "$d_in" | jq -r '.port // empty')"
    sni="$(echo "$r_in" | jq -r '.streamSettings.realitySettings.serverNames[0] // empty')"
    flow="$(echo "$r_in" | jq -r '.settings.clients[0].flow // empty')"
    dest="$(echo "$r_in" | jq -r '.streamSettings.realitySettings.dest // empty')"
    short_count="$(echo "$r_in" | jq -r '.streamSettings.realitySettings.shortIds | length')"

    echo "$r_in" | jq -e '.protocol == "vless" and .streamSettings.network == "tcp" and .streamSettings.security == "reality"' >/dev/null && diag_ok "Reality inbound 协议/传输/安全类型正确" || diag_fail "Reality inbound 协议/传输/安全类型异常"
    echo "$r_in" | jq -e '(.settings.clients[0].id // "") != ""' >/dev/null && diag_ok "Reality UUID 存在" || diag_fail "Reality UUID 缺失"
    if [[ "$flow" == "$REALITY_FLOW_DEFAULT" ]]; then
        diag_ok "Reality flow 一致：${REALITY_FLOW_DEFAULT}"
    elif [[ -z "$flow" ]]; then
        diag_warn "旧 Reality 配置缺少 flow，建议重新执行 ike reality install。"
    else
        diag_fail "Reality flow 异常: ${flow}"
    fi
    echo "$r_in" | jq -e '(.streamSettings.realitySettings.privateKey // "") != ""' >/dev/null && diag_ok "Reality privateKey 已写入服务端配置（默认不输出值）" || diag_fail "Reality privateKey 缺失"
    [[ -n "$sni" ]] && diag_ok "Reality serverNames 已配置" || diag_fail "Reality serverNames 缺失"
    ((short_count == 8)) && diag_ok "Reality shortIds 数量为 8" || diag_warn "Reality shortIds 数量为 ${short_count}"
    [[ "$dest" == "127.0.0.1:${defender_port}" ]] && diag_ok "Reality dest 指向 defender: ${dest}" || diag_fail "Reality dest 异常: ${dest}"
    echo "$d_in" | jq -e --arg sni "$sni" '.listen == "127.0.0.1" and .protocol == "dokodemo-door" and .settings.address == $sni and .settings.port == 443 and .settings.network == "tcp"' >/dev/null && diag_ok "Reality defender 配置正确" || diag_fail "Reality defender 配置异常"
    doctor_reality_routing "$sni"
    doctor_reality_state
    doctor_reality_port "$port" "$defender_port"
    doctor_reality_sni "$sni"
    doctor_reality_output
}

doctor_xhttp() {
    local x_in state_enabled config_has_fm link fm path

    echo -e "\n${YELLOW}XHTTP-FinalMask 诊断${PLAIN}"
    echo "----------------------------------------"
    [[ -f "$CONFIG_FILE" ]] && diag_ok "config.json 存在" || diag_fail "config.json 不存在"
    command -v jq >/dev/null 2>&1 && diag_ok "jq 存在" || diag_fail "jq 不存在"
    if ! inbound_exists "$VLESS_XHTTP_FM_TAG"; then
        diag_info "XHTTP-FinalMask 未安装，跳过 XHTTP 专项检查"
        return 0
    fi
    x_in="$(jq -c --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE")"
    path="$(echo "$x_in" | jq -r '.streamSettings.xhttpSettings.path // empty')"
    echo "$x_in" | jq -e '.protocol == "vless" and (.settings.decryption // "") != "" and .streamSettings.network == "xhttp" and .streamSettings.security == "none"' >/dev/null && diag_ok "XHTTP inbound 协议/加密/传输配置正确" || diag_fail "XHTTP inbound 配置异常"
    validate_xhttp_path "$path" && diag_ok "XHTTP path 合法: ${path}" || diag_fail "XHTTP path 非法: ${path}"
    if [[ -f "$STATE_FILE" ]]; then
        jq -e ".${VLESS_XHTTP_FM_STATE_KEY}.port and .${VLESS_XHTTP_FM_STATE_KEY}.path and .${VLESS_XHTTP_FM_STATE_KEY}.encryption and (.${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled != null) and .${VLESS_XHTTP_FM_STATE_KEY}.link" "$STATE_FILE" >/dev/null 2>&1 &&
            diag_ok "XHTTP state 字段完整" ||
            diag_warn "XHTTP state 字段不完整"
        state_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        link="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"
    else
        diag_warn "installer-state.json 不存在"
        state_enabled="false"
        link=""
    fi
    config_has_fm="$(echo "$x_in" | jq -r '.streamSettings | has("finalmask")')"
    if [[ "$state_enabled" == "true" ]]; then
        [[ "$config_has_fm" == "true" ]] && diag_ok "FinalMask 已写入 config" || diag_fail "state 显示 FinalMask on，但 config 未写 finalmask"
        jq -e ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_json" "$STATE_FILE" >/dev/null 2>&1 && diag_ok "FinalMask JSON 已写入 state" || diag_fail "FinalMask JSON 缺失"
        [[ "$link" == *"fm="* ]] && diag_ok "分享链接包含 fm 参数" || diag_fail "分享链接缺少 fm 参数"
        fm="${link#*fm=}"
        fm="${fm%%#*}"
        [[ "$fm" != *"{"* && "$fm" != *"}"* && "$fm" != *" "* && "$fm" != *"\""* ]] && diag_ok "fm 参数已 URL 编码" || diag_fail "fm 参数包含未编码 JSON 字符"
    else
        [[ "$config_has_fm" == "false" ]] && diag_ok "FinalMask off 时 config 未写 finalmask" || diag_fail "FinalMask off 时 config 仍存在 finalmask"
        [[ "$link" != *"fm="* ]] && diag_ok "FinalMask off 时链接不含 fm" || diag_fail "FinalMask off 时链接仍含 fm"
    fi
    diag_info "Encryption: $(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.encryption // empty" "$STATE_FILE" 2>/dev/null)"
}

doctor_proxy() {
    local tags ports

    echo -e "\n${YELLOW}Xray 代理总览诊断${PLAIN}"
    echo "----------------------------------------"
    [[ -x "$BIN_PATH" ]] && diag_ok "xray 二进制存在" || diag_warn "xray 二进制不存在"
    diag_info "Xray binary: $BIN_PATH"
    diag_info "Xray version: $(detect_xray_version 2>/dev/null || printf '%s' '未安装')"
    [[ -f "$CONFIG_FILE" ]] && diag_ok "config.json 存在" || diag_fail "config.json 不存在"
    command -v jq >/dev/null 2>&1 && diag_ok "jq 存在" || diag_fail "jq 不存在"
    if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v systemctl >/dev/null 2>&1; then
        [[ "$(xray_service_status)" == "运行中" ]] && diag_ok "xray 服务运行中" || diag_warn "xray 服务当前未运行"
    else
        diag_warn "未检测到 systemd，跳过 systemctl 服务检查"
    fi
    [[ -f "$CONFIG_FILE" && -x "$BIN_PATH" ]] && diag_info "Xray 配置校验: $(xray_config_test_status)"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        tags="$(jq -r '[.inbounds[]?.tag] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        ports="$(jq -r '[.inbounds[]? | select(.port != null) | (.tag + ":" + (.port|tostring))] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        diag_info "已安装 inbound tags: ${tags:-无}"
        diag_info "监听端口: ${ports:-无}"
    fi
    default_safety_block_enabled && diag_ok "默认安全屏蔽规则存在" || diag_warn "默认安全屏蔽规则未完整启用"
    detect_xray_feature_support
    doctor_xray_x25519
    if view_config dual quick >/dev/null 2>&1; then
        diag_ok "ike view 可以输出"
    else
        diag_warn "ike view 输出失败，请检查配置和 state"
    fi
}

run_doctor_command() {
    local target="${1:-all}"

    case "$target" in
        preflight) preflight_system ;;
        reality-key) doctor_xray_x25519 ;;
        reality) doctor_reality ;;
        xhttp) doctor_xhttp ;;
        proxy) doctor_proxy ;;
        all | "")
            preflight_system || true
            view_config "$LINK_VIEW_MODE" "doctor" || true
            doctor_proxy
            doctor_reality
            doctor_xhttp
            ;;
        *)
            err "[失败] 未知 doctor 参数: $target"
            echo "用法: ike doctor preflight|reality-key|reality|xhttp|proxy|all"
            return 1
            ;;
    esac
}

show_journal_recent() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 80 --no-pager 2>&1 | redact_sensitive_stream || true
    else
        diag_warn "journalctl 不存在，无法读取最近日志"
    fi
}

run_xray_config_test_verbose() {
    if [[ ! -x "$BIN_PATH" ]]; then
        diag_warn "xray 不存在，跳过 xray run -test"
        return 0
    fi
    if "$BIN_PATH" run -test -c "$CONFIG_FILE"; then
        diag_ok "xray run -test 通过"
        return 0
    fi
    diag_fail "xray run -test 失败"
    return 1
}

smoke_reality() {
    local restart="${1:-false}" port defender_port

    echo -e "\n${YELLOW}Reality 烟测辅助${PLAIN}"
    echo "----------------------------------------"
    if ! inbound_exists "$REALITY_TAG"; then
        diag_info "Reality 未安装，跳过 Reality smoke"
        return 0
    fi
    print_reality_result "show"
    run_xray_config_test_verbose || print_reality_failure_hint
    if [[ "$restart" == "true" ]]; then
        if restart_xray_service; then
            diag_ok "xray restart 成功"
        else
            diag_fail "xray restart 失败，最近日志如下"
            show_journal_recent
            diag_warn "可检查备份并重新部署 Reality，但脚本不会自动删除其它配置。"
        fi
    else
        diag_info "默认不自动 restart；如需重启请执行: ike smoke reality --restart"
    fi
    diag_info "Xray 服务状态: $(xray_service_status)"
    port="$(jq -r --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag).port // empty' "$CONFIG_FILE")"
    defender_port="$(jq -r --arg tag "$REALITY_DEFENDER_TAG" '.inbounds[]? | select(.tag == $tag).port // empty' "$CONFIG_FILE")"
    doctor_reality_port "$port" "$defender_port"
    show_journal_recent
}

smoke_xhttp() {
    local restart="${1:-false}" port fm_enabled

    echo -e "\n${YELLOW}XHTTP-FinalMask 烟测辅助${PLAIN}"
    echo "----------------------------------------"
    if ! inbound_exists "$VLESS_XHTTP_FM_TAG"; then
        diag_info "XHTTP-FinalMask 未安装，跳过 XHTTP smoke"
        return 0
    fi
    print_vless_xhttp_finalmask_result "show"
    if ! run_xray_config_test_verbose; then
        fm_enabled="$(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
        [[ "$fm_enabled" == "true" ]] && print_finalmask_failure_hint
        print_xhttp_failure_hint
    fi
    if [[ "$restart" == "true" ]]; then
        if restart_xray_service; then
            diag_ok "xray restart 成功"
        else
            diag_fail "xray restart 失败，最近日志如下"
            show_journal_recent
        fi
    else
        diag_info "默认不自动 restart；如需重启请执行: ike smoke xhttp --restart"
    fi
    port="$(jq -r --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag).port // empty' "$CONFIG_FILE")"
    if port_listening "$port"; then
        diag_ok "XHTTP 端口正在监听: ${port}"
    else
        diag_warn "XHTTP 端口未监听或 ss 不可用: ${port}"
    fi
    diag_info "FinalMask: $(jq -r ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled // false" "$STATE_FILE" 2>/dev/null)"
}

run_smoke_command() {
    local target="${1:-all}"
    local restart="false"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --restart)
                restart="true"
                ;;
            *)
                err "[失败] 未知 smoke 参数: $1"
                echo "用法: ike smoke reality|xhttp|all [--restart]"
                return 1
                ;;
        esac
        shift
    done

    case "$target" in
        reality) smoke_reality "$restart" ;;
        xhttp) smoke_xhttp "$restart" ;;
        all | "")
            smoke_reality "$restart"
            smoke_xhttp "$restart"
            doctor_proxy
            ;;
        *)
            err "[失败] 未知 smoke 目标: $target"
            echo "用法: ike smoke reality|xhttp|all [--restart]"
            return 1
            ;;
    esac
}

redact_config_json() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    jq '
      def redact:
        walk(if type == "object" then
          with_entries(
            if (.key | test("(?i)(privateKey|private_key|decryption|password|pass|token|secret)")) then
              .value = "***REDACTED***"
            else
              .
            end
          )
        else
          .
        end);
      redact
    ' "$CONFIG_FILE" 2>/dev/null
}

render_export_report() {
    local tags ports xray_version

    echo "Xray-OneClick 脱敏诊断报告"
    echo "----------------------------------------"
    echo "SCRIPT_VERSION: ${SCRIPT_VERSION}"
    if [[ -x "$BIN_PATH" ]]; then
        xray_version="$("$BIN_PATH" version 2>/dev/null | head -n 1 || true)"
        echo "xray version: ${xray_version:-读取失败}"
    else
        echo "xray version: 未安装"
    fi
    echo "systemctl status: $(xray_service_status)"
    echo "config test: $(xray_config_test_status)"
    echo "installed protocols: $(installed_protocols_summary)"
    if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
        tags="$(jq -r '[.inbounds[]?.tag] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        ports="$(jq -r '[.inbounds[]? | select(.port != null) | (.tag + ":" + (.port|tostring))] | join(", ")' "$CONFIG_FILE" 2>/dev/null)"
        echo "inbound tags: ${tags:-无}"
        echo "listen ports: ${ports:-无}"
    fi
    echo
    echo "Reality 摘要:"
    if inbound_exists "$REALITY_TAG"; then
        jq -r --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag) | "  port=\(.port) sni=\(.streamSettings.realitySettings.serverNames[0] // "") flow=\(.settings.clients[0].flow // "")"' "$CONFIG_FILE"
        jq -r ".${REALITY_STATE_KEY} // {} | \"  publicKey=\(.public_key // \"\") shortId=\(.default_short_id // \"\") link=\(.link // \"\")\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  未安装"
    fi
    echo
    echo "XHTTP-FinalMask 摘要:"
    if inbound_exists "$VLESS_XHTTP_FM_TAG"; then
        jq -r --arg tag "$VLESS_XHTTP_FM_TAG" '.inbounds[]? | select(.tag == $tag) | "  port=\(.port) path=\(.streamSettings.xhttpSettings.path // "") finalmask=\(.streamSettings | has("finalmask"))"' "$CONFIG_FILE"
        jq -r ".${VLESS_XHTTP_FM_STATE_KEY} // {} | \"  finalmask_enabled=\(.finalmask_enabled // false) link=\(.link // \"\")\"" "$STATE_FILE" 2>/dev/null
    else
        echo "  未安装"
    fi
    echo
    echo "最近日志摘要:"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null | redact_sensitive_stream || true
    else
        echo "  journalctl 不可用"
    fi
    echo
    echo "脱敏 config 摘要:"
    redact_config_json || true
}

render_export_clients() {
    echo "Xray-OneClick 客户端参数导出"
    echo "----------------------------------------"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "未找到 config.json"
        return 0
    fi
    init_state
    get_local_addresses
    host_candidates "dual"
    view_config dual quick || true
    if [[ -f "$STATE_FILE" ]] && jq -e ".${VLESS_XHTTP_FM_STATE_KEY}.finalmask_enabled == true" "$STATE_FILE" >/dev/null 2>&1; then
        echo
        echo "提示: 如客户端无法导入，请手动填写 path/encryption/finalmask。"
    fi
}

write_or_print_export() {
    local output_path="${1:-}"
    local content

    content="$(cat)"
    if [[ -n "$output_path" ]]; then
        printf '%s\n' "$content" >"$output_path" || {
            err "[导出] 写入失败: $output_path"
            return 1
        }
        chmod 600 "$output_path" 2>/dev/null || true
        ok "[导出] 已写入: $output_path"
    else
        printf '%s\n' "$content"
    fi
}

run_export_command() {
    local action="${1:-report}"
    local output=""

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)
                output="${2:-}"
                [[ -n "$output" ]] || {
                    err "[导出] --output 需要路径"
                    return 1
                }
                shift 2
                ;;
            *)
                err "[失败] 未知 export 参数: $1"
                echo "用法: ike export report|clients [--output PATH]"
                return 1
                ;;
        esac
    done

    case "$action" in
        report)
            render_export_report | write_or_print_export "$output"
            ;;
        clients)
            render_export_clients | write_or_print_export "$output"
            ;;
        *)
            err "[失败] 未知 export 目标: $action"
            echo "用法: ike export report|clients [--output PATH]"
            return 1
            ;;
    esac
}

run_preflight_command() {
    preflight_system
}

run_xray_command() {
    local action="${1:-version}"
    local version="latest"
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
                echo "用法: ike xray version | ike xray upgrade [--version vX.Y.Z] [--dry-run] [--restart]"
                return 1
                ;;
        esac
    done

    case "$action" in
        version | "")
            print_xray_version_summary
            ;;
        upgrade)
            upgrade_xray_core "$version" "$dry_run" "$restart"
            ;;
        *)
            err "[失败] 未知 xray 命令: $action"
            echo "用法: ike xray version | ike xray upgrade [--version vX.Y.Z] [--dry-run] [--restart]"
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
    local old_xhttp_finalmask_json

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

    if jq -e ".${REALITY_STATE_KEY}" "$STATE_FILE" >/dev/null 2>&1; then
        if [[ -z "$old_reality_flow" ]]; then
            if [[ -f "$CONFIG_FILE" ]]; then
                inferred_reality_flow="$(jq -r --arg tag "$REALITY_TAG" '.inbounds[]? | select(.tag == $tag).settings.clients[0].flow // empty' "$CONFIG_FILE" 2>/dev/null)"
            fi
            if [[ -n "$inferred_reality_flow" ]]; then
                diag_info "将从 config 补齐 vless_reality.flow"
                changed="true"
            else
                diag_warn "无法推导 vless_reality.flow；旧配置可能缺少 Vision flow，建议重新执行 ike reality install"
            fi
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
        --arg xhttp_key "$VLESS_XHTTP_FM_STATE_KEY" '
        if .[$reality_key]? then
          (if ((.[$reality_key].flow // "") == "" and $reality_flow != "") then .[$reality_key].flow = $reality_flow else . end) |
          (if ($reality_link != "") then .[$reality_key].link = (.[$reality_key].link // $reality_link) else . end)
        else . end |
        if .[$xhttp_key]? then
          (if ((.[$xhttp_key] | has("finalmask_enabled") | not) and $xhttp_enabled != "") then .[$xhttp_key].finalmask_enabled = ($xhttp_enabled == "true") else . end) |
          (if ((.[$xhttp_key].finalmask_json // null) == null and $xhttp_finalmask_json != null) then .[$xhttp_key].finalmask_json = $xhttp_finalmask_json else . end) |
          (if ($xhttp_link != "") then .[$xhttp_key].link = (.[$xhttp_key].link // $xhttp_link) else . end)
        else . end
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
    jq empty "$CONFIG_FILE" >/dev/null || return 1
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
  ike reality install [--port PORT] [--defender-port PORT] [--sni DOMAIN] [--dry-run] [--yes] [--empty-clients]
  ike reality show
  ike reality remove
  ike view reality
EOF
}

show_xhttp_usage() {
    cat <<'EOF'
用法:
  ike xhttp install [--port PORT] [--path /path] [--finalmask on|off] [--dry-run] [--auth x25519|mlkem768]
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
            XHTTP_FINALMASK_REQUEST="true"
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

run_forward_command() {
    run_tunnel_command "$@"
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
  ike doctor all
  ike doctor preflight
  ike doctor proxy
  ike doctor reality-key
  ike doctor reality
  ike doctor xhttp
  ike smoke reality
  ike smoke xhttp --restart
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
  ike xhttp install --port 30005 --path /api/test --finalmask on
  ike xhttp install --port 30005 --path /api/test --finalmask off
  ike xhttp install --port 30005 --path /api/test --finalmask on --dry-run
  ike xhttp show
  ike xhttp remove
  ike view reality
  ike view xhttp
  ike tunnel list
  ike tunnel add
  ike tunnel add safe
  ike tunnel add relay
  ike tunnel add map
  ike tunnel edit
  ike tunnel enable
  ike tunnel disable
  ike tunnel del
  ike tunnel test
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
  ike forward test
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
        "" | preflight | view | doctor | smoke | export | xray | migrate | uninstall | update | backup | endpoint | config | service | logs | cnblock | safety | tunnel | forward | reality | xhttp | bootstrap) ;;
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
        bootstrap)
            run_bootstrap_command
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
