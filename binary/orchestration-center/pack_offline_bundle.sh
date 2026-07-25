#!/bin/bash
# =============================================================================
# pack_offline_bundle.sh
# =============================================================================
# Run this on the ONLINE machine to build a self-contained offline deployment
# package for the Orchestration Center.
#
# The resulting tarball contains:
#   - Full project source code
#   - Pre-built Python venv (all pip dependencies installed)
#   - Pre-built frontend node_modules (npm dependencies installed)
#   - npm cache tarball (for offline npm ci if rebuild is needed)
#   - pip wheel cache (for offline pip install if rebuild is needed)
#   - Config templates (user edits these on the air-gapped machine)
#
# Usage:
#   ./scripts/pack_offline_bundle.sh [--skip-frontend]
#
# Prerequisites on the online machine:
#   - Python 3.11+
#   - Node.js 20.19+
#   - npm
#   - Internet access (for pip download and npm install)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_NAME="orchestration-center-offline"
BUILD_DIR="${ROOT_DIR}/.offline-build"
BUNDLE_DIR="${BUILD_DIR}/${BUNDLE_NAME}"
SKIP_FRONTEND=false

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-frontend)
            SKIP_FRONTEND=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--skip-frontend]"
            echo ""
            echo "Options:"
            echo "  --skip-frontend   Skip building frontend dependencies (backend-only bundle)"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Offline Bundle Packager${NC}"
echo -e "${BLUE}  Orchestration Center${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ─── Check prerequisites ─────────────────────────────────────────────────────
echo -e "${YELLOW}Step 0: Checking prerequisites...${NC}"

# Auto-detect Python 3.12+ — try common binary names in order of preference
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" &>/dev/null; then
        CAND_VERSION=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        CAND_MAJOR=$(echo "$CAND_VERSION" | cut -d. -f1)
        CAND_MINOR=$(echo "$CAND_VERSION" | cut -d. -f2)
        if [ "$CAND_MAJOR" -eq 3 ] && [ "$CAND_MINOR" -ge 12 ]; then
            PYTHON_BIN="$candidate"
            PY_VERSION="$CAND_VERSION"
            break
        fi
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo -e "${RED}Error: Python 3.12+ not found.${NC}"
    echo -e "       Searched: python3.13, python3.12, python3.11, python3"
    echo -e "       The project requires Python 3.12+."
    echo -e "       Install it with:"
    echo -e "         Ubuntu/Debian: sudo apt install python3.12"
    echo -e "         Or use pyenv:  pyenv install 3.12 && pyenv local 3.12"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Python ${PY_VERSION} ($PYTHON_BIN)"

if [ "$SKIP_FRONTEND" = false ]; then
    if ! command -v node &>/dev/null; then
        echo -e "${RED}Error: node not found. Need Node.js 20.19+.${NC}"
        exit 1
    fi
    NODE_VERSION=$(node --version | sed 's/v//')
    echo -e "  ${GREEN}✓${NC} Node.js ${NODE_VERSION}"

    if ! command -v npm &>/dev/null; then
        echo -e "${RED}Error: npm not found.${NC}"
        exit 1
    fi
    NPM_VERSION=$(npm --version)
    echo -e "  ${GREEN}✓${NC} npm ${NPM_VERSION}"
fi

echo ""

# ─── Clean previous build ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Cleaning previous build...${NC}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUNDLE_DIR"
echo -e "  ${GREEN}✓${NC} Build directory ready: $BUNDLE_DIR"
echo ""

# ─── Copy project source ─────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Copying project source...${NC}"

# Use rsync to copy, excluding things we don't want in the bundle
if command -v rsync &>/dev/null; then
    rsync -a \
        --exclude='.git' \
        --exclude='.offline-build' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.venv' \
        --exclude='venv' \
        --exclude='node_modules' \
        --exclude='.pytest_cache' \
        --exclude='.ruff_cache' \
        --exclude='.mypy_cache' \
        --exclude='/log/' \
        --exclude='/run/' \
        --exclude='*.log' \
        "$ROOT_DIR/" "$BUNDLE_DIR/"
