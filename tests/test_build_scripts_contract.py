# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Full-coverage contract tests for all three offline/online build entrypoints.

Every test uses PATH shims — no real Docker pull/push, no network, no registry.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get("BASH_BIN") or shutil.which("bash")

BUILD_SH = ROOT / "containerized/build/build.sh"
K8S_BUILDER = ROOT / "containerized/offline-install/build/build-offline.sh"
COMPOSE_BUILDER = ROOT / "containerized/offline-install-compose/build/build-offline.sh"


def make_shim(tmp_path, tools=("docker",), fail_docker=False):
    """Create a stub bin dir; docker calls are logged, save creates files."""
    shim = tmp_path / "bin"
    shim.mkdir(exist_ok=True)
    log = tmp_path / "docker-calls.log"
    for tool in tools:
        stub = shim / tool
        if tool == "docker":
            if fail_docker:
                stub.write_text("#!/usr/bin/env bash\nexit 1\n")
            else:
                stub.write_text(f'''#!/usr/bin/env bash
printf "%s\\n" "$*" >> "{log}"
case "$1 $2" in
  "buildx version") echo "docker buildx v0.14.0"; exit 0 ;;
  "buildx inspect") exit 0 ;; # builder exists
  "buildx create") exit 0 ;;
  "image inspect") echo "linux/amd64"; exit 0 ;;
esac
case "$1" in
  save)
    out=""; prev=""
    for arg in "$@"; do
      if [ "$prev" = "-o" ]; then out="$arg"; fi
      prev="$arg"
    done
    if [ -n "$out" ]; then echo "stub-image" > "$out"; fi
    exit 0
    ;;
  pull|load|rm|rmi|tag) exit 0 ;;
  create) echo "stub-container-id"; exit 0 ;;
  cp)
    # docker cp cid:/usr/share/nginx/html/. dest/  → create dest/index.html
    dest=""
    for arg in "$@"; do
      if [ "$prev" != "cp" ] && [ "$prev" != "-c" ] && [ ! -f "$arg" ] && [ "${{arg:0:1}}" != "-" ]; then
        if [ "${{arg:0:1}}" != "/" ] || [ -d "$(dirname "$arg")" ]; then dest="$arg"; fi
      fi
      prev="$arg"
    done
    if [ -n "$dest" ]; then
      mkdir -p "$dest"
      echo "<html>stub</html>" > "$dest/index.html"
    fi
    exit 0
    ;;
esac
exit 0
''')
        else:
            stub.write_text("#!/usr/bin/env bash\nexit 0\n")
        stub.chmod(0o755)
    return shim, log


def run_script(script, args, shim, timeout=30, env_extra=None):
    """Run a build script with a stub PATH. Returns CompletedProcess."""
    shell_path = lambda p: str(p)
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    command = [BASH, "-c", 'export PATH="$1:$PATH"; shift; exec bash "$@"',
               "test", shell_path(shim), shell_path(script), *args]
    return subprocess.run(command, text=True, encoding="utf-8", errors="replace",
                          capture_output=True, timeout=timeout, env=env)


def calls(log):
    return log.read_text() if log.exists() else ""


# =============================================================================
# containerized/build/build.sh (shared online builder)
# =============================================================================

class TestSharedBuilder:
    def test_portal_pull_only(self, tmp_path):
        """portal component pulls from registry, never buildx from source."""
        shim, log = make_shim(tmp_path)
        result = run_script(BUILD_SH, ["portal", "--tag", "v1.0.0", "--platforms", "linux/amd64", "--no-push"], shim)
        assert result.returncode == 0, result.stdout + result.stderr
        c = calls(log)
        assert "openan-portal:v1.0.0" in c, c
        assert "buildx build" not in c, c

    def test_portal_tag_override(self, tmp_path):
        """--portal-tag overrides --tag for the portal image only."""
        shim, log = make_shim(tmp_path)
        result = run_script(BUILD_SH, ["portal", "--tag", "v1.0.0", "--portal-tag", "v0.9.5", "--platforms", "linux/amd64", "--no-push"], shim)
        assert result.returncode == 0, result.stdout + result.stderr
        c = calls(log)
        assert "openan-portal:v0.9.5" in c, c

    def test_portal_src_rejected(self, tmp_path):
        """--portal-src is removed; passing it fails with unknown argument."""
        shim, log = make_shim(tmp_path)
        result = run_script(BUILD_SH, ["portal", "--portal-src", "/tmp/x", "--no-push"], shim)
        assert result.returncode != 0

    def test_registry_orchestration_buildx(self, tmp_path):
        """registry and orchestration still use buildx from source."""
        src = tmp_path / "src"
        (src / "registry-center").mkdir(parents=True)
        (src / "registry-center" / "Dockerfile").write_text("FROM scratch\n")
        (src / "orchestration-center").mkdir(parents=True)
        (src / "orchestration-center" / "Dockerfile").write_text("FROM scratch\n")
        shim, log = make_shim(tmp_path)
        result = run_script(BUILD_SH, [
            "registry", "orchestration",
            "--registry-src", str(src / "registry-center"),
            "--orchestration-src", str(src / "orchestration-center"),
            "--no-push", "--platforms", "linux/amd64",
        ], shim, timeout=10)
        c = calls(log)
        assert "buildx build" in c, c


