#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
detect_arch() {
    case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo 'Unsupported architecture' >&2; return 1 ;; esac
}
require_tools() {
    for tool in docker python3 sha256sum; do command -v "$tool" >/dev/null || { echo "$tool required" >&2; return 1; }; done
    docker info >/dev/null
    docker compose version >/dev/null
}
verify_bundle() {
    [ -f "$BUNDLE_DIR/SHA256SUMS" ] || { echo 'SHA256SUMS required' >&2; return 1; }
    (cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS >/dev/null) || { echo 'Bundle checksum FAILED; refusing install' >&2; return 1; }
    for image in registry-center orchestration-center workflow-designer postgres mysql nginx; do
        [ -s "$BUNDLE_DIR/images/$image-$ARCH.tar" ] || { echo "Missing image: $image-$ARCH.tar" >&2; return 1; }
    done
}

run_compose() {
    # CLI precedence prevents a stale COMPOSE_PROJECT_NAME/.env from targeting
    # another stack, especially during uninstall. Read only our generated name.
    local project
    project="$(python3 -c 'import json,re,sys; name=json.load(open(sys.argv[1]))["name"]; assert re.fullmatch(r"[a-z0-9][a-z0-9_-]*",name); print(name)' "$BUNDLE_DIR/runtime/compose.json")"
    docker compose --project-name "$project" -f "$BUNDLE_DIR/runtime/compose.json" "$@"
}
