# Deployment Notes

This document describes fixes and operational steps applied during the
v1.0.0 offline installation on a kubeadm cluster (4 nodes, mixed
amd64/arm64, openEuler 22.03).

## 1. Node hostname vs Kubernetes node name mismatch

The install script defaults `REGISTRY_NODE` and `STORAGE_NODE` to the
machine's hostname (`hostname`). On this cluster the host is `node-0` but
the Kubernetes node name is `node-186`. This caused the registry Pod to
stay Pending with:

    0/4 nodes are available: 4 node(s) didn't match Pod's node affinity/selector

Fix: set `REGISTRY_NODE` and `STORAGE_NODE` in `config.env` to the actual
Kubernetes node name (e.g. `node-186`). The hostname check in
`scripts/install.sh` was removed because it compared the local hostname
against `REGISTRY_NODE`, which is wrong when they legitimately differ.

## 2. containerd must trust the insecure registry on every node

The private registry runs at `http://<node-ip>:30500` (plain HTTP).
containerd on each node that may pull images needs:

    mkdir -p /etc/containerd/certs.d/<registry-host>:30500
    cat > /etc/containerd/certs.d/<registry-host>:30500/hosts.toml <<EOF
    server = "http://<registry-host>:30500"

    [host."http://<registry-host>:30500"]
      capabilities = ["pull", "resolve", "push"]
      skip_verify = true
    EOF

containerd v2 reads `hosts.toml` at startup only; after creating or
modifying it, restart containerd on the node:

    systemctl restart containerd

Verify on each node:

    crictl pull <registry-host>:30500/library/registry:2

## 3. Missing crane binary in the bundle

`scripts/push-images.sh` requires `deps/bin/crane-linux-$ARCH` but the
v1.0.0 bundle did not include it. Download from:

    https://github.com/google/go-containerregistry/releases
    (go-containerregistry_Linux_x86_64.tar.gz or _arm64.tar.gz)

Place the `crane` binary as `deps/bin/crane-linux-amd64` (or
`crane-linux-arm64`).

## 4. Helm chart fixes

### 4.1 registry-center startup pre-check failure

The application exits when `enable_https=false` but
`startup.strict.identity=true` (default in the image). Added to
`chart/templates/registry-center/configmap.yaml`:

    REGISTRY_VERIFY_CLIENT: "false"
    REGISTRY_OWNER_ISOLATION_ENABLED: "false"
    REGISTRY_STARTUP_STRICT_IDENTITY: "false"

### 4.2 orchestration-center db_config.json missing

The image ships `etc/conf/db_config.json.template` only, but the
entrypoint edits `etc/conf/db_config.json` in place and crashes when it
does not exist. Fixed by an initContainer that copies the whole `etc/`
tree to a writable emptyDir and creates `db_config.json` from the
template.

### 4.3 orchestration-center probes use HTTP 401

All application routes return 401 without a session, so the original
`httpGet` probes on `/rest/v1/orchestrate/agent-cards` always failed and
restarted the Pod. Changed to `tcpSocket` probes in `chart/values.yaml`.

### 4.4 workflow-designer nginx config is read-only

The chart mounted a ConfigMap to `/etc/nginx/conf.d` (read-only), but the
stock nginx entrypoint tries to render `/etc/nginx/templates/*.template`
into that directory and crashes. Fixed by an initContainer that renders
the template into an emptyDir and mounts that instead.

### 4.5 Ingress class and annotations

openan now uses a dedicated ingress class `openan-nginx` (see section 5).
The frontend Ingress must NOT have `use-regex`/`rewrite-target`
annotations; otherwise `/assets/...` requests are rewritten to `/` and
the SPA fails to load.

## 5. Dedicated ingress controller for openan

The cluster already runs an ingress-nginx controller for openFuyao at
`192.168.200.136`. A second controller instance is deployed for openan:

- Namespace: `ingress-openan`
- IngressClass: `openan-nginx`
- LoadBalancer IP: `192.168.200.137` (MetalLB `openan-pool` annotation)

Manifest: `docs/ingress-nginx-openan.yaml` (generated from the
stock `ingress-nginx.yaml` with unique names, class, election ID, service
account, and webhook certificate).

## 6. MetalLB address pool

The default pool `192.168.1.200-192.168.1.250` did not match the cluster
network (`192.168.200.0/24`). Updated to `192.168.200.136-192.168.200.153`
in `config.env` (`METALLB_POOL`) and applied via
`metallb.io/v1beta1/IPAddressPool`.

## 7. Single replica for orchestration-center (optional)

During debugging, scaling orchestration-center to 1 replica resolved
intermittent login failures caused by inconsistent in-memory state
between replicas. A subsequent application-side fix (PR #3) addressed the
root cause; replicas can be restored to 2 when running the fixed image.
