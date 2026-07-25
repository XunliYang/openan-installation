#!/bin/bash
# OpenAN Platform - One-click Setup Script
# Interactive setup: environment check, build, and deploy

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
CHART_DIR="$SCRIPT_DIR/openan-chart"

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }

# ===== Configuration =====
CONFIG_REGISTRY=true
CONFIG_ORCHESTRATION=true
CONFIG_IMAGE_SOURCE="build"  # build or pull
CONFIG_IMAGE_REGISTRY="docker.io"
CONFIG_NAMESPACE="openan"
CONFIG_TAG="v1.0.0"
CONFIG_LOCAL_REGISTRY=false
CONFIG_LOCAL_REGISTRY_PORT="5000"
CONFIG_API_KEY_CHAT=""
CONFIG_API_KEY_EMBED=""
CONFIG_API_KEY_RERANK=""
CONFIG_API_KEY_A2AT=""
CONFIG_DB_PASSWORD="openan-db-password"
CONFIG_INGRESS_HOST="openan.local"

# ===== Helper Functions =====
ask_yes_no() {
    local prompt="$1"
    local default="$2"
    local answer
    
    if [ "$default" = "yes" ]; then
        log_prompt "$prompt [Y/n]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="y"
    else
        log_prompt "$prompt [y/N]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="n"
    fi
    
    [[ "$answer" =~ ^[Yy] ]]
}

ask_input() {
    local prompt="$1"
    local default="$2"
    local value
    
    if [ -n "$default" ]; then
        log_prompt "$prompt [$default]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    read -r value >&2
    echo "${value:-$default}"
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo "" >&2
    log_prompt "$prompt" >&2
    for i in "${!options[@]}"; do
        echo "  $((i+1)). ${options[$i]}" >&2
    done
    read -r choice >&2
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
        echo "${options[$((choice-1))]}"
    else
        echo "${options[0]}"
    fi
}

# ===== Environment Check =====
check_docker() {
    if command -v docker &> /dev/null; then
        local version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_info "Docker installed: $version"
        return 0
    else
        log_error "Docker not found"
        return 1
    fi
}

check_kubectl() {
    if command -v kubectl &> /dev/null; then
        local version=$(kubectl version --client --short 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_info "kubectl installed: $version"
        return 0
    else
        log_error "kubectl not found"
        return 1
    fi
}

check_helm() {
    if command -v helm &> /dev/null; then
        local version=$(helm version --short 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        log_info "Helm installed: $version"
        return 0
    else
        log_error "Helm not found"
        return 1
    fi
}

check_k8s_cluster() {
    if kubectl cluster-info &> /dev/null; then
        log_info "Kubernetes cluster accessible"
        return 0
    else
        log_error "Cannot access Kubernetes cluster"
        return 1
    fi
}

check_ingress_controller() {
    if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller &> /dev/null; then
        log_info "Nginx Ingress Controller found"
        return 0
    elif kubectl get pods -n kube-system -l app.kubernetes.io/name=ingress-nginx &> /dev/null; then
        log_info "Nginx Ingress Controller found (kube-system)"
        return 0
    else
        log_warn "Nginx Ingress Controller not found"
        return 1
    fi
}

install_dependency() {
    local dep="$1"
    
    echo ""
    log_step "Installing $dep..."
    
    case "$dep" in
        docker)
            if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                log_info "Installing Docker on Linux..."
                curl -fsSL https://get.docker.com | sh
                sudo usermod -aG docker $USER
                sudo systemctl start docker
                sudo systemctl enable docker
                log_info "Docker service started"
            elif [[ "$OSTYPE" == "darwin"* ]]; then
                log_error "Please install Docker Desktop manually:"
                log_info "  brew install --cask docker"
                log_info "  Or download from: https://docs.docker.com/desktop/install/mac-install/"
                return 1
            else
                log_error "Automatic Docker installation not supported on this platform"
                return 1
            fi
            ;;
        kubectl)
            if [[ "$OSTYPE" == "linux-gnu"* ]]; then
                curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
                sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
                rm -f kubectl
            elif [[ "$OSTYPE" == "darwin"* ]]; then
                if command -v brew &> /dev/null; then
                    brew install kubectl
                else
                    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
                    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
                    rm -f kubectl
                fi
            else
                log_error "Automatic kubectl installation not supported on this platform"
                return 1
            fi
            ;;
        helm)
            if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &> /dev/null; then
                brew install helm
            else
                curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
            fi
            ;;
        ingress-nginx)
            log_info "Installing Nginx Ingress Controller..."
            kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
            log_info "Waiting for Ingress Controller to be ready..."
            kubectl wait --namespace ingress-nginx \
                --for=condition=ready pod \
                --selector=app.kubernetes.io/component=controller \
                --timeout=120s
            ;;
    esac
    
    return $?
}

