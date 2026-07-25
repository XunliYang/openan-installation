#!/bin/bash
# =============================================================================
# install_offline.sh
# =============================================================================
# Run this on the AIR-GAPPED (offline) machine to install the Orchestration
# Center from the offline bundle.
#
# This script:
#   1. Verifies the bundle is complete
#   2. Installs the project to /opt/orchestration-center (or custom dir)
#   3. Activates the pre-built venv (no internet needed)
#   4. Optionally installs as a systemd service
#   5. Prints next steps for configuration
#
# Usage:
#   ./install_offline.sh [--dir=/custom/path] [--service] [--no-service]
#                        [--rebuild-venv] [--rebuild-frontend]
#
# Prerequisites on the offline machine:
#   - Python 3.11+ (system Python, must match the major.minor of the
#     online machine that built the venv, e.g. both 3.12)
#   - Node.js 20.19+ (only if using the frontend)
#   - Root privileges (for systemd install; non-root for manual start)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR=""
INSTALL_SERVICE=""
REBUILD_VENV=false
REBUILD_FRONTEND=false

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir=*)
            INSTALL_DIR="${1#*=}"
            shift
            ;;
        --service)
            INSTALL_SERVICE=true
            shift
            ;;
        --no-service)
            INSTALL_SERVICE=false
            shift
            ;;
        --rebuild-venv)
            REBUILD_VENV=true
            shift
            ;;
        --rebuild-frontend)
            REBUILD_FRONTEND=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --dir=PATH           Install directory (default: /opt/orchestration-center)"
            echo "  --service            Install as systemd service (requires root)"
            echo "  --no-service         Do not install as systemd service (manual start)"
            echo "  --rebuild-venv       Rebuild venv from cached wheels (use if venv is broken)"
            echo "  --rebuild-frontend   Rebuild frontend from cached npm (use if node_modules is broken)"
            echo ""
            echo "Without --service or --no-service, you will be prompted."
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Offline Bundle Installer${NC}"
echo -e "${BLUE}  Orchestration Center${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ─── Verify bundle integrity ─────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Verifying bundle...${NC}"

if [ ! -f "${ROOT_DIR}/OFFLINE_BUNDLE_MANIFEST.txt" ]; then
    echo -e "${RED}Error: Not running from inside the offline bundle.${NC}"
    echo -e "       Expected to find OFFLINE_BUNDLE_MANIFEST.txt in project root."
    echo -e "       Run this script from: orchestration-center-offline/bin/install_offline.sh"
    exit 1
fi

VENV_DIR="${ROOT_DIR}/venv"
WHEELS_DIR="${ROOT_DIR}/vendor/wheels"
FRONTEND_DIR="${ROOT_DIR}/workflow-designer"

# Check venv
if [ ! -d "$VENV_DIR" ] || [ ! -f "${VENV_DIR}/bin/python3" ]; then
    if [ -d "$WHEELS_DIR" ] && [ "$(ls -A "$WHEELS_DIR" 2>/dev/null)" ]; then
        echo -e "  ${YELLOW}⚠ venv not found, but wheels are available. Will rebuild.${NC}"
        REBUILD_VENV=true
    else
        echo -e "${RED}Error: venv not found and no wheels available for rebuild.${NC}"
        echo -e "       The bundle may be incomplete."
        exit 1
    fi
else
    echo -e "  ${GREEN}✓${NC} venv found"
fi

# Check frontend
if [ -d "${FRONTEND_DIR}" ]; then
    if [ ! -d "${FRONTEND_DIR}/node_modules" ]; then
        if [ -d "${ROOT_DIR}/vendor/npm-cache" ]; then
            echo -e "  ${YELLOW}⚠ node_modules not found, but npm cache is available. Will rebuild.${NC}"
            REBUILD_FRONTEND=true
        else
            echo -e "  ${YELLOW}⚠ Frontend dir exists but no node_modules and no npm cache.${NC}"
            echo -e "     Frontend will not be available."
        fi
    else
        echo -e "  ${GREEN}✓${NC} Frontend node_modules found"
    fi
fi

echo -e "  ${GREEN}✓${NC} Bundle verified"
echo ""

# ─── Check system Python ─────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Checking system Python...${NC}"

# Auto-detect Python 3.12+ — try common binary names in order of preference
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" &>/dev/null; then
        CAND_VERSION=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        CAND_MAJOR=$(echo "$CAND_VERSION" | cut -d. -f1)
        CAND_MINOR=$(echo "$CAND_VERSION" | cut -d. -f2)
        if [ "$CAND_MAJOR" -eq 3 ] && [ "$CAND_MINOR" -ge 12 ]; then
            PYTHON_BIN="$candidate"
            SYSTEM_PY="$CAND_VERSION"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo -e "${RED}Error: Python 3.12+ not found on this machine.${NC}"
    echo -e "       Searched: python3.13, python3.12, python3.11, python3"
    echo -e "       The project requires Python 3.12+."
    exit 1
