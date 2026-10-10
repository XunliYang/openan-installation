# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""Offline Compose regressions; controlled commands are not a live Docker test."""
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
OFFLINE = ROOT / "containerized/offline-install-compose"
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")
SPEC = importlib.util.spec_from_file_location("offline_configure", OFFLINE / "scripts/configure.py")
configure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure)


@pytest.fixture
def deployment(tmp_path):
    bundle = tmp_path / "bundle"
    (bundle / "deps").mkdir(parents=True)
    images = {name: f"contract/{name}:test" for name in ("registry-center", "orchestration-center", "workflow-designer", "nginx", "postgres", "mysql")}
    (bundle / "deps/image-tags.json").write_text(json.dumps({"architectures": ["amd64"], "images": images}))
    (bundle / "web").mkdir()
    (bundle / "web/index.html").write_text("synthetic frontend")
    (bundle / "compose/init").mkdir(parents=True)
    shutil.copyfile(OFFLINE / "compose/init/create-databases.sh", bundle / "compose/init/create-databases.sh")
    shutil.copyfile(OFFLINE / "compose/init/create-mysql-databases.sh", bundle / "compose/init/create-mysql-databases.sh")
    key, token = "synthetic-hmac-key", "synthetic-registry-token"
    (tmp_path / "registry.env").write_text(f"INTEGRATION_TOKEN_HMAC_KEY={key}\nINTEGRATION_FINGERPRINT_KEY=synthetic-fingerprint\n")
    (tmp_path / "orchestration.env").write_text(f"REGISTRY_ACCESS_TOKEN={token}\nOC_ADMIN_INITIAL_PASSWORD=synthetic-admin-password\nORCH_API_TOKEN={'x'*32}\n")
    digest = hmac.new(key.encode(), token.encode(), hashlib.sha256).hexdigest()
    (tmp_path / "credentials.conf").write_text(f"credential.oc.identity=orchestration\ncredential.oc.token_hash={digest}\ncredential.oc.role=partner_service\n")
    for name in ("registry-models.yaml", "orchestration-models.yaml"):
        (tmp_path / name).write_text("models: {chat: {provider: openai_compatible}, embed: {}, rerank: {}}\n")
    for role in ("registry", "orchestration", "public", "registry-proxy", "orch-proxy", "registry-client", "signing"):
        directory = tmp_path / role
        directory.mkdir()
        for name in ("server.cer", "server_key.pem", "cert_pwd", "trust.cer", "client.cer", "client_key.pem",
                     "probe-client.cer", "probe-client.key", "sign.cer", "sign_key.pem"):
            (directory / name).write_text("synthetic-material-not-a-real-certificate")
    config = {"DB_HOST": "mysql.example.invalid", "REGISTRY_DB_PASSWORD": "test-registry", "ORCH_DB_PASSWORD": "test-orch",
              "REGISTRY_CREDENTIAL_FILE": "credentials.conf", "REGISTRY_MODELS_FILE": "registry-models.yaml",
              "ORCH_MODELS_FILE": "orchestration-models.yaml", "REGISTRY_RUNTIME_ENV_FILE": "registry.env",
              "ORCH_RUNTIME_ENV_FILE": "orchestration.env", "REGISTRY_SIGN_DIR": "signing",
              "PUBLIC_TLS_DIR": "public", "REGISTRY_TLS_DIR": "registry", "ORCH_TLS_DIR": "orchestration",
              "REGISTRY_PROXY_TLS_DIR": "registry-proxy", "ORCH_PROXY_TLS_DIR": "orch-proxy", "REGISTRY_CLIENT_TLS_DIR": "registry-client"}
    config_file = tmp_path / "config.env"
    def generate(overrides=None):
        effective = {**config, **(overrides or {})}
        config_file.write_text("\n".join(f"{k}='{v}'" for k, v in effective.items()), encoding="utf-8")
        return configure.plan(config_file, bundle, "amd64")
    return tmp_path, bundle, config_file, generate


