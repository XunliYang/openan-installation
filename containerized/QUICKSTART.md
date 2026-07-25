# OpenAN Platform Quick Start

One-click deployment guide using the automated setup script.

## Prerequisites

Before running the setup script, ensure you have:

- **Linux or macOS** system (Windows not yet supported for automated setup)
- **Kubernetes cluster** (v1.24+) with `kubectl` configured
- **Internet connection** for downloading dependencies and images

The setup script will automatically install missing tools (Docker, kubectl, Helm, Ingress Controller).

## Step 1: Clone Deployment Repository

```bash
git clone https://github.com/XunliYang/openan-deployment.git
cd openan-deployment/containerized
```

## Step 2: Run Install Script

```bash
./install.sh
```

The script will guide you through an interactive setup:

1. **Environment Check** - Detects and auto-installs missing dependencies:
   - Docker (Linux only, auto-install)
   - kubectl (auto-install)
   - Helm (auto-install)
   - Nginx Ingress Controller (auto-install)

2. **Component Selection** - Choose what to deploy:
   - All components (default): Registry Center + Orchestration Center + Workflow Designer
   - Registry Center only
   - Orchestration Center + Workflow Designer only
   - Custom selection

3. **Image Source** - Choose how to get images:
   - Build from source (downloads release packages from GitHub)
   - Pull pre-built images from registry

4. **Local Registry** (optional) - Deploy a local registry in the cluster:
   - Useful for air-gapped environments
   - Configurable NodePort

5. **API Keys** (optional) - Configure LLM API keys:
   - Chat API Key
   - Embed API Key
   - Rerank API Key
   - A2AT API Key

6. **Database & Ingress** - Configure:
   - Database password
   - Ingress host (default: `openan.local`)

7. **Deploy** - Automatically builds images and deploys with Helm

## Step 3: Verify Deployment

After setup completes, verify the deployment:

```bash
# Check Pod status (wait for all Pods to be Running)
kubectl -n openan get pods

# Expected output:
# NAME                                    READY   STATUS    RESTARTS   AGE
# openan-postgres-0                       1/1     Running   0          2m
# registry-center-xxx                     1/1     Running   0          2m
# orchestration-center-xxx                1/1     Running   0          2m
# workflow-designer-xxx                   1/1     Running   0          2m

# Check services
kubectl -n openan get svc

# Check Ingress
kubectl -n openan get ingress
```

## Step 4: Access Platform

### Configure Hosts

Add the Ingress host to your `/etc/hosts` file:

```bash
# Get Ingress Controller IP
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$INGRESS_IP  openan.local" | sudo tee -a /etc/hosts
```

### Access Services

| Service | URL |
|---------|-----|
| **Workflow Designer** (Frontend) | `http://openan.local/` |
| **Registry API** | `http://openan.local/registry/rest/v1/registry-center/agent-cards` |
| **Orchestration API** | `http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards` |

### Test APIs

```bash
# Test Registry API
curl http://openan.local/registry/rest/v1/registry-center/agent-cards

# Test Orchestration API
curl http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards
```

## Cleanup

To uninstall the platform:

```bash
# Uninstall Helm release
helm uninstall openan -n openan

# Delete namespace (removes all resources)
kubectl delete namespace openan

# Delete PVC (optional, clears database data)
kubectl delete pvc -n openan --all
```

## Troubleshooting

### Pod stuck in Pending state

```bash
kubectl -n openan describe pod <pod-name>
# Common cause: PVC not bound → check StorageClass
kubectl get sc
```

### Image pull failed

```bash
# Check if image name and tag are correct
kubectl -n openan describe pod <pod-name> | grep -A5 Events

# For private registry, configure imagePullSecrets
kubectl -n openan create secret docker-registry harbor-cred \
  --docker-server=harbor.example.com \
  --docker-username=admin \
  --docker-password=your-password
```

### Database connection failed

```bash
# Check PostgreSQL Pod status
kubectl -n openan get pods -l app=openan-postgres

# Check PostgreSQL logs
kubectl -n openan logs -l app=openan-postgres
```

### Ingress not accessible

```bash
# Check Ingress resources
kubectl -n openan get ingress

# Check Ingress Controller logs
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller
```

## Related Documentation

- [Helm Chart Configuration](./openan-chart/README.md) - Detailed Helm values
- [Image Build Guide](./build/README.md) - Manual image building
- [K8S Deployment Guide](../k8s-deployment-guide.md) - Pure YAML deployment
