# HTTP/HTTPS 与数据库部署契约

English: [Deployment contract](TRANSPORT_DEPLOYMENT.md).

旧离线 Kubernetes 的构建与安装入口已在外部操作前拒绝执行，避免新镜像使用过期独立 Chart。恢复支持须复用并实际验收现行 Chart。二进制入口同样未验收，不能宣称支持。

本次范围为 `online-install` 在线 Chart、共享镜像构建脚本，以及新增整改的单机 `offline-install-compose`。`offline-install` 离线 Kubernetes 与二进制安装器未纳入本轮验证，不能假定它们已经具有相同契约。下文 Helm 字段针对在线 Chart；Compose 使用独立的 [部署指南](offline-install-compose/README.md) 和配置模板。

本版本 Chart 必须配合包含本次部署整改的 RC/OC 镜像。不能将旧 v1.0.0 镜像视作已包含新功能。先构建并明确指定镜像 tag，再部署；源码 Git ref 与镜像 tag 分开。

## 配置职责

- database.type 选择 postgresql/mysql；postgresql.enabled 只决定是否创建内置 PostgreSQL。MySQL 使用已有外部实例，不创建数据库容器。
- database.registry / database.orchestration 分别配置库名、用户和密码 Secret。两个服务不要共用业务库。
- 内置 PostgreSQL 当前用 postgresql.existingSecret 的 postgres-password 同时初始化业务用户；独立业务密码 Secret 仅用于外部数据库，不能配置成与初始化密码不同。生产推荐外部数据库和独立用户凭据。
- registry.tls / orchestration.tls 分别控制各自监听协议及客户端证书校验。
- 认证与 TLS 独立。RC 的 token 身份复用已有 static_bearer/oauth2_jwt/oauth2_introspection/custom provider；主端口实例与第三方接入端口实例不共用异步客户端。OC 公开接口使用与网页登录相同的账号：POST /api/v1/auth/token 获取 Token，业务请求显式携带账号 Bearer，Cookie 单独携带不授权公开 API。
- registry.signing 独立控制 AgentCard 标准 JWS 签名。off 是明确禁用，非“自动生成”。auto 仅用于演示；生产使用 secret。
- 模型定义通过完整 models.yaml ConfigMap 注入，秘密通过 runtimeSecret 或各能力 existingSecret 注入。自定义 provider/auth 字段请使用 modelsConfigMap，内置 llm 快捷配置仅用于 OpenAI-compatible。

`database.port` 仅作用于外部 SQL，null/省略时按类型选择 PostgreSQL 5432 或 MySQL 3306；内置 PostgreSQL 使用 `postgresql.port`。端口须为 1..65535 整数，两服务启用时拒绝同外部库名。`namespace` 必须与 Helm `--namespace` 一致；应用镜像 tag 必填，不再默认旧 v1.0.0。

默认模板不携带可用密码、机器 Token 或厂商密钥。缺失必要 Secret、HTTP+客户端证书校验等错误组合会明确拒绝渲染/启动。

## 现网：外部 MySQL + HTTPS + 不校验客户端证书

示例只包含 Secret 名称，没有真实敏感值：

```yaml
postgresql:
  enabled: false
database:
  type: mysql
  host: mysql.example.internal
  port: 3306
  registry:
    name: registry_center
    username: registry
    existingSecret: rc-db
    passwordKey: db-password
  orchestration:
    name: orchestration_center
    username: orchestration
    existingSecret: oc-db
    passwordKey: db-password
registry:
  runtimeSecret: rc-runtime
  credentialSecret: rc-credentials
  identityMode: token
  authMode: static_bearer
  signing:
    mode: secret
    existingSecret: rc-signing
  tls:
    enabled: true
    verifyClient: false
    mode: secret
    existingSecret: rc-tls
  ingressClientSecret: rc-ingress-trust
orchestration:
  runtimeSecret: oc-runtime
  registryClientSecret: oc-registry-trust
  clientVerifyServer: true
  tls:
    enabled: true
    verifyClient: false
    mode: secret
    existingSecret: oc-tls
  ingressClientSecret: oc-ingress-trust
frontend:
  backendTls:
    verifyServer: true
    existingSecret: frontend-trust
```

必须同时覆盖 registry/orchestration/frontend.image.tag 为本次镜像版本。省略的 llm 配置仍是占位符，需改为实际模型或指定已有 modelsConfigMap。

关闭对端校验有不同含义，不能混作一个开关：

