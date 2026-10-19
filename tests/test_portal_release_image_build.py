#!/usr/bin/env python3
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
"""Portal release-image builder contract; controlled commands, not a live Docker test."""
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "containerized/build/portal/build-portal-image.sh"
DEPS = ROOT / "containerized/build/portal"
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")

# A buildx listing mixing a broken builder with a healthy one: the script must
# skip the errored node and pick the running docker-container builder.
BUILDX_LS = """\
NAME/NODE                DRIVER/ENDPOINT                STATUS   BUILDKIT   PLATFORMS
brokenbuilder*           docker-container
 \\_ brokenbuilder0       \\_ unix:///var/run/x.sock     error
goodbuilder              docker-container
 \\_ goodbuilder0         \\_ unix:///var/run/docker.sock running  v0.33.1   linux/amd64, linux/arm64
default                  docker
 \\_ default              \\_ default                     running  v0.13.2   linux/amd64, linux/arm64
"""


def _write(path, text):
    # newline="" keeps the shim LF-only on every platform without relying on
    # Path.write_text(newline=), which needs Python 3.10+.
    with open(path, "w", newline="\n") as fh:
        fh.write(text)


def _shim(tmp_path, build_rc=0):
    """PATH dir with docker/curl stubs; docker logs its calls, curl fails loudly."""
    shim = tmp_path / "bin"
    shim.mkdir()
    log = tmp_path / "docker-calls.txt"
    docker = shim / "docker"
    _write(docker, f"""#!/usr/bin/env bash
printf '%s\\n' "$*" >> "{log}"
case "$1" in
  info) exit 0 ;;
  buildx)
    case "$2" in
      version) exit 0 ;;
      ls) cat <<'EOF'
{BUILDX_LS}
EOF
          exit 0 ;;
      create) exit 0 ;;
      build) exit {build_rc} ;;
      imagetools) exit 0 ;;
    esac ;;
esac
exit 0
""")
    docker.chmod(0o755)
    curl = shim / "curl"
    _write(curl, "#!/usr/bin/env bash\necho 'unexpected curl call' >&2\nexit 99\n")
    curl.chmod(0o755)
    return shim, log


def _run(args, shim=None, env=None):
    if not BASH:
        pytest.skip("Bash unavailable")
    full_env = dict(os.environ)
    if env:
        full_env.update(env)
    if shim:
        # Prepend the stub dir to PATH; the real python3/tar/sha256sum stay
        # available from the ambient PATH.
        command = [BASH, "-c", 'export PATH="$1:$PATH"; shift; exec bash "$@"',
                   "test", str(shim), str(SCRIPT), *args]
    else:
        command = [BASH, str(SCRIPT), *args]
    return subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60, env=full_env)


def _payload(tmp_path, with_index=True):
    """Minimal release payload mirroring the published tarball layout."""
    src = tmp_path / "payload"
    (src / "assets").mkdir(parents=True)
    (src / "plugins" / "registry-center").mkdir(parents=True)
    (src / "assets" / "index-abc.js").write_text("//js\n")
    (src / "plugins" / "registry-center" / "plugin.manifest.json").write_text('{"id":"registry-center"}')
    if with_index:
        (src / "index.html").write_text("<!doctype html>\n")
    tarball = tmp_path / "openan-portal-dist.tar.gz"
    with tarfile.open(tarball, "w:gz") as tar:
        for item in sorted(src.rglob("*")):
            tar.add(item, arcname=str(item.relative_to(src)))
    return tarball


def test_help_exits_zero_without_docker():
    result = _run(["-h"])
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Usage:" in result.stdout
    assert "--platforms" not in result.stdout.split("Usage:")[0]


def test_unknown_option_fails():
    result = _run(["--nope"])
    assert result.returncode != 0
    assert "unknown option" in result.stdout + result.stderr


