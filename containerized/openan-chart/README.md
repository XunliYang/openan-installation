# OpenAN Platform Helm Chart

OpenAN 平台 Helm Chart，用于在 Kubernetes 集群上一键部署完整的 OpenAN 平台。

## 部署方式对比

| 特性 | 纯 YAML | Helm Chart（本文档） |
|------|---------|---------------------|
| 适用场景 | 简单部署、快速验证 | 生产环境、多配置管理 |
| 部署命令 | `kubectl apply -f k8s/` | `helm install openan ./openan-chart` |
| 可选组件 | 需手动排除文件 | `--set orchestration.enabled=false` |
| 配置管理 | 直接编辑 YAML 文件 | `values.yaml` + 命令行覆盖 |
| 多环境支持 | 需维护多套文件 | `values-dev.yaml` / `values-prod.yaml` |
| 学习成本 | 低 | 需要 Helm 基础知识 |

> 纯 YAML 部署请参考 [K8S 部署指南](../../k8s-deployment-guide.md)。

## 组件说明

本 Chart 部署以下组件：

| 组件 | 说明 | 默认端口 |
|------|------|----------|
| **Registry Center** | Agent 注册中心，提供 Agent Card 注册、发现、语义搜索 | 5000 |
| **Orchestration Center** | 工作流编排中心，提供 PSOP 生成、工作流执行 | 5001 |
| **Workflow Designer** | 前端工作流设计器，提供可视化工作流编辑界面 | 80 |
| **PostgreSQL** | 共享数据库，存储 registry_center 和 orchestration_center | 5432 |

## 前置要求

- Kubernetes 1.24+
- Helm 3.x
- kubectl 已配置
- Ingress Controller (Nginx) 已安装（如需外部访问）
- 容器镜像已推送到可访问的仓库（参考 [镜像构建指南](../build/README.md)）

## 文件结构

```
openan-chart/
├── Chart.yaml                           # Chart 元数据
├── values.yaml                          # 默认配置
└── templates/
    ├── _helpers.tpl                     # 模板函数
    ├── namespace.yaml                   # openan namespace
    ├── ingress.yaml                     # 统一入口（frontend / orchestration / registry）
    ├── NOTES.txt                        # 部署提示
    ├── postgres/
    │   ├── storage.yaml                 # StorageClass / PV（可选）
    │   └── statefulset.yaml             # 共享 PostgreSQL
    ├── registry-center/
    │   ├── secret.yaml                  # registry 独立 secret
    │   ├── configmap.yaml               # registry 配置
    │   ├── deployment.yaml
    │   ├── service.yaml                 # port 5000
    │   ├── tls-secret.yaml              # TLS 证书（auto 模式）
    │   └── signing-secret.yaml          # JWS 签名证书（auto 模式）
    ├── orchestration-center/
    │   ├── secret.yaml                  # orchestration 独立 secret
    │   ├── configmap.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml                 # port 5001
    │   └── hpa.yaml
    └── workflow-designer/
        ├── deployment.yaml
        ├── service.yaml                 # port 80
        └── hpa.yaml
```

## 快速开始

### 1. 添加 Helm 仓库（如已发布）

```bash
helm repo add openan https://charts.openan.io
helm repo update
```

### 2. 准备配置

创建 `values-custom.yaml`：

```yaml
# 数据库密码
postgresql:
  password: "your-secure-password"

# Registry Center LLM 配置
registry:
  llm:
    chat:
      apiKey: "sk-registry-chat-key"
    embed:
      apiKey: "sk-registry-embed-key"
    rerank:
      apiKey: "sk-registry-rerank-key"

# Orchestration Center LLM 配置
orchestration:
  llm:
    chat:
      apiKey: "sk-orchestration-chat-key"
  a2at:
    apiKey: "sk-orchestration-a2at-key"

# Ingress 配置
ingress:
  host: openan.your-domain.com
  tls:
    enabled: true
    secretName: openan-tls
```

### 3. 安装 Chart

