#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# SPDX-License-Identifier: Apache-2.0
# Build a clean offline bundle; credentials/runtime data are never copied.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG=""; APP_REGISTRY="ghcr.io/project-openan"; APP_SOURCE="pull"
REGISTRY_SRC=""; ORCHESTRATION_SRC=""; APP_TARS_DIR=""
PLATFORMS="linux/amd64"; OUT_DIR="$SCRIPT_DIR/dist"
while [ $# -gt 0 ]; do
    if [[ "$1" == --* && "$1" != --help ]] && { [ $# -lt 2 ] || [[ "$2" == --* ]] || [ -z "$2" ]; }; then
        echo "$1 requires a value" >&2; exit 2
    fi
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --app-registry) APP_REGISTRY="$2"; shift 2 ;;
        --app-source) APP_SOURCE="$2"; shift 2 ;;
        --registry-src) REGISTRY_SRC="$2"; shift 2 ;;
        --orchestration-src) ORCHESTRATION_SRC="$2"; shift 2 ;;
        --app-tars-dir) APP_TARS_DIR="$2"; shift 2 ;;
        --platforms) PLATFORMS="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --help|-h) echo 'Use --tag <release> --app-source pull|build|tars [--platforms linux/amd64,linux/arm64] [--out <dir>]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo 'Explicit valid --tag required' >&2; exit 2; }
[[ "$APP_REGISTRY" =~ ^[A-Za-z0-9][A-Za-z0-9./:_-]*$ ]] || { echo 'Invalid app registry' >&2; exit 2; }
[[ "$APP_SOURCE" == pull || "$APP_SOURCE" == build || "$APP_SOURCE" == tars ]] || { echo 'Invalid app source' >&2; exit 2; }
ARCHS=()
for platform in ${PLATFORMS//,/ }; do
    [[ "$platform" == linux/amd64 || "$platform" == linux/arm64 ]] || { echo 'Only linux/amd64 and linux/arm64 supported' >&2; exit 2; }
    for previous in "${ARCHS[@]}"; do [ "${platform#linux/}" != "$previous" ] || { echo 'Duplicate architecture' >&2; exit 2; }; done
    ARCHS+=("${platform#linux/}")
done
[ "${#ARCHS[@]}" -gt 0 ] || exit 2
for tool in docker python3 tar sha256sum; do command -v "$tool" >/dev/null || { echo "$tool required" >&2; exit 1; }; done
if [ "$APP_SOURCE" == build ]; then
    [ -n "$REGISTRY_SRC" ] && [ -n "$ORCHESTRATION_SRC" ] || { echo 'Both source paths required' >&2; exit 2; }
    REGISTRY_SRC="$(cd "$REGISTRY_SRC" && pwd)"
    ORCHESTRATION_SRC="$(cd "$ORCHESTRATION_SRC" && pwd)"
    [ -f "$REGISTRY_SRC/Dockerfile" ] && [ -f "$ORCHESTRATION_SRC/Dockerfile" ] && [ -f "$ORCHESTRATION_SRC/workflow-designer/Dockerfile" ] || { echo 'Complete service/frontend sources required' >&2; exit 1; }
fi
if [ "$APP_SOURCE" == tars ]; then [ -d "$APP_TARS_DIR" ] || { echo '--app-tars-dir required' >&2; exit 2; }; fi
mkdir -p "$OUT_DIR"
BUNDLE="$(cd "$OUT_DIR" && pwd)/openan-offline-compose-$TAG"
# Never recursively remove a caller-specified/previous bundle. A failed build
# leaves only its own partial output for diagnosis; it never publishes a tar.
[ ! -e "$BUNDLE" ] && [ ! -e "$BUNDLE.tar.gz" ] || { echo 'Output exists; choose a fresh output/tag' >&2; exit 1; }
mkdir -p "$BUNDLE/images" "$BUNDLE/deps" "$BUNDLE/scripts/lib" "$BUNDLE/compose/init"
for script in install.sh check-env.sh uninstall.sh configure.py; do cp "$SOURCE/scripts/$script" "$BUNDLE/scripts/"; done
cp "$SOURCE/scripts/lib/common.sh" "$BUNDLE/scripts/lib/"
cp "$SOURCE/compose/init/create-databases.sh" "$SOURCE/compose/init/create-mysql-databases.sh" "$BUNDLE/compose/init/"
cp "$SOURCE/config.env.example" "$BUNDLE/"
mkdir -p "$BUNDLE/templates"
for template in registry.env.example orchestration.env.example models.yaml.example integration_credentials.conf.example; do
    cp "$SOURCE/templates/$template" "$BUNDLE/templates/"
done
cp "$SOURCE/README.md" "$BUNDLE/"
mkdir -p "$BUNDLE/docs"; cp "$SOURCE/docs/DEPENDENCIES.md" "$BUNDLE/docs/"
chmod +x "$BUNDLE/scripts/"*.sh "$BUNDLE/compose/init/"*.sh
RC="$APP_REGISTRY/registry-center:$TAG"; OC="$APP_REGISTRY/orchestration-center:$TAG"; UI="$APP_REGISTRY/workflow-designer:$TAG"
declare -A REFS=([registry-center]="$RC" [orchestration-center]="$OC" [workflow-designer]="$UI" [postgres]="postgres:15-alpine" [mysql]="mysql:8.4" [nginx]="nginx:1.27-alpine")
for arch in "${ARCHS[@]}"; do
    for component in registry-center orchestration-center workflow-designer postgres mysql nginx; do
        ref="${REFS[$component]}"
        echo "Preparing $component ($arch)"
        if [[ "$component" == postgres || "$component" == mysql || "$component" == nginx || "$APP_SOURCE" == pull ]]; then
            docker pull --platform "linux/$arch" "$ref"
        elif [ "$APP_SOURCE" == build ]; then
            case "$component" in registry-center) context="$REGISTRY_SRC" ;; orchestration-center) context="$ORCHESTRATION_SRC" ;; workflow-designer) context="$ORCHESTRATION_SRC/workflow-designer" ;; esac
            docker buildx build --platform "linux/$arch" --load -t "$ref" "$context"
        else
            tarfile="$APP_TARS_DIR/$component-$arch.tar"
            [ -s "$tarfile" ] || { echo "Missing image tar: $component-$arch.tar" >&2; exit 1; }
            docker load -i "$tarfile"
        fi
        actual="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$ref")"
        [ "$actual" == "linux/$arch" ] || { echo "Wrong image architecture: $component ($arch)" >&2; exit 1; }
        docker save -o "$BUNDLE/images/$component-$arch.tar" "$ref"
        [ -s "$BUNDLE/images/$component-$arch.tar" ] || { echo 'Empty saved image' >&2; exit 1; }
    done
