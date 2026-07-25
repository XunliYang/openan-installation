#!/bin/bash

# Copyright (c) 2026 Huawei Technologies Co., Ltd.
# All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

# ============================================================================
# package_offline.sh - Build offline deployment package
#
# Runs on the ONLINE machine. Downloads target-architecture wheel packages
# and bundles the project into a self-contained tar.gz for air-gapped deploy.
#
# Usage:
#   ./bin/package_offline.sh [--arch=x86_64|aarch64] [--python-version=3.12]
#                            [--version=1.0.0] [--output=dist]
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
TARGET_ARCH="$(uname -m)"
PYTHON_VERSION="3.12"
VERSION="1.0.0"
OUTPUT_DIR="${ROOT_DIR}/dist"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --arch=ARCH             Target architecture: x86_64 or aarch64 (default: current)"
    echo "  --python-version=VER    Target Python version (default: 3.12)"
    echo "  --version=VER           Package version label (default: 1.0.0)"
    echo "  --output=DIR            Output directory (default: ./dist)"
    echo "  -h, --help              Show this help"
    exit 0
}

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --arch=*) TARGET_ARCH="${arg#*=}" ;;
        --python-version=*) PYTHON_VERSION="${arg#*=}" ;;
        --version=*) VERSION="${arg#*=}" ;;
        --output=*) OUTPUT_DIR="${arg#*=}" ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Unknown option: $arg${NC}"; usage ;;
    esac
done

# Validate architecture
if [[ "$TARGET_ARCH" != "x86_64" && "$TARGET_ARCH" != "aarch64" ]]; then
    echo -e "${RED}Error: Unsupported architecture '$TARGET_ARCH'. Use x86_64 or aarch64.${NC}"
    exit 1
fi

# Build list of pip platform tags (newer packages like cryptography require manylinux_2_28+)
PIP_PLATFORMS=()
case "$TARGET_ARCH" in
    x86_64)
        PIP_PLATFORMS+=("manylinux_2_34_x86_64")
        PIP_PLATFORMS+=("manylinux_2_28_x86_64")
        PIP_PLATFORMS+=("manylinux_2_17_x86_64")
        PIP_PLATFORMS+=("manylinux2014_x86_64")
        ;;
    aarch64)
        PIP_PLATFORMS+=("manylinux_2_34_aarch64")
        PIP_PLATFORMS+=("manylinux_2_28_aarch64")
        PIP_PLATFORMS+=("manylinux_2_17_aarch64")
        PIP_PLATFORMS+=("manylinux2014_aarch64")
        ;;
esac

PKG_NAME="registry-center-${VERSION}-linux-${TARGET_ARCH}"
BUILD_DIR="${OUTPUT_DIR}/build/${PKG_NAME}"
WHEELS_DIR="${BUILD_DIR}/wheels"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Registry Center Offline Packager${NC}"
echo -e "${GREEN}============================================${NC}"
echo "  Version:        ${VERSION}"
echo "  Target arch:    ${TARGET_ARCH}"
echo "  Python version: ${PYTHON_VERSION}"
echo "  Pip platforms:  ${PIP_PLATFORMS[*]}"
echo "  Output:         ${OUTPUT_DIR}"
echo ""

# --- Step 1: Verify Python 3.12+ ---
echo -e "${GREEN}[1/7] Verifying Python ${PYTHON_VERSION}+...${NC}"

PYTHON_CMD=""
if command -v "python${PYTHON_VERSION}" &>/dev/null; then
    PYTHON_CMD="python${PYTHON_VERSION}"
elif command -v python3 &>/dev/null; then
    PYTHON_CMD="python3"
else
    echo -e "${RED}Error: Python ${PYTHON_VERSION}+ is not installed or not in PATH.${NC}"
    echo "Please install Python ${PYTHON_VERSION} and try again."
    exit 1
fi

PYTHON_VER=$($PYTHON_CMD --version 2>&1)
PYTHON_MAJOR=$($PYTHON_CMD -c "import sys; print(sys.version_info.major)")
PYTHON_MINOR=$($PYTHON_CMD -c "import sys; print(sys.version_info.minor)")

if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 12 ]; }; then
    echo -e "${RED}Error: Python 3.12+ is required, found ${PYTHON_VER}${NC}"
    exit 1
fi

echo "  Found: ${PYTHON_VER} ($PYTHON_CMD)"

# --- Step 2: Create and activate .venv ---
echo -e "${GREEN}[2/7] Creating virtual environment for packaging...${NC}"

VENV_PACKAGING_DIR="${ROOT_DIR}/.venv"
if [ -d "$VENV_PACKAGING_DIR" ]; then
    echo -e "${YELLOW}  .venv already exists, recreating...${NC}"
    rm -rf "$VENV_PACKAGING_DIR"
fi

$PYTHON_CMD -m venv "$VENV_PACKAGING_DIR"
source "${VENV_PACKAGING_DIR}/bin/activate"

echo "  Virtual environment created and activated: ${VENV_PACKAGING_DIR}"

# --- Step 3: Prepare build directory ---
echo -e "${GREEN}[3/7] Preparing build directory...${NC}"
rm -rf "${OUTPUT_DIR}/build"
mkdir -p "$BUILD_DIR"

# --- Step 4: Copy project source ---
echo -e "${GREEN}[4/7] Copying project source...${NC}"

