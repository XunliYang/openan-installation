#!/bin/bash
# =============================================================================
# Development environment setup script
# Downloads registry-center & orchestration-center releases, creates venvs, and starts all services.
# Prerequisites: python3.12 (>=3.12), node (>=20.19), npm, git, curl, tar
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}"

REGISTRY_RELEASE_URL="https://github.com/project-openan/registry-center/archive/refs/tags/v1.0.0.tar.gz"
REGISTRY_VERSION="v1.0.0"
ORCHESTRATION_RELEASE_URL="https://github.com/project-openan/orchestration-center/archive/refs/tags/v1.0.0.tar.gz"
ORCHESTRATION_VERSION="v1.0.0"

REGISTRY_DIR="${WORK_DIR}/registry-center"
ORCHESTRATION_DIR="${WORK_DIR}/orchestration-center"

CERT_PASSWORD="Dev@12345"

# =============================================================================
# Python 3.12+ resolution functions
# Tries: existing python3.12/python3 → apt/dnf install → standalone download
# Supports: x86_64 & aarch64, Debian/Ubuntu & CentOS/RHEL/Rocky/Alma
# =============================================================================

PYTHON_CMD=""

# Check if a given Python command provides version >= 3.12.
# Echoes the version string on success; returns 1 on failure.
check_python_version() {
    local cmd="$1"
    local ver
    ver=$("$cmd" --version 2>&1 | awk '{print $2}') || return 1
    [ -n "$ver" ] || return 1
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    if [ "${major}" -eq 3 ] && [ "${minor}" -ge 12 ]; then
        echo "$ver"
        return 0
    fi
    return 1
}

# Run a command with sudo if not root, or directly if root.
run_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Try to install Python 3.12 via apt (Debian/Ubuntu).
install_python_apt() {
    echo "  [TRY] Attempting apt install python3.12..."
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [WARN] sudo not available, skipping apt install."
        return 1
    fi

    run_sudo apt-get update -qq 2>/dev/null || true
    run_sudo apt-get install -y -qq python3.12 python3.12-venv 2>/dev/null || true

    if command -v python3.12 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver installed via apt"
            return 0
        fi
    fi

    # Try deadsnakes PPA (Ubuntu)
    if command -v add-apt-repository >/dev/null 2>&1; then
        echo "  [TRY] Adding deadsnakes PPA (Ubuntu)..."
        run_sudo add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
        run_sudo apt-get update -qq 2>/dev/null || true
        run_sudo apt-get install -y -qq python3.12 python3.12-venv 2>/dev/null || true
        if command -v python3.12 >/dev/null 2>&1; then
            local ver2
            ver2=$(check_python_version python3.12 2>/dev/null) || true
            if [ -n "$ver2" ]; then
                PYTHON_CMD="python3.12"
                echo "  [OK] Python $ver2 installed via deadsnakes PPA"
                return 0
            fi
        fi
    fi

    echo "  [WARN] apt install did not provide Python 3.12."
    return 1
}

# Try to install Python 3.12 via dnf/yum (CentOS/RHEL/Rocky/Alma).
install_python_yum() {
    local pkg_mgr=""
    if command -v dnf >/dev/null 2>&1; then
        pkg_mgr="dnf"
    elif command -v yum >/dev/null 2>&1; then
        pkg_mgr="yum"
    else
        echo "  [WARN] Neither dnf nor yum found."
        return 1
    fi

    echo "  [TRY] Attempting $pkg_mgr install python3.12..."
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [WARN] sudo not available, skipping $pkg_mgr install."
        return 1
    fi

    run_sudo "$pkg_mgr" install -y python3.12 2>/dev/null || true

    if command -v python3.12 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver installed via $pkg_mgr"
            return 0
        fi
    fi

    # Try dnf module (RHEL 8/9)
    run_sudo "$pkg_mgr" module enable python3.12 2>/dev/null || true
    run_sudo "$pkg_mgr" install -y python3.12 2>/dev/null || true

    if command -v python3.12 >/dev/null 2>&1; then
        local ver2
        ver2=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver2" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver2 installed via $pkg_mgr module"
            return 0
        fi
    fi

    echo "  [WARN] $pkg_mgr install did not provide Python 3.12."
    return 1
}