verify_installation() {
    local dep="$1"
    
    case "$dep" in
        docker)
            if docker info &> /dev/null; then
                return 0
            fi
            ;;
        kubectl)
            if command -v kubectl &> /dev/null; then
                return 0
            fi
            ;;
        helm)
            if command -v helm &> /dev/null; then
                return 0
            fi
            ;;
        ingress-nginx)
            if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q "Running"; then
                return 0
            fi
            ;;
    esac
    
    return 1
}

# ===== Main Setup Flow =====
echo ""
echo "=========================================="
echo "  OpenAN Platform - One-click Setup"
echo "=========================================="
echo ""

# Step 1: Environment Check
log_step "Checking prerequisites..."
echo ""

MISSING_DEPS=()
FAILED_INSTALLS=()

# Check each dependency
check_docker || MISSING_DEPS+=("docker")
check_kubectl || MISSING_DEPS+=("kubectl")
check_helm || MISSING_DEPS+=("helm")

# Check K8S cluster (requires kubectl)
if command -v kubectl &> /dev/null; then
    if ! check_k8s_cluster; then
        log_error "Cannot access Kubernetes cluster"
        log_info "Please configure kubeconfig first:"
        log_info "  export KUBECONFIG=~/.kube/config"
        log_info "  Or copy kubeconfig to ~/.kube/config"
        exit 1
    fi
else
    log_warn "kubectl not found, skipping cluster check"
    MISSING_DEPS+=("kubectl")
    MISSING_DEPS+=("k8s-cluster-check")
fi

# Check Ingress Controller (requires kubectl and cluster)
if command -v kubectl &> /dev/null && kubectl cluster-info &> /dev/null; then
    check_ingress_controller || MISSING_DEPS+=("ingress-nginx")
fi

# Install missing dependencies
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo ""
    log_warn "Missing dependencies: ${MISSING_DEPS[*]}"
    
    if ask_yes_no "Install missing dependencies automatically?" "yes"; then
        for dep in "${MISSING_DEPS[@]}"; do
            if [ "$dep" = "k8s-cluster-check" ]; then
                continue
            fi
            
            if install_dependency "$dep"; then
                # Verify installation
                if verify_installation "$dep"; then
                    log_info "✓ $dep installed and verified"
                else
                    log_warn "✗ $dep installed but verification failed"
                    FAILED_INSTALLS+=("$dep")
                fi
            else
                log_error "✗ Failed to install $dep"
                FAILED_INSTALLS+=("$dep")
            fi
        done
        
        # Re-check K8S cluster if kubectl was just installed
        if [[ " ${MISSING_DEPS[@]} " =~ " kubectl " ]]; then
            if ! check_k8s_cluster; then
                log_error "Still cannot access Kubernetes cluster"
                log_info "Please configure kubeconfig and re-run"
                exit 1
            fi
        fi
    else
        log_error "Please install dependencies manually:"
        [ "${MISSING_DEPS[*]}" =~ "docker" ] && log_info "  Docker: https://docs.docker.com/get-docker/"
        [ "${MISSING_DEPS[*]}" =~ "kubectl" ] && log_info "  kubectl: https://kubernetes.io/docs/tasks/tools/"
        [ "${MISSING_DEPS[*]}" =~ "helm" ] && log_info "  Helm: https://helm.sh/docs/intro/install/"
        [ "${MISSING_DEPS[*]}" =~ "ingress-nginx" ] && log_info "  Ingress: kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml"
        exit 1
    fi
fi

# Check for failed installations
if [ ${#FAILED_INSTALLS[@]} -gt 0 ]; then
    echo ""
    log_error "Some dependencies failed to install: ${FAILED_INSTALLS[*]}"
    log_info "Please install them manually and re-run"
    exit 1
fi

echo ""
log_info "All prerequisites satisfied!"

# Step 2: Component Selection
echo ""
log_step "Select components to build and deploy:"
echo ""
log_prompt "Components:"
echo "  1. All components (Registry Center + Orchestration Center + Workflow Designer)"
echo "  2. Registry Center only"
echo "  3. Orchestration Center + Workflow Designer only"
echo "  4. Custom selection"
read -r choice

case "$choice" in
    1) CONFIG_REGISTRY=true; CONFIG_ORCHESTRATION=true ;;
    2) CONFIG_REGISTRY=true; CONFIG_ORCHESTRATION=false ;;
    3) CONFIG_REGISTRY=false; CONFIG_ORCHESTRATION=true ;;
    4)
        CONFIG_REGISTRY=$(ask_yes_no "Build Registry Center?" "yes") && CONFIG_REGISTRY=true || CONFIG_REGISTRY=false
        CONFIG_ORCHESTRATION=$(ask_yes_no "Build Orchestration Center?" "yes") && CONFIG_ORCHESTRATION=true || CONFIG_ORCHESTRATION=false
        ;;
    *) CONFIG_REGISTRY=true; CONFIG_ORCHESTRATION=true ;;
