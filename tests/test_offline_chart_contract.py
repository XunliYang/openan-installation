# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Offline chart render contracts for the frontend type switch and portal wiring."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get("HELM_BIN") or shutil.which("helm")
CHART = ROOT / "containerized/offline-install/chart"
BASE = {"registry.image.tag": "contract", "orchestration.image.tag": "contract",
        "frontend.image.tag": "contract"}


def render(settings=None, success=True):
    if not HELM:
        pytest.skip("Set HELM_BIN to run real Helm render validation")
    # Render against the chart's declared minimum so the result does not
    # depend on the K8s version compiled into the local helm binary.
    command = [HELM, "template", "contract", str(CHART), "--namespace", "openan",
                "--kube-version", "1.33.0"]
    for key, value in {**BASE, **(settings or {})}.items():
        command += ["--set", f"{key}={str(value).lower() if isinstance(value, bool) else value}"]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=40)
    assert (result.returncode == 0) is success, result.stderr
    if not success:
        return result.stderr
    docs = {}
    for doc in yaml.safe_load_all(result.stdout):
        if doc:
            key = f"{doc['kind']}/{doc['metadata']['name']}"
            docs[key] = doc
    return docs


def test_frontend_defaults_to_portal():
    docs = render()
    deployment = docs["Deployment/openan-frontend"]
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    assert "openan-portal" in container["image"]
    assert container["ports"][0]["containerPort"] == 8080
    env = {e["name"]: e["value"] for e in container["env"]}
    assert env["BACKEND_URL"] == "http://orchestration-center:5001"
    assert env["REGISTRY_URL"] == "http://registry-center:5000"
    # portal renders no initContainer and no chart-managed nginx ConfigMap
    assert "initContainers" not in deployment["spec"]["template"]["spec"]
    assert "ConfigMap/openan-frontend-nginx-config" not in docs
    assert "Deployment/workflow-designer" not in docs
    assert "Service/workflow-designer" not in docs
    # Service keeps the stable external port, targets the container port
    service = docs["Service/openan-frontend"]
    assert service["spec"]["ports"][0]["port"] == 80
    assert service["spec"]["ports"][0]["targetPort"] == 8080


def test_ingress_routes_frontend_and_registry_api():
    docs = render()
    frontend = docs["Ingress/openan-frontend-ingress"]
    backend = frontend["spec"]["rules"][0]["http"]["paths"][0]["backend"]["service"]
    assert backend["name"] == "openan-frontend"
    assert backend["port"]["number"] == 80
    registry_ingress = docs["Ingress/openan-registry-ingress"]
    paths = {p["path"]: p["backend"]["service"] for p in registry_ingress["spec"]["rules"][0]["http"]["paths"]}
    assert paths["/api/registry(/|$)(.*)"]["name"] == "registry-center"
    assert paths["/api/registry(/|$)(.*)"]["port"]["number"] == 5000
    assert paths["/registry(/|$)(.*)"]["name"] == "registry-center"
    annotations = registry_ingress["metadata"]["annotations"]
    assert annotations["nginx.ingress.kubernetes.io/use-regex"] == "true"
    assert annotations["nginx.ingress.kubernetes.io/rewrite-target"] == "/$2"


def test_oc_admin_password_secret_injection():
    docs = render({"orchestration.admin.initialPassword": "pw-contract"})
    secret = docs["Secret/orchestration-center-admin"]
    assert secret["stringData"]["admin-password"] == "pw-contract"
    env = docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    entry = next(e for e in env if e["name"] == "OC_ADMIN_INITIAL_PASSWORD")
    assert entry["valueFrom"]["secretKeyRef"]["name"] == "orchestration-center-admin"
    assert entry["valueFrom"]["secretKeyRef"]["key"] == "admin-password"


