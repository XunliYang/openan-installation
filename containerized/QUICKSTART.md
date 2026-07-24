# OpenAN Platform Quick Start

Build + Deploy one-stop guide, from zero to an accessible OpenAN platform.

## Overall Process

```
Prepare Environment → Build Images → Deploy to K8S → Verify Access → Cleanup
```

## Prerequisites

| Tool | Minimum Version | Purpose |
|------|----------------|---------|
| Docker | 20.10+ | Image building |
| Docker Buildx | 0.8+ | Multi-architecture builds |
| Kubernetes | 1.24+ | Runtime platform |
| kubectl | 1.24+ | K8S command line |
| Helm | 3.x | Deployment management |
| Ingress Controller (Nginx) | - | External access (optional) |
| Git | - | Source code checkout |

## Step 1: Prepare Source Code

```bash
# Clone component source code (select as needed)
git clone https://github.com/openan/registry-center.git
git clone https://github.com/openan/orchestration-center.git
```

> Workflow Designer is located at `orchestration-center/workflow-designer`, no need to clone separately.

## Step 2: Build Images

### Scenario A: Single-node Cluster (Load images directly to local Docker)

```bash
cd containerized/build

# Build all components (current architecture only, no push)
docker buildx build --platform linux/amd64 \
  -t registry-center:latest --load \
  ../../registry-center

docker buildx build --platform linux/amd64 \
  -t orchestration-center:latest --load \
  ../../orchestration-center

docker buildx build --platform linux/amd64 \
  -t workflow-designer:latest --load \
  ../../orchestration-center/workflow-designer
```

> Replace `linux/amd64` with your node architecture (e.g., `linux/arm64`).

### Scenario B: Private Image Registry (Recommended for multi-node / production)

```bash
cd containerized/build

# Use build script, specify private registry and push
./build.sh \
  --registry harbor.example.com \
  --namespace openan \
  --tag v1.0.0 \
  --registry-src ../../registry-center \
  --orchestration-src ../../orchestration-center \
  --push
```

After build, image list:

```
harbor.example.com/openan/registry-center:v1.0.0
harbor.example.com/openan/orchestration-center:v1.0.0
harbor.example.com/openan/workflow-designer:v1.0.0
```

### Scenario C: Using Configuration File

```bash
cd containerized/build

cp build-config.yaml.example build-config.yaml
# Edit build-config.yaml, fill in source paths and registry info
vim build-config.yaml

./build.sh --config build-config.yaml
```

## Step 3: Deploy to Kubernetes

### Method 1: Using Example Configuration File (Recommended for Quick Start)

```bash
cd containerized

# Copy example configuration file
cp values-prod.yaml.example values-custom.yaml

# Edit configuration file, modify the following:
# 1. Image registry address (if using private registry)
# 2. LLM API Key (replace with your own key)
# 3. Ingress host (replace with your domain or IP)
# 4. Database password (change default password)
vim values-custom.yaml

# Deploy
helm install openan ./openan-chart \
  -n openan --create-namespace \
  -f values-custom.yaml
```

**Example Configuration Description:**

`values-prod.yaml.example` contains complete production environment configuration:

- **Image Registry**: Defaults to `leoyy6/registry-center`, `leoyy6/orchestration-center`, `leoyy6/workflow-designer`
- **LLM Models**:
  - Registry Center: `glm-5.1` (Chat), `bge-m3` (Embed), `bge-reranker-v2-m3` (Rerank)
  - Orchestration Center: `qwen3.7-plus` (Chat and A2AT)
- **API Endpoint**: Uses Alibaba Cloud DashScope (`dashscope.aliyuncs.com`)
- **Ingress**: Default domain `openan.local`, NodePort `30191`
- **Replicas**: 2 replicas per component, HPA auto-scaling enabled

**Quick Modification Examples:**

