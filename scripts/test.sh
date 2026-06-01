#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_PARENT="${ROOT_DIR}/.tmp-tests"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "${TMP_PARENT}/run.XXXXXX")"
export TMPDIR
trap 'rm -rf "$TMPDIR"; rmdir "$TMP_PARENT" 2>/dev/null || true' EXIT

SHELLCHECK_BIN="${SHELLCHECK_BIN:-$(command -v shellcheck || command -v shellcheck.exe || true)}"
SHFMT_BIN="${SHFMT_BIN:-$(command -v shfmt || command -v shfmt.exe || true)}"
GIT_BIN="${GIT_BIN:-$(command -v git || command -v git.exe || true)}"
JQ_BIN="${JQ_BIN:-$(command -v jq || true)}"
OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl || command -v openssl.exe || true)}"
JQ_NEEDS_PATH_WRAPPER="false"

if [[ -z "$SHFMT_BIN" ]]; then
    for candidate in \
        /mnt/host/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/mvdan.shfmt_Microsoft.Winget.Source_*/shfmt.exe \
        /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/mvdan.shfmt_Microsoft.Winget.Source_*/shfmt.exe; do
        if [[ -x "$candidate" ]]; then
            SHFMT_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "$GIT_BIN" ]]; then
    for candidate in \
        /mnt/host/d/Program\ Files/Git/cmd/git.exe \
        /mnt/host/d/Program\ Files/Git/bin/git.exe \
        /mnt/host/c/Program\ Files/Git/cmd/git.exe \
        /mnt/host/c/Program\ Files/Git/bin/git.exe \
        /mnt/d/Program\ Files/Git/cmd/git.exe \
        /mnt/d/Program\ Files/Git/bin/git.exe \
        /mnt/c/Program\ Files/Git/cmd/git.exe \
        /mnt/c/Program\ Files/Git/bin/git.exe; do
        if [[ -x "$candidate" ]]; then
            GIT_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "$OPENSSL_BIN" ]]; then
    for candidate in \
        /mnt/host/d/Program\ Files/Git/mingw64/bin/openssl.exe \
        /mnt/host/d/Program\ Files/Git/usr/bin/openssl.exe \
        /mnt/host/c/Program\ Files/Git/mingw64/bin/openssl.exe \
        /mnt/host/c/Program\ Files/Git/usr/bin/openssl.exe \
        /mnt/d/Program\ Files/Git/mingw64/bin/openssl.exe \
        /mnt/d/Program\ Files/Git/usr/bin/openssl.exe \
        /mnt/c/Program\ Files/Git/mingw64/bin/openssl.exe \
        /mnt/c/Program\ Files/Git/usr/bin/openssl.exe; do
        if [[ -x "$candidate" ]]; then
            OPENSSL_BIN="$candidate"
            break
        fi
    done
fi

if [[ -z "$JQ_BIN" ]]; then
    case "$(uname -m 2>/dev/null || true)" in
        x86_64 | amd64)
            JQ_DOWNLOAD_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
            ;;
        aarch64 | arm64)
            JQ_DOWNLOAD_URL="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-arm64"
            ;;
        *)
            JQ_DOWNLOAD_URL=""
            ;;
    esac
    if [[ -n "$JQ_DOWNLOAD_URL" ]] && command -v wget >/dev/null 2>&1; then
        JQ_BIN="${TMPDIR}/jq"
        if ! wget -q -O "$JQ_BIN" "$JQ_DOWNLOAD_URL"; then
            rm -f "$JQ_BIN"
            JQ_BIN=""
        elif ! chmod +x "$JQ_BIN"; then
            rm -f "$JQ_BIN"
            JQ_BIN=""
        fi
    fi
fi

if [[ -z "$JQ_BIN" ]]; then
    for candidate in \
        /mnt/host/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_Microsoft.Winget.Source_*/jq.exe \
        /mnt/c/Users/*/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_Microsoft.Winget.Source_*/jq.exe; do
        if [[ -x "$candidate" ]]; then
            JQ_BIN="$candidate"
            JQ_NEEDS_PATH_WRAPPER="true"
            break
        fi
    done
fi

if ! command -v jq >/dev/null 2>&1 && [[ -n "$JQ_BIN" ]]; then
    TOOL_BIN="${TMPDIR}/bin"
    mkdir -p "$TOOL_BIN"
    if [[ "$JQ_NEEDS_PATH_WRAPPER" != "true" ]]; then
        ln -sf "$JQ_BIN" "${TOOL_BIN}/jq"
    else
        cat >"${TOOL_BIN}/jq" <<EOF
#!/usr/bin/env bash
jq_bin='${JQ_BIN}'
args=()
for arg in "\$@"; do
    case "\$arg" in
        /mnt/host/[A-Za-z]/*)
            drive_path="\${arg#/mnt/host/}"
            drive="\${drive_path%%/*}"
            rest="\${drive_path#*/}"
            args+=("\${drive^^}:/\${rest}")
            ;;
        /mnt/[A-Za-z]/*)
            drive_path="\${arg#/mnt/}"
            drive="\${drive_path%%/*}"
            rest="\${drive_path#*/}"
            args+=("\${drive^^}:/\${rest}")
            ;;
        *)
            args+=("\$arg")
            ;;
    esac
done
exec "\$jq_bin" "\${args[@]}"
EOF
        chmod +x "${TOOL_BIN}/jq"
    fi
    PATH="${TOOL_BIN}:${PATH}"
    export PATH
fi

if ! command -v openssl >/dev/null 2>&1 && [[ -n "$OPENSSL_BIN" ]]; then
    TOOL_BIN="${TOOL_BIN:-${TMPDIR}/bin}"
    mkdir -p "$TOOL_BIN"
    OPENSSL_FALLBACK_BIN="$OPENSSL_BIN"
    export OPENSSL_FALLBACK_BIN
    cat >"${TOOL_BIN}/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "rand" ]]; then
    shift
    case "${1:-}" in
        -hex)
            bytes="${2:-}"
            [[ "$bytes" =~ ^[0-9]+$ ]] || exit 1
            head -c "$bytes" /dev/urandom | od -An -tx1 -v | tr -d ' \n'
            printf '\n'
            exit 0
            ;;
        -base64)
            bytes="${2:-}"
            [[ "$bytes" =~ ^[0-9]+$ ]] || exit 1
            head -c "$bytes" /dev/urandom | base64 | tr -d '\n'
            printf '\n'
            exit 0
            ;;
    esac
fi

if [[ -n "${OPENSSL_FALLBACK_BIN:-}" ]]; then
    exec "$OPENSSL_FALLBACK_BIN" "$@"
fi

echo "openssl fallback only supports rand -hex/-base64" >&2
exit 127
EOF
    chmod +x "${TOOL_BIN}/openssl"
    PATH="${TOOL_BIN}:${PATH}"
    export PATH
fi

[[ -n "$SHELLCHECK_BIN" ]] || {
    echo "shellcheck not found" >&2
    exit 127
}
[[ -n "$SHFMT_BIN" ]] || {
    echo "shfmt not found" >&2
    exit 127
}
[[ -n "$GIT_BIN" ]] || {
    echo "git not found" >&2
    exit 127
}
[[ -n "$JQ_BIN" ]] || {
    echo "jq not found" >&2
    exit 127
}
[[ -n "$OPENSSL_BIN" ]] || {
    echo "openssl not found" >&2
    exit 127
}

bash -n install.sh
"$SHELLCHECK_BIN" install.sh
"$SHFMT_BIN" -d -i 4 -ci install.sh
"$GIT_BIN" diff --check -- install.sh README.md scripts/test.sh tests/test_reality_xhttp.sh tests/test_install_compat.sh
bash tests/test_forward.sh
bash tests/test_reality_xhttp.sh
bash tests/test_install_compat.sh
