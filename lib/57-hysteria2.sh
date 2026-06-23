#!/usr/bin/env bash
# Hysteria2 protocol install (QUIC/TLS, self-signed cert, optional Salamander obfs).

hysteria2_cert_path() { printf '%s' "${CONFIG_DIR}/hysteria2-cert.pem"; }
hysteria2_key_path() { printf '%s' "${CONFIG_DIR}/hysteria2-key.pem"; }

generate_hysteria2_cert() {
    local cert key
    cert="$(hysteria2_cert_path)"
    key="$(hysteria2_key_path)"

    command -v openssl >/dev/null 2>&1 || {
        err "[Hysteria2] 需要 openssl 生成自签证书。"
        return 1
    }
    mkdir -p "$CONFIG_DIR" || return 1
    if ! openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null; then
        err "[Hysteria2] 生成私钥失败。"
        return 1
    fi
    if ! openssl req -new -x509 -days 3650 -key "$key" -out "$cert" -subj "/CN=${HY2_SNI:-bing.com}" 2>/dev/null; then
        err "[Hysteria2] 生成自签证书失败。"
        return 1
    fi
    chmod 600 "$key" 2>/dev/null || true
    chmod 644 "$cert" 2>/dev/null || true
}

configure_hysteria2() {
    local mode="${1:-interactive}"
    local input

    HY2_LISTEN="0.0.0.0"

    if [[ "$mode" == "interactive" ]]; then
        while true; do
            read -r -p "Hysteria2 UDP 端口 (回车默认 443): " input
            input="${input:-443}"
            if validate_port "$input" && ! port_used_in_config "$input" && check_port "$input"; then
                HY2_PORT="$input"
                break
            fi
            err "[Hysteria2] 端口无效、被占用或已存在于 config.json。"
        done
        read -r -p "Hysteria2 伪装 SNI 域名 (回车随机): " input
        if [[ -n "$input" ]]; then
            HY2_SNI="$input"
        else
            HY2_SNI="${REALITY_SNI_CANDIDATES[$((RANDOM % ${#REALITY_SNI_CANDIDATES[@]}))]}"
        fi
    else
        if [[ -n "${HY2_PORT_REQUEST:-}" ]]; then
            validate_port "$HY2_PORT_REQUEST" || {
                err "[Hysteria2] 端口无效: $HY2_PORT_REQUEST"
                return 1
            }
            if port_used_in_config "$HY2_PORT_REQUEST" || ! check_port "$HY2_PORT_REQUEST"; then
                err "[Hysteria2] 端口已被占用或已存在于 config.json: $HY2_PORT_REQUEST"
                return 1
            fi
            HY2_PORT="$HY2_PORT_REQUEST"
        else
            HY2_PORT="443"
        fi
        HY2_SNI="${HY2_SNI_REQUEST:-${REALITY_SNI_CANDIDATES[0]}}"
    fi

    HY2_AUTH="$(openssl rand -hex 16 2>/dev/null)"
    [[ -n "$HY2_AUTH" ]] || HY2_AUTH="$(generate_uuid | tr -d '-')"
    HY2_OBFS="$(openssl rand -hex 16 2>/dev/null)"
    [[ -n "$HY2_OBFS" ]] || HY2_OBFS="$(generate_uuid | tr -d '-')"

    if [[ "${HY2_DRY_RUN:-false}" != "true" ]]; then
        generate_hysteria2_cert || return 1
    fi
}