fi
echo -e "  System Python: ${SYSTEM_PY} ($PYTHON_BIN)"

# If we have a venv, check version compatibility
if [ "$REBUILD_VENV" = false ] && [ -f "${VENV_DIR}/bin/python3" ]; then
    VENV_PY=$("${VENV_DIR}/bin/python3" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    echo -e "  Bundle venv Python: ${VENV_PY}"
    if [ "$SYSTEM_PY" != "$VENV_PY" ]; then
        echo -e "  ${YELLOW}⚠ Version mismatch! System=${SYSTEM_PY}, venv=${VENV_PY}${NC}"
        echo -e "     The pre-built venv may not work. Options:"
        echo -e "     a) Install Python ${VENV_PY} on this machine"
        echo -e "     b) Rebuild venv from wheels: re-run with --rebuild-venv"
        echo ""
        read -p "$(echo -e "${YELLOW}Rebuild venv from cached wheels now? (y/n): ${NC}")" choice
        case "$choice" in
            [Yy]|[Yy][Ee][Ss]) REBUILD_VENV=true ;;
            *) echo -e "${YELLOW}Continuing with existing venv (may fail)...${NC}" ;;
        esac
    fi
fi

echo ""

# ─── Rebuild venv if needed ──────────────────────────────────────────────────
if [ "$REBUILD_VENV" = true ]; then
    echo -e "${YELLOW}Step 3: Rebuilding Python venv from cached wheels...${NC}"

    if [ ! -d "$WHEELS_DIR" ]; then
        echo -e "${RED}Error: No wheels directory found at $WHEELS_DIR${NC}"
        exit 1
    fi

    rm -rf "$VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip wheel setuptools
    "$VENV_DIR/bin/pip" install --no-index --find-links "$WHEELS_DIR" \
        -r "${ROOT_DIR}/requirements.txt"
    echo -e "  ${GREEN}✓${NC} venv rebuilt from cached wheels"
    echo ""
else
    echo -e "${YELLOW}Step 3: Using pre-built venv${NC}"
    echo -e "  ${GREEN}✓${NC} venv at ${VENV_DIR}"
    echo ""
fi

# ─── Rebuild frontend if needed ──────────────────────────────────────────────
if [ "$REBUILD_FRONTEND" = true ]; then
    echo -e "${YELLOW}Step 4: Rebuilding frontend from npm cache...${NC}"

    NPM_CACHE_DIR="${ROOT_DIR}/vendor/npm-cache"
    if [ ! -d "$NPM_CACHE_DIR" ]; then
        echo -e "${RED}Error: No npm cache found at $NPM_CACHE_DIR${NC}"
        echo -e "${YELLOW}Continuing without frontend...${NC}"
    else
        if ! command -v npm &>/dev/null; then
            echo -e "${RED}Error: npm not found on this machine.${NC}"
            echo -e "${YELLOW}Continuing without frontend...${NC}"
        else
            cd "$FRONTEND_DIR"
            npm install --force --cache "$NPM_CACHE_DIR" --prefer-offline
            echo -e "  ${GREEN}✓${NC} Frontend rebuilt from cache"
            cd "$ROOT_DIR"
        fi
    fi
    echo ""
else
    if [ -d "${FRONTEND_DIR}/node_modules" ]; then
        echo -e "${YELLOW}Step 4: Frontend ready (pre-built node_modules)${NC}"
        echo -e "  ${GREEN}✓${NC} No rebuild needed"
    else
        echo -e "${YELLOW}Step 4: Frontend not available${NC}"
    fi
    echo ""
fi

# ─── Determine install directory ─────────────────────────────────────────────
if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="${ROOT_DIR}"
    echo -e "${YELLOW}Step 5: Install location${NC}"
    echo -e "  Bundle is at: ${ROOT_DIR}"
    echo -e "  You can run directly from here, or install to a system path."
    echo ""
    read -p "$(echo -e "${YELLOW}Install to /opt/orchestration-center? (y/n): ${NC}")" choice
    case "$choice" in
        [Yy]|[Yy][Ee][Ss])
            INSTALL_DIR="/opt/orchestration-center"
            ;;
        *)
            INSTALL_DIR="${ROOT_DIR}"
            echo -e "  ${GREEN}✓${NC} Running in-place from ${INSTALL_DIR}"
            ;;
    esac
fi

