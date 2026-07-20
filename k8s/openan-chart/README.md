# OpenAN Platform Helm Chart

OpenAN 平台 Helm Chart，用于在 Kubernetes 集群上一键部署完整的 OpenAN 平台。

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
- 容器镜像（参考 [镜像构建指南](./build/README.md)）

## 快速开始

### 1. 添加 Helm 仓库（如已发布）

```bash
helm repo add openan https://charts.openan.io
helm repo update
```

### 2. 安装 Chart

```bash
# 基础安装（使用默认配置）
helm install openan . --namespace openan --create-namespace

# 如果命名空间已存在且不是由 Helm 管理的
kubectl create namespace openan
helm install openan . --namespace openan --set createNamespace=false

# 自定义镜像仓库
helm install openan . \
  --namespace openan \
  --create-namespace \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0

# 使用外部数据库
helm install openan . \
  --namespace openan \
  --create-namespace \
  --set postgresql.enabled=false \
  --set postgresql.externalHost=db.example.com \
  --set postgresql.password=your-password
```

### 3. 配置 LLM API Key

创建 Secret：

```bash
kubectl create secret generic openan-llm-keys \
  --namespace openan \
  --from-literal=registry-chat-key=sk-your-registry-key \
  --from-literal=orchestration-chat-key=sk-your-orchestration-key \
  --from-literal=orchestration-a2at-key=sk-your-a2at-key
```

在 values.yaml 中引用：

```yaml
registry:
  llm:
    chat:
      existingSecret: openan-llm-keys
      existingSecretKey: registry-chat-key

orchestration:
  llm:
    chat:
      existingSecret: openan-llm-keys
      existingSecretKey: orchestration-chat-key
  a2at:
    existingSecret: openan-llm-keys
    existingSecretKey: orchestration-a2at-key
```

### 4. 验证部署

```bash
# 查看 Pod 状态
kubectl get pods -n openan

# 查看服务
kubectl get svc -n openan

# 查看 Ingress
kubectl get ingress -n openan

# 测试 API
curl http://localhost:5000/rest/v1/registry-center/agent-cards
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
| `postgresql.storage` | 存储大小 | `20Gi` |
| `postgresql.storageClassName` | StorageClass 名称 | `""` |

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
| `registry.tls.mode` | TLS 证书模式 | `auto` |
| `registry.signing.mode` | JWS 签名证书模式 | `auto` |

### Orchestration Center 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `orchestration.enabled` | 是否启用 Orchestration Center | `true` |
| `orchestration.replicas` | 副本数 | `2` |
| `orchestration.image.repository` | 镜像仓库 | `orchestration-center` |
| `orchestration.image.tag` | 镜像标签 | `latest` |
| `orchestration.port` | 服务端口 | `5001` |
| `orchestration.agentRegistryUrl` | Registry Center URL | `""` (自动发现) |
| `orchestration.llm.chat.model` | Chat 模型 | `deepseek-chat` |
| `orchestration.llm.chat.url` | Chat API URL | `https://api.deepseek.com/v1/chat/completions` |
| `orchestration.llm.chat.apiKey` | Chat API Key | `""` |
| `orchestration.a2at.provider` | A2AT 提供商 | `deepseek` |
| `orchestration.a2at.model` | A2AT 模型 | `deepseek-chat` |
| `orchestration.a2at.baseUrl` | A2AT Base URL | `https://api.deepseek.com` |
| `orchestration.a2at.apiKey` | A2AT API Key | `""` |

### Workflow Designer 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `frontend.enabled` | 是否启用 Workflow Designer | `true` |
| `frontend.replicas` | 副本数 | `2` |
| `frontend.image.repository` | 镜像仓库 | `workflow-designer` |
| `frontend.image.tag` | 镜像标签 | `latest` |
| `frontend.port` | 服务端口 | `80` |

### Ingress 配置

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `ingress.enabled` | 是否启用 Ingress | `true` |
| `ingress.className` | Ingress Class | `nginx` |
| `ingress.host` | 域名 | `openan.example.com` |
| `ingress.tls.enabled` | 是否启用 TLS | `false` |
| `ingress.tls.secretName` | TLS Secret 名称 | `openan-tls` |

## 部署场景

### 开发环境

```bash
helm install openan-dev . \
  --namespace openan-dev \
  --create-namespace \
  --set postgresql.storage=10Gi \
  --set registry.replicas=1 \
  --set orchestration.replicas=1 \
  --set frontend.replicas=1 \
  --set registry.hpa.enabled=false \
  --set orchestration.hpa.enabled=false \
  --set frontend.hpa.enabled=false
```

### 生产环境

```bash
# 使用 values-prod.yaml 文件
helm install openan-prod . \
  --namespace openan-prod \
  --create-namespace \
  -f values-prod.yaml
```

示例 `values-prod.yaml`：

```yaml
postgresql:
  storage: 100Gi
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
┌─────────────────────────────────────────────────────────────┐
│                    openan namespace                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐      ┌──────────────────────────────┐   │
│  │   Ingress    │─────▶│  Workflow Designer (前端)    │   │
│  │  (Nginx)     │      │  - Deployment (2 pods)       │   │
│  │  / → :80     │      │  - Service :80               │   │
│  │  /registry   │      │  - HPA                       │   │
│  │  → :5000     │      └──────────────────────────────┘   │
│  └──────────────┘                  │                       │
│          │                         │ /rest/v1/orchestrate  │
│          ▼                         ▼                       │
│  ┌──────────────────────────────────────────────────────┐ │
│  │           Orchestration Center                       │ │
│  │           - Deployment (2 pods)                      │ │
│  │           - Service :5001                            │ │
│  │           - HPA                                      │ │
│  └──────────────────────────────────────────────────────┘ │
│          │                                                 │
│          ▼                                                 │
│  ┌──────────────────────────────────────────────────────┐ │
│  │           Registry Center                            │ │
│  │           - Deployment (2 pods)                      │ │
│  │           - Service :5000                            │ │
│  │           - HPA                                      │ │
│  └──────────────────────────────────────────────────────┘ │
│          │                                                 │
│          ▼                                                 │
│  ┌──────────────────────────────────────────────────────┐ │
│  │           PostgreSQL (共享)                          │ │
│  │           - StatefulSet                              │ │
│  │           - registry_center DB                       │ │
│  │           - orchestration_center DB                  │ │
│  │           - PVC 20Gi                                 │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## 证书管理

Registry Center 需要 TLS 和 JWS 签名证书，支持三种模式：

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| `auto` | Helm 自动生成自签名证书 | 开发/测试 |
| `secret` | 使用预创建的 Secret | 生产环境 |
| `off` | 不挂载证书，entrypoint 自动生成 | 调试 |

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

- [镜像构建指南](./build/README.md)
- [K8S 部署设计文档](../../docs/k8s-deployment-design.md)
- [单机 Docker Compose 部署](../deploy-standalone/README.md)

## License

Apache License 2.0