def test_oc_admin_existing_secret_wins():
    docs = render({"orchestration.admin.existingSecret": "ops-admin",
                   "orchestration.admin.initialPassword": "pw-contract"})
    assert "Secret/orchestration-center-admin" not in docs
    env = docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    entry = next(e for e in env if e["name"] == "OC_ADMIN_INITIAL_PASSWORD")
    assert entry["valueFrom"]["secretKeyRef"]["name"] == "ops-admin"


def test_oc_admin_absent_when_unconfigured():
    docs = render()
    assert "Secret/orchestration-center-admin" not in docs
    env = docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    assert not any(e["name"] == "OC_ADMIN_INITIAL_PASSWORD" for e in env)


def test_frontend_workflow_designer_fallback():
    docs = render({"frontend.type": "workflow-designer"})
    deployment = docs["Deployment/openan-frontend"]
    spec = deployment["spec"]["template"]["spec"]
    assert "workflow-designer" in spec["containers"][0]["image"]
    assert spec["containers"][0]["ports"][0]["containerPort"] == 80
    assert "initContainers" in spec
    assert "ConfigMap/openan-frontend-nginx-config" in docs
    assert docs["Service/openan-frontend"]["spec"]["ports"][0]["targetPort"] == 80


def test_frontend_invalid_type_fails():
    error = render({"frontend.type": "bogus"}, success=False)
    assert "frontend.type must be" in error


def test_portal_envs_follow_https_switch():
    docs = render({"https.enabled": True})
    container = docs["Deployment/openan-frontend"]["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e["value"] for e in container["env"]}
    assert env["BACKEND_URL"] == "https://orchestration-center:5001"
    assert env["REGISTRY_URL"] == "https://registry-center:5000"


def test_models_yaml_mounted_for_both_services():
    docs = render({"registry.llm.chat.model": "m-chat", "registry.llm.chat.url": "http://llm/v1/chat/completions",
                   "registry.llm.embed.model": "m-embed", "registry.llm.embed.url": "http://llm/v1/embeddings",
                   "orchestration.llm.chat.model": "m-orch", "orchestration.llm.chat.url": "http://llm/v1/chat/completions"})
    rc_models = docs["ConfigMap/registry-center-models"]["data"]["models.yaml"]
    assert "model: m-chat" in rc_models
    assert "model: m-embed" in rc_models
    assert "api_key_env: LLM_CHAT_API_KEY" in rc_models
    assert "api_key_env: LLM_EMBED_API_KEY" in rc_models
    assert "apiKey" not in rc_models  # secrets never in the ConfigMap
    oc_models = docs["ConfigMap/orchestration-center-models"]["data"]["models.yaml"]
    assert yaml.safe_load(oc_models)["models"]["chat"]["model"] == "m-orch"
    assert "embed:" not in oc_models  # OC embed is opt-in (unset in this render)
    rc_spec = docs["Deployment/registry-center"]["spec"]["template"]["spec"]
    rc_mounts = rc_spec["containers"][0]["volumeMounts"]
    assert any(m["mountPath"] == "/opt/registry-center/etc/config/models.yaml" and m["subPath"] == "models.yaml" for m in rc_mounts)
    oc_spec = docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]
    oc_mounts = oc_spec["containers"][0]["volumeMounts"]
    assert any(m["mountPath"] == "/opt/orchestration-center/etc/config/models.yaml" and m["subPath"] == "models.yaml" for m in oc_mounts)
    oc_env = {e["name"]: e.get("value", "") for e in oc_spec["containers"][0]["env"]}
    assert oc_env["LLM_CONFIG_FILE"] == "/opt/orchestration-center/etc/config/models.yaml"


