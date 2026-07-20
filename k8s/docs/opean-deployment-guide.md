# OpenAN Platform Kubernetes 部署指南

本文档介绍两种在 Kubernetes 集群上部署 OpenAN 平台的方式。

## 部署方式对比

| 特性 | 纯 YAML | Helm Chart |
|------|---------|------------|
| 适用场景 | 简单部署、快速验证 | 生产环境、多配置管理 |
| 部署命令 | `kubectl apply -f k8s/` | `helm install openan ./k8s/openan-chart` |
| 可选组件 | 需手动排除文件 | `--set orchestration.enabled=false` |
| 配置管理 | 直接编辑 YAML 文件 | `values.yaml` + 命令行覆盖 |
| 多环境支持 | 需维护多套文件 | `values-dev.yaml` / `values-prod.yaml` |
| 学习成本 | 低 | 需要 Helm 基础知识 |

## 前置条件

- Kubernetes 1.24+
- kubectl 已配置
- Ingress Controller (Nginx) 已安装（如需外部访问）
- 容器镜像已推送到可访问的仓库

## 架构说明

```
┌─────────────────────────────────────────────────────────────┐
│                    openan namespace                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐      ┌──────────────────────────────┐   │
│  │   Ingress    │─────▶│  orchestration-center (可选) │   │
│  │  (Nginx)     │      │  - Deployment (2~10 pods)    │   │
│  │  / → :5001   │      │  - Service :5001             │   │
│  │  /registry   │      │  - HPA                       │   │
│  │  → :5000     │      └──────────────────────────────┘   │
│  └──────────────┘                  │                       │
│          │                         │ AGENT_REGISTRY_URL    │
│          ▼                         ▼                       │
│  ┌──────────────────────────────────────────────────────┐ │
│  │           registry-center (必选)                     │ │
│  │           - Deployment (2 pods)                      │ │
│  │           - Service :5000                            │ │
│  └──────────────────────────────────────────────────────┘ │
│          │                                                 │
│          ▼                                                 │
│  ┌──────────────────────────────────────────────────────┐ │
│  │           openan-postgres (共享)                     │ │
│  │           - StatefulSet                              │ │
│  │           - registry_center DB                       │ │
│  │           - orchestration_center DB                  │ │
│  │           - PVC 20Gi                                 │ │
│  └──────────────────────────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 方式一：纯 YAML 部署

### 文件结构

```
k8s/
├── namespace.yaml              # Namespace: openan
├── secret.yaml                 # DB 密码、LLM API Keys
├── configmap.yaml              # 环境变量配置
├── postgres-statefulset.yaml   # PostgreSQL StatefulSet
├── deployment.yaml             # orchestration-center Deployment
├── service.yaml                # ClusterIP Service
├── ingress.yaml                # Nginx Ingress
└── hpa.yaml                    # 自动伸缩
```

### 部署步骤

#### 1. 准备配置

编辑 `k8s/secret.yaml`，替换 base64 编码的密钥：

```bash
# 生成 base64 编码值
echo -n "your-db-password" | base64
echo -n "sk-your-llm-api-key" | base64
```

编辑 `k8s/configmap.yaml`，配置：
- `AGENT_REGISTRY_URL`: Registry Center 地址
- `LLM_CHAT_URL`: LLM API 地址
- `DB_HOST`: 数据库地址（默认使用内部 PostgreSQL）

#### 2. 全量部署

```bash
kubectl apply -f k8s/
```

#### 3. 仅部署 Registry Center

```bash
# 排除 orchestration-center 相关文件
for f in namespace secret configmap postgres-statefulset service; do
  kubectl apply -f k8s/${f}.yaml
done
```

#### 4. 使用外部数据库

编辑 `k8s/configmap.yaml`：
```yaml
PERSISTENCE_MODE: "postgresql"
DB_HOST: "your-external-db.example.com"
```

跳过 PostgreSQL 部署：
```bash
for f in namespace secret configmap deployment service ingress hpa; do
  kubectl apply -f k8s/${f}.yaml
done
```

#### 5. 验证部署

```bash
# 查看 Pod 状态
kubectl -n openan get pods

# 查看 Service
kubectl -n openan get svc

# 查看日志
kubectl -n openan logs -l app=orchestration-center -f
kubectl -n openan logs -l app=registry-center -f