# Download a prebuilt standalone Python 3.12 (python-build-standalone project).
# Works on any Linux with glibc, regardless of distribution.
install_python_standalone() {
    local py_arch="$1"
    local INSTALL_DIR="${WORK_DIR}/.python3.12"

    command -v curl >/dev/null 2>&1 || { echo "  [ERROR] curl is required to download Python."; return 1; }
    command -v tar  >/dev/null 2>&1 || { echo "  [ERROR] tar is required to extract Python.";  return 1; }

    local API_URL="https://api.github.com/repos/indygreg/python-build-standalone/releases/latest"
    echo "  [DOWNLOAD] Fetching latest Python 3.12 standalone build for ${py_arch}..."

    local release_info
    release_info=$(curl -fsSL "$API_URL" 2>/dev/null) || {
        echo "  [ERROR] Failed to fetch release info from GitHub API."
        return 1
    }

    # Find the matching asset: cpython-3.12.*-<arch>-unknown-linux-gnu-install_only_stripped.tar.gz
    local asset_url
    asset_url=$(echo "$release_info" | grep '"browser_download_url"' | \
        grep 'cpython-3\.12\.' | \
        grep "${py_arch}-unknown-linux-gnu" | \
        grep 'install_only_stripped\.tar\.gz' | \
        head -1 | sed 's/.*"browser_download_url": *"//;s/".*//') || asset_url=""

    if [ -z "$asset_url" ]; then
        echo "  [ERROR] Could not find a Python 3.12 standalone build for ${py_arch}."
        return 1
    fi

    echo "  [DOWNLOAD] URL: $asset_url"
    local tmp_tar
    tmp_tar=$(mktemp /tmp/python-3.12-XXXXXX.tar.gz)
    if ! curl -fsSL "$asset_url" -o "$tmp_tar"; then
        echo "  [ERROR] Failed to download Python 3.12."
        rm -f "$tmp_tar"
        return 1
    fi

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$tmp_tar" -C "$INSTALL_DIR"
    rm -f "$tmp_tar"

    # The standalone build extracts to python/bin/python3.12
    local py_bin="${INSTALL_DIR}/python/bin/python3.12"
    if [ ! -f "$py_bin" ]; then
        py_bin="${INSTALL_DIR}/python/bin/python3"
    fi
    if [ ! -f "$py_bin" ]; then
        echo "  [ERROR] Python binary not found after extraction."
        return 1
    fi

    chmod +x "$py_bin"
    # Ensure python3 and python symlinks exist
    ln -sf "$py_bin" "${INSTALL_DIR}/python/bin/python3"
    ln -sf "$py_bin" "${INSTALL_DIR}/python/bin/python"

    # Add to PATH for this session
    export PATH="${INSTALL_DIR}/python/bin:${PATH}"
    PYTHON_CMD="$py_bin"

    local ver
    ver=$("$PYTHON_CMD" --version 2>&1 | awk '{print $2}')
    echo "  [OK] Python $ver installed (standalone)"
    echo "  [INFO] Location: ${INSTALL_DIR}/python"

    # Verify venv module works (required for later steps)
    if ! "$PYTHON_CMD" -m venv --help >/dev/null 2>&1; then
        echo "  [ERROR] venv module not available in standalone Python."
        return 1
    fi
}

# Main Python resolution: try existing → package manager → standalone download.
resolve_python() {
    # 1. Try python3.12
    if command -v python3.12 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3.12 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3.12"
            echo "  [OK] Python $ver (python3.12)"
            return 0
        fi
    fi

    # 2. Try python3
    if command -v python3 >/dev/null 2>&1; then
        local ver
        ver=$(check_python_version python3 2>/dev/null) || true
        if [ -n "$ver" ]; then
            PYTHON_CMD="python3"
            echo "  [OK] Python $ver (python3)"
            return 0
        fi
    fi

    # 3. Not found — attempt automatic installation
    echo "  [INFO] Python 3.12+ not found on this system."
    echo "         Will attempt automatic installation..."

    # Detect architecture
    local arch py_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)  py_arch="x86_64" ;;
        aarch64|arm64) py_arch="aarch64" ;;
        *)
            echo "[ERROR] Unsupported architecture: $arch"
            echo "        Please install Python 3.12+ manually."
            exit 1
            ;;
    esac

    # Detect distribution
    local distro="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) distro="debian" ;;
            centos|rhel|rocky|almalinux|fedora|amzn) distro="centos" ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*) distro="debian" ;;
                    *rhel*|*fedora*|*centos*) distro="centos" ;;
                esac
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        distro="debian"
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        distro="centos"
    fi

    echo "  [INFO] Architecture: $py_arch, Distribution: $distro"

    # Try package manager first
    if [ "$distro" = "debian" ]; then
        install_python_apt || true
    elif [ "$distro" = "centos" ]; then
        install_python_yum || true
    fi

    if [ -n "$PYTHON_CMD" ]; then
        return 0
    fi

    # Fallback: download standalone Python (works on any distro with glibc)
    echo "  [INFO] Package manager install unavailable or failed."
    echo "         Downloading standalone Python 3.12 (python-build-standalone)..."
    install_python_standalone "$py_arch" || {
        echo "[ERROR] All Python installation methods failed."
        echo "        Please install Python 3.12+ manually from https://www.python.org/downloads/"
        exit 1
    }
}

