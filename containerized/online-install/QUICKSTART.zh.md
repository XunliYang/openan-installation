# OpenAN 容器部署快速开始

English: [Quickstart](QUICKSTART.md).

本次 Chart 已支持独立 HTTP/HTTPS、外部 MySQL/PostgreSQL、应用认证与签名。升级前先阅读 [部署契约](../TRANSPORT_DEPLOYMENT.md)，必须构建包含服务端配套修改的新镜像，不能继续沿用旧 v1.0.0 镜像。

1. 提前准备 Kubernetes、Helm、Ingress；创建数据库和运行凭据/模型/证书 Secret。
2. 复制部署契约中的 values 示例，修改镜像版本、数据库连接、模型配置和 Secret 名称。不要把真实密码写入版本库或 Helm --set 命令。
3. 执行 `helm lint openan-chart -f deployment.yaml`、`helm template openan openan-chart -f deployment.yaml`。
4. 使用原生 Helm（namespace 与 values 一致）：`helm upgrade --install openan openan-chart --namespace openan --create-namespace -f deployment.yaml --wait --timeout 10m`。也可执行 `bash one_click_install.sh --skip-build --skip-infra --values deployment.yaml`。
5. 检查 Pod、探针和日志；再通过真实入口验收登录、卡片/工作流操作、签名与 SSE。

HTTP 仍需要认证；HTTPS 关闭客户端证书校验也仍需要认证。TLS、签名和数据库是各自独立的配置职责。默认 values 刻意不提供可用秘密，未配置不会自动生成演示账户。

**破坏性变更**：旧 install.sh 已替换为 one_click_install.sh。支持 --skip-build、--skip-infra、--values 与 --release/--namespace。构建阶段须提供明确来源 URL 与 tag；基础设施阶段须提供运维审核的本地 MetalLB/Ingress Chart 包与 values，不自动下载浮动版本或猜测 IP 池。

不带 --values 时，向导交互收集外部 SQL 与 HTTP 调测配置。秘密静默输入后仅经 stdin 写入 Kubernetes Secret，生成的 deployment.generated.json 只有非秘密连接信息及引用；不会覆盖现有文件或 Secret。须预建模型 ConfigMap 与签名 Secret。部分失败需显式核对已创建对象，再用 --values 升级。生产/保密流量使用审核后的 HTTPS values。完整参数见[英文快速开始](QUICKSTART.md)。

升级前停止业务写入，导出旧 Pod 的 data/log 并备份 SQL/PKI/Secret；恢复到独立 PVC 后再替换 Pod，不把挂空卷当成迁移。

本地回归：安装 pytest/PyYAML/Helm/Bash 后在仓库根目录执行 `python -m pytest tests/ -q`。没有 Helm/Bash 会明确跳过对应测试；这不是容器或集群验收。
