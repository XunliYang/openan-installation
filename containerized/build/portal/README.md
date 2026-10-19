# OpenAN Portal Image Build (from release)

This builder produces the OpenAN Portal container image directly from the
published GitHub release artifact, for use by the online and offline install
lines.

## Why this exists

`containerized/build/build.sh portal` builds the portal from a **source**
archive using the repository's own `Dockerfile`. The portal release, however,
ships a **prebuilt static site** (`openan-portal-dist.tar.gz` =
`index.html` + `assets/` + `plugins/`) that already contains the compiled SPA
and all bundle plugins. Building from that artifact is:

- **Faster** — no `npm ci`, no Vite build, no per-plugin bundle build.
- **More faithful** — the image matches exactly what the release shipped.
- **More robust** — it does not depend on the portal repo's `Dockerfile`
  staying in sync. (At `v1.0.0` that Dockerfile's `COPY` paths
  `plugins/demo-showcase`, `plugins/hello-portal`, `plugins/registry-center`
  no longer exist in the tree, so a source build fails at the first step.)

## Layout

```
containerized/build/portal/
├── build-portal-image.sh        # the builder
├── default.conf.template        # nginx: API gateways + SPA fallback
├── 15-openan-backends.envsh     # composes BACKEND_URL / REGISTRY_URL
└── README.md                    # this document
```

The two nginx files are the image's only bundled dependencies. They are the
same files as the portal repo root; keep them in sync when the gateway
contract changes.

## Prerequisites

- Docker 20.10+ with `buildx`
- `curl`, `sha256sum`
- For multi-arch: QEMU binfmt

  ```bash
  docker run --privileged --rm tonistiigi/binfmt --install all
  ```

- For pushing: `docker login ghcr.io` (or your target registry)

## Usage

```bash
cd containerized/build/portal

# Default: build v1.0.0 for linux/amd64+linux/arm64 and push to
# ghcr.io/project-openan/openan-portal:v1.0.0
./build-portal-image.sh

# A different release / image tag
./build-portal-image.sh -t v1.0.1

# Local single-arch build, no push
PUSH=0 PLATFORMS=linux/arm64 ./build-portal-image.sh

# Print the plan without building
./build-portal-image.sh -n

# Help
./build-portal-image.sh -h
```

### Options

| Flag | Description |
|------|-------------|
| `-t <tag>` | Release tag and default image tag (default `v1.0.0`) |
| `-r <host/ns>` | Registry host + namespace (default `ghcr.io/project-openan`) |
| `-i <name>` | Image name (default `openan-portal`) |
| `-p <platforms>` | buildx platform list (default `linux/amd64,linux/arm64`) |
| `-n` | Dry run — print the plan, build nothing |
| `-h` | Help |

### Environment overrides

| Variable | Default | Purpose |
|----------|---------|---------|
| `TAG` | `v1.0.0` | Release tag and default image tag |
| `REGISTRY` | `ghcr.io/project-openan` | Registry host + namespace |
| `IMAGE_NAME` | `openan-portal` | Image name |
| `PLATFORMS` | `linux/amd64,linux/arm64` | Target platforms |
| `EXTRA_TAGS` | (empty) | Space-separated extra tags |
| `PUSH` | `1` | `1` = push manifest list, `0` = `--load` locally |
| `BUILDER` | auto | buildx builder name (first *running* docker-container) |
| `TEMPLATE_SRC` | script dir | Dir holding the two nginx files |
| `DIST_TARBALL` | (empty) | Use a local tarball instead of downloading |
| `SKIP_CHECKSUM` | `0` | `1` = skip sha256 verification |
| `KEEP_CTX` | `0` | `1` = keep the temporary build context |

## What the script does

1. Download `openan-portal-dist.tar.gz` for `TAG` from the GitHub release.
2. Verify its sha256 against the pinned value in the script.
3. Extract `index.html` + `assets/` + `plugins/` into a temp context.
4. Copy the two bundled nginx entrypoint files into the context.
5. Generate the Dockerfile inline (unprivileged nginx, port 8080).
6. Pick a running `docker-container` buildx builder (create one if none).
7. `docker buildx build` for `PLATFORMS`, push the manifest list unless `PUSH=0`.
8. Print the resulting image reference and manifest.

## Image contents

The image serves the release site with an unprivileged nginx (uid 101, port
8080). Plugins in the published `v1.0.0` release:

| Plugin | Kind | Enabled |
|--------|------|---------|
| execution-center | source (in main bundle) | yes |
| skill-center | source (in main bundle) | yes |
| registry-center | bundle `/plugins/registry-center` | yes |
| orchestration-center | bundle `/plugins/orchestration-center` | yes |
| ontology-demo | bundle `/plugins/ontology-demo` | no (opt-in) |

### Runtime configuration

The nginx gateway defaults target in-cluster service names, so the container
starts with zero configuration inside Kubernetes. Override at `docker run`:

```bash
docker run -p 8080:8080 \
  -e BACKEND_URL=http://orchestration-center:5001 \
  -e REGISTRY_URL=http://registry-center:5000 \
  ghcr.io/project-openan/openan-portal:v1.0.0
```

Component overrides (`BACKEND_HOST` / `BACKEND_PORT` / `BACKEND_SCHEME`,
`REGISTRY_*`) are also honoured by `15-openan-backends.envsh`.

## Pinned checksums

The release asset sha256 is pinned per tag inside the script (`DIST_SHA`). For a
new tag, add its value; unknown tags are built with verification skipped and a
warning.

| Tag | sha256 (`openan-portal-dist.tar.gz`) |
|-----|--------------------------------------|
| `v1.0.0` | `b43d943f45328ba8008dcb4d60d105e9e934e5737d040a6d8634986c0e04f9f5` |

## Multi-architecture notes

- Multi-arch images must be **pushed**; they cannot be `--load`ed locally.
- `--provenance=false --sbom=false` is passed so the manifest list contains only
  the two platform manifests (some registries/CI mishandle the extra
  `unknown/unknown` attestation entries).
- A `docker-container` builder is required. The script auto-selects the first
  *running* one and skips errored builders; it creates `openan-multiarch` if
  none exists.

## Relationship to `containerized/build/build.sh`

| | `build.sh portal` | `build-portal-image.sh` |
|---|---|---|
| Source | source archive (GitHub `archive/<ref>.tar.gz`) | release asset (`releases/download/<tag>`) |
| Needs Node | yes | no |
| Uses portal repo `Dockerfile` | yes | no (generated inline) |
| Bundle plugins | whatever source produces | all in the release |
| Stages | 2 (node build + nginx) | 1 (nginx) |

Both push `ghcr.io/<ns>/openan-portal:<tag>` and are interchangeable for
deployment; use this builder when you want the exact released artifact.

## Troubleshooting

- **`repository name must be lowercase`** — the registry path must be
  lowercase. `docker login ghcr.io -u MixedCase` is fine, but
  `ghcr.io/MixedCase/img` is rejected. Use `ghcr.io/mixedcase/img`.
- **`host not found in upstream "orchestration-center"`** — nginx resolved the
  default backend service name at startup and failed. Pass
  `-e BACKEND_URL=...` / `-e REGISTRY_URL=...` (the defaults assume in-cluster
  DNS).
- **`a manifest list cannot be --load'ed`** — set `PUSH=1` for multi-arch, or
  build a single platform with `-p linux/amd64` / `-p linux/arm64`.
- **checksum mismatch** — the release asset changed or you are using a tag
  whose hash is not pinned. Confirm the tag, or set `SKIP_CHECKSUM=1` if you
  have verified it another way.
