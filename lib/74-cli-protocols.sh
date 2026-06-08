#!/usr/bin/env bash
# Protocol install CLI: reality, xhttp, advanced.

show_reality_usage() {
    cat <<'EOF'
用法:
  ike reality install [--port PORT] [--defender-port PORT] [--sni DOMAIN] [--flow vision|none] [--dry-run] [--yes] [--empty-clients]
  ike reality show
  ike reality remove
  ike view reality
EOF
}

show_xray_usage() {
    cat <<'EOF'
用法:
  ike xray version
  ike xray upgrade [--version vX.Y.Z] [--xray-channel stable|prerelease] [--dry-run] [--restart]

环境变量:
  XRAY_VERSION=vX.Y.Z
  XRAY_CHANNEL=stable|prerelease
EOF
}

show_xhttp_usage() {
    cat <<'EOF'
用法:
  ike xhttp install [--port PORT] [--path /path] [--finalmask on|off] [--finalmask-preset conservative|balanced|aggressive] [--fm-length 100-200] [--fm-delay 10-20] [--fm-max-split 3-6] [--finalmask-json JSON] [--dry-run] [--auth x25519|mlkem768]
  ike xhttp show
  ike xhttp remove
  ike view xhttp
EOF
}

run_reality_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_reality_usage
            ;;
        install)
            shift
            REALITY_PORT_REQUEST=""
            REALITY_DEFENDER_PORT_REQUEST=""
            REALITY_SNI_REQUEST=""
            REALITY_EMPTY_CLIENTS="false"
            REALITY_ASSUME_YES="false"
            REALITY_FLOW="$REALITY_FLOW_DEFAULT"
            REALITY_DRY_RUN="false"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        REALITY_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --defender-port)
                        REALITY_DEFENDER_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --sni)
                        REALITY_SNI_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --flow)
                        if [[ -z "${2:-}" ]] || ! REALITY_FLOW="$(normalize_reality_flow "$2")"; then
                            err "[Reality] --flow 仅支持 none 或 vision。"
                            return 1
                        fi
                        shift 2
                        ;;
                    --empty-clients)
                        REALITY_EMPTY_CLIENTS="true"
                        shift
                        ;;
                    --yes | -y)
                        REALITY_ASSUME_YES="true"
                        shift
                        ;;
                    --dry-run)
                        REALITY_DRY_RUN="true"
                        REALITY_SKIP_TLS_TEST="${REALITY_SKIP_TLS_TEST:-1}"
                        shift
                        ;;
                    help | -h | --help)
                        show_reality_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 reality install 参数: $1"
                        show_reality_usage
                        return 1
                        ;;
                esac
            done
            if [[ "$REALITY_DRY_RUN" == "true" ]]; then
                configure_reality "dry-run" && install_reality
            else
                prepare_system || return 1
                configure_reality "cli" && install_reality
            fi
            ;;
        show | "")
            init_state
            print_reality_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_reality_config
            ;;
        *)
            err "[失败] 未知 reality 参数: $action"
            show_reality_usage
            return 1
            ;;
    esac
}

