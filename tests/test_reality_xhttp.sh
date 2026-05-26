#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../install.sh
# shellcheck disable=SC1091
source "${ROOT_DIR}/install.sh"
eval "$(declare -f generate_reality_keys | sed '1s/generate_reality_keys/original_generate_reality_keys/')"

TEST_TMP=""
TEST_ROOT="${ROOT_DIR}/.tmp-tests"

info() { :; }
ok() { :; }
err() { printf '%s\n' "$*" >&2; }

ensure_config_security() {
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR"
    [[ -f "$STATE_FILE" ]] && chmod 600 "$STATE_FILE" 2>/dev/null || true
}

install_dependencies() { :; }
install_shortcut() { :; }
enable_bbr() { :; }
create_service() { :; }
TEST_RESTART_COUNT=0
TEST_RESTART_FAIL="false"
restart_xray_service() {
    TEST_RESTART_COUNT=$((TEST_RESTART_COUNT + 1))
    [[ "$TEST_RESTART_FAIL" == "true" ]] && return 1
    return 0
}
restart_service() { restart_xray_service; }
state_set_meta_action() { :; }
check_port() { return 0; }
test_reality_target_tls() { return 0; }
generate_uuid() { printf '%s' "44444444-4444-4444-8444-444444444444"; }
stub_generate_reality_keys() {
    REALITY_PRIVATE_KEY="reality-private-key"
    REALITY_PUBLIC_KEY="reality-public-key"
}
generate_reality_keys() { stub_generate_reality_keys; }
generate_vless_encryption_pair() {
    VLESS_DECRYPTION="server-dec-xhttp"
    VLESS_ENCRYPTION="client-enc-xhttp"
}

validate_config_file() {
    jq empty "$CONFIG_FILE" >/dev/null
}

backup_config() {
    [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "${CONFIG_FILE}.bak.test"
}

apply_config() {
    [[ "${TEST_APPLY_FAIL:-false}" == "true" ]] && return 1
    ensure_default_safety_blocks >/dev/null
    validate_config_file
}

install_or_update_xray() {
    init_config
    init_state
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    dump_debug
    cleanup_fixture
    exit 1
}

dump_debug() {
    [[ -n "$TEST_TMP" ]] || return 0
    if [[ -f "$CONFIG_FILE" ]]; then
        printf '%s\n' "--- debug: config ---" >&2
        jq '.' "$CONFIG_FILE" >&2 || true
    fi
    if [[ -f "$STATE_FILE" ]]; then
        printf '%s\n' "--- debug: state ---" >&2
        jq '.' "$STATE_FILE" >&2 || true
    fi
}

assert_jq() {
    local file="$1"
    local expr="$2"
    local message="$3"

    if ! jq -e "$expr" "$file" >/dev/null; then
        fail "$message"
    fi
}

assert_json() {
    local json="$1"
    local expr="$2"
    local message="$3"

    if ! jq -e "$expr" <<<"$json" >/dev/null; then
        fail "$message"
    fi
}

assert_output_contains() {
    local output="$1"
    local needle="$2"
    local message="$3"

    if [[ "$output" != *"$needle"* ]]; then
        fail "$message"
    fi
}

assert_output_not_contains() {
    local output="$1"
    local needle="$2"
    local message="$3"

    if [[ "$output" == *"$needle"* ]]; then
        fail "$message"
    fi
}

assert_state_mode_600() {
    local mode

    case "$(uname -s 2>/dev/null || true)" in
        MINGW* | MSYS* | CYGWIN*) return 0 ;;
    esac
    mode="$(stat -c '%a' "$STATE_FILE" 2>/dev/null || true)"
    [[ -z "$mode" || "$mode" == "600" ]] || fail "state file mode is not 600: $mode"
}

assert_file_mode_600() {
    local file="$1"
    local mode

    case "$(uname -s 2>/dev/null || true)" in
        MINGW* | MSYS* | CYGWIN*) return 0 ;;
    esac
    mode="$(stat -c '%a' "$file" 2>/dev/null || true)"
    [[ -z "$mode" || "$mode" == "600" ]] || fail "$file mode is not 600: $mode"
}

cleanup_fixture() {
    [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
    rmdir "$TEST_ROOT" 2>/dev/null || true
    TEST_TMP=""
    ENDPOINT_AUTO_OVERRIDE=""
    ENDPOINT_AUTO_CACHE=""
    TEST_X25519_OUTPUT_MODE=""
    XRAY_ONECLICK_TEST_GLOBAL_IPV6=""
    XRAY_ONECLICK_TEST_IPV6_DISABLE_ALL=""
    XRAY_ONECLICK_TEST_IPV6_DISABLE_DEFAULT=""
}

setup_fixture() {
    cleanup_fixture
    mkdir -p "$TEST_ROOT"
    TEST_TMP="$(mktemp -d "${TEST_ROOT}/reality-xhttp.XXXXXX")"
    TMPDIR="${TEST_TMP}/tmp"
    export TMPDIR
    CONFIG_DIR="${TEST_TMP}/etc-xray"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    ASSET_DIR="${TEST_TMP}/share"
    BIN_PATH="${TEST_TMP}/xray"
    ENDPOINT_AUTO_OVERRIDE="203.0.113.10"
    ENDPOINT_AUTO_CACHE=""
    XRAY_ONECLICK_TEST_GLOBAL_IPV6=""
    XRAY_ONECLICK_TEST_IPV6_DISABLE_ALL=""
    XRAY_ONECLICK_TEST_IPV6_DISABLE_DEFAULT=""
    INIT_SYSTEM="test"
    OS_TYPE="test"
    ARCH="x86_64"
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR" "$TMPDIR"
    TEST_X25519_OUTPUT_MODE="new"

    cat >"$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version)
    echo "Xray 26.3.27"
    echo "unknown"
    ;;
  x25519)
    case "${TEST_X25519_OUTPUT_MODE:-new}" in
      old)
        echo "Private key: reality-private-key"
        echo "Public key: reality-public-key"
        ;;
      fail)
        echo "PrivateKey: should-not-leak-private"
        exit 23
        ;;
      *)
        echo "PrivateKey: reality-private-key"
        echo "Password (PublicKey): reality-public-key"
        echo "Hash32: reality-hash32-value"
        ;;
    esac
    ;;
  run)
    [[ "$2" == "-test" ]] && exit 0
    ;;
esac
EOF
    chmod +x "$BIN_PATH"

    cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "ss2022-in",
      "protocol": "shadowsocks",
      "listen": "0.0.0.0",
      "port": 10001,
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "ss-pass"
      }
    },
    {
      "tag": "vless-enc-in",
      "protocol": "vless",
      "listen": "0.0.0.0",
      "port": 10002,
      "settings": {
        "clients": [
          {
            "id": "11111111-1111-4111-8111-111111111111"
          }
        ],
        "decryption": "server-dec"
      }
    },
    {
      "tag": "socks-in",
      "protocol": "socks",
      "listen": "0.0.0.0",
      "port": 10003,
      "settings": {
        "accounts": [
          {
            "user": "admin",
            "pass": "socks-pass"
          }
        ]
      }
    },
    {
      "tag": "occupied-in",
      "protocol": "dokodemo-door",
      "listen": "0.0.0.0",
      "port": 20000,
      "settings": {
        "address": "1.1.1.1",
        "port": 443,
        "network": "tcp"
      }
    },
    {
      "tag": "tunnel-31000-443",
      "protocol": "dokodemo-door",
      "listen": "0.0.0.0",
      "port": 31000,
      "settings": {
        "address": "198.51.100.10",
        "port": 443,
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": ["tunnel-31000-443"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "port": "25,135,137,138,139,445,465,587",
        "outboundTag": "BLOCK"
      }
    ]
  }
}
JSON
    cat >"$STATE_FILE" <<'JSON'
{
  "vless_encryption": {
    "uuid": "11111111-1111-4111-8111-111111111111",
    "encryption": "client-enc",
    "mode": "basic",
    "enc_method": "native",
    "client_rtt": "0rtt",
    "server_ticket": "600s"
  }
}
JSON
    init_config >/dev/null
    init_state >/dev/null
}

