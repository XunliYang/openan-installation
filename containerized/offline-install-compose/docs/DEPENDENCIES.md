# Offline single-host prerequisites

- Linux amd64/arm64 matching the bundle; Docker Engine with Compose v2.20+
  and Python 3.10+ standard library. No pip/Helm/cluster/registry is required
  on the offline target. Run the installer with root privileges for generated
  application data/log directory ownership (UID=10001).
- An unused configured public bind/port (default 0.0.0.0:8080), enough disk
  for images and persisted SQL/application data. Database/worker/model addresses
  must be reachable from the Docker bridge, not only from the host shell.
- External MySQL/PostgreSQL databases/users, or explicitly selected bundled
  MySQL/PostgreSQL; distinct databases for registry and orchestration.
- Two complete models.yaml files, two private environment files, authorized
  registry credentials and optional enterprise IAM connectivity. All secrets
  are operator-provisioned, absent from the release tarball.
- Signing key/certificate/password unless explicitly disabled; HTTP does not
  implicitly disable signature or authentication.
- HTTPS/mTLS CA, SAN, encrypted service-key and ownership contracts described
  in the [README](../README.md). Both local probes and proxy trust need material.

Bundle checksums are mandatory; failed/missing checksums block installation.
SHA256SUMS detects corruption, not authenticity: verify the release source or
an independently distributed signature/hash before trusting an imported bundle.
`check-env.sh` reports deterministic input prerequisites, not successful SQL,
IAM, model or business behavior. Installation waits for container health but
does not substitute for production integration acceptance.
