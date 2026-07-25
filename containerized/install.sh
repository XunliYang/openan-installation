#!/bin/bash
# OpenAN Platform - One-click Setup Script
# Interactive setup: environment check, build, and deploy

set -o pipefail

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

# Ensure scripts are executable
chmod +x "$BUILD_DIR/build.sh" 2>/dev/null || true

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }

# ===== Configuration =====
CONFIG_REGISTRY=true
CONFIG_ORCHESTRATION=true
CONFIG_IMAGE_REGISTRY="docker.io"
CONFIG_IMAGE_NAMESPACE="leoyy6"
CONFIG_K8S_NAMESPACE="openan"
CONFIG_TAG="v1.0.0"

# LLM Configuration for Registry Center
CONFIG_REGISTRY_CHAT_MODEL="glm-5.1"
CONFIG_REGISTRY_CHAT_URL="https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
CONFIG_REGISTRY_CHAT_APIKEY=""

# LLM Configuration for Orchestration Center
CONFIG_ORCH_CHAT_MODEL="qwen3.7-plus"
CONFIG_ORCH_CHAT_URL="https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
CONFIG_ORCH_CHAT_APIKEY=""
CONFIG_ORCH_A2AT_PROVIDER="openai"
CONFIG_ORCH_A2AT_MODEL="qwen3.7-plus"
CONFIG_ORCH_A2AT_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"
CONFIG_ORCH_A2AT_APIKEY=""

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
        if [ -z "$answer" ]; then
            answer="y"
        fi
    else
        log_prompt "$prompt [y/N]:" >&2
        read -r answer
        if [ -z "$answer" ]; then
            answer="n"
        fi
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
log_step "[1/4] Checking prerequisites..."
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
        if [[ "${MISSING_DEPS[*]}" =~ "docker" ]]; then
            log_info "  Docker: https://docs.docker.com/get-docker/"
        fi
        if [[ "${MISSING_DEPS[*]}" =~ "kubectl" ]]; then
            log_info "  kubectl: https://kubernetes.io/docs/tasks/tools/"
        fi
        if [[ "${MISSING_DEPS[*]}" =~ "helm" ]]; then
            log_info "  Helm: https://helm.sh/docs/intro/install/"
        fi
        if [[ "${MISSING_DEPS[*]}" =~ "ingress-nginx" ]]; then
            log_info "  Ingress: kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml"
        fi
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
log_step "[2/4] Select components to deploy:"
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
        CONFIG_REGISTRY=$(ask_yes_no "Deploy Registry Center?" "yes") && CONFIG_REGISTRY=true || CONFIG_REGISTRY=false
        CONFIG_ORCHESTRATION=$(ask_yes_no "Deploy Orchestration Center?" "yes") && CONFIG_ORCHESTRATION=true || CONFIG_ORCHESTRATION=false
        ;;
    *) CONFIG_REGISTRY=true; CONFIG_ORCHESTRATION=true ;;
esac

# Step 3: LLM Configuration for Registry Center
if [ "$CONFIG_REGISTRY" = true ]; then
    echo ""
    log_step "[3/4] Registry Center LLM Configuration (press Enter to use default):"
    
    echo ""
    log_info "Chat Model:"
    chat_model=$(ask_input "  Model name" "$CONFIG_REGISTRY_CHAT_MODEL")
    if [ "$chat_model" != "$CONFIG_REGISTRY_CHAT_MODEL" ]; then
        CONFIG_REGISTRY_CHAT_MODEL="$chat_model"
        CONFIG_REGISTRY_CHAT_URL=$(ask_input "  API URL" "$CONFIG_REGISTRY_CHAT_URL")
    fi
    CONFIG_REGISTRY_CHAT_APIKEY=$(ask_input "  API Key" "$CONFIG_REGISTRY_CHAT_APIKEY")
fi