run_xhttp_command() {
    local action="${1:-show}"

    case "$action" in
        help | -h | --help)
            show_xhttp_usage
            ;;
        install)
            shift
            XHTTP_PORT_REQUEST=""
            XHTTP_PATH_REQUEST=""
            XHTTP_FINALMASK_REQUEST="false"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            XHTTP_DRY_RUN="false"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        XHTTP_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --path)
                        XHTTP_PATH_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --finalmask)
                        XHTTP_FINALMASK_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --finalmask-preset | --fm-packets | --fm-length | --fm-delay | --fm-max-split | --finalmask-json)
                        if ! parse_finalmask_args "$1" "${2:-}"; then
                            return 1
                        fi
                        shift "$FINALMASK_ARG_SHIFT"
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        shift 2
                        ;;
                    --enc-method)
                        VLESS_ENC_METHOD="${2:-}"
                        VLESS_MODE="advanced"
                        shift 2
                        ;;
                    --rtt)
                        VLESS_CLIENT_RTT="${2:-}"
                        VLESS_MODE="advanced"
                        shift 2
                        ;;
                    --ticket)
                        VLESS_SERVER_TICKET="${2:-}"
                        VLESS_MODE="advanced"
                        shift 2
                        ;;
                    --dry-run)
                        XHTTP_DRY_RUN="true"
                        shift
                        ;;
                    help | -h | --help)
                        show_xhttp_usage
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 xhttp install 参数: $1"
                        show_xhttp_usage
                        return 1
                        ;;
                esac
            done
            case "$VLESS_AUTH" in
                x25519 | mlkem768) ;;
                *)
                    err "[XHTTP] --auth 仅支持 x25519 或 mlkem768。"
                    return 1
                    ;;
            esac
            if [[ "$XHTTP_DRY_RUN" == "true" ]]; then
                configure_vless_xhttp_finalmask "dry-run" && install_vless_xhttp_finalmask
            else
                prepare_system || return 1
                configure_vless_xhttp_finalmask "cli" && install_vless_xhttp_finalmask
            fi
            ;;
        show | "")
            init_state
            print_vless_xhttp_finalmask_result "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_vless_xhttp_finalmask_config
            ;;
        *)
            err "[失败] 未知 xhttp 参数: $action"
            show_xhttp_usage
            return 1
            ;;
    esac
}

show_advanced_profile_usage() {
    local kind="$1"

    case "$kind" in
        xhttp-reality)
            cat <<'EOF'
用法:
  ike xhttp-reality install [--port PORT] [--path /path] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--dry-run] [--yes]
  ike xhttp-reality show
  ike xhttp-reality remove
  ike view xhttp-reality
EOF
            ;;
        enc-reality)
            cat <<'EOF'
用法:
  ike enc-reality install [--port PORT] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--dry-run] [--yes] [--auth x25519|mlkem768]
  ike enc-reality show
  ike enc-reality remove
  ike view enc-reality
EOF
            ;;
        fullstack)
            cat <<'EOF'
用法:
  ike fullstack install [--port PORT] [--path /path] [--sni DOMAIN] [--flow none|vision] [--fallback-limit off|conservative] [--finalmask on|off] [--finalmask-preset conservative|balanced|aggressive] [--fm-length 100-200] [--fm-delay 10-20] [--fm-max-split 3-6] [--finalmask-json JSON] [--dry-run] [--yes] [--auth x25519|mlkem768]
  ike fullstack show
  ike fullstack remove
  ike view fullstack
EOF
            ;;
    esac
}

