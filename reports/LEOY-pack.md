# LEOY-pack：binary/build/pack.sh 全参数实测报告

- 测试对象：`binary/build/pack.sh`（OpenAN 二进制离线打包器）
- 测试人：全栈交付工程 Agent（Leo Yang）
- 测试时间：2026-10-18（UTC）

## 1. 实测环境（与 issue 描述有出入，如实记录）

| 项 | issue 声称 | 实际实测 |
|---|---|---|
| 宿主 | aarch64 openEuler 22.03 SP3 | aarch64 openEuler 22.03 LTS-SP3（内核 5.10）✅ 一致 |
| Python | 仅 3.9.9 | 默认 `python3` 为 3.9.9，但 **`/root/.local/bin/python3.12` 已存在（3.12.14）** |
| Node | v22.23.2 | **v24.21.0** |
| npm | 10.9.8 | **11.19.0** |
| curl / tar | — | curl 7.79.1 / GNU tar 1.34 |
| 磁盘 | 18 GiB 剩余 | 32 G 可用 |
| 网络 | — | github / pypi / npm registry 均 200，可达 |

**关键结论**：issue 预设的「宿主只有 3.9.9 → pip 深处失败」前提**不成立**——本环境已带 Python 3.12.14，因此**无需安装即真跑通了 pack.sh**。此外，即使真的只有 3.9.9，脚本也会在**前置检查阶段**干净报错（见 §5.2），而不是在 pip 深处失败。

## 2. 必测参数组合结果（12 条）

| # | 命令 | 退出码 | 结果 | 产物 |
|---|---|---|---|---|
| 1 | `--help` | 0 | 通过：打印 usage | — |
| 2 | `-h` | 0 | 通过：与 `--help` 输出逐字节一致 | — |
| 3 | `--reg` | 0 | 通过：只选 registry | `registry-center-1.0.0-linux.tar.gz` (99M) |
| 4 | `--orc` | 0 | 通过：只选 orchestration | `orchestration-center-1.0.0-linux.tar.gz` (617M) |
| 5 | `--reg --orc` | 0 | 通过：两个包 | 两个 1.0.0 tarball |
| 6 | （无参） | 0 | 通过：默认两个包，与 #5 等价 | 两个 1.0.0 tarball |
| 7 | `--reg-version 1.0.0` | 0 | 通过：`--reg-version` 联合选中 registry；tag 归一化为 `v1.0.0`（flag），包名去 `v` 前缀 | `registry-center-1.0.0-linux.tar.gz` |
| 8 | `--orc-version v1.0.0` | 0 | 通过：只选 orchestration（flag） | `orchestration-center-1.0.0-linux.tar.gz` |
| 9 | `--reg --orc-version v1.0.0` | 0 | 通过：联合语义 registry(default) + orchestration(flag) | 两个 1.0.0 tarball |
| 10 | `--reg-version bogus-not-a-tag` | 1 | 失败（符合预期）：源码 404，明确报错，**未产出半成品 tarball** | 无 .tar.gz（残留一个空 build 目录，见 §6.2） |
| 11 | `--reg --badflag` | 1 | 失败（符合预期）：`Error: Unknown option: --badflag` + usage | — |
| 12 | `--reg-version`（缺值） | 1 | 失败（如实记录）：**`$2: unbound variable`**，非静默取空串 | — |

### #12 实际行为说明

issue 怀疑「`shift 2` 未校验 `$2`，疑似静默取空串或报错」。实测为**报错**：脚本开了 `set -euo pipefail`，`--reg-version` 分支执行 `REG_VERSION_FLAG="$2"`（`pack.sh:113`）时 `$2` 未绑定，直接 `unbound variable` 退出 1。`--orc-version` 同理（`pack.sh:118`）。

> 原始报错：`binary/build/pack.sh: line 113: $2: unbound variable`

根因：参数循环未校验 `--reg-version`/`--orc-version` 后面是否有值。属于 UX 缺陷（报错信息晦涩，未提示「缺值」），不影响正确性（不会误打包）。最小修复建议：在 `--reg-version)`/`--orc-version)` 分支加 `if [ $# -lt 2 ]; then echo "missing value"; exit 1; fi`（约 `pack.sh:112`、`pack.sh:117`）。

## 3. normalize_tag 三分支验证

