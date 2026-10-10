# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""Helm render contracts and controlled build failures; not a cluster smoke test."""
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get("HELM_BIN") or shutil.which("helm")
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")
CHART = ROOT / "containerized/online-install/openan-chart"
BASE = {"postgresql.existingSecret": "postgres-secret", "registry.runtimeSecret": "rc-runtime",
        "registry.credentialSecret": "rc-credentials", "orchestration.runtimeSecret": "oc-runtime",
        "registry.signing.mode": "off"}


def render(settings=None, success=True):
    if not HELM:
        pytest.skip("Set HELM_BIN to run real Helm render validation")
    command = [HELM, "template", "contract", str(CHART)]
    for key, value in {**BASE, **(settings or {})}.items():
        command += ["--set", f"{key}={str(value).lower() if isinstance(value, bool) else value}"]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", timeout=40)
    assert (result.returncode == 0) is success, result.stderr
    if not success:
        return result.stderr
    docs = {}
    for doc in yaml.safe_load_all(result.stdout):
        if doc:
            name = doc["metadata"]["name"]
            # A Service and Deployment can legally share a name.
            if name not in docs or doc["kind"] in {"Deployment", "StatefulSet"}:
                docs[name] = doc
    return docs


@pytest.mark.parametrize("protocol", ["http", "https"])
@pytest.mark.parametrize("db", ["mysql", "postgresql"])
def test_database_and_protocol_matrix(protocol, db):
    settings = {}
    if db == "mysql":
        settings.update({"database.type": "mysql", "postgresql.enabled": False, "database.host": "mysql.example",
                         "database.registry.existingSecret": "rc-db", "database.orchestration.existingSecret": "oc-db"})
    if protocol == "https":
        settings.update({"registry.tls.enabled": True, "registry.tls.existingSecret": "rc-tls",
                         "orchestration.tls.enabled": True, "orchestration.tls.existingSecret": "oc-tls",
                         "frontend.backendTls.existingSecret": "frontend-trust",
                         "orchestration.registryClientSecret": "oc-registry-trust",
                         "registry.ingressClientSecret": "rc-ingress-trust",
                         "orchestration.ingressClientSecret": "oc-ingress-trust"})
    docs = render(settings)
    for component, env in [("registry-center", "REGISTRY"), ("orchestration-center", "ORCH")]:
        conf = docs[component + "-config"]["data"]
        assert conf[env + "_ENABLE_HTTPS"] == str(protocol == "https").lower()
        assert conf[env + "_VERIFY_CLIENT"] == "false"
        assert conf["PERSISTENCE_MODE"] == db
        deployment = docs[component]["spec"]["template"]["spec"]
        assert deployment["securityContext"]["fsGroup"] == 10001
        container = deployment["containers"][0]
        assert "exec" in container["readinessProbe"]
        assert container["envFrom"][1]["secretRef"]["name"] in {"rc-runtime", "oc-runtime"}
        assert any(m["subPath"] == "models.yaml" for m in container["volumeMounts"] if "subPath" in m)
    assert docs["orchestration-center-config"]["data"]["AGENT_REGISTRY_URL"].startswith(protocol + "://")
    nginx = docs["workflow-designer-nginx-config"]["data"]["default.conf"]
    assert f"proxy_pass {protocol}://orchestration-center:5001" in nginx
    assert "proxy_set_header Connection \"\"" in nginx
    assert docs["openan-registry-ingress"]["metadata"]["annotations"][
        "nginx.ingress.kubernetes.io/backend-protocol"] == protocol.upper()
    if db == "mysql":
        assert "openan-postgres" not in docs
        assert docs["registry-center-config"]["data"]["DB_PORT"] == "3306"


def test_mtls_material_and_probes_are_wired():
    docs = render({"registry.tls.enabled": True, "registry.tls.verifyClient": True,
                   "registry.tls.existingSecret": "rc-tls", "registry.identityMode": "certificate",
                   "registry.ingressClientSecret": "rc-ingress-client",
                   "orchestration.tls.enabled": True, "orchestration.tls.verifyClient": True,
                   "orchestration.tls.existingSecret": "oc-tls", "orchestration.ingressClientSecret": "oc-ingress-client",
                   "orchestration.registryClientSecret": "oc-registry-client",
                   "frontend.backendTls.existingSecret": "frontend-client"})
    for comp, env in [("registry-center", "REGISTRY"), ("orchestration-center", "ORCH")]:
        assert "HEALTHCHECK_CLIENT_CERT" in " ".join(docs[comp + "-config"]["data"])
        mounts = docs[comp]["spec"]["template"]["spec"]["containers"][0]["volumeMounts"]
        assert any(m.get("subPath") == "probe-client.key" for m in mounts)
    assert docs["orchestration-center-config"]["data"]["REGISTRY_CLIENT_CERT"].endswith("client.cer")
    assert "proxy_ssl_certificate_key" in docs["workflow-designer-nginx-config"]["data"]["default.conf"]


