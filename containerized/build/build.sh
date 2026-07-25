#!/bin/bash
# OpenAN Platform - One-line Image Build Script
# Usage: ./build.sh [components] [options]
#   No arguments = build all components with defaults
#   Specify component names to build only those: registry, orchestration
#
# Components (positional):
#   registry          Build Registry Center only
#   orchestration     Build Orchestration Center + Workflow Designer only
#   (none)            Build all components
#
# Options:
#   --registry-release <url>   Registry Center release URL
#   --orchestration-release <url> Orchestration Center release URL
#   --image-registry <url>     Image registry (default: docker.io)
#   --namespace <ns>           Image namespace (default: openan)
#   --tag <tag>                Image tag (default: v1.0.0)
#   --platforms <platforms>    Target platforms (default: linux/amd64,linux/arm64)
#   --no-push                  Build local only (single-arch only)
#   --help                     Show help

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== Defaults =====
IMAGE_REGISTRY="docker.io"
NAMESPACE="openan"
TAG="v1.0.0"
REGISTRY_RELEASE=""
ORCHESTRATION_RELEASE=""
PLATFORMS="linux/amd64,linux/arm64"
PUSH=true

BUILD_REGISTRY=false
BUILD_ORCHESTRATION=false
COMPONENTS_SPECIFIED=false

TEMP_DIR=""

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

cleanup() {
    [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

show_help() {
    cat << EOF
OpenAN Platform - One-line Image Build

Usage: ./build.sh [components] [options]

Components (positional, specify any):
  registry          Build Registry Center only
  orchestration     Build Orchestration Center + Workflow Designer only
  (none)            Build all components

Options:
  --image-registry <url>     Image registry (default: docker.io)
  --namespace <ns>           Image namespace (default: openan)
  --tag <tag>                Image tag (default: v1.0.0)
  --registry-release <url>   Registry Center release tarball URL
  --orchestration-release <url>  Orchestration Center release tarball URL
  --platforms <platforms>    Target platforms (default: linux/amd64,linux/arm64)
  --no-push                  Build local only (single-arch only)
  --help                     Show help

Examples:
  ./build.sh                                                          # Build all components
  ./build.sh registry                                                 # Build Registry Center only
  ./build.sh orchestration                                            # Build Orchestration + Frontend only
  ./build.sh registry orchestration                                   # Same as default (both)
  ./build.sh --tag v1.1.0                                             # Custom tag, build all
  ./build.sh registry --image-registry harbor.example.com             # Private registry, registry only
  ./build.sh orchestration --platforms linux/amd64 --no-push          # Local single-arch, orchestration only
EOF
    exit 0
}

# ===== Parse arguments =====
while [[ $# -gt 0 ]]; do
    case $1 in
        registry)                BUILD_REGISTRY=true; COMPONENTS_SPECIFIED=true; shift ;;
        orchestration)           BUILD_ORCHESTRATION=true; COMPONENTS_SPECIFIED=true; shift ;;
        --image-registry)        IMAGE_REGISTRY="$2"; shift 2 ;;
        --namespace)             NAMESPACE="$2"; shift 2 ;;
        --tag)                   TAG="$2"; shift 2 ;;
        --registry-release)      REGISTRY_RELEASE="$2"; shift 2 ;;
        --orchestration-release) ORCHESTRATION_RELEASE="$2"; shift 2 ;;
        --platforms)             PLATFORMS="$2"; shift 2 ;;
        --no-push)               PUSH=false; shift ;;
        --help)                  show_help ;;
        *)                       log_error "Unknown argument: $1"; exit 1 ;;
    esac
done

# If no components specified, build all
if [ "$COMPONENTS_SPECIFIED" = false ]; then
    BUILD_REGISTRY=true
    BUILD_ORCHESTRATION=true
fi

# Auto-generate release URLs based on TAG if not explicitly specified
if [ -z "$REGISTRY_RELEASE" ]; then
    REGISTRY_RELEASE="https://github.com/project-openan/registry-center/archive/refs/tags/${TAG}.tar.gz"
fi
if [ -z "$ORCHESTRATION_RELEASE" ]; then
    ORCHESTRATION_RELEASE="https://github.com/project-openan/orchestration-center/archive/refs/tags/${TAG}.tar.gz"
fi

# Multi-arch requires push
if [[ "$PLATFORMS" == *","* ]] && [ "$PUSH" = false ]; then
    log_warn "Multi-arch images must be pushed to registry, enabling push automatically"
    PUSH=true
fi

# ===== Print configuration =====
COMPONENTS=""
[ "$BUILD_REGISTRY" = true ]      && COMPONENTS="${COMPONENTS}registry-center "
[ "$BUILD_ORCHESTRATION" = true ] && COMPONENTS="${COMPONENTS}orchestration-center"
[ "$BUILD_ORCHESTRATION" = true ] && COMPONENTS="${COMPONENTS} workflow-designer"

echo ""
echo "=========================================="
echo "  OpenAN Platform Image Build"
echo "=========================================="
echo ""
[ "$BUILD_REGISTRY" = true ]      && echo "  Registry Center release:  $REGISTRY_RELEASE"
[ "$BUILD_ORCHESTRATION" = true ] && echo "  Orchestration release:    $ORCHESTRATION_RELEASE"
echo "  Image registry:           $IMAGE_REGISTRY"
echo "  Image namespace:          $NAMESPACE"
echo "  Image tag:                $TAG"
echo "  Platforms:                $PLATFORMS"
echo "  Push:                     $PUSH"
echo "  Components:               $COMPONENTS"
echo ""
echo "=========================================="
echo ""

