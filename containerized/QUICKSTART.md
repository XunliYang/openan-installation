# OpenAN Platform 快速体验

构建 + 部署一站式指南，从零到可访问的 OpenAN 平台。

## 整体流程

```
准备环境 → 构建镜像 → 部署到 K8S → 验证访问 → 清理
```

## 前置条件

| 工具 | 最低版本 | 用途 |
|------|---------|------|
| Docker | 20.10+ | 镜像构建 |
| Docker Buildx | 0.8+ | 多架构构建 |
| Kubernetes | 1.24+ | 运行平台 |
| kubectl | 1.24+ | K8S 命令行 |
| Helm | 3.x | 部署管理 |
| Ingress Controller (Nginx) | - | 外部访问（可选） |
| Git | - | 拉取源码 |

## Step 1: 准备源码

```bash
# 克隆组件源码（按需选择）
git clone https://github.com/openan/registry-center.git
git clone https://github.com/openan/orchestration-center.git
```

> Workflow Designer 位于 `orchestration-center/workflow-designer`，无需单独克隆。

## Step 2: 构建镜像

### 场景 A：单节点集群（镜像直接加载到本地 Docker）

```bash
cd containerized/build

# 构建全部组件（仅当前架构，不推送）
docker buildx build --platform linux/amd64 \
  -t registry-center:latest --load \
  ../../registry-center

docker buildx build --platform linux/amd64 \
  -t orchestration-center:latest --load \
  ../../orchestration-center

docker buildx build --platform linux/amd64 \
  -t workflow-designer:latest --load \
  ../../orchestration-center/workflow-designer
```

> 将 `linux/amd64` 替换为你的节点架构（如 `linux/arm64`）。

### 场景 B：私有镜像仓库（推荐多节点 / 生产环境）

```bash
cd containerized/build

# 使用构建脚本，指定私有仓库并推送
./build.sh \
  --registry harbor.example.com \
  --namespace openan \
  --tag v1.0.0 \
  --registry-src ../../registry-center \
  --orchestration-src ../../orchestration-center \
  --push
```

构建完成后镜像列表：

```
harbor.example.com/openan/registry-center:v1.0.0
harbor.example.com/openan/orchestration-center:v1.0.0
harbor.example.com/openan/workflow-designer:v1.0.0
```

### 场景 C：使用配置文件

```bash
cd containerized/build

cp build-config.yaml.example build-config.yaml
# 编辑 build-config.yaml，填写源码路径和仓库信息
vim build-config.yaml

./build.sh --config build-config.yaml
```

## Step 3: 部署到 Kubernetes

### 方式一：使用示例配置文件（推荐快速体验）

```bash
cd containerized

# 复制示例配置文件
cp values-prod.yaml.example values-custom.yaml

# 编辑配置文件，修改以下内容：
# 1. 镜像仓库地址（如使用私有仓库）
# 2. LLM API Key（替换为你自己的密钥）
# 3. Ingress host（替换为你的域名或 IP）
# 4. 数据库密码（修改默认密码）
vim values-custom.yaml

# 部署
helm install openan ./openan-chart \
  -n openan --create-namespace \
  -f values-custom.yaml
```

**示例配置说明：**

`values-prod.yaml.example` 已包含完整的生产环境配置：

- **镜像仓库**：默认使用 `leoyy6/registry-center`、`leoyy6/orchestration-center`、`leoyy6/workflow-designer`
- **LLM 模型**：
  - Registry Center: `glm-5.1`（Chat）、`bge-m3`（Embed）、`bge-reranker-v2-m3`（Rerank）
  - Orchestration Center: `qwen3.7-plus`（Chat 和 A2AT）
- **API 端点**：使用阿里云 DashScope（`dashscope.aliyuncs.com`）
- **Ingress**：默认域名 `openan.local`，NodePort `30191`
- **副本数**：各组件 2 副本，启用 HPA 自动伸缩

**快速修改示例：**

