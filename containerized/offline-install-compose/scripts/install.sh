#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# OpenAN offline installer (Docker Compose, single host).
#
#   scripts/install.sh                       # interactive
#   scripts/install.sh --config config.env   # non-interactive
#   scripts/install.sh --config config.env --yes --skip-check

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="$BUNDLE_DIR/compose"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

CONFIG_FILE=""
SKIP_CHECK="false"
ASSUME_YES="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --config)     CONFIG_FILE="$2"; shift 2 ;;
        --yes|-y)     ASSUME_YES="true"; shift ;;
        --skip-check) SKIP_CHECK="true"; shift ;;
        -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done
export ASSUME_YES

# --- Defaults (mirrors config.env.example) -----------------------------------
DB_PASSWORD="openan-db-password"
REGISTRY_CENTER_IMAGE="project-openan/registry-center:v1.0.0"
ORCHESTRATION_CENTER_IMAGE="project-openan/orchestration-center:v1.0.0"
WORKFLOW_DESIGNER_IMAGE="project-openan/workflow-designer:v1.0.0"
REGISTRY_CHAT_MODEL=""
REGISTRY_CHAT_URL=""
REGISTRY_CHAT_APIKEY=""
ORCH_CHAT_MODEL=""
ORCH_CHAT_URL=""
ORCH_CHAT_APIKEY=""

[ -n "$CONFIG_FILE" ] && load_config "$CONFIG_FILE"

ARCH="$(detect_arch)"
[ -n "$ARCH" ] || { log_error "unsupported architecture: $(uname -m)"; exit 1; }

if ! have docker; then log_error "docker not found"; exit 1; fi
if ! docker compose version >/dev/null 2>&1; then log_error "docker compose plugin not found"; exit 1; fi

# ---------------------------------------------------------------------------
# 1. Environment check
# ---------------------------------------------------------------------------
if [ "$SKIP_CHECK" != "true" ]; then
    log_step "[1/5] Checking environment"
    check_args=()
    [ -n "$CONFIG_FILE" ] && check_args+=(--config "$CONFIG_FILE")
    if ! "$SCRIPT_DIR/check-env.sh" "${check_args[@]}"; then
        log_error "Environment check failed. Fix the items above and re-run."
        exit 1
    fi
else
    log_warn "Skipping environment check (--skip-check)"
fi

# ---------------------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------------------
if [ "$ASSUME_YES" != "true" ] && [ -z "$CONFIG_FILE" ]; then
    log_step "[2/5] Configuration"
    DB_PASSWORD="$(ask_input_secret "  Postgres password" "$DB_PASSWORD")"
    REGISTRY_CHAT_MODEL="$(ask_input "  Registry Center chat model" "$REGISTRY_CHAT_MODEL")"
    REGISTRY_CHAT_URL="$(ask_input "  Registry Center chat URL" "$REGISTRY_CHAT_URL")"
    [ -n "$REGISTRY_CHAT_URL" ] && REGISTRY_CHAT_APIKEY="$(ask_input_secret "  Registry Center API key" "")"
    ORCH_CHAT_MODEL="$(ask_input "  Orchestration Center chat model" "$ORCH_CHAT_MODEL")"
    ORCH_CHAT_URL="$(ask_input "  Orchestration Center chat URL" "$ORCH_CHAT_URL")"
    [ -n "$ORCH_CHAT_URL" ] && ORCH_CHAT_APIKEY="$(ask_input_secret "  Orchestration Center API key" "")"
fi

echo ""
echo "=========================================="
echo "  OpenAN offline deployment (compose)"
echo "=========================================="
echo "  Architecture:  $ARCH"
echo "  Containers:    postgres x1, registry-center x2,"
echo "                 orchestration-center x2, nginx x1"
echo "  Entry:         http://<this-host>/"
echo "  Registry ctr:  $REGISTRY_CENTER_IMAGE"
echo "  Orchestration: $ORCHESTRATION_CENTER_IMAGE"
echo "=========================================="

if ! ask_yes_no "Proceed?" "yes"; then log_info "Cancelled."; exit 0; fi

# Persist the effective configuration for repeatability.
save_config "$BUNDLE_DIR/config.env"

