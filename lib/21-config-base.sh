#!/usr/bin/env bash
# Xray-OneClick config.json lifecycle: init, backup, validate, apply.

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
