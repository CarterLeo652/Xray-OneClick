#!/usr/bin/env bash
# One-line installer: curl -fsSL .../scripts/bootstrap.sh | sudo bash
# Optional: XRAY_ONECLICK_REF=main  XRAY_ONECLICK_NO_MENU=1  (skip interactive menu after install)
set -euo pipefail

REPO="${XRAY_ONECLICK_REPO:-ike-sh/Xray-OneClick}"
REF="${XRAY_ONECLICK_REF:-main}"
TS="$(date +%s)"

fetch_install_sh() {
    local dest="$1"
    if curl -fsSL -H "Accept: application/vnd.github.raw+json" \
        -o "$dest" "https://api.github.com/repos/${REPO}/contents/install.sh?ref=${REF}" 2>/dev/null; then
        return 0
    fi
    curl -fsSL -o "$dest" "https://raw.githubusercontent.com/${REPO}/${REF}/install.sh?ts=${TS}"
}

tmp="$(mktemp /tmp/xray-oneclick-install.XXXXXX)"
trap 'rm -f -- "$tmp"' EXIT

echo "[INFO] 下载 ${REPO} ${REF}（install.sh，GitHub API 优先）..."
fetch_install_sh "$tmp"
chmod +x "$tmp"
# 版本号唯一来源是 lib/01-constants.sh；此处仅作信息展示，提取失败绝不能中断安装
remote_ver="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" 2>/dev/null | sed -E 's/^SCRIPT_VERSION="([^"]+)".*/\1/')" || remote_ver=""
if [[ -z "$remote_ver" ]]; then
    remote_ver="$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/${REF}/lib/01-constants.sh?ts=${TS}" 2>/dev/null | grep -m1 '^SCRIPT_VERSION=' | sed -E 's/^SCRIPT_VERSION="([^"]+)".*/\1/')" || remote_ver=""
fi
[[ -n "$remote_ver" ]] && echo "[INFO] 远端版本：${remote_ver}"

if [[ "$(id -u)" -eq 0 ]]; then
    bash "$tmp" "$@"
    exit $?
fi

echo "[INFO] 非 root：仅下载 install.sh 到当前目录"
install -m 0755 "$tmp" ./install.sh
echo "[OK] 已保存 ./install.sh（${remote_ver:-未知版本}）"
echo "请运行：sudo bash install.sh"