```bash
# 使用自定义配置安装
helm install openan . \
  -n openan --create-namespace \
  -f values-custom.yaml

# 或使用命令行覆盖
helm install openan . \
  -n openan --create-namespace \
  --set postgresql.password=your-password \
  --set registry.llm.chat.apiKey=sk-xxx \
  --set orchestration.llm.chat.apiKey=sk-yyy \
  --set ingress.host=openan.example.com

# 自定义镜像仓库
helm install openan . \
  -n openan --create-namespace \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0

# 如果命名空间已存在且不是由 Helm 管理的
kubectl create namespace openan
helm install openan . -n openan --set createNamespace=false
```

### 4. 配置 LLM API Key（使用外部 Secret）

创建 Secret：

```bash
kubectl create secret generic openan-llm-keys \
  --namespace openan \
  --from-literal=registry-chat-key=sk-your-registry-key \
  --from-literal=registry-embed-key=sk-your-embed-key \
  --from-literal=registry-rerank-key=sk-your-rerank-key \
  --from-literal=orchestration-chat-key=sk-your-orchestration-key \
  --from-literal=orchestration-a2at-key=sk-your-a2at-key
```

在 `values-custom.yaml` 中引用：

```yaml
registry:
  llm:
    chat:
      existingSecret: openan-llm-keys
      existingSecretKey: registry-chat-key
    embed:
      existingSecret: openan-llm-keys
      existingSecretKey: registry-embed-key
    rerank:
      existingSecret: openan-llm-keys
      existingSecretKey: registry-rerank-key

orchestration:
  llm:
    chat:
      existingSecret: openan-llm-keys
      existingSecretKey: orchestration-chat-key
  a2at:
    existingSecret: openan-llm-keys
    existingSecretKey: orchestration-a2at-key
```

### 5. 验证部署

```bash
# 查看 Helm 发布状态
helm status openan -n openan

# 查看 Pod 状态
kubectl get pods -n openan

# 查看所有资源
kubectl get all -n openan

# 查看 Ingress
kubectl get ingress -n openan

# 查看日志
kubectl logs -n openan -l app=registry-center -f
kubectl logs -n openan -l app=orchestration-center -f
```

### 6. 通过 Ingress 访问

**配置 hosts（如果使用自定义域名）：**

```bash
# 添加以下到 /etc/hosts（Linux/Mac）或 C:\Windows\System32\drivers\etc\hosts（Windows）
# 假设 Ingress Controller 的 IP 为 192.168.200.183
192.168.200.183  openan.local
```

**访问 Workflow Designer（前端）：**

浏览器访问 `http://openan.local/`

**访问 Registry API：**

```bash
# 查询所有 Agent
curl http://openan.local/registry/rest/v1/registry-center/agent-cards

# 注册新 Agent
curl -X POST http://openan.local/registry/rest/v1/registry-center/agent-cards \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-agent",
    "description": "My custom agent",
    "url": "http://my-agent:8080",
    "version": "1.0.0"
  }'

# 查询特定 Agent
curl http://openan.local/registry/rest/v1/registry-center/agent-cards/my-agent

# 删除 Agent
curl -X DELETE http://openan.local/registry/rest/v1/registry-center/agent-cards/my-agent
```

**访问 Orchestration API：**

```bash
# 查询 Agent 列表
curl http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards
```

**端口转发（调试用）：**

```bash
# Registry Center
kubectl -n openan port-forward svc/registry-center 5000:5000
curl http://localhost:5000/rest/v1/registry-center/agent-cards

# Orchestration Center
kubectl -n openan port-forward svc/orchestration-center 5001:5001
curl http://localhost:5001/rest/v1/orchestrate/agent-cards
```

## 配置参数

### 全局配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `namespace` | Kubernetes 命名空间 | `openan` |
| `createNamespace` | 是否由 Helm 创建命名空间 | `true` |

**注意**：如果命名空间已存在且不是由 Helm 管理的，需要设置 `createNamespace=false`，否则会遇到 "namespace already exists" 错误。

