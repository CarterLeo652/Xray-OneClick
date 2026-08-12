#!/usr/bin/env bash
# Xray-OneClick safety blocks and China direct routing.

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

    tmp="$(config_temp_file)" || {
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

    tmp="$(config_temp_file)" || {
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

china_direct_block_rule_mode() {
    local has_ip="false"
    local has_domain="false"

    [[ -f "$CONFIG_FILE" ]] || {
        printf '%s' "off"
        return 0
    }
    command -v jq >/dev/null 2>&1 || {
        printf '%s' "off"
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
        printf '%s' "enhanced"
    elif [[ "$has_ip" == "true" ]]; then
        printf '%s' "basic"
    else
        printf '%s' "off"
    fi
}

china_direct_block_enabled() {
    [[ "$(china_direct_block_rule_mode)" != "off" ]]
}

china_direct_block_status() {
    local user_set="false"
    local mode

    [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1 && {
        user_set="$(jq -r '.cnblock_user_set // false' "$STATE_FILE" 2>/dev/null)"
    }
    mode="$(china_direct_block_rule_mode)"

    if [[ "$mode" != "off" ]]; then
        if [[ "$user_set" == "true" ]]; then
            printf '%s' "已启用（用户开启）"
        else
            printf '%s' "检测到旧规则，建议确认"
        fi
    elif [[ "$user_set" == "true" ]]; then
        printf '%s' "未启用（用户关闭）"
    else
        printf '%s' "未启用"
    fi
}

cnblock_reality_risk_notice() {
    local status warning

    status="$(china_direct_block_status)"
    case "$status" in
        "已启用（用户开启）")
            warning="中国大陆直连屏蔽已启用，如 SNI target 被影响，Reality 可能连接异常。"
            ;;
        "检测到旧规则，建议确认")
            warning="检测到旧版中国大陆直连屏蔽规则，可能来自旧默认策略。1.1.6 起默认关闭；如不需要请执行 ike cnblock off。"
            ;;
        *)
            return 0
            ;;
    esac

    [[ "${CNBLOCK_RISK_NOTICE_SHOWN:-false}" == "true" ]] && return 0
    CNBLOCK_RISK_NOTICE_SHOWN="true"
    diag_warn "$warning"
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

    tmp="$(config_temp_file)" || {
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

    if [[ "$mode" == "off" ]]; then
        if ! state_set_cnblock "false" "true"; then
            rollback_config_after_state_failure "中国大陆直连屏蔽"
            return 1
        fi
    else
        if ! state_set_cnblock "true" "true"; then
            rollback_config_after_state_failure "中国大陆直连屏蔽"
            return 1
        fi
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
