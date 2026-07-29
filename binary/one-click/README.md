# OpenAN 一键部署脚本使用说明（openan_install.sh）

本脚本用于在 Linux 服务器上一键部署 OpenAN 全套服务，包括 registry-center、orchestration-center 后端与前端、agents 示例服务，以及 Nginx HTTPS 反向代理。

---

## 目录

- [环境要求](#环境要求)
- [从 Git Clone 到运行](#从-git-clone-到运行)
- [脚本执行流程详解](#脚本执行流程详解)
- [用户交互提示一览](#用户交互提示一览)
- [服务端口与访问地址](#服务端口与访问地址)
- [日志文件位置](#日志文件位置)
- [停止服务](#停止服务)

---

## 环境要求

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

## 从 Git Clone 到运行

### 1. 克隆仓库

```bash
git clone https://github.com/XunliYang/openan-installation.git
cd openan-installation/binary/one-click
```

### 2. 赋予执行权限（如果需要）

```bash
chmod +x openan_install.sh
```

### 3. 运行脚本

```bash
./openan_install.sh
```

脚本会自动完成所有下载、配置和启动工作。运行过程中会有少量交互提示（见下文），其余全自动完成。

---

## 脚本执行流程详解

### Step 0：环境检查

- **Python 3.12+**：依次尝试 `python3.12` → `python3`。若均不存在，自动检测发行版并尝试：
  - Debian/Ubuntu：`apt-get install python3.12`（含 deadsnakes PPA 回退）
  - CentOS/RHEL/Rocky/Alma/openEuler：`dnf/yum install python3.12`（含 module enable 回退）
  - 最终回退：从 [python-build-standalone](https://github.com/indygreg/python-build-standalone) 下载独立版 Python
- **Node.js 20.19+**：检查版本，不满足则报错退出（需手动安装）
- **npm**：检查是否存在
- **curl / tar**：检查是否存在

### Step 0.5：检查 Nginx

- 若 `nginx` 或 `openssl` 未安装，自动通过包管理器安装（apt / dnf / yum）
- 安装需要 sudo 权限

### Step 1：下载组件源码

从 GitHub Release 下载并解压（使用 `curl` + `tar`，不依赖 `git clone`）：

| 组件 | 下载地址 | 版本 |
|------|---------|------|
| registry-center | `https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |
| orchestration-center | `https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz` | v1.0.0 |

> 若目录已存在且非空，则跳过下载。

### Step 2：配置 registry-center

1. 创建 Python 虚拟环境（venv）
2. 安装 Python 依赖（`pip install -r requirements.txt`）
3. 生成自签名证书（RSA，serverAuth，密码 `Dev@12345`）
4. 准备 SSL 目录（`etc/ssl/`），复制证书并设置 0600 权限
5. 修正 `server.conf` 中的 `jwk_private_key_path` 路径
6. 运行 `python -m agent_registry.init` 初始化（自动输入默认值，无需用户交互）

### Step 3：配置 orchestration-center

1. 创建 Python 虚拟环境（venv）
2. 安装后端 Python 依赖
3. 进入 `workflow-designer/` 目录，运行 `npm install --force` 安装前端依赖

### Step 3.5：配置 LLM 与注册中心地址

**此步骤有用户交互，详见[用户交互提示一览](#用户交互提示一览)。**

- 交互式输入 LLM 模型名、API URL、API Key
-- 建议使用：
```
model name: glm-5.1
model url: https://open.bigmodel.cn/api/paas/v4/chat/completions
```
- 自动验证 LLM 连通性（发送测试请求）
- 验证失败时允许重新输入或跳过
- 将配置写入 `llm_config.json`（registry-center 和 orchestration-center 各一份）
- 将 `server.conf` 中的 `agent_registry_url` 从 `https://` 修正为 `http://`（避免 SSL 版本不匹配错误）

### Step 3.7：配置 Nginx HTTPS 反向代理

1. 生成自签名 SSL 证书（`/etc/nginx/ssl/cert.pem`、`key.pem`，有效期 365 天）
2. 生成 Nginx 配置文件并部署到 `/etc/nginx/conf.d/openan.conf`
3. 移除 Debian/Ubuntu 默认站点配置（避免端口冲突）
4. 测试 Nginx 配置有效性

### Step 4：启动所有服务

依次启动以下 5 个服务，每个服务启动前会自动清理被占用的端口：

| 服务 | 端口 | 启动方式 |
|------|------|---------|
| registry-center | 5000 | `python -m agent_registry.start` |
| orchestration-center 后端 | 5001 | `python -m orchestrate.start` |
| orchestration-center 前端 | 3003 | `npm run dev` |
| agents 示例服务 | 8080 | `python -m samples.start_agents_server` |
| Nginx HTTPS 代理 | 443 | `systemctl start nginx` 或 `nginx` |

---

## 用户交互提示一览

运行过程中，脚本可能出现以下交互提示。除 LLM 配置外，其余均为 sudo 密码提示或自动完成。

### 1. sudo 密码提示（可能多次出现）

```
[sudo] password for <用户名>:
```

**触发时机**：当脚本需要安装 Python、nginx、openssl，或操作 `/etc/nginx/` 目录时。

**你需要做什么**：输入当前用户的 sudo 密码。如果你以 root 用户运行，则不会出现此提示。

---

### 2. LLM 模型名称

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

### 3. LLM API URL

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

### 4. LLM API Key

```
Enter your API key:
```

**这是什么**：调用 LLM API 的密钥，用于身份认证。

**默认值**：无（必须输入）

**你需要做什么**：输入你在 LLM 服务商处获取的 API Key。如果不输入，会跳过验证并提示后续手动编辑 `llm_config.json`。

> 脚本会对 Key 做掩码显示（仅显示前 4 位和后 4 位）。

---

### 5. LLM 验证失败后的重试提示

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

## 服务端口与访问地址

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

## 日志文件位置

| 服务 | 日志路径 |
|------|---------|
| registry-center | `registry-center/registry-center.log` |
| orchestration 后端 | `orchestration-center/backend.log` |
| orchestration 前端 | `orchestration-center/frontend.log` |
| agents 示例服务 | `orchestration-center/agents-server.log` |

> 日志文件相对于脚本所在目录（即 `binary/one-click/`）。

---

## 停止服务

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
