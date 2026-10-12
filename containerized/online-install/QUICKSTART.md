# OpenAN Online Container Quickstart

[中文](QUICKSTART.zh.md) · [Full deployment contract](../TRANSPORT_DEPLOYMENT.md)

## Migration / breaking change

The old install.sh is replaced by **one_click_install.sh**. Unauthenticated defaults, fixed machine Tokens,
unreviewed infrastructure downloads and inline secrets are not retained. Use compatible rebuilt images,
separate databases/prepared Secrets, migrate file data before Pod replacement, then log in again.
Old v1.0.0 images do not implement this contract.

## Helm-native production operations

Prepare Kubernetes, Helm, ingress/storage, SQL databases and model/credential/PKI references from the contract.
Copy [deployment.yaml.example](deployment.yaml.example), set all tags and non-secret fields:

```bash
helm lint openan-chart --namespace openan -f deployment.yaml
helm template openan openan-chart --namespace openan -f deployment.yaml > rendered.yaml
helm upgrade --install openan openan-chart --namespace openan --create-namespace -f deployment.yaml --wait --timeout 10m
```

Namespace must match values. Never put secrets in values/--set; if legacy inline fields were intentionally used,
rendered output may contain them, so protect it. Verify APIs at the actual public entrance, not only probes.

## Guided one-click phases

```bash
# Prepared images/infrastructure/Secrets; --values avoids every prompt.
bash one_click_install.sh --skip-build --skip-infra --values deployment.yaml --release openan --namespace openan

# Prepared images/infrastructure; guided external SQL + HTTP evaluation setup.
bash one_click_install.sh --skip-build --skip-infra --release openan --namespace openan
```

The wizard asks for separate SQL databases/users, existing models.yaml ConfigMaps, a signing Secret,
compatible image tag and public hostname. SQL/admin passwords are collected without echo.
Fresh Kubernetes Secrets are created through stdin. Service Token/HMAC/fingerprint keys and their digest
are never printed or placed in generated values. Only non-secret deployment.generated.json is written;
existing files/Secrets are never overwritten. After partial creation, reconcile objects and use --values for upgrades.
This guided HTTP profile is evaluation-only; use reviewed HTTPS values for confidential/production traffic.
It does not manufacture models or signing material.

For image building, omit --skip-build and provide --tag, --registry-release and --orchestration-release:
organization archive URLs at accepted revisions in the contract. Configure registry credentials first;
the build pushes images, and values must match their repositories/tags.
For infrastructure, omit --skip-infra and supply reviewed local --metallb-chart, --metallb-values,
--ingress-chart and --ingress-values. Helm uses those explicit packages; no guessed IP pool or automatic
OS/cluster reconfiguration. Verify cluster compatibility first. See --help.

## Verification and troubleshooting

With Python/PyYAML/pytest, Helm and Bash installed, run python -m pytest tests/ -q.
Missing tools explicitly skip related tests; render passes are not container/cluster passes.
CI separately builds the real Compose matrix. See [acceptance and troubleshooting](../TRANSPORT_DEPLOYMENT.md#acceptance-and-troubleshooting)
for auth/TLS/SQL/PVC and frontend diagnosis. Single-instance upgrades briefly interrupt service.
