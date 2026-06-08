#!/usr/bin/env bash
# Xray-OneClick terminal output helpers.

info() { echo -e "${YELLOW}$*${PLAIN}"; }
ok() { echo -e "${GREEN}$*${PLAIN}"; }
err() { echo -e "${RED}$*${PLAIN}"; }

die() {
    err "$*"
    exit 1
}
