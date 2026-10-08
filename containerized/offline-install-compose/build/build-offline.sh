#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Build the OpenAN offline bundle for the Docker Compose deployment. Run this
# on an INTERNET-CONNECTED Linux machine with Docker. The output is a
# self-contained directory + tarball for a single offline host.
#
#   ./build-offline.sh                                  # pull app images from ghcr.io
#   ./build-offline.sh --tag v1.0.0
#   ./build-offline.sh --app-source build \
#       --registry-src ~/src/registry-center \
#       --orchestration-src ~/src/orchestration-center
#   ./build-offline.sh --app-source tars --app-tars-dir ~/prebuilt
#
# Options:
#   --tag <tag>                 app image tag (default v1.0.0)
#   --app-registry <host/ns>    upstream app registry (default ghcr.io/project-openan)
#   --app-source pull|build|tars
#   --registry-src <dir>        registry-center source (with Dockerfile) for --app-source build
#   --orchestration-src <dir>   orchestration-center source for --app-source build
#   --app-tars-dir <dir>        directory of pre-built <base>-<arch>.tar for --app-source tars
#   --platforms a,b             target architectures (default linux/amd64,linux/arm64)
#   --out <dir>                 output directory (default ./dist)

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# Resolve a caller-supplied path to an absolute, symlink-resolved path. Docker
# (buildx) resolves build contexts relative to the daemon's working directory,
# so a relative path that bash can resolve (e.g. ../../../src/registry-center)
# still fails inside docker with "unable to prepare context: path ... not found".
# Normalize here so the same path works everywhere; a missing or unresolvable
# path fails here with a clear error instead of failing deep inside docker.
resolve_abs() {
    local p
    p="$(readlink -e "$1" 2>/dev/null)" && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    p="$(realpath -e "$1" 2>/dev/null)" && [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    return 1
}

TAG="v1.0.0"
APP_REGISTRY="ghcr.io/project-openan"
APP_SOURCE="pull"
REGISTRY_SRC=""
ORCHESTRATION_SRC=""
APP_TARS_DIR=""
PLATFORMS="linux/amd64,linux/arm64"
OUT_DIR="$SCRIPT_DIR/dist"

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)               TAG="$2"; shift 2 ;;
        --app-registry)      APP_REGISTRY="$2"; shift 2 ;;
        --app-source)        APP_SOURCE="$2"; shift 2 ;;
        --registry-src)      REGISTRY_SRC="$2"; shift 2 ;;
        --orchestration-src) ORCHESTRATION_SRC="$2"; shift 2 ;;
        --app-tars-dir)      APP_TARS_DIR="$2"; shift 2 ;;
        --platforms)         PLATFORMS="$2"; shift 2 ;;
        --out)               OUT_DIR="$2"; shift 2 ;;
        -h|--help)           sed -n '2,28p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done

for t in docker curl; do
    command -v "$t" >/dev/null 2>&1 || { log_error "$t is required"; exit 1; }
done

REGISTRY_CENTER_REF="$APP_REGISTRY/registry-center:$TAG"
ORCHESTRATION_CENTER_REF="$APP_REGISTRY/orchestration-center:$TAG"
WORKFLOW_DESIGNER_REF="$APP_REGISTRY/workflow-designer:$TAG"