- tls.verifyClient=false：服务端不要求调用方证书，应用 Token 鉴权仍有效。
- orchestration.clientVerifyServer=false：OC 不校验 RC 的服务端证书。
- frontend.backendTls.verifyServer=false：前端 nginx 不校验 OC 的服务端证书。
- ingress.backendVerifyServer=false：ingress-nginx 不校验后端证书。
- 关闭服务端校验并不会取消后端的客户端证书要求；启用 mTLS 时仍必须提供客户端证书。
- `orchestration.clientVerifyServer=false` 时 Chart 不注入 `REGISTRY_CA_FILE`，即使提供了含 CA 的 registryClientSecret；客户端证书和密钥仍按 RC 的 mTLS 要求独立注入。不能把“关闭校验 + 仍指定 CA”当成有效组合。

推荐保留服务端校验并挂载 CA。确需跳过时显式设置，不依赖隐藏默认值。

## Secret 文件与环境变量

| Secret | 内容 |
|---|---|
| rc-db / oc-db | db-password |
| rc-runtime | INTEGRATION_FINGERPRINT_KEY；静态模式还需 INTEGRATION_TOKEN_HMAC_KEY；OAuth2 模式按 RC 公共模板提供凭据和配置引用 |
| rc-credentials | integration_credentials.conf，保存 Token 的 HMAC-SHA256 摘要、identity、role，不能保存明文 Token |
| oc-runtime | OC_ADMIN_INITIAL_PASSWORD（SQL 初次启动）；REGISTRY_ACCESS_TOKEN（访问 RC）；模型密钥变量 |
| rc-tls / oc-tls | server.cer、server_key.pem、cert_pwd、trust.cer；mTLS 探针还需 probe-client.cer、probe-client.key |
| rc-signing | sign.cer、sign_key.pem、cert_pwd |
| oc-registry-trust | trust.cer；RC mTLS 时还需 client.cer、client_key.pem（加密客户端私钥通过 REGISTRY_CLIENT_KEY_PASSWORD 提供口令） |
| frontend-trust | trust.cer；OC mTLS 时还需 client.cer、client_key.pem（nginx 客户端私钥需可直接加载） |
| rc/oc-ingress-trust | ingress-nginx 格式 ca.crt；mTLS 还需 tls.crt、tls.key |

签名私钥可以是未加密 key + 空 cert_pwd，服务会归一为 None；TLS 私钥要求遵循服务现有证书校验契约（加密私钥、非空合规口令、足够强度）。两者不能混用规则。

静态 Token 凭据文件示例（token_hash 必须为以 INTEGRATION_TOKEN_HMAC_KEY 为密钥计算的 HMAC-SHA256 十六进制摘要）：

```properties
credential.oc.identity=orchestration
credential.oc.role=partner_service
credential.oc.token_hash=<64-character-HMAC-SHA256>
```

用于注册、更新和删除 AgentCard 的身份应配置 vendor_agent，所有者取验证后的 identity，不取归属说明 owner。nms_oss 可以进入管理接口，原有所有者校验仍保留。非管理身份在主端口仅开放公开发现与供应商自己的卡片写操作；订阅/审计等请使用已授权的 integration 操作。

## TLS 与公开地址

生产证书由企业 CA 提供。演示可用两个服务自己的 generate_selfsign_cert.py：serverAuth 生成 TLS bundle，dataSigning 生成签名 bundle，--issue-client 生成客户端身份。不要再使用 Helm 的空口令 TLS 自动生成逻辑。

SAN 应包含对应 Service DNS，以及探针使用的 127.0.0.1；或设置 REGISTRY_HEALTHCHECK_HOST / ORCH_HEALTHCHECK_HOST 为证书包含的专用探针 DNS 名（通常是对应服务名）。Chart 会把此 DNS 名通过 Pod hostAliases 解析到本 Pod 的 127.0.0.1，避免探针依赖尚未 Ready 的 Service 端点。该映射影响 Pod 内所有解析，不能复用远端模型、注册中心或 SQL 主机名；已知跨服务/SQL 冲突会被拒绝。后端监听 0.0.0.0 不是公开 JWKS 地址；可设置 registry.publicBaseUrl 为真正的 HTTPS 入口。HTTP 使用预置可信公钥，不降低远程 JWKS 的 HTTPS/SSRF 约束。

