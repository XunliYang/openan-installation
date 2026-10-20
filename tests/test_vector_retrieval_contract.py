# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Vector deployment contracts: real Helm render, no cluster/model dependency."""
import pytest
import yaml

from test_deployment_contract import render as online
from test_offline_chart_contract import render as offline

EXPECTED = {"RETRIEVAL_VECTOR_ENABLED": "false", "RETRIEVAL_VECTOR_TOP_K": "5",
            "RETRIEVAL_VECTOR_MIN_SCORE": "0", "RETRIEVAL_VECTOR_RERANK": "false",
            "RETRIEVAL_VECTOR_LLM_FINAL": "true", "RETRIEVAL_VECTOR_STRICT": "false",
            "RETRIEVAL_VECTOR_INDEX_FILE": "data/vector_index/psop_vectors.json",
            "RETRIEVAL_LLM_THINKING": "true"}


def resources(renderer, settings=None, success=True):
    docs = renderer(settings, success=success)
    if not success:
        return docs
    return {key: value for key, value in docs.items() if "/" in key}


@pytest.mark.parametrize("renderer", [online, offline])
def test_default_retrieval_is_off_and_all_knobs_have_matching_defaults(renderer):
    docs = resources(renderer)
    conf = docs["ConfigMap/orchestration-center-config"]["data"]
    assert {key: conf[key] for key in EXPECTED} == EXPECTED
    models = yaml.safe_load(docs["ConfigMap/orchestration-center-models"]["data"]["models.yaml"])
    assert set(models["models"]) == {"chat"}


@pytest.mark.parametrize("renderer", [online, offline])
@pytest.mark.parametrize("capability", ["embed", "rerank"])
@pytest.mark.parametrize("secret", ["inline", "existing", "keyless"])
def test_optional_models_have_complete_secret_to_pod_chain(renderer, capability, secret):
    prefix = f"orchestration.llm.{capability}"
    settings = {f"{prefix}.model": "123", f"{prefix}.url": "https://example.invalid/model"}
    if secret == "inline":
        settings[f"{prefix}.apiKey"] = "synthetic-model-secret"
    elif secret == "existing":
        settings.update({f"{prefix}.existingSecret": "operator-model", f"{prefix}.existingSecretKey": "key"})
    else:
        settings[f"{prefix}.keyless"] = True
    docs = resources(renderer, settings)
    models = yaml.safe_load(docs["ConfigMap/orchestration-center-models"]["data"]["models.yaml"])
    assert models["models"][capability]["model"] == "123"
    assert "synthetic-model-secret" not in docs["ConfigMap/orchestration-center-models"]["data"]["models.yaml"]
    env = {e["name"]: e for e in docs["Deployment/orchestration-center"]["spec"]["template"]["spec"]["containers"][0]["env"]}
    name = "LLM_" + capability.upper() + "_API_KEY"
    if secret == "keyless":
        assert "api_key_env" not in models["models"][capability]
        assert name not in env
    else:
        assert models["models"][capability]["api_key_env"] == name
        ref = env[name]["valueFrom"]["secretKeyRef"]
        if secret == "existing":
            assert ref == {"name": "operator-model", "key": "key"}
        else:
            assert docs["Secret/" + ref["name"]]["stringData"][ref["key"]] == "synthetic-model-secret"


@pytest.mark.parametrize("renderer", [online, offline])
def test_vector_enable_requires_embed_model_or_external_model_file(renderer):
    error = resources(renderer, {"orchestration.retrieval.vector.enabled": True}, success=False)
    assert "embed" in error
    docs = resources(renderer, {"orchestration.retrieval.vector.enabled": True,
                                "orchestration.modelsConfigMap": "operator-models"})
    assert "ConfigMap/orchestration-center-models" not in docs


@pytest.mark.parametrize("renderer", [online, offline])
def test_custom_retrieval_policy_is_rendered(renderer):
    settings = {"orchestration.modelsConfigMap": "operator-models",
                "orchestration.retrieval.vector.enabled": True, "orchestration.retrieval.vector.topK": 8,
                "orchestration.retrieval.vector.minScore": 0.25, "orchestration.retrieval.vector.rerank": True,
                "orchestration.retrieval.vector.llmFinal": False, "orchestration.retrieval.vector.strict": True,
                "orchestration.retrieval.vector.indexFile": "data/vector_index/custom.json",
                "orchestration.retrieval.llm.thinking": False}
    conf = resources(renderer, settings)["ConfigMap/orchestration-center-config"]["data"]
    assert conf["RETRIEVAL_VECTOR_ENABLED"] == "true"
    assert conf["RETRIEVAL_VECTOR_TOP_K"] == "8"
    assert conf["RETRIEVAL_VECTOR_MIN_SCORE"] == "0.25"
    assert conf["RETRIEVAL_VECTOR_RERANK"] == "true"
    assert conf["RETRIEVAL_VECTOR_LLM_FINAL"] == "false"
    assert conf["RETRIEVAL_LLM_THINKING"] == "false"


def test_offline_index_uses_retained_writable_single_writer_volume():
    docs = resources(offline)
    pvc = docs["PersistentVolumeClaim/orchestration-center-runtime"]
    assert pvc["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
    deployment = docs["Deployment/orchestration-center"]
    assert deployment["spec"]["strategy"] == {"type": "Recreate"}
    assert deployment["spec"]["replicas"] == 1
    pod = deployment["spec"]["template"]["spec"]
    assert pod["securityContext"]["fsGroup"] == 10001
    assert any(m["mountPath"] == "/opt/orchestration-center/data" for m in pod["containers"][0]["volumeMounts"])
    reused = resources(offline, {"orchestration.persistence.existingClaim": "retained-oc"})
    assert "PersistentVolumeClaim/orchestration-center-runtime" not in reused
