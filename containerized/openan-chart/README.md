# OpenAN Platform Helm Chart

OpenAN Platform Helm Chart for deploying the complete OpenAN platform on a Kubernetes cluster.

## Deployment Method Comparison

| Feature | Pure YAML | Helm Chart (this document) |
|---------|-----------|---------------------------|
| Use Case | Simple deployment, quick validation | Production environment, multi-config management |
| Deploy Command | `kubectl apply -f k8s/` | `helm install openan ./openan-chart` |
| Optional Components | Manually exclude files | `--set orchestration.enabled=false` |
| Configuration | Edit YAML files directly | `values.yaml` + command-line overrides |
| Multi-environment Support | Maintain multiple file sets | `values-dev.yaml` / `values-prod.yaml` |
| Learning Curve | Low | Requires basic Helm knowledge |

> For pure YAML deployment, please refer to [K8S Deployment Guide](../../k8s-deployment-guide.md).

## Components

This Chart deploys the following components:

| Component | Description | Default Port |
|-----------|-------------|--------------|
| **Registry Center** | Agent registration center, provides Agent Card registration, discovery, and semantic search | 5000 |
| **Orchestration Center** | Workflow orchestration center, provides PSOP generation and workflow execution | 5001 |
| **Workflow Designer** | Frontend workflow designer, provides visual workflow editing interface | 80 |
| **PostgreSQL** | Shared database, stores registry_center and orchestration_center | 5432 |

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10.0+
- kubectl configured
- Ingress Controller (Nginx) installed (for external access)
- Container images pushed to an accessible registry (see [Image Build Guide](../build/README.md))

## File Structure

```
openan-chart/
├── Chart.yaml                           # Chart metadata
├── values.yaml                          # Default configuration
└── templates/
    ├── _helpers.tpl                     # Template functions
    ├── namespace.yaml                   # openan namespace
    ├── ingress.yaml                     # Unified entry point (frontend / orchestration / registry)
    ├── NOTES.txt                        # Deployment notes
    ├── postgres/
    │   ├── storage.yaml                 # StorageClass / PV (optional)
    │   └── statefulset.yaml             # Shared PostgreSQL
    ├── registry-center/
    │   ├── secret.yaml                  # registry independent secret
    │   ├── configmap.yaml               # registry configuration
    │   ├── deployment.yaml
    │   ├── service.yaml                 # port 5000
    │   ├── tls-secret.yaml              # TLS certificate (auto mode)
    │   └── signing-secret.yaml          # JWS signing certificate (auto mode)
    ├── orchestration-center/
    │   ├── secret.yaml                  # orchestration independent secret
    │   ├── configmap.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml                 # port 5001
    │   └── hpa.yaml
    └── workflow-designer/
        ├── deployment.yaml
        ├── service.yaml                 # port 80
        └── hpa.yaml
```

## Quick Start

### 1. Add Helm Repository (if published)

```bash
helm repo add openan https://charts.openan.io
helm repo update
```

### 2. Prepare Configuration

Create `values-custom.yaml`:

```yaml
# Database password
postgresql:
  password: "your-secure-password"

# Registry Center LLM configuration
registry:
  llm:
    chat:
      apiKey: "sk-registry-chat-key"
    embed:
      apiKey: "sk-registry-embed-key"
    rerank:
      apiKey: "sk-registry-rerank-key"

# Orchestration Center LLM configuration
orchestration:
  llm:
    chat:
      apiKey: "sk-orchestration-chat-key"
  a2at:
    apiKey: "sk-orchestration-a2at-key"

# Ingress configuration
ingress:
  host: openan.your-domain.com
  tls:
    enabled: true
    secretName: openan-tls
```

### 3. Install Chart