```bash
# Replace image registry with your private registry
sed -i 's|leoyy6/|harbor.example.com/openan/|g' values-custom.yaml

# Replace LLM API Key
sed -i 's|sk-3590ce6c3d2e4111b01f14125bc51fab|sk-your-actual-api-key|g' values-custom.yaml

# Replace Ingress domain
sed -i 's|openan.local|openan.example.com|g' values-custom.yaml
```

### Method 2: Command Line Parameter Override

```bash
cd containerized/openan-chart

helm install openan . \
  -n openan --create-namespace \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0 \
  --set registry.llm.chat.apiKey=sk-your-chat-key \
  --set registry.llm.embed.apiKey=sk-your-embed-key \
  --set registry.llm.rerank.apiKey=sk-your-rerank-key \
  --set orchestration.llm.chat.apiKey=sk-your-chat-key \
  --set orchestration.a2at.apiKey=sk-your-a2at-key \
  --set ingress.host=openan.example.com
```

### Method 3: Single-node Local Images

Ensure K8S nodes can access local Docker images. If using `kind` / `minikube` / `k3s`, load images according to their respective methods.

```bash
cd containerized/openan-chart

helm install openan . \
  -n openan --create-namespace \
  --set registry.llm.chat.apiKey=sk-your-chat-key \
  --set registry.llm.embed.apiKey=sk-your-embed-key \
  --set registry.llm.rerank.apiKey=sk-your-rerank-key \
  --set orchestration.llm.chat.apiKey=sk-your-chat-key \
  --set orchestration.a2at.apiKey=sk-your-a2at-key
```

## Configuration Description

Key configuration items in `values-prod.yaml.example`:

### Required Configuration

| Config Item | Default | Description |
|-------------|---------|-------------|
| `registry.llm.chat.apiKey` | `sk-3590ce6c3d2e4111b01f14125bc51fab` | Registry Center Chat model API Key |
| `orchestration.llm.chat.apiKey` | `sk-3590ce6c3d2e4111b01f14125bc51fab` | Orchestration Center Chat model API Key |
| `orchestration.a2at.apiKey` | `sk-3590ce6c3d2e4111b01f14125bc51fab` | A2AT SDK API Key |
| `postgresql.password` | `openan-db-password` | Database password (must change for production) |
| `ingress.host` | `openan.local` | Ingress domain (replace with your domain or IP) |

### Optional Configuration

| Config Item | Default | Description |
|-------------|---------|-------------|
| `registry.image.repository` | `leoyy6/registry-center` | Image registry address |
| `orchestration.image.repository` | `leoyy6/orchestration-center` | Image registry address |
| `frontend.image.repository` | `leoyy6/workflow-designer` | Image registry address |
| `frontend.nodePort` | `30191` | Frontend NodePort |
| `registry.llm.chat.model` | `glm-5.1` | Chat model name |
| `orchestration.llm.chat.model` | `qwen3.7-plus` | Chat model name |
| `registry.replicas` | `2` | Registry Center replica count |
| `orchestration.replicas` | `2` | Orchestration Center replica count |

### LLM Model Configuration

Example configuration uses Alibaba Cloud DashScope as LLM provider:

| Component | Model | Purpose |
|-----------|-------|---------|
| Registry Center | `glm-5.1` | Agent Card semantic search, intelligent matching |
| Registry Center | `bge-m3` | Vector embedding |
| Registry Center | `bge-reranker-v2-m3` | Result reranking |
| Orchestration Center | `qwen3.7-plus` | Workflow orchestration, PSOP generation |

To use other LLM providers (e.g., OpenAI, DeepSeek), modify `model`, `url`, and `apiKey` together:

```yaml
registry:
  llm:
    chat:
      model: "gpt-4"
      url: "https://api.openai.com/v1/chat/completions"
      apiKey: "sk-your-openai-key"
```

## Step 4: Verify Deployment