def test_orchestration_embed_rerank_llm_renders():
    # OC embed drives workflow semantic retrieval; rerank is optional.
    docs = render({"orchestration.llm.embed.model": "m-oc-embed",
                   "orchestration.llm.embed.url": "http://llm/v1/embeddings",
                   "orchestration.llm.embed.apiKey": "oc-embed-key",
                   "orchestration.llm.rerank.model": "m-oc-rerank",
                   "orchestration.llm.rerank.url": "http://llm/v1/rerank"})
    oc_models = docs["ConfigMap/orchestration-center-models"]["data"]["models.yaml"]
    oc_capabilities = yaml.safe_load(oc_models)["models"]
    assert oc_capabilities["embed"]["model"] == "m-oc-embed"
    assert oc_capabilities["embed"]["api_key_env"] == "LLM_EMBED_API_KEY"
    assert oc_capabilities["rerank"]["model"] == "m-oc-rerank"
    assert oc_capabilities["rerank"]["api_key_env"] == "LLM_RERANK_API_KEY"
    config = docs["ConfigMap/orchestration-center-config"]["data"]
    assert config["LLM_EMBED_MODEL"] == "m-oc-embed"
    assert config["LLM_RERANK_URL"] == "http://llm/v1/rerank"
    secret = docs["Secret/orchestration-center-secret"]["stringData"]
    assert secret["llm-embed-api-key"] == "oc-embed-key"
    assert "llm-rerank-api-key" not in secret  # no rerank apiKey set
    oc_env = {e["name"]: e.get("value", e.get("valueFrom", {}).get("secretKeyRef", {}).get("key", ""))
              for e in docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert oc_env["LLM_EMBED_API_KEY"] == "llm-embed-api-key"


def test_orchestration_verifies_registry_tls():
    docs = render({"https.enabled": True,
                   "orchestration.tls.mode": "secret", "orchestration.tls.existingSecret": "oc-tls",
                   "orchestration.clientVerifyServer": True,
                   "orchestration.registryClientSecret": "oc-registry-client"})
    config = docs["ConfigMap/orchestration-center-config"]["data"]
    assert config["ORCH_CLIENT_VERIFY_SERVER"] == "true"
    assert config["REGISTRY_CA_FILE"] == "/opt/orchestration-center/etc/registry_tls/trust.cer"
    assert "REGISTRY_CLIENT_CERT" not in config  # client cert only for registry mTLS
    spec = docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]
    volumes = {v["name"]: v for v in spec["volumes"]}
    assert volumes["registry-tls"]["secret"]["secretName"] == "oc-registry-client"
    mounts = [m["mountPath"] for m in spec["containers"][0]["volumeMounts"]]
    assert "/opt/orchestration-center/etc/registry_tls/trust.cer" in mounts
    # mTLS: client material mounted and env-pointed when the registry requires it
    # (https.verifyClient also makes the RC ingress require its client secret)
    mtls = render({"https.enabled": True, "https.verifyClient": True,
                   "registry.ingressClientSecret": "ingress-client",
                   "orchestration.registryClientSecret": "oc-registry-client",
                   "orchestration.clientVerifyServer": True})
    config = mtls["ConfigMap/orchestration-center-config"]["data"]
    assert config["REGISTRY_CLIENT_CERT"] == "/opt/orchestration-center/etc/registry_tls/client.cer"
    spec = mtls["Deployment/orchestration-center"]["spec"]["template"]["spec"]
    mounts = [m["mountPath"] for m in spec["containers"][0]["volumeMounts"]]
    assert "/opt/orchestration-center/etc/registry_tls/client_key.pem" in mounts
    # default render: verification off, no client material
    default = render()
    config = default["ConfigMap/orchestration-center-config"]["data"]
    assert config["ORCH_CLIENT_VERIFY_SERVER"] == "false"
    assert "REGISTRY_CA_FILE" not in config


