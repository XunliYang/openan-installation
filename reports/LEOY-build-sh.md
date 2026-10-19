# 测试报告 — containerized/build/build.sh 镜像构建链路

- 分支：`fix/build-stderr`（HEAD `49f94e5`，主题提交 `6279b6d fix(build): send log output to stderr so resolve_src captures only the path`）
- 宿主：`aarch64`，Docker 26.1.3，buildx v0.14.0，builder `multiarch-builder`（docker-container，amd64+arm64）
- 推送目标：`IMAGE_REGISTRY=ghcr.io`，`NAMESPACE=xunliyang`（classic PAT，含 `write:packages`，登录并推送成功）
- 统一 tag：`fix-stderr-test-20261018`；单架构测试 `fix-stderr-test-arm64-20261018`

## 必测参数组合结果

| # | 命令 | 退出码 | 结果 | 说明 |
|---|---|---|---|---|
| 1 | `./build.sh --help` | 0 | ✅ 通过 | 打印用法，无临时目录 |
| 2 | `./build.sh registry --image-registry ghcr.io --namespace xunliyang --tag fix-stderr-test-20261018` | 0 | ✅ 通过 | 双架构 manifest list 推送成功 |
| 3 | `./build.sh orchestration ...` | 0 | ✅ 通过 | 推送 orchestration-center（双架构）；workflow-designer 无 Dockerfile 被跳过 |
| 4 | `./build.sh portal --portal-release .../archive/v1.0.0.tar.gz` | 1 | ❌ 失败 | portal v1.0.0 源码 Dockerfile COPY 路径失效（D1） |
| 5 | `./build.sh registry orchestration ...` | 0 | ✅ 通过 | 位参组合：registry-center + orchestration-center 均推送 |
| 6 | `./build.sh --image-registry ... --namespace ... --tag ...` | 1 | ⚠️ 部分通过 | 无位参全量：registry+orchestration 推送成功，portal 源码构建失败（D1） |
| 7 | `./build.sh orchestration --platforms linux/arm64 --tag fix-stderr-test-arm64-20261018` | 0 | ✅ 通过 | 单架构（arm64）推送成功 |
| 8 | `./build.sh portal --platforms linux/arm64 --no-push --portal-src <本地>` | 1 | ❌ 失败 | portal 源码 Dockerfile 引用不存在的 plugin 目录（D1） |
| 9 | `./build.sh registry --platforms linux/amd64,linux/arm64 --no-push` | 2 | ✅ 通过 | `--no-push` + 多架构被拒 |
| 10 | `./build.sh --source-ref main ...` | — | ✅ 通过 | tag 派生为 `main-20261018`（配置区打印即算） |
| 11 | `./build.sh --tag v9.9.9-argtest --source-ref v1.0.0 --registry-src /nonexistent` | 1 | ✅ 通过 | `--tag` 显式不被 `--source-ref` 覆盖（配置区 `Image tag: v9.9.9-argtest`） |
| 12 | `./build.sh --nonsense` | 1 | ✅ 通过 | `Unknown argument: --nonsense` |
| 13 | `./build.sh --tag` | 2 | ✅ 通过 | `--tag requires a value` |
| 14 | `./build.sh --registry-src /nonexistent registry` | 1 | ✅ 通过 | `Local source path not found: /nonexistent` |

（每条命令一份日志见 `artifacts/buildsh_*.log`；构建类命令附 `*.stdout.log` 用于串味核验。）

## 推送镜像回查（imagetools inspect）

| 镜像 tag | 平台 | digest |
|---|---|---|
| `registry-center:fix-stderr-test-20261018` | linux/amd64, linux/arm64 | `sha256:a10da27763ced9efb448a3a612201abf1f299b20a1d5675e05e482465e938f12` |
| `orchestration-center:fix-stderr-test-20261018` | linux/amd64, linux/arm64 | `sha256:ca1bb43d9f9cbe401adde8586b1b747c0719e7b0faed767e71a3a56531e57c53` |
| `orchestration-center:fix-stderr-test-arm64-20261018` | linux/arm64 | `sha256:54b24edac4e1ae22880e7e98bf2e976b986fb3a0cedf27bd4c1358a8a9c4d3d1` |