```bash
# Install with custom configuration
helm install openan . \
  -n openan --create-namespace \
  -f values-custom.yaml

# Or use command-line overrides
helm install openan . \
  -n openan --create-namespace \
  --set postgresql.password=your-password \
  --set registry.llm.chat.apiKey=sk-xxx \
  --set orchestration.llm.chat.apiKey=sk-yyy \
  --set ingress.host=openan.example.com

# Custom image registry
helm install openan . \
  -n openan --create-namespace \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0

# If namespace already exists and is not managed by Helm
kubectl create namespace openan
helm install openan . -n openan --set createNamespace=false
```

### 4. Configure LLM API Key (using external Secret)

Create Secret:

```bash
kubectl create secret generic openan-llm-keys \
  --namespace openan \
  --from-literal=registry-chat-key=sk-your-registry-key \
  --from-literal=registry-embed-key=sk-your-embed-key \
  --from-literal=registry-rerank-key=sk-your-rerank-key \
  --from-literal=orchestration-chat-key=sk-your-orchestration-key \
  --from-literal=orchestration-a2at-key=sk-your-a2at-key
```

Reference in `values-custom.yaml`:

```yaml
registry:
  llm:
    chat:
      existingSecret: openan-llm-keys
      existingSecretKey: registry-chat-key
    embed:
      existingSecret: openan-llm-keys
      existingSecretKey: registry-embed-key
    rerank:
      existingSecret: openan-llm-keys
      existingSecretKey: registry-rerank-key

orchestration:
  llm:
    chat:
      existingSecret: openan-llm-keys
      existingSecretKey: orchestration-chat-key
  a2at:
    existingSecret: openan-llm-keys
    existingSecretKey: orchestration-a2at-key
```

### 5. Verify Deployment

```bash
# Check Helm release status
helm status openan -n openan

# Check Pod status
kubectl get pods -n openan

# Check all resources
kubectl get all -n openan

# Check Ingress
kubectl get ingress -n openan

# Check logs
kubectl logs -n openan -l app=registry-center -f
kubectl logs -n openan -l app=orchestration-center -f
```

### 6. Access via Ingress

**Configure hosts (if using custom domain):**

```bash
# Add to /etc/hosts (Linux/Mac) or C:\Windows\System32\drivers\etc\hosts (Windows)
# Assuming Ingress Controller IP is 192.168.200.183
192.168.200.183  openan.local
```

**Access Workflow Designer (Frontend):**

Open browser at `http://openan.local/`

**Access Registry API:**

```bash
# Query all Agents
curl http://openan.local/registry/rest/v1/registry-center/agent-cards

# Register new Agent
curl -X POST http://openan.local/registry/rest/v1/registry-center/agent-cards \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-agent",
    "description": "My custom agent",
    "url": "http://my-agent:8080",
    "version": "1.0.0"
  }'

# Query specific Agent
curl http://openan.local/registry/rest/v1/registry-center/agent-cards/my-agent

# Delete Agent
curl -X DELETE http://openan.local/registry/rest/v1/registry-center/agent-cards/my-agent
```

**Access Orchestration API:**

```bash
# Query Agent list
curl http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards
```

**Port Forwarding (for debugging):**

```bash
# Registry Center
kubectl -n openan port-forward svc/registry-center 5000:5000
curl http://localhost:5000/rest/v1/registry-center/agent-cards

# Orchestration Center
kubectl -n openan port-forward svc/orchestration-center 5001:5001
curl http://localhost:5001/rest/v1/orchestrate/agent-cards
```

## Configuration Parameters

### Global Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace` | Kubernetes namespace | `openan` |
| `createNamespace` | Whether Helm creates the namespace | `true` |

**Note**: If the namespace already exists and is not managed by Helm, set `createNamespace=false`, otherwise you will encounter a "namespace already exists" error.

