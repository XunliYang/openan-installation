# OpenAN Offline Installation (Docker Compose)

Fully offline single-host deployment of the OpenAN platform using
Docker Compose. This bundle is **independent of the Kubernetes installer** — it
contains no Helm chart and no cluster prerequisites.

## Topology

| Container | Count | Role |
|---|---|---|
| `nginx` | 1 | public entry on port 80; serves the frontend static files and proxies `/registry` and `/api/orchestrate` |
| `registry-center` | **2** | behind the nginx upstream |
| `orchestration-center` | **2** | behind the nginx upstream |
| `postgres` | 1 | shared database, volume under `compose/data` |

No private registry is used: images are loaded locally with `docker load`.

## Build the bundle (internet-connected machine)

Requires Linux + Docker.

```bash
cd build
./build-offline.sh --tag v1.0.0 --app-source pull
```

| `--app-source` | meaning |
|---|---|
| `pull` | `docker pull` the app images from `--app-registry` (default `ghcr.io/project-openan`) |
| `build` | build them from local source (`--registry-src`, `--orchestration-src`) |
| `tars` | reuse pre-built tars (`--app-tars-dir`) |

`postgres:15-alpine` and `nginx:1.25-alpine` are always pulled. The frontend
static files are extracted from the `workflow-designer` image into `web/`.

Each image ships as one tar per architecture:

```
images/registry-center-amd64.tar   images/registry-center-arm64.tar
images/... postgres-15-alpine-* nginx-1-25-alpine-* ...
```

## Install on the offline host

```bash
tar -xzf openan-offline-compose-v1.0.0.tar.gz
cd openan-offline-compose-v1.0.0
cp config.env.example config.env
vi config.env

scripts/check-env.sh --config config.env
sudo scripts/install.sh --config config.env
```

Run `install.sh` without arguments for an interactive prompt; it writes
`config.env` back for repeat runs.

## Re-running and uninstalling

- `docker load` is idempotent, so `install.sh` can be re-run safely; it rewrites
  `compose/.env` and re-applies `docker compose up -d`.
- `scripts/uninstall.sh` stops and removes the containers, then asks whether to
  delete `compose/data`. Images are left in place.

## Layout

```
offline-install-compose/
├── compose/          docker-compose.yml, nginx.conf, init/create-databases.sh
├── build/            build-offline.sh (runs on the internet build machine)
├── scripts/          check-env.sh, install.sh, uninstall.sh, lib/common.sh
├── docs/             DEPENDENCIES.md
├── config.env.example
└── README.md
```

See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for what you must provide
manually (Docker, port 80, disk, and an internal LLM endpoint).
