# OpenAN Platform Kubernetes Deployment Guide

This document describes two ways to deploy the OpenAN platform on a Kubernetes cluster.

## Deployment Method Comparison

| Feature | Pure YAML | Helm Chart |
|---------|-----------|------------|
| Use Case | Simple deployment, quick validation | Production environment, multi-config management |
| Deploy Command | `kubectl apply -f k8s/` | `helm install openan ./k8s/openan-chart` |
| Optional Components | Manually exclude files | `--set orchestration.enabled=false` |
| Configuration | Edit YAML files directly | `values.yaml` + command-line overrides |
| Multi-environment Support | Maintain multiple file sets | `values-dev.yaml` / `values-prod.yaml` |
| Learning Curve | Low | Requires basic Helm knowledge |

## Prerequisites

- Kubernetes 1.24+
- kubectl configured
- Ingress Controller (Nginx) installed (for external access)
- Container images pushed to an accessible registry

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    openan namespace                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐      ┌──────────────────────────────┐   │
│  │   Ingress    │─────▶│  orchestration-center (opt.) │   │
│  │  (Nginx)     │      │  - Deployment (2~10 pods)    │   │
│  │  / → :5001   │      │  - Service :5001             │   │
│  │  /registry   │      │  - HPA                       │   │
│  │  → :5000     │      └──────────────────────────────┘   │
│  └──────────────┘                  │                       │
│          │                         │ AGENT_REGISTRY_URL    │
│          ▼                         ▼                       │
│  ┌──────────────────────────────────────────────────────┐ │
│  │           registry-center (required)                 │ │
│  │           - Deployment (2 pods)                      │ │
│  │           - Service :5000                            │ │
│  └──────────────────────────────────────────────────────┘ │
│          │                                                 │
│          ▼                                                 │
│  ┌──────────────────────────────────────────────────────┐ │
│  │           openan-postgres (shared)                   │ │
│  │           - StatefulSet                              │ │
│  │           - registry_center DB                       │ │
│  │           - orchestration_center DB                  │ │
│  │           - PVC 20Gi                                 │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Method 1: Pure YAML Deployment

### File Structure

```
k8s/
├── namespace.yaml              # Namespace: openan
├── secret.yaml                 # DB password, LLM API Keys
├── configmap.yaml              # Environment variables
├── postgres-statefulset.yaml   # PostgreSQL StatefulSet
├── deployment.yaml             # orchestration-center Deployment
├── service.yaml                # ClusterIP Service
├── ingress.yaml                # Nginx Ingress
└── hpa.yaml                    # Auto-scaling
```

### Deployment Steps

#### 1. Prepare Configuration

Edit `k8s/secret.yaml` and replace base64-encoded keys:

```bash
# Generate base64-encoded values
echo -n "your-db-password" | base64
echo -n "sk-your-llm-api-key" | base64
```

Edit `k8s/configmap.yaml` to configure:
- `AGENT_REGISTRY_URL`: Registry Center address
- `LLM_CHAT_URL`: LLM API address
- `DB_HOST`: Database address (defaults to internal PostgreSQL)

#### 2. Full Deployment

```bash
kubectl apply -f k8s/
```

#### 3. Deploy Registry Center Only

```bash
# Exclude orchestration-center related files
for f in namespace secret configmap postgres-statefulset service; do
  kubectl apply -f k8s/${f}.yaml
done
```

#### 4. Use External Database

Edit `k8s/configmap.yaml`:
```yaml
PERSISTENCE_MODE: "postgresql"
DB_HOST: "your-external-db.example.com"
```

Skip PostgreSQL deployment:
```bash
for f in namespace secret configmap deployment service ingress hpa; do
  kubectl apply -f k8s/${f}.yaml
done
```

#### 5. Verify Deployment

```bash
# Check Pod status
kubectl -n openan get pods

# Check Services
kubectl -n openan get svc

# Check logs
kubectl -n openan logs -l app=orchestration-center -f
kubectl -n openan logs -l app=registry-center -f

# Test API
kubectl -n openan port-forward svc/orchestration-center 5001:5001
curl http://localhost:5001/rest/v1/orchestrate/agent-cards
```

#### 6. Uninstall

```bash
kubectl delete -f k8s/
```

---

## Method 2: Helm Chart Deployment