set_reality_vars() {
    REALITY_PORT="30004"
    REALITY_DEFENDER_PORT="40004"
    REALITY_UUID="22222222-2222-4222-8222-222222222222"
    REALITY_PRIVATE_KEY="reality-private-key"
    REALITY_PUBLIC_KEY="reality-public-key"
    REALITY_SERVER_NAME="www.abmindustriesgroup.com"
    REALITY_SPIDER_X="/"
    REALITY_EMPTY_CLIENTS="false"
    REALITY_FLOW="$REALITY_FLOW_DEFAULT"
    REALITY_DRY_RUN="false"
    REALITY_DEFAULT_SHORT_ID="aa"
    REALITY_SHORT_IDS_JSON='["aa","bbbb","cccccc","dddddddd","eeeeeeeeee","ffffffffffff","11111111111111","2222222222222222"]'
}

install_reality_fixture() {
    set_reality_vars
    install_reality >/dev/null || fail "reality install failed"
}

set_xhttp_vars() {
    XHTTP_PORT="30005"
    XHTTP_PATH="/api/test"
    XHTTP_FINALMASK_ENABLED="${1:-true}"
    XHTTP_FINALMASK_JSON="$(default_finalmask_json)"
    XHTTP_DRY_RUN="false"
    VLESS_UUID="33333333-3333-4333-8333-333333333333"
    VLESS_DECRYPTION="server-dec-xhttp"
    VLESS_ENCRYPTION="client-enc-xhttp"
    VLESS_AUTH="x25519"
    VLESS_MODE="basic"
    VLESS_ENC_METHOD="native"
    VLESS_CLIENT_RTT="0rtt"
    VLESS_SERVER_TICKET="600s"
    reset_finalmask_request_vars
}

install_xhttp_fixture() {
    set_xhttp_vars "${1:-true}"
    install_vless_xhttp_finalmask >/dev/null || fail "xhttp install failed"
}

reset_finalmask_request_vars() {
    FINALMASK_PRESET_REQUEST=""
    FINALMASK_JSON_REQUEST=""
    FINALMASK_PACKETS_REQUEST=""
    FINALMASK_LENGTH_REQUEST=""
    FINALMASK_DELAY_REQUEST=""
    FINALMASK_MAX_SPLIT_REQUEST=""
    FINALMASK_MODE=""
    FINALMASK_PRESET=""
    FINALMASK_SUMMARY=""
    XHTTP_FINALMASK_MODE=""
    XHTTP_FINALMASK_PRESET=""
    XHTTP_FINALMASK_SUMMARY=""
    ADVANCED_FINALMASK_MODE=""
    ADVANCED_FINALMASK_PRESET=""
    ADVANCED_FINALMASK_SUMMARY=""
}

apply_xhttp_finalmask_from_requests() {
    XHTTP_FINALMASK_JSON="$(build_finalmask_json)" || fail "failed to build xhttp finalmask json"
    set_finalmask_metadata_from_requests "$XHTTP_FINALMASK_JSON"
    XHTTP_FINALMASK_MODE="$FINALMASK_MODE"
    XHTTP_FINALMASK_PRESET="$FINALMASK_PRESET"
    XHTTP_FINALMASK_SUMMARY="$FINALMASK_SUMMARY"
}

apply_advanced_finalmask_from_requests() {
    ADVANCED_FINALMASK_JSON="$(build_finalmask_json)" || fail "failed to build advanced finalmask json"
    set_finalmask_metadata_from_requests "$ADVANCED_FINALMASK_JSON"
    ADVANCED_FINALMASK_MODE="$FINALMASK_MODE"
    ADVANCED_FINALMASK_PRESET="$FINALMASK_PRESET"
    ADVANCED_FINALMASK_SUMMARY="$FINALMASK_SUMMARY"
}

set_inbound_listen() {
    local tag="$1"
    local listen="$2"
    local tmp

    tmp="$(mktemp)"
    jq --arg tag "$tag" --arg listen "$listen" \
        '(.inbounds[]? | select(.tag == $tag).listen) = $listen' \
        "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"
}

set_advanced_vars() {
    local kind="$1"
    local finalmask="${2:-true}"

    case "$kind" in
        xhttp-reality)
            ADVANCED_PORT="30006"
            ADVANCED_PATH="/api/test"
            ;;
        enc-reality)
            ADVANCED_PORT="30007"
            ADVANCED_PATH=""
            ;;
        fullstack)
            ADVANCED_PORT="30008"
            ADVANCED_PATH="/api/test"
            ;;
        *) fail "unknown advanced fixture kind: $kind" ;;
    esac
    ADVANCED_SERVER_NAME="www.abmindustriesgroup.com"
    ADVANCED_UUID="55555555-5555-4555-8555-555555555555"
    ADVANCED_SPIDER_X="/"
    ADVANCED_DRY_RUN="false"
    ADVANCED_FINALMASK_ENABLED="$finalmask"
    ADVANCED_FINALMASK_JSON="$(default_finalmask_json)"
    REALITY_PRIVATE_KEY="reality-private-key"
    REALITY_PUBLIC_KEY="reality-public-key"
    REALITY_DEFAULT_SHORT_ID="aa"
    REALITY_SHORT_IDS_JSON='["aa","bbbb","cccccc","dddddddd","eeeeeeeeee","ffffffffffff","11111111111111","2222222222222222"]'
    VLESS_DECRYPTION="server-dec-advanced"
    VLESS_ENCRYPTION="client-enc-advanced"
    VLESS_AUTH="x25519"
    VLESS_MODE="basic"
    VLESS_ENC_METHOD="native"
    VLESS_CLIENT_RTT="0rtt"
    VLESS_SERVER_TICKET="600s"
    reset_finalmask_request_vars
}

install_advanced_fixture() {
    local kind="$1"
    local finalmask="${2:-true}"

    set_advanced_vars "$kind" "$finalmask"
    install_advanced_profile "$kind" >/dev/null || fail "$kind install failed"
}

test_x25519_parser_formats() {
    local output

    parse_xray_x25519_output $'Private key: old-private\nPublic key: old-public\n' || fail "old x25519 format did not parse"
    [[ "$REALITY_PRIVATE_KEY" == "old-private" && "$REALITY_PUBLIC_KEY" == "old-public" ]] || fail "old x25519 format parsed wrong values"

    parse_xray_x25519_output $'\nPrivateKey: new-private\nPassword: new-public\nHash32: hash-value\n' || fail "new x25519 format did not parse"
    [[ "$REALITY_PRIVATE_KEY" == "new-private" && "$REALITY_PUBLIC_KEY" == "new-public" && "$REALITY_X25519_HASH32" == "hash-value" ]] || fail "new x25519 format parsed wrong values"

    parse_xray_x25519_output $'PrivateKey: real-private\nPassword (PublicKey): real-public\nHash32: real-hash\n' || fail "real x25519 format did not parse"
    [[ "$REALITY_PRIVATE_KEY" == "real-private" && "$REALITY_PUBLIC_KEY" == "real-public" && "$REALITY_X25519_HASH32" == "real-hash" ]] || fail "real x25519 format parsed wrong values"

    parse_xray_x25519_output $'PrivateKey: real2-private\nPassword(PublicKey): real2-public\nHash32: real2-hash\n' || fail "no-space real x25519 format did not parse"
    [[ "$REALITY_PRIVATE_KEY" == "real2-private" && "$REALITY_PUBLIC_KEY" == "real2-public" ]] || fail "no-space real x25519 format parsed wrong values"

    parse_xray_x25519_output $'private key : lower-private\nPUBLICKEY: upper-public\n' || fail "mixed case x25519 format did not parse"
    [[ "$REALITY_PRIVATE_KEY" == "lower-private" && "$REALITY_PUBLIC_KEY" == "upper-public" ]] || fail "mixed case x25519 format parsed wrong values"

    parse_xray_x25519_output $'private key: lower-private\npassword (publickey): lower-public\n' || fail "lowercase password publickey format did not parse"
    [[ "$REALITY_PRIVATE_KEY" == "lower-private" && "$REALITY_PUBLIC_KEY" == "lower-public" ]] || fail "lowercase password publickey format parsed wrong values"

    parse_xray_x25519_output $'unknown\n\nPrivateKey: unknown-private\nPassword (PublicKey): unknown-public\nHash32: unknown-hash\n' || fail "unknown line x25519 format did not parse"
    [[ "$REALITY_PRIVATE_KEY" == "unknown-private" && "$REALITY_PUBLIC_KEY" == "unknown-public" ]] || fail "unknown line x25519 format parsed wrong values"

    if parse_xray_x25519_output $'PrivateThing: nope\nHash32: hash-only\n'; then
        fail "unknown x25519 format should fail"
    fi
    if parse_xray_x25519_output $'PrivateKey: only-private\nHash32: hash-only\n'; then
        fail "x25519 output missing public should fail"
    fi
    if parse_xray_x25519_output $'Password (PublicKey): only-public\nHash32: hash-only\n'; then
        fail "x25519 output missing private should fail"
    fi

    output="$(print_masked_x25519_output $'PrivateKey: very-secret-private-key\nPassword (PublicKey): public-value\n')"
    assert_output_not_contains "$output" "very-secret-private-key" "masked x25519 output leaked private key"
}

