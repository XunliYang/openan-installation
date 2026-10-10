#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# OpenAN offline uninstaller (Docker Compose).
#
#   scripts/uninstall.sh                  # ask before deleting data
#   scripts/uninstall.sh --yes            # keep data, no prompts

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$BUNDLE_DIR/compose"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE=""
ASSUME_YES="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES="true"; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done
export ASSUME_YES

[ -z "$CONFIG_FILE" ] && [ -r "$BUNDLE_DIR/config.env" ] && CONFIG_FILE="$BUNDLE_DIR/config.env"
[ -n "$CONFIG_FILE" ] && load_config "$CONFIG_FILE"

log_step "Removing OpenAN (compose)"

if have docker && docker compose version >/dev/null 2>&1; then
    if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
        (cd "$COMPOSE_DIR" && docker compose down --remove-orphans) || log_warn "docker compose down reported an error"
    else
        log_warn "compose/docker-compose.yml not found"
    fi
else
    log_warn "docker compose not available — skipping container shutdown"
fi

if ask_yes_no "Delete persistent data ($COMPOSE_DIR/data)?" "no"; then
    rm -rf "$COMPOSE_DIR/data"
    log_info "Data removed"
else
    log_info "Data preserved at $COMPOSE_DIR/data"
fi

log_info "Images were not removed. Remove them manually with 'docker rmi' if desired."
log_info "Done."