def test_dry_run_keeps_stdout_clean_and_plans_expected_command(tmp_path):
    shim, _ = _shim(tmp_path)
    result = _run(["-n"], shim=shim)
    assert result.returncode == 0, result.stderr
    # Diagnostics live on stderr so `$(...)` captures stay clean (cf. build.sh).
    assert result.stdout == "", result.stdout
    plan = result.stderr
    assert "would run: docker buildx build" in plan
    assert "--builder goodbuilder" in plan
    assert "linux/amd64,linux/arm64" in plan
    assert "--push" in plan


@pytest.mark.parametrize("platforms,expect_load", [("linux/arm64", True), ("linux/amd64,linux/arm64", False)])
def test_multiarch_requires_push(tmp_path, platforms, expect_load):
    shim, log = _shim(tmp_path)
    payload = _payload(tmp_path)
    result = _run([], shim=shim, env={
        "PLATFORMS": platforms,
        "PUSH": "0",
        "DIST_TARBALL": str(payload),
        "SKIP_CHECKSUM": "1",
    })
    if expect_load:
        assert result.returncode == 0, result.stderr
        calls = log.read_text()
        assert "--load" in calls and "--push" not in calls
    else:
        assert result.returncode != 0
        assert "must push" in result.stderr


def test_checksum_mismatch_fails_before_build(tmp_path):
    shim, log = _shim(tmp_path)
    payload = _payload(tmp_path)
    result = _run([], shim=shim, env={
        "TAG": "v1.0.0",            # pinned tag, hash will not match this payload
        "DIST_TARBALL": str(payload),
        "PLATFORMS": "linux/arm64",
        "PUSH": "0",
    })
    assert result.returncode != 0
    assert "checksum mismatch" in result.stderr
    assert "buildx build" not in log.read_text()


def test_missing_payload_index_fails(tmp_path):
    shim, _ = _shim(tmp_path)
    payload = _payload(tmp_path, with_index=False)
    result = _run([], shim=shim, env={
        "DIST_TARBALL": str(payload), "SKIP_CHECKSUM": "1",
        "PLATFORMS": "linux/arm64", "PUSH": "0",
    })
    assert result.returncode != 0
    assert "no index.html" in result.stderr


def test_missing_dependency_fails(tmp_path):
    shim, _ = _shim(tmp_path)
    payload = _payload(tmp_path)
    empty = tmp_path / "empty-deps"
    empty.mkdir()
    result = _run([], shim=shim, env={
        "DIST_TARBALL": str(payload), "SKIP_CHECKSUM": "1",
        "PLATFORMS": "linux/arm64", "PUSH": "0",
        "TEMPLATE_SRC": str(empty),
    })
    assert result.returncode != 0
    assert "missing dependency" in result.stderr


def test_build_failure_is_nonzero(tmp_path):
    shim, _ = _shim(tmp_path, build_rc=17)
    payload = _payload(tmp_path)
    result = _run([], shim=shim, env={
        "DIST_TARBALL": str(payload), "SKIP_CHECKSUM": "1",
        "PLATFORMS": "linux/arm64", "PUSH": "0",
    })
    assert result.returncode != 0
    assert "build failed" in result.stderr


def test_bundled_dependencies_are_present():
    for name in ("default.conf.template", "15-openan-backends.envsh"):
        assert (DEPS / name).is_file(), f"missing bundled dependency: {name}"
    assert "BACKEND_URL" in (DEPS / "15-openan-backends.envsh").read_text()
    assert "BACKEND_URL" in (DEPS / "default.conf.template").read_text()


def test_uppercase_registry_is_rejected_early():
    # Regression: `REGISTRY=ghcr.io/XunliYang` made buildx fail late with
    # "repository name must be lowercase". The script must fail fast instead.
    result = _run(["-n"], env={"REGISTRY": "ghcr.io/XunliYang", "TAG": "v1.0.0"})
    assert result.returncode != 0
    assert "must be lowercase" in result.stderr
    assert "would run" not in result.stderr