### File Structure

```
k8s/openan-chart/
├── Chart.yaml                           # Chart metadata
├── values.yaml                          # Default configuration
└── templates/
    ├── _helpers.tpl                     # Template functions
    ├── namespace.yaml                   # openan namespace
    ├── ingress.yaml                     # Unified entry point
    ├── NOTES.txt                        # Deployment notes
    ├── postgres/
    │   └── statefulset.yaml             # Shared PostgreSQL
    ├── registry-center/
    │   ├── secret.yaml                  # registry independent secret
    │   ├── configmap.yaml               # registry configuration
    │   ├── deployment.yaml
    │   └── service.yaml                 # port 5000
    └── orchestration-center/
        ├── secret.yaml                  # orchestration independent secret
        ├── configmap.yaml
        ├── deployment.yaml
        ├── service.yaml                 # port 5001
        └── hpa.yaml
```

### Deployment Steps

#### 1. Prepare Configuration

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

#### 2. Full Deployment

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  -f values-custom.yaml
```

Or use command-line overrides:

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  --set postgresql.password=your-password \
  --set registry.llm.chat.apiKey=sk-xxx \
  --set orchestration.llm.chat.apiKey=sk-yyy \
  --set ingress.host=openan.example.com
```

#### 3. Deploy Registry Center Only

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  --set orchestration.enabled=false \
  --set registry.llm.chat.apiKey=sk-xxx
```

#### 4. Use External Database

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  --set postgresql.enabled=false \
  --set postgresql.externalHost=your-db.example.com \
  --set postgresql.password=your-password \
  --set registry.llm.chat.apiKey=sk-xxx
```

#### 5. Multi-environment Deployment

Create environment-specific configuration files:

**values-dev.yaml**:
```yaml
postgresql:
  storage: 10Gi

registry:
  replicas: 1

orchestration:
  replicas: 1
  hpa:
    enabled: false

ingress:
  host: openan-dev.example.com
```

**values-prod.yaml**:
```yaml
postgresql:
  storage: 100Gi
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 4Gi

registry:
  replicas: 3

orchestration:
  replicas: 3
  hpa:
    minReplicas: 3
    maxReplicas: 20

ingress:
  host: openan.example.com
  tls:
    enabled: true
```

Deploy:
```bash
# Development environment
helm install openan-dev ./k8s/openan-chart \
  -n openan-dev --create-namespace \
  -f values-dev.yaml

# Production environment
helm install openan-prod ./k8s/openan-chart \
  -n openan-prod --create-namespace \
  -f values-prod.yaml
```

#### 6. Upgrade and Rollback

```bash
# Upgrade
helm upgrade openan ./k8s/openan-chart -n openan -f values-custom.yaml

# View history
helm history openan -n openan

# Rollback
helm rollback openan 1 -n openan
```

#### 7. Verify Deployment

```bash
# Check status
helm status openan -n openan

# Check resources
kubectl -n openan get all

# Check logs
kubectl -n openan logs -l app=orchestration-center -f
```

#### 8. Uninstall

```bash
helm uninstall openan -n openan
```

---

## Configuration Reference

### Pure YAML Key Configuration

| File | Config Item | Description |
|------|-------------|-------------|
| `secret.yaml` | `db-password` | Database password (base64) |
| `secret.yaml` | `llm-api-key` | LLM API Key (base64) |
| `configmap.yaml` | `AGENT_REGISTRY_URL` | Registry Center address |
| `configmap.yaml` | `LLM_CHAT_URL` | LLM API address |
| `configmap.yaml` | `DB_HOST` | Database address |
| `ingress.yaml` | `host` | Ingress domain |

### Helm Chart Key Configuration

