#!/usr/bin/env bash
# Diagnostic output helpers.

diag_ok() { echo "[✓] $*"; }
diag_warn() { echo "[!] $*"; }
diag_fail() { echo "[✗] $*"; }
diag_info() { echo "[i] $*"; }

redact_sensitive_stream() {
    sed -E \
        -e 's/("(privateKey|private_key|decryption|password|pass|token|secret|auth|id|uuid|shortIds|short_ids)"[[:space:]]*:[[:space:]]*")[^"]*/\1***REDACTED***/Ig' \
        -e 's/((privateKey|private_key|decryption|password|pass|token|secret|auth|uuid|shortIds|short_ids|method secret)[[:space:]]*[=:][[:space:]]*)[^[:space:],;]+/\1***REDACTED***/Ig' \
        -e 's#(vless|hysteria2|hy2|ss|socks)://[^[:space:]]+#\1://***REDACTED***#Ig'
}

inbound_exists() {
    local tag="$1"
    [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1 &&
        jq -e --arg tag "$tag" 'any(.inbounds[]?; .tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1
}

port_listening() {
    local port="$1"

    command -v ss >/dev/null 2>&1 || return 2
    ss -tulpn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]"
}

port_listening_localhost() {
    local port="$1"

    command -v ss >/dev/null 2>&1 || return 2
    ss -tulpn 2>/dev/null | grep -qE "(127\.0\.0\.1|::1|\[::1\])[:.]${port}[[:space:]]"
}