test_reality_generate_keys_new_xray_format() {
    local output

    setup_fixture
    TEST_X25519_OUTPUT_MODE="new"
    export TEST_X25519_OUTPUT_MODE
    generate_reality_keys() { original_generate_reality_keys; }
    configure_reality "dry-run" >/dev/null || fail "configure_reality did not parse new x25519 output"
    install_reality >/dev/null || fail "reality install with new x25519 output failed"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+tcp+reality").streamSettings.realitySettings.privateKey) == "reality-private-key"' "reality config did not use parsed privateKey"
    assert_jq "$STATE_FILE" '.vless_reality.private_key == "reality-private-key" and .vless_reality.public_key == "reality-public-key" and .vless_reality.hash32 == "reality-hash32-value" and (.vless_reality.link | contains("pbk=reality-public-key"))' "reality state did not use Password(PublicKey) as publicKey"
    output="$(print_reality_result "show" 2>&1)"
    assert_output_not_contains "$output" "reality-private-key" "reality show leaked private key after new x25519 parse"
    generate_reality_keys() { stub_generate_reality_keys; }
    cleanup_fixture
}

test_reality_generate_keys_failure_is_redacted() {
    local output

    setup_fixture
    TEST_X25519_OUTPUT_MODE="fail"
    export TEST_X25519_OUTPUT_MODE
    generate_reality_keys() { original_generate_reality_keys; }
    if output="$(generate_reality_keys 2>&1)"; then
        fail "x25519 command failure should fail"
    fi
    assert_output_contains "$output" "退出码: 23" "x25519 failure did not show exit code"
    assert_output_not_contains "$output" "should-not-leak-private" "x25519 failure leaked private key"
    generate_reality_keys() { stub_generate_reality_keys; }
    cleanup_fixture
}

test_menu_order_text() {
    local output

    output="$(render_menu | sed -E 's/\x1B\[[0-9;]*[mK]//g')"
    assert_output_contains "$output" "5. 安装 VLESS TCP REALITY" "menu missing Reality at option 5"
    assert_output_contains "$output" "6. 安装 VLESS Encryption + XHTTP + FinalMask" "menu missing XHTTP at option 6"
    assert_output_contains "$output" "7. 安装 VLESS XHTTP + REALITY（高级）" "menu missing xhttp-reality at option 7"
    assert_output_contains "$output" "8. 安装 VLESS Encryption + REALITY（高级）" "menu missing enc-reality at option 8"
    assert_output_contains "$output" "9. 安装 VLESS Encryption + XHTTP + REALITY + FinalMask（FullStack）" "menu missing fullstack at option 9"
    assert_output_contains "$output" "10. 安装 SOCKS5 代理" "menu missing SOCKS5 at option 10"
    assert_output_contains "$output" "19. 退出" "menu missing exit at option 19"
    assert_output_not_contains "$output" "16. 高级协议组合" "menu still hides advanced profiles at option 16"
    assert_output_not_contains "$output" "17. 退出" "menu still exits at option 17"
}