@pytest.mark.parametrize("db", ["mysql", "postgresql"])
@pytest.mark.parametrize("public_https", ["false", "true"])
@pytest.mark.parametrize("rc_https,oc_https", [("false", "false"), ("true", "true"), ("false", "true"), ("true", "false")])
def test_compose_database_and_three_protocol_matrix(deployment, db, public_https, rc_https, oc_https):
    _, _, _, generate = deployment
    compose, nginx = generate({"DATABASE_TYPE": db, "PUBLIC_ENABLE_HTTPS": public_https,
                               "REGISTRY_ENABLE_HTTPS": rc_https, "ORCH_ENABLE_HTTPS": oc_https})
    services = compose["services"]
    assert set(services) == {"registry-center", "orchestration-center", "openan-nginx"}
    for role, name, secure in [("REGISTRY", "registry-center", rc_https), ("ORCH", "orchestration-center", oc_https)]:
        service = services[name]
        assert service["pull_policy"] == "never"
        assert "ports" not in service
        assert service["environment"]["PERSISTENCE_MODE"] == db
        assert service["environment"][role + "_ENABLE_HTTPS"] == secure
        assert service["environment"][role + "_VERIFY_CLIENT"] == "false"
        assert any(m["target"].endswith("/models.yaml") for m in service["volumes"])
        assert "healthcheck" in service
    assert services["registry-center"]["environment"]["REGISTRY_OWNER_IDENTITY_MODE"] == "token"
    assert services["orchestration-center"]["environment"]["ORCH_PUBLIC_SCHEME"] == ("https" if public_https == "true" else "http")
    assert services["orchestration-center"]["environment"]["AGENT_REGISTRY_URL"].startswith("https" if rc_https == "true" else "http")
    assert f"proxy_pass {'https' if rc_https == 'true' else 'http'}://registry-center:5000/;" in nginx
    assert f"proxy_pass {'https' if oc_https == 'true' else 'http'}://orchestration-center:5001/;" in nginx
    assert 'proxy_set_header Connection "";' in nginx
    assert "ip_hash" not in nginx and "$request " not in nginx


def test_mtls_stays_authenticated_when_upstream_verification_is_off(deployment):
    _, _, _, generate = deployment
    compose, nginx = generate({"REGISTRY_ENABLE_HTTPS": "true", "ORCH_ENABLE_HTTPS": "true",
                               "REGISTRY_VERIFY_CLIENT": "true", "ORCH_VERIFY_CLIENT": "true",
                               "BACKEND_VERIFY_SERVER": "false", "ORCH_CLIENT_VERIFY_SERVER": "false"})
    for role, name in (("REGISTRY", "registry-center"), ("ORCH", "orchestration-center")):
        env = compose["services"][name]["environment"]
        assert env[role + "_HEALTHCHECK_CLIENT_CERT"].endswith("probe-client.cer")
    env = compose["services"]["orchestration-center"]["environment"]
    assert env["REGISTRY_CLIENT_KEY"].endswith("client_key.pem")
    assert env["ORCH_EXTERNAL_AUTH_MODE"] == "bearer"
    assert "proxy_ssl_certificate_key" in nginx and "proxy_ssl_verify off;" in nginx


@pytest.mark.parametrize("invalid,message", [
    ({"DATABASE_TYPE": "sqlite"}, "supports mysql/postgresql"),
    ({"REGISTRY_VERIFY_CLIENT": "true"}, "requires HTTPS"),
    ({"ORCH_ENABLE_HTTPS": "yes"}, "true or false"),
    ({"REGISTRY_DB_NAME": "orchestration_center"}, "distinct databases"),
    ({"PUBLIC_BIND": "0.0.0.0; echo unsafe"}, "decimal digits"),
    ({"REGISTRY_MODELS_FILE": "missing.yaml"}, "existing file"),
    ({"REGISTRY_ENABLE_HTTPS": "true", "REGISTRY_PROXY_TLS_DIR": ""}, "upstream CA verification"),
    ({"REGISTRY_ENABLE_HTTPS": "true", "REGISTRY_CLIENT_TLS_DIR": ""}, "registry TLS"),
    ({"REGISTRY_CHAT_APIKEY": "legacy"}, "Unknown deployment keys"),
])
def test_invalid_configs_fail_closed(deployment, invalid, message):
    with pytest.raises(ValueError, match=message):
        deployment[3](invalid)


def test_internal_postgres_and_quoted_credentials(deployment):
    _, _, _, generate = deployment
    compose, _ = generate({"DATABASE_TYPE": "postgresql", "DATABASE_INTERNAL": "true", "POSTGRES_PASSWORD": "test-root", "DB_PORT": "5544"})
    pg = compose["services"]["openan-postgres"]
    assert pg["command"] == ["postgres", "-p", "5544"]
    assert pg["healthcheck"]["test"][-1] == "5544"
    assert pg["environment"]["REGISTRY_DB_PASSWORD"] != pg["environment"]["ORCH_DB_PASSWORD"]
    init = (OFFLINE / "compose/init/create-databases.sh").read_text()
    assert ":'password'" in init and "<<'EOSQL'" in init
    assert "'${POSTGRES_PASSWORD}'" not in init


def test_internal_mysql_is_single_host_and_uses_authenticated_probe(deployment):
    compose, _ = deployment[3]({"DATABASE_INTERNAL": "true", "MYSQL_ROOT_PASSWORD": "test-root"})
    db = compose["services"]["openan-mysql"]
    assert "mysql-data:/var/lib/mysql" in db["volumes"]
    assert "MYSQL_ROOT_PASSWORD" in db["healthcheck"]["test"][-1]
    for service in ("registry-center", "orchestration-center"):
        assert compose["services"][service]["environment"]["DB_HOST"] == "openan-mysql"
    init = (OFFLINE / "compose/init/create-mysql-databases.sh").read_text()
    assert "NO_BACKSLASH_ESCAPES" in init
    assert 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD"' in init