# ─── Copy to install directory if different ──────────────────────────────────
if [ "$INSTALL_DIR" != "$ROOT_DIR" ]; then
    echo -e "${YELLOW}Copying to ${INSTALL_DIR}...${NC}"

    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠ Not running as root. Need sudo to copy to ${INSTALL_DIR}.${NC}"
        SUDO="sudo"
    else
        SUDO=""
    fi

    $SUDO mkdir -p "$INSTALL_DIR"
    $SUDO cp -r "$ROOT_DIR"/* "$INSTALL_DIR/"
    echo -e "  ${GREEN}✓${NC} Installed to ${INSTALL_DIR}"

    # Update ROOT_DIR and VENV_DIR for service install
    ROOT_DIR="$INSTALL_DIR"
    VENV_DIR="${INSTALL_DIR}/venv"
fi
echo ""

# ─── Fix venv symlinks if copied ─────────────────────────────────────────────
if [ "$INSTALL_DIR" != "${SCRIPT_DIR}/.." ]; then
    echo -e "${YELLOW}Step 6: Fixing venv paths...${NC}"
    # The venv has hardcoded paths to the build location. Fix them.
    if [ -f "${VENV_DIR}/bin/activate" ]; then
        OLD_BUILD_PATH=$(grep -m1 'VIRTUAL_ENV=' "${VENV_DIR}/bin/activate" | cut -d= -f2 | tr -d '"' || true)
        if [ -n "$OLD_BUILD_PATH" ] && [ "$OLD_BUILD_PATH" != "$VENV_DIR" ]; then
            sed -i "s|${OLD_BUILD_PATH}|${VENV_DIR}|g" "${VENV_DIR}/bin/activate"
            # Fix the python symlink
            rm -f "${VENV_DIR}/bin/python"
            ln -s "$PYTHON_BIN" "${VENV_DIR}/bin/python" 2>/dev/null || true
            echo -e "  ${GREEN}✓${NC} venv paths updated to ${VENV_DIR}"
        else
            echo -e "  ${GREEN}✓${NC} venv paths already correct"
        fi
    fi
    echo ""
else
    echo -e "${YELLOW}Step 6: Running in-place, no path fixes needed${NC}"
    echo ""
fi

# ─── Make scripts executable ─────────────────────────────────────────────────
chmod +x "${ROOT_DIR}/bin/"*.sh 2>/dev/null || true

# ─── Prompt for systemd service install ──────────────────────────────────────
if [ -z "$INSTALL_SERVICE" ]; then
    echo -e "${YELLOW}Step 7: systemd service${NC}"
    read -p "$(echo -e "${YELLOW}Install as systemd service? (y/n): ${NC}")" choice
    case "$choice" in
        [Yy]|[Yy][Ee][Ss]) INSTALL_SERVICE=true ;;
        *) INSTALL_SERVICE=false ;;
    esac
fi

if [ "$INSTALL_SERVICE" = true ]; then
    echo -e "${YELLOW}Installing systemd service...${NC}"

    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}⚠ Need root for systemd. Using sudo...${NC}"
        SUDO="sudo"
    else
        SUDO=""
    fi

    # Use the bundled install_service.sh, passing --no-deps since venv is pre-built
    $SUDO "${ROOT_DIR}/bin/install_service.sh" install --dir="$INSTALL_DIR" --no-deps
    echo ""
else
    echo -e "${YELLOW}Step 7: Skipping systemd service${NC}"
    echo -e "  You can start manually with: ${ROOT_DIR}/bin/start.sh"
    echo ""
fi

# ─── Print configuration guide ───────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Installation complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${YELLOW}IMPORTANT: Before starting, configure these files:${NC}"
echo ""
echo -e "  ${GREEN}1. Backend config:${NC} ${ROOT_DIR}/etc/conf/server.conf"
echo -e "     - ip, port, enable_https, ssl_certfile, ssl_keyfile"
echo -e "     - access_password, persistence_mode, agent_registry_url"
echo ""
echo -e "  ${GREEN}2. LLM config:${NC}    ${ROOT_DIR}/common/config/llm_config.json"
echo -e "     - chat.api_key, chat.url, chat.model"
echo -e "     - embed/rerank settings (if used)"
echo ""
echo -e "  ${GREEN}3. Database config:${NC} ${ROOT_DIR}/etc/conf/db_config.json"
echo -e "     - host, port, user, password (only if persistence_mode=postgresql)"
echo ""
echo -e "  ${GREEN}4. TLS properties:${NC} ${ROOT_DIR}/etc/conf/server.properties"
echo -e "     - tls.version, tls.cipher, connection limits"
echo ""
echo -e "  ${GREEN}5. SSL certs:${NC}     ${ROOT_DIR}/etc/ssl/"
echo -e "     - server.cer, server_key.pem, trust.cer, cert_pwd"
echo -e "     - Generate self-signed: python generate_selfsign_cert.py etc/ssl serverAuth"
echo ""
echo -e "  See: bin/OFFLINE_CONFIG_GUIDE.md for detailed instructions"
echo ""
echo -e "${YELLOW}To start:${NC}"
if [ "$INSTALL_SERVICE" = true ]; then
    echo -e "  sudo systemctl start orchestration-center"
    echo -e "  sudo systemctl status orchestration-center"
else
    echo -e "  ${ROOT_DIR}/bin/start.sh"
    echo -e "  (frontend: cd ${ROOT_DIR}/workflow-designer && npm run dev)"
fi
echo ""
