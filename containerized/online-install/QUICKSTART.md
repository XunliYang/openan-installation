# OpenAN Online Container Quickstart

[中文](QUICKSTART.zh.md) · [Full deployment contract](../TRANSPORT_DEPLOYMENT.md)

## Prerequisites

- Linux or macOS with internet access (application images and the pinned infrastructure manifests are fetched online)
- A Kubernetes cluster (v1.25+) reachable with `kubectl`
- Helm 3.19+ and python3
- No host tools are auto-installed; the installer never modifies the OS

## Step 1: Interactive install

```bash
cd containerized/online-install
./install.sh
```

The installer orchestrates six phases (`./install.sh --help` shows the short flow):

- **[1/6] Preflight** — checks kubectl, helm and python3, verifies the cluster is reachable and prints the kubectl client version.
- **[2/6] Targets** — asks for the Helm release name and namespace (both default to `openan`).
- **[3/6] Images** — the image tag is required and has no default (old `v1.0.0` images are not compatible with the current chart; see the deployment contract). Building from source needs the two organization source archive URLs at accepted revisions (registry-center and orchestration-center) and pushes images — `docker login` to the target registry first; answer no to reuse an already-pushed tag.
- **[4/6] Infrastructure** — when MetalLB and ingress-nginx are both detected, the phase is skipped; otherwise it can install the pinned MetalLB v0.16.1 and ingress-nginx controller-v1.15.1 manifests, then prompt for a MetalLB IP pool on bare metal (e.g. `192.168.1.200-192.168.1.250`, leave empty to skip).
- **[5/6] Application** — the guided wizard (configure.py) asks for components, SQL hosting (in-cluster PostgreSQL evaluation default / external SQL), models (generated from chat LLM answers with a connectivity probe / existing ConfigMaps), signing (auto demo / existing Secret) and the initial admin password (12+ characters with lower/upper/digit/special classes; asked when orchestration is selected). Secrets go only to Kubernetes Secrets via kubectl stdin; the wizard writes just the non-secret `deployment.generated.json` and never overwrites existing files or Secrets. If a run fails halfway, reconcile the created Secrets/ConfigMaps and continue with `--values` for upgrades.
- **[6/6] Deploy** — lints the chart against the generated values, runs `helm upgrade --install --wait` and prints the access URL. Log in with the admin account configured in the wizard.

## Step 2: Verify deployment

```bash
kubectl -n openan get pods,svc,ingress
```

- Pods: `registry-center-*`, `orchestration-center-*`, `workflow-designer-*` (plus `openan-postgres-0` for in-cluster SQL) should reach `Running`.
- Services: `workflow-designer` (NodePort), `registry-center`, `orchestration-center`, `openan-postgres`.
- Ingresses: `openan-frontend-ingress`, `openan-orchestration-ingress`, `openan-registry-ingress` with the LoadBalancer address in `ADDRESS`.

## Step 3: Access the platform

The LoadBalancer IP is preferred:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP
```

Open `http://<EXTERNAL-IP>/` (the installer also prints the wizard hostname — point DNS or an `/etc/hosts` entry for it at that IP). Without a LoadBalancer IP the installer prints the NodePort fallback:

```bash
NODE_PORT=$(kubectl -n openan get svc workflow-designer -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://${NODE_IP}:${NODE_PORT}/"
```

Log in with the admin account configured in the wizard and change the password in the web UI before API use.

## HTTPS deployment

1. **MetalLB pool first**: a routable IP range must exist (the same IPAddressPool offered in phase [4/6]) so the ingress gets a stable IP; point DNS or an `/etc/hosts` entry at it.
2. **Generate certificates** (certificate tool provided by a separate PR):

   ```bash
   python3 tool/gen_certs.py --host openan.example.com [--ip <LB-IP>]
   # produces ca.crt / tls.crt / tls.key
   ```

3. **Certificate Secret**:

   ```bash
   python3 tool/gen_certs.py --host openan.example.com --install-secret openan-tls --namespace openan
   # or: kubectl create secret tls openan-tls -n openan --cert=tls.crt --key=tls.key
   ```

4. **Enable in values**: `ingress.host: openan.example.com`, `ingress.tls.enabled: true`, `ingress.tls.secretName: openan-tls`.
5. **ingress-nginx default certificate** (optional, serves non-matching hosts): create a Secret in the `ingress-nginx` namespace and set the controller argument `--default-ssl-certificate=ingress-nginx/<secret>`:

   ```bash
   kubectl -n ingress-nginx create secret tls default-tls --cert=tls.crt --key=tls.key
   kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
       -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-ssl-certificate=ingress-nginx/default-tls"}]'
   ```

6. **In-cluster service TLS / mTLS**: see the [full deployment contract](../TRANSPORT_DEPLOYMENT.md).

## Automation / production (helm-native)

Prepare Kubernetes, Helm, ingress/storage, SQL databases and model/credential/PKI references from the contract.
Copy [deployment.yaml.example](deployment.yaml.example), set all tags and non-secret fields:

```bash
helm lint openan-chart --namespace openan -f deployment.yaml
helm template openan openan-chart --namespace openan -f deployment.yaml > rendered.yaml
helm upgrade --install openan openan-chart --namespace openan --create-namespace -f deployment.yaml --wait --timeout 10m
```

Namespace must match values. Never put secrets in values/--set; if legacy inline fields were intentionally used,
rendered output may contain them, so protect it. Verify APIs at the actual public entrance, not only probes.

`one_click_install.sh` remains the flag-driven variant for prepared environments
(`--skip-build` / `--skip-infra` / `--values ...` / `--release` / `--namespace`); for infrastructure it requires
reviewed local MetalLB/ingress-nginx chart packages and values instead of the online pinned manifests.

## Verification and troubleshooting

With Python/PyYAML/pytest, Helm and Bash installed, run `python -m pytest tests/ -q`.
Missing tools explicitly skip related tests; render passes are not container/cluster passes.
CI separately builds the real Compose matrix. See [acceptance and troubleshooting](../TRANSPORT_DEPLOYMENT.md#acceptance-and-troubleshooting)
for auth/TLS/SQL/PVC and frontend diagnosis. Single-instance upgrades briefly interrupt service.
