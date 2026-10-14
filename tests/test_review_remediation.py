# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Anchoring regressions for reviewed deployment contracts, not cluster acceptance."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess

import pytest
import yaml

from test_deployment_contract import BASH, CHART, ROOT, render


def external(db, port=None):
    settings = {"database.type": db, "postgresql.enabled": False, "database.host": "sql.example",
                "database.registry.existingSecret": "rc-db", "database.orchestration.existingSecret": "oc-db"}
    if port is not None:
        settings["database.port"] = port
    return settings


@pytest.mark.parametrize("db,port,expected", [
    ("postgresql", 5544, "5544"), ("postgresql", None, "5432"),
    ("mysql", 3344, "3344"), ("mysql", None, "3306"),
])
def test_external_port_is_consumed_by_both_services(db, port, expected):
    docs = render(external(db, port))
    for component in ("registry", "orchestration"):
        assert docs[component + "-center-config"]["data"]["DB_PORT"] == expected


def test_bundled_pg_uses_its_listener_not_external_port():
    docs = render({"postgresql.port": 5545, "database.port": 3344})
    assert docs["registry-center-config"]["data"]["DB_PORT"] == "5545"


@pytest.mark.parametrize("port", ["invalid", -1, 0, 65536, "12.5"])
def test_invalid_sql_port_fails_before_deployment(port):
    assert "SQL port" in render(external("postgresql", port), success=False)


def test_external_database_isolation_only_applies_to_enabled_services():
    settings = external("mysql")
    settings.update({"database.registry.name": "same_db", "database.orchestration.name": "same_db"})
    assert "separate external database names" in render(settings, success=False)
    render({**settings, "orchestration.enabled": False, "frontend.enabled": False})


def test_namespace_mismatch_is_rejected():
    assert "namespace must match" in render({"namespace": "another"}, success=False)


@pytest.mark.parametrize("component", ["registry", "orchestration", "frontend"])
def test_no_implicit_old_image_tag(component):
    assert "image.tag is required" in render({component + ".image.tag": ""}, success=False)


def test_probe_san_host_overrides_are_rendered():
    docs = render({"registry.extraEnv.REGISTRY_HEALTHCHECK_HOST": "registry-center",
                   "orchestration.extraEnv.ORCH_HEALTHCHECK_HOST": "orchestration-center"})
    assert docs["registry-center-config"]["data"]["REGISTRY_HEALTHCHECK_HOST"] == "registry-center"
    assert docs["orchestration-center-config"]["data"]["ORCH_HEALTHCHECK_HOST"] == "orchestration-center"
    # Avoid a bootstrap loop: Service endpoints don't exist until these probes pass.
    for component in ("registry", "orchestration"):
        spec = docs[component + "-center"]["spec"]["template"]["spec"]
        assert spec["hostAliases"] == [{"ip": "127.0.0.1", "hostnames": [component + "-center"]}]


def test_default_ip_probe_needs_no_dns_alias():
    docs = render()
    assert "hostAliases" not in docs["registry-center"]["spec"]["template"]["spec"]
    assert "hostAliases" not in docs["orchestration-center"]["spec"]["template"]["spec"]


@pytest.mark.parametrize("settings", [
    {"orchestration.extraEnv.ORCH_HEALTHCHECK_HOST": "registry-center"},
    {"registry.extraEnv.REGISTRY_HEALTHCHECK_HOST": "orchestration-center.openan.svc.cluster.local"},
    {"registry.extraEnv.REGISTRY_HEALTHCHECK_HOST": "openan-postgres"},
    {"orchestration.extraEnv.ORCH_HEALTHCHECK_HOST": "external.example",
     "orchestration.agentRegistryUrl": "https://external.example:8443"},
])
def test_probe_dns_alias_must_not_shadow_known_upstream(settings):
    assert "probe host must not shadow" in render(settings, success=False)


def test_public_example_really_renders():
    from test_deployment_contract import HELM
    if not HELM:
        pytest.skip("Set HELM_BIN")
    result = subprocess.run([HELM, "template", "openan", str(CHART), "--namespace", "openan",
                             "-f", str(ROOT / "containerized/online-install/deployment.yaml.example")],
                            capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    docs = list(yaml.safe_load_all(result.stdout))
    assert any(d and d.get("kind") == "PersistentVolumeClaim" for d in docs)


def wizard():
    path = ROOT / "containerized/online-install/configure.py"
    spec = importlib.util.spec_from_file_location("guided_config", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_wizard_secret_only_uses_stdin_and_sanitizes_errors(monkeypatch):
    module = wizard()
    calls = []
    def run(command, **kwargs):
        calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0 if len(calls) == 1 else 1, "", "canary-secret")
    monkeypatch.setattr(module.subprocess, "run", run)
    with pytest.raises(RuntimeError) as error:
        module.create_secret("openan", "runtime", {"password": "canary-secret"})
    assert "canary-secret" not in str(error.value)
    assert all("canary-secret" not in json.dumps(command) for command, _ in calls)
    document = json.loads(calls[-1][1]["input"])
    assert base64.b64decode(document["data"]["password"]) == b"canary-secret"


def test_wizard_never_overwrites_an_existing_secret(monkeypatch):
    module = wizard()
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, "secret/runtime\n", "")
    monkeypatch.setattr(module.subprocess, "run", run)
    with pytest.raises(RuntimeError):
        module.create_secret("openan", "runtime", {"password": "canary-secret"})
    assert len(calls) == 1


