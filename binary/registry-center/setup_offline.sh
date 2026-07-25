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
# setup_offline.sh - Offline environment setup
#
# Runs on the OFFLINE (air-gapped) machine. Creates a virtual environment,
# installs dependencies from pre-downloaded wheels, and optionally runs
# interactive configuration.
#
# Usage:
#   source bin/setup_offline.sh [--skip-init] [--python=python3.12]
#   (Using 'source' activates the venv in your current shell)
# ============================================================================

# Detect if script is being sourced or executed directly
_SETUP_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    _SETUP_SOURCED=1
fi

# Only apply strict mode when executed directly (avoid affecting user's shell)
if [ "$_SETUP_SOURCED" -eq 0 ]; then
    set -euo pipefail
fi

# Portable exit: 'return' when sourced, 'exit' when executed
_setup_exit() {
    if [ "$_SETUP_SOURCED" -eq 1 ]; then
        return "$1"
    else
        exit "$1"
    fi
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VENV_DIR="${ROOT_DIR}/venv"
WHEELS_DIR="${ROOT_DIR}/wheels"
REQUIREMENTS_FILE="${ROOT_DIR}/requirements.txt"
SKIP_INIT="false"
PYTHON_CMD=""

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --skip-init) SKIP_INIT="true" ;;
        --python=*) PYTHON_CMD="${arg#*=}" ;;
        -h|--help)
            echo "Usage: source bin/setup_offline.sh [--skip-init] [--python=PATH]"
            echo ""
            echo "Options:"
            echo "  --skip-init      Skip interactive configuration wizard"
            echo "  --python=PATH    Python interpreter to use (default: auto-detect python3.12)"
            echo "  -h, --help       Show this help"
            _setup_exit 0
            ;;
        *) echo -e "${RED}Unknown option: $arg${NC}"; _setup_exit 1 ;;
    esac
done

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Registry Center - Offline Setup${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# --- Grant execute permissions to bin scripts ---
chmod +x "${ROOT_DIR}"/bin/*
echo "  Execute permissions granted for bin/* scripts."
echo ""

# --- Step 1: Check Python ---
echo -e "${GREEN}[1/4] Checking Python...${NC}"

if [ -z "$PYTHON_CMD" ]; then
    if command -v python3.12 &>/dev/null; then
        PYTHON_CMD="python3.12"
    elif command -v python3 &>/dev/null; then
        PYTHON_CMD="python3"
    elif command -v python &>/dev/null; then
        PYTHON_CMD="python"
    else
        echo -e "${RED}Error: Python3 is not installed or not in PATH.${NC}"
        echo "Please install Python 3.12 and try again."
        _setup_exit 1
    fi
fi

if ! command -v "$PYTHON_CMD" &>/dev/null; then
    echo -e "${RED}Error: Python command not found: $PYTHON_CMD${NC}"
    _setup_exit 1
fi

PYTHON_VER=$($PYTHON_CMD --version 2>&1)
echo "  Found: ${PYTHON_VER} ($PYTHON_CMD)"

# Verify minimum version (3.10+)
PYTHON_MAJOR=$($PYTHON_CMD -c "import sys; print(sys.version_info.major)")
PYTHON_MINOR=$($PYTHON_CMD -c "import sys; print(sys.version_info.minor)")
if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 10 ]; }; then
    echo -e "${RED}Error: Python 3.10+ is required, found ${PYTHON_VER}${NC}"
    _setup_exit 1
fi

# --- Step 2: Create virtual environment ---
echo -e "${GREEN}[2/4] Creating virtual environment...${NC}"

if [ -d "$VENV_DIR" ]; then
    echo -e "${YELLOW}  venv already exists at ${VENV_DIR}, recreating...${NC}"
    rm -rf "$VENV_DIR"
fi

$PYTHON_CMD -m venv "$VENV_DIR"

if [ ! -f "${VENV_DIR}/bin/python3" ]; then
    echo -e "${RED}Error: Failed to create virtual environment.${NC}"
    _setup_exit 1
fi

echo "  Virtual environment created: ${VENV_DIR}"

# Upgrade pip within venv (from local wheels if available, skip if not)
"${VENV_DIR}/bin/pip" install --upgrade pip --no-index --find-links="$WHEELS_DIR" 2>/dev/null || true

# --- Step 3: Install dependencies from local wheels ---
echo -e "${GREEN}[3/4] Installing dependencies from local wheels...${NC}"

if [ ! -d "$WHEELS_DIR" ]; then
    echo -e "${RED}Error: Wheels directory not found: ${WHEELS_DIR}${NC}"
    echo "Make sure you extracted the complete offline package."
    _setup_exit 1
fi

if [ ! -f "$REQUIREMENTS_FILE" ]; then
    echo -e "${RED}Error: requirements.txt not found: ${REQUIREMENTS_FILE}${NC}"
    _setup_exit 1
fi

WHEEL_COUNT=$(find "$WHEELS_DIR" -name "*.whl" 2>/dev/null | wc -l)
echo "  Found ${WHEEL_COUNT} wheel packages in ${WHEELS_DIR}"

if ! "${VENV_DIR}/bin/pip" install \
    --no-index \
    --find-links="$WHEELS_DIR" \
    -r "$REQUIREMENTS_FILE" \
    2>&1 | sed 's/^/  /'; then
    echo -e "${RED}Error: Failed to install dependencies.${NC}"
    echo "Some wheels may be missing for your platform. Check the wheels/ directory."
    _setup_exit 1
fi

echo -e "${GREEN}  Dependencies installed successfully.${NC}"

# --- Step 4: Interactive configuration ---
echo -e "${GREEN}[4/4] Configuration...${NC}"

if [ "$SKIP_INIT" = "true" ]; then
    echo "  Skipped (--skip-init)."
    echo ""
    echo -e "${YELLOW}  You can configure later with:${NC}"
    echo "    ./venv/bin/python -m agent_registry.init"
else
    echo ""
    echo -e "${YELLOW}  Starting interactive configuration wizard...${NC}"
    echo "  (Configure IP, port, TLS, storage, etc.)"
    echo ""

    cd "$ROOT_DIR"
    "${VENV_DIR}/bin/python" -m agent_registry.init

    echo ""
    echo -e "${GREEN}  Configuration complete.${NC}"
fi

# --- Done ---
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Setup complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# Activate venv in the current shell (effective when sourced)
source "${VENV_DIR}/bin/activate"

if [ "$_SETUP_SOURCED" -eq 1 ]; then
    echo "  Virtual environment activated in current shell."
    echo ""
    echo "  Next steps:"
    echo "    1. Place TLS certificates in etc/ssl/ (if HTTPS enabled)"
    echo "    2. Start service:  bin/start.sh"
    echo "    3. Stop service:   bin/stop.sh"
else
    echo "  Next steps:"
    echo "    1. Place TLS certificates in etc/ssl/ (if HTTPS enabled)"
    echo "    2. Activate venv:  source venv/bin/activate"
    echo "    3. Start service:  bin/start.sh"
    echo "    4. Stop service:   bin/stop.sh"
fi
echo ""
echo "  Re-configure anytime:"
echo "    ./venv/bin/python -m agent_registry.init"
echo ""
echo "  Manual config files:"
echo "    etc/conf/server.conf"
echo "    etc/conf/persistence.conf"
echo "    common/config/llm_config.json"
echo -e "${GREEN}============================================${NC}"

# Cleanup internal variables
unset _SETUP_SOURCED
unset -f _setup_exit