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

# 构建所有镜像（Workflow Designer 默认使用 {orchestration-src}/workflow-designer）
./build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center

# 构建并推送
./build.sh \
  --registry harbor.example.com \
  --namespace openan \
  --tag v1.0.0 \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --push
```

### 方式二：使用 Git 仓库（推荐 CI/CD）

```bash
./build.sh \
  --registry-repo https://github.com/org/registry-center.git \
  --orchestration-repo https://github.com/org/orchestration-center.git \
  --tag v1.0.0 \
  --push
```

注意：Workflow Designer 是 Orchestration Center 的子目录，无需单独指定 Git 仓库。

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

| 参数 | 说明 | 示例 |
|------|------|------|
| `--registry` | 镜像仓库地址 | `harbor.example.com` |
| `--namespace` | 镜像命名空间 | `openan` |
| `--tag` | 镜像标签 | `v1.0.0` |
| `--push` | 构建后推送 | - |
| `--config` | 配置文件路径 | `build-config.yaml` |
| `--registry-src` | Registry Center 本地路径 | `/path/to/registry-center` |
| `--orchestration-src` | Orchestration Center 本地路径 | `/path/to/orchestration-center` |
| `--frontend-src` | Workflow Designer 本地路径（默认: `{orchestration-src}/workflow-designer`） | `/path/to/orchestration-center/workflow-designer` |
| `--registry-repo` | Registry Center Git 仓库 | `https://github.com/...` |
| `--orchestration-repo` | Orchestration Center Git 仓库 | `https://github.com/...` |
| `--registry-branch` | Registry Center 分支 | `main` |
| `--orchestration-branch` | Orchestration Center 分支 | `main` |
| `--platforms` | 目标平台架构 | `linux/amd64,linux/arm64` |

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
3. 构建镜像
   ├─ registry-center
   ├─ orchestration-center
   └─ workflow-designer (使用 {orchestration-center}/workflow-designer)
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
# 方式一：命令行指定镜像
helm install openan . \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0

# 方式二：修改 values.yaml
# 编辑 values.yaml 中的 image 配置
vim ../values.yaml

# 部署
helm install openan .
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
  build:
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
      
      - name: Build and Push
        run: |
          cd k8s/openan-chart/build
          ./build.sh \
            --registry ${{ secrets.REGISTRY_URL }} \
            --namespace openan \
            --tag ${{ github.ref_name }} \
            --registry-repo https://github.com/org/registry-center.git \
            --orchestration-repo https://github.com/org/orchestration-center.git \
            --push
```

### GitLab CI

```yaml
build-images:
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

A: 当前脚本不支持单独构建，可以手动执行：

```bash
docker build -t my-registry.com/openan/registry-center:v1.0.0 /path/to/registry-center
docker push my-registry.com/openan/registry-center:v1.0.0
```

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

1. **版本标签**：生产环境使用语义化版本（如 `v1.0.0`），开发环境使用 `latest` 或 git commit hash
2. **镜像扫描**：推送前使用 `trivy` 或 `snyk` 扫描镜像漏洞
3. **多架构支持**：使用 `docker buildx` 构建多架构镜像（amd64/arm64）
4. **缓存优化**：合理编写 Dockerfile，利用构建缓存加速构建
5. **安全存储**：使用 Kubernetes Secrets 或 Vault 存储镜像仓库凭证

## 相关文档

- [Helm Chart 使用指南](../README.md)
- [K8S 部署设计文档](../../../docs/k8s-deployment-design.md)
- [Docker 官方文档](https://docs.docker.com/)