# =============================================================================
# Step 0: Verify prerequisites
# =============================================================================
echo "=========================================="
echo " Step 0: Verifying prerequisites"
echo "=========================================="

# Check Python 3.12+ (auto-install if not found)
resolve_python

# Check Node.js 20.19+
if ! command -v node >/dev/null 2>&1; then
    echo "[ERROR] Node.js is not installed or not on PATH."
    echo "        Please install Node.js 20.19+ from https://nodejs.org/"
    exit 1
fi
NODE_VERSION=$(node --version 2>/dev/null | sed 's/v//')
NODE_MAJOR=$(echo "${NODE_VERSION}" | cut -d. -f1)
NODE_MINOR=$(echo "${NODE_VERSION}" | cut -d. -f2)
if [ "${NODE_MAJOR}" -lt 20 ] || { [ "${NODE_MAJOR}" -eq 20 ] && [ "${NODE_MINOR}" -lt 19 ]; }; then
    echo "[ERROR] Node.js 20.19+ required, found v${NODE_VERSION}."
    exit 1
fi
echo "  [OK] Node.js v${NODE_VERSION}"

# Check npm
if ! command -v npm >/dev/null 2>&1; then
    echo "[ERROR] npm is not installed. Please install Node.js 18+ which includes npm."
    exit 1
fi
echo "  [OK] npm $(npm --version 2>/dev/null)"

# Check curl and tar
command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl is not installed."; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "[ERROR] tar is not installed."; exit 1; }
echo "  [OK] curl and tar available"

# Check nginx (auto-install if not found)
setup_nginx

echo ""

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

# -----------------------------------------------------------------------------
# Detect Linux distribution for package manager selection.
# Echoes "debian", "centos", or "unknown".
# -----------------------------------------------------------------------------
detect_distro() {
    local distro="unknown"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            debian|ubuntu) distro="debian" ;;
            centos|rhel|rocky|almalinux|fedora|amzn) distro="centos" ;;
            *)
                case "${ID_LIKE:-}" in
                    *debian*) distro="debian" ;;
                    *rhel*|*fedora*|*centos*) distro="centos" ;;
                esac
                ;;
        esac
    elif [ -f /etc/debian_version ]; then
        distro="debian"
    elif [ -f /etc/centos-release ] || [ -f /etc/redhat-release ]; then
        distro="centos"
    fi
    echo "$distro"
}

