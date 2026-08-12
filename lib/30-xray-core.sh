#!/usr/bin/env bash
# Xray-OneClick Xray-core download, install, and upgrade.

replace_xray_binary() {
    local new_binary="$1"
    local backup_path=""
    local staging_path had_original="false"

    validate_xray_binary_path "$BIN_PATH" || return 1
    XRAY_REPLACED_BACKUP_PATH=""
    XRAY_REPLACED_HAD_ORIGINAL="false"
    staging_path="$(mktemp "${BIN_PATH}.new.XXXXXX")" || return 1

    if ! install -m 755 "$new_binary" "$staging_path"; then
        rm -f "$staging_path"
        err "[核心] 写入临时二进制失败: $staging_path"
        return 1
    fi

    if [[ -e "$BIN_PATH" ]]; then
        backup_path="$(mktemp "${BIN_PATH}.bak.$(date +%Y%m%d%H%M%S).XXXXXX")" || {
            rm -f "$staging_path"
            return 1
        }
        rm -f "$backup_path"
        if ! mv "$BIN_PATH" "$backup_path"; then
            rm -f "$staging_path"
            err "[核心] 备份旧 Xray 二进制失败，已中止更新。"
            return 1
        fi
        had_original="true"
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
        rm -f "$BIN_PATH"
        if [[ "$had_original" == "true" && -e "$backup_path" ]]; then
            mv "$backup_path" "$BIN_PATH" >/dev/null 2>&1 || true
        fi
        return 1
    }
    XRAY_REPLACED_BACKUP_PATH="$backup_path"
    XRAY_REPLACED_HAD_ORIGINAL="$had_original"
}

rollback_xray_binary_replacement() {
    local backup_path="${1:-}"
    local had_original="${2:-false}"

    if ! rm -f -- "$BIN_PATH"; then
        err "[核心] 回滚时无法移除新 Xray 二进制: $BIN_PATH"
        return 1
    fi
    if [[ "$had_original" == "true" ]]; then
        if [[ -z "$backup_path" || ! -e "$backup_path" ]]; then
            err "[核心] 回滚所需的旧 Xray 二进制不存在。"
            return 1
        fi
        if ! mv "$backup_path" "$BIN_PATH"; then
            err "[核心] 恢复旧 Xray 二进制失败: $BIN_PATH"
            return 1
        fi
        chmod +x "$BIN_PATH" || return 1
    fi
    XRAY_REPLACED_BACKUP_PATH=""
    XRAY_REPLACED_HAD_ORIGINAL="false"
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
    diag_info "XHTTP/FinalMask 属于高级兼容能力，建议保持 Xray-core 为最新版本。"
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

normalize_xray_channel() {
    case "${1:-stable}" in
        stable | "") printf '%s' "stable" ;;
        prerelease | pre-release | pre) printf '%s' "prerelease" ;;
        *) return 1 ;;
    esac
}

xray_release_api_for_channel() {
    case "${1:-stable}" in
        stable) printf '%s' "$XRAY_RELEASE_API_STABLE" ;;
        prerelease) printf '%s' "$XRAY_RELEASE_API_PRERELEASE" ;;
        *) return 1 ;;
    esac
}

xray_release_metadata_url() {
    local version="${1:-latest}"
    local channel="${2:-stable}"

    channel="$(normalize_xray_channel "$channel")" || return 1
    if [[ "$version" == "latest" ]]; then
        xray_release_api_for_channel "$channel"
    else
        printf '%s/%s' "$XRAY_RELEASE_API_TAG_BASE" "$version"
    fi
}

xray_release_metadata() {
    local version="${1:-latest}"
    local channel="${2:-stable}"
    local api tmp release_json

    api="$(xray_release_metadata_url "$version" "$channel")" || return 1
    tmp="$(mktemp)" || return 1
    if ! download_one_url "$api" "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        if [[ "$version" == "latest" ]]; then
            err "[核心] 无法访问 Xray ${channel} release API；可使用 --xray-version 指定版本。"
        else
            err "[核心] 无法访问 Xray release ${version}；可使用 --xray-version 指定版本。"
        fi
        return 1
    fi

    if [[ "$version" == "latest" && "$channel" == "prerelease" ]]; then
        release_json="$(jq -c --arg asset "$XRAY_ASSET" 'map(select(.prerelease == true and any(.assets[]?; .name == $asset))) | .[0] // empty' "$tmp")"
        [[ -n "$release_json" && "$release_json" != "null" ]] || {
            rm -f "$tmp"
            err "[核心] prerelease 通道中未找到匹配 ${XRAY_ASSET} 的 release。"
            return 1
        }
        printf '%s' "$release_json"
    else
        cat "$tmp"
    fi
    rm -f "$tmp"
}

xray_release_asset_url() {
    local version="${1:-latest}"
    local channel="${2:-stable}"
    local release_json release_url

    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    release_json="$(xray_release_metadata "$version" "$channel")" || return 1
    release_url="$(echo "$release_json" | jq -r --arg asset "$XRAY_ASSET" '.assets[]? | select(.name == $asset) | .browser_download_url' | head -n 1)"
    [[ -n "$release_url" && "$release_url" != "null" ]] || return 1
    printf '%s' "$release_url"
}

