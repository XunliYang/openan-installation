#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# OpenAN offline installer (Kubernetes).
#
# Assumes a Kubernetes cluster (kubeadm, v1.34+) is already running and that
# this script is executed on a node with kubectl access and a working containerd
# (root). It never uses the internet and never edits the OS or container runtime
# configuration.
#
#   scripts/install.sh                       # interactive
#   scripts/install.sh --config config.env   # non-interactive
#   scripts/install.sh --config config.env --yes --skip-check

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE=""
SKIP_CHECK="false"
ASSUME_YES="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --config)     CONFIG_FILE="$2"; shift 2 ;;
        --yes|-y)     ASSUME_YES="true"; shift ;;
        --skip-check) SKIP_CHECK="true"; shift ;;
        -h|--help)    sed -n '2,18p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done
export ASSUME_YES

# --- Defaults (mirrors config.env.example) -----------------------------------
K8S_NAMESPACE="openan"
INSTALL_REGISTRY="true"
REGISTRY_NODE=""
REGISTRY_NODE_IP=""
REGISTRY_NODEPORT="30500"
INSTALL_METALLB="true"
METALLB_POOL=""
INGRESS_HOST=""
STORAGE_MODE="auto"
STORAGE_CLASS=""
STORAGE_SIZE="20Gi"
HOSTPATH="/data/openan-postgres"
STORAGE_NODE=""
DB_TYPE="postgresql"
DB_PASSWORD="openan-db-password"
REGISTRY_CENTER_IMAGE="project-openan/registry-center:v1.0.0"
ORCHESTRATION_CENTER_IMAGE="project-openan/orchestration-center:v1.0.0"
WORKFLOW_DESIGNER_IMAGE="project-openan/workflow-designer:v1.0.0"
POSTGRES_IMAGE="library/postgres:15-alpine"
MYSQL_IMAGE="library/mysql:8.4.3"
REGISTRY_CHAT_MODEL=""
REGISTRY_CHAT_URL=""
REGISTRY_CHAT_APIKEY=""
ORCH_CHAT_MODEL=""
ORCH_CHAT_URL=""
ORCH_CHAT_APIKEY=""
LLM_VALIDATE="false"
START_AGENTS_SERVER="false"

[ -n "$CONFIG_FILE" ] && load_config "$CONFIG_FILE"

case "$DB_TYPE" in
    postgresql|mysql) ;;
    *) log_error "Invalid DB_TYPE: $DB_TYPE (use postgresql|mysql)"; exit 2 ;;
esac

ARCH="$(detect_arch)"
[ -n "$ARCH" ] || { log_error "unsupported architecture: $(uname -m)"; exit 1; }

# --- Tool resolution (prefer bundled binaries) -------------------------------
resolve_tool() {
    local name="$1"
    local bundled="$BUNDLE_DIR/deps/bin/${name}-linux-${ARCH}"
    if [ -x "$bundled" ]; then echo "$bundled"; return; fi
    if have "$name"; then echo "$name"; return; fi
    echo ""
}

KUBECTL="$(resolve_tool kubectl)"
HELM="$(resolve_tool helm)"
CRANE=""
[ -x "$BUNDLE_DIR/deps/bin/crane-linux-$ARCH" ] && CRANE="$BUNDLE_DIR/deps/bin/crane-linux-$ARCH"

if [ -z "$KUBECTL" ]; then log_error "kubectl not found (bundled or PATH)"; exit 1; fi
if [ -z "$HELM" ]; then log_error "helm not found (bundled or PATH)"; exit 1; fi
log_info "kubectl: $KUBECTL"
log_info "helm:    $HELM"

# ---------------------------------------------------------------------------
# 1. Environment check
# ---------------------------------------------------------------------------
if [ "$SKIP_CHECK" != "true" ]; then
    log_step "[1/7] Checking environment"
    check_args=()
    [ -n "$CONFIG_FILE" ] && check_args+=(--config "$CONFIG_FILE")
    if ! "$SCRIPT_DIR/check-env.sh" "${check_args[@]}"; then
        log_error "Environment check failed. Fix the items above and re-run,"
        log_error "or pass --skip-check to proceed at your own risk."
        exit 1
    fi
