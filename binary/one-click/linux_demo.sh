#!/bin/bash
# =============================================================================
# Development environment setup script
# Clones registry-center (git) & downloads orchestration-center release, creates venvs, and starts all services.
# Prerequisites: python3.12, node/npm, git, curl, tar
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

REGISTRY_REPO="https://github.com/project-openan/registry-center.git"
ORCHESTRATION_RELEASE_URL="https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz"
ORCHESTRATION_VERSION="v1.0.0"

REGISTRY_DIR="${WORK_DIR}/registry-center"
ORCHESTRATION_DIR="${WORK_DIR}/orchestration-center"

CERT_PASSWORD="Dev@12345"

# -----------------------------------------------------------------------------
# Helper: kill any process listening on a given TCP port.
# Prevents leftover processes from a previous run causing PID mismatches.
# -----------------------------------------------------------------------------
free_port() {
    local port="$1"
    local pids=""
    if command -v fuser >/dev/null 2>&1; then
        pids="$(fuser "${port}/tcp" 2>/dev/null)" || true
    elif command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -t -i:"${port}" 2>/dev/null)" || true
    elif command -v ss >/dev/null 2>&1; then
        pids="$(ss -tlnp 2>/dev/null | grep ":${port}\b" | grep -oE 'pid=[0-9]+' | cut -d= -f2)" || true
    fi
    if [ -n "${pids}" ]; then
        echo "  [WARN] Port ${port} is in use, killing PID(s): ${pids}..."
        echo "${pids}" | tr ' ' '\n' | xargs -r kill 2>/dev/null || true
        sleep 1
        # Force kill if still alive
        echo "${pids}" | tr ' ' '\n' | xargs -r kill -9 2>/dev/null || true
    fi
}

# =============================================================================
# Step 1: Prepare repositories
# =============================================================================
echo "=========================================="
echo " Step 1: Fetching repositories"
echo "=========================================="

if [ -d "${REGISTRY_DIR}/.git" ]; then
    echo "[SKIP] registry-center already exists, pulling latest..."
    git -C "${REGISTRY_DIR}" pull --ff-only || true
else
    echo "[CLONE] registry-center..."
    git clone "${REGISTRY_REPO}" "${REGISTRY_DIR}"
fi

if [ -d "${ORCHESTRATION_DIR}" ] && [ -n "$(ls -A "${ORCHESTRATION_DIR}" 2>/dev/null)" ]; then
    echo "[SKIP] orchestration-center already exists, skipping download..."
else
    rm -rf "${ORCHESTRATION_DIR}"
    echo "[DOWNLOAD] orchestration-center release ${ORCHESTRATION_VERSION}..."
    TMP_TAR=$(mktemp /tmp/orchestration-center-XXXXXX.tar.gz)
    if curl -fsSL "${ORCHESTRATION_RELEASE_URL}" -o "${TMP_TAR}"; then
        mkdir -p "${ORCHESTRATION_DIR}"
        tar -xzf "${TMP_TAR}" -C "${ORCHESTRATION_DIR}" --strip-components=1
        echo "  [OK] orchestration-center ${ORCHESTRATION_VERSION} downloaded and extracted."
    else
        echo "  [ERROR] Failed to download orchestration-center release."
        rm -f "${TMP_TAR}"
        exit 1
    fi
    rm -f "${TMP_TAR}"
fi

# =============================================================================
# Step 2: Setup registry-center
# =============================================================================
echo ""
echo "=========================================="
echo " Step 2: Setting up registry-center"
echo "=========================================="

cd "${REGISTRY_DIR}"

# Create venv
if [ ! -d "venv" ]; then
    echo "[VENV] Creating virtual environment..."
    python3.12 -m venv venv
fi
source venv/bin/activate

# Install dependencies
echo "[PIP] Installing registry-center dependencies..."
pip install --upgrade pip -q
pip install -r requirements.txt -q

# Generate self-signed certificate (serverAuth)
echo "[CERT] Generating self-signed certificates..."
CERT_DIR="${REGISTRY_DIR}/etc/cert"
mkdir -p "${CERT_DIR}"

python3 -c "
import sys
sys.path.insert(0, '.')
from common.cert.certificate_generator import CertificateGenerator

generator = CertificateGenerator(key_algorithm='RSA')
if generator.generate_self_signed_cert('${CERT_DIR}', 'serverAuth', '${CERT_PASSWORD}'):
    print('  [OK] Self-signed certificate generated in ${CERT_DIR}')
else:
    print('  [SKIP] Certificate already exists')
"

# Run init with automated input:
#   - IP: default (empty -> 127.0.0.1)
#   - Port: default (empty -> 5000)
#   - Enable HTTPS: n
#   - Enable registry signing: n
#   - Enable signature validation: n
#   - Enable agent approval: n
#   - Storage mode: file
echo "[INIT] Running registry-center initialization..."
printf '\n\nn\nn\nn\nn\nfile\n' | python -m agent_registry.init

echo "[DONE] registry-center initialized."

# =============================================================================
# Step 3: Setup orchestration-center
# =============================================================================
echo ""
echo "=========================================="
echo " Step 3: Setting up orchestration-center"
echo "=========================================="

cd "${ORCHESTRATION_DIR}"

# Create venv
if [ ! -d "venv" ]; then
    echo "[VENV] Creating virtual environment..."
    python3.12 -m venv venv
