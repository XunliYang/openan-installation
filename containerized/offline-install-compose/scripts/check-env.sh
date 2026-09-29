#!/bin/bash
# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
# Environment check for the OpenAN offline installer (Docker Compose).
#
# It ONLY detects and reports; it never modifies the OS or Docker.
#
#   scripts/check-env.sh [--config config.env] [--soft]

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SOFT="false"
CONFIG_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --soft)   SOFT="true"; shift ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) log_error "Unknown argument: $1"; exit 2 ;;
    esac
done

[ -n "$CONFIG_FILE" ] && load_config "$CONFIG_FILE"

FAILURES=()
WARNINGS=()

pass() { echo -e "  ${GREEN}[ OK ]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAILURES+=("$1"); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARNINGS+=("$1"); }

section() { echo ""; echo -e "${CYAN}== $1 ==${NC}"; }

ARCH="$(detect_arch)"
OS_ID="$(detect_os_id)"

need_image_tar() {
    local f="$BUNDLE_DIR/images/${1}-${ARCH}.tar"
    if [ -r "$f" ]; then pass "image tar: $(basename "$f")"; else fail "missing image tar for this arch: images/${1}-${ARCH}.tar"; fi
}

section "Platform"
if [ -n "$ARCH" ]; then pass "architecture: $ARCH"; else fail "unsupported architecture: $(uname -m) (need x86_64 or aarch64)"; fi
pass "os: $OS_ID ($(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}"))"

section "Bundle"
if [ -d "$BUNDLE_DIR/images" ] && [ -n "$(ls -A "$BUNDLE_DIR/images" 2>/dev/null)" ]; then
    pass "images/ present ($(ls "$BUNDLE_DIR/images" | wc -l) files)"
else
    fail "images/ missing or empty — run this from an unpacked offline bundle"
fi
if [ -r "$BUNDLE_DIR/SHA256SUMS" ]; then
    if (cd "$BUNDLE_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
        pass "bundle checksum verified"
    else
        warn "SHA256SUMS present but verification FAILED — bundle may be corrupted/incomplete"
    fi
else
    warn "SHA256SUMS not found, skipping integrity check"
fi

section "Docker"
if have docker; then
    pass "docker: $(docker --version 2>/dev/null)"
    if docker info >/dev/null 2>&1; then
        pass "docker daemon reachable"
    else
        fail "cannot talk to the docker daemon (rerun as root / add user to the docker group)"
    fi
    if docker compose version >/dev/null 2>&1; then
        pass "docker compose plugin: $(docker compose version --short 2>/dev/null)"
    else
        fail "docker compose plugin not found (docker-compose v1 is not supported)"
    fi
else
    fail "docker not found — install Docker + compose plugin (see docs/DEPENDENCIES.md)"
fi

section "Ports"
if have ss; then
    if ss -ltn 2>/dev/null | grep -q ':80 '; then
        warn "port 80 already in use on this host"
    else
        pass "port 80 available"
    fi
else
    warn "ss not available, cannot check port 80"
fi

section "Images (this arch: $ARCH)"
need_image_tar "registry-center"
need_image_tar "orchestration-center"
need_image_tar "postgres-15-alpine"
need_image_tar "nginx-1-25-alpine"

section "Frontend"
if [ -d "$BUNDLE_DIR/web" ] && [ -n "$(ls -A "$BUNDLE_DIR/web" 2>/dev/null)" ]; then
    pass "frontend static assets (web/) present"
else
    fail "web/ missing — frontend static assets must be extracted at build time"
fi

section "Disks"
avail="$(df -Pk "$BUNDLE_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$avail" ] && [ "$avail" -lt 5242880 ]; then
    warn "less than 5 GiB free next to the bundle"
else
    pass "disk space looks sufficient"
fi

echo ""
echo "=========================================="
if [ "${#FAILURES[@]}" -eq 0 ]; then
    echo -e "${GREEN}Environment check PASSED${NC}"
    [ "${#WARNINGS[@]}" -gt 0 ] && echo -e "${YELLOW}${#WARNINGS[@]} warning(s) — review the manual items above.${NC}"
    echo "=========================================="
    exit 0
else
    echo -e "${RED}Environment check FAILED (${#FAILURES[@]} issue(s))${NC}"
    echo "=========================================="
    i=1
    for f in "${FAILURES[@]}"; do echo "  $i. $f"; i=$((i + 1)); done
    echo ""
    echo "Resolve the items above and re-run. See docs/DEPENDENCIES.md."
    [ "$SOFT" = "true" ] && exit 0
    exit 1
fi
