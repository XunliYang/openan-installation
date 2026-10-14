#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Interactive front door for the online install: preflight, targets, images,
# infrastructure, guided application configuration and deploy. Configuration
# and every secret stay in configure.py (kubectl stdin); this script only
# orchestrates and never echoes credentials.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Interactive prompts (and configure.py's secret collection) need a terminal;
# automation should use one_click_install.sh --values instead.
[ -t 0 ] || { echo "install.sh is interactive and requires a terminal; use one_click_install.sh --values for automation" >&2; exit 2; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }

usage() {
    cat <<'EOF'
Usage: ./install.sh

Interactive OpenAN online install in six phases:
  [1/6] preflight       kubectl / helm / python3 and cluster reachability
  [2/6] targets         Helm release name and namespace
  [3/6] images          build from source or reuse an already-pushed tag
  [4/6] infrastructure  MetalLB + ingress-nginx (pinned, skipped when present)
  [5/6] application     guided configuration (components, SQL, models, signing, admin)
  [6/6] deploy          helm upgrade --install and access summary

Secrets are collected only by configure.py and reach Kubernetes via kubectl stdin.
For prepared environments use the flag-driven variant: one_click_install.sh --help
EOF
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-yes}"
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
    local default="${2:-}"
    local value

    if [ -n "$default" ]; then
        log_prompt "$prompt [$default]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    read -r value
    echo "${value:-$default}"
}

NAME_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'

ask_name() {
    local prompt="$1"
    local default="$2"
    local value

    for _ in 1 2 3; do
        value="$(ask_input "$prompt" "$default")"
        if [[ "$value" =~ $NAME_RE && ${#value} -le 53 ]]; then
            echo "$value"
            return 0
        fi
        log_error "Invalid value: lower-case alphanumerics and '-', starting/ending alphanumeric, at most 53 characters"
    done
    return 1
}

case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    "") ;;
    *) echo "install.sh is interactive and takes no options: $1 (see --help)" >&2; exit 2 ;;
esac

echo ""
echo "=========================================="
echo "  OpenAN Platform - Interactive Install"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# [1/6] Preflight
# ---------------------------------------------------------------------------
log_step "[1/6] Preflight"
for tool in kubectl helm python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        log_error "Required tool not found: $tool"
        exit 2
    fi
done
if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "Kubernetes cluster unreachable: kubectl cluster-info failed"
    exit 2
fi
KUBECTL_CLIENT="$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
log_info "kubectl client version: ${KUBECTL_CLIENT:-unknown}"

# ---------------------------------------------------------------------------
# [2/6] Targets
# ---------------------------------------------------------------------------
log_step "[2/6] Targets"
if ! RELEASE="$(ask_name "Release name" "openan")"; then
    log_error "No valid release name after 3 attempts"
    exit 2
fi
if ! NAMESPACE="$(ask_name "Namespace" "openan")"; then
    log_error "No valid namespace after 3 attempts"
    exit 2
fi

# ---------------------------------------------------------------------------
# [3/6] Images
# ---------------------------------------------------------------------------
log_step "[3/6] Images"
# The tag has no default on purpose: the deployment contract states old v1.0.0
# images are not compatible with the current chart, so it must be explicit.
APP_TAG=""
for _ in 1 2 3; do
    APP_TAG="$(ask_input "Application image tag (no default; see the deployment contract)" "")"
    [ -n "$APP_TAG" ] && break
    log_warn "The image tag is required"
done
[ -n "$APP_TAG" ] || { log_error "No image tag given"; exit 2; }
if ask_yes_no "Build images from source now?" "no"; then
    RC_SOURCE_URL="$(ask_input "registry-center source archive URL")"
    OC_SOURCE_URL="$(ask_input "orchestration-center source archive URL")"
    if [ -z "$RC_SOURCE_URL" ] || [ -z "$OC_SOURCE_URL" ]; then
        log_error "Building requires both source archive URLs at accepted revisions"
        exit 2
    fi
    bash "$SCRIPT_DIR/../build/build.sh" --tag "$APP_TAG" \
        --registry-release "$RC_SOURCE_URL" --orchestration-release "$OC_SOURCE_URL"
else
    log_info "Using already-pushed tag: $APP_TAG"
fi
log_info "Application image tag: $APP_TAG"

# ---------------------------------------------------------------------------
# [4/6] Infrastructure
# ---------------------------------------------------------------------------
log_step "[4/6] Infrastructure"
METALLB_PRESENT=false
INGRESS_PRESENT=false
if kubectl get namespace metallb-system >/dev/null 2>&1; then
    METALLB_PRESENT=true
fi
if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
    INGRESS_PRESENT=true
fi
if [ "$METALLB_PRESENT" = true ] && [ "$INGRESS_PRESENT" = true ]; then
    log_info "MetalLB and ingress-nginx already installed, skipping"
else
    if ask_yes_no "Install MetalLB + ingress-nginx automatically (pinned versions)?" "yes"; then
        log_info "Applying ingress-nginx controller-v1.15.1"
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml
        log_info "Applying MetalLB v0.16.1"
        kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml
        log_info "Waiting for MetalLB CRDs (up to 60s)"
        CRD_READY=false
        for _ in $(seq 1 12); do
            if kubectl get crd ipaddresspools.metallb.io >/dev/null 2>&1; then
                CRD_READY=true
                break
            fi
            sleep 5
        done
        if [ "$CRD_READY" != true ]; then
            log_error "MetalLB CRDs (ipaddresspools.metallb.io) not available after 60s"
            exit 1
        fi
        METALLB_POOL=""
        for _ in 1 2 3; do
            METALLB_POOL="$(ask_input "MetalLB IP pool (e.g. 192.168.1.200-192.168.1.250 or a CIDR, leave empty to skip)" "")"
            [ -z "$METALLB_POOL" ] && break
            if printf '%s' "$METALLB_POOL" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(-([0-9]{1,3}\.){3}[0-9]{1,3}|/[0-9]{1,2})?$'; then
                break
            fi
            log_warn "Pool must be an IP range (a.b.c.d-a.b.c.d) or a CIDR (a.b.c.d/n)"
            METALLB_POOL=""
        done
        if [ -n "$METALLB_POOL" ]; then
            log_info "Configuring MetalLB pool: $METALLB_POOL"
            kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: openan-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: openan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - openan-pool
EOF
        else
            log_warn "No MetalLB pool configured; LoadBalancer IPs stay pending on bare metal"
        fi
    else
        log_warn "Install MetalLB/ingress-nginx yourself, or rerun and answer yes; see QUICKSTART.md"
    fi
fi

# ---------------------------------------------------------------------------
# [5/6] Application
# ---------------------------------------------------------------------------
log_step "[5/6] Application"
VALUES="$PWD/deployment.generated.json"
if [ -e "$VALUES" ]; then
    log_warn "Found existing $VALUES"
    if ask_yes_no "Regenerate the configuration from scratch (removes this file and re-runs the wizard)?" "no"; then
        rm "$VALUES"
    else
        log_info "Keeping $VALUES; deploy it with one_click_install.sh --values or helm directly"
        exit 0
    fi
fi
python3 "$SCRIPT_DIR/configure.py" --namespace "$NAMESPACE" --release "$RELEASE" --tag "$APP_TAG" --output "$VALUES"
log_info "Linting the chart against the generated values"
helm lint "$SCRIPT_DIR/openan-chart" --namespace "$NAMESPACE" --values "$VALUES"

# ---------------------------------------------------------------------------
# [6/6] Deploy
# ---------------------------------------------------------------------------
log_step "[6/6] Deploy"
if ! helm upgrade --install "$RELEASE" "$SCRIPT_DIR/openan-chart" \
        --namespace "$NAMESPACE" --create-namespace --values "$VALUES" \
        --wait --timeout 10m; then
    log_error "Helm deploy failed; inspect with: kubectl -n $NAMESPACE get pods"
    exit 1
fi

# Access summary: LoadBalancer IP preferred, NodePort fallback (no secrets).
INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

SCHEME="http"
INGRESS_HOST=""
ORCHESTRATION_ENABLED=true
FRONTEND_ENABLED=true
while read -r key value; do
    case "$key" in
        scheme) SCHEME="$value" ;;
        host) INGRESS_HOST="$value" ;;
        orchestration) ORCHESTRATION_ENABLED="$value" ;;
        frontend) FRONTEND_ENABLED="$value" ;;
    esac
