# OpenAN single-host offline Docker Compose

One registry center, one orchestration center and one Nginx public entry.
Application sessions, execution/runtime files and registry background jobs are
not claimed to be distributed; this installer does not advertise HA. External
MySQL (default) or PostgreSQL is supported. Bundled MySQL/PostgreSQL is optional
for a self-contained single-host stack.

## Build on an internet-connected Linux host

Use matching service revisions that contain the transport/authentication
contract in registry-center #80 and orchestration-center #158. Old v1.0.0
images are not certified. Build from the accepted revisions or the explicitly
reviewed PR source trees when those changes are not yet merged:

```bash
bash build/build-offline.sh --tag deployment-20261010 --app-source build \
  --registry-src /path/to/registry-center \
  --orchestration-src /path/to/orchestration-center \
  --platforms linux/amd64 --out /path/to/new-output
```

`--app-source pull` pulls matching published tags from `--app-registry`
(default ghcr.io/project-openan). `tars` loads files from `--app-tars-dir`;
their contained image refs must match that registry/tag. Every image is
inspected for the requested architecture and re-saved. Multi-architecture
builds require buildx/QEMU where appropriate; the default is amd64, not an
implicit two-architecture build. Image pull/build/save/load/extraction errors
stop the build without publishing a tarball. Existing output is not erased.

The bundle contains images, templates, scripts, frontend assets and
SHA256SUMS, but no operator config.env, runtime/, passwords, models, PKI or
data directories. Package both application sources only after their own
Docker secret-canary tests pass. The installer itself never pulls images.

## Prepare private configuration, then install

```bash
tar -xzf openan-offline-compose-deployment-20261010.tar.gz
cd openan-offline-compose-deployment-20261010
cp config.env.example config.env
# Copy templates into private registry.env, orchestration.env, two models.yaml
# files and integration_credentials.conf; fill all required values and paths.
chmod 600 config.env registry.env orchestration.env integration_credentials.conf
sudo scripts/check-env.sh --config config.env
sudo scripts/install.sh --config config.env
```

Python 3.10+ standard library and Docker Compose v2.20+ are required on the
offline host. Files are literal KEY=VALUE data, never sourced as shell code;
shell variables/commands are not expanded. Quote values containing spaces or
`#`. Dollar text in passwords is preserved through Compose interpolation.
There is no interactive secret collection and no unsafe --skip-check switch.

- Pre-create separate external SQL databases/users. Containers cannot use
  host 127.0.0.1 for a database on the host; use a reachable host address.
- For bundled MySQL, use DATABASE_TYPE=mysql / DATABASE_INTERNAL=true and set
  MYSQL_ROOT_PASSWORD plus both application passwords. The bundle includes
  mysql:8.4 and initializes separate users/databases on the first volume start.
- For bundled PG, use DATABASE_TYPE=postgresql / DATABASE_INTERNAL=true and
  set POSTGRES_PASSWORD plus both application passwords. Initialization runs
  only on an empty named volume; changing config does not rotate existing SQL
  credentials or migrate data.
- Model files mount read-only in full: chat/embed/rerank/custom authentication
  belong in those files; referenced secrets belong in each service's runtime
  env file. Managed deployment keys may not be overridden in these env files.
- Default registry authentication is static Bearer. Generate the credential
  digest with `python -m agent_registry.integration.token_digest` using the
  same HMAC key, and put its plaintext token only in OC's REGISTRY_ACCESS_TOKEN.
  The installer rejects an unprovisioned OC token. OAuth2 JWT/introspection
  can instead be configured through REGISTRY_AUTH_MODE and canonical service
  environment overrides. Browser callers still need their own authorized
  registry token; the proxy never injects a privileged token for them.
- OC_ADMIN_INITIAL_PASSWORD initializes the SQL user on first startup.
  Public OC APIs use the same account as web login: POST /api/v1/auth/token
  with JSON username/password, then send Authorization: Bearer <access_token>.
  Cookies alone do not authorize public APIs; TLS remains independent.
  Existing SQL passwords are not reset. Initial password changes revoke all
  sessions, so log in again before issuing API tokens.
- Registry signing remains independent of HTTPS. Default enabled signing
  requires sign.cer, sign_key.pem, cert_pwd. Explicitly disabling signing is
  possible, but signed-card consumers must be considered separately.

## HTTP, HTTPS and mTLS