done
# Extract files without running the foreign-architecture frontend process.
docker load -i "$BUNDLE/images/workflow-designer-${ARCHS[0]}.tar"
cid="$(docker create --platform "linux/${ARCHS[0]}" "$UI")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
mkdir -p "$BUNDLE/web"
docker cp "$cid:/usr/share/nginx/html/." "$BUNDLE/web/"
[ -s "$BUNDLE/web/index.html" ] || { echo 'Frontend index.html missing' >&2; exit 1; }
find "$BUNDLE/web" -type d -exec chmod 0755 {} +
find "$BUNDLE/web" -type f -exec chmod 0644 {} +
docker rm -f "$cid" >/dev/null; trap - EXIT
python3 - "$BUNDLE/deps/image-tags.json" "$PLATFORMS" "$RC" "$OC" "$UI" <<'PY'
import json, sys
with open(sys.argv[1], 'w', encoding='utf-8') as stream:
    json.dump({'architectures': [p.removeprefix('linux/') for p in sys.argv[2].split(',')],
               'images': dict(zip(['registry-center','orchestration-center','workflow-designer','postgres','nginx','mysql'],
                                  [*sys.argv[3:], 'postgres:15-alpine','nginx:1.27-alpine','mysql:8.4']))}, stream, indent=2)
PY
(cd "$BUNDLE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
tar -C "$(dirname "$BUNDLE")" -czf "$BUNDLE.tar.gz" "$(basename "$BUNDLE")"
echo "Done. Offline bundle: $BUNDLE.tar.gz"
