# Building the Kubernetes cluster offline (kubeadm)

This document is **reference only**. The OpenAN offline installer expects a
working cluster; it does not create one. Use this guide to build that cluster on
an offline network with `kubeadm`.

Examples cover **openEuler** and **Ubuntu** as the two main lines. Other RPM/DEB
distributions follow the same shape.

---

## 0. Plan

| Item | Example |
|---|---|
| Kubernetes version | v1.29.x |
| Container runtime | containerd 1.7.x or 2.x |
| Control plane | `k8s-master-1` — 192.168.1.10 |
| Workers | `k8s-node-1..3` — 192.168.1.11-13 |
| Pod CIDR | `10.244.0.0/16` (Flannel) or Calico default |
| Service CIDR | `10.96.0.0/12` |
| MetalLB range (for OpenAN) | `192.168.1.200-192.168.1.250` |

All node hostnames must be lowercase, resolvable, and match `kubectl get nodes`.

---

## 1. Offline materials to prepare on an internet machine

| Material | Notes |
|---|---|
| `containerd`, `runc`, `containerd.io` packages | match your distro + arch (amd64/arm64) |
| CNI plugins (`containernetworking-plugins`) | provides `bridge`, `host-local`, `loopback`, `portmap` |
| `kubelet`, `kubeadm`, `kubectl` packages | same version on all nodes (`v1.29.x`) |
| Kubernetes control-plane images | pause, coredns, etcd, apiserver, controller-manager, scheduler, kube-proxy |
| CNI images | Flannel or Calico images + manifest |
| An internal HTTP file server or USB transfer | to move all of the above |

Pre-pull the control-plane images with the **exact references kubeadm expects**
so no node ever pulls from the internet:

```bash
# on the internet machine (same k8s version)
kubeadm config images list --kubernetes-version v1.29.4
kubeadm config images pull  --kubernetes-version v1.29.4
ctr -n k8s.io images export k8s-images.tar \
  $(kubeadm config images list --kubernetes-version v1.29.4)
```

On each node:

```bash
ctr -n k8s.io images import k8s-images.tar
```

> If you have an internal registry instead, use
> `kubeadm init --image-repository <internal-registry>/k8s`.

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
# SELinux: permissive (or per your policy) — openEuler/CentOS
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
# openEuler/CentOS
sudo systemctl enable --now chronyd
# Ubuntu
sudo systemctl enable --now systemd-timesyncd
```

---

## 3. Install containerd

```bash
# openEuler/CentOS
sudo rpm -ivh containerd.io-*.rpm           # or dnf --disablerepo=* install ./containerd.io-*.rpm

# Ubuntu
sudo dpkg -i containerd.io_*.deb
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
# openEuler/CentOS
sudo dnf --disablerepo=* install -y ./kubelet-1.29.*.rpm ./kubeadm-1.29.*.rpm ./kubectl-1.29.*.rpm

# Ubuntu
sudo apt-get install -y --allow-downgrades ./kubelet_1.29.*.deb ./kubeadm_1.29.*.deb ./kubectl_1.29.*.deb
sudo apt-mark hold kubelet kubeadm kubectl
```

```bash
sudo systemctl enable --now kubelet    # expected to crash-loop until init
```

---

## 5. Initialise the control plane

```bash
sudo kubeadm init \
  --kubernetes-version v1.29.4 \
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

Flannel (simplest, offline-friendly):

```bash
ctr -n k8s.io images import flannel-images.tar      # on every node
kubectl apply -f flannel.yaml
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
