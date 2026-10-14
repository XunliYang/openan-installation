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
BASE = {"registry.image.tag": "contract", "orchestration.image.tag": "contract", "frontend.image.tag": "contract",
        "postgresql.existingSecret": "postgres-secret", "registry.runtimeSecret": "rc-runtime",
        "registry.credentialSecret": "rc-credentials", "orchestration.runtimeSecret": "oc-runtime",
        "registry.signing.mode": "off"}


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
    assert docs["orchestration-center-config"]["data"]["ORCH_EXTERNAL_AUTH_MODE"] == "user"
    nginx = docs["workflow-designer-nginx-config"]["data"]["default.conf"]
    assert f"proxy_pass {protocol}://orchestration-center:5001" in nginx
    assert "proxy_set_header Connection \"\"" in nginx
    assert "location ^~ /api/orchestrate/api/ { return 404; }" not in nginx
    assert nginx.count('proxy_set_header X-OpenAN-Browser-Gateway "1";') == 2
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
    assert docs["orchestration-center-config"]["data"]["ORCH_EXTERNAL_AUTH_MODE"] == "user"
    assert "proxy_ssl_certificate_key" in docs["workflow-designer-nginx-config"]["data"]["default.conf"]


@pytest.mark.parametrize("name", ["registry-center", "orchestration-center"])
def test_probe_timeout_seconds_default_is_10(name):
    # BUG-5: the exec healthchecks (Python startup + RSA3072 handshake) take
    # ~2.3s, beyond K8s's 1s default probe timeout; liveness killed the pod
    # before it ever became Ready. timeouts must default to 10, not 1.
    docs = render()
    container = docs[name]["spec"]["template"]["spec"]["containers"][0]
    for probe in ("livenessProbe", "readinessProbe"):
        assert container[probe]["timeoutSeconds"] == 10