> `registry-center:fix-stderr-test-20261018` 在 #2 首次推送后被 #5/#6 重推，provenance/attestation 重新生成使 manifest list digest 变为上表值，amd64/arm64 镜像内容一致。

## stderr/stdout 串味验证（本分支主题）

对 #2（registry）实测，`resolve_src` 返回值与 `log_*` 行已完全分离：

- `RC_SRC` 实际值（正确只含路径）：`…/openan-build.*/registry-center/registry-center-1.0.0/`
- `log_info` / `log_step` 行全部落在 stderr（`[STEP] Downloading …`、`[INFO] URL: …`、`[INFO] Registry Center source: <路径>`）
- stdout 中 `[INFO]`/`[STEP]`/`[WARN]`/`[ERROR]` 出现次数：**0**（仅配置区/结果区 echo）

**反向实证**：在 `main`（未含 `6279b6d` 修复）的 `build.sh` 上重跑同命令，`resolve_src` 把 `log_*` 行混入返回值，buildx 报 `unable to prepare context: path "\x1b[0;36m[STEP]…Downloading…\n…/registry-center-1.0.0/" not found` —— 正是本分支修复所消除的串味缺陷。结论：修复有效且必要。

## 发现的缺陷

### D1. portal v1.0.0 源码 Dockerfile 的 COPY 路径失效（#4/#6/#8 源码构建失败）

- 现象：`ERROR: failed to solve: … "/plugins/registry-center/package.json": not found`（`Dockerfile:50`）。
- 根因：portal 源码归档 `openan-portal-1.0.0` 的 `plugins/` 实际只有 `execution-center / orchestration-center / skill-center`，而源码 `Dockerfile:47-50` 仍引用 `demo-showcase / hello-portal / orchestration-center / registry-center`。属 **portal 源码仓库 v1.0.0 自身 Dockerfile 与源码树不同步**，非 build.sh 缺陷。
- 最小修复建议：portal 镜像改用 `containerized/build/portal/build-portal-image.sh` 的 release 产物路径（portal 报告已实证其双架构推送成功）；或修正 portal 源码仓库 v1.0.0 Dockerfile 的 plugin COPY 列表。`build.sh` 的 portal 源码构建路径在 v1.0.0 不可用。

### D2. workflow-designer 在 v1.0.0 无 Dockerfile，orchestration 只产出 orchestration-center

- 现象：orchestration-center v1.0.0 归档中 `workflow-designer/` 目录存在但**不含 Dockerfile**。
- 后果：`build.sh orchestration` 只构建+推送 `orchestration-center`，`workflow-designer` 走 `[WARN] Workflow Designer Dockerfile not found, skipping` 被跳过。与 issue 表 #3 期望「推送 orchestration-center + workflow-designer」不符。
- 本 PR 已修复进度计数缺陷：`build.sh:350` 由 `[ -d "$OC_SRC/workflow-designer" ]` 改为 `[ -f "$OC_SRC/workflow-designer/Dockerfile" ]`，与构建逻辑（`build.sh:374`）一致。前：`[1/2]` 永达不到 `2/2`；后：`[1/1]` + 跳过 warn + 退出 0（见 `artifacts/buildsh_15_counter_fix.log`）。

## README 与 --help 比对（Stage 3 才改 README，此处只出清单）

`containerized/build/README.md` 参数表（README.md:67-79）遗漏两个 `--help` 中存在的选项：

- `--portal-release <url>`：`--help` 有（`build.sh:112`），README 全篇未提及。
- `--portal-src <dir>`：`--help` 有（`build.sh:113`），README 仅示例（README.md:37）提及，参数表缺。

另「Default Source URLs」段（README.md:109-115）只列 registry-center 与 orchestration-center，漏 openan-portal（build.sh 已派生 `openan-portal/archive/${SOURCE_REF}.tar.gz`）。