# -----------------------------------------------------------------------------
# Install nginx and openssl if not already present.
# Uses apt (Debian/Ubuntu) or dnf/yum (CentOS/RHEL/Rocky/Alma).
# -----------------------------------------------------------------------------
setup_nginx() {
    local need_nginx=false
    local need_openssl=false

    if ! command -v nginx >/dev/null 2>&1; then
        need_nginx=true
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        need_openssl=true
    fi

    if [ "$need_nginx" = "false" ] && [ "$need_openssl" = "false" ]; then
        echo "  [OK] nginx $(nginx -v 2>&1 | awk '{print $3}')"
        echo "  [OK] openssl $(openssl version 2>/dev/null | awk '{print $2}')"
        return 0
    fi

    local distro
    distro=$(detect_distro)

    if [ "$distro" = "unknown" ]; then
        echo "  [ERROR] Cannot detect Linux distribution to install nginx."
        echo "          Please install nginx and openssl manually."
        exit 1
    fi

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "  [ERROR] sudo is required but not available."
        echo "          Please install nginx and openssl manually."
        exit 1
    fi

    if [ "$distro" = "debian" ]; then
        echo "  [INFO] Installing nginx and openssl via apt..."
        run_sudo apt-get update -qq 2>/dev/null || true
        run_sudo apt-get install -y -qq nginx openssl 2>/dev/null || true
    elif [ "$distro" = "centos" ]; then
        local pkg_mgr=""
        if command -v dnf >/dev/null 2>&1; then
            pkg_mgr="dnf"
        elif command -v yum >/dev/null 2>&1; then
            pkg_mgr="yum"
        else
            echo "  [ERROR] Neither dnf nor yum found."
            echo "          Please install nginx and openssl manually."
            exit 1
        fi
        echo "  [INFO] Installing nginx and openssl via $pkg_mgr..."
        # Install EPEL for nginx on CentOS/RHEL
        run_sudo "$pkg_mgr" install -y epel-release 2>/dev/null || true
        run_sudo "$pkg_mgr" install -y nginx openssl 2>/dev/null || true
    fi

    # Verify installation
    if ! command -v nginx >/dev/null 2>&1; then
        echo "  [ERROR] nginx installation failed."
        echo "          Please install nginx manually."
        exit 1
    fi
    echo "  [OK] nginx $(nginx -v 2>&1 | awk '{print $3}')"

    if ! command -v openssl >/dev/null 2>&1; then
        echo "  [WARN] openssl not found; SSL certificate generation may fail."
    else
        echo "  [OK] openssl $(openssl version 2>/dev/null | awk '{print $2}')"
    fi
}

# =============================================================================
# Step 1: Prepare repositories
# =============================================================================
echo "=========================================="
echo " Step 1: Fetching repositories"
echo "=========================================="

if [ -d "${REGISTRY_DIR}" ] && [ -n "$(ls -A "${REGISTRY_DIR}" 2>/dev/null)" ]; then
    echo "[SKIP] registry-center already exists, skipping download..."
else
    rm -rf "${REGISTRY_DIR}"
    echo "[DOWNLOAD] registry-center release ${REGISTRY_VERSION}..."
    TMP_TAR=$(mktemp /tmp/registry-center-XXXXXX.tar.gz)
    if curl -fsSL "${REGISTRY_RELEASE_URL}" -o "${TMP_TAR}"; then
        mkdir -p "${REGISTRY_DIR}"
        tar -xzf "${TMP_TAR}" -C "${REGISTRY_DIR}" --strip-components=1
        echo "  [OK] registry-center ${REGISTRY_VERSION} downloaded and extracted."
    else
        echo "  [ERROR] Failed to download registry-center release."
        rm -f "${TMP_TAR}"
        exit 1
    fi
    rm -f "${TMP_TAR}"
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
    ${PYTHON_CMD} -m venv venv
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

# Prepare etc/ssl/ directory with certificate copies expected by server.conf.
# generate_self_signed_cert creates server_RSA.cer and server_key_RSA.pem in etc/cert/,
# but server.conf defaults reference etc/ssl/server.cer and etc/ssl/server_key.pem.
# init.py validates these paths (file exists, correct extension, 0o600 permissions).
echo "[SSL] Preparing SSL directory for init..."
SSL_DIR="${REGISTRY_DIR}/etc/ssl"
mkdir -p "${SSL_DIR}"
cp -f "${CERT_DIR}/server_RSA.cer" "${SSL_DIR}/server.cer"
cp -f "${CERT_DIR}/server_RSA.cer" "${SSL_DIR}/trust.cer"
cp -f "${CERT_DIR}/server_key_RSA.pem" "${SSL_DIR}/server_key.pem"
chmod 600 "${SSL_DIR}/server.cer" "${SSL_DIR}/trust.cer" "${SSL_DIR}/server_key.pem"

# Update jwk_private_key_path in server.conf to point to a valid .pem file.
# Default template has jwk_private_key_path=etc/sign_cert (wrong extension, file missing).
SERVER_CONF="${REGISTRY_DIR}/etc/conf/server.conf"
if [ -f "${SERVER_CONF}" ]; then
    sed -i 's|^jwk_private_key_path=.*|jwk_private_key_path=etc/ssl/server_key.pem|' "${SERVER_CONF}"
fi