### PostgreSQL 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `postgresql.enabled` | 是否启用内置 PostgreSQL | `true` |
| `postgresql.externalHost` | 外部数据库地址 | `""` |
| `postgresql.port` | 数据库端口 | `5432` |
| `postgresql.password` | 数据库密码 | `"openan-db-password"` |
| `postgresql.storage.size` | 存储大小 | `20Gi` |
| `postgresql.storage.createStorageClass` | 是否自动创建 StorageClass | `false` |
| `postgresql.storage.createPV` | 是否自动创建 PV | `false` |
| `postgresql.storage.storageClassName` | StorageClass 名称 | `"openan-local"` |
| `postgresql.storage.setDefault` | 是否设为默认 StorageClass | `false` |
| `postgresql.storage.reclaimPolicy` | 回收策略（Retain/Delete） | `"Retain"` |
| `postgresql.storage.useHostPath` | 是否使用 hostPath（单节点集群） | `true` |
| `postgresql.storage.hostPath` | hostPath 目录 | `"/data/openan-postgres"` |
| `postgresql.storage.nodeName` | 节点名称（useHostPath=false 时） | `""` |

**存储配置说明：**

**场景一：集群已有默认 StorageClass**
```yaml
postgresql:
  storage:
    createStorageClass: false
    createPV: false
```

**场景二：单节点集群，使用 hostPath**
```yaml
postgresql:
  storage:
    createStorageClass: true
    createPV: true
    useHostPath: true
    hostPath: "/data/openan-postgres"
```

**场景三：多节点集群，使用 local volume**
```yaml
postgresql:
  storage:
    createStorageClass: true
    createPV: true
    useHostPath: false
    localPath: "/data/openan-postgres"
    nodeName: "node185"
```

**注意**：使用 hostPath 或 local volume 时，需要确保节点上已创建对应目录：
```bash
# 在目标节点上执行
mkdir -p /data/openan-postgres
```

### Registry Center 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `registry.enabled` | 是否启用 Registry Center | `true` |
| `registry.replicas` | 副本数 | `2` |
| `registry.image.repository` | 镜像仓库 | `registry-center` |
| `registry.image.tag` | 镜像标签 | `latest` |
| `registry.image.pullPolicy` | 镜像拉取策略 | `Always` |
| `registry.port` | 服务端口 | `5000` |
| `registry.llm.chat.model` | Chat 模型 | `deepseek-chat` |
| `registry.llm.chat.url` | Chat API URL | `https://api.deepseek.com/v1/chat/completions` |
| `registry.llm.chat.apiKey` | Chat API Key | `""` |
| `registry.llm.chat.existingSecret` | 引用已有 Secret | `""` |
| `registry.llm.embed.model` | Embed 模型 | `bge-m3` |
| `registry.llm.embed.url` | Embed API URL | `""` |
| `registry.llm.embed.apiKey` | Embed API Key | `""` |
| `registry.llm.rerank.model` | Rerank 模型 | `bge-reranker-v2-m3` |
| `registry.llm.rerank.url` | Rerank API URL | `""` |
| `registry.llm.rerank.apiKey` | Rerank API Key | `""` |
| `registry.vectordb.enabled` | 是否启用 VectorDB (Milvus) | `false` |
| `registry.vectordb.host` | VectorDB 地址 | `""` |
| `registry.vectordb.port` | VectorDB 端口 | `19530` |
| `registry.tls.mode` | TLS 证书模式：`auto`/`secret`/`off` | `auto` |
| `registry.tls.existingSecret` | TLS 证书 Secret 名称 | `""` |
| `registry.signing.mode` | JWS 签名证书模式：`auto`/`secret`/`off` | `auto` |
| `registry.signing.existingSecret` | JWS 签名证书 Secret 名称 | `""` |
| `registry.resources.requests` | 资源请求 | `cpu: 250m, memory: 256Mi` |
| `registry.resources.limits` | 资源限制 | `cpu: 500m, memory: 512Mi` |
| `registry.livenessProbe` | 存活探针 | `path: /rest/v1/registry-center/agent-cards` |
| `registry.readinessProbe` | 就绪探针 | `path: /rest/v1/registry-center/agent-cards` |

