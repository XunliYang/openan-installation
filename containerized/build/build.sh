#!/bin/bash
# OpenAN Platform - Image Build Script (Independent Repository Version)
# Usage: ./build.sh [options]
#
# Options:
#   --registry <url>              Image registry address (default: docker.io)
#   --namespace <ns>              Image namespace (default: openan)
#   --tag <tag>                   Image tag (default: latest)
#   --push                        Push to registry after build
#   --config <file>               Use configuration file (default: build-config.yaml)
#   --registry-src <path>         Registry Center source path (optional)
#   --orchestration-src <path>    Orchestration Center source path (optional)
#   --frontend-src <path>         Workflow Designer source path (default: {orchestration-src}/workflow-designer)
#   --registry-repo <url>         Registry Center Git repository (optional)
#   --orchestration-repo <url>    Orchestration Center Git repository (optional)
#   --registry-branch <branch>    Registry Center branch (default: main)
#   --orchestration-branch <branch>  Orchestration Center branch (default: main)
#   --platforms <platforms>       Target platform architectures (default: linux/amd64,linux/arm64)
#   --help                        Display help information
#
# Notes:
#   - At least one component source must be specified (--registry-src or --orchestration-src)
#   - Workflow Designer is built together with Orchestration Center by default
#   - Components not specified will be skipped

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default configuration
REGISTRY="docker.io"
NAMESPACE="openan"
TAG="latest"
PUSH=false
CONFIG_FILE=""

# Source paths (priority: command line > config file > defaults)
REGISTRY_SRC=""
ORCHESTRATION_SRC=""
FRONTEND_SRC=""

# Git repositories
REGISTRY_REPO=""
ORCHESTRATION_REPO=""

# Git branches
REGISTRY_BRANCH="main"
ORCHESTRATION_BRANCH="main"

# Target platforms
PLATFORMS="linux/amd64,linux/arm64"

# Temporary directory
TEMP_DIR=""

# Log functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_info "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Register cleanup trap
trap cleanup EXIT

# Display help
show_help() {
    cat << EOF
OpenAN Platform - Image Build Script (Independent Repository Version)

Usage: $0 [options]

Image Registry Options:
  --registry <url>              Image registry address (default: docker.io)
  --namespace <ns>              Image namespace (default: openan)
  --tag <tag>                   Image tag (default: latest)
  --push                        Push to registry after build

Source Path Options (local paths):
  --registry-src <path>         Registry Center source path (optional)
  --orchestration-src <path>    Orchestration Center source path (optional)
  --frontend-src <path>         Workflow Designer source path (default: {orchestration-src}/workflow-designer)

Git Repository Options:
  --registry-repo <url>         Registry Center Git repository (optional)
  --orchestration-repo <url>    Orchestration Center Git repository (optional)
  --registry-branch <branch>    Registry Center branch (default: main)
  --orchestration-branch <branch>  Orchestration Center branch (default: main)

Multi-architecture Build Options:
  --platforms <platforms>       Target platform architectures (default: linux/amd64,linux/arm64)
                                Example: linux/amd64,linux/arm64,linux/arm/v7

Configuration Options:
  --config <file>               Use configuration file (default: build-config.yaml)
  --help                        Display help information

Notes:
  - At least one component source must be specified
  - Workflow Designer is built together with Orchestration Center by default
  - Components not specified will be skipped

Examples:
  # Build Registry Center only
  $0 --registry-src /path/to/registry-center

  # Build Orchestration Center only (includes Workflow Designer)
  $0 --orchestration-src /path/to/orchestration-center

  # Build both components
  $0 --registry-src /path/to/registry-center \\
     --orchestration-src /path/to/orchestration-center

  # Use Git repositories
  $0 --registry-repo https://github.com/org/registry-center.git \\
     --orchestration-repo https://github.com/org/orchestration-center.git

  # Use configuration file
  $0 --config build-config.yaml --push

  # Build and push to private registry
  $0 --registry harbor.example.com --namespace openan --tag v1.0.0 --push

EOF
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --tag)
                TAG="$2"
                shift 2
                ;;
            --push)
                PUSH=true
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --registry-src)
                REGISTRY_SRC="$2"
                shift 2
                ;;
            --orchestration-src)
                ORCHESTRATION_SRC="$2"
                shift 2
                ;;
            --frontend-src)
                FRONTEND_SRC="$2"
                shift 2
                ;;
            --registry-repo)
                REGISTRY_REPO="$2"
                shift 2
                ;;
            --orchestration-repo)
                ORCHESTRATION_REPO="$2"
                shift 2
                ;;
            --registry-branch)
                REGISTRY_BRANCH="$2"
                shift 2
                ;;
            --orchestration-branch)
                ORCHESTRATION_BRANCH="$2"
                shift 2
                ;;
            --platforms)
                PLATFORMS="$2"
                shift 2
                ;;
            --help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Load configuration file