done < <(python3 - "$VALUES" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    values = json.load(stream)
ingress = values.get("ingress") or {}
print("scheme", "https" if (ingress.get("tls") or {}).get("enabled") else "http")
print("host", ingress.get("host") or "")
print("orchestration", str(bool((values.get("orchestration") or {}).get("enabled", True))).lower())
print("frontend", str(bool((values.get("frontend") or {}).get("enabled", True))).lower())
PY
)

echo ""
echo "=========================================="
echo "  Install complete"
echo "=========================================="
if [ -n "$INGRESS_IP" ]; then
    if [ -n "$INGRESS_HOST" ]; then
        echo "  Platform:   ${SCHEME}://${INGRESS_HOST}/"
        echo "  Ingress IP: ${INGRESS_IP} (point DNS or an /etc/hosts entry for ${INGRESS_HOST} at it)"
    else
        echo "  Platform: ${SCHEME}://${INGRESS_IP}/"
    fi
    if [ "$SCHEME" = "https" ]; then
        echo "  HTTPS: enabled in values (ingress.tls)"
    fi
else
    NODE_PORT="$(kubectl -n "$NAMESPACE" get svc workflow-designer \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
    if [ -n "$NODE_PORT" ] && [ "$FRONTEND_ENABLED" = true ]; then
        NODE_IP="$(kubectl get nodes \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
        if [ -n "$NODE_IP" ]; then
            echo "  Platform (NodePort): http://${NODE_IP}:${NODE_PORT}/"
            echo "  No LoadBalancer IP; the NodePort serves the frontend only"
        else
            echo "  NodePort: ${NODE_PORT} (node IP could not be detected)"
        fi
    else
        log_warn "No LoadBalancer IP and no frontend NodePort (frontend disabled or not ready)"
    fi
fi
if [ "$ORCHESTRATION_ENABLED" = true ]; then
    echo "  Login:     use the admin account configured in the wizard, then change the password in the web UI"
fi
echo "  Status:    kubectl -n $NAMESPACE get pods"
echo "  Ingress:   kubectl -n $NAMESPACE get ingress"
echo "  Uninstall: helm uninstall $RELEASE -n $NAMESPACE (or bash $SCRIPT_DIR/uninstall.sh)"
echo ""
