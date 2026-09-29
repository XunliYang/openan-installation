#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# OpenAN offline uninstaller (Kubernetes).
#
# It removes what the installer created. It never edits the OS or the
# container runtime; the containerd insecure-registry change is only printed
# as a reminder.
#
#   scripts/uninstall.sh                    # ask before deleting data
#   scripts/uninstall.sh --config config.env

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE=""
ASSUME_YES="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES="true"; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done
export ASSUME_YES

K8S_NAMESPACE="openan"
REGISTRY_NODE_IP=""
REGISTRY_NODEPORT="30500"

if [ -z "$CONFIG_FILE" ] && [ -r "$BUNDLE_DIR/config.env" ]; then
    CONFIG_FILE="$BUNDLE_DIR/config.env"
fi
[ -n "$CONFIG_FILE" ] && load_config "$CONFIG_FILE"

# ===========================================================================
# Kubernetes
# ===========================================================================
uninstall_k8s() {
    KUBECTL="kubectl"
    [ -x "$BUNDLE_DIR/deps/bin/kubectl-linux-$(detect_arch)" ] && KUBECTL="$BUNDLE_DIR/deps/bin/kubectl-linux-$(detect_arch)"

    if ! "$KUBECTL" cluster-info >/dev/null 2>&1; then
        log_error "Cannot reach the cluster. Check KUBECONFIG."
        exit 1
    fi

    log_step "Removing OpenAN (Kubernetes, namespace $K8S_NAMESPACE)"

    # Helm release
    if "$KUBECTL" get namespace "$K8S_NAMESPACE" >/dev/null 2>&1; then
        if command -v helm >/dev/null 2>&1 || [ -x "$BUNDLE_DIR/deps/bin/helm-linux-$(detect_arch)" ]; then
            HELM="helm"
            [ -x "$BUNDLE_DIR/deps/bin/helm-linux-$(detect_arch)" ] && HELM="$BUNDLE_DIR/deps/bin/helm-linux-$(detect_arch)"
            "$HELM" uninstall openan -n "$K8S_NAMESPACE" 2>/dev/null || log_warn "Helm release 'openan' not found"
        fi
    else
        log_warn "Namespace $K8S_NAMESPACE does not exist"
    fi

    # In-cluster registry
    if "$KUBECTL" -n "$K8S_NAMESPACE" get deploy openan-registry >/dev/null 2>&1; then
        log_info "Removing in-cluster registry"
        "$KUBECTL" -n "$K8S_NAMESPACE" delete deploy openan-registry --ignore-not-found
        "$KUBECTL" -n "$K8S_NAMESPACE" delete svc openan-registry --ignore-not-found
    fi

    # Persistent data
    if ask_yes_no "Delete persistent data (PVC/PV and /data/openan-postgres, /data/openan-registry)?" "no"; then
        "$KUBECTL" -n "$K8S_NAMESPACE" delete pvc --all --ignore-not-found 2>/dev/null || true
        "$KUBECTL" delete pv openan-postgres-pv --ignore-not-found 2>/dev/null || true
        log_warn "hostPath data on the storage node was NOT touched (manual):"
        log_warn "  rm -rf /data/openan-postgres /data/openan-registry"
    else
        log_info "Persistent volumes preserved"
    fi

    # MetalLB configuration created by the installer
    if "$KUBECTL" get crd ipaddresspools.metallb.io >/dev/null 2>&1; then
        if ask_yes_no "Remove the OpenAN MetalLB pool (openan-pool / openan-l2)?" "yes"; then
            "$KUBECTL" -n metallb-system delete ipaddresspool openan-pool --ignore-not-found
            "$KUBECTL" -n metallb-system delete l2advertisement openan-l2 --ignore-not-found
        fi
        log_info "MetalLB itself was NOT uninstalled. Remove it manually if unused:"
        log_info "  kubectl delete -f $BUNDLE_DIR/deps/manifests/metallb-native.yaml"
    fi

    # Namespace
    if ask_yes_no "Delete namespace $K8S_NAMESPACE?" "yes"; then
        "$KUBECTL" delete namespace "$K8S_NAMESPACE" --ignore-not-found
    fi

    echo ""
    log_warn "Manual reminder — undo the containerd insecure-registry entry on EVERY node:"
    log_warn "  edit /etc/containerd/config.toml, remove ${REGISTRY_NODE_IP:-<registry-node-ip>}:${REGISTRY_NODEPORT}"
    log_warn "  then: systemctl restart containerd"
    log_info "Done."
}

uninstall_k8s