esac

# Step 3: Image Source
echo ""
log_step "Image source:"
CONFIG_IMAGE_SOURCE=$(ask_choice "Select image source:" "Build from source (download release packages)" "Pull pre-built images from registry")

if [[ "$CONFIG_IMAGE_SOURCE" == "Build"* ]]; then
    CONFIG_IMAGE_SOURCE="build"
else
    CONFIG_IMAGE_SOURCE="pull"
fi

# Step 4: Local Registry
if [ "$CONFIG_IMAGE_SOURCE" = "build" ]; then
    echo ""
    log_step "Local registry:"
    if ask_yes_no "Deploy a local registry in the cluster to store images?" "no"; then
        CONFIG_LOCAL_REGISTRY=true
        CONFIG_LOCAL_REGISTRY_PORT=$(ask_input "Local registry NodePort" "5000")
        CONFIG_IMAGE_REGISTRY="localhost:$CONFIG_LOCAL_REGISTRY_PORT"
    else
        CONFIG_IMAGE_REGISTRY=$(ask_input "Image registry" "docker.io")
    fi
else
    CONFIG_IMAGE_REGISTRY=$(ask_input "Image registry" "docker.io")
fi

# Step 5: Image Configuration
echo ""
log_step "Image configuration:"
CONFIG_NAMESPACE=$(ask_input "Image namespace" "openan")
CONFIG_TAG=$(ask_input "Image tag" "v1.0.0")

# Step 6: API Keys
echo ""
log_step "LLM API Keys (press Enter to skip):"
CONFIG_API_KEY_CHAT=$(ask_input "Chat API Key" "")
CONFIG_API_KEY_EMBED=$(ask_input "Embed API Key" "")
CONFIG_API_KEY_RERANK=$(ask_input "Rerank API Key" "")
CONFIG_API_KEY_A2AT=$(ask_input "A2AT API Key" "")

# Step 7: Database Password
echo ""
log_step "Database configuration:"
CONFIG_DB_PASSWORD=$(ask_input "Database password" "openan-db-password")

# Step 8: Ingress Configuration
echo ""
log_step "Ingress configuration:"
CONFIG_INGRESS_HOST=$(ask_input "Ingress host" "openan.local")

# ===== Summary =====
echo ""
echo "=========================================="
echo "  Configuration Summary"
echo "=========================================="
echo ""
echo "  Components:"
[ "$CONFIG_REGISTRY" = true ] && echo "    - Registry Center"
[ "$CONFIG_ORCHESTRATION" = true ] && echo "    - Orchestration Center"
[ "$CONFIG_ORCHESTRATION" = true ] && echo "    - Workflow Designer"
echo ""
echo "  Image Source:     $CONFIG_IMAGE_SOURCE"
echo "  Image Registry:   $CONFIG_IMAGE_REGISTRY"
echo "  Image Namespace:  $CONFIG_NAMESPACE"
echo "  Image Tag:        $CONFIG_TAG"
echo "  Local Registry:   $CONFIG_LOCAL_REGISTRY"
echo "  Ingress Host:     $CONFIG_INGRESS_HOST"
echo ""
echo "=========================================="
echo ""

if ! ask_yes_no "Proceed with setup?" "yes"; then
    log_info "Setup cancelled"
    exit 0
fi

# ===== Execute Setup =====

# Deploy local registry if requested
if [ "$CONFIG_LOCAL_REGISTRY" = true ]; then
    log_step "Deploying local registry..."
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: local-registry
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: local-registry
  template:
    metadata:
      labels:
        app: local-registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
---
apiVersion: v1
kind: Service
metadata:
  name: local-registry
  namespace: default
spec:
  type: NodePort
  ports:
  - port: 5000
    nodePort: $CONFIG_LOCAL_REGISTRY_PORT
  selector:
    app: local-registry
EOF
    log_info "Local registry deployed on port $CONFIG_LOCAL_REGISTRY_PORT"
    sleep 5
fi