test_uninstall_menu_order_text() {
    local output

    output="$(render_uninstall_menu | sed -E 's/\x1B\[[0-9;]*[mK]//g')"
    assert_output_contains "$output" "5) 删除 VLESS XHTTP + REALITY 配置" "uninstall menu missing xhttp-reality"
    assert_output_contains "$output" "6) 删除 VLESS Encryption + REALITY 配置" "uninstall menu missing enc-reality"
    assert_output_contains "$output" "7) 删除 VLESS Encryption + XHTTP + REALITY + FinalMask 配置" "uninstall menu missing fullstack"
    assert_output_contains "$output" "9) 卸载全部 Xray" "uninstall all should be option 9"
    assert_output_contains "$output" "11) 返回主菜单" "return should be option 11"
}
test_reality_jq_write() {
    setup_fixture
    install_reality_fixture

    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless+tcp+reality" and .protocol == "vless" and .streamSettings.security == "reality")' "reality inbound missing"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+tcp+reality").settings.clients[0].flow) == "xtls-rprx-vision"' "reality client flow missing"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "reality-defender" and .listen == "127.0.0.1" and .settings.address == "www.abmindustriesgroup.com" and .settings.port == 443)' "reality defender missing"
    # shellcheck disable=SC2016
    assert_jq "$CONFIG_FILE" '.routing.rules as $rules |
      ($rules | map((.inboundTag // []) == ["reality-defender"] and (.domain // []) == ["full:www.abmindustriesgroup.com"] and .outboundTag == "direct") | index(true)) as $direct |
      ($rules | map((.inboundTag // []) == ["reality-defender"] and .outboundTag == "BLOCK") | index(true)) as $block |
      ($direct != null and $block != null and $direct < $block)' "reality direct rule is not before block rule"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+tcp+reality").streamSettings.realitySettings.shortIds | length) == 8' "reality shortIds count is not 8"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+tcp+reality").streamSettings.realitySettings.privateKey | length) > 0' "reality private key missing"
    assert_jq "$STATE_FILE" '.vless_reality.public_key == "reality-public-key" and .vless_reality.private_key == "reality-private-key" and .vless_reality.flow == "xtls-rprx-vision" and (.vless_reality.short_ids | length) == 8 and (.vless_reality.link | contains("flow=xtls-rprx-vision"))' "reality state missing public key/flow/link"
    assert_state_mode_600
    cleanup_fixture
}

test_reality_random_port() {
    local port

    setup_fixture
    port="$(random_free_port 20001 20001)" || fail "random_free_port did not find free single port"
    [[ "$port" == "20001" ]] || fail "random port was not in expected range"
    if port_used_in_config "$port"; then
        fail "random port conflicts with config"
    fi
    port_used_in_config "20000" || fail "port_used_in_config did not detect occupied inbound"
    cleanup_fixture
}

test_xhttp_finalmask_write() {
    local link fm

    setup_fixture
    install_xhttp_fixture "false"

    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless-enc-xhttp-finalmask-in" and .streamSettings.network == "xhttp" and .streamSettings.xhttpSettings.path == "/api/test")' "xhttp inbound/path missing"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless-enc-xhttp-finalmask-in").streamSettings | has("finalmask") | not)' "finalmask off still wrote finalmask"
    assert_jq "$STATE_FILE" '.vless_xhttp_finalmask.finalmask_enabled == false and (.vless_xhttp_finalmask.link | contains("fm=") | not) and (.vless_xhttp_finalmask.link | contains("path=%2Fapi%2Ftest"))' "finalmask off state/link is wrong"

    install_xhttp_fixture "true"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless-enc-xhttp-finalmask-in").streamSettings.finalmask.tcp[0].type) == "fragment"' "finalmask on did not write template"
    assert_jq "$STATE_FILE" '.vless_xhttp_finalmask.finalmask_enabled == true and (.vless_xhttp_finalmask.link | contains("fm=%7B")) and (.vless_xhttp_finalmask.link | contains("{") | not)' "finalmask link is not URL encoded"
    link="$(jq -r '.vless_xhttp_finalmask.link' "$STATE_FILE")"
    fm="${link#*fm=}"
    fm="${fm%%#*}"
    [[ "$fm" != *"{"* && "$fm" != *"}"* && "$fm" != *" "* && "$fm" != *"\""* ]] || fail "fm contains raw JSON characters"
    cleanup_fixture
}

test_finalmask_presets_custom_and_raw_json() {
    local json output

    reset_finalmask_request_vars
    json="$(build_finalmask_preset_json conservative)"
    assert_json "$json" '.tcp[0].settings.length == "120-240" and .tcp[0].settings.delay == "5-10" and .tcp[0].settings.maxSplit == "2-4"' "conservative preset json mismatch"
    json="$(build_finalmask_preset_json balanced)"
    assert_json "$json" '.tcp[0].settings.length == "100-200" and .tcp[0].settings.delay == "10-20" and .tcp[0].settings.maxSplit == "3-6"' "balanced preset json mismatch"
    [[ "$(canonical_json "$json")" == "$(canonical_json "$(default_finalmask_json)")" ]] || fail "default finalmask is not balanced"
    json="$(build_finalmask_preset_json aggressive)"
    assert_json "$json" '.tcp[0].settings.length == "80-160" and .tcp[0].settings.delay == "10-30" and .tcp[0].settings.maxSplit == "4-8"' "aggressive preset json mismatch"

    json="$(build_finalmask_custom_json tlshello 80-160 10-30 4-8)"
    assert_json "$json" '.tcp[0].settings.packets == "tlshello" and .tcp[0].settings.length == "80-160" and .tcp[0].settings.delay == "10-30" and .tcp[0].settings.maxSplit == "4-8"' "custom finalmask json mismatch"

    if build_finalmask_custom_json bad 100-200 10-20 3-6 >/dev/null 2>&1; then fail "invalid packets accepted"; fi
    if build_finalmask_custom_json tlshello 200-100 10-20 3-6 >/dev/null 2>&1; then fail "invalid length range accepted"; fi
    if build_finalmask_custom_json tlshello 100-200 20-10 3-6 >/dev/null 2>&1; then fail "invalid delay range accepted"; fi
    if build_finalmask_custom_json tlshello 100-200 10-20 21 >/dev/null 2>&1; then fail "invalid maxSplit accepted"; fi
    if validate_finalmask_json '{"tcp":{}}'; then fail "invalid raw finalmask structure accepted"; fi

    reset_finalmask_request_vars
    FINALMASK_JSON_REQUEST='{"tcp":[{"type":"fragment","settings":{"packets":"tlshello","length":"77-88","delay":"1-2","maxSplit":"2-3"}}]}'
    json="$(build_finalmask_json)" || fail "raw finalmask json rejected"
    set_finalmask_metadata_from_requests "$json"
    [[ "$FINALMASK_MODE" == "raw-json" && "$FINALMASK_PRESET" == "raw-json" ]] || fail "raw json metadata mismatch"
    assert_json "$json" '.tcp[0].settings.length == "77-88"' "raw finalmask json mismatch"

    reset_finalmask_request_vars
    FINALMASK_PRESET_REQUEST="balanced"
    FINALMASK_LENGTH_REQUEST="80-160"
    if output="$(build_finalmask_json 2>&1)"; then
        fail "preset and custom finalmask options should conflict"
    fi
    assert_output_contains "$output" "--finalmask-preset" "finalmask conflict error missing"
}

test_xhttp_finalmask_modes_and_state() {
    local output

    setup_fixture
    set_xhttp_vars "true"
    reset_finalmask_request_vars
    FINALMASK_PRESET_REQUEST="conservative"
    apply_xhttp_finalmask_from_requests
    install_vless_xhttp_finalmask >/dev/null || fail "xhttp conservative install failed"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless-enc-xhttp-finalmask-in").streamSettings.finalmask.tcp[0].settings.length) == "120-240"' "xhttp conservative finalmask not written"
    assert_jq "$STATE_FILE" '.vless_xhttp_finalmask.finalmask_mode == "preset" and .vless_xhttp_finalmask.finalmask_preset == "conservative" and (.vless_xhttp_finalmask.finalmask_summary | contains("length=120-240"))' "xhttp conservative state metadata missing"

    set_xhttp_vars "true"
    reset_finalmask_request_vars
    FINALMASK_PRESET_REQUEST="aggressive"
    apply_xhttp_finalmask_from_requests
    install_vless_xhttp_finalmask >/dev/null || fail "xhttp aggressive install failed"
    assert_jq "$STATE_FILE" '.vless_xhttp_finalmask.finalmask_preset == "aggressive" and (.vless_xhttp_finalmask.finalmask_summary | contains("maxSplit=4-8"))' "xhttp aggressive state metadata missing"

    set_xhttp_vars "true"
    reset_finalmask_request_vars
    FINALMASK_LENGTH_REQUEST="80-160"
    FINALMASK_DELAY_REQUEST="10-30"
    FINALMASK_MAX_SPLIT_REQUEST="4-8"
    apply_xhttp_finalmask_from_requests
    install_vless_xhttp_finalmask >/dev/null || fail "xhttp custom install failed"
    assert_jq "$STATE_FILE" '.vless_xhttp_finalmask.finalmask_mode == "custom" and .vless_xhttp_finalmask.finalmask_preset == "custom" and (.vless_xhttp_finalmask.finalmask_summary | contains("length=80-160"))' "xhttp custom state metadata missing"

    set_xhttp_vars "true"
    reset_finalmask_request_vars
    FINALMASK_JSON_REQUEST='{"tcp":[{"type":"fragment","settings":{"packets":"tlshello","length":"77-88","delay":"1-2","maxSplit":"2-3"}}]}'
    apply_xhttp_finalmask_from_requests
    install_vless_xhttp_finalmask >/dev/null || fail "xhttp raw-json install failed"
    assert_jq "$STATE_FILE" '.vless_xhttp_finalmask.finalmask_mode == "raw-json" and .vless_xhttp_finalmask.finalmask_preset == "raw-json" and (.vless_xhttp_finalmask.link | contains("fm="))' "xhttp raw-json state/link missing"
    output="$(print_vless_xhttp_finalmask_result "show" 2>&1)"
    assert_output_contains "$output" "FinalMask 模式: raw-json" "xhttp show missing raw-json mode"
    assert_output_contains "$output" "FinalMask 摘要:" "xhttp show missing finalmask summary"
    cleanup_fixture
}

test_fullstack_finalmask_modes_and_state() {
    setup_fixture
    set_advanced_vars "fullstack" "true"
    reset_finalmask_request_vars
    FINALMASK_PRESET_REQUEST="balanced"
    apply_advanced_finalmask_from_requests
    install_advanced_profile "fullstack" >/dev/null || fail "fullstack balanced install failed"
    assert_jq "$STATE_FILE" '.vless_fullstack.finalmask_mode == "preset" and .vless_fullstack.finalmask_preset == "balanced" and (.vless_fullstack.link | contains("fm="))' "fullstack balanced metadata missing"

    set_advanced_vars "fullstack" "true"
    reset_finalmask_request_vars
    FINALMASK_LENGTH_REQUEST="80-160"
    FINALMASK_DELAY_REQUEST="10-30"
    FINALMASK_MAX_SPLIT_REQUEST="4-8"
    apply_advanced_finalmask_from_requests
    install_advanced_profile "fullstack" >/dev/null || fail "fullstack custom install failed"
    assert_jq "$STATE_FILE" '.vless_fullstack.finalmask_mode == "custom" and .vless_fullstack.finalmask_preset == "custom" and (.vless_fullstack.finalmask_summary | contains("maxSplit=4-8"))' "fullstack custom metadata missing"

    set_advanced_vars "fullstack" "true"
    reset_finalmask_request_vars
    FINALMASK_JSON_REQUEST='{"tcp":[{"type":"fragment","settings":{"packets":"tlshello","length":"77-88","delay":"1-2","maxSplit":"2-3"}}]}'
    apply_advanced_finalmask_from_requests
    install_advanced_profile "fullstack" >/dev/null || fail "fullstack raw-json install failed"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+enc+xhttp+reality+finalmask").streamSettings.finalmask.tcp[0].settings.length) == "77-88"' "fullstack raw-json not written"
    assert_jq "$STATE_FILE" '.vless_fullstack.finalmask_mode == "raw-json" and .vless_fullstack.finalmask_preset == "raw-json"' "fullstack raw-json metadata missing"
    cleanup_fixture
}

test_xhttp_path_validation() {
    validate_xhttp_path "/api/test" || fail "/api/test should be valid"
    if validate_xhttp_path "api/test"; then
        fail "path without leading slash should be rejected"
    fi
    if validate_xhttp_path "/api/test space"; then
        fail "path with space should be rejected"
    fi
    if validate_xhttp_path "/api/test?x=1"; then
        fail "path with query should be rejected"
    fi
    if validate_xhttp_path "/api/test#frag"; then
        fail "path with fragment should be rejected"
    fi
    if validate_xhttp_path '/api\test'; then
        fail "path with backslash should be rejected"
    fi
}

test_view_outputs_new_and_old_links() {
    local output

    setup_fixture
    state_set_endpoint "edge.example.com" >/dev/null || fail "endpoint set failed"
    install_reality_fixture
    install_xhttp_fixture "true"

    output="$(view_config dual quick)"
    assert_output_contains "$output" "Shadowsocks 2022" "view lost SS2022 section"
    assert_output_contains "$output" "VLESS Encryption" "view lost VLESS Encryption section"
    assert_output_contains "$output" "VLESS TCP REALITY" "view did not show Reality"
    assert_output_contains "$output" "XHTTP + FinalMask" "view did not show XHTTP-FinalMask"
    assert_output_contains "$output" "SOCKS5" "view lost SOCKS5 section"
    assert_output_contains "$output" "security=reality" "view did not show Reality link"
    assert_output_contains "$output" "flow=xtls-rprx-vision" "view did not show Reality flow"
    assert_output_contains "$output" "type=xhttp" "view did not show XHTTP link"
    assert_output_not_contains "$output" "reality-private-key" "view leaked Reality private key"

    output="$(run_view_command reality 2>&1)"
    assert_output_contains "$output" "vless://" "ike view reality did not show link"
    assert_output_contains "$output" "Flow: xtls-rprx-vision" "ike view reality did not show flow"
    assert_output_not_contains "$output" "reality-private-key" "ike view reality leaked private key"

    output="$(run_view_command xhttp 2>&1)"
    assert_output_contains "$output" "vless://" "ike view xhttp did not show link"
    assert_output_contains "$output" "type=xhttp" "ike view xhttp did not show xhttp link"
    cleanup_fixture
}

test_ipv6_link_scope_consistency() {
    local output tmp

    setup_fixture
    XRAY_ONECLICK_TEST_GLOBAL_IPV6="2407:cdc0:b027::274"
    output="$(view_config dual quick)"
    assert_output_not_contains "$output" "SS2022-IPv6" "IPv4-only SS2022 should not print IPv6 link"
    assert_output_not_contains "$output" "socks5://admin:socks-pass@[" "IPv4-only SOCKS5 should not print IPv6 link"

    set_inbound_listen "$SS_TAG" "::"
    output="$(view_config dual quick)"
    assert_output_contains "$output" "SS2022-IPv6" "SS2022 listening on :: should print IPv6 link"

    set_inbound_listen "$SOCKS_TAG" "::"
    output="$(view_config dual quick)"
    assert_output_contains "$output" "socks5://admin:socks-pass@[" "SOCKS5 listening on :: should print IPv6 link"

    tmp="$(mktemp)"
    jq '.ss2022 = {"port":10001,"listen_scope":"ipv4"}' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    output="$(render_export_clients)"
    assert_output_not_contains "$output" "SS2022-IPv6" "state listen_scope=ipv4 should suppress SS2022 IPv6 export"

    output="$(view_config ipv6 quick)"
    assert_output_contains "$output" "当前协议未监听 IPv6" "ipv6-only view should explain unsupported protocol"

    XRAY_ONECLICK_TEST_GLOBAL_IPV6=""
    XRAY_ONECLICK_TEST_IPV6_DISABLE_ALL="1"
    XRAY_ONECLICK_TEST_IPV6_DISABLE_DEFAULT="1"
    if output="$(check_ipv6_status 2>&1)"; then
        fail "IPv6 check should fail without global IPv6"
    fi
    assert_output_contains "$output" "未检测到全局 IPv6 地址" "IPv6 failure should mention missing global address"

    XRAY_ONECLICK_TEST_GLOBAL_IPV6="2407:cdc0:b027::274"
    info() { printf '%s\n' "$*"; }
    ok() { printf '%s\n' "$*"; }
    output="$(check_ipv6_status 2>&1)" || fail "IPv6 check should continue when global IPv6 exists"
    info() { :; }
    ok() { :; }
    assert_output_contains "$output" "disable_ipv6=1" "IPv6 check should warn when sysctl is disabled but address exists"
    cleanup_fixture
}

test_migrate_infers_listen_scope() {
    local tmp

    setup_fixture
    tmp="$(mktemp)"
    jq '.ss2022 = {"port":10001}' "$STATE_FILE" >"$tmp" && mv "$tmp" "$STATE_FILE"
    migrate_old_state false >/dev/null || fail "migrate_old_state failed"
    assert_jq "$STATE_FILE" '.ss2022.listen_scope == "ipv4"' "migrate did not infer SS2022 listen_scope"
    cleanup_fixture
}

test_remove_reality_and_xhttp_are_scoped() {
    setup_fixture
    install_reality_fixture
    install_xhttp_fixture "true"
    install_advanced_fixture "xhttp-reality"
    install_advanced_fixture "enc-reality"
    install_advanced_fixture "fullstack" "true"

    remove_reality_config >/dev/null || fail "reality remove failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+tcp+reality" or .tag == "reality-defender")] | length) == 0' "reality inbounds remained"
    assert_jq "$CONFIG_FILE" '([.routing.rules[]? | select(((.inboundTag // []) | index("reality-defender")) != null)] | length) == 0' "reality routing remained"
    assert_jq "$STATE_FILE" 'has("vless_reality") | not' "reality state remained"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in") and any(.inbounds[]?; .tag == "tunnel-31000-443") and any(.inbounds[]?; .tag == "vless-enc-xhttp-finalmask-in") and any(.inbounds[]?; .tag == "vless+xhttp+reality") and any(.inbounds[]?; .tag == "vless+enc+reality") and any(.inbounds[]?; .tag == "vless+enc+xhttp+reality+finalmask")' "reality remove affected other protocols"
    assert_jq "$STATE_FILE" 'has("vless_xhttp_reality") and has("vless_enc_reality") and has("vless_fullstack")' "reality remove affected advanced state"
    assert_jq "$CONFIG_FILE" 'any(.routing.rules[]?; ((.inboundTag // []) | index("tunnel-31000-443")) != null)' "reality remove affected tunnel routing"

    install_reality_fixture
    remove_vless_xhttp_finalmask_config >/dev/null || fail "xhttp remove failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless-enc-xhttp-finalmask-in")] | length) == 0' "xhttp inbound remained"
    assert_jq "$STATE_FILE" 'has("vless_xhttp_finalmask") | not' "xhttp state remained"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in") and any(.inbounds[]?; .tag == "tunnel-31000-443") and any(.inbounds[]?; .tag == "vless+tcp+reality") and any(.inbounds[]?; .tag == "reality-defender") and any(.inbounds[]?; .tag == "vless+xhttp+reality") and any(.inbounds[]?; .tag == "vless+enc+reality") and any(.inbounds[]?; .tag == "vless+enc+xhttp+reality+finalmask")' "xhttp remove affected other protocols"
    assert_jq "$STATE_FILE" 'has("vless_reality")' "xhttp remove affected reality state"
    assert_jq "$STATE_FILE" 'has("vless_xhttp_reality") and has("vless_enc_reality") and has("vless_fullstack")' "xhttp remove affected advanced state"

    remove_inbound "$VLESS_TAG"
    state_delete_key "vless_encryption"
    apply_config >/dev/null || fail "base vless remove apply failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless+enc+reality") and any(.inbounds[]?; .tag == "vless+enc+xhttp+reality+finalmask")' "base vless remove affected advanced encryption combos"
    assert_jq "$STATE_FILE" 'has("vless_enc_reality") and has("vless_fullstack")' "base vless remove affected advanced state"
    cleanup_fixture
}

