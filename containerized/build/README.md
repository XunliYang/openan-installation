# OpenAN Platform 镜像构建指南

本文档介绍如何为 OpenAN Helm Chart 构建所需的容器镜像。

## 目录结构

```
build/
├── build.sh                    # 主构建脚本
├── build-config.yaml.example   # 配置文件模板
└── README.md                   # 本文档
```

## 前置要求

- Docker 已安装并运行
- Git（如果使用 Git 仓库方式）
- Python 3（如果使用 YAML 配置文件）

## 快速开始

### 方式一：使用本地源码（推荐开发环境）

```bash
# 进入 build 目录
cd build

# 仅构建 Registry Center
./build.sh --registry-src /path/to/registry-center

# 仅构建 Orchestration Center（包含 Workflow Designer）
./build.sh --orchestration-src /path/to/orchestration-center

# 同时构建两个组件
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center

# 构建并推送到私有仓库
./build.sh \
  --registry harbor.example.com \
  --namespace openan \
  --tag v1.0.0 \
  --orchestration-src /path/to/orchestration-center \
  --push
```

### 方式二：使用 Git 仓库（推荐 CI/CD）

```bash
# 仅构建 Registry Center
./build.sh \
  --registry-repo https://github.com/org/registry-center.git \
  --tag v1.0.0 \
  --push

# 仅构建 Orchestration Center
./build.sh \
  --orchestration-repo https://github.com/org/orchestration-center.git \
  --tag v1.0.0 \
  --push

# 同时构建两个组件
./build.sh \
  --registry-repo https://github.com/org/registry-center.git \
  --orchestration-repo https://github.com/org/orchestration-center.git \
  --tag v1.0.0 \
  --push
```

注意：Workflow Designer 是 Orchestration Center 的子目录，构建 Orchestration Center 时会自动包含。

### 方式三：使用配置文件

```bash
# 复制配置文件模板
cp build-config.yaml.example build-config.yaml

# 编辑配置文件
vim build-config.yaml

# 使用配置文件构建
./build.sh --config build-config.yaml
```

注意：Workflow Designer 是 Orchestration Center 的子目录，默认使用 `{orchestration-center}/workflow-designer`，无需单独配置。

## 多架构构建

构建脚本默认支持多架构（amd64 + arm64），可以通过 `--platforms` 参数自定义目标平台。

### 前置要求

1. **安装 QEMU**（用于模拟不同架构）
   ```bash
   # Ubuntu/Debian
   sudo apt-get install qemu-user-static
   
   # 或使用 Docker
   docker run --privileged --rm tonistiigi/binfmt --install all
   ```

2. **创建 buildx builder**
   ```bash
   docker buildx create --name multiarch --use
   ```

### 构建多架构镜像

```bash
# 默认构建 amd64 + arm64
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --push

# 自定义目标平台
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --platforms linux/amd64,linux/arm64,linux/arm/v7 \
  --push

# 仅构建单架构（更快）
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --platforms linux/amd64 \
  --push
```

### 验证多架构镜像

```bash
# 查看镜像支持的架构
docker buildx imagetools inspect your-registry.com/openan/registry-center:latest

# 输出示例：
# Name: your-registry.com/openan/registry-center:latest
# Manifests:
#   Name: ...@sha256:abc123
#   Platform: linux/amd64
#   
#   Name: ...@sha256:def456
#   Platform: linux/arm64
```

### 注意事项

1. **必须推送**：多架构镜像必须推送到仓库，无法在本地直接使用
2. **构建时间**：多架构构建时间约为单架构的 N 倍（N = 架构数量）
3. **仓库支持**：确保镜像仓库支持多架构 manifest（Docker Hub、Harbor、ACR 等都支持）

## 配置参数说明

### 命令行参数

| 参数 | 说明 | 必填 | 示例 |
|------|------|------|------|
| `--registry` | 镜像仓库地址 | 否 | `harbor.example.com` |
| `--namespace` | 镜像命名空间 | 否 | `openan` |
| `--tag` | 镜像标签 | 否 | `v1.0.0` |
| `--push` | 构建后推送 | 否 | - |
| `--config` | 配置文件路径 | 否 | `build-config.yaml` |
| `--registry-src` | Registry Center 本地路径 | 二选一 | `/path/to/registry-center` |
| `--orchestration-src` | Orchestration Center 本地路径 | 二选一 | `/path/to/orchestration-center` |
| `--frontend-src` | Workflow Designer 本地路径 | 否 | `/path/to/workflow-designer` |
| `--registry-repo` | Registry Center Git 仓库 | 二选一 | `https://github.com/...` |
| `--orchestration-repo` | Orchestration Center Git 仓库 | 二选一 | `https://github.com/...` |
| `--registry-branch` | Registry Center 分支 | 否 | `main` |
| `--orchestration-branch` | Orchestration Center 分支 | 否 | `main` |
| `--platforms` | 目标平台架构 | 否 | `linux/amd64,linux/arm64` |

**说明**：至少需要指定一个组件的源码（`--registry-src` 或 `--orchestration-src`），未指定的组件将跳过构建。

### 配置文件参数

参见 `build-config.yaml.example` 中的注释。

注意：Workflow Designer 是 Orchestration Center 的子目录，配置文件中只需配置 `orchestration-center`，`workflow-designer` 会自动使用 `{orchestration-center}/workflow-designer`。

## 构建流程

