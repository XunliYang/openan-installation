# OpenAN Platform Image Build Guide

This document describes how to build the container images required for the OpenAN Helm Chart.

## Directory Structure

```
build/
├── build.sh                    # Main build script
├── build-config.yaml.example   # Configuration file template
└── README.md                   # This document
```

## Prerequisites

- Docker installed and running
- Git (if using Git repository method)
- Python 3 (if using YAML configuration file)

## Quick Start

### Method 1: Using Local Source Code (Recommended for Development)

```bash
# Enter build directory
cd build

# Build Registry Center only
./build.sh --registry-src /path/to/registry-center

# Build Orchestration Center only (includes Workflow Designer)
./build.sh --orchestration-src /path/to/orchestration-center

# Build both components
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center

# Build and push to private registry
./build.sh \
  --registry harbor.example.com \
  --namespace openan \
  --tag v1.0.0 \
  --orchestration-src /path/to/orchestration-center \
  --push
```

### Method 2: Using Git Repository (Recommended for CI/CD)

```bash
# Build Registry Center only
./build.sh \
  --registry-repo https://github.com/org/registry-center.git \
  --tag v1.0.0 \
  --push

# Build Orchestration Center only
./build.sh \
  --orchestration-repo https://github.com/org/orchestration-center.git \
  --tag v1.0.0 \
  --push

# Build both components
./build.sh \
  --registry-repo https://github.com/org/registry-center.git \
  --orchestration-repo https://github.com/org/orchestration-center.git \
  --tag v1.0.0 \
  --push
```

Note: Workflow Designer is a subdirectory of Orchestration Center and will be automatically included when building Orchestration Center.

### Method 3: Using Configuration File

```bash
# Copy configuration file template
cp build-config.yaml.example build-config.yaml

# Edit configuration file
vim build-config.yaml

# Build using configuration file
./build.sh --config build-config.yaml
```

Note: Workflow Designer is a subdirectory of Orchestration Center and defaults to `{orchestration-center}/workflow-designer`, no separate configuration needed.

## Multi-architecture Build

The build script supports multi-architecture (amd64 + arm64) by default, customizable via the `--platforms` parameter.

### Prerequisites

1. **Install QEMU** (for emulating different architectures)
   ```bash
   # Ubuntu/Debian
   sudo apt-get install qemu-user-static
   
   # Or using Docker
   docker run --privileged --rm tonistiigi/binfmt --install all
   ```

2. **Create buildx builder**
   ```bash
   docker buildx create --name multiarch --use
   ```

### Building Multi-architecture Images

```bash
# Default: build amd64 + arm64
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --push

# Custom target platforms
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --platforms linux/amd64,linux/arm64,linux/arm/v7 \
  --push

# Single architecture only (faster)
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --platforms linux/amd64 \
  --push
```

### Verifying Multi-architecture Images

```bash
# View supported architectures for an image
docker buildx imagetools inspect your-registry.com/openan/registry-center:latest

# Example output:
# Name: your-registry.com/openan/registry-center:latest
# Manifests:
#   Name: ...@sha256:abc123
#   Platform: linux/amd64
#   
#   Name: ...@sha256:def456
#   Platform: linux/arm64
```

### Notes

1. **Must push**: Multi-architecture images must be pushed to a registry, cannot be used locally
2. **Build time**: Multi-architecture build time is approximately N times single architecture (N = number of architectures)
3. **Registry support**: Ensure your image registry supports multi-architecture manifests (Docker Hub, Harbor, ACR, etc. all support this)

## Configuration Parameters

### Command Line Parameters

| Parameter | Description | Required | Example |
|-----------|-------------|----------|---------|
| `--registry` | Image registry address | No | `harbor.example.com` |
| `--namespace` | Image namespace | No | `openan` |
| `--tag` | Image tag | No | `v1.0.0` |
| `--push` | Push after build | No | - |
| `--config` | Configuration file path | No | `build-config.yaml` |
| `--registry-src` | Registry Center local path | One of two | `/path/to/registry-center` |
| `--orchestration-src` | Orchestration Center local path | One of two | `/path/to/orchestration-center` |
| `--frontend-src` | Workflow Designer local path | No | `/path/to/workflow-designer` |
| `--registry-repo` | Registry Center Git repository | One of two | `https://github.com/...` |
| `--orchestration-repo` | Orchestration Center Git repository | One of two | `https://github.com/...` |
| `--registry-branch` | Registry Center branch | No | `main` |
| `--orchestration-branch` | Orchestration Center branch | No | `main` |
| `--platforms` | Target platform architectures | No | `linux/amd64,linux/arm64` |

