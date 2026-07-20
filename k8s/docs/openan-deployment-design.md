# 1、特性描述

OpenAN 平台（Registry Center + Orchestration Center）Kubernetes 集群 Helm Chart 部署方案。

## 1.1、依赖组件

| 组件 | 组件描述 | 可获得性 |
|:-----|:---------|:---------|
| Kubernetes | 容器编排平台，版本 1.24+ | 开源 |
| PostgreSQL | 关系型数据库，版本 15 | 开源 |
| Nginx Ingress Controller | Ingress 控制器，支持 TLS 终止 | 开源 |
| Helm | Kubernetes 包管理器，版本 3.x | 开源 |
| LLM API | 大语言模型服务（DeepSeek/OpenAI 等） | 商业服务 |

## 1.2、License

Apache License 2.0

# 2、需求场景威胁建模

## 2.1、威胁场景分析

| 威胁场景 | 影响 | 缓解措施 |
|:---------|:-----|:---------|
| LLM API Key 泄露 | 未授权访问 LLM 服务，产生费用 | 使用 K8S Secret 存储，支持外部 Secret 管理 |
| 数据库密码泄露 | 数据被未授权访问或篡改 | Secret 加密存储，支持 Vault 集成 |
| 证书私钥泄露 | 中间人攻击，数据被窃听 | Secret 权限控制，支持 cert-manager 自动轮换 |
| Pod 间未授权访问 | 服务被横向移动攻击 | NetworkPolicy 限制 Pod 间通信 |
| 镜像供应链攻击 | 恶意代码注入 | 私有镜像仓库，镜像签名验证 |

## 2.2、信任边界

```
┌─────────────────────────────────────────────────────────────────────┐
│                    外部网络 (不可信)                                 │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Ingress Controller (DMZ)                         │
│                    - TLS 终止                                       │
│                    - 请求过滤                                       │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    openan Namespace (可信)                          │
│                    ┌──────────────────────────────────────────┐    │
│                    │  registry-center / orchestration-center  │    │
│                    │  - mTLS (可选)                           │    │
│                    │  - ServiceAccount 隔离                   │    │
│                    └──────────────────────────────────────────┘    │
│                              │                                      │
│                              ▼                                      │
│                    ┌──────────────────────────────────────────┐    │
│                    │  openan-postgres (数据层)                │    │
│                    │  - 仅 Pod 可访问                         │    │
│                    └──────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

# 3、特性设计

## 3.1、上下文/USE-CASE视图

### 3.1.1、平台架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                         OpenAN Platform                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌─────────────────────┐                                           │
│   │ Workflow Designer   │                                           │
│   │ (Frontend)          │                                           │
│   │  - React + Vite     │                                           │
│   │  - Nginx 反向代理   │                                           │
│   └─────────┬───────────┘                                           │
│             │ /rest/v1/orchestrate/*                                │
│             ▼                                                       │
│   ┌─────────────────────┐         ┌─────────────────────────────┐  │
│   │ Orchestration       │         │ Registry Center             │  │
│   │ Center              │────────▶│                             │  │
│   │                     │  HTTP   │  - Agent 注册/发现          │  │
│   │  - 工作流编排       │  :5000  │  - 语义搜索                 │  │
│   │  - PSOP 生成        │         │  - LLM (chat/embed/rerank)  │  │
│   │  - LLM (chat)       │         │                             │  │
│   │  - A2AT SDK         │         │                             │  │
│   └─────────┬───────────┘         └──────────────┬──────────────┘  │
│             │                                     │                 │
│             └──────────────┬──────────────────────┘                 │
│                            │                                        │
│                            ▼                                        │
│             ┌──────────────────────────────┐                       │
│             │ PostgreSQL (共享实例)         │                       │
│             │                              │                       │
│             │  - registry_center DB        │                       │
│             │  - orchestration_center DB   │                       │
│             └──────────────────────────────┘                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.1.2、组件对比

| 特性 | Registry Center | Orchestration Center | Workflow Designer |
|:-----|:----------------|:---------------------|:------------------|
| 端口 | 5000 | 5001 | 80 (Nginx) |
| 数据库 | registry_center | orchestration_center | 无 |
| LLM 用途 | 语义搜索、Embedding、Rerank | PSOP 生成、工作流执行、协商 | 无 |
| LLM 模型 | chat + embed + rerank | chat + a2at | 无 |
| 依赖 | 独立 | 依赖 Registry Center | 依赖 Orchestration Center |
| 可选性 | 必选 | 可选 | 可选 |
| 资源限制 | 512Mi/500m | 1Gi/1000m | 256Mi/500m |

### 3.1.3、部署流程图

```
用户
 │
 ├── helm install openan-chart
 │
 ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                               │
