#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../install.sh
# shellcheck disable=SC1091
source "${ROOT_DIR}/install.sh"

TEST_TMP=""
TEST_ROOT="${ROOT_DIR}/.tmp-tests"
MOCK_BIN=""

info() { :; }
ok() { :; }
err() { printf '%s\n' "$*" >&2; }
enable_bbr() { :; }
install_dependencies() { :; }
detect_arch() {
    ARCH="${XRAY_ONECLICK_UNAME_M:-x86_64}"
    XRAY_ASSET="Xray-linux-64.zip"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    cleanup_fixture
    exit 1
}

assert_contains() {
    local output="$1"
    local needle="$2"
    local message="$3"
    [[ "$output" == *"$needle"* ]] || fail "$message"
}

assert_not_contains() {
    local output="$1"
    local needle="$2"
    local message="$3"
    [[ "$output" != *"$needle"* ]] || fail "$message"
}

assert_exists() {
    [[ -e "$1" ]] || fail "missing expected path: $1"
}

assert_not_exists() {
    [[ ! -e "$1" ]] || fail "unexpected path exists: $1"
}

cleanup_fixture() {
    [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
    rmdir "$TEST_ROOT" 2>/dev/null || true
    TEST_TMP=""
}

write_mock() {
    local name="$1"
    local body="$2"
    printf '%s\n' "$body" >"${MOCK_BIN}/${name}"
    chmod +x "${MOCK_BIN}/${name}"
}

setup_fixture() {
    cleanup_fixture
    mkdir -p "$TEST_ROOT"
    TEST_TMP="$(mktemp -d "${TEST_ROOT}/install-compat.XXXXXX")"
    MOCK_BIN="${TEST_TMP}/bin"
    mkdir -p "$MOCK_BIN" "${TEST_TMP}/etc-xray" "${TEST_TMP}/share" "${TEST_TMP}/systemd" "${TEST_TMP}/logs" "${TEST_TMP}/installer"
    PATH="${MOCK_BIN}:$PATH"
    export PATH

    CONFIG_DIR="${TEST_TMP}/etc-xray"
    CONFIG_FILE="${CONFIG_DIR}/config.json"
    STATE_FILE="${CONFIG_DIR}/installer-state.json"
    ASSET_DIR="${TEST_TMP}/share"
    BIN_PATH="${TEST_TMP}/xray"
    SHORTCUT_PATH="${TEST_TMP}/ike"
    LEGACY_SHORTCUT_PATH="${TEST_TMP}/sb"
    INSTALLER_DIR="${TEST_TMP}/installer"
    INSTALLER_PATH="${INSTALLER_DIR}/install.sh"
    XRAY_SERVICE_FILE="${TEST_TMP}/systemd/xray.service"
    XRAY_LOG_DIR="${TEST_TMP}/logs"
    XRAY_PURGE_BACKUP_DIR="${TEST_TMP}/backups"
    XRAY_ONECLICK_SYSTEMD_DIR="${TEST_TMP}/run-systemd"
    XRAY_ONECLICK_ALLOW_FAKE_SYSTEMD="true"
    XRAY_ONECLICK_TEST_EUID="0"
    XRAY_ONECLICK_DISK_FREE_KB="409600"
    XRAY_ONECLICK_UNAME_M="x86_64"
    INIT_SYSTEM="systemd"
    OS_TYPE="debian"
    ARCH="x86_64"
    XRAY_ASSET="Xray-linux-64.zip"

    mkdir -p "$XRAY_ONECLICK_SYSTEMD_DIR"
    cat >"${TEST_TMP}/os-release" <<'EOF'
ID=debian
VERSION_ID="12"
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
EOF
    XRAY_ONECLICK_OS_RELEASE="${TEST_TMP}/os-release"

    cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "ss2022-in", "protocol": "shadowsocks", "port": 10001, "settings": {"method": "2022-blake3-aes-128-gcm", "password": "ss-pass"}}
  ],
  "outbounds": [{"tag": "direct", "protocol": "freedom"}],
  "routing": {"rules": []}
}
JSON
    echo '{}' >"$STATE_FILE"

    write_mock systemctl '#!/usr/bin/env bash
echo "systemctl $*" >>"'"${TEST_TMP}"'/systemctl.log"
if [[ "${SYSTEMCTL_FAIL_RESTART:-false}" == "true" && "$1" == "restart" ]]; then exit 1; fi
if [[ "$1" == "is-active" ]]; then exit 0; fi
exit 0'
    write_mock journalctl '#!/usr/bin/env bash
echo "mock journal output privateKey=journal-private decryption=journal-dec password=journal-pass"'
    write_mock ss '#!/usr/bin/env bash