## 验收标准核对

1. 14 + 10 条命令均有明确结果，见两张表。
2. 每条真实推送均已 `imagetools inspect` 回查，`Platforms:` 段与 digest 见上表及 portal 报告。
3. 失败项输出原文+根因+修复建议见 D1/D2。
4. README 不一致清单见上。
5. `python3 -m pytest tests/test_portal_release_image_build.py -q` → `11 passed`。

## 追加：按指定版本构建（用户指定 source）

用户指定三组件 source 后追加实测（非默认 v1.0.0；命令日志见 `artifacts/buildsh_v112_registry.log` 等）。

| 组件 | 命令（source） | 镜像 tag | 结果 |
|---|---|---|---|
| registry-center | `./build.sh registry --source-ref v1.1.2 ...` | `registry-center:v1.1.2`（amd64+arm64） | ✅ 推送成功 |
| orchestration-center | `./build.sh orchestration --source-ref main ...` | `orchestration-center:main-20261019`（amd64+arm64） | ✅ 推送成功 |
| workflow-designer | （同一 orchestration 命令自动带上） | `workflow-designer:main-20261019` | ⚠️ amd64 QEMU 交叉构建 SIGSEGV，见下 |
| openan-portal | v1.0.0 release artifact（portal 报告） | `openan-portal:v1.0.0`（amd64+arm64） | ✅ 已推送（前次） |

推送回查 digest：

| 镜像 | 平台 | digest |
|---|---|---|
| `registry-center:v1.1.2` | linux/amd64, linux/arm64 | `sha256:ec570031dc2fe82fb32baa6cb4f140335a5d7e32d25f5bd1849e484877de97d0` |
| `orchestration-center:main-20261019` | linux/amd64, linux/arm64 | `sha256:3a715a7b27145aa90c76d042640f2047cc1039b4918b7ef6187a225938fc02e9` |
| `workflow-designer:main-20261019-arm64` | linux/arm64 | `sha256:b6aca44c9da44163e2f9de5b4c7f905881870b819a7f09a7cd803f314bb7a80a` |

### 追加发现 D3：workflow-designer amd64 交叉构建 SIGSEGV（QEMU 仿真缺陷，非源码）

- 现象：`./build.sh orchestration --source-ref main`（默认双架构）中 workflow-designer amd64 构建 `#27 RUN npm run build` 退出码 139（SIGSEGV），整体 exit 1；arm64 阶段 `#21 RUN npm run build` **DONE 15.4s** 成功。
- **根因（已隔离复现）**：`npm run build` = `vite build`（Vite 8.0.16），其打包器是 **Rolldown 1.0.3（原生 Rust）**（另含原生 esbuild/lightningcss）。buildx 在 aarch64 宿主上经 QEMU usermode（binfmt_misc）仿真 linux/amd64。Rolldown 的 x86-64 Rust 二进制在 QEMU TCG 下直接段错误——最小复现 `docker run --platform linux/amd64 node:20-slim node -e "…rolldown({input})…"` 报 `qemu: uncaught target signal 11 (Segmentation fault)`。同命令原生 arm64 正常（15.4s）。
- 定位：Vite 8 改用原生 Rust bundler 后，amd64 交叉构建在 QEMU 仿真下必然段错误（Rust 原生多线程/SIMD/内存映射语义 QEMU TCG 不能忠实复现）。属**构建环境（QEMU 仿真）限制，非 workflow-designer 源码缺陷**。
- 验证：`./build.sh orchestration --source-ref main --platforms linux/arm64 --tag main-20261019-arm64` → 双组件 arm64 全部成功（exit 0），`workflow-designer:main-20261019-arm64` 已推送并 `imagetools inspect` 回查。
- 影响：宿主为 aarch64 时，workflow-designer 的 amd64 交叉构建不可用；如需 amd64 镜像需在 amd64 原生机器/CI runner 上构建。orchestration-center 不受影响（Python 构建无此问题，双架构已推送成功）。