```bash
# 替换镜像仓库为你的私有仓库
sed -i 's|leoyy6/|harbor.example.com/openan/|g' values-custom.yaml

# 替换 LLM API Key
sed -i 's|sk-your-actual-api-key|sk-your-actual-api-key|g' values-custom.yaml

# 替换 Ingress 域名
sed -i 's|openan.local|openan.example.com|g' values-custom.yaml
```

### 方式二：命令行参数覆盖

```bash
cd containerized/openan-chart

helm install openan . \
  -n openan --create-namespace \
  --set registry.image.repository=harbor.example.com/openan/registry-center \
  --set registry.image.tag=v1.0.0 \
  --set orchestration.image.repository=harbor.example.com/openan/orchestration-center \
  --set orchestration.image.tag=v1.0.0 \
  --set frontend.image.repository=harbor.example.com/openan/workflow-designer \
  --set frontend.image.tag=v1.0.0 \
  --set registry.llm.chat.apiKey=sk-your-chat-key \
  --set registry.llm.embed.apiKey=sk-your-embed-key \
  --set registry.llm.rerank.apiKey=sk-your-rerank-key \
  --set orchestration.llm.chat.apiKey=sk-your-chat-key \
  --set orchestration.a2at.apiKey=sk-your-a2at-key \
  --set ingress.host=openan.example.com
```

### 方式三：单节点本地镜像

确保 K8S 节点能访问到本地 Docker 镜像。如果使用 `kind` / `minikube` / `k3s`，需按各自方式加载镜像。

```bash
cd containerized/openan-chart

helm install openan . \
  -n openan --create-namespace \
  --set registry.llm.chat.apiKey=sk-your-chat-key \
  --set registry.llm.embed.apiKey=sk-your-embed-key \
  --set registry.llm.rerank.apiKey=sk-your-rerank-key \
  --set orchestration.llm.chat.apiKey=sk-your-chat-key \
  --set orchestration.a2at.apiKey=sk-your-a2at-key
```

## 配置说明

`values-prod.yaml.example` 中的关键配置项：

### 必须修改的配置

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `registry.llm.chat.apiKey` | `sk-your-actual-api-key` | Registry Center Chat 模型 API Key |
| `orchestration.llm.chat.apiKey` | `sk-your-actual-api-key` | Orchestration Center Chat 模型 API Key |
| `orchestration.a2at.apiKey` | `sk-your-actual-api-key` | A2AT SDK API Key |
| `postgresql.password` | `openan-db-password` | 数据库密码（生产环境必须修改） |
| `ingress.host` | `openan.local` | Ingress 域名（替换为你的域名或 IP） |

### 可选修改的配置

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `registry.image.repository` | `leoyy6/registry-center` | 镜像仓库地址 |
| `orchestration.image.repository` | `leoyy6/orchestration-center` | 镜像仓库地址 |
| `frontend.image.repository` | `leoyy6/workflow-designer` | 镜像仓库地址 |
| `frontend.nodePort` | `30191` | 前端 NodePort 端口 |
| `registry.llm.chat.model` | `glm-5.1` | Chat 模型名称 |
| `orchestration.llm.chat.model` | `qwen3.7-plus` | Chat 模型名称 |
| `registry.replicas` | `2` | Registry Center 副本数 |
| `orchestration.replicas` | `2` | Orchestration Center 副本数 |

### LLM 模型配置

示例配置使用阿里云 DashScope 作为 LLM 提供商：

| 组件 | 模型 | 用途 |
|------|------|------|
| Registry Center | `glm-5.1` | Agent Card 语义搜索、智能匹配 |
| Registry Center | `bge-m3` | 向量嵌入 |
| Registry Center | `bge-reranker-v2-m3` | 结果重排序 |
| Orchestration Center | `qwen3.7-plus` | 工作流编排、PSOP 生成 |

如需使用其他 LLM 提供商（如 OpenAI、DeepSeek），需同时修改 `model`、`url` 和 `apiKey`：

```yaml
registry:
  llm:
    chat:
      model: "gpt-4"
      url: "https://api.openai.com/v1/chat/completions"
      apiKey: "sk-your-openai-key"
```

