# OpenAN 容器在线部署快速开始

English: [Quickstart](QUICKSTART.md) · [完整部署契约](../TRANSPORT_DEPLOYMENT.md)

## 前置条件

- Linux 或 macOS，可访问互联网（应用镜像与固定版本的基础设施清单在线拉取）
- 可通过 `kubectl` 访问的 Kubernetes 集群（v1.25+）
- Helm 3.14+（3.14.2 已验证，chart 未使用更高版本特性）与 python3
- 集群内 SQL 与运行时 claim 需要 StorageClass——没有默认 StorageClass 时，可接受向导的本地 hostPath 回退（仅评估用途、单节点）
- 未经确认不安装任何主机工具：缺少 kubectl/helm（以及 Linux 上源码构建所需的 Docker）时，可在交互确认后用官方安装器自动安装；python3 与 Docker Desktop 需手动安装
- 交互式向导从终端读取密钥（getpass），需在真实 TTY 中运行 `./install.sh`；CI/自动化请使用 `./install.sh --values` 并预先创建 Secret

## 第 1 步：交互式安装

```bash
cd containerized/online-install
./install.sh
```

安装器按四个阶段编排（`./install.sh --help` 查看简要流程）。release 与命名空间默认为 `openan`、不再交互询问（可用 `--release`/`--namespace` 覆盖）；从源码构建改为参数驱动（`--tag` 加 `--registry-release` 与 `--orchestration-release`，先 `docker login` 目标仓库），不再是提问。

- **[1/4] 预检** —— 检查 kubectl、helm、python3，确认集群可达，打印 kubectl 客户端版本及所用的 release/命名空间；缺少 kubectl/helm 时可确认后自动安装（官方安装器，python3 仍需手动）。
- **[2/4] 基础设施** —— 同时检测到 MetalLB 与 ingress-nginx 时跳过；否则可安装固定版本的 MetalLB v0.16.1 与 ingress-nginx controller-v1.15.1 清单，随后在裸金属上提示输入 MetalLB IP 池（如 `192.168.1.200-192.168.1.250`，留空跳过）。
- **[3/4] 应用** —— 向导（configure.py）依次询问组件、应用镜像 tag（必填无默认值：旧 `v1.0.0` 镜像与当前 chart 不兼容；可共用一个，也可为 registry/orchestration/frontend 分别指定）、模型（按对话式 LLM 答案生成并做连通性探测，每个组件还可选填 **embed/rerank 模型**用于语义检索，orchestration 另可选填 **A2A-T SDK 协商模型** / 已有 ConfigMap）、签名（自动演示 / 已有 Secret）以及初始管理员密码（8+ 字符，含大小写/数字/特殊字符；选择部署 orchestration 时询问）。SQL、存储与 Ingress 主机名不再询问：评估模式固定使用集群内 PostgreSQL；存储自动选用集群默认 StorageClass，没有时自动回退为节点固定的本地 hostPath PV（单节点）；Ingress 固定空 host（catch-all），直接用 LB IP 访问（基于域名的路由与 HTTPS 请使用审核过的 values；Kubernetes 拒绝 IP 主机）。秘密仅经 kubectl stdin 写入 Kubernetes Secret；向导只生成非秘密的 `deployment.generated.json`，不覆盖已有文件或 Secret；失败时打印具体原因（不含秘密值）。若中途失败，请核对已创建的 Secret/ConfigMap，升级时改用 `--values` 继续。
- **[4/4] 部署** —— 先打印非秘密的部署汇总（release/命名空间、组件、镜像 tag、SQL、存储、模型、签名、Ingress host）并确认后，才执行 `helm upgrade --install --wait`；取消部署会保留生成的 values 与向导已创建的 Secret/ConfigMap（向导非事务性，可用 `--values` 复用重部署）。选择部署 orchestration 时，还会询问是否在 orchestration-center Pod 内启动 **Agent 示例服务**（演示用 agent）：通过 `kubectl exec` 运行 `samples/start_agents_server.py`，健康检查端口 8903，日志位于 `/tmp/agents-server.log`（回答 no 跳过；它仅为演示便利，不是 chart 资源，Pod 重启后不保留）。使用向导中配置的管理员账户登录。

## 第 2 步：验证部署

```bash
kubectl -n openan get pods,svc,ingress
```