else
    log_warn "Skipping environment check (--skip-check)"
fi

# ---------------------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------------------
if [ "$ASSUME_YES" != "true" ] && [ -z "$CONFIG_FILE" ]; then
    log_step "[2/7] Configuration"
    K8S_NAMESPACE="$(ask_input "  Kubernetes namespace" "$K8S_NAMESPACE")"
    INSTALL_METALLB_ANS="$(ask_input "  Install MetalLB for LoadBalancer? (true/false)" "$INSTALL_METALLB")"
    INSTALL_METALLB="$INSTALL_METALLB_ANS"
    if [ "$INSTALL_METALLB" = "true" ]; then
        METALLB_POOL="$(ask_input "  MetalLB IP pool (e.g. 192.168.1.200-192.168.1.250)" "$METALLB_POOL")"
    fi
    INGRESS_HOST="$(ask_input "  Ingress host (empty = access by IP)" "$INGRESS_HOST")"
    DB_TYPE="$(ask_choice "  Database backend:" "postgresql" "mysql")"
    DB_PASSWORD="$(ask_input_secret "  Database password" "$DB_PASSWORD")"
    REGISTRY_CHAT_MODEL="$(ask_input "  Registry Center chat model" "$REGISTRY_CHAT_MODEL")"
    REGISTRY_CHAT_URL="$(ask_input "  Registry Center chat URL" "$REGISTRY_CHAT_URL")"
    if [ -n "$REGISTRY_CHAT_URL" ]; then
        REGISTRY_CHAT_APIKEY="$(ask_input_secret "  Registry Center API key" "")"
    fi
    ORCH_CHAT_MODEL="$(ask_input "  Orchestration Center chat model" "$ORCH_CHAT_MODEL")"
    ORCH_CHAT_URL="$(ask_input "  Orchestration Center chat URL" "$ORCH_CHAT_URL")"
    if [ -n "$ORCH_CHAT_URL" ]; then
        ORCH_CHAT_APIKEY="$(ask_input_secret "  Orchestration Center API key" "")"
    fi
    LLM_VALIDATE_ANS="$(ask_input "  Validate LLM connectivity now? (true/false)" "$LLM_VALIDATE")"
    LLM_VALIDATE="$LLM_VALIDATE_ANS"
fi

if [ -z "$REGISTRY_NODE" ]; then
    REGISTRY_NODE="$(hostname | tr '[:upper:]' '[:lower:]')"
fi
if [ -z "$REGISTRY_NODE_IP" ]; then
    REGISTRY_NODE_IP="$(default_ip)"
fi
if [ -z "$STORAGE_NODE" ]; then
    STORAGE_NODE="$REGISTRY_NODE"
fi
REG_HOST="${REGISTRY_NODE_IP}:${REGISTRY_NODEPORT}"

# ---------------------------------------------------------------------------
# 3. Summary + confirm
# ---------------------------------------------------------------------------
REF_REPO() { echo "${1%:*}"; }
REF_TAG()  { echo "${1##*:}"; }

echo ""
echo "=========================================="
echo "  Offline installation summary"
echo "=========================================="
echo "  Architecture:     $ARCH"
echo "  Namespace:        $K8S_NAMESPACE"
echo "  Registry:         $REG_HOST (node: $REGISTRY_NODE)"
echo "  MetalLB:          $INSTALL_METALLB ${METALLB_POOL:+($METALLB_POOL)}"
echo "  Storage mode:     $STORAGE_MODE (node: $STORAGE_NODE, size: $STORAGE_SIZE)"
echo "  Database:         $DB_TYPE"
echo "  Ingress host:     ${INGRESS_HOST:-<none, IP access>}"
echo "  Registry center:  $REGISTRY_CENTER_IMAGE"
echo "  Orchestration:    $ORCHESTRATION_CENTER_IMAGE"
echo "  Workflow designer:$WORKFLOW_DESIGNER_IMAGE"
echo "=========================================="
echo ""