```
1. 解析参数（命令行 > 配置文件 > 默认值）
   ↓
2. 准备源码
   ├─ 本地路径：验证路径存在
   └─ Git 仓库：克隆到临时目录
   ↓
3. 构建镜像（仅构建指定了源码的组件）
   ├─ registry-center        (如果指定了 --registry-src 或 --registry-repo)
   ├─ orchestration-center   (如果指定了 --orchestration-src 或 --orchestration-repo)
   └─ workflow-designer      (如果构建了 orchestration-center)
   ↓
4. 推送镜像（如果指定 --push）
   ↓
5. 清理临时目录
```

## 镜像命名规范

构建的镜像命名格式：

```
{registry}/{namespace}/{component}:{tag}
```

示例：
- `harbor.example.com/openan/registry-center:v1.0.0`
- `harbor.example.com/openan/orchestration-center:v1.0.0`
- `harbor.example.com/openan/workflow-designer:v1.0.0`

## 与 Helm Chart 集成

构建完成后，使用以下方式部署：

```bash
# 仅构建了 Registry Center
helm install openan . \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0

# 仅构建了 Orchestration Center
helm install openan . \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0

# 同时构建两个组件
helm install openan . \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0
```

## CI/CD 集成示例

### GitHub Actions

```yaml
name: Build and Push Images

on:
  push:
    tags:
      - 'v*'

jobs:
  build-registry:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      
      - name: Login to Registry
        uses: docker/login-action@v2
        with:
          registry: ${{ secrets.REGISTRY_URL }}
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}
      
      - name: Build and Push Registry Center
        run: |
          cd k8s/openan-chart/build
          ./build.sh \
            --registry ${{ secrets.REGISTRY_URL }} \
            --namespace openan \
            --tag ${{ github.ref_name }} \
            --registry-repo https://github.com/org/registry-center.git \
            --push

  build-orchestration:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      
      - name: Login to Registry
        uses: docker/login-action@v2
        with:
          registry: ${{ secrets.REGISTRY_URL }}
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}
      
      - name: Build and Push Orchestration Center
        run: |
          cd k8s/openan-chart/build
          ./build.sh \
            --registry ${{ secrets.REGISTRY_URL }} \
            --namespace openan \
            --tag ${{ github.ref_name }} \
            --orchestration-repo https://github.com/org/orchestration-center.git \
            --push
```

### GitLab CI

```yaml
build-registry:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - cd k8s/openan-chart/build
    - ./build.sh
      --registry $CI_REGISTRY
      --namespace openan
      --tag $CI_COMMIT_TAG
      --registry-repo https://github.com/org/registry-center.git
      --push
  only:
    - tags

build-orchestration:
  stage: build
  image: docker:latest
  services:
    - docker:dind
  script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
    - cd k8s/openan-chart/build
    - ./build.sh
      --registry $CI_REGISTRY
      --namespace openan
      --tag $CI_COMMIT_TAG
      --orchestration-repo https://github.com/org/orchestration-center.git
      --push
  only:
    - tags
```

## 常见问题

### Q: Workflow Designer 如何指定源码？

A: Workflow Designer 是 Orchestration Center 的子目录，默认使用 `{orchestration-src}/workflow-designer`。如需使用其他路径，可通过 `--frontend-src` 参数指定：

```bash
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --frontend-src /custom/path/to/workflow-designer
```

### Q: 如何只构建单个组件？

A: 脚本支持选择性构建，只需指定一个组件的源码：

```bash
# 仅构建 Registry Center
./build.sh --registry-src /path/to/registry-center

# 仅构建 Orchestration Center（自动包含 Workflow Designer）
./build.sh --orchestration-src /path/to/orchestration-center
```

### Q: 如何跳过 Workflow Designer 的构建？

A: 如果 Orchestration Center 源码中没有 `workflow-designer` 目录，脚本会自动跳过前端构建。也可以通过 `--frontend-src ""` 显式跳过。

### Q: 构建失败如何调试？

A: 使用 `--no-cache` 参数禁用缓存，查看详细构建日志：

```bash
docker build --no-cache -t my-image /path/to/source
```

### Q: 如何使用私有 Git 仓库？

A: 配置 Git 认证：

```bash
# 方式一：使用 SSH
git clone git@github.com:org/repo.git

# 方式二：使用 HTTPS + Token
git clone https://token@github.com/org/repo.git

# 方式三：配置 Git credential
git config --global credential.helper store
```

### Q: 如何验证镜像是否构建成功？

A: 使用以下命令检查：

```bash
# 列出镜像
docker images | grep openan

# 测试运行
docker run --rm my-registry.com/openan/registry-center:v1.0.0 --help
```

## 最佳实践

1. **选择性构建**：仅构建有变更的组件，节省构建时间
2. **版本标签**：生产环境使用语义化版本（如 `v1.0.0`），开发环境使用 `latest` 或 git commit hash
3. **镜像扫描**：推送前使用 `trivy` 或 `snyk` 扫描镜像漏洞
4. **多架构支持**：使用 `docker buildx` 构建多架构镜像（amd64/arm64）
5. **缓存优化**：合理编写 Dockerfile，利用构建缓存加速构建
6. **安全存储**：使用 Kubernetes Secrets 或 Vault 存储镜像仓库凭证

## 相关文档

- [Helm Chart 使用指南](../README.md)
- [K8S 部署设计文档](../../../docs/k8s-deployment-design.md)
- [Docker 官方文档](https://docs.docker.com/)
