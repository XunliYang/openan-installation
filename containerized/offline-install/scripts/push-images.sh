#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Push every image from the bundle into the in-cluster private registry and
# build a multi-arch manifest list per component so that both amd64 and arm64
# nodes pull the right variant from a single tag.
#
# Uses the bundled `crane` binary (go-containerregistry): it speaks plain HTTP
# to an insecure registry and needs no Docker daemon on the cluster node.
#
#   scripts/push-images.sh --config config.env
#   scripts/push-images.sh --config config.env --only registry-center

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE=""
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --only)   ONLY="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done

# --- Defaults -----------------------------------------------------------------
INSTALL_REGISTRY="${INSTALL_REGISTRY:-true}"
REGISTRY_NODE_IP="${REGISTRY_NODE_IP:-}"
REGISTRY_NODEPORT="${REGISTRY_NODEPORT:-30500}"
REGISTRY_CENTER_IMAGE="${REGISTRY_CENTER_IMAGE:-project-openan/registry-center:v1.0.0}"
ORCHESTRATION_CENTER_IMAGE="${ORCHESTRATION_CENTER_IMAGE:-project-openan/orchestration-center:v1.0.0}"
WORKFLOW_DESIGNER_IMAGE="${WORKFLOW_DESIGNER_IMAGE:-project-openan/workflow-designer:v1.0.0}"

[ -n "$CONFIG_FILE" ] && load_config "$CONFIG_FILE"

if [ "$INSTALL_REGISTRY" != "true" ]; then
    log_warn "INSTALL_REGISTRY=false — nothing to push. Exiting."
    exit 0
fi
[ -n "$REGISTRY_NODE_IP" ] || REGISTRY_NODE_IP="$(default_ip)"
[ -n "$REGISTRY_NODE_IP" ] || { log_error "REGISTRY_NODE_IP is empty and could not be detected"; exit 1; }

REG_HOST="${REGISTRY_NODE_IP}:${REGISTRY_NODEPORT}"
ARCH="$(detect_arch)"
[ -n "$ARCH" ] || { log_error "unsupported architecture"; exit 1; }

# --- Resolve crane ------------------------------------------------------------
CRANE=""
for c in "$BUNDLE_DIR/deps/bin/crane-linux-$ARCH" "$BUNDLE_DIR/deps/bin/crane"; do
    [ -x "$c" ] && CRANE="$c" && break
done
if [ -z "$CRANE" ] && have crane; then CRANE="crane"; fi
[ -n "$CRANE" ] || { log_error "crane not found (expected deps/bin/crane-linux-$ARCH in the bundle)"; exit 1; }
log_info "Using crane: $CRANE"

# --- Helpers ------------------------------------------------------------------
push_failed=0

# push_one <local-basename> <repo:tag>
push_one() {
    local base="$1" ref="$2"
    local repo="${ref%:*}" tag="${ref##*:}"
    local tars=() a
    for a in amd64 arm64; do
        [ -r "$BUNDLE_DIR/images/${base}-${a}.tar" ] && tars+=("$a")
    done
    if [ "${#tars[@]}" -eq 0 ]; then
        log_warn "no image tar for $base (skipping)"
        return 0
    fi

    if [ "${#tars[@]}" -eq 1 ]; then
        # Single-arch bundle: push straight to the final tag.
        a="${tars[0]}"
        log_info "Pushing $base ($a) -> ${REG_HOST}/${ref}"
        if "$CRANE" push --insecure "$BUNDLE_DIR/images/${base}-${a}.tar" "${REG_HOST}/${ref}"; then
            return 0
        fi
        push_failed=1
        return 1
    fi

    # Multi-arch: push each arch under a side tag, then stitch a manifest list.
    local manifests=()
    for a in "${tars[@]}"; do
        log_info "Pushing $base ($a) -> ${REG_HOST}/${repo}:${tag}-${a}"
        if ! "$CRANE" push --insecure "$BUNDLE_DIR/images/${base}-${a}.tar" "${REG_HOST}/${repo}:${tag}-${a}"; then
            push_failed=1
            return 1
        fi
        manifests+=("-m" "${REG_HOST}/${repo}:${tag}-${a}")
    done
    log_info "Building manifest list ${REG_HOST}/${ref} (${tars[*]})"
    if ! "$CRANE" index append --insecure -t "${REG_HOST}/${repo}:${tag}" "${manifests[@]}"; then
        push_failed=1
        return 1
    fi
    return 0
}

# --- Push everything ----------------------------------------------------------
echo ""
log_step "Pushing images to $REG_HOST"

# Application images (overridable at install time via config.env).
push_one "registry-center"      "$REGISTRY_CENTER_IMAGE"
push_one "orchestration-center" "$ORCHESTRATION_CENTER_IMAGE"
push_one "workflow-designer"    "$WORKFLOW_DESIGNER_IMAGE"

# Infrastructure images (versions pinned at build time).
if [ -r "$BUNDLE_DIR/deps/infra-images.list" ]; then
    while IFS='|' read -r base ref; do
        [ -z "$base" ] && continue
        case "$base" in \#*) continue ;; esac
        if [ -n "$ONLY" ] && [ "$base" != "$ONLY" ]; then continue; fi
        push_one "$base" "$ref"
    done <"$BUNDLE_DIR/deps/infra-images.list"
else
    log_warn "deps/infra-images.list missing — infrastructure images not pushed"
fi

echo ""
if [ "$push_failed" -eq 0 ]; then
    log_info "All images pushed to $REG_HOST"
else
    log_error "One or more images failed to push"
    exit 1
fi