# ---------------------------------------------------------------------------
# 3. Load images
# ---------------------------------------------------------------------------
log_step "[3/5] Loading images"

docker_load() {
    local base="$1" wanted="$2"
    local tar="$BUNDLE_DIR/images/${base}-${ARCH}.tar"
    [ -r "$tar" ] || { log_error "missing image tar: images/${base}-${ARCH}.tar"; return 1; }
    log_info "docker load $(basename "$tar")"
    docker load -i "$tar" >/dev/null || { log_error "failed to load $tar"; return 1; }
    # Retag to the configured reference when the bundle used a different tag.
    local built="$wanted"
    if [ -r "$BUNDLE_DIR/deps/image-tags.env" ]; then
        # shellcheck disable=SC1091
        . "$BUNDLE_DIR/deps/image-tags.env"
    fi
    case "$base" in
        registry-center)      built="${APP_REGISTRY_CENTER_TAG:-$wanted}" ;;
        orchestration-center) built="${APP_ORCHESTRATION_CENTER_TAG:-$wanted}" ;;
    esac
    if [ "$built" != "$wanted" ]; then
        log_info "  retag $built -> $wanted"
        docker tag "$built" "$wanted"
    fi
}

docker_load registry-center      "$REGISTRY_CENTER_IMAGE"      || exit 1
docker_load orchestration-center "$ORCHESTRATION_CENTER_IMAGE" || exit 1

for infra in postgres-15-alpine nginx-1-25-alpine; do
    tar="$BUNDLE_DIR/images/${infra}-${ARCH}.tar"
    [ -r "$tar" ] || { log_error "missing image tar: images/${infra}-${ARCH}.tar"; exit 1; }
    log_info "docker load $(basename "$tar")"
    docker load -i "$tar" >/dev/null || { log_error "failed to load $tar"; exit 1; }
done

# ---------------------------------------------------------------------------
# 4. Write .env and start
# ---------------------------------------------------------------------------
log_step "[4/5] Writing compose environment"
ENV_FILE="$COMPOSE_DIR/.env"
{
    echo "DB_PASSWORD=${DB_PASSWORD}"
    echo "REGISTRY_CENTER_IMAGE=${REGISTRY_CENTER_IMAGE}"
    echo "ORCHESTRATION_CENTER_IMAGE=${ORCHESTRATION_CENTER_IMAGE}"
    echo "REGISTRY_CHAT_MODEL=${REGISTRY_CHAT_MODEL}"
    echo "REGISTRY_CHAT_URL=${REGISTRY_CHAT_URL}"
    echo "REGISTRY_CHAT_APIKEY=${REGISTRY_CHAT_APIKEY}"
    echo "ORCH_CHAT_MODEL=${ORCH_CHAT_MODEL}"
    echo "ORCH_CHAT_URL=${ORCH_CHAT_URL}"
    echo "ORCH_CHAT_APIKEY=${ORCH_CHAT_APIKEY}"
} >"$ENV_FILE"
chmod 600 "$ENV_FILE"

mkdir -p "$COMPOSE_DIR/data/postgres"

log_step "[5/5] Starting containers"
(cd "$COMPOSE_DIR" && docker compose up -d) || { log_error "docker compose up failed"; exit 1; }

log_info "Waiting for containers..."
sleep 15
docker compose --project-directory "$COMPOSE_DIR" ps

# ---------------------------------------------------------------------------
# Self-check
# ---------------------------------------------------------------------------
HOST_IP="$(default_ip)"
echo ""
log_info "Smoke tests against http://${HOST_IP}/"
for path in "/" "/registry/rest/v1/registry-center/agent-cards" "/api/orchestrate/rest/v1/orchestrate/agent-cards"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://${HOST_IP}${path}" 2>/dev/null)"
    if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 500 ] 2>/dev/null; then
        log_info "  ${path} -> HTTP $code"
    else
        log_warn "  ${path} -> HTTP ${code:-000}"
    fi
done

echo ""
echo "  Access URL: http://${HOST_IP}/"
echo "  Logs:       docker compose --project-directory $COMPOSE_DIR logs -f"
echo "  Uninstall:  scripts/uninstall.sh"
echo ""
log_info "Compose installation complete."
