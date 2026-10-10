# OpenAN Helm Chart

See [HTTP/HTTPS and database deployment contract](../../TRANSPORT_DEPLOYMENT.md) for the current supported configuration, Secret schemas and migration requirements.

- Select SQL type with database.type; postgresql.enabled controls in-cluster hosting, not the application provider.
- Supply runtimeSecret, database credentials and model definitions explicitly. No shared default passwords.
- HTTP and HTTPS-no-mTLS retain application authentication. TLS, signing and peer verification are independent controls.
- Supply TLS Secrets created by enterprise PKI or the development certificate tool. Helm auto TLS keys are no longer supported.
- Signing auto preserves deployed keys during upgrade; production uses an explicit signing Secret.
- Models are mounted as a complete file. Existing model Secrets override inline values.
- OC uses one replica: sessions are not shared. Legacy vector-only RC mode cannot serve the complete SQL-backed API and is rejected.

```bash
helm lint . -f deployment.yaml
helm template openan . -f deployment.yaml
helm upgrade --install openan . -n openan --create-namespace -f deployment.yaml
```

Rebuild the matching service images before using this chart. Offline render/lint validates templates, not Secret contents or runtime/cluster behavior. Certificate Secret changes require a Pod rollout because file mounts use subPath.