test_repeat_install_does_not_duplicate() {
    setup_fixture
    install_reality_fixture
    install_reality_fixture
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+tcp+reality")] | length) == 1' "duplicate reality inbound"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "reality-defender")] | length) == 1' "duplicate reality defender inbound"
    assert_jq "$CONFIG_FILE" '([.routing.rules[]? | select(((.inboundTag // []) | index("reality-defender")) != null)] | length) == 2' "duplicate reality defender routing rules"

    install_xhttp_fixture "false"
    install_xhttp_fixture "true"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless-enc-xhttp-finalmask-in")] | length) == 1' "duplicate xhttp inbound"
    cleanup_fixture
}

test_uninstalled_show_remove_are_friendly() {
    local output

    setup_fixture
    output="$(run_reality_command show 2>&1)" || fail "uninstalled reality show failed"
    assert_output_contains "$output" "未安装" "uninstalled reality show was not friendly"
    run_reality_command remove >/dev/null 2>&1 || fail "uninstalled reality remove failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in") and any(.inbounds[]?; .tag == "tunnel-31000-443")' "uninstalled reality remove affected existing protocols"

    output="$(run_xhttp_command show 2>&1)" || fail "uninstalled xhttp show failed"
    assert_output_contains "$output" "未安装" "uninstalled xhttp show was not friendly"
    run_xhttp_command remove >/dev/null 2>&1 || fail "uninstalled xhttp remove failed"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in") and any(.inbounds[]?; .tag == "tunnel-31000-443")' "uninstalled xhttp remove affected existing protocols"
    cleanup_fixture
}

