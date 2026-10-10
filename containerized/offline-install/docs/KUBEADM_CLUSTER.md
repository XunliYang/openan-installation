# Building the Kubernetes cluster offline (kubeadm)

This document is **reference only**. The OpenAN offline installer expects a
working cluster; it does not create one. Use this guide to build that cluster on
an offline network with `kubeadm` — or use the
[openFuyao offline installer](#10-alternative-build-the-cluster-with-openfuyao-optional)
(§10) as an automated alternative.

Examples cover the **RPM family** (openEuler/CentOS/RHEL) and the **Debian
family** (Ubuntu/Debian). Other RPM/DEB distributions follow the same shape.

---

## 0. Plan

| Item | Example |
|---|---|
| Kubernetes version | v1.34.x |
| Container runtime | containerd 1.7.x or 2.x |
| Control plane | `k8s-master-1` — 192.168.1.10 |
| Workers | `k8s-node-1..3` — 192.168.1.11-13 |
| Pod CIDR | `10.244.0.0/16` (Flannel) or Calico default |
| Service CIDR | `10.96.0.0/12` |
| MetalLB range (for OpenAN) | `192.168.1.200-192.168.1.250` |

All node hostnames must be lowercase, resolvable, and match `kubectl get nodes`.

---

## 1. Offline materials to prepare on an internet machine

Do this on an internet-connected machine with the **same distro release** as
your nodes, and with **Docker** installed (the same machine that builds the
OpenAN offline bundle). Everything is collected into `~/offline-materials/`
and transferred to every node. Images are pulled **per architecture**
(`$ARCHES`); OS packages are architecture-specific too — for a
multi-architecture cluster, repeat the package downloads on a machine of each
architecture (the repos resolve the right arch automatically).

```bash
mkdir -p ~/offline-materials
KUBE_VERSION=v1.34.12        # latest v1.34 patch release
FLANNEL_VERSION=v0.28.9
ARCHES="amd64 arm64"         # target architectures — trim to what your nodes use
```

### 1.1 containerd packages

```bash
# RPM family (openEuler/CentOS/RHEL)
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
mkdir -p ~/offline-materials/rpms
# --resolve pulls dependencies too (runc, container-selinux, ...)
dnf download --resolve --destdir ~/offline-materials/rpms containerd.io

# Debian family (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install --download-only --reinstall -y containerd.io
mkdir -p ~/offline-materials/debs
cp /var/cache/apt/archives/*.deb ~/offline-materials/debs/
```

### 1.2 kubelet / kubeadm / kubectl packages

```bash
# RPM family (openEuler/CentOS/RHEL)
sudo tee /etc/yum.repos.d/kubernetes.repo >/dev/null <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
EOF
mkdir -p ~/offline-materials/rpms
# --resolve pulls dependencies too (kubernetes-cni, conntrack, ...)
dnf download --resolve --destdir ~/offline-materials/rpms \
    kubelet-${KUBE_VERSION#v} kubeadm-${KUBE_VERSION#v} kubectl-${KUBE_VERSION#v}

# Debian family (Ubuntu/Debian)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
# download-only pulls dependencies too (kubernetes-cni, conntrack, ...)
sudo apt-get install --download-only --reinstall -y \
    kubelet=${KUBE_VERSION#v}-* kubeadm=${KUBE_VERSION#v}-* kubectl=${KUBE_VERSION#v}-*
mkdir -p ~/offline-materials/debs
cp /var/cache/apt/archives/*.deb ~/offline-materials/debs/
```

> The same package versions must be installed on every node. `kubernetes-cni`
> (the CNI plugins: `bridge`, `host-local`, `loopback`, `portmap`) is pulled in
> automatically as a kubelet dependency.

### 1.3 Control-plane images

kubeadm tells you exactly which images it needs; pull and save them with
**Docker** (the build machine already requires it for the OpenAN offline
bundle — see [QUICKSTART.md](../QUICKSTART.md) Phase 1). Upstream
`registry.k8s.io` images are multi-arch manifest lists, so pulling with
`--platform` is enough — one tar per architecture:

```bash
# static kubeadm binary — used only to list the exact image refs
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  KARCH=amd64 ;;
  aarch64) KARCH=arm64 ;;
esac
curl -fsSLo kubeadm "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${KARCH}/kubeadm"
chmod +x kubeadm

# the exact references kubeadm expects
# (pause, coredns, etcd, apiserver, controller-manager, scheduler, kube-proxy)
IMAGES=$(./kubeadm config images list --kubernetes-version $KUBE_VERSION)
echo "$IMAGES"

# pull + save per architecture
for a in $ARCHES; do
    for img in $IMAGES; do
        docker pull --platform "linux/$a" "$img"
    done
    docker save -o ~/offline-materials/k8s-images-$KUBE_VERSION-linux-$a.tar $IMAGES
done
```

On each node, later — import the tar matching the node's architecture:

```bash
ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; esac
sudo ctr -n k8s.io images import ~/offline-materials/k8s-images-$KUBE_VERSION-linux-$A.tar
```

> With Docker's containerd image store enabled, `docker save` may export all
> pulled platforms — importing a superset is harmless; containerd picks the
> node's architecture. If you have an internal registry, use
> `kubeadm init --image-repository <internal-registry>/k8s` instead.

### 1.4 CNI (Flannel) images + manifest

```bash
curl -fsSL -o ~/offline-materials/kube-flannel.yml \
  https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml

# pull every image the manifest references, per architecture
grep 'image:' ~/offline-materials/kube-flannel.yml
FLANNEL_IMAGES=$(grep 'image:' ~/offline-materials/kube-flannel.yml | awk '{print $2}')
for a in $ARCHES; do
    for img in $FLANNEL_IMAGES; do
        docker pull --platform "linux/$a" "$img"
    done
    docker save -o ~/offline-materials/flannel-images-linux-$a.tar $FLANNEL_IMAGES
done
```

> Calico works the same way: download its manifest, pull the referenced images,
> export them to a tar.

### 1.5 Transfer to the offline nodes

```bash
tar -czf ~/offline-materials.tar.gz -C ~ offline-materials
# copy to every node (USB / SCP / internal HTTP server)：
scp ~/offline-materials.tar.gz user@<node-ip>:~
# then on each node:
tar -xzf ~/offline-materials.tar.gz -C ~
```

---

## 2. Node preparation (all nodes)

### 2.1 Hosts, swap, kernel modules

```bash
# hostnames
sudo hostnamectl set-hostname k8s-master-1          # per node
# populate /etc/hosts on every node
sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.1.10 k8s-master-1
192.168.1.11 k8s-node-1
192.168.1.12 k8s-node-2
192.168.1.13 k8s-node-3
EOF

# disable swap now and on boot
sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^/#/' /etc/fstab

# kernel modules
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl
sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

### 2.2 SELinux / firewall

```bash
# SELinux: permissive (or per your policy) — RPM family
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

Ports to open on every node (firewalld / ufw):

| Port | Purpose |
|---|---|
| `6443/tcp` | kube-apiserver |
| `2379-2380/tcp` | etcd (control plane) |
| `10250/tcp` | kubelet |
| `10259/tcp`, `10257/tcp` | controller-manager, scheduler |
| `30000-32767/tcp` | NodePort range (OpenAN registry, ingress) |
| `80/443/tcp` | ingress-nginx |
| L2/ARP | MetalLB — do not filter ARP on node NICs |

### 2.3 Time

```bash
# RPM family
sudo systemctl enable --now chronyd
# Debian family
sudo systemctl enable --now systemd-timesyncd
```

---

## 3. Install containerd

```bash
cd ~/offline-materials/rpms    # or debs on the Debian family

# RPM family
sudo dnf --disablerepo=* install -y ./containerd.io-*.rpm

# Debian family
sudo dpkg -i ./containerd.io_*.deb
```

Generate a config with the **systemd cgroup driver** (kubelet must match):

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# also point containerd at the OpenAN registry (see DEPENDENCIES.md §2.2)
sudo systemctl enable --now containerd
```

Verify:

```bash
sudo ctr version
sudo systemctl status containerd
```

---

## 4. Install kubelet / kubeadm / kubectl

```bash
cd ~/offline-materials/rpms    # or debs on the Debian family

# RPM family
sudo dnf --disablerepo=* install -y ./kubelet-1.34.*.rpm ./kubeadm-1.34.*.rpm ./kubectl-1.34.*.rpm

# Debian family
sudo apt-get install -y --allow-downgrades ./kubelet_1.34.*.deb ./kubeadm_1.34.*.deb ./kubectl_1.34.*.deb
sudo apt-mark hold kubelet kubeadm kubectl
```

```bash
sudo systemctl enable --now kubelet    # expected to crash-loop until init
```

---

## 5. Initialise the control plane

```bash
sudo kubeadm init \
  --kubernetes-version v1.34.12 \
  --pod-network-cidr 10.244.0.0/16 \
  --cri-socket unix:///run/containerd/containerd.sock
```

If the images were preloaded in §1, kubeadm finds them locally and never pulls.

Configure kubectl for your user:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

## 6. Install a CNI plugin (offline)

Flannel (simplest, offline-friendly) — images and manifest come from §1.4.
Import the tar matching the node's architecture:

```bash
ARCH=$(uname -m); case "$ARCH" in x86_64) A=amd64;; aarch64) A=arm64;; esac
sudo ctr -n k8s.io images import ~/offline-materials/flannel-images-linux-$A.tar   # on every node
kubectl apply -f ~/offline-materials/kube-flannel.yml                              # control plane only
```

Or Calico: import its images on every node, then `kubectl apply -f calico.yaml`.
The CNI manifest must reference **local images**, never an upstream registry.

---

## 7. Join the worker nodes

```bash
# on the control plane
kubeadm token create --print-join-command
# on each worker
sudo <the printed kubeadm join command>
```

---

## 8. Verify

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get --raw='/readyz?verbose'
```

