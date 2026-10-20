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
# Every kubectl delete is bounded by --timeout; a finalizer-blocked delete
# degrades to a warning instead of hanging the script.
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
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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
    HELM=""
    [ -x "$BUNDLE_DIR/deps/bin/helm-linux-$(detect_arch)" ] && HELM="$BUNDLE_DIR/deps/bin/helm-linux-$(detect_arch)"
    [ -z "$HELM" ] && command -v helm >/dev/null 2>&1 && HELM="helm"

    if ! "$KUBECTL" cluster-info >/dev/null 2>&1; then
        log_error "Cannot reach the cluster. Check KUBECONFIG."
        exit 1
    fi

    log_step "Removing OpenAN (Kubernetes, namespace $K8S_NAMESPACE)"
    local ns="$K8S_NAMESPACE"

    if ! "$KUBECTL" get namespace "$ns" >/dev/null 2>&1; then
        log_warn "Namespace $ns does not exist — nothing to remove"
        return 0
    fi

    # ------------------------------------------------------------------
    # 1. Helm release (or reap leftover workloads when release is gone)
    # ------------------------------------------------------------------
    if [ -n "$HELM" ] && "$HELM" status openan -n "$ns" >/dev/null 2>&1; then
        if "$HELM" uninstall openan -n "$ns"; then
            log_info "Helm release uninstalled"
        else
            log_error "Failed to uninstall Helm release"
            return 1
        fi
    else
        # Release metadata can be gone while workloads survive (partial
        # install, deleted release secret). Reap them by kind so PVCs below
        # are not blocked by pvc-protection.
        log_warn "Helm release not found; reaping leftover workloads"
        if "$KUBECTL" get deploy,sts,ds -n "$ns" -o name 2>/dev/null | grep -q .; then
            "$KUBECTL" delete deploy,sts,ds -n "$ns" --all --timeout=120s 2>/dev/null || true
            log_info "Deleted leftover workloads"
        fi
    fi

    # ------------------------------------------------------------------
    # 2. In-cluster registry (created outside the chart)
    # ------------------------------------------------------------------
    if "$KUBECTL" -n "$ns" get deploy openan-registry >/dev/null 2>&1; then
        log_info "Removing in-cluster registry"
        "$KUBECTL" -n "$ns" delete deploy openan-registry --ignore-not-found --timeout=120s 2>/dev/null || true
        "$KUBECTL" -n "$ns" delete svc openan-registry --ignore-not-found --timeout=60s 2>/dev/null || true
    fi

    # ------------------------------------------------------------------
    # 2b. Installer-generated Secrets (labeled openan-offline-installer)
    # ------------------------------------------------------------------
    for secret in openan-rc-tls openan-oc-tls openan-ingress-client openan-public-tls \
                  openan-registry-client openan-db-credentials openan-admin openan-llm-keys; do
        if [ "$("$KUBECTL" -n "$ns" get secret "$secret" -o jsonpath='{.metadata.labels.openan-offline-installer}' 2>/dev/null)" = "true" ]; then
            "$KUBECTL" -n "$ns" delete secret "$secret" --ignore-not-found --timeout=60s 2>/dev/null || true
            log_info "Deleted generated TLS Secret: $secret"
        fi
    done

    # ------------------------------------------------------------------
    # 3. Drain pods (pvc-protection needs mounting pods gone first)
    # ------------------------------------------------------------------
    if "$KUBECTL" get pods -n "$ns" --no-headers 2>/dev/null | grep -qv "No resources"; then
        "$KUBECTL" wait --for=delete pod -n "$ns" --all --timeout=120s 2>/dev/null || \
            log_warn "Some pods did not terminate within 120s; PVC deletion may block"
    fi

    # ------------------------------------------------------------------
    # 4. Persistent data (PVC → PV, all of them, with timeouts)
    # ------------------------------------------------------------------
    if ask_yes_no "Delete persistent data (PVC/PV and hostPath contents)?" "no"; then
        # PVCs — list then delete one by one with timeout
        local pvcs pvc
        pvcs=$("$KUBECTL" get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        for pvc in $pvcs; do
            if "$KUBECTL" delete pvc "$pvc" -n "$ns" --timeout=60s 2>/dev/null; then
                log_info "Deleted PVC: $pvc"
            else
                log_warn "PVC '$pvc' not deleted within 60s (still in use?)"
            fi
        done

        # PVs — match by claimRef.namespace, not hardcoded names
        local pv
        for pv in $("$KUBECTL" get pv -o jsonpath="{range .items[?(@.spec.claimRef.namespace==\"$ns\")]}{.metadata.name}{"\n"}{end}" 2>/dev/null); do
            if "$KUBECTL" delete pv "$pv" --timeout=60s 2>/dev/null; then
                log_info "Deleted PV: $pv"
            else
                log_warn "PV '$pv' not deleted within 60s"
            fi
        done

        log_warn "hostPath data on storage nodes was NOT touched (manual):"
        log_warn "  rm -rf /data/openan-postgres /data/openan-mysql /data/openan-registry"
        log_warn "  (also check for /data/openan-oc /data/openan-rc if present)"
    else
        log_info "Persistent volumes preserved"
    fi

    # ------------------------------------------------------------------
    # 5. MetalLB pool
    # ------------------------------------------------------------------
    if "$KUBECTL" get crd ipaddresspools.metallb.io >/dev/null 2>&1; then
        if ask_yes_no "Remove the OpenAN MetalLB pool (openan-pool / openan-l2)?" "yes"; then
            "$KUBECTL" -n metallb-system delete ipaddresspool openan-pool --ignore-not-found --timeout=60s 2>/dev/null || true
            "$KUBECTL" -n metallb-system delete l2advertisement openan-l2 --ignore-not-found --timeout=60s 2>/dev/null || true
        fi
        log_info "MetalLB itself was NOT uninstalled. Remove it manually if unused:"
        log_info "  kubectl delete -f $BUNDLE_DIR/deps/manifests/metallb-native.yaml"
    fi

    # ------------------------------------------------------------------
    # 6. Namespace (last — after pods/PVCs are already gone)
    # ------------------------------------------------------------------
    if ask_yes_no "Delete namespace $ns?" "yes"; then
        if "$KUBECTL" delete namespace "$ns" --ignore-not-found --timeout=180s 2>/dev/null; then
            log_info "Namespace deleted"
        else
            log_warn "Namespace deletion timed out (finalizers?). Check manually:"
            log_warn "  kubectl get namespace $ns -o jsonpath='{.spec.finalizers}'"
        fi
    fi

    echo ""
    log_warn "Manual reminder — undo the containerd insecure-registry entry on EVERY node:"
    log_warn "  edit /etc/containerd/config.toml, remove ${REGISTRY_NODE_IP:-<registry-node-ip>}:${REGISTRY_NODEPORT}"
    log_warn "  then: systemctl restart containerd"
    log_info "Done."
}

uninstall_k8s