### PostgreSQL Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `postgresql.enabled` | Enable built-in PostgreSQL | `true` |
| `postgresql.externalHost` | External database address | `""` |
| `postgresql.port` | Database port | `5432` |
| `postgresql.password` | Database password | `"openan-db-password"` |
| `postgresql.storage.size` | Storage size | `20Gi` |
| `postgresql.storage.createStorageClass` | Auto-create StorageClass | `false` |
| `postgresql.storage.createPV` | Auto-create PV | `false` |
| `postgresql.storage.storageClassName` | StorageClass name | `"openan-local"` |
| `postgresql.storage.setDefault` | Set as default StorageClass | `false` |
| `postgresql.storage.reclaimPolicy` | Reclaim policy (Retain/Delete) | `"Retain"` |
| `postgresql.storage.useHostPath` | Use hostPath (single-node cluster) | `true` |
| `postgresql.storage.hostPath` | hostPath directory | `"/data/openan-postgres"` |
| `postgresql.storage.nodeName` | Node name (when useHostPath=false) | `""` |

**Production Storage Recommendations:**

The default configuration uses hostPath for quick setup in development/testing environments. For production deployments, it is recommended to use NFS or cloud storage:

- **NFS**: Configure an external NFS server for shared storage across nodes
- **Cloud Storage**: Use cloud provider's block storage (e.g., AWS EBS, Alibaba Cloud Disk, Tencent Cloud CBS)
- **External Database**: Use managed database services (e.g., RDS, PolarDB) for high availability

To use an existing StorageClass in your cluster:
```yaml
postgresql:
  storage:
    storageClassName: "your-storage-class"
```


### Registry Center Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `registry.enabled` | Enable Registry Center | `true` |
| `registry.replicas` | Replica count | `2` |
| `registry.image.repository` | Image registry | `registry-center` |
| `registry.image.tag` | Image tag | `latest` |
| `registry.image.pullPolicy` | Image pull policy | `Always` |
| `registry.port` | Service port | `5000` |
| `registry.llm.chat.model` | Chat model | `deepseek-chat` |
| `registry.llm.chat.url` | Chat API URL | `https://api.deepseek.com/v1/chat/completions` |
| `registry.llm.chat.apiKey` | Chat API Key | `""` |
| `registry.llm.chat.existingSecret` | Reference existing Secret | `""` |
| `registry.llm.embed.model` | Embed model | `bge-m3` |
| `registry.llm.embed.url` | Embed API URL | `""` |
| `registry.llm.embed.apiKey` | Embed API Key | `""` |
| `registry.llm.rerank.model` | Rerank model | `bge-reranker-v2-m3` |
| `registry.llm.rerank.url` | Rerank API URL | `""` |
| `registry.llm.rerank.apiKey` | Rerank API Key | `""` |
| `registry.vectordb.enabled` | Enable VectorDB (Milvus) | `false` |
| `registry.vectordb.host` | VectorDB address | `""` |
| `registry.vectordb.port` | VectorDB port | `19530` |
| `registry.tls.mode` | TLS certificate mode: `auto`/`secret`/`off` | `auto` |
| `registry.tls.existingSecret` | TLS certificate Secret name | `""` |
| `registry.signing.mode` | JWS signing certificate mode: `auto`/`secret`/`off` | `auto` |
| `registry.signing.existingSecret` | JWS signing certificate Secret name | `""` |
| `registry.resources.requests` | Resource requests | `cpu: 250m, memory: 256Mi` |
| `registry.resources.limits` | Resource limits | `cpu: 500m, memory: 512Mi` |
| `registry.livenessProbe` | Liveness probe | `path: /rest/v1/registry-center/agent-cards` |
| `registry.readinessProbe` | Readiness probe | `path: /rest/v1/registry-center/agent-cards` |