if ! ask_yes_no "Proceed with deployment?" "yes"; then
    log_info "Cancelled."
    exit 0
fi

# Persist the effective configuration for repeatability.
save_config "$BUNDLE_DIR/config.env"

# ---------------------------------------------------------------------------
# 4. Private registry (in-cluster)
# ---------------------------------------------------------------------------
log_step "[4/7] Private registry"

if [ "$INSTALL_REGISTRY" != "true" ]; then
    log_warn "INSTALL_REGISTRY=false — assuming an external registry at $REG_HOST"
else
    local_host="$(hostname | tr '[:upper:]' '[:lower:]')"
    if [ "$local_host" != "$REGISTRY_NODE" ]; then
        log_error "The registry must run on the node where install.sh is executed."
        log_error "You are on '$local_host' but REGISTRY_NODE='$REGISTRY_NODE'."
        log_error "Either run install.sh on $REGISTRY_NODE or set REGISTRY_NODE=$local_host."
        exit 1
    fi

    # Bootstrap: the registry image must exist locally before the registry exists.
    registry_tar="$BUNDLE_DIR/images/registry-2-${ARCH}.tar"
    if [ ! -r "$registry_tar" ]; then
        log_error "Missing $registry_tar (needed to bootstrap the registry)"
        exit 1
    fi
    if ctr -n k8s.io images ls -q 2>/dev/null | grep -q "docker.io/library/registry:2"; then
        log_info "registry:2 already present in containerd, skipping import"
    else
        log_info "Importing registry:2 into containerd..."
        ctr -n k8s.io images import "$registry_tar" >/dev/null || {
            log_error "Failed to import registry:2. Are you root?"
            exit 1
        }
    fi

    "$KUBECTL" get namespace "$K8S_NAMESPACE" >/dev/null 2>&1 || \
        "$KUBECTL" create namespace "$K8S_NAMESPACE"

    "$KUBECTL" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openan-registry
  namespace: ${K8S_NAMESPACE}
  labels:
    app: openan-registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: openan-registry
  template:
    metadata:
      labels:
        app: openan-registry
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${REGISTRY_NODE}
      containers:
      - name: registry
        image: docker.io/library/registry:2
        imagePullPolicy: Never
        env:
        - name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY
          value: /var/lib/registry
        - name: REGISTRY_HTTP_ADDR
          value: 0.0.0.0:5000
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
        readinessProbe:
          httpGet:
            path: /v2/
            port: 5000
          initialDelaySeconds: 3
          periodSeconds: 5
      volumes:
      - name: data
        hostPath:
          path: /data/openan-registry
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: openan-registry
  namespace: ${K8S_NAMESPACE}
spec:
  type: NodePort
  selector:
    app: openan-registry
  ports:
  - name: registry
    port: 5000
    targetPort: 5000
    nodePort: ${REGISTRY_NODEPORT}
    protocol: TCP
EOF

    log_info "Waiting for the registry to become ready..."
    ok="false"
    for _ in $(seq 1 30); do
        if curl -sf -m 3 "http://${REG_HOST}/v2/" >/dev/null 2>&1; then ok="true"; break; fi
        sleep 4
    done
    if [ "$ok" != "true" ]; then
        log_error "Registry did not come up at http://${REG_HOST}/v2/"
        "$KUBECTL" -n "$K8S_NAMESPACE" get pods -l app=openan-registry
        exit 1
    fi
    log_info "Registry is up at ${REG_HOST}"
fi

# ---------------------------------------------------------------------------
# 5. Push images + install cluster add-ons
# ---------------------------------------------------------------------------
log_step "[5/7] Pushing images and installing add-ons"

if [ -z "$CRANE" ] && ! have crane; then
    log_error "crane not found — cannot push images (expected deps/bin/crane-linux-$ARCH)"
    exit 1
