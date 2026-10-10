#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# Read-only checks. config.env is literal data, never sourced as shell code.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
CONFIG_FILE="$BUNDLE_DIR/config.env"
while [ $# -gt 0 ]; do
    case "$1" in --config) [ $# -ge 2 ] || exit 2; CONFIG_FILE="$2"; shift 2 ;; --help|-h) echo 'check-env.sh [--config <file>]'; exit 0 ;; *) echo "Unknown argument: $1" >&2; exit 2 ;; esac
done
ARCH="$(detect_arch)"
require_tools
verify_bundle
python3 "$SCRIPT_DIR/configure.py" --config "$CONFIG_FILE" --bundle "$BUNDLE_DIR" --arch "$ARCH"
echo 'Offline prerequisites passed. Container startup and IAM/model reachability are not certified by this check.'
