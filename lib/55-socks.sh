#!/usr/bin/env bash
# SOCKS5 proxy install.

state_set_socks5() {
    init_state
    local tmp

    tmp="$(mktemp)" || return 1
    jq --arg tag "$SOCKS_TAG" \
        --arg port "$S_PORT" \
        --arg listen "0.0.0.0" \
        --arg listen_scope "ipv4" '
        .socks5 = {
          "tag": $tag,
          "port": ($port|tonumber),
          "listen": $listen,
          "listen_scope": $listen_scope
        }
       ' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    rm -f "$tmp"
    ensure_config_security
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
    state_set_socks5 || err "[状态] SOCKS5 状态写入失败，但 config.json 已生效。"
    state_set_meta_action "安装 SOCKS5" || err "[状态] 最近变更记录失败。"
    ok "[完成] SOCKS5 已写入 Xray 配置。"
    view_config
}
