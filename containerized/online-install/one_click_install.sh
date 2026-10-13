#!/usr/bin/env bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# Guided, explicit phases. Never enable shell tracing: secrets travel through stdin.
set -euo pipefail
set +x
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES=""; RELEASE=openan; NAMESPACE=openan
SKIP_BUILD=false; SKIP_INFRA=false
RC_SOURCE=""; OC_SOURCE=""; TAG=""
METALLB_CHART=""; METALLB_VALUES=""; INGRESS_CHART=""; INGRESS_VALUES=""
usage() {
    echo 'Usage: one_click_install.sh [--values FILE] [--release NAME] [--namespace NAME]'
    echo '  [--skip-build | --tag TAG --registry-release URL --orchestration-release URL]'
    echo '  [--skip-infra | --metallb-chart TGZ --metallb-values FILE --ingress-chart TGZ --ingress-values FILE]'
    echo 'Without --values, a wizard collects non-secret configuration and writes Secrets directly to Kubernetes.'
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --skip-infra) SKIP_INFRA=true; shift ;;
        --values|--release|--namespace|--registry-release|--orchestration-release|--tag|--metallb-chart|--metallb-values|--ingress-chart|--ingress-values)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            case "$1" in
                --values) VALUES="$2" ;; --release) RELEASE="$2" ;; --namespace) NAMESPACE="$2" ;;
                --registry-release) RC_SOURCE="$2" ;; --orchestration-release) OC_SOURCE="$2" ;; --tag) TAG="$2" ;;
                --metallb-chart) METALLB_CHART="$2" ;; --metallb-values) METALLB_VALUES="$2" ;;
                --ingress-chart) INGRESS_CHART="$2" ;; --ingress-values) INGRESS_VALUES="$2" ;;
            esac
            shift 2 ;;
        *) echo 'Unknown option; use --help.' >&2; exit 2 ;;
    esac
done
for name in "$RELEASE" "$NAMESPACE"; do
    [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#name} -le 53 ]] || { echo 'Invalid release/namespace.' >&2; exit 2; }
done
if [[ "$SKIP_BUILD" == false && ( -z "$RC_SOURCE" || -z "$OC_SOURCE" || -z "$TAG" ) ]]; then
    echo 'Build requires explicit accepted source URLs and --tag, or --skip-build.' >&2; exit 2
fi
if [[ "$SKIP_INFRA" == false ]]; then
    for file in "$METALLB_CHART" "$METALLB_VALUES" "$INGRESS_CHART" "$INGRESS_VALUES"; do
        [[ -f "$file" ]] || { echo 'Provide reviewed local infrastructure chart packages and values, or --skip-infra.' >&2; exit 2; }
    done
fi
[[ -z "$VALUES" || -f "$VALUES" ]] || { echo 'Values file missing.' >&2; exit 2; }
for tool in python3 kubectl helm; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }; done
kubectl cluster-info >/dev/null
if [[ "$SKIP_BUILD" == false ]]; then
    bash "$SCRIPT_DIR/../build/build.sh" --tag "$TAG" --registry-release "$RC_SOURCE" --orchestration-release "$OC_SOURCE"
fi
if [[ "$SKIP_INFRA" == false ]]; then
    # Explicit operator-approved packages; no guessed IP pools, latest downloads or cluster reconfiguration.
    helm upgrade --install metallb "$METALLB_CHART" --namespace metallb-system --create-namespace --values "$METALLB_VALUES" --wait --timeout 5m
    helm upgrade --install ingress-nginx "$INGRESS_CHART" --namespace ingress-nginx --create-namespace --values "$INGRESS_VALUES" --wait --timeout 5m
fi
if [[ -z "$VALUES" ]]; then
    VALUES="$PWD/deployment.generated.json"
    python3 "$SCRIPT_DIR/configure.py" --namespace "$NAMESPACE" --release "$RELEASE" --output "$VALUES"
fi
# Validate before creating/upgrading application resources; namespace must match values.
helm lint "$SCRIPT_DIR/openan-chart" --namespace "$NAMESPACE" --values "$VALUES"
helm upgrade --install "$RELEASE" "$SCRIPT_DIR/openan-chart" --namespace "$NAMESPACE" --create-namespace --values "$VALUES" --wait --timeout 10m