ARCHS=()
for p in ${PLATFORMS//,/ }; do ARCHS+=("${p#linux/}"); done

mkdir -p "$OUT_DIR"
BUNDLE="$(cd "$OUT_DIR" && pwd)/openan-offline-compose-$TAG"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/images" "$BUNDLE/deps"

log_step "Assembling bundle at $BUNDLE"
cp -r "$BUNDLE_SRC/scripts" "$BUNDLE/scripts"
cp -r "$BUNDLE_SRC/compose" "$BUNDLE/compose"
cp "$BUNDLE_SRC/config.env.example" "$BUNDLE/config.env.example"
cp "$BUNDLE_SRC/README.md" "$BUNDLE/README.md" 2>/dev/null || true
cp -r "$BUNDLE_SRC/docs" "$BUNDLE/docs" 2>/dev/null || true
chmod +x "$BUNDLE/scripts"/*.sh "$BUNDLE/compose/init/create-databases.sh" 2>/dev/null || true

# --- Images -------------------------------------------------------------------
save_image() {
    local ref="$1" base="$2"
    for a in "${ARCHS[@]}"; do
        log_info "  save $base ($a)"
        docker pull --platform "linux/${a}" "$ref" >/dev/null || { log_error "pull failed: $ref"; return 1; }
        docker save -o "$BUNDLE/images/${base}-${a}.tar" "$ref" || { log_error "save failed: $ref"; return 1; }
    done
}

log_step "Pulling and saving infrastructure images"
save_image "postgres:15-alpine" "postgres-15-alpine"
save_image "nginx:1.25-alpine"  "nginx-1-25-alpine"

log_step "Preparing application images ($APP_SOURCE)"
case "$APP_SOURCE" in
    pull)
        save_image "$REGISTRY_CENTER_REF"      "registry-center"
        save_image "$ORCHESTRATION_CENTER_REF" "orchestration-center"
        save_image "$WORKFLOW_DESIGNER_REF"    "workflow-designer"
        ;;
    build)
        [ -n "$REGISTRY_SRC" ] || { log_error "--registry-src is required for --app-source build"; exit 1; }
        [ -n "$ORCHESTRATION_SRC" ] || { log_error "--orchestration-src is required for --app-source build"; exit 1; }
        _path="$(resolve_abs "$REGISTRY_SRC")" || { log_error "--registry-src path not found: $REGISTRY_SRC"; exit 1; }
        REGISTRY_SRC="$_path"
        _path="$(resolve_abs "$ORCHESTRATION_SRC")" || { log_error "--orchestration-src path not found: $ORCHESTRATION_SRC"; exit 1; }
        ORCHESTRATION_SRC="$_path"
        for a in "${ARCHS[@]}"; do
            log_info "  build registry-center ($a)"
            docker buildx build --platform "linux/${a}" --load -t "$REGISTRY_CENTER_REF" "$REGISTRY_SRC" || exit 1
            docker save -o "$BUNDLE/images/registry-center-${a}.tar" "$REGISTRY_CENTER_REF"
            log_info "  build orchestration-center ($a)"
            docker buildx build --platform "linux/${a}" --load -t "$ORCHESTRATION_CENTER_REF" "$ORCHESTRATION_SRC" || exit 1
            docker save -o "$BUNDLE/images/orchestration-center-${a}.tar" "$ORCHESTRATION_CENTER_REF"
            if [ -f "$ORCHESTRATION_SRC/workflow-designer/Dockerfile" ]; then
                log_info "  build workflow-designer ($a)"
                docker buildx build --platform "linux/${a}" --load -t "$WORKFLOW_DESIGNER_REF" "$ORCHESTRATION_SRC/workflow-designer" || exit 1
                docker save -o "$BUNDLE/images/workflow-designer-${a}.tar" "$WORKFLOW_DESIGNER_REF"
            else
                log_warn "  no workflow-designer/Dockerfile — skipping"
            fi
        done
        ;;
    tars)
        [ -d "$APP_TARS_DIR" ] || { log_error "--app-tars-dir is required for --app-source tars"; exit 1; }
        APP_TARS_DIR="$(resolve_abs "$APP_TARS_DIR")"
        for base in registry-center orchestration-center workflow-designer; do
            for a in "${ARCHS[@]}"; do
                [ -r "$APP_TARS_DIR/${base}-${a}.tar" ] || { log_error "missing $APP_TARS_DIR/${base}-${a}.tar"; exit 1; }
                cp "$APP_TARS_DIR/${base}-${a}.tar" "$BUNDLE/images/"
            done
        done
        ;;
    *)
        log_error "invalid --app-source: $APP_SOURCE (use pull|build|tars)"; exit 2 ;;
esac

# --- Frontend static assets (served directly by nginx) ------------------------
log_step "Extracting frontend static assets"
if [ -r "$BUNDLE/images/workflow-designer-${ARCHS[0]}.tar" ]; then
    docker load -i "$BUNDLE/images/workflow-designer-${ARCHS[0]}.tar" >/dev/null
    cid="$(docker create "$WORKFLOW_DESIGNER_REF" 2>/dev/null)"
    if [ -n "$cid" ]; then
        mkdir -p "$BUNDLE/web"
        docker cp "$cid:/usr/share/nginx/html/." "$BUNDLE/web/" >/dev/null 2>&1 \
            && log_info "web/ populated" \
            || log_warn "could not copy /usr/share/nginx/html from the image"
        docker rm -f "$cid" >/dev/null
    else
        log_warn "could not create a container from $WORKFLOW_DESIGNER_REF"
    fi
else
    log_warn "workflow-designer tar missing — the frontend would be empty"
fi

# --- Record tags --------------------------------------------------------------
{
    echo "APP_REGISTRY_CENTER_TAG=$REGISTRY_CENTER_REF"
    echo "APP_ORCHESTRATION_CENTER_TAG=$ORCHESTRATION_CENTER_REF"
    echo "APP_WORKFLOW_DESIGNER_TAG=$WORKFLOW_DESIGNER_REF"
} >"$BUNDLE/deps/image-tags.env"

# --- Checksums ----------------------------------------------------------------
log_step "Generating SHA256SUMS"
(cd "$BUNDLE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)

# --- Tarball ------------------------------------------------------------------
log_step "Creating tarball"
tar -C "$(dirname "$BUNDLE")" -czf "$BUNDLE.tar.gz" "$(basename "$BUNDLE")"
log_info "Bundle:   $BUNDLE"
log_info "Tarball:  $BUNDLE.tar.gz ($(du -sh "$BUNDLE.tar.gz" | cut -f1))"

echo ""
log_info "Done. Copy $BUNDLE.tar.gz to the target host, then:"
log_info "  tar -xzf $(basename "$BUNDLE.tar.gz")"
log_info "  cd $(basename "$BUNDLE")"
log_info "  cp config.env.example config.env && vi config.env"
log_info "  scripts/check-env.sh --config config.env"
log_info "  sudo scripts/install.sh --config config.env"