### Orchestration Center 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `orchestration.enabled` | 是否启用 Orchestration Center | `true` |
| `orchestration.replicas` | 副本数 | `2` |
| `orchestration.image.repository` | 镜像仓库 | `orchestration-center` |
| `orchestration.image.tag` | 镜像标签 | `latest` |
| `orchestration.image.pullPolicy` | 镜像拉取策略 | `Always` |
| `orchestration.port` | 服务端口 | `5001` |
| `orchestration.agentRegistryUrl` | Registry Center URL | `""` (自动发现) |
| `orchestration.llm.chat.model` | Chat 模型 | `deepseek-chat` |
| `orchestration.llm.chat.url` | Chat API URL | `https://api.deepseek.com/v1/chat/completions` |
| `orchestration.llm.chat.apiKey` | Chat API Key | `""` |
| `orchestration.llm.chat.existingSecret` | 引用已有 Secret | `""` |
| `orchestration.a2at.provider` | A2AT 提供商 | `deepseek` |
| `orchestration.a2at.model` | A2AT 模型 | `deepseek-chat` |
| `orchestration.a2at.baseUrl` | A2AT Base URL | `https://api.deepseek.com` |
| `orchestration.a2at.apiKey` | A2AT API Key | `""` |
| `orchestration.a2at.existingSecret` | 引用已有 Secret | `""` |
| `orchestration.hpa.enabled` | 是否启用 HPA | `true` |
| `orchestration.hpa.minReplicas` | 最小副本数 | `2` |
| `orchestration.hpa.maxReplicas` | 最大副本数 | `10` |
| `orchestration.resources.requests` | 资源请求 | `cpu: 250m, memory: 512Mi` |
| `orchestration.resources.limits` | 资源限制 | `cpu: 1000m, memory: 1Gi` |
| `orchestration.livenessProbe` | 存活探针 | `path: /rest/v1/orchestrate/agent-cards` |
| `orchestration.readinessProbe` | 就绪探针 | `path: /rest/v1/orchestrate/agent-cards` |
| `orchestration.startupProbe` | 启动探针 | `failureThreshold: 12` |

### Workflow Designer 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `frontend.enabled` | 是否启用 Workflow Designer | `true` |
| `frontend.replicas` | 副本数 | `2` |
| `frontend.image.repository` | 镜像仓库 | `workflow-designer` |
| `frontend.image.tag` | 镜像标签 | `latest` |
| `frontend.image.pullPolicy` | 镜像拉取策略 | `Always` |
| `frontend.port` | 服务端口 | `80` |
| `frontend.nodePort` | NodePort 端口 | `30080` |
| `frontend.hpa.enabled` | 是否启用 HPA | `true` |
| `frontend.hpa.minReplicas` | 最小副本数 | `2` |
| `frontend.hpa.maxReplicas` | 最大副本数 | `10` |
| `frontend.resources.requests` | 资源请求 | `cpu: 100m, memory: 128Mi` |
| `frontend.resources.limits` | 资源限制 | `cpu: 500m, memory: 256Mi` |

### Ingress 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `ingress.enabled` | 是否启用 Ingress | `true` |
| `ingress.className` | Ingress Class | `nginx` |
| `ingress.host` | 域名 | `openan.local` |
| `ingress.tls.enabled` | 是否启用 TLS | `false` |
| `ingress.tls.secretName` | TLS Secret 名称 | `openan-tls` |

## 部署场景

### 开发环境

```bash
helm install openan-dev . \
  --namespace openan-dev \
  --create-namespace \
  -f values-dev.yaml
```

示例 `values-dev.yaml`：

```yaml
postgresql:
  storage:
    size: 10Gi

registry:
  replicas: 1

orchestration:
  replicas: 1
  hpa:
    enabled: false

frontend:
  replicas: 1
  hpa:
    enabled: false

ingress:
  host: openan-dev.example.com
```

### 生产环境

```bash
helm install openan-prod . \
  --namespace openan-prod \
  --create-namespace \
  -f values-prod.yaml
```

示例 `values-prod.yaml`：

```yaml
postgresql:
  storage:
    size: 100Gi
  resources:
    requests:
      cpu: 1000m
      memory: 2Gi
    limits:
      cpu: 2000m
      memory: 4Gi

registry:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

orchestration:
  replicas: 3
  hpa:
    minReplicas: 3
    maxReplicas: 20
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 2Gi

frontend:
  replicas: 3
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

ingress:
  host: openan.example.com
  tls:
    enabled: true
    secretName: openan-tls
```

### 仅部署 Registry Center

