#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for the offline installer.
# Sourced by check-env.sh / install.sh / push-images.sh / uninstall.sh.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }
log_prompt(){ echo -e "${BLUE}[?]${NC} $1"; }

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
detect_arch() {
    # Container image arch suffix used by the offline bundle (amd64 / arm64)
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

detect_os_id() {
    # Returns the /etc/os-release ID (e.g. openeuler, centos, ubuntu)
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# Interactive helpers
# ---------------------------------------------------------------------------
ask_yes_no() {
    local prompt="$1"
    local default="${2:-yes}"
    local answer

    if [ "$ASSUME_YES" = "true" ]; then
        return 0
    fi

    if [ "$default" = "yes" ]; then
        log_prompt "$prompt [Y/n]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="y"
    else
        log_prompt "$prompt [y/N]:" >&2
        read -r answer
        [ -z "$answer" ] && answer="n"
    fi

    [[ "$answer" =~ ^[Yy] ]]
}

ask_input() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [ -n "$default" ]; then
        log_prompt "$prompt [$default]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    read -r value
    echo "${value:-$default}"
}

ask_input_secret() {
    local prompt="$1"
    local default="${2:-}"
    local char value=""

    if [ -n "$default" ]; then
        log_prompt "$prompt [****]:" >&2
    else
        log_prompt "$prompt:" >&2
    fi
    while IFS= read -rs -n1 char 2>/dev/null; do
        [ -z "${char}" ] && break
        if [[ "${char}" == $'\177' || "${char}" == $'\010' ]]; then
            if [ -n "${value}" ]; then
                value="${value%?}"
                printf '\b \b' >&2
            fi
            continue
        fi
        value+="${char}"
        printf '*' >&2
    done < /dev/tty
    printf '\n' >&2
    echo "${value:-$default}"
}

ask_choice() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice i

    echo "" >&2
    log_prompt "$prompt" >&2
    for i in "${!options[@]}"; do
        echo "  $((i + 1)). ${options[$i]}" >&2
    done
    read -r choice >&2

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
        echo "${options[$((choice - 1))]}"
    else
        echo "${options[0]}"
    fi
}

# ---------------------------------------------------------------------------
# Config file handling (config.env is a plain KEY=VALUE shell file)
# ---------------------------------------------------------------------------
load_config() {
    local file="$1"
    if [ ! -r "$file" ]; then
        log_error "Config file not found or unreadable: $file"
        exit 1
    fi
    log_info "Loading config from $file"
    # shellcheck disable=SC1090
    . "$file"
}

save_config() {
    local file="$1"
    {
        echo "# OpenAN offline installation config (generated $(date -u +%Y-%m-%dT%H:%M:%SZ))"
        echo "K8S_NAMESPACE=\"${K8S_NAMESPACE}\""
        echo "STORAGE_NODE=\"${STORAGE_NODE}\""
        echo "REGISTRY_NODE=\"${REGISTRY_NODE}\""
        echo "REGISTRY_NODE_IP=\"${REGISTRY_NODE_IP}\""
        echo "REGISTRY_NODEPORT=\"${REGISTRY_NODEPORT}\""
        echo "INSTALL_REGISTRY=\"${INSTALL_REGISTRY}\""
        echo "INSTALL_METALLB=\"${INSTALL_METALLB}\""
        echo "METALLB_POOL=\"${METALLB_POOL}\""
        echo "INGRESS_HOST=\"${INGRESS_HOST}\""
        echo "DB_TYPE=\"${DB_TYPE}\""
        echo "DB_PASSWORD=\"${DB_PASSWORD}\""
        echo "STORAGE_MODE=\"${STORAGE_MODE}\""
        echo "STORAGE_CLASS=\"${STORAGE_CLASS}\""
        echo "STORAGE_SIZE=\"${STORAGE_SIZE}\""
        echo "HOSTPATH=\"${HOSTPATH}\""
        echo "POSTGRES_IMAGE=\"${POSTGRES_IMAGE}\""
        echo "MYSQL_IMAGE=\"${MYSQL_IMAGE}\""
        echo "REGISTRY_CENTER_IMAGE=\"${REGISTRY_CENTER_IMAGE}\""
        echo "ORCHESTRATION_CENTER_IMAGE=\"${ORCHESTRATION_CENTER_IMAGE}\""
        echo "WORKFLOW_DESIGNER_IMAGE=\"${WORKFLOW_DESIGNER_IMAGE}\""
        echo "REGISTRY_CHAT_MODEL=\"${REGISTRY_CHAT_MODEL}\""
        echo "REGISTRY_CHAT_URL=\"${REGISTRY_CHAT_URL}\""
        echo "REGISTRY_CHAT_APIKEY=\"${REGISTRY_CHAT_APIKEY}\""
        echo "ORCH_CHAT_MODEL=\"${ORCH_CHAT_MODEL}\""
        echo "ORCH_CHAT_URL=\"${ORCH_CHAT_URL}\""
        echo "ORCH_CHAT_APIKEY=\"${ORCH_CHAT_APIKEY}\""
        echo "LLM_VALIDATE=\"${LLM_VALIDATE}\""
        echo "START_AGENTS_SERVER=\"${START_AGENTS_SERVER}\""
    } >"$file"
    chmod 600 "$file"
    log_info "Wrote config to $file"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
mask_key() {
    local key="$1"
    local len=${#key}
    if [ "$len" -gt 8 ]; then
        echo "${key:0:4}...${key: -4}"
    else
        echo "***"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Returns 0 when the local node's containerd has the given registry host
# configured as insecure (or skipped TLS verification).
containerd_insecure_configured() {
    local host="$1"
    local cfg="/etc/containerd/config.toml"
    [ -r "$cfg" ] || return 1
    grep -q "$host" "$cfg" 2>/dev/null
}

default_ip() {
    # Best-effort primary IP of the local node
    ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1
}