# Step 4: LLM Configuration for Orchestration Center
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo ""
    log_step "[4/4] Orchestration Center LLM Configuration (press Enter to use default):"
    
    echo ""
    log_info "Chat Model:"
    orch_chat_model=$(ask_input "  Model name" "$CONFIG_ORCH_CHAT_MODEL")
    if [ "$orch_chat_model" != "$CONFIG_ORCH_CHAT_MODEL" ]; then
        CONFIG_ORCH_CHAT_MODEL="$orch_chat_model"
        CONFIG_ORCH_CHAT_URL=$(ask_input "  API URL" "$CONFIG_ORCH_CHAT_URL")
    fi
    CONFIG_ORCH_CHAT_APIKEY=$(ask_input "  API Key" "$CONFIG_ORCH_CHAT_APIKEY")
    
    echo ""
    log_info "A2AT Model:"
    orch_a2at_model=$(ask_input "  Model name" "$CONFIG_ORCH_A2AT_MODEL")
    if [ "$orch_a2at_model" != "$CONFIG_ORCH_A2AT_MODEL" ]; then
        CONFIG_ORCH_A2AT_MODEL="$orch_a2at_model"
        CONFIG_ORCH_A2AT_URL=$(ask_input "  API URL" "$CONFIG_ORCH_A2AT_URL")
    fi
    CONFIG_ORCH_A2AT_APIKEY=$(ask_input "  API Key" "$CONFIG_ORCH_A2AT_APIKEY")
fi

# ===== Summary =====
echo ""
echo "=========================================="
echo "  Configuration Summary"
echo "=========================================="
echo ""
echo "  Components:"
if [ "$CONFIG_REGISTRY" = true ]; then
    echo "    - Registry Center"
fi
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo "    - Orchestration Center"
    echo "    - Workflow Designer"
fi

echo ""
echo "  LLM Configuration:"
if [ "$CONFIG_REGISTRY" = true ]; then
    echo "    Registry Center:"
    echo "      Chat:   $CONFIG_REGISTRY_CHAT_MODEL"
fi
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo "    Orchestration Center:"
    echo "      Chat:   $CONFIG_ORCH_CHAT_MODEL"
    echo "      A2AT:   $CONFIG_ORCH_A2AT_MODEL"
fi
echo ""
echo "=========================================="
echo ""

if ! ask_yes_no "Proceed with setup?" "yes"; then
    log_info "Setup cancelled"
    exit 0
fi

# ===== Execute Setup =====

log_step "Using pre-built images from $CONFIG_IMAGE_REGISTRY"

# Deploy with Helm
log_step "Deploying with Helm..."

HELM_ARGS=""
if [ "$CONFIG_REGISTRY" = true ]; then
    HELM_ARGS="$HELM_ARGS --set registry.enabled=true"
else
    HELM_ARGS="$HELM_ARGS --set registry.enabled=false"
fi
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    HELM_ARGS="$HELM_ARGS --set orchestration.enabled=true --set frontend.enabled=true"
else
    HELM_ARGS="$HELM_ARGS --set orchestration.enabled=false --set frontend.enabled=false"
fi

if [ "$CONFIG_REGISTRY" = true ]; then
    HELM_ARGS="$HELM_ARGS --set registry.image.repository=$CONFIG_IMAGE_REGISTRY/$CONFIG_IMAGE_NAMESPACE/registry-center"
    HELM_ARGS="$HELM_ARGS --set registry.image.tag=$CONFIG_TAG"
    
    # Registry LLM Chat
    if [ -n "$CONFIG_REGISTRY_CHAT_MODEL" ]; then
        HELM_ARGS="$HELM_ARGS --set registry.llm.chat.model=$CONFIG_REGISTRY_CHAT_MODEL"
        if [ -n "$CONFIG_REGISTRY_CHAT_URL" ]; then
            HELM_ARGS="$HELM_ARGS --set registry.llm.chat.url=$CONFIG_REGISTRY_CHAT_URL"
        fi
        if [ -n "$CONFIG_REGISTRY_CHAT_APIKEY" ]; then
            HELM_ARGS="$HELM_ARGS --set registry.llm.chat.apiKey=$CONFIG_REGISTRY_CHAT_APIKEY"
        fi
    fi
fi