```bash
helm install openan-registry . \
  --namespace openan \
  --create-namespace \
  --set orchestration.enabled=false \
  --set frontend.enabled=false
```

### 使用外部数据库

```bash
helm install openan . \
  --namespace openan \
  --create-namespace \
  --set postgresql.enabled=false \
  --set postgresql.externalHost=db.example.com \
  --set postgresql.port=5432 \
  --set postgresql.password=your-password
```

### 命名空间已存在

如果命名空间已存在且不是由 Helm 管理的，需要手动创建命名空间并设置 `createNamespace=false`：

```bash
# 手动创建命名空间
kubectl create namespace openan

# 安装时禁用 Helm 创建命名空间
helm install openan . \
  --namespace openan \
  --set createNamespace=false
```

## 常用操作

### 升级

```bash
helm upgrade openan . --namespace openan -f values.yaml
```

### 回滚

```bash
# 查看历史版本
helm history openan -n openan

# 回滚到指定版本
helm rollback openan 1 -n openan
```

### 卸载

```bash
helm uninstall openan -n openan

# 删除 PVC（可选）
kubectl delete pvc -n openan --all
```

### 查看日志

```bash
# Registry Center
kubectl logs -n openan -l app=registry-center -f

# Orchestration Center
kubectl logs -n openan -l app=orchestration-center -f

# Workflow Designer
kubectl logs -n openan -l app=workflow-designer -f

# PostgreSQL
kubectl logs -n openan -l app=openan-postgres -f
```

## 架构说明

```
┌──────────────────────────────────────────────────────────────────┐
│                       openan namespace                           │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐      ┌───────────────────────────────────┐   │
│  │   Ingress    │─────▶│  Workflow Designer (前端)         │   │
│  │  (Nginx)     │      │  - Deployment (2 pods)            │   │
│  │  / → :80     │      │  - Service :80                    │   │
│  │  /api/       │      │  - HPA                            │   │
│  │  orchestrate │      └───────────────────────────────────┘   │
│  │  → :5001     │                      │                       │
│  │  /registry   │                      │ AGENT_REGISTRY_URL    │
│  │  → :5000     │                      ▼                       │
│  └──────────────┘      ┌───────────────────────────────────┐  │
│                        │  Orchestration Center              │  │
│                        │  - Deployment (2 pods)             │  │
│                        │  - Service :5001                   │  │
│                        │  - HPA                             │  │
│                        └───────────────────────────────────┘  │
│                                  │                             │
│                                  ▼                             │
│                        ┌───────────────────────────────────┐  │
│                        │  Registry Center                   │  │
│                        │  - Deployment (2 pods)             │  │
│                        │  - Service :5000                   │  │
│                        └───────────────────────────────────┘  │
│                                  │                             │
│                                  ▼                             │
│                        ┌───────────────────────────────────┐  │
│                        │  PostgreSQL (共享)                 │  │
│                        │  - StatefulSet                     │  │
│                        │  - registry_center DB              │  │
│                        │  - orchestration_center DB         │  │
│                        │  - PVC 20Gi                        │  │
│                        └───────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**Ingress 路径重写规则：**

| 外部路径 | 转发到后端 | 说明 |
|----------|-----------|------|
| `/` | `workflow-designer:80/` | 前端页面 |
| `/api/orchestrate/rest/v1/orchestrate/...` | `orchestration-center:5001/rest/v1/orchestrate/...` | 去掉 `/api/orchestrate` 前缀 |
| `/registry/rest/v1/registry-center/...` | `registry-center:5000/rest/v1/registry-center/...` | 去掉 `/registry` 前缀 |

## 证书管理

Registry Center 需要两类证书：

| 证书类型 | 用途 | 挂载路径 | 文件 |
|----------|------|----------|------|
| TLS 证书 | HTTPS 通信 | `etc/ssl/` | server.cer, server_key.pem, trust.cer |
| JWS 签名证书 | Agent Card 签名 | `etc/sign_cert/` | server.cer, server_key.pem, cert_pwd |

### 证书模式

| 模式 | 说明 | 多副本一致性 | 适用场景 |
|------|------|-------------|----------|
| `auto` (默认) | Helm 用 `genCA`/`genSignedCert` 自动生成，存入 Secret | 一致 | 推荐，所有场景 |
| `secret` | 从用户预创建的 K8S Secret 挂载 | 一致 | 需要正式证书 |
| `off` | entrypoint 每次启动自动生成，不持久化 | 不一致 | 仅开发调试 |

### `auto` 模式工作原理

1. `helm install` 时，Helm 模板调用 `genCA` + `genSignedCert` 生成自签名证书
2. 证书数据写入 K8S Secret (`registry-center-tls` / `registry-center-signing`)
3. Deployment 将 Secret 挂载到 `etc/ssl` 和 `etc/sign_cert`
4. entrypoint 检测到证书文件已存在，跳过自动生成
5. `helm upgrade` 时，通过 `lookup` 检测已有 Secret，**保留原证书不重新生成**

**无需任何手动操作，开箱即用。**

### 使用自动生成的证书（默认）

```yaml
registry:
  tls:
    mode: auto
  signing:
    mode: auto