| 分支 | 输入 | normalize 结果 | 源码 URL | 包名 | 证据 |
|---|---|---|---|---|---|
| `v*` | `--orc-version v1.0.0` | `v1.0.0`（原样） | `.../tags/v1.0.0.tar.gz` | `orchestration-center-1.0.0-linux.tar.gz`（去 `v`） | #8 |
| 数字开头 | `--reg-version 1.0.0` | `v1.0.0`（加 `v`） | `.../tags/v1.0.0.tar.gz` | `registry-center-1.0.0-linux.tar.gz`（去 `v`） | #7 |
| 其他 | `--reg-version custom-x` | `custom-x`（原样） | `.../tags/custom-x.tar.gz`（404） | 构建目录 `registry-center-custom-x-linux` | 附录 #13 |

注：`custom-x` 因上游无此 tag，在源码下载步 404 失败，故拿不到最终 tarball；但 info 块与构建目录名已证明「其他」分支不改写版本串、包名即 `custom-x`（不带 `v` 前缀）。

## 4. 产物证据（Python 3.12 默认，最终一次 `pack.sh` 双包）

```
$ ls -lh binary/build/dist/*.tar.gz
-rw-r--r-- 1 root root 617M ... orchestration-center-1.0.0-linux.tar.gz
-rw-r--r-- 1 root root  99M ... registry-center-1.0.0-linux.tar.gz
```

### 4.1 tar 内容抽查（前 20 行）

registry-center（节选）：根目录、`bin/`、`requirements.txt`、`Dockerfile`、`tests/`、`run/`、`log/`、`docker-compose.yml` 等。
orchestration-center（节选）：根目录、`bin/`、`requirements.txt`、`Dockerfile`、`tests/`、`vendor/wheels/`（含 `pytest-9.1.1-py3-none-any.whl` 等）。

### 4.2 清单文件内容摘要

**registry-center `README_OFFLINE.txt`**：标题 `Registry Center v1.0.0 - Offline Deployment Package`，`Target: linux/x86_64, aarch64 | Python 3.12`，说明含 x86_64 + aarch64 双架构 wheels、目标机免联网、`./install.sh --reg` 一键安装。

**orchestration-center `OFFLINE_BUNDLE_MANIFEST.txt`**：
```
Bundle created:    2026-10-18 03:57:17 UTC
Created on host:   node184
Python version:    Python 3.12.14
Node.js version:   v24.21.0
npm version:       11.19.0
Target archs:      x86_64, aarch64
Contents:
  - Project source code (Python + React)
  - vendor/wheels/       — Pre-downloaded Python wheels
  - vendor/npm-cache/    — npm cache for offline frontend build
  - etc/conf/ ... common/config/ ...
Note: venv and node_modules are NOT pre-built ...
```

## 5. 验收标准 4：包内结构核实

| 检查项 | registry-center | orchestration-center | 结论 |
|---|---|---|---|
| `vendor/wheels/` | ✅ 77 个 .whl | ✅ 79 个 .whl | 存在 |
| 按目标架构分目录 | ❌ **不分目录**，扁平存放，架构写在 wheel 文件名里（`...manylinux_2_28_x86_64.whl` / `..._aarch64.whl`） | 同左 | 见下 |
| `vendor/npm-cache/` | 不适用（无前端） | ✅ 存在 | 存在 |
| `node_modules`（应排除） | 0 | `workflow-designer/node_modules` = 0 ✅；但 `vendor/npm-cache/_npx/*/node_modules/` 有 7559 项 ⚠️ | 见下 |

**结论与证据**：

1. **wheels 按架构「扁平同目录」而非「分目录」**。`vendor/wheels/` 下直接放全部 wheel，架构由文件名区分：
   - registry：77 个 .whl，其中 `x86_64` 13、`aarch64` 13，其余为 `py3-none-any` 纯 Python 包。
   - orchestration：79 个 .whl，其中 `x86_64` 13、`aarch64` 13。
   - 证据：`tar -tzf ... | grep vendor/wheels/`，如 `numpy-2.5.4-cp312-cp312-manylinux_2_27_aarch64...whl` 与 `charset_normalizer-...manylinux2014_x86_64...whl`。这符合 `download_wheels_for_arch` 的实现——两次调用都写同一个 `$wheels_dir`（`pack.sh:285-286`），未按 arch 建子目录。

2. **`node_modules` 排除**：目标机的 app `node_modules` 确实被排除（`workflow-designer/node_modules` 在 tarball 中 0 项，靠 `pack.sh:469` 的 `rm -rf` + rsync `--exclude='node_modules'`）。但 `npm cache` 整目录拷贝（`pack.sh:461` `cp -r "$npm_global_cache"/*`）把历史 `npx` 缓存 `vendor/npm-cache/_npx/*/node_modules/`（7559 项）也一并打进了包——**属于体积膨胀（约数百 MB），非正确性 bug**。