test_dry_run_does_not_modify_files() {
    local before_config before_state after_config after_state output

    setup_fixture
    before_config="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    before_state="$(sha256sum "$STATE_FILE" | awk '{print $1}')"

    set_reality_vars
    REALITY_DRY_RUN="true"
    output="$(install_reality 2>&1)" || fail "reality dry-run failed"
    assert_output_contains "$output" "Reality dry-run" "reality dry-run output missing title"
    assert_output_contains "$output" "30004" "reality dry-run output missing port"
    assert_output_contains "$output" "www.abmindustriesgroup.com" "reality dry-run output missing sni"
    assert_output_not_contains "$output" "reality-private-key" "reality dry-run leaked private key"

    set_xhttp_vars "true"
    XHTTP_DRY_RUN="true"
    output="$(install_vless_xhttp_finalmask 2>&1)" || fail "xhttp dry-run failed"
    assert_output_contains "$output" "XHTTP-FinalMask dry-run" "xhttp dry-run output missing title"
    assert_output_contains "$output" "/api/test" "xhttp dry-run output missing path"
    assert_output_contains "$output" "FinalMask: on" "xhttp dry-run output missing finalmask state"

    after_config="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    after_state="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    [[ "$before_config" == "$after_config" ]] || fail "dry-run modified config"
    [[ "$before_state" == "$after_state" ]] || fail "dry-run modified state"

    if run_reality_command install --sni "https://bad.example.com" --dry-run >/dev/null 2>&1; then
        fail "reality dry-run accepted invalid sni"
    fi
    if run_xhttp_command install --path "/api/bad?x=1" --dry-run >/dev/null 2>&1; then
        fail "xhttp dry-run accepted invalid path"
    fi
    cleanup_fixture
}

test_doctor_smoke_and_export() {
    local output report_file clients_file

    setup_fixture
    install_reality_fixture
    install_xhttp_fixture "true"

    output="$(doctor_reality 2>&1)"
    assert_output_contains "$output" "[✓] Reality inbound 已安装" "doctor reality did not confirm inbound"
    assert_output_contains "$output" "Reality flow 一致" "doctor reality did not check flow"
    assert_output_contains "$output" "PublicKey: reality-public-key" "doctor reality did not show public key"
    assert_output_not_contains "$output" "reality-private-key" "doctor reality leaked private key"

    output="$(doctor_xhttp 2>&1)"
    assert_output_contains "$output" "XHTTP inbound" "doctor xhttp did not check inbound"
    assert_output_contains "$output" "fm 参数已 URL 编码" "doctor xhttp did not check fm encoding"

    TEST_RESTART_COUNT=0
    output="$(smoke_reality false 2>&1)"
    assert_output_contains "$output" "默认不自动 restart" "smoke reality did not state default restart policy"
    [[ "$TEST_RESTART_COUNT" -eq 0 ]] || fail "smoke reality restarted without --restart"
    smoke_reality true >/dev/null 2>&1 || true
    [[ "$TEST_RESTART_COUNT" -eq 1 ]] || fail "smoke reality --restart did not call restart"

    cat >"$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then
  echo "Xray test-version"
  exit 0
fi
if [[ "$1" == "run" && "$2" == "-test" ]]; then
  echo "mock xray test failure"
  exit 1
fi
exit 0
EOF
    chmod +x "$BIN_PATH"
    output="$(smoke_xhttp false 2>&1)"
    assert_output_contains "$output" "--finalmask off" "smoke xhttp failure did not suggest finalmask off"

    output="$(render_export_report 2>&1)"
    assert_output_contains "$output" "SCRIPT_VERSION" "export report missing version"
    assert_output_contains "$output" "Reality 摘要" "export report missing reality summary"
    assert_output_not_contains "$output" "reality-private-key" "export report leaked reality private key"
    assert_output_not_contains "$output" "server-dec-xhttp" "export report leaked decryption"

    output="$(render_export_clients 2>&1)"
    assert_output_contains "$output" "vless://" "export clients missing vless links"
    assert_output_contains "$output" "如客户端无法导入" "export clients missing FinalMask import hint"
    assert_output_not_contains "$output" "reality-private-key" "export clients leaked reality private key"
    assert_output_not_contains "$output" "server-dec-xhttp" "export clients leaked decryption"

    report_file="${TEST_TMP}/report.txt"
    clients_file="${TEST_TMP}/clients.txt"
    run_export_command report --output "$report_file" >/dev/null || fail "export report file failed"
    run_export_command clients --output "$clients_file" >/dev/null || fail "export clients file failed"
    [[ -s "$report_file" && -s "$clients_file" ]] || fail "export output file missing"
    assert_file_mode_600 "$report_file"
    assert_file_mode_600 "$clients_file"
    cleanup_fixture
}