PUBLIC_ENABLE_HTTPS, REGISTRY_ENABLE_HTTPS and ORCH_ENABLE_HTTPS are independent.
The generated Nginx proxy selects each backend protocol; OC's public cookie
scheme follows PUBLIC_ENABLE_HTTPS, not the OC backend protocol. Only Nginx's
chosen PUBLIC_BIND/PUBLIC_PORT is exposed, not application or SQL ports.
The bundled Nginx 1.27.5 uses Docker DNS with dynamic upstream resolution;
replacing application containers does not require restarting the public proxy.
During a restart/replacement requests can fail briefly while the application
starts and DNS refreshes. This single-host deployment is not zero-downtime HA.

Backend TLS bundles use server.cer / server_key.pem / cert_pwd / trust.cer.
Use repository certificate tools for development, enterprise CA material for
production; original encrypted service-key requirements remain in force.
Certificates must include backend DNS SANs registry-center and
orchestration-center for verified proxy/client requests, and the configured
HEALTHCHECK_HOST (default IP 127.0.0.1) for local probes. Probes always verify CA.

Public TLS uses server.cer / server_key.pem and optional cert_pwd in
PUBLIC_TLS_DIR; certificate SAN must match the browser address. Proxy/client
CA bundles live in separate REGISTRY_PROXY_TLS_DIR, ORCH_PROXY_TLS_DIR and
REGISTRY_CLIENT_TLS_DIR. With VERIFY_CLIENT=true, add client.cer/client_key.pem
to the corresponding proxy/client bundle, and unencrypted probe-client.cer /
probe-client.key to each service TLS bundle. An encrypted OC registry client
key requires REGISTRY_CLIENT_KEY_PASSWORD. Nginx can use bundle cert_pwd for
its encrypted upstream keys. Disabling upstream certificate validation via
BACKEND_VERIFY_SERVER=false or ORCH_CLIENT_VERIFY_SERVER=false is explicit,
does not remove mTLS material requirements and never disables Token identity.

Host PKI/model/credential files must be readable by application UID=10001
without world-readable private keys, e.g. root provisioning followed by
owner 10001 / directory 0700 / file 0600, or read-only group permissions that
meet service validators. The installer never changes source PKI ownership.
Nginx master reads its own private mounts as root. Do not grant world access
to fix a bind-mount permission error.

## Frontend

FRONTEND_TYPE selects the unified web entry: `portal` (default) or
`workflow-designer`. The portal container serves itself on 8080 and receives
only BACKEND_URL/REGISTRY_URL (scheme per backend TLS); its image comes from
the bundle manifest (deps/image-tags.json), never from operator config.
`workflow-designer` is the fallback: Nginx mounts the bundle's static web
directory and no portal container runs. The portal image is optional at build
time until it is published (openan-portal#11); when absent the build warns and
the bundle supports only FRONTEND_TYPE=workflow-designer.

## Runtime and lifecycle

The stdlib configure.py is the single composition root for this installer,
generating private runtime/compose.json and nginx.conf; Compose accepts JSON
as well as YAML. There is no second hand-maintained YAML/Nginx contract.
Generated JSON contains secrets (0600): do not print/upload it. check-env is
read-only; install validates it, verifies checksums, loads local images,
recreates the app/proxy containers and waits for health. Inspect deployment
readiness plus real public login, authorization, signatures and model/worker
calls before declaring production acceptance.

The container smoke matrix covers ten profiles, including public HTTPS with
plain backends and each RC/OC mixed protocol direction. It checks returned card
and workflow content, update read-back and deletion, not just status codes.
Replacement must change backend IPs without recreating the proxy, and retain
SQL records, PreFlow, sandbox reports/templates, solution packages and existing
audit bytes. File fixtures use real storage components, not model execution.
These are acceptance gates: only a successful run for the exact revisions
being released establishes coverage; render/unit tests are not Docker evidence.

```bash
sudo docker compose -f runtime/compose.json logs -f
sudo scripts/uninstall.sh
```

Uninstall stops/removes containers but retains SQL volumes, runtime files,
application data and source credentials. Reinstall preserves data. Backup
SQL and runtime/ before upgrading. Legacy compose/data/postgres deployments
require explicit backup/restore migration; never silently switch them to a
fresh named volume. Keep PROJECT_NAME stable. Rotate existing credentials
in the database/provider as well as configuration.

See [dependencies](docs/DEPENDENCIES.md). This path is independent of the
offline Kubernetes installer; its correctness is not certified by these tests.
