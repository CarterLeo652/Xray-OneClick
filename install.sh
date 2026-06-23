#!/bin/bash
# shellcheck disable=SC2015

set -o pipefail

IKE_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IKE_LIB_RAW_BASE="${IKE_LIB_RAW_BASE:-https://raw.githubusercontent.com/ike-sh/Xray-OneClick/main/lib}"
IKE_LIB_MODULES=(
    "00-bootstrap.sh"
    "01-constants.sh"
    "02-output.sh"
    "03-installer.sh"
    "03-system.sh"
    "20-paths.sh"
    "40-network.sh"
    "41-safety.sh"
    "21-config-base.sh"
    "22-state.sh"
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
    "57-hysteria2.sh"
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
        "" | preflight | view | doctor | smoke | export | xray | migrate | uninstall | update | backup | endpoint | config | service | logs | cnblock | safety | tunnel | forward | reality | xhttp | enc-finalmask | enc-xhttp | hysteria2 | xhttp-reality | enc-reality | fullstack | bootstrap | test-config-generate) ;;
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

    # 通过管道启动（curl ... | sudo bash）时本进程 stdin 已被占用/为 EOF，
    # 交互式 read 会立即失败导致菜单空转退出；若存在终端则把 stdin 接回 /dev/tty
    if [[ ! -t 0 && -r /dev/tty ]]; then
        exec </dev/tty
    fi

    ensure_root
    check_os
    detect_arch
    apply_env_endpoint_if_needed || return 1

    case "${1:-}" in
        "")
            show_menu
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
        enc-finalmask)
            shift
            run_enc_finalmask_command "$@"
            ;;
        enc-xhttp)
            shift
            run_enc_xhttp_command "$@"
            ;;
        hysteria2)
            shift
            run_hysteria2_command "$@"
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





