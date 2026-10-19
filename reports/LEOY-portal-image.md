# 测试报告 — containerized/build/portal/build-portal-image.sh（release 产物打包）

- 分支：`fix/build-stderr`（HEAD `49f94e5`）
- 脚本：`containerized/build/portal/build-portal-image.sh`（release 产物 `index.html + assets/ + plugins/` + 内联 Dockerfile）
- 宿主：`aarch64`，Docker 26.1.3，buildx v0.14.0，自动选中 builder `default-builder`（docker-container）

## 必测参数组合结果

| # | 命令 | 退出码 | 结果 | 说明 |
|---|---|---|---|---|
| 1 | `./build-portal-image.sh -h` | 0 | ✅ 通过 | 打印脚本头注释块（`Build the OpenAN Portal ...` → `set -euo pipefail`） |
| 2 | `./build-portal-image.sh -n` | 0 | ✅ 通过 | dry run 打印 `would run: docker buildx build ...`，未下载未构建 |
| 3 | `REGISTRY=ghcr.io/xunliyang TAG=v1.0.0 ./build-portal-image.sh` | 0 | ✅ 通过 | 真实下载 + sha256 校验通过 + 双架构推送成功 |
| 4 | `... TAG=v1.0.0 EXTRA_TAGS="latest fix-stderr-test-20261018" ...` | 0 | ✅ 通过 | 三个 tag 全部推送，`imagetools inspect` 均可查回 |
| 5 | `REGISTRY=ghcr.io/xunliyang PUSH=0 PLATFORMS=linux/arm64 ...` | 0 | ✅ 通过 | 单架构 load 到本地镜像表 |
| 6 | `REGISTRY=ghcr.io/XunliYang ./build-portal-image.sh -n` | 1 | ✅ 通过 | `image reference must be lowercase: ghcr.io/XunliYang/openan-portal:v1.0.0` |
| 7 | `REGISTRY=ghcr.io/xunliyang TAG=v9.9.9 ./build-portal-image.sh -n` | 0 | ✅ 通过 | 命中 `no pinned sha256 for tag v9.9.9 — skipping verification` warn 分支 |
| 8 | `PUSH=0 PLATFORMS=linux/amd64,linux/arm64 ./build-portal-image.sh` | 1 | ✅ 通过 | `multi-arch builds must push (set PUSH=1); a manifest list cannot be --load'ed` |
| 9 | `SKIP_CHECKSUM=1 DIST_TARBALL=<本地> ... TAG=v1.0.0-fixstderr PUSH=0` | 0 | ✅ 通过 | 本地 tarball 单架构 load，未 pin 的 tag 不中断 |
| 10 | `./build-portal-image.sh -z` | 1 | ✅ 通过 | `unknown option -z (try -h)` |

（完整日志见 `artifacts/portal_*.log`。）

## 推送镜像回查（imagetools inspect）

| 镜像 tag | 平台 | digest |
|---|---|---|
| `openan-portal:v1.0.0` | linux/amd64, linux/arm64 | `sha256:f7bda0c9a07b634a685c5b593403552f45ccee9627c536dce0e10ccc3b5f60a7` |
| `openan-portal:latest` | linux/amd64, linux/arm64 | `sha256:f7bda0c9a07b634a685c5b593403552f45ccee9627c536dce0e10ccc3b5f60a7` |
| `openan-portal:fix-stderr-test-20261018` | linux/amd64, linux/arm64 | `sha256:f7bda0c9…`（同上） |

#4 三个 tag 指向同一 manifest list digest（`EXTRA_TAGS` 生效）。

## 重点核实的疑似缺陷（#2 `-n` 与 download 的交互）

dry run 下 `tarball` 变量指向 `$CTX/openan-portal-dist.tar.gz`（不存在），核实脚本在 `-n` 下是否因后续步骤读不到文件而崩溃：

- 结果：**不崩溃，退出 0**。`-n` 下对 `tarball` 的读取（`curl` 下载、`sha256sum` 校验、`tar -xzf` 解包）均被 `[ "$DRY_RUN" = 1 ]` 或 `[ "$DRY_RUN" = 0 ]` 守卫跳过，仅打印 `would verify sha256 == ...` / `would copy ...` / `would run: docker buildx build ...`。
- 结论：疑似缺陷**不存在**，脚本在 dry run 路径是安全的。

## 实证细节

- #3 真实下载 + sha256 校验通过：`ok sha256 verified (b43d943f45328ba8008dcb4d60d105e9e934e5737d040a6d8634986c0e04f9f5)`，与脚本内 pin 的 `DIST_SHA[v1.0.0]` 一致；双架构构建 + 推送成功（`pushed manifest list: ghcr.io/xunliyang/openan-portal:v1.0.0`）。
- #5 / #9 本地 load：`built locally: ghcr.io/xunliyang/openan-portal:v1.0.0` / `…:v1.0.0-fixstderr`（53.6MB）。

## 发现的缺陷

无脚本缺陷。唯一的阻塞（ghcr 推送权限）已解决：换用含 `write:packages` 的 classic PAT 后，#3/#4 真实推送与 `imagetools inspect` 回查均通过。

## 验收标准核对

1. 10 条命令均有明确结果。
2. 每条真实推送（#3/#4）均已 `imagetools inspect` 回查，`Platforms:` 段与 digest 见上表。
3. 失败项：无（#3/#4 已由阻塞转通过）。
4. （本脚本无对应 README 参数表要求。）
5. 相关 pytest：`tests/test_portal_release_image_build.py` → `11 passed`（该文件即本脚本的契约测试）。