def test_unprovisioned_token_or_managed_env_override_is_rejected(deployment):
    root, _, _, generate = deployment
    (root / "credentials.conf").write_text("# No credentials\n")
    with pytest.raises(ValueError, match="no enabled matching identity"):
        generate()
    with (root / "registry.env").open("a") as stream:
        stream.write("REGISTRY_ENABLE_HTTPS=true\n")
    with pytest.raises(ValueError, match="overrides managed keys"):
        generate()


@pytest.mark.parametrize("alias", ["POSTGRES_HOST", "REGISTRY_MYSQL_HOST", "ORCH_SSL_CERTFILE", "DATABASE_CONFIG_DIR"])
def test_runtime_aliases_cannot_bypass_managed_mounts(deployment, alias):
    root, _, _, generate = deployment
    with (root / "orchestration.env").open("a") as stream:
        stream.write(alias + "=unsafe-override\n")
    with pytest.raises(ValueError, match="overrides managed keys"):
        generate()


def test_config_is_literal_and_dollar_text_survives_compose(deployment):
    root, bundle, _, generate = deployment
    marker = root / "should-not-exist"
    env = root / "literal.env"
    env.write_text(f'TEST="$(touch {marker.as_posix()}) $HOME `id`"\n', encoding="utf-8")
    assert configure.read_env(env)["TEST"].startswith("$(touch ")
    assert not marker.exists()
    with (root / "orchestration.env").open("a") as stream:
        stream.write("EXTRA_LITERAL='price $5 ${NOT_EXPANDED} # text'\n")
    compose, nginx = generate()
    configure.write_plan(compose, nginx, bundle)
    generated = bundle / "runtime/compose.json"
    parsed = json.loads(generated.read_text(encoding="utf-8"))
    assert parsed["services"]["orchestration-center"]["environment"]["EXTRA_LITERAL"] == "price $$5 $${NOT_EXPANDED} # text"
    if os.name != "nt":
        assert generated.stat().st_mode & 0o777 == 0o600
    if shutil.which("docker"):
        # Real Compose's config parser requires no running containers or images.
        result = subprocess.run(["docker", "compose", "-f", str(generated), "config", "--format", "json"],
                                capture_output=True, encoding="utf-8", timeout=30, check=True)
        resolved = json.loads(result.stdout)
        # config re-escapes dollars for round-trip serialization; it is not the
        # container environment. The live smoke asserts the process value.
        assert resolved["services"]["orchestration-center"]["environment"]["EXTRA_LITERAL"] == "price $$5 $${NOT_EXPANDED} # text"


def test_legacy_data_and_project_identity_are_not_silently_replaced(deployment):
    _, bundle, _, generate = deployment
    compose, nginx = generate()
    configure.write_plan(compose, nginx, bundle)
    with pytest.raises(ValueError, match="PROJECT_NAME must remain stable"):
        generate({"PROJECT_NAME": "replacement"})
    legacy = bundle / "compose/data/postgres"
    legacy.mkdir(parents=True)
    (legacy / "PG_VERSION").write_text("15")
    with pytest.raises(ValueError, match="explicit backup/restore"):
        generate()


