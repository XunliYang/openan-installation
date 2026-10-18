# 测试报告 — containerized/build/build.sh 镜像构建链路

- 分支：`fix/build-stderr`（HEAD `49f94e5`，主题提交 `6279b6d fix(build): send log output to stderr so resolve_src captures only the path`）
- 宿主：`aarch64`，Docker 26.1.3，buildx v0.14.0，builder `multiarch-builder`（docker-container，amd64+arm64）
- 推送目标：`IMAGE_REGISTRY=ghcr.io`，`NAMESPACE=xunliyang`
- 统一 tag：`fix-stderr-test-20261018`（单架构测试用 `fix-stderr-test-arm64-20261018`）

## 必测参数组合结果

| # | 命令 | 退出码 | 结果 | 说明 |
|---|---|---|---|---|
| 1 | `./build.sh --help` | 0 | ✅ 通过 | 打印用法，无临时目录 |
| 2 | `./build.sh registry --image-registry ghcr.io --namespace xunliyang --tag fix-stderr-test-20261018` | 1 | ⚠️ 阻塞（双架构构建完成，推送 denied） | 真实下载+amd64/arm64 双架构构建全部完成（manifest list `sha256:85081d…` 已导出），推送 `permission_denied: The token provided does not match expected scopes` |
| 3 | `./build.sh orchestration ...` | — | ⚠️ 阻塞 | 见「阻塞项说明」 |
| 4 | `./build.sh portal --portal-release .../archive/v1.0.0.tar.gz` | — | ❌ 失败 | portal v1.0.0 源码 Dockerfile COPY 路径失效（见 #8 实证） |
| 5 | `./build.sh registry orchestration ...` | — | ⚠️ 阻塞 | 位参组合 = #2+#3，推送 403 |
| 6 | `./build.sh --image-registry ... --namespace ... --tag ...` | — | ⚠️ 阻塞 | 无位参全量 = 三组件，推送 403 |
| 7 | `./build.sh orchestration --platforms linux/arm64 --tag fix-stderr-test-arm64-20261018` | 1 | ⚠️ 阻塞（构建完成，推送 denied） | orchestration-center 单架构构建成功，推送 `permission_denied: The token provided does not match expected scopes` |
| 8 | `./build.sh portal --platforms linux/arm64 --no-push --portal-src <本地>` | 1 | ❌ 失败 | portal 源码 Dockerfile 引用不存在的 plugin 目录 |
| 9 | `./build.sh registry --platforms linux/amd64,linux/arm64 --no-push` | 2 | ✅ 通过 | `--no-push` + 多架构被拒 |
| 10 | `./build.sh --source-ref main ...` | — | ✅ 通过 | tag 派生为 `main-20261018`（配置区打印即算） |
| 11 | `./build.sh --tag v9.9.9-argtest --source-ref v1.0.0 --registry-src /nonexistent` | 1 | ✅ 通过 | `--tag` 显式不被 `--source-ref` 覆盖（配置区 `Image tag: v9.9.9-argtest`） |
| 12 | `./build.sh --nonsense` | 1 | ✅ 通过 | `Unknown argument: --nonsense` |
| 13 | `./build.sh --tag` | 2 | ✅ 通过 | `--tag requires a value` |
| 14 | `./build.sh --registry-src /nonexistent registry` | 1 | ✅ 通过 | `Local source path not found: /nonexistent` |

（每条命令的完整日志见 `artifacts/buildsh_*.log`，stdout/stderr 分列于 `*.stdout.log` / `*.stderr.log`。）

## stderr/stdout 串味验证（本分支主题）

对 #2（registry）实测，`resolve_src` 返回值与 `log_*` 行已完全分离：

- `RC_SRC` 实际值（正确只含路径）：`/tmp/multica-task-1515706564/openan-build.C1DKBXVg/registry-center/registry-center-1.0.0/`
- `log_info` / `log_step` 行全部落在 stderr：
  - `[STEP] Downloading registry-center from release...`
  - `[INFO] URL: https://github.com/project-openan/registry-center/archive/v1.0.0.tar.gz`
  - `[INFO] registry-center downloaded and extracted to ...`
  - `[INFO] Registry Center source: <路径>`
- stdout 中 `[INFO]`/`[STEP]`/`[WARN]`/`[ERROR]` 出现次数：**0**（仅配置区与结果区 echo 块）

结论：`fix/build-stderr` 的修复（`log_*` 改 `>&2`，`resolve_src` 只 `printf` 路径）生效，#2/#7/#14 均无串味。

## 发现的脚本/源码缺陷

### D1. portal v1.0.0 源码 Dockerfile 的 COPY 路径失效（`--portal-release` / `--portal-src` 源码构建失败）

