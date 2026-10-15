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
# config.env is literal data; only configure.py's parser reads it, never shell.
FRONTEND_TYPE="$(python3 - "$SCRIPT_DIR/configure.py" "$CONFIG_FILE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("configure", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.read_env(sys.argv[2]).get("FRONTEND_TYPE", module.DEFAULTS["FRONTEND_TYPE"]))
PY
)"
case "$FRONTEND_TYPE" in
    portal) [ -s "$BUNDLE_DIR/images/portal-$ARCH.tar" ] || { echo "FRONTEND_TYPE=portal requires images/portal-$ARCH.tar in the bundle" >&2; exit 1; } ;;
    workflow-designer) ;; # web/index.html stays validated by configure.py
    *) echo "FRONTEND_TYPE must be portal or workflow-designer" >&2; exit 1 ;;
esac
python3 "$SCRIPT_DIR/configure.py" --config "$CONFIG_FILE" --bundle "$BUNDLE_DIR" --arch "$ARCH"
echo 'Offline prerequisites passed. Container startup and IAM/model reachability are not certified by this check.'
