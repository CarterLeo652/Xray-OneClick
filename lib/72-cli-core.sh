#!/usr/bin/env bash
# Preflight and xray CLI handlers restored from pre-P3 baseline.





run_preflight_command() {
    check_os
    detect_arch
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

            ;;
    esac
}

backup_before_migration() {
    local timestamp backup_dir

    timestamp="$(date +%Y%m%d%H%M%S)"
    backup_dir="${CONFIG_DIR}/migration-backup-${timestamp}"
    mkdir -p "$backup_dir"
    [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "$backup_dir/config.json"

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
    local enc_fm_scope="" enc_xhttp_scope=""
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
        if jq -e ".${VLESS_ENC_FM_STATE_KEY}? and ((.${VLESS_ENC_FM_STATE_KEY}.listen_scope // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
            enc_fm_scope="$(config_inbound_listen_scope "$VLESS_ENC_FM_TAG")"
            [[ "$enc_fm_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_enc_finalmask.listen_scope" || changed="true"
        fi
        if jq -e ".${VLESS_ENC_XHTTP_STATE_KEY}? and ((.${VLESS_ENC_XHTTP_STATE_KEY}.listen_scope // \"\") == \"\")" "$STATE_FILE" >/dev/null 2>&1; then
            enc_xhttp_scope="$(config_inbound_listen_scope "$VLESS_ENC_XHTTP_TAG")"
            [[ "$enc_xhttp_scope" == "unknown" ]] && diag_warn "无法从 config 推导 vless_enc_xhttp.listen_scope" || changed="true"
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
        --arg enc_fm_scope "$enc_fm_scope" \
        --arg enc_xhttp_scope "$enc_xhttp_scope" \
        --arg enc_fm_key "$VLESS_ENC_FM_STATE_KEY" \
        --arg enc_xhttp_key "$VLESS_ENC_XHTTP_STATE_KEY" \
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
        fill_scope($enc_fm_key; $enc_fm_scope) |
        fill_scope($enc_xhttp_key; $enc_xhttp_scope) |
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