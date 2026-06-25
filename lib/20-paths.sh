#!/usr/bin/env bash
# Xray-OneClick path security, OS detection, and architecture helpers.

ensure_root() {
    [[ "${XRAY_ONECLICK_TEST_EUID:-$EUID}" -eq 0 ]] || die "错误：请使用 root 或 sudo 运行。"
}

check_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
    elif [[ -f "${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}" ]]; then
        # shellcheck disable=SC1090
        . "${XRAY_ONECLICK_OS_RELEASE:-/etc/os-release}"
        OS_TYPE="${ID:-linux}"
        if command -v systemctl >/dev/null 2>&1; then
            INIT_SYSTEM="systemd"
        else
            INIT_SYSTEM="unknown"
        fi
    else
        die "无法识别系统类型。"
    fi
}

detect_arch() {
    # 官方 XTLS/Xray-core 的 Linux 包是 CGO_ENABLED=0 的静态 Go 二进制，
    # 在 glibc 与 musl(Alpine) 上均可直接运行，官方并不发布单独的 -musl 包。
    # 历史上这里曾错误拼接 -musl 后缀，导致 Alpine 下载不存在的 Xray-linux-64-musl.zip 而安装失败。
    ARCH="${XRAY_ONECLICK_UNAME_M:-$(uname -m)}"
    case "$ARCH" in
        x86_64 | amd64) XRAY_ASSET="Xray-linux-64.zip" ;;
        i386 | i686) XRAY_ASSET="Xray-linux-32.zip" ;;
        aarch64 | arm64) XRAY_ASSET="Xray-linux-arm64-v8a.zip" ;;
        armv7l | armv7*) XRAY_ASSET="Xray-linux-arm32-v7a.zip" ;;
        armv6l | armv6*) XRAY_ASSET="Xray-linux-arm32-v6.zip" ;;
        armv5l | armv5*) XRAY_ASSET="Xray-linux-arm32-v5.zip" ;;
        riscv64) XRAY_ASSET="Xray-linux-riscv64.zip" ;;
        s390x) XRAY_ASSET="Xray-linux-s390x.zip" ;;
        ppc64le) XRAY_ASSET="Xray-linux-ppc64le.zip" ;;
        ppc64) XRAY_ASSET="Xray-linux-ppc64.zip" ;;
        loongarch64 | loong64) XRAY_ASSET="Xray-linux-loong64.zip" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac
}

ensure_config_security() {
    mkdir -p "$CONFIG_DIR" "$ASSET_DIR"
    chmod 700 "$CONFIG_DIR"
    [[ -f "$CONFIG_FILE" ]] && chmod 600 "$CONFIG_FILE"
    [[ -f "$STATE_FILE" ]] && chmod 600 "$STATE_FILE"
    chown root:root "$CONFIG_DIR" "$CONFIG_FILE" "$STATE_FILE" 2>/dev/null || true
}
