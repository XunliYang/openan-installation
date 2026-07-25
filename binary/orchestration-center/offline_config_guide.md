# Offline Deployment Configuration Guide

This guide walks you through configuring the Orchestration Center on an air-gapped
(off-network) machine after extracting the offline bundle.

---

## Quick Start

```bash
# 1. Extract the bundle (from USB, SCP, etc.)
tar xzf orchestration-center-offline-bundle.tar.gz
cd orchestration-center-offline

# 2. Run the installer
./bin/install_offline.sh

# 3. Edit config files (this guide)
# 4. Start the service
bin/start.sh
```

---

## Files You Need to Edit

| # | File | What's Inside | When |
|---|------|---------------|------|
| 1 | `etc/conf/server.conf` | IP, port, HTTPS, auth, persistence mode | **Always** |
| 2 | `common/config/llm_config.json` | LLM API keys, model endpoints | **Always** (chat model required) |
| 3 | `etc/conf/db_config.json` | PostgreSQL connection | Only if `persistence_mode=postgresql` |
| 4 | `etc/conf/server.properties` | TLS versions, ciphers, rate limits | Optional (defaults are fine) |
| 5 | `etc/ssl/` | SSL certificates | Only if `enable_https=true` |
| 6 | `etc/conf/agent_credentials.json` | A2A agent auth credentials | Only if agents require auth |

---

## 1. `etc/conf/server.conf` — Backend Server Config

This is the main config file. Edit with any text editor (`vi`, `nano`, etc.).

### Network

```ini
# Listening address
#   127.0.0.1 = localhost only (use if running behind Nginx)
#   0.0.0.0   = accept from all interfaces
ip=127.0.0.1

# Listening port
port=5001
```

### HTTPS / TLS

```ini
# Set to true for production
enable_https=false

# Certificate paths (relative to project root)
ssl_certfile=etc/ssl/server.cer
ssl_keyfile=etc/ssl/server_key.pem
ssl_keyfile_password=etc/ssl/cert_pwd
ssl_ca_certs=etc/ssl/trust.cer

# Require client certificates (mTLS)
verify_client=false

# Verify remote server certs when connecting outward (to agents, registry)
client_verify_server=false
```

**To enable HTTPS:**

```bash
# Generate self-signed certificates (if you don't have your own)
python generate_selfsign_cert.py etc/ssl serverAuth

# Then edit server.conf:
#   enable_https=true
#   verify_client=false  (or true for mTLS)
```

### Authentication

```ini
# SHA-256 hash of the frontend login password.
# Leave empty to disable login (not recommended for production).
# Generate the hash:
#   python generate_access_password.py
access_password=

# Session token lifetime in seconds (default: 43200 = 12 hours)
access_token_ttl=43200
```

### Persistence

```ini
# file       = JSON files in data/workflow_storage/
# postgresql = PostgreSQL database (see db_config.json)
persistence_mode=file
```

### Registry

```ini
# URL of the Agent Registry Center
agent_registry_url=https://127.0.0.1:5000
```

---

## 2. `common/config/llm_config.json` — LLM Configuration

**This is critical — the orchestration engine cannot function without a working
chat model.** You need at minimum the `chat` section configured.

### Minimal config (OpenAI-compatible API)

```json
{
  "chat": {
    "model": "deepseek-chat",
    "url": "https://api.deepseek.com/v1/chat/completions",
    "api_key": "sk-your-actual-api-key",
    "enable_thinking": true,
    "auth": null,
    "headers": {},
    "body": {
      "model": "$MODEL",
      "messages": [{"role": "user", "content": "$PROMPT"}]
    },
    "response": {
      "answer": "choices[0].message.content",
      "reasoning": "choices[0].message.reasoning_content"
    }
  }
}
```

### Full config (chat + embed + rerank)

If you need semantic search and workflow retrieval, also configure `embed` and
`rerank`:

```json
{
  "chat": { "...": "..." },
  "embed": {
    "model": "bge-m3",
    "url": "http://your-embed-server:3021/embed",
    "api_key": "dummy",
    "auth": null,
    "body": { "model": "$MODEL", "input": "$PROMPT" },
    "response": { "embedding": "data[0].embedding" }
  },
  "rerank": {
    "model": "bge-reranker-v2-m3",
    "url": "http://your-rerank-server:3021/rerank",
    "api_key": "dummy",
    "auth": null,
    "body": { "model": "$MODEL", "query": "$QUERY", "documents": "$DOCUMENTS" },
    "response": { "results": "results" }
  }
}
```

> **Note:** On an air-gapped machine, the LLM API URL must point to a model
> server reachable from that machine (e.g., a local LLM deployment like vLLM,
> Ollama, or an on-prem inference server). External cloud APIs like
> `api.deepseek.com` will not be reachable.

### Key fields to change

| Field | What to set |
|-------|-------------|
| `chat.api_key` | Your LLM API key |
| `chat.url` | LLM inference endpoint (must be reachable from air-gapped machine) |
| `chat.model` | Model name your inference server expects |
| `embed.url` | Embedding model endpoint (optional) |
| `rerank.url` | Reranker model endpoint (optional) |

---

## 3. `etc/conf/db_config.json` — PostgreSQL Config

Only needed if `server.conf` has `persistence_mode=postgresql`.

```json
{
  "host": "127.0.0.1",
  "port": "5432",
  "database": "orchestration_center",
  "user": "opena2a_t",
  "password": "your-password"
}
```

If using `persistence_mode=file` (default), you can ignore this file.

---

## 4. `etc/conf/server.properties` — TLS & Rate Limits

Defaults are fine for most deployments. Edit only if you have specific requirements.

```properties
# TLS versions
tls.version=TLSv1.3,TLSv1.2

# Cipher suites (OpenSSL format)
tls.cipher=TLS_AES_256_GCM_SHA384,...

# Connection limits
connection.max=500
connection.timeout=300

# Rate limiting per API (requests/sec, max concurrency)
flowcontrol.ratelimit.parse_pdf=50
flowcontrol.parallelism.parse_pdf=50
```

---

## 5. `etc/ssl/` — SSL Certificates

Only needed if `enable_https=true` in `server.conf`.

### Option A: Generate self-signed certs

```bash
python generate_selfsign_cert.py etc/ssl serverAuth
cd etc/ssl
cp server_RSA.cer server.cer
cp server_key_RSA.pem server_key.pem
cp server.cer trust.cer
echo -n "your-password" > cert_pwd
```

### Option B: Use your own certificates

Copy your certificate files:

```
etc/ssl/server.cer    ← Your server certificate
etc/ssl/server_key.pem ← Your private key (encrypted)
etc/ssl/trust.cer     ← Your CA trust store
etc/ssl/cert_pwd      ← Password for the private key (plaintext file)
```

Then update `server.conf` paths if your filenames differ.

---

## 6. `etc/conf/agent_credentials.json` — Agent Auth

Only needed if your A2A agents require authentication credentials.

Copy the template and edit:

```bash
cp etc/conf/agent_credentials.json.template etc/conf/agent_credentials.json
vi etc/conf/agent_credentials.json
```

---

## Verification Checklist

After editing configs, verify:

- [ ] `server.conf`: `ip` and `port` are correct for your network
- [ ] `server.conf`: `enable_https` matches your security requirements
- [ ] `llm_config.json`: `chat.api_key` and `chat.url` point to a reachable LLM
- [ ] `llm_config.json`: `chat.model` matches what your LLM server expects
- [ ] `db_config.json`: correct PostgreSQL credentials (if using postgresql mode)
- [ ] `etc/ssl/`: certificates present (if HTTPS enabled)
- [ ] `agent_registry_url`: points to a reachable registry center

### Test the configuration

```bash
# Start the backend
bin/start.sh

# Check if it's running
curl http://127.0.0.1:5001/rest/v1/orchestrate/auth/check

# (If HTTPS is enabled)
curl -k https://127.0.0.1:5001/rest/v1/orchestrate/auth/check
```

---

## Environment Variable Overrides

The `docker-entrypoint.sh` script shows the env-var-to-config-file bridge pattern.
You can use environment variables to override config file values at runtime:

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

This is useful if you want to keep config files as templates and inject secrets
via environment variables at deploy time.