### Orchestration Center Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `orchestration.enabled` | Enable Orchestration Center | `true` |
| `orchestration.replicas` | Replica count | `2` |
| `orchestration.image.repository` | Image registry | `orchestration-center` |
| `orchestration.image.tag` | Image tag | `latest` |
| `orchestration.image.pullPolicy` | Image pull policy | `Always` |
| `orchestration.port` | Service port | `5001` |
| `orchestration.agentRegistryUrl` | Registry Center URL | `""` (auto-discovered) |
| `orchestration.llm.chat.model` | Chat model | `deepseek-chat` |
| `orchestration.llm.chat.url` | Chat API URL | `https://api.deepseek.com/v1/chat/completions` |
| `orchestration.llm.chat.apiKey` | Chat API Key | `""` |
| `orchestration.llm.chat.existingSecret` | Reference existing Secret | `""` |
| `orchestration.a2at.provider` | A2AT provider | `deepseek` |
| `orchestration.a2at.model` | A2AT model | `deepseek-chat` |
| `orchestration.a2at.baseUrl` | A2AT Base URL | `https://api.deepseek.com` |
| `orchestration.a2at.apiKey` | A2AT API Key | `""` |
| `orchestration.a2at.existingSecret` | Reference existing Secret | `""` |
| `orchestration.hpa.enabled` | Enable HPA | `true` |
| `orchestration.hpa.minReplicas` | Minimum replicas | `2` |
| `orchestration.hpa.maxReplicas` | Maximum replicas | `10` |
| `orchestration.resources.requests` | Resource requests | `cpu: 250m, memory: 512Mi` |
| `orchestration.resources.limits` | Resource limits | `cpu: 1000m, memory: 1Gi` |
| `orchestration.livenessProbe` | Liveness probe | `path: /rest/v1/orchestrate/agent-cards` |
| `orchestration.readinessProbe` | Readiness probe | `path: /rest/v1/orchestrate/agent-cards` |
| `orchestration.startupProbe` | Startup probe | `failureThreshold: 12` |

### Workflow Designer Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `frontend.enabled` | Enable Workflow Designer | `true` |
| `frontend.replicas` | Replica count | `2` |
| `frontend.image.repository` | Image registry | `workflow-designer` |
| `frontend.image.tag` | Image tag | `latest` |
| `frontend.image.pullPolicy` | Image pull policy | `Always` |
| `frontend.port` | Service port | `80` |
| `frontend.nodePort` | NodePort port | `30080` |
| `frontend.hpa.enabled` | Enable HPA | `true` |
| `frontend.hpa.minReplicas` | Minimum replicas | `2` |
| `frontend.hpa.maxReplicas` | Maximum replicas | `10` |
| `frontend.resources.requests` | Resource requests | `cpu: 100m, memory: 128Mi` |
| `frontend.resources.limits` | Resource limits | `cpu: 500m, memory: 256Mi` |

### Ingress Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `ingress.enabled` | Enable Ingress | `true` |
| `ingress.className` | Ingress Class | `nginx` |
| `ingress.host` | Domain | `openan.local` |
| `ingress.tls.enabled` | Enable TLS | `false` |
| `ingress.tls.secretName` | TLS Secret name | `openan-tls` |

## Deployment Scenarios

### Production Environment

```bash
helm install openan-prod . \
  --namespace openan-prod \
  --create-namespace \
  -f values-prod.yaml
```

Example `values-prod.yaml`:

```yaml
postgresql:
  storage:
    size: 100Gi
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 4Gi

registry:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

orchestration:
  replicas: 3
  hpa:
    minReplicas: 3
    maxReplicas: 20
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 2Gi

frontend:
  replicas: 3
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

ingress:
  host: openan.example.com
  tls:
    enabled: true
    secretName: openan-tls
```

### Deploy Registry Center Only

```bash
helm install openan-registry . \
  --namespace openan \
  --create-namespace \
  --set orchestration.enabled=false \
  --set frontend.enabled=false
```

### Use External Database

```bash
helm install openan . \
  --namespace openan \
  --create-namespace \
  --set postgresql.enabled=false \
  --set postgresql.externalHost=db.example.com \
  --set postgresql.port=5432 \
  --set postgresql.password=your-password
```

### Namespace Already Exists

If the namespace already exists and is not managed by Helm, manually create the namespace and set `createNamespace=false`:

