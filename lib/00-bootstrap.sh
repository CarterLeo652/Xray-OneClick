#!/usr/bin/env bash
# Xray-OneClick library bootstrap — sources modules in dependency order.

if [[ -n "${IKE_LIB_BOOTSTRAPPED:-}" ]]; then
    return 0
fi
IKE_LIB_BOOTSTRAPPED=1

IKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_ike_source_lib() {
    local name="$1"
    local lib_path="${IKE_LIB_DIR}/${name}.sh"
    if [[ ! -f "$lib_path" ]]; then
        echo "Xray-OneClick: missing library ${lib_path}" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$lib_path"
}

_ike_source_lib "01-constants" || exit 1
_ike_source_lib "02-output" || exit 1
_ike_source_lib "03-installer" || exit 1
_ike_source_lib "03-system" || exit 1
_ike_source_lib "20-paths" || exit 1
_ike_source_lib "40-network" || exit 1
_ike_source_lib "41-safety" || exit 1
_ike_source_lib "21-config-base" || exit 1
_ike_source_lib "31-service" || exit 1
_ike_source_lib "30-xray-core" || exit 1
_ike_source_lib "50-vless-common" || exit 1
_ike_source_lib "54-ss2022" || exit 1
_ike_source_lib "50-vless-enc" || exit 1
_ike_source_lib "51-reality" || exit 1
_ike_source_lib "52-xhttp" || exit 1
_ike_source_lib "53-advanced" || exit 1
_ike_source_lib "55-socks" || exit 1
_ike_source_lib "56-tunnel" || exit 1
_ike_source_lib "70-view" || exit 1
_ike_source_lib "71-cli-view" || exit 1
_ike_source_lib "80-menu" || exit 1
_ike_source_lib "63-diag" || exit 1
_ike_source_lib "60-doctor" || exit 1
_ike_source_lib "61-smoke" || exit 1
_ike_source_lib "62-export" || exit 1
_ike_source_lib "73-cli-migrate" || exit 1
_ike_source_lib "72-cli-core" || exit 1
_ike_source_lib "72-cli-admin" || exit 1
_ike_source_lib "74-cli-protocols" || exit 1
_ike_source_lib "90-test-harness" || exit 1
_ike_source_lib "81-help" || exit 1