# Copy source directories
cp -r "${ROOT_DIR}/agent_registry" "${BUILD_DIR}/"
cp -r "${ROOT_DIR}/common" "${BUILD_DIR}/"
cp -r "${ROOT_DIR}/etc" "${BUILD_DIR}/"
cp -r "${ROOT_DIR}/bin" "${BUILD_DIR}/"
cp "${ROOT_DIR}/requirements.txt" "${BUILD_DIR}/"

# Remove unnecessary files from copied source
find "$BUILD_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$BUILD_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true
rm -rf "${BUILD_DIR}/bin/package_offline.sh"

# Create empty runtime directories
mkdir -p "${BUILD_DIR}/log" "${BUILD_DIR}/run" "${BUILD_DIR}/data"

echo "  Source copied."

# --- Step 5: Download wheel packages ---
echo -e "${GREEN}[5/7] Downloading wheel packages for ${TARGET_ARCH}...${NC}"
mkdir -p "$WHEELS_DIR"

# Build --platform flags for pip download
PLATFORM_FLAGS=()
for p in "${PIP_PLATFORMS[@]}"; do
    PLATFORM_FLAGS+=("--platform" "$p")
done

# First pass: download binary wheels for target platform (all manylinux variants)
"${VENV_PACKAGING_DIR}/bin/pip" download \
    -r "${ROOT_DIR}/requirements.txt" \
    "${PLATFORM_FLAGS[@]}" \
    --python-version "$PYTHON_VERSION" \
    --only-binary=:all: \
    --dest "$WHEELS_DIR" \
    2>&1 | sed 's/^/  /'

# Second pass: download pure-Python packages (platform 'any')
"${VENV_PACKAGING_DIR}/bin/pip" download \
    -r "${ROOT_DIR}/requirements.txt" \
    --platform any \
    --python-version "$PYTHON_VERSION" \
    --only-binary=:all: \
    --dest "$WHEELS_DIR" \
    2>&1 | sed 's/^/  /' || true

# Verify wheels were downloaded
WHEEL_COUNT=$(find "$WHEELS_DIR" -name "*.whl" | wc -l)
if [ "$WHEEL_COUNT" -eq 0 ]; then
    echo -e "${RED}Error: No wheel packages downloaded. Check network and platform settings.${NC}"
    exit 1
fi
echo "  Downloaded ${WHEEL_COUNT} wheel packages."

# --- Step 6: Generate README_OFFLINE.txt ---
echo -e "${GREEN}[6/7] Generating README_OFFLINE.txt...${NC}"
cat > "${BUILD_DIR}/README_OFFLINE.txt" <<EOF
==========================================================
 Registry Center v${VERSION} - Offline Deployment Package
 Target: linux/${TARGET_ARCH} | Python ${PYTHON_VERSION}
==========================================================

Prerequisites:
  - Linux ${TARGET_ARCH}
  - Python ${PYTHON_VERSION} (pre-installed)
  - No internet connection required

Quick Start:
  1. Extract the package:
     tar -xzf ${PKG_NAME}.tar.gz

  2. Enter the directory:
     cd ${PKG_NAME}

  3. Run offline setup (creates venv, installs deps, configures, activates venv):
     bin/setup_offline.sh

     To skip interactive configuration:
     source bin/setup_offline.sh --skip-init

  4. Start the service:
     bin/start.sh

  5. Stop the service:
     bin/stop.sh

Configuration (can be re-run anytime):
  ./venv/bin/python -m agent_registry.init

  Or manually edit:
  - etc/conf/server.conf       (IP, port, TLS, signing)
  - etc/conf/persistence.conf  (storage mode: file/postgresql)
  - common/config/llm_config.json (LLM API key, optional)

Systemd Service (optional, requires root):
  sudo ./bin/install_service.sh install
  sudo systemctl start registry-center

Directory Layout:
  agent_registry/   Application source code
  common/           Shared modules and config templates
  etc/conf/         Configuration files
  etc/systemd/      Systemd service templates
  bin/              Operational scripts
  wheels/           Pre-downloaded Python wheel packages
  venv/             Virtual environment (created by setup_offline.sh)
  log/              Runtime logs
  run/              Runtime PID/socket files
  data/             File-based storage data
EOF

echo "  README generated."

# --- Step 7: Create tar.gz archive ---
echo -e "${GREEN}[7/7] Creating archive...${NC}"
mkdir -p "$OUTPUT_DIR"
tar -czf "${OUTPUT_DIR}/${PKG_NAME}.tar.gz" -C "${OUTPUT_DIR}/build" "$PKG_NAME"

# Cleanup build directory
rm -rf "${OUTPUT_DIR}/build"

ARCHIVE_SIZE=$(du -h "${OUTPUT_DIR}/${PKG_NAME}.tar.gz" | cut -f1)

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Package built successfully!${NC}"
echo -e "${GREEN}============================================${NC}"
echo "  File: ${OUTPUT_DIR}/${PKG_NAME}.tar.gz"
echo "  Size: ${ARCHIVE_SIZE}"
echo ""
echo "  Transfer this file to the offline machine, then:"
echo "    tar -xzf ${PKG_NAME}.tar.gz"
echo "    cd ${PKG_NAME}"
echo "    source bin/setup_offline.sh"
echo "    bin/start.sh"
echo -e "${GREEN}============================================${NC}"