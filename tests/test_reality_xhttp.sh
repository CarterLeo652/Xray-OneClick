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
}

install_xhttp_fixture() {
    set_xhttp_vars "${1:-true}"
    install_vless_xhttp_finalmask >/dev/null || fail "xhttp install failed"
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
    assert_output_contains "$output" "7. 安装 SOCKS5 代理" "menu missing SOCKS5 at option 7"
    assert_output_not_contains "$output" "14. 安装 VLESS TCP REALITY" "menu still has Reality at option 14"
    assert_output_not_contains "$output" "15. 安装 VLESS Encryption + XHTTP + FinalMask" "menu still has XHTTP at option 15"
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

test_remove_reality_and_xhttp_are_scoped() {
    setup_fixture
    install_reality_fixture
    install_xhttp_fixture "true"

    remove_reality_config >/dev/null || fail "reality remove failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless+tcp+reality" or .tag == "reality-defender")] | length) == 0' "reality inbounds remained"
    assert_jq "$CONFIG_FILE" '([.routing.rules[]? | select(((.inboundTag // []) | index("reality-defender")) != null)] | length) == 0' "reality routing remained"
    assert_jq "$STATE_FILE" 'has("vless_reality") | not' "reality state remained"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in") and any(.inbounds[]?; .tag == "tunnel-31000-443") and any(.inbounds[]?; .tag == "vless-enc-xhttp-finalmask-in")' "reality remove affected other protocols"
    assert_jq "$CONFIG_FILE" 'any(.routing.rules[]?; ((.inboundTag // []) | index("tunnel-31000-443")) != null)' "reality remove affected tunnel routing"

    install_reality_fixture
    remove_vless_xhttp_finalmask_config >/dev/null || fail "xhttp remove failed"
    assert_jq "$CONFIG_FILE" '([.inbounds[]? | select(.tag == "vless-enc-xhttp-finalmask-in")] | length) == 0' "xhttp inbound remained"
    assert_jq "$STATE_FILE" 'has("vless_xhttp_finalmask") | not' "xhttp state remained"
    assert_jq "$CONFIG_FILE" 'any(.inbounds[]?; .tag == "ss2022-in") and any(.inbounds[]?; .tag == "vless-enc-in") and any(.inbounds[]?; .tag == "socks-in") and any(.inbounds[]?; .tag == "tunnel-31000-443") and any(.inbounds[]?; .tag == "vless+tcp+reality") and any(.inbounds[]?; .tag == "reality-defender")' "xhttp remove affected other protocols"
    assert_jq "$STATE_FILE" 'has("vless_reality")' "xhttp remove affected reality state"
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
run_test test_reality_jq_write
run_test test_reality_random_port
run_test test_xhttp_finalmask_write
run_test test_xhttp_path_validation
run_test test_view_outputs_new_and_old_links
run_test test_remove_reality_and_xhttp_are_scoped
run_test test_repeat_install_does_not_duplicate
run_test test_uninstalled_show_remove_are_friendly
run_test test_dry_run_does_not_modify_files
run_test test_doctor_smoke_and_export
run_test test_show_output_compatibility_hints
run_test test_failure_hints_do_not_update_state

printf 'All Reality/XHTTP tests passed.\n'