│                                                                     │
│  1. Namespace 创建 (openan)                                        │
│                                                                     │
│  2. Secret/ConfigMap 创建                                          │
│     ├── DB 密码                                                    │
│     ├── LLM API Keys                                               │
│     └── 证书 (auto 模式: genCA + genSignedCert)                    │
│                                                                     │
│  3. PostgreSQL StatefulSet 启动                                    │
│     ├── 等待就绪                                                   │
│     └── 初始化数据库 (create-databases.sh)                         │
│                                                                     │
│  4. Registry Center Deployment 启动                                │
│     ├── 挂载证书 Secret                                            │
│     └── 等待就绪                                                   │
│                                                                     │
│  5. Orchestration Center Deployment 启动                           │
│     ├── 发现 Registry Center (http://registry-center:5000)         │
│     └── 等待就绪                                                   │
│                                                                     │
│  6. Service/Ingress/HPA 创建                                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## 3.2、模块设计

### 3.2.1、Helm Chart 部署模块

#### 文件结构

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
    │   ├── tls-secret.yaml              # TLS 证书 (auto 模式)
    │   ├── signing-secret.yaml          # JWS 签名证书 (auto 模式)
    │   ├── secret.yaml                  # registry 独立 secret
    │   ├── configmap.yaml               # registry 配置
    │   ├── deployment.yaml
    │   └── service.yaml                 # port 5000
    ├── orchestration-center/
    │   ├── secret.yaml                  # orchestration 独立 secret
    │   ├── configmap.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml                 # port 5001
    │   └── hpa.yaml
    └── workflow-designer/
        ├── deployment.yaml              # 前端 Deployment
        ├── service.yaml                 # 前端 Service
        └── hpa.yaml                     # 前端 HPA
```

#### 核心设计

##### 可选组件

```yaml
# values.yaml
registry:
  enabled: true      # 必选，默认开启

orchestration:
  enabled: true      # 可选，可设为 false
```

模板中使用条件渲染：

```yaml
{{- if .Values.orchestration.enabled }}
apiVersion: apps/v1
kind: Deployment
...
{{- end }}
```

##### 独立 LLM 配置

两个服务各有独立的 LLM 配置，互不影响：

```yaml
# Registry Center LLM
registry:
  llm:
    chat:
      model: "deepseek-chat"
      url: "https://api.deepseek.com/v1/chat/completions"
      apiKey: ""
    embed:
      model: "bge-m3"
      url: ""
      apiKey: ""
    rerank:
      model: "bge-reranker-v2-m3"
      url: ""
      apiKey: ""

# Orchestration Center LLM
orchestration:
  llm:
    chat:
      model: "deepseek-chat"
      url: "https://api.deepseek.com/v1/chat/completions"
      apiKey: ""
  a2at:
    provider: "deepseek"
    model: "deepseek-chat"
    baseUrl: "https://api.deepseek.com"
    apiKey: ""
```

##### 共享 PostgreSQL

单个 PostgreSQL 实例，通过 init script 创建多个数据库：

```yaml
postgresql:
  enabled: true
  databases:
    - name: registry_center
      user: registry
    - name: orchestration_center
      user: opena2a_t
```

init script (`create-databases.sh`):
```bash
CREATE USER registry WITH PASSWORD '...';
CREATE DATABASE registry_center OWNER registry;
...
```

##### 服务发现

Orchestration Center 自动发现 Registry Center：

```yaml
# _helpers.tpl
{{- define "openan.registryUrl" -}}
{{- if .Values.orchestration.agentRegistryUrl }}
{{- .Values.orchestration.agentRegistryUrl }}
{{- else if .Values.registry.enabled }}
{{- printf "http://registry-center:%v" .Values.registry.port }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}
```

##### Ingress 路由

统一入口，按路径分发：

```yaml
# ingress.yaml
rules:
- host: {{ .Values.ingress.host }}
  http:
    paths:
    {{- if .Values.frontend.enabled }}
    - path: /
      backend:
        service:
          name: workflow-designer
          port:
            number: {{ .Values.frontend.port }}
    {{- end }}
    {{- if .Values.registry.enabled }}
    - path: /registry
      backend:
        service:
          name: registry-center
          port:
            number: {{ .Values.registry.port }}
    {{- end }}
```

前端 workflow-designer 的 Nginx 配置内部反向代理：
- `/rest/v1/orchestrate/*` → `http://orchestration-center:5001`
- 其他路径 → 静态文件服务

### 3.2.2、证书管理模块

#### 证书类型

| 证书类型 | 用途 | 容器路径 | 文件名 |
|:---------|:-----|:---------|:-------|
| TLS 证书 | HTTPS 通信 | `etc/ssl/` | server.cer, server_key.pem, trust.cer, cert_pwd |
| JWS 签名证书 | Agent Card 签名 | `etc/sign_cert/` | server.cer, server_key.pem, cert_pwd |

#### 证书模式

| 模式 | 说明 | 多副本 | 适用场景 |
|:-----|:-----|:-------|:---------|
| `auto` (默认) | Helm 用 `genCA`/`genSignedCert` 自动生成，存入 Secret | 一致 | 推荐，所有场景 |
| `secret` | 从用户预创建的 K8S Secret 挂载 | 一致 | 需要正式证书 |
| `off` | entrypoint 每次启动自动生成，不持久化 | 不一致 | 仅开发调试 |

#### auto 模式流程

```
helm install / helm upgrade
    │
    ▼
tls-secret.yaml / signing-secret.yaml 模板渲染
    │
    ├── lookup("v1", "Secret", ns, "registry-center-tls")
    │       │
    │       ├── 存在 → 复用已有证书数据 (b64enc 直接复制)
    │       │
    │       └── 不存在 → genCA("OpenAN CA", 3650)
    │                      genSignedCert("registry-center", ..., 3650, $ca)
    │                      写入新 Secret
    │
    ▼
Secret 创建/更新
    │
    ▼
Deployment 挂载 Secret
    │
    ├── registry-center-tls    → /opt/registry-center/etc/ssl
    └── registry-center-signing → /opt/registry-center/etc/sign_cert
    │
    ▼
entrypoint 检测
    │
    ├── 证书文件已存在 → 跳过生成，直接使用
    └── 证书文件不存在 → 自动生成 (mode=off 时)
```

#### Helm 模板关键代码

```yaml
# tls-secret.yaml
{{- $existingTls := lookup "v1" "Secret" .Values.namespace "registry-center-tls" -}}
{{- if $existingTls }}
# 复用已有证书
data:
  server.cer: {{ index $existingTls.data "server.cer" }}
  ...
{{- else }}
# 首次安装，生成新证书
{{- $ca := genCA "OpenAN CA" 3650 -}}
{{- $tlsCert := genSignedCert "registry-center" nil (list "registry-center" ...) 3650 $ca -}}
data:
  server.cer: {{ $tlsCert.Cert | b64enc }}
  ...
{{- end }}
```

#### Deployment 挂载逻辑

```yaml
{{- if ne .Values.registry.tls.mode "off" }}
volumeMounts:
- name: tls-certs
  mountPath: /opt/registry-center/etc/ssl
  readOnly: true
{{- end }}

volumes:
- name: tls-certs
  secret:
    {{- if eq .Values.registry.tls.mode "auto" }}
    secretName: registry-center-tls        # Helm 自动生成
    {{- else }}
    secretName: {{ .Values.registry.tls.existingSecret }}  # 用户提供
    {{- end }}
```

### 3.2.3、单机 Docker Compose 部署模块

#### 设计理念

- **零依赖**：无需 Kubernetes 集群，仅需 Docker + Docker Compose
- **一键部署**：`deploy.sh` 脚本自动完成环境检查、构建、启动、健康检查
- **完全复用镜像**：与 Helm Chart 使用相同的 Dockerfile 构建镜像

#### 文件结构

```
k8s/deploy-standalone/
├── docker-compose.yml          # 统一编排：postgres + registry + orchestration
├── init-db.sh                  # PostgreSQL 多数据库初始化脚本
├── .env.example                # 环境变量模板
└── deploy.sh                   # 一键部署脚本
```

#### 核心设计

##### 共享 PostgreSQL

与 Helm Chart 方案一致，单实例多数据库：

```yaml
# docker-compose.yml
postgres:
  image: postgres:15-alpine
  volumes:
    - pgdata:/var/lib/postgresql/data
    - ./init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro
```

`init-db.sh` 自动创建 `registry_center` 和 `orchestration_center` 两个数据库。

##### 服务依赖与健康检查

```yaml
orchestration-center:
  depends_on:
    postgres:
      condition: service_healthy    # 等待 PG 就绪
    registry-center:
      condition: service_started    # Registry 启动即可
```

##### 服务发现

Orchestration Center 通过 Docker 内部网络发现 Registry Center：

```yaml
environment:
  AGENT_REGISTRY_URL: http://registry-center:5000
```

##### 环境变量配置

通过 `.env` 文件统一管理，支持 LLM API Key 等敏感配置：

```bash
# .env
DB_PASSWORD=openan123
LLM_CHAT_MODEL=deepseek-chat
LLM_CHAT_URL=https://api.deepseek.com/v1/chat/completions
REGISTRY_LLM_API_KEY=sk-xxx
ORCHESTRATION_LLM_API_KEY=sk-yyy
```

#### 部署流程

```
deploy.sh
    │
    ├── 1. 检查 Docker / Docker Compose
    │
    ├── 2. 首次运行：复制 .env.example → .env
    │       └── 提示用户编辑 LLM API Key
    │
    ├── 3. 检查源码目录
    │       ├── REGISTRY_SRC (默认 ../../registry-center)
    │       └── ORCHESTRATION_SRC (默认 ..)
    │
    ├── 4. docker compose build (构建镜像)
    │
    ├── 5. docker compose up -d (启动服务)
    │
    ├── 6. 等待健康检查
    │       ├── PostgreSQL: pg_isready
    │       ├── Registry Center: /rest/v1/registry-center/agent-cards
    │       └── Orchestration Center: /rest/v1/orchestrate/agent-cards
    │
    └── 7. 输出访问地址
            ├── Registry Center:     http://localhost:5000
            └── Orchestration Center: http://localhost:5001
```

#### 与 Helm Chart 对比

| 维度 | Helm Chart | Docker Compose |
|:-----|:-----------|:---------------|
| 适用场景 | 生产/多节点 | 开发/单机/演示 |
| 依赖 | K8S + Helm | Docker + Docker Compose |
| 多副本 | 支持 | 不支持 |
| 自动伸缩 | HPA | 无 |
| 证书管理 | auto/secret/off | entrypoint 自动生成 |
| 负载均衡 | Ingress | 无 |
| 持久化 | PVC | Docker Volume |
| 镜像 | 同一 Dockerfile | 同一 Dockerfile |

### 3.2.4、镜像管理

#### 镜像构建流程

OpenAN 平台包含三个组件，每个组件都有独立的 Dockerfile：

| 组件 | Dockerfile 位置 | 默认镜像名 |
|------|----------------|-----------|
| Registry Center | `registry-center/Dockerfile` | `registry-center:latest` |
| Orchestration Center | `orchestration-center/Dockerfile` | `orchestration-center:latest` |
| Workflow Designer | `orchestration-center/workflow-designer/Dockerfile` | `workflow-designer:latest` |

#### 构建方式

**方式一：使用构建脚本（推荐）**

Helm Chart 仓库提供独立的构建脚本 `k8s/openan-chart/build/build.sh`，支持多种源码来源：

```bash
# 使用本地源码
./k8s/openan-chart/build/build.sh \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center

# 使用 Git 仓库
./k8s/openan-chart/build/build.sh \
  --registry-repo https://github.com/org/registry-center.git \
  --orchestration-repo https://github.com/org/orchestration-center.git

# 使用配置文件
cp k8s/openan-chart/build/build-config.yaml.example k8s/openan-chart/build/build-config.yaml
vim k8s/openan-chart/build/build-config.yaml
./k8s/openan-chart/build/build.sh --config k8s/openan-chart/build/build-config.yaml --push
```

注意：Workflow Designer 是 Orchestration Center 的子目录（`orchestration-center/workflow-designer`），构建脚本会自动处理，无需单独指定。

**方式二：手动构建**

```bash
# 构建 Registry Center
cd registry-center
docker build -t your-registry.com/openan/registry-center:v1.0.0 .
docker push your-registry.com/openan/registry-center:v1.0.0

# 构建 Orchestration Center
cd orchestration-center
docker build -t your-registry.com/openan/orchestration-center:v1.0.0 .
docker push your-registry.com/openan/orchestration-center:v1.0.0

# 构建 Workflow Designer
cd orchestration-center/workflow-designer
docker build -t your-registry.com/openan/workflow-designer:v1.0.0 .
docker push your-registry.com/openan/workflow-designer:v1.0.0
```

#### Helm Chart 镜像配置

构建完成后，通过 values.yaml 或命令行参数指定镜像地址：

```yaml
# values.yaml
registry:
  image:
    repository: your-registry.com/openan/registry-center
    tag: v1.0.0
    pullPolicy: IfNotPresent

orchestration:
  image:
    repository: your-registry.com/openan/orchestration-center
    tag: v1.0.0
    pullPolicy: IfNotPresent

frontend:
  image:
    repository: your-registry.com/openan/workflow-designer
    tag: v1.0.0
    pullPolicy: IfNotPresent
```

或使用命令行覆盖：

```bash
helm install openan ./k8s/openan-chart \
  --set registry.image.repository=your-registry.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=your-registry.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=your-registry.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0
```

#### 私有仓库认证

如果使用私有镜像仓库，需要创建 imagePullSecret：

```bash
# 创建 Secret
kubectl create secret docker-registry registry-secret \
  --docker-server=your-registry.com \
  --docker-username=admin \
  --docker-password=your-password \
  --namespace=openan
```

在 values.yaml 中配置：

```yaml
registry:
  imagePullSecrets:
    - name: registry-secret

orchestration:
  imagePullSecrets:
    - name: registry-secret

frontend:
  imagePullSecrets:
    - name: registry-secret
```

#### CI/CD 集成建议

**GitHub Actions 示例：**

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
      - uses: actions/checkout@v3
      
      - name: Login to Registry
        uses: docker/login-action@v2
        with:
          registry: ${{ secrets.REGISTRY_URL }}
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}
      
      - name: Build and Push Registry Center
        uses: docker/build-push-action@v4
        with:
          context: ../registry-center
          push: true
          tags: ${{ secrets.REGISTRY_URL }}/openan/registry-center:${{ github.ref_name }}
      
      - name: Build and Push Orchestration Center
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          tags: ${{ secrets.REGISTRY_URL }}/openan/orchestration-center:${{ github.ref_name }}
      
      - name: Build and Push Workflow Designer
        uses: docker/build-push-action@v4
        with:
          context: ./workflow-designer
          push: true
          tags: ${{ secrets.REGISTRY_URL }}/openan/workflow-designer:${{ github.ref_name }}
```

#### 本地开发环境

本地开发时，可以使用 `load` 方式将镜像导入 K3S/Minikube，无需推送到远程仓库：

```bash
# K3S
docker save your-registry.com/openan/registry-center:dev | k3s ctr images import -

# Minikube
minikube image load your-registry.com/openan/registry-center:dev

# Kind
kind load docker-image your-registry.com/openan/registry-center:dev
```

### 3.2.5、模块接口定义

#### 内部接口

| 接口 | 提供方 | 消费方 | 协议 | 说明 |
|:-----|:-------|:-------|:-----|:-----|
| `/rest/v1/registry-center/agent-cards` | registry-center | orchestration-center | HTTP | Agent Card 查询 |
| `/rest/v1/orchestrate/*` | orchestration-center | workflow-designer | HTTP | 工作流管理 API |
| `/rest/v1/orchestrate/agent-cards` | orchestration-center | 外部 | HTTP | 健康检查 |
| `/` | workflow-designer | 外部 | HTTP | 前端页面 |
| PostgreSQL :5432 | openan-postgres | registry-center, orchestration-center | TCP | 数据库连接 |

#### 外部接口

| 接口 | 提供方 | 消费方 | 协议 | 说明 |
|:-----|:-------|:-------|:-----|:-----|
| Ingress `/` | workflow-designer | 用户 | HTTPS | 前端页面入口 |
| Ingress `/registry` | registry-center | 用户 | HTTPS | 注册中心 API |
| LLM API | DeepSeek/OpenAI | registry-center, orchestration-center | HTTPS | 大模型服务 |

## 3.3、Story 分解

### 3.3.1、Story 列表

| Story | 描述 | 优先级 |
|:------|:-----|:-------|
| S1: Namespace 创建 | 创建 openan 命名空间 | P0 |
| S2: PostgreSQL 部署 | 部署共享 PostgreSQL 实例 | P0 |
| S3: Registry Center 部署 | 部署注册中心服务 | P0 |
| S4: Orchestration Center 部署 | 部署编排中心服务 | P0 |
| S5: Workflow Designer 部署 | 部署前端工作流设计器 | P0 |
| S6: 证书自动生成 | Helm 自动生成 TLS/JWS 证书 | P1 |
| S7: Ingress 配置 | 配置统一入口和路由 | P1 |
| S8: HPA 自动伸缩 | 配置自动伸缩策略 | P2 |

### 3.3.2、Story 设计

#### S1: Namespace 创建

**功能描述**：创建独立的 openan 命名空间，隔离资源

**验收标准**：
- Namespace 名称为 `openan`
- 包含标签 `app.kubernetes.io/part-of: openan`

**接口清单**：无

#### S2: PostgreSQL 部署

**功能描述**：部署共享 PostgreSQL 实例，自动创建多个数据库

**验收标准**：
- PostgreSQL 版本 15-alpine
- 自动创建 `registry_center` 和 `orchestration_center` 数据库
- 数据持久化到 PVC (默认 20Gi)
- 健康检查使用 `pg_isready`

**接口清单**：
- Service: `openan-postgres:5432`

#### S3: Registry Center 部署

**功能描述**：部署注册中心服务，支持多副本

**验收标准**：
- 默认 2 副本
- 端口 5000
- 挂载 TLS 和 JWS 证书
- 健康检查端点 `/rest/v1/registry-center/agent-cards`

**接口清单**：
- Service: `registry-center:5000`

#### S4: Orchestration Center 部署

**功能描述**：部署编排中心服务，支持多副本和自动伸缩

**验收标准**：
- 默认 2 副本
- 端口 5001
- 自动发现 Registry Center
- 健康检查端点 `/rest/v1/orchestrate/agent-cards`

**接口清单**：
- Service: `orchestration-center:5001`

#### S5: Workflow Designer 部署

**功能描述**：部署前端工作流设计器，提供可视化工作流编辑界面

**验收标准**：
- 默认 2 副本
- 端口 80 (Nginx)
- 静态文件服务 + API 反向代理
- 健康检查端点 `/`

**接口清单**：
- Service: `workflow-designer:80`
- 反向代理: `/rest/v1/orchestrate/*` → `orchestration-center:5001`

#### S6: 证书自动生成

**功能描述**：Helm 自动生成自签名证书，支持升级时保留

**验收标准**：
- 使用 `genCA` 和 `genSignedCert` 生成证书
- 证书存入 Secret
- `helm upgrade` 时通过 `lookup` 保留已有证书
- 多副本共享同一证书

**接口清单**：
- Secret: `registry-center-tls`
- Secret: `registry-center-signing`

#### S7: Ingress 配置

**功能描述**：配置 Nginx Ingress，统一入口

**验收标准**：
- 支持 TLS 终止
- 路径 `/` 路由到 workflow-designer
- 路径 `/registry` 路由到 registry-center
- 超时配置 300s

**接口清单**：
- Ingress: `openan-ingress`

#### S8: HPA 自动伸缩

**功能描述**：配置 Orchestration Center 和 Workflow Designer 自动伸缩

**验收标准**：
- 最小副本 2，最大副本 10
- CPU 阈值 70%
- Memory 阈值 80%

**接口清单**：
- HPA: `orchestration-center`
- HPA: `workflow-designer`

## 3.4、质量属性设计

### 3.4.1、性能规格

| 规格名称 | 规格指标 |
|:---------|:---------|
| 内存占用 | Registry: 512Mi, Orchestration: 1Gi |
| 启动时间 | < 60s (含数据库初始化) |
| 响应时间 | API < 500ms (不含 LLM 调用) |
| 并发能力 | 单实例 80 并发 (uvicorn workers) |

### 3.4.2、可靠性设计

| 设计点 | 实现方式 |
|:-------|:---------|
| 多副本 | Registry 2 副本，Orchestration 2-10 副本 |
| Pod 反亲和 | 优先调度到不同节点 |
| 优雅终止 | terminationGracePeriodSeconds: 120 |
| 健康检查 | startup/liveness/readiness 三探针 |
| 数据持久化 | PostgreSQL PVC 持久化 |
| 自动恢复 | Deployment 自动重启失败 Pod |

### 3.4.3、安全/韧性/隐私设计

| 设计点 | 实现方式 |
|:-------|:---------|
| Secret 管理 | K8S Secret，支持外部 Secret 引用 |
| 证书管理 | auto 模式自动生成，secret 模式用户自定义 |
| 网络隔离 | ClusterIP Service，仅集群内部访问 |
| TLS 终止 | Ingress 支持 TLS |
| 只读挂载 | 证书 volumeMount readOnly: true |
| 资源限制 | 设置 requests/limits 防止资源滥用 |

### 3.4.4、兼容性设计

| 设计点 | 实现方式 |
|:-------|:---------|
| Kubernetes 版本 | 支持 1.24+ |
| 数据库 | 支持内置 PostgreSQL 和外部数据库 |
| 证书模式 | auto/secret/off 三种模式 |
| Helm 版本 | 支持 Helm 3.x |

### 3.4.5、可服务性设计

| 设计点 | 实现方式 |
|:-------|:---------|
| 日志 | 标准输出，可通过 kubectl logs 查看 |
| 监控 | 健康检查端点，可接入 Prometheus |
| 升级 | Helm upgrade 支持滚动升级 |
| 回滚 | Helm rollback 支持快速回滚 |
| 配置更新 | ConfigMap/Secret 更新后重启 Pod 生效 |

### 3.4.6、可测试性设计

| 设计点 | 实现方式 |
|:-------|:---------|
| 开发环境 | 单副本，禁用 HPA，小存储 |
| 健康检查 | 轻量级 API 端点 |
| 可选组件 | orchestration.enabled=false 可跳过 |
| 外部数据库 | postgresql.enabled=false 可跳过内置 PG |

# 4、需求分解分配表

| 序号 | 模块名称 | Story 名称 | Story 描述 |
|:-----|:---------|:-----------|:-----------|
| 1 | 基础设施 | S1: Namespace 创建 | 创建 openan 命名空间 |
| 2 | 基础设施 | S2: PostgreSQL 部署 | 部署共享 PostgreSQL 实例 |
| 3 | 应用服务 | S3: Registry Center 部署 | 部署注册中心服务 |
| 4 | 应用服务 | S4: Orchestration Center 部署 | 部署编排中心服务 |
| 5 | 应用服务 | S5: Workflow Designer 部署 | 部署前端工作流设计器 |
| 6 | 安全 | S6: 证书自动生成 | Helm 自动生成 TLS/JWS 证书 |
| 7 | 网络 | S7: Ingress 配置 | 配置统一入口和路由 |
| 8 | 弹性 | S8: HPA 自动伸缩 | 配置自动伸缩策略 |

# 5、修改日志

| 版本 | 发布说明 |
|:-----|:---------|
| 1.0 | 初始版本，支持纯 YAML 和 Helm Chart 两种部署方式 |
| 1.1 | 增加证书自动生成模块，支持 auto/secret/off 三种模式 |
| 1.2 | 按 Feature-Design 模板重构文档 |
| 1.3 | 移除纯 YAML 部署方式，仅保留 Helm Chart |
| 1.4 | 增加单机 Docker Compose 部署模块，支持一键式容器化部署 |
| 1.5 | 增加 Workflow Designer 前端部署支持，完善 Ingress 路由配置 |

# 6、参考目录

1. [Kubernetes 官方文档](https://kubernetes.io/docs/)
2. [Helm 官方文档](https://helm.sh/docs/)
3. [OpenAN Helm Chart 部署指南](./k8s-deployment-guide.md)
4. [Registry Center 设计文档](../registry-center/docs/)
5. [Orchestration Center 设计文档](./DESIGN.md)