fi
"$SCRIPT_DIR/push-images.sh" --config "$BUNDLE_DIR/config.env" || {
    log_error "Image push failed"
    exit 1
}

# --- MetalLB ----------------------------------------------------------------
if [ "$INSTALL_METALLB" = "true" ]; then
    if "$KUBECTL" get namespace metallb-system >/dev/null 2>&1; then
        log_info "MetalLB already installed, skipping"
    else
        log_info "Installing MetalLB offline..."
        sed -e "s|quay.io/metallb/|${REG_HOST}/metallb/|g" \
            -e "s|@sha256:[a-f0-9]*||g" \
            "$BUNDLE_DIR/deps/manifests/metallb-native.yaml" >/tmp/openan-metallb.yaml
        "$KUBECTL" apply -f /tmp/openan-metallb.yaml >/dev/null || { log_error "MetalLB apply failed"; exit 1; }
        "$KUBECTL" -n metallb-system rollout status deploy/metallb-controller --timeout=180s || true
        for _ in $(seq 1 24); do
            "$KUBECTL" get crd ipaddresspools.metallb.io >/dev/null 2>&1 && break
            sleep 5
        done
    fi
    if [ -z "$METALLB_POOL" ]; then
        log_error "METALLB_POOL is empty — cannot configure the LoadBalancer pool"
        exit 1
    fi
    log_info "Configuring MetalLB pool $METALLB_POOL"
    "$KUBECTL" apply -f - <<EOF
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
fi

# --- ingress-nginx ----------------------------------------------------------
if "$KUBECTL" get ns ingress-nginx >/dev/null 2>&1; then
    log_info "ingress-nginx already installed, skipping"
else
    log_info "Installing ingress-nginx offline..."
    sed -e "s|registry.k8s.io/ingress-nginx/|${REG_HOST}/ingress-nginx/|g" \
        -e "s|@sha256:[a-f0-9]*||g" \
        "$BUNDLE_DIR/deps/manifests/ingress-nginx.yaml" >/tmp/openan-ingress.yaml
    "$KUBECTL" apply -f /tmp/openan-ingress.yaml >/dev/null || { log_error "ingress-nginx apply failed"; exit 1; }
    "$KUBECTL" -n ingress-nginx wait --for=condition=ready pod \
        -l app.kubernetes.io/component=controller --timeout=300s || true
fi

# --- LoadBalancer IP --------------------------------------------------------
INGRESS_IP=""
if "$KUBECTL" get svc -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
    svc_type="$("$KUBECTL" get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.type}' 2>/dev/null)"
    if [ "$svc_type" != "LoadBalancer" ] && [ "$INSTALL_METALLB" = "true" ]; then
        log_info "Switching ingress-nginx Service to LoadBalancer"
        "$KUBECTL" patch svc -n ingress-nginx ingress-nginx-controller -p '{"spec":{"type":"LoadBalancer"}}'
    fi
    if [ "$INSTALL_METALLB" = "true" ] || [ "$svc_type" = "LoadBalancer" ]; then
        log_info "Waiting for a LoadBalancer IP..."
        for _ in $(seq 1 36); do
            INGRESS_IP="$("$KUBECTL" get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
            [ -n "$INGRESS_IP" ] && break
            sleep 5
        done
    fi
fi
[ -n "$INGRESS_IP" ] && log_info "Ingress LoadBalancer IP: $INGRESS_IP" || log_warn "No LoadBalancer IP assigned (will fall back to NodePort access)"

# ---------------------------------------------------------------------------
# 6. Deploy OpenAN with Helm
# ---------------------------------------------------------------------------
log_step "[6/7] Deploying OpenAN"