test_show_output_compatibility_hints() {
    local output

    setup_fixture
    install_reality_fixture
    output="$(print_reality_result "show" 2>&1)"
    assert_output_contains "$output" "Protocol: VLESS" "reality show missing protocol"
    assert_output_contains "$output" "Flow: xtls-rprx-vision" "reality show missing flow"
    assert_output_contains "$output" "PublicKey: reality-public-key" "reality show missing public key"
    assert_output_contains "$output" "ShortID: aa" "reality show missing short id"
    assert_output_contains "$output" "客户端内核可能太旧" "reality show missing compatibility hint"
    assert_output_not_contains "$output" "reality-private-key" "reality show leaked private key"

    install_xhttp_fixture "false"
    output="$(print_vless_xhttp_finalmask_result "show" 2>&1)"
    assert_output_contains "$output" "Path: /api/test" "xhttp show missing path"
    assert_output_contains "$output" "VLESS Encryption: client-enc-xhttp" "xhttp show missing encryption"
    assert_output_contains "$output" "FinalMask: off" "xhttp show missing finalmask off"
    assert_output_not_contains "$output" "fm=" "xhttp finalmask off showed fm"

    install_xhttp_fixture "true"
    output="$(print_vless_xhttp_finalmask_result "show" 2>&1)"
    assert_output_contains "$output" "fm=" "xhttp finalmask on missing fm link"
    assert_output_contains "$output" "XHTTP + FinalMask 需要较新的客户端核心" "xhttp show missing compatibility hint"
    cleanup_fixture
}

test_failure_hints_do_not_update_state() {
    local output status

    setup_fixture
    set_reality_vars
    TEST_APPLY_FAIL="true"
    output="$(install_reality 2>&1)"
    status=$?
    TEST_APPLY_FAIL="false"
    [[ "$status" -ne 0 ]] || fail "reality install unexpectedly succeeded"
    assert_output_contains "$output" "ike doctor reality" "reality failure missing doctor hint"
    assert_output_contains "$output" "ike smoke reality" "reality failure missing smoke hint"
    assert_jq "$STATE_FILE" 'has("vless_reality") | not' "reality failure updated state"
    cleanup_fixture

    setup_fixture
    set_xhttp_vars "true"
    TEST_APPLY_FAIL="true"
    output="$(install_vless_xhttp_finalmask 2>&1)"
    status=$?
    TEST_APPLY_FAIL="false"
    [[ "$status" -ne 0 ]] || fail "xhttp install unexpectedly succeeded"
    assert_output_contains "$output" "--finalmask off" "xhttp failure missing finalmask off hint"
    assert_output_contains "$output" "ike doctor xhttp" "xhttp failure missing doctor hint"
    assert_output_contains "$output" "ike smoke xhttp" "xhttp failure missing smoke hint"
    assert_jq "$STATE_FILE" 'has("vless_xhttp_finalmask") | not' "xhttp failure updated state"
    cleanup_fixture
}

test_advanced_profiles_write_and_links() {
    local link fm

    setup_fixture
    install_advanced_fixture "xhttp-reality"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless+xhttp+reality" and .protocol == "vless" and .settings.decryption == "none" and .streamSettings.network == "xhttp" and .streamSettings.security == "reality" and .streamSettings.xhttpSettings.path == "/api/test" and .streamSettings.realitySettings.privateKey == "reality-private-key")' "xhttp-reality inbound invalid"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+xhttp+reality").settings.clients[0] | has("flow") | not)' "xhttp-reality should not write flow"
    assert_jq "$STATE_FILE" '.vless_xhttp_reality.public_key == "reality-public-key" and (.vless_xhttp_reality.link | contains("type=xhttp")) and (.vless_xhttp_reality.link | contains("security=reality")) and (.vless_xhttp_reality.link | contains("path=%2Fapi%2Ftest")) and (.vless_xhttp_reality.link | contains("pbk=reality-public-key"))' "xhttp-reality state/link invalid"

    install_advanced_fixture "enc-reality"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless+enc+reality" and .settings.decryption == "server-dec-advanced" and .streamSettings.network == "tcp" and .streamSettings.security == "reality")' "enc-reality inbound invalid"
    assert_jq "$STATE_FILE" '.vless_enc_reality.encryption == "client-enc-advanced" and (.vless_enc_reality.link | contains("type=tcp")) and (.vless_enc_reality.link | contains("encryption=client-enc-advanced")) and (.vless_enc_reality.link | contains("pbk=reality-public-key"))' "enc-reality state/link invalid"

    install_advanced_fixture "fullstack" "false"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless+enc+xhttp+reality+finalmask" and .settings.decryption == "server-dec-advanced" and .streamSettings.network == "xhttp" and .streamSettings.security == "reality" and .streamSettings.xhttpSettings.path == "/api/test")' "fullstack inbound invalid"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+enc+xhttp+reality+finalmask").streamSettings | has("finalmask") | not)' "fullstack finalmask off wrote finalmask"
    assert_jq "$STATE_FILE" '.vless_fullstack.finalmask_enabled == false and (.vless_fullstack.link | contains("fm=") | not)' "fullstack finalmask off state/link invalid"

    install_advanced_fixture "fullstack" "true"
    assert_jq "$CONFIG_FILE" '(.inbounds[]? | select(.tag == "vless+enc+xhttp+reality+finalmask").streamSettings.finalmask.tcp[0].type) == "fragment"' "fullstack finalmask on missing template"
    assert_jq "$STATE_FILE" '.vless_fullstack.finalmask_enabled == true and (.vless_fullstack.link | contains("fm=")) and (.vless_fullstack.link | contains("encryption=client-enc-advanced")) and (.vless_fullstack.link | contains("pbk=reality-public-key"))' "fullstack finalmask on link invalid"
    link="$(jq -r '.vless_fullstack.link' "$STATE_FILE")"
    fm="${link#*fm=}"
    fm="${fm%%#*}"
    [[ "$fm" != *"{"* && "$fm" != *"}"* && "$fm" != *" "* && "$fm" != *"\""* ]] || fail "fullstack fm contains raw JSON characters"
    cleanup_fixture
}

test_advanced_remove_repeat_and_dry_run() {
    local before_config before_state after_config after_state output status

    setup_fixture
    install_reality_fixture
    install_xhttp_fixture "true"
    install_advanced_fixture "xhttp-reality"
    install_advanced_fixture "enc-reality"
    install_advanced_fixture "fullstack" "true"

    remove_advanced_profile_config "xhttp-reality" >/dev/null || fail "xhttp-reality remove failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+xhttp+reality")] | length) == 0' "xhttp-reality inbound remained"
    assert_jq "$STATE_FILE" 'has("vless_xhttp_reality") | not' "xhttp-reality state remained"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless-enc-xhttp-finalmask-in") and any(.inbounds[]?; .tag == "vless+tcp+reality") and any(.inbounds[]?; .tag == "vless+enc+reality") and any(.inbounds[]?; .tag == "vless+enc+xhttp+reality+finalmask")' "xhttp-reality remove affected other protocols"

    remove_advanced_profile_config "enc-reality" >/dev/null || fail "enc-reality remove failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+enc+reality")] | length) == 0' "enc-reality inbound remained"
    assert_jq "$STATE_FILE" 'has("vless_enc_reality") | not' "enc-reality state remained"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless+tcp+reality") and any(.inbounds[]?; .tag == "vless-enc-in")' "enc-reality remove affected base protocols"

    remove_advanced_profile_config "fullstack" >/dev/null || fail "fullstack remove failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+enc+xhttp+reality+finalmask")] | length) == 0' "fullstack inbound remained"
    assert_jq "$STATE_FILE" 'has("vless_fullstack") | not' "fullstack state remained"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "vless-enc-xhttp-finalmask-in") and any(.inbounds[]?; .tag == "vless+tcp+reality")' "fullstack remove affected other protocols"

    install_advanced_fixture "xhttp-reality"
    install_advanced_fixture "xhttp-reality"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+xhttp+reality")] | length) == 1' "duplicate xhttp-reality inbound"
    install_advanced_fixture "enc-reality"
    install_advanced_fixture "enc-reality"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+enc+reality")] | length) == 1' "duplicate enc-reality inbound"
    install_advanced_fixture "fullstack" "true"
    install_advanced_fixture "fullstack" "false"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+enc+xhttp+reality+finalmask")] | length) == 1' "duplicate fullstack inbound"
    assert_jq "$CONFIG_FILE" '([.routing.rules[]? | select(((.inboundTag // []) | index("reality-defender")) != null)] | length) == 2' "advanced repeat install duplicated reality defender routing"

    before_config="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    before_state="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    set_advanced_vars "fullstack" "true"
    ADVANCED_DRY_RUN="true"
    output="$(install_advanced_profile "fullstack" 2>&1)" || fail "fullstack dry-run failed"
    assert_output_contains "$output" "dry-run 预览" "fullstack dry-run output missing"
    assert_output_contains "$output" "FinalMask: on" "fullstack dry-run missing finalmask"
    assert_output_not_contains "$output" "reality-private-key" "fullstack dry-run leaked private key"
    after_config="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    after_state="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    [[ "$before_config" == "$after_config" ]] || fail "advanced dry-run modified config"
    [[ "$before_state" == "$after_state" ]] || fail "advanced dry-run modified state"

    before_state="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    set_advanced_vars "fullstack" "true"
    TEST_APPLY_FAIL="true"
    output="$(install_advanced_profile "fullstack" 2>&1)"
    status=$?
    TEST_APPLY_FAIL="false"
    [[ "$status" -ne 0 ]] || fail "fullstack install unexpectedly succeeded with apply failure"
    assert_output_contains "$output" "--finalmask off" "fullstack failure missing finalmask off hint"
    after_state="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    [[ "$before_state" == "$after_state" ]] || fail "fullstack failure updated state"
    cleanup_fixture
}