TEMP_DIR=$(mktemp -d)

# ===== Download release packages =====
download_release() {
    local url=$1
    local name=$2
    local dest="$TEMP_DIR/$name"

    log_step "Downloading $name from release..."
    log_info "URL: $url"

    mkdir -p "$dest"
    curl -fSL --progress-bar -o "$TEMP_DIR/${name}.tar.gz" "$url"
    tar -xzf "$TEMP_DIR/${name}.tar.gz" -C "$dest"
    log_info "$name downloaded and extracted to $dest"
}

[ "$BUILD_REGISTRY" = true ]      && download_release "$REGISTRY_RELEASE" "registry-center"
[ "$BUILD_ORCHESTRATION" = true ] && download_release "$ORCHESTRATION_RELEASE" "orchestration-center"

# ===== Detect source directories =====
REGISTRY_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/registry-center:$TAG"
ORCHESTRATION_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/orchestration-center:$TAG"
FRONTEND_IMAGE="$IMAGE_REGISTRY/$NAMESPACE/workflow-designer:$TAG"

RC_SRC=""
OC_SRC=""

if [ "$BUILD_REGISTRY" = true ]; then
    RC_SRC="$TEMP_DIR/registry-center"
    for d in "$TEMP_DIR/registry-center"/*/; do
        [ -f "$d/Dockerfile" ] && RC_SRC="$d" && break
    done
fi

if [ "$BUILD_ORCHESTRATION" = true ]; then
    OC_SRC="$TEMP_DIR/orchestration-center"
    for d in "$TEMP_DIR/orchestration-center"/*/; do
        [ -f "$d/Dockerfile" ] && OC_SRC="$d" && break
    done
fi

# ===== Build images =====
if ! docker buildx version &> /dev/null; then
    log_error "docker buildx not installed"
    exit 1
fi

if ! docker buildx inspect multiarch-builder &> /dev/null; then
    log_step "Creating buildx builder: multiarch-builder"
    docker buildx create --name multiarch-builder --use
else
    docker buildx use multiarch-builder
fi

BUILD_CMD="docker buildx build --platform $PLATFORMS"
[ "$PUSH" = true ] && BUILD_CMD="$BUILD_CMD --push" || BUILD_CMD="$BUILD_CMD --load"

TOTAL=0
[ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ] && ((TOTAL++))
[ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ] && ((TOTAL++))
[ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ] && [ -d "$OC_SRC/workflow-designer" ] && ((TOTAL++))
CURRENT=0

if [ "$BUILD_REGISTRY" = true ] && [ -n "$RC_SRC" ]; then
    ((CURRENT++))
    log_step "[$CURRENT/$TOTAL] Building Registry Center..."
    $BUILD_CMD -t "$REGISTRY_IMAGE" "$RC_SRC"
    log_info "Done: $REGISTRY_IMAGE"
fi

if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    ((CURRENT++))
    log_step "[$CURRENT/$TOTAL] Building Orchestration Center..."
    $BUILD_CMD -t "$ORCHESTRATION_IMAGE" "$OC_SRC"
    log_info "Done: $ORCHESTRATION_IMAGE"
fi

WD_SRC=""
if [ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ]; then
    [ -f "$OC_SRC/workflow-designer/Dockerfile" ] && WD_SRC="$OC_SRC/workflow-designer"
    if [ -n "$WD_SRC" ]; then
        ((CURRENT++))
        log_step "[$CURRENT/$TOTAL] Building Workflow Designer..."
        $BUILD_CMD -t "$FRONTEND_IMAGE" "$WD_SRC"
        log_info "Done: $FRONTEND_IMAGE"
    else
        log_warn "Workflow Designer Dockerfile not found, skipping"
    fi
fi

# ===== Result =====
echo ""
echo "=========================================="
echo "  Build completed!"
echo "=========================================="
echo ""
echo "  Images:"
[ "$BUILD_REGISTRY" = true ]      && [ -n "$RC_SRC" ] && echo "    - $REGISTRY_IMAGE"
[ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ] && echo "    - $ORCHESTRATION_IMAGE"
[ -n "$WD_SRC" ]                  && echo "    - $FRONTEND_IMAGE"
echo ""
echo "  Deploy:"
echo "    helm install openan ./openan-chart -n openan --create-namespace \\"
[ "$BUILD_REGISTRY" = true ]      && [ -n "$RC_SRC" ] && echo "      --set registry.image.repository=$IMAGE_REGISTRY/$NAMESPACE/registry-center --set registry.image.tag=$TAG \\"
[ "$BUILD_ORCHESTRATION" = true ] && [ -n "$OC_SRC" ] && echo "      --set orchestration.image.repository=$IMAGE_REGISTRY/$NAMESPACE/orchestration-center --set orchestration.image.tag=$TAG \\"
[ -n "$WD_SRC" ]                  && echo "      --set frontend.image.repository=$IMAGE_REGISTRY/$NAMESPACE/workflow-designer --set frontend.image.tag=$TAG"
echo ""