| Config Path | Default | Description |
|-------------|---------|-------------|
| `namespace` | `openan` | Namespace |
| `postgresql.enabled` | `true` | Deploy built-in PostgreSQL |
| `postgresql.password` | - | Database password |
| `postgresql.storage` | `20Gi` | Storage size |
| `registry.enabled` | `true` | Deploy Registry Center |
| `registry.replicas` | `2` | Replica count |
| `registry.llm.chat.apiKey` | - | Chat model API Key |
| `registry.port` | `5000` | Service port |
| `registry.tls.mode` | `auto` | TLS certificate mode: auto/secret |
| `registry.tls.existingSecret` | - | TLS certificate Secret name |
| `registry.signing.mode` | `auto` | JWS signing certificate mode: auto/secret |
| `registry.signing.existingSecret` | - | JWS signing certificate Secret name |
| `orchestration.enabled` | `true` | Deploy Orchestration Center |
| `orchestration.replicas` | `2` | Replica count |
| `orchestration.llm.chat.apiKey` | - | Chat model API Key |
| `orchestration.a2at.apiKey` | - | A2AT SDK API Key |
| `orchestration.port` | `5001` | Service port |
| `ingress.enabled` | `true` | Create Ingress |
| `ingress.host` | `openan.example.com` | Ingress domain |

### Certificate Configuration

Registry Center requires two types of certificates:

| Certificate Type | Purpose | Path | Description |
|-----------------|---------|------|-------------|
| TLS Certificate | HTTPS communication | `etc/ssl/` | server.cer, server_key.pem, trust.cer |
| JWS Signing Certificate | Agent Card signing | `etc/sign_cert/` | server.cer, server_key.pem, cert_pwd |

**Certificate Modes:**

| Mode | Description | Multi-replica | Use Case |
|------|-------------|---------------|----------|
| `auto` (default) | Helm auto-generates using `genCA`/`genSignedCert`, stored in Secret | Consistent | Recommended for all scenarios |
| `secret` | Mount from user-pre-created K8S Secret | Consistent | Requires official certificates |
| `off` | Entrypoint auto-generates on each start, not persisted | Inconsistent | Development/debugging only |

**How `auto` mode works:**

1. During `helm install`, Helm templates call `genCA` + `genSignedCert` to generate self-signed certificates
2. Certificate data is written to K8S Secrets (`registry-center-tls` / `registry-center-signing`)
3. Deployment mounts Secrets to `etc/ssl` and `etc/sign_cert`
4. Entrypoint detects certificate files already exist, skips auto-generation
5. During `helm upgrade`, uses `lookup` to detect existing Secrets, **preserves original certificates without regeneration**

**Works out of the box with no manual intervention required.**

**Using official certificates (secret mode):**

```bash
# Create TLS certificate Secret
kubectl -n openan create secret generic registry-center-tls-custom \
  --from-file=server.cer=./server.crt \
  --from-file=server_key.pem=./server.key \
  --from-file=trust.cer=./ca.crt \
  --from-file=cert_pwd=./cert_pwd.txt

# Create JWS signing certificate Secret
kubectl -n openan create secret generic registry-center-signing-custom \
  --from-file=server.cer=./sign_cert/server.cer \
  --from-file=server_key.pem=./sign_cert/server_key.pem \
  --from-file=cert_pwd=./sign_cert/cert_pwd.txt
```

```yaml
# values.yaml
registry:
  tls:
    mode: secret
    existingSecret: registry-center-tls-custom
  signing:
    mode: secret
    existingSecret: registry-center-signing-custom
```

---

## Troubleshooting

### Pod Cannot Start

```bash
# Check Pod events
kubectl -n openan describe pod <pod-name>

# Check logs
kubectl -n openan logs <pod-name>

# Check Secrets
kubectl -n openan get secret
kubectl -n openan get secret registry-center-secret -o yaml
```

### Database Connection Failed

```bash
# Check PostgreSQL Pod
kubectl -n openan get pods -l app=openan-postgres

# Test database connection
kubectl -n openan exec -it <postgres-pod> -- psql -U postgres -c "\l"
```

### Ingress Not Accessible

```bash
# Check Ingress resources
kubectl -n openan get ingress

# Check Ingress Controller logs
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller
```

---

## Security Recommendations

1. **Certificate Management**: Default `auto` mode generates self-signed certificates; production environments should use `secret` mode with official CA certificates
2. **External Secret Management**: Production environments should use Vault, AWS Secrets Manager, etc. to manage sensitive information
3. **Enable TLS**: Configure Ingress TLS or use cert-manager for automatic certificate issuance
4. **Network Policies**: Use NetworkPolicy to restrict Pod-to-Pod communication
5. **Image Security**: Use private image registries and enable image signature verification
6. **Resource Limits**: Set reasonable requests/limits to prevent resource abuse