```bash
# Manually create namespace
kubectl create namespace openan

# Disable Helm namespace creation during install
helm install openan . \
  --namespace openan \
  --set createNamespace=false
```

## Common Operations

### Upgrade

```bash
helm upgrade openan . --namespace openan -f values.yaml
```

### Rollback

```bash
# View release history
helm history openan -n openan

# Rollback to specific version
helm rollback openan 1 -n openan
```

### Uninstall

```bash
helm uninstall openan -n openan

# Delete PVC (optional)
kubectl delete pvc -n openan --all
```

### View Logs

```bash
# Registry Center
kubectl logs -n openan -l app=registry-center -f

# Orchestration Center
kubectl logs -n openan -l app=orchestration-center -f

# Workflow Designer
kubectl logs -n openan -l app=workflow-designer -f

# PostgreSQL
kubectl logs -n openan -l app=openan-postgres -f
```

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                       openan namespace                           │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐      ┌───────────────────────────────────┐   │
│  │   Ingress    │─────▶│  Workflow Designer (Frontend)     │   │
│  │  (Nginx)     │      │  - Deployment (2 pods)            │   │
│  │  / → :80     │      │  - Service :80                    │   │
│  │  /api/       │      │  - HPA                            │   │
│  │  orchestrate │      └───────────────────────────────────┘   │
│  │  → :5001     │                      │                       │
│  │  /registry   │                      │ AGENT_REGISTRY_URL    │
│  │  → :5000     │                      ▼                       │
│  └──────────────┘      ┌───────────────────────────────────┐  │
│                        │  Orchestration Center              │  │
│                        │  - Deployment (2 pods)             │  │
│                        │  - Service :5001                   │  │
│                        │  - HPA                             │  │
│                        └───────────────────────────────────┘  │
│                                  │                             │
│                                  ▼                             │
│                        ┌───────────────────────────────────┐  │
│                        │  Registry Center                   │  │
│                        │  - Deployment (2 pods)             │  │
│                        │  - Service :5000                   │  │
│                        └───────────────────────────────────┘  │
│                                  │                             │
│                                  ▼                             │
│                        ┌───────────────────────────────────┐  │
│                        │  PostgreSQL (Shared)               │  │
│                        │  - StatefulSet                     │  │
│                        │  - registry_center DB              │  │
│                        │  - orchestration_center DB         │  │
│                        │  - PVC 20Gi                        │  │
│                        └───────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Ingress Path Rewrite Rules:**

| External Path | Forwarded to Backend | Description |
|---------------|---------------------|-------------|
| `/` | `workflow-designer:80/` | Frontend pages |
| `/api/orchestrate/rest/v1/orchestrate/...` | `orchestration-center:5001/rest/v1/orchestrate/...` | Strip `/api/orchestrate` prefix |
| `/registry/rest/v1/registry-center/...` | `registry-center:5000/rest/v1/registry-center/...` | Strip `/registry` prefix |

**Why use Ingress Host?**

- Provides a unified entry point for all services
- Provides url matching isolation and path rewriting. If not config ingress.host, the frontend will accept any host, which may cause conflicts with other services in the cluster.

## Certificate Management

Registry Center requires two types of certificates:

| Certificate Type | Purpose | Mount Path | Files |
|-----------------|---------|------------|-------|
| TLS Certificate | HTTPS communication | `etc/ssl/` | server.cer, server_key.pem, trust.cer |
| JWS Signing Certificate | Agent Card signing | `etc/sign_cert/` | server.cer, server_key.pem, cert_pwd |

### Certificate Modes

| Mode | Description | Multi-replica Consistency | Use Case |
|------|-------------|---------------------------|----------|
| `auto` (default) | Helm auto-generates using `genCA`/`genSignedCert`, stored in Secret | Consistent | Recommended for all scenarios |
| `secret` | Mount from user-pre-created K8S Secret | Consistent | Requires official certificates |
| `off` | Entrypoint auto-generates on each start, not persisted | Inconsistent | Development/debugging only |