load_config() {
    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        log_info "Loading configuration file: $CONFIG_FILE"
        
        # Use Python to parse YAML (more reliable)
        if command -v python3 &> /dev/null; then
            eval $(python3 << EOF
import yaml
import sys

with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)

# Output configuration (only used when not specified on command line)
if config.get('registry', {}).get('url'):
    print(f'REGISTRY="{config["registry"]["url"]}"')
if config.get('registry', {}).get('namespace'):
    print(f'NAMESPACE="{config["registry"]["namespace"]}"')
if config.get('registry', {}).get('tag'):
    print(f'TAG="{config["registry"]["tag"]}"')
if not '$REGISTRY_SRC' and config.get('registry-center', {}).get('source'):
    print(f'REGISTRY_SRC="{config["registry-center"]["source"]}"')
if not '$ORCHESTRATION_SRC' and config.get('orchestration-center', {}).get('source'):
    print(f'ORCHESTRATION_SRC="{config["orchestration-center"]["source"]}"')
if not '$FRONTEND_SRC' and config.get('workflow-designer', {}).get('source'):
    print(f'FRONTEND_SRC="{config["workflow-designer"]["source"]}"')
if not '$REGISTRY_REPO' and config.get('registry-center', {}).get('repository'):
    print(f'REGISTRY_REPO="{config["registry-center"]["repository"]}"')
if not '$ORCHESTRATION_REPO' and config.get('orchestration-center', {}).get('repository'):
    print(f'ORCHESTRATION_REPO="{config["orchestration-center"]["repository"]}"')
if config.get('registry-center', {}).get('branch'):
    print(f'REGISTRY_BRANCH="{config["registry-center"]["branch"]}"')
if config.get('orchestration-center', {}).get('branch'):
    print(f'ORCHESTRATION_BRANCH="{config["orchestration-center"]["branch"]}"')
if config.get('build', {}).get('platforms'):
    print(f'PLATFORMS="{config["build"]["platforms"]}"')
EOF
)
        else
            log_warn "python3 not found, cannot parse YAML configuration file"
        fi
    fi
}

# Clone Git repository
clone_repo() {
    local repo_url=$1
    local branch=$2
    local target_dir=$3
    local component_name=$4
    
    if [ -z "$repo_url" ]; then
        return 1
    fi
    
    log_info "Cloning $component_name repository: $repo_url (branch: $branch)"
    
    if [ -z "$TEMP_DIR" ]; then
        TEMP_DIR=$(mktemp -d)
    fi
    
    local clone_dir="$TEMP_DIR/$target_dir"
    git clone --branch "$branch" --depth 1 "$repo_url" "$clone_dir"
    
    echo "$clone_dir"
    return 0
}