```bash
# Check Pod status (wait for all Pods to be Running)
kubectl -n openan get pods

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# openan-postgres-0                       1/1     Running   0          2m
# registry-center-xxx                     1/1     Running   0          2m
# registry-center-yyy                     1/1     Running   0          2m
# orchestration-center-xxx                1/1     Running   0          2m
# orchestration-center-yyy                1/1     Running   0          2m
# workflow-designer-xxx                   1/1     Running   0          2m
# workflow-designer-yyy                   1/1     Running   0          2m

# Check services
kubectl -n openan get svc

# Check Ingress
kubectl -n openan get ingress

# Check logs
kubectl -n openan logs -l app=registry-center -f
kubectl -n openan logs -l app=orchestration-center -f
```

## Step 5: Access Platform

### Method 1: Via Ingress (Recommended)

Configure hosts (using domain configured in `values-custom.yaml`, default `openan.local`):

```bash
# Get Ingress Controller IP
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Add to /etc/hosts (Linux/Mac) or C:\Windows\System32\drivers\etc\hosts (Windows)
<ingress-ip>  openan.local
```

Access:

| Service | Address |
|---------|---------|
| Workflow Designer (Frontend) | `http://openan.local/` |
| Registry API | `http://openan.local/registry/rest/v1/registry-center/agent-cards` |
| Orchestration API | `http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards` |

```bash
# Test Registry API
curl http://openan.local/registry/rest/v1/registry-center/agent-cards

# Test Orchestration API
curl http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards
```

### Method 2: Via NodePort (No Ingress Environment)

If Ingress is not configured, access directly via NodePort (default port 30191):

```bash
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Access frontend
echo "http://${NODE_IP}:30191/"

# Test Registry API (requires Ingress or port forwarding, NodePort only exposes frontend)
```

> Note: NodePort only exposes Workflow Designer frontend. Registry and Orchestration APIs require Ingress or port forwarding.

### Method 3: Port Forwarding (For Debugging)

```bash
# Frontend
kubectl -n openan port-forward svc/workflow-designer 8080:80
# Open browser at http://localhost:8080

# Registry API
kubectl -n openan port-forward svc/registry-center 5000:5000
curl http://localhost:5000/rest/v1/registry-center/agent-cards

# Orchestration API
kubectl -n openan port-forward svc/orchestration-center 5001:5001
curl http://localhost:5001/rest/v1/orchestrate/agent-cards
```

## Step 6: Cleanup

```bash
# Uninstall Helm release
helm uninstall openan -n openan

# Delete namespace (will clean up all resources)
kubectl delete namespace openan

# Delete PVC (optional, will clear database data)
kubectl delete pvc -n openan --all
```

## FAQ

### Q: Pod stuck in Pending state?

```bash
kubectl -n openan describe pod <pod-name>
# Common cause: PVC not bound → check StorageClass
kubectl get sc
```

### Q: Image pull failed?

```bash
# Check if image name and tag are correct
kubectl -n openan describe pod <pod-name> | grep -A5 Events

# Private registry requires imagePullSecrets configuration
kubectl -n openan create secret docker-registry harbor-cred \
  --docker-server=harbor.example.com \
  --docker-username=admin \
  --docker-password=your-password
```

### Q: Database connection failed?

```bash
# Check PostgreSQL Pod status
kubectl -n openan get pods -l app=openan-postgres

# Check PostgreSQL logs
kubectl -n openan logs -l app=openan-postgres
```

### Q: Certificate errors?

Default uses `auto` mode to automatically generate self-signed certificates, no manual intervention required. For troubleshooting:

```bash
kubectl -n openan get secret registry-center-tls
kubectl -n openan get secret registry-center-signing
kubectl -n openan exec <registry-pod> -- ls -la /opt/registry-center/etc/ssl
```

## Related Documentation

- [Helm Chart Detailed Configuration](./openan-chart/README.md)
- [Image Build Guide](./build/README.md)
- [K8S Deployment Guide](../k8s-deployment-guide.md) (includes pure YAML deployment)