VALUES="$BUNDLE_DIR/config.values.yaml"
{
    echo "namespace: ${K8S_NAMESPACE}"
    echo "database:"
    echo "  type: ${DB_TYPE}"
    echo "postgresql:"
    if [ "$DB_TYPE" = "mysql" ]; then
        echo "  enabled: false"
    else
        echo "  enabled: true"
        echo "  password: \"${DB_PASSWORD}\""
        echo "  image: \"${REG_HOST}/${POSTGRES_IMAGE}\""
        echo "  storage:"
        echo "    size: ${STORAGE_SIZE}"
        if [ "$STORAGE_MODE" = "sc" ] || { [ "$STORAGE_MODE" = "auto" ] && [ -n "$STORAGE_CLASS" ]; }; then
            echo "    storageClassName: \"${STORAGE_CLASS}\""
        fi
        if [ "$STORAGE_MODE" = "hostpath" ] || [ "$STORAGE_MODE" = "auto" ]; then
            echo "    createPV: true"
            echo "    useHostPath: true"
            echo "    hostPath: \"${HOSTPATH}\""
            echo "    nodeName: ${STORAGE_NODE}"
        fi
    fi
    echo "mysql:"
    if [ "$DB_TYPE" = "mysql" ]; then
        MYSQL_HOSTPATH="${HOSTPATH}"
        [ "$MYSQL_HOSTPATH" = "/data/openan-postgres" ] && MYSQL_HOSTPATH="/data/openan-mysql"
        echo "  enabled: true"
        echo "  password: \"${DB_PASSWORD}\""
        echo "  image: \"${REG_HOST}/${MYSQL_IMAGE}\""
        echo "  storage:"
        echo "    size: ${STORAGE_SIZE}"
        if [ "$STORAGE_MODE" = "sc" ] || { [ "$STORAGE_MODE" = "auto" ] && [ -n "$STORAGE_CLASS" ]; }; then
            echo "    storageClassName: \"${STORAGE_CLASS}\""
        fi
        if [ "$STORAGE_MODE" = "hostpath" ] || [ "$STORAGE_MODE" = "auto" ]; then
            echo "    createPV: true"
            echo "    useHostPath: true"
            echo "    hostPath: \"${MYSQL_HOSTPATH}\""
            echo "    nodeName: ${STORAGE_NODE}"
        fi
    else
        echo "  enabled: false"
    fi
    echo "registry:"
    echo "  enabled: true"
    echo "  replicas: 2"
    echo "  image:"
    echo "    repository: ${REG_HOST}/$(REF_REPO "$REGISTRY_CENTER_IMAGE")"
    echo "    tag: $(REF_TAG "$REGISTRY_CENTER_IMAGE")"
    echo "    pullPolicy: IfNotPresent"
    if [ -n "$REGISTRY_CHAT_MODEL" ]; then
        echo "  llm:"
        echo "    chat:"
        echo "      model: \"${REGISTRY_CHAT_MODEL}\""
        echo "      url: \"${REGISTRY_CHAT_URL}\""
        echo "      apiKey: \"${REGISTRY_CHAT_APIKEY}\""
    fi
    echo "orchestration:"
    echo "  enabled: true"
    echo "  replicas: 2"
    echo "  image:"
    echo "    repository: ${REG_HOST}/$(REF_REPO "$ORCHESTRATION_CENTER_IMAGE")"
    echo "    tag: $(REF_TAG "$ORCHESTRATION_CENTER_IMAGE")"
    echo "    pullPolicy: IfNotPresent"
    if [ -n "$ORCH_CHAT_MODEL" ]; then
        echo "  llm:"
        echo "    chat:"
        echo "      model: \"${ORCH_CHAT_MODEL}\""
        echo "      url: \"${ORCH_CHAT_URL}\""
        echo "      apiKey: \"${ORCH_CHAT_APIKEY}\""
    fi
    echo "frontend:"
    echo "  enabled: true"
    echo "  replicas: 2"
    echo "  image:"
    echo "    repository: ${REG_HOST}/$(REF_REPO "$WORKFLOW_DESIGNER_IMAGE")"
    echo "    tag: $(REF_TAG "$WORKFLOW_DESIGNER_IMAGE")"
    echo "    pullPolicy: IfNotPresent"
    echo "ingress:"
    echo "  enabled: true"
    echo "  className: nginx"
    echo "  host: \"${INGRESS_HOST}\""
} >"$VALUES"
chmod 600 "$VALUES"

