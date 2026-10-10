# OpenAN 容器部署快速开始

本次 Chart 已支持独立 HTTP/HTTPS、外部 MySQL/PostgreSQL、应用认证与签名。升级前先阅读 [部署契约](../TRANSPORT_DEPLOYMENT.md)，必须构建包含服务端配套修改的新镜像，不能继续沿用旧 v1.0.0 镜像。

1. 提前准备 Kubernetes、Helm、Ingress；创建数据库和运行凭据/模型/证书 Secret。
2. 复制部署契约中的 values 示例，修改镜像版本、数据库连接、模型配置和 Secret 名称。不要把真实密码写入版本库或 Helm --set 命令。
3. 执行 `helm lint openan-chart -f deployment.yaml`、`helm template openan openan-chart -f deployment.yaml`。
4. 执行 `bash install.sh --values deployment.yaml`。
5. 检查 Pod、探针和日志；再通过真实入口验收登录、卡片/工作流操作、签名与 SSE。

HTTP 仍需要认证；HTTPS 关闭客户端证书校验也仍需要认证。TLS、签名和数据库是各自独立的配置职责。默认 values 刻意不提供可用秘密，未配置不会自动生成演示账户。

脚本现在只负责部署/升级，不安装集群/Helm/LoadBalancer，不把 samples Agent 启动在业务镜像中。相关基础设施请使用运维标准流程管理。

本地回归：安装 pytest/PyYAML/Helm/Bash 后在仓库根目录执行 `python -m pytest tests/ -q`。没有 Helm/Bash 会明确跳过对应测试；这不是容器或集群验收。
