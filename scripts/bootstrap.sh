#!/bin/sh
# One-line installer (POSIX sh, 兼容 Alpine busybox / Debian / Ubuntu / RHEL 系):
#   curl -fsSL .../scripts/bootstrap.sh | sh
#   wget -qO- .../scripts/bootstrap.sh | sh
# 说明：本脚本刻意使用 POSIX sh，因为全新 Alpine 默认没有 bash，也没有 sudo。
#       它会在需要时自动 `apk add bash`，再用 bash 运行 install.sh。
# Optional: XRAY_ONECLICK_REF=main  XRAY_ONECLICK_NO_MENU=1  (skip interactive menu after install)
set -eu

REPO="${XRAY_ONECLICK_REPO:-ike-sh/Xray-OneClick}"
REF="${XRAY_ONECLICK_REF:-main}"
TS="$(date +%s 2>/dev/null || echo 0)"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
errx() { echo "[ERR] $*" >&2; exit 1; }

is_alpine() { [ -f /etc/alpine-release ]; }

# 下载帮助：优先 curl，其次 wget（busybox wget 也可）
dl() { # url dest
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        return 127
    fi
}

# 确保有下载工具；Alpine 上缺失则尝试 apk add（busybox 通常自带 wget）
ensure_downloader() {
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        return 0
    fi
    if is_alpine && command -v apk >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
        log "Alpine 缺少下载工具，正在 apk add curl ..."
        apk add --no-cache curl ca-certificates >/dev/null 2>&1 || true
    fi
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
        errx "需要 curl 或 wget 才能下载，请先安装其中之一。"
}

# install.sh 与所有 lib/*.sh 都是 bash 脚本；全新 Alpine 默认没有 bash，这里负责补齐。
ensure_bash() {
    command -v bash >/dev/null 2>&1 && return 0
    if is_alpine && command -v apk >/dev/null 2>&1; then
        [ "$(id -u)" -eq 0 ] || errx "Alpine 缺少 bash，请以 root 运行本脚本以便自动安装。"
        log "Alpine 检测到缺少 bash，正在 apk add bash ..."
        apk add --no-cache bash >/dev/null 2>&1 || errx "apk add bash 失败，请手动执行：apk add bash"
    fi
    command -v bash >/dev/null 2>&1 || \
        errx "未找到 bash，请先安装 bash（Debian/Ubuntu: apt-get install -y bash；RHEL: dnf install -y bash）。"
}

fetch_install_sh() {
    dest="$1"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsSL -H "Accept: application/vnd.github.raw+json" \
            -o "$dest" "https://api.github.com/repos/${REPO}/contents/install.sh?ref=${REF}" 2>/dev/null; then
            [ -s "$dest" ] && return 0
        fi
    fi
    dl "https://raw.githubusercontent.com/${REPO}/${REF}/install.sh?ts=${TS}" "$dest"
}

ensure_downloader

tmp="$(mktemp /tmp/xray-oneclick-install.XXXXXX 2>/dev/null || mktemp)"
trap 'rm -f -- "$tmp"' EXIT INT TERM

log "下载 ${REPO} ${REF}（install.sh，GitHub API 优先）..."
fetch_install_sh "$tmp" || errx "下载 install.sh 失败，请检查网络或设置 XRAY_ONECLICK_REPO/REF。"
[ -s "$tmp" ] || errx "下载到的 install.sh 为空。"
chmod +x "$tmp" 2>/dev/null || true

# 版本号唯一来源是 lib/01-constants.sh；此处仅作信息展示，提取失败绝不能中断安装
remote_ver="$(grep -m1 '^SCRIPT_VERSION=' "$tmp" 2>/dev/null | sed -E 's/^SCRIPT_VERSION="([^"]+)".*/\1/')" || remote_ver=""
if [ -z "$remote_ver" ]; then
    cver="$(mktemp 2>/dev/null || echo /tmp/ike-cver.$$)"
    if dl "https://raw.githubusercontent.com/${REPO}/${REF}/lib/01-constants.sh?ts=${TS}" "$cver" 2>/dev/null; then
        remote_ver="$(grep -m1 '^SCRIPT_VERSION=' "$cver" 2>/dev/null | sed -E 's/^SCRIPT_VERSION="([^"]+)".*/\1/')" || remote_ver=""
    fi
    rm -f "$cver" 2>/dev/null || true
fi
[ -n "$remote_ver" ] && log "远端版本：${remote_ver}"

if [ "$(id -u)" -eq 0 ]; then
    ensure_bash
    bash -n "$tmp" || errx "下载的 install.sh 语法校验失败。"
    IKE_LIB_RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}/lib"
    XRAY_ONECLICK_REPO="$REPO"
    XRAY_ONECLICK_REF="$REF"
    export IKE_LIB_RAW_BASE XRAY_ONECLICK_REPO XRAY_ONECLICK_REF
    bash "$tmp" "$@"
    exit $?
fi

if command -v bash >/dev/null 2>&1; then
    bash -n "$tmp" || errx "下载的 install.sh 语法校验失败。"
fi

# 非 root：不强依赖 sudo（Alpine 默认无 sudo），仅下载到当前目录并给出提示
log "非 root：仅下载 install.sh 到当前目录"
install -m 0755 "$tmp" ./install.sh 2>/dev/null || { cp "$tmp" ./install.sh && chmod 0755 ./install.sh; }
echo "[OK] 已保存 ./install.sh（${remote_ver:-未知版本}）"
if command -v sudo >/dev/null 2>&1; then
    echo "请以 root 运行：sudo XRAY_ONECLICK_REPO='$REPO' XRAY_ONECLICK_REF='$REF' bash install.sh"
elif command -v doas >/dev/null 2>&1; then
    echo "请以 root 运行：doas env XRAY_ONECLICK_REPO='$REPO' XRAY_ONECLICK_REF='$REF' bash install.sh"
else
    echo "请切换到 root 后运行：XRAY_ONECLICK_REPO='$REPO' XRAY_ONECLICK_REF='$REF' bash install.sh"
fi
