#!/usr/bin/env bash
# View config links, reset secrets, uninstall helpers.

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