# Run init with automated input:
#   - IP: default (empty -> 127.0.0.1)
#   - Port: default (empty -> 5000)
#   - Enable HTTPS: n
#   - Enable registry signing: n
#   - Enable signature validation: n
#   - JWK cert path: default (empty -> etc/ssl/server.cer)
#   - JWK private key path: default (empty -> etc/ssl/server_key.pem)
#   - Enable agent approval: n
#   - Storage mode: default (empty -> file)
echo "[INIT] Running registry-center initialization..."
printf '\n\nn\nn\nn\n\n\nn\n\n' | python -m agent_registry.init

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
    ${PYTHON_CMD} -m venv venv
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
# Step 3.5: Configure LLM API key & fix registry URL
# =============================================================================
echo ""
echo "=========================================="
echo " Step 3.5: Configuring LLM & registry URL"
echo "=========================================="

# --- LLM Configuration ---
# Default values (user can override by typing a different value)
DEFAULT_LLM_MODEL="qwen3.6-flash"
DEFAULT_LLM_URL="https://dashscope.aliyuncs.com/compatible-mode/v1"

echo "[INPUT] LLM configuration is required for the chat model."
echo "        Common providers:"
echo "          Zhipu GLM:   model=glm-5.1      url=https://open.bigmodel.cn/api/paas/v4/chat/completions"
echo "          Aliyun Qwen: model=qwen3.6-flash url=https://dashscope.aliyuncs.com/compatible-mode/v1"
echo ""

# ---------------------------------------------------------------------------
# Function: validate LLM API key and URL by sending a minimal test request.
# Returns 0 if valid, 1 otherwise.
# ---------------------------------------------------------------------------
validate_llm() {
    local model="$1"
    local url="$2"
    local api_key="$3"

    # Construct the chat completions endpoint.
    # If the URL doesn't already end with /chat/completions, append it.
    local test_url="${url}"
    if [[ "${test_url}" != */chat/completions ]]; then
        test_url="${test_url%/}/chat/completions"
    fi

    echo "  [TEST] Validating LLM connection..."
    echo "         URL:   ${test_url}"
    echo "         Model: ${model}"

    local tmp_resp http_code body
    tmp_resp=$(mktemp /tmp/llm-validate-XXXXXX)
    http_code=$(curl -s -o "${tmp_resp}" -w "%{http_code}" \
        -X POST "${test_url}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "{\"model\": \"${model}\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 1}" \
        --connect-timeout 10 \
        --max-time 30 2>/dev/null) || http_code="000"
    body=$(cat "${tmp_resp}" 2>/dev/null)
    rm -f "${tmp_resp}"

    case "${http_code}" in
        200|201)
            echo "  [OK] LLM API validation successful (HTTP ${http_code})."
            return 0
            ;;
        401|403)
            echo "  [ERROR] Authentication failed (HTTP ${http_code}) — invalid API key."
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
        404)
            echo "  [ERROR] Endpoint not found (HTTP 404) — invalid API URL."
            echo "          Tried: ${test_url}"
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
        000)
            echo "  [ERROR] Cannot connect to ${test_url}."
            echo "          Please check the URL and your network connection."
            return 1
            ;;
        *)
            echo "  [ERROR] Validation failed (HTTP ${http_code})."
            [ -n "${body}" ] && echo "          Response: $(printf '%.300s' "${body}")"
            return 1
            ;;
    esac
}

# Read from /dev/tty to ensure we get user input even if stdin is redirected
read -r -p "        Enter LLM model name [${DEFAULT_LLM_MODEL}]: " LLM_MODEL < /dev/tty || LLM_MODEL=""
LLM_MODEL="${LLM_MODEL:-${DEFAULT_LLM_MODEL}}"

read -r -p "        Enter LLM API URL [${DEFAULT_LLM_URL}]: " LLM_URL < /dev/tty || LLM_URL=""
LLM_URL="${LLM_URL:-${DEFAULT_LLM_URL}}"

read -r -p "        Enter your API key: " LLM_API_KEY < /dev/tty || LLM_API_KEY=""