3. **wheels 是 cp312**（默认 3.12）：registry 22 个 cp312、orchestration 20 个 cp312，证明 `--python-version 3.12` 生效。

## 6. PYTHON_VERSION 硬编码缺陷与修复

### 6.1 确认缺陷

`PYTHON_VERSION="3.12"`（原 `pack.sh:163`）为硬编码，但前置检查（`pack.sh:571` 附近）接受 `>= 3.12`。若宿主装的是 3.13，脚本会用 python3.13 跑，却仍按 `--python-version 3.12` 下载 wheel 并在 README 里写「Python 3.12」——ABI 与声明错位。属真实（潜在）缺陷。

### 6.2 最小可配置化修复（已提交）

- `binary/build/pack.sh:165`：`PYTHON_VERSION="${PYTHON_VERSION:-3.12}"`（支持环境变量覆盖）。
- `binary/build/pack.sh:580`：前置检查后，若仍是默认 `3.12`，则对齐到实际探测到的解释器版本 `${PY_VERSION}`。

**验证**（`PYTHON_VERSION=3.13 bash pack.sh --reg`）：退出 0，info 块显示 `Python version: 3.13`，README 写「Python 3.13」，包内 22 个 cp313 wheel、0 个 cp312——覆盖与 lockstep 均生效。默认 3.12 路径不受影响（本机 3.12.14 → 仍是 3.12）。

### 6.3 修正 issue 的一个前提

issue 认为「只有 3.9.9 会在 pip 深处失败」。实测（把 `/root/.local/bin` 从 PATH 隐藏、只剩 python3=3.9.9）脚本在**前置检查即干净退出**：

```
Error: Python 3.12+ not found.
       Searched: python3.13, python3.12, python3.11, python3
```

（退出码 1，见 `artifacts/pack/16-no-py312.log`）。即无需修复也会在 `pack.sh:571` 报清晰错误，不会走到 pip 下载。

## 7. 其他发现（遗留 / 建议，未在本次改动范围）

1. **`--reg-version`/`--orc-version` 缺值** → `unbound variable` 晦涩报错（`pack.sh:113`/`118`），建议补缺值校验（§2 #12）。
2. **打包失败残留空 build 目录**：`pack_registry` 在下载源码前就 `mkdir -p "$build_dir"`（`pack.sh:254`），下载 404 时留下空目录 `dist/build/registry-center-<tag>-linux`（#10/#13 均复现）。无 .tar.gz 产出，不影响正确性，属清理不彻底。
3. **npm cache 拷贝夹带 `_npx/*/node_modules`**（§5 第 2 点），使 orchestration 包膨胀到 617M；可考虑只拷贝 `_cacache/`（实际离线安装所需内容）。

## 8. 实际使用的版本与日志清单

- Python：`/root/.local/bin/python3.12`（3.12.14），本机**未安装**（已存在）。默认 `python3` 仍是 3.9.9。
- Node：v24.21.0；npm：11.19.0。
- 每条命令完整日志：`artifacts/pack/*.log`（16 个文件，含 00-evidence.log 汇总）。

| 日志 | 对应测试 |
|---|---|
| 01-help.log / 02-short-help.log | #1 / #2 |
| 03-reg.log / 04-orc.log | #3 / #4 |
| 05-reg-orc.log / 06-noargs.log | #5 / #6 |
| 07-regversion-1.0.0.log / 08-orcversion-v1.0.0.log / 09-reg-orcversion.log | #7 / #8 / #9 |
| 10-bogus-tag.log / 11-badflag.log / 12-regversion-missing.log | #10 / #11 / #12 |
| 13-regversion-custom-x.log | normalize_tag「其他」分支 |
| 14-env-override-3.13.log | PYTHON_VERSION 环境变量覆盖验证 |
| 15-final-default-both.log | 最终默认双包（产物证据） |
| 16-no-py312.log | 模拟仅 3.9.9 的前置检查行为 |

## 9. 结论

12 条命令全部有明确结果：9 条通过（#1–#9）、3 条按预期失败（#10 源码 404、#11 未知选项、#12 缺值 unbound variable）。两个组件在 Python 3.12.14 + Node 24.21 下**均真实跑通并产出离线 tarball**（99M / 617M），包内 wheels（扁平同目录、cp312、双架构）、npm-cache、清单文件齐全，app `node_modules` 正确排除。`PYTHON_VERSION` 硬编码缺陷已做最小可配置化修复并通过 env 覆盖实测。