- Pod：`registry-center-*`、`orchestration-center-*`、`openan-frontend-*`（集群内 SQL 另有 `openan-postgres-0`）应达到 `Running`。
- Service：`openan-frontend`（NodePort）、`registry-center`、`orchestration-center`、`openan-postgres`。
- Ingress：`openan-frontend-ingress`、`openan-orchestration-ingress`、`openan-registry-ingress`，`ADDRESS` 列显示负载均衡地址。

## 第 3 步：访问平台

优先使用负载均衡 IP：

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP
```

访问 `http://<EXTERNAL-IP>/`（向导固定使用空 host 的 catch-all Ingress，无需配置 DNS；基于域名的路由请使用审核过的 values）。没有负载均衡 IP 时，安装器打印 NodePort 回退地址：

```bash
NODE_PORT=$(kubectl -n openan get svc openan-frontend -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://${NODE_IP}:${NODE_PORT}/"
```

使用向导中配置的管理员账户登录，并在 Web 界面修改密码后再调用 API。

## HTTPS 部署

1. **先配置 MetalLB IP 池**：必须存在可路由的 IP 段（即第 [2/4] 阶段提供的同一 IPAddressPool），Ingress 才能获得稳定 IP；将 DNS 或 `/etc/hosts` 记录指向该 IP。
2. **生成证书**（证书工具由另一个 PR 提供）：

   ```bash
   python3 tool/gen_certs.py --host openan.example.com [--ip <LB-IP>]
   # 生成 ca.crt / tls.crt / tls.key
   ```

3. **创建证书 Secret**：

   ```bash
   python3 tool/gen_certs.py --host openan.example.com --install-secret openan-tls --namespace openan
   # 或：kubectl create secret tls openan-tls -n openan --cert=tls.crt --key=tls.key
   ```

4. **在 values 中启用**：`ingress.host: openan.example.com`、`ingress.tls.enabled: true`、`ingress.tls.secretName: openan-tls`。
5. **ingress-nginx 默认证书**（可选，服务于未匹配的 host）：在 `ingress-nginx` 命名空间创建 Secret，并为控制器设置参数 `--default-ssl-certificate=ingress-nginx/<secret>`：

   ```bash
   kubectl -n ingress-nginx create secret tls default-tls --cert=tls.crt --key=tls.key
   kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
       -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-ssl-certificate=ingress-nginx/default-tls"}]'
   ```

6. **集群内服务 TLS / mTLS**：参见[完整部署契约](../TRANSPORT_DEPLOYMENT.md)。

## 自动化 / 生产（原生 Helm）

按部署契约准备 Kubernetes、Helm、Ingress/存储、SQL 数据库以及模型/凭据/PKI 引用。
复制 [deployment.yaml.example](deployment.yaml.example)，填写全部镜像 tag 与非密钥字段：

```bash
helm lint openan-chart --namespace openan -f deployment.yaml
helm template openan openan-chart --namespace openan -f deployment.yaml > rendered.yaml
helm upgrade --install openan openan-chart --namespace openan --create-namespace -f deployment.yaml --wait --timeout 10m
```

namespace 必须与 values 一致。不要把密钥写入 values/--set；若刻意使用遗留内联字段，渲染输出可能包含密钥，须妥善保护。在真实公网入口验收 API，而非仅探测。

`install.sh --values` 是面向已准备环境与 CI 的非交互变体
（`--skip-build` / `--skip-infra` / `--values ...` / `--release` / `--namespace`）；其基础设施阶段要求运维审核的本地 MetalLB/ingress-nginx Chart 包与 values，而非在线固定版本清单。

## 验证与故障排查

安装 Python/PyYAML/pytest、Helm 与 Bash 后，执行 `python -m pytest tests/ -q`。
缺少工具会明确跳过相关测试；渲染通过不等于容器/集群验收。
CI 单独构建真实 Compose 矩阵。认证/TLS/SQL/PVC 与前端诊断见[验收与故障排查](../TRANSPORT_DEPLOYMENT.md#acceptance-and-troubleshooting)。单实例升级会短暂中断服务。

在残留的本地存储上重装会保留旧数据：`openan-postgres-pv` 中残留的旧 `pgdata` 会让集群内 SQL
沿用旧数据库密码（postgres socket 仍可连接，但 TCP 报 `password authentication failed`）。请在
`uninstall.sh` 中对 "Remove persistent data" 回答 yes——它会检测并清理所有 OpenAN PV 的 hostPath
数据——或手工删除节点上的 `/data/openan-*`。向导在配置存储前也会提示检测到的残留 PV。
