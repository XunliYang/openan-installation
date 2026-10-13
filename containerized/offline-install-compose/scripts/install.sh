#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# Explicit, repeatable installation; no prompts, shell-evaluated config or pulls.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
CONFIG_FILE="$BUNDLE_DIR/config.env"
while [ $# -gt 0 ]; do
    case "$1" in --config) [ $# -ge 2 ] || exit 2; CONFIG_FILE="$2"; shift 2 ;; --yes|-y) shift ;; --help|-h) echo 'install.sh [--config <file>] [--yes]'; exit 0 ;; *) echo "Unknown argument: $1" >&2; exit 2 ;; esac
done
[ "$(id -u)" == 0 ] || { echo 'Run as root to provision UID=10001 runtime data directories' >&2; exit 1; }
"$SCRIPT_DIR/check-env.sh" --config "$CONFIG_FILE"
ARCH="$(detect_arch)"
for image in registry-center orchestration-center workflow-designer postgres mysql nginx; do
    docker load -i "$BUNDLE_DIR/images/$image-$ARCH.tar"
done
python3 "$SCRIPT_DIR/configure.py" --config "$CONFIG_FILE" --bundle "$BUNDLE_DIR" --arch "$ARCH" --write
# Do not print resolved config: it includes private runtime credentials.
run_compose config --quiet
run_compose up -d --pull never --remove-orphans --force-recreate --wait --wait-timeout 180
run_compose exec -T openan-nginx nginx -t
run_compose ps
echo 'Containers ready. Verify public login, registry authorization, signing and model/workflow behavior before production acceptance.'