# Prepare source code
prepare_sources() {
    log_info "Preparing source code..."
    
    local has_registry=false
    local has_orchestration=false
    
    # Registry Center
    if [ -n "$REGISTRY_SRC" ]; then
        if [ ! -d "$REGISTRY_SRC" ]; then
            log_error "Registry Center source path does not exist: $REGISTRY_SRC"
            exit 1
        fi
        log_info "Using local source: Registry Center = $REGISTRY_SRC"
        has_registry=true
    elif [ -n "$REGISTRY_REPO" ]; then
        REGISTRY_SRC=$(clone_repo "$REGISTRY_REPO" "$REGISTRY_BRANCH" "registry-center" "Registry Center")
        log_info "Clone completed: Registry Center = $REGISTRY_SRC"
        has_registry=true
    fi
    
    # Orchestration Center
    if [ -n "$ORCHESTRATION_SRC" ]; then
        if [ ! -d "$ORCHESTRATION_SRC" ]; then
            log_error "Orchestration Center source path does not exist: $ORCHESTRATION_SRC"
            exit 1
        fi
        log_info "Using local source: Orchestration Center = $ORCHESTRATION_SRC"
        has_orchestration=true
    elif [ -n "$ORCHESTRATION_REPO" ]; then
        ORCHESTRATION_SRC=$(clone_repo "$ORCHESTRATION_REPO" "$ORCHESTRATION_BRANCH" "orchestration-center" "Orchestration Center")
        log_info "Clone completed: Orchestration Center = $ORCHESTRATION_SRC"
        has_orchestration=true
    fi
    
    # Workflow Designer (subdirectory of orchestration-center)
    if [ "$has_orchestration" = true ]; then
        if [ -n "$FRONTEND_SRC" ]; then
            if [ ! -d "$FRONTEND_SRC" ]; then
                log_error "Workflow Designer source path does not exist: $FRONTEND_SRC"
                exit 1
            fi
            log_info "Using local source: Workflow Designer = $FRONTEND_SRC"
        else
            # Default to workflow-designer directory under Orchestration Center
            FRONTEND_SRC="$ORCHESTRATION_SRC/workflow-designer"
            if [ ! -d "$FRONTEND_SRC" ]; then
                log_warn "Workflow Designer directory does not exist: $FRONTEND_SRC, skipping frontend build"
                FRONTEND_SRC=""
            else
                log_info "Using default path: Workflow Designer = $FRONTEND_SRC"
            fi
        fi
    elif [ -n "$FRONTEND_SRC" ]; then
        if [ ! -d "$FRONTEND_SRC" ]; then
            log_error "Workflow Designer source path does not exist: $FRONTEND_SRC"
            exit 1
        fi
        log_info "Using local source: Workflow Designer = $FRONTEND_SRC"
    fi
    
    # At least one component is required
    if [ "$has_registry" = false ] && [ "$has_orchestration" = false ]; then
        log_error "No component source specified"
        log_error "Please use one of the following options:"
        log_error "  --registry-src <path>         Registry Center source path"
        log_error "  --orchestration-src <path>    Orchestration Center source path"
        log_error "  --registry-repo <url>         Registry Center Git repository"
        log_error "  --orchestration-repo <url>    Orchestration Center Git repository"
        exit 1
    fi
    
    # Set build flags
    BUILD_REGISTRY="$has_registry"
    BUILD_ORCHESTRATION="$has_orchestration"
    BUILD_FRONTEND="$has_orchestration" && [ -n "$FRONTEND_SRC" ]
}

# Build images
build_images() {
    log_info "Starting multi-architecture image build..."
    log_info "Target platforms: $PLATFORMS"
    
    # Check if buildx is enabled
    if ! docker buildx version &> /dev/null; then
        log_error "docker buildx is not installed, cannot build multi-architecture images"
        log_error "Please install Docker 19.03+ and enable buildx"
        exit 1
    fi
    
    # Create or select builder
    if ! docker buildx inspect multiarch-builder &> /dev/null; then
        log_info "Creating buildx builder: multiarch-builder"
        docker buildx create --name multiarch-builder --use
    else
        docker buildx use multiarch-builder
    fi
    
    local total=0
    local current=0
    
    # Calculate total
    [ "$BUILD_REGISTRY" = true ] && ((total++))
    [ "$BUILD_ORCHESTRATION" = true ] && ((total++))
    [ "$BUILD_FRONTEND" = true ] && ((total++))
    
    # Build Registry Center
    if [ "$BUILD_REGISTRY" = true ]; then
        ((current++))
        REGISTRY_IMAGE="$REGISTRY/$NAMESPACE/registry-center:$TAG"
        log_info "[$current/$total] Building Registry Center..."
        docker buildx build \
            --platform "$PLATFORMS" \
            -t "$REGISTRY_IMAGE" \
            --push \
            "$REGISTRY_SRC"
        log_info "✓ Registry Center image: $REGISTRY_IMAGE"
    fi
    
    # Build Orchestration Center
    if [ "$BUILD_ORCHESTRATION" = true ]; then
        ((current++))
        ORCHESTRATION_IMAGE="$REGISTRY/$NAMESPACE/orchestration-center:$TAG"
        log_info "[$current/$total] Building Orchestration Center..."
        docker buildx build \
            --platform "$PLATFORMS" \
            -t "$ORCHESTRATION_IMAGE" \
            --push \
            "$ORCHESTRATION_SRC"
        log_info "✓ Orchestration Center image: $ORCHESTRATION_IMAGE"
    fi
    
    # Build Workflow Designer
    if [ "$BUILD_FRONTEND" = true ]; then
        ((current++))
        FRONTEND_IMAGE="$REGISTRY/$NAMESPACE/workflow-designer:$TAG"
        log_info "[$current/$total] Building Workflow Designer..."
        docker buildx build \
            --platform "$PLATFORMS" \
            -t "$FRONTEND_IMAGE" \
            --push \
            "$FRONTEND_SRC"
        log_info "✓ Workflow Designer image: $FRONTEND_IMAGE"
    fi
}