**Note**: At least one component source must be specified (`--registry-src` or `--orchestration-src`), components not specified will be skipped.

### Configuration File Parameters

See comments in `build-config.yaml.example`.

Note: Workflow Designer is a subdirectory of Orchestration Center, configuration only needs `orchestration-center`, `workflow-designer` will automatically use `{orchestration-center}/workflow-designer`.

## Build Process

```
1. Parse arguments (command line > config file > defaults)
   ↓
2. Prepare source code
   ├─ Local path: verify path exists
   └─ Git repository: clone to temp directory
   ↓
3. Build images (only builds components with specified source)
   ├─ registry-center        (if --registry-src or --registry-repo specified)
   ├─ orchestration-center   (if --orchestration-src or --orchestration-repo specified)
   └─ workflow-designer      (if orchestration-center is built)
   ↓
4. Push images (if --push specified)
   ↓
5. Clean up temp directories
```

## Image Naming Convention

Built images follow this naming format:

```
{registry}/{namespace}/{component}:{tag}
```

Examples:
- `harbor.example.com/openan/registry-center:v1.0.0`
- `harbor.example.com/openan/orchestration-center:v1.0.0`
- `harbor.example.com/openan/workflow-designer:v1.0.0`

## Integration with Helm Chart

After building, deploy using:

```bash
# Only built Registry Center
helm install openan . \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0

# Only built Orchestration Center
helm install openan . \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0

# Built both components
helm install openan . \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0
```

## FAQ

### Q: How to specify Workflow Designer source?

A: Workflow Designer is a subdirectory of Orchestration Center, defaults to `{orchestration-src}/workflow-designer`. To use a different path, use `--frontend-src`:

```bash
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --frontend-src /custom/path/to/workflow-designer
```

### Q: How to build only one component?

A: The script supports selective builds, just specify one component's source:

```bash
# Build Registry Center only
./build.sh --registry-src /path/to/registry-center

# Build Orchestration Center only (automatically includes Workflow Designer)
./build.sh --orchestration-src /path/to/orchestration-center
```

### Q: How to skip Workflow Designer build?

A: If Orchestration Center source doesn't have a `workflow-designer` directory, the script will automatically skip frontend build. You can also explicitly skip with `--frontend-src ""`.

### Q: How to debug build failures?

A: Use `--no-cache` to disable cache and view detailed build logs:

```bash
docker build --no-cache -t my-image /path/to/source
```

### Q: How to use private Git repositories?

A: Configure Git authentication:

```bash
# Method 1: Using SSH
git clone git@github.com:org/repo.git

# Method 2: Using HTTPS + Token
git clone https://token@github.com/org/repo.git

# Method 3: Configure Git credential
git config --global credential.helper store
```

### Q: How to verify successful image build?

A: Use these commands to check:

```bash
# List images
docker images | grep openan

# Test run
docker run --rm my-registry.com/openan/registry-center:v1.0.0 --help
```

## Best Practices

1. **Selective builds**: Only build components with changes to save build time
2. **Version tags**: Use semantic versioning (e.g., `v1.0.0`) for production, `latest` or git commit hash for development
3. **Image scanning**: Scan images for vulnerabilities using `trivy` or `snyk` before pushing
4. **Multi-architecture support**: Use `docker buildx` to build multi-architecture images (amd64/arm64)
5. **Cache optimization**: Write Dockerfiles to leverage build cache for faster builds
6. **Secure storage**: Use Kubernetes Secrets or Vault to store image registry credentials

## Related Documentation

- [Quick Start](../QUICKSTART.md) (Build + Deploy one-stop guide)
- [Helm Chart Deployment](../openan-chart/README.md)
- [K8S Deployment Guide](../../k8s-deployment-guide.md)
- [Docker Official Documentation](https://docs.docker.com/)
