#!/bin/bash
# shellcheck disable=SC2015

set -o pipefail

IKE_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IKE_LIB_RAW_BASE="${IKE_LIB_RAW_BASE:-https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/lib}"
IKE_LIB_MODULES=(
    "00-bootstrap.sh"
    "01-constants.sh"
    "02-output.sh"
    "03-system.sh"
    "20-paths.sh"
    "40-network.sh"
    "41-safety.sh"
    "21-config-base.sh"
    "31-service.sh"
    "30-xray-core.sh"
    "50-vless-common.sh"
    "54-ss2022.sh"
    "50-vless-enc.sh"
    "51-reality.sh"
    "52-xhttp.sh"
    "53-advanced.sh"
    "55-socks.sh"
    "56-tunnel.sh"
    "70-view.sh"
    "71-cli-view.sh"
    "80-menu.sh"
    "63-diag.sh"
    "60-doctor.sh"
    "61-smoke.sh"
    "62-export.sh"
    "73-cli-migrate.sh"
    "72-cli-core.sh"
    "72-cli-admin.sh"
    "74-cli-protocols.sh"
    "90-test-harness.sh"
    "81-help.sh"
)

ike_ensure_lib_modules() {
    local root_dir="$1"
    local lib_dir="${root_dir}/lib"
    local module missing=()

    [[ -f "${lib_dir}/00-bootstrap.sh" && -f "${lib_dir}/21-config-base.sh" ]] && return 0

    mkdir -p "$lib_dir" || return 1
    for module in "${IKE_LIB_MODULES[@]}"; do
        [[ -f "${lib_dir}/${module}" ]] || missing+=("$module")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo "Xray-OneClick: 缺少 lib/ 模块且无法下载（需要 curl 或 wget）。" >&2
        echo "请从完整仓库安装，或将 lib/ 目录与 install.sh 放在同一目录。" >&2
        return 1
    fi

    for module in "${missing[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${IKE_LIB_RAW_BASE}/${module}" -o "${lib_dir}/${module}" || return 1
        else
            wget -qO "${lib_dir}/${module}" "${IKE_LIB_RAW_BASE}/${module}" || return 1
        fi
    done
}

if ! ike_ensure_lib_modules "$IKE_INSTALLER_DIR"; then
    if [[ "$IKE_INSTALLER_DIR" != "/usr/local/share/ike" ]] && ike_ensure_lib_modules "/usr/local/share/ike"; then
        IKE_INSTALLER_DIR="/usr/local/share/ike"
    else
        exit 1
    fi
fi

# shellcheck source=lib/00-bootstrap.sh disable=SC1091
source "${IKE_INSTALLER_DIR}/lib/00-bootstrap.sh"

install_shortcut() {
    local script_source
    script_source="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

    mkdir -p "$(dirname "$SHORTCUT_PATH")" "$INSTALLER_DIR"

    if [[ -f "$script_source" && -r "$script_source" ]]; then
        if [[ "$script_source" != "$INSTALLER_PATH" ]]; then
            cp "$script_source" "$INSTALLER_PATH"
        fi
        if [[ -d "$(dirname "$script_source")/lib" ]]; then
            mkdir -p "${INSTALLER_DIR}/lib"
            cp -a "$(dirname "$script_source")/lib/." "${INSTALLER_DIR}/lib/"
        fi
        chmod +x "$INSTALLER_PATH"
    elif [[ ! -f "$INSTALLER_PATH" ]]; then
        cat >"$INSTALLER_PATH" <<EOF
#!/bin/bash
SCRIPT_URL="${RAW_SCRIPT_URL}"
TMP_SCRIPT="\$(mktemp)"
trap 'rm -f "\$TMP_SCRIPT"' EXIT
curl -fsSL "\$SCRIPT_URL" -o "\$TMP_SCRIPT" || exit 1
bash "\$TMP_SCRIPT" "\$@"
EOF
        chmod +x "$INSTALLER_PATH"
    fi

    cat >"$SHORTCUT_PATH" <<EOF
#!/bin/bash
if [[ ! -f "$INSTALLER_PATH" ]]; then
    echo "未找到安装器脚本 $INSTALLER_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec bash "$INSTALLER_PATH" "\$@"
EOF
    chmod +x "$SHORTCUT_PATH"

    cat >"$LEGACY_SHORTCUT_PATH" <<EOF
#!/bin/bash
echo "提示：快捷命令已更名为 ike，sb 仅作为兼容入口，将转发到 ike。" >&2
if [[ ! -x "$SHORTCUT_PATH" ]]; then
    echo "未找到主快捷命令 $SHORTCUT_PATH，请重新上传 install.sh 并执行安装。" >&2
    exit 1
fi
exec "$SHORTCUT_PATH" "\$@"
EOF
    chmod +x "$LEGACY_SHORTCUT_PATH"
}

main() {
    case "${1:-}" in
        help | -h | --help)
            show_help
            return 0
            ;;
        version | --version)
            show_version
            return 0
            ;;
        "" | preflight | view | doctor | smoke | export | xray | migrate | uninstall | update | backup | endpoint | config | service | logs | cnblock | safety | tunnel | forward | reality | xhttp | xhttp-reality | enc-reality | fullstack | bootstrap | test-config-generate) ;;
        *)
            err "[失败] 未知命令: $1"
            echo "运行 ike help 查看可用命令。"
            return 1
            ;;
    esac

    if [[ "${1:-}" == "preflight" ]]; then
        shift
        run_preflight_command "$@"
        return $?
    fi

    if [[ "${1:-}" == "test-config-generate" ]]; then
        shift
        run_test_config_generate_command "$@"
        return $?
    fi

    ensure_root
    check_os
    detect_arch
    apply_env_endpoint_if_needed || return 1

    case "${1:-}" in
        "")
            show_menu
            ;;
        preflight)
            shift
            run_preflight_command "$@"
            ;;
        view)
            shift
            run_view_command "$@"
            ;;
        xray)
            shift
            run_xray_command "$@"
            ;;
        migrate)
            shift
            run_migrate_command "$@"
            ;;
        uninstall)
            shift
            run_uninstall_command "$@"
            ;;
        doctor)
            shift
            run_doctor_command "$@"
            ;;
        smoke)
            shift
            run_smoke_command "$@"
            ;;
        export)
            shift
            run_export_command "$@"
            ;;
        update)
            update_xray_core
            ;;
        backup)
            export_current_config_backup
            ;;
        endpoint)
            run_endpoint_command "${2:-show}"
            ;;
        config)
            run_config_command "${2:-path}"
            ;;
        service)
            shift
            run_service_command "$@"
            ;;
        logs)
            run_logs_command
            ;;
        cnblock)
            run_cnblock_command "${2:-}"
            ;;
        safety)
            run_safety_command "${2:-}" "${3:-}"
            ;;
        tunnel)
            shift
            run_tunnel_command "$@"
            ;;
        forward)
            shift
            run_forward_command "$@"
            ;;
        reality)
            shift
            run_reality_command "$@"
            ;;
        xhttp)
            shift
            run_xhttp_command "$@"
            ;;
        xhttp-reality)
            run_advanced_profile_command "xhttp-reality" "${2:-show}" "${@:3}"
            ;;
        enc-reality)
            run_advanced_profile_command "enc-reality" "${2:-show}" "${@:3}"
            ;;
        fullstack)
            run_advanced_profile_command "fullstack" "${2:-show}" "${@:3}"
            ;;
        bootstrap)
            run_bootstrap_command
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi





