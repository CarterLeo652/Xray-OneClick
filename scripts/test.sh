#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TMP_PARENT="${ROOT_DIR}/.tmp-tests"
mkdir -p "$TMP_PARENT"
TMPDIR="$(mktemp -d "${TMP_PARENT}/run.XXXXXX")"
export TMPDIR
trap 'rm -rf "$TMPDIR"; rmdir "$TMP_PARENT" 2>/dev/null || true' EXIT

bash -n install.sh
shellcheck install.sh
shfmt -d -i 4 -ci install.sh
git diff --check -- install.sh README.md scripts/test.sh tests/test_reality_xhttp.sh tests/test_install_compat.sh
bash tests/test_forward.sh
bash tests/test_reality_xhttp.sh
bash tests/test_install_compat.sh