@pytest.mark.parametrize("invalid,message", [
    ({"database.type": "mysql"}, "postgresql.enabled=false"),
    ({"registry.tls.verifyClient": True}, "requires HTTPS"),
    ({"registry.tls.enabled": True}, "requires tls.mode=secret"),
    ({"registry.runtimeSecret": ""}, "runtimeSecret is required"),
    ({"registry.identityMode": "certificate"}, "certificate identity requires"),
    ({"orchestration.replicas": 2}, "sessions are process-local"),
    ({"ingress.tls.enabled": True}, "requires ingress.host"),
    ({"registry.vectordb.enabled": True}, "no authoritative SQL record store"),
    ({"registry.extraEnv.REGISTRY_ENABLE_HTTPS": True}, "duplicates managed setting"),
    ({"orchestration.extraEnv.REGISTRY_CA_FILE": "/wrong"}, "duplicates managed setting"),
    ({"registry.llm.chat.provider": "aoc_signed"}, "use modelsConfigMap"),
    ({"database.registry.existingSecret": "different-password"}, "for external SQL only"),
])
def test_invalid_combinations_fail_before_install(invalid, message):
    assert message in render(invalid, success=False)


def test_signing_names_and_full_model_mount():
    docs = render({"registry.signing.mode": "auto"})
    assert set(docs["registry-center-signing"]["data"]) == {"sign.cer", "sign_key.pem", "cert_pwd"}
    models = yaml.safe_load(docs["registry-center-models"]["data"]["models.yaml"])
    assert set(models["models"]) == {"chat", "embed", "rerank"}


def test_existing_model_secret_wins_over_inline_key():
    docs = render({"registry.llm.chat.apiKey": "test-only-inline-value",
                   "registry.llm.chat.existingSecret": "preferred-model-secret"})
    env = docs["registry-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    entry = next(e for e in env if e["name"] == "LLM_CHAT_API_KEY")
    assert entry["valueFrom"]["secretKeyRef"]["name"] == "preferred-model-secret"


def test_model_and_proxy_updates_roll_out_pods():
    original = render()
    changed = render({"registry.llm.chat.model": "replacement-model",
                      "orchestration.llm.chat.model": "replacement-model",
                      "frontend.nginxConfig": "server { listen 80; }"})
    for component, checksum in [("registry-center", "checksum/models"),
                                ("orchestration-center", "checksum/models"),
                                ("workflow-designer", "checksum/nginx")]:
        before = original[component]["spec"]["template"]["metadata"]["annotations"][checksum]
        after = changed[component]["spec"]["template"]["metadata"]["annotations"][checksum]
        assert before != after


def test_external_full_model_config_accepts_custom_provider():
    docs = render({"registry.modelsConfigMap": "full-models",
                   "registry.llm.chat.provider": "aoc_signed"})
    assert "registry-center-models" not in docs
    volumes = docs["registry-center"]["spec"]["template"]["spec"]["volumes"]
    assert next(v for v in volumes if v["name"] == "models")["configMap"]["name"] == "full-models"


def test_internal_postgres_custom_port_is_used_by_server_and_probe():
    docs = render({"postgresql.port": 5544})
    container = docs["openan-postgres"]["spec"]["template"]["spec"]["containers"][0]
    assert container["args"] == ["-p", "5544"]
    assert container["readinessProbe"]["exec"]["command"][-2:] == ["-p", "5544"]
    assert docs["registry-center-config"]["data"]["DB_PORT"] == "5544"


@pytest.mark.parametrize("args,message", [
    (["--no-push"], "requires one platform"),
    (["--tag"], "requires a value"),
])
def test_invalid_build_flags_do_not_start_docker(args, message):
    if not BASH:
        pytest.skip("Bash unavailable")
    result = subprocess.run([BASH, str(ROOT / "containerized/build/build.sh"), *args],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode != 0
    assert message in result.stdout + result.stderr
    assert "Build completed" not in result.stdout


def test_build_failure_is_nonzero_and_does_not_report_success(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    source = tmp_path / "archive-source"
    source.mkdir()
    (source / "Dockerfile").write_text("FROM scratch\n")
    archive = tmp_path / "source.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(source, arcname="source")
    shim = tmp_path / "shim"
    shim.mkdir()
    docker = shim / "docker"
    docker.write_text('#!/usr/bin/env bash\nif [[ "$1 $2" == "buildx build" ]]; then exit 17; fi\nexit 0\n', newline="\n")
    docker.chmod(0o755)
    def shell_path(path):
        if os.name != "nt":
            return str(path)
        return subprocess.check_output([BASH, "-c", 'cygpath -u "$1"', "test", str(path)], text=True).strip()
    command = [BASH, "-c", 'export PATH="$1:$PATH"; shift; exec bash "$@"', "test", shell_path(shim),
               shell_path(ROOT / "containerized/build/build.sh"), "registry", "--platforms", "linux/amd64",
               "--no-push", "--registry-release", archive.as_uri()]
    result = subprocess.run(command, text=True, capture_output=True, timeout=30)
    assert result.returncode == 17, result.stdout + result.stderr
    assert "Build completed" not in result.stdout and "Done:" not in result.stdout