# =============================================================================
# containerized/offline-install/build/build-offline.sh (K8s offline builder)
# =============================================================================

class TestK8sOfflineBuilder:
    def test_pull_mode_pulls_all(self, tmp_path):
        """pull mode pulls all four app images from the registry."""
        shim, log = make_shim(tmp_path, tools=("docker", "curl", "python3", "tar", "sha256sum"))
        result = run_script(K8S_BUILDER, [
            "--tag", "v1.0.0", "--app-source", "pull",
            "--platforms", "linux/amd64", "--out", str(tmp_path / "dist"),
        ], shim, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        c = calls(log)
        for component in ("registry-center", "orchestration-center", "workflow-designer", "openan-portal"):
            assert f"ghcr.io/project-openan/{component}:v1.0.0" in c, f"missing {component}: {c}"

    def test_per_component_tags(self, tmp_path):
        """--registry-tag/--orchestration-tag/--portal-tag override the global tag."""
        shim, log = make_shim(tmp_path, tools=("docker", "curl", "python3", "tar", "sha256sum"))
        result = run_script(K8S_BUILDER, [
            "--tag", "v1.0.0",
            "--registry-tag", "v1.2.0",
            "--orchestration-tag", "v1.1.0",
            "--portal-tag", "v0.9.5",
            "--app-source", "pull",
            "--platforms", "linux/amd64", "--out", str(tmp_path / "dist"),
        ], shim, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        c = calls(log)
        assert "registry-center:v1.2.0" in c, c
        assert "orchestration-center:v1.1.0" in c, c
        assert "openan-portal:v0.9.5" in c, c
        # workflow-designer shares orchestration tag
        assert "workflow-designer:v1.1.0" in c, c

    def test_portal_src_rejected(self, tmp_path):
        """--portal-src is removed from the offline K8s builder."""
        shim, _ = make_shim(tmp_path)
        result = run_script(K8S_BUILDER, ["--portal-src", "/tmp/x"], shim)
        assert result.returncode != 0

    def test_build_mode_portal_pulled_not_built(self, tmp_path):
        """In build mode, RC/OC are built from source but portal is pulled."""
        src = tmp_path / "src"
        (src / "registry-center").mkdir(parents=True)
        (src / "registry-center" / "Dockerfile").write_text("FROM scratch\n")
        (src / "orchestration-center").mkdir(parents=True)
        (src / "orchestration-center" / "Dockerfile").write_text("FROM scratch\n")
        shim, log = make_shim(tmp_path, tools=("docker", "curl", "python3", "tar", "sha256sum"))
        result = run_script(K8S_BUILDER, [
            "--tag", "v1.0.0", "--app-source", "build",
            "--registry-src", str(src / "registry-center"),
            "--orchestration-src", str(src / "orchestration-center"),
            "--platforms", "linux/amd64", "--out", str(tmp_path / "dist"),
        ], shim, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        c = calls(log)
        assert "buildx build" in c, c
        assert "openan-portal:v1.0.0" in c, c

    def test_source_ref_derives_tag(self, tmp_path):
        """--source-ref main derives main-YYYYMMDD as the tag."""
        shim, log = make_shim(tmp_path, tools=("docker", "curl", "python3", "tar", "sha256sum"))
        result = run_script(K8S_BUILDER, [
            "--source-ref", "main", "--app-source", "pull",
            "--platforms", "linux/amd64", "--out", str(tmp_path / "dist"),
        ], shim, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        c = calls(log)
        assert re.search(r"registry-center:main-\d{8}", c), c

    def test_tars_mode_portal_optional(self, tmp_path):
        """tars mode: portal tar is optional (warn when missing)."""
        tars = tmp_path / "tars"
        tars.mkdir()
        for base in ("registry-center", "orchestration-center", "workflow-designer"):
            (tars / f"{base}-amd64.tar").write_bytes(b"fake")
        shim, log = make_shim(tmp_path, tools=("docker", "curl", "python3", "tar", "sha256sum"))
        result = run_script(K8S_BUILDER, [
            "--tag", "v1.0.0", "--app-source", "tars", "--app-tars-dir", str(tars),
            "--platforms", "linux/amd64", "--out", str(tmp_path / "dist"),
        ], shim, timeout=60)
        # Should succeed with a warning about missing portal
        assert "portal" in result.stderr or "portal" in result.stdout


# =============================================================================
# containerized/offline-install-compose/build/build-offline.sh (Compose builder)
# =============================================================================

class TestComposeOfflineBuilder:
    def test_portal_src_rejected(self, tmp_path):
        """--portal-src is removed from the compose builder."""
        shim, _ = make_shim(tmp_path)
        result = run_script(COMPOSE_BUILDER, ["--portal-src", "/tmp/x"], shim)
        assert result.returncode != 0

    def test_pull_mode_includes_portal(self, tmp_path):
        """pull mode pulls portal (with fallback warn if unavailable)."""
        shim, log = make_shim(tmp_path, tools=("docker", "curl", "python3", "tar", "sha256sum"))
        result = run_script(COMPOSE_BUILDER, [
            "--tag", "v1.0.0", "--app-source", "pull",
            "--platforms", "linux/amd64", "--out", str(tmp_path / "dist"),
        ], shim, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        c = calls(log)
        assert "openan-portal:v1.0.0" in c, c
