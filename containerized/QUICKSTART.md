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

1. **[1/5] Environment Check** - Detects and auto-installs missing dependencies:
   - Docker (Linux only, auto-install)
   - kubectl (auto-install)
   - Helm (auto-install)
   - Nginx Ingress Controller (auto-install)

2. **[2/5] Component Selection** - Choose what to deploy:
   - All components (default): Registry Center + Orchestration Center + Workflow Designer
   - Registry Center only
   - Orchestration Center + Workflow Designer only
   - Custom selection

3. **[3/5] Registry Center LLM Configuration** - Configure LLM for Registry Center:
   - Chat Model (default: `glm-5.1`)
   - API URL (default: `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`)
   - API Key (required)

4. **[4/5] Orchestration Center LLM Configuration** - Configure LLM for Orchestration Center:
   - Chat Model (default: `qwen3.7-plus`)
   - Chat API URL (default: `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`)
   - Chat API Key (required)
   - A2AT Model (default: `qwen3.7-plus`)
   - A2AT API URL (default: `https://dashscope.aliyuncs.com/compatible-mode/v1`)
   - A2AT API Key (required)

5. **[5/5] Agent Examples Configuration** - Start demo agents server:
   - Start agent examples server (default: Yes)
   - Required for testing demo workflows

**Storage Configuration:**
- If cluster has default StorageClass → uses existing storage
- If no default StorageClass → automatically creates PV with hostPath (`/data/openan-postgres`)

**Deploy** - Automatically deploys with Helm and starts agents server (if enabled)

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

### Access via NodePort (Alternative)

If Ingress is not available, you can access the frontend via NodePort:

```bash
# Get NodePort
NODE_PORT=$(kubectl get svc -n openan workflow-designer -o jsonpath='{.spec.ports[0].nodePort}')

# Get any node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')

# Access frontend
echo "http://$NODE_IP:$NODE_PORT"
```

**Configure Nginx Gateway URL:**

When using NodePort access, you need to configure the frontend to connect to the backend services:

* In frontend settings, set Nginx Gateway URL to: http://$NODE_IP:$NODE_PORT

Note: The Nginx Gateway URL should be the same as the frontend access URL, as nginx will proxy the API requests.

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
# Common cause: PVC not bound
kubectl -n openan get pvc
kubectl get pv

# If PVC is Pending and PV is Available, check:
# - Storage capacity matches (both should be 20Gi)
# - Access modes match (both should be ReadWriteOnce)
# - No storageClassName mismatch
```

### Agents server not starting

```bash
# Check agents server logs
kubectl exec -n openan $(kubectl get pods -n openan -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}') -- cat /tmp/agents-server.log

# Manually start agents server
kubectl exec -n openan $(kubectl get pods -n openan -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}') -- /bin/sh -c "cd /opt/orchestration-center && PYTHONPATH=/opt/orchestration-center nohup python3 samples/start_agents_server.py > /tmp/agents-server.log 2>&1 &"

# Verify agents server is running
kubectl exec -n openan $(kubectl get pods -n openan -l app=orchestration-center -o jsonpath='{.items[0].metadata.name}') -- curl -s http://127.0.0.1:8903/health
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
