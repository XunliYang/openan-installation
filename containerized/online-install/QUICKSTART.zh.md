# OpenAN 容器在线部署快速开始

English: [Quickstart](QUICKSTART.md) · [完整部署契约](../TRANSPORT_DEPLOYMENT.md)

## 前置条件

- Linux 或 macOS，可访问互联网（应用镜像与固定版本的基础设施清单在线拉取）
- 可通过 `kubectl` 访问的 Kubernetes 集群（v1.25+）
- Helm 3.19+ 与 python3
- 不自动安装主机工具；安装器不会修改操作系统

## 第 1 步：交互式安装

```bash
cd containerized/online-install
./install.sh
```

安装器按六个阶段编排（`./install.sh --help` 查看简要流程）：

- **[1/6] 预检** —— 检查 kubectl、helm、python3，确认集群可达，并打印 kubectl 客户端版本。
- **[2/6] 目标** —— 询问 Helm release 名称与命名空间（默认均为 `openan`）。
- **[3/6] 镜像** —— 镜像 tag 必填且无默认值（旧 `v1.0.0` 镜像与当前 chart 不兼容，见部署契约）。从源码构建需要两个组织源码归档 URL（registry-center 与 orchestration-center，须为已验收版本）并会推送镜像——先 `docker login` 目标仓库；回答 no 则复用已推送的 tag。
- **[4/6] 基础设施** —— 同时检测到 MetalLB 与 ingress-nginx 时跳过；否则可安装固定版本的 MetalLB v0.16.1 与 ingress-nginx controller-v1.15.1 清单，随后在裸金属上提示输入 MetalLB IP 池（如 `192.168.1.200-192.168.1.250`，留空跳过）。
- **[5/6] 应用** —— 向导（configure.py）依次询问组件、SQL 托管（默认集群内 PostgreSQL 评估模式 / 外部 SQL）、模型（按对话式 LLM 答案生成并做连通性探测 / 已有 ConfigMap）、签名（自动演示 / 已有 Secret）以及初始管理员密码（12+ 字符，含大小写/数字/特殊字符；选择部署 orchestration 时询问）。秘密仅经 kubectl stdin 写入 Kubernetes Secret；向导只生成非秘密的 `deployment.generated.json`，不覆盖已有文件或 Secret。若中途失败，请核对待已创建的 Secret/ConfigMap，升级时改用 `--values` 继续。
- **[6/6] 部署** —— 用生成的 values 对 Chart 做 lint，执行 `helm upgrade --install --wait` 并打印访问 URL。使用向导中配置的管理员账户登录。

## 第 2 步：验证部署

```bash
kubectl -n openan get pods,svc,ingress
```

- Pod：`registry-center-*`、`orchestration-center-*`、`workflow-designer-*`（集群内 SQL 另有 `openan-postgres-0`）应达到 `Running`。
- Service：`workflow-designer`（NodePort）、`registry-center`、`orchestration-center`、`openan-postgres`。
- Ingress：`openan-frontend-ingress`、`openan-orchestration-ingress`、`openan-registry-ingress`，`ADDRESS` 列显示负载均衡地址。

## 第 3 步：访问平台

优先使用负载均衡 IP：

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP
```

访问 `http://<EXTERNAL-IP>/`（安装器同时打印向导中填写的主机名——把 DNS 或 `/etc/hosts` 记录指向该 IP）。没有负载均衡 IP 时，安装器打印 NodePort 回退地址：

```bash
NODE_PORT=$(kubectl -n openan get svc workflow-designer -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://${NODE_IP}:${NODE_PORT}/"
```

使用向导中配置的管理员账户登录，并在 Web 界面修改密码后再调用 API。

## HTTPS 部署

1. **先配置 MetalLB IP 池**：必须存在可路由的 IP 段（即第 [4/6] 阶段提供的同一 IPAddressPool），Ingress 才能获得稳定 IP；将 DNS 或 `/etc/hosts` 记录指向该 IP。
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
复制 [deployment.yaml.example](deployment.yaml.example)，填写全部镜像 tag 与非秘密字段：

```bash
helm lint openan-chart --namespace openan -f deployment.yaml
helm template openan openan-chart --namespace openan -f deployment.yaml > rendered.yaml
helm upgrade --install openan openan-chart --namespace openan --create-namespace -f deployment.yaml --wait --timeout 10m
```

namespace 必须与 values 一致。不要把秘密写入 values/--set；若刻意使用遗留内联字段，渲染输出可能包含秘密，须妥善保护。在真实公网入口验收 API，而非仅探测。

`one_click_install.sh` 仍是面向已准备环境的参数化变体
（`--skip-build` / `--skip-infra` / `--values ...` / `--release` / `--namespace`）；其基础设施阶段要求运维审核的本地 MetalLB/ingress-nginx Chart 包与 values，而非在线固定版本清单。

## 验证与故障排查

安装 Python/PyYAML/pytest、Helm 与 Bash 后，执行 `python -m pytest tests/ -q`。
缺少工具会明确跳过相关测试；渲染通过不等于容器/集群验收。
CI 单独构建真实 Compose 矩阵。认证/TLS/SQL/PVC 与前端诊断见[验收与故障排查](../TRANSPORT_DEPLOYMENT.md#acceptance-and-troubleshooting)。单实例升级会短暂中断服务。