# Validate LLM configuration; retry until valid or user skips
while true; do
    if [ -z "${LLM_API_KEY}" ]; then
        echo "  [WARN] No API key provided. Skipping validation."
        echo "         You can manually edit llm_config.json later to set chat.api_key."
        break
    fi

    if validate_llm "${LLM_MODEL}" "${LLM_URL}" "${LLM_API_KEY}"; then
        break
    fi

    # Validation failed — prompt user for corrected values
    echo ""
    echo "  [RETRY] Please re-enter LLM configuration."
    echo "          (Type 'skip' at any prompt to bypass validation)"
    read -r -p "        Model [${LLM_MODEL}]: " NEW_MODEL < /dev/tty || NEW_MODEL=""
    if [ "${NEW_MODEL}" = "skip" ]; then
        echo "  [WARN] Validation skipped. The configuration may not work correctly."
        break
    fi
    LLM_MODEL="${NEW_MODEL:-${LLM_MODEL}}"

    read -r -p "        API URL [${LLM_URL}]: " NEW_URL < /dev/tty || NEW_URL=""
    if [ "${NEW_URL}" = "skip" ]; then
        echo "  [WARN] Validation skipped. The configuration may not work correctly."
        break
    fi
    LLM_URL="${NEW_URL:-${LLM_URL}}"

    read -r -p "        API key [***]: " NEW_KEY < /dev/tty || NEW_KEY=""
    if [ "${NEW_KEY}" = "skip" ]; then
        echo "  [WARN] Validation skipped. The configuration may not work correctly."
        break
    fi
    LLM_API_KEY="${NEW_KEY:-${LLM_API_KEY}}"
done