def test_failed_checksum_is_a_blocker_not_a_warning(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    bundle = tmp_path / "bundle"
    bundle.mkdir()
    (bundle / "payload").write_text("tampered")
    (bundle / "SHA256SUMS").write_text("0" * 64 + "  payload\n")
    result = subprocess.run([BASH, "-c", 'BUNDLE_DIR="$1"; ARCH=amd64; source "$2"; verify_bundle',
                             "test", shell_path(bundle), shell_path(OFFLINE / "scripts/lib/common.sh")],
                            encoding="utf-8", capture_output=True, timeout=10)
    assert result.returncode != 0 and "checksum FAILED" in result.stderr


@pytest.mark.parametrize("args", [["--tag"], ["--tag", ".."], ["--tag", "contract", "--platforms", "linux/ppc64le"]])
def test_invalid_build_arguments_do_not_publish(args, tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    result = subprocess.run([BASH, str(OFFLINE / "build/build-offline.sh"), *args],
                            encoding="utf-8", capture_output=True, timeout=10)
    assert result.returncode != 0
    assert "Done." not in result.stdout


@pytest.mark.parametrize("failure", ["", "save", "cp"])
def test_complete_bundle_is_allowlisted_and_extraction_failure_blocks_release(tmp_path, failure):
    if not BASH:
        pytest.skip("Bash unavailable")
    source = tmp_path / "source"
    shutil.copytree(OFFLINE, source, ignore=shutil.ignore_patterns("dist", "runtime", "__pycache__"))
    for name in ("config.env", "runtime/secret", "compose/data/private", "templates/operator.env"):
        private = source / name
        private.parent.mkdir(parents=True, exist_ok=True)
        private.write_text("OPERATOR_SECRET_CANARY_MUST_NOT_SHIP")
    shim = tmp_path / "shim"
    shim.mkdir()
    python_shim(shim)
    docker = shim / "docker"
    docker.write_text('''#!/usr/bin/env bash
set -e
if [[ "$1" == "$FAIL_STAGE" && -n "$FAIL_STAGE" ]]; then exit 19; fi
case "$1" in
  image) echo linux/amd64 ;;
  save) printf 'synthetic image' > "$3" ;;
  create) echo synthetic-container ;;
  cp) mkdir -p "$3"; printf '<html>synthetic frontend</html>' > "$3/index.html" ;;
esac
''', newline="\n")
    docker.chmod(0o755)
    out = tmp_path / "dist"
    result = subprocess.run([BASH, "-c", 'export PATH="$1:$PATH"; export FAIL_STAGE="$2"; shift 2; exec bash "$@"',
                             "test", shell_path(shim), failure, shell_path(source / "build/build-offline.sh"),
                             "--tag", "contract", "--out", shell_path(out)],
                            encoding="utf-8", capture_output=True, timeout=30)
    if failure:
        assert result.returncode == 19, result.stdout + result.stderr
        assert not list(out.glob("*.tar.gz"))
    else:
        assert result.returncode == 0, result.stdout + result.stderr
        bundle = out / "openan-offline-compose-contract"
        assert (bundle / "web/index.html").is_file()
        if os.name != "nt":
            for script in (bundle / "compose/init").glob("*.sh"):
                assert script.stat().st_mode & 0o777 == 0o755
        for file in bundle.rglob("*"):
            if file.is_file():
                assert b"OPERATOR_SECRET_CANARY_MUST_NOT_SHIP" not in file.read_bytes(), file
        assert not (bundle / "config.env").exists() and not (bundle / "runtime").exists()
        assert (out / "openan-offline-compose-contract.tar.gz").is_file()


def shell_path(path):
    if os.name != "nt":
        return str(path)
    return subprocess.check_output([BASH, "-c", 'cygpath -u "$1"', "test", str(path)], text=True).strip()


def python_shim(directory):
    """Git Bash need not provide python3; run the same interpreter as pytest."""
    if os.name == "nt":
        executable = directory / "python3"
        executable.write_text('#!/usr/bin/env bash\nexec ' + shlex.quote(shell_path(sys.executable)) + ' "$@"\n', newline="\n")
        executable.chmod(0o755)


def test_failed_image_pull_never_produces_offline_release(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    shim = tmp_path / "shim"
    shim.mkdir()
    python_shim(shim)
    docker = shim / "docker"
    docker.write_text('#!/usr/bin/env bash\nif [[ "$1" == pull ]]; then exit 17; fi\nexit 0\n', newline="\n")
    docker.chmod(0o755)
    out = tmp_path / "dist"
    result = subprocess.run([BASH, "-c", 'export PATH="$1:$PATH"; shift; exec bash "$@"', "test",
                             shell_path(shim), shell_path(OFFLINE / "build/build-offline.sh"),
                             "--tag", "contract", "--platforms", "linux/amd64", "--out", shell_path(out)],
                            text=True, encoding="utf-8", capture_output=True, timeout=30)
    assert result.returncode == 17, result.stdout + result.stderr
    assert not list(out.glob("*.tar.gz"))
    assert "Done." not in result.stdout


def test_uninstall_targets_generated_project_and_retains_volumes(tmp_path):
    if not BASH:
        pytest.skip("Bash unavailable")
    bundle = tmp_path / "bundle"
    (bundle / "runtime").mkdir(parents=True)
    (bundle / "runtime/compose.json").write_text(json.dumps({"name": "controlled-stack"}))
    shutil.copytree(OFFLINE / "scripts", bundle / "scripts")
    shim = tmp_path / "shim"
    shim.mkdir()
    python_shim(shim)
    docker = shim / "docker"
    docker.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n', newline="\n")
    docker.chmod(0o755)
    result = subprocess.run([BASH, "-c", 'export PATH="$1:$PATH"; export COMPOSE_PROJECT_NAME=unrelated-stack; exec bash "$2"',
                             "test", shell_path(shim), shell_path(bundle / "scripts/uninstall.sh")],
                            encoding="utf-8", capture_output=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    args = result.stdout.splitlines()
    assert args[:3] == ["compose", "--project-name", "controlled-stack"]
    assert "down" in args and "--volumes" not in args
    assert "unrelated-stack" not in args
    assert (bundle / "runtime/compose.json").exists()
