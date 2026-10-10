# OpenAN Installation

System-level installation tooling for OpenAN, providing one-click binary installation and clustered containerized installation with modular component selection and fully configurable parameters.

## Project Structure

```
openan-installation/
├── binary/one-click/                # Binary installation
│   ├── install.sh                   # one-click installation script
│   ├── uninstall.sh                 # one-click uninstall script
│   ├── README.md                    # Binary installation guide
└── containerized/                   # Containerized installation
    ├── online-install/              # Internet-connected installation
    │   ├── install.sh               # Explicit values deployment tool
    │   ├── uninstall.sh             # One-click uninstall script
    │   ├── openan-chart/            # Helm chart
    │   └── QUICKSTART.md            # Installation guide
    ├── build/                       # Image build scripts (shared)
    ├── offline-install/             # Offline Kubernetes installation
    └── offline-install-compose/     # Offline Docker Compose installation
```

## Installation Methods

### 1. Clustered Containerized Installation (Kubernetes)

Helm deployment with explicit database, protocol, credentials and certificate settings. OC remains single-replica until shared sessions are implemented. Read [the deployment contract](containerized/TRANSPORT_DEPLOYMENT.md) before upgrading; this chart requires matching newly built service images.

```bash
git clone https://github.com/project-openan/openan-installation.git
cd openan-installation/containerized/online-install
bash install.sh --values /path/to/deployment.yaml
```

**Features:**
- Modular component selection (Registry Center, Orchestration Center, Workflow Designer)
- Fully configurable parameters by helm values(LLM API keys, image registry, storage)
- Existing cluster/Helm/Ingress infrastructure managed independently
- HTTP/HTTPS, external MySQL/PostgreSQL, and credential/certificate Secret injection
- One-click uninstall with optional data cleanup

**Manual / System Admin Installation:**
If you prefer to manually install the Helm chart, follow these steps:
- Prerequisites: Ensure you have a Kubernetes cluster (v1.25+) and Helm 3.10.0+ installed.
- Build your local images by running `containerized/build/build.sh` or pull from ghcr.io.
- Customize the Helm chart values in `containerized/online-install/openan-chart/values.yaml`, and then install the chart using Helm:
```bash
cd containerized/online-install
helm upgrade --install openan ./openan-chart -n openan --create-namespace -f /path/to/deployment.yaml
```

### 2. One-Click Binary Installation

Binary-based installation for virtual machines or bare-metal servers. Downloads and starts all services locally with automatic dependency setup.

**Linux/macOS:**
```bash
cd binary/one-click
./install.sh
```

**Features:**
- Downloads and starts all services locally (PostgreSQL, Registry, Orchestration, Frontend)
- Automatic dependency setup (Python venvs, Node.js)
- Modular component selection (Registry Center, Orchestration Center, Workflow Designer in nginx)
- Ready for installation in minutes

## Uninstall

### Containerized

```bash
cd containerized/online-install
./uninstall.sh
```

Or manually:

```bash
helm uninstall openan -n openan
kubectl delete namespace openan
```

### Binary

```bash
cd binary/one-click
./uninstall.sh
```

The single-host [offline Compose installer](containerized/offline-install-compose/README.md) supports internal/external MySQL or PostgreSQL, independent public/backend HTTP/HTTPS, explicit credentials and readonly PKI/model mounts. It deploys one instance per application, not an HA cluster. Offline Kubernetes remains outside this remediation and is not certified against the same deployment contract.

## Upgrade

> Container upgrades use the same explicit values file via install.sh (helm upgrade --install). Back up data, pin image tags/source refs, and restart Pods when subPath Secrets change. Binary installer compatibility is outside this container remediation.

## Documentation

- [Quick Start](./containerized/online-install/QUICKSTART.md) - Online container deployment guide
- [Helm Chart](./containerized/online-install/openan-chart/README.md) - Helm configuration reference
- [Image Build](./containerized/build/README.md) - Custom image building
- [Offline Installation (Kubernetes)](./containerized/offline-install/README.md) - Offline Kubernetes deployment
- [Offline Installation (Docker Compose)](./containerized/offline-install-compose/README.md) - Offline single-host deployment
- [Binary Installation](./binary/one-click/README.md) - Binary installation details