### How `auto` Mode Works

1. During `helm install`, Helm templates call `genCA` + `genSignedCert` to generate self-signed certificates
2. Certificate data is written to K8S Secrets (`registry-center-tls` / `registry-center-signing`)
3. Deployment mounts Secrets to `etc/ssl` and `etc/sign_cert`
4. Entrypoint detects certificate files already exist, skips auto-generation
5. During `helm upgrade`, uses `lookup` to detect existing Secrets, **preserves original certificates without regeneration**

**Works out of the box with no manual intervention required.**

### Using Auto-generated Certificates (Default)

```yaml
registry:
  tls:
    mode: auto
  signing:
    mode: auto
```

### Using Custom Certificates

```bash
# Create TLS certificate Secret
kubectl create secret generic registry-tls \
  --namespace openan \
  --from-file=server.cer=./server.crt \
  --from-file=server_key.pem=./server.key \
  --from-file=trust.cer=./ca.crt

# Create JWS signing certificate Secret
kubectl create secret generic registry-signing \
  --namespace openan \
  --from-file=server.cer=./sign_cert/server.cer \
  --from-file=server_key.pem=./sign_cert/server_key.pem \
  --from-file=cert_pwd=./sign_cert/cert_pwd.txt
```

```yaml
registry:
  tls:
    mode: secret
    existingSecret: registry-tls
  signing:
    mode: secret
    existingSecret: registry-signing
```

## Security Recommendations

1. **Certificate Management**: Default `auto` mode generates self-signed certificates; production environments should use `secret` mode with official CA certificates
2. **Secret Management**: Production environments should use Vault, AWS Secrets Manager, etc. to manage sensitive information via `existingSecret` references
3. **Enable TLS**: Configure Ingress TLS or use cert-manager for automatic certificate issuance
4. **Network Policies**: Use NetworkPolicy to restrict Pod-to-Pod communication
5. **Image Security**: Use private image registries and enable image signature verification
6. **Resource Limits**: Set reasonable requests/limits to prevent resource abuse

## Troubleshooting

### Namespace Conflict

If you encounter a "namespace already exists" error:

```bash
# Option 1: Delete existing namespace and reinstall
kubectl delete namespace openan
helm install openan . --namespace openan --create-namespace

# Option 2: Manually create namespace and set createNamespace=false
kubectl create namespace openan
helm install openan . --namespace openan --set createNamespace=false

# Option 3: Clean up Helm release cache
kubectl get secrets --all-namespaces | grep "sh.helm.release" | grep openan
kubectl delete secret -l owner=helm,name=openan --all-namespaces
helm install openan . --namespace openan --create-namespace
```

### Pod Cannot Start

```bash
# Check Pod status
kubectl describe pod -n openan <pod-name>

# Check logs
kubectl logs -n openan <pod-name>
```

### Database Connection Failed

```bash
# Check PostgreSQL Pod
kubectl get pods -n openan -l app=openan-postgres

# Test database connection
kubectl exec -n openan <postgres-pod> -- psql -U postgres -c "\l"
```

### Ingress Not Accessible

```bash
# Check Ingress resources
kubectl describe ingress -n openan

# Check Ingress Controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

### Certificate Issues

```bash
# Check certificate Secrets
kubectl get secret -n openan registry-center-tls -o yaml
kubectl get secret -n openan registry-center-signing -o yaml

# Check certificate mounts
kubectl exec -n openan <registry-pod> -- ls -la /opt/registry-center/etc/ssl
kubectl exec -n openan <registry-pod> -- ls -la /opt/registry-center/etc/sign_cert
```

## Related Documentation

- [Quick Start](../QUICKSTART.md) (Build + Deploy one-stop guide)
- [Image Build Guide](../build/README.md)

## License

Apache License 2.0