# 测试 API
kubectl -n openan port-forward svc/orchestration-center 5001:5001
curl http://localhost:5001/rest/v1/orchestrate/agent-cards
```

#### 6. 卸载

```bash
kubectl delete -f k8s/
```

---

## 方式二：Helm Chart 部署

### 文件结构

```
k8s/openan-chart/
├── Chart.yaml                           # Chart 元数据
├── values.yaml                          # 默认配置
└── templates/
    ├── _helpers.tpl                     # 模板函数
    ├── namespace.yaml                   # openan namespace
    ├── ingress.yaml                     # 统一入口
    ├── NOTES.txt                        # 部署提示
    ├── postgres/
    │   └── statefulset.yaml             # 共享 PostgreSQL
    ├── registry-center/
    │   ├── secret.yaml                  # registry 独立 secret
    │   ├── configmap.yaml               # registry 配置
    │   ├── deployment.yaml
    │   └── service.yaml                 # port 5000
    └── orchestration-center/
        ├── secret.yaml                  # orchestration 独立 secret
        ├── configmap.yaml
        ├── deployment.yaml
        ├── service.yaml                 # port 5001
        └── hpa.yaml
```

### 部署步骤

#### 1. 准备配置

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

#### 2. 全量部署

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  -f values-custom.yaml
```

或使用命令行覆盖：

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  --set postgresql.password=your-password \
  --set registry.llm.chat.apiKey=sk-xxx \
  --set orchestration.llm.chat.apiKey=sk-yyy \
  --set ingress.host=openan.example.com
```

#### 3. 仅部署 Registry Center

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  --set orchestration.enabled=false \
  --set registry.llm.chat.apiKey=sk-xxx
```

#### 4. 使用外部数据库

```bash
helm install openan ./k8s/openan-chart \
  -n openan --create-namespace \
  --set postgresql.enabled=false \
  --set postgresql.externalHost=your-db.example.com \
  --set postgresql.password=your-password \
  --set registry.llm.chat.apiKey=sk-xxx
```

#### 5. 多环境部署

创建环境特定配置文件：

**values-dev.yaml**:
```yaml
postgresql:
  storage: 10Gi

registry:
  replicas: 1

orchestration:
  replicas: 1
  hpa:
    enabled: false

ingress:
  host: openan-dev.example.com
```

**values-prod.yaml**:
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

orchestration:
  replicas: 3
  hpa:
    minReplicas: 3
    maxReplicas: 20

ingress:
  host: openan.example.com
  tls:
    enabled: true
```

部署：
```bash
# 开发环境
helm install openan-dev ./k8s/openan-chart \
  -n openan-dev --create-namespace \
  -f values-dev.yaml

# 生产环境
helm install openan-prod ./k8s/openan-chart \
  -n openan-prod --create-namespace \
  -f values-prod.yaml
```

#### 6. 升级和回滚

```bash
# 升级
helm upgrade openan ./k8s/openan-chart -n openan -f values-custom.yaml

# 查看历史
helm history openan -n openan

# 回滚
helm rollback openan 1 -n openan
```

#### 7. 验证部署

```bash
# 查看状态
helm status openan -n openan

# 查看资源
kubectl -n openan get all

