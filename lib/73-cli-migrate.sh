#!/usr/bin/env bash
# Migrate and uninstall CLI handlers.

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