build_hysteria2_share_link() {
    local port="${HY2_PORT:-}" auth="${HY2_AUTH:-}" sni="${HY2_SNI:-}" obfs="${HY2_OBFS:-}"
    local host link_port endpoint_pair auth_uri obfs_uri sni_uri name_uri

    if [[ -z "$port" && -f "$STATE_FILE" ]]; then
        port="$(jq -r ".${HY2_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
        auth="$(jq -r ".${HY2_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
        sni="$(jq -r ".${HY2_STATE_KEY}.sni // empty" "$STATE_FILE" 2>/dev/null)"
        obfs="$(jq -r ".${HY2_STATE_KEY}.obfs // empty" "$STATE_FILE" 2>/dev/null)"
    fi

    [[ -n "$port" && -n "$auth" ]] || return 1
    endpoint_pair="$(link_endpoint_for_tag "$port" "$HY2_TAG" "$HY2_STATE_KEY")"
    IFS=$'\t' read -r host link_port <<<"$endpoint_pair"
    auth_uri="$(url_encode "$auth")"
    obfs_uri="$(url_encode "$obfs")"
    sni_uri="$(url_encode "$sni")"
    name_uri="$(url_encode "Xray-Hysteria2")"

    printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=1' "$auth_uri" "$host" "$link_port" "$sni_uri"
    [[ -n "$obfs" ]] && printf '&obfs=salamander&obfs-password=%s' "$obfs_uri"
    printf '#%s' "$name_uri"
}

state_set_hysteria2() {
    init_state
    local tmp link timestamp
    link="$(build_hysteria2_share_link || true)"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$(mktemp)"
    jq --arg key "$HY2_STATE_KEY" \
        --arg tag "$HY2_TAG" \
        --arg auth "$HY2_AUTH" \
        --arg sni "$HY2_SNI" \
        --arg obfs "$HY2_OBFS" \
        --arg port "$HY2_PORT" \
        --arg link "$link" \
        --arg updated "$timestamp" \
        --arg listen_scope "$(protocol_listen_scope "${HY2_LISTEN:-}")" '
        .[$key] = {
          "tag": $tag,
          "auth": $auth,
          "sni": $sni,
          "obfs": $obfs,
          "port": ($port|tonumber),
          "link": $link,
          "listen_scope": $listen_scope,
          "updated_at": $updated
        }
       ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
}

install_hysteria2() {
    local tmp config_source base_tmp cert key
    cert="$(hysteria2_cert_path)"
    key="$(hysteria2_key_path)"

    config_source="$CONFIG_FILE"
    if [[ "${HY2_DRY_RUN:-false}" == "true" && ! -f "$config_source" ]]; then
        base_tmp="$(mktemp)" || return 1
        printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}\n' >"$base_tmp"
        config_source="$base_tmp"
    fi
    if [[ "${HY2_DRY_RUN:-false}" != "true" ]]; then
        backup_config || {
            err "[Hysteria2] 配置备份失败。"
            return 1
        }
    fi

    tmp="$(mktemp)" || return 1
    if ! jq --arg tag "$HY2_TAG" \
        --arg listen "${HY2_LISTEN:-0.0.0.0}" \
        --arg port "$HY2_PORT" \
        --arg auth "$HY2_AUTH" \
        --arg cert "$cert" \
        --arg key "$key" \
        --arg obfs "$HY2_OBFS" '
        .inbounds = ((.inbounds // []) | map(select(.tag != $tag))) |
        .inbounds += [{
          "tag": $tag,
          "listen": $listen,
          "port": ($port|tonumber),
          "protocol": "hysteria",
          "settings": {
            "version": 2,
            "clients": [ { "auth": $auth, "email": "hysteria2@xray" } ]
          },
          "streamSettings": {
            "network": "hysteria",
            "security": "tls",
            "tlsSettings": {
              "alpn": ["h3"],
              "certificates": [ { "certificateFile": $cert, "keyFile": $key } ]
            },
            "hysteriaSettings": { "version": 2 },
            "finalmask": {
              "udp": [ { "type": "salamander", "settings": { "password": $obfs } } ]
            }
          }
        }]
       ' "$config_source" >"$tmp"; then
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        err "[Hysteria2] jq 生成配置失败。"
        return 1
    fi

    if [[ "${HY2_DRY_RUN:-false}" == "true" ]]; then
        write_test_config_out "$tmp" || {
            rm -f "$tmp"
            [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
            return 1
        }
        rm -f "$tmp"
        [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"
        return 0
    fi
    [[ -n "${base_tmp:-}" ]] && rm -f "$base_tmp"

    mv "$tmp" "$CONFIG_FILE" || {
        rm -f "$tmp"
        err "[Hysteria2] 写入 $CONFIG_FILE 失败。"
        return 1
    }

    if ! apply_config "Hysteria2"; then
        err "[Hysteria2] 配置未通过 Xray 校验；请确认 Xray-core 版本支持 Hysteria2(v26+)。"
        return 1
    fi
    state_set_hysteria2 || err "[状态] Hysteria2 状态写入失败，但 config.json 已生效。"
    state_set_meta_action "安装 Hysteria2" || err "[状态] 最近变更记录失败。"
    ok "[完成] Hysteria2 已写入 Xray 配置。"
    print_hysteria2_result
}

print_hysteria2_result() {
    local missing_mode="${1:-skip}"
    local state_exists link port auth sni obfs

    if [[ ! -f "$STATE_FILE" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Hysteria2] 未安装。"
        return 0
    fi
    state_exists="$(jq -r ".${HY2_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
    if [[ -z "$state_exists" ]]; then
        [[ "$missing_mode" == "show" ]] && echo "[Hysteria2] 未安装。"
        return 0
    fi

    port="$(jq -r ".${HY2_STATE_KEY}.port // empty" "$STATE_FILE" 2>/dev/null)"
    auth="$(jq -r ".${HY2_STATE_KEY}.auth // empty" "$STATE_FILE" 2>/dev/null)"
    sni="$(jq -r ".${HY2_STATE_KEY}.sni // empty" "$STATE_FILE" 2>/dev/null)"
    obfs="$(jq -r ".${HY2_STATE_KEY}.obfs // empty" "$STATE_FILE" 2>/dev/null)"
    link="$(build_hysteria2_share_link 2>/dev/null || jq -r ".${HY2_STATE_KEY}.link // empty" "$STATE_FILE" 2>/dev/null)"

    echo -e "\n${YELLOW}--- Hysteria2 ---${PLAIN}"
    echo -e "端口(UDP): ${port}"
    echo -e "认证密码: ${auth}"
    echo -e "伪装 SNI(自签证书): ${sni}"
    echo -e "Obfs(salamander) 密码: ${obfs}"
    echo -e "提示: 使用自签证书，客户端需开启 insecure / 允许不安全连接。"
    [[ -n "$link" ]] && echo -e "链接: ${link}"
}

remove_hysteria2_config() {
    remove_simple_inbound_config "$HY2_TAG" "$HY2_STATE_KEY" "Hysteria2"
    rm -f "$(hysteria2_cert_path)" "$(hysteria2_key_path)" 2>/dev/null || true
}