xray_release_asset_info() {
    local version="${1:-latest}"
    local channel="${2:-stable}"
    local release_json asset_info

    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    release_json="$(xray_release_metadata "$version" "$channel")" || return 1
    asset_info="$(printf '%s' "$release_json" | jq -r --arg asset "$XRAY_ASSET" --arg fallback "$version" --arg empty "" '
      . as $release |
      first($release.assets[]? | select(.name == $asset)) as $matched |
      [
        $matched.browser_download_url,
        ($release.tag_name // $fallback),
        (($release.prerelease // false) | tostring),
        ($matched.digest // $empty)
      ] | @tsv
    ' 2>/dev/null)" || return 1
    [[ -n "$asset_info" ]] || return 1
    printf '%s' "$asset_info"
}

verify_xray_asset_digest() {
    local archive="$1"
    local digest="${2:-}"
    local algorithm expected actual

    if [[ -z "$digest" || "$digest" == "null" ]]; then
        info "[核心] release API 未提供资产摘要，跳过 SHA-256 校验。"
        return 0
    fi

    algorithm="${digest%%:*}"
    expected="${digest#*:}"
    algorithm="${algorithm,,}"
    expected="${expected,,}"
    if [[ "$algorithm" != "sha256" || ! "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
        err "[核心] release API 返回了不支持的资产摘要: $digest"
        return 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$archive" | awk '{print tolower($1)}')"
    elif command -v openssl >/dev/null 2>&1; then
        actual="$(openssl dgst -sha256 "$archive" 2>/dev/null | awk '{print tolower($NF)}')"
    else
        err "[核心] 缺少 sha256sum/openssl，无法校验 Xray 资产摘要。"
        return 1
    fi

    if [[ "$actual" != "$expected" ]]; then
        err "[核心] Xray 资产 SHA-256 校验失败。"
        err "[核心] expected=$expected"
        err "[核心] actual=${actual:-无法计算}"
        return 1
    fi
    info "[核心] Xray 资产 SHA-256 校验通过。"
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
    local channel="${2:-stable}"
    local tmpdir="${3:-}"
    local asset_info url zip_path resolved_version prerelease digest

    if [[ -z "$tmpdir" ]]; then
        tmpdir="$(mktemp -d)" || return 1
    fi
    mkdir -p "$tmpdir" || return 1
    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    XRAY_DOWNLOAD_CHANNEL="$channel"
    XRAY_DOWNLOAD_IS_PRERELEASE="false"
    XRAY_DOWNLOAD_VERSION="$version"
    XRAY_DOWNLOAD_DIGEST=""
    asset_info="$(xray_release_asset_info "$version" "$channel")" || {
        err "[核心] 无法解析 Xray 下载地址。"
        return 1
    }
    IFS=$'\t' read -r url resolved_version prerelease digest <<<"$asset_info"
    [[ -n "$url" ]] || {
        err "[核心] release 中未找到资产: $XRAY_ASSET"
        return 1
    }
    XRAY_DOWNLOAD_VERSION="${resolved_version:-$version}"
    XRAY_DOWNLOAD_IS_PRERELEASE="${prerelease:-false}"
    XRAY_DOWNLOAD_DIGEST="${digest:-}"
    zip_path="${tmpdir}/${XRAY_ASSET}"
    download_with_mirrors "$url" "$zip_path" || return 1
    verify_xray_asset_digest "$zip_path" "$XRAY_DOWNLOAD_DIGEST" || return 1
    verify_xray_archive "$zip_path" "$tmpdir" || return 1
}

install_xray_binary() {
    local xray_bin="$1"

    mkdir -p "$(dirname "$BIN_PATH")" "$ASSET_DIR" || return 1
    replace_xray_binary "$xray_bin"
}

upgrade_xray_core() {
    local version="${1:-latest}"
    local channel="${2:-stable}"
    local dry_run="${3:-false}"
    local restart="${4:-false}"
    local tmpdir backup_path="" had_original="false"

    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    detect_arch
    tmpdir="$(mktemp -d)" || return 1
    download_xray_core "$version" "$channel" "$tmpdir" || {
        rm -rf "$tmpdir"
        return 1
    }
    if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] Xray 通道: ${XRAY_DOWNLOAD_CHANNEL:-$channel}"
        echo "[dry-run] 解析版本: ${XRAY_DOWNLOAD_VERSION:-$version}"
        echo "[dry-run] prerelease: ${XRAY_DOWNLOAD_IS_PRERELEASE:-false}"
        echo "[dry-run] 将安装 Xray: $("$XRAY_EXTRACTED_BINARY" version 2>/dev/null | head -n 1)"
        echo "[dry-run] 不修改当前二进制: $BIN_PATH"
        rm -rf "$tmpdir"
        return 0
    fi

    install_xray_binary "$XRAY_EXTRACTED_BINARY" || {
        rm -rf "$tmpdir"
        return 1
    }
    backup_path="${XRAY_REPLACED_BACKUP_PATH:-}"
    had_original="${XRAY_REPLACED_HAD_ORIGINAL:-false}"
    if [[ -f "$CONFIG_FILE" ]] && ! validate_config_file; then
        err "[核心] 升级后配置校验失败，正在回滚 xray binary。"
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        rm -rf "$tmpdir"
        return 1
    fi
    info "[核心] Xray 已升级: $(detect_xray_version 2>/dev/null || printf '%s' '版本未知')"
    info "[核心] 通道: ${XRAY_DOWNLOAD_CHANNEL:-$channel} / 版本: ${XRAY_DOWNLOAD_VERSION:-$version} / prerelease: ${XRAY_DOWNLOAD_IS_PRERELEASE:-false}"
    if [[ "$restart" == "true" ]] && ! restart_xray_service; then
        err "[核心] 新版本重启失败，正在恢复旧 Xray 二进制。"
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        [[ "$had_original" == "true" ]] && restart_xray_service >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
}

apply_config() {
    local context="${1:-}"

    if ! ensure_default_safety_blocks || ! ensure_config_security; then
        err "[回滚] 配置预处理失败，正在恢复最近备份。"
        restore_latest_config_backup >/dev/null 2>&1 || true
        return 1
    fi
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
    local version="${XRAY_VERSION_REQUEST:-${XRAY_VERSION:-latest}}"
    local channel="${XRAY_CHANNEL_REQUEST:-${XRAY_CHANNEL:-stable}}"
    local tmpdir replacing_existing service_was_active="false" backup_path="" had_original="false"

    channel="$(normalize_xray_channel "$channel")" || {
        err "[核心] 未知 Xray 通道: ${channel}"
        return 1
    }
    install_dependencies || return 1
    init_config || return 1
    init_state || return 1

    if [[ -x "$BIN_PATH" && "$force" != "true" ]]; then
        info "[核心] Xray 已安装: $(detect_xray_version 2>/dev/null || printf '%s' '版本未知')"
        create_service || return 1
        return 0
    fi

    tmpdir="$(mktemp -d)" || {
        err "[核心] 创建下载临时目录失败。"
        return 1
    }
    info "[核心] 下载 Xray ${version} (${channel} 通道, ${XRAY_ASSET})..."
    if ! download_xray_core "$version" "$channel" "$tmpdir"; then
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
        xray_service_is_active && service_was_active="true"
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
        [[ "$service_was_active" == "true" ]] && restart_service >/dev/null 2>&1 || true
        return 1
    fi
    backup_path="${XRAY_REPLACED_BACKUP_PATH:-}"
    had_original="${XRAY_REPLACED_HAD_ORIGINAL:-false}"

    if [[ -f "${tmpdir}/geoip.dat" ]] && ! cp "${tmpdir}/geoip.dat" "$ASSET_DIR/"; then
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        [[ "$service_was_active" == "true" ]] && restart_service >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        err "[核心] 更新 geoip.dat 失败。"
        return 1
    fi
    if [[ -f "${tmpdir}/geosite.dat" ]] && ! cp "${tmpdir}/geosite.dat" "$ASSET_DIR/"; then
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        [[ "$service_was_active" == "true" ]] && restart_service >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        err "[核心] 更新 geosite.dat 失败。"
        return 1
    fi

    if ! ensure_default_safety_blocks; then
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        [[ "$service_was_active" == "true" ]] && restart_service >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        return 1
    fi

    if ! create_service; then
        err "[服务] 创建或刷新服务文件失败。"
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        [[ "$service_was_active" == "true" ]] && restart_service >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        return 1
    fi

    if [[ "$replacing_existing" == "true" && -f "$CONFIG_FILE" ]] && ! validate_config_file; then
        err "[核心] 新 Xray 无法加载当前配置，正在恢复旧版本。"
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        [[ "$service_was_active" == "true" ]] && restart_service >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        return 1
    fi
    if [[ "$service_was_active" == "true" ]] && ! restart_service; then
        err "[核心] 新 Xray 重启失败，正在恢复旧版本。"
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        restart_service >/dev/null 2>&1 || true
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"

    ok "[核心] Xray ${XRAY_DOWNLOAD_VERSION:-$version} 安装/更新完成。"
    info "[核心] 通道: ${XRAY_DOWNLOAD_CHANNEL:-$channel} / prerelease: ${XRAY_DOWNLOAD_IS_PRERELEASE:-false}"
}

update_xray_core() {
    local backup_path had_original

    prepare_system || return 1
    install_or_update_xray true || return 1
    backup_path="${XRAY_REPLACED_BACKUP_PATH:-}"
    had_original="${XRAY_REPLACED_HAD_ORIGINAL:-false}"
    if ! validate_config_file || ! restart_service; then
        err "[核心] 更新后的校验或重启失败，正在恢复旧 Xray 二进制。"
        rollback_xray_binary_replacement "$backup_path" "$had_original" || true
        [[ "$had_original" == "true" ]] && restart_service >/dev/null 2>&1 || true
        return 1
    fi
    ok "[核心] Xray 已更新并重启。"
}
