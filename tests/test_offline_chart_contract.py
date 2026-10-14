# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Offline chart render contracts for the frontend type switch and portal wiring."""
import os
from pathlib import Path
import shutil
import subprocess

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
    command = [HELM, "template", "contract", str(CHART), "--namespace", "openan"]
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
    assert "model: m-orch" in oc_models
    assert "embed:" not in oc_models  # OC values have no embed block
    rc_spec = docs["Deployment/registry-center"]["spec"]["template"]["spec"]
    rc_mounts = rc_spec["containers"][0]["volumeMounts"]
    assert any(m["mountPath"] == "/opt/registry-center/etc/config/models.yaml" and m["subPath"] == "models.yaml" for m in rc_mounts)
    oc_spec = docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]
    oc_mounts = oc_spec["containers"][0]["volumeMounts"]
    assert any(m["mountPath"] == "/opt/orchestration-center/etc/config/models.yaml" and m["subPath"] == "models.yaml" for m in oc_mounts)
    oc_env = {e["name"]: e.get("value", "") for e in oc_spec["containers"][0]["env"]}
    assert oc_env["LLM_CONFIG_FILE"] == "/opt/orchestration-center/etc/config/models.yaml"


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
