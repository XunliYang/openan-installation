# Orchestration Center 离线部署 / Offline Deployment

[中文](#中文) | [English](#english)

---

## 中文

### 概述

本目录包含 Orchestration Center（编排中心）的离线部署脚本。采用**两阶段部署模式**：在联网机器上打包，然后在气隙（离线）机器上安装。

### 目录文件

| 文件 | 说明 |
|------|------|
| `pack_offline_bundle.sh` | 在**联网机器**上运行，构建自包含的离线部署包 |
| `install_offline.sh` | 在**离线机器**上运行，从离线包安装 Orchestration Center |
| `offline_config_guide.md` | 离线配置指南，详细说明各配置文件的编辑方法 |

### 部署流程

```
┌─────────────────┐     tar.gz      ┌─────────────────┐
│  联网机器 (Online) │ ──────────────▶ │  离线机器 (Air-gapped) │
│                  │   USB / SCP     │                  │
│  pack_offline_   │                 │  install_offline │
│  bundle.sh       │                 │  .sh             │
└─────────────────┘                  └─────────────────┘
```

#### 第一阶段：在联网机器上打包

```bash
# 前提条件：Python 3.12+、Node.js 20.19+、npm、互联网连接
./pack_offline_bundle.sh

# 跳过前端构建（仅后端）
./pack_offline_bundle.sh --skip-frontend
```

生成的 tarball 包含：
- 完整项目源码（Python + React）
- 预构建的 Python 虚拟环境（venv）
- 预构建的前端 node_modules
- pip wheel 缓存（用于离线重建 venv）
- npm 缓存（用于离线重建前端）
- 配置模板文件

#### 第二阶段：在离线机器上安装

```bash
# 1. 解压离线包
tar xzf orchestration-center-offline-bundle.tar.gz
cd orchestration-center-offline

# 2. 运行安装脚本
./bin/install_offline.sh

# 3. 编辑配置文件（参见 offline_config_guide.md）
# 4. 启动服务
bin/start.sh
```

`install_offline.sh` 支持的参数：

| 参数 | 说明 |
|------|------|
| `--dir=PATH` | 安装目录（默认：`/opt/orchestration-center`） |
| `--service` | 安装为 systemd 服务（需要 root） |
| `--no-service` | 不安装为 systemd 服务（手动启动） |
| `--rebuild-venv` | 从缓存的 wheels 重建 venv |
| `--rebuild-frontend` | 从缓存的 npm 重建前端 |

### 离线机器前提条件

| 组件 | 版本要求 | 说明 |
|------|---------|------|
| Python | 3.12+ | 系统自带，需与联网机器的大版本.小版本一致 |
| Node.js | 20.19+ | 仅使用前端时需要 |
| 根权限 | — | systemd 安装需要；手动启动则不需要 |

### 配置文件

安装完成后，需编辑以下配置文件（详见 [offline_config_guide.md](./offline_config_guide.md)）：

| 文件 | 说明 | 何时编辑 |
|------|------|---------|
| `etc/conf/server.conf` | IP、端口、HTTPS、认证、持久化模式 | **必须** |
| `common/config/llm_config.json` | LLM API 密钥、模型端点 | **必须**（至少配置 chat 模型） |
| `etc/conf/db_config.json` | PostgreSQL 连接 | 仅当 `persistence_mode=postgresql` |
| `etc/conf/server.properties` | TLS 版本、加密套件、限流 | 可选（默认值即可） |
| `etc/ssl/` | SSL 证书 | 仅当 `enable_https=true` |
| `etc/conf/agent_credentials.json` | A2A Agent 认证凭据 | 仅当 Agent 需要认证 |

### 环境变量覆盖

可通过环境变量在运行时覆盖配置文件值：

| 环境变量 | 对应配置 | 配置键 |
|---------|---------|--------|
| `ORCH_IP` | server.conf | `ip` |
| `ORCH_PORT` / `PORT` | server.conf | `port` |
| `ORCH_ENABLE_HTTPS` | server.conf | `enable_https` |
| `AGENT_REGISTRY_URL` | server.conf | `agent_registry_url` |
| `PERSISTENCE_MODE` | server.conf | `persistence_mode` |
| `DB_HOST` | db_config.json | `host` |
| `DB_PORT` | db_config.json | `port` |
| `DB_PASSWORD` | db_config.json | `password` |
| `LLM_CHAT_API_KEY` | llm_config.json | `chat.api_key` |
| `LLM_CHAT_URL` | llm_config.json | `chat.url` |
| `LLM_CHAT_MODEL` | llm_config.json | `chat.model` |

---

## English

### Overview

This directory contains offline deployment scripts for the Orchestration Center. It uses a **two-phase deployment model**: package on an online machine, then install on an air-gapped (offline) machine.

### Directory Files

| File | Description |
|------|-------------|
| `pack_offline_bundle.sh` | Run on the **online** machine to build a self-contained offline bundle |
| `install_offline.sh` | Run on the **offline** machine to install from the bundle |
| `offline_config_guide.md` | Detailed configuration guide for editing config files on the air-gapped machine |

### Deployment Workflow

```
┌─────────────────┐     tar.gz      ┌─────────────────┐
│  Online Machine  │ ──────────────▶ │  Air-gapped Machine │
│                  │   USB / SCP     │                  │
│  pack_offline_   │                 │  install_offline │
│  bundle.sh       │                 │  .sh             │
└─────────────────┘                  └─────────────────┘
```

#### Phase 1: Package on the Online Machine

```bash
# Prerequisites: Python 3.12+, Node.js 20.19+, npm, internet access
./pack_offline_bundle.sh

# Skip frontend build (backend only)
./pack_offline_bundle.sh --skip-frontend
```

The resulting tarball contains:
- Full project source code (Python + React)
- Pre-built Python virtual environment (venv)
- Pre-built frontend node_modules
- pip wheel cache (for offline venv rebuild)
- npm cache (for offline frontend rebuild)
- Configuration templates

#### Phase 2: Install on the Offline Machine

```bash
# 1. Extract the bundle
tar xzf orchestration-center-offline-bundle.tar.gz
cd orchestration-center-offline

# 2. Run the installer
./bin/install_offline.sh

# 3. Edit config files (see offline_config_guide.md)
# 4. Start the service
bin/start.sh
```

`install_offline.sh` supported options:

| Option | Description |
|--------|-------------|
| `--dir=PATH` | Install directory (default: `/opt/orchestration-center`) |
| `--service` | Install as systemd service (requires root) |
| `--no-service` | Do not install as systemd service (manual start) |
| `--rebuild-venv` | Rebuild venv from cached wheels |
| `--rebuild-frontend` | Rebuild frontend from cached npm |

### Offline Machine Prerequisites

| Component | Version | Notes |
|-----------|---------|-------|
| Python | 3.12+ | System Python; must match the major.minor of the online machine |
| Node.js | 20.19+ | Only needed if using the frontend |
| Root privileges | — | Required for systemd install; not needed for manual start |

### Configuration Files

After installation, edit the following config files (see [offline_config_guide.md](./offline_config_guide.md) for details):

| File | Description | When |
|------|-------------|------|
| `etc/conf/server.conf` | IP, port, HTTPS, auth, persistence mode | **Always** |
| `common/config/llm_config.json` | LLM API keys, model endpoints | **Always** (chat model required) |
| `etc/conf/db_config.json` | PostgreSQL connection | Only if `persistence_mode=postgresql` |
| `etc/conf/server.properties` | TLS versions, ciphers, rate limits | Optional (defaults are fine) |
| `etc/ssl/` | SSL certificates | Only if `enable_https=true` |
| `etc/conf/agent_credentials.json` | A2A agent auth credentials | Only if agents require auth |

### Environment Variable Overrides

Config file values can be overridden at runtime via environment variables:

| Env Var | Config File | Key |
|---------|-------------|-----|
| `ORCH_IP` | server.conf | `ip` |
| `ORCH_PORT` / `PORT` | server.conf | `port` |
| `ORCH_ENABLE_HTTPS` | server.conf | `enable_https` |
| `AGENT_REGISTRY_URL` | server.conf | `agent_registry_url` |
| `PERSISTENCE_MODE` | server.conf | `persistence_mode` |
| `DB_HOST` | db_config.json | `host` |
| `DB_PORT` | db_config.json | `port` |
| `DB_PASSWORD` | db_config.json | `password` |
| `LLM_CHAT_API_KEY` | llm_config.json | `chat.api_key` |
| `LLM_CHAT_URL` | llm_config.json | `chat.url` |
| `LLM_CHAT_MODEL` | llm_config.json | `chat.model` |