if "$HELM" status openan -n "$K8S_NAMESPACE" >/dev/null 2>&1; then
    log_error "Helm release 'openan' already exists in namespace '$K8S_NAMESPACE'."
    log_error "This version does not support upgrades. Run scripts/uninstall.sh first."
    exit 1
fi

if ! "$HELM" install openan "$BUNDLE_DIR/chart" \
    -n "$K8S_NAMESPACE" --create-namespace \
    -f "$VALUES"; then
    log_error "helm install failed"
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Self-check
# ---------------------------------------------------------------------------
log_step "[7/7] Verifying deployment"

SELFCHECK="ok"
log_info "Waiting for pods to become ready..."
for _ in $(seq 1 60); do
    not_ready="$("$KUBECTL" -n "$K8S_NAMESPACE" get pods --no-headers 2>/dev/null | grep -Evc "Running|Completed")"
    [ "$not_ready" = "0" ] && break
    sleep 5
done
"$KUBECTL" -n "$K8S_NAMESPACE" get pods

if "$KUBECTL" -n "$K8S_NAMESPACE" get pods --no-headers 2>/dev/null | grep -Evq "Running|Completed"; then
    log_error "Some pods are not Running"
    SELFCHECK="fail"
fi

# Registry catalog
catalog="$(curl -sf -m 5 "http://${REG_HOST}/v2/_catalog" 2>/dev/null)"
if [ -n "$catalog" ]; then log_info "Registry catalog: $catalog"; else log_warn "Registry catalog unreachable"; fi

# Optional demo agents server
if [ "$START_AGENTS_SERVER" = "true" ]; then
    log_info "Starting agent examples server (optional)..."
    ORCH_POD="$("$KUBECTL" -n "$K8S_NAMESPACE" get pods -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ -n "$ORCH_POD" ]; then
        "$KUBECTL" exec "$ORCH_POD" -n "$K8S_NAMESPACE" -- /bin/sh -c \
            "cd /opt/orchestration-center && PYTHONPATH=/opt/orchestration-center nohup python3 samples/start_agents_server.py > /tmp/agents-server.log 2>&1 &" 2>/dev/null \
            && log_info "Agents server start requested (verify with: kubectl exec $ORCH_POD -n $K8S_NAMESPACE -- cat /tmp/agents-server.log)" \
            || log_warn "Could not start the agents server (python3/curl may be absent in the image)"
    fi
fi

# API smoke tests
smoke() {
    local url="$1" name="$2"
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$url" 2>/dev/null)"
    if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 500 ] 2>/dev/null; then
        log_info "smoke $name: HTTP $code"
    else
        log_warn "smoke $name: HTTP ${code:-000} ($url)"
    fi
}

echo ""
if [ -n "$INGRESS_IP" ]; then
    echo "  Access URL:  http://${INGRESS_IP}/"
    smoke "http://${INGRESS_IP}/registry/rest/v1/registry-center/agent-cards" "registry"
    smoke "http://${INGRESS_IP}/api/orchestrate/rest/v1/orchestrate/agent-cards" "orchestration"
else
    NODE_PORT="$("$KUBECTL" -n "$K8S_NAMESPACE" get svc workflow-designer -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)"
    NODE_IP="$("$KUBECTL" get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
    echo "  Access URL (NodePort): http://${NODE_IP}:${NODE_PORT}/"
fi
echo ""
echo "  Status:  $KUBECTL -n $K8S_NAMESPACE get pods,ingress,svc"
echo "  Uninstall: scripts/uninstall.sh --config $BUNDLE_DIR/config.env"
echo ""

if [ "$SELFCHECK" != "ok" ]; then
    log_error "Deployment finished with errors — inspect the pods above."
    exit 1
fi
log_info "Installation complete."