run_advanced_profile_command() {
    local kind="$1"
    local action="${2:-show}"

    case "$action" in
        help | -h | --help)
            show_advanced_profile_usage "$kind"
            ;;
        install)
            shift 2
            ADVANCED_PORT_REQUEST=""
            ADVANCED_PATH_REQUEST=""
            ADVANCED_SNI_REQUEST=""
            ADVANCED_FINALMASK_REQUEST="false"
            ADVANCED_FINALMASK_SPECIFIED="false"
            ADVANCED_FLOW="$REALITY_FLOW_NONE"
            ADVANCED_FALLBACK_LIMIT_REQUEST="off"
            FINALMASK_PRESET_REQUEST=""
            FINALMASK_JSON_REQUEST=""
            FINALMASK_PACKETS_REQUEST=""
            FINALMASK_LENGTH_REQUEST=""
            FINALMASK_DELAY_REQUEST=""
            FINALMASK_MAX_SPLIT_REQUEST=""
            ADVANCED_AUTH_SPECIFIED="false"
            ADVANCED_ASSUME_YES="false"
            ADVANCED_DRY_RUN="false"
            VLESS_MODE="basic"
            VLESS_AUTH="x25519"
            VLESS_ENC_METHOD="native"
            VLESS_CLIENT_RTT="0rtt"
            VLESS_SERVER_TICKET="600s"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --port)
                        ADVANCED_PORT_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --path)
                        ADVANCED_PATH_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --sni)
                        ADVANCED_SNI_REQUEST="${2:-}"
                        shift 2
                        ;;
                    --flow)
                        if [[ -z "${2:-}" ]] || ! ADVANCED_FLOW="$(normalize_reality_flow "$2")"; then
                            err "[高级组合] --flow 仅支持 none 或 vision。"
                            return 1
                        fi
                        shift 2
                        ;;
                    --fallback-limit)
                        ADVANCED_FALLBACK_LIMIT_REQUEST="${2:-}"
                        case "${ADVANCED_FALLBACK_LIMIT_REQUEST}" in
                            off | conservative) ;;
                            *)
                                err "[高级组合] --fallback-limit 仅支持 off 或 conservative。"
                                return 1
                                ;;
                        esac
                        shift 2
                        ;;
                    --finalmask)
                        ADVANCED_FINALMASK_REQUEST="${2:-}"
                        ADVANCED_FINALMASK_SPECIFIED="true"
                        shift 2
                        ;;
                    --finalmask-preset | --fm-packets | --fm-length | --fm-delay | --fm-max-split | --finalmask-json)
                        if ! parse_finalmask_args "$1" "${2:-}"; then
                            return 1
                        fi
                        ADVANCED_FINALMASK_SPECIFIED="true"
                        shift "$FINALMASK_ARG_SHIFT"
                        ;;
                    --auth)
                        VLESS_AUTH="${2:-}"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --enc-method)
                        VLESS_ENC_METHOD="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --rtt)
                        VLESS_CLIENT_RTT="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --ticket)
                        VLESS_SERVER_TICKET="${2:-}"
                        VLESS_MODE="advanced"
                        ADVANCED_AUTH_SPECIFIED="true"
                        shift 2
                        ;;
                    --yes | -y)
                        ADVANCED_ASSUME_YES="true"
                        shift
                        ;;
                    --dry-run)
                        ADVANCED_DRY_RUN="true"
                        REALITY_SKIP_TLS_TEST="${REALITY_SKIP_TLS_TEST:-1}"
                        shift
                        ;;
                    help | -h | --help)
                        show_advanced_profile_usage "$kind"
                        return 0
                        ;;
                    *)
                        err "[失败] 未知 ${kind} install 参数: $1"
                        show_advanced_profile_usage "$kind"
                        return 1
                        ;;
                esac
            done
            if [[ -n "$ADVANCED_PATH_REQUEST" ]] && ! advanced_profile_has_xhttp "$kind"; then
                err "[高级组合] ${kind} 不支持 --path。"
                return 1
            fi
            if [[ "$ADVANCED_FINALMASK_SPECIFIED" == "true" ]] && ! advanced_profile_has_finalmask "$kind"; then
                err "[高级组合] ${kind} 不支持 --finalmask。"
                return 1
            fi
            if [[ "$ADVANCED_AUTH_SPECIFIED" == "true" ]] && ! advanced_profile_has_encryption "$kind"; then
                err "[高级组合] ${kind} 不支持 VLESS Encryption 参数。"
                return 1
            fi
            if advanced_profile_has_encryption "$kind"; then
                case "$VLESS_AUTH" in
                    x25519 | mlkem768) ;;
                    *)
                        err "[高级组合] --auth 仅支持 x25519 或 mlkem768。"
                        return 1
                        ;;
                esac
            fi
            if [[ "$ADVANCED_DRY_RUN" == "true" ]]; then
                configure_advanced_profile "$kind" "dry-run" && install_advanced_profile "$kind"
            else
                prepare_system || return 1
                configure_advanced_profile "$kind" "cli" && install_advanced_profile "$kind"
            fi
            ;;
        show | "")
            init_state
            print_advanced_profile_result "$kind" "show"
            ;;
        remove | delete | del)
            prepare_system || return 1
            remove_advanced_profile_config "$kind"
            ;;
        *)
            err "[失败] 未知 ${kind} 参数: $action"
            show_advanced_profile_usage "$kind"
            return 1
            ;;
    esac
}

run_forward_command() {
    run_tunnel_command "$@"
}