## Step 4: 验证部署

```bash
# 查看 Pod 状态（等待所有 Pod Running）
kubectl -n openan get pods

# 预期输出：
# NAME                                    READY   STATUS    RESTARTS   AGE
# openan-postgres-0                       1/1     Running   0          2m
# registry-center-xxx                     1/1     Running   0          2m
# registry-center-yyy                     1/1     Running   0          2m
# orchestration-center-xxx                1/1     Running   0          2m
# orchestration-center-yyy                1/1     Running   0          2m
# workflow-designer-xxx                   1/1     Running   0          2m
# workflow-designer-yyy                   1/1     Running   0          2m

# 查看服务
kubectl -n openan get svc

# 查看 Ingress
kubectl -n openan get ingress

# 查看日志
kubectl -n openan logs -l app=registry-center -f
kubectl -n openan logs -l app=orchestration-center -f
```

## Step 5: 访问平台

### 方式一：通过 Ingress（推荐）

配置 hosts（使用 `values-custom.yaml` 中配置的域名，默认 `openan.local`）：

```bash
# 获取 Ingress Controller IP
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# 添加到 /etc/hosts（Linux/Mac）或 C:\Windows\System32\drivers\etc\hosts（Windows）
<ingress-ip>  openan.local
```

访问：

| 服务 | 地址 |
|------|------|
| Workflow Designer（前端） | `http://openan.local/` |
| Registry API | `http://openan.local/registry/rest/v1/registry-center/agent-cards` |
| Orchestration API | `http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards` |

```bash
# 测试 Registry API
curl http://openan.local/registry/rest/v1/registry-center/agent-cards

# 测试 Orchestration API
curl http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards
```

### 方式二：通过 NodePort（无 Ingress 环境）

如果未配置 Ingress，可通过 NodePort 直接访问（默认端口 30191）：

```bash
# 获取节点 IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# 访问前端
echo "http://${NODE_IP}:30191/"

# 测试 Registry API（需要通过 Ingress 或端口转发，NodePort 仅暴露前端）
curl http://openan.local/registry/rest/v1/registry-center/agent-cards

# 测试 Orchestration API
curl http://openan.local/api/orchestrate/rest/v1/orchestrate/agent-cards

```

## Step 6: 更新

```bash
# 更新 Helm 发布
helm upgrade openan . -n openan -f values-custom.yaml
```

## Step 7: 清理

```bash
# 卸载 Helm 发布
helm uninstall openan -n openan

# 删除命名空间（会清理所有资源）
kubectl delete namespace openan

# 删除 PVC（可选，会清除数据库数据）
kubectl delete pvc -n openan --all
```

## 常见问题

### Q: Pod 一直处于 Pending 状态？

```bash
kubectl -n openan describe pod <pod-name>
# 常见原因：PVC 未绑定 → 检查 StorageClass
kubectl get sc
```

### Q: 镜像拉取失败？

```bash
# 检查镜像名称和标签是否正确
kubectl -n openan describe pod <pod-name> | grep -A5 Events

# 私有仓库需要配置 imagePullSecrets
kubectl -n openan create secret docker-registry harbor-cred \
  --docker-server=harbor.example.com \
  --docker-username=admin \
  --docker-password=your-password
```

### Q: 数据库连接失败？

```bash
# 检查 PostgreSQL Pod 状态
kubectl -n openan get pods -l app=openan-postgres

# 查看 PostgreSQL 日志
kubectl -n openan logs -l app=openan-postgres
```

### Q: 证书报错？

默认使用 `auto` 模式自动生成自签名证书，无需手动操作。如需排查：

```bash
kubectl -n openan get secret registry-center-tls
kubectl -n openan get secret registry-center-signing
kubectl -n openan exec <registry-pod> -- ls -la /opt/registry-center/etc/ssl
```

## 相关文档

- [Helm Chart 详细配置](./openan-chart/README.md)
- [镜像构建指南](./build/README.md)
- [K8S 部署指南](../k8s-deployment-guide.md)（含纯 YAML 部署方式）