def test_secret_volume_permissions_are_not_world_readable():
    # The registry-center service walks etc/ssl and rejects mounts whose
    # directory has world bits (a whole-directory secret mount creates a
    # kubelet-owned 0755 root — field crash). TLS/signing files must mount
    # per-key via subPath into the image's pre-created 0700 directories,
    # with defaultMode 0440 on the secret volume and fsGroup for ownership.
    docs = render({"https.enabled": True,
                   "registry.tls.mode": "secret", "registry.tls.existingSecret": "rc-tls",
                   "orchestration.tls.mode": "secret", "orchestration.tls.existingSecret": "oc-tls",
                   "orchestration.registryClientSecret": "oc-registry-client"})
    for deployment in ("Deployment/registry-center", "Deployment/orchestration-center"):
        spec = docs[deployment]["spec"]["template"]["spec"]
        assert spec["securityContext"]["fsGroup"] == 10001, deployment
        volumes = {v["name"]: v for v in spec["volumes"]}
        secret_volumes = [v for v in volumes.values() if "secret" in v]
        assert secret_volumes, deployment
        for volume in secret_volumes:
            assert volume["secret"]["defaultMode"] == 0o440, f"{deployment}/{volume['name']}"
    # RC TLS/signing files mount per-key (subPath) into the image directories
    rc = docs["Deployment/registry-center"]["spec"]["template"]["spec"]["containers"][0]
    mounts = rc["volumeMounts"]
    tls_paths = {m["mountPath"] for m in mounts if m.get("subPath") and "/etc/ssl/" in m["mountPath"]}
    assert tls_paths == {f"/opt/registry-center/etc/ssl/{k}"
                         for k in ("server.cer", "server_key.pem", "cert_pwd", "trust.cer")}
    signing_paths = {m["mountPath"] for m in mounts if m.get("subPath") and "/etc/sign_cert/" in m["mountPath"]}
    assert signing_paths == {f"/opt/registry-center/etc/sign_cert/{k}"
                             for k in ("sign.cer", "sign_key.pem", "cert_pwd")}
    # No whole-directory secret mounts remain on RC
    assert not any(m["mountPath"] == "/opt/registry-center/etc/ssl" and "subPath" not in m
                   for m in mounts)
    # OC TLS also mounts per-key (subPath) into the seeded emptyDir directory
    oc = docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]["containers"][0]
    oc_mounts = oc["volumeMounts"]
    oc_tls_paths = {m["mountPath"] for m in oc_mounts if m.get("subPath") and "/etc/ssl/" in m["mountPath"]}
    assert oc_tls_paths == {f"/opt/orchestration-center/etc/ssl/{k}"
                            for k in ("server.cer", "server_key.pem", "cert_pwd", "trust.cer")}
    # No whole-directory TLS mount on OC either
    assert not any(m["mountPath"] == "/opt/orchestration-center/etc/ssl" and "subPath" not in m
                   for m in oc_mounts)


def test_orchestration_runtime_pv_fallback_renders():
    # PR #31 added the runtime PVC; clusters without a StorageClass left it
    # Pending forever (field crash). The fallback mirrors the database
    # storage blocks: createPV + useHostPath + nodeName + storageClassName.
    docs = render({"orchestration.persistence.createPV": True,
                   "orchestration.persistence.useHostPath": True,
                   "orchestration.persistence.nodeName": "node185",
                   "orchestration.persistence.storageClassName": "openan-local"})
    pv = docs["PersistentVolume/openan-oc-runtime-pv"]
    assert pv["spec"]["hostPath"]["path"] == "/data/openan-orchestration-runtime"
    assert pv["spec"]["storageClassName"] == "openan-local"
    affinity = pv["spec"]["nodeAffinity"]["required"]["nodeSelectorTerms"][0]["matchExpressions"][0]
    assert affinity["values"] == ["node185"]
    pvc = docs["PersistentVolumeClaim/orchestration-center-runtime"]
    assert pvc["spec"]["storageClassName"] == "openan-local"
    # Default render: no PV created
    default = render()
    assert "PersistentVolume/openan-oc-runtime-pv" not in default


