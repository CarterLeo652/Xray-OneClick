#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
TEST_TMP_PARENT="${REPO_ROOT}/.tmp/tests"
mkdir -p "$TEST_TMP_PARENT"
TMP_DIR="$(mktemp -d "${TEST_TMP_PARENT}/config-generation.XXXXXX")"
TEST_BIN_DIR="${TMP_DIR}/bin"
mkdir -p "$TEST_BIN_DIR"

REALITY_TAG="vless+tcp+reality"
REALITY_DEFENDER_TAG="reality-defender"
XHTTP_TAG="vless-enc-xhttp-finalmask-in"
XHTTP_REALITY_TAG="vless+xhttp+reality"
ENC_REALITY_TAG="vless+enc+reality"
FULLSTACK_TAG="vless+enc+xhttp+reality+finalmask"
ENC_FM_TAG="vless-enc-tcp-finalmask-in"
ENC_XHTTP_TAG="vless-enc-xhttp-in"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少依赖命令: $1"
}

require_cmd bash

setup_jq() {
    local jq_exe

    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    jq_exe="$(command -v jq.exe 2>/dev/null || true)"
    if [[ -n "$jq_exe" ]]; then
        cat >"${TEST_BIN_DIR}/jq" <<EOF
#!/usr/bin/env bash
args=()
for arg in "\$@"; do
    if [[ "\$arg" == /* || "\$arg" == ./* || "\$arg" == ../* ]] && [[ -e "\$arg" ]] && command -v wslpath >/dev/null 2>&1; then
        args+=("\$(wslpath -w "\$arg")")
    else
        args+=("\$arg")
    fi
done
exec "$jq_exe" "\${args[@]}"
EOF
        chmod +x "${TEST_BIN_DIR}/jq"
        export PATH="${TEST_BIN_DIR}:$PATH"
        return 0
    fi
    fail "缺少依赖命令: jq"
}

setup_jq

XRAY_TEST_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_TEST_BIN" ]]; then
    XRAY_TEST_BIN="$(command -v xray 2>/dev/null || true)"
fi

run_xray_config_test_if_available() {
    local config="$1"

    if [[ -n "$XRAY_TEST_BIN" && -x "$XRAY_TEST_BIN" ]]; then
        "$XRAY_TEST_BIN" run -test -config "$config" >/dev/null ||
            fail "xray run -test 未通过: $config"
        echo "[OK] xray run -test: $config"
    else
        echo "[SKIP] 未找到可执行 xray，跳过 xray run -test: $config"
    fi
}

run_case() {
    local name="$1"
    shift
    local case_dir="${TMP_DIR}/${name}"
    local out="${case_dir}/config.json"

    mkdir -p "$case_dir"
    echo "[CASE] $name"
    IKE_TEST_ROOT="${case_dir}/root" IKE_CONFIG_OUT="$out" bash "$INSTALL_SH" test-config-generate "$@" >/dev/null
    [[ -s "$out" ]] || fail "$name 未生成 config.json"
    jq . "$out" >/dev/null || fail "$name 生成的 JSON 无效"
    assert_no_reality_dest "$out"
    run_xray_config_test_if_available "$out"
    LAST_CONFIG="$out"
}

assert_no_reality_dest() {
    local config="$1"

    jq -e '([.. | objects | .realitySettings? | select(type == "object" and has("dest"))] | length) == 0' "$config" >/dev/null ||
        fail "新生成配置包含 realitySettings.dest: $config"
}

assert_reality_target() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      any(.inbounds[]?; .tag == $tag and ((.streamSettings.realitySettings.target // "") | length > 0))
    ' "$config" >/dev/null || fail "缺少 realitySettings.target: tag=$tag config=$config"
}

assert_reality_defender() {
    local config="$1"

    jq -e --arg tag "$REALITY_TAG" --arg defender "$REALITY_DEFENDER_TAG" --arg block "BLOCK" '
      any(.inbounds[]?; .tag == $tag) and
      any(.inbounds[]?; .tag == $defender and .listen == "127.0.0.1") and
      any(.routing.rules[]?; ((.inboundTag // []) | index($defender)) and .outboundTag == "direct") and
      any(.routing.rules[]?; ((.inboundTag // []) | index($defender)) and .outboundTag == $block)
    ' "$config" >/dev/null || fail "普通 Reality defender/routing 缺失: $config"
}

assert_no_finalmask() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      ([.inbounds[]? | select(.tag == $tag) | (.streamSettings | has("finalmask"))] | index(true) | not)
    ' "$config" >/dev/null || fail "FinalMask off 时仍写入 streamSettings.finalmask: tag=$tag config=$config"
}

assert_finalmask_balanced() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings.finalmask) as $fm |
      ($fm | type == "object") and
      ($fm.tcp | type == "array") and
      ($fm.tcp[0].type == "fragment") and
      ($fm.tcp[0].settings.packets == "tlshello") and
      ($fm.tcp[0].settings.length == "100-200") and
      ($fm.tcp[0].settings.delay == "10-20") and
      ($fm.tcp[0].settings.maxSplit == "3-6")
    ' "$config" >/dev/null || fail "FinalMask balanced 配置不合法: tag=$tag config=$config"
}

assert_finalmask_sudoku() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings.finalmask) as $fm |
      ($fm | type == "object") and
      ($fm.tcp | type == "array") and
      ($fm.tcp[0].type == "sudoku")
    ' "$config" >/dev/null || fail "FinalMask sudoku 配置不合法: tag=$tag config=$config"
}

assert_tcp_security_none() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings) as $ss |
      ($ss.network == "tcp") and ($ss.security == "none")
    ' "$config" >/dev/null || fail "ENC-FinalMask 入站 network/security 不正确: tag=$tag config=$config"
}

assert_xhttp_plain() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      (.inbounds[]? | select(.tag == $tag).streamSettings) as $ss |
      ($ss.network == "xhttp") and ($ss.security == "none") and
      ($ss.xhttpSettings | type == "object") and ($ss.xhttpSettings | has("path")) and
      (($ss | has("finalmask")) | not)
    ' "$config" >/dev/null || fail "ENC-XHTTP 入站结构不正确(应为 xhttp/none/含xhttpSettings.path/无finalmask): tag=$tag config=$config"
}

assert_fallback_limit() {
    local config="$1"
    local tag="$2"

    jq -e --arg tag "$tag" '
      .inbounds[]? |
      select(.tag == $tag).streamSettings.realitySettings |
      has("limitFallbackUpload") and has("limitFallbackDownload") and
      (.limitFallbackUpload | type == "object") and
      (.limitFallbackDownload | type == "object")
    ' "$config" >/dev/null || fail "fallback-limit conservative 未写入 limitFallbackUpload/Download: tag=$tag config=$config"
}

run_case "reality" reality --port 30004 --defender-port 40004 --sni www.microsoft.com
assert_reality_target "$LAST_CONFIG" "$REALITY_TAG"
assert_reality_defender "$LAST_CONFIG"

run_case "xhttp_off" xhttp-off --port 30005 --path /api/off
assert_no_finalmask "$LAST_CONFIG" "$XHTTP_TAG"

run_case "xhttp_balanced" xhttp-balanced --port 30005 --path /api/balanced --finalmask-preset balanced
assert_finalmask_balanced "$LAST_CONFIG" "$XHTTP_TAG"

run_case "xhttp_reality" xhttp-reality --port 30006 --path /api/xhttp-reality --sni www.microsoft.com
assert_reality_target "$LAST_CONFIG" "$XHTTP_REALITY_TAG"

run_case "enc_reality" enc-reality --port 30007 --sni www.microsoft.com
assert_reality_target "$LAST_CONFIG" "$ENC_REALITY_TAG"

run_case "fullstack_off" fullstack --port 30008 --path /api/fullstack-off --sni www.microsoft.com --finalmask off
assert_reality_target "$LAST_CONFIG" "$FULLSTACK_TAG"
assert_no_finalmask "$LAST_CONFIG" "$FULLSTACK_TAG"

run_case "fullstack_balanced" fullstack --port 30008 --path /api/fullstack-balanced --sni www.microsoft.com --finalmask on --finalmask-preset balanced
assert_reality_target "$LAST_CONFIG" "$FULLSTACK_TAG"
assert_finalmask_balanced "$LAST_CONFIG" "$FULLSTACK_TAG"

run_case "xhttp_reality_fallback_limit" xhttp-reality --port 30009 --path /api/xhttp-reality-limit --sni www.microsoft.com --fallback-limit conservative
assert_reality_target "$LAST_CONFIG" "$XHTTP_REALITY_TAG"
assert_fallback_limit "$LAST_CONFIG" "$XHTTP_REALITY_TAG"

run_case "enc_finalmask" enc-finalmask --port 30010
assert_finalmask_sudoku "$LAST_CONFIG" "$ENC_FM_TAG"
assert_tcp_security_none "$LAST_CONFIG" "$ENC_FM_TAG"

run_case "enc_xhttp" enc-xhttp --port 30011 --path /api/enc-xhttp
assert_xhttp_plain "$LAST_CONFIG" "$ENC_XHTTP_TAG"

echo "[OK] 离线配置生成测试全部通过"
