# OpenAN 一键部署脚本使用说明 / One-Click Deployment Script Guide (openan_install.sh)

[中文](#中文) | [English](#english)

---

## 中文

本脚本用于在 Linux 服务器上一键部署 OpenAN 全套服务，包括 registry-center、orchestration-center 后端与前端、agents 示例服务，以及 Nginx HTTPS 反向代理。

---

### 目录

- [环境要求](#环境要求)
- [从 Git Clone 到运行](#从-git-clone-到运行)
- [脚本执行流程详解](#脚本执行流程详解)
- [用户交互提示一览](#用户交互提示一览)
- [服务端口与访问地址](#服务端口与访问地址)
- [日志文件位置](#日志文件位置)
- [停止服务](#停止服务)

---

### 环境要求

| 组件 | 最低版本 | 说明 |
|------|---------|------|
| 操作系统 | Linux (x86_64 / aarch64) | 支持 Debian/Ubuntu、CentOS/RHEL/Rocky/Alma/openEuler |
| Python | 3.12+ | 脚本会自动检测并尝试安装 |
| Node.js | 20.19+ | 需手动安装 |
| npm | 随 Node.js 附带 | — |
| curl | 任意 | 系统自带 |
| tar | 任意 | 系统自带 |
| 网络连接 | 必需 | 需访问 GitHub 下载组件 Release |

> 如果 Python 3.12+ 或 nginx 未安装，脚本会尝试通过包管理器自动安装，此时可能需要 **sudo 权限**。

---

### 从 Git Clone 到运行

#### 1. 克隆仓库

```bash
git clone https://github.com/XunliYang/openan-installation.git
cd openan-installation/binary/one-click
```

#### 2. 赋予执行权限（如果需要）

```bash
chmod +x openan_install.sh
```

#### 3. 运行脚本

```bash
./openan_install.sh
```

脚本会自动完成所有下载、配置和启动工作。运行过程中会有少量交互提示（见下文），其余全自动完成。

---

### 脚本执行流程详解

#### Step 0：环境检查

- **Python 3.12+**：依次尝试 `python3.12` → `python3`。若均不存在，自动检测发行版并尝试：
  - Debian/Ubuntu：`apt-get install python3.12`（含 deadsnakes PPA 回退）
  - CentOS/RHEL/Rocky/Alma/openEuler：`dnf/yum install python3.12`（含 module enable 回退）
  - 最终回退：从 [python-build-standalone](https://github.com/indygreg/python-build-standalone) 下载独立版 Python
- **Node.js 20.19+**：检查版本，不满足则报错退出（需手动安装）
- **npm**：检查是否存在
- **curl / tar**：检查是否存在

#### Step 0.5：检查 Nginx

- 若 `nginx` 或 `openssl` 未安装，自动通过包管理器安装（apt / dnf / yum）
- 安装需要 sudo 权限

#### Step 1：下载组件源码

从 GitHub Release 下载并解压（使用 `curl` + `tar`，不依赖 `git clone`）：

| 组件 | 下载地址 | 版本 |
|------|---------|------|
| registry-center | `https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |
| orchestration-center | `https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |

> 若目录已存在且非空，则跳过下载。

#### Step 2：配置 registry-center

1. 创建 Python 虚拟环境（venv）
2. 安装 Python 依赖（`pip install -r requirements.txt`）
3. 生成自签名证书（RSA，serverAuth，密码 `Dev@12345`）
4. 准备 SSL 目录（`etc/ssl/`），复制证书并设置 0600 权限
5. 修正 `server.conf` 中的 `jwk_private_key_path` 路径
6. 运行 `python -m agent_registry.init` 初始化（自动输入默认值，无需用户交互）

#### Step 3：配置 orchestration-center

1. 创建 Python 虚拟环境（venv）
2. 安装后端 Python 依赖
3. 进入 `workflow-designer/` 目录，运行 `npm install --force` 安装前端依赖

#### Step 3.5：配置 LLM 与注册中心地址

**此步骤有用户交互，详见[用户交互提示一览](#用户交互提示一览)。**

- 可选择跳过 LLM 配置
- 交互式输入 LLM 模型名、API URL、API Key
- 建议使用：
```
model name: glm-5.1
model url: https://open.bigmodel.cn/api/paas/v4/chat/completions
```
- 自动验证 LLM 连通性（发送测试请求）
- 验证失败时允许重新输入或跳过
- 将配置写入 `llm_config.json`（registry-center 和 orchestration-center 各一份）
- 无论是否跳过，脚本都会在 Step 3.5 结束时输出一段 bash 命令，供用户随时重新配置 LLM
- 将 `server.conf` 中的 `agent_registry_url` 从 `https://` 修正为 `http://`（避免 SSL 版本不匹配错误）

#### Step 3.7：配置 Nginx HTTPS 反向代理

1. 生成自签名 SSL 证书（`/etc/nginx/ssl/cert.pem`、`key.pem`，有效期 365 天）
2. 生成 Nginx 配置文件并部署到 `/etc/nginx/conf.d/openan.conf`
3. 移除 Debian/Ubuntu 默认站点配置（避免端口冲突）
4. 测试 Nginx 配置有效性

#### Step 4：启动所有服务

依次启动以下 5 个服务，每个服务启动前会自动清理被占用的端口：

| 服务 | 端口 | 启动方式 |
|------|------|---------|
| registry-center | 5000 | `python -m agent_registry.start` |
| orchestration-center 后端 | 5001 | `python -m orchestrate.start` |
| orchestration-center 前端 | 3003 | `npm run dev` |
| agents 示例服务 | 8080 | `python -m samples.start_agents_server` |
| Nginx HTTPS 代理 | 443 | `systemctl start nginx` 或 `nginx` |

---

### 用户交互提示一览

运行过程中，脚本可能出现以下交互提示。除 LLM 配置外，其余均为 sudo 密码提示或自动完成。

#### 1. sudo 密码提示（可能多次出现）

```
[sudo] password for <用户名>:
```

**触发时机**：当脚本需要安装 Python、nginx、openssl，或操作 `/etc/nginx/` 目录时。

**你需要做什么**：输入当前用户的 sudo 密码。如果你以 root 用户运行，则不会出现此提示。

---

#### 2. 是否跳过 LLM 配置

```
Skip LLM configuration and configure manually? [y/N]:
```

**这是什么**：选择是否跳过 LLM 配置步骤。如果跳过，脚本不会询问模型名、API URL 和 API Key，也不会修改 `llm_config.json`。

**默认值**：`N`（不跳过，进入交互式配置）

**你需要做什么**：
- 直接回车（或输入 `n`）进入交互式 LLM 配置流程
- 输入 `y` 跳过 LLM 配置，使用默认值

> 无论是否跳过，脚本都会在 Step 3.5 结束时输出一段 bash 命令，供你随时重新配置 LLM。复制后修改其中的 `MODEL`、`URL`、`API_KEY` 三个变量值，然后在终端（脚本目录下）运行即可：

```bash
# 脚本会输出类似以下的命令（请替换实际值后运行）：
MODEL="glm-5.1"
URL="https://open.bigmodel.cn/api/paas/v4/chat/completions"
API_KEY="your-api-key-here"

for f in \
  registry-center/common/config/llm_config.json \
  orchestration-center/common/config/llm_config.json
do
  [ -f "$f" ] || { echo "  [WARN] $f not found"; continue; }
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    c = json.load(fh)
c['chat']['model'] = sys.argv[2]
c['chat']['url'] = sys.argv[3]
c['chat']['api_key'] = sys.argv[4]
with open(sys.argv[1], 'w') as fh:
    json.dump(c, fh, indent=2, ensure_ascii=False)
    fh.write('\n')
print(f'  [OK] Updated {sys.argv[1]}')
" "$f" "$MODEL" "$URL" "$API_KEY"
done
```

> 如果跳过了交互式配置，LLM 相关功能将使用默认值，可能无法正常工作。请在启动服务前运行上述命令完成配置。

---

#### 3. LLM 模型名称

```
Enter LLM model name [qwen3.6-flash]:
```

**这是什么**：指定 LLM 聊天模型名称。脚本会用此名称调用大语言模型 API。

**默认值**：`qwen3.6-flash`（阿里云通义千问）

**常见选择**：

| 提供商 | 模型名称 |
|--------|---------|
| 阿里云通义千问 | `qwen3.6-flash` |
| 智谱 GLM | `glm-5.1` |

**你需要做什么**：直接回车使用默认值，或输入你使用的模型名称。

---

#### 4. LLM API URL

```
Enter LLM API URL [https://dashscope.aliyuncs.com/compatible-mode/v1]:
```

**这是什么**：LLM 服务的 API 接口地址（OpenAI 兼容格式）。脚本会自动在 URL 后拼接 `/chat/completions`（如果尚未包含）。

**默认值**：`https://dashscope.aliyuncs.com/compatible-mode/v1`（阿里云通义千问）

**常见选择**：

| 提供商 | API URL |
|--------|---------|
| 阿里云通义千问 | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4/chat/completions` |

**你需要做什么**：直接回车使用默认值，或输入你的 API 地址。

---

#### 5. LLM API Key

```
Enter your API key:
```

**这是什么**：调用 LLM API 的密钥，用于身份认证。

**默认值**：无（必须输入）

**你需要做什么**：输入你在 LLM 服务商处获取的 API Key。如果不输入，会跳过验证并提示后续手动编辑 `llm_config.json`。

> 脚本会对 Key 做掩码显示（仅显示前 4 位和后 4 位）。

---

#### 6. LLM 验证失败后的重试提示

当 API Key / URL / 模型验证失败时，脚本会依次重新询问以上三项：

```
[RETRY] Please re-enter LLM configuration.
        (Type 'skip' at any prompt to bypass validation)

Model [当前模型]:
API URL [当前URL]:
API key [***]:
```

**你需要做什么**：
- 修正输入错误的值后回车
- 在任意一个提示处输入 `skip` 可跳过验证（配置可能不正确，需后续手动修改 `llm_config.json`）
- 直接回车保留当前值不变

---

### 服务端口与访问地址

部署完成后，可通过以下地址访问各服务：

| 服务 | HTTP 地址 | HTTPS 地址（经 Nginx 代理） |
|------|----------|--------------------------|
| registry-center | http://127.0.0.1:5000 | https://localhost/registry/ |
| orchestration 后端 | http://127.0.0.1:5001 | https://localhost/api/orchestrate/ |
| orchestration 前端 | http://localhost:3003 | https://localhost/ |
| agents 示例服务 | http://127.0.0.1:8080 | — |
| Nginx HTTPS 入口 | — | https://localhost |

> Nginx 使用自签名证书，浏览器会提示安全警告，选择"继续访问"即可。

---

### 日志文件位置

| 服务 | 日志路径 |
|------|---------|
| registry-center | `registry-center/registry-center.log` |
| orchestration 后端 | `orchestration-center/backend.log` |
| orchestration 前端 | `orchestration-center/frontend.log` |
| agents 示例服务 | `orchestration-center/agents-server.log` |

> 日志文件相对于脚本所在目录（即 `binary/one-click/`）。

---

### 停止服务

脚本运行结束后会输出所有服务的 PID。停止方式：

```bash
# 停止 Python 和 Node.js 服务
kill <REGISTRY_PID> <BACKEND_PID> <FRONTEND_PID> <AGENTS_PID>

# 停止 Nginx
sudo systemctl stop nginx
# 或
sudo nginx -s stop
```

> 将 `<PID>` 替换为脚本结束时输出的实际 PID。

---

## English

This script deploys the full OpenAN stack on a Linux server in one command, including registry-center, orchestration-center backend and frontend, agents example server, and an Nginx HTTPS reverse proxy.

---

### Table of Contents

- [Prerequisites](#prerequisites)
- [From Clone to Running](#from-clone-to-running)
- [Script Execution Flow](#script-execution-flow)
- [Interactive Prompts](#interactive-prompts)
- [Service Ports and URLs](#service-ports-and-urls)
- [Log File Locations](#log-file-locations)
- [Stopping Services](#stopping-services)

---

### Prerequisites

| Component | Minimum Version | Notes |
|-----------|----------------|-------|
| OS | Linux (x86_64 / aarch64) | Supports Debian/Ubuntu, CentOS/RHEL/Rocky/Alma/openEuler |
| Python | 3.12+ | Auto-detected; script will attempt to install |
| Node.js | 20.19+ | Must be installed manually |
| npm | Bundled with Node.js | — |
| curl | Any | Pre-installed |
| tar | Any | Pre-installed |
| Network | Required | Needs GitHub access to download component releases |

> If Python 3.12+ or nginx is not installed, the script will attempt to install them via the system package manager. This may require **sudo privileges**.

---

### From Clone to Running

#### 1. Clone the repository

```bash
git clone https://github.com/XunliYang/openan-installation.git
cd openan-installation/binary/one-click
```

#### 2. Grant execute permission (if needed)

```bash
chmod +x openan_install.sh
```

#### 3. Run the script

```bash
./openan_install.sh
```

The script handles all downloads, configuration, and service startup automatically. There are a few interactive prompts during execution (see below); everything else is fully automated.

---

### Script Execution Flow

#### Step 0: Environment Check

- **Python 3.12+**: Tries `python3.12` → `python3` in order. If neither exists, auto-detects the distribution and attempts:
  - Debian/Ubuntu: `apt-get install python3.12` (with deadsnakes PPA fallback)
  - CentOS/RHEL/Rocky/Alma/openEuler: `dnf/yum install python3.12` (with module enable fallback)
  - Final fallback: Download standalone Python from [python-build-standalone](https://github.com/indygreg/python-build-standalone)
- **Node.js 20.19+**: Checks version; exits with error if not met (manual install required)
- **npm**: Checks availability
- **curl / tar**: Checks availability

#### Step 0.5: Check Nginx

- If `nginx` or `openssl` is not installed, auto-installs via package manager (apt / dnf / yum)
- Requires sudo privileges

#### Step 1: Download Component Source

Downloads and extracts from GitHub Release (using `curl` + `tar`, no `git clone` dependency):

| Component | Download URL | Version |
|-----------|-------------|---------|
| registry-center | `https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |
| orchestration-center | `https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |

> If the directory already exists and is non-empty, the download is skipped.

#### Step 2: Configure registry-center

1. Create a Python virtual environment (venv)
2. Install Python dependencies (`pip install -r requirements.txt`)
3. Generate self-signed certificate (RSA, serverAuth, password `Dev@12345`)
4. Prepare SSL directory (`etc/ssl/`), copy certificates and set 0600 permissions
5. Fix `jwk_private_key_path` in `server.conf`
6. Run `python -m agent_registry.init` initialization (automated input with defaults, no user interaction needed)

#### Step 3: Configure orchestration-center

1. Create a Python virtual environment (venv)
2. Install backend Python dependencies
3. Enter `workflow-designer/` directory, run `npm install --force` to install frontend dependencies

#### Step 3.5: Configure LLM and Registry URL

**This step involves user interaction. See [Interactive Prompts](#interactive-prompts).**

- Option to skip LLM configuration
- Interactive input for LLM model name, API URL, and API Key
- Suggested values:
```
model name: glm-5.1
model url: https://open.bigmodel.cn/api/paas/v4/chat/completions
```
- Automatic LLM connectivity validation (sends a test request)
- Allows re-entry or skipping on validation failure
- Writes configuration to `llm_config.json` (one copy each for registry-center and orchestration-center)
- Regardless of whether skipped, the script always outputs a bash command at the end of Step 3.5 for users to reconfigure LLM at any time
- Fixes `agent_registry_url` in `server.conf` from `https://` to `http://` (avoids SSL version mismatch errors)

#### Step 3.7: Configure Nginx HTTPS Reverse Proxy

1. Generate self-signed SSL certificate (`/etc/nginx/ssl/cert.pem`, `key.pem`, valid for 365 days)
2. Generate Nginx configuration and deploy to `/etc/nginx/conf.d/openan.conf`
3. Remove Debian/Ubuntu default site config (avoids port conflicts)
4. Test Nginx configuration validity

#### Step 4: Start All Services

Starts the following 5 services in order. Each service's port is automatically freed before startup:

| Service | Port | Start Method |
|---------|------|-------------|
| registry-center | 5000 | `python -m agent_registry.start` |
| orchestration-center backend | 5001 | `python -m orchestrate.start` |
| orchestration-center frontend | 3003 | `npm run dev` |
| agents example server | 8080 | `python -m samples.start_agents_server` |
| Nginx HTTPS proxy | 443 | `systemctl start nginx` or `nginx` |

---

### Interactive Prompts

During execution, the script may present the following interactive prompts. Except for LLM configuration, all are sudo password prompts or automated.

#### 1. sudo Password Prompt (may appear multiple times)

```
[sudo] password for <username>:
```

**When**: When the script needs to install Python, nginx, openssl, or modify `/etc/nginx/` directory.

**What to do**: Enter your sudo password. If running as root, this prompt will not appear.

---

#### 2. Skip LLM Configuration

```
Skip LLM configuration and configure manually? [y/N]:
```

**What**: Choose whether to skip the LLM configuration step. If skipped, the script will not ask for model name, API URL, or API Key, and will not modify `llm_config.json`.

**Default**: `N` (do not skip, enter interactive configuration)

**What to do**:
- Press Enter (or type `n`) to enter the interactive LLM configuration flow
- Type `y` to skip LLM configuration and use defaults

> Regardless of whether you skip, the script always outputs a bash command at the end of Step 3.5 for you to reconfigure the LLM at any time. Copy it, modify the `MODEL`, `URL`, and `API_KEY` variables, and run it from the script directory:

```bash
# The script outputs a command like this (replace values before running):
MODEL="glm-5.1"
URL="https://open.bigmodel.cn/api/paas/v4/chat/completions"
API_KEY="your-api-key-here"

for f in \
  registry-center/common/config/llm_config.json \
  orchestration-center/common/config/llm_config.json
do
  [ -f "$f" ] || { echo "  [WARN] $f not found"; continue; }
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    c = json.load(fh)
c['chat']['model'] = sys.argv[2]
c['chat']['url'] = sys.argv[3]
c['chat']['api_key'] = sys.argv[4]
with open(sys.argv[1], 'w') as fh:
    json.dump(c, fh, indent=2, ensure_ascii=False)
    fh.write('\n')
print(f'  [OK] Updated {sys.argv[1]}')
" "$f" "$MODEL" "$URL" "$API_KEY"
done
```

> If you skipped interactive configuration, LLM-related features will use defaults and may not work correctly. Please run the above command to configure before starting services.

---

#### 3. LLM Model Name

```
Enter LLM model name [qwen3.6-flash]:
```

**What**: Specifies the LLM chat model name. The script uses this name to call the LLM API.

**Default**: `qwen3.6-flash` (Alibaba Cloud Qwen)

**Common choices**:

| Provider | Model Name |
|----------|-----------|
| Alibaba Cloud Qwen | `qwen3.6-flash` |
| Zhipu GLM | `glm-5.1` |

**What to do**: Press Enter for the default, or type your model name.

---

#### 4. LLM API URL

```
Enter LLM API URL [https://dashscope.aliyuncs.com/compatible-mode/v1]:
```

**What**: The LLM service API endpoint (OpenAI-compatible format). The script automatically appends `/chat/completions` if not already present.

**Default**: `https://dashscope.aliyuncs.com/compatible-mode/v1` (Alibaba Cloud Qwen)

**Common choices**:

| Provider | API URL |
|----------|---------|
| Alibaba Cloud Qwen | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| Zhipu GLM | `https://open.bigmodel.cn/api/paas/v4/chat/completions` |

**What to do**: Press Enter for the default, or type your API URL.

---

#### 5. LLM API Key

```
Enter your API key:
```

**What**: The API key for calling the LLM API, used for authentication.

**Default**: None (must be entered)

**What to do**: Enter the API key obtained from your LLM provider. If left empty, validation is skipped and you'll be prompted to edit `llm_config.json` manually.

> The key is masked in output (only first 4 and last 4 characters shown).

---

#### 6. Retry Prompt After LLM Validation Failure

When API Key / URL / model validation fails, the script re-prompts for all three:

```
[RETRY] Please re-enter LLM configuration.
        (Type 'skip' at any prompt to bypass validation)

Model [current model]:
API URL [current URL]:
API key [***]:
```

**What to do**:
- Correct the erroneous value and press Enter
- Type `skip` at any prompt to bypass validation (configuration may be incorrect; edit `llm_config.json` manually later)
- Press Enter to keep the current value unchanged

---

### Service Ports and URLs

After deployment, services are accessible at the following addresses:

| Service | HTTP URL | HTTPS URL (via Nginx proxy) |
|---------|----------|------------------------------|
| registry-center | http://127.0.0.1:5000 | https://localhost/registry/ |
| orchestration backend | http://127.0.0.1:5001 | https://localhost/api/orchestrate/ |
| orchestration frontend | http://localhost:3003 | https://localhost/ |
| agents example server | http://127.0.0.1:8080 | — |
| Nginx HTTPS entry | — | https://localhost |

> Nginx uses a self-signed certificate. Browsers will show a security warning; choose "Proceed" to continue.

---

### Log File Locations

| Service | Log Path |
|---------|----------|
| registry-center | `registry-center/registry-center.log` |
| orchestration backend | `orchestration-center/backend.log` |
| orchestration frontend | `orchestration-center/frontend.log` |
| agents example server | `orchestration-center/agents-server.log` |

> Log files are relative to the script directory (i.e., `binary/one-click/`).

---

### Stopping Services

The script outputs all service PIDs when finished. To stop:

```bash
# Stop Python and Node.js services
kill <REGISTRY_PID> <BACKEND_PID> <FRONTEND_PID> <AGENTS_PID>

# Stop Nginx
sudo systemctl stop nginx
# or
sudo nginx -s stop
```

> Replace `<PID>` with the actual PIDs output at the end of the script.