else
    # Fallback: cp + manual cleanup
    cp -r "$ROOT_DIR"/* "$BUNDLE_DIR/"
    cp -r "$ROOT_DIR"/.??* "$BUNDLE_DIR/" 2>/dev/null || true
    rm -rf "$BUNDLE_DIR/.git" "$BUNDLE_DIR/.offline-build"
    find "$BUNDLE_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
    find "$BUNDLE_DIR" -name '*.pyc' -delete 2>/dev/null || true
    rm -rf "$BUNDLE_DIR/.venv" "$BUNDLE_DIR/venv" "$BUNDLE_DIR/workflow-designer/node_modules"
    rm -rf "$BUNDLE_DIR/.pytest_cache" "$BUNDLE_DIR/.ruff_cache" "$BUNDLE_DIR/.mypy_cache"
fi
echo -e "  ${GREEN}✓${NC} Source copied"
echo ""

# ─── Build Python venv ───────────────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Building Python virtual environment...${NC}"

VENV_DIR="${BUNDLE_DIR}/venv"
"$PYTHON_BIN" -m venv "$VENV_DIR"
echo -e "  ${GREEN}✓${NC} venv created at $VENV_DIR"

VENV_PIP="$VENV_DIR/bin/pip"
VENV_PYTHON="$VENV_DIR/bin/python3"

# Upgrade pip and install dependencies
echo -e "  ${YELLOW}Installing pip dependencies (this may take a while)...${NC}"
"$VENV_PIP" install --upgrade pip wheel setuptools
"$VENV_PIP" install -r "${BUNDLE_DIR}/requirements.txt"
echo -e "  ${GREEN}✓${NC} Python dependencies installed"

# Also download wheels for offline re-install if needed
echo -e "  ${YELLOW}Downloading wheels for offline fallback...${NC}"
WHEELS_DIR="${BUNDLE_DIR}/vendor/wheels"
mkdir -p "$WHEELS_DIR"
"$VENV_PIP" download -r "${BUNDLE_DIR}/requirements.txt" -d "$WHEELS_DIR"
echo -e "  ${GREEN}✓${NC} Wheels cached: $(ls "$WHEELS_DIR" | wc -l) packages"
echo ""

# ─── Build frontend ──────────────────────────────────────────────────────────
if [ "$SKIP_FRONTEND" = false ]; then
    echo -e "${YELLOW}Step 4: Building frontend dependencies...${NC}"

    FRONTEND_DIR="${BUNDLE_DIR}/workflow-designer"
    cd "$FRONTEND_DIR"

    echo -e "  ${YELLOW}Running npm install (this may take a while)...${NC}"
    npm install --force
    echo -e "  ${GREEN}✓${NC} node_modules installed"

    # Pack npm cache for offline rebuild if needed
    echo -e "  ${YELLOW}Packing npm cache for offline fallback...${NC}"
    NPM_CACHE_DIR="${BUNDLE_DIR}/vendor/npm-cache"
    mkdir -p "$NPM_CACHE_DIR"
    # Use npm pack to create tarballs of all dependencies
    npm cache verify 2>/dev/null || true
    # Copy the npm cache
    NPM_GLOBAL_CACHE=$(npm config get cache 2>/dev/null || echo "")
    if [ -n "$NPM_GLOBAL_CACHE" ] && [ -d "$NPM_GLOBAL_CACHE" ]; then
        cp -r "$NPM_GLOBAL_CACHE"/* "$NPM_CACHE_DIR/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} npm cache copied"
    else
        echo -e "  ${YELLOW}⚠ npm cache not found, skipping${NC}"
    fi

    cd "$ROOT_DIR"
    echo ""
else
    echo -e "${YELLOW}Step 4: Skipping frontend (--skip-frontend)${NC}"
    echo ""
fi

# ─── Copy in the offline install script ──────────────────────────────────────
echo -e "${YELLOW}Step 5: Adding offline install script...${NC}"
# The install script is already in scripts/ and was copied with the source
# Just make sure it's executable
chmod +x "${BUNDLE_DIR}/bin/install_offline.sh" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/bin/install_service.sh" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/bin/start.sh" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/bin/stop.sh" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/bin/start_samples.sh" 2>/dev/null || true
chmod +x "${BUNDLE_DIR}/bin/stop_samples.sh" 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Scripts are executable"
echo ""

# ─── Create bundle manifest ──────────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Creating manifest...${NC}"
MANIFEST="${BUNDLE_DIR}/OFFLINE_BUNDLE_MANIFEST.txt"

cat > "$MANIFEST" << EOF
============================================================
  Orchestration Center - Offline Deployment Bundle
============================================================

Bundle created:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Created on host:   $(hostname)
Python version:    $("$PYTHON_BIN" --version)
Node.js version:   $(node --version 2>/dev/null || echo 'N/A (frontend skipped)')
npm version:       $(npm --version 2>/dev/null || echo 'N/A (frontend skipped)')

Contents:
  - Project source code (Python + React)
  - venv/                — Pre-built Python virtual environment
  - vendor/wheels/       — pip wheels for offline re-install
  - vendor/npm-cache/    — npm cache for offline rebuild (if frontend bundled)
  - workflow-designer/node_modules/ — Pre-built frontend deps (if frontend bundled)
  - etc/conf/            — Configuration files (EDIT THESE on target machine)
  - common/config/       — LLM configuration (EDIT THESE on target machine)

To install on the air-gapped machine:
  1. Extract: tar xzf orchestration-center-offline-bundle.tar.gz
  2. Run:     ./bin/install_offline.sh
  3. Edit config files (see bin/OFFLINE_CONFIG_GUIDE.md)
  4. Start:   bin/start.sh  (or bin/install_service.sh install for systemd)

EOF

echo -e "  ${GREEN}✓${NC} Manifest created"
echo ""

# ─── Create the tarball ──────────────────────────────────────────────────────
echo -e "${YELLOW}Step 7: Creating tarball...${NC}"

TARBALL="${ROOT_DIR}/${BUNDLE_NAME}-bundle.tar.gz"

# Go to build dir parent so the tarball has a clean top-level dir name
cd "$BUILD_DIR"
tar czf "$TARBALL" "$BUNDLE_NAME"
cd "$ROOT_DIR"

TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
echo -e "  ${GREEN}✓${NC} Tarball created: $TARBALL ($TARBALL_SIZE)"
echo ""

# ─── Summary ─────────────────────────────────────────────────────────────────
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Bundle created successfully!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Output:  $TARBALL"
echo "Size:    $TARBALL_SIZE"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Copy $TARBALL to the air-gapped machine (USB, SCP, etc.)"
echo "  2. Extract:  tar xzf ${BUNDLE_NAME}-bundle.tar.gz"
echo "  3. Install:  ./${BUNDLE_NAME}/bin/install_offline.sh"
echo "  4. Configure: edit files in etc/conf/ and common/config/"
echo "     (see bin/OFFLINE_CONFIG_GUIDE.md for details)"
echo "  5. Start:    bin/start.sh"
echo ""
