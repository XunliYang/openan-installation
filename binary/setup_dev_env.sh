#!/bin/bash
# =============================================================================
# Development environment setup script
# Clones registry-center & orchestration-center, creates venvs, and starts all services.
# Prerequisites: python3.12, node/npm, git
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

REGISTRY_REPO="https://github.com/huang2001junjie-rgb/registry-center"
ORCHESTRATION_REPO="https://github.com/huang2001junjie-rgb/orchestration-center"

REGISTRY_DIR="${WORK_DIR}/registry-center"
ORCHESTRATION_DIR="${WORK_DIR}/orchestration-center"

CERT_PASSWORD="Dev@12345"

# =============================================================================
# Step 1: Clone repositories
# =============================================================================
echo "=========================================="
echo " Step 1: Cloning repositories"
echo "=========================================="

if [ -d "${REGISTRY_DIR}/.git" ]; then
    echo "[SKIP] registry-center already exists, pulling latest..."
    git -C "${REGISTRY_DIR}" pull --ff-only || true
else
    echo "[CLONE] registry-center..."
    git clone "${REGISTRY_REPO}" "${REGISTRY_DIR}"
fi

if [ -d "${ORCHESTRATION_DIR}/.git" ]; then
    echo "[SKIP] orchestration-center already exists, pulling latest..."
    git -C "${ORCHESTRATION_DIR}" pull --ff-only || true
else
    echo "[CLONE] orchestration-center..."
    git clone "${ORCHESTRATION_REPO}" "${ORCHESTRATION_DIR}"
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

# Start registry-center
echo "[START] registry-center (http://127.0.0.1:5000)..."
cd "${REGISTRY_DIR}"
source venv/bin/activate
nohup python -m agent_registry.start > "${REGISTRY_DIR}/registry-center.log" 2>&1 &
REGISTRY_PID=$!
echo "  PID: ${REGISTRY_PID}"

# Start orchestration-center backend (port 5001)
echo "[START] orchestration-center backend (http://127.0.0.1:5001)..."
cd "${ORCHESTRATION_DIR}"
source venv/bin/activate
nohup python -m orchestrate.start > "${ORCHESTRATION_DIR}/backend.log" 2>&1 &
OC_BACKEND_PID=$!
echo "  PID: ${OC_BACKEND_PID}"

# Start orchestration-center frontend (port 3003)
FRONTEND_PORT=3003
echo "[START] orchestration-center frontend (http://localhost:${FRONTEND_PORT})..."

# Free the port if already in use (e.g. leftover process from a previous run)
if command -v fuser >/dev/null 2>&1; then
    fuser -k "${FRONTEND_PORT}/tcp" 2>/dev/null || true
elif command -v lsof >/dev/null 2>&1; then
    lsof -t -i:"${FRONTEND_PORT}" 2>/dev/null | xargs -r kill 2>/dev/null || true
fi
sleep 1

cd "${ORCHESTRATION_DIR}/workflow-designer"
nohup npm run dev > "${ORCHESTRATION_DIR}/frontend.log" 2>&1 &
OC_FRONTEND_PID=$!
echo "  PID: ${OC_FRONTEND_PID}"

# Wait and verify the frontend is actually listening
FRONTEND_OK=false
echo "  [WAIT] Verifying frontend startup..."
for _ in $(seq 1 20); do
    if ! kill -0 "${OC_FRONTEND_PID}" 2>/dev/null; then
        echo "  [ERROR] Frontend process exited unexpectedly."
        echo "          Check log: ${ORCHESTRATION_DIR}/frontend.log"
        break
    fi
    if ss -lnt 2>/dev/null | grep -q ":${FRONTEND_PORT}\b"; then
        echo "  [OK] Frontend is listening on port ${FRONTEND_PORT}"
        FRONTEND_OK=true
        break
    fi
    sleep 1
done
if [ "${FRONTEND_OK}" = "false" ]; then
    echo "  [WARN] Frontend may not have started. Check ${ORCHESTRATION_DIR}/frontend.log"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=========================================="
echo " All services started!"
echo "=========================================="
echo " registry-center:        http://127.0.0.1:5000  (PID: ${REGISTRY_PID})"
echo " orchestration backend:  http://127.0.0.1:5001  (PID: ${OC_BACKEND_PID})"
echo " orchestration frontend: http://localhost:3003   (PID: ${OC_FRONTEND_PID})"
echo ""
echo " Logs:"
echo "   ${REGISTRY_DIR}/registry-center.log"
echo "   ${ORCHESTRATION_DIR}/backend.log"
echo "   ${ORCHESTRATION_DIR}/frontend.log"
echo ""
echo " To stop all: kill ${REGISTRY_PID} ${OC_BACKEND_PID} ${OC_FRONTEND_PID}"
echo "=========================================="
