#!/usr/bin/env bash
# Endpoint detection and link rendering helpers.

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