All nodes `Ready`, all `kube-system` pods `Running`.

---

## 9. Prepare the cluster for OpenAN

Once the cluster is healthy:

1. **Trust the OpenAN registry** on every node (see
   [DEPENDENCIES.md §2.2](DEPENDENCIES.md)).
2. Decide a **MetalLB pool** of unused, routable IPs.
3. (Optional) create a **default StorageClass**, otherwise the installer falls
   back to a node-pinned hostPath PV.
4. Then run `scripts/check-env.sh` and `scripts/install.sh` from the offline
   bundle.

---

## 10. Alternative: build the cluster with openFuyao (optional)

Instead of the manual kubeadm flow above, the
[openFuyao offline installer](https://docs.openfuyao.cn/zh/docs/v26.09/cluster_installation_guide/bootstrap_cluster_installation/offline_bootstrap_cluster_installation.html)
(`bke`) can build the cluster for you: it assembles an offline deployment
package on an internet-connected **build node** (requires tar, pigz and
**Docker**), installs a bootstrap cluster on the bootstrap node, and you then
create the business cluster from the openFuyao management plane. OpenAN is
installed onto that cluster exactly as in the sections above.

Condensed flow — follow the linked guide for the authoritative version:

1. On the build node, install the tools and configure Docker:

   ```bash
   # RPM family (openEuler/CentOS/RHEL)
   yum install -y tar pigz docker && systemctl enable --now docker

   # Debian family (Ubuntu/Debian)
   apt-get update && apt-get install -y tar pigz docker.io && systemctl enable --now docker
   ```

   ```json
   // /etc/docker/daemon.json — then: systemctl restart docker
   { "insecure-registries": ["0.0.0.0/0"] }
   ```

2. Download and verify the BKE install tool (as root):

   ```bash
   curl -LO https://openfuyao.obs.cn-north-4.myhuaweicloud.com/openFuyao/bkeadm/releases/download/26.9.0/download.sh
   curl -LO https://openfuyao.obs.cn-north-4.myhuaweicloud.com/openFuyao/bkeadm/releases/download/26.9.0/download.sh.sha256
   sha256sum -c <(cat download.sh.sha256) < download.sh
   chmod +x download.sh && ./download.sh
   ```

3. Download `Core-VersionConfig-v26.09.yaml` (linked in the openFuyao guide),
   set `needDownload: true` for any optional components you want, and build
   the offline package (~1 hour; retryable errors during the build can be
   ignored):

   ```bash
   rm -rf /bke && bke build -f Core-VersionConfig-v26.09.yaml -t bke.tar.gz
   ```

4. Copy `bke.tar.gz` to the **clean** bootstrap node (no leftover
   docker/containerd state; ≥ 50 GB free on `/`), extract and initialise:

   ```bash
   rm -rf /bke && tar zxvf bke.tar.gz -C /
   ARCH=$(uname -m)
   case $ARCH in
   x86_64)  ARCH="amd64";;
   aarch64) ARCH="arm64";;
   esac
   mv /usr/local/bin/bkeadm_linux_$ARCH /usr/local/bin/bke
   bke init --confirm
   ```

5. Verify: `kubectl get pod -A` — done when all pods are `Running`/`Completed`
   and the log ends with `BKE initialization is complete`. The management
   plane is at `https://<bootstrap-node-ip>:30010` (default `admin` /
   `test@1234` — change on first login).

6. Create the business cluster from the management plane (see the openFuyao
   service-cluster guide), then continue with §9 of this document and the
   OpenAN install.
