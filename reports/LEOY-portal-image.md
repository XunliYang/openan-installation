# 测试报告 — containerized/build/portal/build-portal-image.sh（release 产物打包）

- 分支：`fix/build-stderr`（HEAD `49f94e5`）
- 脚本：`containerized/build/portal/build-portal-image.sh`（release 产物 `index.html + assets/ + plugins/` + 内联 Dockerfile）
- 宿主：`aarch64`，Docker 26.1.3，buildx v0.14.0，自动选中 builder `default-builder`（docker-container）

## 必测参数组合结果

| # | 命令 | 退出码 | 结果 | 说明 |
|---|---|---|---|---|
| 1 | `./build-portal-image.sh -h` | 0 | ✅ 通过 | 打印脚本头注释块（`Build the OpenAN Portal ...` → `set -euo pipefail`） |
| 2 | `./build-portal-image.sh -n` | 0 | ✅ 通过 | dry run 打印 `would run: docker buildx build ...`，未下载未构建 |
| 3 | `REGISTRY=ghcr.io/xunliyang TAG=v1.0.0 ./build-portal-image.sh` | 1 | ⚠️ 阻塞（构建成功，推送 403） | 真实下载 + sha256 校验通过 + 双架构构建成功，推送被 ghcr 403 拒绝 |
| 4 | `... TAG=v1.0.0 EXTRA_TAGS="latest fix-stderr-test-20261018" ...` | — | ⚠️ 阻塞 | 与 #3 同路径，推送 403；EXTRA_TAGS 拼接逻辑已由 dry-run 验证（见下） |
| 5 | `REGISTRY=ghcr.io/xunliyang PUSH=0 PLATFORMS=linux/arm64 ...` | 0 | ✅ 通过 | 单架构 load 到本地镜像表 |
| 6 | `REGISTRY=ghcr.io/XunliYang ./build-portal-image.sh -n` | 1 | ✅ 通过 | `image reference must be lowercase: ghcr.io/XunliYang/openan-portal:v1.0.0` |
| 7 | `REGISTRY=ghcr.io/xunliyang TAG=v9.9.9 ./build-portal-image.sh -n` | 0 | ✅ 通过 | 命中 `no pinned sha256 for tag v9.9.9 — skipping verification` warn 分支 |
| 8 | `PUSH=0 PLATFORMS=linux/amd64,linux/arm64 ./build-portal-image.sh` | 1 | ✅ 通过 | `multi-arch builds must push (set PUSH=1); a manifest list cannot be --load'ed` |
| 9 | `SKIP_CHECKSUM=1 DIST_TARBALL=<本地> ... TAG=v1.0.0-fixstderr PUSH=0` | 0 | ✅ 通过 | 本地 tarball 单架构 load，未 pin 的 tag 不中断 |
| 10 | `./build-portal-image.sh -z` | 1 | ✅ 通过 | `unknown option -z (try -h)` |

（完整日志见 `artifacts/portal_*.log`，stdout/stderr 分列。）

## 重点核实的疑似缺陷（#2 `-n` 与 download 的交互）

dry run 下 `tarball` 变量指向 `$CTX/openan-portal-dist.tar.gz`（不存在），核实脚本在 `-n` 下是否因后续步骤读不到文件而崩溃：

- 结果：**不崩溃，退出 0**。`-n` 下对 `tarball` 的读取（`curl` 下载、`sha256sum` 校验、`tar -xzf` 解包）均被 `[ "$DRY_RUN" = 1 ]` 或 `[ "$DRY_RUN" = 0 ]` 守卫跳过，仅打印 `would verify sha256 == ...` / `would copy ...` / `would run: docker buildx build ...`。
- 结论：疑似缺陷**不存在**，脚本在 dry run 路径是安全的。

## 实证细节

### #3 双架构构建成功，仅推送被拒

`linux/amd64` 与 `linux/arm64` 两个平台全部构建完成（`exporting manifest list ... done`），失败发生在导出推送阶段：

```
#21 exporting to image
#21 pushing layers 1.4s done
#21 ERROR: failed to push ghcr.io/xunliyang/openan-portal:v1.0.0: unexpected status from HEAD request to https://ghcr.io/v2/xunliyang/openan-portal/blobs/sha256:4f19ed...: 403 Forbidden
```

sha256 校验（真实下载）通过：`ok sha256 verified (b43d943f45328ba8008dcb4d60d105e9e934e5737d040a6d8634986c0e04f9f5)`，与脚本内 pin 的 `DIST_SHA[v1.0.0]` 一致。

### #4 EXTRA_TAGS 拼接（dry-run 旁证）

由于真实推送被 403 拒绝，`imagetools inspect` 三 tag 回查无法执行。作为旁证，dry run 已验证多 tag 的 `-t` 拼接正确：

```
-t ghcr.io/xunliyang/openan-portal:v1.0.0 -t ghcr.io/xunliyang/openan-portal:latest -t ghcr.io/xunliyang/openan-portal:fix-stderr-test-20261018
```

（推送权限恢复后，`imagetools inspect` 应能对三个 tag 均查回同一 manifest list digest。）

### #5 / #9 本地 load 结果

- #5：`built locally: ghcr.io/xunliyang/openan-portal:v1.0.0`（`docker images` 可见，53.6MB）
- #9：`built locally: ghcr.io/xunliyang/openan-portal:v1.0.0-fixstderr`（本地 tarball，SKIP_CHECKSUM=1）

## 发现的缺陷

### 推送权限缺失（环境阻塞，非脚本缺陷）

与 `build.sh` 报告 D3 相同：当前沙箱 GitHub token 无 `write:packages`，所有真实 `--push` 被 ghcr 403 拒绝。修复建议同 D3（提供带 `write:packages` 的 PAT 并 `docker login ghcr.io` 后重跑 #3/#4）。

## 验收标准核对

1. 10 条命令均有明确结果（通过/失败/阻塞）。
2. 真实推送的 `imagetools inspect` 回查：**因 403 无法回查**（见上）。
3. 失败项根因+修复建议见上。
4. （本脚本无对应 README 参数表要求。）
5. 相关 pytest：`tests/test_portal_release_image_build.py` → `11 passed`（该文件即本脚本的契约测试）。