fi
source venv/bin/activate

# Install backend dependencies
echo "[PIP] Installing orchestration-center backend dependencies..."
pip install --upgrade pip -q
if [ -f "requirements.txt" ]; then
    pip install -r requirements.txt -q
fi

# Install frontend dependencies
echo "[NPM] Installing orchestration-center frontend dependencies..."
cd "${ORCHESTRATION_DIR}/workflow-designer"
npm install --force

cd "${ORCHESTRATION_DIR}"

# =============================================================================
# Step 4: Start all services
# =============================================================================
echo ""
echo "=========================================="
echo " Step 4: Starting all services"
echo "=========================================="

# Start registry-center (port 5000)
free_port 5000
echo "[START] registry-center (http://127.0.0.1:5000)..."
cd "${REGISTRY_DIR}"
source venv/bin/activate
nohup python -m agent_registry.start > "${REGISTRY_DIR}/registry-center.log" 2>&1 &
REGISTRY_PID=$!
echo "  PID: ${REGISTRY_PID}"

# Start orchestration-center backend (port 5001)
free_port 5001
echo "[START] orchestration-center backend (http://127.0.0.1:5001)..."
cd "${ORCHESTRATION_DIR}"
source venv/bin/activate
nohup python -m orchestrate.start > "${ORCHESTRATION_DIR}/backend.log" 2>&1 &
OC_BACKEND_PID=$!
echo "  PID: ${OC_BACKEND_PID}"

# Start orchestration-center frontend (port 3003)
FRONTEND_PORT=3003
free_port "${FRONTEND_PORT}"
echo "[START] orchestration-center frontend (http://localhost:${FRONTEND_PORT})..."

cd "${ORCHESTRATION_DIR}/workflow-designer"
nohup npm run dev > "${ORCHESTRATION_DIR}/frontend.log" 2>&1 &
OC_FRONTEND_PID=$!
echo "  PID: ${OC_FRONTEND_PID}"

# Wait and verify the frontend is actually listening
# NOTE: ss -lntp requires root to see PIDs, so we detect the port with ss -lnt
# (no -p) first, then try to grab the PID as best-effort extra info.
FRONTEND_OK=false
FRONTEND_REAL_PID="${OC_FRONTEND_PID}"
echo "  [WAIT] Verifying frontend startup (up to 30s)..."
for _ in $(seq 1 30); do
    if ! kill -0 "${OC_FRONTEND_PID}" 2>/dev/null; then
        echo "  [ERROR] Frontend process exited unexpectedly."
        echo "          --- Last 20 lines of frontend.log ---"
        tail -n 20 "${ORCHESTRATION_DIR}/frontend.log" 2>/dev/null | sed 's/^/          /'
        break
    fi
    # Check if the port is listening (does NOT require root)
    if ss -lnt 2>/dev/null | grep -q ":${FRONTEND_PORT}\b"; then
        # Best-effort: try to grab the actual PID owning the port
        # NOTE: || true prevents set -e from exiting when grep finds no match
        _pid=$(ss -lntp 2>/dev/null | grep ":${FRONTEND_PORT}\b" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
        [ -n "${_pid}" ] && FRONTEND_REAL_PID="${_pid}"
        echo "  [OK] Frontend is listening on port ${FRONTEND_PORT} (PID: ${FRONTEND_REAL_PID})"
        FRONTEND_OK=true
        break
    fi
    sleep 1
done
if [ "${FRONTEND_OK}" = "false" ]; then
    echo "  [WARN] Frontend may not have started on port ${FRONTEND_PORT}."
    echo "         --- Last 20 lines of frontend.log ---"
    tail -n 20 "${ORCHESTRATION_DIR}/frontend.log" 2>/dev/null | sed 's/^/         /'
fi

# Start agents examples server (provides sample agents for testing)
AGENTS_PORT=8080
free_port "${AGENTS_PORT}"
echo "[START] agents examples server (http://127.0.0.1:${AGENTS_PORT})..."
cd "${ORCHESTRATION_DIR}"
source venv/bin/activate
nohup python -m samples.start_agents_server > "${ORCHESTRATION_DIR}/agents-server.log" 2>&1 &
AGENTS_PID=$!
echo "  PID: ${AGENTS_PID}"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=========================================="
echo " All services started!"
echo "=========================================="
echo " registry-center:        http://127.0.0.1:5000  (PID: ${REGISTRY_PID})"
echo " orchestration backend:  http://127.0.0.1:5001  (PID: ${OC_BACKEND_PID})"
echo " orchestration frontend: http://localhost:3003   (PID: ${FRONTEND_REAL_PID})"
echo " agents examples server: http://127.0.0.1:${AGENTS_PORT}  (PID: ${AGENTS_PID})"
echo ""
echo " Logs:"
echo "   ${REGISTRY_DIR}/registry-center.log"
echo "   ${ORCHESTRATION_DIR}/backend.log"
echo "   ${ORCHESTRATION_DIR}/frontend.log"
echo "   ${ORCHESTRATION_DIR}/agents-server.log"
echo ""
echo " To stop all: kill ${REGISTRY_PID} ${OC_BACKEND_PID} ${FRONTEND_REAL_PID} ${AGENTS_PID}"
echo "=========================================="
