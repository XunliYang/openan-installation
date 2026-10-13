#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# Preserve all persistent data and private configuration. No recursive deletion.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
while [ $# -gt 0 ]; do
    case "$1" in --yes|-y) shift ;; --help|-h) echo 'uninstall.sh: stop containers; retain volumes and runtime configuration'; exit 0 ;; *) echo "Unknown argument: $1" >&2; exit 2 ;; esac
done
[ -f "$BUNDLE_DIR/runtime/compose.json" ] || { echo 'No generated runtime/compose.json; refusing to guess project identity' >&2; exit 1; }
run_compose down --remove-orphans
echo 'Containers removed. Database volumes, bind-mounted data, PKI and configuration preserved.'
