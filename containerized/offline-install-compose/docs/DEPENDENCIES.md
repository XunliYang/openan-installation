# Offline dependencies — Docker Compose

The installer is deliberately split in two:

- **The bundle handles these for you** — no internet, no manual work.
- **You must provide these manually** — they are OS-level; the installer only
  *detects* and *reports* them.

`scripts/check-env.sh` checks everything below and prints the exact fix.

---

## 1. Handled automatically from the bundle

| Component | How |
|---|---|
| PostgreSQL 15 | `postgres:15-alpine` from `images/`, database init script applied on first start |
| nginx | `nginx:1.25-alpine` from `images/` |
| OpenAN app images | registry-center, orchestration-center loaded from `images/` |
| Frontend static files | extracted at build time into `web/`, served by nginx |
| compose networking | two `registry-center` and two `orchestration-center` containers behind an nginx upstream |

No registry is used: images are loaded with `docker load` and never pulled from
the internet.

---

## 2. You must provide manually

### 2.1 Docker Engine + Compose plugin

A recent Docker Engine (20.10+) with the **`docker compose` v2 plugin**. The
legacy `docker-compose` v1 binary is **not** supported.

```bash
docker --version
docker compose version
```

For a fully offline host, install Docker from the distribution packages you
carry in (RPM/DEB). Both `amd64` and `arm64` are supported.

### 2.2 Privileges

`scripts/install.sh` must be able to talk to the Docker daemon. Run it with
`sudo`, or as a user in the `docker` group.

### 2.3 Port 80

Port 80 must be free on the host — nginx binds it and it is the only exposed
entry point.

### 2.4 Disk space

Roughly 5 GiB for loaded images plus the PostgreSQL volume under `compose/data`.

### 2.5 An internal LLM endpoint

OpenAN needs a chat model at run time. In an air-gapped network this is normally
an **internal** LLM service (vLLM / MindIE / Ollama / an internal gateway):

```bash
REGISTRY_CHAT_MODEL / REGISTRY_CHAT_URL / REGISTRY_CHAT_APIKEY
ORCH_CHAT_MODEL     / ORCH_CHAT_URL     / ORCH_CHAT_APIKEY
```

LLM connectivity is **not validated** during the install.

---

## 3. Frequently missed

- The host architecture must match the image tars you extract
  (`uname -m` → `amd64` / `arm64`); `check-env.sh` verifies this.
- If a previous installation left containers running, `scripts/uninstall.sh`
  first, or re-run `install.sh` (it is idempotent).
- `AGENT_REGISTRY_URL` points at the internal nginx endpoint
  (`http://openan-nginx:5000`); do not change it unless you also change
  `compose/nginx.conf`.