def test_installer_emits_orchestration_persistence():
    # The installer must set the runtime PVC storage from STORAGE_MODE,
    # matching the database fallback (field crash: PVC Pending, no SC).
    text = (ROOT / "containerized/offline-install/scripts/install.sh").read_text(encoding="utf-8")
    assert "createPV: true" in text
    assert "/data/openan-orchestration-runtime" in text
    # Appear in both the database section and the orchestration section
    assert text.count("createPV: true") >= 2


def test_installer_security_contract():
    # Security batch: strict mode, no default DB password, credentials only as
    # Secret references (never inlined into the generated values file).
    text = (ROOT / "containerized/offline-install/scripts/install.sh").read_text(encoding="utf-8")
    assert "set -euo pipefail" in text
    assert "openan-db-password" not in text
    assert "initialPassword" not in text
    assert "existingSecret: openan-db-credentials" in text
    assert "existingSecret: openan-admin" in text
    assert "create_secret_from_pairs" in text  # stdin JSON, never argv


def test_example_values_really_render():
    # The pure-Helm entry point documented in chart/README.md: the shipped
    # example must render and carry Secret references, not inline credentials.
    if not HELM:
        pytest.skip("Set HELM_BIN to run real Helm render validation")
    example = ROOT / "containerized/offline-install/example.values.yaml"
    result = subprocess.run([HELM, "template", "openan", str(CHART), "--namespace", "openan",
                             "--kube-version", "1.33.0", "-f", str(example)],
                            capture_output=True, text=True, encoding="utf-8", timeout=40)
    assert result.returncode == 0, result.stderr
    docs = list(yaml.safe_load_all(result.stdout))
    assert any(d and d.get("kind") == "Deployment" for d in docs)
    rendered = result.stdout
    assert "openan-rc-tls" in rendered and "openan-ingress-client" in rendered
    assert "proxy-ssl-verify" in rendered  # backend verification on
    text = example.read_text(encoding="utf-8")
    assert "initialPassword" not in text
    assert "apiKey:" not in text


def test_frontend_image_override_beats_type_default():
    docs = render({"frontend.image.repository": "harbor.local/openan/portal-custom",
                   "frontend.image.tag": "custom"})
    container = docs["Deployment/openan-frontend"]["spec"]["template"]["spec"]["containers"][0]
    assert container["image"] == "harbor.local/openan/portal-custom:custom"


def test_frontend_disabled_renders_nothing():
    docs = render({"frontend.enabled": False})
    for key in ("Deployment/openan-frontend", "Service/openan-frontend",
                "ConfigMap/openan-frontend-nginx-config", "Ingress/openan-frontend-ingress"):
        assert key not in docs
    assert "Ingress/openan-registry-ingress" in docs


def test_designer_initcontainer_follows_https_switch():
    docs = render({"frontend.type": "workflow-designer", "https.enabled": True})
    init = docs["Deployment/openan-frontend"]["spec"]["template"]["spec"]["initContainers"][0]
    env = {e["name"]: e["value"] for e in init["env"]}
    assert env["BACKEND_SCHEME"] == "https"


HTTPS_SETTINGS = {"https.enabled": True,
                  "registry.tls.mode": "secret", "registry.tls.existingSecret": "rc-tls",
                  "orchestration.tls.mode": "secret", "orchestration.tls.existingSecret": "oc-tls",
                  "ingress.backendVerifyServer": True,
                  "registry.ingressClientSecret": "ingress-client",
                  "orchestration.ingressClientSecret": "ingress-client"}


def test_ingress_verifies_https_backends():
    docs = render(HTTPS_SETTINGS)
    for name, service in [("Ingress/openan-registry-ingress", "registry-center"),
                          ("Ingress/openan-orchestration-ingress", "orchestration-center")]:
        annotations = docs[name]["metadata"]["annotations"]
        assert annotations["nginx.ingress.kubernetes.io/backend-protocol"] == "HTTPS"
        assert annotations["nginx.ingress.kubernetes.io/proxy-ssl-verify"] == "on"
        assert annotations["nginx.ingress.kubernetes.io/proxy-ssl-server-name"] == "true"
        assert annotations["nginx.ingress.kubernetes.io/proxy-ssl-name"] == service
        assert annotations["nginx.ingress.kubernetes.io/proxy-ssl-secret"] == "openan/ingress-client"
    # the frontend ingress backend stays plain HTTP: no verification there
    annotations = docs["Ingress/openan-frontend-ingress"]["metadata"]["annotations"]
    assert "nginx.ingress.kubernetes.io/proxy-ssl-verify" not in annotations