exit 1'
    write_mock curl '#!/usr/bin/env bash
out=""
url=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$arg"; prev=""; continue; fi
  if [[ "$arg" == "-o" ]]; then prev="-o"; continue; fi
  [[ "$arg" == http* ]] && url="$arg"
done
echo "$url" >>"'"${TEST_TMP}"'/curl.urls"
if [[ "$url" == https://github.com/* && "${CURL_FAIL_ORIGINAL:-false}" == "true" ]]; then exit 22; fi
printf "fake zip" >"$out"'
    write_mock wget '#!/usr/bin/env bash
exit 1'
    write_mock unzip '#!/usr/bin/env bash
if [[ "$1" == "-t" ]]; then
  [[ "${UNZIP_FAIL_TEST:-false}" == "true" ]] && exit 1
  exit 0
fi
dest=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-d" ]]; then dest="$arg"; prev=""; continue; fi
  if [[ "$arg" == "-d" ]]; then prev="-d"; fi
done
mkdir -p "$dest"
cat >"$dest/xray" <<'"'"'XRAY'"'"'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then echo "Xray 25.1.1"; exit 0; fi
if [[ "$1" == "run" && "$2" == "-test" ]]; then
  [[ "${XRAY_TEST_FAIL:-false}" == "true" ]] && exit 1
  exit 0
fi
exit 0
XRAY
chmod +x "$dest/xray"'
}

test_preflight_matrix() {
    local output

    setup_fixture
    output="$(preflight_system 2>&1)" || fail "preflight should pass"
    assert_contains "$output" "root 权限" "preflight root missing"
    assert_contains "$output" "Debian" "preflight os missing"
    assert_contains "$output" "systemd 可用" "preflight systemd missing"
    assert_contains "$output" "amd64" "preflight arch missing"

    XRAY_ONECLICK_TEST_EUID="1000"
    output="$(preflight_system 2>&1)"
    assert_contains "$output" "请使用 root 或 sudo" "preflight non-root missing"
    XRAY_ONECLICK_TEST_EUID="0"

    XRAY_ONECLICK_SYSTEMD_DIR="${TEST_TMP}/missing-systemd"
    output="$(preflight_system 2>&1)"
    assert_contains "$output" "未检测到 systemd" "preflight missing systemd not reported"
    XRAY_ONECLICK_SYSTEMD_DIR="${TEST_TMP}/run-systemd"

    XRAY_ONECLICK_DISK_FREE_KB="1024"
    output="$(preflight_system 2>&1)"
    assert_contains "$output" "可用空间不足" "preflight disk low not reported"
    cleanup_fixture
}

test_download_mirror_and_upgrade() {
    local output old_hash new_hash

    setup_fixture
    XRAY_GITHUB_MIRRORS="https://mirror.example/"
    CURL_FAIL_ORIGINAL="true"
    export XRAY_GITHUB_MIRRORS CURL_FAIL_ORIGINAL
    download_xray_core "v25.1.1" "${TEST_TMP}/download" || fail "download with mirror failed"
    assert_contains "$(cat "${TEST_TMP}/curl.urls")" "https://github.com/XTLS" "original url not attempted"
    assert_contains "$(cat "${TEST_TMP}/curl.urls")" "https://mirror.example/https://github.com/XTLS" "mirror url not attempted"
    assert_contains "$(cat "${TEST_TMP}/curl.urls")" "/v25.1.1/Xray-linux-64.zip" "specified version URL not used"

    UNZIP_FAIL_TEST="true"
    export UNZIP_FAIL_TEST
    if download_xray_core "v25.1.1" "${TEST_TMP}/download-unzip-fail" >/dev/null 2>&1; then
        fail "download should fail when unzip -t fails"
    fi
    UNZIP_FAIL_TEST="false"

    printf '#!/usr/bin/env bash\necho old-xray\n' >"$BIN_PATH"
    chmod +x "$BIN_PATH"
    old_hash="$(sha256sum "$BIN_PATH" | awk '{print $1}')"
    output="$(upgrade_xray_core "v25.1.1" "true" "false" 2>&1)" || fail "xray upgrade dry-run failed"
    assert_contains "$output" "dry-run" "upgrade dry-run output missing"
    new_hash="$(sha256sum "$BIN_PATH" | awk '{print $1}')"
    [[ "$old_hash" == "$new_hash" ]] || fail "xray upgrade dry-run modified binary"

    XRAY_TEST_FAIL="true"
    export XRAY_TEST_FAIL
    if upgrade_xray_core "v25.1.1" "false" "false" >/dev/null 2>&1; then
        fail "xray upgrade should fail when config test fails"
    fi
    new_hash="$(sha256sum "$BIN_PATH" | awk '{print $1}')"
    [[ "$old_hash" == "$new_hash" ]] || fail "xray upgrade did not roll back binary"
    cleanup_fixture
}

test_service_management() {
    local output

    setup_fixture
    ensure_xray_service true || fail "service install failed"
    grep -q "ExecStart=$BIN_PATH run -c $CONFIG_FILE" "$XRAY_SERVICE_FILE" || fail "service ExecStart missing"

    printf '[Service]\nExecStart=/other\n' >"$XRAY_SERVICE_FILE"
    if write_xray_service "$XRAY_SERVICE_FILE" false >/dev/null 2>&1; then
        fail "non-project service was overwritten without yes"
    fi
    grep -q "ExecStart=/other" "$XRAY_SERVICE_FILE" || fail "non-project service changed"

    SYSTEMCTL_FAIL_RESTART="true"
    export SYSTEMCTL_FAIL_RESTART
    output="$(restart_xray_service 2>&1)"
    assert_contains "$output" "mock journal output" "restart failure did not show journal"
    assert_not_contains "$output" "journal-private" "restart logs leaked private key"
    assert_not_contains "$output" "journal-dec" "restart logs leaked decryption"
    assert_contains "$(cat "${TEST_TMP}/systemctl.log")" "systemctl daemon-reload" "restart did not daemon-reload"
    SYSTEMCTL_FAIL_RESTART="false"
    run_service_command repair --yes >/dev/null || fail "service repair failed"
    cleanup_fixture
}

test_migrate_and_alias() {
    local before after output

    setup_fixture
    cat >"$STATE_FILE" <<'JSON'
{
  "vless_reality": {
    "port": 30004,
    "defender_port": 40004,
    "uuid": "22222222-2222-4222-8222-222222222222",
    "private_key": "reality-private-key",
    "public_key": "reality-public-key",
    "default_short_id": "aa",
    "server_name": "www.abmindustriesgroup.com",
    "spider_x": "/"
  },
  "vless_xhttp_finalmask": {
    "port": 30005,
    "path": "/api/test",
    "uuid": "33333333-3333-4333-8333-333333333333",
    "encryption": "client-enc-xhttp"
  }
}
JSON
    cat >"$CONFIG_FILE" <<'JSON'
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "ss2022-in", "protocol": "shadowsocks", "port": 10001, "settings": {"method": "2022-blake3-aes-128-gcm", "password": "ss-pass"}},
    {"tag":"vless+tcp+reality","protocol":"vless","port":30004,"settings":{"clients":[{"id":"22222222-2222-4222-8222-222222222222","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"privateKey":"reality-private-key","serverNames":["www.abmindustriesgroup.com"],"shortIds":["aa"]}}},
    {"tag":"vless-enc-xhttp-finalmask-in","protocol":"vless","port":30005,"settings":{"decryption":"server-dec-xhttp"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"/api/test"}}}
  ],
  "outbounds": [{"tag":"direct","protocol":"freedom"}],
  "routing": {"rules": []}
}
JSON
    before="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    output="$(run_migrate_command --dry-run 2>&1)" || fail "migrate dry-run failed"
    assert_contains "$output" "dry-run" "migrate dry-run output missing"
    after="$(sha256sum "$STATE_FILE" | awk '{print $1}')"
    [[ "$before" == "$after" ]] || fail "migrate dry-run modified state"

    run_migrate_command >/dev/null || fail "migrate failed"
    jq -e '.vless_reality.flow == "xtls-rprx-vision" and (.vless_reality.link | startswith("vless://")) and .vless_xhttp_finalmask.finalmask_enabled == false and (.vless_xhttp_finalmask.link | startswith("vless://"))' "$STATE_FILE" >/dev/null || fail "migrate did not fill state fields"

    output="$(show_help)"
    assert_contains "$output" "ike preflight" "help missing preflight"
    assert_contains "$output" "ike xray" "help missing xray"
    assert_contains "$output" "ike migrate" "help missing migrate"
    assert_contains "$output" "ike fullstack install" "help missing fullstack"
    output="$(show_version)"
    assert_contains "$output" "1.1.4" "version output mismatch"
    cat >"$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "version" ]]; then
  echo "Xray 26.3.27"
  echo "unknown"
  exit 0
fi
exit 0
EOF
    chmod +x "$BIN_PATH"
    output="$(show_version)"
    assert_contains "$output" "Xray: 26.3.27" "version parser did not keep clean version"
    assert_not_contains "$output" "unknown" "version output leaked bare unknown"
    if main does-not-exist >/dev/null 2>"${TEST_TMP}/unknown.err"; then
        fail "unknown command should fail"
    fi
    assert_contains "$(cat "${TEST_TMP}/unknown.err")" "未知命令" "unknown command missing error"

    install_shortcut
    install_shortcut
    assert_exists "$SHORTCUT_PATH"
    assert_exists "$LEGACY_SHORTCUT_PATH"
    cleanup_fixture
}

test_migrate_uninferable_warning() {
    local output

    setup_fixture
    cat >"$STATE_FILE" <<'JSON'
{
  "vless_reality": {
    "port": 30004,
    "uuid": "22222222-2222-4222-8222-222222222222",
    "public_key": "reality-public-key",
    "default_short_id": "aa",
    "server_name": "www.abmindustriesgroup.com"
  }
}
JSON
    output="$(run_migrate_command 2>&1)" || fail "migrate with missing flow should not fail"
    assert_contains "$output" "将补齐 vless_reality.flow=xtls-rprx-vision" "migrate missing reality flow fill message"
    jq -e '.vless_reality.flow == "xtls-rprx-vision"' "$STATE_FILE" >/dev/null || fail "migrate did not fill reality flow default"
    cleanup_fixture
}

test_uninstall_modes() {
    setup_fixture
    printf '#!/usr/bin/env bash\n' >"$BIN_PATH"
    printf '#!/usr/bin/env bash\n' >"$SHORTCUT_PATH"
    printf '#!/usr/bin/env bash\n' >"$LEGACY_SHORTCUT_PATH"
    printf '#!/usr/bin/env bash\n' >"$INSTALLER_PATH"
    write_xray_service "$XRAY_SERVICE_FILE" true || fail "service write failed"

    run_uninstall_command --dry-run >/dev/null || fail "uninstall dry-run failed"
    assert_exists "$BIN_PATH"
    assert_exists "$CONFIG_FILE"

    run_uninstall_command --keep-config >/dev/null || fail "uninstall keep-config failed"
    assert_not_exists "$BIN_PATH"
    assert_exists "$CONFIG_FILE"
    assert_exists "$STATE_FILE"

    printf '#!/usr/bin/env bash\n' >"$BIN_PATH"
    chmod +x "$BIN_PATH"
    if run_uninstall_command --purge >/dev/null 2>&1; then
        fail "purge without yes should fail"
    fi
    run_uninstall_command --purge --yes >/dev/null || fail "purge with yes failed"
    compgen -G "${XRAY_PURGE_BACKUP_DIR}/xray-oneclick-purge-*.tar.gz" >/dev/null || fail "purge backup not created"
    assert_not_exists "$CONFIG_DIR"
    cleanup_fixture
}

test_export_redaction_still_holds() {
    local output

    setup_fixture
    cat >"$CONFIG_FILE" <<'JSON'
{
  "inbounds": [
    {"tag":"vless+tcp+reality","protocol":"vless","port":30004,"settings":{"clients":[{"id":"u","flow":"xtls-rprx-vision"}],"decryption":"server-secret"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"privateKey":"reality-private-key","serverNames":["www.abmindustriesgroup.com"],"shortIds":["aa"]}}},
    {"tag":"vless-enc-xhttp-finalmask-in","protocol":"vless","port":30005,"settings":{"decryption":"server-dec-xhttp"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"/api/test"}}}
  ],
  "outbounds": [{"tag":"direct","protocol":"freedom"}]
}
JSON
    cat >"$STATE_FILE" <<'JSON'
{
  "vless_reality": {"public_key":"reality-public-key","default_short_id":"aa","link":"vless://u@example"},
  "vless_xhttp_finalmask": {"finalmask_enabled": false, "link": "vless://x@example"}
}
JSON
    output="$(render_export_report)"
    assert_not_contains "$output" "reality-private-key" "export report leaked private key"
    assert_not_contains "$output" "server-dec-xhttp" "export report leaked decryption"
    assert_not_contains "$output" "journal-private" "export report leaked journal private key"
    assert_not_contains "$output" "journal-dec" "export report leaked journal decryption"
    cleanup_fixture
}

run_test() {
    local name="$1"
    printf 'test: %s\n' "$name"
    "$name"
}

trap cleanup_fixture EXIT

run_test test_preflight_matrix
run_test test_download_mirror_and_upgrade
run_test test_service_management
run_test test_migrate_and_alias
run_test test_migrate_uninferable_warning
run_test test_uninstall_modes
run_test test_export_redaction_still_holds

printf 'All install compatibility tests passed.\n'