if [ "$CONFIG_ORCHESTRATION" = true ]; then
    HELM_ARGS="$HELM_ARGS --set orchestration.image.repository=$CONFIG_IMAGE_REGISTRY/$CONFIG_IMAGE_NAMESPACE/orchestration-center"
    HELM_ARGS="$HELM_ARGS --set orchestration.image.tag=$CONFIG_TAG"
    HELM_ARGS="$HELM_ARGS --set frontend.image.repository=$CONFIG_IMAGE_REGISTRY/$CONFIG_IMAGE_NAMESPACE/workflow-designer"
    HELM_ARGS="$HELM_ARGS --set frontend.image.tag=$CONFIG_TAG"
    
    # Orchestration LLM Chat
    if [ -n "$CONFIG_ORCH_CHAT_MODEL" ]; then
        HELM_ARGS="$HELM_ARGS --set orchestration.llm.chat.model=$CONFIG_ORCH_CHAT_MODEL"
        if [ -n "$CONFIG_ORCH_CHAT_URL" ]; then
            HELM_ARGS="$HELM_ARGS --set orchestration.llm.chat.url=$CONFIG_ORCH_CHAT_URL"
        fi
        if [ -n "$CONFIG_ORCH_CHAT_APIKEY" ]; then
            HELM_ARGS="$HELM_ARGS --set orchestration.llm.chat.apiKey=$CONFIG_ORCH_CHAT_APIKEY"
        fi
    fi
    
    # Orchestration A2AT
    if [ -n "$CONFIG_ORCH_A2AT_PROVIDER" ]; then
        HELM_ARGS="$HELM_ARGS --set orchestration.a2at.provider=$CONFIG_ORCH_A2AT_PROVIDER"
    fi
    if [ -n "$CONFIG_ORCH_A2AT_MODEL" ]; then
        HELM_ARGS="$HELM_ARGS --set orchestration.a2at.model=$CONFIG_ORCH_A2AT_MODEL"
        if [ -n "$CONFIG_ORCH_A2AT_URL" ]; then
            HELM_ARGS="$HELM_ARGS --set orchestration.a2at.baseUrl=$CONFIG_ORCH_A2AT_URL"
        fi
        if [ -n "$CONFIG_ORCH_A2AT_APIKEY" ]; then
            HELM_ARGS="$HELM_ARGS --set orchestration.a2at.apiKey=$CONFIG_ORCH_A2AT_APIKEY"
        fi
    fi
fi

HELM_ARGS="$HELM_ARGS --set postgresql.password=$CONFIG_DB_PASSWORD"
HELM_ARGS="$HELM_ARGS --set ingress.host=$CONFIG_INGRESS_HOST"

# Check if default StorageClass exists
if kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | grep -q .; then
    log_info "Default StorageClass found, using existing storage"
else
    log_info "No default StorageClass found, creating local storage"
    HELM_ARGS="$HELM_ARGS --set postgresql.storage.createStorageClass=true"
    HELM_ARGS="$HELM_ARGS --set postgresql.storage.createPV=true"
    HELM_ARGS="$HELM_ARGS --set postgresql.storage.useHostPath=true"
    HELM_ARGS="$HELM_ARGS --set postgresql.storage.hostPath=/data/openan-postgres"
fi

cd "$CHART_DIR"

# Check if release already exists
if helm status openan -n "$CONFIG_K8S_NAMESPACE" &>/dev/null 2>&1; then
    log_info "Upgrading existing release..."
    if ! helm upgrade openan . \
        -n "$CONFIG_K8S_NAMESPACE" \
        $HELM_ARGS; then
        log_error "Helm upgrade failed"
        exit 1
    fi
else
    log_info "Installing new release..."
    if ! helm install openan . \
        -n "$CONFIG_K8S_NAMESPACE" \
        --create-namespace \
        $HELM_ARGS; then
        log_error "Helm install failed"
        exit 1
    fi
fi

# ===== Start Agents Server =====
if [ "$CONFIG_ORCHESTRATION" = true ]; then
    echo ""
    log_step "Waiting for Orchestration Center to be ready..."
    
    # Wait for orchestration-center pod to be running
    kubectl wait --for=condition=ready pod -l app=orchestration-center -n "$CONFIG_K8S_NAMESPACE" --timeout=300s
    
    # Get the first orchestration-center pod name
    ORCH_POD=$(kubectl get pods -l app=orchestration-center -n "$CONFIG_K8S_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
    
    if [ -n "$ORCH_POD" ]; then
        log_info "Starting agents server in $ORCH_POD..."
        kubectl exec "$ORCH_POD" -n "$CONFIG_K8S_NAMESPACE" -- /bin/sh -c "PYTHONPATH=. python3 samples/start_agents_server.py"
    else
        log_warn "Could not find orchestration-center pod"
    fi
fi

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
echo "    kubectl -n $CONFIG_K8S_NAMESPACE get pods"
echo "    kubectl -n $CONFIG_K8S_NAMESPACE get ingress"
echo ""
echo "  Uninstall:"
echo "    helm uninstall openan -n $CONFIG_K8S_NAMESPACE"
echo ""
