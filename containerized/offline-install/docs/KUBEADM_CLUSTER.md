# Building the Kubernetes cluster offline (kubeadm)

This document is **reference only**. The OpenAN offline installer expects a
working cluster; it does not create one. Use this guide to build that cluster on
an offline network with `kubeadm`.

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

Do this on an internet-connected machine with the **same distro release and
architecture** as your nodes. Everything is collected into
`~/offline-materials/` and transferred to every node.

```bash
mkdir -p ~/offline-materials
KUBE_VERSION=v1.34.12        # latest v1.34 patch release
FLANNEL_VERSION=v0.28.9
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

kubeadm tells you exactly which images it needs — pull and export them so no
node ever touches the internet. Requires containerd + kubeadm on the online
machine (install them from the packages above).

```bash
sudo systemctl enable --now containerd

# list the exact references kubeadm expects
sudo kubeadm config images list --kubernetes-version $KUBE_VERSION

# pull them (pause, coredns, etcd, apiserver, controller-manager, scheduler, kube-proxy)
sudo kubeadm config images pull --kubernetes-version $KUBE_VERSION \
    --cri-socket unix:///run/containerd/containerd.sock

# export for transfer
sudo ctr -n k8s.io images export ~/offline-materials/k8s-images-$KUBE_VERSION.tar \
    $(sudo kubeadm config images list --kubernetes-version $KUBE_VERSION)
```

On each node, later:

```bash
sudo ctr -n k8s.io images import k8s-images-$KUBE_VERSION.tar
```

> Mixed-architecture cluster? Repeat the pull/export on a machine of the other
> architecture. If you have an internal registry, use
> `kubeadm init --image-repository <internal-registry>/k8s` instead.

### 1.4 CNI (Flannel) images + manifest

```bash
curl -fsSL -o ~/offline-materials/kube-flannel.yml \
  https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml

# pull every image the manifest references, then export
grep 'image:' ~/offline-materials/kube-flannel.yml
for img in $(grep 'image:' ~/offline-materials/kube-flannel.yml | awk '{print $2}'); do
    sudo ctr -n k8s.io images pull "$img"
done
sudo ctr -n k8s.io images export ~/offline-materials/flannel-images.tar \
    $(grep 'image:' ~/offline-materials/kube-flannel.yml | awk '{print $2}')
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

Flannel (simplest, offline-friendly) — images and manifest come from §1.4:

```bash
sudo ctr -n k8s.io images import ~/offline-materials/flannel-images.tar   # on every node
kubectl apply -f ~/offline-materials/kube-flannel.yml                      # control plane only
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
