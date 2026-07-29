# OpenAN Installation

System-level installation tooling for OpenAN, providing one-click binary installation and clustered containerized installation with modular component selection and fully configurable parameters.

## Project Structure

```
openan-installation/
├── binary/                          # Binary deployment
│   ├── one-click/                   # One-click installation scripts
│   ├── orchestration-center/        # Orchestration Center binaries
│   └── registry-center/             # Registry Center binaries
└── containerized/                   # Containerized deployment
    ├── build/                       # Image build scripts
    ├── install.sh                   # Interactive installation tool
    ├── openan-chart/                # Helm chart
    └── QUICKSTART.md                # Quick start guide
```

## Installation Methods

### 1. Clustered Containerized Installation (Kubernetes)

Production-grade installation using Helm charts. Supports multi-node clusters, HPA auto-scaling, and TLS certificates.

```bash
git clone https://github.com/XunliYang/openan-installation.git
cd openan-installation/containerized
./install.sh
```

**Features:**
- Modular component selection (Registry Center, Orchestration Center, Workflow Designer)
- Fully configurable parameters (LLM API keys, image registry, storage)
- Auto-detects cluster environment (StorageClass, Ingress Controller)

**Manual / System Admin Installation:**
If you prefer to manually install the Helm chart, follow these steps:
- Prerequisites: Ensure you have a Kubernetes cluster (v1.24+) and Helm installed.
- Build your local images by running `containerized/build/build.sh` or pull from Docker Hub.
- Customize the Helm chart values in `containerized/openan-chart/values.yaml`, and then install the chart using Helm:
```bash
helm install openan ./openan-chart -n openan --create-namespace -f values.yaml
```

**Documentation:**
- [Quick Start](./containerized/QUICKSTART.md) - One-click installation guide
- [Helm Chart](./containerized/openan-chart/README.md) - Helm configuration reference
- [Image Build](./containerized/build/README.md) - Custom image building

### 2. One-Click Binary Installation

Binary-based installation for virtual machines or bare-metal servers. Downloads and starts all services locally with automatic dependency setup.

**Linux/macOS:**
```bash
cd binary/one-click
./linux_demo.sh
```

**Features:**
- Downloads and starts all services locally (PostgreSQL, Registry, Orchestration, Frontend)
- Automatic dependency setup (Python venvs, Node.js)
- Ready for installation in minutes

