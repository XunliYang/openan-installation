#!/bin/bash
# OpenAN Platform - 镜像构建脚本（独立仓库版本）
# 用法: ./build.sh [options]
#
# 选项:
#   --registry <url>              镜像仓库地址 (默认: docker.io)
#   --namespace <ns>              镜像命名空间 (默认: openan)
#   --tag <tag>                   镜像标签 (默认: latest)
#   --push                        构建后推送到仓库
#   --config <file>               使用配置文件 (默认: build-config.yaml)
#   --registry-src <path>         Registry Center 源码路径
#   --orchestration-src <path>    Orchestration Center 源码路径
#   --frontend-src <path>         Workflow Designer 源码路径 (默认: {orchestration-src}/workflow-designer)
#   --registry-repo <url>         Registry Center Git 仓库
#   --orchestration-repo <url>    Orchestration Center Git 仓库
#   --registry-branch <branch>    Registry Center 分支 (默认: main)
#   --orchestration-branch <branch>  Orchestration Center 分支 (默认: main)
#   --platforms <platforms>       目标平台架构 (默认: linux/amd64,linux/arm64)
#   --help                        显示帮助信息

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认配置
REGISTRY="docker.io"
NAMESPACE="openan"
TAG="latest"
PUSH=false
CONFIG_FILE=""

# 源码路径（优先级：命令行 > 配置文件 > 默认值）
REGISTRY_SRC=""
ORCHESTRATION_SRC=""
FRONTEND_SRC=""

# Git 仓库
REGISTRY_REPO=""
ORCHESTRATION_REPO=""

# Git 分支
REGISTRY_BRANCH="main"
ORCHESTRATION_BRANCH="main"

# 目标平台
PLATFORMS="linux/amd64,linux/arm64"

# 临时目录
TEMP_DIR=""

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 清理函数
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        log_info "清理临时目录: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# 注册清理 trap
trap cleanup EXIT

# 显示帮助
show_help() {
    cat << EOF
OpenAN Platform - 镜像构建脚本（独立仓库版本）

用法: $0 [options]

镜像仓库选项:
  --registry <url>              镜像仓库地址 (默认: docker.io)
  --namespace <ns>              镜像命名空间 (默认: openan)
  --tag <tag>                   镜像标签 (默认: latest)
  --push                        构建后推送到仓库

源码路径选项（本地路径）:
  --registry-src <path>         Registry Center 源码路径
  --orchestration-src <path>    Orchestration Center 源码路径
  --frontend-src <path>         Workflow Designer 源码路径 (默认: {orchestration-src}/workflow-designer)

Git 仓库选项:
  --registry-repo <url>         Registry Center Git 仓库
  --orchestration-repo <url>    Orchestration Center Git 仓库
  --registry-branch <branch>    Registry Center 分支 (默认: main)
  --orchestration-branch <branch>  Orchestration Center 分支 (默认: main)

多架构构建选项:
  --platforms <platforms>       目标平台架构 (默认: linux/amd64,linux/arm64)
                                示例: linux/amd64,linux/arm64,linux/arm/v7

配置选项:
  --config <file>               使用配置文件 (默认: build-config.yaml)
  --help                        显示帮助信息

示例:
  # 使用本地源码
  $0 --registry-src /path/to/registry-center \\
     --orchestration-src /path/to/orchestration-center \\
     --frontend-src /path/to/orchestration-center/workflow-designer

  # 使用 Git 仓库
  $0 --registry-repo https://github.com/org/registry-center.git \\
     --orchestration-repo https://github.com/org/orchestration-center.git

  # 使用配置文件
  $0 --config build-config.yaml --push

  # 构建并推送到私有仓库
  $0 --registry harbor.example.com --namespace openan --tag v1.0.0 --push

EOF
    exit 0
}

# 解析命令行参数
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
                log_error "未知选项: $1"
                exit 1
                ;;
        esac
    done
}