# Build or pull images
if [ "$CONFIG_IMAGE_SOURCE" = "build" ]; then
    log_step "Building images..."
    
    BUILD_ARGS=""
    [ "$CONFIG_REGISTRY" = true ] && BUILD_ARGS="$BUILD_ARGS registry"
    [ "$CONFIG_ORCHESTRATION" = true ] && BUILD_ARGS="$BUILD_ARGS orchestration"
    
    cd "$BUILD_DIR"
    ./build.sh $BUILD_ARGS \
        --image-registry "$CONFIG_IMAGE_REGISTRY" \
        --namespace "$CONFIG_NAMESPACE" \
        --tag "$CONFIG_TAG"
    
    # If local registry, push images
    if [ "$CONFIG_LOCAL_REGISTRY" = true ]; then
        log_step "Pushing images to local registry..."
        # Images are already pushed by build.sh
    fi
else
    log_step "Skipping build (using pre-built images)"
fi

# Deploy with Helm
log_step "Deploying with Helm..."

HELM_ARGS=""
[ "$CONFIG_REGISTRY" = true ] && HELM_ARGS="$HELM_ARGS --set registry.enabled=true"
[ "$CONFIG_REGISTRY" = false ] && HELM_ARGS="$HELM_ARGS --set registry.enabled=false"
[ "$CONFIG_ORCHESTRATION" = true ] && HELM_ARGS="$HELM_ARGS --set orchestration.enabled=true --set frontend.enabled=true"
[ "$CONFIG_ORCHESTRATION" = false ] && HELM_ARGS="$HELM_ARGS --set orchestration.enabled=false --set frontend.enabled=false"

if [ "$CONFIG_REGISTRY" = true ]; then
    HELM_ARGS="$HELM_ARGS --set registry.image.repository=$CONFIG_IMAGE_REGISTRY/$CONFIG_NAMESPACE/registry-center"
    HELM_ARGS="$HELM_ARGS --set registry.image.tag=$CONFIG_TAG"
    [ -n "$CONFIG_API_KEY_CHAT" ] && HELM_ARGS="$HELM_ARGS --set registry.llm.chat.apiKey=$CONFIG_API_KEY_CHAT"
    [ -n "$CONFIG_API_KEY_EMBED" ] && HELM_ARGS="$HELM_ARGS --set registry.llm.embed.apiKey=$CONFIG_API_KEY_EMBED"
    [ -n "$CONFIG_API_KEY_RERANK" ] && HELM_ARGS="$HELM_ARGS --set registry.llm.rerank.apiKey=$CONFIG_API_KEY_RERANK"
fi

if [ "$CONFIG_ORCHESTRATION" = true ]; then
    HELM_ARGS="$HELM_ARGS --set orchestration.image.repository=$CONFIG_IMAGE_REGISTRY/$CONFIG_NAMESPACE/orchestration-center"
    HELM_ARGS="$HELM_ARGS --set orchestration.image.tag=$CONFIG_TAG"
    HELM_ARGS="$HELM_ARGS --set frontend.image.repository=$CONFIG_IMAGE_REGISTRY/$CONFIG_NAMESPACE/workflow-designer"
    HELM_ARGS="$HELM_ARGS --set frontend.image.tag=$CONFIG_TAG"
    [ -n "$CONFIG_API_KEY_CHAT" ] && HELM_ARGS="$HELM_ARGS --set orchestration.llm.chat.apiKey=$CONFIG_API_KEY_CHAT"
    [ -n "$CONFIG_API_KEY_A2AT" ] && HELM_ARGS="$HELM_ARGS --set orchestration.a2at.apiKey=$CONFIG_API_KEY_A2AT"
fi

HELM_ARGS="$HELM_ARGS --set postgresql.password=$CONFIG_DB_PASSWORD"
HELM_ARGS="$HELM_ARGS --set ingress.host=$CONFIG_INGRESS_HOST"

cd "$CHART_DIR"
helm upgrade --install openan . \
    -n "$CONFIG_NAMESPACE" --create-namespace \
    $HELM_ARGS

# ===== Final Summary =====
echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "  Access the platform:"
echo "    - Workflow Designer: http://$CONFIG_INGRESS_HOST/"
echo "    - Registry API:      http://$CONFIG_INGRESS_HOST/registry/rest/v1/registry-center/agent-cards"
echo "    - Orchestration API: http://$CONFIG_INGRESS_HOST/api/orchestrate/rest/v1/orchestrate/agent-cards"
echo ""
echo "  Add to /etc/hosts:"
echo "    <ingress-ip>  $CONFIG_INGRESS_HOST"
echo ""
echo "  Check status:"
echo "    kubectl -n $CONFIG_NAMESPACE get pods"
echo "    kubectl -n $CONFIG_NAMESPACE get ingress"
echo ""
echo "  Uninstall:"
echo "    helm uninstall openan -n $CONFIG_NAMESPACE"
echo ""