# Push images (multi-architecture images are pushed directly via --push)
push_images() {
    log_info "Multi-architecture images have been pushed to registry during build"
    log_info "Verifying image architectures:"
    
    if [ "$BUILD_REGISTRY" = true ]; then
        REGISTRY_IMAGE="$REGISTRY/$NAMESPACE/registry-center:$TAG"
        log_info "Registry Center:"
        docker buildx imagetools inspect "$REGISTRY_IMAGE" || true
    fi
    
    if [ "$BUILD_ORCHESTRATION" = true ]; then
        ORCHESTRATION_IMAGE="$REGISTRY/$NAMESPACE/orchestration-center:$TAG"
        log_info "Orchestration Center:"
        docker buildx imagetools inspect "$ORCHESTRATION_IMAGE" || true
    fi
    
    if [ "$BUILD_FRONTEND" = true ]; then
        FRONTEND_IMAGE="$REGISTRY/$NAMESPACE/workflow-designer:$TAG"
        log_info "Workflow Designer:"
        docker buildx imagetools inspect "$FRONTEND_IMAGE" || true
    fi
}

# Display results
show_result() {
    echo ""
    echo "=========================================="
    echo "Multi-architecture image build completed!"
    echo "=========================================="
    echo ""
    echo "Target platforms: $PLATFORMS"
    echo ""
    echo "Image list:"
    
    if [ "$BUILD_REGISTRY" = true ]; then
        echo "  - $REGISTRY/$NAMESPACE/registry-center:$TAG"
    fi
    if [ "$BUILD_ORCHESTRATION" = true ]; then
        echo "  - $REGISTRY/$NAMESPACE/orchestration-center:$TAG"
    fi
    if [ "$BUILD_FRONTEND" = true ]; then
        echo "  - $REGISTRY/$NAMESPACE/workflow-designer:$TAG"
    fi
    
    echo ""
    echo "Deploy using Helm:"
    echo "  helm install openan . \\"
    
    if [ "$BUILD_REGISTRY" = true ]; then
        echo "    --set registry.image.repository=$REGISTRY/$NAMESPACE/registry-center \\"
        echo "    --set registry.image.tag=$TAG \\"
    fi
    if [ "$BUILD_ORCHESTRATION" = true ]; then
        echo "    --set orchestration.image.repository=$REGISTRY/$NAMESPACE/orchestration-center \\"
        echo "    --set orchestration.image.tag=$TAG \\"
    fi
    if [ "$BUILD_FRONTEND" = true ]; then
        echo "    --set frontend.image.repository=$REGISTRY/$NAMESPACE/workflow-designer \\"
        echo "    --set frontend.image.tag=$TAG"
    fi
    echo ""
}

# Main function
main() {
    parse_args "$@"
    load_config
    
    # Multi-architecture builds must be pushed
    if [ "$PUSH" = false ]; then
        log_warn "Multi-architecture images must be pushed to registry, enabling push automatically"
        PUSH=true
    fi
    
    prepare_sources
    build_images
    push_images
    show_result
}

# Execute main function
main "$@"