```

### 使用自定义证书

```bash
# 创建 TLS 证书 Secret
kubectl create secret generic registry-tls \
  --namespace openan \
  --from-file=server.cer=./server.crt \
  --from-file=server_key.pem=./server.key \
  --from-file=trust.cer=./ca.crt

# 创建 JWS 签名证书 Secret
kubectl create secret generic registry-signing \
  --namespace openan \
  --from-file=server.cer=./sign_cert/server.cer \
  --from-file=server_key.pem=./sign_cert/server_key.pem \
  --from-file=cert_pwd=./sign_cert/cert_pwd.txt
```

```yaml
registry:
  tls:
    mode: secret
    existingSecret: registry-tls
  signing:
    mode: secret
    existingSecret: registry-signing
```

## 安全建议

1. **证书管理**：默认 `auto` 模式自动生成自签名证书，生产环境建议使用 `secret` 模式配合正式 CA 证书
2. **Secret 管理**：生产环境建议使用 Vault、AWS Secrets Manager 等管理敏感信息，通过 `existingSecret` 引用
3. **启用 TLS**：配置 Ingress TLS 或使用 cert-manager 自动签发证书
4. **网络策略**：使用 NetworkPolicy 限制 Pod 间通信
5. **镜像安全**：使用私有镜像仓库，启用镜像签名验证
6. **资源限制**：设置合理的 requests/limits 防止资源滥用

## 故障排查

### Namespace 冲突

如果遇到 "namespace already exists" 错误：

```bash
# 方案 1：删除现有命名空间后重新安装
kubectl delete namespace openan
helm install openan . --namespace openan --create-namespace

# 方案 2：手动创建命名空间并设置 createNamespace=false
kubectl create namespace openan
helm install openan . --namespace openan --set createNamespace=false

# 方案 3：清理 Helm release 缓存
kubectl get secrets --all-namespaces | grep "sh.helm.release" | grep openan
kubectl delete secret -l owner=helm,name=openan --all-namespaces
helm install openan . --namespace openan --create-namespace
```

### Pod 无法启动

```bash
# 查看 Pod 状态
kubectl describe pod -n openan <pod-name>

# 查看日志
kubectl logs -n openan <pod-name>
```

### 数据库连接失败

```bash
# 检查 PostgreSQL Pod
kubectl get pods -n openan -l app=openan-postgres

# 测试数据库连接
kubectl exec -n openan <postgres-pod> -- psql -U postgres -c "\l"
```

### Ingress 无法访问

```bash
# 检查 Ingress 资源
kubectl describe ingress -n openan

# 检查 Ingress Controller 日志
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller
```

### 证书问题

```bash
# 查看证书 Secret
kubectl get secret -n openan registry-center-tls -o yaml
kubectl get secret -n openan registry-center-signing -o yaml

# 检查证书挂载
kubectl exec -n openan <registry-pod> -- ls -la /opt/registry-center/etc/ssl
kubectl exec -n openan <registry-pod> -- ls -la /opt/registry-center/etc/sign_cert
```

## 相关文档

- [快速体验](../QUICKSTART.md)（构建 + 部署一站式指南）
- [K8S 部署指南](../../k8s-deployment-guide.md)（含纯 YAML 部署方式）
- [镜像构建指南](../build/README.md)

## License

Apache License 2.0
