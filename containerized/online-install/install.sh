#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Explicit values + existing Secrets replace insecure interactive credential defaults.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ $# -lt 2 || "$1" != "--values" || ! -f "$2" ]]; then
    echo "Usage: bash install.sh --values /path/to/deployment.yaml [helm upgrade options]" >&2
    echo "Create credential/certificate Secrets first; see ../TRANSPORT_DEPLOYMENT.md." >&2
    exit 2
fi
VALUES_FILE="$2"
shift 2
exec helm upgrade --install openan "$SCRIPT_DIR/openan-chart" \
    --namespace openan --create-namespace --values "$VALUES_FILE" "$@"