# Mask the key for display (show first 4 and last 4 chars)
if [ -n "${LLM_API_KEY}" ]; then
    KEY_LEN=${#LLM_API_KEY}
    if [ "${KEY_LEN}" -gt 8 ]; then
        KEY_MASK="${LLM_API_KEY:0:4}...${LLM_API_KEY: -4}"
    else
        KEY_MASK="***"
    fi
    echo "  [OK] API key set (${KEY_MASK}, length=${KEY_LEN})"
    echo "  [OK] LLM config -> model=${LLM_MODEL}, url=${LLM_URL}"
else
    echo "  [WARN] No API key set. Edit llm_config.json manually to set chat.api_key."
fi

# Export API key as env var so Python can read it safely (avoids shell
# escaping issues with special characters in command-line arguments)
export LLM_API_KEY
export LLM_MODEL
export LLM_URL

for LLM_CONFIG in "${REGISTRY_DIR}/common/config/llm_config.json" "${ORCHESTRATION_DIR}/common/config/llm_config.json"; do
    if [ ! -f "${LLM_CONFIG}" ]; then
        echo "  [WARN] ${LLM_CONFIG} not found, skipping."
        continue
    fi
    echo "[CONFIG] Updating chat model in ${LLM_CONFIG}..."
    python3 -c "
import json, os, sys

config_path = sys.argv[1]
api_key = os.environ.get('LLM_API_KEY', '')
model = os.environ.get('LLM_MODEL', '')
url = os.environ.get('LLM_URL', '')

with open(config_path, 'r', encoding='utf-8') as f:
    config = json.load(f)

if 'chat' in config:
    config['chat']['model'] = model
    config['chat']['url'] = url
    if api_key:
        config['chat']['api_key'] = api_key

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write('\n')

# Report what was written for verification
written_key = config.get('chat', {}).get('api_key', '(missing)')
if written_key and len(written_key) > 8:
    display = written_key[:4] + '...' + written_key[-4:]
else:
    display = '***'
print(f'  chat.api_key = {display}')
" "${LLM_CONFIG}"
    echo "  [OK] Chat model updated -> model=${LLM_MODEL}, url=${LLM_URL}"
done

# --- Fix agent_registry_url in server.conf (https -> http) ---
# registry-center runs in HTTP mode; default server.conf has https which causes
# SSL: WRONG_VERSION_NUMBER errors in orchestration-center.
SERVER_CONF="${ORCHESTRATION_DIR}/etc/conf/server.conf"
if [ -f "${SERVER_CONF}" ]; then
    echo "[CONFIG] Fixing agent_registry_url in server.conf (https -> http)..."
    sed -i 's|agent_registry_url=https://|agent_registry_url=http://|' "${SERVER_CONF}"
    echo "  [OK] server.conf agent_registry_url set to http."
else
    echo "  [WARN] server.conf not found at ${SERVER_CONF}, skipping registry URL fix."
fi

# =============================================================================
# Step 3.7: Configure Nginx (HTTPS reverse proxy on port 443)
# =============================================================================
echo ""
echo "=========================================="
echo " Step 3.7: Configuring Nginx"
echo "=========================================="

# Generate self-signed SSL certificate for HTTPS
NGINX_SSL_DIR="/etc/nginx/ssl"
if [ ! -f "${NGINX_SSL_DIR}/cert.pem" ] || [ ! -f "${NGINX_SSL_DIR}/key.pem" ]; then
    echo "[SSL] Generating self-signed SSL certificate..."
    run_sudo mkdir -p "${NGINX_SSL_DIR}"
    run_sudo openssl req -x509 -nodes -days 365 \
        -newkey rsa:2048 \
        -keyout "${NGINX_SSL_DIR}/key.pem" \
        -out "${NGINX_SSL_DIR}/cert.pem" \
        -subj "/CN=localhost" 2>/dev/null
    if [ -f "${NGINX_SSL_DIR}/cert.pem" ] && [ -f "${NGINX_SSL_DIR}/key.pem" ]; then
        echo "  [OK] SSL certificate generated at ${NGINX_SSL_DIR}"
    else
        echo "  [ERROR] Failed to generate SSL certificate."
        exit 1
    fi
else
    echo "[SKIP] SSL certificate already exists at ${NGINX_SSL_DIR}"
fi

# Generate nginx configuration file
echo "[CONFIG] Generating nginx configuration..."
NGINX_CONF_LOCAL="${WORK_DIR}/openan-nginx.conf"
cat > "${NGINX_CONF_LOCAL}" << 'NGINX_EOF'
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/nginx/ssl/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/key.pem;

    # Frontend (Vite dev server with WebSocket upgrade for HMR)
    location / {
        proxy_pass http://127.0.0.1:3003;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Orchestration backend API (trailing slash strips /api/orchestrate prefix)
    location /api/orchestrate/ {
        proxy_pass http://127.0.0.1:5001/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Registry Center (trailing slash strips /registry prefix)
    location /registry/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX_EOF

# Deploy configuration to nginx conf.d
NGINX_CONF_DEST="/etc/nginx/conf.d/openan.conf"
run_sudo cp "${NGINX_CONF_LOCAL}" "${NGINX_CONF_DEST}"
echo "  [OK] Configuration deployed to ${NGINX_CONF_DEST}"

# Remove default site if it conflicts (Debian/Ubuntu ships a default server on port 80)
if [ -f /etc/nginx/sites-enabled/default ]; then
    echo "[CLEAN] Removing default nginx site to avoid conflicts..."
    run_sudo rm -f /etc/nginx/sites-enabled/default
fi

# Test nginx configuration
echo "[TEST] Validating nginx configuration..."
if run_sudo nginx -t 2>&1; then
    echo "  [OK] nginx configuration is valid."
else
    echo "  [ERROR] nginx configuration test failed."
    exit 1
fi

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
export AGENT_REGISTRY_URL="http://127.0.0.1:5000"
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

# Start nginx (HTTPS reverse proxy on port 443)
free_port 443
echo "[START] nginx (https://localhost)..."
if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
    echo "  [INFO] nginx is already running, reloading configuration..."
    run_sudo nginx -s reload 2>/dev/null || true
elif command -v systemctl >/dev/null 2>&1; then
    run_sudo systemctl start nginx 2>/dev/null || run_sudo nginx
else
    run_sudo nginx 2>/dev/null || true
fi
sleep 1
NGINX_PID="$(pgrep -f 'nginx: master' 2>/dev/null | head -1)" || NGINX_PID=""
if [ -n "${NGINX_PID}" ]; then
    echo "  [OK] nginx started (PID: ${NGINX_PID})"
else
    echo "  [WARN] Could not determine nginx master PID."
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
echo " orchestration frontend: http://localhost:3003   (PID: ${FRONTEND_REAL_PID})"
echo " agents examples server: http://127.0.0.1:${AGENTS_PORT}  (PID: ${AGENTS_PID})"
echo " nginx (HTTPS):          https://localhost        (PID: ${NGINX_PID})"
echo ""
echo " Logs:"
echo "   ${REGISTRY_DIR}/registry-center.log"
echo "   ${ORCHESTRATION_DIR}/backend.log"
echo "   ${ORCHESTRATION_DIR}/frontend.log"
echo "   ${ORCHESTRATION_DIR}/agents-server.log"
echo ""
echo " To stop all: kill ${REGISTRY_PID} ${OC_BACKEND_PID} ${FRONTEND_REAL_PID} ${AGENTS_PID}"
echo "           nginx: run_sudo systemctl stop nginx  (or: sudo nginx -s stop)"
echo "=========================================="