Kubernetes TLS/签名文件使用只读 subPath 挂载，UID/fsGroup=10001，文件 0440，镜像目录 0700。Secret 文件变化需滚动重启（subPath 不会热更新），签名轮换还需同步可信公钥。auto 签名升级使用 lookup 保留旧 key，并兼容旧 server.cer/server_key.pem 名称；不要用离线 template 生成的随机 Secret 覆盖已有线上签名材料。

Chart 自己生成的 models.yaml 和 nginx 配置带 Pod checksum，Helm 更新会触发滚动重启。外部 modelsConfigMap 内容更新不属于 Helm 输入，须由运维滚动重启；同样不能期待 subPath 文件热更新。

当前 RC 的 legacy use_vectordb=true 会切换成缺少权威 SQL 记录的向量专用模式，不能用于完整业务 API。本 Chart 明确拒绝 vectordb.enabled=true。SQL 主存储加派生向量索引的完整实现是后续独立需求，本轮不宣称已提供该能力。

## HTTP 模式

将两个 tls.enabled 改为 false，verifyClient=false；RC 保持 token 身份，OC 保留用户和机器凭据。无需 TLS Secret。签名与入站签名校验并不因 HTTP 自动关闭。HTTP 仅适用于受信内网/演示，凭据会在链路明文传输。

Cookie 的 Secure 以公共入口为准。前端/Ingress 公共 TLS 启用时自动采用 https；外部网关终止 TLS 时显式 orchestration.publicScheme=https。应用不直接信任任意 X-Forwarded-Proto。主机直连 HTTPS 而不使用该 HTTP 前端时也应显式配置 publicScheme=https。

OC 会话仍为进程内状态，当前仅支持 replicas=1、HPA=false。RC 的健康事件 SSE listeners、事件唤醒及调度器同样是进程内的，共享 SQL 并不提供跨实例通知协调，所以 RC 也仅支持 replicas=1。Chart 对多副本配置失败关闭，不宣称支持服务级 HA；不能通过直接 kubectl scale 绕开该边界。

## 运行态文件持久化与升级

MySQL/PostgreSQL 只覆盖 SQL 数据。OC 的 PreFlow、沙箱报告/Stub 模板和方案包仍写入 `data/`；RC 的本地安全审计仍写入 `log/audit/`。两个服务分别拥有独立的 runtime PVC，以 `data`、`log` 子目录挂载到 `/opt/<service>/data`、`/opt/<service>/log`。禁止把两服务指向同一个 claim。

```yaml
registry:
  replicas: 1
  persistence:
    existingClaim: ""  # 空：创建 registry-center-runtime；已有卷则填写同 namespace 的 claim
    size: 5Gi
    storageClassName: "" # 空：集群默认；"-"：显式无 StorageClass；或指定支持 fsGroup 的类
orchestration:
  replicas: 1
  persistence:
    existingClaim: ""
    size: 10Gi
    storageClassName: ""
```

自动创建的卷为 ReadWriteOnce，并带 `helm.sh/resource-policy: keep`；卸载保留卷，备份/销毁由运维显式管理。已有 claim 不由 Chart 创建或删除；应独立且可由 UID/GID 10001 写入。init container 使用同一个应用镜像、非 root 用户创建两个子目录，不对已有业务数据递归 chown。存储驱动需支持 fsGroup；无默认 provisioner 时应预建 claim 或配置 StorageClass，不能把 Pending Pod 当作已安装成功。

RC/OC Deployment 使用 `Recreate`，升级期间会短暂停服并清空内存会话。目的是避免同一卷的多个应用进程并发写审计/文件，并避免 RWO 卷在跨节点升级时因旧 Pod 占用而无法挂载；这不是零停机 HA。

**旧部署升级不能仅新挂一个空 PVC。** 在升级前停止业务写入，并在删除/替换旧 Pod 之前导出其 `data/`、`log/`；同时备份 SQL、独立 PKI 和 Secret。将导出文件按子目录恢复到新 claim，确认 UID 10001 权限、大小和校验和，然后使用 `existingClaim` 部署。若旧 Pod 已被删除且没有备份，其容器层数据无法靠这次修复恢复。PVC 容量扩展需遵循 StorageClass 能力；不要尝试用 Helm 缩小已有卷。

公共工作流模板改为镜像内 `samples/workflow_templates/` 的只读资源，不再放在运行态 `data/`。自定义旧模板应人工审查迁入发布资源目录、重建镜像；不要把整个本地 data 目录打包。

## 构建、部署与验证