def test_https_without_backend_verify_keeps_verify_off():
    docs = render({"https.enabled": True})
    for name in ("Ingress/openan-registry-ingress", "Ingress/openan-orchestration-ingress"):
        annotations = docs[name]["metadata"]["annotations"]
        assert annotations["nginx.ingress.kubernetes.io/proxy-ssl-verify"] == "off"
        assert "nginx.ingress.kubernetes.io/proxy-ssl-secret" not in annotations


def test_backend_verify_requires_ingress_client_secret():
    error = render({"https.enabled": True, "ingress.backendVerifyServer": True}, success=False)
    assert "ingressClientSecret" in error


def test_https_backends_mount_operator_tls_secrets():
    docs = render(HTTPS_SETTINGS)
    for deployment, secret in [("Deployment/registry-center", "rc-tls"),
                               ("Deployment/orchestration-center", "oc-tls")]:
        volumes = {v["name"]: v for v in docs[deployment]["spec"]["template"]["spec"]["volumes"]}
        assert volumes["tls-certs"]["secret"]["secretName"] == secret


def test_gen_certs_tool_builds_a_verifiable_chain(tmp_path):
    openssl = shutil.which("openssl")
    if not openssl:
        pytest.skip("openssl unavailable")
    tool = ROOT / "containerized/offline-install/tool/gen_certs.py"
    out = tmp_path / "certs"
    command = [sys.executable, str(tool), "--out", str(out), "--namespace", "openan",
               "--ingress-host", "openan.test", "--ingress-ip", "192.0.2.10",
               "--ca-password", "ContractCA#2026"]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=180)
    assert result.returncode == 0, result.stderr
    for rel in ("ca/ca.cer", "ca/ca_key.pem", "ca/cert_pwd",
                "registry-center/server.cer", "registry-center/server_key.pem",
                "registry-center/trust.cer", "registry-center/cert_pwd",
                "orchestration-center/server.cer",
                "ingress/tls.crt", "ingress/tls.key",
                "ingress-client/tls.crt", "ingress-client/tls.key"):
        assert (out / rel).is_file(), rel
    for cert in ("registry-center/server.cer", "orchestration-center/server.cer",
                 "ingress/tls.crt", "ingress-client/tls.crt"):
        check = subprocess.run([openssl, "verify", "-CAfile", str(out / "ca" / "ca.cer"),
                                str(out / cert)], capture_output=True, text=True)
        assert check.returncode == 0, check.stderr
    text = subprocess.run([openssl, "x509", "-in", str(out / "registry-center" / "server.cer"),
                           "-noout", "-text"], capture_output=True, text=True).stdout
    assert "DNS:registry-center.openan.svc.cluster.local" in text
    assert "DNS:localhost" in text
    # app-consumed keys are encrypted; ingress keys stay plain for nginx
    app_key = (out / "registry-center" / "server_key.pem").read_text(encoding="utf-8")
    assert "ENCRYPTED PRIVATE KEY" in app_key or "DEK-Info" in app_key
    for plain_key in ("ingress/tls.key", "ingress-client/tls.key"):
        content = (out / plain_key).read_text(encoding="utf-8")
        assert "ENCRYPTED" not in content and "DEK-Info" not in content
    # re-runs never overwrite existing material
    rerun = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=180)
    assert rerun.returncode == 0, rerun.stderr
    assert "SKIPPED (exists)" in rerun.stdout
