#!/usr/bin/env bash
# VLESS Encryption protocol install.

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
        --arg port "$VLESS_PORT" \
        --arg listen_scope "$(protocol_listen_scope "${VLESS_LISTEN:-}")" '
        .vless_encryption = {
          "tag": $tag,
          "uuid": $uuid,
          "encryption": $encryption,
          "auth": $auth,
          "mode": $mode,
          "enc_method": $enc_method,
          "client_rtt": $client_rtt,
          "server_ticket": $server_ticket,
          "port": ($port|tonumber),
          "listen_scope": $listen_scope
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