# 加载配置文件
load_config() {
    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        log_info "加载配置文件: $CONFIG_FILE"
        
        # 使用 Python 解析 YAML（更可靠）
        if command -v python3 &> /dev/null; then
            eval $(python3 << EOF
import yaml
import sys

with open('$CONFIG_FILE', 'r') as f:
    config = yaml.safe_load(f)

# 输出配置（仅在命令行未指定时使用）
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
            log_warn "未找到 python3，无法解析 YAML 配置文件"
        fi
    fi
}

# 克隆 Git 仓库
clone_repo() {
    local repo_url=$1
    local branch=$2
    local target_dir=$3
    local component_name=$4
    
    if [ -z "$repo_url" ]; then
        return 1
    fi
    
    log_info "克隆 $component_name 仓库: $repo_url (分支: $branch)"
    
    if [ -z "$TEMP_DIR" ]; then
        TEMP_DIR=$(mktemp -d)
    fi
    
    local clone_dir="$TEMP_DIR/$target_dir"
    git clone --branch "$branch" --depth 1 "$repo_url" "$clone_dir"
    
    echo "$clone_dir"
    return 0
}

# 准备源码
prepare_sources() {
    log_info "准备源码..."
    
    # Registry Center
    if [ -n "$REGISTRY_SRC" ]; then
        if [ ! -d "$REGISTRY_SRC" ]; then
            log_error "Registry Center 源码路径不存在: $REGISTRY_SRC"
            exit 1
        fi
        log_info "使用本地源码: Registry Center = $REGISTRY_SRC"
    elif [ -n "$REGISTRY_REPO" ]; then
        REGISTRY_SRC=$(clone_repo "$REGISTRY_REPO" "$REGISTRY_BRANCH" "registry-center" "Registry Center")
        log_info "克隆完成: Registry Center = $REGISTRY_SRC"
    else
        log_error "未指定 Registry Center 源码（需要 --registry-src 或 --registry-repo）"
        exit 1
    fi
    
    # Orchestration Center
    if [ -n "$ORCHESTRATION_SRC" ]; then
        if [ ! -d "$ORCHESTRATION_SRC" ]; then
            log_error "Orchestration Center 源码路径不存在: $ORCHESTRATION_SRC"
            exit 1
        fi
        log_info "使用本地源码: Orchestration Center = $ORCHESTRATION_SRC"
    elif [ -n "$ORCHESTRATION_REPO" ]; then
        ORCHESTRATION_SRC=$(clone_repo "$ORCHESTRATION_REPO" "$ORCHESTRATION_BRANCH" "orchestration-center" "Orchestration Center")
        log_info "克隆完成: Orchestration Center = $ORCHESTRATION_SRC"
    else
        log_error "未指定 Orchestration Center 源码（需要 --orchestration-src 或 --orchestration-repo）"
        exit 1
    fi
    
    # Workflow Designer (orchestration-center 的子目录)
    if [ -n "$FRONTEND_SRC" ]; then
        if [ ! -d "$FRONTEND_SRC" ]; then
            log_error "Workflow Designer 源码路径不存在: $FRONTEND_SRC"
            exit 1
        fi
        log_info "使用本地源码: Workflow Designer = $FRONTEND_SRC"
    else
        # 默认使用 Orchestration Center 下的 workflow-designer 目录
        FRONTEND_SRC="$ORCHESTRATION_SRC/workflow-designer"
        if [ ! -d "$FRONTEND_SRC" ]; then
            log_error "Workflow Designer 目录不存在: $FRONTEND_SRC"
            log_error "请使用 --frontend-src 指定正确的路径"
            exit 1
        fi
        log_info "使用默认路径: Workflow Designer = $FRONTEND_SRC"
    fi
}

# 构建镜像
build_images() {
    log_info "开始构建多架构镜像..."
    log_info "目标平台: $PLATFORMS"
    
    # 镜像名称
    REGISTRY_IMAGE="$REGISTRY/$NAMESPACE/registry-center:$TAG"
    ORCHESTRATION_IMAGE="$REGISTRY/$NAMESPACE/orchestration-center:$TAG"
    FRONTEND_IMAGE="$REGISTRY/$NAMESPACE/workflow-designer:$TAG"
    
    # 检查是否启用了 buildx
    if ! docker buildx version &> /dev/null; then
        log_error "docker buildx 未安装，无法构建多架构镜像"
        log_error "请安装 Docker 19.03+ 并启用 buildx"
        exit 1
    fi
    
    # 创建或选择 builder
    if ! docker buildx inspect multiarch-builder &> /dev/null; then
        log_info "创建 buildx builder: multiarch-builder"
        docker buildx create --name multiarch-builder --use
    else
        docker buildx use multiarch-builder
    fi
    
    # 构建 Registry Center
    log_info "[1/3] 构建 Registry Center..."
    docker buildx build \
        --platform "$PLATFORMS" \
        -t "$REGISTRY_IMAGE" \
        --push \
        "$REGISTRY_SRC"
    log_info "✓ Registry Center 镜像: $REGISTRY_IMAGE"
    
    # 构建 Orchestration Center
    log_info "[2/3] 构建 Orchestration Center..."
    docker buildx build \
        --platform "$PLATFORMS" \
        -t "$ORCHESTRATION_IMAGE" \
        --push \
        "$ORCHESTRATION_SRC"
    log_info "✓ Orchestration Center 镜像: $ORCHESTRATION_IMAGE"
    
    # 构建 Workflow Designer
    log_info "[3/3] 构建 Workflow Designer..."
    docker buildx build \
        --platform "$PLATFORMS" \
        -t "$FRONTEND_IMAGE" \
        --push \
        "$FRONTEND_SRC"
    log_info "✓ Workflow Designer 镜像: $FRONTEND_IMAGE"
}

# 推送镜像（多架构镜像已通过 --push 直接推送）
push_images() {
    log_info "多架构镜像已在构建时推送到仓库"
    log_info "验证镜像架构:"
    
    REGISTRY_IMAGE="$REGISTRY/$NAMESPACE/registry-center:$TAG"
    ORCHESTRATION_IMAGE="$REGISTRY/$NAMESPACE/orchestration-center:$TAG"
    FRONTEND_IMAGE="$REGISTRY/$NAMESPACE/workflow-designer:$TAG"
    
    log_info "[1/3] Registry Center:"
    docker buildx imagetools inspect "$REGISTRY_IMAGE" || true
    
    log_info "[2/3] Orchestration Center:"
    docker buildx imagetools inspect "$ORCHESTRATION_IMAGE" || true
    
    log_info "[3/3] Workflow Designer:"
    docker buildx imagetools inspect "$FRONTEND_IMAGE" || true
}

# 显示结果
show_result() {
    echo ""
    echo "=========================================="
    echo "多架构镜像构建完成！"
    echo "=========================================="
    echo ""
    echo "目标平台: $PLATFORMS"
    echo ""
    echo "镜像列表:"
    echo "  - $REGISTRY/$NAMESPACE/registry-center:$TAG"
    echo "  - $REGISTRY/$NAMESPACE/orchestration-center:$TAG"
    echo "  - $REGISTRY/$NAMESPACE/workflow-designer:$TAG"
    echo ""
    echo "使用 Helm 部署:"
    echo "  helm install openan . \\"
    echo "    --set registry.image.repository=$REGISTRY/$NAMESPACE/registry-center \\"
    echo "    --set registry.image.tag=$TAG \\"
    echo "    --set orchestration.image.repository=$REGISTRY/$NAMESPACE/orchestration-center \\"
    echo "    --set orchestration.image.tag=$TAG \\"
    echo "    --set frontend.image.repository=$REGISTRY/$NAMESPACE/workflow-designer \\"
    echo "    --set frontend.image.tag=$TAG"
    echo ""
}

# 主函数
main() {
    parse_args "$@"
    load_config
    
    # 多架构构建必须推送
    if [ "$PUSH" = false ]; then
        log_warn "多架构镜像必须推送到仓库，自动启用推送"
        PUSH=true
    fi
    
    prepare_sources
    build_images
    push_images
    show_result
}

# 执行主函数
main "$@"