@pytest.mark.parametrize("invalid,message", [
    ({"database.type": "mysql"}, "postgresql.enabled=false"),
    ({"registry.tls.verifyClient": True}, "requires HTTPS"),
    ({"registry.tls.enabled": True}, "requires tls.mode=secret"),
    ({"registry.runtimeSecret": ""}, "runtimeSecret is required"),
    ({"registry.identityMode": "certificate"}, "certificate identity requires"),
    ({"orchestration.replicas": 2}, "sessions are process-local"),
    ({"registry.replicas": 2}, "events and dispatchers are process-local"),
    ({"registry.replicas": 1.5}, "events and dispatchers are process-local"),
    ({"orchestration.replicas": 1.5}, "sessions are process-local"),
    ({"registry.persistence.size": ""}, "persistence.size is required"),
    ({"registry.persistence.existingClaim": "shared", "orchestration.persistence.existingClaim": "shared"}, "separate runtime claims"),
    ({"registry.persistence.existingClaim": "orchestration-center-runtime"}, "separate runtime claims"),
    ({"orchestration.persistence.existingClaim": "registry-center-runtime"}, "separate runtime claims"),
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


@pytest.mark.parametrize("verify_server", [False, True])
@pytest.mark.parametrize("mtls", [False, True])
def test_registry_trust_and_client_identity_are_independent(verify_server, mtls):
    docs = render({"registry.tls.enabled": True, "registry.tls.existingSecret": "rc-tls",
                   "registry.tls.verifyClient": mtls, "registry.ingressClientSecret": "ingress-client",
                   "orchestration.registryClientSecret": "registry-client",
                   "orchestration.clientVerifyServer": verify_server})
    env = docs["orchestration-center-config"]["data"]
    assert ("REGISTRY_CA_FILE" in env) is verify_server
    assert ("REGISTRY_CLIENT_CERT" in env) is mtls
    assert ("REGISTRY_CLIENT_KEY" in env) is mtls
    assert env["ORCH_CLIENT_VERIFY_SERVER"] == str(verify_server).lower()


@pytest.mark.parametrize("component,name", [("registry", "registry-center"), ("orchestration", "orchestration-center")])
def test_runtime_files_use_retained_pvc_and_nonoverlapping_rollout(component, name, tmp_path):
    docs = render()
    deployment = docs[name]
    assert deployment["spec"]["replicas"] == 1
    assert deployment["spec"]["strategy"] == {"type": "Recreate"}
    pod = deployment["spec"]["template"]["spec"]
    volume = next(v for v in pod["volumes"] if v["name"] == "runtime")
    assert volume["persistentVolumeClaim"]["claimName"] == name + "-runtime"
    mounts = {m["subPath"]: m["mountPath"] for m in pod["containers"][0]["volumeMounts"] if m["name"] == "runtime"}
    assert mounts == {"data": f"/opt/{name}/data", "log": f"/opt/{name}/log"}
    initializer = pod["initContainers"][0]
    assert initializer["image"] == pod["containers"][0]["image"]
    assert initializer["command"][:2] == ["python", "-c"]
    # Execute the rendered initializer against a controlled local volume root.
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    code = initializer["command"][2].replace("/runtime", runtime.as_posix())
    import sys
    subprocess.run([sys.executable, "-c", code], check=True, timeout=10)
    subprocess.run([sys.executable, "-c", code], check=True, timeout=10)
    assert (runtime / "data").is_dir() and (runtime / "log").is_dir()
    assert pod["securityContext"]["runAsUser"] == 10001
    assert initializer["securityContext"]["allowPrivilegeEscalation"] is False
    pvc = docs[name + "-runtime"]
    assert pvc["kind"] == "PersistentVolumeClaim"
    assert pvc["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
    assert pvc["spec"]["accessModes"] == ["ReadWriteOnce"]
    assert "storageClassName" not in pvc["spec"]
    assert pvc["spec"]["resources"]["requests"]["storage"]


def test_existing_runtime_claims_are_reused_without_creating_resources():
    docs = render({"registry.persistence.existingClaim": "retained-rc", "orchestration.persistence.existingClaim": "retained-oc"})
    for name, claim in [("registry-center", "retained-rc"), ("orchestration-center", "retained-oc")]:
        assert name + "-runtime" not in docs
        volumes = docs[name]["spec"]["template"]["spec"]["volumes"]
        assert next(v for v in volumes if v["name"] == "runtime")["persistentVolumeClaim"]["claimName"] == claim


@pytest.mark.parametrize("storage_class,expected", [("-", ""), ("fast", "fast")])
def test_runtime_storage_class_selection(storage_class, expected):
    docs = render({"registry.persistence.storageClassName": storage_class})
    assert docs["registry-center-runtime"]["spec"]["storageClassName"] == expected


def test_disabled_registry_has_no_runtime_claim_or_replica_guard():
    docs = render({"registry.enabled": False, "registry.replicas": 2})
    assert "registry-center-runtime" not in docs


def test_existing_model_secret_wins_over_inline_key():
    docs = render({"registry.llm.chat.apiKey": "test-only-inline-value",
                   "registry.llm.chat.existingSecret": "preferred-model-secret"})
    env = docs["registry-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    entry = next(e for e in env if e["name"] == "LLM_CHAT_API_KEY")
    assert entry["valueFrom"]["secretKeyRef"]["name"] == "preferred-model-secret"
    assert "llm-chat-api-key" not in (docs["registry-center-secret"]["stringData"] or {})


@pytest.mark.parametrize("capability", ["chat", "embed", "rerank"])
def test_orchestration_inline_model_secrets_match_environment_references(capability):
    docs = render({f"orchestration.llm.{capability}.model": "test-model",
                   f"orchestration.llm.{capability}.url": "https://example.invalid/model",
                   f"orchestration.llm.{capability}.apiKey": "synthetic-model-key"})
    env = docs["orchestration-center"]["spec"]["template"]["spec"]["containers"][0]["env"]
    ref = next(e for e in env if e["name"] == f"LLM_{capability.upper()}_API_KEY")["valueFrom"]["secretKeyRef"]
    assert docs[ref["name"]]["stringData"][ref["key"]] == "synthetic-model-key"


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