# 查看日志
kubectl -n openan logs -l app=orchestration-center -f
```

#### 8. 卸载

```bash
helm uninstall openan -n openan
```

---

## 配置参考

### 纯 YAML 关键配置

| 文件 | 配置项 | 说明 |
|------|--------|------|
| `secret.yaml` | `db-password` | 数据库密码 (base64) |
| `secret.yaml` | `llm-api-key` | LLM API Key (base64) |
| `configmap.yaml` | `AGENT_REGISTRY_URL` | Registry Center 地址 |
| `configmap.yaml` | `LLM_CHAT_URL` | LLM API 地址 |
| `configmap.yaml` | `DB_HOST` | 数据库地址 |
| `ingress.yaml` | `host` | Ingress 域名 |

### Helm Chart 关键配置

| 配置路径 | 默认值 | 说明 |
|----------|--------|------|
| `namespace` | `openan` | 命名空间 |
| `postgresql.enabled` | `true` | 是否部署内置 PostgreSQL |
| `postgresql.password` | - | 数据库密码 |
| `postgresql.storage` | `20Gi` | 存储大小 |
| `registry.enabled` | `true` | 是否部署 Registry Center |
| `registry.replicas` | `2` | 副本数 |
| `registry.llm.chat.apiKey` | - | Chat 模型 API Key |
| `registry.port` | `5000` | 服务端口 |
| `registry.tls.mode` | `auto` | TLS 证书模式：auto/secret |
| `registry.tls.existingSecret` | - | TLS 证书 Secret 名称 |
| `registry.signing.mode` | `auto` | JWS 签名证书模式：auto/secret |
| `registry.signing.existingSecret` | - | JWS 签名证书 Secret 名称 |
| `orchestration.enabled` | `true` | 是否部署 Orchestration Center |
| `orchestration.replicas` | `2` | 副本数 |
| `orchestration.llm.chat.apiKey` | - | Chat 模型 API Key |
| `orchestration.a2at.apiKey` | - | A2AT SDK API Key |
| `orchestration.port` | `5001` | 服务端口 |
| `ingress.enabled` | `true` | 是否创建 Ingress |
| `ingress.host` | `openan.example.com` | Ingress 域名 |

### 证书配置

Registry Center 需要两类证书：

| 证书类型 | 用途 | 路径 | 说明 |
|----------|------|------|------|
| TLS 证书 | HTTPS 通信 | `etc/ssl/` | server.cer, server_key.pem, trust.cer |
| JWS 签名证书 | Agent Card 签名 | `etc/sign_cert/` | server.cer, server_key.pem, cert_pwd |

**证书模式：**

| 模式 | 说明 | 多副本 | 适用场景 |
|------|------|--------|----------|
| `auto` (默认) | Helm 用 `genCA`/`genSignedCert` 自动生成，存入 Secret | 一致 | 推荐，所有场景 |
| `secret` | 从用户预创建的 K8S Secret 挂载 | 一致 | 需要正式证书 |
| `off` | entrypoint 每次启动自动生成，不持久化 | 不一致 | 仅开发调试 |

**`auto` 模式工作原理：**

1. `helm install` 时，Helm 模板调用 `genCA` + `genSignedCert` 生成自签名证书
2. 证书数据写入 K8S Secret (`registry-center-tls` / `registry-center-signing`)
3. Deployment 将 Secret 挂载到 `etc/ssl` 和 `etc/sign_cert`
4. entrypoint 检测到证书文件已存在，跳过自动生成
5. `helm upgrade` 时，通过 `lookup` 检测已有 Secret，**保留原证书不重新生成**

**无需任何手动操作，开箱即用。**

**使用正式证书 (secret 模式)：**

```bash
# 创建 TLS 证书 Secret
kubectl -n openan create secret generic registry-center-tls-custom \
  --from-file=server.cer=./server.crt \
  --from-file=server_key.pem=./server.key \
  --from-file=trust.cer=./ca.crt \
  --from-file=cert_pwd=./cert_pwd.txt

# 创建 JWS 签名证书 Secret
kubectl -n openan create secret generic registry-center-signing-custom \
  --from-file=server.cer=./sign_cert/server.cer \
  --from-file=server_key.pem=./sign_cert/server_key.pem \
  --from-file=cert_pwd=./sign_cert/cert_pwd.txt
```

```yaml
# values.yaml
registry:
  tls:
    mode: secret
    existingSecret: registry-center-tls-custom
  signing:
    mode: secret
    existingSecret: registry-center-signing-custom
```

---

## 故障排查

### Pod 无法启动

```bash
# 查看 Pod 事件
kubectl -n openan describe pod <pod-name>

# 查看日志
kubectl -n openan logs <pod-name>

# 检查 Secret
kubectl -n openan get secret
kubectl -n openan get secret registry-center-secret -o yaml
```

### 数据库连接失败

```bash
# 检查 PostgreSQL Pod
kubectl -n openan get pods -l app=openan-postgres

# 测试数据库连接
kubectl -n openan exec -it <postgres-pod> -- psql -U postgres -c "\l"
```

### Ingress 无法访问

```bash
# 检查 Ingress 资源
kubectl -n openan get ingress

# 检查 Ingress Controller 日志
kubectl -n ingress-nginx logs -l app.kubernetes.io/component=controller
```

---

## 安全建议

1. **证书管理**：默认 `auto` 模式自动生成自签名证书，生产环境建议使用 `secret` 模式配合正式 CA 证书
2. **使用外部 Secret 管理**：生产环境建议使用 Vault、AWS Secrets Manager 等管理敏感信息
3. **启用 TLS**：配置 Ingress TLS 或使用 cert-manager 自动签发证书
4. **网络策略**：使用 NetworkPolicy 限制 Pod 间通信
5. **镜像安全**：使用私有镜像仓库，启用镜像签名验证
6. **资源限制**：设置合理的 requests/limits 防止资源滥用