test_advanced_view_doctor_smoke_export() {
    local output

    setup_fixture
    install_advanced_fixture "xhttp-reality"
    install_advanced_fixture "enc-reality"
    install_advanced_fixture "fullstack" "true"

    output="$(run_view_command xhttp-reality 2>&1)"
    assert_output_contains "$output" "VLESS XHTTP + REALITY" "view xhttp-reality missing title"
    assert_output_contains "$output" "PublicKey: reality-public-key" "view xhttp-reality missing public key"
    assert_output_not_contains "$output" "reality-private-key" "view xhttp-reality leaked private key"

    output="$(run_view_command enc-reality 2>&1)"
    assert_output_contains "$output" "VLESS Encryption: client-enc-advanced" "view enc-reality missing encryption"
    assert_output_not_contains "$output" "server-dec-advanced" "view enc-reality leaked decryption"

    output="$(run_view_command fullstack 2>&1)"
    assert_output_contains "$output" "fm=" "view fullstack missing fm"
    assert_output_contains "$output" "FullStack 是最高级组合" "view fullstack missing compatibility hint"

    output="$(doctor_advanced_profile "fullstack" 2>&1)"
    assert_output_contains "$output" "inbound 协议/传输/REALITY 配置正确" "doctor fullstack missing inbound check"
    assert_output_contains "$output" "fm 参数已 URL 编码" "doctor fullstack missing fm check"
    assert_output_not_contains "$output" "server-dec-advanced" "doctor fullstack leaked decryption"
    assert_output_not_contains "$output" "reality-private-key" "doctor fullstack leaked private key"

    TEST_RESTART_COUNT=0
    output="$(smoke_advanced_profile "xhttp-reality" false 2>&1)"
    assert_output_contains "$output" "默认不自动 restart" "advanced smoke missing default restart policy"
    [[ "$TEST_RESTART_COUNT" -eq 0 ]] || fail "advanced smoke restarted without --restart"
    smoke_advanced_profile "xhttp-reality" true >/dev/null 2>&1 || true
    [[ "$TEST_RESTART_COUNT" -eq 1 ]] || fail "advanced smoke --restart did not call restart"

    output="$(render_export_clients 2>&1)"
    assert_output_contains "$output" "Xray-FullStack" "export clients missing fullstack link"
    assert_output_contains "$output" "Xray-XHTTP-Reality" "export clients missing xhttp-reality link"
    assert_output_not_contains "$output" "reality-private-key" "export clients leaked advanced private key"
    assert_output_not_contains "$output" "server-dec-advanced" "export clients leaked advanced decryption"

    output="$(render_export_report 2>&1)"
    assert_output_contains "$output" "高级协议组合摘要" "export report missing advanced summary"
    assert_output_not_contains "$output" "reality-private-key" "export report leaked advanced private key"
    assert_output_not_contains "$output" "server-dec-advanced" "export report leaked advanced decryption"

    output="$(show_help)"
    assert_output_contains "$output" "ike xhttp-reality install" "help missing xhttp-reality"
    assert_output_contains "$output" "ike enc-reality install" "help missing enc-reality"
    assert_output_contains "$output" "ike fullstack install" "help missing fullstack"
    cleanup_fixture
}

test_advanced_uninstalled_show_doctor_smoke_are_friendly() {
    local output

    setup_fixture
    output="$(print_advanced_profile_result "xhttp-reality" "show" 2>&1)" || fail "uninstalled xhttp-reality show failed"
    assert_output_contains "$output" "未安装" "xhttp-reality show was not friendly"
    output="$(doctor_advanced_profile "enc-reality" 2>&1)" || fail "uninstalled enc-reality doctor failed"
    assert_output_contains "$output" "未安装，跳过专项检查" "enc-reality doctor did not skip"
    output="$(smoke_advanced_profile "fullstack" false 2>&1)" || fail "uninstalled fullstack smoke failed"
    assert_output_contains "$output" "未安装，跳过 smoke" "fullstack smoke did not skip"
    output="$(render_export_clients 2>&1)" || fail "export clients without advanced failed"
    assert_output_not_contains "$output" "jq:" "export clients printed jq error"
    output="$(render_export_report 2>&1)" || fail "export report without advanced failed"
    assert_output_contains "$output" "XHTTP-Reality: 未安装" "export report did not mark xhttp-reality uninstalled"
    cleanup_fixture
}

test_readme_final_user_doc_guard() {
    local output

    if output="$(grep -E 'scripts/test\.sh|tests/|shellcheck|shfmt|mock|单元测试|测试覆盖|开发测试|CI|alpha|beta' "${ROOT_DIR}/README.md" 2>&1)"; then
        fail "README contains development test content: $output"
    fi
}

run_test() {
    local name="$1"
    printf 'test: %s\n' "$name"
    "$name"
}

trap cleanup_fixture EXIT

run_test test_x25519_parser_formats
run_test test_reality_generate_keys_new_xray_format
run_test test_reality_generate_keys_failure_is_redacted
run_test test_menu_order_text
run_test test_uninstall_menu_order_text
run_test test_reality_jq_write
run_test test_reality_random_port
run_test test_xhttp_finalmask_write
run_test test_finalmask_presets_custom_and_raw_json
run_test test_xhttp_finalmask_modes_and_state
run_test test_fullstack_finalmask_modes_and_state
run_test test_xhttp_path_validation
run_test test_view_outputs_new_and_old_links
run_test test_ipv6_link_scope_consistency
run_test test_migrate_infers_listen_scope
run_test test_remove_reality_and_xhttp_are_scoped
run_test test_repeat_install_does_not_duplicate
run_test test_uninstalled_show_remove_are_friendly
run_test test_dry_run_does_not_modify_files
run_test test_doctor_smoke_and_export
run_test test_show_output_compatibility_hints
run_test test_failure_hints_do_not_update_state
run_test test_advanced_profiles_write_and_links
run_test test_advanced_remove_repeat_and_dry_run
run_test test_advanced_view_doctor_smoke_export
run_test test_advanced_uninstalled_show_doctor_smoke_are_friendly
run_test test_readme_final_user_doc_guard

printf 'All Reality/XHTTP tests passed.\n'
