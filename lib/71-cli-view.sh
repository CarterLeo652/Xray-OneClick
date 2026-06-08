#!/usr/bin/env bash
# ike view command handler.

run_view_command() {
    local mode="$LINK_VIEW_MODE"
    local detail="quick"
    local protocol=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            doctor)
                detail="doctor"
                ;;
            ipv4 | ipv6 | dual)
                mode="$1"
                ;;
            reality)
                protocol="reality"
                ;;
            xhttp)
                protocol="xhttp"
                ;;
            xhttp-reality | enc-reality | fullstack)
                protocol="$1"
                ;;
            *)
                err "[失败] 未知 view 参数: $1"
                echo "用法: ike view [ipv4|ipv6|dual] [doctor|reality|xhttp|xhttp-reality|enc-reality|fullstack]"
                return 1
                ;;
        esac
        shift
    done

    if [[ -n "$protocol" ]]; then
        init_state
        if [[ "$detail" == "doctor" ]]; then
            get_public_addresses
        else
            get_local_addresses
        fi
        host_candidates "$mode"
        CURRENT_LINK_VIEW_MODE="$mode"
        case "$protocol" in
            reality)
                print_reality_result "show"
                ;;
            xhttp)
                print_vless_xhttp_finalmask_result "show"
                ;;
            xhttp-reality | enc-reality | fullstack)
                print_advanced_profile_result "$protocol" "show"
                ;;
        esac
        show_footer
        return 0
    fi

    view_config "$mode" "$detail"
}
