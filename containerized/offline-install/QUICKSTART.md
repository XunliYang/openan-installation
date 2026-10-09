# OpenAN Offline Installation Quickstart (Kubernetes)

End-to-end guide: build the offline bundle on an **internet-connected machine**,
transfer it to the **offline machine**, and install OpenAN onto an existing
Kubernetes cluster. Nothing at install time touches the internet.

For architecture, configuration reference and troubleshooting see
[README.md](README.md) and [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

---

## Prerequisites

### Build machine (online)

- Linux with **Docker** (buildx enabled) and `curl`
- Internet access to `ghcr.io`, `docker.io`, `registry.k8s.io`, `quay.io`,
  `get.helm.sh`, `dl.k8s.io`, `github.com`

### Offline machine / cluster

The cluster and its OS-level dependencies are **already installed** — the
installer deploys *onto* a cluster, it does not create one:

- A running **Kubernetes cluster (v1.34+)**, e.g. built with `kubeadm`
  (`kubeadm`, `kubelet`, `kubectl`, containerd and the control-plane images all
  in place). Building the cluster offline is covered by
  [docs/KUBEADM_CLUSTER.md](docs/KUBEADM_CLUSTER.md).
- `kubectl` access to the cluster from the machine you run the installer on
  (`~/.kube/config` present, nodes `Ready`).

Prepare the following items **before** running the installer (full details and
the exact check commands for each are in
[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)):

**1. Every node's containerd trusts the in-cluster registry**
([DEPENDENCIES.md §2.2](docs/DEPENDENCIES.md#22-containerd-must-trust-the-private-registry-every-node)).
The registry is plain HTTP on `<REGISTRY_NODE_IP>:30500`. On **every** node:

```bash
sudo mkdir -p /etc/containerd/certs.d/192.168.1.10:30500
sudo tee /etc/containerd/certs.d/192.168.1.10:30500/hosts.toml >/dev/null <<'EOF'
server = "http://192.168.1.10:30500"

[host."http://192.168.1.10:30500"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
```

Make sure `/etc/containerd/config.toml` enables `config_path = "/etc/containerd/certs.d"`
(containerd 1.6/1.7 and 2.x use different sections — see the doc), then
`sudo systemctl restart containerd` on every node. Replace `192.168.1.10` with
your `REGISTRY_NODE_IP`. `check-env.sh` verifies this per node.

**2. A MetalLB address pool** (bare-metal clusters,
[§2.3](docs/DEPENDENCIES.md#23-metallb-address-pool)) — a range of routable,
currently-unused IPs on your LAN, e.g. `192.168.1.200-192.168.1.250`. Goes into
`METALLB_POOL` in `config.env`.

**3. Storage** ([§2.4](docs/DEPENDENCIES.md#24-storage)) — either a default
StorageClass exists, or the installer falls back to a node-pinned hostPath PV
(`HOSTPATH=/data/openan-postgres`, or `/data/openan-mysql` when
`DB_TYPE=mysql`; `STORAGE_NODE`).

**4. Time synchronisation, disk space, firewall, SELinux**
([§2.5–2.8](docs/DEPENDENCIES.md#25-time-synchronisation)) — NTP running on all
nodes; ~5 GiB free; open `30500/tcp`, `30000-32767/tcp`, `80/443/tcp`, and do
not filter MetalLB L2/ARP traffic; on openEuler/CentOS/Rocky either label the
data directories or set SELinux permissive.

**5. An internal LLM endpoint** ([§2.9](docs/DEPENDENCIES.md#29-an-internal-llm-endpoint)) —
OpenAN needs a chat model at run time; in an offline network this is normally
an internal service (vLLM / MindIE / Ollama / gateway). Its model/URL/API key
go into `config.env` (`REGISTRY_CHAT_*`, `ORCH_CHAT_*`).

---

## Phase 1: Build the offline bundle (online machine)

```bash
cd containerized/offline-install/build
./build-offline.sh --tag v1.0.0 --app-source pull
```

This downloads the pinned dependencies (helm, kubectl, crane, ingress-nginx,
MetalLB manifests) and pulls/builds all images, then produces:

```
build/dist/openan-offline-v1.0.0/         # bundle directory
build/dist/openan-offline-v1.0.0.tar.gz   # transferable tarball
```

Application image sources (`--app-source`):

| value | meaning |
|---|---|
| `pull` (default) | pull the three app images from `--app-registry` (default `ghcr.io/project-openan`) |
| `build` | build from local source: `--registry-src <dir> --orchestration-src <dir>` |
| `tars` | reuse pre-built `<base>-<arch>.tar` from `--app-tars-dir <dir>` |

Useful options: `--platforms linux/amd64,linux/arm64` (default both),
`--out <dir>`, `--keep-images`. See `./build-offline.sh --help`.

## Phase 2: Transfer the bundle to the offline machine

Copy `openan-offline-v1.0.0.tar.gz` to the offline machine (the node where you
will run the installer — it must have `kubectl` access and will host the
in-cluster registry by default), using SCP, USB or an internal file server:

```bash
scp build/dist/openan-offline-v1.0.0.tar.gz user@<offline-node>:~
```

## Phase 3: Install on the offline machine

```bash
tar -xzf openan-offline-v1.0.0.tar.gz
cd openan-offline-v1.0.0

# 1. Configure — every option is documented inline
cp config.env.example config.env
vi config.env          # at minimum: METALLB_POOL, DB_PASSWORD, LLM endpoints

# 2. Verify the environment (never changes anything)
scripts/check-env.sh --config config.env

# 3. Install
sudo scripts/install.sh --config config.env
```

Interactive mode is also supported: run `sudo scripts/install.sh` with no
arguments and it prompts for the same values, then writes `config.env` for you.

The installer will:

1. Run the environment check (skip with `--skip-check` if already verified).
2. Bootstrap an in-cluster private registry (`registry:2`, NodePort `30500`).
   The registry is plain HTTP, so **every node's containerd must be configured
   to trust it** (`certs.d` host config) before images can be pulled — see
   [docs/DEPENDENCIES.md §2.2](docs/DEPENDENCIES.md#22-containerd-must-trust-the-private-registry-every-node)
   for the exact per-node setup.
3. Push all bundle images and stitch multi-arch manifest lists.
4. Install MetalLB (optional) and ingress-nginx offline.
5. `helm install` the OpenAN chart with a generated values file.
6. Self-check: pods ready, registry catalog reachable, API smoke tests.

## Verify

```bash
kubectl -n openan get pods,svc,ingress
```

The installer prints the access URL at the end — either the MetalLB
LoadBalancer IP (`http://<LB_IP>/`) or a NodePort fallback
(`http://<node-ip>:<nodePort>/`).

## Uninstall

```bash
scripts/uninstall.sh --config config.env
```

Removes the Helm release, the in-cluster registry, and optionally the
persistent volumes and namespace.

---

## Troubleshooting

- **check-env.sh failures** — it prints the exact fix for every item; see
  [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).
- **`http: server gave HTTP response to HTTPS client`** — a node's containerd
  does not trust the in-cluster registry yet; apply the `certs.d` config from
  [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) §2.2 on every node.
- **Re-running install** — infrastructure steps are idempotent, but if the Helm
  release `openan` already exists the installer aborts; run `uninstall.sh`
  first (this version does not support upgrades).