def test_wizard_generated_values_contain_references_not_credentials(tmp_path, monkeypatch):
    module = wizard()
    answers = iter(["tested", "mysql", "sql.example", "3306", "registry_db", "orch_db",
                    "registry_user", "orch_user", "rc-models", "oc-models", "signing", "openan.example"])
    monkeypatch.setattr(module, "ask", lambda _: next(answers))
    monkeypatch.setattr(module, "secret_input", lambda _: "SyntheticSecret9!")
    saved = {}
    monkeypatch.setattr(module, "create_secret", lambda ns, name, data: saved.update({name: data}))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 0, "{}", ""))
    output = tmp_path / "values.json"
    module.configure("openan", "openan", output)
    values = json.loads(output.read_text(encoding="utf-8"))
    assert "SyntheticSecret9!" not in output.read_text(encoding="utf-8")
    token = saved["openan-oc-runtime"]["REGISTRY_ACCESS_TOKEN"]
    assert token not in output.read_text(encoding="utf-8")
    assert "token_hash=" in saved["openan-rc-credentials"]["integration_credentials.conf"]
    assert values["database"]["registry"]["name"] != values["database"]["orchestration"]["name"]


def test_offline_k8s_entrypoints_are_not_sealed():
    # The offline Kubernetes line is maintained again; the legacy refusal
    # seals must stay out of both entrypoints.
    for script in ("containerized/offline-install/scripts/install.sh",
                   "containerized/offline-install/build/build-offline.sh"):
        text = Path(ROOT, script).read_text(encoding="utf-8")
        assert "Legacy offline Kubernetes installer is unsupported" not in text
        assert "refuse execution" not in text


def test_ci_uses_accepted_org_revisions():
    workflow = (ROOT / ".github/workflows/deployment-contract.yml").read_text(encoding="utf-8")
    assert "repository: project-openan/registry-center" in workflow
    assert "repository: project-openan/orchestration-center" in workflow
    assert "repository: Zhoujie628/" not in workflow


def test_frontend_cache_is_static_only():
    config = render()["workflow-designer-nginx-config"]["data"]["default.conf"]
    assert "gzip on;" in config and "gzip off;" in config
    assert 'location = /index.html' in config and '"no-store"' in config
    assert "^/assets/" in config and "immutable" in config
    assert 'add_header X-XSS-Protection' not in config


def test_guided_skip_phases_preserve_selected_release_namespace_and_fail_fast(tmp_path):
    if not BASH:
        pytest.skip("Set BASH_BIN")
    from test_offline_compose_contract import shell_path
    values = tmp_path / "deployment.yaml"
    values.write_text("namespace: team-a\n", encoding="utf-8")
    script = ROOT / "containerized/online-install/one_click_install.sh"
    # Exported functions are test-owned substitutes, never real cluster/build calls.
    shim = """
kubectl() { echo "KUBECTL:$*" >&2; }
helm() { echo "HELM:$*" >&2; }
python3() { echo "Unexpected wizard execution" >&2; return 99; }
export -f kubectl helm python3
bash "$@"
"""
    result = subprocess.run([BASH, "-c", shim, "test", shell_path(script),
                             "--skip-build", "--skip-infra", "--values", shell_path(values),
                             "--release", "custom", "--namespace", "team-a"],
                            capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0, result.stderr
    assert "HELM:upgrade --install custom" in result.stderr
    assert "--namespace team-a" in result.stderr
    assert "Unexpected wizard" not in result.stderr
    assert "metallb" not in result.stderr and "ingress-nginx" not in result.stderr
    failed = subprocess.run([BASH, "-c", shim, "test", shell_path(script), "--skip-build",
                             "--values", shell_path(values)], capture_output=True, text=True, encoding="utf-8")
    assert failed.returncode == 2
    assert "KUBECTL:" not in failed.stderr and "HELM:" not in failed.stderr


def test_wizard_rejects_missing_public_dependencies_before_secrets(tmp_path, monkeypatch):
    module = wizard()
    answers = iter(["tested", "mysql", "sql.example", "3306", "registry_db", "orch_db",
                    "registry_user", "orch_user", "rc-models", "oc-models", "signing", "openan.example"])
    monkeypatch.setattr(module, "ask", lambda _: next(answers))
    monkeypatch.setattr(module.subprocess, "run", lambda command, **kw: subprocess.CompletedProcess(command, 1, "", ""))
    monkeypatch.setattr(module, "secret_input", lambda _: pytest.fail("Must not collect secrets yet"))
    monkeypatch.setattr(module, "create_secret", lambda *args: pytest.fail("Must not create secrets yet"))
    with pytest.raises(ValueError, match="reference"):
        module.configure("openan", "openan", tmp_path / "values.json")


def test_compose_and_helm_static_asset_policy_agree():
    from test_offline_compose_contract import configure
    config = configure.nginx_config(False, [], Path("unused"))
    assert "gzip on;" in config and "^/assets/" in config
    assert "immutable" in config and "no-store" in config
    assert 'add_header X-XSS-Protection' not in config