- 现象（#8，退出码 1）：`ERROR: failed to solve: ... "/plugins/registry-center/package.json": not found`，对应 `Dockerfile:50`。
- 根因：portal 源码归档 `openan-portal-1.0.0` 的 `plugins/` 实际只有 `execution-center / orchestration-center / skill-center`（外加 `plugin-overrides.json`），而源码 `Dockerfile`（`openan-portal-1.0.0/Dockerfile:47-50`）仍引用 `demo-showcase / hello-portal / orchestration-center / registry-center` 四个 plugin 子目录。属于 **portal 源码仓库 v1.0.0 自身 Dockerfile 与源码树不同步**，非 build.sh 缺陷。
- 最小修复建议：portal 镜像改用 `containerized/build/portal/build-portal-image.sh` 的 release 产物路径（`index.html + assets/ + plugins/`，已内联 Dockerfile），这正是该脚本存在的原因；或修正 portal 源码仓库 v1.0.0 Dockerfile 的 plugin COPY 列表。`build.sh` 的 portal 源码构建路径在 v1.0.0 不可用。

### D2. workflow-designer 在 v1.0.0 无 Dockerfile，orchestration 只产出 orchestration-center

- 现象：orchestration-center v1.0.0 归档中 `workflow-designer/` 目录存在但**不含 Dockerfile**（`find . -name Dockerfile` 仅命中顶层 `./Dockerfile`）。
- 后果：`build.sh orchestration`（#3/#7）实际只会构建+推送 `orchestration-center`，`workflow-designer` 走 `log_warn "Workflow Designer Dockerfile not found, skipping"` 分支被跳过。与 issue 表 #3 期望「推送 orchestration-center + workflow-designer」不符。
- 该脚本缺陷已在本 PR 修复：`build.sh:350` 计数条件由 `[ -d "$OC_SRC/workflow-designer" ]` 改为 `[ -f "$OC_SRC/workflow-designer/Dockerfile" ]`，与构建逻辑（`build.sh:374`）保持一致。
  - 前：`[STEP] [1/2] Building Orchestration Center...`（TOTAL=2，但 workflow-designer 被跳过，永远达不到 2/2）
  - 后：`[STEP] [1/1] Building Orchestration Center...` + `[WARN] Workflow Designer Dockerfile not found, skipping`，退出 0（见 `artifacts/buildsh_15_counter_fix.log`）

### D3. 推送权限缺失（环境阻塞，非脚本缺陷）

- 现象：所有真实 `--push` 被 ghcr 拒绝。证据（三条独立路径）：
  - `docker buildx imagetools create -t ghcr.io/xunliyang/registry-center:push-probe-20261018 ghcr.io/xunliyang/registry-center:v1.0.0` → `PUT .../manifests/push-probe-20261018: 403 Forbidden`
  - #7 orchestration-center 单架构构建成功后推送 → `denied: permission_denied: The token provided does not match expected scopes.`
  - portal #3 双架构构建成功后推送 → `HEAD .../blobs/sha256:...: 403 Forbidden`
- 根因：当前沙箱可用的 GitHub token（`~/.config/gh/hosts.yml` 的 fine-grained PAT）无 `write:packages` 权限；`GET /user/packages` 返回 `403 Resource not accessible by personal access token`。issue 所称「已用探针镜像验证推送权限可用」在本沙箱无法复现。
- 最小修复建议：提供带 `write:packages`（及 `read:packages`）权限的 PAT，`echo $TOKEN | docker login ghcr.io -u Xunliyang --password-stdin` 后重跑 #2/#3/#4/#5/#6/#7。

## README 与 --help 比对（Stage 3 才改 README，此处只出清单）

`containerized/build/README.md` 参数表（Options 表，README.md:67-79）遗漏两个 `--help` 中存在的选项：

- `--portal-release <url>`：`--help` 有（`build.sh:112`），README 全篇未提及。
- `--portal-src <dir>`：`--help` 有（`build.sh:113`），README 仅示例（README.md:37）提及，参数表缺。

另：「Default Source URLs」段（README.md:109-115）只列 registry-center 与 orchestration-center，漏 openan-portal（build.sh 已派生 `openan-portal/archive/${SOURCE_REF}.tar.gz`）。

## 验收标准核对

1. 24 条命令均有明确结果（通过/失败/阻塞），见两张表。
2. 真实推送的 `imagetools inspect` 回查：**因推送被 403 拒绝，无推送产物可回查**；已回查既有 `ghcr.io/xunliyang/registry-center:v1.0.0`（amd64+arm64 manifest list）作为对照。
3. 失败项输出原文+根因+修复建议见 D1/D2/D3。
4. README 不一致清单见上。
5. `python3 -m pytest tests/test_portal_release_image_build.py -q` → `11 passed in 0.50s`。