```bash
# 为每个组件使用准确的源码 SHA；两个仓库的 SHA 不相同。
bash build/build.sh registry --source-ref <RC_SHA> --tag <IMAGE_TAG> --platforms linux/amd64 --no-push
bash build/build.sh orchestration --source-ref <OC_SHA> --tag <IMAGE_TAG> --platforms linux/amd64 --no-push
# 需要多架构时显式推送；多架构 --no-push 会拒绝，不会偷偷 --push。
bash online-install/one_click_install.sh --skip-build --skip-infra --values /path/to/deployment.yaml
helm lint online-install/openan-chart -f /path/to/deployment.yaml
helm template openan online-install/openan-chart -f /path/to/deployment.yaml
```

one_click_install.sh 恢复可跳过的构建、审核后的本地基础设施 Chart 与交互引导阶段；--values 跳过交互，--skip-build/--skip-infra 使用已准备环境。秘密静默输入并经 stdin 创建 Secret，不写入生成的 values；生产推荐预备 Secret + 原生 Helm 路径。不会在业务镜像启动 samples。镜像中保留公共 solution_packages 示例数据，但不携带样例账户和 Agent 服务。数据库不存在时按服务已有创建权限/迁移策略处理，生产推荐 DBA 预建。

CI 分别验证 Helm 矩阵、错误配置和构建失败退出；RC 已有 Linux 容器 smoke，OC 的真实启动/API 回归可独立执行。上线验收必须另外运行真实镜像+MySQL+nginx/Ingress，覆盖登录 Cookie、AgentCard CRUD/JWS、工作流 CRUD/SSE、证书缺失/错误密码、无/错 Token、断连和重启。Helm 渲染通过不是集群实测。

## 单机离线 Compose

浏览器入口不应借用 Nginx 的上游证书获得用户权限。在线 Chart 和 Compose 代理转发 `/api/orchestrate/api/v1/*`，保留 Authorization，并覆盖 `X-OpenAN-Browser-Gateway: 1`；后端只把它作为限制标记，不作为身份。公开 API 必须携带原账号 Bearer；网页内部接口保持 HttpOnly Cookie。在线 Chart 编排服务 Ingress 的直连入口同样验证账号 Bearer。自定义 frontend.nginxConfig 必须保留标记覆盖与原始 Authorization；未配用户认证时代理返回 503。

关闭对端证书校验与关闭业务鉴权不同：后端 HTTPS + verifyClient=false 配合调用方 verify=False 可以建立 TLS；合法 Token/用户会话仍必需。后端 verifyClient=true 时，调用方 verify=False 不会取消客户端证书要求。生产推荐配置可信 CA。

在线 Chart 与 Compose 显式设置 `ORCH_EXTERNAL_AUTH_MODE=user`，包括后端开启 mTLS 的场景；无需固定 ORCH_API_TOKEN。Ingress 证书只证明代理，不能代替原始账号 Token。改密、删除账号撤销该账号所有会话，重启后需重新登录；SQL 初始化账号必须先在网页完成强制改密。配套镜像必须包含 /api/v1/auth/token 和 user 认证模式；旧镜像需先升级，不能只升级安装模板。

使用 `offline-install-compose/build/build-offline.sh` 将匹配服务源码构建的镜像、前端静态文件与公共模板打成白名单发布包；不会复制本地 config.env、runtime、PKI 或业务数据。离线端不拉镜像，校验失败阻止安装，配置按字面解析而不执行 shell。

数据库可选外部/内置 MySQL 或 PostgreSQL，两个服务使用独立业务库和凭据。应用各单实例，Nginx 是唯一公开入口，公共协议、两个后端协议与客户端证书校验分别配置。TLS、签名和 Token 身份保持独立。全量 models.yaml 只读挂载，密钥由私有 runtime env 注入。生成的 runtime/compose.json 含敏感值，不应提交或上传。

Linux CI 构建真实镜像与离线发布包，验收脚本包含十组 MySQL/PostgreSQL、HTTP/HTTPS、公共 TLS 终止、RC/OC 混合协议及 mTLS 场景。检查返回的 AgentCard/PSOP 关键内容、更新读回、删除确实不存在，并在后端 IP 替换后验证 SQL、PreFlow、沙箱报告/Stub 模板、方案包和旧审计字节保留。文件夹具由真实存储组件生成，不冒称完成真实模型/工作流执行。只有对应提交的容器 job 通过，才能认定这些场景已验证；该结果不替代离线 Kubernetes、外部 IAM/模型、arm64 或完整工作流/SSE 的验收。卸载保留 SQL 卷和应用数据，旧目录数据需显式备份/恢复迁移。
